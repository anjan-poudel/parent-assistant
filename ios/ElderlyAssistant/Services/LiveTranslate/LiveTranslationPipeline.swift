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
//      Vision pass cannot build a backlog. The cloud resolution is *not* under
//      that flag: it is a session-scoped task, so the OCR cadence continues
//      while a request is in flight, and the next tick is the retry.
//
//   4. **Ordering is a monotone counter, never a clock (AM-6).** Each
//      publication carries `sequence`, incremented in memory under actor
//      isolation. Two same-millisecond cycles cannot invert, and no consumer
//      anywhere needs to look at a time. The counter starts at 1, so 0 means
//      "nothing has been published".
//
//   5. **One terminal outcome per region per cycle (AM-8, CL-1).** An outcome
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
//   6. **A component failure degrades one region, not the session.** Every
//      path in this file ends in a rendered state: resolved, degraded with the
//      original text, or the empty-state hint. There is no `return` that
//      leaves a region unaccounted for, and no failure of the detector, the
//      cache or the cloud layer can stop the next cycle from publishing.
//
//   7. **Closing is structural cancellation.** One session-scoped task tree;
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
    private let tier: CloudTranslationTier
    private let cloudNeed: LiveTranslateCloudNeedDeciding
    private weak var backpressure: LiveTranslateBackpressure?
    private let events: LiveTranslateEvents
    private let publishToSink: PublicationSink

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

    private var isPaused = false
    private var isClosed = false
    private var cycleInFlight = false

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
         config: LiveTranslateConfig = .default,
         observabilityBus: ObservabilityBus,
         publish: @escaping PublicationSink) {
        self.locale = locale
        self.targetLanguage = targetLanguage
        self.recogniser = recogniser
        self.cache = cache
        self.tier = tier
        self.cloudNeed = cloudNeed
        self.backpressure = backpressure
        self.alwaysShowOriginal = alwaysShowOriginal
        self.config = config
        self.events = LiveTranslateEvents(bus: observabilityBus, config: config)
        self.publishToSink = publish
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
            record(stabilizer.consume(regions: result.regions, tracked: result.trackedBoxes))
            reconcile()
            resolveFromTheDevice()
            await publish()
            dispatchCloudNeeds()
        }
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
        stabilizer.reset()
        outcomes.removeAll()

        await publish()
    }

    /// The backgrounding half. Nothing is published while paused and no frame
    /// is processed (T-027's lifecycle): frames cannot even arrive, because the
    /// camera session pauses itself on the same notification.
    func pause() {
        guard !isClosed else { return }
        isPaused = true
    }

    /// The session's close. Cancels the task tree, releases recognition and
    /// drops every outcome, so nothing this actor owns can publish or call back
    /// afterwards.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        backpressure?.ocrPassInFlight = false
        cancelResolutionTasks()
        recogniser.end()
        stabilizer.reset()
        outcomes.removeAll()
        settledOutcomes.removeAll()
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

    // MARK: - The cycle

    /// Change events are content-free (a region identity and nothing else), so
    /// recording them cannot leak a string. The single `text_change` carries
    /// the visible-region count, which is the shape the elder's screen has.
    private func record(_ changes: [TextRegionStabilizer.RegionChangeEvent]) {
        guard !changes.isEmpty else { return }
        for change in changes {
            switch change {
            case .appeared: events.regionAppeared()
            case .textChanged: break
            case .disappeared: events.regionRemoved()
            }
        }
        events.textChange(regionCount: stabilizer.visible.count)
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
            let key = LabelTranslationCache.normalizationKey(text: region.text,
                                                             targetLanguage: targetLanguage)
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
        outcomes = next
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
    private func resolveFromTheDevice() {
        for region in stabilizer.visible {
            guard let existing = outcomes[region.id], case .pending = existing.outcome else { continue }
            guard case .success(let hit) = cache.lookup(text: region.text,
                                                        targetLanguage: targetLanguage),
                  let hit else { continue }
            outcomes[region.id] = .resolved(originalText: region.text,
                                            translation: hit.translation,
                                            tier: hit.tier)
        }
    }

    /// Hands every still-pending string to the cloud tier — through the gate,
    /// one session-scoped task, never awaited by the tick.
    private func dispatchCloudNeeds() {
        var items: [String: CloudTranslationTier.Item] = [:]
        for region in stabilizer.visible {
            guard let existing = outcomes[region.id], case .pending = existing.outcome else { continue }
            let key = LabelTranslationCache.normalizationKey(text: region.text,
                                                             targetLanguage: targetLanguage)
            guard settledOutcomes[key] == nil, !attemptKeys.contains(key) else { continue }
            items[key] = CloudTranslationTier.Item(id: key,
                                                   text: region.text,
                                                   detectedSourceLanguage: region.detectedLanguage)
        }
        guard !items.isEmpty else { return }

        attemptKeys.formUnion(items.keys)
        let dispatched = Array(items.values)
        let token = UUID()
        resolutionTasks[token] = Task { [weak self] in
            guard let self else { return }
            await self.resolveThroughTheGate(dispatched)
            await self.forget(task: token)
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
                                                        alwaysShowOriginal: alwaysShowOriginal)
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
                                          policy: policy,
                                          stateCopy: surface.stateCopy(for:))
    }
}

/// The snapshot path's view of the live cycle (T-033): the gate-then-tier
/// sequence and the session's ordering counter, both already implemented here
/// and neither of them the stabiliser's. Nothing else is exposed, so the
/// snapshot cannot reach the live cycle's state even by accident.
extension LiveTranslationPipeline: LiveTranslateLiveCycle {}
