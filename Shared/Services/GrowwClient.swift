import CryptoKit
import Foundation

/// Groww Trade API (https://groww.in/trade-api/docs), called straight from the device.
///
///   POST /token/api/access     daily access token (TOTP or approval checksum)
///   GET  /holdings/user        demat holdings: trading_symbol, quantity, average_price
///   GET  /live-data/quote      per symbol: last_price, day_change
///   GET  /margins/detail/user  clear_cash
///
/// Requires an active Trade API subscription. Mutual funds aren't exposed by the API.
struct GrowwClient: Sendable {
    static let brokerID = BrokerID.groww
    static let displayName = "Groww"
    static let shortName = "GROWW"
    static let currency = CurrencyCode.inr

    private static let baseURL = URL(string: "https://api.groww.in/v1")!
    private static let ist = TimeZone(identifier: "Asia/Kolkata")!

    var keychain: Keychain = .shared

    var isConfigured: Bool {
        keychain.string(.growwAPIKey) != nil
            && (keychain.string(.growwTOTPSecret) != nil || keychain.string(.growwAPISecret) != nil)
    }

    func fetchHoldings() async throws -> BrokerHoldings {
        do {
            do {
                return try await fetch(token: accessToken())
            } catch GrowwFailure.unauthorized {
                // Token revoked or expired early: log in once more.
                try? keychain.set(nil, for: .growwAccessToken)
                return try await fetch(token: accessToken())
            }
        } catch let failure as GrowwFailure {
            throw PortfolioError.groww(failure.message)
        }
    }

    private func fetch(token: String) async throws -> BrokerHoldings {
        async let holdingsPayload: HoldingsPayload = get("/holdings/user", token: token)
        async let marginsPayload: MarginsPayload = get("/margins/detail/user", token: token)
        let holdings = try await holdingsPayload.holdings.filter { $0.quantity > 0 }
        let cash = try await marginsPayload.clearCash ?? 0

        let positions = await holdings.concurrentMap(limit: 5) { holding in
            await position(for: holding, token: token)
        }

        return BrokerHoldings(
            id: Self.brokerID,
            displayName: Self.displayName,
            shortName: Self.shortName,
            currency: Self.currency,
            cash: cash,
            syncedAt: .now,
            syncStatus: .ok,
            positions: positions
        )
    }

    /// Holdings don't say which exchange a stock trades on: try NSE, then BSE.
    /// Unpriceable holdings (suspended, delisted) are valued at cost rather than dropped.
    private func position(for holding: Holding, token: String) async -> Position {
        for exchange in ["NSE", "BSE"] {
            let quote: QuotePayload? = try? await get(
                "/live-data/quote",
                query: ["exchange": exchange, "segment": "CASH", "trading_symbol": holding.tradingSymbol],
                token: token
            )
            if let quote, let last = quote.lastPrice {
                let previous = quote.dayChange.map { last - $0 } ?? quote.ohlc?.close ?? last
                return Position(
                    symbol: holding.tradingSymbol, name: holding.tradingSymbol, exchange: exchange,
                    currency: Self.currency, quantity: holding.quantity, lastPrice: last, previousClose: previous
                )
            }
        }
        let cost = holding.averagePrice ?? 0
        return Position(
            symbol: holding.tradingSymbol, name: holding.tradingSymbol, exchange: "NSE",
            currency: Self.currency, quantity: holding.quantity, lastPrice: cost, previousClose: cost
        )
    }

    // MARK: - Auth

    /// Cached in the Keychain until Groww's daily 06:00 IST expiry.
    private func accessToken(now: Date = .now) async throws -> String {
        if let cached = keychain.string(.growwAccessToken) {
            let parts = cached.split(separator: "\n")
            if parts.count == 2, let expiry = TimeInterval(parts[1]), now.timeIntervalSince1970 < expiry {
                return String(parts[0])
            }
        }

        guard let apiKey = keychain.string(.growwAPIKey) else { throw PortfolioError.notConfigured }
        let body: [String: Any]
        if let secret = keychain.string(.growwTOTPSecret) {
            guard let code = TOTP.code(secret: secret, at: now) else {
                throw PortfolioError.groww("TOTP secret isn't valid base32.")
            }
            body = ["key_type": "totp", "totp": code]
        } else if let secret = keychain.string(.growwAPISecret) {
            let timestamp = Int(now.timeIntervalSince1970)
            let checksum = SHA256.hash(data: Data((secret + String(timestamp)).utf8))
                .map { String(format: "%02x", $0) }.joined()
            body = ["key_type": "approval", "checksum": checksum, "timestamp": timestamp]
        } else {
            throw PortfolioError.notConfigured
        }

        var request = Self.request(path: "/token/api/access", token: apiKey)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await HTTP.send(request)
        guard response.statusCode == 200,
              let token = (try? JSONDecoder().decode(TokenResponse.self, from: data))?.token else {
            let detail = (try? HTTP.snakeCaseDecoder.decode(Envelope<EmptyPayload>.self, from: data))?.error?.text
            throw PortfolioError.groww("Login failed (\(response.statusCode))\(detail.map { ": \($0)" } ?? "").")
        }

        try? keychain.set("\(token)\n\(Self.nextExpiry(after: now).timeIntervalSince1970)", for: .growwAccessToken)
        return token
    }

    static func nextExpiry(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ist
        let sixAM = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: date) ?? date
        return sixAM > date ? sixAM : calendar.date(byAdding: .day, value: 1, to: sixAM) ?? date.addingTimeInterval(86_400)
    }

    // MARK: - HTTP

    private static func request(path: String, query: [String: String] = [:], token: String) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1.0", forHTTPHeaderField: "X-API-VERSION")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-request-id")
        return request
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], token: String) async throws -> T {
        let (data, response) = try await HTTP.send(Self.request(path: path, query: query, token: token))
        if response.statusCode == 401 || response.statusCode == 403 { throw GrowwFailure.unauthorized }
        let envelope = try HTTP.snakeCaseDecoder.decode(Envelope<T>.self, from: data)
        guard response.statusCode < 400, envelope.status != "FAILURE", let payload = envelope.payload else {
            throw GrowwFailure.api(envelope.error?.text ?? "HTTP \(response.statusCode) for \(path)")
        }
        return payload
    }
}

// MARK: - Wire types

private enum GrowwFailure: Error {
    case unauthorized
    case api(String)

    var message: String {
        switch self {
        case .unauthorized: "Login rejected. Check your API key in the app."
        case .api(let text): text
        }
    }
}

private struct Envelope<Payload: Decodable>: Decodable {
    struct APIError: Decodable {
        let code: String?
        let message: String?
        var text: String? { message ?? code }
    }

    let status: String?
    let payload: Payload?
    let error: APIError?
}

private struct EmptyPayload: Decodable {}
private struct TokenResponse: Decodable { let token: String }

private struct Holding: Decodable, Sendable {
    let tradingSymbol: String
    let quantity: Double
    let averagePrice: Double?
}

private struct HoldingsPayload: Decodable { let holdings: [Holding] }
private struct MarginsPayload: Decodable { let clearCash: Double? }

private struct QuotePayload: Decodable {
    struct OHLC: Decodable { let close: Double? }
    let lastPrice: Double?
    let dayChange: Double?
    let ohlc: OHLC?
}
