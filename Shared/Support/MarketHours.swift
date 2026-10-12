import Foundation

/// Regular trading session for an exchange. Exchange holidays are not modelled:
/// on a holiday the widget simply refreshes at the market-hours cadence and sees no change.
struct MarketSession: Sendable {
    let name: String
    let timeZone: TimeZone
    /// Minutes after local midnight.
    let openMinute: Int
    let closeMinute: Int

    static let nse = MarketSession(name: "NSE", timeZone: TimeZone(identifier: "Asia/Kolkata")!, openMinute: 9 * 60 + 15, closeMinute: 15 * 60 + 30)
    static let nyse = MarketSession(name: "NYSE", timeZone: TimeZone(identifier: "America/New_York")!, openMinute: 9 * 60 + 30, closeMinute: 16 * 60)

    static let all: [MarketSession] = [.nse, .nyse]

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    func isOpen(at date: Date) -> Bool {
        guard isTradingDay(date) else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return (openMinute..<closeMinute).contains(minute)
    }

    /// Today's close, if the session is currently open.
    func close(after date: Date) -> Date? {
        guard isOpen(at: date) else { return nil }
        return time(minute: closeMinute, on: date)
    }

    func nextOpen(after date: Date) -> Date {
        var day = calendar.startOfDay(for: date)
        for _ in 0..<8 {
            if isTradingDay(day), let open = time(minute: openMinute, on: day), open > date {
                return open
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        return date.addingTimeInterval(86_400)
    }

    private func isTradingDay(_ date: Date) -> Bool {
        (2...6).contains(calendar.component(.weekday, from: date)) // Mon–Fri
    }

    private func time(minute: Int, on day: Date) -> Date? {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
    }
}

enum RefreshPolicy {
    /// Cadence while NSE or NYSE is open. 20 min keeps a full NSE + NYSE day (~13h)
    /// at ~40 reloads, inside WidgetKit's daily budget.
    static let marketHoursInterval: TimeInterval = 20 * 60
    /// Longest gap while every market is closed (FX and after-hours still drift).
    static let offHoursMaxInterval: TimeInterval = 3 * 60 * 60
    /// Retry cadence after a failed fetch.
    static let retryInterval: TimeInterval = 10 * 60
    /// Don't hit the network again if the cache is younger than this.
    static let minimumFetchInterval: TimeInterval = 5 * 60

    static func nextReload(after now: Date, sessions: [MarketSession] = MarketSession.all) -> Date {
        let closes = sessions.compactMap { $0.close(after: now) }
        if !closes.isEmpty {
            let regular = now.addingTimeInterval(marketHoursInterval)
            // Pick up the closing print a couple of minutes after the bell.
            let afterClose = closes.min()!.addingTimeInterval(2 * 60)
            return min(regular, afterClose)
        }
        let nextOpen = sessions.map { $0.nextOpen(after: now) }.min() ?? now
        return min(nextOpen.addingTimeInterval(60), now.addingTimeInterval(offHoursMaxInterval))
    }

    /// Entry dates between reloads so "Updated Xm ago" stays accurate without extra fetches:
    /// every minute while the data is under an hour old, then every 15 minutes.
    static func entryDates(from start: Date, until end: Date, dataAsOf asOf: Date) -> [Date] {
        var dates = [start]
        var cursor = start
        while dates.count < 120 {
            let step: TimeInterval = cursor.timeIntervalSince(asOf) < 3_600 ? 60 : 15 * 60
            cursor = cursor.addingTimeInterval(step)
            guard cursor < end else { break }
            dates.append(cursor)
        }
        return dates
    }

    static func statusText(at date: Date, sessions: [MarketSession] = MarketSession.all) -> String {
        let open = sessions.filter { $0.isOpen(at: date) }.map(\.name)
        return open.isEmpty ? "Markets closed" : open.joined(separator: " · ") + " open"
    }
}
