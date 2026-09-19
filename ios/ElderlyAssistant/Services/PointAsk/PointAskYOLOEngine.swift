import CoreML
import CoreVideo
import Foundation
import Vision

// [YOLO] The real on-device object detector behind the point-ask tap box.
//
// The owner's device-test verdict (2026-09-19): the tap box must be a REAL
// object detection box ("tap the cap → the bottle's box, any size").
// Apple's Vision has no general object detector; saliency/masks give
// foreground blobs. The fix is YOLO11n on the Neural Engine.
//
// ## The artifact (verified from the compiled spec on the training server)
//
// `yolo11n.mlmodelc` — ultralytics 8.4.155 `export_coreml`, imgsz 640,
// `nms: False`, torch 2.14 trace of `Detect.forward` in eval mode:
//
//  - input:  `image`, an ImageType (RGB, 640×640, scale 1/255) — Vision
//    converts and resizes the camera frame automatically, so this engine
//    hands a raw `CVPixelBuffer` over and never touches pixels;
//  - output: ONE tensor named `var_1223`, a Float32 multiarray
//    `[1, 84, 8400]` — the three strides' predictions concatenated along
//    the anchor axis (80×80 + 40×40 + 20×20 = 8400 anchors over strides
//    8/16/32), 84 channels per anchor.
//
// **The decode is the verified one, not a guess.** The task's brief
// assumed two raw tensors ("coordinates 1×4×8400 + confidence
// 1×80×8400") needing per-stride anchor-grid math; the REAL spec is the
// single concatenated tensor, and — read from ultralytics 8.4.155's
// `Detect._inference` on the server — it is already DECODED:
//
//     dbox = self.decode_bboxes(self.dfl(x["boxes"]), self.anchors) * self.strides
//     return torch.cat((dbox, x["scores"].sigmoid()), 1)
//
// so channels 0-3 are cx/cy/w/h in 640-PIXEL space (DFL + anchor decode
// baked into the graph) and channels 4-83 are sigmoid class scores over
// the standard 80 COCO classes. No anchor grids in Swift: the decode is
// "corners from cx/cy/w/h, threshold 0.25, greedy NMS at IoU 0.45".

/// One detection: the object's box (normalized against the input, top-left
/// origin) with its COCO class name and the model's confidence.
struct YOLODetection: Equatable {
    let normalizedBox: NormalizedBox
    let label: String
    let confidence: Double
}

/// The detector seam: a protocol so the resolver is testable with a fake
/// and so the shipped engine's availability (artifact installed) is
/// separated from its pass (the ANE run). The shipped implementation is
/// `PointAskYOLOEngine`; tests use a scripted stub (the `PointAskMaskProbing`
/// pattern).
protocol PointAskObjectDetecting: AnyObject {

    /// Whether the compiled model directory exists AND a request can be
    /// built for it. The probe also doubles as the AUTO-INSTALL trigger:
    /// when the artifact is absent and a provisioner is wired, the first
    /// point-ask use kicks the catalog download (the download service
    /// dedupes, so repeated probes while absent are retries, not fan-out).
    var isAvailable: Bool { get }

    /// One detection pass over the frame — Vision resizes the buffer to
    /// the model's 640×640 RGB input, the Neural Engine runs the model,
    /// and `YOLODecoder` turns the raw tensor into boxes. Throws when the
    /// model could not be loaded or run at all — a refusal, not an empty
    /// scene (an empty scene is an empty array).
    func detectObjects(in pixelBuffer: CVPixelBuffer) throws -> [YOLODetection]
}

/// The provision seam for the auto-install kick: starts the background
/// download of the detector's catalog entry. `ModelDownloadService`
/// conforms (its `start` is idempotent — a download already running or a
/// completed install is a no-op); tests use a recording fake.
protocol PointAskYOLOProvisioning: AnyObject {
    func kickDownload(for id: ModelID)
}

extension ModelDownloadService: PointAskYOLOProvisioning {
    func kickDownload(for id: ModelID) {
        guard let entry = ModelCatalog.entry(for: id) else { return }
        start(entry)
    }
}

/// The shipped detector: a `VNCoreMLRequest` over the installed
/// `yolo11n.mlmodelc`.
///
/// The model load is lazy (the first detection pass pays it) and cached;
/// a load that fails flips the probe off for the process lifetime — a
/// device where the request exists but cannot run is not retried per tap
/// (the `PointAskMaskEngine.supportsMasks` honesty). The artifact is
/// already compiled (`.mlmodelc`), so "install" is the download +
/// unzip (`ModelDownloadService` → `ModelStore.installCoreMLEncoder`),
/// never an on-device compile.
final class PointAskYOLOEngine: PointAskObjectDetecting {

    private let modelStore: ModelStore
    private let modelId: ModelID
    private let provisioner: PointAskYOLOProvisioning?
    private let lock = NSLock()
    private var vnModel: VNCoreMLModel?
    /// The load attempted and failed — the probe reports false from then
    /// on, never retried per tap.
    private var loadFailed = false

    init(modelStore: ModelStore,
         modelId: ModelID = ModelCatalog.yolo11n,
         provisioner: PointAskYOLOProvisioning? = nil) {
        self.modelStore = modelStore
        self.modelId = modelId
        self.provisioner = provisioner
    }

    var isAvailable: Bool {
        guard modelStore.isCoreMLCached(modelId) else {
            // [AUTO-INSTALL] The probe is the readiness trigger: the
            // resolver asks it on every tap, so the first point-ask use on
            // a device without the artifact starts the download, and the
            // next tap after the install lands gets the real detector.
            provisioner?.kickDownload(for: modelId)
            return false
        }
        lock.lock(); defer { lock.unlock() }
        return !loadFailed
    }

    func detectObjects(in pixelBuffer: CVPixelBuffer) throws -> [YOLODetection] {
        guard isAvailable else { throw PointAskError.yoloPassFailed }
        let model: VNCoreMLModel
        if let cached = vnModel {
            model = cached
        } else {
            guard let url = modelStore.coreMLBundleFinalURL(for: modelId) else {
                throw PointAskError.yoloPassFailed
            }
            do {
                let loaded = try VNCoreMLModel(for: MLModel(contentsOf: url))
                vnModel = loaded
                model = loaded
            } catch {
                lock.lock(); loadFailed = true; lock.unlock()
                throw PointAskError.yoloPassFailed
            }
        }
        let request = VNCoreMLRequest(model: model)
        // The model's input is EXACTLY 640×640: scaleFill stretches the
        // frame to the training resolution so every anchor is filled with
        // scene pixels (a crop would drop objects at the frame edge; the
        // aspect stretch is the accepted on-device YOLO trade — device
        // verification item for real-world box quality).
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw PointAskError.yoloPassFailed
        }
        guard let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
              let multiArray = observation.featureValue.multiArrayValue else {
            throw PointAskError.yoloPassFailed
        }
        return YOLODecoder.detections(from: multiArray)
    }
}

/// The pure postprocess: the raw `var_1223` tensor → detections. No
/// Vision, no CoreML — static functions over `MLMultiArray`/`[Float]` so
/// the decode is unit-testable with synthetic tensors (the engine's only
/// job is running the model).
enum YOLODecoder {

    /// The model's square input side (imgsz 640).
    static let inputSide: Int = 640
    /// Box channels per anchor (cx, cy, w, h) — the decoded layout
    /// `torch.cat((dbox, scores.sigmoid()), 1)` ships (see the file
    /// header).
    static let boxChannelCount = 4
    /// The COCO class count the model was trained on.
    static let classCount = 80
    /// Anchors per output: 80×80 (stride 8) + 40×40 (stride 16) +
    /// 20×20 (stride 32), concatenated in that order.
    static let anchorCount = 8400
    /// Detections below this confidence are dropped before NMS.
    static let confidenceThreshold: Float = 0.25
    /// Greedy NMS overlap threshold (IoU).
    static let nmsIOUThreshold: Float = 0.45

    /// The 80 COCO class names, indexed by class id — verbatim from the
    /// model's own metadata (`names` field of the compiled spec, read on
    /// the training server 2026-09-19).
    static let classNames: [String] = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus",
        "train", "truck", "boat", "traffic light", "fire hydrant",
        "stop sign", "parking meter", "bench", "bird", "cat", "dog",
        "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe",
        "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee",
        "skis", "snowboard", "sports ball", "kite", "baseball bat",
        "baseball glove", "skateboard", "surfboard", "tennis racket",
        "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl",
        "banana", "apple", "sandwich", "orange", "broccoli", "carrot",
        "hot dog", "pizza", "donut", "cake", "chair", "couch",
        "potted plant", "bed", "dining table", "toilet", "tv", "laptop",
        "mouse", "remote", "keyboard", "cell phone", "microwave", "oven",
        "toaster", "sink", "refrigerator", "book", "clock", "vase",
        "scissors", "teddy bear", "hair drier", "toothbrush"
    ]

    // MARK: The decode

    /// The full pipeline over the model's raw output tensor: per-anchor
    /// box/class decode, confidence threshold, greedy NMS — in that
    /// order, the standard YOLO postprocess.
    static func detections(from multiArray: MLMultiArray) -> [YOLODetection] {
        guard let flat = flatten(multiArray) else { return [] }
        return detections(from: flat)
    }

    /// The pure decode over the flat Float32 payload (row-major
    /// [1, 84, 8400] — element index `channel * 8400 + anchor`).
    ///
    /// Channels 0-3 are cx/cy/w/h in 640-PIXEL space (DFL-decoded by the
    /// graph — see the file header), channels 4-83 the sigmoid class
    /// scores. A tensor shorter than the pinned shape decodes as an empty
    /// scene, never a crash and never a guess.
    static func detections(from flat: [Float]) -> [YOLODetection] {
        let required = (boxChannelCount + classCount) * anchorCount
        guard flat.count >= required else { return [] }
        var candidates: [YOLODetection] = []
        candidates.reserveCapacity(64)
        for anchor in 0..<anchorCount {
            let cx = flat[anchor]
            let cy = flat[anchorCount + anchor]
            let w = flat[2 * anchorCount + anchor]
            let h = flat[3 * anchorCount + anchor]
            var bestClass = -1
            var bestScore: Float = -1
            let classBase = 4 * anchorCount + anchor
            for c in 0..<classCount {
                let score = flat[classBase + c * anchorCount]
                if score > bestScore {
                    bestScore = score
                    bestClass = c
                }
            }
            guard bestScore >= confidenceThreshold, bestClass >= 0,
                  let box = box(cx: cx, cy: cy, w: w, h: h) else { continue }
            candidates.append(YOLODetection(normalizedBox: box,
                                            label: classNames[bestClass],
                                            confidence: Double(bestScore)))
        }
        return nms(candidates, iouThreshold: nmsIOUThreshold)
    }

    /// cx/cy/w/h in input-pixel space → normalized corners, top-left
    /// origin, clamped into [0, 1]. Nil for a degenerate (zero or
    /// negative) extent — never a nonsense box.
    static func box(cx: Float, cy: Float, w: Float, h: Float,
                    inputSide: Int = YOLODecoder.inputSide) -> NormalizedBox? {
        let side = Float(inputSide)
        guard side > 0, w > 0, h > 0 else { return nil }
        let xMin = clamp01(Double((cx - w / 2) / side))
        let xMax = clamp01(Double((cx + w / 2) / side))
        let yMin = clamp01(Double((cy - h / 2) / side))
        let yMax = clamp01(Double((cy + h / 2) / side))
        let box = NormalizedBox(xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax)
        return box.xMax > box.xMin && box.yMax > box.yMin ? box : nil
    }

    // MARK: NMS

    /// Greedy NMS: detections ordered by confidence descending, each kept
    /// unless it overlaps an already-kept box by more than
    /// `iouThreshold`. Class-agnostic (the standard YOLO pipeline NMS —
    /// the per-class variant only matters for crowded multi-class scenes
    /// and costs a pass per class).
    static func nms(_ detections: [YOLODetection],
                    iouThreshold: Float) -> [YOLODetection] {
        let ordered = detections.sorted { $0.confidence > $1.confidence }
        var kept: [YOLODetection] = []
        for candidate in ordered {
            if kept.allSatisfy({
                iou(candidate.normalizedBox, $0.normalizedBox) <= Double(iouThreshold)
            }) {
                kept.append(candidate)
            }
        }
        return kept
    }

    /// Intersection-over-union of two normalized boxes. 0 when they do
    /// not touch; the boxes are clamped to [0, 1] by construction.
    static func iou(_ a: NormalizedBox, _ b: NormalizedBox) -> Double {
        let xA = max(a.xMin, b.xMin)
        let yA = max(a.yMin, b.yMin)
        let xB = min(a.xMax, b.xMax)
        let yB = min(a.yMax, b.yMax)
        let intersection = max(0, xB - xA) * max(0, yB - yA)
        let areaA = (a.xMax - a.xMin) * (a.yMax - a.yMin)
        let areaB = (b.xMax - b.xMin) * (b.yMax - b.yMin)
        let union = areaA + areaB - intersection
        guard union > 0 else { return 0 }
        return intersection / union
    }

    // MARK: MLMultiArray plumbing

    /// The raw Float32 payload of a contiguous multiarray, or nil when
    /// the array is not Float32 (a drifted export would surface here as
    /// an empty scene rather than a garbage decode). CoreML outputs are
    /// contiguous row-major, so `dataPointer` IS the tensor.
    static func flatten(_ multiArray: MLMultiArray) -> [Float]? {
        guard multiArray.dataType == .float32, multiArray.count > 0 else { return nil }
        let pointer = multiArray.dataPointer.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: pointer, count: multiArray.count))
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
