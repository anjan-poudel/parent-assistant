import CoreGraphics
import CoreVideo
import XCTest
@testable import ElderlyAssistant

/// The tap hit-test (design §2 stage 1, §4, §6): which box the elder's tap
/// anchors — a saliency box, the opt-in mask answer, or the pad box — and
/// that the answer is always a box (the pad fallback), never an error and
/// never a stale position.
///
/// The scenarios that matter:
///
///  - **Tap in box / tap outside.** A tap inside a saliency box anchors it
///    (largest first, the engine's own order); a tap outside every box
///    anchors the pad box centred on the tap — and a second tap elsewhere
///    anchors a *different* box, so the box follows the finger.
///  - **The cache is refreshed only when stale.** A second tap on the same
///    scene is a hit-test over remembered boxes and costs no Vision pass;
///    a tap after `saliencyCacheSeconds` pays the pass again.
///  - **Degradation, never an error.** A failing saliency pass (or mask
///    pass) anchors the pad box; the mask path is consulted only while the
///    probe holds, and never when the engine is absent.
final class PointAskTargetResolverTests: XCTestCase {

    private var bus = LiveTranslateSanitisingBus()
    private var now = Date(timeIntervalSinceReferenceDate: 0)

    override func setUp() {
        super.setUp()
        bus = LiveTranslateSanitisingBus()
        now = Date(timeIntervalSinceReferenceDate: 0)
    }

    private func makeResolver(object: StubPointAskObjectEngine,
                              mask: StubPointAskMaskEngine? = nil,
                              yolo: StubPointAskYOLOEngine? = nil,
                              config: PointAskConfig = .default) -> PointAskTargetResolver {
        PointAskTargetResolver(objectEngine: object,
                               maskEngine: mask,
                               yoloEngine: yolo,
                               config: config,
                               observabilityBus: bus,
                               now: { self.now })
    }

    private func frame(width: Int = 400, height: Int = 200) -> CVPixelBuffer {
        PointAskTestFrames.solidPixelBuffer(width: width, height: height,
                                            rgba: (0, 0, 0, 255))
    }

    // MARK: - Scenario: a tap inside a saliency box anchors that box

    func testATapInsideASaliencyBoxAnchorsThatBoxInPixelCoordinates() {
        let object = StubPointAskObjectEngine()
        object.boxes = [PointAskBoxes.leftHalf]
        let resolver = makeResolver(object: object)

        let target = resolver.resolve(tap: CGPoint(x: 0.25, y: 0.5), in: frame())

        XCTAssertEqual(target.normalizedBox, PointAskBoxes.leftHalf)
        XCTAssertEqual(target.source, .saliency)
        XCTAssertEqual(target.pixelRect, CGRect(x: 0, y: 0, width: 200, height: 200),
                       "the pixel rect is the same box in the frame's pixels, top-left origin")
        XCTAssertEqual(bus.events(named: "tap_anchored").last?.metadata["origin"], "saliency")
    }

    func testTheFirstContainingBoxInTheEnginesOrderWins() {
        // The shipped engine delivers largest first; the resolver honours
        // the engine's order — a later box never overrides an earlier one.
        let smallCenter = NormalizedBox(xMin: 0.4, yMin: 0.4, xMax: 0.6, yMax: 0.6)
        let whole = NormalizedBox(xMin: 0, yMin: 0, xMax: 1, yMax: 1)

        XCTAssertEqual(PointAskTargetResolver.saliencyBox([whole, smallCenter],
                                                          containing: CGPoint(x: 0.5, y: 0.5)),
                       whole)
        XCTAssertEqual(PointAskTargetResolver.saliencyBox([smallCenter, whole],
                                                          containing: CGPoint(x: 0.5, y: 0.5)),
                       smallCenter)

        let object = StubPointAskObjectEngine()
        object.boxes = [smallCenter, whole]
        let target = makeResolver(object: object)
            .resolve(tap: CGPoint(x: 0.5, y: 0.5), in: frame())
        XCTAssertEqual(target.normalizedBox, smallCenter)
        XCTAssertEqual(target.source, .saliency)
    }

    // MARK: - Scenario: a tap outside every box anchors the pad box

    func testATapOutsideEveryBoxAnchorsThePadBoxAroundTheTap() {
        let object = StubPointAskObjectEngine()
        object.boxes = [PointAskBoxes.leftHalf]
        let resolver = makeResolver(object: object)
        let tap = CGPoint(x: 0.8, y: 0.5)

        let target = resolver.resolve(tap: tap, in: frame())

        XCTAssertEqual(target.normalizedBox,
                       PointAskTargetResolver.padBox(around: tap))
        XCTAssertEqual(target.source, .pad)
        XCTAssertEqual(target.normalizedBox.center.x, 0.8, accuracy: 0.0001,
                       "the pad box is centred on the tap")
        XCTAssertEqual(target.normalizedBox.center.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(bus.events(named: "tap_anchored").last?.metadata["origin"], "pad")
    }

    func testTwoTapsAnchorTwoDifferentBoxesNeverAStalePosition() {
        let object = StubPointAskObjectEngine()
        object.boxes = [PointAskBoxes.leftHalf]
        let resolver = makeResolver(object: object)
        let frame = self.frame()

        let first = resolver.resolve(tap: CGPoint(x: 0.1, y: 0.5), in: frame)
        let second = resolver.resolve(tap: CGPoint(x: 0.9, y: 0.5), in: frame)

        XCTAssertEqual(first.normalizedBox, PointAskBoxes.leftHalf)
        XCTAssertNotEqual(first.normalizedBox, second.normalizedBox,
                          "the box follows the finger, never a stale position")
        XCTAssertTrue(second.normalizedBox.contains(CGPoint(x: 0.9, y: 0.5)),
                      "the re-anchored box contains the newest tap")
    }

    func testThePadBoxClampsIntoTheFrameAtAnEdge() {
        let object = StubPointAskObjectEngine()
        let resolver = makeResolver(object: object)
        let frame = self.frame()

        for tap in [CGPoint(x: 0.02, y: 0.98), CGPoint(x: 0.98, y: 0.02)] {
            let target = resolver.resolve(tap: tap, in: frame)
            XCTAssertEqual(target.source, .pad)
            XCTAssertGreaterThanOrEqual(target.normalizedBox.xMin, 0)
            XCTAssertLessThanOrEqual(target.normalizedBox.xMax, 1)
            XCTAssertGreaterThanOrEqual(target.normalizedBox.yMin, 0)
            XCTAssertLessThanOrEqual(target.normalizedBox.yMax, 1)
            XCTAssertTrue(target.normalizedBox.contains(tap),
                          "the clamped pad box still contains the tap")
        }
    }

    func testAnOutOfRangeTapIsClampedIntoTheFrame() {
        let object = StubPointAskObjectEngine()
        let resolver = makeResolver(object: object)

        // (1.4, 0.5) clamps to (1, 0.5): outside the left half, so the pad
        // box is clamped to end exactly at the frame's right edge.
        let target = resolver.resolve(tap: CGPoint(x: 1.4, y: 0.5), in: frame())
        XCTAssertEqual(target.source, .pad)
        XCTAssertEqual(target.normalizedBox.xMax, 1, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(target.normalizedBox.xMin, 0)
    }

    // MARK: - Scenario: the saliency pass is cached until it is stale

    func testTheSaliencyPassIsCachedUntilItIsStale() {
        let object = StubPointAskObjectEngine()
        object.boxes = [PointAskBoxes.leftHalf]
        let config = PointAskConfig.default
        let resolver = makeResolver(object: object, config: config)
        let frame = self.frame()

        _ = resolver.resolve(tap: CGPoint(x: 0.1, y: 0.5), in: frame)
        XCTAssertEqual(object.passCount, 1)
        XCTAssertEqual(resolver.cachedSaliencyBoxCount, 1)

        // A second tap within the cache window: a hit-test over remembered
        // boxes, no second Vision pass.
        now = now.addingTimeInterval(config.saliencyCacheSeconds - 0.1)
        let second = resolver.resolve(tap: CGPoint(x: 0.2, y: 0.6), in: frame)
        XCTAssertEqual(object.passCount, 1, "a tap on the same scene costs no second pass")
        XCTAssertEqual(second.source, .saliency)

        // A tap after the window pays the pass again.
        now = now.addingTimeInterval(config.saliencyCacheSeconds)
        _ = resolver.resolve(tap: CGPoint(x: 0.3, y: 0.4), in: frame)
        XCTAssertEqual(object.passCount, 2, "a stale cache pays the pass again")
    }

    func testASecondTapDuringTheCacheWindowCanFindNothingAndFallsToThePadBox() {
        let object = StubPointAskObjectEngine()
        object.boxes = [PointAskBoxes.leftHalf]
        let resolver = makeResolver(object: object)
        let frame = self.frame()

        _ = resolver.resolve(tap: CGPoint(x: 0.1, y: 0.5), in: frame)
        let outside = resolver.resolve(tap: CGPoint(x: 0.9, y: 0.5), in: frame)

        XCTAssertEqual(outside.source, .pad,
                       "the cached boxes are hit-tested, and a miss is the pad fallback")
        XCTAssertEqual(object.passCount, 1)
    }

    // MARK: - Scenario: a failing pass degrades, never errors

    func testAFailingSaliencyPassAnchorsThePadBoxAndNeverErrors() {
        struct PassDown: Error {}
        let object = StubPointAskObjectEngine()
        object.error = PassDown()
        let resolver = makeResolver(object: object)

        let target = resolver.resolve(tap: CGPoint(x: 0.5, y: 0.5), in: frame())

        XCTAssertEqual(target.source, .pad,
                       "a failing pass is a pad box, never an error to the elder")
        XCTAssertEqual(resolver.cachedSaliencyBoxCount, 0,
                       "a failed pass leaves no cache to answer the next tap")
        XCTAssertEqual(object.passCount, 1)
        XCTAssertEqual(bus.events(named: "tap_anchored").last?.metadata["origin"], "pad")
    }

    func testAFailingPassPaysThePassAgainOnTheNextTap() {
        struct PassDown: Error {}
        let object = StubPointAskObjectEngine()
        object.error = PassDown()
        let resolver = makeResolver(object: object)
        let frame = self.frame()

        _ = resolver.resolve(tap: CGPoint(x: 0.5, y: 0.5), in: frame)
        XCTAssertEqual(object.passCount, 1)

        // No cache survived the failure, so the next tap tries again and
        // can succeed.
        object.error = nil
        object.boxes = [PointAskBoxes.leftHalf]
        let recovered = resolver.resolve(tap: CGPoint(x: 0.1, y: 0.5), in: frame)
        XCTAssertEqual(object.passCount, 2)
        XCTAssertEqual(recovered.source, .saliency)
    }

    // MARK: - Scenario: the mask path (tight object box, on by default)

    func testTheMaskPassAnswersBeforeTheSaliencyPassAndAnchorsItsOwnBox() {
        let object = StubPointAskObjectEngine()
        object.boxes = [PointAskBoxes.leftHalf]
        let mask = StubPointAskMaskEngine()
        mask.box = NormalizedBox(xMin: 0.2, yMin: 0.3, xMax: 0.4, yMax: 0.7)
        let resolver = makeResolver(object: object, mask: mask)
        let tap = CGPoint(x: 0.25, y: 0.5)

        let target = resolver.resolve(tap: tap, in: frame())

        XCTAssertEqual(target.source, .mask)
        XCTAssertEqual(mask.passCount, 1)
        XCTAssertEqual(object.passCount, 0,
                       "the silhouette answer came first; no saliency pass was paid")
        XCTAssertEqual(target.normalizedBox,
                       NormalizedBox(xMin: 0.2, yMin: 0.3, xMax: 0.4, yMax: 0.7),
                       "the box is the OBJECT'S extent, not a pad around the tap")
    }

    func testAMaskMissFallsToTheSaliencyPath() {
        let object = StubPointAskObjectEngine()
        object.boxes = [PointAskBoxes.leftHalf]
        let mask = StubPointAskMaskEngine()
        mask.box = nil
        let resolver = makeResolver(object: object, mask: mask)

        let target = resolver.resolve(tap: CGPoint(x: 0.25, y: 0.5), in: frame())

        XCTAssertEqual(target.source, .saliency,
                       "a mask miss is not a 'no': the saliency boxes answer next")
        XCTAssertEqual(mask.passCount, 1)
    }

    // MARK: - Scenario: the mask extent is the object's silhouette

    func testInstanceExtentWrapsTheInstancePixels() {
        // A mask buffer: instance pixels (0) form a left-half block; the
        // rest is background (1).
        let mask = PointAskTestFrames.pixelBuffer(width: 8, height: 4) { x, _ in
            (x < 4) ? (0, 0, 0, 0) : (1, 1, 1, 1)
        }
        let extent = PointAskMaskEngine.instanceExtent(in: mask)

        XCTAssertEqual(extent, NormalizedBox(xMin: 0, yMin: 0, xMax: 0.5, yMax: 1),
                       "the extent is the instance's min/max pixels, normalized")
    }

    func testInstanceExtentIsNilForAnEmptyMask() {
        let mask = PointAskTestFrames.solidPixelBuffer(width: 8, height: 4,
                                                       rgba: (1, 1, 1, 1))
        XCTAssertNil(PointAskMaskEngine.instanceExtent(in: mask))
    }

    func testAMaskPassFailureFallsToTheSaliencyPathAndNeverErrors() {
        struct MaskDown: Error {}
        let object = StubPointAskObjectEngine()
        object.boxes = [PointAskBoxes.leftHalf]
        let mask = StubPointAskMaskEngine()
        mask.error = MaskDown()
        let resolver = makeResolver(object: object, mask: mask)

        let target = resolver.resolve(tap: CGPoint(x: 0.25, y: 0.5), in: frame())

        XCTAssertEqual(target.source, .saliency)
        XCTAssertEqual(bus.events(named: "tap_anchored").last?.metadata["origin"], "saliency")
    }

    func testTheMaskEngineIsNotConsultedWhenTheProbeIsOff() {
        let object = StubPointAskObjectEngine()
        object.boxes = [PointAskBoxes.leftHalf]
        let mask = StubPointAskMaskEngine()
        mask.supportsMasks = false
        let resolver = makeResolver(object: object, mask: mask)

        let target = resolver.resolve(tap: CGPoint(x: 0.25, y: 0.5), in: frame())

        XCTAssertEqual(target.source, .saliency)
        XCTAssertEqual(mask.passCount, 0,
                       "a probe that reports unsupported is never asked to run")
    }

    func testTheShippedDefaultHasNoMaskEngine() {
        let object = StubPointAskObjectEngine()
        object.boxes = [PointAskBoxes.leftHalf]
        let resolver = makeResolver(object: object, mask: nil)

        let target = resolver.resolve(tap: CGPoint(x: 0.25, y: 0.5), in: frame())

        XCTAssertEqual(target.source, .saliency,
                       "the spike stays behind the probe; the shipped path is saliency")
        XCTAssertEqual(object.passCount, 1)
    }

    // MARK: - Scenario: the YOLO detector answers first (the real object box)

    func testTheYOLOBoxWinsOverMaskAndSaliencyAndCarriesItsLabel() {
        // The owner's device-test verdict: the tap box is a REAL
        // detection box — the detector's, not a mask extent or a
        // saliency blob.
        let yoloBox = NormalizedBox(xMin: 0.3, yMin: 0.3, xMax: 0.7, yMax: 0.7)
        let yolo = StubPointAskYOLOEngine()
        yolo.detections = [YOLODetection(normalizedBox: yoloBox,
                                         label: "bottle", confidence: 0.9)]
        let mask = StubPointAskMaskEngine()
        mask.box = NormalizedBox(xMin: 0.2, yMin: 0.2, xMax: 0.8, yMax: 0.8)
        let object = StubPointAskObjectEngine()
        object.boxes = [PointAskBoxes.leftHalf]
        let resolver = makeResolver(object: object, mask: mask, yolo: yolo)
        let tap = CGPoint(x: 0.5, y: 0.5)

        let target = resolver.resolve(tap: tap, in: frame())

        XCTAssertEqual(target.source, .yolo)
        XCTAssertEqual(target.normalizedBox, yoloBox)
        XCTAssertEqual(target.detectedLabel, "bottle",
                       "the winning box's label rides the target into the analysis")
        XCTAssertEqual(yolo.passCount, 1)
        XCTAssertEqual(mask.passCount, 0, "the detector came first; no mask pass was paid")
        XCTAssertEqual(object.passCount, 0, "… and no saliency pass")
        XCTAssertEqual(bus.events(named: "tap_anchored").last?.metadata["origin"], "yolo")
    }

    func testTheContainingYOLOBoxIsPreferredOverAHigherConfidenceOne() {
        // A tap on the cap: the lower-confidence bottle box CONTAINS the
        // tap, the higher-confidence person box does not — the box that
        // wraps what the finger points at wins ("prefer the one
        // CONTAINING the tap").
        let containing = YOLODetection(
            normalizedBox: NormalizedBox(xMin: 0.4, yMin: 0.4, xMax: 0.6, yMax: 0.6),
            label: "bottle", confidence: 0.6)
        let elsewhere = YOLODetection(
            normalizedBox: NormalizedBox(xMin: 0.05, yMin: 0.05, xMax: 0.2, yMax: 0.2),
            label: "cup", confidence: 0.9)
        let yolo = StubPointAskYOLOEngine()
        yolo.detections = [elsewhere, containing]
        let resolver = makeResolver(object: StubPointAskObjectEngine(), mask: nil, yolo: yolo)

        let target = resolver.resolve(tap: CGPoint(x: 0.5, y: 0.5), in: frame())

        XCTAssertEqual(target.normalizedBox, containing.normalizedBox)
        XCTAssertEqual(target.detectedLabel, "bottle")
    }

    func testWhenNoYOLOBoxContainsTheTapTheHighestConfidenceBoxWins() {
        // A tap that misses every box (the cap's edge): the scene's most
        // confident object still anchors — a real object box, any size,
        // never a pad.
        let strongest = YOLODetection(
            normalizedBox: NormalizedBox(xMin: 0.3, yMin: 0.3, xMax: 0.7, yMax: 0.7),
            label: "bottle", confidence: 0.9)
        let weaker = YOLODetection(
            normalizedBox: NormalizedBox(xMin: 0.1, yMin: 0.1, xMax: 0.2, yMax: 0.2),
            label: "cup", confidence: 0.7)
        let yolo = StubPointAskYOLOEngine()
        yolo.detections = [weaker, strongest]
        let resolver = makeResolver(object: StubPointAskObjectEngine(), mask: nil, yolo: yolo)

        let target = resolver.resolve(tap: CGPoint(x: 0.95, y: 0.95), in: frame())

        XCTAssertEqual(target.source, .yolo)
        XCTAssertEqual(target.normalizedBox, strongest.normalizedBox)
    }

    func testAnEmptyYOLOSceneFallsToTheMaskAndSaliencyLadder() {
        let yolo = StubPointAskYOLOEngine()
        yolo.detections = []
        let mask = StubPointAskMaskEngine()
        mask.box = nil
        let object = StubPointAskObjectEngine()
        object.boxes = [PointAskBoxes.leftHalf]
        let resolver = makeResolver(object: object, mask: mask, yolo: yolo)

        let target = resolver.resolve(tap: CGPoint(x: 0.25, y: 0.5), in: frame())

        XCTAssertEqual(target.source, .saliency,
                       "no detector boxes: the ladder continues, never an empty anchor")
        XCTAssertNil(target.detectedLabel,
                     "a non-YOLO anchor carries no detector label")
    }

    func testAFailingYOLOPassFallsToTheLadderAndNeverErrors() {
        struct DetectorDown: Error {}
        let yolo = StubPointAskYOLOEngine()
        yolo.error = DetectorDown()
        let object = StubPointAskObjectEngine()
        object.boxes = [PointAskBoxes.leftHalf]
        let resolver = makeResolver(object: object, mask: nil, yolo: yolo)

        let target = resolver.resolve(tap: CGPoint(x: 0.25, y: 0.5), in: frame())

        XCTAssertEqual(target.source, .saliency,
                       "a failing detector pass degrades, exactly like a failing mask pass")
    }

    func testAnUnavailableYOLOEngineIsNeverAskedToRun() {
        let yolo = StubPointAskYOLOEngine()
        yolo.isAvailable = false
        let object = StubPointAskObjectEngine()
        object.boxes = [PointAskBoxes.leftHalf]
        let resolver = makeResolver(object: object, mask: nil, yolo: yolo)

        let target = resolver.resolve(tap: CGPoint(x: 0.25, y: 0.5), in: frame())

        XCTAssertEqual(target.source, .saliency,
                       "the artifact absent: the shipped ladder answers exactly as before")
        XCTAssertEqual(yolo.passCount, 0, "a probe that reports unavailable is never asked to run")
    }

    func testWithoutAYOLOEngineTheLadderIsIntact() {
        let object = StubPointAskObjectEngine()
        object.boxes = [PointAskBoxes.leftHalf]
        let resolver = makeResolver(object: object, mask: nil, yolo: nil)

        let target = resolver.resolve(tap: CGPoint(x: 0.25, y: 0.5), in: frame())

        XCTAssertEqual(target.source, .saliency,
                       "no detector wired: the resolver behaves exactly as it shipped")
        XCTAssertNil(target.detectedLabel)
    }

    func testThePureYOLOBoxSelection() {
        let box = YOLODetection(
            normalizedBox: NormalizedBox(xMin: 0.2, yMin: 0.2, xMax: 0.8, yMax: 0.8),
            label: "bottle", confidence: 0.5)
        XCTAssertEqual(PointAskTargetResolver.yoloBox([box], containing: CGPoint(x: 0.5, y: 0.5)),
                       box)
        XCTAssertNil(PointAskTargetResolver.yoloBox([], containing: .zero),
                     "an empty scene is the ladder's cue, not a guess")
    }

    // MARK: - Scenario: geometry helpers

    func testPixelRectConversionIsTopLeftOrigin() {
        XCTAssertEqual(PointAskTargetResolver.pixelRect(of: PointAskBoxes.leftHalf,
                                                        in: CGSize(width: 400, height: 200)),
                       CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(PointAskTargetResolver.pixelRect(of: PointAskBoxes.rightHalf,
                                                        in: CGSize(width: 400, height: 200)),
                       CGRect(x: 200, y: 0, width: 200, height: 200))
    }

    func testADegenerateFrameYieldsTheZeroRect() {
        XCTAssertEqual(PointAskTargetResolver.pixelRect(of: PointAskBoxes.leftHalf,
                                                        in: .zero),
                       .zero,
                       "a zero rect is the crop stage's refusal signal, never a guessed crop")
    }

    func testThePadBoxFractionIsBounded() {
        let whole = PointAskTargetResolver.padBox(around: CGPoint(x: 0.5, y: 0.5),
                                                  fraction: 2.0)
        XCTAssertEqual(whole, NormalizedBox(xMin: 0, yMin: 0, xMax: 1, yMax: 1),
                       "a fraction above 1 clamps to the whole frame")
        let corner = PointAskTargetResolver.padBox(around: CGPoint(x: 0.5, y: 0.5),
                                                   fraction: -1)
        XCTAssertGreaterThanOrEqual(corner.xMin, 0)
        XCTAssertLessThanOrEqual(corner.xMax, 1)
    }

    func testBoxEdgeBoundariesCountAsInside() {
        // The elder's tap lands exactly on a box edge — the boundary counts
        // as inside, so a finger on the line does not re-anchor to the pad.
        XCTAssertNotNil(PointAskTargetResolver.saliencyBox([PointAskBoxes.leftHalf],
                                                           containing: CGPoint(x: 0.5, y: 1)))
        XCTAssertNotNil(PointAskTargetResolver.saliencyBox([PointAskBoxes.leftHalf],
                                                           containing: CGPoint(x: 0, y: 0)))
        XCTAssertNil(PointAskTargetResolver.saliencyBox([PointAskBoxes.leftHalf],
                                                        containing: CGPoint(x: 0.5 + 0.001, y: 0.5)),
                     "just past the edge is outside")
    }
}
