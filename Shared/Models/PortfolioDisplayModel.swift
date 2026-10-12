import Foundation

/// Everything a widget view needs, pre-computed in the user's chosen base currency.
/// Views stay dumb: no FX math, sorting or aggregation happens in `body`.
struct PortfolioDisplayModel: Hashable, Sendable {
    struct Broker: Hashable, Sendable, Identifiable {
        let id: BrokerID
        let shortName: String
        let nativeCurrency: CurrencyCode
        let nativeValue: Double
        let baseValue: Double
        let dayChangePercent: Double
        /// Fraction of the combined portfolio held at this broker.
        let share: Double
        let syncStatus: SyncStatus
    }

    struct Holding: Hashable, Sendable, Identifiable {
        let id: String
        let symbol: String
        let broker: BrokerID
        let currency: CurrencyCode
        let lastPrice: Double
        let dayChangePercent: Double
        let baseValue: Double
    }

    let baseCurrency: CurrencyCode
    let asOf: Date
    let totalValue: Double
    let dayChange: Double
    let dayChangePercent: Double
    let brokers: [Broker]
    /// Largest positions by base-currency value.
    let topHoldings: [Holding]
    /// Largest absolute 24h % moves.
    let topMovers: [Holding]
    /// Daily totals in base currency, ending with the live value.
    let sparkline: [Double]
    /// e.g. "USD/INR 88.65"; nil when every broker is already in the base currency.
    let fxLabel: String?
    /// True when a rate needed for conversion was missing and a broker was left out of the total.
    let hasMissingFX: Bool

    init(summary: PortfolioSummary, baseCurrency base: CurrencyCode) {
        let fx = summary.fx
        let toBase: (Double, CurrencyCode) -> Double = { fx.convert($0, from: $1, to: base) ?? 0 }

        // Converting yesterday's value at today's rate keeps FX moves out of "today's P&L",
        // which is what you want for a stock P&L figure.
        let total = summary.brokers.reduce(0) { $0 + toBase($1.totalValue(using: fx), $1.currency) }
        let change = summary.brokers.reduce(0) { $0 + toBase($1.dayChange(using: fx), $1.currency) }
        let previous = total - change

        baseCurrency = base
        asOf = summary.asOf
        totalValue = total
        dayChange = change
        dayChangePercent = previous > 0 ? change / previous : 0
        let currencies = Set(summary.brokers.flatMap { [$0.currency] + $0.positions.map(\.currency) })
        hasMissingFX = currencies.contains { fx.convert(1, from: $0, to: base) == nil }

        brokers = summary.brokers.map { broker in
            let nativeValue = broker.totalValue(using: fx)
            let value = toBase(nativeValue, broker.currency)
            return Broker(
                id: broker.id,
                shortName: broker.shortName,
                nativeCurrency: broker.currency,
                nativeValue: nativeValue,
                baseValue: value,
                dayChangePercent: broker.dayChangePercent(using: fx),
                share: total > 0 ? value / total : 0,
                syncStatus: broker.syncStatus
            )
        }

        let holdings = summary.brokers.flatMap { broker in
            broker.positions.map { position in
                Holding(
                    id: "\(broker.id.rawValue):\(position.id)",
                    symbol: position.symbol,
                    broker: broker.id,
                    currency: position.currency,
                    lastPrice: position.lastPrice,
                    dayChangePercent: position.dayChangePercent,
                    baseValue: toBase(position.marketValue, position.currency)
                )
            }
        }
        topHoldings = Array(holdings.sorted { $0.baseValue > $1.baseValue }.prefix(5))
        topMovers = Array(holdings.sorted { abs($0.dayChangePercent) > abs($1.dayChangePercent) }.prefix(4))

        let history = summary.history
            .sorted { $0.timestamp < $1.timestamp }
            .map { point in
                summary.brokers.reduce(0) { $0 + toBase(point.values[$1.id.rawValue] ?? 0, $1.currency) }
            }
        sparkline = history + [total]

        fxLabel = Set(summary.brokers.map(\.currency))
            .subtracting([base])
            .sorted { $0.rawValue < $1.rawValue }
            .first
            .flatMap { other in
                guard let rate = fx.convert(1, from: other, to: base), rate > 0 else { return nil }
                // Quote the pair the conventional way round (USD/INR 88.65, not INR/USD 0.0113).
                return rate >= 1
                    ? "\(other)/\(base) \(rate.formatted(.number.precision(.fractionLength(2))))"
                    : "\(base)/\(other) \((1 / rate).formatted(.number.precision(.fractionLength(2))))"
            }
    }

    var sparklineChange: Double {
        guard let first = sparkline.first, let last = sparkline.last else { return 0 }
        return last - first
    }
}
