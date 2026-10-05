import XCTest
import AVFoundation
import SwiftUI
@testable import ElderlyAssistant

/// T-095: the `VoicePipeline` wake-acknowledgment seam, exercised with
/// fakes exactly like `VoicePipelineNoiseFilterSeamTests` /
/// `VoiceTurnTimingSeamTests` — no audio hardware, no `start()` (the
/// `inputNode` abort doctrine). The seam's nil default must preserve
/// today's synchronous capture start; a set seam moves capture behind the
/// ack completion; the generation check makes stale completions inert.
///
/// The racing-detection pair's other half (the service's supersede
/// teardown) lives in `WakeAcknowledgmentServiceTests`.
final class WakeAcknowledgmentSeamTests: XCTestCase {

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
        func emit(_ event: ObservabilityEvent) { events.append(event) }
    }

    /// The seam stub: records every `begin` in order and exposes the
    /// completions for the test to fire — in ANY order, so the pipeline's
    /// generation guard is what is being measured.
    private final class StubAcknowledger: WakeAcknowledging {
        private(set) var beginCalls = 0
        private(set) var cancelCalls = 0
        private(set) var completions: [() -> Void] = []
        var onBegin: (() -> Void)?
        var onCancel: (() -> Void)?

        func begin(completion: @escaping () -> Void) {
            beginCalls += 1
            completions.append(completion)
            onBegin?()
        }

        func cancel() {
            cancelCalls += 1
            onCancel?()
        }

        func complete(at index: Int) {
            completions[index]()
        }
    }

    private final class FakeRecognizer: SpeechRecognizerProtocol {
        var isAvailable = true
        let ownsAudioCapture = false
        private(set) var startCalls = 0
        private(set) var cancelCalls = 0
        var onCancel: (() -> Void)?

        func requestAuthorization(_ callback: @escaping (Bool) -> Void) {
            callback(true)
        }

        func startListening(timeout: TimeInterval,
                            completion: @escaping (Result<String, RecognitionError>) -> Void) {
            startCalls += 1
        }

        func feed(_ buffer: AVAudioPCMBuffer) {}

        func finish() {}

        func cancel() {
            cancelCalls += 1
            onCancel?()
        }
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

    private final class RecordingNoiseSuppressor: NoiseSuppressor {
        enum Call: Equatable {
            case captureStarted
            case captureEnded
        }
        let requiredSampleRate: Double = 16_000
        let name = "fake_engine"
        let latencySamples = 0
        private(set) var calls: [Call] = []

        func process(_ samples: [Int16]) -> [Int16] { samples }
        func reset() {}
        func setMode(_ mode: NoiseSuppressorMode) {}
        func captureStarted() { calls.append(.captureStarted) }
        func captureEnded() { calls.append(.captureEnded) }
    }

    /// Trimmed copy of the `CommandRouterTests` mock (kept complete so
    /// protocol evolution surfaces as a compile error, not a silent
    /// default) — same shape as the noise-filter seam suite.
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

    // MARK: - Helpers

    private func makePipeline(noiseSuppressor: NoiseSuppressor? = nil)
        -> (pipeline: VoicePipeline, recognizer: FakeRecognizer,
            vad: FakeVAD, bus: RecordingBus) {
        let bus = RecordingBus()
        let recognizer = FakeRecognizer()
        let vad = FakeVAD()
        let defaults = UserDefaults(suiteName: "ack-seam-\(UUID().uuidString)")!
        let session = AudioSessionManager(observabilityBus: bus,
                                          audioSession: RecordingSession(),
                                          defaults: defaults)
        // Never started: init only wires callbacks and stores the stages —
        // no inputNode, no tap, no audio server.
        let pipeline = VoicePipeline(
            audioSession: session,
            audioEngine: AVAudioEngine(),
            wakeWordEngine: NullWakeWordEngine(),
            wakeWordGate: nil,
            speechRecognizer: recognizer,
            voiceActivityDetector: vad,
            noiseSuppressor: noiseSuppressor,
            router: CommandRouter(coordinator: MockVoiceCommandCoordinator(),
                                  observabilityBus: bus),
            observabilityBus: bus
        )
        return (pipeline, recognizer, vad, bus)
    }

    // MARK: - Scenario: nil seam = today's synchronous capture start

    func testNilSeamStartsCaptureSynchronously() {
        let suppressor = RecordingNoiseSuppressor()
        let (pipeline, recognizer, _, _) = makePipeline(noiseSuppressor: suppressor)
        pipeline.debugEnterIdleForTesting()

        pipeline.simulateWakeWordDetection()

        XCTAssertEqual(recognizer.startCalls, 1,
                       "no seam: capture starts in the same runloop turn")
        XCTAssertEqual(pipeline.state, .capturingCommand)
        XCTAssertEqual(suppressor.calls, [.captureStarted],
                       "the noise-filter bookend still opens the capture")
    }

    // MARK: - Scenario: with a seam, capture follows the completion

    func testCaptureWaitsForTheAckCompletion() {
        let suppressor = RecordingNoiseSuppressor()
        let (pipeline, recognizer, _, _) = makePipeline(noiseSuppressor: suppressor)
        let stub = StubAcknowledger()
        pipeline.wakeAcknowledger = stub
        pipeline.debugEnterIdleForTesting()

        pipeline.simulateWakeWordDetection()

        XCTAssertEqual(stub.beginCalls, 1, "the ack begins at detection")
        XCTAssertEqual(recognizer.startCalls, 0,
                       "no recognizer start before the completion")
        XCTAssertEqual(pipeline.state, .idle,
                       "the pipeline stays idle while the greeting plays")
        XCTAssertTrue(suppressor.calls.isEmpty,
                      "the capture bookend belongs to beginCapture")

        stub.complete(at: 0)

        XCTAssertEqual(recognizer.startCalls, 1, "capture starts exactly once")
        XCTAssertEqual(pipeline.state, .capturingCommand)
        XCTAssertEqual(suppressor.calls, [.captureStarted],
                       "the bookend runs once, inside beginCapture")
    }

    // MARK: - Scenario: the Talk button gets the same acknowledgment

    func testTheTalkButtonRoutesThroughTheSameSeam() {
        let (pipeline, recognizer, _, _) = makePipeline()
        let stub = StubAcknowledger()
        pipeline.wakeAcknowledger = stub
        pipeline.debugEnterIdleForTesting()

        pipeline.simulateWakeWordDetection() // the Talk button's entry point

        XCTAssertEqual(stub.beginCalls, 1,
                       "the button's detection is acknowledged before capture")
        XCTAssertEqual(recognizer.startCalls, 0)
        stub.complete(at: 0)
        XCTAssertEqual(recognizer.startCalls, 1)
    }

    // MARK: - Scenario: a stale completion is inert

    func testACompletionAfterStopIsInert() {
        let (pipeline, recognizer, _, _) = makePipeline()
        let stub = StubAcknowledger()
        pipeline.wakeAcknowledger = stub
        pipeline.debugEnterIdleForTesting()

        pipeline.simulateWakeWordDetection()
        pipeline.stop()
        XCTAssertEqual(stub.cancelCalls, 1, "stop cancels the in-flight ack")

        stub.complete(at: 0) // the deferred completion fires after the stop

        XCTAssertEqual(recognizer.startCalls, 0, "no capture after stop")
        XCTAssertEqual(pipeline.state, .stopped)
    }

    // MARK: - Scenario: stop cancels the ack before engine teardown

    func testStopCancelsTheAckBeforeEngineTeardown() {
        var order: [String] = []
        let (pipeline, recognizer, _, _) = makePipeline()
        let stub = StubAcknowledger()
        stub.onCancel = { order.append("ack_cancel") }
        recognizer.onCancel = { order.append("recognizer_cancel") }
        pipeline.wakeAcknowledger = stub
        pipeline.debugEnterIdleForTesting()

        pipeline.simulateWakeWordDetection()
        pipeline.stop()

        XCTAssertEqual(stub.cancelCalls, 1)
        XCTAssertEqual(order, ["ack_cancel", "recognizer_cancel"],
                       "the ack is cancelled before the engine teardown")
    }

    // MARK: - Scenario: the AM-3 racing window and the supersede path

    func testRacingDetectionNeverDoublesTheCaptureStart() {
        let suppressor = RecordingNoiseSuppressor()
        let (pipeline, recognizer, _, _) = makePipeline(noiseSuppressor: suppressor)
        let stub = StubAcknowledger()
        pipeline.wakeAcknowledger = stub
        pipeline.debugEnterIdleForTesting()

        // First detection: the ack begins. The gate has NOT closed yet —
        // the shipped `noteSpeakingStarted` hook closes it inside a
        // main-queue async (AM-3), so `state` is still `.idle`.
        pipeline.simulateWakeWordDetection()
        XCTAssertEqual(stub.beginCalls, 1)
        XCTAssertEqual(pipeline.state, .idle, "the AM-3 window is open")

        // The racing second detection passes the same gate and begins a
        // new ack; the service's supersede teardown owns the old one (its
        // half is pinned in WakeAcknowledgmentServiceTests).
        pipeline.simulateWakeWordDetection()
        XCTAssertEqual(stub.beginCalls, 2, "the second begin tears down the first")

        // The OLD completion fires late: the pipeline's generation check
        // makes it inert (it belongs to the superseded capture epoch).
        stub.complete(at: 0)
        XCTAssertEqual(recognizer.startCalls, 0,
                       "a stale completion never starts a capture")
        XCTAssertEqual(pipeline.state, .idle)

        // The new completion starts capture exactly once.
        stub.complete(at: 1)
        XCTAssertEqual(recognizer.startCalls, 1,
                       "the worst outcome is a restarted greeting — never a "
                       + "doubled capture start")
        XCTAssertEqual(suppressor.calls, [.captureStarted],
                       "the bookend ran exactly once")
        XCTAssertEqual(pipeline.state, .capturingCommand)
    }
}
