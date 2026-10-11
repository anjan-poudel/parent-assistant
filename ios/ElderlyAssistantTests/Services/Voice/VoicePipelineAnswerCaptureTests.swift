import XCTest
import AVFoundation
import SwiftUI
@testable import ElderlyAssistant

/// [MULTI-TURN AUTO-LISTEN] (2026-10-11) — the `beginAnswerCapture()`
/// seam: the slot answer window opens a capture epoch WITHOUT the wake
/// acknowledgment (the "Yes, Mum" greeting would interrupt the
/// conversation) and emits `answer_capture_opened` instead of
/// `wake_word_detected`. Same doctrine as
/// `VoicePipelineNoiseFilterSeamTests`: fakes only, no audio hardware,
/// `start()` never called (`debugEnterIdleForTesting` is the idle seam).
final class VoicePipelineAnswerCaptureTests: XCTestCase {

    // MARK: - Fakes

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

    private final class RecordingBus: ObservabilityBus {
        private(set) var events: [ObservabilityEvent] = []
        func emit(_ event: ObservabilityEvent) {
            events.append(event)
        }
        func events(ofType type: String) -> [ObservabilityEvent] {
            events.filter { $0.eventType == type }
        }
    }

    private final class FakeRecognizer: SpeechRecognizerProtocol {
        var isAvailable = true
        let ownsAudioCapture = false
        private(set) var startCalls = 0
        private var completion: ((Result<String, RecognitionError>) -> Void)?

        func requestAuthorization(_ callback: @escaping (Bool) -> Void) {
            callback(true)
        }
        func startListening(timeout: TimeInterval,
                            completion: @escaping (Result<String, RecognitionError>) -> Void) {
            startCalls += 1
            self.completion = completion
        }
        func feed(_ buffer: AVAudioPCMBuffer) {}
        func finish() {}
        func cancel() {}
    }

    private final class FakeVAD: VoiceActivityDetector {
        let requiredSampleRate: Double = 16_000
        let frameLength = 512
        var onSpeechStateChange: ((Bool) -> Void)?
        var onEndOfUtterance: (() -> Void)?
        private(set) var startCalls = 0
        func start(endOfUtteranceMs: Int) { startCalls += 1 }
        func stop() {}
        func reset() {}
        func process(_ pcm: [Int16]) {}
    }

    /// Records `begin` without ever completing it, so a test can prove
    /// capture is deferred to the ack's completion (and, for the
    /// auto-listen seam, that it is never consulted at all).
    private final class RecordingAck: WakeAcknowledging {
        private(set) var beginCalls = 0
        private var pending: [() -> Void] = []
        func begin(completion: @escaping () -> Void) {
            beginCalls += 1
            pending.append(completion)
        }
        func cancel() {}
        func fireLast() {
            guard let last = pending.last else { return }
            pending.removeAll()
            last()
        }
    }

    private final class MockVoiceCommandCoordinator: VoiceCommandCoordinating {
        var isAwaitingConfirmation = false
        var brainReadiness = BrainReadiness.available
        var isAwaitingCallConfirmation = false
        var activeLocale: Locale { Locale(identifier: "ne-NP") }
        var canAnswerLiveQuestionsFromWeb = false
        var isOnDeviceStack = false
        var navigationCandidates: [DirectionsCandidate] = []
        var isAwaitingNavigationDisambiguation = false
        var pendingRephraseCommand: InterpretedCommand? { nil }
        var recordedTranscripts: [String] = []

        func recordTranscript(_ text: String) { recordedTranscripts.append(text) }
        func oldestPendingReminderEntryId() -> UUID? { nil }
        func handleMedicationAcknowledgement(entryId: UUID) {}
        func startVoiceAckConfirmation(for entryId: UUID) -> String? { nil }
        func handleConfirmationResponse(_ response: ConfirmationResponse) {}
        func noteSpeakingStarted() {}
        func noteSpeakingEnded() {}
        func noteAssistantSpoke(_ text: String) {}
        func noteGenericReply(_ text: String) {}
        func addVoiceReminder(title: String, time: DateComponents) {}
        func requestCallConfirmation(contactQuery: String?, callType: String?,
                                     requestedApp: String?, sourceTranscript: String?,
                                     sourceCommand: InterpretedCommand?) -> String? { nil }
        func startRephraseConfirmation(_ command: InterpretedCommand,
                                       sourceTranscript: String?) {}
        func takePendingRephraseCommand()
            -> (command: InterpretedCommand, sourceTranscript: String?)? { nil }
        func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }
        func composeMessage(toContactNamed name: String?, body: String,
                            requestedApp: String?) -> MessageComposeOutcome {
            .contactNotFound
        }
        func presentPluginView(_ view: AnyView) {}
        func requestContactSearch(query: String?) {}
        func requestNavigation(to target: DirectionsRoute.PlaceTarget) {}
        func requestNavigationDisambiguation(targets: [DirectionsCandidate]) -> String? { nil }
        func requestAlarmSet(at time: Date, label: String?) async -> AlarmTimerSetOutcome { .failed }
        func requestTimerStart(durationSeconds: Int, label: String?) async -> AlarmTimerSetOutcome { .failed }
        func fireMorningBriefing() {}
    }

    // MARK: - Fixture

    private func makePipeline(ack: RecordingAck? = nil)
        -> (pipeline: VoicePipeline, recognizer: FakeRecognizer,
            vad: FakeVAD, bus: RecordingBus) {
        let bus = RecordingBus()
        let recognizer = FakeRecognizer()
        let vad = FakeVAD()
        let defaults = UserDefaults(suiteName: "answer-capture-\(UUID().uuidString)")!
        let session = AudioSessionManager(observabilityBus: bus,
                                          audioSession: RecordingSession(),
                                          defaults: defaults)
        let pipeline = VoicePipeline(
            audioSession: session,
            audioEngine: AVAudioEngine(),
            wakeWordEngine: NullWakeWordEngine(),
            wakeWordGate: nil,
            speechRecognizer: recognizer,
            voiceActivityDetector: vad,
            noiseSuppressor: nil,
            router: CommandRouter(coordinator: MockVoiceCommandCoordinator(),
                                  observabilityBus: bus),
            observabilityBus: bus
        )
        pipeline.wakeAcknowledger = ack
        return (pipeline, recognizer, vad, bus)
    }

    // MARK: - Tests

    func testBeginAnswerCaptureOpensTheMicWithoutTheWakeAck() {
        let ack = RecordingAck()
        let (pipeline, recognizer, _, bus) = makePipeline(ack: ack)
        pipeline.debugEnterIdleForTesting()

        pipeline.beginAnswerCapture()

        XCTAssertEqual(pipeline.state, .capturingCommand,
                       "the answer window opens a capture epoch")
        XCTAssertEqual(recognizer.startCalls, 1,
                       "STT starts synchronously — no ack in front of it")
        XCTAssertEqual(ack.beginCalls, 0,
                       "no wake acknowledgment for an auto-open (it is not a wake)")
        XCTAssertEqual(bus.events(ofType: "answer_capture_opened").count, 1)
        XCTAssertTrue(bus.events(ofType: "wake_word_detected").isEmpty,
                      "the answer capture must not masquerade as a wake")
    }

    func testWakeAndTalkPathsStillAcknowledgeBeforeCapture() {
        let ack = RecordingAck()
        let (pipeline, recognizer, _, bus) = makePipeline(ack: ack)
        pipeline.debugEnterIdleForTesting()

        pipeline.simulateWakeWordDetection()

        XCTAssertEqual(ack.beginCalls, 1,
                       "the Talk path keeps the wake acknowledgment")
        XCTAssertEqual(recognizer.startCalls, 0,
                       "capture is deferred to the ack's completion")
        XCTAssertEqual(pipeline.state, .idle,
                       "the pipeline waits for the ack before capturing")
        XCTAssertEqual(bus.events(ofType: "wake_word_detected").count, 1)

        ack.fireLast()
        XCTAssertEqual(recognizer.startCalls, 1,
                       "the ack's completion opens the capture")
        XCTAssertEqual(pipeline.state, .capturingCommand)
    }

    func testBeginAnswerCaptureIsInertWhileStopped() {
        let ack = RecordingAck()
        let (pipeline, recognizer, _, bus) = makePipeline(ack: ack)
        // Never debugEnterIdleForTesting — a stopped pipeline owns its
        // own start (the boot's start()), like the wake path's guard.

        pipeline.beginAnswerCapture()

        XCTAssertEqual(pipeline.state, .stopped)
        XCTAssertEqual(recognizer.startCalls, 0)
        XCTAssertEqual(ack.beginCalls, 0)
        XCTAssertTrue(bus.events(ofType: "answer_capture_opened").isEmpty)
    }
}
