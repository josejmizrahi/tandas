import Foundation

/// Computes future occurrences of a recurring event based on a frequency
/// type + config. Pure function, no side effects.
enum EventScheduler {
    /// Returns the next `count` dates after `from` matching the frequency.
    /// `from` is treated as the most recent occurrence (or "now" for first
    /// scheduling). Empty array if frequency is `.unscheduled`.
    static func nextDates(
        from anchor: Date,
        count: Int,
        type: FrequencyType,
        config: FrequencyConfig,
        in calendar: Calendar = .autoupdatingCurrent
    ) -> [Date] {
        guard count > 0, type != .unscheduled else { return [] }
        var results: [Date] = []
        var current = anchor
        for _ in 0..<count {
            guard let next = nextDate(after: current, type: type, config: config, in: calendar) else { break }
            results.append(next)
            current = next
        }
        return results
    }

    /// Compute a single next occurrence after `current`.
    static func nextDate(
        after current: Date,
        type: FrequencyType,
        config: FrequencyConfig,
        in calendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        switch type {
        case .weekly:
            return calendar.date(byAdding: .day, value: 7, to: current)
        case .biweekly:
            return calendar.date(byAdding: .day, value: 14, to: current)
        case .monthly:
            // Add 1 month. `Calendar.date(byAdding:)` clamps to end-of-month
            // automatically (Jan 31 + 1mo → Feb 28/29).
            guard let candidate = calendar.date(byAdding: .month, value: 1, to: current) else { return nil }
            // If config explicitly wants a specific day-of-month, snap.
            if let dom = config.dayOfMonth {
                return snapToDayOfMonth(candidate, dayOfMonth: dom, in: calendar)
            }
            return candidate
        case .unscheduled:
            return nil
        }
    }

    /// Snaps a date to the requested day-of-month, clamped if month is short.
    private static func snapToDayOfMonth(_ date: Date, dayOfMonth: Int, in calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .hour, .minute, .second], from: date)
        guard let year = comps.year, let month = comps.month else { return date }
        let lastDay = lastDayOfMonth(year: year, month: month, calendar: calendar)
        comps.day = min(dayOfMonth, lastDay)
        return calendar.date(from: comps) ?? date
    }

    private static func lastDayOfMonth(year: Int, month: Int, calendar: Calendar) -> Int {
        var comps = DateComponents(year: year, month: month, day: 1)
        guard let firstOfMonth = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: firstOfMonth) else { return 28 }
        return range.upperBound - 1
    }
}
