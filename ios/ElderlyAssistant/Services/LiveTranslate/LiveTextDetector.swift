import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Vision

// C02 — on-device text detection (T-007, FR-LCT-003/004, NFR-LCT-001/002/005).
//
// Scene-block rework, 2026-09-18 (owner device verdict: "still shaky,
// illegible, unusable as a gimmick"; direction: "maximize text regions —
// bigger but fewer translations — and use object detection bounding boxes").
// Three things joined this file, and nothing else in the feature changed
// shape:
//
//  - **An object pass.** `LiveObjectDetectionEngine` detects the physical
//    objects in the frame and returns boxes (with class labels where the
//    runtime can name one). It runs on its own, much slower cadence
//    (`objectPassCadenceSeconds`) and its result is cached, because an
//    appliance does not become a different appliance between two OCR passes;
//    a failed object pass degrades the *grouping* and never the text.
//  - **Grouping.** The OCR pass's lines and the cached objects go through
//    `SceneBlockGrouper`, and what the pass reports is **blocks** — one
//    surface each, not one box per recognized line. Everything downstream
//    (the stabiliser, the translation request, the placement, the overlay)
//    therefore works on blocks without being told that anything changed: a
//    block *is* a region whose text is its member lines.
//  - **A block identity on every region.** `DetectedTextRegion.blockIdentity`
//    carries the grouper's key, so the stabiliser can hold a block's identity
//    across OCR wobble inside an object panel — the case that used to re-key a
//    region (and repaint the overlay) on nearly every pass.
//
// The tracking path is unchanged in kind and now reports **block** geometry:
// the engine still follows one rectangle per recognized *line* (that is the
// only rectangle Vision has), and the detector unions a block's members into
// the box the block reports. A block whose members were all lost is a
// tracking loss, exactly as a single lost line was.
//
// What this file exists to make true:
//
//  - **Two non-interchangeable request kinds.** A *tracking pass* carries
//    region geometry between OCR passes and produces **no text at all**; an
//    *OCR pass* is the only thing in the feature that can produce or change a
//    recognized string. That is structural here, not a convention: the two
//    kinds return different fields of `Pass`, and the tracking path has no
//    string in its output type to set.
//  - **One still entry, and it is the same pass (T-033).** `recognizeStillFrame`
//    is the snapshot path's way in: an OCR pass, unconditionally, over the
//    frame's own full-resolution buffer, on this detector's one serial queue
//    through the one engine. There is no second detector, no second request
//    and no resized copy of the frame — and a frozen frame can never come back
//    as a tracking pass, which would return no text at all.
//  - **Entirely on device.** Recognition is Vision's, locally; there is no
//    network client, no model download and no URL anywhere in this file.
//  - **A failed pass is dropped.** A Vision failure returns a failure the
//    caller drops and records as `ocr_pass_failed`; nothing reaches the elder
//    and the next pass simply tries again.
//  - **Tracking is a SHOULD.** If the tracking request cannot be run, the
//    detector degrades to OCR-only, says so once with `tracking_unsupported`,
//    and stays usable. A tracking *loss* is not even a degradation: the key is
//    omitted, and the stabiliser keeps the last OCR-confirmed geometry.
//  - **Tracking is bounded and scene-driven (resource rework, 2026-09-17).**
//    Tracking runs only while regions exist *and* the frame differs from the
//    last OCR'd one, and never for more than
//    `trackingMaxRectanglesPerPass` rectangles. Both halves exist because a
//    tracking pass costs one Vision request per remembered rectangle: an
//    unchanged scene has no movement to find, and a scene with a dozen strings
//    has more rectangles than the overlay can draw.
//  - **No invented language.** `detectedLanguage` is Vision's own report or
//    nothing; a value is never substituted, and no caller can hard-code a
//    source language through this API.
//
// Everything Vision-shaped sits behind `LiveTextRecognitionEngine`, so the
// cadence, the pass-kind policy and the degradation paths are testable without
// a camera — and the shipped engine is exercised for real on a rendered frame.

// MARK: - Engine seam

/// C02's seam: everything Vision-shaped, in the detector's own vocabulary.
///
/// The two request kinds are separate methods on purpose. `recognizeText` is
/// the only one that returns strings; `followRememberedRectangles` returns
/// geometry and nothing else, so no implementation of it can change a region's
/// text (FR-LCT-004).
protocol LiveTextRecognitionEngine: AnyObject {

    /// Whether a rectangle-tracking request can be created and run here.
    /// `false` degrades the detector to OCR-only before the first pass.
    var supportsTracking: Bool { get }

    /// Runs an OCR pass over the frame. Returns one entry per recognized
    /// string, in Vision's own order, and remembers each one's rectangle under
    /// its text so the next tracking pass can follow it.
    func recognizeText(in pixelBuffer: CVPixelBuffer) throws -> [LiveTextDetector.DetectedTextRegion]

    /// Runs a tracking pass over the frame against the rectangles the last OCR
    /// pass remembered. One entry per string that is still tracked; a string
    /// absent from the result is a tracking loss. Returns geometry only.
    func followRememberedRectangles(in pixelBuffer: CVPixelBuffer) throws -> [String: NormalizedBox]

    /// Drops the remembered rectangles (the OCR pass's observations).
    func forgetRememberedRectangles()
}

// MARK: - Object-detection seam

/// The object pass's seam: the physical objects in one frame, in the
/// detector's own vocabulary.
///
/// Separate from `LiveTextRecognitionEngine` because the two answer different
/// questions on different cadences: text recognition is the feature's
/// high-frequency pass and its output can change a region's *string*, while
/// object detection is a slow, cached scene description that can only change
/// how the strings are *grouped*.
protocol LiveObjectDetectionEngine: AnyObject {

    /// Whether an object-detection request can be created and run here.
    /// `false` leaves the detector grouping by text geometry alone, before the
    /// first pass.
    var supportsObjectDetection: Bool { get }

    /// Runs an object pass over the frame. One entry per detected object, in
    /// the runtime's own order. Throws when the request could not be run at
    /// all — a refusal, not an empty scene.
    func detectObjects(in pixelBuffer: CVPixelBuffer) throws -> [LiveTextDetector.DetectedSceneObject]
}

/// The shipped object engine: Vision, on device.
///
/// **What this runtime actually provides.** The task's premise was
/// `VNRecognizeObjectsRequest`'s built-in object classes. That request is not
/// in this SDK: it was deprecated in iOS 13 and is now absent from the
/// framework headers entirely (`VNRecognizeObjectsRequest` appears nowhere in
/// the iOS 26.5 simulator SDK; `VNRecognizedObjectObservation` survives, but
/// only `VNRecognizeAnimalsRequest` produces one, and it knows dogs and cats).
/// So the shipped engine composes the two requests that *do* exist and answer
/// the same question — where are the objects, and what are they:
///
///  1. **Where.** `VNGenerateObjectnessBasedSaliencyImageRequest` returns a
///     heat map whose `salientObjects` are the bounding boxes of the distinct
///     object-like regions in the frame (iOS 13 and later). This is the
///     geometry: a panel, a screen, a remote, a box of packaging — objectness
///     does not care which.
///  2. **What.** `VNClassifyImageRequest`, run with `regionOfInterest` set to
///     one box, returns the classifier's labels for *that part of the frame* —
///     the same taxonomy the old built-in object model used, so
///     "remote control", "television", "microwave" and "screen" are in it. The
///     top label above `minimumClassConfidence` becomes the object's class.
///
/// Bounded like the tracking pass, and for the same reason: one classification
/// request per object, so at most `maximumObjects` of them per pass — the
/// largest regions first, because those are the surfaces a panel would be
/// drawn on.
final class VisionObjectDetectionEngine: LiveObjectDetectionEngine {

    private let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
    private let classifyRequest = VNClassifyImageRequest()

    /// Objects reported per pass, at most. Defaulted from the config's own
    /// block bound — a scene that resolves to a handful of surfaces does not
    /// need classes for regions the overlay could never draw.
    private let maximumObjects: Int
    /// The smallest share of the frame an object may occupy to be reported.
    /// A property of the request rather than a policy of the feature: a
    /// saliency box under a hundredth of the frame is noise, not an object.
    private let minimumObjectArea: Double
    /// The lowest classifier confidence that names an object. Below it the
    /// object is still an object — it groups its own text — it is just
    /// unnamed, which is the honest report rather than a guessed class.
    private let minimumClassConfidence: Float

    init(maximumObjects: Int = LiveTranslateConfig.default.maxVisibleBlocks,
         minimumObjectArea: Double = 0.01,
         minimumClassConfidence: Float = 0.15) {
        self.maximumObjects = maximumObjects
        self.minimumObjectArea = minimumObjectArea
        self.minimumClassConfidence = minimumClassConfidence
    }

    /// The requests exist on every OS this app deploys to (objectness saliency
    /// and image classification are both iOS 13 APIs, and the deployment target
    /// is above that), so there is no honest "no" a probe could return here. A
    /// device where the request cannot be *run* is handled where it happens:
    /// the pass throws and the detector degrades with its own event.
    var supportsObjectDetection: Bool { true }

    func detectObjects(in pixelBuffer: CVPixelBuffer) throws -> [LiveTextDetector.DetectedSceneObject] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([saliencyRequest])
        } catch {
            throw LiveTranslateError.ocrPassFailed(.requestFailed)
        }

        let boxes = Self.objectBoxes(from: saliencyRequest.results?.first,
                                     maximum: maximumObjects,
                                     minimumArea: minimumObjectArea)
        return boxes.map { box in
            LiveTextDetector.DetectedSceneObject(
                classLabel: classLabel(in: pixelBuffer, region: box),
                // Vision's origin is bottom-left and the feature's is
                // top-left: mirrored here, once, exactly as the text path does.
                normalizedBox: Self.normalizedBox(from: box),
                confidence: 1)
        }
    }

    /// The frame's object boxes, largest first, capped and filtered.
    ///
    /// Pure and static so the policy — which regions of a dense scene are
    /// worth a classification request — is a fact a test can pin without a
    /// camera or a rendered frame.
    static func objectBoxes(from observation: VNSaliencyImageObservation?,
                            maximum: Int,
                            minimumArea: Double) -> [CGRect] {
        guard maximum > 0, let observation else { return [] }
        let salient: [VNRectangleObservation] = observation.salientObjects ?? []
        var candidates: [CGRect] = []
        for box in salient.map({ $0.boundingBox }) {
            guard box.width > 0, box.height > 0,
                  Double(box.width * box.height) >= minimumArea else { continue }
            candidates.append(box)
        }
        candidates.sort(by: Self.objectOrder)
        return Array(candidates.prefix(maximum))
    }

    /// Largest first, ties broken by position — so which boxes survive the cap
    /// is a fact about the frame rather than about the sort's stability.
    ///
    /// Its own function rather than an inline closure: the chained expression
    /// it came from was expensive enough for the compiler to give up on the
    /// enclosing function, and this reads better besides.
    static func objectOrder(_ left: CGRect, _ right: CGRect) -> Bool {
        let leftArea = Double(left.width * left.height)
        let rightArea = Double(right.width * right.height)
        if leftArea != rightArea { return leftArea > rightArea }
        if left.minY != right.minY { return left.minY > right.minY }
        return left.minX < right.minX
    }

    /// The classifier's name for the region, or nil when it could not name one
    /// confidently. Vision's own answer or nothing — never substituted.
    private func classLabel(in pixelBuffer: CVPixelBuffer, region: CGRect) -> String? {
        classifyRequest.regionOfInterest = region
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        guard (try? handler.perform([classifyRequest])) != nil,
              let top = classifyRequest.results?.first,
              top.confidence >= minimumClassConfidence else { return nil }
        return top.identifier
    }

    private static func normalizedBox(from visionBox: CGRect) -> NormalizedBox {
        let box = NormalizedBox(
            xMin: Double(visionBox.minX).clampedToUnitInterval,
            yMin: Double(1 - visionBox.maxY).clampedToUnitInterval,
            xMax: Double(visionBox.maxX).clampedToUnitInterval,
            yMax: Double(1 - visionBox.minY).clampedToUnitInterval)
        return box.isValid ? box : NormalizedBox(xMin: 0, yMin: 0, xMax: 0, yMax: 0)
    }
}

/// The shipped engine: Vision, on device, one request kind per entry point.
final class VisionTextRecognitionEngine: LiveTextRecognitionEngine {

    // MARK: - What one pass asks Vision for

    /// The OCR pass's settings, **read back off the requests themselves**
    /// rather than kept as a copy of what the engine meant to set.
    ///
    /// The distinction matters because this type exists to make a claim that
    /// can be checked: "the pass that ran was configured this way". A stored
    /// copy of the intent would assert that the initializer ran and nothing
    /// more; a read-back says what Vision was actually handed. Every field
    /// here is a property of a `VNRequest` this engine owns, and the values
    /// come from `LiveTranslateConfig` and nowhere else.
    struct Settings: Equatable {
        /// The level the accurate pass runs at. `.accurate` and not `.fast`:
        /// the whole point of the OCR-first rework is reading small print.
        var recognitionLevel: VNRequestTextRecognitionLevel
        /// Whether the recognizer's language model corrects what it read
        /// (`ocrAppliesLanguageCorrection`).
        var appliesLanguageCorrection: Bool
        /// Whether the request picks the language itself
        /// (`ocrAutomaticallyDetectsLanguage`, iOS 16 and later).
        var automaticallyDetectsLanguage: Bool
        /// The languages the request is held to when it is *not* detecting
        /// (`ocrCorrectionLanguages`).
        var recognitionLanguages: [String]
        /// The smallest share of the image a line may occupy
        /// (`ocrMinimumTextHeight`).
        var minimumTextHeight: Float
        /// The words the recognizer is biased toward (`ocrVocabulary`).
        var vocabulary: [String]
    }

    /// The accurate pass: the feature's recognition, once per OCR tick.
    private let textRequest = VNRecognizeTextRequest()
    /// The whole-frame retry, at the fast recognition level.
    ///
    /// A second *request object* rather than a reconfigured first one: the two
    /// passes differ in level, in correction and in vocabulary, and toggling
    /// those on one object would make the nominal pass's configuration depend
    /// on whether the previous pass happened to come back blank.
    private let retryRequest = VNRecognizeTextRequest()
    private let sequenceHandler = VNSequenceRequestHandler()

    /// The last OCR pass's rectangles, keyed by the recognized string they
    /// belong to. A tracking pass follows these; `nil` after `forget`.
    private var rectangles: [String: VNRectangleObservation] = [:]

    /// Rectangles followed per pass, at most
    /// (`LiveTranslateConfig.trackingMaxRectanglesPerPass`).
    ///
    /// A tracking pass runs one `VNTrackRectangleRequest` **per remembered
    /// rectangle**, one after another on this engine's caller's serial queue,
    /// and a dense scene can remember a dozen. The requests the cap drops are
    /// not losses of text and not errors: a key absent from a tracking pass is
    /// the documented tracking-loss case (FR-LCT-004), which the stabiliser
    /// answers by holding the last OCR-confirmed geometry. The overlay
    /// therefore goes on drawing the box it already had, and the scene pays for
    /// the rectangles the elder can actually see instead of for every string
    /// Vision found in it.
    private let maximumRectanglesPerPass: Int

    /// Whether the blank-pass retry is allowed (`ocrLargeTextRetryEnabled`).
    private let retriesBlankPasses: Bool

    /// The bound defaults to the shipped config's, so a parameterless
    /// construction is the same engine the detector builds — the cap is a
    /// policy of the feature and not a property of one call site. The config
    /// defaults to the shipped one for the same reason: an engine built with
    /// no arguments is the engine the feature ships.
    init(maximumRectanglesPerPass: Int = LiveTranslateConfig.default.trackingMaxRectanglesPerPass,
         config: LiveTranslateConfig = .default) {
        self.maximumRectanglesPerPass = maximumRectanglesPerPass
        self.retriesBlankPasses = config.ocrLargeTextRetryEnabled
        Self.configure(textRequest, level: .accurate, config: config, corrected: true)
        // The retry is a *different* recognition: the fast level the platform
        // documents for large, well-lit text, with correction and the custom
        // vocabulary left off — both are accurate-level features, and a retry
        // that inherited them would be the same pass over a bigger frame at a
        // worse level.
        Self.configure(retryRequest, level: .fast, config: config, corrected: false)
    }

    /// Applies the config's recognition settings to one request.
    ///
    /// The one place a `VNRequest` is configured, so the two passes cannot
    /// drift: both go through here, and `corrected` is the only difference
    /// between them.
    static func configure(_ request: VNRecognizeTextRequest,
                          level: VNRequestTextRecognitionLevel,
                          config: LiveTranslateConfig,
                          corrected: Bool) {
        request.recognitionLevel = level
        request.usesLanguageCorrection = corrected && config.ocrAppliesLanguageCorrection
        request.minimumTextHeight = config.ocrMinimumTextHeight
        if corrected, !config.ocrVocabulary.isEmpty {
            request.customWords = config.ocrVocabulary
        }
        // The capability check the design asks for (C02): automatic language
        // detection is an iOS 16-and-later property, and the deployment target
        // supports it. When it is not applied, the request is held to the
        // configured languages instead — and when it *is* applied, Vision
        // ignores the language list, so it is deliberately not also set: a
        // request that both detected and was restricted could come back as an
        // English-only pass over a Devanagari sign. When detection is not
        // available, `detectedLanguage` stays `nil` — a missing report, never a
        // substituted value.
        if #available(iOS 16.0, *), config.ocrAutomaticallyDetectsLanguage {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = config.ocrCorrectionLanguages
        }
    }

    /// What the accurate pass actually carries. Read off the request, so this
    /// cannot describe a configuration the engine failed to apply.
    var settings: Settings {
        var detects = false
        if #available(iOS 16.0, *) { detects = textRequest.automaticallyDetectsLanguage }
        return Settings(recognitionLevel: textRequest.recognitionLevel,
                        appliesLanguageCorrection: textRequest.usesLanguageCorrection,
                        automaticallyDetectsLanguage: detects,
                        recognitionLanguages: textRequest.recognitionLanguages,
                        minimumTextHeight: textRequest.minimumTextHeight,
                        vocabulary: textRequest.customWords)
    }

    /// Rectangle tracking has been part of Vision since iOS 11 and the
    /// request's initializer is non-failable on a supported OS, so there is no
    /// probe that could honestly answer "no" here. A device where the request
    /// cannot be *run* is handled where it happens: the tracking pass throws,
    /// and the detector degrades with the same honest event.
    var supportsTracking: Bool { true }

    /// One OCR pass over the frame, with the blank-pass retry behind it.
    ///
    /// The retry's condition is deliberately the narrowest one there is: the
    /// accurate pass over the elder's window returned **nothing at all**. Any
    /// recognized line, however poor, is a scene the retry has nothing to add
    /// to, so the nominal pass costs exactly what it did before this rework and
    /// the second pass is paid for only where its absence is visible as an
    /// empty overlay over a picture full of text.
    func recognizeText(in pixelBuffer: CVPixelBuffer) throws -> [LiveTextDetector.DetectedTextRegion] {
        let regions = try recognize(pixelBuffer, with: textRequest)
        guard regions.isEmpty, retriesBlankPasses else { return regions }
        return try recognize(pixelBuffer, with: retryRequest)
    }

    /// One pass with one request, mapped into the feature's vocabulary and
    /// remembered for tracking.
    private func recognize(_ pixelBuffer: CVPixelBuffer,
                           with request: VNRecognizeTextRequest)
        throws -> [LiveTextDetector.DetectedTextRegion] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw LiveTranslateError.ocrPassFailed(.requestFailed)
        }

        var regions: [LiveTextDetector.DetectedTextRegion] = []
        var remembered: [String: VNRectangleObservation] = [:]
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first,
                  let box = Self.normalizedBox(from: observation.boundingBox) else { continue }
            let text = candidate.string
            // Two observations with the same string cannot be told apart by a
            // text-keyed map; the later one wins. The stabiliser owns region
            // identity and merges duplicates (T-009), so nothing is lost here
            // that it would have kept.
            remembered[text] = observation
            regions.append(LiveTextDetector.DetectedTextRegion(
                text: text,
                normalizedBox: box,
                detectedLanguage: nil,
                confidence: Double(candidate.confidence)))
        }
        rectangles = remembered
        return regions
    }

    func followRememberedRectangles(in pixelBuffer: CVPixelBuffer) throws -> [String: NormalizedBox] {
        guard !rectangles.isEmpty else { return [:] }

        var tracked: [String: NormalizedBox] = [:]
        var refreshed: [String: VNRectangleObservation] = [:]
        for (text, rectangle) in followed() {
            let request = VNTrackRectangleRequest(rectangleObservation: rectangle)
            do {
                try sequenceHandler.perform([request], on: pixelBuffer)
            } catch {
                // The request could not be run at all: not a loss, a refusal.
                // The detector degrades; the throw is how it finds out.
                throw LiveTranslateError.trackingUnsupported
            }
            // No observation means the tracker lost the rectangle on this
            // frame — a loss, not a failure: the key is simply absent, and the
            // stabiliser keeps the last OCR-confirmed geometry.
            guard let result = request.results?.first as? VNRectangleObservation,
                  let box = Self.normalizedBox(from: result.boundingBox) else { continue }
            tracked[text] = box
            // Re-anchor on the tracked rectangle so the next frame follows
            // from where the region actually is; the next OCR pass re-anchors
            // on recognized text again, which is what bounds any drift.
            refreshed[text] = result
        }
        if !refreshed.isEmpty { rectangles = refreshed }
        return tracked
    }

    func forgetRememberedRectangles() {
        rectangles.removeAll()
    }

    /// The rectangles this pass will follow: at most
    /// `maximumRectanglesPerPass` of them, largest first.
    ///
    /// Largest first, because the overlay is a glance surface with a bounded
    /// number of regions (`declutterMaxRegions`): the boxes big enough to be
    /// drawn are the ones whose tracking the elder can see, and a string whose
    /// box was too small to render is not worth a Vision request. The order is
    /// by area with the string as the tie-break, so the same scene always
    /// follows the same rectangles — a set that changed between two identical
    /// frames would make the overlay's geometry depend on dictionary order.
    private func followed() -> [(String, VNRectangleObservation)] {
        let remembered: [(text: String, area: Double)] = rectangles.map {
            (text: $0.key,
             area: Double($0.value.boundingBox.width * $0.value.boundingBox.height))
        }
        let chosen = Self.rectanglesToFollow(remembered, maximum: maximumRectanglesPerPass)
        return chosen.compactMap { text in rectangles[text].map { (text, $0) } }
    }

    /// The rule `followed()` applies, as a function of named rectangles rather
    /// than of Vision objects: largest first, at most `maximum` of them.
    ///
    /// Extracted so the cap is a fact about the scene — which boxes of a dense
    /// scene cost a request — that a test can pin without a camera, a rendered
    /// frame or a Vision request.
    static func rectanglesToFollow(_ remembered: [(text: String, area: Double)],
                                   maximum: Int) -> [String] {
        guard maximum >= 0 else { return [] }
        let ordered = remembered.sorted { left, right in
            if left.area != right.area { return left.area > right.area }
            return left.text < right.text
        }
        guard ordered.count > maximum else { return ordered.map(\.text) }
        return ordered.prefix(maximum).map(\.text)
    }

    /// Vision's normalized box, converted to the feature's one box
    /// representation: `NormalizedBox` (0–1, origin top-left, as the shipped
    /// overlay mapping consumes). Vision's origin is bottom-left, so `y` is
    /// mirrored; the values are clamped because a float that lands a hair
    /// outside the frame is a rounding artifact, not geometry to drop.
    private static func normalizedBox(from visionBox: CGRect) -> NormalizedBox? {
        let box = NormalizedBox(
            xMin: Double(visionBox.minX).clampedToUnitInterval,
            yMin: Double(1 - visionBox.maxY).clampedToUnitInterval,
            xMax: Double(visionBox.maxX).clampedToUnitInterval,
            yMax: Double(1 - visionBox.minY).clampedToUnitInterval)
        return box.isValid ? box : nil
    }
}

private extension Double {
    var clampedToUnitInterval: Double { Swift.min(1, Swift.max(0, self)) }
}

// MARK: - Detector

/// Wraps on-device recognition: one pass at a time on a serial queue, with the
/// two request kinds, the OCR cadence and the degradation policy.
final class LiveTextDetector {

    // MARK: Output types

    /// One recognized string from an OCR pass. The only type in the feature
    /// that carries recognized text out of Vision.
    ///
    /// Since the scene-block rework this is one **block**: `text` is the
    /// block's member lines joined by `SceneBlock.lineSeparator`,
    /// `normalizedBox` is the block's rect (an object's box clipped to its text,
    /// or the union of merged lines), and `blockIdentity` is the grouper's
    /// stable key for it. The type keeps its name and shape for the same reason
    /// the whole feature keeps working unchanged: a block **is** a region — one
    /// surface, one string — so nothing downstream has to know.
    struct DetectedTextRegion: Equatable {
        let text: String
        /// The feature's one box representation — the same `NormalizedBox` the
        /// stabiliser, the placement mapper and the shipped overlay maths
        /// consume (T-009/T-020, NFR-LCT-012).
        let normalizedBox: NormalizedBox
        /// The runtime's report, or `nil` when it did not make one. Never
        /// guessed.
        let detectedLanguage: String?
        let confidence: Double
        /// The grouper's identity for the block this region is, when the region
        /// came from the grouper — the member-string set of the block, for
        /// every block, object or not. `nil` for a region from any other path
        /// (a test fake, a plain OCR pass): the stabiliser then identifies the
        /// region by its string, exactly as it always has.
        let blockIdentity: String?

        init(text: String,
             normalizedBox: NormalizedBox,
             detectedLanguage: String?,
             confidence: Double,
             blockIdentity: String? = nil) {
            self.text = text
            self.normalizedBox = normalizedBox
            self.detectedLanguage = detectedLanguage
            self.confidence = confidence
            self.blockIdentity = blockIdentity
        }
    }

    /// One detected physical object from an object pass: where it is, and what
    /// the runtime could name it (or `nil` when it could not).
    ///
    /// The same box representation as a region's, deliberately — the grouper's
    /// whole job is deciding which boxes contain which, and two box types would
    /// make that a conversion rather than a comparison.
    struct DetectedSceneObject: Equatable {
        /// The runtime's own name for the object, or `nil`. Never guessed: an
        /// unnamed object is still an object and still groups its text.
        let classLabel: String?
        let normalizedBox: NormalizedBox
        let confidence: Double
    }

    /// One pass's output. An OCR pass fills `regions` and leaves `trackedBoxes`
    /// empty; a tracking pass fills `trackedBoxes` and leaves `regions` empty. A
    /// caller that reads text from `trackedBoxes` has nothing to read: there is
    /// no string in it.
    struct Pass: Equatable {
        let regions: [DetectedTextRegion]
        /// Tracked key → geometry, for the keys the tracker still holds. A
        /// missing key is a tracking loss. Since the rework the keys are
        /// **block** texts: a block is what the stabiliser tracks, so a block is
        /// what the tracker reports.
        let trackedBoxes: [String: NormalizedBox]
        /// The scene's objects as of this pass — freshly detected or the cached
        /// set, whichever the cadence allowed. Always empty on a tracking pass
        /// (an object pass never runs there) and on any detector whose runtime
        /// cannot detect objects. Reported rather than hidden because the
        /// grouping is only as good as they are, and this is where a caller can
        /// see which grouping actually happened.
        let objects: [DetectedSceneObject]

        init(regions: [DetectedTextRegion],
             trackedBoxes: [String: NormalizedBox],
             objects: [DetectedSceneObject] = []) {
            self.regions = regions
            self.trackedBoxes = trackedBoxes
            self.objects = objects
        }
    }

    /// Which request a pass is. Not a mode to be toggled by callers: the
    /// cadence decides, and the pass kind decides which output field can be
    /// filled.
    enum PassKind: Equatable { case ocr, tracking }

    private enum State { case idle, ready }

    // MARK: Dependencies

    let config: LiveTranslateConfig
    private let events: LiveTranslateEvents
    private let engine: LiveTextRecognitionEngine
    /// The object pass's engine. Separate from the text engine because the two
    /// are separate requests on separate cadences — a runtime can have text
    /// recognition and no way to name an object, and the detector must then
    /// group by text geometry rather than fail.
    private let objectEngine: LiveObjectDetectionEngine
    private let now: () -> TimeInterval

    /// Vision runs here and nowhere else: one pass at a time, so two passes
    /// can never share a request handler.
    private let visionQueue = DispatchQueue(label: "com.elderlyassistant.livetranslate.vision")

    /// The object pass's own serial queue, and deliberately not `visionQueue`.
    ///
    /// The two passes have opposite urgencies: the OCR pass is the one the
    /// elder is waiting on, and the object pass is a slow scene description
    /// that only decides how the next pass *groups* what it read. Serialising
    /// them would put a saliency request — and, on a device's first one, a
    /// model load — in front of the first text of a session, which is exactly
    /// the delay the owner reported. One object pass at a time, on its own
    /// queue, and the text path never joins it.
    private let objectQueue = DispatchQueue(
        label: "com.elderlyassistant.livetranslate.objects")

    /// Whether an object pass is running. Read and written under the lock, and
    /// the reason the cadence cannot queue detections behind a slow one.
    private var objectPassInFlight = false

    /// Bumped whenever the picture an object pass was measuring stops being the
    /// one this session is reading: `begin`, `end`, and a window change. A
    /// detection that lands after that describes a scene nobody is looking at,
    /// so it is discarded rather than grouped against.
    private var objectPassEpoch = 0

    private let lock = NSLock()

    // MARK: State (lock-guarded)

    private var currentState: State = .idle
    private var trackingAvailable = false
    private var objectsAvailable = false
    private var lastOCRPassAt: TimeInterval?
    private var lastObjectPassAt: TimeInterval?
    private var rememberedKeys: Set<String> = []
    /// The last OCR pass's blocks: block text → its member strings, in reading
    /// order. A tracking pass re-keys the per-line geometry the engine followed
    /// into the block geometry the stabiliser tracks, and this is the only
    /// place that mapping is known.
    private var blockMembers: [String: [String]] = [:]
    /// The object pass's cached result. Objects belong to the *scene*, not to
    /// one frame: an appliance does not become a different appliance between two
    /// OCR passes, so the set is reused until the cadence says otherwise.
    private var objects: [DetectedSceneObject] = []
    private var passesInFlight = 0

    /// The frame-change gate's state: the signature of the last frame
    /// recognition ran on, and whether the frame in hand differs from it.
    ///
    /// The detector keeps its own gate rather than taking the camera's answer
    /// because it is the component that decides the pass kind, and the
    /// decision has to hold for whatever caller delivered the frame — the tap
    /// today, a test or a future still-frame path tomorrow.
    private var frameDetector = FrameChangeDetector()
    /// Whether the frame in hand is materially different from the last OCR'd
    /// one. Defaults to `true` so a session's first pass is never gated.
    private var sceneChanged = true

    /// The window the last OCR pass ran on. A pass over a different window is a
    /// pass over a different picture — its remembered rectangles describe the
    /// old one (see `noteCropChange`).
    private var lastPassCrop: LiveCameraCrop = .whole

    // MARK: Init

    init(config: LiveTranslateConfig = .default,
         observabilityBus: ObservabilityBus,
         engine: LiveTextRecognitionEngine? = nil,
         objectEngine: LiveObjectDetectionEngine? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.config = config
        self.events = LiveTranslateEvents(bus: observabilityBus, config: config)
        // The shipped engine takes its per-pass rectangle bound **and its
        // recognition settings** from the same config as everything else; an
        // injected engine (a test fake) is used exactly as handed in.
        self.engine = engine
            ?? VisionTextRecognitionEngine(
                maximumRectanglesPerPass: config.trackingMaxRectanglesPerPass,
                config: config)
        // Same rule for the object engine: the shipped one unless a caller
        // hands in its own, and the shipped one takes the block bound from the
        // config like everything else.
        self.objectEngine = objectEngine
            ?? VisionObjectDetectionEngine(maximumObjects: config.maxVisibleBlocks)
        self.now = now
    }

    // MARK: Lifecycle

    /// Prepares the detector for a session. Idempotent.
    ///
    /// Tracking is a SHOULD (FR-LCT-004): when it is switched off, or the
    /// device cannot provide it, the detector runs OCR-only and — in the
    /// second case only — says so once with `tracking_unsupported`. A
    /// configured "off" is not a degradation and is not reported as one.
    func begin() -> Result<Void, LiveTranslateError> {
        let wasIdle = withLock { () -> Bool in
            guard currentState == .idle else { return false }
            currentState = .ready
            // A detection scheduled by an earlier session described a picture
            // this one is not reading.
            objectPassEpoch += 1
            return true
        }
        guard wasIdle else { return .success(()) }

        let engineSupportsTracking = engine.supportsTracking
        withLock { trackingAvailable = config.trackingEnabled && engineSupportsTracking }
        if config.trackingEnabled && !engineSupportsTracking {
            events.trackingUnsupported()
        }

        // Object detection is the same kind of capability: a SHOULD that the
        // detector can do without. There is no config switch for it — the
        // feature always wants the grouping — so the only "off" is a runtime
        // that cannot do it, and that is reported once, honestly.
        let engineSupportsObjects = objectEngine.supportsObjectDetection
        withLock { objectsAvailable = engineSupportsObjects }
        if !engineSupportsObjects {
            events.objectDetectionUnsupported()
        }
        return .success(())
    }

    /// Releases what the session accumulated. Idempotent; the detector is
    /// usable again after a later `begin()`.
    func end() {
        let wasReady = withLock { () -> Bool in
            guard currentState == .ready else { return false }
            currentState = .idle
            trackingAvailable = false
            objectsAvailable = false
            objectPassEpoch += 1
            lastOCRPassAt = nil
            lastObjectPassAt = nil
            rememberedKeys = []
            blockMembers = [:]
            objects = []
            frameDetector.forget()
            sceneChanged = true
            lastPassCrop = .whole
            return true
        }
        guard wasReady else { return }
        engine.forgetRememberedRectangles()
    }

    /// Whether a pass is running. The pipeline uses this to drive the camera's
    /// backpressure flag, which is what makes the frame tap *drop* samples
    /// while Vision is busy (T-006, NFR-LCT-002).
    var isPassInFlight: Bool {
        withLock { passesInFlight > 0 }
    }

    // MARK: Passes

    /// Runs one pass over `frame`.
    ///
    /// The caller drops a failure silently: a failed OCR pass is recorded as
    /// `ocr_pass_failed` and never surfaced, and the next pass tries again.
    func recognize(_ frame: CameraFrame) async -> Result<Pass, LiveTranslateError> {
        // The frame's own window: what the elder can see is what recognition
        // reads (owner follow-up, 2026-09-18). A frame from a session that has
        // neither zoomed nor panned carries `.whole`, and this is then the
        // whole-buffer pass this feature has always run.
        await perform(frame, crop: frame.crop, limit: config.maxVisibleBlocks) { [self] in
            // Measured before the pass kind is chosen, because the answer is
            // what chooses it (a still scene has no geometry worth following).
            noteSceneChange(of: frame)
            return passKind(at: now())
        }
    }

    /// Runs one **OCR** pass over `frame`, always — T-033's still-frame entry.
    ///
    /// A frozen frame is one frame: there is no cadence to respect and nothing
    /// to follow, so the pass kind is not a decision here. That is also what
    /// makes the still path immune to the live session's cadence state — a
    /// snapshot taken right after a live OCR pass cannot come back as a
    /// tracking pass, which carries geometry and no text.
    ///
    /// It is the same pass, on the same serial queue, through the same engine
    /// and the same `VNRecognizeTextRequest` as a live OCR pass: the frame's
    /// own buffer is handed to Vision whole, at its full resolution, with no
    /// crop, no downscale and no second request.
    ///
    /// "Whole" is the still path's contract and stays it even when the live
    /// session was showing a window: the frozen picture the elder is looking at
    /// is drawn from the frame's own buffer (`LiveTranslateSnapshotPath` places
    /// it with `.whole`), so it is the buffer Vision must read, or the boxes
    /// would be geometry of a picture that is not on screen.
    ///
    /// No block cap here (`limit: nil`): the cap exists because the live
    /// overlay can only carry a few readable surfaces, and the still path has no
    /// overlay — every block it resolves is one more line the snapshot card can
    /// show at a legible size.
    func recognizeStillFrame(_ frame: CameraFrame) async -> Result<Pass, LiveTranslateError> {
        await perform(frame, crop: .whole, limit: nil) { .ocr }
    }

    /// **The focused read's way in: one OCR pass over a crop.**
    ///
    /// The still entry's twin, over a smaller picture — the lifecycle guard,
    /// this detector's one serial queue and the one engine, so a crop can never
    /// race the live cadence's own pass.
    ///
    /// Deliberately *not* `perform`: that path exists to map Vision's boxes out
    /// of a frame's window and to group them into blocks, and a crop has
    /// neither — its boxes are its own whole coordinate space, and the focused
    /// read splits the raw strings itself (`LiveTranslateSentenceSplitter`).
    /// The engine's strings come back as the engine read them, in its order.
    ///
    /// The tracking state is dropped **first, and in full** — the engine's
    /// remembered rectangles *and* the detector's own `rememberedKeys`,
    /// `blockMembers`, `lastOCRPassAt` and `sceneChanged` (review finding 11,
    /// see `forgetTrackingForOneOffPass`). Dropping only the rectangles left the
    /// half-reset the review found: the cadence still believed it had geometry
    /// to follow, so the live frame after a crop asked Vision to track strings
    /// the crop had already replaced. The cost is one OCR pass on the live
    /// cadence's next frame (nothing to track re-anchors by OCR), and it buys a
    /// live tracker that can never be handed a crop's coordinates.
    func recognizeCrop(_ pixelBuffer: CVPixelBuffer) async -> Result<[DetectedTextRegion], LiveTranslateError> {
        guard markPassStarted() else {
            // `begin()` was never called, or `end()` has already run: reported
            // rather than run anyway, exactly as the still entry reports it.
            return .failure(.ocrUnavailable(.requestCreationFailed))
        }
        defer { markPassFinished() }
        return await withCheckedContinuation { continuation in
            visionQueue.async { [self] in
                forgetTrackingForOneOffPass()
                do {
                    continuation.resume(returning: .success(try engine.recognizeText(in: pixelBuffer)))
                } catch {
                    // The pass ran and failed. The caller records it and shows
                    // the honest failure; the next tap runs a fresh pass.
                    continuation.resume(returning: .failure(.ocrPassFailed(.requestFailed)))
                }
            }
        }
    }

    /// The one pass implementation both entries share, so "a pass" means one
    /// thing: the lifecycle guard, the serial queue and the pass-kind decision
    /// happen here and nowhere else. `limit` is the pass's block cap, and it is
    /// the caller's because it is a property of *where the blocks are going*,
    /// not of the grouping.
    private func perform(_ frame: CameraFrame,
                         crop: LiveCameraCrop,
                         limit: Int?,
                         kind: @escaping () -> PassKind) async -> Result<Pass, LiveTranslateError> {
        guard markPassStarted() else {
            // No OCR request has been created: `begin()` was never called (or
            // `end()` has already run). Reported rather than run anyway.
            return .failure(.ocrUnavailable(.requestCreationFailed))
        }
        defer { markPassFinished() }

        // One pass at a time: a second caller waits its turn on the queue
        // rather than racing the first pass's request handler.
        return await withCheckedContinuation { continuation in
            visionQueue.async { [self] in
                // The window comes first, before the pass kind is chosen: a
                // window that moved makes every remembered rectangle a
                // rectangle of the *old* picture, and a tracking pass would be
                // handed one of them. Dropping them here is what leaves such a
                // frame with an OCR pass — the one that can re-anchor on
                // recognized text.
                noteCropChange(to: crop)
                switch kind() {
                case .ocr:
                    continuation.resume(returning: runOCRPass(on: frame, crop: crop, limit: limit))
                case .tracking:
                    continuation.resume(returning: runTrackingPass(on: frame, crop: crop))
                }
            }
        }
    }

    /// The pass kind this frame gets. OCR when the cadence is due, when there
    /// is nothing to track, or when the scene has not changed; tracking
    /// otherwise. The camera's frame tap already throttles samples to the same
    /// interval, so a sampled frame is normally due — the tracking branch is
    /// what carries geometry for any frame the caller delivers sooner than the
    /// cadence.
    ///
    /// The scene-change condition is the resource fix and it is not a
    /// micro-optimisation: a tracking pass costs one `VNTrackRectangleRequest`
    /// per remembered rectangle, so a still scene used to buy a burst of Vision
    /// requests per delivered frame for geometry that could only come back the
    /// same. A tracker cannot find movement that is not there, so the whole
    /// pass is skipped and the frame gets the OCR pass it was delivered for
    /// (the tap's reduced cadence is what makes that the *refresh* pass and not
    /// a fourth of a second of wasted Vision).
    func passKind(at time: TimeInterval) -> PassKind {
        let decision: PassKind? = withLock {
            guard trackingAvailable, !rememberedKeys.isEmpty, let last = lastOCRPassAt else {
                return nil
            }
            guard sceneChanged else { return .ocr }
            return time - last >= config.ocrSampleInterval ? .ocr : .tracking
        }
        return decision ?? .ocr
    }

    /// Measures the frame in hand against the last one OCR ran on and records
    /// the answer. Does **not** move the reference: only an OCR pass does that,
    /// so a tracking pass compares against the last frame whose strings are
    /// actually known.
    private func noteSceneChange(of frame: CameraFrame) {
        let changed = frameDetector.isMateriallyDifferent(frame,
                                                          side: config.frameSignatureSide,
                                                          threshold: config.frameChangeThreshold)
        withLock { sceneChanged = changed }
    }

    // MARK: Pass implementation (visionQueue)

    private func runOCRPass(on frame: CameraFrame,
                            crop: LiveCameraCrop,
                            limit: Int?) -> Result<Pass, LiveTranslateError> {
        // Stamped at the start, before recognition: the cadence bounds how
        // often Vision runs, on success and on failure alike, so a failing
        // scene cannot become a per-frame retry loop.
        withLock { lastOCRPassAt = now() }

        do {
            let found = try engine.recognizeText(in: frame.cropped(to: crop))
            // The objects this pass groups with: the cached set, and a fresh
            // detection *scheduled* when the object cadence is due — never
            // awaited. Never a reason for the pass to fail or to wait: a scene
            // with no objects yet is grouped by text geometry, which is what
            // every pass did before this rework.
            let sceneObjects = objectsForPass(in: frame, crop: crop)
            // Vision's boxes are normalized to the buffer it was handed — the
            // window — and every consumer of a box speaks the frame's
            // coordinates, so they are mapped back here, once, where the window
            // is known. The same mapping covers the lines and the objects, which
            // is what lets the grouper compare them at all.
            let lines = found.map {
                SceneTextLine(text: $0.text,
                              normalizedBox: crop.frameBox(ofCropBox: $0.normalizedBox),
                              confidence: $0.confidence,
                              detectedLanguage: $0.detectedLanguage)
            }
            let objects = sceneObjects.map {
                SceneObjectBox(classLabel: $0.classLabel,
                               normalizedBox: $0.normalizedBox,
                               confidence: $0.confidence)
            }
            let blocks = Self.publishedBlocks(
                from: SceneBlockGrouper.group(lines: lines,
                                              objects: objects,
                                              config: config,
                                              limit: limit),
                fallbackLines: lines,
                limit: limit)
            let regions = blocks.map {
                DetectedTextRegion(text: $0.text,
                                   normalizedBox: $0.normalizedBox,
                                   detectedLanguage: $0.detectedLanguage,
                                   confidence: $0.confidence,
                                   blockIdentity: $0.identityKey)
            }
            withLock {
                rememberedKeys = Set(regions.map(\.text))
                // The block map the tracking pass re-keys through. Two blocks
                // can legitimately share a text (the same sign twice in one
                // frame), and the first is as good as the second: the entry
                // exists to turn line geometry into block geometry, and either
                // block's members answer that.
                blockMembers = Dictionary(blocks.map { ($0.text, $0.memberStrings) },
                                          uniquingKeysWith: { first, _ in first })
                // This is "the last OCR'd frame" every later comparison is
                // made against. Committed on success only: a failed pass made
                // no claim about the scene, and letting a frame Vision could
                // not read become the baseline would gate the next pass against
                // a picture nothing was recognized in.
                frameDetector.remember(frame, side: config.frameSignatureSide)
                sceneChanged = false
            }
            events.ocrPass(regionCount: regions.count)
            // An OCR pass has no tracked geometry to report — it is the
            // anchor, not the carrier. Zero regions is the empty-state hint,
            // not a failure.
            return .success(Pass(regions: regions, trackedBoxes: [:], objects: sceneObjects))
        } catch {
            let failure = (error as? LiveTranslateError) ?? .ocrPassFailed(.requestFailed)
            events.ocrPassFailed(failure)
            return .failure(failure)
        }
    }

    /// The blocks a pass publishes: the grouper's own decision, or — when it
    /// formed none — **one block per recognized line**.
    ///
    /// The never-empty rule, at the one place a pass decides what it is
    /// publishing (see `SceneBlockGrouper.perLineBlocks`). The alternative is
    /// the failure the owner's device verdict reported: lines recognized, no
    /// blocks formed, and therefore nothing published — which the overlay
    /// renders as its empty state, "I don't see any text yet", over a picture
    /// full of text the pass had just read.
    ///
    /// A group failure degrades the grouping. It may never degrade the text:
    /// the per-line blocks are the publication this feature shipped before
    /// grouping existed, so the elder loses the *merge* and not the words.
    static func publishedBlocks(from blocks: [SceneBlock],
                                fallbackLines lines: [SceneTextLine],
                                limit: Int?) -> [SceneBlock] {
        guard blocks.isEmpty else { return blocks }
        return SceneBlockGrouper.perLineBlocks(from: lines, limit: limit)
    }

    private func runTrackingPass(on frame: CameraFrame, crop: LiveCameraCrop) -> Result<Pass, LiveTranslateError> {
        do {
            let followed = try engine.followRememberedRectangles(in: frame.cropped(to: crop))
            let frameBoxes = followed.mapValues { crop.frameBox(ofCropBox: $0) }
            let tracked = Self.blockBoxes(from: frameBoxes, members: withLock { blockMembers })
            // Geometry only: no region and no string can come out of here.
            return .success(Pass(regions: [], trackedBoxes: tracked))
        } catch {
            degradeTracking()
            return .failure(.trackingUnsupported)
        }
    }

    /// Turns the per-line geometry a tracking pass followed into the per-block
    /// geometry the stabiliser tracks: a block's box is the union of the boxes
    /// its members are still tracked at.
    ///
    /// A block with no tracked member is **absent** from the result rather than
    /// reported at stale geometry — and that is the documented tracking-loss
    /// case, unchanged in meaning: the stabiliser holds the last OCR-confirmed
    /// geometry for it. Putting a block's key in with a box nothing was
    /// followed at would be an invented observation.
    ///
    /// Pure, and a function of two dictionaries rather than of Vision: the
    /// re-keying rule is testable without a camera, which matters because it is
    /// the one place where a text-keyed engine and a block-keyed stabiliser
    /// have to agree.
    static func blockBoxes(from followed: [String: NormalizedBox],
                           members: [String: [String]]) -> [String: NormalizedBox] {
        var boxes: [String: NormalizedBox] = [:]
        for (block, lines) in members {
            let tracked = lines.compactMap { followed[$0] }
            guard !tracked.isEmpty else { continue }
            boxes[block] = SceneBlockGrouper.union(tracked)
        }
        return boxes
    }

    /// The scene's objects for this pass: **the cached set, always** — and a
    /// fresh detection *scheduled* when the object cadence is due.
    ///
    /// The cache is the whole point of the cadence. An object pass costs one
    /// saliency request plus up to one classification request per object, and
    /// its answer — which appliances are in the picture — is not a
    /// frame-by-frame property. Running it every pass would spend the frame
    /// budget re-learning the same kitchen.
    ///
    /// **The pass never waits for a detection.** The object pass is the slow
    /// pass, and the OCR pass is the one the elder is waiting on, so the
    /// detection runs on `objectQueue` — off this pass's critical path — and
    /// what it finds groups the *next* pass of the scene. That is the isolation
    /// the owner's device verdict ("fires after a long delay") is about: a
    /// saliency request that takes a second, or that never returns, or that the
    /// runtime refuses outright, costs the text pass nothing at all. Its worst
    /// case is the one it always had — the pass groups by text geometry, which
    /// is what every pass did before the rework.
    ///
    /// The cached set is what the pass reports. A detection that has not landed
    /// yet is not an object set this pass saw, and reporting it as one would be
    /// claiming a scene description the pass did not have.
    ///
    /// **The ledger is monotone in what it knows.** A detection that finds
    /// nothing, or that is refused, adds nothing and removes nothing
    /// (`scheduleObjectPass`); only a detection with objects to report replaces
    /// what the session already knows. An object pass is a *cadenced* claim
    /// about a kitchen, and a scene does not stop containing a microwave
    /// because one saliency request came back empty — while acting as if it
    /// does re-groups the very text the previous pass had grouped, which is the
    /// churn the owner's device log shows (`object_pass success=1` followed by
    /// `object_pass empty count=0`, over an unchanged scene).
    ///
    /// The one thing that does clear it is a genuine change of picture: the
    /// window the display is showing (`noteCropChange`), because those boxes
    /// are geometry of a buffer this session is no longer reading.
    private func objectsForPass(in frame: CameraFrame, crop: LiveCameraCrop) -> [DetectedSceneObject] {
        let due = withLock { () -> Bool in
            // One at a time: a detection that outlives its cadence must not
            // queue a second behind it, however slow the runtime is.
            guard objectsAvailable, !objectPassInFlight else { return false }
            guard let last = lastObjectPassAt else { return true }
            return now() - last >= config.objectPassCadenceSeconds
        }
        if due { scheduleObjectPass(in: frame, crop: crop) }
        return withLock { objects }
    }

    /// Starts one object pass on the object queue. Returns immediately.
    ///
    /// Stamped at *schedule* time, like the OCR cadence and for the same
    /// reason: a failing object pass must not become a per-frame retry loop.
    /// The epoch is captured with it, so a detection that lands after the
    /// session ended, restarted or moved its window is discarded rather than
    /// describing a picture this session is no longer reading.
    private func scheduleObjectPass(in frame: CameraFrame, crop: LiveCameraCrop) {
        let epoch = withLock { () -> Int in
            lastObjectPassAt = now()
            objectPassInFlight = true
            return objectPassEpoch
        }
        objectQueue.async { [self] in
            let landed: Result<[DetectedSceneObject], Error>
            do {
                let found = try objectEngine.detectObjects(in: frame.cropped(to: crop))
                landed = .success(found.map {
                    DetectedSceneObject(classLabel: $0.classLabel,
                                        normalizedBox: crop.frameBox(ofCropBox: $0.normalizedBox),
                                        confidence: $0.confidence)
                })
            } catch {
                landed = .failure(error)
            }

            // Whatever happened to the session meanwhile, the slot is free
            // again: the in-flight flag is a property of this pass, not of the
            // scene it was measuring.
            let stale = withLock { () -> Bool in
                objectPassInFlight = false
                return objectPassEpoch != epoch
            }
            guard !stale else { return }

            switch landed {
            case .success(let mapped):
                // An object pass that found nothing **adds nothing**: the
                // objects this session already knows are not un-found by a
                // saliency request that returned an empty set, and clearing the
                // ledger here is what re-keyed the owner's scene from one pass
                // to the next (`object_pass outcome=empty`, on the device log,
                // over the very text the previous pass had grouped). The
                // ledger is a claim about the scene, so only a detection with
                // something to say replaces it.
                withLock { if !mapped.isEmpty { objects = mapped } }
                events.objectPass(objectCount: mapped.count)
            case .failure(let error):
                // The same rule for a refused pass: the refusal is a fact about
                // the runtime, not about the kitchen. What the last successful
                // detection described is still the best answer the session has,
                // so the ledger is left as it stands.
                //
                // The refusal is recorded with its taxonomy code, and the pass
                // stops asking rather than retrying every frame (the cadence is
                // stamped, so a broken runtime is one event and one request, not
                // a loop). `object_detection_unsupported` is for the runtime
                // that never had the capability, and `begin` is where that one
                // is announced.
                events.objectPassFailed((error as? LiveTranslateError)
                                        ?? .ocrPassFailed(.requestFailed))
                stopAskingForObjects()
            }
        }
    }

    /// Waits for every object pass this detector has scheduled to land.
    ///
    /// The object pass is asynchronous by design — it must never delay a text
    /// pass — which makes "the detection has landed" an event rather than a
    /// return value. A test (and a diagnostic) that wants to observe what the
    /// object pass did after the fact waits here: the object queue is serial,
    /// so this returns once the passes already scheduled have finished.
    func awaitObjectPass() async {
        await withCheckedContinuation { continuation in
            objectQueue.async { continuation.resume() }
        }
    }

    /// The window a pass runs on, and what a change of window means.
    ///
    /// The engine remembers the last OCR pass's rectangles (`VNRectangleObservation`s,
    /// normalized to the buffer *that pass saw*), and a tracker follows one of
    /// them in whatever buffer it is handed next. Two buffers cropped
    /// differently are two different coordinate spaces, so a window that moves
    /// makes every remembered rectangle a rectangle of the wrong picture:
    /// following one would put a region's geometry somewhere the elder never
    /// pointed, and — worse — the text attached to it would then be drawn over
    /// a *different* label. The rectangles are dropped before the first pass at
    /// a new window, which costs the tracker its anchors and nothing else: the
    /// stabiliser holds the last OCR-confirmed geometry until the next OCR pass
    /// re-anchors on recognized text (FR-LCT-004's documented tracking loss).
    ///
    /// The remembered *keys* go with them, for the same reason at the
    /// detector's own level: a key whose rectangle is gone must not keep the
    /// pass-kind decision thinking there is geometry to follow. Both drops
    /// happen *before* the pass kind is chosen (`perform`), so the first frame
    /// at a new window cannot come back as a tracking pass carrying an old
    /// rectangle — it gets the OCR pass that re-anchors on text.
    private func noteCropChange(to crop: LiveCameraCrop) {
        let changed = withLock { () -> Bool in
            guard lastPassCrop != crop else { return false }
            lastPassCrop = crop
            rememberedKeys = []
            blockMembers = [:]
            // The cached objects are geometry of the old window: their boxes
            // were mapped out of a buffer this session is no longer reading, so
            // grouping the new window's text with them would put a panel over
            // whatever now happens to sit where the old appliance was. Dropped,
            // and the pass is made due again, so the first OCR pass at the new
            // window detects the objects that are actually in it.
            objects = []
            lastObjectPassAt = nil
            // A detection in flight measured the *old* window's picture, so its
            // boxes describe pixels this session has panned away from.
            objectPassEpoch += 1
            return true
        }
        guard changed else { return }
        engine.forgetRememberedRectangles()
    }

    /// Drops the live cadence's own text-tracking state for a pass that is
    /// **not** the live window — the focused read's crop (review finding 11).
    ///
    /// `noteCropChange`'s rule, applied to a one-off buffer rather than to a
    /// moved window, and for the same reason: nothing that follows a crop's
    /// picture may be reused. The crop recognizes into the same engine, so the
    /// rectangles it leaves behind are the crop's, and a later tracking pass
    /// seeded with them would follow boxes of a buffer this detector is no
    /// longer reading. The rectangles were the *only* state this entry used to
    /// drop, which is the half-reset the review found: `rememberedKeys` still
    /// named strings the crop had replaced, so `passKind` answered `.tracking`
    /// on the live cadence's very next frame and asked Vision to follow geometry
    /// that no longer existed; `lastOCRPassAt` still anchored the sample
    /// interval to the pass *before* the crop; and `sceneChanged` still claimed
    /// the scene was the one the remembered keys were read from.
    ///
    /// So the detector's own text state goes with the rectangles — the keys, the
    /// blocks grouped under them, the OCR anchor and the scene flag — and the
    /// live window's next pass is an OCR pass that re-anchors on recognized
    /// text. That single re-anchoring pass is the documented cost of a tracker
    /// that has lost its anchors (FR-LCT-004), and it is the same cost
    /// `noteCropChange` pays.
    ///
    /// **The object cache stays.** Unlike a pan, a crop does not move the live
    /// window: the cached objects are geometry of the window this detector is
    /// still reading, the crop pass does not write them, and dropping them would
    /// make the live picture's panels wait on a detection pass for a window that
    /// never changed.
    private func forgetTrackingForOneOffPass() {
        withLock {
            rememberedKeys = []
            blockMembers = [:]
            lastOCRPassAt = nil
            sceneChanged = true
        }
        engine.forgetRememberedRectangles()
    }

    /// Turning tracking off for the session, announced exactly once: an honest
    /// event rather than a silent capability loss.
    private func degradeTracking() {
        let firstTime = withLock { () -> Bool in
            guard trackingAvailable else { return false }
            trackingAvailable = false
            return true
        }
        if firstTime { events.trackingUnsupported() }
    }

    /// The object pass is not asked for again. Says nothing on the event bus:
    /// the two ways this happens — a runtime without the capability, and a
    /// request it refused — have already been recorded by their own events, and
    /// the difference is the whole reason they are two events rather than one
    /// call to this function that reports as well as stops.
    private func stopAskingForObjects() {
        withLock { objectsAvailable = false }
    }

    // MARK: Plumbing

    private func markPassStarted() -> Bool {
        withLock {
            guard currentState == .ready else { return false }
            passesInFlight += 1
            return true
        }
    }

    private func markPassFinished() {
        withLock { passesInFlight -= 1 }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
