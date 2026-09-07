import XCTest
import SwiftUI
@testable import ElderlyAssistant

/// Registry tests for the rendering v2/v3 contract (home-redesign
/// 2026-09-08): Home widgets are NOTIFICATION PANELS whose output is one
/// row (`HomeNotificationRow`) feeding the bell badge AND the Updates
/// leaf's "Notifications" section (v3 — the pushed leaf that replaced the
/// v2 drawer sheet; the registry contract itself is unchanged by the
/// swap). The old stacked-card render site is gone — the registry's
/// contract is "Notifications-section row source + bell-badge source",
/// plus the fixed-layout guarantee that Home's built-in set contains
/// ONLY notification panels (the calendar strip / next-reminder content
/// now lives in the Updates leaf's "Today" section, composed by
/// `UpdatesComposer` — not a widget, so Home's layout cannot regrow).
@MainActor
final class HomeWidgetRegistryTests: XCTestCase {

    // MARK: - Row ordering + self-hiding

    func testRowsOrderByPriority() {
        let low = FakePanelWidget(id: "low", priority: 30,
                                   row: row(id: "low", text: "low"))
        let high = FakePanelWidget(id: "high", priority: 5,
                                    row: row(id: "high", text: "high"))
        let mid = FakePanelWidget(id: "mid", priority: 15,
                                   row: row(id: "mid", text: "mid"))
        let registry = HomeWidgetRegistry(widgets: [low, high, mid])
        XCTAssertEqual(registry.notificationRows(coordinator: stub).map(\.widgetID),
                       ["high", "mid", "low"])
    }

    func testSelfHidingWidgetsProduceNoRows() {
        let shown = FakePanelWidget(id: "shown", priority: 10,
                                     row: row(id: "shown", text: "shown"))
        let hidden = FakePanelWidget(id: "hidden", priority: 5, row: nil)
        let registry = HomeWidgetRegistry(widgets: [shown, hidden])
        XCTAssertEqual(registry.notificationRows(coordinator: stub).map(\.widgetID),
                       ["shown"],
                       "a widget that returns no row is invisible — no placeholder rows")
        XCTAssertEqual(registry.orderedVisibleWidgets(coordinator: stub).map(\.widgetID),
                       ["shown"])
    }

    // MARK: - Built-in set = the Notifications panels (and nothing that
    // would regrow the Home layout)

    func testBuiltInsAreTheNotificationsPanelsOnly() {
        // The old registration list had FOUR stacked cards (calendar
        // strip, briefing, next reminder, meds status). v2 registered
        // only panels that live in the notifications surface; v3 kept
        // exactly that set — calendar strip + next-reminder content is
        // the Updates leaf's "Today" section (`UpdatesComposer`), fixed
        // chrome, not widgets, so Home's fixed layout cannot regrow.
        let builtIns = HomeWidgetRegistry.builtIns()
        XCTAssertEqual(builtIns.map(\.widgetID), ["todayBriefing", "medsStatus"])
        XCTAssertEqual(Set(builtIns.map(\.widgetID)).count, builtIns.count)
        let priorities = builtIns.map(\.priority)
        XCTAssertEqual(priorities, priorities.sorted(),
                       "builtIns must be registered in priority order — the registry's sort is a safety net, not the ordering mechanism")
        XCTAssertTrue(builtIns.contains { $0.widgetID == "todayBriefing" },
                      "Today's-briefing panel must be registered among the built-ins")
    }

    // MARK: - Today's briefing panel (briefing persistence task, 2026-09-08)

    func testTodayBriefingWidgetHiddenWhenNoBriefingStoredForToday() {
        let widget = TodayBriefingWidget()
        let stub = StubHomeWidgetDataSource()   // todayBriefing == nil
        XCTAssertNil(widget.makeRow(coordinator: stub),
                     "no stored briefing for the current day → no panel (no-mockups rule)")
    }

    func testTodayBriefingWidgetVisibleWhenBriefingExistsForToday() {
        let widget = TodayBriefingWidget()
        let stub = StubHomeWidgetDataSource()
        stub.activeLocale = Locale(identifier: "en")
        stub.todayBriefing = StoredBriefing(
            dayStart: Date(),
            localeIdentifier: "en-US",
            text: "Good morning\nToday is Sunday, September 6, 2026\n"
                + "Your routines today: Morning walk — 7 am"
        )
        let row = widget.makeRow(coordinator: stub)
        XCTAssertNotNil(row)
        assertRow(row, id: "todayBriefing", icon: "sunrise.fill",
                  destinationID: "briefing")
        XCTAssertEqual(row?.text, "Today’s briefing: Your routines today: Morning walk — 7 am")
    }

    // MARK: - Meds status panel

    func testMedsStatusWidgetHiddenWhenNoDosesScheduledToday() {
        let widget = MedsStatusWidget()
        let stub = StubHomeWidgetDataSource()
        stub.pendingReminders = [.fixture(hour: 9, minute: 0, dayOffset: 1)]  // tomorrow
        XCTAssertNil(widget.makeRow(coordinator: stub))
    }

    func testMedsStatusRowReportsPartialAdherence() {
        let widget = MedsStatusWidget()
        let stub = StubHomeWidgetDataSource()
        stub.activeLocale = Locale(identifier: "en")
        stub.pendingReminders = [
            .fixture(hour: 7, minute: 0, acknowledged: true),
            .fixture(hour: 20, minute: 0, acknowledged: false)
        ]
        let row = widget.makeRow(coordinator: stub)
        assertRow(row, id: "medsStatus", icon: "pills.fill", destinationID: "meds")
        XCTAssertEqual(row?.text, "१ of २ doses taken today",
                       "adherence digits stay Devanagari in every locale — the pre-existing widget contract")
    }

    func testMedsStatusRowReportsFullAdherenceWithDoneIcon() {
        let widget = MedsStatusWidget()
        let stub = StubHomeWidgetDataSource()
        stub.pendingReminders = [
            .fixture(hour: 7, minute: 0, acknowledged: true),
            .fixture(hour: 20, minute: 0, acknowledged: true)
        ]
        let row = widget.makeRow(coordinator: stub)
        assertRow(row, id: "medsStatus", icon: "checkmark.circle.fill",
                  destinationID: "meds")
    }

    // MARK: - Notifications-section order for the built-in set

    func testBriefingRowSitsAboveMedsStatus() {
        let registry = HomeWidgetRegistry()
        let stub = StubHomeWidgetDataSource()
        stub.todayBriefing = StoredBriefing(
            dayStart: Date(),
            localeIdentifier: "en-US",
            text: "Good morning\nToday is Monday\nYour routines today: Morning walk — 7 am"
        )
        stub.pendingReminders = [.fixture(hour: 8, minute: 0)]
        let ids = registry.notificationRows(coordinator: stub).map(\.widgetID)
        XCTAssertLessThan(ids.firstIndex(of: "todayBriefing")!,
                          ids.firstIndex(of: "medsStatus")!)
    }

    // MARK: - Bell badge derivation + leaf scale consistency
    //
    // The Updates leaf's Notifications section must look identical and
    // stay usable with 1 item or 10+: every item is the same
    // `HomeNotificationRow` model rendered by the same row component
    // (`UpdatesRowButton`) (view-level identity is not unit-assertable —
    // the section is a single `ForEach` over exactly these rows). What IS
    // locked here is the model contract: the badge count is the row count
    // (bell and leaf can never disagree), and a row's VALUE is
    // bit-identical whether its panel sits alone or among ten — no row
    // changes because its neighbors do.

    func testBadgeCountIsZeroWhenNothingIsActive() {
        let registry = HomeWidgetRegistry()   // briefing + meds panels
        XCTAssertEqual(registry.activeNotificationCount(coordinator: stub), 0)
        XCTAssertTrue(registry.notificationRows(coordinator: stub).isEmpty)
    }

    func testBadgeCountMatchesDrawerRowCount() {
        let stub = StubHomeWidgetDataSource()
        stub.todayBriefing = StoredBriefing(dayStart: Date(), localeIdentifier: "en-US",
                                            text: "Good morning\nToday is Monday\nWalk — 7 am")
        stub.pendingReminders = [.fixture(hour: 8, minute: 0)]
        let registry = HomeWidgetRegistry()
        let rows = registry.notificationRows(coordinator: stub)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(registry.activeNotificationCount(coordinator: stub), rows.count)
    }

    func testSingleActivePanelStillYieldsOneRowOneBadge() {
        let stub = StubHomeWidgetDataSource()
        stub.pendingReminders = [.fixture(hour: 8, minute: 0)]
        let registry = HomeWidgetRegistry()
        XCTAssertEqual(registry.activeNotificationCount(coordinator: stub), 1)
        XCTAssertEqual(registry.notificationRows(coordinator: stub).map(\.widgetID),
                       ["medsStatus"])
    }

    func testRowValuesAreStableRegardlessOfPanelCount() {
        // The same panel row, composed alone and composed among 10
        // neighbors, must be value-identical.
        let solo = HomeWidgetRegistry(widgets: [FakePanelWidget(
            id: "panel", priority: 10, row: row(id: "panel", text: "Alone"))])
        let crowded = HomeWidgetRegistry(widgets: [
            FakePanelWidget(id: "panel", priority: 10,
                             row: row(id: "panel", text: "Alone")),
            FakePanelWidget(id: "p2", priority: 20, row: row(id: "p2", text: "2")),
            FakePanelWidget(id: "p3", priority: 30, row: row(id: "p3", text: "3")),
            FakePanelWidget(id: "p4", priority: 40, row: row(id: "p4", text: "4")),
            FakePanelWidget(id: "p5", priority: 50, row: row(id: "p5", text: "5")),
            FakePanelWidget(id: "p6", priority: 60, row: row(id: "p6", text: "6")),
            FakePanelWidget(id: "p7", priority: 70, row: row(id: "p7", text: "7")),
            FakePanelWidget(id: "p8", priority: 80, row: row(id: "p8", text: "8")),
            FakePanelWidget(id: "p9", priority: 90, row: row(id: "p9", text: "9")),
            FakePanelWidget(id: "p10", priority: 100, row: row(id: "p10", text: "10"))
        ])
        let soloRows = solo.notificationRows(coordinator: stub)
        let crowdedRows = crowded.notificationRows(coordinator: stub)
        XCTAssertEqual(crowdedRows.count, 10)
        assertRowsMatch(soloRows[0], crowdedRows[0])
        XCTAssertEqual(crowdedRows.map(\.widgetID),
                       ["panel", "p2", "p3", "p4", "p5", "p6", "p7", "p8", "p9", "p10"])
    }

    // MARK: - Doubles

    private let stub = StubHomeWidgetDataSource()

    private func row(id: String, text: String) -> HomeNotificationRow {
        HomeNotificationRow(widgetID: id, icon: "bell.fill", tint: .reminders,
                            text: text, destination: .meds)
    }

    private func assertRowsMatch(_ a: HomeNotificationRow, _ b: HomeNotificationRow,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.widgetID, b.widgetID, file: file, line: line)
        XCTAssertEqual(a.icon, b.icon, file: file, line: line)
        XCTAssertEqual(a.text, b.text, file: file, line: line)
        XCTAssertEqual(a.destination.id, b.destination.id, file: file, line: line)
    }

    private func assertRow(_ row: HomeNotificationRow?, id: String, icon: String,
                           destinationID: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(row, file: file, line: line)
        XCTAssertEqual(row?.widgetID, id, file: file, line: line)
        XCTAssertEqual(row?.icon, icon, file: file, line: line)
        XCTAssertEqual(row?.destination.id, destinationID, file: file, line: line)
    }
}
