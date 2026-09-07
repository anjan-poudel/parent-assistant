import XCTest
@testable import ElderlyAssistant

/// Unit tests for the wake-word ("Hey Sahayak") configuration surface —
/// open item #4. Every type under test is deliberately FREE of Porcupine
/// types (see Services/Voice/WakeWordConfig.swift), so the full decision
/// table runs without the SPM package linked into the test target.
final class WakeWordConfigTests: XCTestCase {

    // MARK: - WakeWordPreferences (persisted toggle)

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.wakeword.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testToggleDefaultsOnWhenUnset() {
        // 2026-09-06 rationale: ON is inert until the access key + .ppn
        // exist (Null engine regardless), and means the wake word activates
        // at the next launch once a family member completes the setup.
        let prefs = WakeWordPreferences(defaults: defaults)
        XCTAssertTrue(prefs.isEnabled, "unset preference must default to ON")
    }

    func testToggleRoundTripsOffAndBackOn() {
        let prefs = WakeWordPreferences(defaults: defaults)
        prefs.setEnabled(false)
        XCTAssertFalse(prefs.isEnabled)
        prefs.setEnabled(true)
        XCTAssertTrue(prefs.isEnabled)
    }

    func testTogglePersistsAcrossInstancesOverTheSameDefaults() {
        WakeWordPreferences(defaults: defaults).setEnabled(false)
        XCTAssertFalse(WakeWordPreferences(defaults: defaults).isEnabled)
    }

    // MARK: - WakeWordAccessKeyStore (encrypted key, mirror of
    // GeminiConfigStore)

    func testKeyStoreStartsUnconfiguredWhenNothingStored() {
        let store = WakeWordAccessKeyStore(storage: WakeWordInMemoryStorage())
        XCTAssertFalse(store.isConfigured)
        XCTAssertNil(store.accessKey)
    }

    func testKeyStoreSaveTrimsWhitespaceAndMarksConfigured() {
        let store = WakeWordAccessKeyStore(storage: WakeWordInMemoryStorage())
        store.save("  my-test-access-key  ")
        XCTAssertTrue(store.isConfigured)
        XCTAssertEqual(store.accessKey, "my-test-access-key")
    }

    func testKeyStoreSavingBlankClearsInsteadOfStoringEmpty() {
        let store = WakeWordAccessKeyStore(storage: WakeWordInMemoryStorage())
        store.save("real-key")
        store.save("   ")
        XCTAssertFalse(store.isConfigured)
        XCTAssertNil(store.accessKey)
    }

    func testKeyStoreClearRemovesTheKey() {
        let store = WakeWordAccessKeyStore(storage: WakeWordInMemoryStorage())
        store.save("real-key")
        store.clear()
        XCTAssertFalse(store.isConfigured)
        XCTAssertNil(store.accessKey)
    }

    func testKeyStorePersistsAcrossInstancesOverTheSameStorage() {
        let storage = WakeWordInMemoryStorage()
        WakeWordAccessKeyStore(storage: storage).save("persisted-key")
        let reloaded = WakeWordAccessKeyStore(storage: storage)
        XCTAssertTrue(reloaded.isConfigured)
        XCTAssertEqual(reloaded.accessKey, "persisted-key")
    }

    // MARK: - resolvedAccessKey precedence (plist wins over stored)

    func testResolvedAccessKeyPrefersPlistOverStored() {
        XCTAssertEqual(
            WakeWordAccessKeyStore.resolvedAccessKey(plistKey: "plist-key",
                                                     storedKey: "stored-key"),
            "plist-key")
    }

    func testResolvedAccessKeyFallsBackToStoredWhenPlistAbsent() {
        XCTAssertEqual(
            WakeWordAccessKeyStore.resolvedAccessKey(plistKey: nil,
                                                     storedKey: "stored-key"),
            "stored-key")
    }

    func testResolvedAccessKeyTreatsBlankPlistAsAbsent() {
        XCTAssertEqual(
            WakeWordAccessKeyStore.resolvedAccessKey(plistKey: "   ",
                                                     storedKey: "stored-key"),
            "stored-key")
    }

    func testResolvedAccessKeyNilWhenBothAbsent() {
        XCTAssertNil(WakeWordAccessKeyStore.resolvedAccessKey(plistKey: nil,
                                                              storedKey: nil))
        XCTAssertNil(WakeWordAccessKeyStore.resolvedAccessKey(plistKey: " ",
                                                              storedKey: ""))
    }

    func testResolvedAccessKeyTrimsBothSources() {
        XCTAssertEqual(
            WakeWordAccessKeyStore.resolvedAccessKey(plistKey: "  plist  ",
                                                     storedKey: " stored "),
            "plist")
    }

    // MARK: - WakeWordEngineSelection (pure decision table)

    func testSelectionReturnsNilWhenToggleOffEvenWithKeyAndModel() {
        var buildCalls = 0
        let engine = WakeWordEngineSelection.make(
            toggleEnabled: false,
            accessKey: "a-key",
            keywordPath: "/a/ppn",
            build: { _, _ in
                buildCalls += 1
                return WakeWordTestEngine()
            })
        XCTAssertNil(engine)
        XCTAssertEqual(buildCalls, 0,
                       "build must not run when the toggle is OFF — disabled "
                       + "must behave exactly like today")
    }

    func testSelectionReturnsNilWhenKeyMissing() {
        var buildCalls = 0
        let engine = WakeWordEngineSelection.make(
            toggleEnabled: true,
            accessKey: nil,
            keywordPath: "/a/ppn",
            build: { _, _ in
                buildCalls += 1
                return WakeWordTestEngine()
            },
            // No sherpa model (this pins the LEGACY Porcupine chain — the
            // default candidate would consult the test host's bundle and
            // make the test depend on whether fetch-kws-model.sh has run).
            sherpaCandidate: { nil })
        XCTAssertNil(engine)
        XCTAssertEqual(buildCalls, 0)
    }

    func testSelectionReturnsNilWhenKeyBlank() {
        var buildCalls = 0
        let engine = WakeWordEngineSelection.make(
            toggleEnabled: true,
            accessKey: "   ",
            keywordPath: "/a/ppn",
            build: { _, _ in
                buildCalls += 1
                return WakeWordTestEngine()
            },
            // Legacy-chain pin — see the sibling test's comment.
            sherpaCandidate: { nil })
        XCTAssertNil(engine)
        XCTAssertEqual(buildCalls, 0)
    }

    func testSelectionReturnsNilWhenKeywordPathMissing() {
        var buildCalls = 0
        let engine = WakeWordEngineSelection.make(
            toggleEnabled: true,
            accessKey: "a-key",
            keywordPath: nil,
            build: { _, _ in
                buildCalls += 1
                return WakeWordTestEngine()
            },
            // Legacy-chain pin — see the sibling test's comment.
            sherpaCandidate: { nil })
        XCTAssertNil(engine)
        XCTAssertEqual(buildCalls, 0)
    }

    func testSelectionReturnsNilWhenBuilderFails() {
        let engine = WakeWordEngineSelection.make(
            toggleEnabled: true,
            accessKey: "a-key",
            keywordPath: "/a/ppn",
            build: { _, _ in nil },
            // Legacy-chain pin — see the sibling test's comment.
            sherpaCandidate: { nil })
        XCTAssertNil(engine, "a throwing Porcupine init must fall back to Null")
    }

    func testSelectionReturnsBuilderEngineWhenEverythingPresent() {
        // The PORCUPINE chain, pinned without a sherpa model — the sherpa-
        // first ordering is covered in SherpaKWSWakeWordEngineTests.
        let real = WakeWordTestEngine()
        let engine = WakeWordEngineSelection.make(
            toggleEnabled: true,
            accessKey: "a-key",
            keywordPath: "/a/ppn",
            build: { _, _ in real },
            sherpaCandidate: { nil })
        XCTAssertTrue(engine === real,
                      "the real engine must pass through untouched")
    }

    func testSelectionHandsNormalizedArgumentsToBuilder() {
        var received: (accessKey: String, path: String)?
        _ = WakeWordEngineSelection.make(
            toggleEnabled: true,
            accessKey: "  a-key  ",
            keywordPath: "  /a/ppn  ",
            build: { key, path in
                received = (key, path)
                return WakeWordTestEngine()
            },
            // Legacy-chain pin — see the sibling test's comment.
            sherpaCandidate: { nil })
        XCTAssertEqual(received?.accessKey, "a-key")
        XCTAssertEqual(received?.path, "/a/ppn")
    }

    // MARK: - WakeWordStatusResolver (honest status derivation)

    func testStatusIsOffWhenToggleOffRegardlessOfProvisioning() {
        XCTAssertEqual(WakeWordStatusResolver.status(enabled: false,
                                                     isProvisioned: true,
                                                     realEngineAtLaunch: true),
                       .off)
        XCTAssertEqual(WakeWordStatusResolver.status(enabled: false,
                                                     isProvisioned: false,
                                                     realEngineAtLaunch: false),
                       .off)
    }

    func testStatusIsNeedsSetupWhenOnButNotProvisioned() {
        XCTAssertEqual(WakeWordStatusResolver.status(enabled: true,
                                                     isProvisioned: false,
                                                     realEngineAtLaunch: false),
                       .needsSetup)
    }

    func testStatusIsActiveWhenOnAndProvisionedAndRealAtLaunch() {
        XCTAssertEqual(WakeWordStatusResolver.status(enabled: true,
                                                     isProvisioned: true,
                                                     realEngineAtLaunch: true),
                       .active)
    }

    func testStatusIsRestartToActivateWhenOnAndProvisionedButEngineWasNullAtLaunch() {
        // The engine is fixed per launch: toggling OFF at launch then ON
        // mid-run cannot build a real engine until the next launch — the
        // status must say so instead of pretending.
        XCTAssertEqual(WakeWordStatusResolver.status(enabled: true,
                                                     isProvisioned: true,
                                                     realEngineAtLaunch: false),
                       .restartToActivate)
    }

    // MARK: - WakeWordActivityGate (self-hearing + toggle-off)

    func testGateAllowsBothByDefault() {
        let gate = WakeWordActivityGate()
        XCTAssertTrue(gate.allowsWakeWordAudio)
        XCTAssertTrue(gate.allowsWakeDetection)
    }

    func testSpeakingClosesBothFeedAndDetection() {
        let gate = WakeWordActivityGate()
        gate.setSpeaking(true)
        XCTAssertFalse(gate.allowsWakeWordAudio)
        XCTAssertFalse(gate.allowsWakeDetection)
    }

    func testSpeakingEndedReopensBoth() {
        let gate = WakeWordActivityGate()
        gate.setSpeaking(true)
        gate.setSpeaking(false)
        XCTAssertTrue(gate.allowsWakeWordAudio)
        XCTAssertTrue(gate.allowsWakeDetection)
    }

    func testToggleOffClosesAudioFeedButNotDetection() {
        // The enable half is deliberately NOT consulted for detection: the
        // Talk button runs simulateWakeWordDetection() through the same
        // path and must keep working with listening switched off.
        let gate = WakeWordActivityGate()
        gate.setEnabled(false)
        XCTAssertFalse(gate.allowsWakeWordAudio)
        XCTAssertTrue(gate.allowsWakeDetection)
    }

    func testReEnablingReopensAudioFeed() {
        let gate = WakeWordActivityGate()
        gate.setEnabled(false)
        gate.setEnabled(true)
        XCTAssertTrue(gate.allowsWakeWordAudio)
    }

    func testSpeakingWinsOverReEnabledToggleForAudioFeed() {
        let gate = WakeWordActivityGate()
        gate.setEnabled(false)
        gate.setEnabled(true)
        gate.setSpeaking(true)
        XCTAssertFalse(gate.allowsWakeWordAudio,
                       "the assistant's own speech must still be suppressed")
        XCTAssertFalse(gate.allowsWakeDetection)
    }
}

// MARK: - Test doubles

/// Minimal protocol-conforming engine for identity checks. The Porcupine
/// package is never linked into the test target, so the builder closure
/// fabricates this instead.
private final class WakeWordTestEngine: WakeWordEngine {
    let requiredSampleRate: Double = 16_000
    let frameLength: Int = 512
    var onDetection: (() -> Void)?
    func start() throws {}
    func stop() {}
    func process(_ pcm: [Int16]) {}
}

/// In-memory `EncryptedLocalStorage` — same double shape as
/// `GeminiConfigStoreTests`; the real implementation is Keychain-backed and
/// untestable without a device context.
private final class WakeWordInMemoryStorage: EncryptedLocalStorage {
    private var values: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        do {
            values[key] = try encoder.encode(value)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard let data = values[key] else { return .failure(.encryptedReadFailed) }
        do {
            return .success(try decoder.decode(type, from: data))
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        values.removeValue(forKey: key)
        return .success(())
    }
}
