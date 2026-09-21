import CoreGraphics
import Foundation

// T-026 — C13, the join point (FR-LCT-018, FR-LCT-022, FR-LCT-023,
// NFR-LCT-010, NFR-LCT-011; AM-6 applied to publication ordering, AM-8, CL-1).
//
// Every other component of this feature is built and tested. This file is
// where they meet, and it is deliberately the only file that knows their
// order:
//
//   1. **The pipeline sequences; it does not re-implement.** Classification is
//      T-019's, placement is T-020's, consent is T-014/T-015's, sanitisation
//      is T-017's, stabilisation is T-009/T-010's, the copy is T-005's. A
//      second copy of any of those rules in this file would be a defect, so
//      there is none: the actor calls into them and carries their answers.
//
//      The one order it does own is the cascade (FR-LCT-008 as amended
//      2026-09-17): the curated dictionary and the persisted cache first, the
//      on-device brain second, the consent-gated cloud last — and only for
//      what the layer before it did not answer. The brain is asked inside the
//      same session-scoped task as the cloud attempt, so the cadence never
//      waits on a generation.
//
//   2. **One cycle, one coherent publication.** A cycle's regions, outcomes,
//      placements and the policy they were measured under are published as a
//      single value, so a consumer can never observe a new region with an old
//      outcome, or a new translation drawn on a stale rect. This is a
//      property of the shape (`LiveTranslatePublication`), not a convention
//      about call order.
//
//      A cycle whose state differs from the last published one by nothing but
//      sub-epsilon box movement publishes **nothing at all** (`publishBoxEpsilon`):
//      recognition jitter is not news, and republishing it re-renders the
//      overlay for a wobble the elder cannot see. The gate is on *rendering*
//      only — the translation gate is keyed by text and has already run.
//
//   3. **Per-cycle work is bounded, and nothing queues behind anything.**
//      `ingest(_:)` is the frame tick. While the OCR pass runs, the actor
//      holds the frame source's own backpressure flag (T-006), so the tap
//      drops samples instead of queueing them — memory stays flat and a slow
//      Vision pass cannot build a backlog. Resolution — the brain's
//      generation, then the cloud request — is *not* under that flag: it is a
//      session-scoped task, so the OCR cadence continues while a request or a
//      generation is in flight, and the next tick is the retry.
//
//      That task is also what keeps a *slow* stage from becoming a lost
//      region. Both tiers bound themselves, but a bound a component enforces
//      on itself only reaches the elder if the call returns, and a stage that
//      claimed strings and never came back would strand them: every later tick
//      sees the claim and skips them, so the region sits pending while the
//      tier behind it is never asked. The brain stage therefore runs under the
//      pipeline's own deadline (`brainTranslationStageDeadlineSeconds`) and
//      hands its strings to the gate when that deadline wins.
//
//   4. **The cadence follows the scene, not the clock (resource rework,
//      2026-09-17).** The frame source reduces every delivered frame to a
//      luminance signature and runs recognition on it only when the picture
//      materially changed, and this actor is the second half of that rule: it
//      is the only component that knows whether a pass produced anything, so
//      it is the one that reports a scene stale (no new region, no box moving)
//      and lets the tap fall back to `stableSampleInterval`. Both halves are
//      needed. The frame source alone cannot see that a *moving* scene
//      contains no new text; this actor alone cannot see the frames the gate
//      never delivered. Neither of them stops work: a scene that holds still
//      is still recognized, just less often, because the stabiliser needs
//      consecutive sightings to publish a region at all.
//
//   5. **Ordering is a monotone counter, never a clock (AM-6).** Each
//      publication carries `sequence`, incremented in memory under actor
//      isolation. Two same-millisecond cycles cannot invert, and no consumer
//      anywhere needs to look at a time. The counter starts at 1, so 0 means
//      "nothing has been published".
//
//   6. **One terminal outcome per region per cycle (AM-8, CL-1).** An outcome
//      is terminal while the region's text is unchanged: a resolved region
//      never returns to pending, and a settled string is not re-sent on every
//      tick. The answer is held **per string**, so a region the stabiliser
//      rebirthed for a string the session has already answered inherits that
//      answer in the same cycle it is published — a camera movement cannot
//      flash "translating…" over a translation that is already on screen, and
//      it cannot leave a region pending with nothing left to dispatch it.
//      The one re-attempt the design asks for is a *resume*, which restarts
//      the stabiliser from empty and clears the settled set.
//
//   7. **A component failure degrades one region, not the session.** Every
//      path in this file ends in a rendered state: resolved, degraded with the
//      original text, or the empty-state hint. There is no `return` that
//      leaves a region unaccounted for, and no failure of the detector, the
//      cache or the cloud layer can stop the next cycle from publishing.
//
//   8. **Closing is structural cancellation.** One session-scoped task tree;
//      `close()` cancels it, releases recognition and drops every outcome.
//      Each merge re-checks `isClosed` after its `await`, so a cancellation
//      that lands mid-request can never publish, and `publish()` itself
//      refuses after close.

// MARK: - Seams the pipeline drives

/// The frame source's own backpressure flag (T-006). The pipeline owns the
/// pass, so the pipeline sets it: while it is `true` the frame tap drops
/// samples rather than queueing them, which is what keeps per-cycle work flat
/// under a dense scene (NFR-LCT-011).
protocol LiveTranslateBackpressure: AnyObject {
    var ocrPassInFlight: Bool { get set }

    /// The pipeline's stale-scene signal: recent passes contained no new or
    /// changed region, so the tap may run at the reduced cadence.
    ///
    /// It is a second flag rather than a reuse of the first because the two
    /// mean different things and have different lifetimes: `ocrPassInFlight`
    /// is per-pass and is cleared the moment Vision returns, while this one
    /// describes the *scene* and stays set until a pass finds something new.
    /// A consumer that does not care about cadence (a test spy) gets a no-op
    /// default, so the flag cannot break a conformance that never asked for it.
    var ocrSceneStale: Bool { get set }
}

extension LiveTranslateBackpressure {
    /// Default: the cadence is none of this conformer's business.
    var ocrSceneStale: Bool {
        get { false }
        set { _ = newValue }
    }
}

extension LiveCameraSession: LiveTranslateBackpressure {}

/// C02's detection, narrowed to the one frame tick. The concrete detector
/// conforms as it is; tests script passes through a double, so no pixel buffer
/// is needed to exercise the pipeline.
protocol LiveTranslateFrameRecognising: AnyObject {
    func begin() -> Result<Void, LiveTranslateError>
    func end()
    func recognize(_ frame: CameraFrame) async -> Result<LiveTextDetector.Pass, LiveTranslateError>
}

extension LiveTextDetector: LiveTranslateFrameRecognising {}

/// C09's prompt lifecycle, narrowed to the one question the cloud path asks.
///
/// The pipeline asks *before* the tier and only when the on-device layers
/// could not answer, which is what makes the prompt appear at the point of
/// first cloud need (FR-LCT-011) rather than at session open — and what keeps
/// a curated scene from ever presenting it (FR-LCT-020).
///
/// The `Grant` the answer may carry is deliberately not consumed here: the
/// tier mints its own proof by re-reading the gate immediately before each
/// attempt (AM-1). The pipeline only needs the yes/no.
@MainActor
protocol LiveTranslateCloudNeedDeciding: AnyObject {
    func cloudNeedDetected() -> ConsentPromptController.Outcome
}

extension ConsentPromptController: LiveTranslateCloudNeedDeciding {}

/// What one gate-then-tier attempt produced, before a cycle decided what it
/// means for its own regions.
///
/// It exists as a value because **two** callers share this sequence (T-026's
/// live cycle and T-033's snapshot path), and the ordering is a rule: the gate
/// decides before the tier is consulted, an unanswered prompt sends nothing
/// and degrades nothing, and a refusal is the honest reason rather than a
/// generic failure. A second copy of that ordering is what this type removes.
enum LiveTranslateCloudAttempt: Equatable {
    /// The elder has not answered the prompt. Nothing was sent; the question
    /// is open, not failed.
    case awaitingDecision
    /// No send at all: the honest reason the tier is unavailable (switched off
    /// at the household's master switch, declined, revoked, unreadable,
    /// unrecorded-and-unaskable).
    case unavailable(LiveTranslateError)
    /// The tier answered every item it was handed.
    case answered(CloudTranslationTier.BatchResult)
}

/// Which mode a plan is running — the one thing a *mode* changes about the
/// shared plan, stated once so a second path cannot carry a second copy of it.
///
/// The plan (`runResolution`) is deliberately mode-blind about everything else:
/// the claim ledger, the terminal writer, the one-event-per-degradation rule
/// and the gate-then-tier ordering are the same whatever the elder was doing
/// when they asked. Two things genuinely differ, and both are here:
///
///  - **who leads.** The cascade routes each string by its own class (the short
///    forms the device is proven on keep the device in front; the sentence
///    class leads with the cloud when the cloud can lead). A focused read is a
///    different question — the elder pointed at one thing and asked about
///    *that* — and a network round-trip under their finger is the wrong
///    latency for a targeted ask, so the device leads every string.
///  - **how much may be spent.** A live tick is one frame of a cadence and a
///    scene is bounded by what is on screen; a focused read's crop is
///    whatever the recogniser found in the box the elder drew, which is not
///    bounded by anything this side of the budget. `focusMaxBatchCalls` caps
///    the tier batches one capture may spend.
///
/// `.cascade` is the default on every entry point, so the live cycle, the held
/// frame, the prompt's retry and the snapshot path are byte-for-byte the plans
/// they were before this type existed.
enum TranslationMode: String, Sendable, Equatable, CaseIterable {
    /// The shipped routing: per-string, by class.
    case cascade
    /// One pointed-at region: the device leads, and the plan's batches are
    /// capped by `LiveTranslateConfig.focusMaxBatchCalls`.
    case focused

    /// What this mode may do to the **persisted** store — the one property
    /// every tier call reads, so a mode cannot be routed as a focus and still
    /// put the crop on disk (review finding 3).
    ///
    /// A focused read answers a question about a picture the elder pointed at
    /// — a letter, a prescription, a form — and the session's store outlives
    /// the tap by a day. So a focus reads the store and writes nothing — the
    /// tier's adoption write **and** the lookups' bookkeeping writes, which
    /// `LabelTranslationCache` suppresses on this policy's word (review round
    /// 2, finding 8); every other mode persists, exactly as it always has.
    /// Declared here rather than spelled at each call site because the gate and
    /// the brain are two halves of **one** promise: the brain path that stored
    /// a focus's strings while the cloud path refused to was the same capture
    /// persisted by a different tier.
    var cachePolicy: CloudTranslationTier.CachePolicy {
        switch self {
        case .cascade: .persist
        case .focused: .readOnly
        }
    }
}

/// The live cycle, as the snapshot path (T-033) may use it: the two things
/// that must be *shared* rather than re-created — the gate-then-tier sequence
/// and the session's ordering counter (AM-6).
///
/// Deliberately narrow. Everything else the snapshot needs it takes from the
/// components it was handed, and none of this touches the live cycle's own
/// state: no stabiliser, no outcomes, no settled set, no in-flight registry
/// and no live publication.
protocol LiveTranslateLiveCycle: AnyObject {
    /// The plan, for a caller that owns its own regions: the device leads for
    /// its class, the gate leads for the class the device is not proven on,
    /// and whatever the cloud cannot answer comes back to the device rather
    /// than degrading.
    ///
    /// One terminal result per string the plan could answer, keyed by item id.
    /// `nil` means nothing may be applied at all: the elder has not answered
    /// the consent prompt (their question is open, and no tier has failed), or
    /// the session is gone.
    ///
    /// The rules are the live cycle's own — the same router, the same device
    /// tier, the same gate-then-tier sequence — so a frozen frame cannot
    /// translate by a different policy than the live picture behind it.
    /// `regionCounts` is how many regions the caller's own picture shows each
    /// string, keyed by item id: the live stabiliser cannot see a held frame's
    /// regions, so a degradation on this path is counted from here instead
    /// (review: a frozen string degraded as one region whatever the frame
    /// held). A caller with no picture of its own passes nothing and the live
    /// count is used.
    func resolveFrozen(_ items: [CloudTranslationTier.Item],
                       regionCounts: [String: Int]) async -> [String: TranslationResult]?
    /// The session's next ordering value, so a publication this actor did not
    /// build still advances the one monotone counter the session has.
    func nextPublicationSequence() async -> Int
}

// MARK: - Inputs the pipeline cannot derive

/// The session view's geometry (T-027). The pipeline knows everything else it
/// needs — the frame's own size comes with the frame — but the container, the
/// safe area and the chrome the overlay must not draw under are facts only the
/// view has, so they are pushed in and re-placed when they change.
struct LiveTranslateLayout: Equatable {
    var containerSize: CGSize
    var safeArea: CGRect
    /// Rects a callout must avoid. The session view composes this from the
    /// overlay's own reserved strip (T-021's `chromeRects`) and its own
    /// controls (consent, indicator, toggle, close), so a callout never lands
    /// under a control the elder needs.
    var occupiedRects: [CGRect]

    /// The window of the frame the elder is looking through: the zoom's and the
    /// pan's virtual crop (owner follow-up, 2026-09-18). It is the layout's
    /// business rather than the publication's because it is a fact about the
    /// *container* — what part of the picture is on screen — exactly like the
    /// container size, and it changes when the elder's fingers move rather than
    /// when a pass produces text. `LiveOverlayPlacement.place` maps every
    /// region's box through it, so the callouts land on the pixels the preview
    /// layer is drawing (the two go through `LiveCameraPresentation`).
    ///
    /// `.whole` for a session that has neither zoomed nor panned, which is the
    /// layout every caller before the window existed pushed in.
    var crop: LiveCameraCrop = .whole

    static let unknown = LiveTranslateLayout(containerSize: .zero,
                                             safeArea: .zero,
                                             occupiedRects: [])
}

// MARK: - The published value

/// One cycle's complete state, as a single value.
struct LiveTranslatePublication: Equatable {

    /// AM-6. Monotone within a session, in memory, never wall-clock derived:
    /// two same-millisecond cycles cannot invert and a clock change cannot
    /// reorder. The first publication is 1.
    let sequence: Int

    /// The stabilised regions, in the stabiliser's own order.
    let regions: [TextRegionStabilizer.StableTextRegion]

    /// Every visible region's outcome. Rebuilt each cycle from the visible set
    /// only, so no outcome outlives the region it belongs to.
    let outcomes: [TextRegionStabilizer.RegionIdentity: TranslationResult]

    /// The placements measured from these regions and these outcomes under
    /// `policy` — the overlay draws exactly these rects (T-020/T-021).
    let placements: [LiveOverlayPlacement.PlacedOverlay]

    /// The policy the placements were measured under, carried with them so a
    /// consumer never re-derives it from a preference that has since changed.
    let policy: LiveOverlayPlacement.Policy

    /// Nothing is visible: the overlay's empty state, which is a rendered
    /// state and not a blank screen.
    var hasVisibleText: Bool { !regions.isEmpty }

    /// A region's outcome. A missing entry is pending, which is the honest
    /// answer for a region the cycle has not resolved yet — never a blank
    /// bubble, because pending renders T-005's pending copy (T-021).
    func result(for region: TextRegionStabilizer.StableTextRegion) -> TranslationResult {
        outcomes[region.id] ?? .pending(region.text)
    }
}

// MARK: - The content-free scene digest

/// The digest a `text_change` carries beside its region count (owner device
/// verdict, 2026-09-18). **It is a discriminator, not content.**
///
/// The owner had two stories arriving as one line of console: four
/// `ocr_pass success regionCount=4` and four `text_change regionCount=4` every
/// pass, with `region_removed`/`region_appeared` pairs in between. The count
/// cannot separate *the reading really changed* from *the identity churned*, so
/// the next capture needed one more number — and the number had to be one that
/// says the same thing about a scene without carrying the scene.
///
/// What it is, exactly:
///
///  - **a digest of the set**, not of the order: the visible regions'
///    normalized strings, sorted, each length-prefixed, folded by FNV-1a
///    (32-bit). Two passes over the same text produce the same digest whatever
///    order the stabiliser drew them in, and a box that moved is not a change;
///  - **salted**, with a per-pipeline random value that is never logged, never
///    stored and never sent anywhere. Without it the digest of a *small* set —
///    a shop sign has a handful of readings — is a dictionary attack away from
///    confirming a guess at what the camera saw, which is precisely the content
///    this feature refuses to log. With it the value is only ever comparable
///    inside one session's own log, which is the comparison the owner makes;
///  - **32 bits, rendered nine characters** (`xxxx:xxxx`, see
///    `LiveTranslateEvents.regionSetHashHex`): long enough that a false match
///    between two different scenes is a one-in-four-billion event, short enough
///    that it cannot be mistaken for a hash anyone could key a store on.
///
/// What it is not: it is not derived from the device, the session or the user;
/// it is not stable across sessions or across launches (the salt sees to that);
/// it is not reversible to a string, or to the *number* of strings, or to any
/// one of them; and it is not a commitment about the content — a reader who
/// already knows what the scene said cannot use the digest to prove it, and a
/// reader who does not cannot recover it.
///
/// FNV-1a rather than `Hasher`: Swift's own `hashValue` is seeded per process,
/// so it is *stable within a run* but its value differs between runs of the same
/// input — the opposite of what a log line the owner will compare next week
/// needs. FNV-1a is written out here (both constants are its published ones) so
/// "the same scene logs the same digest" is a property of this file.
enum LiveTranslateRegionSetDigest {

    /// The digest of a visible text set, under `salt`.
    static func digest(of texts: [String], salt: UInt) -> UInt32 {
        var hash: UInt32 = 2166136261
        func fold(_ byte: UInt8) {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        // The salt first, so two sessions cannot be compared by digest alone.
        withUnsafeBytes(of: salt.littleEndian) { bytes in
            for byte in bytes { fold(byte) }
        }
        // Sorted, so the digest describes the *set*: the stabiliser's order is
        // its own bookkeeping and must not show up as a change. Length-prefixed
        // so no two different sets can fold to one digest by a boundary shift
        // ("ab" + "c" is not "a" + "bc").
        for text in texts.sorted() {
            var length = UInt32(text.utf8.count).littleEndian
            withUnsafeBytes(of: &length) { bytes in
                for byte in bytes { fold(byte) }
            }
            for byte in text.utf8 { fold(byte) }
        }
        return hash
    }
}

// MARK: - The pipeline

/// C13's orchestration: the frame tick, the layers in order, the gate, the
/// placement, and the publication the model renders.
///
/// The stabiliser is a value type held exclusively by this actor (value
/// semantics plus actor isolation is the whole concurrency story: no lock and
/// no shared mutable reference to reason about). Everything else is a
/// reference to a component that already owns its own rules.
actor LiveTranslationPipeline {

    /// Where a publication goes. The session model is the one production
    /// consumer; tests record into a double. The reference is weak on the
    /// *caller's* side, so a session that has gone away cannot be kept alive
    /// by its own pipeline.
    typealias PublicationSink = @Sendable (LiveTranslatePublication) async -> Void

    // MARK: Dependencies

    private let config: LiveTranslateConfig
    private let locale: Locale
    /// The translation target. The pilot's own default, resolved once (T-005's
    /// catalogue and C05's per-language keys are both keyed by it).
    private let targetLanguage: AppLanguage
    private let recogniser: LiveTranslateFrameRecognising
    private let cache: LabelTranslationCache
    /// Tier 1 — the on-device brain, asked before anything leaves the device
    /// (FR-LCT-008 as amended 2026-09-17). Never nil: a device with no brain
    /// installed has a tier that says so and hands the strings back, which is
    /// a different thing from a cascade that has no tier at all.
    private let brain: LocalBrainTranslating
    private let tier: CloudTranslationTier
    private let cloudNeed: LiveTranslateCloudNeedDeciding
    private weak var backpressure: LiveTranslateBackpressure?
    private let events: LiveTranslateEvents
    private let publishToSink: PublicationSink

    /// The salt this session's scene digests are taken under
    /// (`LiveTranslateRegionSetDigest`). Drawn per pipeline and never logged,
    /// stored or sent: it exists so the digest in the log is a discriminator
    /// *within one session* and not a value a reader could match a guess about
    /// the scene against. A test that pins a digest's exact value passes its own.
    ///
    /// A word-sized `UInt` rather than a spelled-out `UInt64`: the feature's
    /// sources are scanned for the configured defaults (`NFR-LCT-011`) and a
    /// `64` in a type name reads to that scan exactly like a re-declared
    /// `translationMaxLengthAllowance`. The word is 64 bits on every platform
    /// this app ships to, which is the whole width the salt needs.
    private let regionDigestSalt: UInt

    /// The session's one clock, injected (the consent gate's `now:` seam,
    /// same convention). The pipeline is not time-driven — it is a frame tick,
    /// and AM-6 puts every *ordering* decision on a counter — but three rules
    /// are bounded in the unit the elder experiences them in, which is
    /// seconds: the stabiliser's departure grace, and the two dispatch-pacing
    /// intervals (`translationDispatchMinInterval`,
    /// `brainAttemptMinInterval`). One clock for all three, so a test that
    /// advances it moves the whole feature. Production passes `Date.init`; a
    /// test that asserts any of them passes its own clock and never waits on
    /// the wall.
    private let now: () -> Date

    /// One string waiting on the elder's answer to the consent prompt, and who
    /// raised the question (`awaitingDecision`).
    private struct PendingAsk {
        /// **The plan's ask, whole** (review round 2, finding 2) — its strings
        /// in their order, its urgency, its destination, its mode, the frame's
        /// counts and the epoch the plan was made for. The retry replays it; it
        /// does not rebuild it from the parts someone remembered.
        ///
        /// What this replaced was the hand-picked subset the retry happened to
        /// need — the item, the mode, the region count — which was correct only
        /// for the fields somebody had copied. Every field added to a request
        /// afterwards was silently dropped on this path, and the one the review
        /// caught is the one that writes to disk: a `.focused` ask whose *mode*
        /// was rebuilt as the default came back as a `.cascade`'s and stored
        /// the crop's strings through the very store the focus exists to keep
        /// them out of. A request carried whole cannot drift, because there is
        /// nothing to keep in step.
        let request: ResolutionRequest
        /// Whether the ask came from a region on the live picture — a property
        /// of *where* the question was raised and not of the ask, which is why
        /// it is the one field beside the request. It is the prune's rule: a
        /// live ask is a claim about a sighting and goes with it, while a held
        /// frame's ask does not (see `awaitingDecision`).
        let isLive: Bool
    }

    // MARK: State (actor-isolated)

    private var stabilizer: TextRegionStabilizer
    /// The current outcome per visible region. Never holds an entry for a
    /// region that is no longer visible.
    private var outcomes: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [:]
    /// The **answer** for every normalized key whose question has been
    /// answered terminally (resolved or degraded), not merely the fact that it
    /// was. Keyed by text, so a text change is automatically a new question —
    /// which is why nothing here has to invalidate on edit.
    ///
    /// Holding the answer rather than a flag is what makes a region born for
    /// an already-answered string inherit that answer **in the cycle that
    /// publishes it**: a camera movement is not a new question, and the elder
    /// must never see "translating…" flash over a translation the session
    /// already has. The alternative — a set plus a lookup somewhere else —
    /// left the new region pending with nothing left to dispatch it, because
    /// the key was already settled.
    private var settledOutcomes: [String: TranslationResult] = [:]
    /// The answers a **held frame** settled, keyed by normalized key, which the
    /// live sighting's prune must therefore leave alone (see `reconcile`). A
    /// frame's answers outlive the picture they were rendered from, and the
    /// live cycle cannot see them: they are released when the frame is put down
    /// (`discardHeldAnswers`), on a resume, and on a close — never by the
    /// live prune.
    ///
    /// The **answer** is held, not merely the key, because the release is
    /// ownership-checked: a key a live plan settled over the top of the frame's
    /// answer is that plan's, and deleting it at the thaw destroyed a live
    /// settlement the frame only borrowed (review).
    private var heldSettledKeys: [String: TranslationResult] = [:]
    /// Which picture the held answers belong to: bumped every time the frame is
    /// put down. A frozen plan carries the epoch it was made for, so a plan
    /// that lands after the elder has put the picture down settles its answers
    /// **without holding them** — keys committed past the thaw guard used to be
    /// held for a frame that no longer existed, and no later thaw released
    /// them (review).
    private var heldFrameEpoch = 0
    /// Normalized keys currently dispatched to the cloud tier. Cleared when
    /// the attempt reports back, so a key is never requested twice at once
    /// (the tier's own claim step is the second half of that guarantee).
    private var attemptKeys: Set<String> = []
    /// The plan that holds each key in `attemptKeys`. A claim is a reference
    /// the claimant releases itself: a release that went by key alone let one
    /// plan drop another plan's claim, and a deferral that released whatever
    /// happened to be in `attemptKeys` dropped strings a plan was still
    /// working on (review).
    private var claimOwner: [String: UUID] = [:]
    /// Normalized keys the on-device brain has already been asked about **in
    /// this sighting**. The brain is not a lookup: one attempt is a generation
    /// of seconds, so asking it again on the next tick — which is exactly what
    /// the tick-per-attempt design does for the cloud, where an attempt is a
    /// cheap in-memory decision — would queue generations behind each other
    /// for as long as a region stayed on screen. Pruned with the settled set
    /// and cleared by a resume, so the claim is per sighting and no stronger:
    /// the same text seen again is a new question, answered again (the
    /// sampling is deterministic, so it is answered the same way).
    private var brainAttemptedKeys: Set<String> = []
    /// [RELIABILITY-ROUTER] Normalized keys the **cloud** has already come back
    /// empty-handed for in this sighting: a request was made (or the gate
    /// refused one) and no translation came of it.
    ///
    /// The cloud's ledger, beside the brain's, and it exists for the same
    /// reason: an attempt is not free. A string the cloud has failed is the
    /// device's to answer from then on — the router plans it device-first
    /// whatever its class — because a plan that kept leading with the cloud
    /// for a string the cloud just failed would spend a request per tick on a
    /// string the device answers locally, and would do it in a loop that never
    /// terminates (fail → ask again → fail). One attempt each per sighting is
    /// what makes the plan finite: both tiers tried, and if neither answered,
    /// the reason is recorded and the region says so.
    private var cloudFailedKeys: Set<String> = []
    /// Normalized keys currently waiting on the elder's answer to the consent
    /// prompt: the gate returned `.awaitingDecision`, nothing was sent and
    /// nothing failed.
    ///
    /// Kept because the live cycle is not the only asker. A tick follows every
    /// frame, so the live path re-asks these as soon as the answer is recorded
    /// — but **extract mode has no next tick**: its whole translation path is
    /// the one tap, and a key released by the prompt would sit pending for the
    /// rest of the session unless the elder's answer could hand it back to the
    /// plan. That is `retryAwaitingResolution`, which the answers call.
    ///
    /// The **item** is kept, not the key alone, because the answer has to be
    /// able to re-ask the string the question interrupted, and the live picture
    /// is not the only place a question is raised: a frozen frame asks about
    /// the strings on the *held* picture, and those strings are in no
    /// stabiliser. A registry of keys alone rebuilt its candidates from
    /// `stabilizer.visible`, so every frozen ask was dropped on the floor and
    /// the grant that answered it carried nothing (review of #100). `isLive` is
    /// what keeps the registry bounded — a live ask is a claim about a sighting
    /// and is pruned with it, while a held frame's ask is not pruned by frames
    /// it is not in (the picture is still on screen and a frame has no next
    /// tick to raise the question again) and is replaced wholesale by the next
    /// capture, so the registry never holds more than one frame's worth.
    private var awaitingDecision: [String: PendingAsk] = [:]
    /// The two pacing clocks (`translationDispatchMinInterval`,
    /// `brainAttemptMinInterval`), read and written together in the dispatch's
    /// own prologue: when pending strings were last dispatched, and when the
    /// brain was last asked for a generation. `nil` is "nothing has been paid
    /// for yet", which is what makes a session's first dispatch always
    /// immediate. Cleared by a resume, so an interruption is not a pause in a
    /// rate limit: the first tick after it dispatches like a first tick.
    private var lastDispatchAt: Date?
    private var lastBrainAttemptAt: Date?
    /// The session-scoped task tree: one entry per dispatched attempt, removed
    /// by the attempt itself when it finishes, so this stays bounded by the
    /// number of in-flight requests rather than by the session's length.
    ///
    /// The value carries the plan's answers, because a caller that must have
    /// them before it returns — the frozen half of `retryAwaitingResolution` —
    /// awaits the very task the session holds, so a thaw or a close cancels
    /// what that caller is waiting on rather than a private copy of it. The
    /// registry's own reads (cancel, forget, count) never touch the value.
    private var resolutionTasks: [UUID: Task<[String: TranslationResult], Never>] = [:]

    /// The publication counter (AM-6).
    private var publicationSequence = 0
    /// The last publication actually delivered, and the geometry it was
    /// measured under. The jitter gate (T-026) compares against these; a
    /// suppressed cycle leaves them alone, so the next cycle is measured
    /// against the same baseline the consumer is still looking at.
    private var lastPublished: LiveTranslatePublication?
    private var lastPublishedLayout: LiveTranslateLayout?
    private var lastPublishedFramePixelSize: CGSize = .zero
    private var layout: LiveTranslateLayout = .unknown
    /// The last frame's pixel size — the letterbox the placement maps through.
    /// Held only as a size: no frame, no buffer and no image is retained beyond
    /// the cycle that used it.
    private var framePixelSize: CGSize = .zero
    private var alwaysShowOriginal: Bool
    /// The cloud tier's master switch (owner directive, 2026-09-19): when it
    /// is off, the gate answers `.cloudDisabled` before the consent question
    /// is even asked, so no prompt is presented and no request is built.
    ///
    /// It is a `Bool` and not an `Optional`: the initializer resolves the
    /// caller's `nil` into the config's nominal default once, so there is no
    /// later read at which "the household never chose" and "the household
    /// chose off" could diverge. The switch is checked in
    /// `attemptThroughTheGate` — the one gate-then-tier sequence the live
    /// cycle and the snapshot path share — which is what makes "off" mean the
    /// same thing in extract mode's tap-to-translate, in the translated view,
    /// and on a frozen frame.
    private var geminiCloudEnabled: Bool
    /// [RELIABILITY-ROUTER] Whether a network path exists right now — the
    /// other half of "can the cloud lead?" (`cloudCanLead`) beside the
    /// household switch. This is a PATH question, not a permission one; the
    /// permission questions stay in `attemptThroughTheGate`, after this.
    private let reachability: NetworkReachability
    /// Extract mode (owner verdict, 2026-09-18): the overlay shows the
    /// recognized text, and **no tier runs until a region is asked for**.
    ///
    /// It is a gate on the cycle's two resolution steps and on nothing else:
    /// recognition, stabilisation, grouping, placement and publication are the
    /// same work in both modes, which is what keeps the boxes still while the
    /// elder switches between the two views. `false` is the translated view,
    /// and it is the default the initializer keeps, so every caller before this
    /// rework is unchanged.
    private var extractionMode: Bool

    private var isPaused = false
    private var isClosed = false
    private var cycleInFlight = false

    /// Consecutive passes that produced no new information (see
    /// `noteSceneActivity`). Drives the reduced cadence: at
    /// `stalePassesBeforeReducedCadence` the pipeline tells the frame source
    /// the scene is stale and the tap drops from the nominal cadence to
    /// `stableSampleInterval`.
    private var idlePasses = 0
    /// The visible regions' boxes as of the last cycle, for the one question
    /// the stabiliser's change events cannot answer: a scene can publish no
    /// new *region* while every box in it is still moving, which is exactly
    /// what a pan over text the session already knows looks like. Movement is
    /// activity — the overlay is following it and the elder expects it to keep
    /// following — so it resets the idle count rather than earning a slower
    /// cadence.
    private var lastCycleBoxes: [TextRegionStabilizer.RegionIdentity: NormalizedBox] = [:]

    // MARK: Init

    /// The pilot's translation target, stated once.
    ///
    /// The live cycle's initializer default and T-033's snapshot path both
    /// take the value from here, so the two paths cannot translate into
    /// different languages — and a later move to a second target language has
    /// one place to change rather than a copy to find.
    static let defaultTargetLanguage: AppLanguage = .nepali

    init(locale: Locale,
         targetLanguage: AppLanguage = LiveTranslationPipeline.defaultTargetLanguage,
         recogniser: LiveTranslateFrameRecognising,
         cache: LabelTranslationCache,
         tier: CloudTranslationTier,
         cloudNeed: LiveTranslateCloudNeedDeciding,
         backpressure: LiveTranslateBackpressure?,
         alwaysShowOriginal: Bool,
         /// The cloud tier's master switch (owner directive, 2026-09-19).
         /// **Optional and defaulted to `nil`**, which resolves to
         /// `config.geminiCloudEnabledDefault` — so every call site that
         /// predates the switch (and every test that is not about it) keeps
         /// the shipped behaviour without being edited, and a caller that
         /// means something hands in the value it means.
         geminiCloudEnabled: Bool? = nil,
         /// [RELIABILITY-ROUTER] The network's answer, for the router's
         /// "can the cloud lead?" question. **Defaulted to the no-path
         /// answer**, so every construction site that predates the router —
         /// and every test that is not about it — keeps the cascade in the
         /// order it shipped with (device leads, cloud takes the misses)
         /// instead of silently gaining a cloud-first order nobody asked for.
         /// The production session hands in the real monitor.
         reachability: NetworkReachability = UnavailableReachability(),
         /// Extract mode's initial state (owner verdict, 2026-09-18). Defaulted
         /// so every caller that predates the mode keeps the translated view,
         /// which is what its tests assert about it.
         extractionMode: Bool = false,
         config: LiveTranslateConfig = .default,
         observabilityBus: ObservabilityBus,
         brain: LocalBrainTranslating? = nil,
         /// Where the warden's two notices go (owner directive, 2026-09-19).
         /// Forwarded to the tier this initializer builds; ignored when a
         /// brain was handed in, because an injected tier owns its own wiring
         /// and a caller that replaced the tier has replaced its surface too.
         ///
         /// Defaulted, so every caller that predates the notice path keeps
         /// exactly the behaviour it had: the events still record both
         /// moments, and a session with nothing listening loses nothing.
         onWardenNotice: (@Sendable (LocalBrainWardenNotice) -> Void)? = nil,
         now: @escaping () -> Date = Date.init,
         /// The scene digest's salt (`LiveTranslateRegionSetDigest`). Random per
         /// pipeline by default — a digest the log carries is only ever compared
         /// with another from the same session's own log — and injectable for the
         /// one test that pins a digest's exact value.
         regionDigestSalt: UInt = UInt.random(in: .min ... .max),
         publish: @escaping PublicationSink) {
        self.locale = locale
        self.targetLanguage = targetLanguage
        self.recogniser = recogniser
        self.cache = cache
        self.tier = tier
        self.cloudNeed = cloudNeed
        self.backpressure = backpressure
        self.alwaysShowOriginal = alwaysShowOriginal
        // The one place the switch's absent value is resolved: past this line
        // the pipeline holds a decision, never a question.
        self.geminiCloudEnabled = geminiCloudEnabled ?? config.geminiCloudEnabledDefault
        self.reachability = reachability
        self.extractionMode = extractionMode
        self.config = config
        let events = LiveTranslateEvents(bus: observabilityBus, config: config)
        self.events = events
        // Tier 1 is built here when no brain was handed in, so the production
        // session model — which knows nothing about models — gets the real
        // tier without a second construction site to keep in step. Tests hand
        // in a deterministic fake; the store is the same process-wide layout
        // the coordinator builds its own store over, and a failure to build it
        // is reported by the tier as `runtime_missing` rather than swallowed.
        self.brain = brain ?? LocalBrainTranslationTier(config: config,
                                                        modelStore: try? ModelStore(observabilityBus: observabilityBus),
                                                        events: events,
                                                        targetLanguage: targetLanguage,
                                                        onWardenNotice: onWardenNotice)
        self.publishToSink = publish
        self.now = now
        self.regionDigestSalt = regionDigestSalt
        self.stabilizer = TextRegionStabilizer(config: config)
    }

    // MARK: - Evidence (tests and `security-test`; production reads none of it)

    /// How many cloud attempts are in flight. Proof that the task tree is
    /// bounded and that a close released everything.
    var inFlightAttemptCount: Int { resolutionTasks.count }

    /// The publication counter's current value, read under isolation so the
    /// monotonicity assertion cannot be racing the writer.
    var publishedSequence: Int { publicationSequence }

    /// The strings currently dispatched but unanswered. Derived from the
    /// attempt registry, so it cannot disagree with it.
    var inFlightKeys: Set<String> { attemptKeys }

    /// The strings the elder is being asked about: the asks
    /// `retryAwaitingResolution` will carry when the answer arrives.
    ///
    /// A plan that meets an unanswered prompt leaves nothing else behind — no
    /// event, no publication, no tier call — so this is the only thing a test
    /// can read to know a tap has reached the gate. It is here for exactly
    /// that: an extract-mode scenario with several taps has to wait for *every*
    /// one of them to be recorded before it answers the prompt, or a plan the
    /// answer overtakes goes on to send the ask by itself and the scenario's
    /// request count means two different things on two runs (review of #100,
    /// finding 12).
    var awaitingResolutionKeys: Set<String> { Set(awaitingDecision.keys) }

    var activeRegionCount: Int { stabilizer.activeRegionCount }

    // MARK: - The frame tick

    /// One frame, end to end. The next tick is the retry: a failed pass, a
    /// slow tier or a region that could not be decided leaves nothing queued
    /// here, because nothing in this method waits for the cloud.
    func ingest(_ frame: CameraFrame) async {
        guard !isClosed, !isPaused, !cycleInFlight else { return }
        cycleInFlight = true
        defer { cycleInFlight = false }

        // The frame's geometry is the letterbox the placement maps through.
        // The frame itself is not retained: only its size is.
        framePixelSize = frame.pixelSize

        // Backpressure is scoped to the Vision pass and to nothing else: the
        // tap drops samples while it is set, and it is cleared before the
        // cloud work starts, so a slow request cannot stall the cadence.
        backpressure?.ocrPassInFlight = true
        let pass = await recogniser.recognize(frame)
        backpressure?.ocrPassInFlight = false

        guard !isClosed, !isPaused else { return }

        switch pass {
        case .failure:
            // Recorded by the detector as `ocr_pass_failed` and never surfaced
            // (T-007). The regions stay exactly as they were: a failed pass
            // makes no claim about the scene, so nothing is dropped or
            // degraded on its account.
            return
        case .success(let result):
            // The pass's region count travels the sanitising bus from the
            // detector (`ocrPass(regionCount:)`); the recognized strings travel
            // it through `LiveTranslateDebugLane`, which hands them to the bus
            // for `LogSanitiser` to redact. A capture shows the pass, its count
            // and the leg's timing and never the text — the feature carries no
            // console write at all, in any configuration (NFR-LCT-006).
            #if DEBUG
            LiveTranslateDebugLane(bus: events.bus,
                                   enabled: config.translationDebugLoggingEnabled)
                .recognizedText(result.regions.map(\.text).joined(separator: " | "),
                                regionCount: result.regions.count)
            #endif
            let changes = stabilizer.consume(regions: result.regions,
                                             tracked: result.trackedBoxes,
                                             at: now())
            record(changes)
            noteSceneActivity(changed: !changes.isEmpty)
            reconcile()
            // The extract-mode gate (owner verdict, 2026-09-18). In extract
            // mode the cycle publishes and stops: the recognized text is the
            // content, so there is nothing to resolve and nothing to send —
            // not the dictionary, not the brain, not the cloud. That is the
            // owner's "no wrong translations by default" and it is also the
            // CPU the mode exists to save. The *rest* of the cycle is
            // untouched: the pass, the stabiliser, the grouper, the placement
            // and the publication are the same work in both modes, so the
            // boxes the elder is looking at do not move when they switch.
            //
            // A region that *is* asked for — a block the elder tapped — runs
            // the same sequence through `translateRegion`, which is the one
            // entry point that resolves in this mode.
            guard !extractionMode else {
                await publish()
                return
            }
            resolveFromTheDevice()
            await publish()
            dispatchResolutionNeeds()
        }
    }

    /// The pipeline's half of the cadence rule: it is the only component that
    /// knows whether a pass produced anything, so it is the one that decides a
    /// scene has gone stale and says so on the frame source's backpressure
    /// flag.
    ///
    /// A pass is *active* when the stabiliser published a change (a region
    /// appeared, changed text or went away) **or** when a box already on
    /// screen moved. The second half is what keeps a pan honest: panning across
    /// text the session already knows produces no change event — the identities
    /// are stable — but every box is moving, the overlay is following them, and
    /// dropping to a slower cadence there would make the boxes lag the picture.
    /// Movement is therefore activity, and only a scene that is producing
    /// nothing new *and* holding still earns the reduced rate.
    ///
    /// The flag is only written when it changes, so a steady scene is not a
    /// steady stream of cross-thread writes.
    private func noteSceneActivity(changed: Bool) {
        let moved = boxesMovedSinceLastCycle()
        idlePasses = (changed || moved) ? 0 : idlePasses + 1
        let stale = idlePasses >= config.stalePassesBeforeReducedCadence
        if backpressure?.ocrSceneStale != stale {
            backpressure?.ocrSceneStale = stale
        }
    }

    /// Drops the stale-scene claim and everything it was counted from. The flag
    /// is cleared unconditionally (rather than "only if it was set") because
    /// the caller may be a close, where the last thing the frame source should
    /// be left holding is a claim about a scene nobody is watching.
    private func forgetSceneActivity() {
        idlePasses = 0
        lastCycleBoxes.removeAll()
        backpressure?.ocrSceneStale = false
    }

    /// Whether any region still on screen has moved since the last cycle — the
    /// question the stabiliser's change events do not answer.
    ///
    /// Only regions present in *both* cycles count: a box that arrived or left
    /// is already a change event, and comparing against a box that is gone
    /// would report movement for a region that simply disappeared. The
    /// movement threshold is the publication epsilon, the same "a wobble the
    /// elder cannot see" the jitter gate uses, so the two cannot disagree about
    /// what counts as motion.
    private func boxesMovedSinceLastCycle() -> Bool {
        var moved = false
        var next: [TextRegionStabilizer.RegionIdentity: NormalizedBox] = [:]
        for region in stabilizer.visible {
            next[region.id] = region.box
            guard let previous = lastCycleBoxes[region.id] else { continue }
            let deltas = [abs(previous.xMin - region.box.xMin),
                          abs(previous.yMin - region.box.yMin),
                          abs(previous.xMax - region.box.xMax),
                          abs(previous.yMax - region.box.yMax)]
            if deltas.contains(where: { $0 > config.publishBoxEpsilon }) { moved = true }
        }
        lastCycleBoxes = next
        return moved
    }

    /// The pipeline's half of the resume rule: the stabiliser restarts from
    /// empty, so every previously visible string is a new region and re-enters
    /// resolution — and the settled set is cleared, so strings that degraded or
    /// were in flight are attempted once more, under the normal consent and
    /// budget rules (AM-1 re-reads the gate, so a withdrawal still denies).
    ///
    /// The publication that follows is empty and that is the honest state: the
    /// session makes no claim about a frame it has not seen since the
    /// interruption.
    func resume() async {
        guard !isClosed, isPaused else { return }
        isPaused = false

        cancelResolutionTasks()
        settledOutcomes.removeAll()
        brainAttemptedKeys.removeAll()
        // The pacing clocks are claims about what has already been paid for,
        // and a resume takes every such claim back: the first tick after an
        // interruption dispatches immediately rather than waiting out an
        // interval that belonged to the session before it.
        lastDispatchAt = nil
        lastBrainAttemptAt = nil
        stabilizer.reset()
        outcomes.removeAll()
        // A resume restarts the scene as well as the regions: the frame source
        // has dropped its own remembered frame too, so the cadence starts from
        // the nominal rate rather than inheriting the staleness of a scene the
        // session was interrupted in the middle of.
        forgetSceneActivity()

        await publish()
    }

    /// The backgrounding half. Nothing is published while paused and no frame
    /// is processed (T-027's lifecycle): frames cannot even arrive, because the
    /// camera session pauses itself on the same notification.
    func pause() {
        guard !isClosed else { return }
        isPaused = true
        // The stale flag is a claim about a scene the session is no longer
        // looking at, so it is dropped rather than parked for the resume.
        forgetSceneActivity()
    }

    /// The session's close. Cancels the task tree, releases recognition and
    /// drops every outcome, so nothing this actor owns can publish or call back
    /// afterwards.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        backpressure?.ocrPassInFlight = false
        forgetSceneActivity()
        cancelResolutionTasks()
        recogniser.end()
        // Closing gives the brain's memory back: a session that is over must
        // not leave a 4B resident parked behind it (the tier takes no ledger
        // slot, so this release is its only one).
        await brain.release()
        stabilizer.reset()
        outcomes.removeAll()
        settledOutcomes.removeAll()
        brainAttemptedKeys.removeAll()
        lastDispatchAt = nil
        lastBrainAttemptAt = nil
    }

    // MARK: - Pushed state

    /// The view reported new geometry (it appeared, rotated, or its chrome
    /// changed). Re-placing the same content is the whole point: the rects the
    /// overlay draws are the rects this actor computed, so they must move with
    /// the container rather than being recomputed by the view.
    func updateLayout(_ newLayout: LiveTranslateLayout) async {
        guard !isClosed, layout != newLayout else { return }
        layout = newLayout
        // An empty container cannot place anything; publishing then would turn
        // "not laid out yet" into the empty state, which is a different claim.
        guard newLayout.containerSize.width > 0, newLayout.containerSize.height > 0 else { return }
        await publish()
    }

    /// The FR-LCT-017 preference, from either of its two writers (the overlay
    /// chrome or the voice command), routed through the session model so the
    /// placements and the control cannot disagree.
    func updateAlwaysShowOriginal(_ value: Bool) async {
        guard !isClosed, alwaysShowOriginal != value else { return }
        alwaysShowOriginal = value
        await publish()
    }

    /// The cloud tier's master switch, from its one writer (the session model,
    /// behind the Settings leaf's row). Owner directive, 2026-09-19.
    ///
    /// The write is deliberately smaller than `updateAlwaysShowOriginal`'s: it
    /// guards and assigns, and it does **not** publish. The display preference
    /// republishes because it moves where every callout is drawn; this switch
    /// does not move a single placement and does not touch a region's outcome,
    /// so a publication from here would be a frame a consumer re-renders to
    /// produce exactly the picture already on screen. What it does affect is
    /// the *next* attempt, and that attempt publishes its own result — the
    /// degraded region it produces is the visible consequence of switching the
    /// cloud off, which is a state the elder can read.
    ///
    /// It does **not** cancel, retry or re-dispatch anything either:
    ///
    ///  - turning it **off** stops the next attempt, not the one in flight. A
    ///    request that has already left is not un-sent by flipping a switch,
    ///    and pretending otherwise (a cancelled batch reported as "never
    ///    sent") would be a lie in the evidence; what the switch guarantees is
    ///    that nothing *new* starts, and `attemptThroughTheGate` is where that
    ///    is enforced for both callers.
    ///  - turning it **on** does not by itself re-attempt strings the session
    ///    already settled as `cloud_disabled`. They are terminal for the
    ///    session's own monotonicity rule (AM-8), and the honest way to ask
    ///    again is the one the design already has — a resume — rather than a
    ///    switch that silently re-opens settled regions.
    func updateGeminiCloudEnabled(_ value: Bool) async {
        guard !isClosed, geminiCloudEnabled != value else { return }
        geminiCloudEnabled = value
    }

    /// The extract-mode toggle, from its one writer (the overlay chrome).
    ///
    /// Turning the *translated view* on is a request about everything on
    /// screen, so it is acted on in the same turn rather than at the next
    /// tick: the device's own answers are taken (`resolveFromTheDevice`), the
    /// view is published, and the rest is dispatched exactly as a cycle would
    /// have dispatched it. Turning *extract mode* on changes nothing that is
    /// already in flight — an attempt that has been paid for is not thrown
    /// away, and its answer lands in the same region it was asked about — it
    /// only stops new ones from being started.
    func updateExtractMode(_ value: Bool) async {
        guard !isClosed, extractionMode != value else { return }
        extractionMode = value
        guard !value else {
            await publish()
            return
        }
        resolveFromTheDevice()
        await publish()
        dispatchResolutionNeeds()
    }

    /// Extract mode's one ask: translate **this** region — the block the elder
    /// tapped — and nothing else on screen.
    ///
    /// This is the mode's whole translation path, and it is deliberately the
    /// ordinary one, scoped: the same device lookup, the same tier cascade
    /// behind the same consent gate, the same settle-and-publish, narrowed to
    /// one region's key. Nothing here can be reached for a region that is not
    /// on screen, is not pending, or is not the one asked for, so a tap cannot
    /// turn into the continuous background work the mode exists to avoid.
    func translateRegion(_ regionID: TextRegionStabilizer.RegionIdentity) async {
        guard !isClosed else { return }
        guard let region = stabilizer.visible.first(where: { $0.id == regionID }),
              let existing = outcomes[region.id], case .pending = existing.outcome else { return }

        let key = Self.cacheKey(for: region.text, targetLanguage: targetLanguage)
        resolveFromTheDevice(only: key)
        await publish()
        dispatchResolutionNeeds(only: [key])
    }

    // MARK: - The cycle

    /// Change events are content-free (a region identity and nothing else), so
    /// recording them cannot leak a string. The single `text_change` carries
    /// the visible-region count and the scene digest, which are the shape of the
    /// elder's screen and nothing of what is on it — the two numbers that let
    /// the next device capture tell a changed reading from a re-keyed region
    /// (`LiveTranslateRegionSetDigest`).
    private func record(_ changes: [TextRegionStabilizer.RegionChangeEvent]) {
        guard !changes.isEmpty else { return }
        for change in changes {
            switch change {
            case .appeared: events.regionAppeared()
            case .textChanged: break
            case .disappeared: events.regionRemoved()
            }
        }
        events.textChange(regionCount: stabilizer.visible.count,
                          regionSetHash: LiveTranslateRegionSetDigest.digest(
                              of: stabilizer.visible.map(\.normalizedText),
                              salt: regionDigestSalt))
    }

    /// The visible set is the only set: a region's outcome survives a cycle
    /// while its text is unchanged (AM-8/CL-1 — a resolved region never
    /// returns to pending), and everything else — a region the stabiliser
    /// just republished under a new identity, or one whose identity it kept —
    /// inherits the answer its *string* already has, in this same cycle, so
    /// nothing that has been answered is ever published as pending.
    ///
    /// Inheritance is keyed by the normalized string, which is the same key
    /// the cache, the tier and the settled set use. It is what makes a camera
    /// movement free: the region may be a different identity, but the
    /// question was about the text, and the text has an answer.
    ///
    /// The settled map is pruned to the visible one for the same reason, and
    /// it is a correctness rule rather than tidiness. "Settled" means *an
    /// answer is attached to a region on screen*; an answer that arrived for a
    /// string nothing is showing — a resume released the regions and the
    /// attempt landed afterwards — settles nothing, and keeping it settled
    /// would leave the region pending for good when the same text came back:
    /// no outcome to render from the last cycle, and no dispatch because the
    /// key was "answered". Dropping it makes the string askable again, and the
    /// cache answers it first, so nothing is re-charged and nothing is left
    /// unrendered.
    private func reconcile() {
        var next: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [:]
        var visibleKeys: Set<String> = []
        for region in stabilizer.askable {
            let key = Self.cacheKey(for: region.text, targetLanguage: targetLanguage)
            visibleKeys.insert(key)
            if let existing = outcomes[region.id], existing.isFinal, existing.originalText == region.text {
                next[region.id] = existing
            } else if let settled = settledOutcomes[key] {
                next[region.id] = LiveTranslateCaptureSupport.restating(settled, for: region.text)
            } else {
                next[region.id] = .pending(region.text)
            }
        }
        // A held frame's settlements are not this sighting's to prune. Its keys
        // are absent from `visibleKeys` by construction — the frame is a still
        // picture, not the scene the stabiliser is watching — and dropping them
        // here made the frame's next refresh ask the tiers for a string the
        // session had already answered and paid for (review). They are released
        // with the frame instead (`discardHeldAnswers`).
        settledOutcomes = settledOutcomes.filter {
            visibleKeys.contains($0.key) || heldSettledKeys[$0.key] != nil
        }
        brainAttemptedKeys = Set(brainAttemptedKeys.filter { visibleKeys.contains($0) })
        // The router's two ledgers are per-sighting claims like the brain's,
        // and they are pruned the same way: a string that has left the scene
        // costs nothing to forget, and one that is still on screen keeps its
        // spent attempt.
        cloudFailedKeys = Set(cloudFailedKeys.filter { visibleKeys.contains($0) })
        // Only the *live* asks are pruned with the sighting: a held frame's ask
        // is not about this picture at all (see `awaitingDecision`).
        awaitingDecision = awaitingDecision.filter { !$0.value.isLive || visibleKeys.contains($0.key) }
        outcomes = next
    }

    /// The key a string is asked about under: the cache's own normalization
    /// (`LabelTranslationCache.normalizationKey`), stated once so the device
    /// lookup, the attempt registry, the settled set and extract mode's
    /// one-region dispatch cannot disagree about what "the same question" is.
    private static func cacheKey(for text: String, targetLanguage: AppLanguage) -> String {
        LabelTranslationCache.normalizationKey(text: text, targetLanguage: targetLanguage)
    }

    /// The stored answer, restated for the text a region is showing now — the
    /// one rule, shared with the capture paths
    /// (`LiveTranslateCaptureSupport.restating`). It used to be spelled here
    /// and in `LiveTranslateFocusCapture`, which is exactly the pair of copies
    /// review round 2 (finding 7) asked to collapse.
    ///
    /// The on-device layers — the curated dictionary and the persisted cache —
    /// answer before anything else is asked.
    ///
    /// This is a sequencing decision, not a second copy of a rule: the lookup
    /// *is* C05's, and the tier asks the same layer again for anything it is
    /// handed, so the two cannot disagree. It has to happen here because the
    /// consent prompt is presented at the point of first cloud need, and asking
    /// a question about a string the device already knows the answer to would
    /// prompt the elder for nothing (FR-LCT-020).
    private func resolveFromTheDevice(only key: String? = nil) {
        for region in stabilizer.visible {
            guard let existing = outcomes[region.id], case .pending = existing.outcome else { continue }
            // Extract mode asks about one region at a time; `nil` is the
            // translated view's "every pending region", which is the shipped
            // behaviour and stays the default.
            if let key, Self.cacheKey(for: region.text, targetLanguage: targetLanguage) != key {
                continue
            }
            guard case .success(let hit) = cache.lookup(text: region.text,
                                                        targetLanguage: targetLanguage),
                  let hit else { continue }
            let result = TranslationResult.resolved(originalText: region.text,
                                                    translation: hit.translation,
                                                    tier: hit.tier)
            outcomes[region.id] = result
            // [CACHE-SETTLE] (owner's 15:50 report: the events resolve, the
            // screen stays "translating…".) The answer must ride BOTH keys,
            // the way every other settlement path's does: `outcomes` is keyed
            // by the region's identity, which churns every frame on a busy
            // scene, and `reconcile()` rebuilds a changed identity from
            // `settledOutcomes[key]` — which this path never wrote. A cache
            // hit therefore re-pended its region on the very next churn.
            settledOutcomes[Self.cacheKey(for: region.text,
                                          targetLanguage: targetLanguage)] = result
            events.translationResolved(tier: hit.tier, origin: .cache, count: 1)
        }
    }

    /// [RELIABILITY-ROUTER] Whether the cloud may LEAD for the sentence class:
    /// the household's switch is on AND there is a network path. Both are
    /// pre-conditions of an attempt worth leading with, and requiring them here
    /// means the router never trades a translation the device can produce for
    /// one the cloud cannot — with either false, the device keeps the front,
    /// which is the order the cascade shipped with.
    ///
    /// Deliberately NOT "consent is granted": consent is the gate's to read
    /// immediately before each attempt (`attemptThroughTheGate`), and caching
    /// it here would answer for the elder on the strength of an older decision.
    private var cloudCanLead: Bool { geminiCloudEnabled && reachability.isReachable }

    /// [RELIABILITY-ROUTER] Which tier leads for one string, by the session's
    /// own rule.
    ///
    /// Two questions, in this order:
    /// 1. **Has the cloud already come back empty-handed for it?** Then the
    ///    device leads, whatever the string's class — one cloud attempt per
    ///    string per sighting (`cloudFailedKeys`), or a failure would buy
    ///    another request on the next tick, forever.
    /// 2. Otherwise the class decides: the short forms the model is proven on
    ///    keep the device in front (the order the cascade shipped with), the
    ///    sentence class leads with the cloud when the cloud can lead.
    ///
    /// The order of the two questions is the whole of the fallback: the class
    /// is what the *model* is good for, and the ledger is what the *session*
    /// has already spent. A string whose only cloud attempt is behind it is not
    /// a sentence-class question any more — it is a string the device owes an
    /// answer to.
    private func leadingTier(for item: CloudTranslationTier.Item,
                             mode: TranslationMode = .cascade)
        -> TranslationReliabilityRouter.LeadingTier {
        if cloudFailedKeys.contains(item.id) { return .onDevice }
        switch mode {
        case .cascade:
            return TranslationReliabilityRouter.leadingTier(for: item.text,
                                                            cloudAvailable: cloudCanLead)
        case .focused:
            // A pointed-at read leads with the device whatever the string's
            // class. The class rule is a statement about what the *model* is
            // proven on, and it is what the cascade exists for — but it is
            // also a statement about a scene the elder is living in, where a
            // sentence worth reading will still be there a second later. A
            // focused read is an elder pointing at one thing and asking for
            // it now: the device answers in a generation, the cloud in a
            // round trip, and the round trip is the wrong answer under their
            // finger. What the device cannot answer still reaches the cloud
            // through the ordinary stages behind it — the mode changes who
            // leads, never who is reachable.
            return .onDevice
        }
    }

    /// Records that a string's brain generation has been paid for (see
    /// `brainAttemptedKeys`). A method rather than a direct mutation because
    /// the dispatch task body is not actor-isolated.
    private func noteBrainAttempt(_ ids: [String]) {
        brainAttemptedKeys.formUnion(ids)
    }

    /// Whether the brain's own clock allows a generation at `moment`.
    ///
    /// Every stage that can spend a generation asks it, so the paths that can
    /// pay for one are paced by one rule. They were two: the fallback stage
    /// asked the brain on every dispatch tick it ran under, which is a
    /// generation per 1.5 s of a sustained cloud outage rather than the one per
    /// `brainAttemptMinInterval` the device log asked for (owner device report,
    /// 2026-09-19).
    ///
    /// The elder's own ask is the caller's business, not this method's: a tap
    /// and a prompt's answer are the elder acting, and they are allowed through
    /// the clock by `maySpendAGeneration`.
    private func brainMayAttempt(at moment: Date) -> Bool {
        lastBrainAttemptAt.map {
            moment.timeIntervalSince($0) >= config.brainAttemptMinInterval
        } ?? true
    }

    /// Records that the cloud came back empty-handed for these strings (see
    /// `cloudFailedKeys`). A method for the same reason `noteBrainAttempt` is
    /// one: the task body is not actor-isolated.
    private func noteCloudFailure(_ ids: [String]) {
        cloudFailedKeys.formUnion(ids)
    }

    // MARK: - The resolution plan (the one way in)

    /// How the elder came to ask for a resolution — the whole of the pacing
    /// policy, stated once.
    ///
    /// A clock is not a property of a *path*; it is a property of the ask. Three
    /// paths resolve strings — the frame tick, the elder's own ask, and a still
    /// frame — and before this type each of them carried its own copy of "may I
    /// spend a dispatch, may I spend a generation", which is how one copy came
    /// to skip the pacing that protects the model and another came to strand the
    /// one block it was ever handed (review of #100).
    private enum ResolutionUrgency {
        /// A frame tick: background work. Both clocks apply — the dispatch
        /// clock spaces the requests, and the brain's clock spaces the model
        /// loads.
        case tick
        /// The elder acted: a tap on a block, or the answer to a prompt. Both
        /// clocks are skipped (and still moved), because an ask that did
        /// nothing because a background dispatch happened 0.9 s ago is the
        /// feature failing at the one thing it does (owner verdict, 2026-09-18).
        case explicitAsk
        /// A still picture. Not background work — the elder pressed the shutter
        /// — but not a reason to skip the brain's clock either: a capture that
        /// paid a generation per press would thrash the model's load every time
        /// the elder looked at something, and a cloud outage is exactly when
        /// they press it repeatedly (owner decision, 2026-09-20). The dispatch
        /// clock does not apply to it: a capture is one ask, not a cadence.
        case capture
    }

    /// Where a plan's terminal answers land. The three paths differ in this and
    /// in nothing else.
    private enum ResolutionDestination {
        /// The live cycle: a terminal answer is written onto the region on
        /// screen and the cycle publishes it as it lands, so a region stops
        /// being pending in the frame after its answer arrives.
        case live
        /// A held frame: answers are collected for the caller, which is about to
        /// re-render one still picture and owns the publication they land on.
        case frozen
    }

    /// One ask for resolution, as the adapters hand it to the plan.
    ///
    /// `Equatable` because two recorded asks have to be comparable to be
    /// replayed as one batch (`isSameBatch(as:)`) — and comparable *whole*,
    /// which is the point: a request is a value, and a comparison that named a
    /// subset of its fields would be wrong about every field added later.
    private struct ResolutionRequest: Equatable {
        /// The strings to resolve, in the order they are to be planned — region
        /// order for a tick (so the same scene produces the same batch and the
        /// bounds are deterministic), the elder's own order for an ask, and the
        /// frozen picture's region order for a capture.
        var items: [CloudTranslationTier.Item]
        var urgency: ResolutionUrgency
        var destination: ResolutionDestination
        /// Which routing and which batch budget this ask runs under. Defaulted
        /// to `.cascade` so every existing construction states the shipped
        /// behaviour by saying nothing (see `TranslationMode`).
        var mode: TranslationMode = .cascade
        /// How many regions are showing each string **in the picture this ask
        /// is about**, when that picture is not the live one. A held frame's
        /// regions are not in the stabiliser, so the live scanner answers 0 for
        /// them and the degradation count fell back to the floor of 1 whatever
        /// the frame held (review: a two-region string degraded as one). Empty
        /// is "the live picture", which the scanner can count for itself.
        var regionCounts: [String: Int] = [:]
        /// The held frame this ask is for, when `destination` is `.frozen` —
        /// `heldFrameEpoch` at the moment the ask began. The plan holds its
        /// answers for the frame only while this still names the frame the
        /// session is holding; a plan that lands after the elder put the
        /// picture down holds none of them (review). Ignored by the live
        /// destination, which holds nothing.
        var frozenEpoch: Int = 0
        /// Whether this plan's answers belong to a picture the **session** is
        /// holding, and are therefore kept for it in `heldSettledKeys` until
        /// it is put down.
        ///
        /// True for the still path, whose frame the elder can thaw. **False
        /// for a focused read**, and that is the whole of review finding 5: a
        /// focus owns its own picture's lifetime and reads its answers
        /// straight out of `plan.value`, so a focused plan that held them
        /// stamped a frame epoch it was not holding — and every key whose
        /// release sits behind the thaw guard (`discardHeldAnswers`, called
        /// only by `returnToLive`) would wait for a thaw that never comes,
        /// leaking the keys and leaving a stale degraded answer sticky for the
        /// rest of the session. A plan that holds nothing is pruned by
        /// `reconcile` like any other settlement.
        var holdsAnswers: Bool = true

        // MARK: Replaying a recorded ask

        /// The same ask with the retry's own urgency: the elder just answered
        /// the prompt, so both pacing clocks are skipped (see
        /// `ResolutionUrgency.explicitAsk`, and the retry's note for why that
        /// is the *one* field the retry owns).
        ///
        /// A copy rather than a rebuild. A request reassembled field by field
        /// is a list of everything someone remembered about the ask, and the
        /// field nobody remembers is how a `.focused` capture came back from
        /// the consent retry as a `.cascade` and stored the crop through the
        /// store the focus exists to keep it out of (review round 2, finding
        /// 2). Nothing can be forgotten by a copy.
        func replayed() -> ResolutionRequest {
            var copy = self
            copy.urgency = .explicitAsk
            return copy
        }

        /// The same ask, owning only these strings — the ledger rule every
        /// hand-over already applies (`resolveFocused`, `resolveFrozen`,
        /// `dispatchResolutionNeeds`): a string another plan is working on is
        /// that plan's to answer, and asking it here pays twice for one answer.
        ///
        /// The strings are the group's and the rest of the request is
        /// untouched, so the counts, the epoch and the mode still describe the
        /// plan the ask was raised by.
        func restricting(to items: [CloudTranslationTier.Item]) -> ResolutionRequest {
            var copy = self
            copy.items = items
            return copy
        }

        /// Whether two recorded asks are the **same batch** — the same ask in
        /// every respect two plans can differ in — so the strings they hold are
        /// replayed as the one request the prompt interrupted rather than as
        /// one request per string.
        ///
        /// Compared on copies with the two things that are a *plan's* rather
        /// than an *ask's* set aside: the strings themselves, and the urgency
        /// the retry owns (`replayed()`). Written this way rather than as a
        /// field-by-field comparison on purpose — a hand-written list is a list
        /// every later field is missing from, and the failure mode of a
        /// *missing* field here is merging two asks that are not the same one.
        func isSameBatch(as other: ResolutionRequest) -> Bool {
            var mine = self
            var theirs = other
            mine.items = []
            theirs.items = []
            mine.urgency = .explicitAsk
            theirs.urgency = .explicitAsk
            return mine == theirs
        }

        /// This ask with the group's strings appended, each key once and in the
        /// order the asks were recorded — the order the prompt raised them in.
        func carrying(_ items: [CloudTranslationTier.Item]) -> ResolutionRequest {
            var copy = self
            var seen = Set(copy.items.map(\.id))
            for item in items where seen.insert(item.id).inserted {
                copy.items.append(item)
            }
            return copy
        }
    }

    /// One plan's identity, and the picture it is answering for.
    ///
    /// What every stage that writes a claim, holds an answer or counts a
    /// degradation needs, carried as one value so a call site cannot state one
    /// half of the rule and assume the other: the token that releases exactly
    /// the claims this plan made, and the picture whose counts and epoch the
    /// settle needs. Nothing here has a default — a stage that counts a
    /// degradation states which picture's counts it is counting (review: the
    /// `[:]` defaults let a call site undercount in silence).
    private struct PlanContext {
        /// The plan's own token: `claim`/`release` match on it.
        let token: UUID
        /// **The ask itself**, whole. Every stage reads the field it needs
        /// through the accessors below rather than through a copy kept beside
        /// it, so a request can never disagree with the context it runs in; and
        /// the retry that answers the consent prompt replays this value
        /// verbatim (`PendingAsk.request`), which is what makes the recorded
        /// ask and the replayed ask the same ask by construction.
        let request: ResolutionRequest

        var destination: ResolutionDestination { request.destination }
        /// Regions per string in the picture this ask is about (a held frame's
        /// own multiplicities); empty is the live picture.
        var regionCounts: [String: Int] { request.regionCounts }
        /// The frame epoch this plan was made for (see
        /// `ResolutionRequest.frozenEpoch`).
        var frozenEpoch: Int { request.frozenEpoch }
        /// Whether this plan's answers are held for a picture the session
        /// holds (see `ResolutionRequest.holdsAnswers`).
        var holdsAnswers: Bool { request.holdsAnswers }
        /// Which routing and which batch budget this plan runs under — the
        /// ask's own, carried so every stage that can spend a batch or route a
        /// string reads one value (see `TranslationMode`).
        var mode: TranslationMode { request.mode }

        init(token: UUID, request: ResolutionRequest) {
            self.token = token
            self.request = request
        }
    }

    /// [RELIABILITY-ROUTER] Hands the live picture's still-pending regions to
    /// the plan — the live cycle's own adapter.
    ///
    /// The candidates are built here because only this path has regions: the
    /// visible pending ones, in region order, deduped by key. `only` narrows it
    /// to a set of keys — extract mode's tap-to-translate, and the consent
    /// prompt's own answered batch, which must go back as **one** dispatch
    /// rather than one per key: five single-string dispatches are five requests
    /// where the batch that asked the question was one, and both pacing clocks
    /// are skipped by an explicit ask, so nothing would space them out again.
    /// `nil` is every pending region, which is the mode-off behaviour the cycle
    /// has always had.
    private func dispatchResolutionNeeds(only onlyKeys: Set<String>? = nil) {
        // A closed session dispatches nothing — and the claim below is made
        // here, so returning before it is also what keeps a claim from being
        // written for a plan that will never run.
        guard !isClosed else { return }
        var candidates: [CloudTranslationTier.Item] = []
        var claimed: Set<String> = []
        for region in stabilizer.askable {
            guard let existing = outcomes[region.id], case .pending = existing.outcome else { continue }
            let key = Self.cacheKey(for: region.text, targetLanguage: targetLanguage)
            if let onlyKeys, !onlyKeys.contains(key) { continue }
            guard claimed.insert(key).inserted else { continue }
            guard settledOutcomes[key] == nil,
                  !attemptKeys.contains(key) else { continue }
            candidates.append(CloudTranslationTier.Item(id: key,
                                                         text: region.text,
                                                         detectedSourceLanguage: region.detectedLanguage))
        }
        guard !candidates.isEmpty else { return }
        // The claim is made **here**, on the actor and in the same synchronous
        // step as the filter above — `resolutionTask` claims before its task is
        // created, and nothing between the filter and that call suspends. It
        // used to happen inside the plan's own task body, so a second dispatch
        // that ran before that task reached its claim passed the same
        // `attemptKeys` filter and handed the tiers the same strings a second
        // time (review: check-then-act across the dispatch boundary). The claim
        // is **owned**: the plan's `defer` releases exactly the keys it claimed
        // and no others (review finding 4).
        startResolution(ResolutionRequest(items: candidates,
                                          urgency: onlyKeys == nil ? .tick : .explicitAsk,
                                          destination: .live))
    }

    /// Starts a plan off the caller's stack — the live cycle's shape. Resolution
    /// is a session-scoped task, never awaited by the tick, so the OCR cadence
    /// continues while a request or a generation is in flight and the next tick
    /// is the retry.
    private func startResolution(_ request: ResolutionRequest) {
        _ = resolutionTask(request)
    }

    /// The same plan, registered in the session's task tree **and** handed back
    /// so a caller that must have the answers before it returns can await them
    /// (the prompt's frozen retry is the one caller). One creator for both
    /// shapes: a plan awaited inline instead of registered is a plan a thaw, a
    /// resume or a close cannot cancel — the frozen retry used to run that way,
    /// and a plan the session had already ended still walked its strings to a
    /// tier and committed their answers (review: the two halves of the same
    /// retry used different task policies).
    @discardableResult
    private func resolutionTask(_ request: ResolutionRequest)
        -> Task<[String: TranslationResult], Never> {
        let token = UUID()
        // The claim is taken here — synchronously, in the caller's own actor
        // step — so the dispatcher's check-then-act guarantee holds, and it is
        // taken **as this plan's**: `claim` records the owner, which is what
        // makes the plan's `defer` able to release its own claims and nothing
        // else (review finding 4).
        claim(keys: request.items.map(\.id), by: token)
        let plan = PlanContext(token: token, request: request)
        let task = Task { [weak self] () -> [String: TranslationResult] in
            guard let self else { return [:] }
            let answers = await self.runResolution(request, plan: plan)
            await self.forget(task: token)
            return answers
        }
        resolutionTasks[token] = task
        return task
    }

    /// **The** resolution plan: the one entry point every path that reaches a
    /// tier goes through (the mandate of the third review, #100).
    ///
    /// Before any stage, one rule that is not a stage: **what the session has
    /// already answered is an answer, not an ask** — a hand-over that names a
    /// settled string gets that string's own result back and no second payment.
    ///
    /// It owns the four things that used to exist once per path and drifted:
    ///
    ///  1. **the clock policy** — the prologue below, from the ask's own
    ///     `urgency`: a tick answers to both clocks, an elder's ask to neither,
    ///     and a capture to the brain's (the dispatch clock does not pace a
    ///     single press). A plan the clock holds claims nothing, settles nothing
    ///     and drops nothing: the strings are still pending, so the next plan
    ///     that is allowed carries them, which is what turns a burst of arrivals
    ///     into one batch instead of one request each;
    ///  2. **batch bounding with deferral** — `askTheBrain`, which asks the
    ///     prefix the tier can be asked about and *releases* the surplus
    ///     unclaimed, rather than recording a generation that was never paid for
    ///     or failing a string the device never saw its turn on;
    ///  3. **the claim ledger** — `attemptKeys` (an attempt is owed),
    ///     `brainAttemptedKeys` (a generation has been paid for in this
    ///     sighting), `cloudFailedKeys` (the cloud came back empty-handed) and
    ///     `awaitingDecision` (the elder is being asked) — written here and by
    ///     the stages below, never by a caller;
    ///  4. **the terminal writer** — `settleTerminal`, the one place a string's
    ///     answer becomes the session's answer, and the one place a degradation
    ///     is emitted: exactly once, never silently, never twice.
    ///
    /// The three paths are thin adapters over it and differ in the destination
    /// they hand in. The strings are planned in the order they are handed over —
    /// region order, not dictionary order: a batch whose subset depended on
    /// Dictionary iteration order asks a different prefix of the same scene on
    /// every capture, which is what the review found the frozen path doing.
    ///
    /// The stages, and why they are in this order: the device leads for its
    /// class (the device's answers must never queue behind a network round-trip
    /// or an unanswered prompt), the gate leads for the class the device is not
    /// proven on, and whatever the tier behind the device cannot answer comes
    /// back to the device instead of degrading — a string the cloud failed is
    /// the device's to answer from then on.
    @discardableResult
    private func runResolution(_ request: ResolutionRequest,
                               plan: PlanContext) async -> [String: TranslationResult] {
        var answers: [String: TranslationResult] = [:]
        guard !isClosed, !request.items.isEmpty else { return answers }

        // The claim, before any await **and before the first early return**: one
        // attempt is owed per string, and a plan that lands mid-plan must not
        // start a second. `resolutionTask` has already claimed these keys
        // synchronously — this is the plan's own re-claim for a body that runs
        // after a cancel cleared the ledger, and it is idempotent: a key
        // another plan owns keeps its owner (review finding 4).
        claim(keys: request.items.map(\.id), by: plan.token)

        // Every way out of this plan — the end of it **and every early return**
        // a throttle, a thaw, a resume or a close takes — releases whatever of
        // **this plan's own** strings is still claimed, and nothing else. The
        // release used to go by key against the shared ledger, so a plan could
        // drop a claim a later plan had made and a string being worked on was
        // handed back to the next dispatch (review finding 4). The end-of-plan
        // release used to be the only one, so a plan that returned early kept
        // its claim for the rest of the session and no later plan could ask
        // about that string (review: a claim nobody will settle is a region
        // pending for good).
        defer { release(keys: request.items.map(\.id), by: plan.token) }

        // 0. A string the session has already answered is an answer, not an
        //    ask. The live adapter filters these itself, but the two hand-over
        //    paths cannot: a held frame's refresh hands over the whole frame
        //    again, and the prompt's retry hands back what it recorded — both
        //    of which can name a string this pipeline settled while they were
        //    waiting. Asking again would pay a second time for a scene the
        //    elder has already been shown, and (for a degradation) emit the
        //    second event that finding 3 of the review was about.
        for item in request.items where settledOutcomes[item.id] != nil {
            answers[item.id] = settledOutcomes[item.id]
        }
        let items = request.items.filter { settledOutcomes[$0.id] == nil }
        guard !items.isEmpty else { return answers }

        // 1. The clocks, in one prologue, before anything is claimed: a plan
        //    either runs and moves them or runs nothing at all. A plan that is
        //    **already cancelled** (a thaw, a resume or a close landed between
        //    the dispatch and this body) settles nothing, so it must not move
        //    the clock either: the first tick after the interruption would be
        //    paced out of the picture by a plan that never ran (review
        //    finding 11). The `defer` above still releases its claims, so the
        //    string is askable by the next plan.
        guard !Task.isCancelled, !isClosed else { return answers }
        let moment = now()
        if request.urgency == .tick {
            if let last = lastDispatchAt,
               moment.timeIntervalSince(last) < config.translationDispatchMinInterval {
                return answers
            }
            // Only a plan the dispatch clock governs moves it. A capture and an
            // elder's ask skip that clock by their urgency, and letting them
            // write it meant a held frame's every refresh — or a burst of
            // shutter presses that answered nothing new — paced the live ticks
            // out of the picture they were pacing (review: an empty capture
            // still moved the dispatch clock).
            lastDispatchAt = moment
        }
        let mayGenerateNow = maySpendAGeneration(request.urgency, at: moment)

        // The plan's own batch budget, from the ask's mode. A live tick's
        // plan is bounded by the screen and a held frame's by the strings a
        // still picture carries, so neither has ever needed a cap. A focused
        // read has one: its strings are whatever the recogniser found inside
        // the box the elder drew — a label, a line, or a whole paragraph —
        // and nothing this side of the budget bounds that. A stage the cap
        // holds **releases** its strings rather than failing them: the same
        // deferral the dispatch and brain clocks already use, so the next
        // capture (or the live tick behind it) carries them and no region is
        // settled degraded for a reason that is only "we stopped asking".
        var batchesRemaining = request.mode == .focused
            ? max(0, config.focusMaxBatchCalls)
            : Int.max
        func spendABatch() -> Bool {
            guard batchesRemaining > 0 else { return false }
            batchesRemaining -= 1
            return true
        }

        // The plan (the router): which tier leads each string, decided before
        // anything is claimed, so the batch, its order and the clocks below are
        // all fixed first.
        var onDeviceFirst: [CloudTranslationTier.Item] = []
        var cloudFirst: [CloudTranslationTier.Item] = []
        for item in items {
            switch leadingTier(for: item, mode: request.mode) {
            case .onDevice: onDeviceFirst.append(item)
            case .cloud: cloudFirst.append(item)
            }
        }

        // The strings a clock holds are released again immediately — that is
        // what makes them a deferral rather than a failure.
        let held: [CloudTranslationTier.Item] = mayGenerateNow
            ? []
            : onDeviceFirst.filter { !brainAttemptedKeys.contains($0.id) }
        release(keys: held.map(\.id), by: plan.token)

        // 2. The device leads for its class. A string the brain has already
        //    been asked about in this sighting is carried without a second
        //    payment — that generation is paid for, and the plan after the
        //    elder's answer must still reach the cloud without buying the same
        //    one twice.
        var carryOnward = onDeviceFirst.filter { brainAttemptedKeys.contains($0.id) }
        let owed = mayGenerateNow ? onDeviceFirst.filter { !brainAttemptedKeys.contains($0.id) } : []
        if !owed.isEmpty, spendABatch() {
            lastBrainAttemptAt = moment
            let stage = await askTheBrain(owed, by: plan.token, mode: plan.mode)
            guard !Task.isCancelled, !isClosed else { return answers }
            // The device tier reports no per-answer origin (the persisted cache
            // answers it in `askTheBrain`, which is a local read the histogram
            // counts as computed). Stated rather than defaulted, so the next
            // reader can see that the emptiness is a decision.
            await commit(stage.answered, to: plan, into: &answers, origins: [:])
            carryOnward += stage.unanswered
        } else {
            // Either nothing was owed (the surplus is empty and this is a
            // no-op) or the plan's budget is spent: released, unclaimed, for
            // the next plan to carry. Never settled, never failed.
            release(keys: owed.map(\.id), by: plan.token)
        }

        // 3. The class the device is not proven on leads with the gate, and
        //    whatever the gate cannot settle comes back reserved rather than
        //    degraded: that reservation is the whole reason this order is
        //    allowed.
        //
        //    **No budget arm.** The gate's own plan is the *second* stage, so
        //    in every mode the cap can bind it has already bound stage 2 — and
        //    the class is empty in `.focused`, where the cap applies, so the
        //    two conditions cannot both be true. The unreachable `else` this
        //    replaced released strings the budget could never have held back
        //    (review finding 10); what a plan does not settle is released by
        //    its own `defer` in every case.
        var reserved: [(CloudTranslationTier.Item, LiveTranslateError)] = []
        if !cloudFirst.isEmpty, spendABatch() {
            let decision = await gateDecision(for: cloudFirst,
                                              reservingFallback: true,
                                              mode: request.mode)
            guard !Task.isCancelled, !isClosed else { return answers }
            await commit(decision.terminal, to: plan, into: &answers,
                         origins: decision.origins,
                         degradationsAreTheTiersOwn: decision.degradationsAreTheTiersOwn)
            record(awaiting: decision.awaiting, in: plan)
            reserved = decision.reserved
        }

        // 4. What the cloud could not answer is the device's now — and only
        //    what has not already had its turn there. A string the device was
        //    asked about already is not asked twice: the cloud is the tier that
        //    just came back empty-handed and nothing is behind it, so the honest
        //    terminal is the cloud's own reason. Its generation is not paid for
        //    a second time, and its region does not degrade under a *cloud*
        //    reason on a tier whose device was never asked (both review of #100
        //    findings).
        if !reserved.isEmpty {
            let ids = reserved.map(\.0.id)
            noteCloudFailure(ids)
            let reasonByID = Dictionary(reserved.map { ($0.0.id, $0.1.unavailableReason) },
                                        uniquingKeysWith: { first, _ in first })
            let spent = reserved.filter { brainAttemptedKeys.contains($0.0.id) }
            let fresh = reserved.filter { !brainAttemptedKeys.contains($0.0.id) }
            await commit(spent.map { ($0.0, TranslationResult.degraded(originalText: $0.0.text,
                                                                      reason: $0.1.unavailableReason)) },
                         to: plan,
                         into: &answers,
                         origins: [:])
            if !fresh.isEmpty {
                // The generation this stage is about to cost — and this is the
                // stage that runs *because* the tier ahead of it is failing, so
                // without this it is the one that runs most — is paced by the
                // brain's clock like every other generation. The elder's own ask
                // skips that clock by its urgency, and a plan the clock holds is
                // released rather than dropped: the cloud failure is on the
                // ledger, so the next plan the clock allows asks them in stage 2
                // (review of #100: without the override an extract-mode tap
                // could strand the only block it ever gets).
                guard !Task.isCancelled, !isClosed else { return answers }
                // **No budget arm**, for stage 3's reason: this stage runs
                // only for strings the *cloud* led with and could not answer,
                // and `cloudFirst` is empty in `.focused` — the one mode a
                // budget bounds — so the cap was already satisfied by the time
                // this guard could refuse anything. The two stages that can
                // really spend in a focus (2 and 5) are the two that decrement
                // the budget (review finding 10).
                if maySpendAGeneration(request.urgency, at: now()) {
                    lastBrainAttemptAt = now()
                    let stage = await askTheBrain(fresh.map(\.0), by: plan.token, mode: plan.mode)
                    guard !Task.isCancelled, !isClosed else { return answers }
                    await commit(stage.answered, to: plan, into: &answers, origins: [:])
                    // The device had its turn — a generation was paid and did
                    // not answer — and there is no tier behind it: the cloud is
                    // the tier that just failed. The honest terminal is the
                    // cloud's own reason, written through the one terminal
                    // writer, so an outage this path degrades is an outage the
                    // evidence counts.
                    await commit(stage.unanswered.map { item in
                        (item, TranslationResult.degraded(originalText: item.text,
                                                          reason: reasonByID[item.id] ?? .noTierResolved))
                    }, to: plan, into: &answers, origins: [:])
                } else {
                    release(keys: fresh.map(\.0.id), by: plan.token)
                }
            }
        }

        // 5. Everything the plan put in front of the device-and-then-cloud, and
        //    did not answer, goes on to the gate in region order. This is the
        //    **second** of the two stages a `.focused` plan can spend at, which
        //    is what makes the cap able to bind: a budget of 1 (a narrow,
        //    device-only focus) is spent in stage 2, and the strings the gate
        //    would have asked about are released here rather than dropped.
        if !carryOnward.isEmpty, spendABatch() {
            let decision = await gateDecision(for: carryOnward,
                                              reservingFallback: false,
                                              mode: request.mode)
            guard !Task.isCancelled, !isClosed else { return answers }
            await commit(decision.terminal, to: plan, into: &answers,
                         origins: decision.origins,
                         degradationsAreTheTiersOwn: decision.degradationsAreTheTiersOwn)
            record(awaiting: decision.awaiting, in: plan)
        } else {
            // Budget spent, or nothing to carry (a no-op): the strings stay
            // pending and unclaimed for the next plan, exactly as a
            // clock-held string does.
            release(keys: carryOnward.map(\.id), by: plan.token)
        }

        // Whatever is left of the strings this plan was handed is released by
        // the `defer` installed with the claim — on this path and on every
        // early return above it.
        return answers
    }

    /// Whether a generation may be paid at `moment` for an ask of this urgency:
    /// the elder's own asks skip the clock, everything else is paced by it. One
    /// rule, asked by every stage that can spend a generation.
    private func maySpendAGeneration(_ urgency: ResolutionUrgency, at moment: Date) -> Bool {
        urgency == .explicitAsk || brainMayAttempt(at: moment)
    }

    /// The device stage: one batch, under the tier's own bound.
    ///
    /// The bound is applied here rather than left to the tier, because what is
    /// not asked must not be claimed. `LocalBrainTranslationTier` keeps the first
    /// N that fit of what it is handed and leaves the rest, so a caller that
    /// hands over more gets answers for a prefix and silence for the surplus —
    /// and a caller that pre-claimed the whole batch, as the frozen path did,
    /// recorded a generation that was never paid for and then failed the surplus
    /// with a *cloud* reason on a tier with no cloud (review of #100). The
    /// surplus is therefore a deferral: released, unclaimed, left pending for
    /// the next plan.
    ///
    /// - Returns: the answers, and the strings that were asked and did not
    ///   answer — the callers that have a tier behind the device carry those
    ///   onward. The surplus the bound deferred is released here and is in
    ///   neither list.
    private func askTheBrain(_ items: [CloudTranslationTier.Item],
                             by token: UUID,
                             mode: TranslationMode = .cascade)
        async -> (answered: [(CloudTranslationTier.Item, TranslationResult)],
                  unanswered: [CloudTranslationTier.Item]) {
        guard !items.isEmpty else { return ([], []) }

        let asked = Array(items.prefix(LocalBrainTranslationTier.batchPrefixLength(of: items.map(\.text),
                                                                                   config: config)))
        // Not asked yet, so not failed and not paid for: no claim, no outcome.
        // Released by the plan's own token, so a string another plan is holding
        // is not handed back by this one (review finding 4).
        release(keys: items.dropFirst(asked.count).map(\.id), by: token)

        // The generation is claimed before the stage, exactly as the dispatch has
        // always claimed its strings: one payment per string per sighting, and a
        // generation that timed out was still paid for. Claiming it here is what
        // stops a second plan from paying for a string whose first generation is
        // still running.
        noteBrainAttempt(asked.map(\.id))

        let outcome = await deviceAnswers(asked)
        // The cancellation contract: a thaw, a resume or a close that lands
        // mid-generation wins, and the strings go back unanswered rather than
        // onward — a cancelled plan must not walk them to the gate.
        guard !Task.isCancelled, !isClosed, let outcome else { return ([], asked) }

        var answered: [(CloudTranslationTier.Item, TranslationResult)] = []
        var unanswered: [CloudTranslationTier.Item] = []
        var resolutions: [LabelTranslationCache.Resolution] = []
        for item in asked {
            guard let translation = outcome.translations[item.text] else {
                unanswered.append(item)
                continue
            }
            resolutions.append(LabelTranslationCache.Resolution(text: item.text,
                                                                translation: translation,
                                                                tier: .onDeviceBrain))
            answered.append((item, .resolved(originalText: item.text,
                                             translation: translation,
                                             tier: .onDeviceBrain)))
        }
        // [BRAIN-CACHE] The generation is paid for; the same text seen again
        // must not pay it twice. This is the session's store, so the one path
        // that had no store — a frozen frame — repays nothing on thaw, and a
        // later cloud answer for the same text cannot overwrite the
        // attribution with `.cloud`.
        //
        // One batch, one persist (NFR-LCT-002): the per-item spelling paid a
        // full encrypt-and-atomic-write of the whole payload per string, and
        // the brain answers a whole frame's worth at once
        // (`LabelTranslationCache.storeBatch`).
        //
        // **And only when the ask's mode persists** (review finding 3). The
        // device leads before the cloud for a focused read, so this path — not
        // the gate — is the one that would write the crop into the session's
        // store; a `.focused` plan's strings stay in this run's memory cache
        // (`LiveTranslateMemoryCache`) and on no disk, which is the promise
        // `TranslationMode.cachePolicy` states once for both tiers. The store
        // is still *read* on that path (`deviceAnswers`), so a focus repays
        // nothing for what the session already knows.
        if mode.cachePolicy == .persist {
            _ = cache.storeBatch(resolutions, targetLanguage: targetLanguage)
        }
        return (answered, unanswered)
    }

    /// Records the elder's own asks (see `awaitingDecision`), and releases their
    /// claims so the plan that follows the answer can re-ask them.
    private func record(awaiting items: [CloudTranslationTier.Item],
                        in plan: PlanContext) {
        guard !items.isEmpty else { return }
        release(keys: items.map(\.id), by: plan.token)
        // A held frame is a moment, not a stream: this capture's strings are
        // added to the registry beside any earlier frame's, and beside the live
        // picture's. **Merged, not replaced** (review of #100): the old shape
        // wiped every non-live ask before recording this frame's, so an earlier
        // still whose question was still open lost its ask the moment the elder
        // captured another one — they answered the prompt and the frame they
        // had asked about was never retried, because nothing remembered it had
        // been asked. They all go back together in `retryAwaitingResolution`.
        //
        // **One field beside the request, and it is the one that is not the
        // ask's**: where the question was raised, which is the prune's rule
        // (see `PendingAsk`). The request is the plan's own, whole — its
        // destination, its mode, the frame's counts and its epoch all travel
        // with it instead of being re-derived from a hand-picked subset.
        let isLive = plan.destination == .live
        for item in items {
            awaitingDecision[item.id] = PendingAsk(request: plan.request, isLive: isLive)
        }
    }

    /// Writes one stage's terminal answers where they belong.
    ///
    /// The writing itself is `settleTerminal` — the same for a live tick, an
    /// elder's ask and a held frame, so a degradation is emitted exactly once on
    /// every path and the claim ledger cannot disagree with the outcomes. What
    /// differs is only where the answer lands: on the live regions (and then
    /// published, so the region stops being pending in the frame after it
    /// arrived) or in the map a held frame's caller is about to render.
    private func commit(_ results: [(CloudTranslationTier.Item, TranslationResult)],
                        to plan: PlanContext,
                        into answers: inout [String: TranslationResult],
                        origins: [String: LiveTranslateResolutionOrigin],
                        degradationsAreTheTiersOwn: Bool = false) async {
        let terminal = results.filter {
            if case .pending = $0.1.outcome { return false }
            return true
        }
        guard !terminal.isEmpty else { return }
        let settled = settleTerminal(terminal,
                                     regionCounts: plan.regionCounts,
                                     origins: origins,
                                     degradationsAreTheTiersOwn: degradationsAreTheTiersOwn,
                                     plan: plan)
        switch plan.destination {
        case .live:
            apply(items: terminal)
            await publish()
        case .frozen:
            for (item, result) in terminal {
                answers[item.id] = result
            }
            // A held frame's answers are a moment's, not this sighting's: a
            // live tick that reconciles while the frame is still held would
            // prune the string out of `settledOutcomes` (its key is not on
            // the live picture) and the frame's next refresh would ask for
            // it again — the answer the elder already paid for, paid for
            // again (review). Held until the frame is put down, released by
            // `discardHeldAnswers`.
            //
            // Two tests before anything is held, and both are review findings.
            // **What this plan settled**, not what it was handed: a key the
            // ledger already held was deduped by the terminal writer, and
            // holding it made this frame the owner of an answer another plan
            // wrote — which `discardHeldAnswers` then deleted out of
            // `settledOutcomes` at the thaw, destroying a live settlement and
            // re-emitting the degradation the dedup existed to prevent. And
            // **the frame this plan was made for**: a plan that lands after the
            // elder put the picture down holds nothing, so its keys cannot wait
            // for a thaw that has already happened.
            // And **this plan holds at all** (review finding 5): a focused
            // read's answers are its caller's, read out of `plan.value`, and
            // holding them stamped a frame epoch the plan is not the owner of
            // — see `ResolutionRequest.holdsAnswers`.
            guard plan.holdsAnswers, plan.frozenEpoch == heldFrameEpoch else { return }
            for id in settled {
                if let result = answers[id] { heldSettledKeys[id] = result }
            }
        }
    }

    /// [RELIABILITY-ROUTER] What one pass through the gate means for the strings
    /// it was handed — and nothing more: no outcome is written here, no claim is
    /// settled and no event is emitted. The plan commits the decision, which is
    /// what makes every path that ends a string terminally end it through the
    /// one writer.
    private struct GateDecision {
        /// The strings this stage ended, with the result.
        var terminal: [(CloudTranslationTier.Item, TranslationResult)] = []
        /// The strings the cloud could not answer and the device still can (a
        /// reserving caller only).
        var reserved: [(CloudTranslationTier.Item, LiveTranslateError)] = []
        /// The strings the elder is being asked about: no send, no failure.
        var awaiting: [CloudTranslationTier.Item] = []
        /// The tier that produced these terminal results reported its own
        /// failures — `CloudTranslationTier.reportDegradation`, once per reason,
        /// counted in the regions it covers. Set on the `.answered` branch and
        /// nowhere else, because that branch is the only one whose results came
        /// out of a `BatchResult`: a gate refusal no tier ever saw, a device
        /// ending and a held frame's degradation were written by this pipeline
        /// and are this pipeline's to report. This flag is what keeps the one
        /// outage from being counted twice, now that both layers report (review
        /// of d33089d: deleting the tier's emission instead took the evidence
        /// with it for every failure the caller never settles — the reserved
        /// ones — and left `SecurityEvidenceBoundaryTests` red).
        var degradationsAreTheTiersOwn = false
        /// Where each terminal answer came from — `.cache` for a string the
        /// tier served out of the device's own store, `.fresh` for a genuine
        /// response. Carried out of the gate because the gate is the last place
        /// the tier's own `BatchResult` exists: `TranslationResult` keeps the
        /// tier and drops the origin, and the histogram needs both (review: the
        /// settle claimed `.fresh` for every answer, so a string answered from
        /// the persisted cache was reported as one the cloud had just produced).
        var origins: [String: LiveTranslateResolutionOrigin] = [:]
    }

    /// The gate, and what its answer means.
    ///
    /// - Parameter reservingFallback: when `true`, the strings the cloud could
    ///   not translate are returned UNSETTLED — never degraded — so the caller
    ///   can still answer them on a tier that needs no switch, no consent and no
    ///   network. This is the [RELIABILITY-ROUTER] seam: the sentence class leads
    ///   with the gate, and "the household switched the cloud off", "consent was
    ///   declined", "there is no path after all" or a provider failure must leave
    ///   those strings translatable on the device rather than degraded. The
    ///   default is the shipped behaviour — settle them and say why.
    ///
    ///   Two things deliberately **do not** come back reserved: a string the
    ///   elder is being asked about (the prompt is open — answering it on the
    ///   device would answer for the elder the very question they are being
    ///   asked) and a string the tier *did* answer, even by degrading it.
    private func gateDecision(for items: [CloudTranslationTier.Item],
                              reservingFallback: Bool,
                              mode: TranslationMode = .cascade) async -> GateDecision {
        switch await attemptThroughTheGate(items, mode: mode) {
        case .awaitingDecision:
            // The prompt is on screen. The regions stay pending — not degraded,
            // because nothing has failed and the elder has not answered yet.
            return GateDecision(awaiting: items)

        case .unavailable(let error):
            // Declined, revoked, unreadable, unrecorded-and-unaskable, or the
            // household's own switch: fail closed and say so with the honest
            // reason. No request, no retry.
            guard reservingFallback else {
                // No tier ever saw these strings, so this degradation is the
                // pipeline's own and the one terminal writer emits it. The
                // shipped shape wrote it through a non-emitting settle, so the
                // evidence never learned the region had degraded (review of
                // #100).
                return GateDecision(terminal: items.map {
                    ($0, TranslationResult.degraded(originalText: $0.text,
                                                    reason: error.unavailableReason))
                })
            }
            // Nothing was sent and nothing was translated, so every one of
            // these strings is still the device's to answer. **Claimed, not
            // released** — the same shape the answered case below uses: a
            // release here would hand the strings back to the plan while this
            // one is still walking them to the device, and the next tick could
            // settle them DEGRADED at the gate before the fallback that is
            // running right now ever reported.
            return GateDecision(reserved: items.map { ($0, error) })

        case .answered(let batch):
            guard !isClosed else { return GateDecision() }
            guard reservingFallback else {
                return GateDecision(terminal: items.map { ($0, batch.result(for: $0)) },
                                    degradationsAreTheTiersOwn: true,
                                    origins: batch.origins(for: items))
            }
            // The strings the tier left unanswered, and the reason it left
            // them: every failure it reports except quarantine is a failure that
            // never reached the string, so the device can still answer it (see
            // `leavesTheStringTranslatableOnTheDevice`).
            var reserved: [(CloudTranslationTier.Item, LiveTranslateError)] = []
            for item in items {
                guard let error = batch.failures[item.id],
                      error.leavesTheStringTranslatableOnTheDevice else { continue }
                reserved.append((item, error))
            }
            // The reserved strings are settled by **nobody** here: settling them
            // would publish a degraded overlay for a string the device is about
            // to translate — a lie one frame long — and would make the region
            // terminal before its fallback had run.
            let reservedIDs = Set(reserved.map(\.0.id))
            let settled = items.filter { !reservedIDs.contains($0.id) }
            return GateDecision(terminal: settled.map { ($0, batch.result(for: $0)) },
                                reserved: reserved,
                                // The reserved strings' failures ride in the
                                // same `BatchResult`, and the tier reported
                                // them there: an outage the router works around
                                // is still an outage the evidence counts.
                                degradationsAreTheTiersOwn: true,
                                origins: batch.origins(for: settled))
        }
    }

    /// The device tier's answers for a batch, with no cycle state touched — no
    /// settlement, no outcome, no publication, and no key of the live cycle's
    /// consulted.
    ///
    /// This is the half of `askTheBrain` that the frozen path (T-033)
    /// needs and the half it must not have: a still frame owns its own
    /// outcomes and its own ordering, but the *tier* it asks — the model, the
    /// prompt, the deadline, the honest record of a timeout — is the
    /// session's one device tier. Two spellings of that stage is how a frozen
    /// frame would end up running a different model, a different deadline or
    /// no timeout record at all.
    ///
    /// `nil` is "the stage did not return within its deadline" — the caller
    /// treats it exactly as it treats an outcome with no translations.
    private func deviceAnswers(_ items: [CloudTranslationTier.Item])
        async -> LocalBrainTranslationOutcome? {
        guard !items.isEmpty else { return .none }

        let brain = self.brain
        let generation = Task { await brain.translate(items.map(\.text)) }
        let (outcome, arrival) = await Self.waiting(for: generation,
                                                    upTo: config.brainTranslationStageDeadlineSeconds)
        generation.cancel()
        guard let outcome else {
            // The wait ended with no outcome, and two arrivals end it that way.
            // The stage says *whose* it was, which is the difference between
            // "the model is too slow" (`stage_deadline`, the caller's bound, as
            // against the tier's own `deadline` — 2026-09-17: the two were
            // indistinguishable on the device) and "nobody is waiting any more"
            // (`.cancelled`: a thaw, a resume or a close stopped the wait on
            // purpose). Reporting the second as the first fabricated an
            // `inferenceTimeout` for a decode that was cancelled — an outage
            // the evidence counted and the model never had (review).
            //
            // The stage is the **arbiter's** answer, not this task's: the two
            // arms are the clock and the cancellation, and `Task.isCancelled`
            // is sticky, so a plan cancelled in the window between a real
            // deadline and this line reported the elapsed deadline as a
            // cancellation (review finding 8).
            let stage: BrainFailureStage = arrival == .cancellation ? .cancelled : .stageDeadline
            events.brainTranslationUnavailable(.inferenceTimeout, stage: stage)
            return nil
        }
        return outcome
    }

    /// Waits for a generation up to `seconds`, and answers `nil` when the clock
    /// gets there first — or when the caller is cancelled.
    ///
    /// Not a task group, and deliberately so. A group **awaits its remaining
    /// children before it returns**, cancellation or not, so racing the
    /// generation against a sleep inside one would leave the caller waiting for
    /// exactly the thing the deadline exists to stop waiting for. What is
    /// wanted here is weaker and simpler than cancellation-by-structure — stop
    /// waiting, let the loser finish into nothing — so the arrivals are raced
    /// against a continuation that only the first of them may resume.
    ///
    /// **Cancellation is one of the arrivals** (review of #100, finding C). A
    /// thaw, a resume or a close that lands while the model is decoding must end
    /// this wait, not wait out the bound: without it the cancel fired after the
    /// tier's own timeout had already elapsed, the decoder ran to its end
    /// producing an answer nobody would apply, and the next capture queued
    /// behind a freeze that was still coming.
    /// - Returns: the outcome, and which arm ended the wait. The caller needs
    ///   the second half to name the stage honestly: `nil` alone cannot say
    ///   whether the clock ran out or the session walked away (review finding
    ///   8 — the sticky cancellation flag was standing in for the arrival).
    private static func waiting(for work: Task<LocalBrainTranslationOutcome, Never>,
                                upTo seconds: TimeInterval) async -> BrainStageRace.Decision {
        // The arbiter is created **before** the cancellation handler is
        // installed, so a cancellation that has already been requested when this
        // call begins finds an object to end the wait through: a continuation
        // that does not exist yet cannot be resumed, and the wait would then
        // suspend for a caller that is already gone.
        let race = BrainStageRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.start(continuation, after: seconds, awaiting: work)
            }
        } onCancel: {
            race.finish(with: nil, arrival: .cancellation)
        }
    }
    /// [RELIABILITY-ROUTER] Resume the strings whose consent question has just
    /// been answered.
    ///
    /// The live cycle resumes by itself: a tick follows every frame, and the
    /// keys the prompt released are picked up by the next dispatch. **Extract
    /// mode has no next tick** — its whole translation path is the elder's one
    /// tap — so without this the answer to the prompt that tap raised would
    /// never reach the tiers, and the region would sit pending for the rest of
    /// the session.
    ///
    /// The strings that were interrupted are the ones the plan *recorded* when it
    /// raised the question — not the keys the stabiliser happens to be showing
    /// now. That distinction is the whole of review of #100's finding 5: a held
    /// frame's ask is raised over a still the elder has since put down, so the
    /// frozen string is not in the stabiliser at all, and a resume that rebuilt
    /// its candidates from `stabilizer.visible` dropped the frozen ask on the
    /// floor — the elder granted consent and the frame stayed untranslated.
    ///
    /// Both halves go back with `.explicitAsk`, which skips both pacing clocks
    /// exactly as a tap does: the elder has just acted, and an ask that did
    /// nothing because a background dispatch happened 0.9 s ago would be the
    /// feature failing at the one thing it does.
    ///
    /// Called for **either** answer. A refusal is not a dead end: it resolves
    /// the strings through the same plan, and the plan's device fallback is what
    /// turns "the elder said no to the cloud" into a translation rather than an
    /// unavailable region.
    func retryAwaitingResolution() async {
        guard !isClosed else { return }
        let asks = awaitingDecision
        guard !asks.isEmpty else { return }
        awaitingDecision.removeAll()

        // **The recorded asks, replayed as the asks they were** (review round
        // 2, finding 2). The registry keys these by string, so the strings one
        // plan asked about arrive here one entry at a time; they go back as the
        // *one request* they were asked in, because the prompt was raised for
        // that batch and its answer releases that batch — a dispatch per key
        // would turn a five-string question into five requests, and with the
        // explicit path's clocks skipped, nothing would space them out again.
        //
        // The batch is **read** off the recorded requests rather than rebuilt
        // from the live picture. That rebuild is where the frozen ask was lost
        // (a held frame's strings are in no stabiliser) and where a capture's
        // strings came back as a cascade's — the mode, the counts and the
        // epoch are the recorded request's and travel with it.
        var replays: [ResolutionRequest] = []
        for ask in asks.values {
            if let index = replays.firstIndex(where: { $0.isSameBatch(as: ask.request) }) {
                replays[index] = replays[index].carrying(ask.request.items)
            } else {
                replays.append(ask.request)
            }
        }

        // **The destination is the ask's own**, no longer forced onto the live
        // picture. Forcing it was the old shape's last trace of re-deriving the
        // ask: the answers of a held frame's question went onto the live
        // regions, and a focused read's went with them. What both callers
        // actually read is the ledger — `resolveFrozen` and `resolveFocused`
        // answer from `settledOutcomes` (step 0), and a live region showing the
        // same text picks the answer up through the ordinary reconcile. So a
        // capture's ask stays a capture's: its answers are not held against a
        // frame it never froze (`holdsAnswers: false`, review finding 5), and a
        // still's ask keeps the epoch it was made under, which is what holds
        // its answer for the frame that asked while that frame is still held.
        //
        // Every replay is **started before any is awaited**. The replays are
        // independent — one per recorded request — and a loop that started and
        // awaited each in turn made the second ask wait out the first's tier
        // round-trip for nothing (review round 2, finding 7). Awaiting matters
        // all the same: the caller that answered the prompt re-renders from
        // these answers the moment this returns
        // (`LiveTranslateSessionModel.refreshHeldFrame`, and the focused
        // capture's own re-pack), and a fire-and-forget dispatch here would
        // have the retry's request in flight while that render's hand-over
        // named the same strings, paying twice for one answer. The plans are
        // registered in the session's task tree, so awaiting is also what lets
        // a thaw, a resume or a close cancel them.
        var plans: [Task<[String: TranslationResult], Never>] = []
        for replayed in replays {
            // The ledger rule every hand-over keeps: a string another plan is
            // already working on is that plan's to answer, and asking it here
            // pays twice for one answer. What this drops is not lost — the
            // owning plan's answer lands in `settledOutcomes`, and the caller
            // that renders reads it there.
            let owed = replayed.items.filter { !attemptKeys.contains($0.id) }
            guard !owed.isEmpty else { continue }
            // The one field the retry owns is the urgency, and the request
            // states it itself (`replayed()`); everything else is the recorded
            // ask's, carried whole.
            plans.append(resolutionTask(replayed.replayed().restricting(to: owed)))
        }
        for plan in plans { _ = await plan.value }
    }
    /// **The** gate-then-tier sequence, with no cycle state touched: the same
    /// ordering serves the live cycle and the snapshot path (T-033), so
    /// "consent is read immediately before every attempt" and "an unanswered
    /// prompt sends nothing" cannot diverge between them.
    ///
    /// The ordering is: **the household's master switch, then consent, then
    /// the send.** The switch leads because with it off there is no attempt to
    /// gate — no prompt, no in-flight registration, no request — and because a
    /// feature that asked the elder to consent to something the household had
    /// already switched off would be asking a question it would not act on.
    /// `mode` is the ask's own, and it reaches exactly one thing here: the
    /// store policy the tier runs under. A focused read answers a question
    /// about a picture the elder pointed at — a letter, a prescription, a
    /// form — and writing those strings into the session's persisted store
    /// would put the document's contents on disk for the rest of the day
    /// because someone held a camera up to it. So the capture reads the store
    /// and writes nothing, and keeps its own answers in memory instead
    /// (`LiveTranslateMemoryCache`). Every other mode persists, exactly as it
    /// always has.
    private func attemptThroughTheGate(_ items: [CloudTranslationTier.Item],
                                       mode: TranslationMode = .cascade)
        async -> LiveTranslateCloudAttempt {
        // The master switch first, and before the gate (owner directive,
        // 2026-09-19): with it off there is no cloud need to detect, so the
        // consent prompt is never presented, no request is ever built, and the
        // honest reason is the switch itself rather than a question the elder
        // was asked and answered. **This is the one place the switch is read**,
        // which is what makes the live cycle, extract mode's tap-to-translate
        // and the snapshot path honour it by construction instead of by three
        // matching guards.
        guard geminiCloudEnabled else { return .unavailable(.cloudDisabled) }

        switch await cloudNeed.cloudNeedDetected() {
        case .awaitingDecision:
            return .awaitingDecision
        case .unavailable(let error):
            return .unavailable(error)
        case .proceed:
            // The mode's own policy, stated once (`TranslationMode.cachePolicy`)
            // so this gate and `askTheBrain` cannot disagree about whether a
            // focus writes to the store (review finding 3).
            return .answered(await tier.resolve(items: items,
                                                targetLanguage: targetLanguage,
                                                cachePolicy: mode.cachePolicy))
        }
    }

    // MARK: - The snapshot path's way in (T-033)

    /// The frozen frame's plan — now a thin adapter over `runResolution`, which
    /// is the one entry point every path that reaches a tier goes through
    /// (review of #100's mandate).
    ///
    /// What belongs to the session and is therefore the pipeline's: the router,
    /// the device tier, the gate-then-tier sequence, the claim ledger and the one
    /// terminal writer. A held frame that kept its own copy of any of that is how
    /// this path came to hand the tier a batch it had already claimed in full,
    /// fail the surplus with a cloud reason on a tier with no cloud, and never
    /// store the answers it did get. What belongs to the frame is what it hands
    /// back: one map of terminal results for the caller that is about to
    /// re-render one still picture and owns its publication.
    ///
    /// `.capture` urgency, and this is the owner's decision (2026-09-20) rather
    /// than a derivable rule: a capture is an *ask* — the elder pressed the
    /// shutter — so the dispatch clock does not pace it, and it is not a reason
    /// to skip the brain's clock either. A capture that paid a generation per
    /// press would thrash the model's load every time the elder looked at
    /// something, and a cloud outage is exactly when they press it repeatedly.
    /// The strings a held-back generation defers are released, unclaimed, so the
    /// next capture — or the live tick that follows — asks them; what has already
    /// been paid for stays paid, so a capture after a live generation carries the
    /// string to the gate instead of buying the same answer twice.
    ///
    /// - Returns: one terminal result per string the plan could answer, keyed by
    ///   item id. A key that is absent is a string the plan made no claim about
    ///   (or one whose generation the clock deferred), which the caller leaves
    ///   pending — the same honesty the live path keeps. `nil` means the caller
    ///   must apply nothing at all: the plan answered nothing for this frame (the
    ///   elder's consent question is open over every string the device did not
    ///   answer, or the session is gone). A frame the device *did* answer keeps
    ///   those answers even while the question is open — the device owes no
    ///   consent, and the answer was already paid for.
    func resolveFrozen(_ items: [CloudTranslationTier.Item],
                       regionCounts: [String: Int] = [:]) async -> [String: TranslationResult]? {
        // The cascade's seating of the one capture plan: the frame's answers
        // are held for it (`holds: true`), so the next thaw knows which keys
        // were the picture's to release.
        await resolveCaptured(items,
                              mode: .cascade,
                              regionCounts: regionCounts,
                              holds: true)
    }

    /// The focused read's way in: **the same plan**, in the mode the elder's
    /// ask put it in.
    ///
    /// Deliberately not a second plan. Everything that makes a plan correct —
    /// the claim ledger and its per-plan ownership, the clock prologue, the
    /// batch bounding with its release, the gate-then-tier ordering, the one
    /// terminal writer and its one-event-per-degradation rule — is the same
    /// whether the elder pressed the shutter, tapped a block or pointed at a
    /// region, and a second copy of any of it is where the two would start to
    /// disagree. What `mode` changes is on the plan's own terms: who leads
    /// (`leadingTier`) and how many batches may be spent (`focusMaxBatchCalls`),
    /// both stated once inside `runResolution`.
    ///
    /// The destination is `.frozen`, like the still path's: the caller is about
    /// to draw one picture of its own, owns that picture's lifetime and its
    /// publication, and a plan that wrote onto the live regions would put a
    /// crop's answers on a scene that has moved on. The urgency is `.capture`,
    /// also like the still path's — the elder acted, so the dispatch clock
    /// does not pace it, and it is not a reason to skip the brain's clock
    /// either, because a read that paid a generation per tap would thrash the
    /// model's load and a cloud outage is exactly when an elder taps
    /// repeatedly.
    ///
    /// - Returns: one terminal result per string the session can answer, keyed
    ///   by item id — this plan's own answers plus whatever the ledger already
    ///   held for the rest (review finding 6). `nil` means nothing may be
    ///   applied at all: the elder's consent question is open (it is their
    ///   question, and answering it on the device would answer for them the
    ///   very thing they are being asked), or the session is gone. A key that
    ///   is absent is a string **nobody** has answered — a generation the clock
    ///   deferred, or a batch the capture's budget did not spend — which the
    ///   caller leaves pending, the same honesty the live path keeps.
    func resolveFocused(_ items: [CloudTranslationTier.Item],
                        regionCounts: [String: Int] = [:]) async -> [String: TranslationResult]? {
        // The focused seating of the one capture plan: the mode is fixed here
        // rather than passed in (review round 2, finding 7 — every caller of
        // this entry is a focused read, and a parameter with one legal value is
        // a second place for that value to drift), and the plan **holds
        // nothing**: a focused read reads its answers straight out of
        // `plan.value`, so a plan that held them would stamp a frame epoch its
        // caller does not own, and every key whose release sits behind the thaw
        // guard would wait for a thaw that never comes (see
        // `ResolutionRequest.holdsAnswers`, and review finding 5 of the first
        // round).
        await resolveCaptured(items,
                              mode: .focused,
                              regionCounts: regionCounts,
                              holds: false)
    }

    /// The answers the session's ledger already holds for these strings, keyed
    /// by item id — **and nothing else**: no claim, no plan, no request.
    ///
    /// The re-pack's read (`LiveTranslateFocusCapture.updated`): a focused
    /// card whose strings a later plan settled — the consent replay, the live
    /// tick behind the crop — renders them without a second crop and without
    /// paying for the same answer twice (review round 2, finding 3).
    func settledAnswers(for items: [CloudTranslationTier.Item])
        async -> [String: TranslationResult] {
        answersAlreadySettled(items)
    }

    /// The one capture plan, and the whole of what a still picture and a
    /// focused crop share (review round 2, finding 7).
    ///
    /// The two public entries above are seatings of this: they name the mode
    /// (`TranslationMode` — who leads, and how many batches may be spent) and
    /// whether the plan owns its keys for a picture's lifetime (`holds`). The
    /// bodies were near-identical and had already drifted once — the focused
    /// half re-read the ledger for keys another plan had answered and the
    /// frozen half returned `nil`, which is how "everything I asked about was
    /// another plan's" came to mean "render nothing" for a held frame and
    /// "render the ledger" for a card (review finding 6 of the first round).
    /// One body means the next correction lands on both.
    ///
    /// What is identical, and is why this is one function: the claim wait (a
    /// string a live plan is working on is **that plan's** to answer, and this
    /// caller waits for it rather than paying for the same answer twice), the
    /// plan's shape (`.capture` urgency, `.frozen` destination — the caller
    /// draws its own picture and owns that picture's lifetime), the ledger
    /// re-read, and the one-terminal-writer rule the plan itself keeps.
    private func resolveCaptured(_ items: [CloudTranslationTier.Item],
                                 mode: TranslationMode,
                                 regionCounts: [String: Int],
                                 holds: Bool) async -> [String: TranslationResult]? {
        guard !isClosed, !items.isEmpty else { return nil }
        let claimed = items.filter { attemptKeys.contains($0.id) }
        if !claimed.isEmpty {
            let owners = Set(claimed.compactMap { claimOwner[$0.id] })
            for owner in owners {
                guard let task = resolutionTasks[owner] else { continue }
                _ = await task.value
            }
            guard !isClosed else { return nil }
        }
        let unclaimed = items.filter { !attemptKeys.contains($0.id) }
        var answers: [String: TranslationResult] = [:]
        if !unclaimed.isEmpty {
            // Registered in the session's task tree **and** awaited: a thaw, a
            // resume or a close must be able to stop this plan, and the caller
            // needs the answers before it draws. The claim and the plan's own
            // context are `resolutionTask`'s, so this path owns exactly the
            // keys it claimed (review finding 4 of the first round) and carries
            // the epoch of the frame it was made for (review finding 3) — the
            // epoch is the held frame's even when `holds` is false, because a
            // focused plan's keys are released by the ledger prune rather than
            // by a thaw, and `holdsAnswers: false` is what says so.
            let plan = resolutionTask(ResolutionRequest(items: unclaimed,
                                                        urgency: .capture,
                                                        destination: .frozen,
                                                        mode: mode,
                                                        regionCounts: regionCounts,
                                                        frozenEpoch: heldFrameEpoch,
                                                        holdsAnswers: holds))
            answers = await plan.value
        }
        // The strings this plan was not handed — the claims the wait above
        // resolved — are read back from the same ledger step 0 reads: an answer
        // the session already has is never left unrendered, and a key the
        // ledger has nothing for stays absent, which the caller leaves pending.
        // The same honesty the live path keeps. A caller that asked about
        // nothing but another plan's strings therefore still renders them
        // rather than nothing.
        for (key, settled) in answersAlreadySettled(items) where answers[key] == nil {
            answers[key] = settled
        }
        return answers.isEmpty ? nil : answers
    }

    /// The answers the session already holds for these strings, keyed by item
    /// id — the ledger read `runResolution`'s step 0 makes, exposed so a
    /// focused read can make it too (review finding 6). One ledger, so a
    /// focused read and a held frame cannot disagree about what the session
    /// knows.
    private func answersAlreadySettled(_ items: [CloudTranslationTier.Item])
        -> [String: TranslationResult] {
        var settled: [String: TranslationResult] = [:]
        for item in items {
            if let answer = settledOutcomes[item.id] { settled[item.id] = answer }
        }
        return settled
    }

    /// The elder put the still picture down: the frame's answers go with it.
    ///
    /// A held frame's settlements are kept out of the live prune so its own
    /// refresh cannot repay for them (see `reconcile`), which means the frame's
    /// lifetime is the thing that releases them. Called on the thaw — the one
    /// moment the picture this session was showing stops existing. The live
    /// picture is untouched: a key that is on screen now keeps its answer
    /// through the ordinary reconcile path.
    func discardHeldAnswers() async {
        // The epoch moves **first, and whatever is held** — including nothing
        // (review finding 3, "keys committed after the thaw guard"). The guard
        // this replaced returned before the epoch moved whenever no answer had
        // been held yet, which is exactly the window a frame is put down in: a
        // frozen plan still in flight (a capture against a slow tier) landed a
        // moment later, saw the epoch it was born under still current, and held
        // its answers for a picture that no longer existed — they were then
        // never released, and the live prune could not take them back either.
        // The counter is a generation marker, not a record of what is held, so
        // moving it costs nothing and closing the window is the whole point.
        heldFrameEpoch += 1
        guard !heldSettledKeys.isEmpty else { return }
        let released = heldSettledKeys
        heldSettledKeys.removeAll()
        // Only the entries this frame's plan actually settled are dropped, and
        // only while they are still the answer the ledger holds. A key a live
        // plan settled over the top of the frame's answer is that plan's, and
        // deleting it here destroyed a live settlement — and, for a degraded
        // one, left the string to be settled a second time (review finding 3).
        settledOutcomes = settledOutcomes.filter { key, result in
            guard let held = released[key] else { return true }
            return result != held
        }
    }
    /// The session's next ordering value (AM-6), for a publication this actor
    /// did not build. One counter per session: a frozen frame's publication
    /// and a live cycle's publication can never share a sequence, so a
    /// consumer that sees both sees them in the order they happened.
    func nextPublicationSequence() async -> Int {
        publicationSequence += 1
        return publicationSequence
    }

    /// Writes outcomes onto the regions whose string they belong to.
    ///
    /// `applying` is the shipped monotone transition (T-002): a text change
    /// replaces the outcome wholesale, a pending never overwrites a terminal,
    /// and otherwise the newer answer wins. One expression, one rule — this
    /// file does not decide again which result outranks which.
    private func apply(items: [(CloudTranslationTier.Item, TranslationResult)]) {
        let keys = Set(items.map(\.0.id))
        guard !keys.isEmpty else { return }
        var byKey: [String: TranslationResult] = [:]
        for (item, result) in items { byKey[item.id] = result }

        // [DISPATCH-ON-FIRST-SIGHTING] The askable set feeds the DISPATCH,
        // but `outcomes` is the publication's map and the publication must
        // carry exactly the visible regions — an answer for a region that
        // has not corroborated into `visible` lands in the string ledger
        // instead, and `reconcile` picks it up when the region appears.
        let visibleIDs = Set(stabilizer.visible.map(\.id))
        for region in stabilizer.askable where visibleIDs.contains(region.id) {
            let key = LabelTranslationCache.normalizationKey(text: region.text,
                                                             targetLanguage: targetLanguage)
            guard let result = byKey[key] else { continue }
            let current = outcomes[region.id] ?? .pending(region.text)
            outcomes[region.id] = current.applying(result.outcome)
        }
    }

    private func regionCount(forKey key: String) -> Int {
        stabilizer.visible.reduce(into: 0) { count, region in
            let regionKey = LabelTranslationCache.normalizationKey(text: region.text,
                                                                   targetLanguage: targetLanguage)
            if regionKey == key { count += 1 }
        }
    }

    /// How many regions are showing a string — and never zero.
    ///
    /// The degradation count is the evidence's unit — regions the elder can see
    /// — but a string can end terminally with no region on screen at all: a held
    /// frame's answers outlive the picture they came from, and an extract-mode
    /// tap's gate terminal lands after the block has scrolled away. A count of
    /// zero would report "nothing degraded" for the very degradation the evidence
    /// file exists to count; the honest unit is the *string*, counted once when
    /// nothing on screen is showing it, which is also what makes this the one
    /// unit both writers agree on (review of #100, finding 3).
    ///
    /// `overrides` is the picture the ask was about, when that picture is not
    /// the live one: a held frame's regions are not in the stabiliser at all,
    /// so scanning it reported 0 for a string the frame was showing twice and
    /// the floor turned that into 1 — a two-region degradation counted as one
    /// (review). An override is the frame's own count, which is the honest unit
    /// for a frame's degradation.
    private func regionCountOrOne(forKey key: String, overrides: [String: Int] = [:]) -> Int {
        if let override = overrides[key] { return max(1, override) }
        return max(1, regionCount(forKey: key))
    }

    /// Claims `keys` for one plan: the claim is owed, and it is **this plan's**
    /// to release.
    ///
    /// A key another plan already holds keeps its owner. The claim is a
    /// reference — "nobody else may ask about this string until I am done with
    /// it" — so a second plan that overwrote the owner would take over a string
    /// the first is still working on, and the first plan's release (which is
    /// what the ownership exists for) would then drop the second plan's claim
    /// (review finding 4).
    private func claim(keys: [String], by token: UUID) {
        for key in keys where claimOwner[key] == nil {
            attemptKeys.insert(key)
            claimOwner[key] = token
        }
    }

    /// Releases the keys **this plan** claimed, and only those.
    ///
    /// Deliberately not "subtract these keys from the ledger": a deferral (a
    /// clock holding a string, a batch bound leaving the surplus unasked, an ask
    /// whose question the elder is being asked) hands a string back, and it may
    /// only hand back what it is holding. A key that another plan claimed is
    /// still that plan's question, and releasing it here made the string
    /// dispatchable while the plan that owned it was still working — which is
    /// the double ask the claim ledger exists to prevent (review finding 4).
    private func release(keys: [String], by token: UUID) {
        for key in keys where claimOwner[key] == token {
            attemptKeys.remove(key)
            claimOwner[key] = nil
        }
    }

    /// **The** terminal writer: the one place a string's answer becomes the
    /// session's answer, and the one place a degradation is emitted.
    ///
    /// This replaces three helpers that each wrote a terminal outcome and each
    /// had a different idea of what to say about it — which is the whole of
    /// review of #100's findings 3, 4 and 15:
    ///
    ///  - `settle` wrote outcomes and said nothing: the right shape for a batch
    ///    the *device* answered, and the wrong one for every degradation the
    ///    gate wrote for itself, so those regions degraded silently and the
    ///    evidence never learned they had;
    ///  - `settleOrRelease` emitted, but counted `regionCount(forKey:)`, which
    ///    is 0 for a string that is not on screen — a held frame's answers or an
    ///    extract-mode tap whose block has scrolled away — so the same outage was
    ///    reported as "0 regions degraded", or as the cloud tier's own failure
    ///    count from its internal `reportDegradation`;
    ///  - `settleDegraded` emitted a second event for a batch whose tier had
    ///    *already* emitted the same outage through `reportDegradation`, counted
    ///    in the tier's unit rather than the region's.
    ///
    /// One rule from here on, and it is a rule rather than a habit because the
    /// evidence file is how "which tier failed, how often" is answered: **every
    /// terminal outcome is written here, and every degradation is emitted
    /// exactly once, counted in regions.** No other code in this pipeline emits
    /// `translationDegraded`, and the cloud tier emits it for the failures it
    /// returns and for nothing else: this writer skips exactly those
    /// (`degradationsAreTheTiersOwn`), because the tier is the layer that knows
    /// the failure class, counts the regions it covers, and keeps the record
    /// even when the caller reserves the string instead of settling it. So a
    /// degradation can be neither double-counted nor silently dropped, and the
    /// claim ledger cannot disagree with the outcomes it holds.
    ///
    /// Callers pass terminal results only — a `.pending` is not an answer the
    /// session can write, and `commit` filters it out. A string no tier answered
    /// keeps its claim for the caller's own release, so it is asked again rather
    /// than settled by a claim nobody made.
    /// - Returns: the keys this call actually wrote. The caller that holds a
    ///   held frame's answers holds **exactly these** and nothing else (review
    ///   finding 3): a key that was deduped here belongs to the plan that
    ///   settled it first, and a frame that claimed it would release another
    ///   plan's answer at its own thaw.
    @discardableResult
    private func settleTerminal(_ answered: [(CloudTranslationTier.Item, TranslationResult)],
                                regionCounts: [String: Int],
                                origins: [String: LiveTranslateResolutionOrigin],
                                degradationsAreTheTiersOwn: Bool,
                                plan: PlanContext) -> Set<String> {
        var reasons: [TranslationUnavailableReason: Int] = [:]
        var settled: [String] = []

        for (item, result) in answered {
            if case .pending = result.outcome { continue }
            // **A string is settled once, and this is what makes that true.**
            // Two plans can hold the same string at the same time — a held
            // frame's ask re-dispatched by the prompt and the live cycle's own
            // carry, say — and the second one to finish arrives here with the
            // outcome the first one already wrote. Counting it again would put
            // a second `translation_degraded` on the evidence bus for one
            // degradation, and one string degraded is one event (review of
            // #100, finding 3: the double count this pipeline used to have).
            // The claim is still released: the string has been answered, and
            // the ledger's job is to stop a *third* attempt, not this one.
            //
            // The comparison is on the **answer**, not on the whole result
            // (review finding 9). `TranslationResult` carries the region's
            // spelling of the original text, and two regions showing the same
            // string can be recognized differently ("Light" beside "LIGHT")
            // while normalizing to the one key this ledger is indexed by: an
            // equality test that included the spelling let the second region
            // settle a string the first had already settled, which counted its
            // degradation twice. The **first writer's spelling wins**, and it
            // wins deterministically because the actor serializes these calls;
            // every region still renders its own text, because that text is the
            // region's (`restating`/`applying`) and never the ledger's.
            if let existing = settledOutcomes[item.id], Self.sameAnswer(existing, result) {
                release(keys: [item.id], by: plan.token)
                continue
            }
            settledOutcomes[item.id] = result
            settled.append(item.id)
            if case .degraded(_, let reason) = result.outcome {
                reasons[reason, default: 0] += regionCountOrOne(forKey: item.id,
                                                               overrides: regionCounts)
            }
        }
        guard !settled.isEmpty else { return [] }

        // The ledger transition, in one place: a string this writer settled has
        // had its attempt answered, so its claim is released here and not by the
        // caller — and only if this plan is the one holding it (review finding
        // 4). (A string the *caller* is still working on re-claims itself by
        // settling it here; a string no tier answered is never released by this
        // function at all.)
        release(keys: settled, by: plan.token)

        // The cascade's provenance (owner ask, 2026-09-19): which tier answered
        // and where the answer came from, counts only. Emitted here so every
        // path that answers a string publishes the same histogram.
        //
        // Counted over the strings this call **settled**, not over everything it
        // was handed: a batch that arrived with an answer this writer already
        // had was deduped above, and counting it here reported the same
        // resolution twice (review: the histogram ran ahead of the dedup). The
        // origin is the answer's own — the tier's cache and the pipeline's
        // dictionary say `.cache`, a genuine response says `.fresh` — because
        // "which tier answered" without "did it ask anyone" cannot tell a
        // served-from-storage answer from a paid one (review: every settle
        // claimed `.fresh`).
        for entry in answeredTierCounts(answered, settled: Set(settled), origins: origins) {
            events.translationResolved(tier: entry.tier,
                                       origin: entry.origin,
                                       count: entry.count)
        }
        // One event per reason, in a stable order, so two runs of the same scene
        // produce the same evidence file — unless the tier that produced these
        // failures already reported them, which is the `.answered` branch and
        // only that branch (`degradationsAreTheTiersOwn`). The outcomes above
        // are still written: who reports a degradation and who writes the
        // outcome are two different jobs, and the tier can only do the first.
        guard !degradationsAreTheTiersOwn else { return Set(settled) }
        for (reason, count) in reasons.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            events.translationDegraded(reason: reason, regionCount: count)
        }
        return Set(settled)
    }

    /// Whether two results are the same **answer** for the same string,
    /// whatever the region that produced them spelled its original text as.
    ///
    /// The ledger is keyed by the normalized string, so this is the comparison
    /// its keys promise: same translation and tier, or same degradation reason.
    /// The original text is the *region's* and is deliberately not compared
    /// (review finding 9). A `.pending` never matches anything terminal.
    ///
    /// Internal rather than private so the review's own test can pin the rule
    /// itself — one spelling of a string is not a different answer from another
    /// — rather than only its effect through two racing plans.
    static func sameAnswer(_ lhs: TranslationResult,
                           _ rhs: TranslationResult) -> Bool {
        switch (lhs.outcome, rhs.outcome) {
        case (.pending, .pending):
            return true
        case (.resolved(_, let left, let leftTier), .resolved(_, let right, let rightTier)):
            return left == right && leftTier == rightTier
        case (.degraded(_, let left), .degraded(_, let right)):
            return left == right
        default:
            return false
        }
    }

    /// One histogram bucket: a tier, and whether the answer was computed or
    /// served from storage. Both are parts of the evidence's question ("which
    /// tier answered, and did anyone get paid"), so the bucket is the pair.
    private struct TierOriginBucket: Hashable {
        let tier: TranslationTier
        let origin: LiveTranslateResolutionOrigin
    }

    /// The tier histogram of one settle — one entry per (tier, origin) pair
    /// present among the strings `settled` names, in a stable order.
    private func answeredTierCounts(_ answered: [(CloudTranslationTier.Item, TranslationResult)],
                                    settled: Set<String>,
                                    origins: [String: LiveTranslateResolutionOrigin])
        -> [(tier: TranslationTier, origin: LiveTranslateResolutionOrigin, count: Int)] {
        var counts: [TierOriginBucket: Int] = [:]
        for (item, result) in answered where settled.contains(item.id) {
            if case .resolved(_, _, tier: let tier) = result.outcome {
                counts[TierOriginBucket(tier: tier, origin: origins[item.id] ?? .fresh),
                       default: 0] += 1
            }
        }
        return counts
            .sorted {
                ($0.key.tier.rawValue, $0.key.origin.rawValue)
                    < ($1.key.tier.rawValue, $1.key.origin.rawValue)
            }
            .map { (tier: $0.key.tier, origin: $0.key.origin, count: $0.value) }
    }

    private func cancelResolutionTasks() {
        for task in resolutionTasks.values { task.cancel() }
        resolutionTasks.removeAll()
        attemptKeys.removeAll()
        // The owners go with the claims: a plan whose task was just cancelled
        // has no claim to release, and a stale owner would make a later plan's
        // release a no-op (review finding 4).
        claimOwner.removeAll()
        // The attempt ledgers are claims about what has already been spent in
        // this sighting, and cancelling the tasks takes every such claim back:
        // both callers (a resume, a close) restart the scene, so the next
        // dispatch of these strings plans and pays for them from scratch.
        cloudFailedKeys.removeAll()
        awaitingDecision.removeAll()
        // The held frame's settlements are a claim like the others, and a
        // resume or a close takes it back with them: `resume` and `close` drop
        // the whole settled set a line later anyway, and holding the keys here
        // would keep a frame's answers alive past the session that framed them.
        heldSettledKeys.removeAll()
        // …and the epoch moves with them, so a frozen plan still in flight
        // cannot hold its answers against a session that has already restarted.
        heldFrameEpoch += 1
    }

    private func forget(task token: UUID) {
        resolutionTasks[token] = nil
    }

    // MARK: - Publication

    /// One publication per call, built under isolation and handed over whole.
    ///
    /// The guard is the last line of the close contract: a cancelled attempt
    /// that re-enters the actor after `close()` finds this and publishes
    /// nothing. The counter is only advanced when a publication is actually
    /// delivered, so a gap cannot appear in the stream a consumer sees.
    private func publish() async {
        guard !isClosed else { return }

        let policy = LiveTranslateOverlaySurface.policy(config: config,
                                                        alwaysShowOriginal: alwaysShowOriginal,
                                                        extractionMode: extractionMode)
        let regions = stabilizer.visible

        // The jitter gate (T-026). Decided before the counter moves, so a
        // suppressed cycle is invisible in every sense: no sequence step, no
        // value, nothing for a consumer to re-render.
        guard !isJitterOnly(regions: regions, policy: policy) else { return }

        publicationSequence += 1
        // [DISPATCH-ON-FIRST-SIGHTING] The askable set feeds the dispatch,
        // but the publication must carry exactly the visible regions — an
        // answer for a region that has not corroborated into `visible`
        // lives in the string ledger and lands through `reconcile` when it
        // appears. The filter is the one central gate every settlement
        // path flows through.
        let visibleIDs = Set(regions.map(\.id))
        let publicationOutcomes = outcomes.filter { visibleIDs.contains($0.key) }
        let publication = LiveTranslatePublication(
            sequence: publicationSequence,
            regions: regions,
            outcomes: publicationOutcomes,
            placements: place(regions: regions, policy: policy),
            policy: policy)
        lastPublished = publication
        lastPublishedLayout = layout
        lastPublishedFramePixelSize = framePixelSize
        await publishToSink(publication)
    }

    /// Whether this cycle's state differs from the last published one by
    /// nothing but box jitter — the publish epsilon, and nothing else.
    ///
    /// The answer is `true` only when **every** other input to the publication
    /// is identical: the same regions in the same order with the same ids,
    /// texts, languages and confidences; the same outcomes; the same policy;
    /// and the same container, safe area, occupied rects and frame the
    /// placements were measured from. Given all of that, the only thing a
    /// consumer could notice is where the boxes are.
    ///
    /// Two halves, both load-bearing:
    ///
    ///  - every box moved by at most `publishBoxEpsilon` on every coordinate —
    ///    a wobble nobody can see;
    ///  - at least one box actually moved. A cycle that is *identical* to the
    ///    last one is not jitter, and republishing it is the pipeline's
    ///    pre-existing behaviour; this gate exists to stop the shake, not to
    ///    re-decide what an unchanged cycle means.
    ///
    /// The comparison is against the last **delivered** publication, so a
    /// suppressed cycle does not move the baseline: a slow drift accumulates
    /// against the rects the overlay is actually drawing and publishes as soon
    /// as the difference is one the elder could see.
    ///
    /// Nothing here can re-ask a question. The translation gate is keyed by
    /// text and lives in the stabiliser, which has already consumed this
    /// pass — its events, its outcomes and the dispatch that follows are
    /// untouched by a suppression.
    private func isJitterOnly(regions: [TextRegionStabilizer.StableTextRegion],
                              policy: LiveOverlayPlacement.Policy) -> Bool {
        guard let lastPublished,
              lastPublishedLayout == layout,
              lastPublishedFramePixelSize == framePixelSize,
              lastPublished.policy == policy,
              lastPublished.outcomes == outcomes,
              lastPublished.regions.count == regions.count
        else { return false }

        var moved = false
        for (previous, next) in zip(lastPublished.regions, regions) {
            guard previous.id == next.id,
                  previous.text == next.text,
                  previous.normalizedText == next.normalizedText,
                  previous.detectedLanguage == next.detectedLanguage,
                  previous.confidence == next.confidence
            else { return false }

            let deltas = [abs(previous.box.xMin - next.box.xMin),
                          abs(previous.box.yMin - next.box.yMin),
                          abs(previous.box.xMax - next.box.xMax),
                          abs(previous.box.yMax - next.box.yMax)]
            guard deltas.allSatisfy({ $0 <= config.publishBoxEpsilon }) else { return false }
            if deltas.contains(where: { $0 > 0 }) { moved = true }
        }
        return moved
    }

    /// T-020's placement, called with T-021's policy and T-021's copy. The
    /// state sentence for a degraded region is the overlay's own
    /// (`stateCopy(for:)`), so the words on screen have one author.
    private func place(regions: [TextRegionStabilizer.StableTextRegion],
                       policy: LiveOverlayPlacement.Policy) -> [LiveOverlayPlacement.PlacedOverlay] {
        let surface = LiveTranslateOverlaySurface(placements: [], policy: policy, locale: locale)
        return LiveOverlayPlacement.place(regions: regions,
                                          results: outcomes,
                                          containerSize: layout.containerSize,
                                          framePixelSize: framePixelSize,
                                          safeArea: layout.safeArea,
                                          occupiedRects: layout.occupiedRects,
                                          crop: layout.crop,
                                          policy: policy,
                                          stateCopy: surface.stateCopy(for:))
    }
}

/// The snapshot path's view of the live cycle (T-033): the gate-then-tier
/// sequence and the session's ordering counter, both already implemented here
/// and neither of them the stabiliser's. Nothing else is exposed, so the
/// snapshot cannot reach the live cycle's state even by accident.
extension LiveTranslationPipeline: LiveTranslateLiveCycle {}

/// The arbiter of the brain stage's race: the first of the two arrivals — the
/// generation, or the clock — resumes the continuation, and the second is a
/// no-op.
///
/// A lock rather than an actor, for two reasons. The wait it arbitrates exists
/// to *end* a suspension, so an actor hop on the deadline's path would be a
/// suspension added to the machinery that bounds one; and the arrivals are two
/// unstructured tasks' tails, not two pieces of state with rules between them.
/// Resuming a continuation twice is a crash rather than a bug, which is what
/// makes this a type with one method instead of a flag two closures set. It is
/// the same tool, for the same reason, as the residency ledger's own lock.
///
/// `@unchecked Sendable` is exact here rather than a convenience: the only
/// mutable state is the continuation, and every read and write of it is inside
/// the lock.
private final class BrainStageRace: @unchecked Sendable {

    /// Which arm ended the wait. The two `nil` outcomes are not the same event —
    /// one is an outage the evidence counts, the other is the session ending its
    /// own wait — and the caller cannot tell them apart after the fact: asking
    /// `Task.isCancelled` answers "has this task ever been cancelled", which is
    /// sticky and can turn a genuine deadline into a cancellation (review
    /// finding 8). So the arm that wins records itself here.
    enum Arrival: Equatable {
        case generation
        case deadline
        case cancellation
    }

    /// One arrival: the outcome it decided (nil for the clock and the
    /// cancellation) and the arm that decided it. The arrival travels **with**
    /// the outcome through the continuation, so the caller reads the arm the
    /// wait actually ended on rather than asking a sticky flag afterwards.
    typealias Decision = (outcome: LocalBrainTranslationOutcome?, arrival: Arrival)

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Decision, Never>?
    /// The arrival that came before the wait began: `nil` is "nothing has
    /// arrived yet"; otherwise the decision, taken by whichever arm got there
    /// first (a `.generation` arrival always carries an outcome).
    private var arrivedEarly: Decision?

    /// Begins the wait: takes the continuation, and starts the two arms that
    /// have not been observed yet. Called synchronously before the suspension,
    /// so an arrival that already happened resumes `continuation` here.
    func start(_ continuation: CheckedContinuation<Decision, Never>,
               after seconds: TimeInterval,
               awaiting work: Task<LocalBrainTranslationOutcome, Never>) {
        lock.lock()
        if let decided = arrivedEarly {
            arrivedEarly = nil
            lock.unlock()
            continuation.resume(returning: decided)
            return
        }
        self.continuation = continuation
        lock.unlock()

        Task {
            let outcome = await work.value
            self.finish(with: outcome, arrival: .generation)
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            self.finish(with: nil, arrival: .deadline)
        }
    }

    func finish(with outcome: LocalBrainTranslationOutcome?, arrival: Arrival) {
        let decision: Decision = (outcome: outcome, arrival: arrival)
        lock.lock()
        let waiting = continuation
        continuation = nil
        if waiting == nil, arrivedEarly == nil { arrivedEarly = decision }
        lock.unlock()
        waiting?.resume(returning: decision)
    }
}