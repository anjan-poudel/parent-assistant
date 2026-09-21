import CoreGraphics
import CoreVideo
import Foundation

// [FOCUS-CAPTURE] The focused read: one crop, read once, translated, packed.
//
// The live picture is a scene; a focus capture is a *thing*. The elder points
// at one notice, one label, one line of a prescription and asks about that —
// and what comes back is a picture of that thing with its own translations,
// rather than a pair of boxes on a moving frame.
//
// The file's shape is deliberately the one `LiveTranslateSnapshotPath` already
// established, because the two paths are the same three steps over a different
// picture, and the second spelling of a rule is where the two start to drift:
//
//  1. **The crop is the picture.** `PointAskCrop.cropped` copies the tapped
//     box out of the frame — the shipped crop stage, not a second one — and
//     everything downstream measures against the crop's own pixel size. The
//     frame is never what is read, never what is drawn and never what is sent
//     (the crop is the only buffer that leaves this type's hands).
//  2. **One OCR pass, over the crop.** `LiveTextDetector.recognizeCrop` — the
//     shipped detector's own crop entry, which runs the one configured engine's
//     request over the buffer on the detector's one serial queue. No second
//     detector and no second request, so the strings a focused read produces
//     are the strings a pass over the same pixels would have produced.
//  3. **The same plan as every other path.** The strings go to
//     `LiveTranslationPipeline.resolveFocused`, which is the shared plan with
//     the capture urgency and the frozen destination — the same reliability
//     router, the same device tier, the same gate-then-tier sequence. Nothing
//     here reaches a tier directly, so a focused read cannot send something
//     the live path would not have sent or answer on the cloud something the
//     live path would have answered on the device.
//
// Three properties this file exists to make true:
//
//  - **The splitter runs here, in the caller.** A crop of a paragraph is
//    several sentences and the tiers are measured per *string*, so the split
//    happens before the hand-over — see `LiveTranslateSentenceSplitter` for
//    why it can never live inside a tier.
//  - **Nothing from a capture is persisted.** Every read this path makes is a
//    read-only read and every write it could reach is suppressed: the tier runs
//    with `.readOnly` (`CloudTranslationTier.CachePolicy`), the lookups on both
//    paths are told so (`persistingBookkeeping: false`), and the tier's own
//    adoption write is skipped. So the persisted layers are *read* — the
//    device's curated dictionary still answers the crop — and pointing at a
//    letter does not put its contents on disk, which is a property of every
//    write the path can reach rather than a promise about one call (review
//    round 2, finding 8). What the capture does reuse, it reuses in memory
//    (`LiveTranslateMemoryCache`), which dies with the process.
//
//    One write is still reachable and is not this path's to suppress: a
//    payload the store cannot decode is discarded by the cache itself (deleted
//    and rebuilt empty), because every later launch would otherwise pay the
//    same read fault. That removes content; it cannot add the crop's.
//  - **The result is a value.** Image, rows and placement, packed and handed
//    back — the caller owns the picture's lifetime, as the session model owns
//    a frozen frame's.

// MARK: - Seams

/// The detector's crop entry (C02), narrowed to the one call this path makes.
///
/// The same narrowing `LiveTranslateStillFrameRecognising` performs on the
/// still-frame entry, and for the same reason: a path that needs one call from
/// a type should not be able to reach the rest of it, and a test should be able
/// to script that one call without pixels. `LiveTextDetector` already
/// satisfies this as it is written.
protocol LiveTranslateCropRecognising: AnyObject {
    func recognizeCrop(_ pixelBuffer: CVPixelBuffer) async
        -> Result<[LiveTextDetector.DetectedTextRegion], LiveTranslateError>
}

extension LiveTextDetector: LiveTranslateCropRecognising {}

/// The focused cycle: the two calls the shared plan offers a capture.
///
/// A protocol of its own rather than a member added to
/// `LiveTranslateLiveCycle`: that protocol is what the still path depends on
/// and what its test doubles conform to, and widening a shipped protocol to
/// carry a second path's method would break every conformer that has no
/// interest in it. `LiveTranslationPipeline` conforms to both.
protocol LiveTranslateFocusedCycle: AnyObject {
    /// The plan, in the focused mode — the mode is fixed inside the pipeline
    /// rather than passed in (review round 2, finding 7): every caller of this
    /// entry is a focused read, and a parameter that has one legal value is a
    /// second place for that value to drift.
    func resolveFocused(_ items: [CloudTranslationTier.Item],
                        regionCounts: [String: Int]) async -> [String: TranslationResult]?
    /// The ledger read and **nothing else** — no plan, no claim, no request.
    ///
    /// The re-pack's entry (`LiveTranslateFocusCapture.updated`): the answers a
    /// later plan settled for this crop's strings, so a card whose strings the
    /// consent replay answered can render them without a second crop and
    /// without paying for the same answer twice (review round 2, finding 3).
    func settledAnswers(for items: [CloudTranslationTier.Item])
        async -> [String: TranslationResult]
    func nextPublicationSequence() async -> Int
}

extension LiveTranslationPipeline: LiveTranslateFocusedCycle {}

// MARK: - The packed result

/// One focused read, packed for the caller to render.
///
/// Image, rows and placement — the three things a surface needs and the whole
/// of what a capture produces. The placement is the publication's (the same
/// `PlacedOverlay` values the live renderer draws), so a focused read is
/// rendered by the feature's one renderer rather than by a second layout pass
/// that could disagree with it about where a box goes.
struct LiveTranslateFocusedCapture {

    /// The crop as a picture, in memory, built from the cropped buffer. Nothing
    /// writes it anywhere; the frame it came from is not retained.
    let image: CGImage

    /// The crop's own pixel size. The placements were measured against this,
    /// so a caller mapping a box back to the picture uses the picture's size
    /// and not the frame's.
    let framePixelSize: CGSize

    /// Where the crop was taken from, in the frame's own pixel coordinates —
    /// the rect the elder pointed at. Carried so a caller can map the packed
    /// result back onto the live preview without re-deriving the crop.
    let pixelRect: CGRect

    /// The crop's placements, outcomes and policy.
    let publication: LiveTranslatePublication

    /// The crop as a list to read — one row per recognized string, exactly the
    /// card a held frame builds (`LiveTranslateResultsCardSurface`), so the
    /// focused read reuses the feature's reading surface rather than defining a
    /// second one.
    let rows: [LiveTranslateResultsCardSurface.Row]

    /// The strings this crop handed to the plan that the plan did **not**
    /// answer — the batch budget released them for a later plan rather than
    /// settling them degraded (review round 2, finding 4).
    ///
    /// Keyed by item id, which is the cache key. They are *deferred*: the
    /// outcomes behind them stay `.pending` (so an answer can still land, and
    /// the next plan for these keys carries them — the live tick behind the
    /// crop, the next capture, or the interrupted ask's replay), while the card
    /// says so instead of "translating…" for as long as the picture is on
    /// screen. `updated(_:layout:policy:)` is what renders a later settlement
    /// onto this picture, and it drops each key it answers from this set.
    let deferredKeys: Set<String>

    var placements: [LiveOverlayPlacement.PlacedOverlay] { publication.placements }

    /// Whether the crop showed anything to read. A crop with no text on it is
    /// an honest empty result, not a failure.
    var isEmpty: Bool { rows.isEmpty }
}

// MARK: - The focus path

/// The focus path: crop one region, read it once, split it, resolve it, pack it.
///
/// Deliberately stateless. The capture itself is the session model's (it is the
/// single observation surface, T-026); what it needs from this type is the
/// sequence that turns a rect on a frame into a packed picture, and every step
/// of it is a function of its inputs.
struct LiveTranslateFocusCapture {

    let recogniser: LiveTranslateCropRecognising
    /// The shared plan, for the three things that must not be re-created: its
    /// gate-then-tier sequence, the capture urgency, and its ordering counter
    /// (AM-6).
    let cycle: LiveTranslateFocusedCycle
    /// The persisted layers — read, never written on this path.
    let cache: LabelTranslationCache
    /// This run's own answers, in memory only.
    let memoryCache: LiveTranslateMemoryCache
    let locale: Locale
    /// The live cycle's own default target — not a second constant
    /// (`LiveTranslationPipeline.defaultTargetLanguage`), so a focused read and
    /// the live picture cannot translate into different languages.
    let targetLanguage: AppLanguage = LiveTranslationPipeline.defaultTargetLanguage

    /// The whole path for one tapped rect: crop, raster, one OCR pass, the
    /// device layers, the plan, and the packed picture.
    ///
    /// - Returns: the packed capture, or the reason the crop could not be read.
    ///   A crop that produced no text is a **success with no rows**, not a
    ///   failure: "there is nothing written here" is an answer, and the surface
    ///   has a state for it.
    func capture(in frame: CameraFrame,
                 pixelRect: CGRect,
                 layout: LiveTranslateLayout,
                 policy: LiveOverlayPlacement.Policy)
        async -> Result<LiveTranslateFocusedCapture, LiveTranslateError> {
        // 1. The crop. Refused rather than clamped when the rect is degenerate
        //    or outside the frame — the crop stage's own rule.
        guard let crop = PointAskCrop.cropped(frame.pixelBuffer, pixelRect: pixelRect) else {
            return .failure(.ocrUnavailable(.requestCreationFailed))
        }
        // 2. The picture the elder is shown. Built from the crop, so the image
        //    and the strings describe the same pixels.
        guard let image = LiveTranslateFrozenRaster.image(from: crop) else {
            return .failure(.ocrUnavailable(.requestCreationFailed))
        }
        // 3. One pass, over the crop, through the shipped detector's own crop
        //    entry — the same engine, the same configured request.
        let detected: [LiveTextDetector.DetectedTextRegion]
        switch await recogniser.recognizeCrop(crop) {
        case .success(let regions):
            detected = regions
        case .failure(let error):
            // A pass that did not run is a failure; a pass that ran and read
            // nothing is the empty result below. The two are different answers
            // and the caller shows different things for them.
            return .failure(error)
        }

        // 4. The strings, split into the pieces the tiers are measured on. The
        //    crop is the picture, so the boxes stay crop-relative.
        let regions = Self.regions(from: detected)
        let cropSize = CGSize(width: CVPixelBufferGetWidth(crop),
                              height: CVPixelBufferGetHeight(crop))

        // 5. What the device already knows — this run's memory first, then the
        //    persisted layers — and what is left to ask.
        var outcomes = await resolveFromTheDevice(regions)
        let pendingItems = Self.items(for: regions, outcomes: outcomes,
                                      targetLanguage: targetLanguage)
        // What the plan was handed and did not answer is **deferred**, and the
        // distinction is the whole of review round 2's finding 4: the budget
        // releases a surplus string for a later plan (a batch the cap held, a
        // generation the clock deferred, a batch's prefix that did not reach
        // it), and a card that showed it as "translating…" for the rest of the
        // picture's life made a deferral look like a hang. `nil` is the other
        // thing entirely — the consent question is open, or the session is gone
        // — and nothing is deferred there: the answer is not held back, it is
        // being asked for.
        var deferred: Set<String> = []
        if !pendingItems.items.isEmpty {
            let answers = await cycle.resolveFocused(pendingItems.items,
                                                     regionCounts: pendingItems.regionCounts)
            if let answers {
                for item in pendingItems.items {
                    guard let answer = answers[item.id] else {
                        deferred.insert(item.id)
                        continue
                    }
                    for id in pendingItems.regionIDsByKey[item.id] ?? [] {
                        outcomes[id] = (outcomes[id] ?? .pending(item.text))
                            .applying(answer.outcome)
                    }
                }
            }
        }
        // 6. What this capture answered is kept **in memory only** — the same
        //    answer to the same tap a moment later costs nothing, and the
        //    session's end takes it with the process.
        await remember(outcomes: outcomes, regions: regions)

        // 7. Placed against the crop's own geometry, and packed. The placement
        //    is given the card's own copy source: a callout's supporting line
        //    and the row beneath it are one sentence for one situation, and a
        //    deferred string that said "translating…" in the box while the row
        //    under it said otherwise would be the picture disagreeing with
        //    itself.
        let surface = LiveTranslateOverlaySurface(placements: [], policy: policy, locale: locale)
        let stateCopy = copySource(deferring: deferred, from: surface)
        let publication = await placed(regions: regions,
                                       outcomes: outcomes,
                                       policy: policy,
                                       layout: layout,
                                       framePixelSize: cropSize,
                                       stateCopy: stateCopy)
        let card = LiveTranslateResultsCardSurface(publication: publication,
                                                   stateCopy: stateCopy,
                                                   emptyHint: surface.emptyHint)
        return .success(LiveTranslateFocusedCapture(image: image,
                                                    framePixelSize: cropSize,
                                                    pixelRect: pixelRect,
                                                    publication: publication,
                                                    rows: card.rows,
                                                    deferredKeys: deferred))
    }

    /// The standing capture re-read from the session's ledger — the focused
    /// read's counterpart of the held frame's refresh (review round 2,
    /// finding 3).
    ///
    /// A focused read whose strings reached the consent prompt leaves its card
    /// saying "translating…". The answers arrive on the **replay** the elder's
    /// answer triggers (`LiveTranslationPipeline.retryAwaitingResolution`),
    /// into the ledger every plan reads — and nothing rendered them onto the
    /// picture: the card stayed unanswerable, and the only way to see the
    /// answers was a second tap, which re-cropped and re-read the page to reach
    /// the same ledger, paying for the read twice.
    ///
    /// **No plan is started here.** The drive has already happened (the replay,
    /// or the live tick behind the crop); this is the render, so it makes the
    /// one ledger read and nothing else: no crop, no pass, no request and no
    /// claim. A key the ledger still has nothing for is left pending, exactly
    /// as it was.
    ///
    /// - Returns: the re-packed capture, or `nil` when the ledger moved nothing
    ///   — in which case the caller must leave the picture it already has
    ///   exactly as it is, publication sequence included.
    func updated(_ capture: LiveTranslateFocusedCapture,
                 layout: LiveTranslateLayout,
                 policy: LiveOverlayPlacement.Policy) async -> LiveTranslateFocusedCapture? {
        let regions = capture.publication.regions
        let pendingItems = Self.items(for: regions,
                                      outcomes: capture.publication.outcomes,
                                      targetLanguage: targetLanguage)
        guard !pendingItems.items.isEmpty else { return nil }
        let settled = await cycle.settledAnswers(for: pendingItems.items)
        var outcomes = capture.publication.outcomes
        var stillDeferred = capture.deferredKeys
        var moved = false
        for item in pendingItems.items {
            guard let answer = settled[item.id] else { continue }
            for id in pendingItems.regionIDsByKey[item.id] ?? [] {
                let merged = (outcomes[id] ?? .pending(item.text)).applying(answer.outcome)
                if merged != outcomes[id] { moved = true }
                outcomes[id] = merged
            }
            stillDeferred.remove(item.id)
        }
        // Nothing moved: the caller keeps the picture it has rather than a
        // re-place that would advance the session's publication counter for an
        // unchanged card.
        guard moved else { return nil }
        // The settlement is the same answer the lookup will ask for, so it is
        // kept in memory with the rest of this crop's answers.
        await remember(outcomes: outcomes, regions: regions)
        let surface = LiveTranslateOverlaySurface(placements: [], policy: policy, locale: locale)
        let stateCopy = copySource(deferring: stillDeferred, from: surface)
        let publication = await placed(regions: regions,
                                       outcomes: outcomes,
                                       policy: policy,
                                       layout: layout,
                                       framePixelSize: capture.framePixelSize,
                                       stateCopy: stateCopy)
        let card = LiveTranslateResultsCardSurface(publication: publication,
                                                   stateCopy: stateCopy,
                                                   emptyHint: surface.emptyHint)
        return LiveTranslateFocusedCapture(image: capture.image,
                                           framePixelSize: capture.framePixelSize,
                                           pixelRect: capture.pixelRect,
                                           publication: publication,
                                           rows: card.rows,
                                           deferredKeys: stillDeferred)
    }

    /// The card's state copy, with one addition: a row whose string the plan
    /// was handed and did not answer says what a deferral is instead of
    /// "translating…".
    ///
    /// The sentence is the feature's own rather than a new one — the surface's
    /// copy for a result that has no translation, "translation isn't available
    /// right now, showing the original text" — because "not available right
    /// now" is exactly true of a string the next plan will carry, and because
    /// this path may not spell a user-facing sentence of its own. The
    /// **outcome** is untouched: the publication still reads `.pending`, so
    /// nothing here settles a region that has not been answered.
    private func copySource(deferring deferred: Set<String>,
                            from surface: LiveTranslateOverlaySurface)
        -> (TranslationResult) -> String? {
        guard !deferred.isEmpty else { return surface.stateCopy(for:) }
        return { result in
            guard case .pending = result.outcome,
                  deferred.contains(LabelTranslationCache.normalizationKey(
                      text: result.text,
                      targetLanguage: self.targetLanguage)) else {
                return surface.stateCopy(for: result)
            }
            return surface.stateCopy(for: .degraded(originalText: result.text,
                                                     reason: .noTierResolved))
        }
    }

    // MARK: The device layers

    /// The on-device answer with no network at all: this run's memory cache,
    /// then the shipped persisted layers — the same read the live cycle makes,
    /// so the two cannot disagree about what the device knows.
    ///
    /// A hit is **restated onto the region's own text** before it is used: the
    /// cache is keyed by normalized text, and a result carrying another crop's
    /// original string would render that string under this crop's box.
    private func resolveFromTheDevice(_ regions: [TextRegionStabilizer.StableTextRegion])
        async -> [TextRegionStabilizer.RegionIdentity: TranslationResult] {
        var outcomes: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [:]
        for region in regions {
            let key = LabelTranslationCache.normalizationKey(text: region.text,
                                                             targetLanguage: targetLanguage)
            if let remembered = await memoryCache.lookup(key) {
                outcomes[region.id] = LiveTranslateCaptureSupport.restating(remembered,
                                                                            for: region.text)
                continue
            }
            // The read is told this path may not write (review round 2, finding
            // 8): a hit's LRU touch used to rewrite the whole encrypted payload
            // — the first read of a stored key in a session — which is a write
            // on the one path that promises the crop's contents stay in memory.
            guard case .success(let hit) = cache.lookup(text: region.text,
                                                        targetLanguage: targetLanguage,
                                                        persistingBookkeeping: false),
                  let hit else {
                outcomes[region.id] = .pending(region.text)
                continue
            }
            outcomes[region.id] = .resolved(originalText: region.text,
                                            translation: hit.translation,
                                            tier: hit.tier)
        }
        return outcomes
    }

    /// Keeps the terminal answers this capture produced, keyed the way the
    /// lookup will ask for them. Pending answers are not stored: "not answered
    /// yet" is not an answer to reuse.
    private func remember(outcomes: [TextRegionStabilizer.RegionIdentity: TranslationResult],
                          regions: [TextRegionStabilizer.StableTextRegion]) async {
        for region in regions {
            guard let result = outcomes[region.id], result.isFinal else { continue }
            let key = LabelTranslationCache.normalizationKey(text: region.text,
                                                             targetLanguage: targetLanguage)
            await memoryCache.store(result, forKey: key)
        }
    }

    // MARK: Placement

    /// The feature's one placement, called with the feature's one policy and
    /// the feature's one copy source. The geometry is the **crop's**: a focused
    /// read is the picture that was cropped, so its boxes are whole-frame boxes
    /// on that picture and its rects are measured through `.whole`. The live
    /// window is dropped here deliberately, exactly as the still path drops it:
    /// the pan and the zoom are live gestures, and the crop the elder took must
    /// not slide when they move.
    private func placed(regions: [TextRegionStabilizer.StableTextRegion],
                        outcomes: [TextRegionStabilizer.RegionIdentity: TranslationResult],
                        policy: LiveOverlayPlacement.Policy,
                        layout: LiveTranslateLayout,
                        framePixelSize: CGSize,
                        stateCopy: ((TranslationResult) -> String?)? = nil)
        async -> LiveTranslatePublication {
        let placements = LiveTranslateCaptureSupport.placements(regions: regions,
                                                                outcomes: outcomes,
                                                                policy: policy,
                                                                layout: layout,
                                                                framePixelSize: framePixelSize,
                                                                locale: locale,
                                                                stateCopy: stateCopy)
        let sequence = await cycle.nextPublicationSequence()
        return LiveTranslatePublication(sequence: sequence,
                                        regions: regions,
                                        outcomes: outcomes,
                                        placements: placements,
                                        policy: policy)
    }

    /// Re-measures a packed capture under a new policy and the current
    /// geometry — the placement call and nothing else (review finding 12).
    ///
    /// No crop, no raster, no OCR pass, no cache read and no request: the
    /// strings are already read and already answered, so the only thing a
    /// display preference can change is *where they are drawn*. The same rule
    /// the held frame's re-measure keeps (T-033), for the same reason — a
    /// preference that appears to stop working the moment there is a picture to
    /// look at is a lie about a display setting — and it is what keeps the
    /// focused read and the still path behaving identically for the FR-LCT-017
    /// toggle.
    ///
    /// The capture's **rows** are rebuilt with the publication: the card is
    /// drawn from them, and a re-placed callout with a stale row would render
    /// the old placement's text state beside the new geometry.
    ///
    /// The frame's own answers, image and rect are untouched: this is one
    /// picture re-measured, not a second read.
    func rePlaced(_ capture: LiveTranslateFocusedCapture,
                  layout: LiveTranslateLayout,
                  policy: LiveOverlayPlacement.Policy) async -> LiveTranslateFocusedCapture {
        let surface = LiveTranslateOverlaySurface(placements: [], policy: policy, locale: locale)
        let stateCopy = copySource(deferring: capture.deferredKeys, from: surface)
        let publication = await placed(regions: capture.publication.regions,
                                       outcomes: capture.publication.outcomes,
                                       policy: policy,
                                       layout: layout,
                                       framePixelSize: capture.framePixelSize,
                                       stateCopy: stateCopy)
        let card = LiveTranslateResultsCardSurface(publication: publication,
                                                   stateCopy: stateCopy,
                                                   emptyHint: surface.emptyHint)
        return LiveTranslateFocusedCapture(image: capture.image,
                                           framePixelSize: capture.framePixelSize,
                                           pixelRect: capture.pixelRect,
                                           publication: publication,
                                           rows: card.rows,
                                           deferredKeys: capture.deferredKeys)
    }

    // MARK: The strings

    /// The crop's detected strings, split into sentences and minted as the
    /// regions the placement and the renderer consume.
    ///
    /// **One region per sentence.** A crop of a paragraph is several sentences
    /// and each is its own string to the tiers, the cache and the evidence —
    /// asking a tier about the whole paragraph is asking it about a string
    /// nobody measured it on. The pieces inherit their parent's geometry: a
    /// sentence read from a box is read from that box, so the translations
    /// still land on the thing they came from.
    ///
    /// A detected string that the splitter leaves whole yields exactly one
    /// region, so the common case — a sign, a label — is unchanged.
    private static func regions(from detected: [LiveTextDetector.DetectedTextRegion])
        -> [TextRegionStabilizer.StableTextRegion] {
        var regions: [TextRegionStabilizer.StableTextRegion] = []
        var identity = 0
        for region in detected {
            let pieces = LiveTranslateSentenceSplitter.sentences(in: region.text)
            // A string the splitter could not read at all is still a string
            // the recogniser saw: it is kept whole rather than dropped.
            for piece in (pieces.isEmpty ? [region.text] : pieces) {
                regions.append(LiveTranslateCaptureSupport.region(id: identity,
                                                                  from: region,
                                                                  text: piece))
                identity += 1
            }
        }
        return regions
    }

    /// The strings still to ask about, in region order, deduped by cache key —
    /// two sentences that normalize the same are one ask (AM-8), and the
    /// multiplicities travel with the ask so a degradation covers the regions
    /// that showed the string and not just the first one (the live scanner
    /// cannot count a crop's regions; this is that count).
    private static func items(for regions: [TextRegionStabilizer.StableTextRegion],
                              outcomes: [TextRegionStabilizer.RegionIdentity: TranslationResult],
                              targetLanguage: AppLanguage)
        -> (items: [CloudTranslationTier.Item], regionCounts: [String: Int],
            regionIDsByKey: [String: [TextRegionStabilizer.RegionIdentity]]) {
        var orderedKeys: [String] = []
        var itemsByKey: [String: CloudTranslationTier.Item] = [:]
        var regionIDsByKey: [String: [TextRegionStabilizer.RegionIdentity]] = [:]
        for region in regions {
            guard case .pending? = outcomes[region.id]?.outcome else { continue }
            let key = LabelTranslationCache.normalizationKey(text: region.text,
                                                             targetLanguage: targetLanguage)
            regionIDsByKey[key, default: []].append(region.id)
            if itemsByKey[key] == nil {
                orderedKeys.append(key)
                itemsByKey[key] = CloudTranslationTier.Item(id: key,
                                                            text: region.text,
                                                            detectedSourceLanguage: region.detectedLanguage)
            }
        }
        let items = orderedKeys.compactMap { itemsByKey[$0] }
        let counts = regionIDsByKey.mapValues(\.count)
        return (items, counts, regionIDsByKey)
    }
}
