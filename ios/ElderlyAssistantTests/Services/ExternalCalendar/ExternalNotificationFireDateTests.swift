import XCTest
@testable import ElderlyAssistant

/// `ExternalCalendarService.fireDate(for:leadMinutes:now:calendar:)` —
/// when an imported item's in-app notification fires, or nil when it
/// must surface without one. Pure function, pinned clock (the
/// RoutineSchedulerTests pattern).
final class ExternalNotificationFireDateTests: XCTestCase {

    /// Pinned clock instant: 2026-09-07 10:00 local.
    private var now: Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 7, hour: 10, minute: 0))!
    }

    private func date(hour: Int, minute: Int = 0, day: Int = 7) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func item(start: Date, isAllDay: Bool = false,
                      hasOwnAlarm: Bool = false) -> ExternalReminder {
        ExternalReminder(
            id: "id",
            source: .event,
            title: "t",
            notes: nil,
            startDate: start,
            isAllDay: isAllDay,
            hasOwnAlarm: hasOwnAlarm,
            calendarName: "c"
        )
    }

    // MARK: - Timed items

    func testTimedItemFiresLeadMinutesBeforeStart() {
        let fire = ExternalCalendarService.fireDate(
            for: item(start: date(hour: 11)),
            leadMinutes: 5, now: now)
        XCTAssertEqual(fire, date(hour: 10, minute: 55))
    }

    func testZeroLeadFiresAtStart() {
        let fire = ExternalCalendarService.fireDate(
            for: item(start: date(hour: 11)),
            leadMinutes: 0, now: now)
        XCTAssertEqual(fire, date(hour: 11), "lead 0 means a notification at the start itself")
    }

    func testTimedItemWhoseFireMomentPassedGetsNoNotification() {
        // Start 10:03, lead 5 → 09:58, already gone at 10:00.
        let early = ExternalCalendarService.fireDate(
            for: item(start: date(hour: 10, minute: 3)),
            leadMinutes: 5, now: now)
        XCTAssertNil(early)
        // Start exactly now (lead 0) → the moment is not still ahead.
        let atNow = ExternalCalendarService.fireDate(
            for: item(start: now),
            leadMinutes: 0, now: now)
        XCTAssertNil(atNow)
    }

    // MARK: - All-day items

    func testAllDayItemFiresAtEightRegardlessOfLead() {
        // 07:00 now: morning is still ahead. Lead 30 must NOT apply —
        // all-day items announce at 08:00, always.
        let fire = ExternalCalendarService.fireDate(
            for: item(start: date(hour: 0), isAllDay: true),
            leadMinutes: 30,
            now: date(hour: 7))
        XCTAssertEqual(fire, date(hour: 8))
    }

    func testAllDayItemMorningsAlreadyGoneGetsNoNotification() {
        let fire = ExternalCalendarService.fireDate(
            for: item(start: date(hour: 0), isAllDay: true),
            leadMinutes: 5, now: now)   // 10:00 — 08:00 has passed
        XCTAssertNil(fire)
    }

    func testAllDayItemOnPastDayGetsNoNotification() {
        let fire = ExternalCalendarService.fireDate(
            for: item(start: date(hour: 0, day: 6), isAllDay: true),
            leadMinutes: 5, now: now)
        XCTAssertNil(fire)
    }

    // MARK: - Own-alarm exemption

    func testOwnAlarmItemsNeverGetAnInAppNotification() {
        let timed = ExternalCalendarService.fireDate(
            for: item(start: date(hour: 11), hasOwnAlarm: true),
            leadMinutes: 5, now: now)
        XCTAssertNil(timed, "the OS already covers an item with its own alarm")
        let allDay = ExternalCalendarService.fireDate(
            for: item(start: date(hour: 0), isAllDay: true, hasOwnAlarm: true),
            leadMinutes: 5, now: date(hour: 7))
        XCTAssertNil(allDay)
    }
}
