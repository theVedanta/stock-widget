import Foundation

enum DataFreshness: Hashable, Sendable {
    /// Fetched (or served from a still-fresh cache) on this reload.
    case live
    /// Network failed; showing the last good payload.
    case cached
}

struct PortfolioLoad: Sendable {
    let summary: PortfolioSummary
    let freshness: DataFreshness
}

/// Last good payload, persisted in the App Group so it survives extension restarts
/// and is readable while the device is locked (after first unlock).
struct PortfolioCache: Sendable {
    struct Record: Codable {
        let summary: PortfolioSummary
        let fetchedAt: Date
    }

    let fileURL: URL?

    init(fileURL: URL? = AppGroup.containerURL?.appendingPathComponent("portfolio-cache.json")) {
        self.fileURL = fileURL
    }

    func read() -> Record? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder.portfolio.decode(Record.self, from: data)
    }

    func write(_ record: Record) {
        guard let fileURL, let data = try? JSONEncoder.portfolio.encode(record) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Single entry point for portfolio data, shared by the app and the widget. Throttles
/// broker calls, de-duplicates concurrent requests (medium + large widgets reload together)
/// and falls back to the last good result when offline.
actor PortfolioRepository {
    static let shared = PortfolioRepository()

    private let aggregator: PortfolioAggregator
    private let cache: PortfolioCache
    private var inFlight: Task<PortfolioSummary, Error>?

    init(aggregator: PortfolioAggregator = PortfolioAggregator(), cache: PortfolioCache = PortfolioCache()) {
        self.aggregator = aggregator
        self.cache = cache
    }

    /// - Parameter force: skip the throttle and regenerate the IBKR Flex statement (used by the app).
    func load(now: Date = .now, force: Bool = false) async throws -> PortfolioLoad {
        let record = cache.read()
        if !force, let record, now.timeIntervalSince(record.fetchedAt) < RefreshPolicy.minimumFetchInterval {
            return PortfolioLoad(summary: record.summary, freshness: .live)
        }

        do {
            let summary = try await fetchDeduplicated(previous: record?.summary, force: force)
            cache.write(.init(summary: summary, fetchedAt: now))
            return PortfolioLoad(summary: summary, freshness: .live)
        } catch PortfolioError.notConfigured {
            throw PortfolioError.notConfigured
        } catch {
            guard let record else { throw error }
            return PortfolioLoad(summary: record.summary, freshness: .cached)
        }
    }

    /// Instant, network-free result for widget gallery snapshots.
    func cached() -> PortfolioLoad? {
        cache.read().map { PortfolioLoad(summary: $0.summary, freshness: .live) }
    }

    private func fetchDeduplicated(previous: PortfolioSummary?, force: Bool) async throws -> PortfolioSummary {
        if let inFlight { return try await inFlight.value }
        let aggregator = aggregator
        let task = Task { try await aggregator.fetchPortfolio(previous: previous, forceStatement: force) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
