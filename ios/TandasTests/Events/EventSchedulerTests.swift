import Testing
import Foundation
@testable import Tandas

@Suite("EventScheduler")
struct EventSchedulerTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Mexico_City")!
        return c
    }

    @Test("weekly stride is 7 days")
    func weeklyStride() {
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 20, minute: 0))!
        let next = EventScheduler.nextDate(after: anchor, type: .weekly, config: .empty, in: calendar)!
        #expect(calendar.dateComponents([.day], from: anchor, to: next).day == 7)
    }

    @Test("biweekly stride is 14 days")
    func biweeklyStride() {
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 5, day: 5))!
        let next = EventScheduler.nextDate(after: anchor, type: .biweekly, config: .empty, in: calendar)!
        #expect(calendar.dateComponents([.day], from: anchor, to: next).day == 14)
    }

    @Test("monthly Jan 31 → Feb 28 (clamped)")
    func monthlyClampToShortMonth() {
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 20, minute: 0))!
        let config = FrequencyConfig(dayOfMonth: 31, hour: 20, minute: 0)
        let next = EventScheduler.nextDate(after: anchor, type: .monthly, config: config, in: calendar)!
        let comps = calendar.dateComponents([.month, .day], from: next)
        #expect(comps.month == 2)
        // Feb 2026 has 28 days. Should clamp to 28.
        #expect(comps.day == 28)
    }

    @Test("monthly with no day_of_month uses calendar +1mo")
    func monthlyWithoutDayConfig() {
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 5, day: 15))!
        let next = EventScheduler.nextDate(after: anchor, type: .monthly, config: .empty, in: calendar)!
        let comps = calendar.dateComponents([.month, .day], from: next)
        #expect(comps.month == 6)
        #expect(comps.day == 15)
    }

    @Test("unscheduled returns nil")
    func unscheduledIsNil() {
        let anchor = Date.now
        #expect(EventScheduler.nextDate(after: anchor, type: .unscheduled, config: .empty, in: calendar) == nil)
    }

    @Test("nextDates(count: 4, weekly) returns 4 sequential weeks")
    func nextDatesWeekly() {
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 5, day: 5))!
        let dates = EventScheduler.nextDates(from: anchor, count: 4, type: .weekly, config: .empty, in: calendar)
        #expect(dates.count == 4)
        for i in 1..<dates.count {
            let delta = calendar.dateComponents([.day], from: dates[i-1], to: dates[i]).day
            #expect(delta == 7)
        }
    }

    @Test("count = 0 returns empty")
    func zeroCount() {
        let dates = EventScheduler.nextDates(from: .now, count: 0, type: .weekly, config: .empty)
        #expect(dates.isEmpty)
    }
}
