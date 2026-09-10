import XCTest
import UserNotifications
import AlarmKit
@testable import ElderlyAssistant

// MARK: - Recording AlarmKit manager fake

/// [ALARMKIT-ALARMS] (2026-09-10) Scriptable `AlarmKitManaging` fake.
/// `AlarmManager` cannot be driven deterministically (system alarms are
/// real), and `AlarmManager.AlarmConfiguration` exposes NO stored
/// properties (SDK swiftinterface shows init + static factories only),
/// so these tests assert the OBSERVABLE contract: which alarms reach the
/// system, which cancellations/snoozes are issued, what the state
/// mapping resolves, and that a system refusal degrades to the UN arm.
@available(iOS 26.0, *)
private final class FakeAlarmKitManager: AlarmKitManaging {
    var state: AlarmManager.AuthorizationState = .authorized
    var authorizationRequestCount = 0
    var requestResult: AlarmManager.AuthorizationState = .authorized
    var scheduleError: Error?
    var countdownError: Error?
    private(set) var scheduledIDs: [UUID] = []
    private(set) var cancelledIDs: [UUID] = []
    private(set) var countdownIDs: [UUID] = []

    var authorizationState: AlarmManager.AuthorizationState { state }

    func requestAuthorization() async throws -> AlarmManager.AuthorizationState {
        authorizationRequestCount += 1
        // The real manager's authorizationState reflects the resolved
        // status after the ask — the fake mirrors that.
        state = requestResult
        return requestResult
    }

    func schedule(id: AlarmKit.Alarm.ID,
                  configuration: AlarmManager.AlarmConfiguration<AlarmKitMetadata>) async throws {
        if let scheduleError { throw scheduleError }
        scheduledIDs.append(id)
    }

    func cancel(id: AlarmKit.Alarm.ID) throws {
        cancelledIDs.append(id)
    }

    func countdown(id: AlarmKit.Alarm.ID) throws {
        if let countdownError { throw countdownError }
        countdownIDs.append(id)
    }
}

/// [ALARMKIT-ALARMS] (2026-09-10) Recording `LocalNotificationScheduling`
/// fake (the one in AlarmTimersServiceTests is file-private).
@available(iOS 26.0, *)
private final class RecordingAlarmKitNotificationCenter: LocalNotificationScheduling {
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

// MARK: - AlarmKit backend tests

/// [ALARMKIT-ALARMS] (2026-09-10) The AlarmKit backend's behavior with a
/// fake manager — runs ONLY on iOS 26 runtimes (the SDK types exist at
/// compile time; XCTest discovery skips this class below iOS 26).
@available(iOS 26.0, *)
@MainActor
final class AlarmKitAlarmBackendTests: XCTestCase {

    private var center: RecordingAlarmKitNotificationCenter!

    override func setUp() {
        super.setUp()
        center = RecordingAlarmKitNotificationCenter()
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    // MARK: - Authorization

    func testAuthorizationStateMapping() {
        XCTAssertEqual(AlarmKitAlarmBackend.map(.notDetermined), .notDetermined)
        XCTAssertEqual(AlarmKitAlarmBackend.map(.denied), .denied)
        XCTAssertEqual(AlarmKitAlarmBackend.map(.authorized), .authorized)
    }

    func testRequestAuthorizationNotDeterminedAsksAndReports() async {
        let manager = FakeAlarmKitManager()
        manager.state = .notDetermined
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center)

        let granted = await backend.requestAuthorizationIfNeeded()

        XCTAssertTrue(granted)
        XCTAssertEqual(manager.authorizationRequestCount, 1)
        // The UN ask rides along best-effort (snooze fallback + other
        // notification features) but never gates the system alarm.
        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(backend.authorizationStatus, .authorized)
    }

    func testRequestAuthorizationDeniedNeverReprompts() async {
        let manager = FakeAlarmKitManager()
        manager.state = .denied
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center)

        let granted = await backend.requestAuthorizationIfNeeded()

        XCTAssertFalse(granted)
        XCTAssertEqual(manager.authorizationRequestCount, 0,
                       "a previous denial must never re-prompt")
        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(backend.authorizationStatus, .denied)
    }

    func testRequestAuthorizationResolvesDenialFromTheAsk() async {
        let manager = FakeAlarmKitManager()
        manager.state = .notDetermined
        manager.requestResult = .denied
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center)

        let granted = await backend.requestAuthorizationIfNeeded()

        XCTAssertFalse(granted)
        XCTAssertEqual(backend.authorizationStatus, .denied)
    }

    func testRequestAuthorizationAlreadyAuthorizedSkipsTheAsk() async {
        let manager = FakeAlarmKitManager()
        manager.state = .authorized
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center)

        let granted = await backend.requestAuthorizationIfNeeded()

        XCTAssertTrue(granted)
        XCTAssertEqual(manager.authorizationRequestCount, 0)
    }

    // MARK: - Arming

    func testScheduleArmsTheSystemAlarmWithTheAppAlarmID() async {
        let manager = FakeAlarmKitManager()
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center)
        let alarm = Alarm(time: date(2026, 9, 7, 6, 0))

        backend.scheduleAlarm(alarm)
        await backend.waitForPendingArms()

        // The SAME id the app persisted is the system alarm's id — the
        // AlarmKit list API (`AlarmManager.alarms`) stays reconcilable
        // with the app's own list by id.
        XCTAssertEqual(manager.scheduledIDs, [alarm.id])
        XCTAssertTrue(center.addedRequests.isEmpty,
                      "no UN fallback when the system accepts")
    }

    func testSystemRefusalDegradesToTheUNDailyNotification() async throws {
        let manager = FakeAlarmKitManager()
        manager.scheduleError = AlarmManager.AlarmError.maximumLimitReached
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center)
        let alarm = Alarm(time: date(2026, 9, 7, 6, 0))

        backend.scheduleAlarm(alarm)
        await backend.waitForPendingArms()

        // The system refused — the alarm still rings as the app's daily
        // notification (the pre-26 shape), never silently not at all.
        XCTAssertEqual(center.addedRequests.count, 1)
        let request = try XCTUnwrap(center.addedRequests.first)
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(request.identifier, AlarmScheduler.alarmRequestID(alarm.id))
        XCTAssertTrue(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.hour, 6)
        XCTAssertEqual(trigger.dateComponents.minute, 0)
        XCTAssertEqual(request.content.userInfo["kind"] as? String, "alarm")
    }

    // MARK: - Snooze

    func testSnoozeViaSystemHonorsOnlyTheDefaultMinutes() {
        let manager = FakeAlarmKitManager()
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center,
                                           systemSnoozeMinutes: 10)
        let alarmID = UUID()

        XCTAssertTrue(backend.snoozeViaSystem(id: alarmID, minutes: 10))
        XCTAssertEqual(manager.countdownIDs, [alarmID])

        XCTAssertFalse(backend.snoozeViaSystem(id: alarmID, minutes: 15),
                       "arbitrary minutes fall back to the app one-shot")
        XCTAssertEqual(manager.countdownIDs, [alarmID],
                       "no system call for the refused snooze")

        manager.countdownError = AlarmManager.AlarmError.maximumLimitReached
        XCTAssertFalse(backend.snoozeViaSystem(id: alarmID, minutes: 10),
                       "a system failure falls back too")
    }

    // MARK: - Cancel

    func testCancelRoutesToTheManager() {
        let manager = FakeAlarmKitManager()
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center)
        let alarmID = UUID()

        backend.cancelAlarm(id: alarmID)

        XCTAssertEqual(manager.cancelledIDs, [alarmID])
    }

    func testCancelSnoozeIsANoOpSystemSide() {
        // The system snooze is a countdown PHASE of the alarm itself —
        // there is no separate system snooze to cancel; cancelling the
        // alarm kills its countdown. The backend's cancelSnooze must not
        // touch UN either (the system path armed no one-shot).
        let manager = FakeAlarmKitManager()
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center)
        let alarmID = UUID()

        backend.cancelSnooze(id: alarmID)

        XCTAssertTrue(manager.cancelledIDs.isEmpty)
        XCTAssertTrue(center.removedIdentifiers.isEmpty)
    }
}
