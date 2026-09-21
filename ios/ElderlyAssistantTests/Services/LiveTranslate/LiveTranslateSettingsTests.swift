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
        settings().setGeminiCloudEnabled(true)
        // The feature's own master switch is persisted like the other two, and
        // it is a boolean too: this walk is what keeps the feature's namespace
        // to booleans and nothing else.
        settings().setLiveTranslateEnabled(true)
        // [DEBUG-LOG] The diagnostic switch is persisted like the two
        // preferences, and it is a boolean too: this walk is what keeps the
        // feature's namespace to booleans and nothing else.
        settings().setTranslationDebugLoggingEnabled(true)

        let featureKeys = featureScopedEntries().map(\.key)
        XCTAssertEqual(Set(featureKeys), LiveTranslateSettings.featureKeys,
                       "an extra feature key in UserDefaults is a new persisted surface")

        for key in LiveTranslateSettings.featureKeys {
            XCTAssertTrue(defaults.object(forKey: key) is Bool,
                          "\(key)'s value is the boolean preference")
        }

        for entry in featureScopedEntries() {
            XCTAssertFalse(entry.value is String,
                           "\(entry.key) holds a string — no user content belongs in this store")
        }
    }

    // MARK: The [DEBUG-LOG] diagnostic switch (review finding on #99)

    /// The switch reads the config's **nominal default** until someone turns it
    /// on or off, and the absent key reads that default rather than a value
    /// nobody chose — the same rule the other two preferences follow.
    ///
    /// [SANITISED-DEBUG-LANE] (owner decision, 2026-09-20) The nominal default
    /// is **on**. The owner's directive of 2026-09-20 turned it back on so a
    /// fresh device build logs without a scheme edit, and the safety that used
    /// to live in the default now lives in the route: the lane's readers are
    /// `#if DEBUG`-only and every string the lane carries is redacted by
    /// `LogSanitiser` before a sink sees it, so no shipped build writes
    /// anything on account of this value, either way round.
    func testTheDiagnosticSwitchFollowsTheNominalDefaultUntilSomeoneChooses() {
        XCTAssertTrue(settings().translationDebugLoggingEnabled,
                      "nothing stored: the config's nominal default answers")
        XCTAssertTrue(LiveTranslateConfig.default.translationDebugLoggingEnabled,
                      "the owner's 2026-09-20 directive put the nominal default back on")
        XCTAssertNil(defaults.object(forKey: LiveTranslateSettings.translationDebugLoggingEnabledKey),
                     "reading the default must not write a value nobody chose")
    }

    func testTheDiagnosticSwitchRoundTripsAcrossASimulatedRelaunch() {
        settings().setTranslationDebugLoggingEnabled(true)
        XCTAssertTrue(settings().translationDebugLoggingEnabled)

        // A relaunch: fresh settings over the same store.
        XCTAssertTrue(settings().translationDebugLoggingEnabled,
                      "the switch survives the process, which is the point of "
                      + "persisting it — a capture cannot wait for a rebuild")

        settings().setTranslationDebugLoggingEnabled(false)
        XCTAssertFalse(settings().translationDebugLoggingEnabled)
        XCTAssertEqual(defaults.object(forKey: LiveTranslateSettings.translationDebugLoggingEnabledKey)
                        as? Bool,
                       false)
    }

    /// The switch reaches the tiers by exactly one route: the config the
    /// session runs with, built by `applyingDebugLogging(to:)`. Nothing else
    /// about the config moves with it.
    func testTheSwitchReachesTheSessionThroughTheConfigAndMovesNothingElse() {
        var config = LiveTranslateConfig.default
        config.geminiCloudEnabledDefault = false

        settings().setTranslationDebugLoggingEnabled(true)
        let resolved = settings().applyingDebugLogging(to: config)

        XCTAssertTrue(resolved.translationDebugLoggingEnabled,
                      "the live session's config carries the persisted switch")
        XCTAssertEqual(resolved.geminiCloudEnabledDefault, config.geminiCloudEnabledDefault,
                       "the diagnostic is not an egress switch and cannot move one")
        XCTAssertEqual(resolved.brainTranslationModelIDs, config.brainTranslationModelIDs,
                       "nor does it choose a model")
        XCTAssertEqual(resolved.cacheGeneralEntryLimit, config.cacheGeneralEntryLimit,
                       "nor does it change what is stored")

        // And the other direction: nothing else about the store moves it.
        settings().setAlwaysShowOriginal(true)
        XCTAssertTrue(settings().applyingDebugLogging(to: config).translationDebugLoggingEnabled,
                      "the display preference does not turn the diagnostic off")
    }

    /// The switch had **no production writer**: the only thing that ever turned
    /// it on was a test's own `setTranslationDebugLoggingEnabled(true)`, so the
    /// [DEBUG-LOG] diagnostic the whole feature was built around could not be
    /// enabled on a device at all. The launch argument is the writer.
    func testTheLaunchArgumentIsAProductionWriterForTheDiagnosticSwitch() {
        // The argument's job is not to change the effective value — the
        // nominal default is already on (2026-09-20) — but to make the value
        // *chosen*, which is what carries it into the session's config.
        XCTAssertNil(settings().chosenDebugLogging,
                     "with nothing stored and no argument, nobody has chosen")
        XCTAssertTrue(settings().translationDebugLoggingEnabled,
                      "the effective value is the config's nominal default")

        let launched = LiveTranslateSettings(defaults: defaults,
                                             config: .default,
                                             launchArguments: ["-liveTranslateDebugLogging"])
        XCTAssertTrue(launched.translationDebugLoggingEnabled,
                      "a launch argument is how a shipped build gets the diagnostic")
        XCTAssertEqual(launched.chosenDebugLogging, true,
                       "and it reads as *chosen*, so it reaches the session's config")
        XCTAssertTrue(launched.applyingDebugLogging(to: .default).translationDebugLoggingEnabled)
    }

    /// A persisted choice outranks the launch argument, in both directions: a
    /// household (or a support call) that turned the diagnostic off does not
    /// get it back because a developer left the flag on the scheme, and the
    /// argument cannot turn it off either.
    func testAPersistedChoiceOutranksTheLaunchArgument() {
        defaults.set(false, forKey: LiveTranslateSettings.translationDebugLoggingEnabledKey)
        let off = LiveTranslateSettings(defaults: defaults,
                                        config: .default,
                                        launchArguments: ["-liveTranslateDebugLogging"])
        XCTAssertFalse(off.translationDebugLoggingEnabled,
                       "an explicit off is a choice, and a choice outranks an argument")

        defaults.set(true, forKey: LiveTranslateSettings.translationDebugLoggingEnabledKey)
        let on = LiveTranslateSettings(defaults: defaults, config: .default, launchArguments: [])
        XCTAssertTrue(on.translationDebugLoggingEnabled)
    }

    /// `applyingDebugLogging` used to write the config's nominal default over
    /// the caller's value (`resolved.translationDebugLoggingEnabled =
    /// translationDebugLoggingEnabled`, which is `chosen ?? config.default`),
    /// so a caller that had deliberately switched the diagnostic **on** in the
    /// config it built had it silently switched off. Nothing chosen means the
    /// config is left exactly as it came in.
    func testApplyingDebugLoggingLeavesACallersOwnChoiceAlone() {
        var config = LiveTranslateConfig.default
        config.translationDebugLoggingEnabled = true

        let untouched = settings().applyingDebugLogging(to: config)

        XCTAssertTrue(untouched.translationDebugLoggingEnabled,
                      "no stored choice and no argument: the caller's config is untouched")
        XCTAssertEqual(untouched.translationDebugLoggingEnabled,
                       config.translationDebugLoggingEnabled)
    }

    // MARK: The cloud tier's master switch (owner directive, 2026-09-19)

    /// The directive's requirement, at the store: a household that has never
    /// touched the switch has **not** opted in. The absent key reads the
    /// config's nominal default — `false` — rather than `false` by accident,
    /// which is the assertion immediately below it.
    func testTheCloudSwitchIsOffUntilSomeoneTurnsItOn() {
        XCTAssertFalse(settings().geminiCloudEnabled,
                       "the cloud tier must not cascade unless a household opts in")
        XCTAssertEqual(settings().geminiCloudEnabled,
                       LiveTranslateConfig.default.geminiCloudEnabledDefault,
                       "an unset switch reads the config, not a second literal")
        XCTAssertFalse(LiveTranslateConfig.default.geminiCloudEnabledDefault,
                       "the nominal default is off — the owner's directive, 2026-09-19")
    }

    func testTheCloudSwitchesDefaultComesFromTheConfigNotASecondLiteral() {
        var config = LiveTranslateConfig.default
        config.geminiCloudEnabledDefault = true
        XCTAssertTrue(settings(config: config).geminiCloudEnabled,
                      "an unset switch must follow the injected config's nominal default")
    }

    func testTheCloudSwitchRoundTripsAcrossASimulatedRelaunch() {
        settings().setGeminiCloudEnabled(true)
        XCTAssertTrue(settings().geminiCloudEnabled, "the opt-in survives a relaunch")

        settings().setGeminiCloudEnabled(false)
        XCTAssertFalse(settings().geminiCloudEnabled,
                       "opting back out persists too — the directive is that off is the resting state")
    }

    /// Same no-cache property the display preference has: the next read — the
    /// next session, the next frame of the Settings leaf — sees the write, so
    /// no surface can hold a switch value that disagrees with the store.
    func testTheCloudSwitchChangeIsVisibleOnTheNextReadWithNoRestart() {
        let live = settings()
        XCTAssertFalse(live.geminiCloudEnabled)
        live.geminiCloudEnabled = true
        XCTAssertTrue(live.geminiCloudEnabled,
                      "a cached value here would make the switch need a restart")
    }

    func testTheCloudSwitchIsReachableThroughTheDeclaredKeyAlone() {
        defaults.set(true, forKey: LiveTranslateSettings.geminiCloudEnabledKey)
        XCTAssertTrue(settings().geminiCloudEnabled,
                      "the switch is reachable by its declared key, not only through the setter")
        XCTAssertEqual(LiveTranslateSettings.geminiCloudEnabledKey,
                       "livetranslate.geminiCloudEnabled")
    }

    /// The switch and the display preference are two independent settings:
    /// writing one must not move the other, or the Settings leaf and the
    /// overlay would disagree about which of them was changed.
    func testTheCloudSwitchAndTheDisplayPreferenceDoNotMoveEachOther() {
        let live = settings()
        live.setGeminiCloudEnabled(true)
        XCTAssertFalse(live.alwaysShowOriginal)
        live.setAlwaysShowOriginal(true)
        XCTAssertTrue(live.geminiCloudEnabled)

        live.setGeminiCloudEnabled(false)
        XCTAssertTrue(live.alwaysShowOriginal, "opting out of the cloud leaves the display preference alone")
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

    // MARK: The feature's master switch (owner directive, 2026-09-21)

    /// The directive's requirement, at the store: a household that has never
    /// touched the switch has **not** opted in. The absent key reads the
    /// config's nominal default — `false` — rather than `false` by accident,
    /// which is the assertion immediately below it.
    func testTheFeatureSwitchIsOffUntilSomeoneTurnsItOn() {
        XCTAssertFalse(settings().liveTranslateEnabled,
                       "the feature must not turn itself on")
        XCTAssertEqual(settings().liveTranslateEnabled,
                       LiveTranslateConfig.default.liveTranslateEnabledDefault,
                       "an unset switch reads the config, not a second literal")
        XCTAssertFalse(LiveTranslateConfig.default.liveTranslateEnabledDefault,
                       "the nominal default is off — the owner's directive, 2026-09-21")
        XCTAssertNil(defaults.object(forKey: LiveTranslateSettings.liveTranslateEnabledKey),
                     "reading the default must not write a value nobody chose")
    }

    func testTheFeatureSwitchesDefaultComesFromTheConfigNotASecondLiteral() {
        var config = LiveTranslateConfig.default
        config.liveTranslateEnabledDefault = true
        XCTAssertTrue(settings(config: config).liveTranslateEnabled,
                      "an unset switch must follow the injected config's nominal default")
    }

    func testTheFeatureSwitchRoundTripsAcrossASimulatedRelaunch() {
        settings().setLiveTranslateEnabled(true)
        XCTAssertTrue(settings().liveTranslateEnabled, "the opt-in survives a relaunch")

        settings().setLiveTranslateEnabled(false)
        XCTAssertFalse(settings().liveTranslateEnabled,
                       "opting back out persists too — off is the resting state")
        XCTAssertEqual(defaults.object(forKey: LiveTranslateSettings.liveTranslateEnabledKey)
                        as? Bool,
                       false)
    }

    /// Same no-cache property the other preferences have: the next read — the
    /// next session, the next frame of the Settings leaf — sees the write, so
    /// no surface can hold a switch value that disagrees with the store.
    func testTheFeatureSwitchChangeIsVisibleOnTheNextReadWithNoRestart() {
        let live = settings()
        XCTAssertFalse(live.liveTranslateEnabled)
        live.liveTranslateEnabled = true
        XCTAssertTrue(live.liveTranslateEnabled,
                      "a cached value here would make the switch need a restart")
    }

    func testTheFeatureSwitchIsReachableThroughTheDeclaredKeyAlone() {
        defaults.set(true, forKey: LiveTranslateSettings.liveTranslateEnabledKey)
        XCTAssertTrue(settings().liveTranslateEnabled,
                      "the switch is reachable by its declared key, not only through the setter")
        XCTAssertEqual(LiveTranslateSettings.liveTranslateEnabledKey, "livetranslate.enabled")
    }

    /// Three independent switches. The feature's master switch is not the cloud
    /// switch and not the display preference: writing one must not move
    /// another, or the Settings leaf would show a change the elder did not make.
    func testTheFeatureSwitchMovesNeitherTheCloudSwitchNorTheDisplayPreference() {
        let live = settings()
        live.setLiveTranslateEnabled(true)
        XCTAssertFalse(live.geminiCloudEnabled,
                       "turning the feature on is not opting into egress")
        XCTAssertFalse(live.alwaysShowOriginal,
                       "nor is it a display preference")

        live.setGeminiCloudEnabled(true)
        XCTAssertTrue(live.liveTranslateEnabled,
                      "opting into the cloud leaves the feature switch alone")
        live.setAlwaysShowOriginal(true)
        XCTAssertTrue(live.liveTranslateEnabled)
    }

    // MARK: Disclosure stamp

    func testTheDisclosureVersionIsTheConfigsStamp() {
        var config = LiveTranslateConfig.default
        config.disclosureVersion = "livetranslate.disclosure.test.stamp"
        XCTAssertEqual(settings(config: config).disclosureVersion, config.disclosureVersion)
    }
}
