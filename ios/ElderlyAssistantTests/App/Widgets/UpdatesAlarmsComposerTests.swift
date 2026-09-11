import XCTest
@testable import ElderlyAssistant

/// Composition tests for the Updates leaf's ALARMS section (updates-alarms
/// task, 2026-09-10) — the glance of enabled alarms + live timer
/// countdowns that sits between Notifications and Today. All composition
/// lives in `UpdatesAlarmsComposer`, pure with respect to its inputs
/// ([Alarm] + [TimerItem] + now), so it is fully testable without an
/// AppCoordinator. The section is DELIBERATELY absent while nothing is
/// armed — no header, no empty line (silence without noise for seniors).
@MainActor
final class UpdatesAlarmsComposerTests: XCTestCase {

    private let en = Locale(identifier: "en")
    private let ne = Locale(identifier: "ne-NP")

    // MARK: - Section visibility (hidden when nothing armed)

    func testSectionHiddenWhenNothingEnabledOrActive() {
        let now = date(hour: 12, minute: 0)
        XCTAssertNil(UpdatesAlarmsComposer.section(alarms: [], timers: [],
                                                   now: now, locale: en))
        XCTAssertNil(UpdatesAlarmsComposer.section(
            alarms: [alarm(hour: 6, minute: 0, isEnabled: false)],
            timers: [], now: now, locale: en),
            "a disabled alarm is not armed — the section stays hidden")
    }

    func testSectionAnatomyWhenSomethingIsArmed() {
        let now = date(hour: 12, minute: 0)
        let section = UpdatesAlarmsComposer.section(
            alarms: [alarm(hour: 6, minute: 0)],
            timers: [TimerItem(endsAt: now.addingTimeInterval(180))],
            now: now, locale: en)
        XCTAssertNotNil(section)
        XCTAssertEqual(section?.id, "alarms")
        XCTAssertEqual(section?.titleKey, "settings.alarms.title",
                       "the header reuses the Settings row's title — the section and the leaf it pushes share one name")
        XCTAssertNil(section?.emptyTextKey,
                     "the section never renders empty — it exists only while armed")
        XCTAssertEqual(section?.rows.count, 2, "enabled alarm first, then the timer")
    }

    // MARK: - Alarm rows

    func testAlarmRowsSortedByNextOccurrence() {
        // Noon: 11 pm is TONIGHT (closest); 5:30 and 6 am are tomorrow.
        let now = date(hour: 12, minute: 0)
        let alarms = [
            alarm(hour: 6, minute: 0),
            alarm(hour: 23, minute: 0),
            alarm(hour: 5, minute: 30)
        ].shuffled()
        let rows = UpdatesAlarmsComposer.alarmRows(alarms: alarms, now: now, locale: en)
        XCTAssertEqual(rows.map(\.text), ["11 pm", "5:30 am", "6 am"])
    }

    func testAlarmRowsIgnoreDisabledAlarms() {
        let now = date(hour: 12, minute: 0)
        let rows = UpdatesAlarmsComposer.alarmRows(
            alarms: [alarm(hour: 6, minute: 0, isEnabled: false),
                     alarm(hour: 9, minute: 0)],
            now: now, locale: en)
        XCTAssertEqual(rows.map(\.text), ["9 am"],
                       "disabled alarms are the Settings leaf's business, never glance noise")
    }

    func testAlarmRowTextIsTheSpokenTimeForm() {
        let now = date(hour: 12, minute: 0)
        let enRow = UpdatesAlarmsComposer.alarmRows(
            alarms: [alarm(hour: 6, minute: 0)], now: now, locale: en)[0]
        XCTAssertEqual(enRow.text, "6 am",
                       "the row shows the SPOKEN form — the words the assistant says when the alarm rings")
        let neRow = UpdatesAlarmsComposer.alarmRows(
            alarms: [alarm(hour: 8, minute: 0)], now: now, locale: ne)[0]
        XCTAssertEqual(neRow.text, "बिहान ८ बजे")
    }

    func testAlarmRowCarriesLabelOnSecondaryLine() {
        let now = date(hour: 12, minute: 0)
        let row = UpdatesAlarmsComposer.alarmRows(
            alarms: [alarm(hour: 6, minute: 0, label: "Morning pills")],
            now: now, locale: en)[0]
        XCTAssertEqual(row.secondaryText, "Morning pills")
    }

    func testAlarmRowShowsSnoozedStateWhileSnoozeIsPending() {
        let now = date(hour: 6, minute: 0)
        let row = UpdatesAlarmsComposer.alarmRows(
            alarms: [alarm(hour: 6, minute: 0, snoozedUntil: date(hour: 6, minute: 15))],
            now: now, locale: en)[0]
        XCTAssertEqual(row.secondaryText, "Snoozed until 6:15 am.",
                       "the SAME sentence the router speaks on snooze, with the spoken re-wake time")
    }

    func testAlarmRowCombinesLabelAndSnoozedState() {
        let now = date(hour: 6, minute: 0)
        let row = UpdatesAlarmsComposer.alarmRows(
            alarms: [alarm(hour: 6, minute: 0, label: "Morning pills",
                           snoozedUntil: date(hour: 6, minute: 15))],
            now: now, locale: en)[0]
        XCTAssertEqual(row.secondaryText, "Morning pills · Snoozed until 6:15 am.")
    }

    func testAlarmRowHidesStaleSnooze() {
        // The snooze one-shot has fired; the marker is stale — showing
        // "Snoozed until 6:15 am" at 8 am would be a lie.
        let now = date(hour: 8, minute: 0)
        let row = UpdatesAlarmsComposer.alarmRows(
            alarms: [alarm(hour: 6, minute: 0, label: "Morning pills",
                           snoozedUntil: date(hour: 6, minute: 15))],
            now: now, locale: en)[0]
        XCTAssertEqual(row.secondaryText, "Morning pills")
    }

    func testAlarmRowPushesTheAlarmsLeaf() {
        let now = date(hour: 12, minute: 0)
        let row = UpdatesAlarmsComposer.alarmRows(
            alarms: [alarm(hour: 6, minute: 0)], now: now, locale: en)[0]
        XCTAssertEqual(row.destination, .alarms,
                       "one tap from the glance to the Settings → Alarms leaf")
        XCTAssertEqual(row.destination?.id, "alarms")
        XCTAssertNil(row.countdownEndsAt, "alarm rows are static — no live countdown")
        XCTAssertEqual(row.icon, "alarm.fill")
        XCTAssertTrue(row.id.hasPrefix("alarm."))
    }

    // MARK: - Timer rows

    func testTimerRowsSortedByRemaining() {
        let now = date(hour: 12, minute: 0)
        let timers = [
            TimerItem(endsAt: now.addingTimeInterval(300)),
            TimerItem(endsAt: now.addingTimeInterval(120)),
            TimerItem(endsAt: now.addingTimeInterval(600))
        ].shuffled()
        let rows = UpdatesAlarmsComposer.timerRows(timers: timers, now: now, locale: en)
        XCTAssertEqual(rows.map(\.text), ["2:00", "5:00", "10:00"],
                       "soonest first — the one about to ring reads on top")
    }

    func testTimerRowCarriesCountdownAndLabel() {
        let now = date(hour: 12, minute: 0)
        let endsAt = now.addingTimeInterval(204)
        let row = UpdatesAlarmsComposer.timerRows(
            timers: [TimerItem(endsAt: endsAt, label: "Tea")], now: now, locale: en)[0]
        XCTAssertEqual(row.text, "3:24",
                       "the composed text is the honest countdown at now (initial state + screen-reader label)")
        XCTAssertEqual(row.countdownEndsAt, endsAt,
                       "the row view ticks the display live from this instant")
        XCTAssertEqual(row.secondaryText, "Tea")
        XCTAssertEqual(row.destination, .alarms)
        XCTAssertEqual(row.icon, "timer")
        XCTAssertTrue(row.id.hasPrefix("timer."))
    }

    // MARK: - Countdown text (mm:ss / h:mm:ss)

    func testCountdownFormattingBoundaries() {
        XCTAssertEqual(UpdatesAlarmsComposer.countdownText(remainingSeconds: 59), "0:59")
        XCTAssertEqual(UpdatesAlarmsComposer.countdownText(remainingSeconds: 60), "1:00")
        XCTAssertEqual(UpdatesAlarmsComposer.countdownText(remainingSeconds: 3599), "59:59")
        XCTAssertEqual(UpdatesAlarmsComposer.countdownText(remainingSeconds: 3600), "1:00:00",
                       "hours collapse into minutes below an hour, h:mm:ss from an hour up")
        XCTAssertEqual(UpdatesAlarmsComposer.countdownText(remainingSeconds: 3661), "1:01:01")
    }

    func testCountdownClampsAtZeroAndRoundsUp() {
        XCTAssertEqual(UpdatesAlarmsComposer.countdownText(remainingSeconds: 0), "0:00")
        XCTAssertEqual(UpdatesAlarmsComposer.countdownText(remainingSeconds: -3), "0:00",
                       "expired countdowns clamp honestly at zero — the service prunes the row")
        XCTAssertEqual(UpdatesAlarmsComposer.countdownText(remainingSeconds: 59.1), "1:00",
                       "rounds UP so the display never shows time that has already passed")
        XCTAssertEqual(UpdatesAlarmsComposer.countdownText(remainingSeconds: 3599.9), "1:00:00")
    }

    func testCountdownUsesDevanagariDigitsInNepali() {
        XCTAssertEqual(UpdatesAlarmsComposer.countdownText(remainingSeconds: 204, locale: ne),
                       "३:२४")
        XCTAssertEqual(UpdatesAlarmsComposer.countdownText(remainingSeconds: 3661, locale: ne),
                       "१:०१:०१")
        XCTAssertEqual(UpdatesAlarmsComposer.countdownText(remainingSeconds: 204, locale: en),
                       "3:24")
    }

    // MARK: - Section assembly in the leaf

    func testSectionsInsertAlarmsBetweenNotificationsAndTodayWhenArmed() {
        let now = date(hour: 12, minute: 0)
        let stub = StubHomeWidgetDataSource()
        stub.activeLocale = Locale(identifier: "en")
        stub.alarms = [alarm(hour: 6, minute: 0)]
        stub.activeTimers = [TimerItem(endsAt: now.addingTimeInterval(180))]
        let registry = HomeWidgetRegistry(widgets: [])

        let sections = UpdatesComposer.sections(registry: registry, data: stub,
                                                now: now)
        XCTAssertEqual(sections.map(\.id), ["notifications", "alarms", "today", "activity"],
                       "the Alarms section sits exactly between Notifications and Today")
        XCTAssertEqual(sections[1].rows.map(\.id),
                       ["alarm.\(stub.alarms[0].id.uuidString)",
                        "timer.\(stub.activeTimers[0].id.uuidString)"],
                       "enabled alarms first, then timers")
    }

    func testSectionsOmitAlarmsWhenNothingArmed() {
        let stub = StubHomeWidgetDataSource()
        let registry = HomeWidgetRegistry(widgets: [])

        let sections = UpdatesComposer.sections(registry: registry, data: stub,
                                                now: date(hour: 12, minute: 0))
        XCTAssertEqual(sections.map(\.id), ["notifications", "today", "activity"],
                       "nothing armed → the Alarms section does not exist at all (no noise)")
    }

    // MARK: - Destination mapping

    func testLeafDestinationAlarmsHasItsOwnID() {
        XCTAssertEqual(LeafDestination.alarms.id, "alarms")
    }

    // MARK: - Helpers

    private func date(hour: Int, minute: Int, second: Int = 0) -> Date {
        Calendar.current.startOfDay(for: Date())
            .addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second))
    }

    private func alarm(hour: Int, minute: Int, label: String? = nil,
                       isEnabled: Bool = true, snoozedUntil: Date? = nil) -> Alarm {
        Alarm(time: date(hour: hour, minute: minute), label: label,
              isEnabled: isEnabled, snoozedUntil: snoozedUntil)
    }
}
