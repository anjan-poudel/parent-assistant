import Foundation

// MARK: - Turn latency breakdown ([TURN-TIMING-BREAKDOWN], 2026-09-14)
//
// The INTENT-MODEL half of one voice turn, timed stage by stage. Where
// `VoiceTurnLatencyTracer` answers "how long did the turn take, per
// coarse pipeline step" (capture → ASR → router → speech), this answers
// "where did the local-brain work go": encoder tokenizer / CoreML
// forward / decode, the cascade's serve-or-escalate decision, the picker
// brain's prompt build / inference, and the TTS start latency.
//
// Exactly ONE observability event per finalized turn — component
// `turn_latency`, eventType `turn_timing_breakdown` — carries the stage
// list as millisecond numbers only. No transcript, no entities, no reply
// text, no contact or medication names: the stage vocabulary is a fixed
// enum and the payload is `{"stage": <fixed token>, "ms": <int>}`, so
// nothing PII-shaped can reach the bus (C9 / NFR-016 — the same
// convention `VoiceTurnLatencyTracer` documents).
//
// Cost model (requirement: accurate, not noisy, zero-cost when off):
//
//  · Instrumentation is gated by the COMPILE-TIME `INTENT_ENCODER`
//    condition (`IntentEncoderFeature.isEnabled`). On a non-gated build
//    the coordinator constructs no recorder and no reporter, so every
//    call site hands `nil` to the optional extensions below — a nil check
//    and a plain call, no clock read, no allocation, no lock.
//  · Time comes from `DispatchTime.now().uptimeNanoseconds` (monotonic —
//    mach_absolute_time-backed, immune to wall-clock adjustments) and is
//    injectable for deterministic tests, exactly like the tracer's
//    `now` seam.
//  · The recorder is TURN-SCOPED: records outside a turn (a notification
//    read-aloud, a briefing, a stray model load) are DROPPED, so
//    background speech can never leak a stage into the next turn's
//    breakdown — the same doctrine as the tracer's `mark` no-op guard.
//  · A span carries the turn epoch it opened in, so a slow operation
//    that outlives its turn (synthesis finishing after the turn
//    finalized) records nothing instead of polluting a newer turn.
//
// This is PURE INSTRUMENTATION: no stage measurement decides anything.
// The routing/decision code paths are byte-for-byte what they were — the
// recorder is read only after a turn's outcome is already settled.

/// The fixed stage vocabulary. Raw values are the machine tokens that
/// travel in the event (`snake_case`, never localized) — adding a stage
/// is a schema change, so the set is deliberately small and closed.
enum TurnTimingStage: String, CaseIterable {
    /// ASR span, reused from `VoiceTurnLatencyTracer` (`asr_done`) rather
    /// than re-measured: the recognizers already mark it, and a second
    /// clock reading of the same work would only add noise.
    case sttTotal = "stt_total"
    /// `IntentEncoderTokenizer.tokenize` — sanitised text → token ids.
    case encoderTokenizer = "encoder_tokenizer"
    /// The CoreML forward pass (`IntentEncoderModelRunning.predict`).
    case encoderInference = "encoder_inference"
    /// `IntentEncoderDecoder.decode` — logits → validated command.
    case encoderDecode = "encoder_decode"
    /// The cascade's serve-or-escalate decision in `LocalBrainChain`
    /// (cascade mode only; near-zero by construction — it exists so the
    /// breakdown shows the decision was taken, not just the two brains).
    case cascadeDecision = "cascade_decision"
    /// The picker brain's prompt construction (`IntentPrompt.build`).
    case pickerPromptBuild = "picker_prompt_build"
    /// The picker brain's llama.cpp round-trip (including its first-use
    /// model load — the same honest conflation the tracer's `llm` stage
    /// already carries).
    case pickerInference = "picker_inference"
    /// Handed-to-speaker → audio start: the speaker's own ramp (voice
    /// resolution + synthesis), NOT the playback duration.
    case ttsStart = "tts_start"

    /// Short technical label for the Settings card's readout — the same
    /// non-localized diagnostic style as the tracer's `captionEntries`
    /// ("asr 120ms · llm 2.4s"), not user-facing copy.
    var label: String {
        switch self {
        case .sttTotal:          return "stt"
        case .encoderTokenizer:  return "enc tokenize"
        case .encoderInference:  return "enc infer"
        case .encoderDecode:     return "enc decode"
        case .cascadeDecision:   return "cascade"
        case .pickerPromptBuild: return "picker prompt"
        case .pickerInference:   return "picker infer"
        case .ttsStart:          return "tts start"
        }
    }
}

/// One turn's stage list, in canonical pipeline order.
///
/// The stage entries are the tracer's `StageTiming` — the same
/// `{stage, ms}` wire shape, so both timing events serialize identically
/// and one decoder reads either (`VoiceTurnLatencyTracer.serialize`).
struct TurnTimingBreakdown: Equatable {

    /// Canonical order (`TurnTimingStage.allCases`), stages that did not
    /// occur absent entirely.
    let stages: [VoiceTurnLatencyTracer.StageTiming]

    var isEmpty: Bool { stages.isEmpty }

    /// One Settings-card row: the machine stage, its short display label,
    /// and the measured milliseconds (`value` is the formatted text).
    struct ReadoutRow: Equatable, Identifiable {
        let stage: String
        let label: String
        let ms: Int

        /// `120ms` under a second, else one-decimal seconds — the
        /// tracer's own formatting, so the caption and the card agree.
        var value: String { VoiceTurnLatencyTracer.msText(ms) }
        var id: String { stage }
    }

    /// Card rows, one per recorded stage, in canonical order. Empty when
    /// no stage was recorded (the caller renders its placeholder).
    var readout: [ReadoutRow] {
        stages.map { stage in
            ReadoutRow(stage: stage.stage,
                       // An unknown token can only come from a hand-built
                       // breakdown (the recorder records enum members) —
                       // shown verbatim rather than dropped.
                       label: TurnTimingStage(rawValue: stage.stage)?.label ?? stage.stage,
                       ms: stage.ms)
        }
    }

    /// `[{"ms":0,"stage":"stt_total"}, …]` — deterministic (sorted keys),
    /// byte-compatible with the `voice_turn_timing` event's `stages`.
    static func serialize(_ stages: [VoiceTurnLatencyTracer.StageTiming]) -> String {
        VoiceTurnLatencyTracer.serialize(stages)
    }
}

/// Per-turn stage stopwatch. One instance lives in the coordinator for
/// the life of the process; `beginTurn()`/`finishTurn()` bracket each
/// voice turn.
///
/// Every mutating entry point is lock-guarded: stages are recorded from
/// the encoder's inference queue, the speaker's detached synthesis task
/// and the pipeline's completion hops, while the turn edges arrive on
/// main — the same threading shape the tracer handles.
final class TurnTimingRecorder {

    /// Injectable monotonic clock in NANOSECONDS. Production reads
    /// `DispatchTime` (mach_absolute_time, nanosecond resolution); tests
    /// pin a manual clock for exact durations.
    var now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }

    private let lock = NSLock()
    /// Bumped on every turn so a span opened before a turn boundary can
    /// never record into the next one.
    private var epoch = 0
    private var turnActive = false
    /// Accumulated ms per `TurnTimingStage.rawValue` — repeated records of
    /// one stage SUM (a retry inside a turn is real time spent).
    private var recorded: [String: Int] = [:]

    init() {}

    // MARK: - Turn lifecycle

    /// Opens a turn: bumps the epoch and clears every recorded stage.
    func beginTurn() {
        lock.lock()
        epoch += 1
        turnActive = true
        recorded = [:]
        lock.unlock()
    }

    /// Ends the turn: returns the stages recorded during it (canonical
    /// order) and stops collecting. Records that land after this point
    /// are dropped until the next `beginTurn()`.
    func finishTurn() -> TurnTimingBreakdown {
        lock.lock()
        let snapshot = recorded
        recorded = [:]
        turnActive = false
        lock.unlock()
        let stages = TurnTimingStage.allCases.compactMap { stage
            -> VoiceTurnLatencyTracer.StageTiming? in
            guard let ms = snapshot[stage.rawValue] else { return nil }
            return VoiceTurnLatencyTracer.StageTiming(stage: stage.rawValue,
                                                      ms: max(0, ms))
        }
        return TurnTimingBreakdown(stages: stages)
    }

    // MARK: - Recording

    /// Records an externally measured duration. No-op while no turn is
    /// active (background speech must never open or extend a turn).
    func record(_ stage: TurnTimingStage, ms: Int) {
        lock.lock()
        guard turnActive else {
            lock.unlock()
            return
        }
        recorded[stage.rawValue, default: 0] += max(0, ms)
        lock.unlock()
    }

    /// Opens a span for `stage`, or nil while no turn is active — a span
    /// that is never finished records nothing (see `TurnTimingSpan`).
    func start(_ stage: TurnTimingStage) -> TurnTimingSpan? {
        lock.lock()
        defer { lock.unlock() }
        guard turnActive else { return nil }
        return TurnTimingSpan(recorder: self, stage: stage,
                              epoch: epoch, startNs: now())
    }

    /// Runs `body` inside a span for `stage` and returns its value — the
    /// call-site shape for the synchronous stages. The duration is
    /// recorded even when `body` throws (the time was spent either way).
    /// With no active turn the body runs untouched: no clock read, no lock.
    @discardableResult
    func measure<T>(_ stage: TurnTimingStage, _ body: () throws -> T) rethrows -> T {
        guard let span = start(stage) else { return try body() }
        defer { span.finish() }
        return try body()
    }

    /// Closes `span`: adds its elapsed ms to `span.stage` — only when the
    /// turn it opened in is still the active one.
    fileprivate func finish(_ span: TurnTimingSpan) {
        let current = now()
        // A non-monotonic reading (a misbehaving injected clock) reads as
        // 0 ms rather than a wrapped-around negative.
        let elapsedNs = current >= span.startNs ? current - span.startNs : 0
        let ms = Int(elapsedNs / 1_000_000)
        lock.lock()
        guard turnActive, epoch == span.epoch else {
            lock.unlock()
            return
        }
        recorded[span.stage.rawValue, default: 0] += max(0, ms)
        lock.unlock()
    }
}

/// One open stage span. `finish()` is ONE-SHOT and idempotent: a span
/// finished twice records exactly one duration, and a span that is never
/// finished (a cancelled utterance) records none — call sites can
/// therefore finish on every exit path without bookkeeping.
final class TurnTimingSpan {

    private let recorder: TurnTimingRecorder
    fileprivate let stage: TurnTimingStage
    fileprivate let epoch: Int
    fileprivate let startNs: UInt64

    private let lock = NSLock()
    private var finished = false

    fileprivate init(recorder: TurnTimingRecorder, stage: TurnTimingStage,
                     epoch: Int, startNs: UInt64) {
        self.recorder = recorder
        self.stage = stage
        self.epoch = epoch
        self.startNs = startNs
    }

    func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        recorder.finish(self)
    }
}

/// Nil-safe call-site sugar: `timingRecorder.measure(.encoderInference) { … }`
/// and `timingRecorder?.start(.ttsStart)`. With a nil recorder (a build
/// without `INTENT_ENCODER`) these are a branch and a plain call — the
/// zero-cost requirement, enforced at the call site rather than by a
/// feature check repeated in every instrumented file.
extension Optional where Wrapped == TurnTimingRecorder {

    @discardableResult
    func measure<T>(_ stage: TurnTimingStage, _ body: () throws -> T) rethrows -> T {
        guard let recorder = self else { return try body() }
        return try recorder.measure(stage, body)
    }

    func start(_ stage: TurnTimingStage) -> TurnTimingSpan? {
        self?.start(stage)
    }
}

/// [TURN-TIMING-BREAKDOWN] The SINGLE emission point for a turn's stage
/// breakdown: assembles the recorder's stages plus the reused STT span,
/// emits exactly one `turn_latency`/`turn_timing_breakdown` event, and
/// hands the breakdown to the caller's readout (`onReported`).
///
/// The reporter is wired to the tracer at composition
/// (`attach(to:)`) — it wraps whatever handlers already exist, so the
/// coordinator's transcript-caption hook keeps working unchanged.
final class TurnLatencyReporter {

    /// Event identity — pinned here so the wire contract lives in one
    /// place (and so tests assert the constants, not string copies).
    static let component = "turn_latency"
    static let eventType = "turn_timing_breakdown"
    /// The tracer's own stage token for the reused ASR span.
    static let sttStageToken = "asr_done"

    private let observabilityBus: ObservabilityBus
    private let recorder: TurnTimingRecorder
    /// Defense in depth, mirroring `IntentEncoderInterpreter.requestReadiness`:
    /// the coordinator already refuses to construct a reporter without the
    /// `INTENT_ENCODER` compilation condition, and this guard keeps a stray
    /// future caller from emitting internal-testing telemetry in a release
    /// build. Explicit (defaulted) so both sides are unit-testable.
    private let isInstrumentationEnabled: Bool

    /// Fired after each emitted breakdown, on the finalizing thread — the
    /// coordinator hops to main to publish the card's readout.
    var onReported: ((TurnTimingBreakdown) -> Void)?

    init(observabilityBus: ObservabilityBus,
         recorder: TurnTimingRecorder,
         isInstrumentationEnabled: Bool = IntentEncoderFeature.isEnabled) {
        self.observabilityBus = observabilityBus
        self.recorder = recorder
        self.isInstrumentationEnabled = isInstrumentationEnabled
    }

    /// Subscribes to the tracer's turn edges: `onTurnBegan` opens the
    /// recorder's turn, `onTurnFinalized` reports it. Both handlers CHAIN
    /// to any handler already installed (the coordinator's caption hook;
    /// a test's expectation), so attaching instrumentation never silently
    /// replaces existing wiring.
    ///
    /// Ordering: the tracer delivers an abandoned turn's finalize BEFORE
    /// it starts the new turn, so the report of the old turn runs before
    /// the new turn's `beginTurn()` — a stale breakdown can never include
    /// the next turn's stages.
    func attach(to tracer: VoiceTurnLatencyTracer) {
        let existingBegan = tracer.onTurnBegan
        tracer.onTurnBegan = { [weak self] in
            existingBegan?()
            self?.recorder.beginTurn()
        }
        let existingFinalized = tracer.onTurnFinalized
        tracer.onTurnFinalized = { [weak self] stages, totalMs in
            existingFinalized?(stages, totalMs)
            self?.report(tracerStages: stages, totalMs: totalMs)
        }
    }

    /// Assembles the finalized turn's breakdown and emits the ONE event
    /// for it. Returns the breakdown (empty when instrumentation is off),
    /// which is also what `onReported` receives.
    ///
    /// The STT stage is the tracer's `asr_done` span REUSED, not
    /// re-measured: the recognizers already time it, and the tracer's
    /// stage list is the chronological record of the turn.
    @discardableResult
    func report(tracerStages: [VoiceTurnLatencyTracer.StageTiming],
                totalMs: Int) -> TurnTimingBreakdown {
        // Always close the recorder's turn, even when disabled: the
        // state must not accumulate across turns for a later flip.
        let recorded = recorder.finishTurn()
        guard isInstrumentationEnabled else { return TurnTimingBreakdown(stages: []) }

        var stages = recorded.stages
        if let stt = tracerStages.first(where: { $0.stage == Self.sttStageToken }) {
            stages.insert(VoiceTurnLatencyTracer.StageTiming(stage: TurnTimingStage.sttTotal.rawValue,
                                                             ms: max(0, stt.ms)),
                          at: 0)
        }
        let breakdown = TurnTimingBreakdown(stages: stages)
        observabilityBus.emit(ObservabilityEvent(
            component: Self.component,
            eventType: Self.eventType,
            durationMs: max(0, totalMs),
            outcome: "success",
            errorCode: nil,
            // Stage names + milliseconds ONLY — the PII rule of the
            // event (see the file header). No other metadata key.
            metadata: ["stages": TurnTimingBreakdown.serialize(stages)]
        ))
        onReported?(breakdown)
        return breakdown
    }
}
