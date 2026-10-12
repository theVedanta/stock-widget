import SwiftUI
import WidgetKit

@main
struct StockWidgetBundle: WidgetBundle {
    var body: some Widget {
        PortfolioWidget()
    }
}

struct PortfolioWidget: Widget {
    static let kind = "PortfolioWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: PortfolioConfigurationIntent.self,
            provider: PortfolioTimelineProvider()
        ) { entry in
            PortfolioWidgetView(entry: entry)
                .containerBackground(Theme.background, for: .widget)
        }
        .configurationDisplayName("Portfolio")
        .description("Groww and Interactive Brokers, combined.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct PortfolioWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PortfolioEntry

    var body: some View {
        Group {
            if let portfolio = entry.portfolio {
                switch family {
                case .systemLarge:
                    LargePortfolioView(portfolio: portfolio, date: entry.date, freshness: entry.freshness)
                default:
                    MediumPortfolioView(portfolio: portfolio, date: entry.date, freshness: entry.freshness)
                }
            } else if let message = entry.errorMessage {
                UnavailableView(message: message)
            } else {
                LoadingView()
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
