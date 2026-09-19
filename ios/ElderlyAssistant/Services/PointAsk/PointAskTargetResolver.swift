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

    var supportsMasks: Bool {
        lock.lock(); defer { lock.unlock() }
        guard #available(iOS 17, *) else { return false }
        return !probeFailed
    }

    func maskBox(at point: CGPoint, in pixelBuffer: CVPixelBuffer) throws -> NormalizedBox? {
        guard #available(iOS 17, *) else { throw PointAskError.maskPassFailed }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        let mask: CVPixelBuffer
        do {
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            // The observation's own scaled-mask renderer: the instance's
            // pixels carry the index (0), the background the other label.
            guard let observation = request.results?.first else {
                lock.lock(); probeFailed = true; lock.unlock()
                throw PointAskError.maskPassFailed
            }
            mask = try observation.generateScaledMaskForImage(forInstances: [0],
                                                              from: handler)
        } catch {
            lock.lock(); probeFailed = true; lock.unlock()
            throw PointAskError.maskPassFailed
        }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        guard width > 0, height > 0 else { return nil }
        let x = min(max(Int(CGFloat(width) * point.x), 0), width - 1)
        let y = min(max(Int(CGFloat(height) * point.y), 0), height - 1)
        guard Self.pixelValue(atX: x, y: y, in: mask) == 0 else { return nil }
        return Self.instanceExtent(in: mask)
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
    private let now: () -> Date

    private var cachedBoxes: [NormalizedBox] = []
    private var cachedAt: Date?

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
        self.now = now
    }

    /// The box the tap anchors. `point` is normalized against the frame
    /// (top-left origin, 0…1); the frame is the one the elder tapped on.
    ///
    /// Order of evidence, most specific first:
    ///  1. [YOLO] the real object-detector pass, while the engine is
    ///     available — the box that WRAPS the object (the owner's
    ///     device-test verdict: the tap box must be a real detection box,
    ///     "any size"), carrying the detector's class label;
    ///  2. the opt-in mask pass, while `supportsMasks` holds — the
    ///     silhouette answer, and the spike path;
    ///  3. the saliency boxes, refreshed only when the cached pass is
    ///     stale or absent;
    ///  4. the pad box around the tap — the honest fallback that keeps
    ///     "tap outside re-anchors" true even when the pass fails or finds
    ///     nothing.
    ///
    /// A failing detector pass degrades to the mask path, a failing mask
    /// pass to the saliency path (the probe flips and the resolver never
    /// asks again), and a failing saliency pass to the pad box. Never an
    /// error to the elder — the box is a pointer, not an answer
    /// (FR-LCT-004's degradation shape).
    func resolve(tap point: CGPoint, in pixelBuffer: CVPixelBuffer) -> ResolvedPointAskTarget {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer))
        let clamped = CGPoint(x: min(max(point.x, 0), 1),
                              y: min(max(point.y, 0), 1))

        if let yoloEngine, yoloEngine.isAvailable,
           let yolo = yoloDetection(using: yoloEngine, in: pixelBuffer, containing: clamped) {
            return anchor(yolo.normalizedBox, size: size, source: .yolo,
                          detectedLabel: yolo.label)
        }

        if let maskEngine, maskEngine.supportsMasks,
           let maskBox = try? maskEngine.maskBox(at: clamped, in: pixelBuffer) {
            return anchor(maskBox, size: size, source: .mask, detectedLabel: nil)
        }

        if let saliencyBox = saliencyBox(containing: clamped, in: pixelBuffer) {
            return anchor(saliencyBox, size: size, source: .saliency, detectedLabel: nil)
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
    /// CONTAINS the tap wins; when no box contains the tap, the
    /// detection whose box CENTER is nearest the tap — the object under
    /// the finger — instead of the global confidence maximum (which
    /// grabbed the most confident thing anywhere in the scene, e.g. the
    /// elder's own hand, and was the "wrong object" device report).
    /// Nil only for an empty scene, which is the ladder's cue to
    /// continue.
    static func yoloBox(_ detections: [YOLODetection],
                        containing point: CGPoint) -> YOLODetection? {
        guard !detections.isEmpty else { return nil }
        let containing = detections
            .filter { $0.normalizedBox.contains(point) }
            .max { $0.confidence < $1.confidence }
        if let containing { return containing }
        return detections.min { lhs, rhs in
            Self.centerDistance(lhs.normalizedBox, to: point)
                < Self.centerDistance(rhs.normalizedBox, to: point)
        }
    }

    /// The box center's distance to the tap — the "what is under the
    /// finger" metric for the no-containment fallback.
    static func centerDistance(_ box: NormalizedBox, to point: CGPoint) -> Double {
        let centerX = (box.xMin + box.xMax) / 2
        let centerY = (box.yMin + box.yMax) / 2
        let dx = centerX - Double(point.x)
        let dy = centerY - Double(point.y)
        return (dx * dx + dy * dy).squareRoot()
    }

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
