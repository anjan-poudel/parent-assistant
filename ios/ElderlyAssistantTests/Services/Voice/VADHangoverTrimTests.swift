import XCTest
import AVFoundation
import SwiftUI
@testable import ElderlyAssistant

/// [LAT-M2] Tests for the flag-gated VAD hangover trim: the pure policy
/// ([VAD-HANGOVER-DEFAULT]: 1200 ms by default, 700 ms when the trim
/// flag is explicitly ON), the EnergyVAD's frame-level end latency at
/// the trimmed value, and the pipeline seam that hands the policy's
/// value to the detector per capture.
/// The existing EnergyVADTests pin the 900 ms world with explicit
/// values — untouched, they stay green alongside these.
final class VADHangoverTrimTests: XCTestCase {

    // MARK: - Policy (pure)

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "vad-hangover-\(UUID().uuidString)")!
    }

    func testDefaultPolicyIsAdaptive() {
        XCTAssertEqual(VADHangoverPolicy.hangoverPolicy(defaults: freshDefaults()),
                       .production,
                       "the default is the self-calibrating policy ([ADAPTIVE-ENDPOINT])")
    }

    func testExplicitFalseKeepsAdaptive() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: VADHangoverPolicy.trim700DefaultsKey)
        XCTAssertEqual(VADHangoverPolicy.hangoverPolicy(defaults: defaults),
                       .production,
                       "flag OFF keeps the adaptive policy")
    }

    func testExplicitTrueGivesFixed700() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: VADHangoverPolicy.trim700DefaultsKey)
        XCTAssertEqual(VADHangoverPolicy.hangoverPolicy(defaults: defaults),
                       .fixed(VADHangoverPolicy.trimmedMs),
                       "the explicitly-enabled trim keeps the old fixed behavior")
    }

    // MARK: - AdaptiveEndpointPolicy (pure)

    func testAdaptiveWindowBeforeFirstPauseIsInitial() {
        var policy = AdaptiveEndpointPolicy.production
        XCTAssertEqual(policy.effectiveWindowMs, 2800,
                       "before any pause is observed the window is the full cap — the speaker always finishes")
        XCTAssertFalse(policy.shouldEnd(currentQuietMs: 2_799))
        XCTAssertTrue(policy.shouldEnd(currentQuietMs: 2_800))
    }

    func testAdaptiveWindowScalesWithTheSpeakersPauses() {
        var policy = AdaptiveEndpointPolicy.production
        // The speaker pauses 800 ms mid-thought, twice.
        policy.recordPause(800)
        policy.recordPause(800)
        // p75 = 800 -> window = max(1800, 800 x 1.6 = 1280) = 1800
        // (the raised floor).
        XCTAssertEqual(policy.effectiveWindowMs, 1800)
        XCTAssertFalse(policy.shouldEnd(currentQuietMs: 1_000),
                       "a 1 s pause no longer ends the capture once the speaker is known to pause long")
        XCTAssertFalse(policy.shouldEnd(currentQuietMs: 1_799))
        XCTAssertTrue(policy.shouldEnd(currentQuietMs: 1_800))
    }

    func testAdaptiveWindowNeverFallsBelowFloor() {
        var policy = AdaptiveEndpointPolicy.production
        policy.recordPause(100)   // a fast speaker's short pauses
        XCTAssertEqual(policy.effectiveWindowMs, 1800,
                       "the 1800 ms floor still bounds a fast speaker's window")
    }

    func testAdaptiveWindowCapsAtForceEnd() {
        var policy = AdaptiveEndpointPolicy.production
        policy.recordPause(2_500)
        XCTAssertEqual(policy.effectiveWindowMs, 2_800,
                       "the window caps just under the 3 s force end")
    }

    func testFixedPolicyIsTheOldFixedBehavior() {
        let policy = AdaptiveEndpointPolicy.fixed(700)
        XCTAssertEqual(policy.effectiveWindowMs, 700)
        XCTAssertFalse(policy.shouldEnd(currentQuietMs: 699))
        XCTAssertTrue(policy.shouldEnd(currentQuietMs: 700))
    }

    func testPauseSamplesResetPerCapture() {
        var policy = AdaptiveEndpointPolicy.production
        policy.recordPause(800)
        policy.resetForCapture()
        XCTAssertEqual(policy.effectiveWindowMs, 2_800,
                       "a new capture recalibrates from its own pauses — back to the full initial cap")
    }

    // MARK: - EnergyVAD end latency at the trimmed hangover
    //
    // 700 ms / 32 ms per frame = 21.875 -> 22 required quiet frames, so
    // the end fires on the 22nd quiet frame (~704 ms after the last
    // speech frame) — the ~200 ms saving over the 900 ms / 29-frame
    // hangover.

    /// Constant-amplitude mono frames at the VAD's frame length.
    private func frames(_ amplitude: Int16, count: Int, length: Int = 512) -> [[Int16]] {
        (0..<count).map { _ in Array(repeating: amplitude, count: length) }
    }

    func testSevenHundredMsHangoverEndsOnTwentySecondQuietFrame() {
        let vad = EnergyVAD()
        var endFrame: Int?
        var frameIndex = 0
        vad.onEndOfUtterance = { endFrame = frameIndex }

        vad.start(policy: .fixed(VADHangoverPolicy.trimmedMs))
        for f in frames(3_000, count: 4) { frameIndex += 1; vad.process(f) }
        for f in frames(0, count: 30) { frameIndex += 1; vad.process(f) }

        XCTAssertEqual(endFrame, 4 + 22,
                       "the trimmed hangover ends the capture on the 22nd quiet frame (~704 ms after speech)")
    }

    func testNineHundredMsHangoverStillEndsOnTwentyNinthQuietFrame() {
        let vad = EnergyVAD()
        var endFrame: Int?
        var frameIndex = 0
        vad.onEndOfUtterance = { endFrame = frameIndex }

        vad.start(policy: .fixed(900))
        for f in frames(3_000, count: 4) { frameIndex += 1; vad.process(f) }
        for f in frames(0, count: 30) { frameIndex += 1; vad.process(f) }

        XCTAssertEqual(endFrame, 4 + 29,
                       "the legacy value keeps its 29-frame (928 ms) end")
    }

    /// The documented elderly-pause trade-off, pinned as behavior: a
    /// 0.5 s TRUE-QUIET pause still survives the trimmed hangover; the
    /// band hold + force end cover the rest (see VADHangoverPolicy).
    func testHalfSecondPauseSurvivesTrimmed700Hangover() {
        let vad = EnergyVAD()
        var ended = false
        vad.onEndOfUtterance = { ended = true }

        vad.start(policy: .fixed(VADHangoverPolicy.trimmedMs))
        for f in frames(3_000, count: 8) { vad.process(f) }
        for f in frames(0, count: 16) { vad.process(f) }       // 0.5 s breath
        XCTAssertFalse(ended,
                       "a 0.5 s quiet pause (below the 700 ms line) must not cut the capture")
        for f in frames(3_000, count: 4) { vad.process(f) }    // the user resumes
        XCTAssertFalse(ended, "resumed speech resets the hangover")
        for f in frames(0, count: 22) { vad.process(f) }       // final silence
        XCTAssertTrue(ended, "the finished utterance still ends at the trimmed hangover")
    }

    /// A full 700 ms TRUE-QUIET pause DOES close the capture — the
    /// trade-off's other edge, pinned so a future change is deliberate.
    func testSevenHundredMsQuietPauseClosesCapture() {
        let vad = EnergyVAD()
        var ended = false
        vad.onEndOfUtterance = { ended = true }

        vad.start(policy: .fixed(VADHangoverPolicy.trimmedMs))
        for f in frames(3_000, count: 8) { vad.process(f) }
        for f in frames(0, count: 22) { vad.process(f) }
        XCTAssertTrue(ended,
                      "a >= 700 ms quiet pause closes the capture at the trimmed hangover — the documented trade-off")
    }

    // MARK: - Pipeline seam (the value the capture hands to the VAD)

    private final class RecordingSession: AudioSessionControlling {
        var isInputAvailable = false
        var notificationSource: AnyObject? { nil }
        func requestRecordPermission(_ callback: @escaping (Bool) -> Void) {
            callback(true)
        }
        func setCategory(_ category: AVAudioSession.Category,
                         mode: AVAudioSession.Mode,
                         options: AVAudioSession.CategoryOptions) throws {}
        func setActive(_ active: Bool,
                       options: AVAudioSession.SetActiveOptions) throws {}
        func setMode(_ mode: AVAudioSession.Mode) throws {}
        func setVoiceProcessingEnabled(_ enabled: Bool) throws {}
    }

    private final class FakeRecognizer: SpeechRecognizerProtocol {
        let ownsAudioCapture = false
        var isAvailable = true
        func requestAuthorization(_ callback: @escaping (Bool) -> Void) {
            callback(true)
        }
        func startListening(timeout: TimeInterval,
                            completion: @escaping (Result<String, RecognitionError>) -> Void) {}
        func feed(_ buffer: AVAudioPCMBuffer) {}
        func finish() {}
        func cancel() {}
    }

    private final class HangoverFakeVAD: VoiceActivityDetector {
        let requiredSampleRate: Double = 16_000
        let frameLength = 512
        var onSpeechStateChange: ((Bool) -> Void)?
        var onEndOfUtterance: (() -> Void)?
        var onForcedEndOfUtterance: (() -> Void)?
        private(set) var startedPolicies: [AdaptiveEndpointPolicy] = []
        func start(policy: AdaptiveEndpointPolicy) { startedPolicies.append(policy) }
        func stop() {}
        func reset() {}
        func process(_ pcm: [Int16]) {}
    }

    private final class MockCoordinator: VoiceCommandCoordinating {
        var isAwaitingConfirmation = false
        var brainReadiness = BrainReadiness.available
        var isAwaitingCallConfirmation = false
        var activeLocale: Locale { Locale(identifier: "ne-NP") }
        var pendingRephraseCommand: InterpretedCommand? { nil }
        func recordTranscript(_ text: String) {}
        func oldestPendingReminderEntryId() -> UUID? { nil }
        func handleMedicationAcknowledgement(entryId: UUID) {}
        func startVoiceAckConfirmation(for entryId: UUID) -> String? { nil }
        func handleConfirmationResponse(_ response: ConfirmationResponse) {}
        func noteSpeakingStarted() {}
        func noteSpeakingEnded() {}
        func noteAssistantSpoke(_ text: String) {}
        func noteGenericReply(_ text: String) {}
        func addVoiceReminder(title: String, time: DateComponents) {}
        func requestCallConfirmation(contactQuery: String?, callType: String?, requestedApp: String?,
                                     sourceTranscript: String?, sourceCommand: InterpretedCommand?) -> String? { nil }
        func startRephraseConfirmation(_ command: InterpretedCommand, sourceTranscript: String?) {}
        func takePendingRephraseCommand() -> (command: InterpretedCommand, sourceTranscript: String?)? { nil }
        func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }
        func composeMessage(toContactNamed name: String?, body: String,
                            requestedApp: String?) -> MessageComposeOutcome { .contactNotFound }
        func presentPluginView(_ view: AnyView) {}
        func requestContactSearch(query: String?) {}
        func requestNavigation(to target: DirectionsRoute.PlaceTarget) {}
        func requestNavigationDisambiguation(targets: [DirectionsCandidate]) -> String? { nil }
        func requestAlarmSet(at time: Date, label: String?) async -> AlarmTimerSetOutcome { .failed }
        func requestTimerStart(durationSeconds: Int, label: String?) async -> AlarmTimerSetOutcome { .failed }
        func fireMorningBriefing() {}
        func fireNewsReader() {}
    }

    private final class RecordingBus: ObservabilityBus {
        func emit(_ event: ObservabilityEvent) {}
    }

    private func makeHarness() -> (pipeline: VoicePipeline, vad: HangoverFakeVAD,
                                   defaults: UserDefaults) {
        let vad = HangoverFakeVAD()
        let defaults = freshDefaults()
        let router = CommandRouter(coordinator: MockCoordinator(),
                                   observabilityBus: RecordingBus())
        let session = AudioSessionManager(observabilityBus: RecordingBus(),
                                          audioSession: RecordingSession(),
                                          defaults: freshDefaults())
        let pipeline = VoicePipeline(
            audioSession: session,
            audioEngine: AVAudioEngine(),
            wakeWordEngine: NullWakeWordEngine(),
            wakeWordGate: nil,
            speechRecognizer: FakeRecognizer(),
            voiceActivityDetector: vad,
            router: router,
            observabilityBus: RecordingBus()
        )
        pipeline.vadHangoverDefaults = defaults
        return (pipeline, vad, defaults)
    }

    func testPipelineStartsVADWithAdaptivePolicyByDefault() {
        let h = makeHarness()
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        XCTAssertEqual(h.vad.startedPolicies, [.production],
                       "the capture hands the adaptive policy to the VAD by default")
    }

    func testPipelineStartsVADWithFixedTrimWhenExplicitlyOn() {
        let h = makeHarness()
        h.defaults.set(true, forKey: VADHangoverPolicy.trim700DefaultsKey)
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        XCTAssertEqual(h.vad.startedPolicies, [.fixed(VADHangoverPolicy.trimmedMs)],
                       "the explicitly-enabled trim hands the fixed 700 ms policy")
    }

    func testPipelineReadsTheFlagPerCapture() {
        let h = makeHarness()
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        h.pipeline.stop()
        // Flip the trim ON mid-session: the NEXT capture picks it up.
        h.defaults.set(true, forKey: VADHangoverPolicy.trim700DefaultsKey)
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        XCTAssertEqual(h.vad.startedPolicies,
                       [AdaptiveEndpointPolicy.production,
                        .fixed(VADHangoverPolicy.trimmedMs)],
                       "the policy is read at capture start, not cached at launch")
    }

    // MARK: - Adaptive integration (the field case)
    //
    // The owner's sentence: "मलाई भोलि बिहान ७ बजे … औषधि खान …
    // सम्झाउनु" — natural pauses of 0.7-1.2 s. The detector learns the
    // speaker's pause from the FIRST pause and never cuts the second.

    /// The measured field case: the FIRST pause exceeds the old 1200 ms
    /// initial window (the owner's cut at "७ बजे"). 2000 ms rides through
    /// it, and the learned window covers every later pause.
    func testFirstPauseUpToTwoSecondsIsProtected() {
        let vad = EnergyVAD()
        var ended = false
        vad.onEndOfUtterance = { ended = true }

        vad.start(policy: .production)
        for f in frames(3_000, count: 8) { vad.process(f) }     // "मलाई भोलि बिहान ७ बजे"
        for f in frames(0, count: 84) { vad.process(f) }        // ~2.69 s first breath
        XCTAssertFalse(ended, "a 2.69 s first pause must not cut the capture")
        for f in frames(3_000, count: 6) { vad.process(f) }     // "औषधि खान सम्झाउनु"
        // The learned window is the full 2800 ms cap (the 2.69 s pause) —
        // the final silence must exceed it: 90 frames = 2880 ms, still
        // under the 3 s force end.
        for f in frames(0, count: 90) { vad.process(f) }        // ~2.88 s final silence
        XCTAssertTrue(ended, "the finished utterance still ends after the final silence")
    }

    func testDeliberateSpeakerIsNeverCutAtTheirOwnPause() {
        let vad = EnergyVAD()
        var ended = false
        vad.onEndOfUtterance = { ended = true }

        vad.start(policy: .production)
        for f in frames(3_000, count: 8) { vad.process(f) }     // "मलाई भोलि"
        for f in frames(0, count: 25) { vad.process(f) }        // ~0.8 s breath
        XCTAssertFalse(ended, "the first pause must never end the capture")
        for f in frames(3_000, count: 6) { vad.process(f) }     // "बिहान ७ बजे"
        for f in frames(0, count: 30) { vad.process(f) }        // ~0.96 s pause — below the learned 1280 window
        XCTAssertFalse(ended, "the learned window rides through the second pause")
        for f in frames(3_000, count: 6) { vad.process(f) }     // "औषधि खान सम्झाउनु"
        // The two pauses taught a 1800 ms window (the raised floor) — the
        // final silence must exceed it (60 frames = 1920 ms; still below
        // the 3 s force end).
        for f in frames(0, count: 60) { vad.process(f) }        // ~1.92 s final silence
        XCTAssertTrue(ended, "after the last word the capture ends within the learned window")
    }
}
