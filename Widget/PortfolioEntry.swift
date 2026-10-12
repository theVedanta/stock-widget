import WidgetKit

struct PortfolioEntry: TimelineEntry {
    let date: Date
    /// `nil` only when nothing has ever loaded (no cache, fetch failed).
    let portfolio: PortfolioDisplayModel?
    let freshness: DataFreshness
    let errorMessage: String?

    init(date: Date, portfolio: PortfolioDisplayModel?, freshness: DataFreshness, errorMessage: String? = nil) {
        self.date = date
        self.portfolio = portfolio
        self.freshness = freshness
        self.errorMessage = errorMessage
    }

    init(date: Date, load: PortfolioLoad, baseCurrency: CurrencyCode) {
        self.init(
            date: date,
            portfolio: PortfolioDisplayModel(summary: load.summary, baseCurrency: baseCurrency),
            freshness: load.freshness
        )
    }

    static func sample(
        _ scenario: MockPortfolio.Scenario = .gainDay,
        baseCurrency: CurrencyCode = .inr,
        date: Date = .now
    ) -> PortfolioEntry {
        PortfolioEntry(
            date: date,
            portfolio: PortfolioDisplayModel(summary: MockPortfolio.summary(scenario, now: date), baseCurrency: baseCurrency),
            freshness: .sample
        )
    }

    static func unavailable(_ message: String, date: Date = .now) -> PortfolioEntry {
        PortfolioEntry(date: date, portfolio: nil, freshness: .live, errorMessage: message)
    }
}
