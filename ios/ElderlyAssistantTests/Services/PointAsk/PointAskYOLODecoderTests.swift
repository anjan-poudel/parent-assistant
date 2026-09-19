import CoreML
import XCTest
@testable import ElderlyAssistant

/// [YOLO] The pure decode — synthetic `var_1223` tensors in, detections
/// out. What is pinned here is the VERIFIED output contract read from the
/// compiled model's spec on the training server (ultralytics 8.4.155,
/// nms=False):
///
///  - one Float32 output `var_1223`, shape [1, 84, 8400], row-major
///    (`channel * 8400 + anchor`);
///  - channels 0-3 = cx/cy/w/h already DFL-decoded into 640-PIXEL space
///    (`Detect._inference` bakes `decode_bboxes(dfl(boxes)) * strides`
///    into the graph before the trace — no per-stride anchor grids in
///    Swift);
///  - channels 4-83 = sigmoid class scores over the 80 COCO classes.
///
/// The scenarios: one confident object decodes to the right box and
/// label; sub-threshold confidence is dropped; overlapping boxes collapse
/// under greedy NMS; disjoint objects both survive; and the MLMultiArray
/// plumbing hands the engine's real output to the same decode.
final class PointAskYOLODecoderTests: XCTestCase {

    // MARK: - Synthetic tensors

    /// Builds the flat `[1, 84, 8400]` payload with the given anchors set
    /// (everything else zero — below threshold).
    private func tensor(_ anchors: [(anchor: Int, cx: Float, cy: Float,
                                     w: Float, h: Float, classID: Int,
                                     score: Float)]) -> [Float] {
        let required = (YOLODecoder.boxChannelCount + YOLODecoder.classCount)
            * YOLODecoder.anchorCount
        var flat = [Float](repeating: 0, count: required)
        for item in anchors {
            flat[item.anchor] = item.cx
            flat[YOLODecoder.anchorCount + item.anchor] = item.cy
            flat[2 * YOLODecoder.anchorCount + item.anchor] = item.w
            flat[3 * YOLODecoder.anchorCount + item.anchor] = item.h
            flat[(4 + item.classID) * YOLODecoder.anchorCount + item.anchor] = item.score
        }
        return flat
    }

    private func multiArray(from flat: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [1,
                    NSNumber(value: YOLODecoder.boxChannelCount + YOLODecoder.classCount),
                    NSNumber(value: YOLODecoder.anchorCount)],
            dataType: .float32)
        for i in 0..<flat.count { array[i] = NSNumber(value: flat[i]) }
        return array
    }

    // MARK: - Scenario: one confident object decodes to the right box and label

    func testOneConfidentObjectDecodesToItsBoxAndCOCOLabel() {
        // A bottle: cx=320, cy=320, w=200, h=100 in the 640×640 input —
        // the DFL-decoded pixel-space box the graph ships.
        let flat = tensor([(anchor: 0, cx: 320, cy: 320, w: 200, h: 100,
                            classID: 39, score: 0.9)])

        let detections = YOLODecoder.detections(from: flat)

        XCTAssertEqual(detections.count, 1)
        let bottle = detections[0]
        XCTAssertEqual(bottle.label, "bottle",
                       "class id 39 is 'bottle' in the model's own COCO names")
        XCTAssertEqual(bottle.confidence, 0.9, accuracy: 0.0001)
        XCTAssertEqual(bottle.normalizedBox.xMin, Double(220) / 640, accuracy: 0.0001)
        XCTAssertEqual(bottle.normalizedBox.xMax, Double(420) / 640, accuracy: 0.0001)
        XCTAssertEqual(bottle.normalizedBox.yMin, Double(270) / 640, accuracy: 0.0001)
        XCTAssertEqual(bottle.normalizedBox.yMax, Double(370) / 640, accuracy: 0.0001)
    }

    func testTheClassArgmaxWinsOnTheSameAnchor() {
        // Two classes fire on one anchor: cup 0.6, bottle 0.9 — the
        // argmax (bottle) names the object.
        var flat = tensor([(anchor: 3, cx: 320, cy: 320, w: 100, h: 100,
                            classID: 41, score: 0.6)])
        flat[(4 + 39) * YOLODecoder.anchorCount + 3] = 0.9

        let detections = YOLODecoder.detections(from: flat)

        XCTAssertEqual(detections.map(\.label), ["bottle"])
        XCTAssertEqual(detections.first?.confidence ?? 0, 0.9, accuracy: 0.0001)
    }

    func testASubThresholdObjectIsDroppedBeforeNMS() {
        let flat = tensor([(anchor: 0, cx: 320, cy: 320, w: 200, h: 100,
                            classID: 39, score: 0.24)]) // below the 0.25 floor

        XCTAssertEqual(YOLODecoder.detections(from: flat), [],
                       "0.24 is below the threshold — no detection, never a guess")
    }

    func testAnExactlyThresholdObjectSurvives() {
        let flat = tensor([(anchor: 0, cx: 320, cy: 320, w: 200, h: 100,
                            classID: 39, score: 0.25)])

        XCTAssertEqual(YOLODecoder.detections(from: flat).count, 1)
    }

    // MARK: - Scenario: greedy NMS

    func testOverlappingBoxesCollapseToTheHighestConfidence() {
        // IoU(same, near) = 0.0324 / 0.0476 ≈ 0.68 — above the 0.45 NMS
        // threshold, so the weaker twin must be suppressed.
        let same = NormalizedBox(xMin: 0.4, yMin: 0.4, xMax: 0.6, yMax: 0.6)
        let near = NormalizedBox(xMin: 0.42, yMin: 0.42, xMax: 0.62, yMax: 0.62)
        XCTAssertGreaterThan(YOLODecoder.iou(same, near), 0.45,
                             "the fixture's overlap exceeds the NMS threshold")

        let detections = [
            YOLODetection(normalizedBox: near, label: "cup", confidence: 0.5),
            YOLODetection(normalizedBox: same, label: "cup", confidence: 0.9)
        ]

        let kept = YOLODecoder.nms(detections, iouThreshold: 0.45)

        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.normalizedBox, same,
                       "the higher-confidence box survives the collapse")
    }

    func testDisjointObjectsBothSurviveNMS() {
        let left = NormalizedBox(xMin: 0, yMin: 0, xMax: 0.2, yMax: 0.2)
        let right = NormalizedBox(xMin: 0.7, yMin: 0.7, xMax: 0.9, yMax: 0.9)
        XCTAssertEqual(YOLODecoder.iou(left, right), 0)

        let kept = YOLODecoder.nms([
            YOLODetection(normalizedBox: left, label: "cup", confidence: 0.9),
            YOLODetection(normalizedBox: right, label: "bottle", confidence: 0.8)
        ], iouThreshold: 0.45)

        XCTAssertEqual(kept.count, 2, "two separate objects are two detections")
    }

    func testTheFullDecodeNMSesOverlappingAnchors() {
        // The same object decoded twice (neighbouring anchors at the same
        // centre) collapses to one detection.
        let flat = tensor([
            (anchor: 0, cx: 320, cy: 320, w: 200, h: 100, classID: 39, score: 0.9),
            (anchor: 1, cx: 320, cy: 320, w: 200, h: 100, classID: 39, score: 0.8)
        ])

        let detections = YOLODecoder.detections(from: flat)

        XCTAssertEqual(detections.count, 1)
        XCTAssertEqual(detections.first?.confidence ?? 0, 0.9, accuracy: 0.0001,
                       "the higher-confidence twin survives")
    }

    // MARK: - Scenario: box geometry

    func testTheBoxIsClampedIntoTheFrame() {
        // An object half off the top-left corner clamps to the frame
        // edge — a box that reaches past the glass is not a pointer.
        guard let box = YOLODecoder.box(cx: 10, cy: 10, w: 100, h: 100) else {
            return XCTFail("a partially off-frame object still yields a clamped box")
        }
        XCTAssertEqual(box.xMin, 0, accuracy: 0.0001)
        XCTAssertEqual(box.yMin, 0, accuracy: 0.0001)
        XCTAssertEqual(box.xMax, Double(60) / 640, accuracy: 0.0001)
        XCTAssertEqual(box.yMax, Double(60) / 640, accuracy: 0.0001)
    }

    func testADegenerateBoxDecodesAsNilNeverANonsenseBox() {
        XCTAssertNil(YOLODecoder.box(cx: 320, cy: 320, w: 0, h: 100))
        XCTAssertNil(YOLODecoder.box(cx: 320, cy: 320, w: 100, h: -5))
    }

    func testIOUIsTheIntersectionOverUnion() {
        let a = NormalizedBox(xMin: 0, yMin: 0, xMax: 0.5, yMax: 0.5)
        let disjoint = NormalizedBox(xMin: 0.6, yMin: 0.6, xMax: 1, yMax: 1)
        XCTAssertEqual(YOLODecoder.iou(a, disjoint), 0)
        XCTAssertEqual(YOLODecoder.iou(a, a), 1, accuracy: 0.0001)
        // a vs its right-half-shift clone: half the area overlaps —
        // IoU 0.25 / 0.75 = 1/3.
        let shifted = NormalizedBox(xMin: 0.25, yMin: 0, xMax: 0.75, yMax: 0.5)
        XCTAssertEqual(YOLODecoder.iou(a, shifted), 1.0 / 3.0, accuracy: 0.0001)
    }

    // MARK: - Scenario: the MLMultiArray plumbing

    func testFlattenReadsTheRawFloat32Payload() throws {
        let array = try MLMultiArray(shape: [1, 2, 3], dataType: .float32)
        for i in 0..<6 { array[i] = NSNumber(value: Float(i)) }

        let flat = try XCTUnwrap(YOLODecoder.flatten(array))

        XCTAssertEqual(flat, [0, 1, 2, 3, 4, 5],
                       "CoreML outputs are contiguous row-major: dataPointer IS the tensor")
    }

    func testTheMultiArrayDecodeMatchesTheFlatDecode() throws {
        let flat = tensor([(anchor: 5, cx: 320, cy: 320, w: 200, h: 100,
                            classID: 39, score: 0.9)])
        let array = try multiArray(from: flat)

        let fromArray = YOLODecoder.detections(from: array)
        let fromFlat = YOLODecoder.detections(from: flat)

        XCTAssertEqual(fromArray, fromFlat,
                       "the engine's MLMultiArray output decodes identically to the pure [Float]")
        XCTAssertEqual(fromArray.first?.label, "bottle")
    }

    func testAShortTensorDecodesAsAnEmptySceneNeverACrash() {
        XCTAssertEqual(YOLODecoder.detections(from: [0, 0, 0, 0]), [],
                       "a drifted export surfaces as an empty scene, not a guess")
    }

    func testTheCOCONamesMatchTheModelsMetadata() {
        XCTAssertEqual(YOLODecoder.classNames.count, YOLODecoder.classCount)
        XCTAssertEqual(YOLODecoder.classNames[0], "person")
        XCTAssertEqual(YOLODecoder.classNames[39], "bottle")
        XCTAssertEqual(YOLODecoder.classNames[41], "cup")
        XCTAssertEqual(YOLODecoder.classNames[56], "chair")
        XCTAssertEqual(YOLODecoder.classNames[79], "toothbrush")
    }
}
