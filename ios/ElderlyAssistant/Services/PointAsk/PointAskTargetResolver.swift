import CoreGraphics
import Foundation
import Vision

/// The tap hit-test: which box of the frame the elder pointed at, in the
/// feature's one box representation (`NormalizedBox`, top-left origin,
/// 0…1 of the frame) plus the same box in pixel coordinates for the crop.
///
/// One box at a time, by design (§4: the elder's hand tremor makes a
/// two-finger two-box gesture a non-goal): a tap either lands on one
/// saliency box (the largest containing box wins) or — when no box contains
/// it — anchors a pad box centred on the tap. A tap outside an anchored box
/// therefore *re-anchors*: the box follows the tap, never a stale position.
struct ResolvedPointAskTarget: Equatable {

    let normalizedBox: NormalizedBox
    /// The same box in pixel coordinates (top-left origin) for the crop.
    let pixelRect: CGRect
    let source: PointAskTargetSource
    /// [YOLO] The detector's COCO label for the winning box, when the
    /// source is `.yolo`. Carried into the analysis so the ladder-1
    /// answer can name the object.
    let detectedLabel: String?
}

/// How a tap's box was chosen. Closed vocabulary — it travels as the
/// `origin` token on `tap_anchored` (the `PointAskEvents` contract).
enum PointAskTargetSource: String, Equatable {
    /// [YOLO] A real object-detector box (YOLO11n on the Neural Engine) —
    /// the box that WRAPS the object the elder pointed at, with a class
    /// label. The preferred source.
    case yolo
    /// One of the objectness-saliency boxes contained the tap.
    case saliency
    /// The foreground-instance mask contained the tap (opt-in spike
    /// path, behind `supportsMasks`).
    case mask
    /// No box contained the tap: the anchor is the configured pad box
    /// around the point.
    case pad
}

/// The mask seam: a foreground-instance mask pass can say, at pixel
/// precision, whether the tapped point is on the object the elder pointed
/// at — the saliency boxes' weaker answer (a rectangle, not a silhouette).
///
/// The seam exists so the resolver is testable with a fake and so the
/// shipped engine stays a spike: it is wired only when the config's
/// `maskEngineEnabled` opt-in is on, and it is consulted only while
/// `supportsMasks` holds.
protocol PointAskMaskProbing: AnyObject {
    /// Whether a mask request can be created and run here. The probe's
    /// verdict: true until the first real attempt proves otherwise, then
    /// false for the process lifetime — a device where the request exists
    /// but cannot run is not retried per tap.
    var supportsMasks: Bool { get }

    /// The foreground instance the tapped point lies on, as its TIGHT
    /// bounding box (normalized, top-left origin) — the extent of the
    /// instance's own pixels, the way an object detector boxes an object,
    /// not a pad around the finger. Returns nil when the tapped point is
    /// NOT on an instance (background) — the resolver then falls to the
    /// saliency/pad ladder. Throws when the request could not be run at
    /// all — a refusal, not an empty answer.
    func maskBox(at point: CGPoint, in pixelBuffer: CVPixelBuffer) throws -> NormalizedBox?
}

/// The shipped mask engine: `VNGenerateForegroundInstanceMaskRequest`, a
/// spike wrapper (research §Q8 Phase 1: "spike, not default").
///
/// The probe is the first attempt, cached: `supportsMasks` reports true
/// until a real pass fails, and a failed pass flips it off permanently —
/// the honest shape of "the request exists on this OS, but this device
/// cannot run it" (the same honesty
/// `VisionObjectDetectionEngine.supportsObjectDetection` documents for its
/// own seam). The request itself is an iOS 17 API; below that the probe
/// reports false before anything is asked of Vision, so an iOS 16 device
/// is a permanent no — never a crash, never a retry.
///
/// The mask pixel is read at the tap's scaled position; the returned buffer
/// carries the instance index (0) where the instance is, and the background
/// label elsewhere. This path costs one Vision request per tap and is
/// opt-in exactly because its device latency is unmeasured (ship gate:
/// "device spike for mask-engine latency — opt-in stays behind the probe").
final class PointAskMaskEngine: PointAskMaskProbing {

    private let lock = NSLock()
    private var probeFailed = false
    /// [MASK-OBSERVABILITY] (2026-09-20) The evidence trail this pass was
    /// missing: the owner's device report ("bounding boxes are just
    /// squares") is the pad fallback, and the mask is the one class-free
    /// pass that would hug the pointed object — but a failed probe flips
    /// it off silently and permanently, and a "not on an instance" answer
    /// looks identical in the capture. The same per-pass shape the YOLO
    /// engine emits (`yolo_pass`), so the next capture can tell the three
    /// pad producers apart.
    private let observabilityBus: ObservabilityBus?

    init(observabilityBus: ObservabilityBus? = nil) {
        self.observabilityBus = observabilityBus
    }

    var supportsMasks: Bool {
        lock.lock(); defer { lock.unlock() }
        guard #available(iOS 17, *) else { return false }
        return !probeFailed
    }

    /// One pass's content-free self-portrait, on the same vocabulary the
    /// resolver's `origin` token already uses: how many instances, and
    /// whether the tapped point sat on one. Never the image, never text.
    private func emitPass(outcome: String,
                          errorCode: String?,
                          count: Int,
                          pointOnInstance: Bool? = nil) {
        guard let observabilityBus else { return }
        var metadata: [String: String] = ["count": "\(count)"]
        if let pointOnInstance { metadata["point_on_instance"] = pointOnInstance ? "true" : "false" }
        observabilityBus.emit(ObservabilityEvent(
            component: "pointask",
            eventType: "mask_pass",
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: metadata
        ))
    }

    func maskBox(at point: CGPoint, in pixelBuffer: CVPixelBuffer) throws -> NormalizedBox? {
        guard #available(iOS 17, *) else {
            emitPass(outcome: "failed", errorCode: "os_too_old", count: 0)
            throw PointAskError.maskPassFailed
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        let mask: CVPixelBuffer
        do {
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            // The observation's own scaled-mask renderer: the instance's
            // pixels carry the index (0), the background the other label.
            guard let observation = request.results?.first else {
                lock.lock(); probeFailed = true; lock.unlock()
                emitPass(outcome: "failed", errorCode: "no_observation", count: 0)
                throw PointAskError.maskPassFailed
            }
            mask = try observation.generateScaledMaskForImage(forInstances: [0],
                                                              from: handler)
        } catch {
            lock.lock(); probeFailed = true; lock.unlock()
            emitPass(outcome: "failed", errorCode: "request_failed", count: 0)
            throw PointAskError.maskPassFailed
        }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        guard width > 0, height > 0 else { return nil }
        let x = min(max(Int(CGFloat(width) * point.x), 0), width - 1)
        let y = min(max(Int(CGFloat(height) * point.y), 0), height - 1)
        guard Self.pixelValue(atX: x, y: y, in: mask) == 0 else {
            // The pass ran and the point is background — an honest "no",
            // distinct from a failed request: the resolver falls to the
            // saliency/pad ladder, and the event says which it was.
            emitPass(outcome: "success", errorCode: nil,
                     count: 0, pointOnInstance: false)
            return nil
        }
        let extent = Self.instanceExtent(in: mask)
        emitPass(outcome: "success", errorCode: nil,
                 count: extent == nil ? 0 : 1, pointOnInstance: true)
        return extent
    }

    /// The tight bounding box of the instance's pixels — min/max of every
    /// pixel carrying the instance label (0) — normalized against the mask
    /// buffer's own size (which is the frame's size, top-left origin).
    /// This is the object-detector behaviour: the box wraps the object's
    /// silhouette, not a pad around the finger.
    static func instanceExtent(in mask: CVPixelBuffer) -> NormalizedBox? {
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        guard width > 0, height > 0 else { return nil }
        guard CVPixelBufferLockBaseAddress(mask, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let floatsPerRow = bytesPerRow / MemoryLayout<Float>.size
        let pointer = base.assumingMemoryBound(to: Float.self)

        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for row in 0..<height {
            let rowBase = row * floatsPerRow
            for column in 0..<width where pointer[rowBase + column] == 0 {
                if column < minX { minX = column }
                if column > maxX { maxX = column }
                if row < minY { minY = row }
                if row > maxY { maxY = row }
            }
        }
        guard maxX >= 0 else { return nil }
        return NormalizedBox(xMin: Double(minX) / Double(width),
                             yMin: Double(minY) / Double(height),
                             xMax: Double(maxX + 1) / Double(width),
                             yMax: Double(maxY + 1) / Double(height))
    }

    /// Reads one pixel of the scaled mask (a single-channel float buffer).
    /// `nil` when the buffer cannot be locked — an unreadable mask is not a
    /// "yes" (fail closed: the resolver falls to the saliency/pad path).
    static func pixelValue(atX x: Int, y: Int, in mask: CVPixelBuffer) -> Float? {
        guard CVPixelBufferLockBaseAddress(mask, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let pointer = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
        return pointer[x]
    }
}

/// The tap → target stage (research §Q6 stage 1: <50 ms, refresh only when
/// the cached saliency pass is stale).
///
/// [YOLO] The evidence order is detector-first: when the `yoloEngine` is
/// wired and its artifact is installed, the tap box is a REAL YOLO11n
/// detection box with a class label (the owner's device-test verdict).
/// Below that, the geometry comes from the **existing**
/// `LiveObjectDetectionEngine` (the shipped `VisionObjectDetectionEngine`
/// over `VNGenerateObjectnessBasedSaliencyImageRequest` — the same engine
/// the live-translate detector runs its scene-block pass with, used here
/// for its boxes only, on tap, never per frame). The saliency result is
/// cached for `saliencyCacheSeconds`: a second tap on the same scene is a
/// hit-test over remembered boxes and costs no Vision pass.
final class PointAskTargetResolver {

    private let objectEngine: LiveObjectDetectionEngine
    private let maskEngine: PointAskMaskProbing?
    private let yoloEngine: PointAskObjectDetecting?
    private let config: PointAskConfig
    private let events: PointAskEvents
    private let observabilityBus: ObservabilityBus
    private let now: () -> Date

    private var cachedBoxes: [NormalizedBox] = []
    private var cachedAt: Date?
    /// [MASK-OBSERVABILITY] Whether this session has already reported the
    /// mask engine's state once. The report exists so a mask that is
    /// unavailable — a failed probe, an unwired engine, an OS below 17 —
    /// can never degrade every tap to a pad *silently* again (the owner's
    /// "bounding boxes are just squares" session produced zero mask_pass
    /// events, which could not tell a stale build from a dead probe).
    private var maskStateReported = false

    init(objectEngine: LiveObjectDetectionEngine,
         maskEngine: PointAskMaskProbing? = nil,
         yoloEngine: PointAskObjectDetecting? = nil,
         config: PointAskConfig = .default,
         observabilityBus: ObservabilityBus,
         now: @escaping () -> Date = Date.init) {
        self.objectEngine = objectEngine
        self.maskEngine = maskEngine
        self.yoloEngine = yoloEngine
        self.config = config
        self.events = PointAskEvents(bus: observabilityBus, config: config)
        self.observabilityBus = observabilityBus
        self.now = now
    }

    /// The box the tap anchors. `point` is normalized against the frame
    /// (top-left origin, 0…1); the frame is the one the elder tapped on.
    ///
    /// Order of evidence, class-free first ([CLASS-FREE-FIRST],
    /// 2026-09-20 — the owner's 06:03 capture showed YOLO11n hallucinating
    /// books on a scene with none, and the false boxes contained the
    /// taps, so a classed detector must never speak first):
    ///  1. the opt-in mask pass, while `supportsMasks` holds — the
    ///     silhouette answer: pixel-precise, class-free, the one pass
    ///     that hugs an arbitrary object;
    ///  2. the saliency boxes, refreshed only when the cached pass is
    ///     stale or absent — class-free objectness;
    ///  3. [YOLO] the classed object-detector pass, while the engine is
    ///     available — trusted only when both class-free passes missed
    ///     and its box CONTAINS the tap, carrying the detector's label;
    ///  4. the pad box around the tap — the honest fallback that keeps
    ///     "tap outside re-anchors" true even when every pass fails or
    ///     finds nothing.
    ///
    /// A failing mask pass degrades to the saliency path (the probe flips
    /// and the resolver never asks again), a failing saliency pass to the
    /// YOLO pass, and a failing YOLO pass to the pad box. Never an error
    /// to the elder — the box is a pointer, not an answer
    /// (FR-LCT-004's degradation shape).
    func resolve(tap point: CGPoint, in pixelBuffer: CVPixelBuffer) -> ResolvedPointAskTarget {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer))
        let clamped = CGPoint(x: min(max(point.x, 0), 1),
                              y: min(max(point.y, 0), 1))

        // [MASK-OBSERVABILITY] One report per session, before the ladder:
        // whether the mask engine exists and whether it will be consulted.
        // A session of pad-only anchors with `mask_probe state=unavailable`
        // is a dead probe, not a missing build — the distinction the
        // owner's "bounding boxes are just squares" session could not make.
        if !maskStateReported {
            maskStateReported = true
            let state: String
            if let maskEngine {
                state = maskEngine.supportsMasks ? "available" : "unavailable"
            } else {
                state = "unwired"
            }
            observabilityBus.emit(ObservabilityEvent(
                component: "pointask",
                eventType: "mask_probe",
                durationMs: nil,
                outcome: state == "available" ? "success" : "degraded",
                errorCode: nil,
                metadata: ["state": state]
            ))
        }

        // [CLASS-FREE-FIRST] (2026-09-20) The ladder runs the class-free
        // passes first: the owner's 06:03 capture showed YOLO11n
        // hallucinating books (0.27–0.69) on a scene with none — a tub of
        // moisturiser — and the false boxes CONTAINED the taps, so the
        // classed detector anchored ghosts. The mask is pixel-precise and
        // class-free; the saliency pass is class-free; only when both miss
        // is a classed YOLO box trusted, and then only when it contains
        // the tap. The pad remains the final honest fallback.
        if let maskEngine, maskEngine.supportsMasks,
           let maskBox = try? maskEngine.maskBox(at: clamped, in: pixelBuffer) {
            return anchor(maskBox, size: size, source: .mask, detectedLabel: nil)
        }

        if let saliencyBox = saliencyBox(containing: clamped, in: pixelBuffer) {
            return anchor(saliencyBox, size: size, source: .saliency, detectedLabel: nil)
        }

        if let yoloEngine, yoloEngine.isAvailable,
           let yolo = yoloDetection(using: yoloEngine, in: pixelBuffer, containing: clamped) {
            return anchor(yolo.normalizedBox, size: size, source: .yolo,
                          detectedLabel: yolo.label)
        }
        return anchor(Self.padBox(around: clamped), size: size, source: .pad,
                      detectedLabel: nil)
    }

    /// How many saliency boxes the resolver is holding from the last pass.
    /// Evidence for tests; nothing else reads it.
    var cachedSaliencyBoxCount: Int { cachedBoxes.count }

    // MARK: The YOLO pass

    /// One detector pass (per tap — a tap is a rare event, and the probe
    /// re-checks the artifact's presence so a mid-session install lands
    /// on the next tap), then the pure selection. A failing pass is nil —
    /// the ladder continues with the mask path, exactly like a failing
    /// mask pass (never an error to the elder).
    private func yoloDetection(using engine: PointAskObjectDetecting,
                               in pixelBuffer: CVPixelBuffer,
                               containing point: CGPoint) -> YOLODetection? {
        let detections: [YOLODetection]
        do {
            detections = try engine.detectObjects(in: pixelBuffer)
        } catch {
            return nil
        }
        return Self.yoloBox(detections, containing: point)
    }

    /// The pure selection: the highest-confidence detection whose box
    /// CONTAINS the tap wins, and that is the ONLY way a detection wins.
    /// Nil otherwise — and nil is the ladder's cue to continue, so a tap
    /// on something the detector cannot see (its class is not in the
    /// COCO-80 vocabulary, or no detection contains the finger) anchors
    /// through the mask/saliency/pad paths instead of a wrong object.
    ///
    /// The nearest-center fallback was removed (2026-09-20) because the
    /// owner's device report showed exactly its failure mode: a green
    /// Vaseline tub — not a COCO class, visually unmissable — anchored a
    /// box over the nearest *detectable* thing beside it, so the pointer
    /// pointed at the wrong object. The detector abstaining is the
    /// honest answer; "nearest thing it can see" is not the thing the
    /// elder pointed at.
    ///
    /// [FULL-FRAME-FILTER] (2026-09-20) A detection whose box covers
    /// more than `maxSelectableFrameCoverage` of the frame is never
    /// SELECTED — the classic is `person` filling the camera when the
    /// elder's body is in the picture (device report: the tap anchored
    /// a box over the whole frame). The pass still logs it; the pointer
    /// just refuses to point at the room.
    static func yoloBox(_ detections: [YOLODetection],
                        containing point: CGPoint) -> YOLODetection? {
        let selectable = detections.filter {
            Self.frameCoverage($0.normalizedBox) <= Self.maxSelectableFrameCoverage
        }
        guard !selectable.isEmpty else { return nil }
        return selectable
            .filter { $0.normalizedBox.contains(point) }
            .max { $0.confidence < $1.confidence }
    }

    /// A normalized box's share of the frame's area.
    static func frameCoverage(_ box: NormalizedBox) -> Double {
        (box.xMax - box.xMin) * (box.yMax - box.yMin)
    }

    /// Boxes covering more of the frame than this are never selected as
    /// the elder's pointer target (logged, not pointed at).
    static let maxSelectableFrameCoverage: Double = 0.85

    // MARK: The pass and the cache

    /// The first box — largest first, the engine's own order — that contains
    /// the tap, or nil. Refreshes the cached pass when it is stale or absent;
    /// a pass that throws leaves the cache empty and returns nil (the pad
    /// path answers).
    private func saliencyBox(containing point: CGPoint,
                             in pixelBuffer: CVPixelBuffer) -> NormalizedBox? {
        if let cachedAt, now().timeIntervalSince(cachedAt) < config.saliencyCacheSeconds {
            return Self.saliencyBox(cachedBoxes, containing: point)
        }
        cachedBoxes = []
        cachedAt = nil
        do {
            cachedBoxes = try objectEngine.detectObjects(in: pixelBuffer).map(\.normalizedBox)
        } catch {
            events.tapAnchored(source: .pad)
            return nil
        }
        cachedAt = now()
        return Self.saliencyBox(cachedBoxes, containing: point)
    }

    /// Pure hit-test: the first box (in the given order — the shipped engine
    /// delivers largest first) that contains the point.
    static func saliencyBox(_ boxes: [NormalizedBox], containing point: CGPoint) -> NormalizedBox? {
        boxes.first { $0.contains(point) }
    }

    // MARK: The pad fallback

    /// The pad box around a tap: a square `cropPadFraction` of the frame's
    /// short side in extent, centred on the tap, clamped into the frame.
    /// This is the box the elder sees (and the crop the pipeline reads) when
    /// no object box answered the hit-test.
    static func padBox(around point: CGPoint, fraction: Double = PointAskConfig.default.cropPadFraction) -> NormalizedBox {
        let clampedFraction = CGFloat(min(max(0, fraction), 1))
        let half = clampedFraction / 2
        let size = CGSize(width: clampedFraction, height: clampedFraction)
        var box = CGRect(origin: CGPoint(x: point.x - half, y: point.y - half), size: size)
        // Clamp into the frame: the box is a pointer, and a pointer half
        // off the glass is not a pointer (a crop that reaches past the
        // frame's edge is clamped again at the crop stage, so the two
        // cannot disagree).
        box.origin.x = min(max(box.minX, 0), 1 - box.width)
        box.origin.y = min(max(box.minY, 0), 1 - box.height)
        return NormalizedBox(xMin: Double(box.minX),
                             yMin: Double(box.minY),
                             xMax: Double(box.maxX),
                             yMax: Double(box.maxY))
    }

    // MARK: Composition

    private func anchor(_ box: NormalizedBox,
                        size: CGSize,
                        source: PointAskTargetSource,
                        detectedLabel: String?) -> ResolvedPointAskTarget {
        events.tapAnchored(source: source)
        return ResolvedPointAskTarget(normalizedBox: box,
                                      pixelRect: Self.pixelRect(of: box, in: size),
                                      source: source,
                                      detectedLabel: detectedLabel)
    }

    /// The box in pixel coordinates, top-left origin — the unit the crop
    /// reads. A degenerate frame size yields the zero rect, which the crop
    /// stage refuses rather than inventing a crop for.
    static func pixelRect(of box: NormalizedBox, in size: CGSize) -> CGRect {
        CGRect(x: CGFloat(box.xMin) * size.width,
               y: CGFloat(box.yMin) * size.height,
               width: CGFloat(box.xMax - box.xMin) * size.width,
               height: CGFloat(box.yMax - box.yMin) * size.height)
    }
}

extension NormalizedBox {
    /// Whether the point (normalized, top-left origin) lies inside the box.
    func contains(_ point: CGPoint) -> Bool {
        point.x >= xMin && point.x <= xMax && point.y >= yMin && point.y <= yMax
    }
}
