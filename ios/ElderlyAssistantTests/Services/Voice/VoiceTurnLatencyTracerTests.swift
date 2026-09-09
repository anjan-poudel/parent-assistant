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
}
