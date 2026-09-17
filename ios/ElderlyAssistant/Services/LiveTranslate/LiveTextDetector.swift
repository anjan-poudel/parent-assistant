import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Vision

// C02 — on-device text detection (T-007, FR-LCT-003/004, NFR-LCT-001/002/005).
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

/// The shipped engine: Vision, on device, one request kind per entry point.
final class VisionTextRecognitionEngine: LiveTextRecognitionEngine {

    private let textRequest = VNRecognizeTextRequest()
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

    /// The bound defaults to the shipped config's, so a parameterless
    /// construction is the same engine the detector builds — the cap is a
    /// policy of the feature and not a property of one call site.
    init(maximumRectanglesPerPass: Int = LiveTranslateConfig.default.trackingMaxRectanglesPerPass) {
        self.maximumRectanglesPerPass = maximumRectanglesPerPass
        textRequest.recognitionLevel = .accurate
        // The capability check the design asks for (C02): automatic language
        // detection is an iOS 16-and-later property, and the deployment target
        // supports it. When it is not applied, `detectedLanguage` stays `nil`
        // — a missing report, never a substituted value.
        if #available(iOS 16.0, *) {
            textRequest.automaticallyDetectsLanguage = true
        }
    }

    /// Rectangle tracking has been part of Vision since iOS 11 and the
    /// request's initializer is non-failable on a supported OS, so there is no
    /// probe that could honestly answer "no" here. A device where the request
    /// cannot be *run* is handled where it happens: the tracking pass throws,
    /// and the detector degrades with the same honest event.
    var supportsTracking: Bool { true }

    func recognizeText(in pixelBuffer: CVPixelBuffer) throws -> [LiveTextDetector.DetectedTextRegion] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([textRequest])
        } catch {
            throw LiveTranslateError.ocrPassFailed(.requestFailed)
        }

        var regions: [LiveTextDetector.DetectedTextRegion] = []
        var remembered: [String: VNRectangleObservation] = [:]
        for observation in textRequest.results ?? [] {
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
    struct DetectedTextRegion: Equatable {
        let text: String
        /// The feature's one box representation — the same `NormalizedBox` the
        /// stabiliser, the placement mapper and the shipped overlay maths
        /// consume (T-009/T-020, NFR-LCT-012).
        let normalizedBox: NormalizedBox
        /// Vision's report, or `nil` when it did not make one. Never guessed.
        let detectedLanguage: String?
        let confidence: Double
    }

    /// One pass's output. An OCR pass fills `regions` and leaves
    /// `trackedBoxes` empty; a tracking pass fills `trackedBoxes` and leaves
    /// `regions` empty. A caller that reads text from `trackedBoxes` has
    /// nothing to read: there is no string in it.
    struct Pass: Equatable {
        let regions: [DetectedTextRegion]
        /// Tracked key → geometry, for the keys the tracker still holds. A
        /// missing key is a tracking loss.
        let trackedBoxes: [String: NormalizedBox]
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
    private let now: () -> TimeInterval

    /// Vision runs here and nowhere else: one pass at a time, so two passes
    /// can never share a request handler.
    private let visionQueue = DispatchQueue(label: "com.elderlyassistant.livetranslate.vision")
    private let lock = NSLock()

    // MARK: State (lock-guarded)

    private var currentState: State = .idle
    private var trackingAvailable = false
    private var lastOCRPassAt: TimeInterval?
    private var rememberedKeys: Set<String> = []
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
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.config = config
        self.events = LiveTranslateEvents(bus: observabilityBus, config: config)
        // The shipped engine takes its per-pass rectangle bound from the same
        // config as everything else; an injected engine (a test fake) is used
        // exactly as handed in.
        self.engine = engine
            ?? VisionTextRecognitionEngine(
                maximumRectanglesPerPass: config.trackingMaxRectanglesPerPass)
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
            return true
        }
        guard wasIdle else { return .success(()) }

        let engineSupportsTracking = engine.supportsTracking
        withLock { trackingAvailable = config.trackingEnabled && engineSupportsTracking }
        if config.trackingEnabled && !engineSupportsTracking {
            events.trackingUnsupported()
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
            lastOCRPassAt = nil
            rememberedKeys = []
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
        await perform(frame, crop: frame.crop) { [self] in
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
    func recognizeStillFrame(_ frame: CameraFrame) async -> Result<Pass, LiveTranslateError> {
        await perform(frame, crop: .whole) { .ocr }
    }

    /// The one pass implementation both entries share, so "a pass" means one
    /// thing: the lifecycle guard, the serial queue and the pass-kind decision
    /// happen here and nowhere else.
    private func perform(_ frame: CameraFrame,
                         crop: LiveCameraCrop,
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
                    continuation.resume(returning: runOCRPass(on: frame, crop: crop))
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

    private func runOCRPass(on frame: CameraFrame, crop: LiveCameraCrop) -> Result<Pass, LiveTranslateError> {
        // Stamped at the start, before recognition: the cadence bounds how
        // often Vision runs, on success and on failure alike, so a failing
        // scene cannot become a per-frame retry loop.
        withLock { lastOCRPassAt = now() }

        do {
            let found = try engine.recognizeText(in: frame.cropped(to: crop))
            let regions = found.map {
                DetectedTextRegion(text: $0.text,
                                   // Vision's boxes are normalized to the
                                   // buffer it was handed — the window — and
                                   // every consumer of a region box speaks the
                                   // frame's coordinates, so they are mapped
                                   // back here, once, where the window is
                                   // known.
                                   normalizedBox: crop.frameBox(ofCropBox: $0.normalizedBox),
                                   detectedLanguage: $0.detectedLanguage,
                                   confidence: $0.confidence)
            }
            withLock {
                rememberedKeys = Set(regions.map(\.text))
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
            return .success(Pass(regions: regions, trackedBoxes: [:]))
        } catch {
            let failure = (error as? LiveTranslateError) ?? .ocrPassFailed(.requestFailed)
            events.ocrPassFailed(failure)
            return .failure(failure)
        }
    }

    private func runTrackingPass(on frame: CameraFrame, crop: LiveCameraCrop) -> Result<Pass, LiveTranslateError> {
        do {
            let followed = try engine.followRememberedRectangles(in: frame.cropped(to: crop))
            let tracked = followed.mapValues { crop.frameBox(ofCropBox: $0) }
            // Geometry only: no region and no string can come out of here.
            return .success(Pass(regions: [], trackedBoxes: tracked))
        } catch {
            degradeTracking()
            return .failure(.trackingUnsupported)
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
            return true
        }
        guard changed else { return }
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
