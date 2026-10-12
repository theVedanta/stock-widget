import Foundation

protocol PortfolioDataSource: Sendable {
    /// True for canned data; the widget labels it "SAMPLE" and never caches it.
    var isSample: Bool { get }
    func fetchPortfolio() async throws -> PortfolioSummary
}

extension PortfolioDataSource {
    var isSample: Bool { false }
}

enum PortfolioError: LocalizedError, Equatable {
    case invalidEndpoint
    case missingCredentials
    case unauthorized
    case http(Int)
    case invalidResponse
    case unsupportedSchema(Int)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Endpoint must be an https:// URL."
        case .missingCredentials: "Add your API token in the app."
        case .unauthorized: "Token rejected. Update it in the app."
        case .http(let code): "Server error (\(code))."
        case .invalidResponse: "Unexpected response from server."
        case .unsupportedSchema(let version): "Update the app to read schema v\(version)."
        case .keychain(let status): "Keychain error (\(status))."
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? PortfolioError { return error.errorDescription ?? "Something went wrong." }
        if error is URLError { return "You're offline." }
        if error is DecodingError { return "Unexpected response from server." }
        return "Something went wrong."
    }
}

/// Fetches the aggregated portfolio from your backend.
///
/// The backend owns the Groww and IBKR integrations (and their credentials); the
/// device only ever holds a read-only, revocable bearer token for this one endpoint.
struct RemotePortfolioDataSource: PortfolioDataSource {
    let endpoint: URL
    var credentials: CredentialStore = .shared
    var session: URLSession = .portfolio

    func fetchPortfolio() async throws -> PortfolioSummary {
        guard let token = credentials.readToken() else { throw PortfolioError.missingCredentials }

        // Widgets get a few seconds of runtime per reload, so keep the timeout tight.
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PortfolioError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw PortfolioError.unauthorized
        default: throw PortfolioError.http(http.statusCode)
        }

        let summary = try JSONDecoder.portfolio.decode(PortfolioSummary.self, from: data)
        guard summary.schemaVersion == PortfolioSummary.supportedSchemaVersion else {
            throw PortfolioError.unsupportedSchema(summary.schemaVersion)
        }
        return summary
    }
}

extension URLSession {
    /// No disk cache (balances shouldn't linger in URLCache) and fail fast when offline.
    static let portfolio: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()
}

enum PortfolioDataSourceFactory {
    static func make() -> PortfolioDataSource {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return MockPortfolioDataSource()
        }
        if let endpoint = BackendConfiguration.endpoint {
            return RemotePortfolioDataSource(endpoint: endpoint)
        }
        // Not configured yet: render sample data rather than an empty widget.
        return MockPortfolioDataSource()
    }
}
