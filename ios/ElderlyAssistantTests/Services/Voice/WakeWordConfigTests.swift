import XCTest
@testable import ElderlyAssistant

/// Unit tests for the wake-word ("ये कान्छी") configuration surface —
/// open item #4. Every type under test is deliberately FREE of engine
/// types (see Services/Voice/WakeWordConfig.swift): the real sherpa
/// engine arrives only as the selection's injected candidate closure, so
/// the whole decision table runs without the sherpa-onnx SPM package
/// linked into the test target.
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
        // 2026-09-08 rationale: ON is the shipped default — with the KWS
        // model bundled, the wake word then listens from the next launch
        // on; when the model is absent the engine is Null regardless.
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

    // MARK: - WakeWordEngineSelection (pure decision table)

    func testSelectionReturnsNilWhenToggleOffAndSkipsCandidate() {
        // The master toggle is checked BEFORE any engine is constructed —
        // the sherpa model load is not free, and disabled must behave
        // exactly like today.
        var candidateCalls = 0
        let engine = WakeWordEngineSelection.make(
            toggleEnabled: false,
            sherpaCandidate: {
                candidateCalls += 1
                return WakeWordTestEngine()
            })
        XCTAssertNil(engine)
        XCTAssertEqual(candidateCalls, 0,
                       "candidate must not run when the toggle is OFF")
    }

    func testSelectionReturnsCandidateEngineWhenToggleOn() {
        let real = WakeWordTestEngine()
        let engine = WakeWordEngineSelection.make(
            toggleEnabled: true,
            sherpaCandidate: { real })
        XCTAssertTrue(engine === real,
                      "a live sherpa engine must pass through untouched")
    }

    func testSelectionReturnsNilWhenCandidateDeclines() {
        // No model in this build (or the runtime not linked): the honest
        // result is nil and the caller falls back to NullWakeWordEngine —
        // never a silent stub pretending to listen.
        let engine = WakeWordEngineSelection.make(
            toggleEnabled: true,
            sherpaCandidate: { nil })
        XCTAssertNil(engine)
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
        // ON + no bundled KWS model (or no sherpa runtime): the engine is
        // Null and the screen must say so instead of pretending.
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

// MARK: - Test double

/// Minimal protocol-conforming engine for identity checks. The sherpa-onnx
/// package is never linked into the test target, so the candidate closure
/// fabricates this instead.
private final class WakeWordTestEngine: WakeWordEngine {
    let requiredSampleRate: Double = 16_000
    let frameLength: Int = 512
    var onDetection: (() -> Void)?
    func start() throws {}
    func stop() {}
    func process(_ pcm: [Int16]) {}
}
