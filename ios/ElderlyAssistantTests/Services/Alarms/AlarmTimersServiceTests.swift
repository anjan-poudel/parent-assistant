import XCTest
import UserNotifications
@testable import ElderlyAssistant

// MARK: - Recording notification-center fake

/// [ALARMS-TIMERS] (2026-09-07) Scriptable `LocalNotificationScheduling`
/// fake — records every request it was asked to arm (identifier, content,
/// trigger) and every cancellation, and reports a scripted authorization
/// outcome. `MockEncryptedLocalStorage` / `MockObservabilityBus` come from
/// MedicationSchedulerTests.swift (shared across the test module).
private final class RecordingNotificationCenter: LocalNotificationScheduling {
    var authorizationGranted = true
    private(set) var authorizationRequestCount = 0
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removedIdentifiers: [String] = []

    func requestAuthorization() async -> Bool {
        authorizationRequestCount += 1
        return authorizationGranted
    }

    func add(_ request: UNNotificationRequest, completion: ((Error?) -> Void)? = nil) {
        addedRequests.append(request)
        completion?(nil)
    }

    func removePendingNotifications(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
    }
}

// MARK: - AlarmTimersService tests

/// [ALARMS-TIMERS] (2026-09-07) Service behavior with a fixed clock and
/// recording fakes: persist-before-arm ordering, daily-repeat vs one-shot
/// notification shapes, permission denial storing nothing, caps, toggling /
/// cancelling / expiring / pruning, the FR-025 `scheduleAll` re-arm and
/// localized notification content.
///
/// Main-confined by contract: `AlarmTimersService` mutates its state on the
/// main thread and `scheduleAll()` / `expireTimer(id:)` DISPATCH to main when
/// called off it (background task / notification callbacks). XCTest runs
/// `async` test methods on a background executor, so without `@MainActor`
/// those sync calls would only enqueue work and the assertions right after
/// them would race the main-queue pass. Running the class on the main actor
/// makes every service call execute synchronously, as the UI does.
@MainActor
final class AlarmTimersServiceTests: XCTestCase {

    private var storage: MockEncryptedLocalStorage!
    private var center: RecordingNotificationCenter!
    private var bus: MockObservabilityBus!
    private var scheduler: AlarmScheduler!
    private var store: AlarmTimersStore!
    private var nowDate: Date!

    /// Fixed "now" = 2026-09-07 10:00 local (matches the calendar the
    /// service itself uses — `Calendar.current`).
    private func fixedNow() -> Date { nowDate }

    override func setUp() {
        super.setUp()
        storage = MockEncryptedLocalStorage()
        center = RecordingNotificationCenter()
        bus = MockObservabilityBus()
        scheduler = AlarmScheduler(notifications: center)
        store = AlarmTimersStore(storage: storage)
        nowDate = date(2026, 9, 7, 10, 0)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func makeService() -> AlarmTimersService {
        AlarmTimersService(store: store, scheduler: scheduler,
                           observabilityBus: bus, now: fixedNow)
    }

    private func lastEvent(_ service: AlarmTimersService) -> ObservabilityEvent? {
        bus.emittedEvents.last
    }

    // MARK: - Alarms

    func testAddAlarmArmsDailyRepeatingNotificationAndPersists() async throws {
        let service = makeService()

        let outcome = await service.addAlarm(at: date(2026, 9, 7, 6, 0), label: nil)

        XCTAssertEqual(outcome, .scheduled)
        XCTAssertEqual(service.alarms.count, 1)
        // 6:00 today is already past the fixed 10:00 "now" — rolls to
        // tomorrow at the same minute.
        XCTAssertEqual(service.alarms[0].time, date(2026, 9, 8, 6, 0))
        XCTAssertTrue(service.alarms[0].isEnabled)

        XCTAssertEqual(center.addedRequests.count, 1)
        let request = try XCTUnwrap(center.addedRequests.first)
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(request.identifier, AlarmScheduler.alarmRequestID(service.alarms[0].id))
        XCTAssertTrue(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.hour, 6)
        XCTAssertEqual(trigger.dateComponents.minute, 0)
        XCTAssertEqual(request.content.userInfo["kind"] as? String, "alarm")
        XCTAssertEqual(request.content.userInfo["id"] as? String,
                       service.alarms[0].id.uuidString)
        XCTAssertEqual(request.content.title, "Alarm")

        // Persisted BEFORE arming — a fresh service over the same storage
        // sees the alarm even though the notification is gone.
        let reloaded = AlarmTimersService(store: store, scheduler: scheduler,
                                          observabilityBus: bus, now: fixedNow)
        XCTAssertEqual(reloaded.alarms, service.alarms)

        let event = lastEvent(service)
        XCTAssertEqual(event?.component, "alarms_timers")
        XCTAssertEqual(event?.eventType, "alarm_created")
        XCTAssertEqual(event?.outcome, "success")
        XCTAssertNotNil(event?.metadata["id_hash"])
    }

    func testAddAlarmFutureTimeStaysSameDay() async {
        let service = makeService()

        let outcome = await service.addAlarm(at: date(2026, 9, 7, 20, 0), label: nil)

        XCTAssertEqual(outcome, .scheduled)
        XCTAssertEqual(service.alarms[0].time, date(2026, 9, 7, 20, 0))
    }

    func testAddAlarmStoresLabelInContentBody() async {
        let service = makeService()

        _ = await service.addAlarm(at: date(2026, 9, 7, 6, 0), label: "yoga")

        XCTAssertEqual(service.alarms[0].label, "yoga")
        XCTAssertEqual(center.addedRequests.first?.content.body, "yoga")
    }

    func testPermissionDeniedStoresAndArmsNothing() async {
        center.authorizationGranted = false
        let service = makeService()

        let outcome = await service.addAlarm(at: date(2026, 9, 7, 6, 0), label: nil)

        XCTAssertEqual(outcome, .permissionDenied)
        XCTAssertTrue(service.alarms.isEmpty)
        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertEqual(lastEvent(service)?.eventType, "alarm_permission_denied")
        XCTAssertEqual(lastEvent(service)?.outcome, "denied")
        // Nothing persisted either.
        XCTAssertEqual(store.loadAlarms(), [])
    }

    func testAlarmCapacityReachedStoresNothing() async {
        // Seed the store at the cap, then have the service load it.
        let seeds = (0..<AlarmTimersStore.maxAlarms).map { index in
            Alarm(time: date(2026, 9, 10, 6, 0).addingTimeInterval(TimeInterval(index)))
        }
        XCTAssertTrue(store.saveAlarms(seeds))
        let service = makeService()

        let outcome = await service.addAlarm(at: date(2026, 9, 7, 20, 0), label: nil)

        XCTAssertEqual(outcome, .atCapacity)
        XCTAssertEqual(service.alarms.count, AlarmTimersStore.maxAlarms)
        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertEqual(lastEvent(service)?.eventType, "alarm_capacity_reached")
    }

    func testDisableCancelsPendingEnableRearms() async throws {
        let service = makeService()
        _ = await service.addAlarm(at: date(2026, 9, 7, 6, 0), label: nil)
        let alarmID = try XCTUnwrap(service.alarms.first?.id)
        XCTAssertEqual(center.addedRequests.count, 1)

        service.setAlarmEnabled(id: alarmID, enabled: false)

        XCTAssertEqual(center.removedIdentifiers, [AlarmScheduler.alarmRequestID(alarmID)])
        XCTAssertEqual(service.alarms[0].isEnabled, false)
        XCTAssertEqual(lastEvent(service)?.eventType, "alarm_disabled")
        // Persisted — a fresh service over the same storage sees it off.
        let reloaded = AlarmTimersService(store: store, scheduler: scheduler,
                                          observabilityBus: bus, now: fixedNow)
        XCTAssertEqual(reloaded.alarms[0].isEnabled, false)

        service.setAlarmEnabled(id: alarmID, enabled: true)

        XCTAssertEqual(service.alarms[0].isEnabled, true)
        // Re-arm replaces the pending request in place (same identifier).
        XCTAssertEqual(center.addedRequests.count, 2)
        XCTAssertEqual(center.addedRequests.last?.identifier,
                       AlarmScheduler.alarmRequestID(alarmID))
        XCTAssertEqual(lastEvent(service)?.eventType, "alarm_enabled")
    }

    func testRemoveAlarmCancelsPendingAndPersists() async {
        let service = makeService()
        _ = await service.addAlarm(at: date(2026, 9, 7, 6, 0), label: nil)
        let alarmID = service.alarms[0].id

        service.removeAlarm(id: alarmID)

        XCTAssertTrue(service.alarms.isEmpty)
        XCTAssertTrue(center.removedIdentifiers.contains(AlarmScheduler.alarmRequestID(alarmID)))
        XCTAssertEqual(store.loadAlarms(), [])
        XCTAssertEqual(lastEvent(service)?.eventType, "alarm_removed")
    }

    func testPersistFailureOnAddReturnsFailedAndArmsNothing() async {
        storage.shouldFailWrite = true
        let service = makeService()

        let outcome = await service.addAlarm(at: date(2026, 9, 7, 6, 0), label: nil)

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(service.alarms.isEmpty)
        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertEqual(lastEvent(service)?.eventType, "alarm_persistence_failed")
    }

    // MARK: - Timers

    func testStartTimerArmsOneShotCompletionAndPersists() async throws {
        let service = makeService()

        let outcome = await service.startTimer(durationSeconds: 300, label: "tea")

        XCTAssertEqual(outcome, .scheduled)
        XCTAssertEqual(service.timers.count, 1)
        XCTAssertEqual(service.timers[0].endsAt, date(2026, 9, 7, 10, 5))
        XCTAssertTrue(service.timers[0].isActive)
        XCTAssertEqual(service.timers[0].label, "tea")
        XCTAssertEqual(service.activeTimers.count, 1)

        let request = try XCTUnwrap(center.addedRequests.first)
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(request.identifier, AlarmScheduler.timerRequestID(service.timers[0].id))
        XCTAssertFalse(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.hour, 10)
        XCTAssertEqual(trigger.dateComponents.minute, 5)
        XCTAssertEqual(request.content.userInfo["kind"] as? String, "timer")
        XCTAssertEqual(request.content.userInfo["id"] as? String,
                       service.timers[0].id.uuidString)
        XCTAssertEqual(request.content.title, "Timer finished.")
        XCTAssertEqual(request.content.body, "tea")

        XCTAssertEqual(store.loadTimers(), service.timers)
        XCTAssertEqual(lastEvent(service)?.eventType, "timer_created")
        XCTAssertEqual(lastEvent(service)?.outcome, "success")
    }

    func testInvalidTimerDurationFailsBeforeAuthorization() async {
        center.authorizationGranted = false
        let service = makeService()

        let outcome = await service.startTimer(durationSeconds: 0, label: nil)
        let overMax = await service.startTimer(durationSeconds: 86_401, label: nil)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(overMax, .failed)
        // The bounds guard runs BEFORE any permission request.
        XCTAssertEqual(center.authorizationRequestCount, 0)
        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertTrue(service.timers.isEmpty)
        XCTAssertEqual(lastEvent(service)?.eventType, "timer_invalid_duration")
    }

    func testMaximumDurationBoundaryIsAccepted() async {
        center.authorizationGranted = false
        let service = makeService()

        // 86_400 s = 24 h passes the bounds guard, so the (ungranted)
        // permission request is what stops it — proving the boundary is
        // accepted by the guard.
        let outcome = await service.startTimer(durationSeconds: 86_400, label: nil)

        XCTAssertEqual(outcome, .permissionDenied)
        XCTAssertEqual(center.authorizationRequestCount, 1)
    }

    func testTimerPermissionDeniedStoresNothing() async {
        center.authorizationGranted = false
        let service = makeService()

        let outcome = await service.startTimer(durationSeconds: 300, label: nil)

        XCTAssertEqual(outcome, .permissionDenied)
        XCTAssertTrue(service.timers.isEmpty)
        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertEqual(store.loadTimers(), [])
        XCTAssertEqual(lastEvent(service)?.eventType, "timer_permission_denied")
    }

    func testTimerCapacityReachedStoresNothing() async {
        // Seed 10 live countdowns (the cap), all ending in the future.
        let seeds = (0..<AlarmTimersStore.maxTimers).map { index in
            TimerItem(endsAt: date(2026, 9, 7, 11, 0).addingTimeInterval(TimeInterval(index)))
        }
        XCTAssertTrue(store.saveTimers(seeds))
        let service = makeService()
        XCTAssertEqual(service.activeTimers.count, AlarmTimersStore.maxTimers)

        let outcome = await service.startTimer(durationSeconds: 300, label: nil)

        XCTAssertEqual(outcome, .atCapacity)
        XCTAssertEqual(center.addedRequests.count, 0)
        XCTAssertEqual(lastEvent(service)?.eventType, "timer_capacity_reached")
    }

    func testCancelTimerRemovesPendingAndPersists() async {
        let service = makeService()
        _ = await service.startTimer(durationSeconds: 300, label: nil)
        let timerID = service.timers[0].id

        service.cancelTimer(id: timerID)

        XCTAssertTrue(service.timers.isEmpty)
        XCTAssertTrue(service.activeTimers.isEmpty)
        XCTAssertTrue(center.removedIdentifiers.contains(AlarmScheduler.timerRequestID(timerID)))
        XCTAssertEqual(store.loadTimers(), [])
        XCTAssertEqual(lastEvent(service)?.eventType, "timer_cancelled")
    }

    func testExpireTimerMarksInactiveAndPruneSweeps() async {
        let service = makeService()
        _ = await service.startTimer(durationSeconds: 300, label: nil)
        let timerID = service.timers[0].id

        service.expireTimer(id: timerID)

        XCTAssertTrue(service.activeTimers.isEmpty)
        XCTAssertEqual(service.timers[0].isActive, false)
        // Persisted as finished; the prune sweep drops the row entirely.
        let reloaded = AlarmTimersService(store: store, scheduler: scheduler,
                                          observabilityBus: bus, now: fixedNow)
        XCTAssertEqual(reloaded.timers.count, 1)
        XCTAssertFalse(reloaded.timers[0].isActive)
        XCTAssertEqual(lastEvent(service)?.eventType, "timer_finished")

        reloaded.pruneFinishedTimers()
        XCTAssertTrue(reloaded.timers.isEmpty)
        XCTAssertEqual(store.loadTimers(), [])
    }

    func testPruneDropsRowsWhoseDeadlinePassed() {
        // An app closed while a timer ran finds the row swept on relaunch:
        // prune drops inactive rows AND rows whose endsAt is in the past.
        let seeds = [
            TimerItem(endsAt: date(2026, 9, 7, 9, 30), label: "dead"),
            TimerItem(endsAt: date(2026, 9, 7, 11, 0), label: "live")
        ]
        XCTAssertTrue(store.saveTimers(seeds))
        let service = makeService()
        XCTAssertEqual(service.activeTimers.count, 1)
        XCTAssertEqual(service.activeTimers[0].label, "live")

        service.pruneFinishedTimers()

        XCTAssertEqual(service.timers.count, 1)
        XCTAssertEqual(service.timers[0].label, "live")
        XCTAssertEqual(store.loadTimers().map(\.label), ["live"])
        XCTAssertEqual(lastEvent(service)?.eventType, "timer_pruned_expired")
    }

    func testPersistFailureOnStartTimerReturnsFailed() async {
        storage.shouldFailWrite = true
        let service = makeService()

        let outcome = await service.startTimer(durationSeconds: 300, label: nil)

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(service.timers.isEmpty)
        XCTAssertTrue(center.addedRequests.isEmpty)
    }

    // MARK: - scheduleAll (FR-025 re-queue)

    func testScheduleAllRearmsEnabledAlarmsAndLiveTimersIdempotently() async {
        let service = makeService()
        _ = await service.addAlarm(at: date(2026, 9, 7, 6, 0), label: nil)
        _ = await service.addAlarm(at: date(2026, 9, 7, 21, 0), label: nil)
        _ = await service.startTimer(durationSeconds: 300, label: nil)
        service.setAlarmEnabled(id: service.alarms[1].id, enabled: false)
        let armedBefore = center.addedRequests.map(\.identifier)

        service.scheduleAll()

        // One re-arm per enabled alarm (disabled one skipped) + one re-arm
        // per live timer — replacements in place, same identifiers.
        XCTAssertEqual(center.addedRequests.count, armedBefore.count + 2)
        let rearmed = center.addedRequests.suffix(2).map(\.identifier)
        XCTAssertEqual(Set(rearmed), Set([
            AlarmScheduler.alarmRequestID(service.alarms[0].id),
            AlarmScheduler.timerRequestID(service.timers[0].id)
        ]))
        XCTAssertEqual(lastEvent(service)?.eventType, "alarms_timers_requeued")
        XCTAssertEqual(lastEvent(service)?.outcome, "success")

        // A second pass re-arms the same identifiers again — never duplicating.
        service.scheduleAll()
        XCTAssertEqual(center.addedRequests.count, armedBefore.count + 4)
    }

    func testScheduleAllDropsNoExpiredTimersFromTheLists() async {
        let service = makeService()
        _ = await service.startTimer(durationSeconds: 300, label: nil)

        service.scheduleAll()
        XCTAssertEqual(service.timers.count, 1)
        XCTAssertTrue(service.timers[0].isActive)
    }

    // MARK: - Localized notification content

    func testNepaliSchedulerLocaleProducesNepaliContent() async {
        scheduler.locale = Locale(identifier: "ne-NP")
        let service = makeService()

        _ = await service.addAlarm(at: date(2026, 9, 7, 6, 0), label: nil)
        _ = await service.startTimer(durationSeconds: 300, label: nil)

        XCTAssertEqual(center.addedRequests[0].content.title, "अलार्म")
        XCTAssertEqual(center.addedRequests[1].content.title, "टाइमर सकियो।")
    }
}
