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

    init() {
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
        for (text, rectangle) in rectangles {
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

    // MARK: Init

    init(config: LiveTranslateConfig = .default,
         observabilityBus: ObservabilityBus,
         engine: LiveTextRecognitionEngine = VisionTextRecognitionEngine(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.config = config
        self.events = LiveTranslateEvents(bus: observabilityBus, config: config)
        self.engine = engine
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
        await perform(frame) { [self] in passKind(at: now()) }
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
    func recognizeStillFrame(_ frame: CameraFrame) async -> Result<Pass, LiveTranslateError> {
        await perform(frame) { .ocr }
    }

    /// The one pass implementation both entries share, so "a pass" means one
    /// thing: the lifecycle guard, the serial queue and the pass-kind decision
    /// happen here and nowhere else.
    private func perform(_ frame: CameraFrame,
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
                switch kind() {
                case .ocr:
                    continuation.resume(returning: runOCRPass(on: frame))
                case .tracking:
                    continuation.resume(returning: runTrackingPass(on: frame))
                }
            }
        }
    }

    /// The pass kind this frame gets. OCR when the cadence is due or when there
    /// is nothing to track; tracking otherwise. The camera's frame tap already
    /// throttles samples to the same interval, so a sampled frame is normally
    /// due — the tracking branch is what carries geometry for any frame the
    /// caller delivers sooner than the cadence.
    func passKind(at time: TimeInterval) -> PassKind {
        let decision: PassKind? = withLock {
            guard trackingAvailable, !rememberedKeys.isEmpty, let last = lastOCRPassAt else {
                return nil
            }
            return time - last >= config.ocrSampleInterval ? .ocr : .tracking
        }
        return decision ?? .ocr
    }

    // MARK: Pass implementation (visionQueue)

    private func runOCRPass(on frame: CameraFrame) -> Result<Pass, LiveTranslateError> {
        // Stamped at the start, before recognition: the cadence bounds how
        // often Vision runs, on success and on failure alike, so a failing
        // scene cannot become a per-frame retry loop.
        withLock { lastOCRPassAt = now() }

        do {
            let regions = try engine.recognizeText(in: frame.pixelBuffer)
            withLock { rememberedKeys = Set(regions.map(\.text)) }
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

    private func runTrackingPass(on frame: CameraFrame) -> Result<Pass, LiveTranslateError> {
        do {
            let tracked = try engine.followRememberedRectangles(in: frame.pixelBuffer)
            // Geometry only: no region and no string can come out of here.
            return .success(Pass(regions: [], trackedBoxes: tracked))
        } catch {
            degradeTracking()
            return .failure(.trackingUnsupported)
        }
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
