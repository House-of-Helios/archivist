import Foundation

/// When a backup runs by itself. The background helper wakes every 5 minutes and whenever a
/// drive mounts, and asks each backup `isDue`.
public enum Schedule: Codable, Hashable, Sendable {
    case byHand
    case whenConnected                          // as soon as the destination appears, once per connection
    case hourly(minute: Int)                    // once an hour, at this minute
    case daily(hour: Int, minute: Int)          // once a day, at this time
    case weekly(weekday: Int, hour: Int, minute: Int)   // once a week (1 = Sunday … 7 = Saturday, Calendar's numbering)

    /// - lastRun: when this backup last finished (by hand or by schedule).
    /// - destinationSince: when the destination was first seen present this time (nil = not there).
    /// - setAt: when this schedule was chosen. A time before it was never missed: choosing
    ///   "daily at 14:00" at 22:00 waits for tomorrow's 14:00 instead of starting at once.
    /// A slot missed while the Mac slept runs on wake: due when the last run is older than the
    /// most recent slot.
    public func isDue(now: Date, lastRun: Date?, destinationSince: Date?, setAt: Date? = nil, calendar: Calendar = .current) -> Bool {
        guard let since = destinationSince else { return false }
        let lastFinished = lastRun ?? .distantPast
        let last = max(lastFinished, setAt ?? .distantPast)
        switch self {
        case .byHand:
            return false
        case .whenConnected:
            return lastFinished < since
        case let .hourly(minute):
            return mostRecent(DateComponents(minute: minute), before: now, calendar).map { last < $0 } ?? false
        case let .daily(hour, minute):
            return mostRecent(DateComponents(hour: hour, minute: minute), before: now, calendar).map { last < $0 } ?? false
        case let .weekly(weekday, hour, minute):
            return mostRecent(DateComponents(hour: hour, minute: minute, weekday: weekday), before: now, calendar).map { last < $0 } ?? false
        }
    }

    private func mostRecent(_ c: DateComponents, before now: Date, _ cal: Calendar) -> Date? {
        cal.nextDate(after: now, matching: c, matchingPolicy: .nextTime, direction: .backward)
            ?? (cal.date(from: c).flatMap { cal.dateComponents(in: cal.timeZone, from: $0) == cal.dateComponents(in: cal.timeZone, from: now) ? now : nil })
    }

    public var words: String {
        let f = DateFormatter()          // the Mac's own clock: 13:00 or 1:00 PM
        f.timeStyle = .short
        f.dateStyle = .none
        func time(_ h: Int, _ m: Int) -> String {
            Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()).map(f.string(from:)) ?? String(format: "%d:%02d", h, m)
        }
        switch self {
        case .byHand: return "Manually"
        case .whenConnected: return "When connected"
        case let .hourly(m): return String(format: "Once an hour at :%02d", m)
        case let .daily(h, m): return "Once a day at " + time(h, m)
        case let .weekly(d, h, m):
            let names = Calendar.current.weekdaySymbols
            return "Once a week on \(names[(d - 1 + 7) % 7]) at " + time(h, m)
        }
    }

    /// The short form for the window: "Daily at 14:00", "Weekly, Monday at 14:00", "—".
    public var short: String {
        switch self {
        case .byHand: return "—"
        case .whenConnected: return "When connected"
        case let .hourly(m): return String(format: "Hourly at :%02d", m)
        case .daily: return words.replacingOccurrences(of: "Once a day", with: "Daily")
        case .weekly: return words.replacingOccurrences(of: "Once a week on ", with: "Weekly, ")
        }
    }
}
