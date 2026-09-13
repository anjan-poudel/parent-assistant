import XCTest
@testable import ElderlyAssistant

/// Per-event-type caregiver notification preferences (caregiver
/// event-notifications task, 2026-09-13). The load-bearing properties
/// are: defaults OFF (nobody is alerted until the elder opts in), the
/// three toggles are independent, and the choice persists.
final class CaregiverNotifySettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // A throwaway suite per test: the settings persist BY DESIGN, so
        // the process-wide standard defaults would leak a flipped toggle
        // from one test into the next.
        suiteName = "caregiverNotify.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeSettings() -> CaregiverNotifySettings {
        CaregiverNotifySettings(defaults: defaults)
    }

    // MARK: - Defaults

    /// The user decision, stated as a test: configure once, events of
    /// that type auto-notify — and nothing is shared until then.
    func testAllThreeTogglesDefaultToOff() {
        let settings = makeSettings()

        XCTAssertFalse(settings.medicationReminders)
        XCTAssertFalse(settings.routineReminders)
        XCTAssertFalse(settings.calendarEvents)
    }

    func testAllKindsDefaultToOffThroughTheLookup() {
        let settings = makeSettings()

        for kind in EventNotifyKind.allCases {
            XCTAssertFalse(settings.isEnabled(for: kind),
                           "\(kind.rawValue) must default OFF")
        }
    }

    // MARK: - Per-kind lookup

    /// `isEnabled(for:)` is the single lookup every fire site uses — it
    /// must read the toggle that belongs to the kind.
    func testEachKindReadsItsOwnToggle() {
        let settings = makeSettings()

        settings.medicationReminders = true
        XCTAssertTrue(settings.isEnabled(for: .medicationReminder))
        XCTAssertFalse(settings.isEnabled(for: .routineReminder))
        XCTAssertFalse(settings.isEnabled(for: .calendarEvent))

        settings.routineReminders = true
        XCTAssertTrue(settings.isEnabled(for: .routineReminder))

        settings.calendarEvents = true
        XCTAssertTrue(settings.isEnabled(for: .calendarEvent))
    }

    /// The three kinds are the three firing systems, and every one of
    /// them has a toggle — a kind added without a preference must break
    /// this test, not fall through a switch.
    func testKindSetMatchesTheFiringSystems() {
        XCTAssertEqual(Set(EventNotifyKind.allCases.map(\.rawValue)),
                       ["medicationReminder", "routineReminder", "calendarEvent"])
    }

    // MARK: - Persistence

    /// The choice survives a relaunch: a fresh instance over the same
    /// defaults reads back what the elder set (the fire sites construct
    /// no state of their own — this is the ONLY place the choice lives).
    func testTogglesPersistAcrossInstances() {
        let first = makeSettings()
        first.medicationReminders = true
        first.calendarEvents = true

        let second = makeSettings()

        XCTAssertTrue(second.medicationReminders)
        XCTAssertTrue(second.calendarEvents)
        XCTAssertFalse(second.routineReminders, "an untouched toggle stays OFF")
    }

    func testTurningAToggleBackOffPersistsToo() {
        let first = makeSettings()
        first.routineReminders = true
        first.routineReminders = false

        XCTAssertFalse(makeSettings().routineReminders,
                       "flipping back must persist the OFF, not just skip the write")
    }

    // MARK: - Key namespacing

    /// The keys are namespaced so a Settings re-shuffle can never collide
    /// with another preference — and they are distinct from each other
    /// (a shared key would make two toggles move together).
    func testKeysAreNamespacedAndDistinct() {
        let keys = [CaregiverNotifySettings.medicationKey,
                    CaregiverNotifySettings.routineKey,
                    CaregiverNotifySettings.calendarKey]

        XCTAssertEqual(Set(keys).count, 3)
        for key in keys {
            XCTAssertTrue(key.hasPrefix("caregiverNotify."), "un-namespaced key: \(key)")
        }
    }

    /// The initializer reads the SAME keys the property observers write —
    /// proven by writing through one instance and reading the raw
    /// defaults, which is what a future migration would do.
    func testStoredValuesLandOnTheDocumentedKeys() {
        let settings = makeSettings()
        settings.medicationReminders = true

        XCTAssertTrue(defaults.bool(forKey: CaregiverNotifySettings.medicationKey))
        XCTAssertFalse(defaults.bool(forKey: CaregiverNotifySettings.routineKey))
        XCTAssertFalse(defaults.bool(forKey: CaregiverNotifySettings.calendarKey))
    }

    // MARK: - Test seam

    /// The `isolated()` helper the fire-site suites build on: a
    /// throwaway suite, so two instances never share state.
    func testIsolatedHelperProducesIndependentInstances() {
        let first = CaregiverNotifySettings.isolated(medication: true)
        let second = CaregiverNotifySettings.isolated()

        XCTAssertTrue(first.medicationReminders)
        XCTAssertFalse(second.medicationReminders,
                       "isolated() must not fall back to a shared suite")
    }
}
