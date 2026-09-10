import XCTest
import AVFoundation
import SwiftUI
@testable import ElderlyAssistant

/// [TURN-TIMING] Seam tests for the turn-timing wiring: the REAL
/// VoicePipeline + CommandRouter composition (with fakes for audio,
/// recognizer, VAD, interpreter and speaker) must emit exactly ONE
/// `voice_turn_timing` event per turn with the expected stages in order.
/// No audio hardware, no network — the same doctrine as
/// VoicePipelineNoiseFilterSeamTests (the inputNode hazard is never
/// reached: the pipeline is never `start()`ed).
final class VoiceTurnTimingSeamTests: XCTestCase {

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
        func setVoiceProcessingEnabled(_ enabled: Bool) throws {}
    }

    private final class RecordingBus: ObservabilityBus {
        private(set) var events: [ObservabilityEvent] = []
        func emit(_ event: ObservabilityEvent) {
            events.append(event)
        }
        var turnTimingEvents: [ObservabilityEvent] {
            events.filter { $0.eventType == "voice_turn_timing" }
        }
    }

    /// Holds the pipeline completion until the test fires it — the same
    /// shape as the production recognizers' async completion.
    private final class FakeRecognizer: SpeechRecognizerProtocol {
        let ownsAudioCapture = false
        var isAvailable = true
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

        func cancel() {
            guard let completion else { return }
            self.completion = nil
            completion(.failure(.cancelled))
        }

        func complete(with result: Result<String, RecognitionError>) {
            guard let completion else { return }
            self.completion = nil
            completion(result)
        }
    }

    private final class FakeVAD: VoiceActivityDetector {
        let requiredSampleRate: Double = 16_000
        let frameLength = 512
        var onSpeechStateChange: ((Bool) -> Void)?
        var onEndOfUtterance: (() -> Void)?
        func start(endOfUtteranceMs: Int) {}
        func stop() {}
        func reset() {}
        func process(_ pcm: [Int16]) {}
    }

    /// Async speaker that settles after a short suspension — long enough
    /// that the main-queue tail (router_done / endTurn) provably runs
    /// before `speak_finished` marks, so the stage ORDER assertions are
    /// deterministic. Speech duration itself is not what these tests pin.
    private final class FakeSpeaker: Speaker {
        private(set) var spoken: [String] = []
        func speak(_ text: String, locale: Locale) async {
            spoken.append(text)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        func cancel() {}
    }

    /// Holds the LLM completion until the test fires it (mirrors the
    /// production async interpreter round-trip).
    private final class HoldableCommandInterpreter: CommandInterpreter {
        var isAvailable = true
        private(set) var interpretCallCount = 0
        private var held: [(transcript: String,
                            context: InterpreterContext,
                            completion: (InterpretedCommand?) -> Void)] = []

        func interpret(transcript: String, context: InterpreterContext,
                       completion: @escaping (InterpretedCommand?) -> Void) {
            interpretCallCount += 1
            held.append((transcript, context, completion))
        }

        func completeNext(with command: InterpretedCommand?) {
            let item = held.removeFirst()
            item.completion(command)
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

    /// Proven interpreter-reaching transcript (QueryEndToEndRegressionTests)
    /// — no deterministic stage intercepts it, so the LLM path fires.
    private static let openQuestionTranscript = "के छ खबर?"

    // MARK: - Harness

    private final class Harness {
        let bus = RecordingBus()
        let recognizer = FakeRecognizer()
        let vad = FakeVAD()
        let interpreter = HoldableCommandInterpreter()
        let speaker = FakeSpeaker()
        let tracer: VoiceTurnLatencyTracer
        let router: CommandRouter
        let pipeline: VoicePipeline

        init() {
            let bus = self.bus
            tracer = VoiceTurnLatencyTracer(observabilityBus: bus)
            router = CommandRouter(
                coordinator: MockVoiceCommandCoordinator(),
                observabilityBus: bus,
                speaker: speaker,
                interpreter: interpreter,
                turnTracer: tracer
            )
            let defaults = UserDefaults(suiteName: "turn-timing-seam-\(UUID().uuidString)")!
            let session = AudioSessionManager(observabilityBus: bus,
                                              audioSession: RecordingSession(),
                                              defaults: defaults)
            pipeline = VoicePipeline(
                audioSession: session,
                audioEngine: AVAudioEngine(),
                wakeWordEngine: NullWakeWordEngine(),
                wakeWordGate: nil,
                speechRecognizer: recognizer,
                voiceActivityDetector: vad,
                router: router,
                observabilityBus: bus,
                turnTracer: tracer
            )
        }

        func stageNames(of eventIndex: Int = 0) -> [String] {
            let event = bus.turnTimingEvents[eventIndex]
            let raw = event.metadata["stages"] ?? "[]"
            let stages = (try? JSONDecoder()
                .decode([VoiceTurnLatencyTracer.StageTiming].self,
                        from: raw.data(using: .utf8)!)) ?? []
            return stages.map(\.stage)
        }
    }

    // MARK: - LLM path (the production async round-trip)

    func testOneTimingEventPerTurnWithOrderedStagesOnLLMPath() {
        let h = Harness()
        let finalized = expectation(description: "turn finalized")
        h.tracer.onTurnFinalized = { _, _ in finalized.fulfill() }

        // 1. Wake — the turn starts (idle entered via the debug seam:
        //    `start()` is unreachable in seam tests — inputNode hazard).
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        XCTAssertEqual(h.pipeline.state, .capturingCommand)
        XCTAssertEqual(h.recognizer.startCalls, 1)

        // 2. The VAD declares the utterance over. Its callback hops to
        //    main; the inner async below is queued AFTER that hop, so it
        //    fulfills only once `vad_end` was actually marked.
        let vadEnd = expectation(description: "vad end mark landed")
        DispatchQueue.main.async {
            h.vad.onEndOfUtterance?()
            DispatchQueue.main.async { vadEnd.fulfill() }
        }
        wait(for: [vadEnd], timeout: 2)

        // 3. Recognition completes — the pipeline routes the transcript
        //    into the router, whose interpreter holds the completion.
        h.recognizer.complete(with: .success(Self.openQuestionTranscript))
        XCTAssertEqual(h.interpreter.interpretCallCount, 1)

        // 4. The LLM answers — dispatch, speech, and the turn finalize.
        h.interpreter.completeNext(with: InterpretedCommand(
            action: .query,
            entryId: nil, contact: nil, time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: nil, topic: nil,
            steps: nil, pluginAction: nil, pluginEntities: nil,
            confidence: 0.9, reply: "सबै ठीक छ।"
        ))
        wait(for: [finalized], timeout: 2)

        XCTAssertEqual(h.bus.turnTimingEvents.count, 1,
                       "exactly ONE voice_turn_timing event per turn")
        // Chronological: llm_start fires inside route() (before it
        // returns), so it precedes router_done; speak stages trail the
        // async interpret completion. [VOICE-ACK] The pre-ack's
        // speak_queued commits BEFORE llm_start (it is spoken at route
        // time), and the reply's speak_queued trails llm_done — two
        // speak_queued/speak_finished pairs in one turn.
        XCTAssertEqual(h.stageNames(), [
            "turn_start", "vad_end", "asr_done", "speak_queued", "llm_start",
            "router_done", "llm_done", "speak_queued", "speak_finished",
            "speak_finished", "turn_end",
        ])
        XCTAssertEqual(h.bus.turnTimingEvents[0].outcome, "success")
        XCTAssertNotNil(h.bus.turnTimingEvents[0].durationMs)
        XCTAssertEqual(h.speaker.spoken, ["एक छिन…", "सबै ठीक छ।"],
                       "the pre-ack precedes the model reply — the seam alters nothing else")
    }

    // MARK: - Deterministic (sync) path

    func testOneTimingEventPerTurnOnSyncPath() {
        let h = Harness()
        let finalized = expectation(description: "turn finalized")
        h.tracer.onTurnFinalized = { _, _ in finalized.fulfill() }

        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        // Emergency — the safety net answers synchronously inside route().
        h.recognizer.complete(with: .success("मद्दत गर्नुहोस्"))
        wait(for: [finalized], timeout: 2)

        XCTAssertEqual(h.bus.turnTimingEvents.count, 1)
        // speak_queued fires synchronously INSIDE route() (the emergency
        // handler speaks before route returns), hence before router_done.
        XCTAssertEqual(h.stageNames(), [
            "turn_start", "asr_done", "speak_queued", "router_done",
            "speak_finished", "turn_end",
        ])
        XCTAssertEqual(h.interpreter.interpretCallCount, 0,
                       "the deterministic net never consults the LLM")
    }

    // MARK: - Cancellation

    func testCancelledCaptureEmitsNoTimingEvent() {
        let h = Harness()
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        h.pipeline.stop()
        // Give any (incorrect) finalize a beat to fire.
        let pause = expectation(description: "pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { pause.fulfill() }
        wait(for: [pause], timeout: 2)
        XCTAssertTrue(h.bus.turnTimingEvents.isEmpty,
                      "a cancelled capture's turn is abandoned, never emitted")
    }

    // MARK: - Honest no-speech diagnostic ([VAD-REGRESSION])

    /// A capture that ends (STT completion) without the VAD ever reporting
    /// speech must emit `capture_ended_no_vad_speech` — the console
    /// signature that separates "the capture stream never crossed the VAD
    /// speech threshold" (environment/mic) from "the recognizer is slow"
    /// (code/network).
    func testCaptureEndingWithoutVadSpeechEmitsHonestEvent() {
        let h = Harness()
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        h.recognizer.complete(with: .failure(.timedOut))

        XCTAssertTrue(h.bus.events.contains { $0.component == "voice_pipeline"
                && $0.eventType == "capture_ended_no_vad_speech" },
                      "a capture with a VAD that never detected speech emits the honest diagnostic")
    }

    /// The positive twin: once the VAD has reported speech, the same
    /// capture end must NOT emit the no-speech diagnostic.
    func testCaptureWithVadSpeechDoesNotEmitNoSpeechEvent() {
        let h = Harness()
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        h.vad.onSpeechStateChange?(true)  // the VAD heard the user
        h.recognizer.complete(with: .failure(.timedOut))

        XCTAssertFalse(h.bus.events.contains { $0.component == "voice_pipeline"
                && $0.eventType == "capture_ended_no_vad_speech" },
                       "speech was detected — the no-speech diagnostic must stay silent")
    }
}
