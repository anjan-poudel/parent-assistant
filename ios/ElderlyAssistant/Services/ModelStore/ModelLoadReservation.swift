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
    /// from the reservation's side: a replacing load is still admitted (the
    /// user's explicit pick must not become unloadable) and announced; a
    /// *peer* load is refused, because a second copy of something already
    /// over budget has no escape hatch to invoke.
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
        }
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
    /// only a *replacing* load is allowed to invoke it.
    let soloOverBudget: Bool

    /// The budget the decision was made against, for the event and for the
    /// caller's degraded-path reasoning.
    let budgetBytes: UInt64

    /// Age at a given instant, for the reaper and for the events.
    func heldSeconds(at now: Date) -> TimeInterval {
        now.timeIntervalSince(reservedAt)
    }
}
