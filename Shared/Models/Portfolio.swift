import Foundation

// MARK: - Portfolio models
//
// Built on device by `PortfolioAggregator` from raw facts (quantities, prices, cash, FX).
// Totals, P&L and percentages are always derived, so they can never disagree.

struct PortfolioSummary: Codable, Hashable, Sendable {
    /// When the portfolio was last priced. Drives "Updated Xm ago".
    let asOf: Date
    let fx: FXRates
    let brokers: [BrokerHoldings]
    /// Daily closing values per broker (native currency), oldest first. Feeds the sparkline.
    let history: [HistoryPoint]
}

struct BrokerID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    static let groww = BrokerID(rawValue: "groww")
    static let ibkr = BrokerID(rawValue: "ibkr")
}

enum SyncStatus: String, Codable, Hashable, Sendable {
    case ok, stale, error

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SyncStatus(rawValue: raw) ?? .stale
    }
}

/// Everything held at a single broker, denominated in that broker's currency.
struct BrokerHoldings: Codable, Hashable, Sendable, Identifiable {
    let id: BrokerID
    let displayName: String
    /// Uppercase tag shown in pills, e.g. "GROWW", "IBKR".
    let shortName: String
    let currency: CurrencyCode
    let cash: Double
    let syncedAt: Date
    let syncStatus: SyncStatus
    let positions: [Position]
    /// Why the last sync failed, when `syncStatus` isn't `.ok`.
    var syncMessage: String? = nil

    // Positions can be in a different currency from the account (an IBKR USD account
    // holding a EUR-listed ETF), so totals convert each position into `currency`.

    func totalValue(using fx: FXRates) -> Double {
        positions.reduce(cash) { $0 + (fx.convert($1.marketValue, from: $1.currency, to: currency) ?? 0) }
    }

    func dayChange(using fx: FXRates) -> Double {
        positions.reduce(0) { $0 + (fx.convert($1.dayChange, from: $1.currency, to: currency) ?? 0) }
    }

    func dayChangePercent(using fx: FXRates) -> Double {
        let change = dayChange(using: fx)
        let previous = totalValue(using: fx) - change
        return previous > 0 ? change / previous : 0
    }

    func marked(_ status: SyncStatus, message: String?) -> BrokerHoldings {
        BrokerHoldings(
            id: id, displayName: displayName, shortName: shortName, currency: currency,
            cash: cash, syncedAt: syncedAt, syncStatus: status, positions: positions, syncMessage: message
        )
    }
}

struct Position: Codable, Hashable, Sendable, Identifiable {
    let symbol: String
    let name: String
    let exchange: String
    let currency: CurrencyCode
    let quantity: Double
    let lastPrice: Double
    let previousClose: Double

    var id: String { "\(exchange):\(symbol)" }
    var marketValue: Double { quantity * lastPrice }
    var dayChange: Double { quantity * (lastPrice - previousClose) }
    /// Fractional change, e.g. 0.0152 for +1.52%.
    var dayChangePercent: Double { previousClose > 0 ? lastPrice / previousClose - 1 : 0 }
}

struct HistoryPoint: Codable, Hashable, Sendable {
    let timestamp: Date
    /// Broker ID → total value in that broker's native currency.
    let values: [String: Double]
}

// MARK: - Decoding

extension JSONDecoder {
    /// Accepts ISO-8601 timestamps with or without fractional seconds.
    static var portfolio: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
                ?? (try? Date.ISO8601FormatStyle().parse(string)) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(string)")
        }
        return decoder
    }
}

extension JSONEncoder {
    static var portfolio: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
