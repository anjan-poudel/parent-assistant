import XCTest
import AVFoundation
import SwiftUI
@testable import ElderlyAssistant

/// [LAT-M2] Tests for the flag-gated VAD hangover trim: the pure policy
/// (700 ms by default, 900 ms when explicitly OFF), the EnergyVAD's
/// frame-level end latency at the trimmed value, and the pipeline seam
/// that hands the policy's value to the detector per capture.
/// The existing EnergyVADTests pin the 900 ms world with explicit
/// values — untouched, they stay green alongside these.
final class VADHangoverTrimTests: XCTestCase {

    // MARK: - Policy (pure)

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "vad-hangover-\(UUID().uuidString)")!
    }

    func testDefaultIsTrimmed700() {
        XCTAssertEqual(VADHangoverPolicy.hangoverMs(defaults: freshDefaults()),
                       VADHangoverPolicy.trimmedMs,
                       "the trim is ON by default (the plan's default-ON contract)")
    }

    func testExplicitFalseRestores900() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: VADHangoverPolicy.trim700DefaultsKey)
        XCTAssertEqual(VADHangoverPolicy.hangoverMs(defaults: defaults),
                       VADHangoverPolicy.legacyMs,
                       "the field can restore the pre-trim hangover without a release")
    }

    func testExplicitTrueKeeps700() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: VADHangoverPolicy.trim700DefaultsKey)
        XCTAssertEqual(VADHangoverPolicy.hangoverMs(defaults: defaults),
                       VADHangoverPolicy.trimmedMs)
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

        vad.start(endOfUtteranceMs: VADHangoverPolicy.trimmedMs)
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

        vad.start(endOfUtteranceMs: VADHangoverPolicy.legacyMs)
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

        vad.start(endOfUtteranceMs: VADHangoverPolicy.trimmedMs)
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

        vad.start(endOfUtteranceMs: VADHangoverPolicy.trimmedMs)
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
        private(set) var startedMs: [Int] = []
        func start(endOfUtteranceMs: Int) { startedMs.append(endOfUtteranceMs) }
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

    func testPipelineStartsVADWithTrimmed700ByDefault() {
        let h = makeHarness()
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        XCTAssertEqual(h.vad.startedMs, [VADHangoverPolicy.trimmedMs],
                       "the capture hands the trimmed hangover to the VAD by default")
    }

    func testPipelineStartsVADWith900WhenFlagOff() {
        let h = makeHarness()
        h.defaults.set(false, forKey: VADHangoverPolicy.trim700DefaultsKey)
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        XCTAssertEqual(h.vad.startedMs, [VADHangoverPolicy.legacyMs],
                       "the flag OFF restores the pre-trim hangover per capture")
    }

    func testPipelineReadsTheFlagPerCapture() {
        let h = makeHarness()
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        h.pipeline.stop()
        // Flip the flag mid-session: the NEXT capture picks it up.
        h.defaults.set(false, forKey: VADHangoverPolicy.trim700DefaultsKey)
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        XCTAssertEqual(h.vad.startedMs, [700, 900],
                       "the hangover is read at capture start, not cached at launch")
    }
}
