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
//  - **Nothing from a capture is persisted.** The tier runs with
//    `.readOnly` (`CloudTranslationTier.CachePolicy`): the persisted layers are
//    *read* — the device's curated dictionary still answers the crop — and the
//    translation is not written back, so pointing at a letter does not put its
//    contents on disk. What the capture does reuse, it reuses in memory
//    (`LiveTranslateMemoryCache`), which dies with the process.
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
    func resolveFocused(_ items: [CloudTranslationTier.Item],
                        mode: TranslationMode,
                        regionCounts: [String: Int]) async -> [String: TranslationResult]?
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
        if !pendingItems.items.isEmpty {
            let answers = await cycle.resolveFocused(pendingItems.items,
                                                     mode: .focused,
                                                     regionCounts: pendingItems.regionCounts)
            if let answers {
                for item in pendingItems.items {
                    guard let answer = answers[item.id] else { continue }
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

        // 7. Placed against the crop's own geometry, and packed.
        let publication = await placed(regions: regions,
                                       outcomes: outcomes,
                                       policy: policy,
                                       layout: layout,
                                       framePixelSize: cropSize)
        let surface = LiveTranslateOverlaySurface(placements: [], policy: policy, locale: locale)
        let card = LiveTranslateResultsCardSurface(publication: publication,
                                                   stateCopy: surface.stateCopy(for:),
                                                   emptyHint: surface.emptyHint)
        return .success(LiveTranslateFocusedCapture(image: image,
                                                    framePixelSize: cropSize,
                                                    pixelRect: pixelRect,
                                                    publication: publication,
                                                    rows: card.rows))
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
                outcomes[region.id] = Self.restating(remembered, for: region.text)
                continue
            }
            guard case .success(let hit) = cache.lookup(text: region.text,
                                                        targetLanguage: targetLanguage),
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
                        framePixelSize: CGSize) async -> LiveTranslatePublication {
        let surface = LiveTranslateOverlaySurface(placements: [], policy: policy, locale: locale)
        let placements = LiveOverlayPlacement.place(regions: regions,
                                                    results: outcomes,
                                                    containerSize: layout.containerSize,
                                                    framePixelSize: framePixelSize,
                                                    safeArea: layout.safeArea,
                                                    occupiedRects: layout.occupiedRects,
                                                    crop: .whole,
                                                    policy: policy,
                                                    stateCopy: surface.stateCopy(for:))
        let sequence = await cycle.nextPublicationSequence()
        return LiveTranslatePublication(sequence: sequence,
                                        regions: regions,
                                        outcomes: outcomes,
                                        placements: placements,
                                        policy: policy)
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
                regions.append(TextRegionStabilizer.StableTextRegion(
                    id: TextRegionStabilizer.RegionIdentity(rawValue: identity),
                    text: piece,
                    normalizedText: LiveTranslateTextNormalization.normalized(piece),
                    box: region.normalizedBox,
                    detectedLanguage: region.detectedLanguage,
                    confidence: region.confidence))
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

    /// A cached answer re-stated onto the text it is being used for. The
    /// pipeline's own rule (`LiveTranslationPipeline.restating`), applied here
    /// because a cache key is a *normalized* string and the region's text is
    /// the one the elder is looking at.
    private static func restating(_ result: TranslationResult,
                                  for text: String) -> TranslationResult {
        switch result.outcome {
        case .pending:
            return .pending(text)
        case .resolved(_, let translation, let tier):
            return .resolved(originalText: text, translation: translation, tier: tier)
        case .degraded(_, let reason):
            return .degraded(originalText: text, reason: reason)
        }
    }
}
