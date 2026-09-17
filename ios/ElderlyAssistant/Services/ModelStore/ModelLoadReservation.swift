import Foundation

// MARK: - [MODEL-WARDEN] Step 1 — the reservation vocabulary
//
// Step 0 made the ledger honest (every resident registered, `phys_footprint`
// observable). It did not fix the hole the OOM kills actually came through:
// **an admitted load was not a reservation.** `prepareLoad` decided and
// returned; the caller then loaded asynchronously, and the ledger only
// counted the slot at `didLoad` — i.e. *after* the model was in memory.
// Between those two moments (seconds for an ANE specialization, tens of
// seconds for a 2.5 GB GGUF page-in) the ledger counted nothing for the
// incoming model, so two callers on different slots were both admitted
// against the same budget and both allocated.
//
// The types in this file are that missing interval, named:
//
//   ModelLoadRequest     what a load site asks for
//   ModelReservation     what it got — the bytes it may spend, until when
//   ReservationDenial    why not, in a closed vocabulary
//   ReservationAbandonReason  why a granted reservation was handed back
//   ModelWardenConfig    the bounds, all of them configurable
//
// [MODEL-WARDEN] Step 2 adds three more, and they are the ones that make a
// resident's claim on its bytes *negotiable* rather than absolute:
//
//   ModelPriority        where a request, and a resident, sit on the ladder
//   ModelResident        an owner that can be ASKED to stand down
//   UnloadAck            what it says — and `PreemptionOutcome`, what the
//                        warden did about it
//   ThrashGuardKind      which half of the loop-breaker refused a load
//
// The Step 1 kernel's one asymmetry is what makes Step 2 possible: a
// reservation is already a *permit*, and a permit that can be refused can
// also be *recalled*. Preemption is that recall, and it is deliberately the
// narrowest one that works — an ask, an ack, and a force fallback that the
// release contract can veto (`ModelReleaseContract.allowsForcedUnload`).
//
// The kernel is Option C's, not Option B's: **the warden owns permission and
// the queue; the handles stay with their owners.** No shared pool, no
// refcounts, no cross-tenant `LLM.stop()` — a reservation is a *permit to
// allocate*, and the object that allocates is still the subsystem that
// already owns the release path
// (`docs/superpowers/specs/2026-09-18-model-memory-manager-proposal.md` §4.3,
// §5.1).

/// One load site's request for permission to allocate.
///
/// The request carries no handle and no closure: a reservation is bytes and
/// a deadline, and the caller keeps ownership of everything else.
struct ModelLoadRequest {

    /// The pipeline position being loaded. For a *replacing* load this is
    /// the slot the model will occupy; for a peer load (see
    /// `replacesSlotContents`) it is the position the model belongs to
    /// even though another owner holds its own handle.
    let slot: ModelSlot

    /// The catalog artifact about to be loaded. Drives the footprint, so a
    /// size bump in the catalog moves the reservation arithmetic with it.
    let modelID: ModelID?

    /// Which caller this reservation belongs to, for the TTL reaper's
    /// `ownerGone` reason and for the ledger's own bookkeeping. Held
    /// **weakly** by the manager — a dead owner's reservation must be
    /// reapable, not kept alive by the thing that is supposed to notice it
    /// died.
    let owner: AnyObject?

    /// What the load is for. Closed vocabulary, content-free, and the one
    /// field the queue's fairness rules will read when Step 2 adds
    /// priority. It is recorded now so the field capture that decides
    /// tomorrow's priority ladder has today's distribution in it.
    let purpose: ReservationPurpose

    /// Whether this load REPLACES whatever the slot holds (the recognizers
    /// and the voice interpreter: one handle per pipeline position) or is a
    /// PEER of it (the translate tier's generator, which shares the
    /// `.brain` position with the voice interpreter but is a second,
    /// independently-owned handle).
    ///
    /// The distinction is only about the budget arithmetic. A replacing
    /// load excludes the slot's own residency — the load is the same
    /// position being refilled, and counting both would double-book one
    /// position and evict an innocent bystander. A peer load does NOT
    /// exclude it: the bytes really are additive, and excluding them is
    /// how a second 4B would slip past the budget the first one already
    /// spent.
    let replacesSlotContents: Bool

    init(slot: ModelSlot,
         modelID: ModelID?,
         owner: AnyObject? = nil,
         purpose: ReservationPurpose,
         replacesSlotContents: Bool = true) {
        self.slot = slot
        self.modelID = modelID
        self.owner = owner
        self.purpose = purpose
        self.replacesSlotContents = replacesSlotContents
    }

    /// [MODEL-WARDEN] Step 2 — the ladder position this request carries.
    /// Derived from the purpose rather than passed separately, so a load
    /// site cannot ask for the carve-out of one purpose while claiming
    /// another: the two fields are one field.
    var priority: ModelPriority { purpose.priority }
}

/// What a load is for. Step 1 records it; Step 2 (the priority ladder)
/// reads it. Nothing in Step 1 branches on it beyond the event metadata.
enum ReservationPurpose: String, Sendable {
    /// A live voice turn — the household is waiting on an answer.
    case voiceTurn
    /// The camera session's translation brain. Preemptible by design in
    /// Step 2; in Step 1 it is simply a purpose the queue can name.
    case liveTranslate
    /// A boot warm or a post-turn re-warm: nothing is waiting on it.
    case warm
    /// Anything else (a Settings probe, a maintenance path).
    case maintenance

    /// [MODEL-WARDEN] Step 2 — the ladder. See `ModelPriority`.
    var priority: ModelPriority {
        switch self {
        case .voiceTurn: return .safetyCritical
        case .liveTranslate: return .foreground
        case .warm, .maintenance: return .background
        }
    }
}

// MARK: - [MODEL-WARDEN] Step 2 — the priority ladder

/// How reluctant the warden is to take a resident's bytes back.
///
/// The ladder is the *ordering* the victim walk uses, not a veto: whatever
/// else is true, a background prefetch's bytes go before a foreground
/// feature's, and a foreground feature's before the thing a live voice turn
/// is waiting on. It is also the gate on preemption — an owner is only
/// *asked* to stand down by a request above it on the ladder, because a
/// boot warm asking the camera translation to give up its handle is the
/// warden spending a user-visible feature on a prefetch.
///
/// Ordering is by `rawValue`, so `Comparable` reads the way the ladder is
/// written. The cases are ordered lowest-first deliberately: a `sort` on
/// the raw value puts the first evictions where they belong without a
/// second mapping to keep in sync.
enum ModelPriority: Int, Comparable, CaseIterable, Sendable {
    /// A boot warm, a post-turn re-warm, a maintenance probe. Nobody is
    /// waiting on it and a refusal costs a later latency spike, not an
    /// answer.
    case background = 0
    /// A foreground feature's resident: the camera session's translation
    /// brain, the picker's brain, the recognizer's weights. Repaying these
    /// bytes costs a user-visible feature its handle.
    case foreground = 1
    /// A live voice turn. The household is waiting on an answer, and the
    /// budget arithmetic comes second — which is why the thrash guard's
    /// rate limit never refuses one (`ModelWardenConfig.maxLoadsPerMinute`).
    case safetyCritical = 2

    static func < (lhs: ModelPriority, rhs: ModelPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - [MODEL-WARDEN] Step 2 — the revocable lease

/// What an owner says when the warden asks for its bytes back.
///
/// The ask exists because the ledger's release closures are *unconditional*
/// — the warden calls one and the handle is gone — while the owners know
/// things the ledger does not: whether an inference is mid-flight on that
/// handle, whether the drop would free memory or merely mark it for a free
/// that cannot happen yet. The ack is the owner's sentence; the
/// `ModelReleaseContract` is the runtime's, and where the two disagree the
/// contract wins (`allowsForcedUnload`).
enum UnloadAck: Equatable {
    /// The handle is dropped on the way out of this call.
    case released
    /// The owner refuses. The reason is content-free and travels on the
    /// event; the warden decides whether to force (see
    /// `PreemptionOutcome.forced`) or to leave the bytes where they are.
    case refused(UnloadRefusal)
    /// There was nothing to give back — the owner had already dropped it.
    /// Distinct from `released` so a capture does not read a
    /// reclamation for a handle that was never resident.
    case notHolding
}

/// Why an owner said no. Closed vocabulary, one word each, no values.
enum UnloadRefusal: String, Equatable {
    /// An inference is running on the handle. Dropping the reference is
    /// safe for the runtime (the running call holds its own) but it is not
    /// *free*: the next use pays a full reload.
    case inUse
    /// The owner cannot reach a safe point to let go of it — a load or a
    /// hand-off is in progress and the handle is mid-assignment.
    case cannotReleaseNow
}

/// An owner that can be asked rather than only told.
///
/// Held by the manager as `AnyObject` and called **outside the lock**, so
/// the requirement is synchronous and must not re-enter the manager: the
/// manager's lock is non-recursive and a resident that called
/// `didUnload` from inside this method would deadlock. Dropping a
/// reference, or reading a flag the owner already keeps under its own
/// lock, is the whole of the expected body.
protocol ModelResident: AnyObject {
    /// Called on the caller's thread, outside the manager's lock.
    func releaseForWarden() -> UnloadAck
}

/// What actually happened to a preemption ask. The distinction between
/// `.refused` and `.forced` is the one the field capture needs: an owner
/// that refuses and is overruled is describing a contract that is doing
/// work, and one that refuses and is obeyed is describing a slot the
/// ledger cannot reclaim right now.
enum PreemptionOutcome: Equatable {
    /// The owner dropped the handle on the ask. Nothing else was called;
    /// the bytes are accounted for.
    case released
    /// Nothing to drop — the resident had already let go.
    case alreadyReleased
    /// The owner refused and the release contract does not permit forcing
    /// (whisper.cpp's `perAttemptContext`), so the bytes stayed where they
    /// were and the victim was skipped.
    case refused(reason: UnloadRefusal)
    /// The owner refused and the contract allows it, so the registered
    /// release path was invoked anyway. Legal exactly because
    /// `releaseContract.allowsForcedUnload` says the runtime survives it.
    case forced(reason: UnloadRefusal)

    /// Whether the warden got the bytes back.
    var reclaimed: Bool {
        switch self {
        case .released, .alreadyReleased, .forced: return true
        case .refused: return false
        }
    }

    /// The observability token for this outcome — closed vocabulary, one
    /// word, no values. `refused`/`forced` carry the refusal reason with
    /// them (`reason`), because "which refusal" is the whole diagnostic
    /// value of the pair.
    var token: String {
        switch self {
        case .released: return "released"
        case .alreadyReleased: return "already_released"
        case .refused: return "refused"
        case .forced: return "forced"
        }
    }

    /// The refusal that produced this outcome, if the owner said no.
    var refusalReason: UnloadRefusal? {
        switch self {
        case .released, .alreadyReleased: return nil
        case .refused(let reason), .forced(let reason): return reason
        }
    }
}

/// Which half of the thrash guard refused a load.
enum ThrashGuardKind: String, Equatable {
    /// One slot is being kept out of the victim order — quarantined,
    /// cooling down after a preemption, or inside a refusal grace (see
    /// `ModelLifecycleManager.guardSparedLocked`) — and the load that wanted
    /// its bytes is refused instead of the loop continuing.
    case victimSpared = "victim_spared"
    /// More large loads were admitted in the last minute than
    /// `maxLoadsPerMinute` allows. The blunt, global half of the guard.
    case loadRateExceeded = "load_rate_exceeded"
}

/// Why a load may not proceed, in a closed vocabulary.
///
/// Every case is a *refusal to answer*, never a failure that happened later:
/// the caller gets it synchronously, before any allocation, and is expected
/// to take its own existing degraded path (whisper.cpp, the cloud tier, the
/// dictionary). That is the "fail fast with an explicit, honest error"
/// contract — the alternative, silently parking the caller on a queue behind
/// a 2.5 GB page-in, is how a feature ends up with no error and no answer
/// (`docs/.../model-memory-manager-proposal.md` §4.3 failure table).
enum ReservationDenial: Error, Equatable {
    /// The incoming model's own live footprint exceeds the class budget, so
    /// no eviction could make room. This is the `soloOverBudget` case seen
    /// from the reservation's side: a load that is allowed to invoke the
    /// escape hatch is still admitted and announced; everything else is
    /// refused. The hatch is a *peer* load never (a second copy of something
    /// already over budget has no argument to make) and a replacing load
    /// only where `ModelSlot.admitsSoloOverBudget` — the two positions whose
    /// artifact is the user's own pick, and whose refusal would make the
    /// app's primary function unloadable.
    case overBudgetAlone(liveBytes: UInt64, budgetBytes: UInt64)
    /// The model would fit alone, but the bytes in its way are not
    /// evictable right now (pinned by an in-flight inference, or held by a
    /// slot that is not evictable at all). Admitting would cross the budget
    /// silently — refuse instead.
    case budgetExhausted(by: ModelSlot)
    /// The model's non-pageable bytes exceed the app's remaining headroom.
    /// The one case where the honest answer is "not on this device, not
    /// now": evicting more cannot help, because these are the bytes the
    /// kernel will not reclaim for us.
    case insufficientHeadroom(requiredBytes: UInt64, availableBytes: UInt64)
    /// The serial load queue is occupied. A load at or above
    /// `largeLoadThresholdBytes` is only allowed `maxConcurrentLargeLoads`
    /// at a time (one, by default), because the spike the watchdog kills
    /// for is two page-ins together — not the steady state after them.
    /// `holder` names the slot currently in flight, so the caller can say
    /// *what* it is waiting behind rather than only that it lost.
    case loadInFlight(holder: ModelSlot)
    /// This slot already has a live reservation from another load site.
    /// Two reservations on one pipeline position would both be admitted
    /// against a position that can only hold one model — the exact
    /// double-book the ledger exists to prevent.
    case alreadyReserved(slot: ModelSlot, holder: ReservationPurpose)
    /// [MODEL-WARDEN] Step 2 — the thrash guard. Admitting this load would
    /// keep an evict-then-reload loop running, so the warden refuses
    /// instead of feeding it. See `ThrashGuardKind` for which half of the
    /// guard spoke and `count` for the number it counted.
    ///
    /// The refusal is a *deferral*: the loop breaks because the load takes
    /// its degraded path and stops re-asking, and the window rolls off on
    /// its own. Nothing here is sticky.
    case thrashGuarded(slot: ModelSlot, kind: ThrashGuardKind, count: Int)

    /// The content-free token this denial travels as on the observability
    /// bus. `String(describing:)` would be the obvious spelling and is
    /// exactly the one that must not be used: it renders the associated
    /// values, and while they happen to be integers and slots today, a
    /// future case could carry a path. The token is a closed vocabulary the
    /// capture can be counted on, and the numeric detail rides on the
    /// dedicated metadata keys (`liveBytes`, `budgetBytes`, `slot`).
    var token: String {
        switch self {
        case .overBudgetAlone: return "over_budget_alone"
        case .budgetExhausted: return "budget_exhausted"
        case .insufficientHeadroom: return "insufficient_headroom"
        case .loadInFlight: return "load_in_flight"
        case .alreadyReserved: return "already_reserved"
        case .thrashGuarded: return "thrash_guarded"
        }
    }

    /// The guard firing behind this denial, if it is one. Lets the ledger
    /// emit the same fact in its own vocabulary without a second switch
    /// over the denial, which is where the two would drift apart.
    var thrashGuardFiring: (slot: ModelSlot,
                            kind: ThrashGuardKind,
                            count: Int)? {
        guard case .thrashGuarded(let slot, let kind, let count) = self else {
            return nil
        }
        return (slot, kind, count)
    }
}

/// Why a granted reservation was given back unspent.
enum ReservationAbandonReason: String, Equatable {
    /// The load itself threw. The bytes were never allocated.
    case loadFailed
    /// The caller stopped waiting (its own deadline, or a cancelled task
    /// above it). Distinct from `loadFailed` because the two mean opposite
    /// things about the model: one says the runtime refused, the other
    /// says nobody is waiting any more.
    case cancelled
    /// The caller replaced this attempt with a newer one (a re-issued
    /// batch, a re-primed turn).
    case superseded
    /// Nobody committed or abandoned it before `reservationTTLSeconds`
    /// lapsed. Reclaimed by the reaper, not by the owner.
    ///
    /// This is the *abandoned load* the proposal names as a new failure
    /// mode (§2.4): `LiveTranslationPipeline.waiting(for:upTo:)` races the
    /// brain stage against its deadline and deliberately does not cancel
    /// the loser, so a load can proceed with no caller, no lease and no
    /// ledger entry while the next cycle's reservation is evaluated against
    /// a probe that is still moving. The TTL is what reaps it.
    case ttlExpired
    /// A granted reservation that outlived `loadWatchdogSeconds`. Same
    /// reclamation as `ttlExpired` with a louder name: at this age the
    /// load is not merely late, it is a slot the warden should treat as
    /// suspect (mirrors `whisperCPPWedgedReserveBytes`).
    case watchdogExpired
    /// Memory pressure below the level a load may proceed under —
    /// `.critical` cancels everything pending.
    case memoryPressure
    /// The app went to the background with this load in flight.
    case backgrounded
}

/// The bounds. Every one of them is a default the owner may revise; none is
/// compiled into a decision.
///
/// The four blocking product decisions the proposal asked for are settled
/// here as **configurable defaults** rather than as constants in a branch —
/// which is what makes them revisable after the first field capture without
/// a behavioural rewrite. The two that live in this struct are the load
/// bounds; the class → brain mapping and the working-set figures live on
/// `ModelLifecycleBudget` and `ModelBudgetPolicy` (Step 3).
struct ModelWardenConfig: Equatable {

    /// Loads at or above `largeLoadThresholdBytes` that may be in flight at
    /// once. One, and the reason is §2.1: the observed device kill was a
    /// CPU resource watchdog at a 1.2–1.4 GB footprint, and two concurrent
    /// page-ins of a 2.5 GB GGUF are the spike that gets there. Serialising
    /// them costs a little latency on a path that already has a deadline;
    /// not serialising them costs the app.
    var maxConcurrentLargeLoads: Int = 1

    /// The line between "a load" and "a spike". 256 MB: above it are the
    /// whisper weights, the llama brains, the ANE graph; below it are the
    /// Piper voices, the encoder and the VAD, which are cheap enough that
    /// serialising them would buy nothing and cost a queue hop.
    var largeLoadThresholdBytes: UInt64 = 256_000_000

    /// Bounds the light-load burst too, so "small" cannot mean "unlimited".
    /// Two is what the app can actually do at once (the boot warm's voices
    /// and a re-arm); a third is a caller that has lost its own
    /// serialization.
    var maxConcurrentSmallLoads: Int = 2

    /// An uncommitted reservation is reclaimed after this long. Thirty
    /// seconds is longer than any load the app performs (the ANE cold load
    /// is ~77 s but is *committed* at its end, not at its start — the
    /// reservation is held across it, so this is the bound on a load that
    /// neither committed nor abandoned) and far shorter than the idle
    /// sweep, so an abandoned load is reaped long before it can be mistaken
    /// for residency.
    var reservationTTLSeconds: TimeInterval = 30

    /// A granted reservation older than this is reclaimed *and* its slot
    /// reported as suspect. The two bounds are deliberately different: the
    /// TTL is housekeeping, the watchdog is evidence.
    var loadWatchdogSeconds: TimeInterval = 120

    // MARK: [MODEL-WARDEN] Step 2 — the preemption and thrash-guard bounds

    /// How long a refusal that cannot be forced buys the refused slot.
    ///
    /// The ack is synchronous by construction (`ModelResident`), so there
    /// is nothing to wait for — what the deadline bounds is how long the
    /// warden *believes* the refusal before asking again. Without it, a
    /// load that cannot evict a busy whisper.cpp context would re-ask on
    /// every cycle of the pipeline and emit a refusal per attempt, which is
    /// a log storm around a slot that is simply in use. Two seconds is
    /// shorter than any batch the app runs and longer than a pipeline tick,
    /// so the grace is over before the next real attempt.
    ///
    /// It is also the deadline a future *asynchronous* ack would have to
    /// answer within; Step 2's is synchronous, and moving to async is a
    /// Step 3 concern (see the seam note on `ModelLifecycleManager`).
    var unloadAckDeadlineSeconds: TimeInterval = 2

    /// After a slot is preempted, it is kept out of the load-driven victim
    /// order for this long. Short and targeted: the loop this breaks is
    /// "give the bytes back, then take them again two seconds later", and
    /// twenty seconds is longer than a pipeline tick and shorter than the
    /// idle window, so a slot that is genuinely unused still gets evicted
    /// by the idle sweep inside the cooldown.
    var preemptionCooldownSeconds: TimeInterval = 20

    /// How many load-driven evictions of ONE slot inside
    /// `preemptionQuarantineSeconds` quarantine it.
    ///
    /// From the victim's side, being taken to make room for someone else is
    /// one event whatever the reason recorded on it, so this counts every
    /// load-driven eviction (`.budget` and `.preemption`) and never the
    /// memory-pressure or idle sweeps — those are the OS asking and the slot
    /// being unused, and dampening either of them would be the guard
    /// fighting the wrong thing.
    var preemptionsBeforeQuarantine: Int = 3

    /// The thrash window, and the quarantine it latches. A slot evicted
    /// `preemptionsBeforeQuarantine` times inside this window is spared from
    /// the load-driven victim order for the same length. Two minutes is
    /// deliberately longer than the cooldown: the cooldown is "let it
    /// settle", the quarantine is "one of these two features has to take
    /// its degraded path".
    var preemptionQuarantineSeconds: TimeInterval = 120

    /// Large loads admitted per rolling minute before the guard refuses the
    /// next one. The blunt half: the per-slot quarantine catches a loop
    /// between two specific features, this catches N features churning at
    /// once. Four is the proposal's number.
    ///
    /// It never refuses a live voice turn (the household is waiting), and
    /// it never refuses a `.maintenance` load — that purpose is the
    /// synchronous `prepareLoad` fast path, not a feature loop.
    var maxLoadsPerMinute: Int = 4

    /// Master switch. Off restores Step 1's behaviour exactly: no cooldown,
    /// no quarantine, no rate limit. Kept because a guard that can only be
    /// disabled by a rebuild is a guard nobody can field-test against.
    var thrashGuardEnabled: Bool = true

    static let `default` = ModelWardenConfig()
}

/// A granted permit to allocate.
///
/// It is a value: the id is what `commit` and `abandon` match on, and the
/// byte figures are the ones the admission decision was made with — so a
/// caller that logs them logs the decision, not a re-derivation that could
/// disagree with it.
struct ModelReservation: Equatable, Identifiable {
    let id: UUID
    let slot: ModelSlot
    let modelID: ModelID?
    let purpose: ReservationPurpose
    /// `liveBytes` of the incoming model: the worst-case resident cost, and
    /// the quantity added to the ledger's transient term `T`.
    let liveBytes: UInt64
    /// The non-pageable part, and the quantity the post-eviction headroom
    /// check compares against the probe. Kept on the reservation so
    /// `commit` and the diagnostics do not have to re-resolve the catalog
    /// and risk disagreeing with the decision.
    let hardBytes: UInt64
    /// Whether this reservation occupies one of the serial large-load
    /// slots. Resolved at grant time from `largeLoadThresholdBytes`.
    let isLargeLoad: Bool
    let reservedAt: Date
    let expiresAt: Date

    /// What granting the reservation cost — the residents that had to leave
    /// first. Carried on the reservation (rather than recomputed by the
    /// caller) so the load site can report the same list the decision was
    /// made with.
    let evicted: [ModelSlot]

    /// The grant was made despite the incoming model exceeding the class
    /// budget on its own, because refusing would make the app's own default
    /// model unloadable. See `ReservationDenial.overBudgetAlone` — the two
    /// are the same condition seen from the two sides of the decision, and
    /// only a *replacing* load on a slot that `admitsSoloOverBudget` may
    /// invoke it.
    let soloOverBudget: Bool

    /// The budget the decision was made against, for the event and for the
    /// caller's degraded path reasoning.
    let budgetBytes: UInt64

    /// [MODEL-WARDEN] Step 2 — where this request sat on the ladder. Copied
    /// from the request at grant time so the decision, the event and the
    /// caller all report the same position rather than re-deriving it from
    /// the purpose.
    let priority: ModelPriority

    /// [MODEL-WARDEN] Step 2 — the victims the warden had to ask for, and
    /// what they said. Empty when nothing was preempted (the ordinary
    /// case), and carried on the reservation so the load site reports the
    /// same conversation the decision was made with.
    let preempted: [PreemptionRecord]

    /// Age at a given instant, for the reaper and for the events.
    func heldSeconds(at now: Date) -> TimeInterval {
        now.timeIntervalSince(reservedAt)
    }
}

/// [MODEL-WARDEN] Step 2 — one ask, and its answer.
///
/// `slot` names the resident that was asked; `outcome` is what it said and
/// what the warden did about it. The pair is the evidence that the
/// revocation protocol is real: a capture that never sees a `.refused`
/// either has no slot that can refuse, or has a warden that never asks.
struct PreemptionRecord: Equatable {
    let slot: ModelSlot
    let outcome: PreemptionOutcome
}
