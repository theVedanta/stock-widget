import SwiftUI
import WidgetKit

/// Full dashboard: net worth + sparkline, broker cards, top 5 positions, footer.
struct LargePortfolioView: View {
    let portfolio: PortfolioDisplayModel
    let date: Date
    let freshness: DataFreshness

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 8) {
                ForEach(portfolio.brokers) { broker in
                    BrokerCard(broker: broker, baseCurrency: portfolio.baseCurrency)
                }
            }
            // Five rows on most phones; gracefully drops to four/three on smaller screens.
            ViewThatFits(in: .vertical) {
                positions(limit: 5)
                positions(limit: 4)
                positions(limit: 3)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            FreshnessFooter(
                asOf: portfolio.asOf,
                now: date,
                freshness: freshness,
                trailing: [RefreshPolicy.statusText(at: date), portfolio.fxLabel]
                    .compactMap { $0 }
                    .joined(separator: "  ·  ")
            )
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel("NET WORTH")
                TotalValueText(value: portfolio.totalValue, currency: portfolio.baseCurrency, size: 30)
                ChangeBadge(amount: portfolio.dayChange, percent: portfolio.dayChangePercent, currency: portfolio.baseCurrency)
            }
            .layoutPriority(1)

            VStack(alignment: .trailing, spacing: 2) {
                Text("30D")
                    .font(.label(8.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                Sparkline(values: portfolio.sparkline)
            }
            .frame(maxWidth: 120, maxHeight: 60)
        }
    }

    private func positions(limit: Int) -> some View {
        let holdings = Array(portfolio.topHoldings.prefix(limit))
        return VStack(spacing: 0) {
            HStack {
                SectionLabel("TOP POSITIONS")
                Spacer()
                SectionLabel("PRICE")
                    .frame(width: 86, alignment: .trailing)
                SectionLabel("24H")
                    .frame(width: 58, alignment: .trailing)
            }
            .padding(.bottom, 3)

            ForEach(holdings) { holding in
                PositionRow(holding: holding)
                if holding.id != holdings.last?.id {
                    Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 0.5)
                }
            }
        }
    }
}

private struct BrokerCard: View {
    let broker: PortfolioDisplayModel.Broker
    let baseCurrency: CurrencyCode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                BrokerTag(id: broker.id, name: broker.shortName, status: broker.syncStatus)
                Spacer(minLength: 2)
                PercentText(fraction: broker.dayChangePercent, size: 10.5)
            }
            Text(MoneyFormat.compact(broker.nativeValue, broker.nativeCurrency))
                .font(.numeric(16, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .privacySensitive()
            Text(subtitle)
                .font(.numeric(9.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .privacySensitive()
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
    }

    /// Native value is primary; the converted figure sits underneath (side-by-side currencies).
    private var subtitle: String {
        let share = broker.share.formatted(.percent.precision(.fractionLength(0)))
        guard broker.nativeCurrency != baseCurrency else { return "\(share) of total" }
        return "≈ \(MoneyFormat.compact(broker.baseValue, baseCurrency))  ·  \(share)"
    }
}

private struct PositionRow: View {
    let holding: PortfolioDisplayModel.Holding

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.broker(holding.broker))
                .frame(width: 5, height: 5)
            Text(holding.symbol)
                .font(.label(13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 4)
            Text(MoneyFormat.price(holding.lastPrice, holding.currency))
                .font(.numeric(12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 86, alignment: .trailing)
            PercentText(fraction: holding.dayChangePercent, size: 12.5)
                .frame(width: 58, alignment: .trailing)
        }
        .frame(height: 20)
    }
}

#Preview("Large", as: .systemLarge) {
    PortfolioWidget()
} timeline: {
    PortfolioEntry.sample(.gainDay)
    PortfolioEntry.sample(.lossDay, baseCurrency: .usd)
    PortfolioEntry.sample(.ibkrStale)
}
