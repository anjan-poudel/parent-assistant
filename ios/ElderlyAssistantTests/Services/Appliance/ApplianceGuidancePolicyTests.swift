import XCTest
@testable import ElderlyAssistant

/// Confidence thresholds and fallback decisions (design §4.1): hedge
/// below 0.4 identification confidence, never circle below 0.5 control
/// confidence, and the "can't locate precisely" fallback.
final class ApplianceGuidancePolicyTests: XCTestCase {

    private func box(_ xMin: Double = 0.1, _ yMin: Double = 0.1,
                     _ xMax: Double = 0.3, _ yMax: Double = 0.3) -> NormalizedBox {
        NormalizedBox(xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax)
    }

    private func guidance(confidence: Double,
                          controls: [GroundedControl] = [],
                          steps: [String] = ["step"]) -> ApplianceGuidance {
        ApplianceGuidance(
            identity: ApplianceIdentity(brand: nil, model: nil,
                                        category: "microwave", displayName: "d"),
            steps: steps, groundedControls: controls, spokenSummary: "s",
            confidence: confidence)
    }

    // MARK: - Identification hedge threshold (0.4)

    func testBelowIdentificationThresholdIsHedged() {
        XCTAssertTrue(ApplianceGuidancePolicy.presentation(for: guidance(confidence: 0.39)).hedged)
        XCTAssertTrue(ApplianceGuidancePolicy.presentation(for: guidance(confidence: 0.0)).hedged)
    }

    func testAtIdentificationThresholdIsNotHedged() {
        XCTAssertFalse(ApplianceGuidancePolicy.presentation(for: guidance(confidence: 0.4)).hedged)
        XCTAssertFalse(ApplianceGuidancePolicy.presentation(for: guidance(confidence: 0.95)).hedged)
    }

    // MARK: - Per-control circle threshold (0.5)

    func testControlsBelowThresholdAreNotCircled() {
        let low = GroundedControl(label: "a", stepNumber: 1,
                                  normalizedBox: box(), confidence: 0.49)
        let at = GroundedControl(label: "b", stepNumber: 2,
                                 normalizedBox: box(), confidence: 0.5)
        let high = GroundedControl(label: "c", stepNumber: 3,
                                   normalizedBox: box(), confidence: 0.99)
        let p = ApplianceGuidancePolicy.presentation(
            for: guidance(confidence: 0.9, controls: [low, at, high]))
        XCTAssertEqual(p.visibleControls.map(\.label), ["b", "c"],
                       "0.49 drops, 0.5 (inclusive) and above circle")
    }

    // MARK: - Malformed boxes

    func testMalformedBoxesAreDroppedEvenWithHighConfidence() {
        let cases: [(String, NormalizedBox)] = [
            ("zero-area", box(0.5, 0.5, 0.5, 0.6)),
            ("inverted-x", box(0.6, 0.1, 0.3, 0.3)),
            ("inverted-y", box(0.1, 0.6, 0.3, 0.3)),
            ("fully-outside", box(1.2, 1.2, 1.5, 1.5)),
            ("negative-outside", box(-0.9, -0.9, -0.1, -0.1)),
            ("nan", NormalizedBox(xMin: .nan, yMin: 0.1, xMax: 0.3, yMax: 0.3)),
        ]
        for (name, badBox) in cases {
            let p = ApplianceGuidancePolicy.presentation(for: guidance(
                confidence: 0.9,
                controls: [GroundedControl(label: name, stepNumber: nil,
                                           normalizedBox: badBox, confidence: 0.99)]))
            XCTAssertTrue(p.visibleControls.isEmpty, "\(name) must not produce a circle")
        }
    }

    func testPartiallyOutsideBoxStillCircles() {
        // Intersecting the frame is plausible localization; only fully-
        // outside/degenerate boxes are dropped.
        let p = ApplianceGuidancePolicy.presentation(for: guidance(
            confidence: 0.9,
            controls: [GroundedControl(label: "edge", stepNumber: nil,
                                       normalizedBox: box(0.9, 0.9, 1.2, 1.2),
                                       confidence: 0.9)]))
        XCTAssertEqual(p.visibleControls.count, 1)
    }

    // MARK: - "Can't locate precisely" fallback

    func testCloserPhotoHintOnlyWhenStepsExistButNothingCircled() {
        // Steps, no visible controls → hint.
        let noControls = ApplianceGuidancePolicy.presentation(
            for: guidance(confidence: 0.9, controls: [], steps: ["a", "b"]))
        XCTAssertTrue(noControls.showCloserPhotoHint)

        // Steps AND a circled control → no hint.
        let circled = ApplianceGuidancePolicy.presentation(for: guidance(
            confidence: 0.9,
            controls: [GroundedControl(label: "x", stepNumber: nil,
                                       normalizedBox: box(), confidence: 0.9)]))
        XCTAssertFalse(circled.showCloserPhotoHint)

        // No steps at all (total miss) → no hint: there is nothing to
        // follow, the failure path owns that case.
        let empty = ApplianceGuidancePolicy.presentation(
            for: guidance(confidence: 0.9, controls: [], steps: []))
        XCTAssertFalse(empty.showCloserPhotoHint)
    }

    // MARK: - NormalizedBox.isValid direct

    func testNormalizedBoxValidity() {
        XCTAssertTrue(box().isValid)
        XCTAssertTrue(box(-0.2, -0.2, 0.5, 0.5).isValid, "partial overlap is valid")
        XCTAssertFalse(box(0.4, 0.1, 0.4, 0.2).isValid, "zero width")
        XCTAssertFalse(box(0.1, 0.4, 0.2, 0.4).isValid, "zero height")
        XCTAssertFalse(box(0.5, 0.1, 0.3, 0.2).isValid, "inverted")
        XCTAssertFalse(box(2, 2, 3, 3).isValid, "outside")
        XCTAssertFalse(NormalizedBox(xMin: .infinity, yMin: 0, xMax: 1, yMax: 1).isValid)
    }
}
