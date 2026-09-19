import CoreGraphics
import CoreVideo
import Foundation

// T-033 — snapshot mode: the freeze-frame affordance (owner directive,
// OD-13 "never images", AM-10).
//
// What this file exists to make true:
//
//  1. **A freeze is holding one publication, not a second renderer.** The
//     frozen frame's placements and outcomes are the feature's own
//     `LiveTranslatePublication` — the same value the live cycle publishes —
//     so the overlay renders them through the one renderer and the speech path
//     speaks them through the one speech object. Nothing here draws anything.
//
//  2. **One frame, so no stabiliser.** A frozen frame has no "next frame", and
//     the stabiliser's whole job is cross-frame identity: it is neither
//     constructed nor consulted on this path, no tracking pass is run, and
//     every region the detector returns is placed immediately — the appear
//     hysteresis that bounds live overlay flicker has nothing to bound here.
//     The region *values* are the stabiliser's types (`StableTextRegion`,
//     `RegionIdentity`) because those are the types the placement and the
//     renderer consume; the type is not the tracker.
//
//  3. **The same detector, at the frame's own full resolution.** One call to
//     `LiveTextDetector.recognizeStillFrame`, which runs an OCR pass over the
//     frame's own pixel buffer on the detector's one serial queue through the
//     one Vision request. No crop, no downscale, no second detector.
//
//  4. **The same cache, the same gate, the same tiers, the same order.**
//     Device layers first (`LabelTranslationCache.lookup`), then the *live
//     cycle's own* plan (`LiveTranslateLiveCycle.resolveFrozen`): the same
//     reliability router, the same device tier, the same gate-then-tier
//     sequence, so a snapshot cannot send something the live path would not
//     have sent, cannot answer on the cloud something the live path would have
//     answered on the device, and cannot prompt for something the live path
//     would have answered. The plan is shared rather than copied.
//
//  5. **The frozen frame never leaves memory, and never reaches the network.**
//     The raster is built once, in memory, from the frame's pixel buffer and
//     held by the model; the tier is handed `CloudTranslationTier.Item`s —
//     which have an id, a string and a language code and no field an image
//     could travel in. There is no photo output, no photo library, no picker
//     and no file write anywhere on this path, and the source scan in
//     `SnapshotModeTests` fails if one appears.
//
//  6. **Placement is measured where it is drawn.** This type answers with
//     regions, outcomes and a placement *call*, never with a cached render:
//     the model measures the frozen frame's callouts under the policy in
//     force at that moment, so a display-preference change while a picture is
//     held re-measures it instead of leaving stale rects on screen.

// MARK: - Seams

/// The detector's still-frame entry (C02), narrowed to the one call this path
/// makes. The concrete detector conforms as it is; tests script passes through
/// a double, so no pixel content is needed to exercise the path.
protocol LiveTranslateStillFrameRecognising: AnyObject {
    func recognizeStillFrame(_ frame: CameraFrame) async -> Result<LiveTextDetector.Pass, LiveTranslateError>
}

extension LiveTextDetector: LiveTranslateStillFrameRecognising {}

// MARK: - The frozen frame

/// One frozen frame: what the elder sees, and what is drawn on it.
///
/// A value, deliberately. The freeze is the session's model *holding* this —
/// the overlay and the speech path read the publication out of it and nothing
/// else changes: no second observation surface, no second renderer and no
/// second speech path.
struct LiveTranslateSnapshot {

    /// The frozen frame's own geometry — the full pixel size of the buffer
    /// that was captured. The placements were measured with it, so the
    /// letterbox the callouts are mapped through is the frozen picture's, not
    /// the live preview's.
    let framePixelSize: CGSize

    /// The frozen picture, in memory: one `CGImage` the capture built from the
    /// frame's pixel buffer. Nothing writes it anywhere, and the buffer it came
    /// from is not retained.
    let image: CGImage

    /// The frozen frame's placements, outcomes and policy — the same value the
    /// live cycle publishes. `var` because the cloud answers for the strings
    /// the device could not translate land on the held publication, and a
    /// display-preference change re-measures it; the image and the geometry
    /// never change.
    var publication: LiveTranslatePublication

    var placements: [LiveOverlayPlacement.PlacedOverlay] { publication.placements }

    /// Whether the frozen frame shows anything to read. The overlay's empty
    /// state is a rendered state, not a blank screen (T-021).
    var hasVisibleText: Bool { publication.hasVisibleText }
}

/// The in-memory raster of one frame.
///
/// One conversion per capture, of the pixel buffer the capture layer produced
/// (32BGRA, fixed by T-006 and asserted by `LiveCameraCaptureGuaranteeTests`) —
/// the same buffer the detector is handed, at its own full size. The result is
/// a `CGImage` the view draws with; nothing here describes a location, a file
/// or a photo library.
enum LiveTranslateFrozenRaster {

    /// The one pixel format the capture layer configures. A buffer of any
    /// other format is refused rather than reinterpreted: an image with the
    /// wrong channel order would be a picture the elder cannot read, which is
    /// worse than no freeze at all.
    private static let supportedFormat = kCVPixelFormatType_32BGRA

    static func image(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == supportedFormat else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: base,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo) else { return nil }
        return context.makeImage()
    }
}

// MARK: - The results card

/// A frozen frame as a list to read (owner UX rework, 2026-09-17).
///
/// The owner's words after the first device demo: the bubbles "are everywhere
/// and shaky and get stacked and clustered depending on text", and what an
/// elder actually wants from a still is to *read* it. So the snapshot's
/// landing surface is this card, and the overlay goes back to being the
/// glance: no boxes over the picture, no motion, one scrollable column of
/// large type with the original underneath each line and a target an
/// elder-sized thumb can hit to hear it.
///
/// Pure and `Equatable`, like every other surface in the feature, and built
/// from the publication — one row per **recognized string**, not per measured
/// box — so the card and the overlay cannot disagree about what a region says
/// (both read the placement's own measured lines) and a recognized string
/// cannot disappear from the only surface a held frame has.
struct LiveTranslateResultsCardSurface: Equatable {

    /// One row: a translation, the text it came from, and whether there is
    /// something to hear.
    struct Row: Equatable, Identifiable {
        /// The overlay's own view identity — the normalized string — so the
        /// card's list is keyed by the same thing the overlay keys its boxes
        /// by, and a moving region keeps its row as well as its box.
        let id: String
        /// The large line: the translation for a resolved region, and the
        /// recognized text otherwise — never a translated-looking string for a
        /// region that was not translated (FR-LCT-018).
        let translation: String
        /// The small line beneath it: the original text beside a translation,
        /// or the honest state sentence when there is none.
        let source: String?
        /// The glyph for a state that needs one, or `nil` for a translation.
        let symbolName: String?
        /// Whether tapping the row speaks (C12's tap-to-hear). A row with
        /// nothing to say is not a button that does nothing.
        let speaksTranslation: Bool
        /// The region this row came from: what a tap hands back.
        let regionID: TextRegionStabilizer.RegionIdentity

        /// One recognized string's row.
        ///
        /// `lines` are the strings the region's own box was measured around,
        /// when it has a box: the row then carries exactly what the overlay
        /// draws and announces. A region with no box has no lines and the same
        /// two strings are derived by the rule the placement measures a
        /// callout's supporting line with — the original beside a translation,
        /// the honest state sentence when there is none — so "this region could
        /// not be measured" changes where a string is *drawn*, never whether it
        /// can be *read*.
        init(regionID: TextRegionStabilizer.RegionIdentity,
             result: TranslationResult,
             id: String,
             lines: [LiveOverlayTextLine] = [],
             stateCopy: (TranslationResult) -> String?) {
            let primary = lines.first?.text ?? result.text
            self.id = id
            self.regionID = regionID
            self.translation = primary

            if lines.count > 1 {
                // A callout draws its own second line; the card repeats it
                // rather than re-deriving it.
                self.source = lines[1].text
            } else if result.sourceTier != nil {
                // A translation exists and was drawn alone — in place, over the
                // text it replaces — so the original is the supporting line the
                // box did not draw. A string identical to the label is not
                // repeated.
                let original = result.originalText
                self.source = original.isEmpty || original == primary ? nil : original
            } else {
                self.source = stateCopy(result)
            }

            self.speaksTranslation = result.sourceTier != nil
            switch result.outcome {
            case .resolved: self.symbolName = nil
            case .pending: self.symbolName = RegionPresentation.pendingSymbolName
            case .degraded: self.symbolName = RegionPresentation.degradedSymbolName
            }
        }
    }

    let rows: [Row]
    /// The calm sentence for a frozen frame with no text on it. Reused from
    /// the overlay's empty state: one sentence for one situation.
    let emptyHint: String

    /// The card before anything has been read: no strings, and the same calm
    /// sentence a frame with no text on it says.
    init(emptyHint: String) {
        self.rows = []
        self.emptyHint = emptyHint
    }

    /// A publication as a list to read.
    ///
    /// **One row per recognized string.** The regions the overlay drew come
    /// first, in the placement's own reading order, and then every string the
    /// overlay had no box for. A held frame's card is the picture's *text*, not
    /// its geometry: a region the placement could not measure — no container
    /// yet, a frame shape with no room, a box the detector could not place — is
    /// a region with no box, and never a recognized string that vanishes from
    /// the only surface the elder has (owner's requirement, 2026-09-17: a
    /// frozen picture with text on it is never an empty card).
    ///
    /// The rows of the placed regions are the rows the overlay's own
    /// presentations carry — same identity, same two strings, same glyph, same
    /// tap — because both are built from the lines the placement measured.
    /// `stateCopy` is the overlay's own copy source and `emptyHint` its own
    /// hint: one situation, one sentence (T-005).
    init(publication: LiveTranslatePublication,
         stateCopy: (TranslationResult) -> String?,
         emptyHint: String) {
        var rows: [Row] = []
        var ordinals: [String: Int] = [:]
        var placed: Set<TextRegionStabilizer.RegionIdentity> = []

        // What the overlay drew, in the order it stacked it.
        for placement in publication.placements {
            placed.insert(placement.region.id)
            rows.append(Row(regionID: placement.region.id,
                            result: placement.result,
                            id: Self.identity(for: placement.region.text, ordinals: &ordinals),
                            lines: placement.lines,
                            stateCopy: stateCopy))
        }

        // ... and what it had no box for.
        for region in publication.regions where !placed.contains(region.id) {
            rows.append(Row(regionID: region.id,
                            result: publication.result(for: region),
                            id: Self.identity(for: region.text, ordinals: &ordinals),
                            stateCopy: stateCopy))
        }

        self.rows = rows
        self.emptyHint = emptyHint
    }

    /// The identity a row is keyed by: the overlay's own rule, over the same
    /// strings and in the same order — the normalized text, with an ordinal
    /// only when a second region carries it — so a row and its box are one
    /// view identity and a list cannot swap two regions that say the same
    /// thing.
    private static func identity(for text: String, ordinals: inout [String: Int]) -> String {
        let key = LiveTranslateTextNormalization.normalized(text)
        let ordinal = ordinals[key, default: 0]
        ordinals[key] = ordinal + 1
        return ordinal == 0 ? key : "\(key)#\(ordinal)"
    }

    /// Whether the card has read anything. A frozen frame with no text shows
    /// the empty hint instead of an empty list.
    var isEmpty: Bool { rows.isEmpty }
}

// MARK: - The snapshot path

/// The snapshot path: freeze one frame, read it once, place what it says.
///
/// Deliberately stateless. The freeze itself is the session model's (it is the
/// single observation surface, T-026); what it needs from this type is the
/// three steps that turn a frame into a renderable publication — the still
/// pass, the cloud answers for what the device could not translate, and the
/// placement — and each is a function of its inputs.
struct LiveTranslateSnapshotPath {

    let recogniser: LiveTranslateStillFrameRecognising
    /// The live cycle, for the two things that must not be re-created: its
    /// gate-then-tier sequence, and its ordering counter (AM-6).
    let cycle: LiveTranslateLiveCycle
    let cache: LabelTranslationCache
    let locale: Locale
    /// The live cycle's own default target — not a second constant
    /// (`LiveTranslationPipeline.defaultTargetLanguage`), so the still path
    /// and the live cycle cannot translate into different languages.
    let targetLanguage: AppLanguage = LiveTranslationPipeline.defaultTargetLanguage

    // MARK: Freeze

    /// Freezes `frame` and reads it: the raster, one still OCR pass, the device
    /// layers, and the first publication to render.
    ///
    /// The cloud is *not* waited for. What the device can answer is resolved
    /// here; everything else is published pending and asked in
    /// `outcomesAfterCloudAnswers` — so the elder gets the frozen picture
    /// immediately and the translations arrive onto it, exactly as they do
    /// live.
    ///
    /// `holdingRegions` is the text the live picture was showing at the tap,
    /// and it is what a *failed* still pass leaves on the held frame: a failed
    /// pass is recorded by the detector itself (`ocr_pass_failed`) and never
    /// surfaced — and, exactly as on the live path (T-007, where a failed pass
    /// keeps the regions already on screen), it does not blank the picture the
    /// elder is holding. A pass that succeeds is the frozen frame's own truth,
    /// including when that truth is "no text on this frame".
    func freeze(_ frame: CameraFrame,
                layout: LiveTranslateLayout,
                policy: LiveOverlayPlacement.Policy,
                holdingRegions: [TextRegionStabilizer.StableTextRegion] = [])
        async -> Result<LiveTranslateSnapshot, LiveTranslateError> {
        guard let image = LiveTranslateFrozenRaster.image(from: frame.pixelBuffer) else {
            // The frame cannot be shown, so it is not frozen: refusing is the
            // honest answer, and the live picture stays where it is.
            return .failure(.ocrUnavailable(.requestCreationFailed))
        }

        let detected: [LiveTextDetector.DetectedTextRegion]
        switch await recogniser.recognizeStillFrame(frame) {
        case .success(let pass):
            detected = pass.regions
        case .failure:
            // The regions the live picture was showing, held onto the frozen
            // frame: the elder tapped a picture with text on it, and a still
            // pass that failed is not a statement that the text went away.
            // Without this the freeze publishes nothing at all — and the held
            // frame's reading surface is the card, so "nothing" is a blank
            // card, which is the one thing a picture with text on it must
            // never be (owner's report, 2026-09-17: "now nothing").
            return await heldFrame(frame,
                                   image: image,
                                   regions: holdingRegions,
                                   layout: layout,
                                   policy: policy)
        }

        return await heldFrame(frame,
                               image: image,
                               regions: Self.regions(from: detected),
                               layout: layout,
                               policy: policy)
    }

    /// One held frame, from the strings it is holding: the device layers, the
    /// placement measured against the frozen frame's own geometry, and the
    /// publication to render. The one place a frozen frame is built — whether
    /// the strings came from the still pass or from the picture the elder was
    /// looking at when they tapped — so a freeze has one shape, not two.
    private func heldFrame(_ frame: CameraFrame,
                           image: CGImage,
                           regions: [TextRegionStabilizer.StableTextRegion],
                           layout: LiveTranslateLayout,
                           policy: LiveOverlayPlacement.Policy)
        async -> Result<LiveTranslateSnapshot, LiveTranslateError> {
        let publication = await placed(regions: regions,
                                       outcomes: resolveFromTheDevice(regions),
                                       policy: policy,
                                       layout: layout,
                                       framePixelSize: frame.pixelSize)
        return .success(LiveTranslateSnapshot(framePixelSize: frame.pixelSize,
                                              image: image,
                                              publication: publication))
    }

    // MARK: The cloud, for what the device could not answer

    /// The plan's answers for `publication`'s still-pending strings, merged
    /// onto its outcomes — or `nil` when there is nothing to ask, the elder has
    /// not answered the prompt yet, or the session is gone.
    ///
    /// Not "the cloud's answers": the frozen frame is planned by the same
    /// reliability router the live cycle plans by, so a short-form string the
    /// device is proven on is answered **by the device** here too, the sentence
    /// class leads with the cloud when the cloud can lead, and whatever the
    /// cloud cannot answer comes back to the device instead of degrading. The
    /// rule is `LiveTranslateLiveCycle.resolveFrozen`'s, in one place, for both
    /// paths.
    ///
    /// What travels is `CloudTranslationTier.Item`: an id, the sanitised text
    /// and Vision's language report. The frozen picture is not a parameter of
    /// anything on this path, and there is no attachment, media or image field
    /// in the type that travels — OD-13's "never images" is a property of the
    /// request's shape, not a promise about call sites.
    ///
    /// Answers, not placements: the caller measures the frozen frame's callouts
    /// under the policy in force when it draws them, so an answer that lands
    /// while the display preference is changing does not restore the old one.
    func outcomesAfterCloudAnswers(of publication: LiveTranslatePublication)
        async -> [TextRegionStabilizer.RegionIdentity: TranslationResult]? {
        var keyedRegions: [String: [TextRegionStabilizer.RegionIdentity]] = [:]
        var items: [String: CloudTranslationTier.Item] = [:]
        for region in publication.regions {
            guard case .pending? = publication.outcomes[region.id]?.outcome else { continue }
            let key = LabelTranslationCache.normalizationKey(text: region.text,
                                                             targetLanguage: targetLanguage)
            keyedRegions[key, default: []].append(region.id)
            items[key] = CloudTranslationTier.Item(id: key,
                                                   text: region.text,
                                                   detectedSourceLanguage: region.detectedLanguage)
        }
        guard !items.isEmpty else { return nil }
        // One call, the whole plan: the device for its class, the cloud for the
        // class the device is not proven on, and the device again for whatever
        // the cloud could not answer. `nil` is the open consent question and
        // the closed session — the two cases in which nothing may be applied.
        guard let answers = await cycle.resolveFrozen(Array(items.values)) else { return nil }

        var outcomes = publication.outcomes
        for item in items.values {
            // A key the plan made no claim about is not an answer: the region
            // stays pending, exactly as it would live.
            guard let answer = answers[item.id] else { continue }
            for id in keyedRegions[item.id] ?? [] {
                outcomes[id] = (outcomes[id] ?? .pending(item.text)).applying(answer.outcome)
            }
        }
        return outcomes
    }

    // MARK: Placement

    /// The feature's one placement, called with the feature's one policy and
    /// the feature's one copy source (T-020/T-021). The frame's pixel size is
    /// the frozen frame's, which is the whole of "the callouts are placed
    /// against the frozen picture".
    ///
    /// Pure geometry: no pass, no cache read and no request. That is what makes
    /// it safe to call again when the display preference changes, and what
    /// keeps a held frame's rects measured against the frozen geometry rather
    /// than the live one.
    ///
    /// The layout's window is dropped here, deliberately. A held picture is the
    /// frame's own buffer drawn whole (`LiveTranslateSnapshot` builds the image
    /// from it, and a freeze is "the picture in front of me"), so its regions
    /// are whole-frame boxes and its rects are measured through `.whole`. The
    /// zoom and the pan are live gestures: what the elder was pointing at when
    /// they tapped is held still, and moving the camera's window afterwards
    /// must not slide the callouts off their labels.
    func placed(regions: [TextRegionStabilizer.StableTextRegion],
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
        // The session's own counter, from the live cycle: a frozen frame's
        // publication advances the same monotone sequence a live one does
        // (AM-6), so no consumer can see two publications share an order.
        let sequence = await cycle.nextPublicationSequence()
        return LiveTranslatePublication(sequence: sequence,
                                        regions: regions,
                                        outcomes: outcomes,
                                        placements: placements,
                                        policy: policy)
    }

    // MARK: The device layers

    /// The on-device answer, with no network at all — the same call the live
    /// cycle makes, so the two cannot disagree about what the device knows.
    private func resolveFromTheDevice(_ regions: [TextRegionStabilizer.StableTextRegion])
        -> [TextRegionStabilizer.RegionIdentity: TranslationResult] {
        var outcomes: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [:]
        for region in regions {
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

    /// The detector's regions, as the values the placement and the renderer
    /// consume — one per detected string, in the detector's own order, each
    /// with an identity minted from its position.
    ///
    /// No hysteresis, no merging, no tracking: the pass is the frame. Two
    /// observations of the same string are two regions here, because a single
    /// frame makes no claim about which of them is the same thing seen twice.
    private static func regions(from detected: [LiveTextDetector.DetectedTextRegion])
        -> [TextRegionStabilizer.StableTextRegion] {
        detected.enumerated().map { index, region in
            TextRegionStabilizer.StableTextRegion(
                id: TextRegionStabilizer.RegionIdentity(rawValue: index),
                text: region.text,
                normalizedText: LiveTranslateTextNormalization.normalized(region.text),
                box: region.normalizedBox,
                detectedLanguage: region.detectedLanguage,
                confidence: region.confidence)
        }
    }
}
