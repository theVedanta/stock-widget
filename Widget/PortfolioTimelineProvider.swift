import WidgetKit

struct PortfolioTimelineProvider: AppIntentTimelineProvider {
    var repository: PortfolioRepository = .shared

    /// Skeleton shown while the first timeline loads.
    func placeholder(in context: Context) -> PortfolioEntry {
        .loading()
    }

    /// Widget gallery + transient displays: must be fast, so never block on the network
    /// unless there's nothing cached at all.
    func snapshot(for configuration: PortfolioConfigurationIntent, in context: Context) async -> PortfolioEntry {
        let base = configuration.baseCurrency.code
        if let cached = await repository.cached() {
            return PortfolioEntry(date: .now, load: cached, baseCurrency: base)
        }
        if context.isPreview {
            return .loading()
        }
        return await entries(for: base, now: .now).entries.first ?? .loading()
    }

    func timeline(for configuration: PortfolioConfigurationIntent, in context: Context) async -> Timeline<PortfolioEntry> {
        let result = await entries(for: configuration.baseCurrency.code, now: .now)
        return Timeline(entries: result.entries, policy: .after(result.reloadDate))
    }

    /// One fetch per reload; the data is then repeated across minute-spaced entries
    /// so "Updated Xm ago" ticks without spending reload budget.
    private func entries(for base: CurrencyCode, now: Date) async -> (entries: [PortfolioEntry], reloadDate: Date) {
        do {
            let load = try await repository.load(now: now)
            let model = PortfolioDisplayModel(summary: load.summary, baseCurrency: base)
            let reloadDate = load.freshness == .cached
                ? now.addingTimeInterval(RefreshPolicy.retryInterval)
                : RefreshPolicy.nextReload(after: now)
            let entries = RefreshPolicy
                .entryDates(from: now, until: reloadDate, dataAsOf: load.summary.asOf)
                .map { PortfolioEntry(date: $0, portfolio: model, freshness: load.freshness) }
            return (entries, reloadDate)
        } catch {
            return ([.unavailable(PortfolioError.message(for: error), date: now)], now.addingTimeInterval(RefreshPolicy.retryInterval))
        }
    }
}
