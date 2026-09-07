import XCTest
@testable import ElderlyAssistant

/// Composition tests for the persistent "Today" card (home-redesign
/// 2026-09-08): the card is fixed Home chrome merging the old calendar
/// strip (BS date/tithi/festival line) with the old next-reminder widget
/// (next activity still ahead today). All composition lives in
/// `TodayCardSource` — pure with respect to the `HomeWidgetDataSource`
/// slice — so it is testable without an AppCoordinator.
@MainActor
final class TodayCardCompositionTests: XCTestCase {

    // MARK: - Next-activity selection

    func testNextActivityPicksEarliestFutureTodayFromUnsortedInput() {
        let now = today(6, 0)
        let expected = ScheduledReminder.fixture(hour: 7, minute: 5)
        let reminders = [
            ScheduledReminder.fixture(hour: 20, minute: 0),
            ScheduledReminder.fixture(hour: 9, minute: 30),
            expected,
            ScheduledReminder.fixture(hour: 5, minute: 0)   // already past
        ].shuffled()
        XCTAssertEqual(TodayCardSource.nextActivity(now: now, reminders: reminders)?
                           .scheduledAt,
                       expected.scheduledAt)
    }

    func testNextActivityIgnoresPastAndOtherDays() {
        let now = today(6, 0)
        let reminders = [
            ScheduledReminder.fixture(hour: 5, minute: 0),          // past today
            ScheduledReminder.fixture(hour: 9, minute: 0, dayOffset: -1),  // yesterday
            ScheduledReminder.fixture(hour: 9, minute: 0, dayOffset: 1)    // tomorrow
        ]
        XCTAssertNil(TodayCardSource.nextActivity(now: now, reminders: reminders),
                     "the card's next line is about TODAY — past and other days belong to the schedule leaf, not the glance")
    }

    func testNextActivityNilWhenNothingLeftToday() {
        let now = today(6, 0)
        XCTAssertNil(TodayCardSource.nextActivity(now: now, reminders: []))
        XCTAssertNil(TodayCardSource.nextActivity(
            now: now,
            reminders: [ScheduledReminder.fixture(hour: 5, minute: 0)]))
    }

    // MARK: - Next-activity text (the "Next: … at …" line)

    func testActivityTextFormatsNameAndTimeForTheLocale() {
        let at = today(7, 5)
        XCTAssertEqual(TodayCardSource.activityText(name: "Aspirin", at: at,
                                                    locale: Locale(identifier: "en"))
                       .replacingOccurrences(of: "\u{202F}", with: " "),
                       "Next: Aspirin at 7:05 AM")
        let ne = TodayCardSource.activityText(name: "Aspirin", at: at,
                                              locale: Locale(identifier: "ne-NP"))
        XCTAssertTrue(ne.hasPrefix("अर्को:"),
                      "the line speaks Nepali in the Nepali locale, got: \(ne)")
    }

    // MARK: - Date line (the old calendar-strip content)

    func testDateLinePassesTheCalendarLineThroughWhenPresent() {
        let stub = StubHomeWidgetDataSource()
        stub.homeCalendarLine = "आइतबार, भदौ २२, २०८३ · तिथि · दशैं"
        stub.pendingReminders = [.fixture(hour: 7, minute: 5)]
        let content = TodayCardSource.content(now: today(6, 0), coordinator: stub)
        XCTAssertEqual(content.dateLine, "आइतबार, भदौ २२, २०८३ · तिथि · दशैं")
        XCTAssertTrue(content.hasUpcomingActivity)
    }

    func testDateLineFallsBackToTodayShortDateUntilRefreshLands() {
        // homeCalendarLine is nil only between launch and the one-shot
        // offline refresh — the fallback keeps the card's height (and the
        // hero below it) from jumping. Independent oracle: DateFormatter.
        let stub = StubHomeWidgetDataSource()
        stub.activeLocale = Locale(identifier: "en")
        stub.pendingReminders = [.fixture(hour: 7, minute: 5)]
        let content = TodayCardSource.content(now: Date(), coordinator: stub)

        let oracle = DateFormatter()
        oracle.locale = Locale(identifier: "en")
        oracle.dateStyle = .medium
        oracle.timeStyle = .none
        XCTAssertEqual(content.dateLine, oracle.string(from: Date()))
        XCTAssertFalse(content.dateLine.isEmpty)
    }

    // MARK: - Card content composition

    func testCardComposesNextActivityWhenOneIsAhead() {
        let stub = StubHomeWidgetDataSource()
        stub.activeLocale = Locale(identifier: "en")
        stub.homeCalendarLine = "Sunday, September 6, 2026"
        let dose = ScheduledReminder.fixture(hour: 7, minute: 5)
        stub.medicationNames[dose.medicationEntryId] = "Aspirin"
        stub.pendingReminders = [dose]

        let content = TodayCardSource.content(now: today(6, 0), coordinator: stub)
        XCTAssertEqual(content.dateLine, "Sunday, September 6, 2026")
        XCTAssertTrue(content.hasUpcomingActivity)
        XCTAssertEqual(content.activityText
            .replacingOccurrences(of: "\u{202F}", with: " "),
            "Next: Aspirin at 7:05 AM")
    }

    func testCardShowsHonestEmptyStateWhenNothingIsLeftToday() {
        let stub = StubHomeWidgetDataSource()
        stub.activeLocale = Locale(identifier: "en")
        stub.pendingReminders = [.fixture(hour: 5, minute: 0)]  // past today
        let content = TodayCardSource.content(now: today(6, 0), coordinator: stub)
        XCTAssertFalse(content.hasUpcomingActivity)
        XCTAssertEqual(content.activityText, "Nothing else on today's schedule.")
    }

    // MARK: - The card is ONE tap target → the day's schedule leaf

    func testCardDestinationIsTheDayScheduleLeaf() {
        // Whole-card NavigationLink — one destination, never split
        // affordances (the old strip split calendar vs reminder taps).
        let stub = StubHomeWidgetDataSource()
        let content = TodayCardSource.content(now: Date(), coordinator: stub)
        XCTAssertEqual(content.destination.id, "reminders")
    }

    // MARK: - Helper

    private func today(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0,
                              of: Date())!
    }
}
