import SwiftUI
import WidgetKit

/// Left: combined net worth + today's P&L. Right: broker split + top 2 movers.
struct MediumPortfolioView: View {
    let portfolio: PortfolioDisplayModel
    let date: Date
    let freshness: DataFreshness

    var body: some View {
        HStack(spacing: 14) {
            summaryColumn
            Rectangle()
                .fill(Theme.border)
                .frame(width: 0.5)
            breakdownColumn
        }
    }

    private var summaryColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("NET WORTH")
            Spacer(minLength: 6)
            TotalValueText(value: portfolio.totalValue, currency: portfolio.baseCurrency, size: 26)
            ChangeBadge(amount: portfolio.dayChange, percent: portfolio.dayChangePercent, currency: portfolio.baseCurrency)
                .padding(.top, 6)
            Spacer(minLength: 6)
            FreshnessFooter(asOf: portfolio.asOf, now: date, freshness: freshness)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var breakdownColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(portfolio.brokers) { broker in
                HStack(spacing: 6) {
                    BrokerTag(id: broker.id, name: broker.shortName, status: broker.syncStatus)
                    Spacer(minLength: 4)
                    Text(MoneyFormat.compact(broker.nativeValue, broker.nativeCurrency))
                        .font(.numeric(13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .privacySensitive()
                }
            }
            AllocationBar(brokers: portfolio.brokers)
                .padding(.vertical, 1)

            Spacer(minLength: 0)

            SectionLabel("TOP MOVERS")
            ForEach(portfolio.topMovers.prefix(2)) { holding in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.broker(holding.broker))
                        .frame(width: 4, height: 4)
                    Text(holding.symbol)
                        .font(.label(12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    PercentText(fraction: holding.dayChangePercent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
