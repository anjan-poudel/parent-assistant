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
    /// No send at all: the honest reason the tier is unavailable (declined,
    /// revoked, unreadable, unrecorded-and-unaskable).
    case unavailable(LiveTranslateError)
    /// The tier answered every item it was handed.
    case answered(CloudTranslationTier.BatchResult)
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
    /// One attempt through the gate and the tier. `nil` means nothing was
    /// attempted (the session is closed, or there was nothing to ask).
    func attemptResolution(_ items: [CloudTranslationTier.Item]) async -> LiveTranslateCloudAttempt?
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
    /// and AM-6 puts every *ordering* decision on a counter — but a departure
    /// has to be bounded in the unit the elder experiences it in, which is
    /// seconds, so exactly one rule reads this: the stabiliser's departure
    /// grace. Production passes `Date.init`; a test that asserts the grace
    /// passes its own clock and never waits on the wall.
    private let now: () -> Date

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
    /// Normalized keys currently dispatched to the cloud tier. Cleared when
    /// the attempt reports back, so a key is never requested twice at once
    /// (the tier's own claim step is the second half of that guarantee).
    private var attemptKeys: Set<String> = []
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
    /// The session-scoped task tree: one entry per dispatched attempt, removed
    /// by the attempt itself when it finishes, so this stays bounded by the
    /// number of in-flight requests rather than by the session's length.
    private var resolutionTasks: [UUID: Task<Void, Never>] = [:]

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
        dispatchResolutionNeeds(only: key)
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
        for region in stabilizer.visible {
            let key = Self.cacheKey(for: region.text, targetLanguage: targetLanguage)
            visibleKeys.insert(key)
            if let existing = outcomes[region.id], existing.isFinal, existing.originalText == region.text {
                next[region.id] = existing
            } else if let settled = settledOutcomes[key] {
                next[region.id] = Self.restating(settled, for: region.text)
            } else {
                next[region.id] = .pending(region.text)
            }
        }
        settledOutcomes = settledOutcomes.filter { visibleKeys.contains($0.key) }
        brainAttemptedKeys = Set(brainAttemptedKeys.filter { visibleKeys.contains($0) })
        outcomes = next
    }

    /// The key a string is asked about under: the cache's own normalization
    /// (`LabelTranslationCache.normalizationKey`), stated once so the device
    /// lookup, the attempt registry, the settled set and extract mode's
    /// one-region dispatch cannot disagree about what "the same question" is.
    private static func cacheKey(for text: String, targetLanguage: AppLanguage) -> String {
        LabelTranslationCache.normalizationKey(text: text, targetLanguage: targetLanguage)
    }

    /// The stored answer, restated for the text a region is showing now.
    ///
    /// The translation is a property of the *string*; the original text is a
    /// property of the *region*. The two can differ in spelling while
    /// normalizing identically ("Light" recognized again as "LIGHT"), and a
    /// result carrying the previous spelling would put the wrong original on
    /// screen beside the translation — so the answer is carried over and the
    /// text is the region's own.
    ///
    /// A stored entry is terminal by construction, so the pending branch is
    /// unreachable; it is here because "every case is answered" is the shape
    /// this function promises and a future caller may not be so lucky.
    private static func restating(_ result: TranslationResult, for text: String) -> TranslationResult {
        switch result.outcome {
        case .pending:
            return .pending(text)
        case .resolved(_, let translation, let tier):
            return .resolved(originalText: text, translation: translation, tier: tier)
        case .degraded(_, let reason):
            return .degraded(originalText: text, reason: reason)
        }
    }

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
            outcomes[region.id] = .resolved(originalText: region.text,
                                            translation: hit.translation,
                                            tier: hit.tier)
            events.translationResolved(tier: hit.tier, origin: .cache, count: 1)
        }
    }

    /// Hands every still-pending string to the on-device brain first and the
    /// cloud second — one session-scoped task, never awaited by the tick.
    ///
    /// The order is the cascade (FR-LCT-008 as amended 2026-09-17): the
    /// dictionary has already answered what it can (`resolveFromTheDevice`),
    /// the brain is asked next, and only what it did not answer reaches the
    /// consent gate and the cloud. The gate therefore sees the *remainder*,
    /// which is what keeps a scene the device can answer from ever presenting
    /// the elder with a consent prompt (FR-LCT-011, FR-LCT-020).
    ///
    /// Region order, not dictionary order: the batch the brain receives is
    /// built by walking the visible regions, so the same scene produces the
    /// same batch and the first-N bound is deterministic.
    ///
    /// The two claims are not the same claim. `attemptKeys` is "an attempt is
    /// owed for this string" and is released when the gate asks for a decision;
    /// `brainAttemptedKeys` is "a generation has already been paid for this
    /// string in this sighting" and is not, because the brain is a generation
    /// rather than a lookup and a tick that re-asked it would turn one answer
    /// into one generation per frame. The two are therefore applied separately:
    /// a string the brain has already been asked about is carried straight to
    /// the gate, so the tick that follows the elder's answer reaches the cloud
    /// without paying for the same generation twice.
    /// `only` narrows the hand-over to one string's key — extract mode's
    /// tap-to-translate, which must not become a dispatch for the whole scene.
    /// `nil` is every pending region, which is the mode-off behaviour the
    /// cycle has always had.
    private func dispatchResolutionNeeds(only onlyKey: String? = nil) {
        var items: [CloudTranslationTier.Item] = []
        var claimed: Set<String> = []
        for region in stabilizer.visible {
            guard let existing = outcomes[region.id], case .pending = existing.outcome else { continue }
            let key = Self.cacheKey(for: region.text, targetLanguage: targetLanguage)
            if let onlyKey, key != onlyKey { continue }
            guard claimed.insert(key).inserted else { continue }
            guard settledOutcomes[key] == nil,
                  !attemptKeys.contains(key) else { continue }
            items.append(CloudTranslationTier.Item(id: key,
                                                   text: region.text,
                                                   detectedSourceLanguage: region.detectedLanguage))
        }
        guard !items.isEmpty else { return }

        attemptKeys.formUnion(items.map(\.id))
        let unanswered = items.filter { !brainAttemptedKeys.contains($0.id) }
        brainAttemptedKeys.formUnion(unanswered.map(\.id))
        let fresh = Set(unanswered.map(\.id))

        let token = UUID()
        resolutionTasks[token] = Task { [weak self] in
            guard let self else { return }
            let remainder = await self.resolveThroughTheBrain(unanswered)
            let stillUnresolved = Set(remainder.map(\.id))
            // Everything the brain did not answer goes on to the gate, in
            // region order: the strings it answered are settled and drop out,
            // and the ones it was not asked about this time — the elder has
            // just answered the prompt for them — are carried through.
            let onward = items.filter { !fresh.contains($0.id) || stillUnresolved.contains($0.id) }
            if !onward.isEmpty {
                await self.resolveThroughTheGate(onward)
            }
            await self.forget(task: token)
        }
    }

    /// Tier 1: the on-device brain, before anything leaves the device.
    ///
    /// Returns the items the brain did not answer, in the order it was handed
    /// them — the caller sends exactly those to the gate, so a string the
    /// brain answered never reaches the cloud and a string it did not is never
    /// dropped (FR-LCT-008's cascade). Nothing here is consent-gated: no
    /// request, no egress, no budget — the brain is the device's own, which is
    /// why the gate is consulted *after* this stage and not before it.
    ///
    /// A brain answer is settled and published immediately, so the region
    /// stops being pending in the cycle the answer arrives rather than waiting
    /// for a tier that has not been asked yet. The answer is attributed to
    /// `.onDeviceBrain`: it is neither curated nor cloud, and saying otherwise
    /// would either misreport egress or let unvetted model output take the
    /// in-place form only the curated tier may take (FR-LCT-015).
    ///
    /// Nothing to ask is not an attempt: an empty hand-over asks the brain for
    /// nothing at all, rather than for everything and nothing.
    ///
    /// The stage is waited on under the pipeline's own deadline
    /// (`brainTranslationStageDeadlineSeconds`), and the reason is the caller's
    /// whole contract: this method's return value is what the gate is handed.
    /// A stage that never returned would keep its strings claimed, every later
    /// tick would skip them as already dispatched, and the region would hold on
    /// the pending copy for the rest of the session. The deadline makes "did
    /// not answer" and "did not return" the same thing: the strings go onward.
    private func resolveThroughTheBrain(_ items: [CloudTranslationTier.Item]) async -> [CloudTranslationTier.Item] {
        guard !items.isEmpty else { return [] }

        let brain = self.brain
        let generation = Task { await brain.translate(items.map(\.text)) }
        let outcome = await Self.waiting(for: generation,
                                         upTo: config.brainTranslationStageDeadlineSeconds)
        generation.cancel()

        guard let outcome else {
            // The clock won. The tier is not being waited on any more — it has
            // not come back to report anything — and a stage that falls
            // through to the cloud without a record is exactly the silent
            // degradation this feature must not have. The reason is the
            // timeout token, which is what happened; the stage says *whose*
            // timeout it was (`stage_deadline`, the caller's, as against the
            // tier's own `deadline`), which is the difference between "the
            // model is too slow" and "the tier never got to its own bound"
            // (2026-09-17: the two were indistinguishable on the device and
            // the tier reported the second as `inference_failed`).
            events.brainTranslationUnavailable(.inferenceTimeout, stage: .stageDeadline)
            return items
        }

        // The cancellation contract: a close that lands mid-generation wins.
        // The keys were released by `cancelResolutionTasks`, so nothing is left
        // claimed by this attempt.
        guard !isClosed else { return [] }
        guard !outcome.translations.isEmpty else { return items }

        var answered: [(CloudTranslationTier.Item, TranslationResult)] = []
        var remainder: [CloudTranslationTier.Item] = []
        for item in items {
            if let translation = outcome.translations[item.text] {
                answered.append((item, .resolved(originalText: item.text,
                                                 translation: translation,
                                                 tier: .onDeviceBrain)))
            } else {
                remainder.append(item)
            }
        }

        settle(answered)
        apply(items: answered)
        await publish()
        return remainder
    }

    /// Waits for a generation up to `seconds`, and answers `nil` when the clock
    /// gets there first.
    ///
    /// Not a task group, and deliberately so. A group **awaits its remaining
    /// children before it returns**, cancellation or not, so racing the
    /// generation against a sleep inside one would leave the caller waiting for
    /// exactly the thing the deadline exists to stop waiting for. What is
    /// wanted here is weaker and simpler than cancellation — stop waiting, let
    /// the loser finish into nothing — so the two arrivals are raced against a
    /// continuation that only the first of them may resume.
    private static func waiting(for work: Task<LocalBrainTranslationOutcome, Never>,
                                upTo seconds: TimeInterval) async -> LocalBrainTranslationOutcome? {
        await withCheckedContinuation { continuation in
            let race = BrainStageRace(continuation)
            Task {
                let outcome = await work.value
                race.finish(with: outcome)
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                race.finish(with: nil)
            }
        }
    }

    /// One attempt, in the order AM-1 and FR-LCT-011 fix: the gate decides
    /// first, and the tier is consulted only when the answer allows a send.
    ///
    /// The sequence itself is `attemptThroughTheGate`, which the snapshot path
    /// (T-033) calls too. What is here is only what *this* cycle does with its
    /// answer: the settled set, the outcomes and the publication.
    private func resolveThroughTheGate(_ items: [CloudTranslationTier.Item]) async {
        switch await attemptThroughTheGate(items) {
        case .awaitingDecision:
            // The prompt is on screen. The regions stay pending — not degraded,
            // because nothing has failed and the elder has not answered yet —
            // and the keys are released so the next tick, after the answer,
            // attempts them again.
            release(keys: items.map(\.id))

        case .unavailable(let error):
            // Declined, revoked, unreadable or unrecorded-and-unaskable: fail
            // closed and say so with the honest reason. No request, no retry.
            let answered = items.map { item in
                (item, TranslationResult.degraded(originalText: item.text,
                                                  reason: error.unavailableReason))
            }
            settle(answered)
            apply(items: answered)
            await publish()

        case .answered(let batch):
            guard !isClosed else { return }
            settleOrRelease(items: items, batch: batch)
            apply(items: items.map { ($0, batch.result(for: $0)) })
            await publish()
        }
    }

    /// **The** gate-then-tier sequence, with no cycle state touched: the same
    /// ordering serves the live cycle and the snapshot path (T-033), so
    /// "consent is read immediately before every attempt" and "an unanswered
    /// prompt sends nothing" cannot diverge between them.
    private func attemptThroughTheGate(_ items: [CloudTranslationTier.Item]) async -> LiveTranslateCloudAttempt {
        switch await cloudNeed.cloudNeedDetected() {
        case .awaitingDecision:
            return .awaitingDecision
        case .unavailable(let error):
            return .unavailable(error)
        case .proceed:
            return .answered(await tier.resolve(items: items, targetLanguage: targetLanguage))
        }
    }

    // MARK: - The snapshot path's way in (T-033)

    /// One attempt through the same gate and the same tier, for a caller that
    /// owns its own state — the frozen frame. Nothing here reads or writes the
    /// cycle: the stabiliser is not consulted, no outcome is recorded, no key
    /// is settled and no live publication is made.
    func attemptResolution(_ items: [CloudTranslationTier.Item]) async -> LiveTranslateCloudAttempt? {
        guard !isClosed, !items.isEmpty else { return nil }
        return await attemptThroughTheGate(items)
    }

    /// The session's next ordering value (AM-6), for a publication this actor
    /// did not build. One counter per session: a frozen frame's publication
    /// and a live cycle's publication can never share a sequence, so a
    /// consumer that sees both sees them in the order they happened.
    func nextPublicationSequence() async -> Int {
        publicationSequence += 1
        return publicationSequence
    }

    /// Records the tier's answers against the regions that asked.
    ///
    /// The tier answers every item it is handed (there is no pending case in a
    /// `BatchResult`), but the merge is written so that "no answer" is still
    /// honest: a key the tier made no claim about stays pending and stays
    /// attemptable, so it is re-tried on a later tick rather than being
    /// silently dropped.
    private func settleOrRelease(items: [CloudTranslationTier.Item],
                                 batch: CloudTranslationTier.BatchResult) {
        var unresolved: [String] = []
        var degradedReasons: [TranslationUnavailableReason: Int] = [:]

        for item in items {
            let result = batch.result(for: item)
            switch result.outcome {
            case .pending:
                unresolved.append(item.id)
            case .resolved:
                settledOutcomes[item.id] = result
            case .degraded(_, let reason):
                settledOutcomes[item.id] = result
                degradedReasons[reason, default: 0] += regionCount(forKey: item.id)
            }
        }

        attemptKeys.subtract(items.map(\.id))
        attemptKeys.formUnion(unresolved)

        for (reason, count) in degradedReasons.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            events.translationDegraded(reason: reason, regionCount: count)
        }
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

        for region in stabilizer.visible {
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

    private func release(keys: [String]) {
        attemptKeys.subtract(keys)
    }

    /// Records a terminal answer against the strings it answers, so a region
    /// that later claims one of those strings inherits it instead of asking
    /// again.
    private func settle(_ answered: [(CloudTranslationTier.Item, TranslationResult)]) {
        attemptKeys.subtract(answered.map(\.0.id))
        for (item, result) in answered { settledOutcomes[item.id] = result }
        // The cascade's provenance (owner ask, 2026-09-19): which tier
        // answered, per tier, counts only.
        for (tier, count) in answeredTierCounts(answered) {
            events.translationResolved(tier: tier, origin: .fresh, count: count)
        }
    }

    /// The tier histogram of one settle — one entry per tier present.
    private func answeredTierCounts(_ answered: [(CloudTranslationTier.Item, TranslationResult)])
        -> [(TranslationTier, Int)] {
        var counts: [TranslationTier: Int] = [:]
        for (_, result) in answered {
            if case .resolved(_, _, tier: let tier) = result.outcome {
                counts[tier, default: 0] += 1
            }
        }
        return counts.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    private func cancelResolutionTasks() {
        for task in resolutionTasks.values { task.cancel() }
        resolutionTasks.removeAll()
        attemptKeys.removeAll()
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
        let publication = LiveTranslatePublication(
            sequence: publicationSequence,
            regions: regions,
            outcomes: outcomes,
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

    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalBrainTranslationOutcome?, Never>?

    init(_ continuation: CheckedContinuation<LocalBrainTranslationOutcome?, Never>) {
        self.continuation = continuation
    }

    func finish(with outcome: LocalBrainTranslationOutcome?) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: outcome)
    }
}
