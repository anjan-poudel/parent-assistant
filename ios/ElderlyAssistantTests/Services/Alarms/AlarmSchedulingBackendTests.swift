import XCTest
import UserNotifications
@testable import ElderlyAssistant

// MARK: - Fakes

/// [ALARMKIT-ALARMS] (2026-09-10) Scriptable `AlarmSchedulingBackend`
/// fake — records every alarm-side call and reports scripted outcomes.
private final class FakeAlarmSchedulingBackend: AlarmSchedulingBackend {
    let kind: AlarmBackendKind
    var authorizationStatus: AlarmAuthorizationStatus
    var locale: Locale

    var authorizationRequestCount = 0
    var authorizationGranted = true
    private(set) var scheduledAlarms: [Alarm] = []
    private(set) var cancelledIDs: [UUID] = []
    private(set) var snoozes: [(alarm: Alarm, timeInterval: TimeInterval)] = []
    private(set) var cancelledSnoozeIDs: [UUID] = []
    private(set) var systemSnoozeCalls: [(id: UUID, minutes: Int)] = []
    /// The minutes the fake "system" can honor (mirrors the AlarmKit
    /// backend's fixed-duration contract); nil = never.
    var systemSnoozeSupportedMinutes: Int?

    init(kind: AlarmBackendKind,
         authorizationStatus: AlarmAuthorizationStatus = .authorized,
         locale: Locale = Locale(identifier: "en")) {
        self.kind = kind
        self.authorizationStatus = authorizationStatus
        self.locale = locale
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        authorizationRequestCount += 1
        authorizationStatus = authorizationGranted ? .authorized : .denied
        return authorizationGranted
    }

    func scheduleAlarm(_ alarm: Alarm) { scheduledAlarms.append(alarm) }
    func cancelAlarm(id: UUID) { cancelledIDs.append(id) }
    func scheduleSnooze(for alarm: Alarm, timeInterval: TimeInterval) {
        snoozes.append((alarm, timeInterval))
    }
    func cancelSnooze(id: UUID) { cancelledSnoozeIDs.append(id) }
    func snoozeViaSystem(id: UUID, minutes: Int) -> Bool {
        systemSnoozeCalls.append((id, minutes))
        return systemSnoozeSupportedMinutes == minutes
    }
}

/// [ALARMKIT-ALARMS] (2026-09-10) Recording `LocalNotificationScheduling`
/// fake (the one in AlarmTimersServiceTests is file-private).
private final class RecordingAlarmNotificationCenter: LocalNotificationScheduling {
    var authorizationGranted = true
    private(set) var authorizationRequestCount = 0
    private(set) var addedRequests: [UNNotificationRequest] = []
    var removedIdentifiers: [String] = []

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

// MARK: - Seam tests

/// [ALARMKIT-ALARMS] (2026-09-10) Seam-level tests that never touch
/// AlarmKit types: backend selection (the iOS 26 → AlarmKit, else UN
/// rule), the UN backend's pre-26 contract, scheduler passthroughs, and
/// the service's system-first snooze routing with the persist-then-arm
/// house rule intact. `MockEncryptedLocalStorage` / `MockObservabilityBus`
/// come from MedicationSchedulerTests.swift (shared across the test
/// module). Main-confined like the service under test.
@MainActor
final class AlarmSchedulingBackendTests: XCTestCase {

    private var storage: MockEncryptedLocalStorage!
    private var center: RecordingAlarmNotificationCenter!
    private var bus: MockObservabilityBus!
    private var store: AlarmTimersStore!
    private var nowDate: Date!

    override func setUp() {
        super.setUp()
        storage = MockEncryptedLocalStorage()
        center = RecordingAlarmNotificationCenter()
        bus = MockObservabilityBus()
        store = AlarmTimersStore(storage: storage)
        nowDate = date(2026, 9, 7, 10, 0)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func fixedNow() -> Date { nowDate }

    private func makeService(backend: AlarmSchedulingBackend) -> AlarmTimersService {
        let scheduler = AlarmScheduler(notifications: center,
                                       locale: Locale(identifier: "en"),
                                       backend: backend)
        return AlarmTimersService(store: store, scheduler: scheduler,
                                  observabilityBus: bus, now: fixedNow)
    }

    private static var alarmKitIsAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    // MARK: - Backend selection

    func testSelectionPrefersAlarmKitWhenTheRuntimeSupportsIt() throws {
        try XCTSkipUnless(Self.alarmKitIsAvailable,
                          "AlarmKit selection requires an iOS 26 runtime")
        let backend = AlarmScheduler.makeAlarmBackend(
            isAlarmKitAvailable: true,
            notifications: center,
            locale: Locale(identifier: "en"))
        XCTAssertEqual(backend.kind, .alarmKit)
    }

    func testSelectionFallsBackToUNWithoutAlarmKit() {
        let backend = AlarmScheduler.makeAlarmBackend(
            isAlarmKitAvailable: false,
            notifications: center,
            locale: Locale(identifier: "en"))
        XCTAssertEqual(backend.kind, .localNotifications)
    }

    func testSelectionHonorsTheRuntimeGateEvenWhenTheFlagClaimsAlarmKit() throws {
        try XCTSkipIf(Self.alarmKitIsAvailable,
                      "on an iOS 26 runtime the gate correctly ADMITS AlarmKit — the refusal shape is pre-26 only")
        let backend = AlarmScheduler.makeAlarmBackend(
            isAlarmKitAvailable: true,
            notifications: center,
            locale: Locale(identifier: "en"))
        XCTAssertEqual(backend.kind, .localNotifications)
    }

    func testExplicitInitKeepsTheUNBackend() {
        // The historical test construction (`AlarmScheduler(notifications:)`)
        // must keep selecting the UN backend — the pre-26 production path
        // AND the contract every existing UN assertion relies on.
        let scheduler = AlarmScheduler(notifications: center)
        XCTAssertEqual(scheduler.alarmSchedulingKind, .localNotifications)
        XCTAssertEqual(scheduler.alarmAuthorizationStatus, .notDetermined)
    }

    // MARK: - UN backend (pre-26 fallback)

    func testUNBackendAuthorizationStatusTracksPointOfUseResolution() async {
        let backend = UNAlarmBackend(notifications: center)
        XCTAssertEqual(backend.authorizationStatus, .notDetermined)

        center.authorizationGranted = false
        let denied = await backend.requestAuthorizationIfNeeded()
        XCTAssertFalse(denied)
        XCTAssertEqual(backend.authorizationStatus, .denied)

        center.authorizationGranted = true
        let granted = await backend.requestAuthorizationIfNeeded()
        XCTAssertTrue(granted)
        XCTAssertEqual(backend.authorizationStatus, .authorized)
    }

    func testUNBackendArmsTheHistoricalDailyRepeatAndCancelsByIdentifier() throws {
        let backend = UNAlarmBackend(notifications: center)
        let alarm = Alarm(time: date(2026, 9, 7, 6, 0))

        backend.scheduleAlarm(alarm)

        XCTAssertEqual(center.addedRequests.count, 1)
        let request = try XCTUnwrap(center.addedRequests.first)
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(request.identifier, AlarmScheduler.alarmRequestID(alarm.id))
        XCTAssertTrue(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.hour, 6)
        XCTAssertEqual(trigger.dateComponents.minute, 0)
        XCTAssertEqual(request.content.userInfo["kind"] as? String, "alarm")

        backend.cancelAlarm(id: alarm.id)
        XCTAssertEqual(center.removedIdentifiers, [AlarmScheduler.alarmRequestID(alarm.id)])

        XCTAssertFalse(backend.snoozeViaSystem(id: alarm.id, minutes: 10),
                       "pre-26 there is no system alarm to snooze")
    }

    // MARK: - Service routing through the seam

    func testAddAlarmStillGatesOnBackendAuthorization() async {
        let backend = FakeAlarmSchedulingBackend(kind: .alarmKit)
        backend.authorizationGranted = false
        let service = makeService(backend: backend)

        let outcome = await service.addAlarm(at: date(2026, 9, 7, 6, 0), label: nil)

        XCTAssertEqual(outcome, .permissionDenied)
        XCTAssertTrue(service.alarms.isEmpty)
        XCTAssertTrue(backend.scheduledAlarms.isEmpty, "nothing armed on a denial")
        XCTAssertEqual(backend.authorizationStatus, .denied)
        XCTAssertEqual(store.loadAlarms(), [], "nothing stored on a denial")
    }

    func testAddAlarmRoutesThroughTheBackendAndPersistsFirst() async throws {
        let backend = FakeAlarmSchedulingBackend(kind: .alarmKit)
        let service = makeService(backend: backend)

        let outcome = await service.addAlarm(at: date(2026, 9, 7, 6, 0), label: nil)

        XCTAssertEqual(outcome, .scheduled)
        XCTAssertEqual(service.alarms.count, 1)
        XCTAssertEqual(backend.scheduledAlarms.map(\.id), service.alarms.map(\.id))
        XCTAssertEqual(store.loadAlarms(), service.alarms)
    }

    func testSnoozeRoutesToTheSystemWhenTheBackendSupportsIt() async throws {
        let backend = FakeAlarmSchedulingBackend(kind: .alarmKit)
        backend.systemSnoozeSupportedMinutes = 10
        let service = makeService(backend: backend)
        _ = await service.addAlarm(at: date(2026, 9, 7, 6, 0), label: nil)
        let alarmID = try XCTUnwrap(service.alarms.first?.id)

        let outcome = service.snoozeAlarm(id: alarmID, minutes: 10)

        guard case .snoozed(let until) = outcome else {
            return XCTFail("expected .snoozed, got \(outcome)")
        }
        XCTAssertEqual(until, date(2026, 9, 7, 10, 10))
        // The SYSTEM handled the re-wake — no app one-shot was armed.
        XCTAssertEqual(backend.systemSnoozeCalls.map(\.minutes), [10])
        XCTAssertTrue(backend.snoozes.isEmpty)
        // The marker stays honest and persisted.
        XCTAssertEqual(service.alarms[0].snoozedUntil, date(2026, 9, 7, 10, 10))
        XCTAssertEqual(store.loadAlarms()[0].snoozedUntil, date(2026, 9, 7, 10, 10))
        XCTAssertEqual(bus.emittedEvents.last?.eventType, "alarm_snoozed")
    }

    func testSnoozeFallsBackToOneShotWhenTheSystemCannotHonorTheMinutes() async throws {
        let backend = FakeAlarmSchedulingBackend(kind: .alarmKit)
        backend.systemSnoozeSupportedMinutes = 10
        let service = makeService(backend: backend)
        _ = await service.addAlarm(at: date(2026, 9, 7, 6, 0), label: nil)
        let alarmID = try XCTUnwrap(service.alarms.first?.id)

        let outcome = service.snoozeAlarm(id: alarmID, minutes: 15)

        guard case .snoozed(let until) = outcome else {
            return XCTFail("expected .snoozed, got \(outcome)")
        }
        XCTAssertEqual(until, date(2026, 9, 7, 10, 15))
        // The system was asked (fixed duration refuses) and the app's own
        // one-shot is armed with the requested minutes.
        XCTAssertEqual(backend.systemSnoozeCalls.map(\.minutes), [15])
        XCTAssertEqual(backend.snoozes.map(\.timeInterval), [900])
        XCTAssertTrue(backend.cancelledIDs.isEmpty, "the daily repeat is untouched")
    }

    func testSnoozeFallsBackToTheOneShotOnTheUNBackend() async throws {
        let service = makeService(backend: UNAlarmBackend(notifications: center))
        _ = await service.addAlarm(at: date(2026, 9, 7, 6, 0), label: nil)
        let alarmID = try XCTUnwrap(service.alarms.first?.id)

        let outcome = service.snoozeAlarm(id: alarmID, minutes: 10)

        guard case .snoozed = outcome else {
            return XCTFail("expected .snoozed, got \(outcome)")
        }
        // Pre-26: the daily repeat + the one-shot snooze notification are
        // the whole story — the historical shape, unchanged.
        XCTAssertEqual(center.addedRequests.count, 2)
        XCTAssertEqual(center.addedRequests.last?.identifier,
                       AlarmScheduler.alarmSnoozeRequestID(alarmID))
        let trigger = try XCTUnwrap(
            center.addedRequests.last?.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, 600)
    }

    func testSnoozeStillPersistsBeforeArmingOnTheSystemPath() async throws {
        let backend = FakeAlarmSchedulingBackend(kind: .alarmKit)
        backend.systemSnoozeSupportedMinutes = 10
        let service = makeService(backend: backend)
        _ = await service.addAlarm(at: date(2026, 9, 7, 6, 0), label: nil)
        let alarmID = try XCTUnwrap(service.alarms.first?.id)
        storage.shouldFailWrite = true

        let outcome = service.snoozeAlarm(id: alarmID, minutes: 10)

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(backend.systemSnoozeCalls.isEmpty,
                      "a failed persist must not touch the system")
        XCTAssertNil(service.alarms[0].snoozedUntil)
    }

    // MARK: - Scheduler passthroughs

    func testSchedulerForwardsLocaleAndExposesBackendState() {
        let backend = FakeAlarmSchedulingBackend(kind: .alarmKit,
                                                 authorizationStatus: .denied)
        let scheduler = AlarmScheduler(notifications: center,
                                       locale: Locale(identifier: "en"),
                                       backend: backend)
        XCTAssertEqual(scheduler.alarmSchedulingKind, .alarmKit)
        XCTAssertEqual(scheduler.alarmAuthorizationStatus, .denied)

        scheduler.locale = Locale(identifier: "ne-NP")
        XCTAssertEqual(backend.locale.identifier, "ne-NP")
    }
}
