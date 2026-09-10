import XCTest
import UserNotifications
import AlarmKit
@testable import ElderlyAssistant

// MARK: - Recording system-alarm-manager fake (NEUTRAL — no AlarmKit)

/// [ALARMKIT-ALARMS] (2026-09-11) Scriptable `SystemAlarmManaging` fake.
/// Deliberately conforms to the NEUTRAL seam protocol, not to any
/// AlarmKit-typed protocol: a test-bundle type conforming to an
/// iOS-26-only protocol crashes the test runner on older runtimes at
/// TYPE METADATA COMPLETION (reproduced on an iOS 18.3 simulator —
/// "test runner crashed ... at type metadata completion function for
/// FakeAlarmKitManager"). With the neutral seam this file carries no
/// AlarmKit symbol in any declaration, so nothing can crash pre-26.
///
/// The fake captures the schedule COMPONENTS (id, hour, minute,
/// snoozeMinutes, pre-localized title/snooze label) — testable here
/// precisely because `AlarmManager.AlarmConfiguration` exposes no stored
/// properties (SDK swiftinterface shows init + static factories only)
/// and the production adapter builds the real configuration.
final class FakeSystemAlarmManager: SystemAlarmManaging {
    var alarmAuthorizationStatus: AlarmAuthorizationStatus = .authorized
    var authorizationRequestCount = 0
    var requestResult: AlarmAuthorizationStatus = .authorized
    var scheduleError: Error?
    var countdownError: Error?
    private(set) var scheduled: [(id: UUID, hour: Int, minute: Int,
                                  snoozeMinutes: Int, title: String, snoozeLabel: String)] = []
    private(set) var cancelledIDs: [UUID] = []
    private(set) var countdownIDs: [UUID] = []

    func requestSystemAlarmAuthorization() async -> AlarmAuthorizationStatus {
        authorizationRequestCount += 1
        // The real manager's authorizationState reflects the resolved
        // status after the ask — the fake mirrors that.
        alarmAuthorizationStatus = requestResult
        return requestResult
    }

    func scheduleSystemAlarm(id: UUID, hour: Int, minute: Int,
                             snoozeMinutes: Int,
                             title: String, snoozeLabel: String) async throws {
        if let scheduleError { throw scheduleError }
        scheduled.append((id, hour, minute, snoozeMinutes, title, snoozeLabel))
    }

    func cancelSystemAlarm(id: UUID) throws {
        cancelledIDs.append(id)
    }

    func countdownSystemAlarm(id: UUID) throws {
        if let countdownError { throw countdownError }
        countdownIDs.append(id)
    }
}

/// [ALARMKIT-ALARMS] (2026-09-11) Recording `LocalNotificationScheduling`
/// fake (the one in AlarmTimersServiceTests is file-private).
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
/// fake system-alarm manager. The class is `@available(iOS 26.0, *)`
/// because `AlarmKitAlarmBackend` itself is iOS-26-gated (XCTest skips
/// the class on older runtimes) — but every DECLARATION in this file is
/// AlarmKit-free, so even a pre-26 metadata realization (integration
/// failure on iOS 18.3) cannot touch an unavailable symbol. The
/// seam/selection suites (`AlarmSchedulingBackendTests`) run everywhere.
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

    func testRequestAuthorizationNotDeterminedAsksAndReports() async {
        let manager = FakeSystemAlarmManager()
        manager.alarmAuthorizationStatus = .notDetermined
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
        let manager = FakeSystemAlarmManager()
        manager.alarmAuthorizationStatus = .denied
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center)

        let granted = await backend.requestAuthorizationIfNeeded()

        XCTAssertFalse(granted)
        XCTAssertEqual(manager.authorizationRequestCount, 0,
                       "a previous denial must never re-prompt")
        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(backend.authorizationStatus, .denied)
    }

    func testRequestAuthorizationResolvesDenialFromTheAsk() async {
        let manager = FakeSystemAlarmManager()
        manager.alarmAuthorizationStatus = .notDetermined
        manager.requestResult = .denied
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center)

        let granted = await backend.requestAuthorizationIfNeeded()

        XCTAssertFalse(granted)
        XCTAssertEqual(backend.authorizationStatus, .denied)
    }

    func testRequestAuthorizationAlreadyAuthorizedSkipsTheAsk() async {
        let manager = FakeSystemAlarmManager()
        manager.alarmAuthorizationStatus = .authorized
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center)

        let granted = await backend.requestAuthorizationIfNeeded()

        XCTAssertTrue(granted)
        XCTAssertEqual(manager.authorizationRequestCount, 0)
    }

    // MARK: - Arming

    func testScheduleArmsTheSystemAlarmWithTheAppAlarmIDAndTimeOfDay() async {
        let manager = FakeSystemAlarmManager()
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center,
                                           systemSnoozeMinutes: 10)
        let alarm = Alarm(time: date(2026, 9, 7, 6, 0))

        backend.scheduleAlarm(alarm)
        await backend.waitForPendingArms()

        // The SAME id the app persisted is the system alarm's id — the
        // AlarmKit list API (`AlarmManager.alarms`) stays reconcilable
        // with the app's own list by id. The time-of-day and the
        // postAlert snooze duration ride the seam as components.
        XCTAssertEqual(manager.scheduled.count, 1)
        XCTAssertEqual(manager.scheduled[0].id, alarm.id)
        XCTAssertEqual(manager.scheduled[0].hour, 6)
        XCTAssertEqual(manager.scheduled[0].minute, 0)
        XCTAssertEqual(manager.scheduled[0].snoozeMinutes, 10)
        XCTAssertEqual(manager.scheduled[0].title, "Alarm")
        XCTAssertEqual(manager.scheduled[0].snoozeLabel, "Snooze")
        XCTAssertTrue(center.addedRequests.isEmpty,
                      "no UN fallback when the system accepts")
    }

    func testSystemRefusalDegradesToTheUNDailyNotification() async throws {
        let manager = FakeSystemAlarmManager()
        manager.scheduleError = SystemAlarmScheduleError.refused
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center)
        let alarm = Alarm(time: date(2026, 9, 7, 6, 0))

        backend.scheduleAlarm(alarm)
        await backend.waitForPendingArms()

        // The system refused — the alarm still rings as the app's daily
        // notification (the pre-26 shape), never silently not at all.
        XCTAssertTrue(manager.scheduled.isEmpty)
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
        let manager = FakeSystemAlarmManager()
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center,
                                           systemSnoozeMinutes: 10)
        let alarmID = UUID()

        XCTAssertTrue(backend.snoozeViaSystem(id: alarmID, minutes: 10))
        XCTAssertEqual(manager.countdownIDs, [alarmID])

        XCTAssertFalse(backend.snoozeViaSystem(id: alarmID, minutes: 15),
                       "arbitrary minutes fall back to the app one-shot")
        XCTAssertEqual(manager.countdownIDs, [alarmID],
                       "no system call for the refused snooze")

        manager.countdownError = SystemAlarmScheduleError.refused
        XCTAssertFalse(backend.snoozeViaSystem(id: alarmID, minutes: 10),
                       "a system failure falls back too")
    }

    // MARK: - Cancel

    func testCancelRoutesToTheManager() {
        let manager = FakeSystemAlarmManager()
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
        let manager = FakeSystemAlarmManager()
        let backend = AlarmKitAlarmBackend(manager: manager, notifications: center)
        let alarmID = UUID()

        backend.cancelSnooze(id: alarmID)

        XCTAssertTrue(manager.cancelledIDs.isEmpty)
        XCTAssertTrue(center.removedIdentifiers.isEmpty)
    }
}

/// A throw-anything error for the fake's refusal scripting (no AlarmKit
/// types in the test bundle).
private enum SystemAlarmScheduleError: Error {
    case refused
}

// MARK: - Authorization-state mapping (iOS 26 runtime only)

/// [ALARMKIT-ALARMS] (2026-09-11) The one test that names AlarmKit enum
/// cases — in METHOD BODIES only. No declaration in this class is
/// AlarmKit-typed, so metadata completion is safe everywhere; the
/// `@available` gate makes XCTest skip it on pre-26 runtimes.
@available(iOS 26.0, *)
final class AlarmKitAuthorizationStateMappingTests: XCTestCase {

    func testAuthorizationStateMapping() {
        XCTAssertEqual(AlarmKitAlarmBackend.map(.notDetermined), .notDetermined)
        XCTAssertEqual(AlarmKitAlarmBackend.map(.denied), .denied)
        XCTAssertEqual(AlarmKitAlarmBackend.map(.authorized), .authorized)
    }
}
