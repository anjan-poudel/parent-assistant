import XCTest
import Security
@testable import ElderlyAssistant

/// The reinstall guarantee ([SETTINGS-PERSIST], 2026-10-14): every
/// owner-facing preference must survive the elder deleting and
/// reinstalling the app, where iOS wipes the whole `UserDefaults`
/// domain by design.
///
/// The simulation is honest and whole: a scratch KEYCHAIN SERVICE per
/// test (so nothing touches the production items) plus a scratch
/// fallback SUITE. "A reinstall" is a NEW `SettingsPersistence` over
/// the SAME keychain service with a FRESH EMPTY fallback — exactly the
/// post-reinstall state (defaults domain gone, keychain items kept).
/// Anything such an instance can still read came from the keychain
/// alone.
///
/// The suite also pins the two reviewed LISTS the seam runs on — the
/// `backfillKeys` owner surface and the `neverMirroredKeys` secrets —
/// in both directions, because the failure modes are asymmetric and
/// both are bad: an owner setting missing from the list silently
/// vanishes on reinstall, and a secret added to it would land a
/// credential in a plist.
///
/// What the tests exercise keychain-ENABLED instances
/// (`SettingsPersistence.make(service:fallback:)`); under the test
/// runner `SettingsPersistence.shared` is a deliberate PASSTHROUGH
/// (see `testTheSharedInstanceStaysOnUserDefaultsUnderXCTest`) — that
/// is what keeps every coordinator suite that asserts on
/// `UserDefaults.standard` honest without edits, and what keeps test
/// junk out of the production keychain service.
final class SettingsPersistenceTests: XCTestCase {

    private var serviceName = ""
    private var fallback: UserDefaults!
    private var sut: SettingsPersistence!
    /// Every fallback suite this test created, so teardown can wipe the
    /// plists as well as the keychain items.
    private var fallbackSuiteNames: [String] = []

    override func setUp() {
        super.setUp()
        serviceName = "test.settings.\(UUID().uuidString)"
        fallback = makeSuite()
        sut = SettingsPersistence.make(service: serviceName, fallback: fallback)
    }

    override func tearDown() {
        sut.removeAllStoredItems()
        for suiteName in fallbackSuiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        fallbackSuiteNames = []
        sut = nil
        fallback = nil
        super.tearDown()
    }

    // MARK: - The reinstall guarantee

    /// The owner's literal complaint: a preference set before the
    /// reinstall is still there after it. String + bool + int, the
    /// types the household actually rekeys.
    func testAnOwnerFacingValueSurvivesAReinstall() {
        sut.set("messenger", forKey: "defaultCallApp")
        sut.set(true, forKey: "wakeWord.enabled")
        sut.set(150, forKey: "voice.outputVolumePercent")

        let reinstalled = seamAfterReinstall()
        XCTAssertEqual(reinstalled.string(forKey: "defaultCallApp"), "messenger")
        XCTAssertTrue(reinstalled.bool(forKey: "wakeWord.enabled"))
        XCTAssertEqual(reinstalled.integer(forKey: "voice.outputVolumePercent"), 150)
    }

    /// Every value type the listed keys use round-trips the reinstall,
    /// INCLUDING the `false` half of a bool: "false" is a stored value,
    /// not an absence, and the settings UI must be able to tell the two
    /// apart when it renders a switch.
    func testEveryListedValueTypeSurvivesAReinstall() {
        sut.set("en", forKey: "k.string")
        sut.set(false, forKey: "k.bool")
        sut.set(3, forKey: "k.int")
        sut.set(0.97, forKey: "k.double")
        sut.set(["maps", "phone"], forKey: "k.array")
        sut.set(Data([0x01, 0x02, 0x03]), forKey: "k.data")

        let reinstalled = seamAfterReinstall()
        XCTAssertEqual(reinstalled.string(forKey: "k.string"), "en")
        XCTAssertNotNil(reinstalled.object(forKey: "k.bool"),
                        "stored false must not read back as absent")
        XCTAssertFalse(reinstalled.bool(forKey: "k.bool"))
        XCTAssertEqual(reinstalled.integer(forKey: "k.int"), 3)
        XCTAssertEqual(reinstalled.double(forKey: "k.double"), 0.97, accuracy: 0.0001)
        XCTAssertEqual(reinstalled.stringArray(forKey: "k.array"), ["maps", "phone"])
        XCTAssertEqual(reinstalled.data(forKey: "k.data"), Data([0x01, 0x02, 0x03]))
        XCTAssertNil(reinstalled.object(forKey: "k.never.set"))
    }

    /// The dispatch the whole seam rests on: every store receives the
    /// seam through a `defaults: UserDefaults` PARAMETER, and the
    /// overrides must still run after that upcast (verified with a
    /// swiftc probe before adoption — pinned here so a future Swift
    /// change to UserDefaults subclass dispatch fails a test, not an
    /// elder's reinstall).
    func testTheSeamDispatchesThroughAUserDefaultsTypedParameter() {
        func readPick(_ store: UserDefaults) -> String? { store.string(forKey: "defaultCallApp") }

        sut.set("messenger", forKey: "defaultCallApp")
        XCTAssertEqual(readPick(sut), "messenger")
        XCTAssertEqual(readPick(seamAfterReinstall()), "messenger",
                       "an upcast seam must still record its value in the keychain")
    }

    // MARK: - Read precedence

    /// Once the keychain holds a key, the fallback copy is a cache —
    /// the keychain wins, cached AND uncached. A stale defaults value
    /// (an install that wrote through both stores at different times)
    /// must never shadow the durable record.
    func testTheKeychainWinsOverAStaleFallbackCopy() {
        sut.set("messenger", forKey: "defaultCallApp")
        fallback.set("whatsApp", forKey: "defaultCallApp")

        XCTAssertEqual(sut.string(forKey: "defaultCallApp"), "messenger",
                       "the cached read must serve the keychain value")

        let uncached = SettingsPersistence.make(service: serviceName, fallback: fallback)
        XCTAssertEqual(uncached.string(forKey: "defaultCallApp"), "messenger",
                       "an uncached read must ALSO prefer the keychain over the stale mirror")
    }

    /// The install that predates the seam: the value exists ONLY in
    /// `UserDefaults`, the keychain holds nothing, and reads must still
    /// work — until the first boot's backfill adopts it.
    func testALegacyFallbackValueIsStillRead() {
        fallback.set("ne-IN", forKey: "appLocale")
        fallback.set(true, forKey: "noiseFilterEnabled")

        XCTAssertEqual(sut.string(forKey: "appLocale"), "ne-IN")
        XCTAssertTrue(sut.bool(forKey: "noiseFilterEnabled"))
    }

    // MARK: - Removal

    /// `removeObject` (and its `set(nil)` spelling) must clear BOTH
    /// stores — a reset that leaves the keychain item behind would
    /// resurrect the value on the next read.
    func testRemoveObjectClearsTheKeychainAndTheFallback() {
        sut.set("messenger", forKey: "defaultCallApp")
        fallback.set("ne", forKey: "appLanguage")
        sut.set("whatsApp", forKey: "secondaryCallApp")

        sut.removeObject(forKey: "defaultCallApp")
        sut.removeObject(forKey: "appLanguage")
        sut.set(nil, forKey: "secondaryCallApp")

        XCTAssertNil(sut.object(forKey: "defaultCallApp"))
        XCTAssertNil(fallback.object(forKey: "defaultCallApp"))
        XCTAssertNil(fallback.object(forKey: "appLanguage"),
                     "a fallback-only legacy value must be removable too")

        let reinstalled = seamAfterReinstall()
        XCTAssertNil(reinstalled.object(forKey: "defaultCallApp"),
                     "the keychain item must be gone, not just shadowed")
        XCTAssertNil(reinstalled.object(forKey: "appLanguage"))
        XCTAssertNil(reinstalled.object(forKey: "secondaryCallApp"))
    }

    // MARK: - Secrets

    /// The `StoragePlacementPolicy` secrets may pass through the seam
    /// (so callers keep their signatures) but must NEVER be mirrored
    /// into `UserDefaults` — a credential in a plist is the thing the
    /// whole storage split exists to prevent. Ordinary keys, by
    /// contrast, DO get the write-through mirror every un-migrated
    /// reader still depends on.
    func testSecretsAreNeverMirroredIntoUserDefaults() {
        for key in SettingsPersistence.neverMirroredKeys {
            sut.set("secret-\(key)", forKey: key)
            XCTAssertNil(fallback.object(forKey: key),
                         "\(key) must never be mirrored into UserDefaults")
        }

        let reinstalled = seamAfterReinstall()
        for key in SettingsPersistence.neverMirroredKeys {
            XCTAssertEqual(reinstalled.string(forKey: key), "secret-\(key)",
                           "\(key) must stay durable in the keychain")
        }

        sut.set("messenger", forKey: "defaultCallApp")
        XCTAssertEqual(fallback.string(forKey: "defaultCallApp"), "messenger",
                       "an ordinary key keeps the write-through mirror")
    }

    // MARK: - Backfill (the one-time migration)

    /// A pre-seam install's values are adopted by the first boot of the
    /// new build: after `backfillFromUserDefaults()`, the keychain holds
    /// them and a reinstall restores them. The fallback copy is NOT
    /// deleted — it IS the fallback.
    func testBackfillCopiesLegacyDefaultsIntoTheKeychain() {
        fallback.set("ne", forKey: "appLanguage")
        fallback.set(120, forKey: "voice.outputVolumePercent")

        sut.backfillFromUserDefaults()

        XCTAssertEqual(fallback.string(forKey: "appLanguage"), "ne",
                       "backfill must never delete the fallback copy")
        let reinstalled = seamAfterReinstall()
        XCTAssertEqual(reinstalled.string(forKey: "appLanguage"), "ne")
        XCTAssertEqual(reinstalled.integer(forKey: "voice.outputVolumePercent"), 120)
    }

    /// Keychain wins over backfill: a key the household already touched
    /// with the new build must not be rolled back to an older defaults
    /// copy by a later boot's migration.
    func testBackfillNeverClobbersAKeychainValue() {
        sut.set("en", forKey: "appLanguage")
        fallback.set("ne", forKey: "appLanguage")

        sut.backfillFromUserDefaults()

        XCTAssertEqual(sut.string(forKey: "appLanguage"), "en")
        let reinstalled = seamAfterReinstall()
        XCTAssertEqual(reinstalled.string(forKey: "appLanguage"), "en",
                       "the newer keychain value must survive the backfill")
    }

    /// Backfill migrates the REVIEWED list only: the secrets (their own
    /// store, `MigratingEncryptedStorage`, owns them), a key that is
    /// not on the list, and the deliberately volatile markers all stay
    /// exactly where they were.
    func testBackfillSkipsSecretsAndNonListedKeys() {
        fallback.set("legacy-gemini-key", forKey: "gemini.apiKey")
        fallback.set("x", forKey: "some.store.unknownSetting")
        fallback.set(true, forKey: "settings.hiddenSheet.used")
        fallback.set(true, forKey: "onboarding.hasSeen")

        sut.backfillFromUserDefaults()

        let reinstalled = seamAfterReinstall()
        XCTAssertNil(reinstalled.object(forKey: "gemini.apiKey"),
                     "the secret's migration belongs to MigratingEncryptedStorage")
        XCTAssertNil(reinstalled.object(forKey: "some.store.unknownSetting"),
                     "only reviewed keys are backfilled — a new owner key must join the list consciously")
        XCTAssertNil(reinstalled.object(forKey: "settings.hiddenSheet.used"),
                     "the hidden-sheet marker is deliberately not migrated")
        XCTAssertNil(reinstalled.object(forKey: "onboarding.hasSeen"),
                     "onboarding is deliberately non-persistent — a reinstalling elder re-sees the wizard")
    }

    /// Idempotence, asserted on the ITEM COUNT, not just on the value:
    /// a second boot's backfill must not write a second item, or every
    /// launch would grow the keychain forever.
    func testBackfillIsIdempotent() {
        fallback.set("ne", forKey: "appLocale")

        sut.backfillFromUserDefaults()
        XCTAssertEqual(keychainItemCount(), 1)

        sut.backfillFromUserDefaults()
        XCTAssertEqual(keychainItemCount(), 1, "a second run must not write a second item")
        XCTAssertEqual(seamAfterReinstall().string(forKey: "appLocale"), "ne")
    }

    // MARK: - The reviewed lists (both directions)

    /// Set equality, the `StoragePlacementTests` discipline: every key
    /// in the owner surface is a deliberate decision, so a new owner
    /// setting appearing — or an existing one dropping out — must be a
    /// conscious edit to this list.
    func testTheBackfillListIsExactlyTheReviewedOwnerSurface() {
        XCTAssertEqual(SettingsPersistence.backfillKeys, [
            // App language + formatting locale (AppLanguage / AppLocale).
            "appLanguage", "appLocale",
            // Appearance (AppCoordinator).
            "appTheme", "appVisualStyle", "appTextSize",
            // Model picks, global + per-language memory.
            "sttModelPreference", "brainModelPreference",
            "sttModelPreferenceByLanguage", "brainModelPreferenceByLanguage",
            // Calling + navigation picks.
            "defaultCallApp", "secondaryCallApp", "navigationMapApp",
            // Voice stack + engines.
            "voiceEngineStack", "voiceProcessingEnabled", "noiseFilterEnabled",
            "warmStartEngines", "wakeWord.enabled", "dialectBiasEnabled",
            // Reply voice.
            "ttsResponseVoiceSelection", "ttsVoicePreferenceByLanguage",
            "voice.outputVolumePercent",
            // Cloud tiers.
            "cloudFallbackEnabled", "cloudProvider",
            "cloudCascade.threshold", "cloudCascade.enabled",
            // Home quick-access row.
            "quickAccessApps",
            // Medications / appointments.
            "appointmentsToCalendar", "appointmentSmsNoteDismissed.v1",
            // Slot-clock retime note (the one-shot m-5 dismissal, T-020).
            "medicationRetimeNoteDismissed.v1",
            // Calendar display + sync + sharing.
            "calendarDisplay.seeded.v1", "calendarDisplay.defaultCalendar.v1",
            "calendarDisplay.bsOverlay.v1", "calendarDisplay.tithiOverlay.v1",
            "calendarSync.enabled", "calendarSync.twoWayEnabled",
            "calendarShare.consentAccepted", "calendarShare.inboundSyncToken",
            "externalCalendar.enabled", "externalCalendar.leadMinutes",
            "festivalCalendar.advanceReminderDays",
            // Caregiver notifications.
            "caregiverNotify.medicationReminder", "caregiverNotify.routineReminder",
            "caregiverNotify.calendarEvent",
            // Live translate — the owner-facing switches only.
            "livetranslate.alwaysShowOriginal", "livetranslate.geminiCloudEnabled",
            "livetranslate.enabled",
        ])
    }

    /// The never-mirror set is exactly the placement policy's secrets —
    /// aliased, so the two policies cannot drift — and the two lists
    /// are disjoint: a secret must never become a backfill candidate.
    func testTheNeverMirroredSetIsThePlacementPolicysSecrets() {
        XCTAssertEqual(SettingsPersistence.neverMirroredKeys,
                       StoragePlacementPolicy.keychainResidentKeys)
        for key in SettingsPersistence.neverMirroredKeys {
            XCTAssertFalse(SettingsPersistence.backfillKeys.contains(key),
                           "\(key) is a secret — it must not be a backfill candidate")
        }
    }

    /// The named OMISSIONS, pinned so promoting one of these to an
    /// owner-facing setting is a conscious act that fails here first:
    /// diagnostics and engineering pins (debug toggles, feature pins,
    /// calibration knobs), volatile runtime state (quota counters,
    /// auto-detected dialect, sync-link caches), the hidden-sheet
    /// marker, and onboarding (deliberately non-persistent).
    func testDiagnosticAndVolatileKeysAreNotBackfillCandidates() {
        let notMigrated = [
            // Diagnostics / engineering pins.
            "voiceTimingDebug",
            "livetranslate.translationDebugLoggingEnabled",
            "modelDownload.ignoreModelFitPolicyForDownloads",
            "modelDownload.ignoreRamTierForDownloads",
            "sttCorrection.mode", "sttCorrection.threshold",
            "canonicalizer.enabled",
            "intentEncoder.enabled", "intentEncoder.cascade",
            "intentEncoder.corrector", "intentEncoder.canonicalizer",
            "pointask.geminiCloudEnabled",
            // Volatile runtime state.
            "search.quota.day", "search.quota.count",
            "dialectLabel",
            "externalEventLinks.byAppKey",
            "externalEventLinks.sahayakCalendarIdentifier",
            // Deliberately volatile product state.
            "settings.hiddenSheet.used",
            "onboarding.hasSeen", "onboarding.stepStatuses",
        ]
        for key in notMigrated {
            XCTAssertFalse(SettingsPersistence.backfillKeys.contains(key),
                           "\(key) is deliberately NOT on the owner surface (see this suite's doc)")
        }
    }

    // MARK: - The storage contract

    /// After-first-unlock, this-device-only, never synchronizable: the
    /// accessibility the seam promises is the one stored on the ITEM.
    /// A silently promoted accessibility (or an accidental iCloud
    /// Keychain sync) fails here before it ships.
    func testStoredItemsAreThisDeviceOnlyAndNeverSynchronizable() {
        sut.set("ne", forKey: "appLanguage")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "appLanguage",
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &out), errSecSuccess)

        let attributes = out as? [String: Any]
        XCTAssertEqual(attributes?[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                       "settings must be readable after first unlock and stay on this device")
        let synchronizable = attributes?[kSecAttrSynchronizable as String] as? NSNumber
        XCTAssertNotEqual(synchronizable?.boolValue, true,
                          "kSecAttrSynchronizable must never be true — settings do not travel via iCloud Keychain")
    }

    /// An unencodable value keeps the pre-seam behavior exactly:
    /// fallback only, no durability promise, no crash. (None of the
    /// listed keys uses such a type — this pins the escape hatch.)
    func testAnUnsupportedTypeFallsBackWithoutCrash() {
        sut.set(Date(), forKey: "k.date")

        XCTAssertNotNil(fallback.object(forKey: "k.date"),
                        "an unencodable type must still reach the fallback")
        XCTAssertNil(seamAfterReinstall().object(forKey: "k.date"),
                     "and carries no keychain durability promise")
    }

    // MARK: - The test-runner contract

    /// Under XCTest, `.shared` is a PASSTHROUGH: no keychain reads, no
    /// keychain writes, everything through `UserDefaults.standard` —
    /// byte-identical to the pre-seam behavior, which is what keeps the
    /// coordinator suites that build the real `AppCoordinator` hermetic
    /// without edits. A unique probe key proves both halves: the value
    /// IS in `UserDefaults.standard`, and an instance over the
    /// PRODUCTION service cannot see it — the test run leaves no junk
    /// in the production keychain.
    func testTheSharedInstanceStaysOnUserDefaultsUnderXCTest() {
        let key = "settingsPersistence.test.passthrough.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        SettingsPersistence.shared.set("probe", forKey: key)

        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "probe",
                       "under the runner .shared must mirror into UserDefaults.standard")
        XCTAssertEqual(SettingsPersistence.shared.string(forKey: key), "probe")

        let productionProbe = SettingsPersistence.make(service: SettingsPersistence.service,
                                                       fallback: makeSuite())
        XCTAssertNil(productionProbe.object(forKey: key),
                     "the test run must leave no junk in the production keychain service")
    }

    /// The hygiene tool the suite's teardown itself runs: wiping a
    /// scratch service deletes every item it holds.
    func testRemoveAllStoredItemsWipesTheScratchService() {
        sut.set("messenger", forKey: "defaultCallApp")
        sut.set("ne", forKey: "appLanguage")
        XCTAssertEqual(keychainItemCount(), 2)

        sut.removeAllStoredItems()

        XCTAssertEqual(keychainItemCount(), 0)
        XCTAssertNil(seamAfterReinstall().object(forKey: "defaultCallApp"))
    }

    // MARK: - Helpers

    /// The reinstall simulation: a NEW seam over the SAME keychain
    /// service with a FRESH (empty) fallback. Whatever it can read came
    /// from the keychain alone — the post-reinstall state.
    private func seamAfterReinstall() -> SettingsPersistence {
        SettingsPersistence.make(service: serviceName, fallback: makeSuite())
    }

    /// A brand-new scratch fallback suite, tracked for teardown.
    private func makeSuite() -> UserDefaults {
        let suiteName = "test.settings.fallback.\(UUID().uuidString)"
        fallbackSuiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

    /// The number of keychain items this test's scratch service holds —
    /// counting with the same query shape the seam writes with.
    private func keychainItemCount() -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let items = out as? [[String: Any]] else { return 0 }
        return items.count
    }
}
