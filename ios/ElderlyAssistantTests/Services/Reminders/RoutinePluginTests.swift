import XCTest
@testable import ElderlyAssistant

/// Voice-intent tests for the routine plugin (v2 pivot Phase 1). The
/// plugin's `handle` is async but never touches the network — it only
/// parses entities and mutates the injected `RoutineScheduler`, so tests
/// drive it with a real scheduler over in-memory storage, a recording
/// alarm fake, and a pinned clock.
final class RoutinePluginTests: XCTestCase {

    var storage: MockEncryptedLocalStorage!
    var alarm: MockRoutineAlarmScheduler!
    var bus: MockObservabilityBus!
    var scheduler: RoutineScheduler!
    var plugin: RoutinePlugin!
    var fakeNow: Date!

    override func setUp() {
        super.setUp()
        storage = MockEncryptedLocalStorage()
        alarm = MockRoutineAlarmScheduler()
        bus = MockObservabilityBus()
        let store = RoutineStore(storage: storage)
        let pinned = Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 7, hour: 10, minute: 0))
        guard let pinned else {
            XCTFail("could not build pinned date")
            return
        }
        fakeNow = pinned
        scheduler = RoutineScheduler(store: store, alarmScheduler: alarm,
                                     observabilityBus: bus, now: { [weak self] in
                                         self?.fakeNow ?? Date()
                                     })
        plugin = RoutinePlugin(scheduler: scheduler)
    }

    private func makeContext(locale: Locale = Locale(identifier: "ne")) -> PluginExecutionContext {
        PluginExecutionContext(
            locale: locale,
            geminiClient: GeminiClient(
                configStore: GeminiConfigStore(storage: storage),
                observabilityBus: bus
            ),
            observabilityBus: bus
        )
    }

    private func command(_ action: String,
                         entities: [String: String] = [:]) -> PluginCommand {
        PluginCommand(actionName: action, transcript: "",
                      entities: entities, confidence: 0.9)
    }

    // MARK: - Registration shape

    func testIsApplicableForAnyLocale() {
        XCTAssertTrue(plugin.isApplicable(locale: Locale(identifier: "ne")))
        XCTAssertTrue(plugin.isApplicable(locale: Locale(identifier: "en")))
    }

    func testDeclaresSetAndQueryActions() {
        XCTAssertEqual(Set(plugin.intentContribution.actionNames),
                       ["routine.set", "routine.query"])
        XCTAssertFalse(plugin.intentContribution.promptFragment.isEmpty)
    }

    // MARK: - routine.set

    func testSetWalkAtFiveCreatesDailyEntry() async {
        let result = await plugin.handle(
            command("routine.set", entities: [
                "category": "walk", "time": "बेलुका ५ बजे"
            ]),
            context: makeContext()
        )

        guard case .spoken = result else {
            XCTFail("expected a spoken confirmation, got \(result)")
            return
        }
        let entries = scheduler.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.category, .walk)
        XCTAssertEqual(entries.first?.frequency, .daily)
        XCTAssertEqual(entries.first?.scheduleTimes.first?.hour, 17)
        XCTAssertEqual(entries.first?.isEnabled, true)
        // And it actually armed alarms: 17:00 today + 17:00 tomorrow.
        XCTAssertEqual(alarm.scheduled.count, 2)
    }

    func testSetWithoutTimeFailsHonestly() async {
        let result = await plugin.handle(
            command("routine.set", entities: ["category": "walk"]),
            context: makeContext()
        )

        guard case .failed(let apology) = result else {
            XCTFail("expected .failed, got \(result)")
            return
        }
        XCTAssertEqual(apology, L10n.str("plugin.routine.noTime",
                                         locale: Locale(identifier: "ne")))
        XCTAssertTrue(scheduler.entries().isEmpty,
                      "a failed set must not leave a half-created entry")
    }

    func testSetWeeklyWithNepaliWeekday() async {
        let result = await plugin.handle(
            command("routine.set", entities: [
                "category": "gym", "time": "बिहान ९ बजे",
                "frequency": "weekly", "weekday": "सोमबार"
            ]),
            context: makeContext()
        )

        guard case .spoken = result else {
            XCTFail("expected a spoken confirmation, got \(result)")
            return
        }
        let entry = scheduler.entries().first
        XCTAssertEqual(entry?.frequency, .weekly)
        XCTAssertEqual(entry?.weekdays, [2])
        XCTAssertEqual(entry?.scheduleTimes.first?.hour, 9)
    }

    func testSetCustomWithoutTitleFails() async {
        let result = await plugin.handle(
            command("routine.set", entities: [
                "category": "custom", "time": "5 pm"
            ]),
            context: makeContext()
        )
        guard case .failed = result else {
            XCTFail("custom reminders need a title; expected .failed, got \(result)")
            return
        }
    }

    func testSetCustomKeepsVerbatimTitle() async {
        let result = await plugin.handle(
            command("routine.set", entities: [
                "category": "custom", "time": "बिहान ८ बजे",
                "title": "बिरुवालाई पानी दिने"
            ]),
            context: makeContext()
        )

        guard case .spoken = result else {
            XCTFail("expected a spoken confirmation, got \(result)")
            return
        }
        let entry = scheduler.entries().first
        XCTAssertEqual(entry?.category, .custom)
        XCTAssertEqual(entry?.titleOverride, "बिरुवालाई पानी दिने")
    }

    // MARK: - routine.query

    func testQueryWithNoRemindersSaysSo() async {
        let result = await plugin.handle(command("routine.query"),
                                         context: makeContext())
        XCTAssertEqual(result, .spoken(L10n.str("plugin.routine.noneToday",
                                                locale: Locale(identifier: "ne"))))
    }

    func testQueryListsTodaysPendingRoutines() async {
        scheduler.addEntry(RoutineEntry(
            category: .walk,
            scheduleTimes: [DateComponents(hour: 17, minute: 30)],
            isEnabled: true
        ))

        let result = await plugin.handle(command("routine.query"),
                                         context: makeContext())

        guard case .spoken(let text) = result else {
            XCTFail("expected .spoken, got \(result)")
            return
        }
        XCTAssertNotEqual(text, L10n.str("plugin.routine.noneToday",
                                         locale: Locale(identifier: "ne")))
        // Time formatting and catalog resolution vary by host
        // locale/bundle; the query answer must mention the reminder
        // SOMEHOW — localized title or a time rendering.
        let mentionsReminder = ["हिँड्ने", "Walk", "17:30", "5:30", "५:३०"]
            .contains { text.contains($0) }
        XCTAssertTrue(mentionsReminder,
                      "query answer should carry the reminder, got: \(text)")
    }

    func testQueryFoldsInMedicationSummary() async {
        plugin.medicationSummaryProvider = { ["Amlodipine — 8:00 AM"] }

        let result = await plugin.handle(command("routine.query"),
                                         context: makeContext())

        guard case .spoken(let text) = result else {
            XCTFail("expected .spoken, got \(result)")
            return
        }
        XCTAssertTrue(text.contains("Amlodipine"),
                      "the user's ONE reminder list spans both systems, got: \(text)")
    }

    func testUnknownActionFails() async {
        let result = await plugin.handle(command("routine.bogus"),
                                         context: makeContext())
        guard case .failed = result else {
            XCTFail("expected .failed, got \(result)")
            return
        }
    }
}
