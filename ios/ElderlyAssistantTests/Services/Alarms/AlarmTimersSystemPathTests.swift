import XCTest
import UserNotifications
@testable import ElderlyAssistant

// MARK: - Recording fakes

/// [TIMER-ALARM] (2026-09-10) Scriptable `AlarmKitTimerScheduling` fake —
/// records every schedule/cancel, scripts the authorization outcome, and
/// can be told to throw on schedule (the service must then fall back to
/// the UN path).
private final class FakeAlarmKitScheduler: AlarmKitTimerScheduling {
    var authorization: AlarmKitTimerAuthorization = .notDetermined
    var scheduleShouldThrow = false
    private(set) var authorizationRequestCount = 0
    private(set) var scheduled: [(id: UUID, duration: TimeInterval, label: String?)] = []
    private(set) var cancelledIDs: [UUID] = []
    private(set) var reportedSystemIDs: Set<UUID> = []

    var authorizationState: AlarmKitTimerAuthorization { authorization }

    func requestAuthorization() async -> AlarmKitTimerAuthorization {
        authorizationRequestCount += 1
        return authorization
    }

    func scheduleTimer(id: UUID, duration: TimeInterval, label: String?) async throws {
        if scheduleShouldThrow {
            throw NSError(domain: "FakeAlarmKit", code: 1)
        }
        scheduled.append((id, duration, label))
        reportedSystemIDs.insert(id)
    }

    func cancelTimer(id: UUID) {
        cancelledIDs.append(id)
        reportedSystemIDs.remove(id)
    }

    func systemTimerIDs() -> Set<UUID> { reportedSystemIDs }
}

/// [TIMER-ALARM] (2026-09-10) Local `LocalNotificationScheduling` fake
/// (the one in AlarmTimersServiceTests is file-private).
private final class RecordingUNCenter: LocalNotificationScheduling {
    var authorizationGranted = true
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removedIdentifiers: [String] = []

    func requestAuthorization() async -> Bool { authorizationGranted }

    func add(_ request: UNNotificationRequest, completion: ((Error?) -> Void)? = nil) {
        addedRequests.append(request)
        completion?(nil)
    }

    func removePendingNotifications(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
    }
}

// MARK: - System-path composition tests

/// [TIMER-ALARM] (2026-09-10) `AlarmTimersService` timer-path selection:
/// iOS-26 AlarmKit system-managed timers vs the UN fallback — the
/// best-first composition, the honest fallbacks, and the scheduleAll
/// reconciliation. Main actor, fixed clock, recording fakes (same
/// contract as AlarmTimersServiceTests).
@MainActor
final class AlarmTimersSystemPathTests: XCTestCase {

    private var storage: MockEncryptedLocalStorage!
    private var unCenter: RecordingUNCenter!
    private var alarmKit: FakeAlarmKitScheduler!
    private var bus: MockObservabilityBus!
    private var nowDate: Date!

    private func fixedNow() -> Date { nowDate }

    override func setUp() {
        super.setUp()
        storage = MockEncryptedLocalStorage()
        unCenter = RecordingUNCenter()
        alarmKit = FakeAlarmKitScheduler()
        bus = MockObservabilityBus()
        nowDate = Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 10, hour: 10, minute: 0
        ))!
    }

    private func makeService() -> AlarmTimersService {
        AlarmTimersService(
            store: AlarmTimersStore(storage: storage),
            scheduler: AlarmScheduler(notifications: unCenter),
            observabilityBus: bus,
            now: fixedNow,
            systemScheduler: alarmKit
        )
    }

    // MARK: - Path selection at creation

    func testAuthorizedAlarmKitTakesSystemPathAndArmsNoUNNotification() async {
        alarmKit.authorization = .authorized
        let service = makeService()

        let outcome = await service.startTimer(durationSeconds: 300, label: "चिया")

        XCTAssertEqual(outcome, .scheduled)
        XCTAssertEqual(alarmKit.scheduled.count, 1)
        XCTAssertEqual(alarmKit.scheduled.first?.duration, 300)
        XCTAssertEqual(alarmKit.scheduled.first?.label, "चिया")
        // No UN request armed — the system owns this timer.
        XCTAssertTrue(unCenter.addedRequests.isEmpty)
        XCTAssertTrue(service.systemManagedTimerIDs.contains(service.timers[0].id))
        // The in-app engine feed excludes system-managed timers (the
        // SYSTEM presents the alarm; a second in-app bell would double-ring).
        XCTAssertTrue(service.engineManagedActiveTimers.isEmpty)
    }

    func testDeniedAlarmKitFallsBackToUNPath() async {
        alarmKit.authorization = .denied
        let service = makeService()

        let outcome = await service.startTimer(durationSeconds: 300, label: nil)

        XCTAssertEqual(outcome, .scheduled)
        XCTAssertTrue(alarmKit.scheduled.isEmpty)
        XCTAssertEqual(unCenter.addedRequests.count, 1)
        XCTAssertEqual(unCenter.addedRequests.first?.content.userInfo["kind"] as? String, "timer")
        XCTAssertEqual(service.engineManagedActiveTimers.count, 1)
    }

    func testAlarmKitScheduleFailureFallsBackToUNPath() async {
        alarmKit.authorization = .authorized
        alarmKit.scheduleShouldThrow = true
        let service = makeService()

        let outcome = await service.startTimer(durationSeconds: 60, label: nil)

        XCTAssertEqual(outcome, .scheduled)  // honest: a timer IS armed
        XCTAssertEqual(unCenter.addedRequests.count, 1)
        XCTAssertTrue(service.engineManagedActiveTimers.contains(service.timers[0]))
        XCTAssertEqual(bus.emittedEvents.map(\.eventType)
            .last(where: { $0 == "timer_system_schedule_failed_un_fallback" }),
            "timer_system_schedule_failed_un_fallback")
    }

    func testBothDeniedIsPermissionDeniedAndNothingStored() async {
        alarmKit.authorization = .denied
        unCenter.authorizationGranted = false
        let service = makeService()

        let outcome = await service.startTimer(durationSeconds: 60, label: nil)

        XCTAssertEqual(outcome, .permissionDenied)
        XCTAssertTrue(service.timers.isEmpty)
        XCTAssertTrue(alarmKit.scheduled.isEmpty)
        XCTAssertTrue(unCenter.addedRequests.isEmpty)
    }

    func testNotificationDeniedButAlarmKitAuthorizedStillWorks() async {
        // The timer behaves like a real alarm even when notifications are
        // off — the system-managed path is independent of UN permission.
        alarmKit.authorization = .authorized
        unCenter.authorizationGranted = false
        let service = makeService()

        let outcome = await service.startTimer(durationSeconds: 60, label: nil)

        XCTAssertEqual(outcome, .scheduled)
        XCTAssertEqual(alarmKit.scheduled.count, 1)
    }

    // MARK: - Timer notification content (UN fallback path)

    func testUNFallbackTimerNotificationIsTimeSensitiveWithPayload() async {
        alarmKit.authorization = .denied
        let service = makeService()
        _ = await service.startTimer(durationSeconds: 60, label: "औषधि")

        let request = unCenter.addedRequests[0]
        XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(request.content.userInfo["kind"] as? String, "timer")
        XCTAssertEqual(request.content.body, "औषधि")
    }

    // MARK: - Cancel + reconciliation

    func testCancelTimerCancelsSystemTimerWhenTracked() async {
        alarmKit.authorization = .authorized
        let service = makeService()
        _ = await service.startTimer(durationSeconds: 300, label: nil)
        let id = service.timers[0].id

        service.cancelTimer(id: id)

        XCTAssertEqual(alarmKit.cancelledIDs, [id])
        XCTAssertTrue(service.timers.isEmpty)
    }

    func testScheduleAllSkipsSystemManagedTimersAndExpiresDismissedOnes() async {
        alarmKit.authorization = .authorized
        let service = makeService()
        _ = await service.startTimer(durationSeconds: 300, label: nil)
        let id = service.timers[0].id
        unCenter.addedRequests.removeAll()

        // Re-arm with the system still managing it: nothing UN-armed.
        service.scheduleAll()
        XCTAssertTrue(unCenter.addedRequests.isEmpty)
        XCTAssertTrue(service.activeTimers.contains(where: { $0.id == id }))

        // The system no longer lists it (dismissed from the system UI):
        // the next re-arm mirrors the system — the row expires.
        alarmKit.reportedSystemIDs = []
        service.scheduleAll()
        XCTAssertFalse(service.activeTimers.contains(where: { $0.id == id }))
    }

    func testNoteSystemTimerUpdatesExpiresDismissedSystemTimer() async {
        alarmKit.authorization = .authorized
        let service = makeService()
        _ = await service.startTimer(durationSeconds: 300, label: nil)
        let id = service.timers[0].id

        service.noteSystemTimerUpdates(systemTimerIDs: [])

        XCTAssertFalse(service.activeTimers.contains(where: { $0.id == id }))
    }

    func testPruneKeepsRecentlyEndedRowForTapGrace() {
        // A timer that ended 2 minutes ago survives the prune for the
        // tap grace window — the delivered notification stays tappable
        // and must be able to route into the ringing screen.
        let endedRecently = TimerItem(endsAt: nowDate.addingTimeInterval(-120))
        XCTAssertTrue(AlarmTimersStore(storage: storage).saveTimers([endedRecently]))
        let service = makeService()
        service.restorePersistedState()

        service.pruneFinishedTimers()

        XCTAssertTrue(service.timers.contains(where: { $0.id == endedRecently.id }))
        // Past-deadline rows never render as live countdowns.
        XCTAssertTrue(service.activeTimers.isEmpty)
    }

    func testCancelPendingNotificationRemovesOnlyUNRequest() async {
        alarmKit.authorization = .denied
        let service = makeService()
        _ = await service.startTimer(durationSeconds: 60, label: nil)
        let id = service.timers[0].id

        service.cancelPendingNotification(id: id)

        XCTAssertEqual(unCenter.removedIdentifiers, [AlarmScheduler.timerRequestID(id)])
        // The row survives — the in-app engine owns the foreground ring.
        XCTAssertEqual(service.timers.count, 1)
    }
}
