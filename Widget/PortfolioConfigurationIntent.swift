import AppIntents
import WidgetKit

enum BaseCurrencyOption: String, AppEnum {
    case inr, usd

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Currency"
    static let caseDisplayRepresentations: [BaseCurrencyOption: DisplayRepresentation] = [
        .inr: "Indian Rupee (₹)",
        .usd: "US Dollar ($)",
    ]

    var code: CurrencyCode {
        switch self {
        case .inr: .inr
        case .usd: .usd
        }
    }
}

/// Long-press → Edit Widget lets the user pick the currency the combined total is shown in.
/// Per-broker values always stay in their native currency (₹ for Groww, $ for IBKR).
struct PortfolioConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Portfolio"
    static let description = IntentDescription("Choose the currency for your combined net worth.")

    @Parameter(title: "Show total in", default: .inr)
    var baseCurrency: BaseCurrencyOption

    init() {}

    init(baseCurrency: BaseCurrencyOption) {
        self.baseCurrency = baseCurrency
    }
}
