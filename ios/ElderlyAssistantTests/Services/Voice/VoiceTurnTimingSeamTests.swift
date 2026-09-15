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
        /// [PIPELINE-TRACE] The trace recorder the pipeline records its
        /// `.stt` row into — nil (the default) is every test above this
        /// section: the same pipeline, byte-identical, with no trace.
        let traceRecorder: PipelineTraceRecorder?

        init(traceRecorder: PipelineTraceRecorder? = nil) {
            let bus = self.bus
            self.traceRecorder = traceRecorder
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
                turnTracer: tracer,
                traceRecorder: traceRecorder
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

    // MARK: - [TURN-TIMING-BREAKDOWN] the intent-model breakdown event
    //
    // The same real pipeline + tracer composition, with a
    // `TurnLatencyReporter` ATTACHED the way `AppCoordinator` attaches
    // it: exactly one `turn_latency`/`turn_timing_breakdown` event per
    // turn, carrying the reused STT span plus that turn's recorded
    // stages — and nothing from the turn before it. Everything here is
    // instrumentation: the routing assertions of the tests above still
    // hold, unaltered.

    func testBreakdownEventIsEmittedOncePerTurnThroughTheSeam() {
        let h = Harness()
        let recorder = TurnTimingRecorder()
        let reporter = TurnLatencyReporter(observabilityBus: h.bus,
                                           recorder: recorder,
                                           isInstrumentationEnabled: true)
        let reported = expectation(description: "breakdown reported")
        reporter.onReported = { _ in reported.fulfill() }

        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        h.recognizer.complete(with: .success(Self.openQuestionTranscript))
        // Mid-turn local-brain work, recorded exactly as the instrumented
        // call sites record it (the turn is open from wake to finalize).
        recorder.record(.encoderInference, ms: 42)
        recorder.record(.pickerInference, ms: 1_200)

        h.interpreter.completeNext(with: InterpretedCommand(
            action: .query,
            entryId: nil, contact: nil, time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: nil, topic: nil,
            steps: nil, pluginAction: nil, pluginEntities: nil,
            confidence: 0.9, reply: "सबै ठीक छ।"
        ))
        wait(for: [reported], timeout: 2)

        let events = h.bus.events.filter {
            $0.eventType == TurnLatencyReporter.eventType
        }
        XCTAssertEqual(events.count, 1,
                       "exactly ONE breakdown event per finalized turn")
        XCTAssertEqual(events[0].component, TurnLatencyReporter.component)
        XCTAssertEqual(events[0].outcome, "success")
        XCTAssertNil(events[0].errorCode)
        XCTAssertNotNil(events[0].durationMs)
        XCTAssertEqual(h.bus.turnTimingEvents.count, 1,
                       "the tracer's own voice_turn_timing event is untouched")

        // Same wire shape as the tracer's stages, so one decoder reads
        // either: the reused STT span first, then the recorded stages in
        // canonical order.
        let raw = events[0].metadata["stages"] ?? "[]"
        let stages = (try? JSONDecoder()
            .decode([VoiceTurnLatencyTracer.StageTiming].self,
                    from: raw.data(using: .utf8)!)) ?? []
        XCTAssertEqual(stages.map(\.stage),
                       ["stt_total", "encoder_inference", "picker_inference"])
        XCTAssertEqual(stages.map(\.ms).suffix(2), [42, 1_200])
        XCTAssertTrue(stages.allSatisfy { $0.ms >= 0 },
                      "every reported duration is non-negative")
    }

    func testBreakdownReportsPerTurnWithoutStageLeaksForward() {
        let h = Harness()
        let recorder = TurnTimingRecorder()
        let reporter = TurnLatencyReporter(observabilityBus: h.bus,
                                           recorder: recorder,
                                           isInstrumentationEnabled: true)
        let reported = expectation(description: "two breakdowns")
        reported.expectedFulfillmentCount = 2
        var breakdowns: [TurnTimingBreakdown] = []
        reporter.onReported = { breakdown in
            breakdowns.append(breakdown)
            reported.fulfill()
        }
        reporter.attach(to: h.tracer)

        // Turn 1 — the sync (emergency) path, with picker work recorded.
        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        h.recognizer.complete(with: .success("मद्दत गर्नुहोस्"))
        recorder.record(.pickerPromptBuild, ms: 8)

        // Turn 2 — nothing recorded: its breakdown is the STT span alone.
        let firstDone = expectation(description: "first turn finalized")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { firstDone.fulfill() }
        wait(for: [firstDone], timeout: 2)

        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        h.recognizer.complete(with: .success("मद्दत गर्नुहोस्"))
        wait(for: [reported], timeout: 3)

        XCTAssertEqual(breakdowns.count, 2, "one breakdown per turn")
        XCTAssertEqual(h.bus.events.filter {
            $0.eventType == TurnLatencyReporter.eventType
        }.count, 2)
        XCTAssertEqual(breakdowns[0].stages.first?.stage, "stt_total")
        XCTAssertTrue(breakdowns[0].stages.contains { $0.stage == "picker_prompt_build" },
                      "turn 1 reports the work recorded during it")
        XCTAssertEqual(breakdowns[1].stages.map(\.stage), ["stt_total"],
                       "turn 2 carries no stage from turn 1")
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

    // MARK: - [PIPELINE-TRACE] the full-width per-gate trace
    //
    // The trace is wired to the SAME turn edges the breakdown rides
    // (`TurnLatencyReporter.attach(to:)`), so one real LLM-path turn
    // produces one trace holding a row for EVERY stage of the pipeline —
    // the ones that ran with their summaries and decisions, the ones that
    // did not marked `off(…)`. The event it emits beside the readout
    // carries stage tokens and milliseconds and nothing else; the card's
    // copy is the only surface that may name the words.

    /// Collects the traces the reporter hands the card, on whichever
    /// thread the turn finalized.
    private final class TraceSink {
        private let lock = NSLock()
        private var traces: [PipelineTrace] = []
        func append(_ trace: PipelineTrace) {
            lock.lock()
            traces.append(trace)
            lock.unlock()
        }
        var all: [PipelineTrace] {
            lock.lock()
            defer { lock.unlock() }
            return traces
        }
    }

    /// One traced turn's handles. The reporter is HELD here — `attach(to:)`
    /// stores it weakly on the tracer, so a caller that let it go would
    /// silently lose the readout.
    private final class TracedTurn {
        let harness: Harness
        let reporter: TurnLatencyReporter
        let sink: TraceSink

        init(harness: Harness, reporter: TurnLatencyReporter, sink: TraceSink) {
            self.harness = harness
            self.reporter = reporter
            self.sink = sink
        }

        var trace: PipelineTrace? { sink.all.first }
    }

    /// The production wiring — a trace recorder on the tracer's own turn
    /// edges, assembled by the reporter — plus one full LLM-path turn
    /// through the seam.
    private func tracedLLMTurn() -> TracedTurn {
        let traceRecorder = PipelineTraceRecorder()
        let h = Harness(traceRecorder: traceRecorder)
        let reporter = TurnLatencyReporter(observabilityBus: h.bus,
                                           recorder: TurnTimingRecorder(),
                                           traceRecorder: traceRecorder,
                                           isInstrumentationEnabled: true)
        let sink = TraceSink()
        let reported = expectation(description: "trace reported")
        reporter.onTraceReported = { trace in
            sink.append(trace)
            reported.fulfill()
        }
        reporter.attach(to: h.tracer)

        h.pipeline.debugEnterIdleForTesting()
        h.pipeline.simulateWakeWordDetection()
        h.recognizer.complete(with: .success(Self.openQuestionTranscript))
        h.interpreter.completeNext(with: InterpretedCommand(
            action: .query,
            entryId: nil, contact: nil, time: nil, medication: nil,
            message: nil, callType: nil, requestedApp: nil, topic: nil,
            steps: nil, pluginAction: nil, pluginEntities: nil,
            confidence: 0.9, reply: "सबै ठीक छ।"
        ))
        wait(for: [reported], timeout: 2)
        return TracedTurn(harness: h, reporter: reporter, sink: sink)
    }

    /// One row per stage, in canonical pipeline order, every duration a
    /// non-negative measurement — and the stages this turn never reached
    /// MARKED `off(…)`, never omitted (a trace with holes cannot be read
    /// as a trace). The `.stt` row's duration is the tracer's own ASR
    /// span REUSED, not a second clock reading of the same work.
    func testTraceCarriesEveryStageInCanonicalOrder() throws {
        let turn = tracedLLMTurn()
        let h = turn.harness

        XCTAssertEqual(turn.sink.all.count, 1, "exactly one trace per turn")
        let trace = try XCTUnwrap(turn.trace, "the reporter published the turn's trace")
        XCTAssertEqual(trace.rows.map(\.stage), PipelineTraceStage.allCases,
                       "every stage, in canonical order, regardless of record order")
        XCTAssertTrue(trace.rows.allSatisfy { $0.durationMs >= 0 },
                      "no measured duration is ever negative")

        let stt = trace.rows[0]
        XCTAssertEqual(stt.stage, .stt)
        XCTAssertTrue(stt.ran, "the recognizer ran this turn")
        XCTAssertEqual(stt.decision, "recognized")
        XCTAssertTrue(stt.outputSummary.contains(Self.openQuestionTranscript),
                      "the readout names what the recognizer heard")

        // The reused ASR span, decoded from the timing event the same turn
        // emitted — the two readouts can never disagree about it.
        let raw = h.bus.turnTimingEvents[0].metadata["stages"] ?? "[]"
        let tracerStages = (try? JSONDecoder()
            .decode([VoiceTurnLatencyTracer.StageTiming].self,
                    from: Data(raw.utf8))) ?? []
        let asrMs = tracerStages.first { $0.stage == "asr_done" }?.ms
        XCTAssertNotNil(asrMs, "the tracer timed the recognizer")
        XCTAssertEqual(stt.durationMs, asrMs ?? -1,
                       "the STT row reuses the tracer's asr_done span")

        // This turn reached no corrector, no encoder, no band policy, no
        // cascade, no picker brain and no speaker — all present, all off.
        for row in trace.rows.dropFirst() {
            XCTAssertFalse(row.ran, "\(row.stage.rawValue) did not run this turn")
            XCTAssertTrue(row.decisionText.hasPrefix("off("),
                          "an unrun stage says off: \(row.decisionText)")
            XCTAssertEqual(row.durationMs, 0)
            XCTAssertEqual(row.decision, row.stage.offReason,
                           "the row carries the stage's own off reason")
        }
        XCTAssertEqual(trace.ranCount, 1, "the STT stage was this turn's only work")

        // The trace's own event: one per turn, beside the breakdown's.
        XCTAssertEqual(h.bus.events.filter {
            $0.eventType == PipelineTrace.eventType
        }.count, 1)
        XCTAssertEqual(h.bus.events.filter {
            $0.eventType == TurnLatencyReporter.eventType
        }.count, 1, "the breakdown event is untouched by the trace")
    }

    /// The disclosure split, pinned on the seam: the EVENT carries the
    /// stage tokens and milliseconds only (the breakdown's own wire
    /// shape), while the card's readout — and the Debug console shape —
    /// carries the summaries. Nothing PII-shaped can reach the bus.
    func testTraceEventCarriesStageTokensOnlyWhileTheReadoutNamesTheWords() throws {
        let turn = tracedLLMTurn()
        let h = turn.harness
        let trace = try XCTUnwrap(turn.trace)

        let events = h.bus.events.filter { $0.eventType == PipelineTrace.eventType }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].component, PipelineTrace.component)
        XCTAssertNotNil(events[0].durationMs)
        XCTAssertEqual(Array(events[0].metadata.keys), ["stages"],
                       "the trace event carries the stage list and nothing else")

        // The payload decodes through the SAME decoder the breakdown uses,
        // with the closed stage vocabulary as its keys.
        let raw = events[0].metadata["stages"] ?? "[]"
        let stages = (try? JSONDecoder()
            .decode([VoiceTurnLatencyTracer.StageTiming].self,
                    from: Data(raw.utf8))) ?? []
        XCTAssertEqual(stages.map(\.stage),
                       PipelineTraceStage.allCases.map(\.rawValue),
                       "the egressing payload is stage tokens, in canonical order")
        XCTAssertTrue(stages.allSatisfy { $0.ms >= 0 })

        // …and no value anywhere in the event names what the user said or
        // what the trace's summaries hold.
        let words = (Self.openQuestionTranscript + " " + "सबै ठीक छ।")
            .components(separatedBy: .whitespaces)
            .filter { $0.count > 1 }
        for value in events[0].metadata.values {
            for word in words {
                XCTAssertFalse(value.contains(word),
                               "the event leaked on-device content: \(value)")
            }
            XCTAssertFalse(value.contains("in:"),
                           "the event never carries a summary line")
        }

        // The readout, by contrast, is the on-device view and names them.
        XCTAssertTrue(trace.rows[0].summaryText.contains(Self.openQuestionTranscript))
        XCTAssertEqual(trace.rows[0].inputSummary, "audio capture")
    }

    /// The console split ([PIPELINE-TRACE], the B1 release-log rule): the
    /// Debug shape carries the summaries, the RELEASE shape carries the
    /// stage token, the milliseconds, the decision token and the
    /// structured token count — and no words. Pinned on the pure
    /// renderer, which is the one place both shapes exist.
    func testConsoleShapesSplitDebugSummariesFromTheReleaseTokens() {
        let trace = PipelineTrace(rows: [
            PipelineTraceRow(
                stage: .pickerInference,
                inputSummary: "~42 tok (est)",
                outputSummary: "query 0.90 reply=भोलि घाम लाग्नेछ।",
                durationMs: 1_234,
                decision: "command",
                ran: true,
                tokenCount: 42),
            PipelineTraceRow(
                stage: .encoderDecode,
                inputSummary: "—",
                outputSummary: "not run",
                durationMs: 0,
                decision: PipelineTraceStage.encoderDecode.offReason,
                ran: false),
            PipelineTraceRow(
                stage: .corrector,
                inputSummary: "—",
                outputSummary: "not run",
                durationMs: 0,
                decision: PipelineTraceStage.corrector.offReason,
                ran: false),
        ])

        let debug = trace.consoleLines(includeSummaries: true)
        let release = trace.consoleLines(includeSummaries: false)

        XCTAssertEqual(debug.count, 3)
        XCTAssertEqual(release.count, 3, "the off rows print in BOTH shapes")
        XCTAssertTrue(debug[0].hasPrefix(PipelineTrace.consolePrefix),
                      "greppable in a captured console")
        XCTAssertTrue(debug[0].contains("picker_inference"))
        XCTAssertTrue(debug[0].contains(trace.rows[0].durationText))
        XCTAssertTrue(debug[0].contains("tok=42"))
        XCTAssertTrue(debug[0].contains("भोलि घाम लाग्नेछ।"),
                      "the Debug console is the internal-testing surface")

        XCTAssertFalse(release[0].contains("भोलि"),
                       "the Release console never carries summary text")
        XCTAssertFalse(release[0].contains("~42 tok (est)"))
        XCTAssertFalse(release[0].contains("in:"))
        XCTAssertTrue(release[0].contains("picker_inference"),
                      "the stage token is release-safe")
        XCTAssertTrue(release[0].contains("command"),
                      "so is the decision token")
        XCTAssertTrue(release[0].contains("tok=42"),
                      "and so is the structured count")
        XCTAssertTrue(release[1].contains("off(encoder_not_serving)"),
                      "an unrun stage is marked off on the console too")
        XCTAssertTrue(debug[1].contains("off(encoder_not_serving)"))
        XCTAssertTrue(release[2].contains("off(seam_not_run)"),
                      "the pre-intent layers' own off token — the vocabulary "
                      + "the seam and the backfill agree on, pinned here so a "
                      + "reworded token is a failing test and not a silent drift")
        XCTAssertTrue(debug[2].contains("off(seam_not_run)"))
    }
}
