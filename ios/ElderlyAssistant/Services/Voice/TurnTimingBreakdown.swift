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

// MARK: - Pipeline debug trace ([PIPELINE-TRACE], 2026-09-16)
//
// The FULL-WIDTH sibling of the breakdown above. Where the breakdown
// answers "how long did each stage take" (numbers only, one event, one
// card section), the trace answers "what went IN, what came OUT, WHAT
// WAS DECIDED and how long it took" for EVERY gate of the voice→intent
// pipeline — the STT transcript, the corrector, the canonicalizer, the
// encoder's three stages, the confidence band, the cascade's
// serve-or-escalate branch, the picker brain's prompt and FINAL LLM
// round-trip, and the TTS hand-off.
//
// DISCLOSURE POSTURE — the same one the "Last correction" line already
// ships, stated once here because it is the whole reason this type is
// safe to have:
//
//  · The CARD READOUT may name the words. It is the on-device debugger's
//    view (internal-testing Settings screen), and a debugger that cannot
//    see the text going in and out of each gate cannot tell a wrong
//    correction from a missing one. The strings live in memory on the
//    coordinator, LAST TURN ONLY, and disappear with the process.
//  · The EVENT never carries them. `PipelineTrace.eventMetadata` is
//    `{"stages": [{"ms": <int>, "stage": <fixed token>}, …]}` — the
//    SAME wire shape the breakdown event already uses, so one decoder
//    reads either, and nothing PII-shaped can reach the bus: the stage
//    vocabulary is a closed enum and the payload is integers and tokens.
//    The decision strings (`off(encoder_not_serving)`, `accept/local`, …)
//    stay on the device with the summaries — the card is their only
//    surface.
//  · NOTHING IS PERSISTED. Never a file, never an encrypted store, never
//    `IntentLogStore`. Same posture as `TurnTimingBreakdown` and
//    `CorrectionReadout` — the trace lives in memory, last turn only, and
//    disappears with the process.
//  · THE CONSOLE SPLITS BY COMPILATION CONFIGURATION, and that split is
//    the B1 release-log rule (`tools/check-release-log-safety.py`) applied
//    to this type: a Debug build's device log carries the FULL rows
//    (summaries included) because the tester reading the console is the
//    same person looking at the Settings card, and a captured Debug log is
//    the point of the console dump; a RELEASE build's log carries a
//    content-free line per stage — stage token, milliseconds, decision
//    token, structured token count — never the summaries. `logToConsole`
//    picks the shape with `#if DEBUG`, and `consoleLines(includeSummaries:)`
//    keeps both shapes testable in one place so the release shape cannot
//    drift into carrying words.
//
// COST — zero when nothing is instrumented, exactly like the timing
// recorder: every call site is an optional-chained `start`/`record`, so a
// nil recorder (a build without `INTENT_ENCODER`) is a nil check and a
// plain call — no clock read, no lock, no allocation.
//
// THIS IS PURE INSTRUMENTATION. No gate below reads a row, and the
// routing/decision code is byte-for-byte what it was: the recorder is
// read only after a turn's outcome is already settled (see
// `TurnLatencyReporter.report`).

/// The trace's stage vocabulary, in canonical pipeline order — the order
/// the card renders and the order the stages actually run in.
///
/// Raw values are the machine tokens (`snake_case`, never localized);
/// they are what the trace EVENT carries, so adding a stage is a schema
/// change and the set is deliberately closed.
enum PipelineTraceStage: String, CaseIterable {
    /// The recognizer's own span: audio in, transcript out. Its DURATION
    /// is the tracer's `asr_done` span REUSED, never re-measured (see
    /// `PipelineTraceRecorder.finishTurn(asrMs:)`).
    case stt
    /// `STTCorrector.correct` — sanitised transcript in, corrected text
    /// out, `CorrectionDecision.reason` as the decision (TG-12).
    case corrector
    /// `DialectCanonicalizer.canonicalize` — corrected text in, canonical
    /// text out, applied rule ids as the decision.
    case canonicalizer
    /// `IntentEncoderTokenizer.tokenize` — text in, token count out.
    case encoderTokenizer = "encoder_tokenizer"
    /// The CoreML forward pass.
    case encoderInference = "encoder_inference"
    /// `IntentEncoderDecoder.decode` — logits in, intent + slots out.
    case encoderDecode = "encoder_decode"
    /// `IntentRouter`'s band policy — the turn's confidence score, the
    /// band it landed in, and what the policy did with it.
    case band
    /// `LocalBrainChain`'s serve-or-escalate branch (cascade mode).
    case cascade
    /// The picker brain's prompt construction (`IntentPrompt.build`).
    case pickerPrompt = "picker_prompt"
    /// The picker brain's llama.cpp round-trip — the FINAL LLM time.
    case pickerInference = "picker_inference"
    /// Handed-to-speaker → audio start (the speaker's own ramp).
    case tts

    /// Short technical label for the card's row — the same non-localized
    /// diagnostic style as `TurnTimingStage.label`.
    var label: String {
        switch self {
        case .stt:              return "stt"
        case .corrector:        return "corrector"
        case .canonicalizer:    return "canonicalizer"
        case .encoderTokenizer: return "enc tokenize"
        case .encoderInference: return "enc infer"
        case .encoderDecode:    return "enc decode"
        case .band:             return "band"
        case .cascade:          return "cascade"
        case .pickerPrompt:     return "picker prompt"
        case .pickerInference:  return "picker LLM"
        case .tts:              return "tts start"
        }
    }

    /// The fixed token a stage that DID NOT RUN is marked with —
    /// "disabled stages are marked off, not omitted" (the whole reason
    /// `finishTurn` fills every stage). The card renders it as
    /// `off(<token>)`; the token itself stays a closed-vocabulary string
    /// so it could ride an event unchanged if one ever needs it.
    var offReason: String {
        switch self {
        case .stt:
            return "no_capture"
        case .corrector, .canonicalizer:
            // [CORRECTION-ANYBRAIN] The two pre-intent layers now run at
            // the LOCAL SLOT's input, whichever brain serves it — so this
            // token is the backfill for a turn the seam never ran on (no
            // input seam attached, i.e. a caller outside the slot). A
            // layer that ran with its switch off is marked with the
            // layer's own `disabled` instead, from the seam itself.
            return "seam_not_run"
        case .encoderTokenizer, .encoderInference, .encoderDecode:
            // The three encoder stages exist only while the encoder is the
            // brain that served; in every other mode the turn never
            // reached them.
            return "encoder_not_serving"
        case .band:
            return "no_command_reached_the_band_policy"
        case .cascade:
            return "cascade_off"
        case .pickerPrompt, .pickerInference:
            return "picker_not_consulted"
        case .tts:
            return "not_spoken"
        }
    }
}

/// One trace row — one pipeline stage's full story for the turn.
///
/// `durationMs` is a measured millisecond count for every stage except
/// `stt`, whose row is filled with the tracer's own ASR span at assembly
/// (see `PipelineTraceRecorder.finishTurn(asrMs:)`); a stage that did not
/// run carries 0 and `ran == false`.
struct PipelineTraceRow: Equatable, Identifiable {

    let stage: PipelineTraceStage
    /// What went in, as the ON-DEVICE card may show it (truncated, one
    /// line) — never placed in an event.
    let inputSummary: String
    /// What came out, same disclosure rules.
    let outputSummary: String
    let durationMs: Int
    /// The stage's own closed-vocabulary decision token; for a stage that
    /// did not run, the REASON it did not (see `PipelineTraceStage.offReason`).
    ///
    /// MUST STAY A TOKEN. Unlike the two summaries, this field is also
    /// printed by the RELEASE console dump (see `PipelineTrace.logToConsole`),
    /// so it may never be built from the user's words — codes only.
    let decision: String
    /// False for a stage that did not participate in this turn. Such a row
    /// is always present — marked, never omitted.
    let ran: Bool
    /// The stage's ONE structured count, where a count exists: the
    /// tokenizer's token count, the forward pass's input tokens, the
    /// picker's estimated prompt tokens. A plain integer, so it is the
    /// only part of a summary that may ride the RELEASE console line
    /// (the same number also appears in the text summaries, which stay on
    /// the card and in Debug builds).
    var tokenCount: Int? = nil

    var id: String { stage.rawValue }

    var durationText: String { VoiceTurnLatencyTracer.msText(durationMs) }

    /// The card's decision cell: `off(<reason>)` for a stage that did not
    /// run, else the stage's own token.
    var decisionText: String { ran ? decision : "off(\(decision))" }

    /// The card's second line: `in: … → out: …`.
    var summaryText: String { "in: \(inputSummary) → out: \(outputSummary)" }
}

/// One turn's full trace, in canonical stage order — EVERY stage present,
/// the ones that did not run marked `off(…)`.
struct PipelineTrace: Equatable {

    /// Event identity — pinned here so the wire contract lives in one
    /// place (tests assert the constants, not string copies).
    static let component = "pipeline_trace"
    static let eventType = "turn_pipeline_trace"

    let rows: [PipelineTraceRow]

    var isEmpty: Bool { rows.isEmpty }

    /// Stages that actually ran this turn — what the card counts in its
    /// header line ("9/11 stages ran").
    var ranCount: Int { rows.filter(\.ran).count }

    /// The egressing payload: stage tokens and millisecond numbers ONLY,
    /// byte-compatible with `TurnTimingBreakdown.serialize` so one decoder
    /// reads either. The summaries and decisions stay on the device —
    /// this is the PII line of the file header, and a test pins it.
    var eventMetadata: [String: String] {
        let stages = rows.map {
            VoiceTurnLatencyTracer.StageTiming(stage: $0.stage.rawValue,
                                               ms: max(0, $0.durationMs))
        }
        return ["stages": VoiceTurnLatencyTracer.serialize(stages)]
    }
}

// MARK: - Console dump ([PIPELINE-TRACE], console half)
extension PipelineTrace {

    /// Log prefix — greppable in a captured console, and the same word the
    /// Settings section uses.
    static let consolePrefix = "[pipeline-trace]"

    /// The trace as console lines.
    ///
    /// `includeSummaries` selects the SHAPE, and it is a parameter only so
    /// both shapes stay testable in one place — production picks it at
    /// COMPILE TIME in `logToConsole` (`#if DEBUG`), never at runtime:
    ///
    ///  · `true` — the Debug shape: `stage  ms  decision  in: … → out: …`,
    ///    summaries and all. The device console in a Debug build is the
    ///    internal-testing surface, the same disclosure posture as the
    ///    Settings card (the file header states it).
    ///  · `false` — the Release shape: `stage  ms  decision  tok=<n>`, and
    ///    NOTHING else. Every field is a closed-vocabulary token or an
    ///    integer, so the line cannot render the user's words even though
    ///    a Release build still compiles it (B1: no transcript content in
    ///    a Release log sink).
    ///
    /// A stage that did not run prints its `off(<reason>)` token in both
    /// shapes — the console shows the same "marked, never omitted" rule
    /// the card does.
    func consoleLines(includeSummaries: Bool) -> [String] {
        rows.map { row in
            var line = "\(Self.consolePrefix) \(row.stage.rawValue) "
                + "\(row.durationText) \(row.decisionText)"
            if let tokenCount = row.tokenCount { line += " tok=\(tokenCount)" }
            guard includeSummaries else { return line }
            return line + " | " + row.summaryText
        }
    }

    /// Prints the turn's trace to the device console.
    ///
    /// The header is count-only in BOTH configurations (stages ran, total
    /// ms) — it is printed outside any `#if DEBUG`, so it must not carry
    /// content in a Release build.
    func logToConsole(totalMs: Int) {
        // The one line that is always printed: counts and a duration.
        print("\(Self.consolePrefix) turn \(ranCount)/\(rows.count) stages ran, "
              + "\(max(0, totalMs)) ms total")
        #if DEBUG
        consoleLines(includeSummaries: true).forEach { print($0) }
        #else
        consoleLines(includeSummaries: false).forEach { print($0) }
        #endif
    }
}

/// Formats the trace's short one-line summaries. Kept in one place so
/// every call site truncates the same way and no summary can grow into an
/// unbounded dump on the card.
enum PipelineTraceSummary {

    /// Longest summary the card shows per field; longer text is truncated
    /// with an ellipsis (the card is a readout, not a transcript view).
    static let maxLength = 28

    /// One line, bounded. Newlines collapse to spaces so a multi-line
    /// reply cannot break the card's row rhythm.
    static func text(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "(empty)" }
        guard flattened.count > maxLength else { return flattened }
        return String(flattened.prefix(maxLength)) + "…"
    }

    /// `42 tok` — a real token count (the encoder's tokenizer reports one).
    static func tokens(_ count: Int) -> String { "\(count) tok" }

    /// `~180 tok (est)` — an ESTIMATE for a prompt that no tokenizer in
    /// this process measured. The picker brain's llama.cpp runtime
    /// tokenizes internally and exposes no count, so the estimate is
    /// deliberately coarse and labelled: about four characters per token,
    /// which is the usual BPE ratio for the Latin template text and an
    /// UNDER-estimate for Devanagari. It exists to make a prompt that is
    /// heading for the 1,024-token context visible on the card, not to
    /// pretend to be a measurement.
    static func estimatedPromptTokens(_ prompt: String) -> String {
        "~\(estimatedPromptTokenCount(prompt)) tok (est)"
    }

    /// The estimate behind `estimatedPromptTokens`, as the integer the
    /// row carries — one computation, so the text and the structured
    /// count can never disagree (and the count is the release-safe half).
    static func estimatedPromptTokenCount(_ prompt: String) -> Int {
        prompt.count / 4
    }

    /// `0.82` — the card's and the correction line's shared two-decimal
    /// formatting.
    static func score(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

/// Per-turn stopwatch + summary recorder for the pipeline debug trace.
/// One instance lives in the coordinator; `beginTurn()`/`finishTurn(…)`
/// bracket each voice turn, driven by the SAME tracer edges the timing
/// recorder rides (`TurnLatencyReporter.attach(to:)`).
///
/// ONE ROW PER STAGE: a stage's row is REPLACED by a later record for the
/// same stage — the furthest-along owner of that stage is the one whose
/// decision the turn actually ended with (the outer cascade chain
/// overwrites the inner chain's `cascade_off`, and the router's final
/// band call overwrites an earlier dropped one). The readout is always in
/// canonical stage order regardless of the order records landed in.
///
/// Lock-guarded like the timing recorder: rows arrive from the inference
/// queue, the speaker's detached synthesis task and the pipeline's
/// completion hops, while the turn edges arrive on main.
final class PipelineTraceRecorder {

    /// Injectable monotonic clock in NANOSECONDS (production:
    /// `DispatchTime`, mach_absolute_time-backed; tests pin a manual
    /// clock for exact durations) — the timing recorder's own convention.
    var now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }

    private let lock = NSLock()
    /// Bumped on every turn so a stage opened before a turn boundary can
    /// never record into the next one.
    private var epoch = 0
    private var turnActive = false
    private var rows: [String: PipelineTraceRow] = [:]

    init() {}

    // MARK: - Turn lifecycle

    /// Opens a turn: bumps the epoch and drops the previous turn's rows.
    func beginTurn() {
        lock.lock()
        epoch += 1
        turnActive = true
        rows = [:]
        lock.unlock()
    }

    /// Ends the turn and returns it, every stage present and in canonical
    /// order. `asrMs` REPLACES the `stt` row's duration with the
    /// tracer's own `asr_done` span — the recognizers already time the
    /// ASR, so a second clock reading of the same work would only add
    /// noise (the doctrine `TurnLatencyReporter` states for the
    /// breakdown's `stt_total`). Records that land after this point are
    /// dropped until the next `beginTurn()`.
    func finishTurn(asrMs: Int? = nil) -> PipelineTrace {
        lock.lock()
        var snapshot = rows
        rows = [:]
        turnActive = false
        lock.unlock()
        if let asrMs, let stt = snapshot[PipelineTraceStage.stt.rawValue] {
            snapshot[PipelineTraceStage.stt.rawValue] = PipelineTraceRow(
                stage: stt.stage,
                inputSummary: stt.inputSummary,
                outputSummary: stt.outputSummary,
                durationMs: max(0, asrMs),
                decision: stt.decision,
                ran: stt.ran,
                tokenCount: stt.tokenCount)
        }
        // Every stage, always: a stage with no recorded row did not run
        // this turn, and says so with its own off-reason rather than
        // disappearing (a trace with holes cannot be read as a trace).
        let ordered = PipelineTraceStage.allCases.map { stage in
            snapshot[stage.rawValue] ?? PipelineTraceRow(stage: stage,
                                                         inputSummary: "—",
                                                         outputSummary: "not run",
                                                         durationMs: 0,
                                                         decision: stage.offReason,
                                                         ran: false)
        }
        return PipelineTrace(rows: ordered)
    }

    // MARK: - Recording

    /// Records (or replaces) one stage's row. `ms == nil` means "no
    /// duration measured here" — the row carries 0 unless the report
    /// supplies the tracer's own span (which is what happens for `stt`).
    /// No-op while no turn is active: background speech (a notification
    /// read-aloud) must never open or extend a turn.
    func record(_ stage: PipelineTraceStage,
                input: String,
                output: String,
                decision: String,
                ms: Int? = nil,
                ran: Bool = true,
                tokenCount: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard turnActive else { return }
        rows[stage.rawValue] = PipelineTraceRow(stage: stage,
                                                inputSummary: input,
                                                outputSummary: output,
                                                durationMs: max(0, ms ?? 0),
                                                decision: decision,
                                                ran: ran,
                                                tokenCount: tokenCount)
    }

    /// Marks one or more stages as NOT RUN, with the honest reason — the
    /// explicit half of the off-marking (the other half is `finishTurn`'s
    /// fill for stages no owner mentioned at all).
    func recordOff(_ stages: [PipelineTraceStage], reason: String) {
        for stage in stages {
            record(stage, input: "—", output: "not run",
                   decision: reason, ms: nil, ran: false)
        }
    }

    /// Opens a span for `stage`, or nil while no turn is active — a span
    /// that is never finished records nothing (see `PipelineTraceSpan`).
    func start(_ stage: PipelineTraceStage, input: String) -> PipelineTraceSpan? {
        lock.lock()
        defer { lock.unlock() }
        guard turnActive else { return nil }
        return PipelineTraceSpan(recorder: self, stage: stage, epoch: epoch,
                                 startNs: now(), input: input)
    }

    /// Closes `span`, recording its elapsed ms and the caller's summaries
    /// — only when the turn it opened in is still the active one.
    fileprivate func finish(_ span: PipelineTraceSpan,
                            input: String,
                            output: String,
                            decision: String,
                            tokenCount: Int?) {
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
        rows[span.stage.rawValue] = PipelineTraceRow(stage: span.stage,
                                                     inputSummary: input,
                                                     outputSummary: output,
                                                     durationMs: max(0, ms),
                                                     decision: decision,
                                                     ran: true,
                                                     tokenCount: tokenCount)
        lock.unlock()
    }
}

/// One open trace span. `finish` is ONE-SHOT and idempotent: a span
/// finished twice records exactly one row, and a span that is never
/// finished (a cancelled utterance, a turn that ended first) records none
/// — call sites can therefore finish on every exit path without
/// bookkeeping, exactly like `TurnTimingSpan`.
final class PipelineTraceSpan {

    private let recorder: PipelineTraceRecorder
    fileprivate let stage: PipelineTraceStage
    fileprivate let epoch: Int
    fileprivate let startNs: UInt64
    fileprivate let input: String

    private let lock = NSLock()
    private var finished = false

    fileprivate init(recorder: PipelineTraceRecorder, stage: PipelineTraceStage,
                     epoch: Int, startNs: UInt64, input: String) {
        self.recorder = recorder
        self.stage = stage
        self.epoch = epoch
        self.startNs = startNs
        self.input = input
    }

    /// Closes the span. `input` defaults to what the span opened with and
    /// is overridable for stages whose input is only known once the work
    /// is done (the picker's prompt size, measured after the build).
    func finish(input: String? = nil, output: String, decision: String,
                tokenCount: Int? = nil) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        recorder.finish(self, input: input ?? self.input,
                        output: output, decision: decision,
                        tokenCount: tokenCount)
    }
}

/// Nil-safe call-site sugar, the timing recorder's own shape:
/// `traceRecorder?.start(.cascade, input: …)`. With a nil recorder these
/// are a nil check and a plain call.
extension Optional where Wrapped == PipelineTraceRecorder {

    func start(_ stage: PipelineTraceStage, input: String) -> PipelineTraceSpan? {
        self?.start(stage, input: input)
    }

    /// Records a stage as not run, nil-safely.
    func recordOff(_ stages: [PipelineTraceStage], reason: String) {
        self?.recordOff(stages, reason: reason)
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
    /// [PIPELINE-TRACE] The full-width debug trace's recorder — nil on
    /// every call site that does not want one (existing tests, and any
    /// future non-gated configuration). Its turn edges ride the SAME
    /// attach point as the timing recorder's, so the two can never
    /// disagree about where a turn began or ended.
    private let traceRecorder: PipelineTraceRecorder?
    /// Defense in depth, mirroring `IntentEncoderInterpreter.requestReadiness`:
    /// the coordinator already refuses to construct a reporter without the
    /// `INTENT_ENCODER` compilation condition, and this guard keeps a stray
    /// future caller from emitting internal-testing telemetry in a release
    /// build. Explicit (defaulted) so both sides are unit-testable.
    private let isInstrumentationEnabled: Bool

    /// Fired after each emitted breakdown, on the finalizing thread — the
    /// coordinator hops to main to publish the card's readout.
    var onReported: ((TurnTimingBreakdown) -> Void)?

    /// [PIPELINE-TRACE] Fired after the turn's trace is assembled, on the
    /// finalizing thread — the coordinator hops to main to publish the
    /// card's "Pipeline trace" section. The trace carries the ON-DEVICE
    /// summaries (the same disclosure posture as the correction line); the
    /// event emitted alongside it does NOT.
    var onTraceReported: ((PipelineTrace) -> Void)?

    init(observabilityBus: ObservabilityBus,
         recorder: TurnTimingRecorder,
         traceRecorder: PipelineTraceRecorder? = nil,
         isInstrumentationEnabled: Bool = IntentEncoderFeature.isEnabled) {
        self.observabilityBus = observabilityBus
        self.recorder = recorder
        self.traceRecorder = traceRecorder
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
            // [PIPELINE-TRACE] The trace opens on the same edge, AFTER
            // any abandoned turn was reported above (the tracer delivers
            // a finalize before the new begin), so a stale row can never
            // land in the new turn.
            self?.traceRecorder?.beginTurn()
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

        // The tracer's own ASR span, reused for both readouts: the STT
        // row's duration in the trace, and the breakdown's `stt_total`.
        let sttMs = tracerStages.first(where: { $0.stage == Self.sttStageToken })
            .map { max(0, $0.ms) }
        // [PIPELINE-TRACE] Closed on the same edge, before the
        // instrumentation guard: a disabled reporter still ends the
        // trace's turn, so a flip cannot leave stale rows behind.
        let trace = traceRecorder?.finishTurn(asrMs: sttMs)

        guard isInstrumentationEnabled else { return TurnTimingBreakdown(stages: []) }

        var stages = recorded.stages
        if let sttMs {
            stages.insert(VoiceTurnLatencyTracer.StageTiming(stage: TurnTimingStage.sttTotal.rawValue,
                                                             ms: sttMs),
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

        // [PIPELINE-TRACE] The trace's OWN event, emitted beside the
        // breakdown's — `{"stages": [{stage, ms}, …]}` and nothing else,
        // so the summaries and decisions the card shows at that moment
        // (the user's own words among them) never reach the bus.
        if let trace {
            observabilityBus.emit(ObservabilityEvent(
                component: PipelineTrace.component,
                eventType: PipelineTrace.eventType,
                durationMs: max(0, totalMs),
                outcome: "success",
                errorCode: nil,
                metadata: trace.eventMetadata
            ))
            onTraceReported?(trace)
            // [PIPELINE-TRACE] …and the console copy. Debug builds print
            // the full rows, Release builds the count-only shape; the
            // choice is made inside `logToConsole` at compile time (see
            // its doc — it is the B1 release-log rule).
            trace.logToConsole(totalMs: totalMs)
        }
        return breakdown
    }
}
