import Foundation

enum MoneyFormat {
    /// Full amount with locale grouping: ₹83,74,596 / $74,628.
    static func full(_ value: Double, _ currency: CurrencyCode, fractionDigits: Int = 0) -> String {
        value.formatted(
            .currency(code: currency.rawValue)
                .locale(currency.locale)
                .precision(.fractionLength(fractionDigits))
        )
    }

    /// Price with two decimals: ₹2,945.30 / $187.62.
    static func price(_ value: Double, _ currency: CurrencyCode) -> String {
        full(value, currency, fractionDigits: 2)
    }

    /// Short amount: ₹17.59L, ₹1.24Cr, $74.6K, $1.20M. Uses a true minus sign.
    static func compact(_ value: Double, _ currency: CurrencyCode, signed: Bool = false) -> String {
        let magnitude = abs(value)
        let sign = value < 0 ? "−" : (signed && value > 0 ? "+" : "")
        let units: [(divisor: Double, suffix: String)] = currency == .inr
            ? [(1e7, "Cr"), (1e5, "L"), (1e3, "K")]
            : [(1e9, "B"), (1e6, "M"), (1e3, "K")]

        for unit in units where magnitude >= unit.divisor {
            let scaled = magnitude / unit.divisor
            let digits = scaled >= 100 ? 0 : (scaled >= 10 ? 1 : 2)
            let number = scaled.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(currency.locale))
            return sign + currency.symbol + number + unit.suffix
        }
        return sign + currency.symbol + magnitude.formatted(.number.precision(.fractionLength(0)).locale(currency.locale))
    }

    /// Signed percentage from a fraction: 0.0152 → "+1.52%".
    static func percent(_ fraction: Double) -> String {
        let text = abs(fraction).formatted(.percent.precision(.fractionLength(2)).locale(Locale(identifier: "en_US")))
        if fraction > 0.00005 { return "+" + text }
        if fraction < -0.00005 { return "−" + text }
        return text
    }
}

enum FreshnessFormat {
    /// "Updated just now" / "Updated 4m ago" / "Updated 2h ago" / "Updated 3d ago".
    static func updated(asOf: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(asOf))
        return switch seconds {
        case ..<60: "Updated just now"
        case ..<3_600: "Updated \(Int(seconds / 60))m ago"
        case ..<86_400: "Updated \(Int(seconds / 3_600))h ago"
        default: "Updated \(Int(seconds / 86_400))d ago"
        }
    }
}
