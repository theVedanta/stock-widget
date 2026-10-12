import Foundation

enum DataFreshness: Hashable, Sendable {
    /// Fetched (or served from a still-fresh cache) on this reload.
    case live
    /// Network failed; showing the last good payload.
    case cached
    /// Mock data (previews, or backend not configured yet).
    case sample
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

/// Single entry point for portfolio data. Throttles network calls, de-duplicates
/// concurrent requests (medium + large widgets reload together) and falls back to cache.
actor PortfolioRepository {
    static let shared = PortfolioRepository()

    private let makeSource: @Sendable () -> PortfolioDataSource
    private let cache: PortfolioCache
    private var inFlight: Task<PortfolioSummary, Error>?

    init(
        source: @escaping @Sendable () -> PortfolioDataSource = PortfolioDataSourceFactory.make,
        cache: PortfolioCache = PortfolioCache()
    ) {
        self.makeSource = source
        self.cache = cache
    }

    func load(now: Date = .now) async throws -> PortfolioLoad {
        let source = makeSource()
        if source.isSample {
            return PortfolioLoad(summary: try await source.fetchPortfolio(), freshness: .sample)
        }

        if let record = cache.read(), now.timeIntervalSince(record.fetchedAt) < RefreshPolicy.minimumFetchInterval {
            return PortfolioLoad(summary: record.summary, freshness: .live)
        }

        do {
            let summary = try await fetchDeduplicated(from: source)
            cache.write(.init(summary: summary, fetchedAt: now))
            return PortfolioLoad(summary: summary, freshness: .live)
        } catch {
            guard let record = cache.read() else { throw error }
            return PortfolioLoad(summary: record.summary, freshness: .cached)
        }
    }

    /// Instant, network-free result for widget gallery snapshots.
    func cached() -> PortfolioLoad? {
        cache.read().map { PortfolioLoad(summary: $0.summary, freshness: .live) }
    }

    private func fetchDeduplicated(from source: PortfolioDataSource) async throws -> PortfolioSummary {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await source.fetchPortfolio() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
