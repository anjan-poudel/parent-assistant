import XCTest
import UserNotifications
@testable import ElderlyAssistant

/// [BOOT-M1M2] Structural guard for the constant-time startup contract:
/// NONE of the three M2 stores may perform storage IO in `init` — every
/// keychain read was moved off the init path onto the coordinator's boot
/// queue via `start()`.
///
/// Spy = `MockEncryptedLocalStorage` (the module-wide double from
/// MedicationSchedulerTests, counts every read/write). The ONLY
/// production storage implementation is the Keychain
/// (`KeychainEncryptedStorage`), so zero storage calls in init ⟺ zero
/// `SecItemCopyMatching`/`SecItemAdd` in init — the design's structural
/// assertion, per store.
///
/// AppCoordinator itself is NOT constructed here: full construction is
/// hazardous in the unit suite (AVAudioEngine/ModelStore/APNs — the
/// existing store-level seam doctrine), and none of the three stores
/// touch FileManager, so the FileManager create-directory assertion is
/// vacuous for them. The per-store seams assert the same property the
/// design requires: constructing a store performs zero IO, and the
/// deferred load restores exactly what init used to.
@MainActor
final class NoIOInInitTests: XCTestCase {

    private var spy: MockEncryptedLocalStorage!
    private var bus: MockObservabilityBus!

    override func setUp() {
        super.setUp()
        spy = MockEncryptedLocalStorage()
        bus = MockObservabilityBus()
    }

    // MARK: - Zero IO in init (the structural guard)

    func testGeminiConfigStoreInitPerformsNoStorageIO() {
        // A persisted value that init MUST NOT read.
        GeminiConfigStore(storage: spy).save("old-key")
        let ioBefore = (reads: spy.readCallCount, writes: spy.writeCallCount)

        let store = GeminiConfigStore(storage: spy)

        XCTAssertNil(store.apiKey, "init must start unloaded")
        XCTAssertEqual(store.model, GeminiConfigStore.defaultModel)
        XCTAssertEqual(spy.readCallCount, ioBefore.reads,
                       "GeminiConfigStore.init performed a keychain read")
        XCTAssertEqual(spy.writeCallCount, ioBefore.writes,
                       "GeminiConfigStore.init performed a keychain write")
    }

    func testAlarmTimersServiceInitPerformsNoStorageIO() {
        let alarmStore = AlarmTimersStore(storage: spy)
        _ = alarmStore.saveAlarms([Alarm(time: Date(), label: "wake")])
        let ioBefore = (reads: spy.readCallCount, writes: spy.writeCallCount)

        let service = AlarmTimersService(
            store: alarmStore,
            scheduler: AlarmScheduler(notifications: SilentNotificationCenter()),
            observabilityBus: bus
        )

        XCTAssertTrue(service.alarms.isEmpty, "init must start unloaded")
        XCTAssertTrue(service.timers.isEmpty, "init must start unloaded")
        XCTAssertEqual(spy.readCallCount, ioBefore.reads,
                       "AlarmTimersService.init performed a storage read")
        XCTAssertEqual(spy.writeCallCount, ioBefore.writes,
                       "AlarmTimersService.init performed a storage write")
    }

    func testRoutineStoreInitPerformsNoStorageIO() {
        let ioBefore = (reads: spy.readCallCount, writes: spy.writeCallCount)

        _ = RoutineStore(storage: spy)

        XCTAssertEqual(spy.readCallCount, ioBefore.reads,
                       "RoutineStore.init performed a storage read")
        XCTAssertEqual(spy.writeCallCount, ioBefore.writes,
                       "RoutineStore.init performed a storage write")
    }

    // MARK: - The deferred load restores what init used to (per store)

    func testGeminiDeferredLoadRestoresStoredValuesOffInit() {
        GeminiConfigStore(storage: spy).save("persisted-key")
        let reloaded = GeminiConfigStore(storage: spy)
        XCTAssertNil(reloaded.apiKey, "nothing may load in init")

        let loaded = expectation(description: "deferred gemini load")
        reloaded.loadPersistedValues(on: DispatchQueue(label: "test.gemini.boot"),
                                     completion: { loaded.fulfill() })
        wait(for: [loaded], timeout: 1)

        XCTAssertEqual(reloaded.apiKey, "persisted-key")
    }

    func testAlarmTimersDeferredRestoreLoadsBeforeRearmingSoStoredRowsSurvive() {
        // The hazard the design guards: `scheduleAll()` prunes the
        // in-memory timer list AND persists the prune. If the re-arm ran
        // against an unloaded (empty) list, the stored rows would be
        // WIPED. The restore must therefore load first, then arm.
        let alarmStore = AlarmTimersStore(storage: spy)
        let wake = Alarm(time: date(2026, 9, 10, 6, 0), label: "wake")
        let finished = TimerItem(endsAt: date(2026, 9, 9, 8, 0), label: "tea",
                                 isActive: false)
        XCTAssertTrue(alarmStore.saveAlarms([wake]))
        XCTAssertTrue(alarmStore.saveTimers([finished]))

        let center = RecordingNotifications()
        let service = AlarmTimersService(
            store: alarmStore,
            scheduler: AlarmScheduler(notifications: center),
            observabilityBus: bus,
            now: { self.date(2026, 9, 10, 10, 0) }
        )
        XCTAssertTrue(service.alarms.isEmpty)
        XCTAssertTrue(service.timers.isEmpty)

        let restored = expectation(description: "restore + re-arm completed")
        service.restoreAndScheduleAll { restored.fulfill() }
        wait(for: [restored], timeout: 1)

        // The alarm survived the sweep and is re-armed...
        XCTAssertEqual(service.alarms, [wake])
        XCTAssertEqual(center.addedRequests.map(\.identifier),
                       [AlarmScheduler.alarmRequestID(wake.id)])
        // ...the finished timer was pruned and the prune persisted...
        XCTAssertTrue(service.timers.isEmpty)
        XCTAssertTrue(alarmStore.loadTimers().isEmpty)
        // ...and the alarm row is still in the store (nothing wiped).
        XCTAssertEqual(alarmStore.loadAlarms(), [wake])
    }

    // MARK: - Helpers

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }
}

/// Minimal `LocalNotificationScheduling` recording double — records every
/// armed request (the same shape as the double in AlarmTimersServiceTests;
/// that one is file-private, so the structural-guard suite carries its own).
private final class RecordingNotifications: LocalNotificationScheduling {
    private(set) var addedRequests: [UNNotificationRequest] = []

    func requestAuthorization() async -> Bool { true }

    func add(_ request: UNNotificationRequest, completion: ((Error?) -> Void)? = nil) {
        addedRequests.append(request)
        completion?(nil)
    }

    func removePendingNotifications(withIdentifiers identifiers: [String]) {}
}

/// Grants nothing and records nothing — construction-only placeholder for
/// the init-IO guard (no request may be armed during init anyway).
private final class SilentNotificationCenter: LocalNotificationScheduling {
    func requestAuthorization() async -> Bool { false }

    func add(_ request: UNNotificationRequest, completion: ((Error?) -> Void)? = nil) {
        completion?(nil)
    }

    func removePendingNotifications(withIdentifiers identifiers: [String]) {}
}
