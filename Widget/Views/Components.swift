import Charts
import SwiftUI
import WidgetKit

/// Small uppercase caption: "NET WORTH", "TOP MOVERS".
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.label(9.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// Combined total. Redacted on the Lock Screen / StandBy when the device is locked.
struct TotalValueText: View {
    let value: Double
    let currency: CurrencyCode
    let size: CGFloat

    var body: some View {
        Text(MoneyFormat.full(value, currency))
            .font(.numeric(size, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .contentTransition(.numericText(value: value))
            .widgetAccentable()
            .privacySensitive()
    }
}

/// "▲ +₹42.1K  +0.51%" capsule. The amount is private; the percentage is not.
struct ChangeBadge: View {
    let amount: Double
    let percent: Double
    let currency: CurrencyCode

    var body: some View {
        let color = Theme.trend(amount)
        HStack(spacing: 5) {
            Image(systemName: amount > 0 ? "arrow.up.right" : (amount < 0 ? "arrow.down.right" : "minus"))
                .font(.system(size: 9, weight: .heavy))
            Text(MoneyFormat.compact(amount, currency, signed: true))
                .privacySensitive()
            Text(MoneyFormat.percent(percent))
                .opacity(0.75)
        }
        .font(.numeric(11.5, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Broker tag pill: "● GROWW". A warning glyph appears when the broker sync is stale.
struct BrokerTag: View {
    let id: BrokerID
    let name: String
    var status: SyncStatus = .ok

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Theme.broker(id))
                .frame(width: 5, height: 5)
            Text(name)
                .font(.label(8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
            if status != .ok {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

/// Thin split bar showing each broker's share of the combined portfolio.
struct AllocationBar: View {
    let brokers: [PortfolioDisplayModel.Broker]

    var body: some View {
        GeometryReader { geometry in
            let gaps = CGFloat(max(brokers.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(brokers) { broker in
                    Capsule()
                        .fill(Theme.broker(broker.id))
                        .frame(width: max(2, (geometry.size.width - gaps) * broker.share))
                }
            }
        }
        .frame(height: 3)
        .privacySensitive()
    }
}

/// Signed % change in the trend colour.
struct PercentText: View {
    let fraction: Double
    var size: CGFloat = 12

    var body: some View {
        Text(MoneyFormat.percent(fraction))
            .font(.numeric(size, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.trend(fraction))
            .lineLimit(1)
    }
}

/// Area + line sparkline with a dashed baseline at the first value.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        if values.count >= 2, let low = values.min(), let high = values.max() {
            let color = Theme.trend(values.last! - values.first!)
            let padding = max((high - low) * 0.12, abs(high) * 0.0005)
            let floor = low - padding
            let points = Array(values.enumerated())

            Chart {
                RuleMark(y: .value("Start", values.first!))
                    .foregroundStyle(Theme.textTertiary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [2, 3]))

                ForEach(points, id: \.offset) { point in
                    AreaMark(
                        x: .value("Day", point.offset),
                        yStart: .value("Floor", floor),
                        yEnd: .value("Value", point.element)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(colors: [color.opacity(0.30), color.opacity(0)], startPoint: .top, endPoint: .bottom)
                    )

                    LineMark(x: .value("Day", point.offset), y: .value("Value", point.element))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                }

                PointMark(x: .value("Day", values.count - 1), y: .value("Value", values.last!))
                    .symbolSize(18)
                    .foregroundStyle(color)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartXScale(domain: 0...(values.count - 1))
            .chartYScale(domain: floor...(high + padding))
            .privacySensitive()
        } else {
            Color.clear
        }
    }
}

/// "Updated 4m ago" plus an offline marker when serving cached data.
struct FreshnessFooter: View {
    let asOf: Date
    let now: Date
    let freshness: DataFreshness
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if freshness == .cached {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.warning)
            }
            Text(FreshnessFormat.updated(asOf: asOf, now: now))
                .lineLimit(1)
            if let trailing {
                Spacer(minLength: 4)
                Text(trailing)
                    .lineLimit(1)
            }
        }
        .font(.label(9.5, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(Theme.textTertiary)
    }
}

/// Skeleton shown while the first timeline loads (WidgetKit placeholder).
struct LoadingView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("NET WORTH")
            bar(width: 150, height: 26)
            bar(width: 110, height: 18)
            Spacer(minLength: 0)
            if family == .systemLarge {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card)
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card)
                }
                .frame(height: 70)
                ForEach(0..<5, id: \.self) { _ in bar(width: .infinity, height: 14) }
                Spacer(minLength: 0)
            }
            bar(width: 80, height: 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 3, style: .continuous)
            .fill(Theme.card)
            .frame(maxWidth: width, minHeight: height, maxHeight: height)
    }
}

/// Shown when there is no data at all (not configured, first launch offline, bad token, …).
struct UnavailableView: View {
    let message: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text("Portfolio unavailable")
                .font(.label(13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let message {
                Text(message)
                    .font(.label(11, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
