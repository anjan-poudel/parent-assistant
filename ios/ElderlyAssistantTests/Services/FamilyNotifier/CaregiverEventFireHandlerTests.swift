import XCTest
import UserNotifications
@testable import ElderlyAssistant

/// The bridge from "the OS delivered an event notification" to "the
/// caregiver-notification feature reacted" (caregiver event-notifications
/// task, 2026-09-13).
///
/// Two producers flow through here: routine reminders (which delegate
/// the notify decision to `RoutineScheduler.markDelivered`) and imported
/// native-calendar items (which this handler resolves and alerts on
/// directly). The other load-bearing rule is negative: the handler NEVER
/// claims a notification, so it can neither mute the reader nor be
/// muted by it.
final class CaregiverEventFireHandlerTests: XCTestCase {

    var storage: MockEncryptedLocalStorage!
    var store: RoutineStore!
    var alarm: MockRoutineAlarmScheduler!
    var bus: MockObservabilityBus!
    var notifier: MockFamilyNotifier!
    var settings: CaregiverNotifySettings!
    var scheduler: RoutineScheduler!
    var fakeNow: Date!
    /// The item the handler "finds" for a stable key — the `ExternalReminder`
    /// analogue of a freshly-scanned native event.
    var lookup: [String: ExternalReminder]!

    override func setUp() {
        super.setUp()
        storage = MockEncryptedLocalStorage()
        store = RoutineStore(storage: storage)
        alarm = MockRoutineAlarmScheduler()
        bus = MockObservabilityBus()
        notifier = MockFamilyNotifier()
        settings = CaregiverNotifySettings.isolated()
        lookup = [:]
        fakeNow = Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 7, hour: 10, minute: 0))
        scheduler = RoutineScheduler(store: store, alarmScheduler: alarm,
                                     observabilityBus: bus,
                                     familyNotifier: notifier,
                                     caregiverNotifySettings: settings,
                                     now: { [weak self] in self?.fakeNow ?? Date() })
    }

    private func makeHandler() -> CaregiverEventFireHandler {
        CaregiverEventFireHandler(
            routineScheduler: scheduler,
            familyNotifier: notifier,
            settings: settings,
            externalItemLookup: { [lookup] stableKey in lookup?[stableKey] },
            observability: bus
        )
    }

    /// A routine reminder at 11:00 that is still pending at the pinned
    /// 10:00 "now".
    private func seedPendingOccurrence() -> RoutineOccurrence {
        store.add(RoutineEntry(category: .walk,
                               scheduleTimes: [DateComponents(hour: 11, minute: 0)],
                               isEnabled: true))
        scheduler.scheduleAll()
        guard let occurrence = scheduler.todaysOccurrences().first else {
            fatalError("expected a pending occurrence today")
        }
        return occurrence
    }

    private func externalReminder(stableKey: String,
                                  title: String,
                                  startDate: Date = Date()) -> ExternalReminder {
        ExternalReminder(id: stableKey, source: .event, title: title, notes: nil,
                         startDate: startDate, isAllDay: false, hasOwnAlarm: false,
                         calendarName: "Home")
    }

    /// A 64-char hex digest, the shape `ExternalCalendarService.stableKey`
    /// produces (the handler truncates it to the bus's 12-char width).
    private let stableKey = "3f9c1d4b2a7e60581234567890abcdef3f9c1d4b2a7e60581234567890abcd"

    // MARK: - Routine reminders

    /// A delivered routine notification goes through `markDelivered` —
    /// the seam that owns BOTH the occurrence state and the notify
    /// decision, so the handler never re-derives the toggle.
    func testRoutineReminderMarksTheOccurrenceDelivered() async {
        let occurrence = seedPendingOccurrence()
        settings.routineReminders = true
        let handler = makeHandler()
        let notified = expectation(description: "caregiver alert")
        notifier.onNotify = { notified.fulfill() }

        let claimed = handler.willPresent(
            TestNotificationFactory.notification(
                category: "ROUTINE_REMINDER", title: "Walk", body: "Time to walk",
                userInfo: ["type": "routine_reminder",
                           "occurrence_id": occurrence.id.uuidString]),
            categoryIdentifier: "ROUTINE_REMINDER")

        XCTAssertFalse(claimed)
        XCTAssertEqual(scheduler.todaysOccurrences().first?.state, .delivered,
                       "the OS delivery IS the delivery — the handler records it")
        await fulfillment(of: [notified], timeout: 2)
        XCTAssertEqual(notifier.contexts.first?.kind, .routineReminder)
    }

    /// The handler must not second-guess the scheduler's toggle: with the
    /// routine preference OFF, the occurrence is still marked delivered
    /// (that is the elder's alarm state, not the caregiver's) and nobody
    /// is alerted.
    func testRoutineReminderStillMarksDeliveredWhenTheToggleIsOff() async {
        let occurrence = seedPendingOccurrence()
        XCTAssertFalse(settings.routineReminders, "defaults are OFF")
        let handler = makeHandler()
        let noAlert = expectation(description: "no caregiver alert")
        noAlert.isInverted = true
        notifier.onNotify = { noAlert.fulfill() }

        _ = handler.willPresent(
            TestNotificationFactory.notification(
                category: "ROUTINE_REMINDER", title: "Walk", body: "Time to walk",
                userInfo: ["type": "routine_reminder",
                           "occurrence_id": occurrence.id.uuidString]),
            categoryIdentifier: "ROUTINE_REMINDER")
        await fulfillment(of: [noAlert], timeout: 0.3)

        XCTAssertEqual(scheduler.todaysOccurrences().first?.state, .delivered)
        XCTAssertTrue(notifier.contexts.isEmpty)
    }

    /// A routine payload without a parseable occurrence id is malformed,
    /// not a crash — and it is observable.
    func testMalformedRoutinePayloadIsObservableAndHarmless() {
        let handler = makeHandler()

        let claimed = handler.willPresent(
            TestNotificationFactory.notification(
                category: "ROUTINE_REMINDER", title: "Walk", body: "Time to walk",
                userInfo: ["type": "routine_reminder", "occurrence_id": "not-a-uuid"]),
            categoryIdentifier: "ROUTINE_REMINDER")

        XCTAssertFalse(claimed)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "caregiver_event_handler_malformed" },
                      "a payload we cannot read must be observable, never silently dropped")
    }

    // MARK: - Imported calendar items

    func testExternalReminderNotifiesCaregiversWithCalendarKind() async {
        let start = Date()
        lookup[stableKey] = externalReminder(stableKey: stableKey,
                                             title: "Doctor appointment",
                                             startDate: start)
        settings.calendarEvents = true
        let handler = makeHandler()
        let notified = expectation(description: "caregiver alert")
        notifier.onNotify = { notified.fulfill() }

        let claimed = handler.willPresent(
            TestNotificationFactory.notification(
                category: "EXTERNAL_REMINDER", title: "Doctor appointment",
                body: "Doctor appointment",
                userInfo: ["type": "external_reminder",
                           "external_id": ExternalNotificationIdentity.identifier(for: stableKey)]),
            categoryIdentifier: "EXTERNAL_REMINDER")

        XCTAssertFalse(claimed)
        await fulfillment(of: [notified], timeout: 2)
        XCTAssertEqual(notifier.lastAlertType, .eventReminder)
        XCTAssertEqual(notifier.contexts.count, 1)
        let context = notifier.contexts.first
        XCTAssertEqual(context?.kind, .calendarEvent)
        XCTAssertEqual(context?.eventTitle, "Doctor appointment")
        XCTAssertEqual(context?.fireAt, start,
                       "fireAt is the event's own start, not the moment we observed the delivery")
    }

    /// The bus carries the HASH, never the title — the constitution's
    /// no-PII rule, asserted against every metadata value of every event
    /// this handler emitted.
    func testExternalAlertIsPiiFreeOnTheBus() async {
        let title = "Dr Sharma Cardiology"
        lookup[stableKey] = externalReminder(stableKey: stableKey, title: title)
        settings.calendarEvents = true
        let handler = makeHandler()
        let notified = expectation(description: "caregiver alert")
        notifier.onNotify = { notified.fulfill() }

        _ = handler.willPresent(
            TestNotificationFactory.notification(
                category: "EXTERNAL_REMINDER", title: title, body: title,
                userInfo: ["type": "external_reminder",
                           "external_id": ExternalNotificationIdentity.identifier(for: stableKey)]),
            categoryIdentifier: "EXTERNAL_REMINDER")
        await fulfillment(of: [notified], timeout: 2)

        let fired = bus.emittedEvents.filter { $0.eventType == "caregiver_event_fired" }
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.metadata["kind"], EventNotifyKind.calendarEvent.rawValue)
        XCTAssertEqual(fired.first?.metadata["event_id_hash"], String(stableKey.prefix(12)),
                       "the stable key is already a SHA-256 digest — truncated, not re-hashed")
        for event in bus.emittedEvents {
            for (_, value) in event.metadata {
                XCTAssertFalse(value.contains(title),
                               "the event title must never reach the bus: \(value)")
            }
        }
    }

    func testExternalReminderIsSkippedWhenTheToggleIsOff() async {
        lookup[stableKey] = externalReminder(stableKey: stableKey, title: "Doctor")
        XCTAssertFalse(settings.calendarEvents, "defaults are OFF")
        let handler = makeHandler()
        let noAlert = expectation(description: "no caregiver alert")
        noAlert.isInverted = true
        notifier.onNotify = { noAlert.fulfill() }

        _ = handler.willPresent(
            TestNotificationFactory.notification(
                category: "EXTERNAL_REMINDER", title: "Doctor", body: "Doctor",
                userInfo: ["type": "external_reminder",
                           "external_id": ExternalNotificationIdentity.identifier(for: stableKey)]),
            categoryIdentifier: "EXTERNAL_REMINDER")
        await fulfillment(of: [noAlert], timeout: 0.3)

        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "caregiver_event_skipped" },
                      "a suppressed alert is still observable")
        XCTAssertTrue(notifier.contexts.isEmpty)
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "caregiver_event_fired" })
    }

    /// The item can vanish between arming and firing (deleted natively,
    /// or a rescan dropped it). The event DID happen, so the alert still
    /// fires — titled with the producer's own body rather than a
    /// fabricated name.
    func testVanishedItemStillAlertsUsingTheNotificationBody() async {
        settings.calendarEvents = true
        let handler = makeHandler()   // lookup is empty
        let notified = expectation(description: "caregiver alert")
        notifier.onNotify = { notified.fulfill() }

        _ = handler.willPresent(
            TestNotificationFactory.notification(
                category: "EXTERNAL_REMINDER", title: "Doctor", body: "Doctor",
                userInfo: ["type": "external_reminder",
                           "external_id": ExternalNotificationIdentity.identifier(for: stableKey)]),
            categoryIdentifier: "EXTERNAL_REMINDER")
        await fulfillment(of: [notified], timeout: 2)

        XCTAssertEqual(notifier.contexts.first?.eventTitle, "Doctor")
        XCTAssertEqual(notifier.contexts.first?.eventIdHash, String(stableKey.prefix(12)))
    }

    func testMalformedExternalPayloadIsObservableAndHarmless() {
        settings.calendarEvents = true
        let handler = makeHandler()

        let claimed = handler.willPresent(
            TestNotificationFactory.notification(
                category: "EXTERNAL_REMINDER", title: "Doctor", body: "Doctor",
                userInfo: ["type": "external_reminder"]),
            categoryIdentifier: "EXTERNAL_REMINDER")

        XCTAssertFalse(claimed)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "caregiver_event_handler_malformed" })
    }

    // MARK: - Not our notification

    /// Medication alarms carry no `type` key — the handler must leave
    /// them completely alone (their caregiver alerts ride the scheduler,
    /// not this bridge).
    func testUntypedNotificationIsIgnored() {
        let handler = makeHandler()
        var notified = false
        notifier.onNotify = { notified = true }

        let claimed = handler.willPresent(
            TestNotificationFactory.notification(
                category: "MEDICATION_REMINDER", title: "Amlodipine", body: "Time for your medicine"),
            categoryIdentifier: "MEDICATION_REMINDER")

        XCTAssertFalse(claimed)
        XCTAssertFalse(notified)
        XCTAssertTrue(bus.emittedEvents.isEmpty, "nothing to say about a notification that isn't ours")
    }

    func testUnknownTypeIsIgnored() {
        let handler = makeHandler()
        var notified = false
        notifier.onNotify = { notified = true }

        let claimed = handler.willPresent(
            TestNotificationFactory.notification(
                category: "SOMETHING_ELSE", title: "T", body: "B",
                userInfo: ["type": "some_future_type"]),
            categoryIdentifier: "SOMETHING_ELSE")

        XCTAssertFalse(claimed)
        XCTAssertFalse(notified)
    }

    // MARK: - Never claims (facade contract)

    /// The handler is registered on the single `NotificationFacade`. The
    /// facade stops consulting handlers after the first claim, so a `true`
    /// here would silently mute every later handler — including the
    /// reader's read-aloud. Delivery options must stay untouched too.
    func testHandlerNeverClaimsSoLaterHandlersStillRun() {
        let occurrence = seedPendingOccurrence()
        let spy = SpyNotificationEventHandler()
        let facade = NotificationFacade(handlers: [makeHandler(), spy],
                                        observability: MockObservabilityBus())

        let options = facade.present(
            TestNotificationFactory.notification(
                category: "ROUTINE_REMINDER", title: "Walk", body: "Time to walk",
                userInfo: ["type": "routine_reminder",
                           "occurrence_id": occurrence.id.uuidString]))

        XCTAssertEqual(options, [.banner, .list, .sound],
                       "presentation is preserved no matter what a handler decides")
        XCTAssertEqual(spy.willPresentCalls, 1,
                       "the handler after it must still be consulted — it claims nothing")
        XCTAssertEqual(scheduler.todaysOccurrences().first?.state, .delivered)
    }
}

/// Minimal stand-in for the handler registered AFTER the caregiver
/// bridge (the reader, in production) — it only needs to prove it was
/// reached.
private final class SpyNotificationEventHandler: NotificationEventHandling {
    private(set) var willPresentCalls = 0

    func willPresent(_ notification: UNNotification, categoryIdentifier: String) -> Bool {
        willPresentCalls += 1
        return true
    }

    func didReceive(_ response: UNNotificationResponse) async {}
}
