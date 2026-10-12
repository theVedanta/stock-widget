import Foundation

/// ISO-4217 currency code. A struct rather than an enum so an unexpected
/// currency (e.g. an IBKR EUR sub-account) works without code changes.
struct CurrencyCode: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue.uppercased() }

    static let inr = CurrencyCode(rawValue: "INR")
    static let usd = CurrencyCode(rawValue: "USD")

    var description: String { rawValue }

    /// Locale used for grouping (₹12,45,300 for INR vs $1,245,300 for USD).
    var locale: Locale {
        switch self {
        case .inr: Locale(identifier: "en_IN")
        default: Locale(identifier: "en_US")
        }
    }

    var symbol: String {
        switch self {
        case .inr: "₹"
        case .usd: "$"
        default: rawValue + " "
        }
    }
}

/// Spot FX rates: units of each currency per 1 `base`.
/// `{"base": "USD", "rates": {"INR": 88.65}}` means 1 USD = 88.65 INR.
struct FXRates: Codable, Hashable, Sendable {
    let base: CurrencyCode
    let rates: [String: Double]
    let asOf: Date

    /// Converts `amount` between any two currencies via the base currency.
    /// Returns `nil` when a rate is missing so callers can flag it instead of showing a wrong total.
    func convert(_ amount: Double, from source: CurrencyCode, to target: CurrencyCode) -> Double? {
        if source == target { return amount }
        guard let from = rate(for: source), let to = rate(for: target), from > 0 else { return nil }
        return amount / from * to
    }

    private func rate(for currency: CurrencyCode) -> Double? {
        currency == base ? 1 : rates[currency.rawValue]
    }
}
