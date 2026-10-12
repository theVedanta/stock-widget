import WidgetKit

struct PortfolioEntry: TimelineEntry {
    let date: Date
    /// `nil` while loading (placeholder) or when nothing has ever loaded.
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

    static func loading(date: Date = .now) -> PortfolioEntry {
        PortfolioEntry(date: date, portfolio: nil, freshness: .live)
    }

    static func unavailable(_ message: String, date: Date = .now) -> PortfolioEntry {
        PortfolioEntry(date: date, portfolio: nil, freshness: .live, errorMessage: message)
    }
}
