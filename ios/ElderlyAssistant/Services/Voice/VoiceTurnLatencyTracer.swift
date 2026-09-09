import Foundation

// MARK: - Voice turn latency tracer ([TURN-TIMING], 2026-09-09)
//
// Turn-scoped stage timer for one voice turn (wake → reply → speech end).
// Every hook in the voice pipeline, the router's LLM dispatch, and the
// TTS speaker calls one of the `mark` variants below; each stage records
// start/end monotonic timestamps plus a duration, and exactly ONE
// `voice_turn_timing` observability event per turn carries the ordered
// stage list (stage names only, snake_case — never transcript/reply text,
// so nothing PII-shaped reaches the bus).
//
// Duration model (diagnostics, not accounting):
//
//  · The stage list is CHRONOLOGICAL. `mark(_:)` closes the currently
//    open stage at `now` — its entry's ms is set to the time from its
//    own mark until this one — and opens the named stage with a 0 ms
//    placeholder. Finalize closes the last open stage and appends
//    `turn_end` (ms 0 — the boundary marker), so the non-placeholder
//    stage ms values sum to the total turn duration.
//  · `mark(_:elapsedMs:)` appends an externally measured duration as a
//    POINT entry (e.g. `asr_loaded` / `tts_voice_loaded` — measured
//    inside the model-loader boundary), in its emission position. Point
//    entries do NOT disturb the open-stage bookkeeping, so the open
//    stage's ms keeps accumulating across them — an intentional,
//    documented overlap: the point entry answers "how long was the
//    load", the surrounding stage answers "how long was the whole step".
//
//  · Speak tracking: `noteSpeakQueued()`/`noteSpeakFinished()` keep a
//    pending-speech counter. `endTurn()` (dispatch resolved) only
//    finalizes the turn once every queued utterance finished, so
//    `turn_end` lands at the end of the last reply — never while speech
//    is still playing. A turn with no speech finalizes at `endTurn()`.
//
// The event fires REGARDLESS of the "Show conversation timing" toggle
// (console evidence for remote debugging); the UI caption behind that
// toggle is the coordinator's separate rendering concern.

final class VoiceTurnLatencyTracer {

    /// One named stage and its measured duration. `ms` is `var` so the
    /// open stage's placeholder (0) is closed in place when the next
    /// mark lands — keeping the stage list chronological.
    struct StageTiming: Equatable, Codable {
        let stage: String
        var ms: Int
    }

    /// Injectable monotonic clock (seconds) — pinned in unit tests for
    /// deterministic duration math. Production uses the system uptime
    /// clock (monotonic — immune to wall-clock adjustments).
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// Fired once per finalized turn with the ordered stage list and the
    /// total turn ms. Called off the tracer's lock, on whatever queue
    /// finalized the turn — hop to main in the handler.
    var onTurnFinalized: ((_ stages: [StageTiming], _ totalMs: Int) -> Void)?

    private let bus: ObservabilityBus
    private let lock = NSLock()

    private var turnStart: TimeInterval?
    private var openStageIndex: Int?
    private var lastMark: TimeInterval?
    private var stages: [StageTiming] = []
    private var pendingSpeaks = 0
    private var dispatchResolved = false

    init(observabilityBus: ObservabilityBus) {
        self.bus = observabilityBus
    }

    // MARK: - Turn lifecycle

    /// Starts (or defensively re-starts) a turn. An active turn found at
    /// begin time is finalized immediately — its evidence is emitted
    /// rather than silently dropped.
    func beginTurn() {
        lock.lock()
        if let finalized = takeFinalizedLocked() {
            lock.unlock()
            deliver(finalized)
            lock.lock()
        }
        let t = now()
        turnStart = t
        stages = [StageTiming(stage: "turn_start", ms: 0)]
        openStageIndex = 0
        lastMark = t
        pendingSpeaks = 0
        dispatchResolved = false
        lock.unlock()
    }

    /// Closes the currently open stage at `now` (its ms = time since its
    /// start) and opens `stage`. No-op while no turn is active —
    /// background speech (notification announcements) must never open or
    /// extend a turn.
    func mark(_ stage: String) {
        lock.lock()
        markLocked(stage)
        lock.unlock()
    }

    /// Appends an externally measured duration as a point entry (see the
    /// type doc for the overlap contract). No-op while no turn is active.
    func mark(_ stage: String, elapsedMs: Int) {
        lock.lock()
        guard turnStart != nil else {
            lock.unlock()
            return
        }
        stages.append(StageTiming(stage: stage, ms: max(0, elapsedMs)))
        lock.unlock()
    }

    /// A reply utterance was handed to the speaker: records
    /// `speak_queued` and opens the pending-speech counter.
    func noteSpeakQueued() {
        lock.lock()
        guard turnStart != nil else {
            lock.unlock()
            return
        }
        markLocked("speak_queued")
        pendingSpeaks += 1
        lock.unlock()
    }

    /// A queued utterance finished (spoken or cancelled). When the turn's
    /// dispatch already resolved and this was the last pending utterance,
    /// the turn finalizes here.
    func noteSpeakFinished() {
        lock.lock()
        guard turnStart != nil else {
            lock.unlock()
            return
        }
        markLocked("speak_finished")
        pendingSpeaks = max(0, pendingSpeaks - 1)
        let finalized = (dispatchResolved && pendingSpeaks == 0)
            ? takeFinalizedLocked() : nil
        lock.unlock()
        if let finalized {
            deliver(finalized)
        }
    }

    /// The turn's dispatch (router) has resolved its reply — sync routes
    /// call this right after `route()` returns; the async LLM path calls
    /// it from the interpret completion. Finalizes immediately when no
    /// speech is pending, else waits for the last `noteSpeakFinished()`.
    func endTurn() {
        lock.lock()
        guard turnStart != nil else {
            lock.unlock()
            return
        }
        dispatchResolved = true
        let finalized = (pendingSpeaks == 0) ? takeFinalizedLocked() : nil
        lock.unlock()
        if let finalized {
            deliver(finalized)
        }
    }

    /// Abandons the active turn WITHOUT emitting (pipeline `stop()`
    /// mid-turn — the capture was cancelled, no evidence to report).
    func cancelTurn() {
        lock.lock()
        turnStart = nil
        openStageIndex = nil
        lastMark = nil
        stages = []
        pendingSpeaks = 0
        dispatchResolved = false
        lock.unlock()
    }

    // MARK: - Locked helpers (lock held)

    private func markLocked(_ stage: String) {
        guard let openStageIndex, let lastMark else { return }
        let t = now()
        // The currently open stage's duration = time until this mark.
        stages[openStageIndex].ms = max(0, Int((t - lastMark) * 1000))
        stages.append(StageTiming(stage: stage, ms: 0))
        self.openStageIndex = stages.count - 1
        self.lastMark = t
    }

    /// Closes the turn and returns the finalized stage list + total ms
    /// (or nil when no turn is active). Resets the tracer state.
    private func takeFinalizedLocked() -> (stages: [StageTiming], totalMs: Int)? {
        guard let turnStart, let openStageIndex, let lastMark else { return nil }
        let t = now()
        let totalMs = max(0, Int((t - turnStart) * 1000))
        // Close the last open stage, then append the boundary marker.
        stages[openStageIndex].ms = max(0, Int((t - lastMark) * 1000))
        stages.append(StageTiming(stage: "turn_end", ms: 0))
        let result = (stages: stages, totalMs: totalMs)
        self.turnStart = nil
        self.openStageIndex = nil
        self.lastMark = nil
        self.stages = []
        pendingSpeaks = 0
        dispatchResolved = false
        return result
    }

    /// Emits the `voice_turn_timing` event and fires the callback — both
    /// outside the lock.
    private func deliver(_ finalized: (stages: [StageTiming], totalMs: Int)) {
        bus.emit(ObservabilityEvent(
            component: "voice_turn_timing",
            eventType: "voice_turn_timing",
            durationMs: finalized.totalMs,
            outcome: "success",
            errorCode: nil,
            metadata: ["stages": Self.serialize(finalized.stages)]
        ))
        onTurnFinalized?(finalized.stages, finalized.totalMs)
    }

    // MARK: - Pure presentation helpers (unit-tested, no state)

    /// Serializes the stage list as a JSON array —
    /// `[{"stage":"turn_start","ms":0}, …]`. Deterministic: a flat array
    /// of Codable structs, no dictionary key ordering.
    static func serialize(_ stages: [StageTiming]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]  // deterministic key order
        let data = (try? encoder.encode(stages)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// The stage names the compact UI caption shows, in display order —
    /// short technical labels, diagnostic tokens only.
    static let captionEntries: [(label: String, stage: String)] = [
        ("asr", "asr_done"),
        ("llm", "llm_done"),
        ("tts", "tts_done"),
        ("play", "speak_finished"),
    ]

    /// Compact per-stage breakdown for the transcript caption —
    /// `"asr 120ms · llm 2.4s · tts 310ms"`. Only stages that actually
    /// occurred appear, in `captionEntries` order; "" when none did.
    static func caption(stages: [StageTiming]) -> String {
        let byStage = Dictionary(stages.map { ($0.stage, $0.ms) },
                                 uniquingKeysWith: { first, _ in first })
        return captionEntries.compactMap { entry -> String? in
            guard let ms = byStage[entry.stage] else { return nil }
            return "\(entry.label) \(msText(ms))"
        }.joined(separator: " · ")
    }

    /// `120ms` under a second, else one-decimal seconds (`2.4s`).
    static func msText(_ ms: Int) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        }
        let seconds = Double(ms) / 1000
        let value = (seconds * 10).rounded() / 10
        return "\(value)s"
    }
}
