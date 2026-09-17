import XCTest
@testable import ElderlyAssistant

/// T-001 — the always-show-original preference persists without a restart,
/// takes effect on the next read, and the store carries no user content
/// (FR-LCT-017, OD2).
final class LiveTranslateSettingsTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "livetranslate.settings.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func settings(config: LiveTranslateConfig = .default) -> LiveTranslateSettings {
        LiveTranslateSettings(defaults: defaults, config: config)
    }

    // MARK: Scenario: the setting has a documented default

    func testUnsetPreferenceReadsTheDesignsNominalDefault() {
        XCTAssertFalse(settings().alwaysShowOriginal,
                       "the design's nominal default is false (smart mix on, OD2)")
        XCTAssertFalse(settings().alwaysShowOriginal)
    }

    func testTheDefaultComesFromTheConfigNotASecondLiteral() {
        var config = LiveTranslateConfig.default
        config.alwaysShowOriginalDefault = true
        XCTAssertTrue(settings(config: config).alwaysShowOriginal,
                      "an unset preference must follow the injected config's nominal default")
    }

    // MARK: Scenario: the setting persists without a restart

    func testPreferenceRoundTripsAcrossASimulatedRelaunch() {
        settings().setAlwaysShowOriginal(true)
        // A fresh settings value over the same store is what a relaunch
        // produces: no shared in-memory state is involved.
        XCTAssertTrue(settings().alwaysShowOriginal)
    }

    func testTurningThePreferenceBackOffAlsoPersists() {
        settings().setAlwaysShowOriginal(true)
        settings().setAlwaysShowOriginal(false)
        XCTAssertFalse(settings().alwaysShowOriginal)
    }

    /// "Takes effect on the next rendered frame, without restarting the
    /// session": the read is not cached, so the next read — the overlay's
    /// next render — sees the new value.
    func testTheChangeIsVisibleOnTheNextReadWithNoRestart() {
        let live = settings()
        XCTAssertFalse(live.alwaysShowOriginal)
        live.alwaysShowOriginal = true
        XCTAssertTrue(live.alwaysShowOriginal,
                      "a cached value here would make the toggle need a restart")
    }

    // MARK: Both write paths (touch control and voice command) agree

    /// T-022's consistency requirement: the touch control (T-022) and the
    /// `set-show-original` voice command (T-023) write the same setting, so
    /// the two cannot disagree. Both paths are exercised here through the
    /// same store, and a second reader sees each write.
    func testTouchControlAndVoiceCommandWriteTheSameSetting() {
        settings().setAlwaysShowOriginal(true)          // touch control
        XCTAssertTrue(settings().alwaysShowOriginal, "voice/touch reader disagrees with the touch write")

        settings().toggleAlwaysShowOriginal()           // voice command
        XCTAssertFalse(settings().alwaysShowOriginal, "voice/touch reader disagrees with the voice write")

        XCTAssertEqual(defaults.object(forKey: LiveTranslateSettings.alwaysShowOriginalKey) as? Bool,
                       false,
                       "both paths must write the one declared key")
    }

    func testTheToggleIsReachableThroughTheDeclaredKeyAlone() {
        defaults.set(true, forKey: LiveTranslateSettings.alwaysShowOriginalKey)
        XCTAssertTrue(settings().alwaysShowOriginal,
                      "the preference is reachable by its declared key, not only through the setter")
    }

    // MARK: Scenario: the settings store carries no user content

    /// The persisted store holds the boolean and nothing else — no recognized
    /// text, no translation, no consent state. The encrypted file channel is
    /// where content-bearing payloads live (C05/C09); this store must stay a
    /// UI preference.
    func testThePersistedStoreCarriesOnlyTheBooleanPreference() {
        settings().setAlwaysShowOriginal(true)

        let featureKeys = featureScopedEntries().map(\.key)
        XCTAssertEqual(Set(featureKeys), LiveTranslateSettings.featureKeys,
                       "an extra feature key in UserDefaults is a new persisted surface")

        let stored = defaults.object(forKey: LiveTranslateSettings.alwaysShowOriginalKey)
        XCTAssertTrue(stored is Bool, "the only feature value is the boolean preference")

        for entry in featureScopedEntries() {
            XCTAssertFalse(entry.value is String,
                           "\(entry.key) holds a string — no user content belongs in this store")
        }
    }

    /// Every entry in the store under the feature's prefix. `dictionaryRepresentation`
    /// keys are `AnyHashable`, so they are narrowed to `String` explicitly
    /// rather than relied on to compare as one.
    private func featureScopedEntries() -> [(key: String, value: Any)] {
        defaults.dictionaryRepresentation().compactMap { key, value in
            guard let name = key as? String, name.hasPrefix(LiveTranslateSettings.featureKeyPrefix) else {
                return nil
            }
            return (name, value)
        }
    }

    // MARK: Disclosure stamp

    func testTheDisclosureVersionIsTheConfigsStamp() {
        var config = LiveTranslateConfig.default
        config.disclosureVersion = "livetranslate.disclosure.test.stamp"
        XCTAssertEqual(settings(config: config).disclosureVersion, config.disclosureVersion)
    }
}
