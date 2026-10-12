import Foundation

/// Fetches Groww and IBKR concurrently on device, prices everything, converts FX and
/// records history.
struct PortfolioAggregator: Sendable {
    var groww = GrowwClient()
    var ibkr = IBKRClient()
    var history = HistoryStore()

    /// - Parameters:
    ///   - previous: last good summary; a broker that fails now keeps its old holdings marked `stale`.
    ///   - forceStatement: regenerate the IBKR Flex statement even if the cached one is fresh.
    func fetchPortfolio(previous: PortfolioSummary?, forceStatement: Bool = false) async throws -> PortfolioSummary {
        let growwEnabled = groww.isConfigured
        let ibkrEnabled = ibkr.isConfigured
        guard growwEnabled || ibkrEnabled else { throw PortfolioError.notConfigured }

        async let growwResult = Self.capture(growwEnabled) { try await groww.fetchHoldings() }
        async let ibkrResult = Self.capture(ibkrEnabled) { try await ibkr.fetchHoldings(forceStatement: forceStatement) }

        let results: [(BrokerID, Result<BrokerHoldings, Error>?)] = [(.groww, await growwResult), (.ibkr, await ibkrResult)]
        var brokers: [BrokerHoldings] = []
        var firstError: Error?
        for (id, result) in results {
            switch result {
            case .none:
                continue
            case .some(.success(let holdings)):
                brokers.append(holdings)
            case .some(.failure(let error)):
                firstError = firstError ?? error
                let message = PortfolioError.message(for: error)
                if let old = previous?.brokers.first(where: { $0.id == id }), old.syncStatus != .error {
                    brokers.append(old.marked(.stale, message: message))
                } else {
                    brokers.append(Self.placeholder(for: id).marked(.error, message: message))
                }
            }
        }

        if brokers.allSatisfy({ $0.syncStatus == .error }), let firstError { throw firstError }

        let currencies = Set(brokers.flatMap { [$0.currency] + $0.positions.map(\.currency) })
        let fx: FXRates
        do {
            fx = try await MarketData.fxRates(for: currencies)
        } catch {
            guard let old = previous?.fx else { throw error }
            fx = old
        }

        let now = Date.now
        let freshTotals = Dictionary(
            uniqueKeysWithValues: brokers.filter { $0.syncStatus == .ok }.map { ($0.id.rawValue, $0.totalValue(using: fx)) }
        )
        history.record(at: now, values: freshTotals)

        return PortfolioSummary(
            asOf: now,
            fx: fx,
            brokers: brokers,
            history: history.daily(before: now, days: 30, brokers: brokers.map(\.id.rawValue))
        )
    }

    private static func capture(
        _ enabled: Bool,
        _ body: @Sendable () async throws -> BrokerHoldings
    ) async -> Result<BrokerHoldings, Error>? {
        guard enabled else { return nil }
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// A broker that has never loaded: shown with a warning instead of silently missing from the total.
    private static func placeholder(for id: BrokerID) -> BrokerHoldings {
        let isGroww = id == .groww
        return BrokerHoldings(
            id: id,
            displayName: isGroww ? GrowwClient.displayName : IBKRClient.displayName,
            shortName: isGroww ? GrowwClient.shortName : IBKRClient.shortName,
            currency: isGroww ? GrowwClient.currency : IBKRClient.defaultCurrency,
            cash: 0,
            syncedAt: .now,
            syncStatus: .error,
            positions: []
        )
    }
}

/// Daily per-broker totals in the App Group, for the 30-day sparkline. Every refresh
/// overwrites today's value, so the last one of each (UTC) day is that day's close —
/// NSE and NYSE both close inside the same UTC day.
struct HistoryStore: Sendable {
    private struct Day: Codable {
        var recordedAt: Date
        var values: [String: Double]
    }

    var fileURL: URL? = AppGroup.fileURL("history.json")
    var retentionDays = 90

    func record(at date: Date, values: [String: Double]) {
        guard !values.isEmpty else { return }
        var days = load()
        let key = Self.dayKey(date)
        var day = days[key] ?? Day(recordedAt: date, values: [:])
        day.recordedAt = date
        day.values.merge(values) { _, new in new }
        days[key] = day

        let cutoff = Self.dayKey(date.addingTimeInterval(-Double(retentionDays) * 86_400))
        days = days.filter { $0.key >= cutoff }
        save(days)
    }

    /// Closes for the `days` days before `date`, oldest first. A broker missing on some day carries
    /// its previous value forward; days before a broker's first record are skipped, so the line
    /// never drops to zero.
    func daily(before date: Date, days count: Int, brokers: [String]) -> [HistoryPoint] {
        let today = Self.dayKey(date)
        let start = Self.dayKey(date.addingTimeInterval(-Double(count) * 86_400))
        var carried: [String: Double] = [:]
        var points: [HistoryPoint] = []
        for (key, day) in load().sorted(by: { $0.key < $1.key }) where key >= start && key < today {
            carried.merge(day.values) { _, new in new }
            if brokers.allSatisfy({ carried[$0] != nil }) {
                points.append(HistoryPoint(timestamp: day.recordedAt, values: carried.filter { brokers.contains($0.key) }))
            }
        }
        return points
    }

    func clear() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private static func dayKey(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle().year().month().day()) // UTC, "2026-10-12"
    }

    private func load() -> [String: Day] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder.portfolio.decode([String: Day].self, from: data)) ?? [:]
    }

    private func save(_ days: [String: Day]) {
        guard let fileURL, let data = try? JSONEncoder.portfolio.encode(days) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
