import Foundation

// MARK: - Background engine readiness contract ([LAT-M1], 2026-09-11)
//
// This state machine measures whether startup warm work and KWS setup have
// settled. It is background-engine telemetry only: manual Talk readiness is
// published independently and never waits for this contract.
//
// The tracked settlement signals are:
//
//    whisper warm settled (ready, skipped, or failed)
//    ∧ primary reply-voice warm settled
//    ∧ llama interpreter warm settled
//    ∧ KWS hot-swap settled
//
// Budget semantics:
//
//  - `WarmStartPlanner.bootWarmBudgetSeconds` bounds the startup
//    `.warmingEngines` stage. Slow warm work may finish detached.
//  - Budget expiry does not mutate this state; only actual outcomes and the
//    watchdog settle features.
//  - A warm step that fails (or outlives the watchdog) is recorded as cold so
//    diagnostics can report which engine was unavailable at settlement.
//  - A warm step that never settles cannot leave the telemetry pending
//    forever: `noteTalkWatchdogExpired` settles all remaining features.
//
// [CONTRACT-FIX] Never-stuck telemetry guarantee:
//
//  - The watchdog's deadline runs on an independent scheduler, never the warm
//    queue, so a warm hung on its serial queue cannot delay settlement
//    (`TalkBootWatchdog`; the coordinator arms it on main). First arm wins:
//    progress notes and retry re-plans never extend the deadline.
//  - The watchdog fire re-reads current state and only settles features still
//    `.pending`, preserving an outcome that landed just before the deadline.
//  - Warm outcomes also have a runner-level per-step timeout
//    (`WarmStartRunner`, seam_timeout), and the KWS path settles on every exit
//    of the deferred build, including "no pipeline to swap into".
//
// Settlement rules:
//
//  - `.skip` actions (simulator, gemini_stack, model_missing,
//    preference_off) are settled with the planner's reason.
//  - Settled states are sticky except honest upgrades: a retry warm outcome
//    upgrades `.failed` to `.ready`, and a late real settle upgrades
//    `.skipped(reason: "watchdog")`. Nothing else moves a settled feature.
//  - KWS absence is not a cold engine classification: a Null-engine settle is
//    `.skipped(reason: "null_engine")`, and a KWS build still pending at the
//    watchdog is `.skipped(reason: "watchdog")`.

/// Background engine features whose startup settlement is measured.
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

/// A per-feature snapshot for readiness telemetry while settlement is open.
struct TalkBootProgress: Equatable {
    let statuses: [TalkBootFeature: TalkBootFeatureStatus]
    /// Still-pending features, in `TalkBootFeature` case order — the
    /// honest "what is left" list for the caption.
    let pendingFeatures: [TalkBootFeature]
}

/// The cold-engine classification after settlement.
struct TalkBootDegradation: Equatable {
    let coldFeatures: [TalkBootFeature]
}

/// The pure background-engine settlement machine.
struct TalkBootContractState: Equatable {

    /// The settlement watchdog interval. Long enough for serialized whisper,
    /// llama, and TTS warms at measured device speeds; short enough to ensure
    /// telemetry cannot remain pending indefinitely after a hung load.
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

    /// Complete with no failed warm features.
    var isSatisfied: Bool {
        isComplete && statuses.values.allSatisfy { !$0.isFailure }
    }

    /// Failed warm features in stable display order.
    var coldFeatures: [TalkBootFeature] {
        TalkBootFeature.allCases.filter { statuses[$0]?.isFailure == true }
    }

    var pendingFeatures: [TalkBootFeature] {
        TalkBootFeature.allCases.filter { statuses[$0] == .pending }
    }

    var progress: TalkBootProgress {
        TalkBootProgress(statuses: statuses, pendingFeatures: pendingFeatures)
    }

    /// The warm-engine to tracked-feature mapping. TTS voice steps map to the
    /// primary feature; `noteWarmPlanStep` defensively settles post-boot work.
    static func feature(for engine: WarmStartEngine) -> TalkBootFeature? {
        switch engine {
        case .whisperKit, .whisperCpp: return .whisper
        case .ttsVoice: return .primaryTTS
        case .llamaInterpreter: return .llama
        }
    }

    // MARK: - Transitions

    /// Feeds one plan step. A skip settles immediately, a boot-phase warm stays
    /// pending until its outcome, and a post-boot warm settles defensively.
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

    /// Settles warm features omitted by an empty preference-disabled plan.
    /// Idempotent: only pending features with no boot warm running are changed.
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

    /// Records deferred KWS settlement. A real hot-swap is `.ready`; the Null
    /// fallback is a non-failure `.skipped` classification.
    mutating func noteKWSApplied(isReal: Bool) {
        guard statuses[.kws] != .ready else { return }
        statuses[.kws] = isReal ? .ready : .skipped(reason: Self.nullEngineReason)
    }

    /// Settles remaining telemetry at the watchdog deadline. Pending warm
    /// features fail as cold; pending KWS falls back to a non-failure skip.
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


// MARK: - The watchdog seam ([CONTRACT-FIX])

/// The background readiness contract's settlement backstop. Its deadline is
/// scheduled on an independent scheduler, never the warm queue, so a hung warm
/// or silent publisher cannot delay telemetry settlement. First arm wins;
/// later arms retain the original deadline.
final class TalkBootWatchdog {
    private let scheduler: DispatchQueue
    private var workItem: DispatchWorkItem?

    /// True while a fire is scheduled.
    var isArmed: Bool { workItem != nil }

    /// - Parameter scheduler: where the deadline runs. Defaults to main;
    ///   tests inject their own queue. It must not be the warm queue whose
    ///   blockage this watchdog is designed to survive.
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
