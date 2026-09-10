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
        func setMode(_ mode: AVAudioSession.Mode) throws {}
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
        /// [VAD-TUNE] Counts VAD-driven finish() calls (normal + forced
        /// ends share the same pipeline hop).
        private(set) var finishCalls = 0
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

        func finish() { finishCalls += 1 }

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
        /// [VAD-TUNE] Real storage (not the protocol's default no-op) so
        /// the pipeline's forced-end wiring is reachable from tests.
        var onForcedEndOfUtterance: (() -> Void)?
        /// [VAD-RT] Call sequence across lifecycle methods + frame count —
        /// pins the capture-start priming ORDER (reset/start before the
        /// first process) and the frame-latency event math.
        private(set) var calls: [String] = []
        private(set) var frames: [[Int16]] = []
        func start(endOfUtteranceMs: Int) { calls.append("start") }
        func stop() { calls.append("stop") }
        func reset() { calls.append("reset") }
        func process(_ pcm: [Int16]) {
            calls.append("process")
            frames.append(pcm)
        }
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
        // [VAD-RT] `vad_fired` (marked on the VAD's queue, before the
        // main hop) precedes `vad_end` (marked after the hop) — the
        // hop-wait span between them is the first-turn main-thread stall
        // detector.
        XCTAssertEqual(h.stageNames(), [
            "turn_start", "vad_fired", "vad_end", "asr_done", "speak_queued",
            "llm_start", "router_done", "llm_done", "speak_queued",
            "speak_finished", "speak_finished", "turn_end",
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

    // MARK: - VAD force end ([VAD-TUNE])

    /// The trailing-silence force end ends the capture exactly like a
    /// normal end — finish() feeds the recognizer — but emits the honest
    /// `vad_force_end` event so device logs distinguish a noise-held
    /// pause from a genuine silence-detection end.
    func testForcedVADEndEmitsVadForceEndAndFinishesCapture() {
        let h = Harness()
        let finalized = expectation(description: "turn finalized")
        h.tracer.onTurnFinalized = { _, _ in finalized.fulfill() }

        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        XCTAssertEqual(h.pipeline.state, .capturingCommand)

        // The VAD's force end fires; its handler hops to main. The inner
        // async is queued AFTER that hop, so it fulfills only once the
        // forced end was actually processed.
        let forcedEnd = expectation(description: "forced end processed")
        DispatchQueue.main.async {
            h.vad.onForcedEndOfUtterance?()
            DispatchQueue.main.async { forcedEnd.fulfill() }
        }
        wait(for: [forcedEnd], timeout: 2)

        XCTAssertEqual(h.recognizer.finishCalls, 1,
                       "the forced end must finish the recognizer")
        XCTAssertTrue(h.bus.events.contains { $0.component == "voice_pipeline"
                && $0.eventType == "vad_force_end" },
                      "the forced end emits the honest vad_force_end event")
        XCTAssertFalse(h.bus.events.contains { $0.component == "voice_pipeline"
                && $0.eventType == "vad_end_of_utterance" },
                       "a forced end must not masquerade as a normal silence end")

        // Emergency transcript: the deterministic net answers
        // synchronously, so the turn finalizes without an LLM round-trip.
        h.recognizer.complete(with: .success("मद्दत गर्नुहोस्"))
        wait(for: [finalized], timeout: 2)

        XCTAssertEqual(h.bus.turnTimingEvents.count, 1)
        XCTAssertTrue(h.stageNames().contains("vad_end"),
                      "the forced end marks vad_end like a normal end")
        // [VAD-RT] The forced end also marks `vad_fired` before the hop —
        // the same instrumentation as the normal end.
        let stages = h.stageNames()
        XCTAssertTrue(stages.contains("vad_fired"),
                      "the forced end marks vad_fired like a normal end")
        XCTAssertLessThan(stages.firstIndex(of: "vad_fired")!,
                          stages.firstIndex(of: "vad_end")!,
                          "vad_fired precedes vad_end (hop wait between them)")
    }

    /// The normal silence-detection end keeps its existing event and
    /// behavior — the forced-end wiring must not disturb it.
    func testNormalVADEndEmitsVadEndOfUtteranceEvent() {
        let h = Harness()
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()

        let normalEnd = expectation(description: "normal end processed")
        DispatchQueue.main.async {
            h.vad.onEndOfUtterance?()
            DispatchQueue.main.async { normalEnd.fulfill() }
        }
        wait(for: [normalEnd], timeout: 2)

        XCTAssertEqual(h.recognizer.finishCalls, 1)
        XCTAssertTrue(h.bus.events.contains { $0.component == "voice_pipeline"
                && $0.eventType == "vad_end_of_utterance" })
        XCTAssertFalse(h.bus.events.contains { $0.component == "voice_pipeline"
                && $0.eventType == "vad_force_end" },
                       "a normal end must not emit the forced-end event")
    }

    // MARK: - VAD real-time diagnostics ([VAD-RT], 2026-09-11)
    //
    // The first-turn instrumentation: the hop wait between the VAD's
    // fire (processing queue) and `finish()` (main hop) is measured and
    // carried as `hop_ms` on the end event, and every capture reports
    // its per-frame VAD processing cost via `vad_frame_latency`. These
    // seams pin both with an injected monotonic clock.

    /// Deterministic injected clock: first read (the fire, on the VAD
    /// callback's queue) = 0 ns, second read (the main hop) = 5 000 000
    /// ns — so the measured hop is exactly 5 ms.
    private final class FakeVADClock {
        private let lock = NSLock()
        private var callCount = 0
        func now() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            let value: UInt64 = callCount == 0 ? 0 : 5_000_000
            callCount += 1
            return value
        }
    }

    /// The VAD end event carries `hop_ms` — the main-queue hop wait the
    /// VAD's end decision paid before `finish()`. This is the
    /// first-turn stall detector: a large hop_ms on the FIRST turn
    /// means the main thread was busy (e.g. the simulator's
    /// main-thread KWS build), not that the VAD was slow.
    func testVADEndEventCarriesMeasuredHopMs() {
        let h = Harness()
        let clock = FakeVADClock()
        h.pipeline.vadClock = clock.now

        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()

        let processed = expectation(description: "end processed")
        DispatchQueue.main.async {
            h.vad.onEndOfUtterance?()
            DispatchQueue.main.async { processed.fulfill() }
        }
        wait(for: [processed], timeout: 2)

        let event = h.bus.events.first { $0.component == "voice_pipeline"
            && $0.eventType == "vad_end_of_utterance" }
        XCTAssertNotNil(event, "the end event fires")
        XCTAssertEqual(event?.metadata["hop_ms"], "5",
                       "the injected clock pins the measured main-hop wait at 5 ms")
    }

    /// Every VAD-driven capture end reports `vad_frame_latency` with the
    /// per-frame processing stats accumulated on the processing queue
    /// (frame count + max/mean microseconds, including frame extraction).
    func testVadFrameLatencyEventReportsPerCaptureFrameStats() {
        let h = Harness()
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()

        // Feed 2048 samples -> 4 VAD frames through the real seam.
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: 16_000, channels: 1,
                                   interleaved: true)!
        let samples = [Int16](repeating: 3_000, count: 2_048)
        let buffer = VoicePipeline.makeInt16Buffer(from: samples, format: format)
        h.pipeline.feedCapture(pcm: samples, buffer: buffer)
        XCTAssertEqual(h.vad.frames.count, 4,
                       "the VAD consumes the stream sliced into 512-sample frames")

        let processed = expectation(description: "end processed")
        DispatchQueue.main.async {
            h.vad.onEndOfUtterance?()
            DispatchQueue.main.async { processed.fulfill() }
        }
        wait(for: [processed], timeout: 2)

        let event = h.bus.events.first { $0.component == "voice_pipeline"
            && $0.eventType == "vad_frame_latency" }
        XCTAssertNotNil(event, "a VAD-ended capture reports vad_frame_latency")
        XCTAssertEqual(event?.metadata["frames"], "4",
                       "the reported frame count matches the frames processed")
        let meanUs = event?.metadata["mean_us"].flatMap(UInt64.init)
        let maxUs = event?.metadata["max_us"].flatMap(UInt64.init)
        XCTAssertNotNil(meanUs, "mean_us is reported")
        XCTAssertNotNil(maxUs, "max_us is reported")
        XCTAssertLessThanOrEqual(meanUs ?? 0, maxUs ?? 0,
                                 "the mean can never exceed the max")
        XCTAssertLessThan(maxUs ?? .max, 32_000,
                          "per-frame VAD cost sits far inside the 32 ms realtime frame budget")
    }

    /// [VAD-RT] Capture-start priming order: the VAD is reset and
    /// started BEFORE any frame reaches it — the first capture chunk can
    /// never be processed against an un-primed detector (the old order
    /// let the processing queue race main's reset on the first turn).
    func testVadIsPrimedBeforeAnyCaptureFrameProcesses() {
        let h = Harness()
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()

        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: 16_000, channels: 1,
                                   interleaved: true)!
        let samples = [Int16](repeating: 1_000, count: 512)
        let buffer = VoicePipeline.makeInt16Buffer(from: samples, format: format)
        h.pipeline.feedCapture(pcm: samples, buffer: buffer)

        XCTAssertEqual(Array(h.vad.calls.prefix(3)), ["reset", "start", "process"],
                       "reset/start must precede the first processed frame")
    }

    /// Captures that end WITHOUT a VAD end (STT timeout / wedge) still
    /// report their VAD frame cost — the once-per-capture fallback in
    /// the STT completion tail.
    func testVadFrameLatencyFallsBackWhenCaptureEndsWithoutVADEnd() {
        let h = Harness()
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()

        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: 16_000, channels: 1,
                                   interleaved: true)!
        let samples = [Int16](repeating: 3_000, count: 2_048)
        let buffer = VoicePipeline.makeInt16Buffer(from: samples, format: format)
        h.pipeline.feedCapture(pcm: samples, buffer: buffer)

        // No VAD end — the recognizer times out and settles the capture.
        h.recognizer.complete(with: .failure(.timedOut))

        let events = h.bus.events.filter { $0.component == "voice_pipeline"
            && $0.eventType == "vad_frame_latency" }
        XCTAssertEqual(events.count, 1,
                       "exactly one vad_frame_latency per capture, even without a VAD end")
        XCTAssertEqual(events.first?.metadata["frames"], "4")
    }
}
