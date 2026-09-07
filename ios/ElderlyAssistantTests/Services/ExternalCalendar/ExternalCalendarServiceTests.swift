import XCTest
@testable import ElderlyAssistant

/// Orchestration tests for `ExternalCalendarService` against fakes: a
/// canned `FakeCalendarScanner` (no EventKit), a recording alarm
/// scheduler, and a scriptable item opener. "Now" is anchored to REAL
/// today (the service's today filters use the wall clock) at a fixed
/// 10:00 — the calendar-day relative math stays deterministic whatever
/// hour the suite runs.
final class ExternalCalendarServiceTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeCalendarScanner: NativeCalendarScanning {
        var eventsGranted: Bool
        var remindersGranted: Bool
        var eventAccessRequests = 0
        var reminderAccessRequests = 0
        var fetchRemindersCalls = 0
        var events: [ScannedEvent] = []
        var reminders: [ScannedReminder] = []
        var fetchEventsShouldThrow = false
        var lastFetchStart: Date?
        var lastFetchEnd: Date?

        init(eventsGranted: Bool = true, remindersGranted: Bool = true) {
            self.eventsGranted = eventsGranted
            self.remindersGranted = remindersGranted
        }

        var eventAuthorizationGranted: Bool { eventsGranted }
        var reminderAuthorizationGranted: Bool { remindersGranted }

        func requestEventAccess() async -> Bool {
            eventAccessRequests += 1
            return eventsGranted
        }

        func requestReminderAccess() async -> Bool {
            reminderAccessRequests += 1
            return remindersGranted
        }

        func fetchEvents(from start: Date, to end: Date) async throws -> [ScannedEvent] {
            lastFetchStart = start
            lastFetchEnd = end
            if fetchEventsShouldThrow { throw ScannerFault.fetchFailed }
            return events
        }

        func fetchDueReminders() async throws -> [ScannedReminder] {
            fetchRemindersCalls += 1
            return reminders
        }

        enum ScannerFault: Error { case fetchFailed }
    }

    private final class RecordingExternalAlarmScheduler: ExternalAlarmScheduling {
        struct ScheduledCall: Equatable {
            let identifier: String
            let title: String
            let body: String
            let fireDate: Date
        }

        private(set) var scheduled: [ScheduledCall] = []
        private(set) var cancelled: [String] = []

        func scheduleExternalReminder(identifier: String, title: String,
                                      body: String, at fireDate: Date) {
            scheduled.append(ScheduledCall(identifier: identifier, title: title,
                                           body: body, fireDate: fireDate))
        }

        func cancelExternalReminders(identifiers: [String]) {
            cancelled.append(contentsOf: identifiers)
            scheduled.removeAll { identifiers.contains($0.identifier) }
        }
    }

    private final class MockExternalItemOpener: ExternalItemOpening {
        var canOpenResult = true
        private(set) var canOpenCalls: [URL] = []
        private(set) var opened: [URL] = []

        func canOpen(_ url: URL) -> Bool {
            canOpenCalls.append(url)
            return canOpenResult
        }

        func open(_ url: URL) { opened.append(url) }
    }

    // MARK: - Harness

    var bus: MockObservabilityBus!
    var fakeNow: Date!
    private var submitCount = 0

    /// Start of REAL today — the anchor for every item date below.
    private var startOfToday: Date { Calendar.current.startOfDay(for: Date()) }

    private func time(_ hour: Int, minute: Int = 0, dayOffset: Int = 0) -> Date {
        let base = dayOffset == 0
            ? startOfToday
            : Calendar.current.date(byAdding: .day, value: dayOffset, to: startOfToday)!
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
    }

    private func scannedEvent(id: String, at date: Date, isAllDay: Bool = false,
                              declined: Bool = false, notes: String? = nil,
                              hasAlarms: Bool = false) -> ScannedEvent {
        ScannedEvent(nativeIdentifier: id, title: "Event \(id)", notes: notes,
                     startDate: date, isAllDay: isAllDay, isDeclined: declined,
                     hasAlarms: hasAlarms, calendarName: "Family")
    }

    private func scannedReminder(id: String, at date: Date?, isAllDay: Bool = false,
                                 completed: Bool = false) -> ScannedReminder {
        ScannedReminder(nativeIdentifier: id, title: "Reminder \(id)", notes: nil,
                        dueDate: date, isAllDay: isAllDay, isCompleted: completed,
                        hasAlarms: false, calendarName: "Home List")
    }

    private func makeService(scanner: FakeCalendarScanner? = nil)
        -> (service: ExternalCalendarService,
            scanner: FakeCalendarScanner,
            alarm: RecordingExternalAlarmScheduler,
            opener: MockExternalItemOpener) {
        let scanner = scanner ?? FakeCalendarScanner()
        let alarm = RecordingExternalAlarmScheduler()
        let opener = MockExternalItemOpener()
        submitCount = 0
        let service = ExternalCalendarService(
            scanner: scanner,
            alarmScheduler: alarm,
            opener: opener,
            observabilityBus: bus,
            now: { [weak self] in self?.fakeNow ?? Date() },
            submitRefreshRequest: { [weak self] in self?.submitCount += 1 }
        )
        return (service, scanner, alarm, opener)
    }

    override func setUp() {
        super.setUp()
        bus = MockObservabilityBus()
        fakeNow = time(10)
        // The service persists enablement/status/lead in UserDefaults and
        // restores them in init — clean slate per test.
        UserDefaults.standard.removeObject(forKey: "externalCalendar.enabled")
        UserDefaults.standard.removeObject(forKey: "externalCalendar.status")
        UserDefaults.standard.removeObject(forKey: "externalCalendar.leadMinutes")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "externalCalendar.enabled")
        UserDefaults.standard.removeObject(forKey: "externalCalendar.status")
        UserDefaults.standard.removeObject(forKey: "externalCalendar.leadMinutes")
        super.tearDown()
    }

    /// A scanner whose store holds one importable timed event (11:00),
    /// one importable all-day event (today), one declined + one
    /// mirror-tagged + one already-started event (all dropped), and one
    /// due reminder (13:00) beside completed/dateless/past ones.
    private func populate(_ scanner: FakeCalendarScanner) {
        scanner.events = [
            scannedEvent(id: "timed", at: time(11)),
            scannedEvent(id: "allday", at: time(0), isAllDay: true),
            scannedEvent(id: "declined", at: time(12), declined: true),
            scannedEvent(id: "mirror", at: time(12, minute: 30),
                         notes: CalendarSyncService.mirrorTag),
            scannedEvent(id: "started", at: time(9))
        ]
        scanner.reminders = [
            scannedReminder(id: "due", at: time(13)),
            scannedReminder(id: "done", at: time(14), completed: true),
            scannedReminder(id: "no-date", at: nil)   // dateless = a to-do, not a timed reminder
        ]
    }

    // MARK: - Enable / statuses

    func testEnableAsksBothStoresAndPublishesTheScan() async {
        let scanner = FakeCalendarScanner()
        populate(scanner)
        let (service, scannerRef, alarm, _) = makeService(scanner: scanner)

        await service.enable()

        XCTAssertEqual(scannerRef.eventAccessRequests, 1)
        XCTAssertEqual(scannerRef.reminderAccessRequests, 1)
        XCTAssertEqual(service.isEnabled, true)
        XCTAssertEqual(service.status, .enabled)
        // Mirror-tagged / declined / started / completed / dateless all
        // dropped at mapping — timed 11:00 + all-day + due 13:00 remain.
        XCTAssertEqual(service.reminders.count, 3)
        XCTAssertEqual(service.reminders.map(\.source).sorted { $0.rawValue < $1.rawValue },
                       [.event, .event, .reminder])
        // Horizon fetch is now…+7 days.
        XCTAssertEqual(scannerRef.lastFetchStart, fakeNow)
        XCTAssertEqual(scannerRef.lastFetchEnd,
                       fakeNow.addingTimeInterval(TimeInterval(7 * 86_400)))
        XCTAssertEqual(scannerRef.fetchRemindersCalls, 1)
        // Armed: the two timed-future items (all-day 08:00 has passed at
        // the 10:00 clock).
        XCTAssertEqual(alarm.scheduled.count, 2)
        XCTAssertEqual(alarm.scheduled.map(\.body).sorted(),
                       ["Event timed", "Reminder due"].sorted())
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "external_enabled" })
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "external_scan" })
        XCTAssertGreaterThanOrEqual(submitCount, 1,
                                    "every scan keeps the hourly background refresh alive")
    }

    func testEnableWithSingleStoreGrantIsPartialAndSkipsTheOther() async {
        let scanner = FakeCalendarScanner(eventsGranted: true, remindersGranted: false)
        populate(scanner)
        let (service, scannerRef, alarm, _) = makeService(scanner: scanner)

        await service.enable()

        XCTAssertEqual(service.status, .partial,
                       "one granted store must read as partial, not enabled")
        XCTAssertEqual(scannerRef.fetchRemindersCalls, 0,
                       "the denied store is not fetched at all")
        XCTAssertEqual(service.reminders.map(\.source), [.event, .event])
        XCTAssertEqual(alarm.scheduled.count, 1, "only the 11:00 timed event arms")
    }

    func testEnableFullyDeniedFetchesNothingAndSaysDenied() async {
        let scanner = FakeCalendarScanner(eventsGranted: false, remindersGranted: false)
        populate(scanner)
        let (service, scannerRef, alarm, _) = makeService(scanner: scanner)

        await service.enable()

        XCTAssertEqual(service.status, .denied)
        XCTAssertTrue(service.reminders.isEmpty)
        XCTAssertTrue(alarm.scheduled.isEmpty)
        XCTAssertNil(scannerRef.lastFetchStart, "no fetch without permission")
        XCTAssertEqual(scannerRef.fetchRemindersCalls, 0)
    }

    func testFetchFailurePersistsErrorStatusHonestly() async {
        let scanner = FakeCalendarScanner(eventsGranted: true, remindersGranted: false)
        populate(scanner)
        scanner.fetchEventsShouldThrow = true
        let (service, _, _, _) = makeService(scanner: scanner)

        await service.enable()

        XCTAssertEqual(service.status, .error,
                       "a granted store whose fetch failed is .error, not a silent empty list")
        XCTAssertTrue(service.reminders.isEmpty)
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "external_scan" && $0.outcome == "failure"
        })
    }

    // MARK: - Disable / scoped cancels

    func testDisableCancelsOnlyIdentifiersTheServiceArmed() async {
        let scanner = FakeCalendarScanner()
        populate(scanner)
        let (service, _, alarm, _) = makeService(scanner: scanner)
        await service.enable()
        let armedIds = Set(alarm.scheduled.map(\.identifier))
        XCTAssertEqual(armedIds.count, 2)

        await service.disable()

        XCTAssertEqual(Set(alarm.cancelled), armedIds,
                       "disable cancels EXACTLY the identifiers the last pass armed")
        XCTAssertTrue(alarm.cancelled.allSatisfy {
            $0.hasPrefix(ExternalNotificationIdentity.prefix)
        }, "scoped cancels never leave the external_ namespace")
        XCTAssertTrue(alarm.scheduled.isEmpty)
        XCTAssertTrue(service.reminders.isEmpty)
        XCTAssertEqual(service.status, .notRequested)
        XCTAssertEqual(service.isEnabled, false)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "external_disabled" })
    }

    // MARK: - Rescan idempotency

    func testRescanCancelsPreviousPassThenRearmsSameIdentifiers() async {
        let scanner = FakeCalendarScanner()
        populate(scanner)
        let (service, _, alarm, _) = makeService(scanner: scanner)
        await service.enable()
        let firstIds = Set(alarm.scheduled.map(\.identifier))
        let submitAfterEnable = submitCount

        await service.rescan()

        XCTAssertEqual(submitCount, submitAfterEnable + 1)
        XCTAssertEqual(Set(alarm.cancelled), firstIds,
                       "the second pass cancels only its own previous arms")
        XCTAssertEqual(Set(alarm.scheduled.map(\.identifier)), firstIds,
                       "same-identifier re-arms keep the armed set stable")
    }

    func testRescanWhileDisabledIsANoOp() async {
        let (service, scanner, alarm, _) = makeService()

        await service.rescan()
        await service.startIfEnabled()

        XCTAssertEqual(submitCount, 0)
        XCTAssertNil(scanner.lastFetchStart)
        XCTAssertEqual(scanner.fetchRemindersCalls, 0)
        XCTAssertTrue(alarm.scheduled.isEmpty)
        XCTAssertEqual(service.status, .notRequested,
                       "no prompt, no scan, no status churn while the feature is off")
    }

    // MARK: - Lead time

    func testLeadMinutesClampToZeroThroughThirtyAndPersist() {
        let (service, _, _, _) = makeService()
        XCTAssertEqual(service.leadMinutes, ExternalCalendarService.defaultLeadMinutes)

        service.leadMinutes = 45
        XCTAssertEqual(service.leadMinutes, ExternalCalendarService.maxLeadMinutes)
        service.leadMinutes = -3
        XCTAssertEqual(service.leadMinutes, 0)

        // Persisted value is the CLAMPED one, not the raw assignment.
        let restored = ExternalCalendarService(observabilityBus: bus)
        XCTAssertEqual(restored.leadMinutes, 0)
    }

    func testLeadChangeRescansAndReschedulesArmedFires() async {
        let scanner = FakeCalendarScanner()
        populate(scanner)
        let (service, _, alarm, _) = makeService(scanner: scanner)
        await service.enable()
        // 11:00 event armed at 10:55 with the default 5-minute lead.
        let eventArm = alarm.scheduled.first { $0.body == "Event timed" }!
        XCTAssertEqual(eventArm.fireDate, time(10, minute: 55))
        let submitBefore = submitCount

        service.leadMinutes = 15
        // The didSet re-scan is an unstructured Task — give it a turn.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(submitCount, submitBefore + 1)
        let rearrmed = alarm.scheduled.first { $0.body == "Event timed" }
        XCTAssertEqual(rearrmed?.fireDate, time(10, minute: 45),
                       "armed fires follow the new lead immediately")
        XCTAssertTrue(service.leadMinutes == 15)
    }

    func testArmsAtMostFortyEightNearestFires() async {
        let scanner = FakeCalendarScanner(remindersGranted: false)
        // 60 timed events across the next five days (every two hours) —
        // all importable, all future.
        for i in 0..<60 {
            let dayOffset = 1 + i / 12
            let hour = (i % 12) * 2
            scanner.events.append(scannedEvent(id: "bulk-\(i)", at: time(hour, dayOffset: dayOffset)))
        }
        let (service, _, alarm, _) = makeService(scanner: scanner)
        await service.enable()

        XCTAssertEqual(service.reminders.count, 60)
        XCTAssertEqual(alarm.scheduled.count, ExternalCalendarService.maxArmedNotifications)
        // The 48 nearest fires are armed; the 12 farthest are not.
        let mappedIds = service.reminders
            .sorted { $0.startDate < $1.startDate }
            .map { ExternalNotificationIdentity.identifier(for: $0.id) }
        let armedIds = Set(alarm.scheduled.map(\.identifier))
        XCTAssertTrue(Set(mappedIds.prefix(48)).isSubset(of: armedIds))
        XCTAssertTrue(Set(mappedIds.suffix(12)).isDisjoint(with: armedIds),
                      "the 12 farthest fires must not be armed")
    }

    // MARK: - Today lists + spoken lines

    func testTodaysSpokenLinesExcludeGoneMomentsButKeepAllDay() async {
        let scanner = FakeCalendarScanner(remindersGranted: false)
        scanner.events = [
            scannedEvent(id: "gone", at: time(10, minute: 30)),      // 30 min after 10:00 scan
            scannedEvent(id: "ahead", at: time(11)),
            scannedEvent(id: "allday", at: time(0), isAllDay: true)
        ]
        let (service, _, _, _) = makeService(scanner: scanner)
        await service.enable()
        XCTAssertEqual(service.reminders.count, 3)

        // Ask at 10:45 — the 10:30 item's moment has passed.
        fakeNow = time(10, minute: 45)
        let lines = service.todaysSpokenLines(locale: Locale(identifier: "en"))

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "Event allday",
                       "all-day items are spoken as bare titles, relevant all day")
        let timed = lines[1]
        XCTAssertTrue(timed.contains("Event ahead") && timed.contains("—"),
                      "timed items speak as 'title — time', got: \(timed)")
        XCTAssertFalse(lines.contains { $0.contains("Event gone") },
                       "a timed item whose moment passed is not spoken")
    }

    func testTodaysItemsAreTodayOnlySortedOldestFirst() async {
        let scanner = FakeCalendarScanner(remindersGranted: false)
        scanner.events = [
            scannedEvent(id: "tomorrow", at: time(9, dayOffset: 1)),
            scannedEvent(id: "late", at: time(15)),
            scannedEvent(id: "early", at: time(11))
        ]
        let (service, _, _, _) = makeService(scanner: scanner)
        await service.enable()

        let today = service.todaysItems()
        XCTAssertEqual(today.map(\.title), ["Event early", "Event late"],
                       "tomorrow's event is published by the scan but not 'today'")
    }

    // MARK: - Opening (read-only integration)

    func testOpenOpensTheNativeAppPerSourceWhenAvailable() {
        let (service, _, _, opener) = makeService()
        let event = ExternalReminder(id: "e", source: .event, title: "t", notes: nil,
                                     startDate: fakeNow, isAllDay: false,
                                     hasOwnAlarm: false, calendarName: "c")
        let reminder = ExternalReminder(id: "r", source: .reminder, title: "t", notes: nil,
                                        startDate: fakeNow, isAllDay: false,
                                        hasOwnAlarm: false, calendarName: "c")

        service.open(event)
        service.open(reminder)

        XCTAssertEqual(opener.opened, [URL(string: "calshow://")!,
                                       URL(string: "x-apple-reminderkit://show")!])
        XCTAssertTrue(bus.emittedEvents.filter { $0.eventType == "external_item_opened" }.count == 2)
    }

    func testOpenSkipsWhenNativeAppUnavailableAndSaysSo() {
        let (service, _, _, opener) = makeService()
        opener.canOpenResult = false
        let event = ExternalReminder(id: "e", source: .event, title: "t", notes: nil,
                                     startDate: fakeNow, isAllDay: false,
                                     hasOwnAlarm: false, calendarName: "c")

        service.open(event)

        XCTAssertTrue(opener.opened.isEmpty, "no open() without canOpen")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "external_open_unavailable" && $0.outcome == "failure"
        })
    }

    // MARK: - State restore

    func testPersistedStateRestoresAcrossInstances() {
        UserDefaults.standard.set(true, forKey: "externalCalendar.enabled")
        UserDefaults.standard.set("partial", forKey: "externalCalendar.status")
        UserDefaults.standard.set(12, forKey: "externalCalendar.leadMinutes")

        let restored = ExternalCalendarService(observabilityBus: bus)

        XCTAssertEqual(restored.isEnabled, true)
        XCTAssertEqual(restored.status, .partial)
        XCTAssertEqual(restored.leadMinutes, 12)
        XCTAssertTrue(restored.reminders.isEmpty,
                      "restore never fabricates a scan — the list fills on the next rescan")
    }
}
