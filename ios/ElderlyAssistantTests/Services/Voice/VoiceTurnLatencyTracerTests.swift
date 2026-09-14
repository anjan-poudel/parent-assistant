import XCTest
@testable import ElderlyAssistant

/// Unit tests for `VoiceTurnLatencyTracer` ([TURN-TIMING]): stage
/// ordering, duration accumulation against an injected monotonic clock,
/// point-entry semantics, duplicate/finalize behavior, speak gating, and
/// the serialization + caption presentation helpers. Pure logic — no
/// audio, no pipeline, no wall clock.
final class VoiceTurnLatencyTracerTests: XCTestCase {

    // MARK: - Fakes

    private final class RecordingBus: ObservabilityBus {
        private(set) var events: [ObservabilityEvent] = []
        func emit(_ event: ObservabilityEvent) {
            events.append(event)
        }
        var turnTimingEvents: [ObservabilityEvent] {
            events.filter { $0.eventType == "voice_turn_timing" }
        }
    }

    /// Manual monotonic clock: the test advances `seconds` and the
    /// closure reads it — fully deterministic durations.
    private final class ManualClock {
        var seconds: TimeInterval = 1000
        func now() -> TimeInterval { seconds }
    }

    private final class FinalizeRecord {
        var calls: [(stages: [VoiceTurnLatencyTracer.StageTiming], totalMs: Int)] = []
    }

    private func makeTracer(bus: RecordingBus,
                            clock: ManualClock) -> (VoiceTurnLatencyTracer, FinalizeRecord) {
        let tracer = VoiceTurnLatencyTracer(observabilityBus: bus)
        tracer.now = clock.now
        let record = FinalizeRecord()
        tracer.onTurnFinalized = { stages, totalMs in
            record.calls.append((stages, totalMs))
        }
        return (tracer, record)
    }

    // MARK: - Stage ordering + duration accumulation

    func testStageOrderingAndDurationsWithInjectedClock() {
        let bus = RecordingBus()
        let clock = ManualClock()
        let (tracer, record) = makeTracer(bus: bus, clock: clock)

        tracer.beginTurn()
        clock.seconds += 0.5      // user speaking
        tracer.mark("vad_end")
        clock.seconds += 1.25     // STT
        tracer.mark("asr_done")
        clock.seconds += 0.25     // router decision
        tracer.mark("router_done")
        tracer.endTurn()          // no speech — finalizes immediately

        XCTAssertEqual(record.calls.count, 1)
        let stages = record.calls[0].stages
        XCTAssertEqual(stages.map(\.stage),
                       ["turn_start", "vad_end", "asr_done", "router_done", "turn_end"])
        XCTAssertEqual(stages.map(\.ms), [500, 1250, 250, 0, 0])
        XCTAssertEqual(record.calls[0].totalMs, 2000)
        XCTAssertEqual(bus.turnTimingEvents.count, 1)
    }

    func testSpeakStagesGateFinalizationUntilLastUtterance() {
        let bus = RecordingBus()
        let clock = ManualClock()
        let (tracer, record) = makeTracer(bus: bus, clock: clock)

        tracer.beginTurn()
        clock.seconds += 2.0
        tracer.mark("llm_done")
        tracer.noteSpeakQueued()
        tracer.endTurn()          // speech pending — must NOT finalize yet
        XCTAssertEqual(record.calls.count, 0)
        XCTAssertTrue(bus.turnTimingEvents.isEmpty)

        clock.seconds += 3.0      // playback
        tracer.noteSpeakFinished()

        XCTAssertEqual(record.calls.count, 1)
        XCTAssertEqual(record.calls[0].stages.map(\.stage),
                       ["turn_start", "llm_done", "speak_queued", "speak_finished", "turn_end"])
        // llm_done closes at the speak_queued mark (same instant — the
        // dispatch gap is ~0); the speech span carries the 3 s playback.
        XCTAssertEqual(record.calls[0].stages.map(\.ms), [2000, 0, 3000, 0, 0])
        XCTAssertEqual(record.calls[0].totalMs, 5000)
        XCTAssertEqual(bus.turnTimingEvents.count, 1)
    }

    func testMultipleQueuedSpeaksFinalizeOnlyAfterLast() {
        let bus = RecordingBus()
        let clock = ManualClock()
        let (tracer, record) = makeTracer(bus: bus, clock: clock)

        tracer.beginTurn()
        tracer.noteSpeakQueued()
        tracer.noteSpeakQueued()
        tracer.endTurn()
        XCTAssertEqual(record.calls.count, 0)

        clock.seconds += 1.0
        tracer.noteSpeakFinished()
        XCTAssertEqual(record.calls.count, 0, "one utterance still playing")

        tracer.noteSpeakFinished()
        XCTAssertEqual(record.calls.count, 1)
        XCTAssertEqual(record.calls[0].stages.map(\.stage),
                       ["turn_start", "speak_queued", "speak_queued",
                        "speak_finished", "speak_finished", "turn_end"])
        XCTAssertEqual(bus.turnTimingEvents.count, 1)
    }

    // MARK: - Point entries

    func testPointEntryCarriesExternalDurationWithoutDisturbingOpenStage() {
        let bus = RecordingBus()
        let clock = ManualClock()
        let (tracer, record) = makeTracer(bus: bus, clock: clock)

        tracer.beginTurn()
        clock.seconds += 0.5
        tracer.mark("vad_end")
        clock.seconds += 0.75   // the ASR load happened inside this span
        tracer.mark("asr_loaded", elapsedMs: 750)
        clock.seconds += 0.25   // rest of inference
        tracer.mark("asr_done")
        tracer.endTurn()

        let stages = record.calls[0].stages
        XCTAssertEqual(stages.map(\.stage),
                       ["turn_start", "vad_end", "asr_loaded", "asr_done", "turn_end"])
        // vad_end's span covers the whole STT step (load + inference),
        // and the point entry carries the load portion — documented
        // overlap; it lands in its chronological emission position.
        XCTAssertEqual(stages.map(\.ms), [500, 1000, 750, 0, 0])
    }

    func testPointEntryOutsideTurnIsNoOp() {
        let bus = RecordingBus()
        let (tracer, record) = makeTracer(bus: bus, clock: ManualClock())
        tracer.mark("asr_loaded", elapsedMs: 800)
        tracer.mark("vad_end")
        tracer.noteSpeakQueued()
        tracer.endTurn()
        XCTAssertEqual(record.calls.count, 0)
        XCTAssertTrue(bus.events.isEmpty)
    }

    // MARK: - Duplicate / finalize semantics

    func testDuplicateEndTurnIsIdempotent() {
        let bus = RecordingBus()
        let clock = ManualClock()
        let (tracer, record) = makeTracer(bus: bus, clock: clock)

        tracer.beginTurn()
        tracer.endTurn()
        tracer.endTurn()
        clock.seconds += 5
        tracer.mark("asr_done")          // marks after finalize are no-ops
        tracer.endTurn()

        XCTAssertEqual(record.calls.count, 1)
        XCTAssertEqual(bus.turnTimingEvents.count, 1)
    }

    func testBeginTurnWhileActiveFinalizesPreviousTurn() {
        let bus = RecordingBus()
        let clock = ManualClock()
        let (tracer, record) = makeTracer(bus: bus, clock: clock)

        tracer.beginTurn()
        clock.seconds += 1.0
        tracer.mark("vad_end")
        tracer.beginTurn()               // defensive: emit the abandoned turn
        XCTAssertEqual(record.calls.count, 1)
        XCTAssertEqual(record.calls[0].stages.map(\.stage),
                       ["turn_start", "vad_end", "turn_end"])

        clock.seconds += 2.0
        tracer.endTurn()                 // the NEW turn
        XCTAssertEqual(record.calls.count, 2)
        XCTAssertEqual(record.calls[1].stages.map(\.stage), ["turn_start", "turn_end"])
        XCTAssertEqual(record.calls[1].stages[0].ms, 2000)
        XCTAssertEqual(bus.turnTimingEvents.count, 2)
    }

    func testCancelTurnEmitsNothing() {
        let bus = RecordingBus()
        let clock = ManualClock()
        let (tracer, record) = makeTracer(bus: bus, clock: clock)

        tracer.beginTurn()
        clock.seconds += 3
        tracer.mark("vad_end")
        tracer.noteSpeakQueued()
        tracer.cancelTurn()

        XCTAssertEqual(record.calls.count, 0)
        XCTAssertTrue(bus.events.isEmpty)

        // A fresh turn after the cancel starts clean.
        tracer.beginTurn()
        clock.seconds += 1
        tracer.endTurn()
        XCTAssertEqual(record.calls.count, 1)
        XCTAssertEqual(record.calls[0].stages.map(\.stage), ["turn_start", "turn_end"])
        XCTAssertEqual(bus.turnTimingEvents.count, 1)
    }

    // MARK: - Event emission + serialization

    func testFinalizeEmitsOneEventWithSerializedStages() {
        let bus = RecordingBus()
        let clock = ManualClock()
        let (tracer, _) = makeTracer(bus: bus, clock: clock)

        tracer.beginTurn()
        clock.seconds += 0.25
        tracer.mark("vad_end")
        clock.seconds += 1.75
        tracer.mark("llm_done")
        tracer.endTurn()

        XCTAssertEqual(bus.turnTimingEvents.count, 1)
        let event = bus.turnTimingEvents[0]
        XCTAssertEqual(event.component, "voice_turn_timing")
        XCTAssertEqual(event.outcome, "success")
        XCTAssertEqual(event.durationMs, 2000)
        XCTAssertNil(event.errorCode)

        let raw = event.metadata["stages"]
        XCTAssertNotNil(raw)
        let decoded = try? JSONDecoder()
            .decode([VoiceTurnLatencyTracer.StageTiming].self,
                    from: (raw ?? "").data(using: .utf8)!)
        XCTAssertEqual(decoded?.map(\.stage),
                       ["turn_start", "vad_end", "llm_done", "turn_end"])
        XCTAssertEqual(decoded?.map(\.ms), [250, 1750, 0, 0])
    }

    func testSerializeProducesOrderedJSONArray() {
        let stages = [
            VoiceTurnLatencyTracer.StageTiming(stage: "turn_start", ms: 0),
            VoiceTurnLatencyTracer.StageTiming(stage: "asr_done", ms: 1234),
        ]
        let json = VoiceTurnLatencyTracer.serialize(stages)
        XCTAssertEqual(json, #"[{"ms":0,"stage":"turn_start"},{"ms":1234,"stage":"asr_done"}]"#)
    }

    // MARK: - Caption + ms formatting

    func testCaptionComposesOnlyStagesThatOccurred() {
        let stages = [
            VoiceTurnLatencyTracer.StageTiming(stage: "asr_done", ms: 120),
            VoiceTurnLatencyTracer.StageTiming(stage: "llm_done", ms: 2400),
            VoiceTurnLatencyTracer.StageTiming(stage: "tts_done", ms: 310),
            VoiceTurnLatencyTracer.StageTiming(stage: "speak_finished", ms: 1500),
        ]
        XCTAssertEqual(VoiceTurnLatencyTracer.caption(stages: stages),
                       "asr 120ms · llm 2.4s · tts 310ms · play 1.5s")
    }

    func testCaptionSkipsMissingStagesAndIsEmptyWhenNone() {
        let partial = [VoiceTurnLatencyTracer.StageTiming(stage: "llm_done", ms: 800)]
        XCTAssertEqual(VoiceTurnLatencyTracer.caption(stages: partial), "llm 800ms")
        XCTAssertEqual(VoiceTurnLatencyTracer.caption(stages: []), "")
    }

    func testMsTextFormatsMillisAndSeconds() {
        XCTAssertEqual(VoiceTurnLatencyTracer.msText(0), "0ms")
        XCTAssertEqual(VoiceTurnLatencyTracer.msText(999), "999ms")
        XCTAssertEqual(VoiceTurnLatencyTracer.msText(1000), "1.0s")
        XCTAssertEqual(VoiceTurnLatencyTracer.msText(2400), "2.4s")
        XCTAssertEqual(VoiceTurnLatencyTracer.msText(2406), "2.4s")
    }

    // MARK: - [TURN-TIMING-BREAKDOWN] stage recorder
    //
    // The recorder is the per-stage stopwatch the intent-model half of a
    // turn reports through: fixed vocabulary, millisecond durations,
    // turn-scoped collection. Its clock is injected, so every duration
    // below is exact rather than "roughly".

    /// Manual monotonic clock in NANOSECONDS (`TurnTimingRecorder.now`).
    private final class ManualNanosecondClock {
        private let lock = NSLock()
        private var ns: UInt64 = 1_000_000_000
        func now() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return ns
        }
        func advance(ms: UInt64) {
            lock.lock()
            ns += ms * 1_000_000
            lock.unlock()
        }
    }

    func testRecorderMeasuresSpansAndRecordsDurationsInCanonicalOrder() {
        let clock = ManualNanosecondClock()
        let recorder = TurnTimingRecorder()
        recorder.now = clock.now
        recorder.beginTurn()

        // Recorded out of pipeline order on purpose: the breakdown is
        // CANONICAL, not call order.
        recorder.record(.encoderDecode, ms: 7)
        let span = recorder.start(.encoderInference)
        clock.advance(ms: 120)
        span?.finish()
        recorder.measure(.encoderTokenizer) { clock.advance(ms: 3) }
        recorder.record(.ttsStart, ms: -5)   // clamped — never negative

        let breakdown = recorder.finishTurn()
        XCTAssertEqual(breakdown.stages.map(\.stage),
                       ["encoder_tokenizer", "encoder_inference",
                        "encoder_decode", "tts_start"])
        XCTAssertEqual(breakdown.stages.map(\.ms), [3, 120, 7, 0])
        XCTAssertTrue(recorder.finishTurn().isEmpty,
                      "finishing a turn clears it — one breakdown per turn")
    }

    func testSpanFinishedTwiceRecordsOneDuration() {
        let clock = ManualNanosecondClock()
        let recorder = TurnTimingRecorder()
        recorder.now = clock.now
        recorder.beginTurn()
        let span = recorder.start(.pickerInference)
        clock.advance(ms: 50)
        span?.finish()
        clock.advance(ms: 500)
        span?.finish()                       // idempotent — no second record

        XCTAssertEqual(recorder.finishTurn().stages.map(\.ms), [50])
    }

    func testRecordsOutsideATurnAreDropped() {
        let clock = ManualNanosecondClock()
        let recorder = TurnTimingRecorder()
        recorder.now = clock.now

        // A notification read-aloud / briefing speaks outside any turn:
        // none of it may open or extend one (the tracer's own doctrine).
        recorder.record(.ttsStart, ms: 900)
        XCTAssertNil(recorder.start(.pickerInference),
                     "no span opens while no turn is active")
        recorder.measure(.pickerPromptBuild) { clock.advance(ms: 10) }
        XCTAssertTrue(recorder.finishTurn().isEmpty,
                      "background work records nothing")

        recorder.beginTurn()
        recorder.record(.ttsStart, ms: 40)
        XCTAssertEqual(recorder.finishTurn().stages.map(\.ms), [40])
    }

    func testSpanOpenedInAClosedTurnRecordsNothingInTheNextTurn() {
        let clock = ManualNanosecondClock()
        let recorder = TurnTimingRecorder()
        recorder.now = clock.now

        recorder.beginTurn()
        let stale = recorder.start(.pickerInference)
        _ = recorder.finishTurn()             // the turn finalized mid-flight
        recorder.beginTurn()                  // …and the next turn starts
        clock.advance(ms: 500)
        stale?.finish()

        XCTAssertTrue(recorder.finishTurn().isEmpty,
                      "a span from a closed turn must not leak into the next one")
    }

    func testRepeatedRecordsOfOneStageAccumulate() {
        let recorder = TurnTimingRecorder()
        recorder.beginTurn()
        recorder.record(.pickerInference, ms: 30)
        recorder.record(.pickerInference, ms: 12)   // a retry inside the turn
        XCTAssertEqual(recorder.finishTurn().stages.map(\.ms), [42])
    }

    // MARK: - [TURN-TIMING-BREAKDOWN] reporter (one event per turn)

    /// A recorder + reporter attached to a REAL tracer, driven through
    /// two turns: exactly ONE `turn_latency`/`turn_timing_breakdown`
    /// event per finalized turn, carrying the reused STT span plus that
    /// turn's recorded stages — and nothing from the turn before it.
    func testReporterEmitsOneBreakdownEventPerTurn() {
        let bus = RecordingBus()
        let clock = ManualClock()
        let (tracer, _) = makeTracer(bus: bus, clock: clock)
        let recorder = TurnTimingRecorder()
        let reporter = TurnLatencyReporter(observabilityBus: bus,
                                           recorder: recorder,
                                           isInstrumentationEnabled: true)
        var reported: [TurnTimingBreakdown] = []
        reporter.onReported = { reported.append($0) }
        reporter.attach(to: tracer)

        // Turn 1 — STT 1.5 s, an encoder answer that the cascade escalated.
        tracer.beginTurn()
        clock.seconds += 1.5
        tracer.mark("asr_done")
        recorder.record(.encoderInference, ms: 88)
        recorder.record(.cascadeDecision, ms: 0)
        clock.seconds += 0.5
        tracer.mark("router_done")
        tracer.endTurn()

        let breakdownEvents = bus.events.filter {
            $0.eventType == TurnLatencyReporter.eventType
        }
        XCTAssertEqual(breakdownEvents.count, 1,
                       "exactly ONE breakdown event per finalized turn")
        XCTAssertEqual(bus.turnTimingEvents.count, 1,
                       "the tracer's own event is untouched by the reporter")
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported[0].stages.map(\.stage),
                       ["stt_total", "encoder_inference", "cascade_decision"],
                       "the STT span is REUSED from the tracer's asr_done mark")
        XCTAssertEqual(reported[0].stages.map(\.ms), [1500, 88, 0])
        XCTAssertEqual(breakdownEvents[0].component, TurnLatencyReporter.component)
        XCTAssertEqual(breakdownEvents[0].outcome, "success")
        XCTAssertEqual(breakdownEvents[0].durationMs, 2000)
        XCTAssertNil(breakdownEvents[0].errorCode)
        XCTAssertTrue(reported.allSatisfy { breakdown in
            breakdown.stages.allSatisfy { $0.ms >= 0 }
        }, "every reported duration is non-negative")

        // Turn 2 — nothing recorded: the breakdown carries the STT span
        // alone, proving turn 1's stages did not leak forward.
        tracer.beginTurn()
        clock.seconds += 1.0
        tracer.mark("asr_done")
        tracer.endTurn()

        XCTAssertEqual(bus.events.filter {
            $0.eventType == TurnLatencyReporter.eventType
        }.count, 2, "one event per turn, every turn")
        XCTAssertEqual(reported.count, 2)
        XCTAssertEqual(reported[1].stages.map(\.stage), ["stt_total"])
    }

    /// The PII rule ([TURN-TIMING-BREAKDOWN] / C9): the event carries
    /// stage names and millisecond numbers ONLY — the fixed stage
    /// vocabulary, never transcript words, contact names or other
    /// entities, even when the turn's utterance is full of them.
    func testBreakdownEventCarriesNoTranscriptOrEntityContent() throws {
        let bus = RecordingBus()
        let clock = ManualClock()
        let (tracer, _) = makeTracer(bus: bus, clock: clock)
        let recorder = TurnTimingRecorder()
        let reporter = TurnLatencyReporter(observabilityBus: bus,
                                           recorder: recorder,
                                           isInstrumentationEnabled: true)
        reporter.attach(to: tracer)

        // The turn's actual utterance — a contact + a time entity.
        let transcript = "छोरालाई भोलि बिहान ८ बजे फोन गर्नुहोस्"
        let contact = "छोरा"

        tracer.beginTurn()
        clock.seconds += 1.2
        tracer.mark("asr_done")
        recorder.record(.encoderInference, ms: 64)
        tracer.endTurn()
        _ = transcript   // the turn's text never reaches the reporter

        let event = try XCTUnwrap(bus.events.first {
            $0.eventType == TurnLatencyReporter.eventType
        })
        XCTAssertEqual(Set(event.metadata.keys), ["stages"],
                       "stage names + durations are the whole payload")
        let raw = try XCTUnwrap(event.metadata["stages"])
        XCTAssertFalse(raw.contains(contact),
                       "no contact / entity content in the event")
        XCTAssertFalse(raw.contains("भोलि"),
                       "no transcript content in the event")

        let objects = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
        XCTAssertFalse(objects.isEmpty, "the breakdown names its stages")
        for object in objects {
            XCTAssertEqual(Set(object.keys), ["stage", "ms"],
                           "each entry is exactly a stage token + a duration")
            let stage = try XCTUnwrap(object["stage"] as? String)
            XCTAssertNotNil(TurnTimingStage(rawValue: stage),
                            "only the fixed stage vocabulary travels")
            XCTAssertNotNil(object["ms"] as? Int)
        }
    }

    /// The compile-time gate, defense in depth: a reporter built with
    /// instrumentation off stays silent AND leaves no state behind.
    func testReporterWithInstrumentationOffEmitsNothing() {
        let bus = RecordingBus()
        let recorder = TurnTimingRecorder()
        let reporter = TurnLatencyReporter(observabilityBus: bus,
                                           recorder: recorder,
                                           isInstrumentationEnabled: false)
        var reported: [TurnTimingBreakdown] = []
        reporter.onReported = { reported.append($0) }

        recorder.beginTurn()
        recorder.record(.encoderInference, ms: 12)
        let breakdown = reporter.report(
            tracerStages: [VoiceTurnLatencyTracer.StageTiming(stage: "asr_done", ms: 900)],
            totalMs: 1000)

        XCTAssertTrue(breakdown.isEmpty)
        XCTAssertTrue(reported.isEmpty)
        XCTAssertTrue(bus.events.isEmpty,
                      "no internal-testing telemetry without the gate")
        XCTAssertTrue(recorder.finishTurn().isEmpty,
                      "the reporter still closes the turn's collection")
    }

    // MARK: - [TURN-TIMING-BREAKDOWN] card readout

    /// The Settings card's "Last turn" rows: one per recorded stage, the
    /// machine stage + short label + the tracer's own ms formatting.
    func testReadoutFormatsEachStageNameAndDuration() {
        let breakdown = TurnTimingBreakdown(stages: [
            VoiceTurnLatencyTracer.StageTiming(stage: "stt_total", ms: 1400),
            VoiceTurnLatencyTracer.StageTiming(stage: "encoder_tokenizer", ms: 12),
            VoiceTurnLatencyTracer.StageTiming(stage: "encoder_inference", ms: 88),
            VoiceTurnLatencyTracer.StageTiming(stage: "cascade_decision", ms: 0),
        ])

        XCTAssertEqual(breakdown.readout.map(\.stage),
                       ["stt_total", "encoder_tokenizer",
                        "encoder_inference", "cascade_decision"])
        XCTAssertEqual(breakdown.readout.map(\.label),
                       ["stt", "enc tokenize", "enc infer", "cascade"])
        XCTAssertEqual(breakdown.readout.map(\.value),
                       ["1.4s", "12ms", "88ms", "0ms"])
        XCTAssertEqual(breakdown.readout.map(\.id),
                       breakdown.readout.map(\.stage))
    }

    func testReadoutIsEmptyWithoutStagesAndKeepsUnknownTokensVerbatim() {
        XCTAssertTrue(TurnTimingBreakdown(stages: []).readout.isEmpty)
        XCTAssertTrue(TurnTimingBreakdown(stages: []).isEmpty)

        // A hand-built entry outside the enum (never produced by the
        // recorder) is shown verbatim rather than dropped.
        let odd = TurnTimingBreakdown(stages: [
            VoiceTurnLatencyTracer.StageTiming(stage: "future_stage", ms: 5),
        ])
        XCTAssertEqual(odd.readout.map(\.label), ["future_stage"])
        XCTAssertEqual(odd.readout.map(\.value), ["5ms"])
    }

    func testBreakdownSerializesAsTheSharedStageShape() {
        let json = TurnTimingBreakdown.serialize([
            VoiceTurnLatencyTracer.StageTiming(stage: "stt_total", ms: 0),
            VoiceTurnLatencyTracer.StageTiming(stage: "tts_start", ms: 45),
        ])
        XCTAssertEqual(json,
                       #"[{"ms":0,"stage":"stt_total"},{"ms":45,"stage":"tts_start"}]"#)
    }
}
