import Foundation

enum PortfolioError: LocalizedError, Equatable {
    case notConfigured
    case groww(String)
    case ibkr(String)
    case prices(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Open the app to add your Groww or IBKR keys."
        case .groww(let message): "Groww: \(message)"
        case .ibkr(let message): "IBKR: \(message)"
        case .prices(let message): "Prices: \(message)"
        case .keychain(let status): "Keychain error (\(status))."
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? PortfolioError { return error.errorDescription ?? "Something went wrong." }
        if error is URLError { return "You're offline." }
        if error is DecodingError { return "Unexpected response from a broker." }
        return "Something went wrong."
    }
}

enum HTTP {
    /// No disk cache (balances shouldn't linger in URLCache) and fail fast when offline:
    /// a widget only gets a few seconds per reload.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration)
    }()

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    static let snakeCaseDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

extension Array where Element: Sendable {
    /// Order-preserving async map with at most `limit` transforms in flight (API rate limits).
    func concurrentMap<T: Sendable>(limit: Int, _ transform: @escaping @Sendable (Element) async -> T) async -> [T] {
        var results = [T?](repeating: nil, count: count)
        await withTaskGroup(of: (Int, T).self) { group in
            var next = 0
            for _ in 0..<Swift.min(limit, count) {
                let index = next
                group.addTask { (index, await transform(self[index])) }
                next += 1
            }
            while let finished = await group.next() {
                results[finished.0] = finished.1
                if next < count {
                    let index = next
                    group.addTask { (index, await transform(self[index])) }
                    next += 1
                }
            }
        }
        return results.map { $0! }
    }
}
