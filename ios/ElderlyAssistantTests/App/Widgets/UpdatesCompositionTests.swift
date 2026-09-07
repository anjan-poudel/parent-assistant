import XCTest
@testable import ElderlyAssistant

/// Composition tests for the Updates leaf (home-redesign v3, 2026-09-08)
/// — the pushed leaf (bell in the top bar) whose three always-headed
/// sections — Notifications, Today, Activity — replace both the Home
/// Today card and the notifications drawer sheet. All composition lives
/// in `UpdatesComposer`, pure with respect to the `UpdatesDataProviding`
/// slice (registry + coordinator data + conversation window), so it is
/// testable without an AppCoordinator. The Today-section logic moved
/// here UNCHANGED from the removed Today card (`TodayCardSource`), which
/// is why the next-activity tests read as they do.
@MainActor
final class UpdatesCompositionTests: XCTestCase {

    // MARK: - Next-activity selection (TodayCardSource.nextActivity, moved
    // unchanged into UpdatesComposer)

    func testNextActivityPicksEarliestFutureTodayFromUnsortedInput() {
        let now = today(6, 0)
        let expected = ScheduledReminder.fixture(hour: 7, minute: 5)
        let reminders = [
            ScheduledReminder.fixture(hour: 20, minute: 0),
            ScheduledReminder.fixture(hour: 9, minute: 30),
            expected,
            ScheduledReminder.fixture(hour: 5, minute: 0)   // already past
        ].shuffled()
        XCTAssertEqual(UpdatesComposer.nextActivity(now: now, reminders: reminders)?
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
        XCTAssertNil(UpdatesComposer.nextActivity(now: now, reminders: reminders),
                     "the next line is about TODAY — past and other days belong to the schedule leaf, not the glance")
    }

    func testNextActivityNilWhenNothingLeftToday() {
        let now = today(6, 0)
        XCTAssertNil(UpdatesComposer.nextActivity(now: now, reminders: []))
        XCTAssertNil(UpdatesComposer.nextActivity(
            now: now,
            reminders: [ScheduledReminder.fixture(hour: 5, minute: 0)]))
    }

    // MARK: - Next-activity text (the "Next: … at …" line)

    func testActivityTextFormatsNameAndTimeForTheLocale() {
        let at = today(7, 5)
        XCTAssertEqual(UpdatesComposer.activityText(name: "Aspirin", at: at,
                                                    locale: Locale(identifier: "en"))
                           .replacingOccurrences(of: "\u{202F}", with: " "),
                       "Next: Aspirin at 7:05 AM")
        let ne = UpdatesComposer.activityText(name: "Aspirin", at: at,
                                              locale: Locale(identifier: "ne-NP"))
        XCTAssertTrue(ne.hasPrefix("अर्को:"),
                      "the line speaks Nepali in the Nepali locale, got: \(ne)")
    }

    // MARK: - Today section rows (the old Today-card content)

    func testTodayRowsDateRowPassesCalendarLineThroughWhenPresent() {
        let stub = StubHomeWidgetDataSource()
        stub.activeLocale = Locale(identifier: "en")
        stub.homeCalendarLine = "Sunday, September 6, 2026"
        stub.pendingReminders = [.fixture(hour: 7, minute: 5)]

        let rows = UpdatesComposer.todayRows(now: today(6, 0), data: stub)
        XCTAssertEqual(rows.count, 2, "date row + next row while something is ahead")
        let dateRow = rows[0]
        XCTAssertEqual(dateRow.id, "today.date")
        XCTAssertEqual(dateRow.icon, "calendar")
        XCTAssertEqual(dateRow.destination?.id, "calendar",
                       "the date line stays the calendar leaf's entry point")
        XCTAssertEqual(dateRow.text, "Sunday, September 6, 2026")
        XCTAssertNil(dateRow.secondaryText)
    }

    func testTodayRowsDateRowFallsBackToTodayShortDateUntilRefreshLands() {
        // homeCalendarLine is nil only between launch and the one-shot
        // offline refresh — the fallback keeps the row honest (never a
        // mock date). Independent oracle: DateFormatter.
        let stub = StubHomeWidgetDataSource()
        stub.activeLocale = Locale(identifier: "en")
        stub.pendingReminders = [.fixture(hour: 7, minute: 5)]

        let rows = UpdatesComposer.todayRows(now: Date(), data: stub)
        let oracle = DateFormatter()
        oracle.locale = Locale(identifier: "en")
        oracle.dateStyle = .medium
        oracle.timeStyle = .none
        XCTAssertEqual(rows[0].text, oracle.string(from: Date()))
        XCTAssertFalse(rows[0].text.isEmpty)
    }

    func testTodayRowsNextRowWhenOneIsAhead() {
        let stub = StubHomeWidgetDataSource()
        stub.activeLocale = Locale(identifier: "en")
        stub.homeCalendarLine = "Sunday, September 6, 2026"
        let dose = ScheduledReminder.fixture(hour: 7, minute: 5)
        stub.medicationNames[dose.medicationEntryId] = "Aspirin"
        stub.pendingReminders = [dose]

        let rows = UpdatesComposer.todayRows(now: today(6, 0), data: stub)
        let nextRow = rows[1]
        XCTAssertEqual(nextRow.id, "today.next")
        XCTAssertEqual(nextRow.icon, "clock.fill")
        XCTAssertEqual(nextRow.destination?.id, "reminders",
                       "the next-activity row pushes the day's schedule")
        XCTAssertEqual(nextRow.text
            .replacingOccurrences(of: "\u{202F}", with: " "),
            "Next: Aspirin at 7:05 AM")
        XCTAssertNil(nextRow.secondaryText)
    }

    func testTodayRowsOmitNextRowWhenNothingIsLeftToday() {
        let stub = StubHomeWidgetDataSource()
        stub.activeLocale = Locale(identifier: "en")
        stub.pendingReminders = [.fixture(hour: 5, minute: 0)]  // past today

        let rows = UpdatesComposer.todayRows(now: today(6, 0), data: stub)
        XCTAssertEqual(rows.count, 1, "the date row always exists; no lying 'next' row")
        XCTAssertEqual(rows[0].id, "today.date")
    }

    // MARK: - Notifications section rows (the widget-registry contract)

    func testNotificationRowsMirrorRegistryRowsVerbatim() {
        let briefing = HomeNotificationRow(widgetID: "todayBriefing", icon: "sunrise.fill",
                                           tint: .reminders,
                                           text: "Today's briefing: …", destination: .briefing)
        let meds = HomeNotificationRow(widgetID: "medsStatus", icon: "pills.fill",
                                       tint: .meds,
                                       text: "2 of 3 doses taken today", destination: .meds)
        let registry = HomeWidgetRegistry(widgets: [
            FakePanelWidget(id: "medsStatus", priority: 20, row: meds),
            FakePanelWidget(id: "todayBriefing", priority: 10, row: briefing)
        ])
        let stub = StubHomeWidgetDataSource()

        let rows = UpdatesComposer.notificationRows(registry: registry, data: stub)
        XCTAssertEqual(rows.map(\.id), ["todayBriefing", "medsStatus"],
                       "registry rows keep their priority order")
        let first = rows[0]
        XCTAssertEqual(first.icon, "sunrise.fill")
        XCTAssertEqual(first.text, "Today's briefing: …")
        XCTAssertEqual(first.destination?.id, "briefing",
                       "the drawer-row destination contract is unchanged — the row pushes the briefing leaf")
        XCTAssertNil(first.secondaryText,
                     "notification rows are single-line; no time bucket")
    }

    func testSectionsAlwaysIncludeNotificationsWithHonestEmptyLine() {
        // Empty registry (no active panels): the section must still
        // EXIST with its header — silence is said honestly, never by
        // vanishing.
        let registry = HomeWidgetRegistry(widgets: [])
        let stub = StubHomeWidgetDataSource()

        let sections = UpdatesComposer.sections(registry: registry,
                                                data: stub,
                                                now: today(6, 0))
        let notifications = sections.first { $0.id == "notifications" }
        XCTAssertNotNil(notifications)
        XCTAssertEqual(notifications?.titleKey, "notifications.title")
        XCTAssertTrue(notifications?.rows.isEmpty == true)
        XCTAssertEqual(notifications?.emptyTextKey, "notifications.empty")
    }

    // MARK: - Activity section rows (the conversation window, read-only)

    func testActivityRowsNewestFirstWithRoleBadges() {
        let stub = StubHomeWidgetDataSource()
        stub.activeLocale = Locale(identifier: "en")
        stub.conversationHistory = [
            ChatHistoryStore.Exchange(role: .user, text: "Call Ramesh",
                                      timestamp: today(9, 0)),
            ChatHistoryStore.Exchange(role: .assistant, text: "Calling Ramesh now.",
                                      timestamp: today(9, 5))
        ]

        let rows = UpdatesComposer.activityRows(history: stub.conversationHistory,
                                                now: today(10, 0),
                                                locale: stub.activeLocale)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id, "activity.\(stub.conversationHistory[1].id.uuidString)",
                       "newest exchange first — the log reads latest-on-top")
        XCTAssertEqual(rows[0].icon, "waveform")
        XCTAssertEqual(rows[0].text, "Calling Ramesh now.",
                       "log text is never truncated")
        XCTAssertEqual(rows[1].icon, "person.fill")
        XCTAssertEqual(rows[1].text, "Call Ramesh")
    }

    func testActivityRowsAreReadOnlyAndCarryTimeBucketSecondary() {
        let stub = StubHomeWidgetDataSource()
        stub.activeLocale = Locale(identifier: "en")
        let now = today(10, 0)
        let recent = ChatHistoryStore.Exchange(role: .user, text: "My pills",
                                               timestamp: now.addingTimeInterval(-30))
        stub.conversationHistory = [recent]

        let rows = UpdatesComposer.activityRows(history: stub.conversationHistory,
                                                now: now,
                                                locale: stub.activeLocale)
        XCTAssertNil(rows[0].destination,
                     "activity rows are READ-ONLY — no chevron, no tap-through")
        XCTAssertEqual(rows[0].secondaryText, "Just now",
                       "the time bucket from HistoryTimeFormat rides the secondary line")
    }

    func testActivityRowsEmptyForEmptyWindow() {
        let stub = StubHomeWidgetDataSource()
        let rows = UpdatesComposer.activityRows(history: [],
                                                now: today(6, 0),
                                                locale: stub.activeLocale)
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - Section assembly (order + honesty)

    func testSectionsAssembleInDisplayOrderFromTheSharedSources() {
        let dose = ScheduledReminder.fixture(hour: 7, minute: 5)
        let briefing = HomeNotificationRow(widgetID: "todayBriefing", icon: "sunrise.fill",
                                           tint: .reminders,
                                           text: "Today's briefing: …", destination: .briefing)
        let registry = HomeWidgetRegistry(widgets: [
            FakePanelWidget(id: "todayBriefing", priority: 10, row: briefing)
        ])
        let stub = StubHomeWidgetDataSource()
        stub.activeLocale = Locale(identifier: "en")
        stub.homeCalendarLine = "Sunday, September 6, 2026"
        stub.medicationNames[dose.medicationEntryId] = "Aspirin"
        stub.pendingReminders = [dose]
        stub.conversationHistory = [
            ChatHistoryStore.Exchange(role: .user, text: "Remind me at 7",
                                      timestamp: today(8, 0))
        ]

        let sections = UpdatesComposer.sections(registry: registry, data: stub,
                                                now: today(6, 0))
        XCTAssertEqual(sections.map(\.id), ["notifications", "today", "activity"])

        let notifications = sections[0]
        XCTAssertEqual(notifications.rows.count, 1)
        XCTAssertEqual(notifications.rows[0].id, "todayBriefing")
        XCTAssertEqual(notifications.emptyTextKey, "notifications.empty")

        let today = sections[1]
        XCTAssertEqual(today.titleKey, "updates.section.today")
        XCTAssertEqual(today.rows.map(\.id), ["today.date", "today.next"])
        XCTAssertNil(today.emptyTextKey,
                     "the Today section can never be empty — the date row always exists, so it carries no empty line")

        let activity = sections[2]
        XCTAssertEqual(activity.titleKey, "updates.section.activity")
        XCTAssertEqual(activity.rows.map(\.id),
                       ["activity.\(stub.conversationHistory[0].id.uuidString)"])
        XCTAssertEqual(activity.emptyTextKey, "updates.activity.empty")
    }

    func testEmptySectionsStayPresentWithHonestEmptyLines() {
        // Nothing active, nothing scheduled, nothing said: ALL THREE
        // sections still render (header + honest empty line) — a leaf
        // that says "no notifications right now" instead of hiding the
        // section teaches where content will appear.
        let registry = HomeWidgetRegistry(widgets: [])
        let stub = StubHomeWidgetDataSource()

        let sections = UpdatesComposer.sections(registry: registry, data: stub,
                                                now: today(6, 0))
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0].titleKey, "notifications.title")
        XCTAssertTrue(sections[0].rows.isEmpty)
        XCTAssertEqual(sections[0].emptyTextKey, "notifications.empty")
        XCTAssertEqual(sections[2].titleKey, "updates.section.activity")
        XCTAssertTrue(sections[2].rows.isEmpty)
        XCTAssertEqual(sections[2].emptyTextKey, "updates.activity.empty")
        XCTAssertEqual(sections[1].rows.map(\.id), ["today.date"],
                       "even a silent day keeps its date row")
    }

    // MARK: - Helper

    private func today(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0,
                              of: Date())!
    }
}
