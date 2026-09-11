import Foundation

// MARK: - Invariance boot contract ([LAT-M1], 2026-09-11)
//
// The invariance contract the latency-compliance plan requires: the speak
// button is enabled IF AND ONLY IF
//
//    pipeline started
//    ∧ whisper warm settled (ready, or skipped with an honest reason)
//    ∧ primary reply-voice warm settled
//    ∧ llama interpreter warm settled
//    ∧ KWS hot-swap settled
//
// so request #1 runs on the same warm engines as request #50. This
// machine is the pure, unit-tested half of that contract (no clock, no
// queues — same doctrine as `ManualTalkReadinessState`); the coordinator
// feeds it and publishes the COMBINED readiness through
// `TalkBootContract.combine`.
//
// Budget semantics ([LAT-M1] conversion of the old 4 s "expire and
// enable"):
//
//  - `WarmStartPlanner.bootWarmBudgetSeconds` still bounds the SPINNER's
//    `.warmingEngines` stage — a slow warm finishes detached, and boot
//    reaches `.ready` on schedule (the startup-perf contract is intact).
//  - The TALK BUTTON does not follow the budget: it stays disabled with
//    the honest preparing label + per-feature status until every feature
//    settles — budget expiry alone NEVER enables it (no silent enable).
//  - A warm step that FAILS (or outlives the talk watchdog) settles the
//    contract DEGRADED: the button enables with a banner naming the cold
//    features — the first conversation honestly pays those loads.
//  - A warm step that never settles cannot block forever: the
//    coordinator's talk watchdog (see `noteTalkWatchdogExpired`) fails
//    still-pending features.
//
// [CONTRACT-FIX] The never-stuck guarantee (device field report, the
// speak button stuck disabled with the preparing label):
//
//  - The watchdog's deadline runs on an INDEPENDENT scheduler — never the
//    warm queue — so a warm hung on its own serial queue can never delay
//    settlement past the deadline (`TalkBootWatchdog`; the coordinator
//    arms it on main). First arm wins: progress notes and retry re-plans
//    never extend the deadline.
//  - The watchdog fire re-reads CURRENT state: it only settles features
//    that are still `.pending`, so a settle signal that landed just
//    before the deadline is honored, never overwritten.
//  - A publisher that never emits is not fatal: warm outcomes have a
//    runner-level per-step timeout (`WarmStartRunner`, seam_timeout),
//    and the KWS path settles on EVERY exit of the deferred build —
//    including "no pipeline to swap into" — plus the watchdog skip.
//    Manual Talk never depends on a signal that can never arrive.
//
// Settlement rules:
//
//  - `.skip` actions (simulator, gemini_stack, model_missing,
//    preference_off) are SETTLED — a skipped feature satisfies the
//    contract exactly like a ready one: the skip is the planner's honest
//    "this engine is not part of THIS launch's first conversation".
//  - Settled states are sticky EXCEPT the honest upgrades: a retry warm
//    outcome (the degraded-capability recovery path) upgrades
//    `.failed` → `.ready`, and a late real settle upgrades
//    `.skipped(reason: "watchdog")`. Nothing else moves a settled
//    feature.
//  - KWS NEVER degrades manual Talk (the startup-r2 doctrine): a Null
//    engine settle is `.skipped(reason: "null_engine")` — satisfied, no
//    banner; a KWS build still pending at the watchdog falls back to the
//    Null behavior the same way (`.skipped(reason: "watchdog")`).

/// The features the contract gates on.
enum TalkBootFeature: String, CaseIterable, Equatable, Hashable {
    case whisper
    case primaryTTS
    case llama
    case kws
}

/// One feature's state. `skipped`/`failed` carry a MACHINE reason string
/// (logs/events), never user copy — the UI maps the status, not the text.
enum TalkBootFeatureStatus: Equatable {
    case pending
    case ready
    case skipped(reason: String)
    case failed(reason: String)

    var isSettled: Bool {
        if case .pending = self { return false }
        return true
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The preparing label's per-feature snapshot (published while the
/// contract is still open).
struct TalkBootProgress: Equatable {
    let statuses: [TalkBootFeature: TalkBootFeatureStatus]
    /// Still-pending features, in `TalkBootFeature` case order — the
    /// honest "what is left" list for the caption.
    let pendingFeatures: [TalkBootFeature]
}

/// The degraded settle: the hero is enabled, but these features are cold.
struct TalkBootDegradation: Equatable {
    let coldFeatures: [TalkBootFeature]
}

/// The pure boot-completion machine.
struct TalkBootContractState: Equatable {

    /// The coordinator's talk watchdog: a warm step (or the KWS build)
    /// still pending this long after the warm phase began fails the
    /// contract honestly instead of blocking the button forever. Long
    /// enough for the slowest real settle (serialized whisper + llama +
    /// TTS warms at their measured device speeds), short enough that a
    /// hung load degrades to today's behavior (first conversation pays
    /// the load) instead of a dead button.
    static let talkWatchdogSeconds: TimeInterval = 30.0

    static let preferenceOffReason = "preference_off"
    static let watchdogReason = "watchdog"
    static let nullEngineReason = "null_engine"
    static let postBootSlotReason = "post_boot_slot"

    private(set) var statuses: [TalkBootFeature: TalkBootFeatureStatus]
    /// Features whose boot-slice `.warm` step is running — their outcome
    /// (not a plan-time skip) settles them.
    private var awaitingWarmOutcome: Set<TalkBootFeature> = []

    init() {
        var initial: [TalkBootFeature: TalkBootFeatureStatus] = [:]
        for feature in TalkBootFeature.allCases {
            initial[feature] = .pending
        }
        statuses = initial
    }

    // MARK: - Queries

    /// Every feature settled (ready, skipped or failed).
    var isComplete: Bool {
        statuses.values.allSatisfy(\.isSettled)
    }

    /// Complete with no cold features — the button may enable clean.
    var isSatisfied: Bool {
        isComplete && statuses.values.allSatisfy { !$0.isFailure }
    }

    /// The failed features (ordered) — the degraded banner's payload.
    var coldFeatures: [TalkBootFeature] {
        TalkBootFeature.allCases.filter { statuses[$0]?.isFailure == true }
    }

    var pendingFeatures: [TalkBootFeature] {
        TalkBootFeature.allCases.filter { statuses[$0] == .pending }
    }

    var progress: TalkBootProgress {
        TalkBootProgress(statuses: statuses, pendingFeatures: pendingFeatures)
    }

    /// The warm-engine → contract-feature mapping. TTS voice steps are
    /// ALWAYS the primary (the planner defers/skips the secondary out of
    /// the boot slot; a hand-built plan's secondary voice would still map
    /// here — see `noteWarmPlanStep`'s post-boot defensive settle).
    static func feature(for engine: WarmStartEngine) -> TalkBootFeature? {
        switch engine {
        case .whisperKit, .whisperCpp: return .whisper
        case .ttsVoice: return .primaryTTS
        case .llamaInterpreter: return .llama
        }
    }

    // MARK: - Transitions

    /// Feeds one plan step (ANY phase — the coordinator feeds the full
    /// plan before it splits the slices). Plan-time settle: a skip is
    /// settled now (it never reaches the runner); a boot-phase warm stays
    /// pending until its outcome; a post-boot warm settles defensively
    /// (the planner never puts the PRIMARY in the post-boot slot today —
    /// the simulator defers TTS warms as skips — so this branch cannot
    /// gate the button on a post-boot load).
    mutating func noteWarmPlanStep(_ step: WarmStartStep) {
        guard let feature = Self.feature(for: step.engine) else { return }
        switch step.action {
        case .skip(let reason):
            // Skips never downgrade a settled state — a retry re-plan
            // re-asserts the same skip; a ready feature stays ready.
            guard statuses[feature] == .pending else { return }
            statuses[feature] = .skipped(reason: reason)
        case .warm:
            guard step.phase == .boot else {
                if statuses[feature] == .pending {
                    statuses[feature] = .skipped(reason: Self.postBootSlotReason)
                }
                return
            }
            // A boot-phase warm awaits a runner outcome. Inserted even
            // over a previous skip: a RETRY plan may upgrade a skipped
            // feature (model installed since launch) — the retry's warm
            // outcome then settles it honestly.
            awaitingWarmOutcome.insert(feature)
        }
    }

    /// The warm preference is OFF (empty plan): the warm features are
    /// not part of this launch's first conversation BY CHOICE — settled,
    /// not failed, and the button never waits on them. Idempotent: only
    /// features that are still pending AND have no boot warm running
    /// settle here.
    mutating func settleUnplannedWarmFeatures() {
        for feature in [TalkBootFeature.whisper, .primaryTTS, .llama] {
            guard statuses[feature] == .pending,
                  !awaitingWarmOutcome.contains(feature) else { continue }
            statuses[feature] = .skipped(reason: Self.preferenceOffReason)
        }
    }

    /// A boot-slice warm step's terminal outcome. Upgrades `.failed` and
    /// `.skipped(reason: "watchdog")` (the retry/late-settle recovery);
    /// no-ops on `.ready` and on plain skips.
    mutating func noteWarmOutcome(feature: TalkBootFeature,
                                  result: WarmStartEngineResult) {
        guard allowsOutcomeUpgrade(statuses[feature]) else { return }
        switch result {
        case .ready:
            statuses[feature] = .ready
        case .failed(let reason):
            statuses[feature] = .failed(reason: reason)
        }
    }

    /// The deferred KWS build settled. A real engine (the hot-swap
    /// landed) is `.ready`; the honest Null fallback is `.skipped` — the
    /// wake-word doctrine: manual Talk must come up even with a Null
    /// engine, and it is never a Talk degradation.
    mutating func noteKWSApplied(isReal: Bool) {
        guard statuses[.kws] != .ready else { return }
        statuses[.kws] = isReal ? .ready : .skipped(reason: Self.nullEngineReason)
    }

    /// The coordinator's talk watchdog fired: warm features still
    /// pending FAIL (cold — the first conversation pays their loads),
    /// while a pending KWS falls back to the Null behavior (skipped —
    /// wake word never degrades manual Talk).
    mutating func noteTalkWatchdogExpired() {
        for feature in TalkBootFeature.allCases {
            guard statuses[feature] == .pending else { continue }
            if feature == .kws {
                statuses[feature] = .skipped(reason: Self.watchdogReason)
            } else {
                statuses[feature] = .failed(reason: Self.watchdogReason)
            }
        }
    }

    private func allowsOutcomeUpgrade(_ status: TalkBootFeatureStatus?) -> Bool {
        guard let status else { return false }
        switch status {
        case .pending, .failed: return true
        case .skipped(let reason): return reason == Self.watchdogReason
        case .ready: return false
        }
    }
}

// MARK: - The published conjunction

/// Combines the pipeline-start machine with the boot contract into the
/// ONE readiness value the Talk hero gates on.
enum TalkBootContract {
    static func combine(pipeline: VoicePipelineReadiness,
                        contract: TalkBootContractState) -> VoicePipelineReadiness {
        // The pipeline's start callback is the foundation: until it
        // succeeds (or fails), the contract is irrelevant.
        guard case .ready = pipeline else { return pipeline }
        if contract.isComplete {
            return contract.isSatisfied
                ? .ready
                : .degraded(TalkBootDegradation(coldFeatures: contract.coldFeatures))
        }
        return .loading(.preparingEngines(contract.progress))
    }
}

// MARK: - The watchdog seam ([CONTRACT-FIX])

/// The talk contract's settlement backstop. The deadline is scheduled on
/// an INDEPENDENT scheduler — never the warm queue — so a warm hung on
/// its own serial queue (or any publisher that never emits) can never
/// delay settlement past the deadline. Idempotent: the deadline is
/// measured from the FIRST arm; later arms keep the original deadline
/// (progress notes and retry re-plans must not extend the wait).
final class TalkBootWatchdog {
    private let scheduler: DispatchQueue
    private var workItem: DispatchWorkItem?

    /// True while a fire is scheduled.
    var isArmed: Bool { workItem != nil }

    /// - Parameter scheduler: where the deadline runs. Defaults to main
    ///   (the coordinator's settle path is main-confined); tests inject
    ///   their own queue. Must NEVER be the warm queue — a hung warm
    ///   occupies it, which is exactly the state the watchdog must
    ///   survive.
    init(scheduler: DispatchQueue = .main) {
        self.scheduler = scheduler
    }

    /// Schedules `fire` after `interval` unless already armed. Returns
    /// true when this call armed the watchdog (first arm wins).
    @discardableResult
    func arm(after interval: TimeInterval, fire: @escaping () -> Void) -> Bool {
        guard workItem == nil else { return false }
        let work = DispatchWorkItem { [weak self] in
            self?.workItem = nil
            fire()
        }
        workItem = work
        scheduler.asyncAfter(deadline: .now() + interval, execute: work)
        return true
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
