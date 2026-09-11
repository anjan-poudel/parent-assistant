import XCTest
import AVFoundation
@testable import ElderlyAssistant

/// Voice-personalisation P0, slice C — the switchable Voice Processing I/O
/// audio-session preset behind `AudioSessionManager.voiceProcessingEnabled`
/// (A/B gate, default OFF).
///
/// Locked contracts:
///  - OFF: activation makes the exact pre-A/B call sequence (`.playAndRecord`
///    + `.measurement` + the same options), never touches the engine node,
///    and emits no preset events — byte-identical observability included.
///  - ON: `.voiceChat` + node VP enable; when the device/route cannot do
///    VPIO the activation falls back to the measurement config, still
///    succeeds, and emits `audio_session_vpio_unavailable` — no crash paths.
///  - the toggle persists through UserDefaults (the same key the
///    coordinator's published mirror restores from).
///
/// No real audio session or engine anywhere: the manager is driven through
/// the `AudioSessionControlling` seam (fakes) with a disposable defaults
/// suite, so the preset selection logic is exercised without hardware.
final class AudioSessionPresetTests: XCTestCase {

    // MARK: - Fakes

    /// Records every session call the manager makes and simulates the
    /// configurable failure modes (permission, session calls, VP enable).
    private final class RecordingSession: AudioSessionControlling {
        var isInputAvailable = true
        var permissionGranted = true
        /// When set, `setCategory` throws it.
        var categoryError: Error?
        /// When set, `setActive` throws it.
        var activeError: Error?
        /// When set, `setVoiceProcessingEnabled(true)` throws it.
        var voiceProcessingEnableError: Error?

        var notificationSource: AnyObject? { nil }

        struct CategoryCall: Equatable {
            let category: AVAudioSession.Category
            let mode: AVAudioSession.Mode
            let options: AVAudioSession.CategoryOptions
        }
        private(set) var categoryCalls: [CategoryCall] = []
        private(set) var activeCalls: [(Bool, AVAudioSession.SetActiveOptions)] = []
        private(set) var voiceProcessingCalls: [Bool] = []
        /// [LOUD-TTS] Every `setMode` call, in order — the playback-mode
        /// seam's begin/end dance is asserted against this.
        private(set) var modeCalls: [AVAudioSession.Mode] = []
        private(set) var permissionRequests = 0

        func requestRecordPermission(_ callback: @escaping (Bool) -> Void) {
            permissionRequests += 1
            // Synchronous — keeps the activation assertions deterministic
            // (the real controller hops to main; that hop is not what
            // these tests exercise).
            callback(permissionGranted)
        }

        func setCategory(_ category: AVAudioSession.Category,
                         mode: AVAudioSession.Mode,
                         options: AVAudioSession.CategoryOptions) throws {
            categoryCalls.append(CategoryCall(category: category,
                                              mode: mode,
                                              options: options))
            if let categoryError { throw categoryError }
        }

        func setActive(_ active: Bool,
                       options: AVAudioSession.SetActiveOptions) throws {
            activeCalls.append((active, options))
            if let activeError { throw activeError }
        }

        func setMode(_ mode: AVAudioSession.Mode) throws {
            modeCalls.append(mode)
        }

        func setVoiceProcessingEnabled(_ enabled: Bool) throws {
            voiceProcessingCalls.append(enabled)
            // Mirrors the real controller: no input route = refuse
            // without ever touching the node (the 2026-09-02 abort guard).
            if enabled {
                guard isInputAvailable else {
                    throw AudioSessionControllingError.inputUnavailable
                }
                if let voiceProcessingEnableError {
                    throw voiceProcessingEnableError
                }
            }
        }
    }

    private final class RecordingBus: ObservabilityBus {
        private(set) var events: [ObservabilityEvent] = []
        func emit(_ event: ObservabilityEvent) {
            events.append(event)
        }
        func events(ofType type: String) -> [ObservabilityEvent] {
            events.filter { $0.eventType == type }
        }
    }

    // MARK: - Helpers

    private let measurementOptions: AVAudioSession.CategoryOptions =
        [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AudioSessionPresetTests-\(UUID().uuidString)")!
    }

    /// Runs `activate` and returns its result. The fake's permission
    /// callback is synchronous, so the completion lands synchronously.
    private func activate(_ manager: AudioSessionManager)
        -> Result<Void, AudioSessionManager.ActivationError> {
        var outcome: Result<Void, AudioSessionManager.ActivationError>!
        manager.activate { outcome = $0 }
        return outcome
    }

    private func assertSuccess(
        _ result: Result<Void, AudioSessionManager.ActivationError>,
        _ message: String = "activation must succeed",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .success = result else {
            XCTFail("\(message) — got \(result)", file: file, line: line)
            return
        }
    }

    // MARK: - Persistence

    func testToggleDefaultsOffAndPersists() {
        let defaults = makeDefaults()
        let manager = makeManager(session: RecordingSession(), defaults: defaults)

        XCTAssertFalse(manager.voiceProcessingEnabled,
                       "the A/B gate must default OFF (byte-identical legacy behavior)")

        manager.voiceProcessingEnabled = true
        XCTAssertTrue(defaults.bool(forKey: AudioSessionManager.voiceProcessingEnabledDefaultsKey),
                      "didSet must persist the toggle")

        // A fresh manager over the same defaults restores the value
        // (what the coordinator's published mirror mirrors at init).
        let restored = makeManager(session: RecordingSession(), defaults: defaults)
        XCTAssertTrue(restored.voiceProcessingEnabled)
    }

    // MARK: - OFF: byte-identical legacy preset

    func testOffActivationIsByteIdenticalMeasurementSequence() {
        let session = RecordingSession()
        let bus = RecordingBus()
        let manager = AudioSessionManager(observabilityBus: bus,
                                          audioSession: session,
                                          defaults: makeDefaults())

        assertSuccess(activate(manager))

        XCTAssertEqual(session.categoryCalls, [
            .init(category: .playAndRecord,
                  mode: .measurement,
                  options: measurementOptions)
        ])
        XCTAssertEqual(session.activeCalls.map(\.0), [true])
        XCTAssertEqual(session.activeCalls.map(\.1), [[.notifyOthersOnDeactivation]],
                       "same setActive options as the pre-A/B flow")
        XCTAssertTrue(session.voiceProcessingCalls.isEmpty,
                      "OFF must never touch the engine node")

        XCTAssertEqual(Set(bus.events.map(\.eventType)), ["audio_activate"],
                       "OFF activation emits exactly the legacy events")
        XCTAssertEqual(bus.events(ofType: "audio_activate").first?.outcome, "success")
    }

    func testOffRepeatedActivationsStayByteIdentical() {
        let session = RecordingSession()
        let bus = RecordingBus()
        let manager = AudioSessionManager(observabilityBus: bus,
                                          audioSession: session,
                                          defaults: makeDefaults())

        assertSuccess(activate(manager))
        assertSuccess(activate(manager))

        XCTAssertTrue(session.voiceProcessingCalls.isEmpty,
                      "steady-state OFF never makes a node call, not even once")
        XCTAssertTrue(bus.events(ofType: "audio_session_preset_changed").isEmpty)
        XCTAssertTrue(bus.events(ofType: "audio_session_vpio_unavailable").isEmpty)
        XCTAssertEqual(bus.events(ofType: "audio_activate").count, 2)
    }

    func testOffPermissionDeniedShortCircuitsBeforeAnySessionCall() {
        let session = RecordingSession()
        session.permissionGranted = false
        let bus = RecordingBus()
        let manager = AudioSessionManager(observabilityBus: bus,
                                          audioSession: session,
                                          defaults: makeDefaults())

        let result = activate(manager)

        guard case .failure(.microphonePermissionDenied) = result else {
            return XCTFail("expected microphonePermissionDenied, got \(result)")
        }
        XCTAssertTrue(session.categoryCalls.isEmpty)
        XCTAssertTrue(session.activeCalls.isEmpty)
        XCTAssertEqual(bus.events(ofType: "audio_activate").first?.outcome, "denied")
    }

    // MARK: - ON: voice-processing preset

    func testOnActivationUsesVoiceChatAndEnablesNodeVoiceProcessing() {
        let session = RecordingSession()
        let bus = RecordingBus()
        let defaults = makeDefaults()
        defaults.set(true, forKey: AudioSessionManager.voiceProcessingEnabledDefaultsKey)
        let manager = AudioSessionManager(observabilityBus: bus,
                                          audioSession: session,
                                          defaults: defaults)

        assertSuccess(activate(manager))

        XCTAssertEqual(session.categoryCalls, [
            .init(category: .playAndRecord,
                  mode: .voiceChat,
                  options: measurementOptions)
        ])
        XCTAssertEqual(session.voiceProcessingCalls, [true],
                       "VP preset must enable voice processing on the node")
        XCTAssertEqual(session.activeCalls.map(\.0), [true])

        let changed = bus.events(ofType: "audio_session_preset_changed")
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.outcome, "applied")
        XCTAssertEqual(changed.first?.metadata["state"], "on")
        XCTAssertTrue(bus.events(ofType: "audio_session_vpio_unavailable").isEmpty)
    }

    func testOnActivationFallsBackToMeasurementWhenNodeVpFails() {
        let session = RecordingSession()
        session.voiceProcessingEnableError = NSError(domain: "test", code: 1)
        let bus = RecordingBus()
        let defaults = makeDefaults()
        defaults.set(true, forKey: AudioSessionManager.voiceProcessingEnabledDefaultsKey)
        let manager = AudioSessionManager(observabilityBus: bus,
                                          audioSession: session,
                                          defaults: defaults)

        assertSuccess(activate(manager),
                      "an unsupported VPIO attempt must fall back, not fail activation")

        XCTAssertEqual(session.categoryCalls.map(\.mode), [.voiceChat, .measurement],
                       "failed VP enable must reconfigure to the measurement preset")
        XCTAssertEqual(session.categoryCalls.last?.options, measurementOptions)
        XCTAssertEqual(session.activeCalls.map(\.0), [true, false, true],
                       "the fallback cycles active off and on so the measurement "
                       + "configuration deterministically applies")

        let unavailable = bus.events(ofType: "audio_session_vpio_unavailable")
        XCTAssertEqual(unavailable.count, 1)
        XCTAssertEqual(unavailable.first?.outcome, "fallback")
        XCTAssertEqual(unavailable.first?.metadata["state"], "on")
        XCTAssertEqual(unavailable.first?.metadata["reason"], "enable_failed")
        XCTAssertTrue(bus.events(ofType: "audio_session_preset_changed").isEmpty,
                       "an unapplied preset must not report itself applied")
    }

    func testOnActivationFallsBackWhenNoInputRoute() {
        let session = RecordingSession()
        session.isInputAvailable = false
        let bus = RecordingBus()
        let defaults = makeDefaults()
        defaults.set(true, forKey: AudioSessionManager.voiceProcessingEnabledDefaultsKey)
        let manager = AudioSessionManager(observabilityBus: bus,
                                          audioSession: session,
                                          defaults: defaults)

        assertSuccess(activate(manager))

        XCTAssertEqual(session.categoryCalls.map(\.mode), [.voiceChat, .measurement])
        XCTAssertEqual(session.voiceProcessingCalls, [true, false],
                       "the node enable is refused by the availability guard, "
                       + "then the fallback drops the flag best-effort")
        let unavailable = bus.events(ofType: "audio_session_vpio_unavailable")
        XCTAssertEqual(unavailable.first?.metadata["reason"], "input_unavailable",
                       "the no-input-route abort guard (2026-09-02) must surface "
                       + "as the honest reason")
    }

    func testOnPermissionDeniedShortCircuitsBeforeAnySessionCall() {
        let session = RecordingSession()
        session.permissionGranted = false
        let defaults = makeDefaults()
        defaults.set(true, forKey: AudioSessionManager.voiceProcessingEnabledDefaultsKey)
        let manager = makeManager(session: session, defaults: defaults)

        let result = activate(manager)

        guard case .failure(.microphonePermissionDenied) = result else {
            return XCTFail("expected microphonePermissionDenied, got \(result)")
        }
        XCTAssertTrue(session.categoryCalls.isEmpty)
        XCTAssertTrue(session.voiceProcessingCalls.isEmpty)
    }

    // MARK: - ON -> OFF transition in-process

    func testTurningOffAfterOnDisablesNodeVpAndReportsOff() {
        let session = RecordingSession()
        let bus = RecordingBus()
        let defaults = makeDefaults()
        defaults.set(true, forKey: AudioSessionManager.voiceProcessingEnabledDefaultsKey)
        let manager = AudioSessionManager(observabilityBus: bus,
                                          audioSession: session,
                                          defaults: defaults)

        assertSuccess(activate(manager))
        XCTAssertEqual(session.voiceProcessingCalls, [true])

        manager.voiceProcessingEnabled = false
        XCTAssertFalse(defaults.bool(forKey: AudioSessionManager.voiceProcessingEnabledDefaultsKey),
                       "the OFF flip must persist")
        assertSuccess(activate(manager))

        // The node flag survives engine stop/start — the OFF activation
        // must drop it explicitly BEFORE switching to measurement.
        XCTAssertEqual(session.voiceProcessingCalls, [true, false])
        XCTAssertEqual(session.categoryCalls.last?.mode, .measurement)

        let offEvents = bus.events(ofType: "audio_session_preset_changed")
            .filter { $0.metadata["state"] == "off" }
        XCTAssertEqual(offEvents.count, 1)
        XCTAssertEqual(offEvents.first?.outcome, "applied")
    }

    func testTurningOffAfterFailedEnableDoesNotEmitOffTransition() {
        // A fallback (VP never actually engaged) must not be reported as
        // an "off" transition later — the in-process flag tracks what was
        // really enabled.
        let session = RecordingSession()
        session.voiceProcessingEnableError = NSError(domain: "test", code: 1)
        let bus = RecordingBus()
        let defaults = makeDefaults()
        defaults.set(true, forKey: AudioSessionManager.voiceProcessingEnabledDefaultsKey)
        let manager = AudioSessionManager(observabilityBus: bus,
                                          audioSession: session,
                                          defaults: defaults)

        assertSuccess(activate(manager))   // falls back to measurement
        manager.voiceProcessingEnabled = false
        assertSuccess(activate(manager))

        XCTAssertEqual(session.voiceProcessingCalls, [true, false],
                       "the fallback's own disable was the only one — the OFF "
                       + "activation must not disable a node that never engaged")
        XCTAssertTrue(bus.events(ofType: "audio_session_preset_changed")
                        .filter { $0.metadata["state"] == "off" }.isEmpty)
    }

    // MARK: - Failure mapping (unchanged contract)

    func testCategoryFailureMapsToActivationFailedUnderBothPresets() {
        for presetOn in [false, true] {
            let session = RecordingSession()
            session.categoryError = NSError(domain: "test", code: 2)
            let bus = RecordingBus()
            let defaults = makeDefaults()
            defaults.set(presetOn,
                         forKey: AudioSessionManager.voiceProcessingEnabledDefaultsKey)
            let manager = AudioSessionManager(observabilityBus: bus,
                                              audioSession: session,
                                              defaults: defaults)

            let result = activate(manager)

            guard case .failure(.activationFailed) = result else {
                return XCTFail("presetOn=\(presetOn): expected activationFailed, "
                               + "got \(result)")
            }
            XCTAssertEqual(bus.events(ofType: "audio_activate").first?.errorCode,
                           "activation_failed", "presetOn=\(presetOn)")
        }
    }

    // MARK: - Fixtures

    private func makeManager(session: RecordingSession,
                             defaults: UserDefaults) -> AudioSessionManager {
        AudioSessionManager(observabilityBus: RecordingBus(),
                            audioSession: session,
                            defaults: defaults)
    }

    // MARK: - Response playback loudness ([LOUD-TTS])

    func testResponsePlaybackSwitchesToVoicePromptAndRestoresCaptureMode() {
        let session = RecordingSession()
        let manager = makeManager(session: session, defaults: makeDefaults())

        manager.beginResponsePlayback()
        XCTAssertEqual(session.modeCalls, [.voicePrompt],
                       "speaking must switch the session to the speech-optimized mode")

        manager.endResponsePlayback()
        XCTAssertEqual(session.modeCalls, [.voicePrompt, .measurement],
                       "playback end must restore the capture preset (default OFF = measurement)")
    }

    func testNestedResponsePlaybackRestoresOnlyAtOutermostEnd() {
        let session = RecordingSession()
        let manager = makeManager(session: session, defaults: makeDefaults())

        // Piper falling back to the system speaker nests begin/end.
        manager.beginResponsePlayback()
        manager.beginResponsePlayback()
        manager.endResponsePlayback()
        XCTAssertEqual(session.modeCalls, [.voicePrompt],
                       "the inner end must NOT restore while an outer playback still runs")
        manager.endResponsePlayback()
        XCTAssertEqual(session.modeCalls, [.voicePrompt, .measurement],
                       "the outermost end restores exactly once")
    }

    func testResponsePlaybackEndWithoutBeginIsHarmless() {
        let session = RecordingSession()
        let manager = makeManager(session: session, defaults: makeDefaults())
        manager.endResponsePlayback()
        XCTAssertTrue(session.modeCalls.isEmpty)
    }

    func testResponsePlaybackRestoresVoiceChatWhenVPPresetIsOn() {
        let session = RecordingSession()
        let manager = makeManager(session: session, defaults: makeDefaults())
        manager.voiceProcessingEnabled = true

        manager.beginResponsePlayback()
        manager.endResponsePlayback()
        XCTAssertEqual(session.modeCalls, [.voicePrompt, .voiceChat],
                       "restore must return to the ACTIVE preset, not hardcode measurement")
    }
}
