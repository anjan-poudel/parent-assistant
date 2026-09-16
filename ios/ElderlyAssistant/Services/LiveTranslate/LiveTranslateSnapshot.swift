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
//  4. **The same cache, the same gate, the same tier.** Device layers first
//     (`LabelTranslationCache.lookup`), then the *live cycle's own*
//     gate-then-tier sequence (`LiveTranslateLiveCycle.attemptResolution`), so
//     a snapshot cannot send something the live path would not have sent, and
//     cannot prompt for something the live path would have answered. Ordering
//     is shared rather than copied.
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
    func freeze(_ frame: CameraFrame,
                layout: LiveTranslateLayout,
                policy: LiveOverlayPlacement.Policy) async -> Result<LiveTranslateSnapshot, LiveTranslateError> {
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
            // A failed still pass is recorded by the detector itself
            // (`ocr_pass_failed`) and never surfaced, exactly as on the live
            // path (T-007): the elder gets the frozen picture with no text on
            // it, which is what is true.
            detected = []
        }

        let regions = Self.regions(from: detected)
        let outcomes = resolveFromTheDevice(regions)
        let publication = await placed(regions: regions,
                                       outcomes: outcomes,
                                       policy: policy,
                                       layout: layout,
                                       framePixelSize: frame.pixelSize)
        return .success(LiveTranslateSnapshot(framePixelSize: frame.pixelSize,
                                              image: image,
                                              publication: publication))
    }

    // MARK: The cloud, for what the device could not answer

    /// The cloud's answers for `publication`'s still-pending strings, merged
    /// onto its outcomes — or `nil` when there is nothing to ask, the elder has
    /// not answered the prompt yet, or the session is gone.
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
        guard let attempt = await cycle.attemptResolution(Array(items.values)) else { return nil }

        var outcomes = publication.outcomes
        switch attempt {
        case .awaitingDecision:
            // The prompt is on screen. The regions stay pending — nothing has
            // failed and the elder has not answered — and the next capture, or
            // the live path's own next cycle, is where the answer applies.
            return nil

        case .unavailable(let error):
            for item in items.values {
                for id in keyedRegions[item.id] ?? [] {
                    outcomes[id] = (outcomes[id] ?? .pending(item.text))
                        .applying(.degraded(originalText: item.text,
                                            reason: error.unavailableReason))
                }
            }

        case .answered(let batch):
            for item in items.values {
                for id in keyedRegions[item.id] ?? [] {
                    outcomes[id] = (outcomes[id] ?? .pending(item.text))
                        .applying(batch.result(for: item).outcome)
                }
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
