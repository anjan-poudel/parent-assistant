import XCTest
@testable import ElderlyAssistant

/// [TAP-FIX] (2026-09-19) Pins the tap-input contract that the first
/// device test exposed: a tap arrives FRAME-NORMALIZED (0…1), and the
/// session must anchor it as-is — the shipped bug divided by the frame
/// size a second time, so the finger at (0.5, 0.5) anchored a pad box
/// near the origin, tiny and way off the object.
final class PointAskSessionModelTests: XCTestCase {

    func testANormalizedTapPointIsAnchoredAsIs() {
        let point = PointAskSessionModel.normalizedTapPoint(CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(point.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.5, accuracy: 0.0001)
    }

    func testATapOutsideTheFrameIsClampedNotScaled() {
        let point = PointAskSessionModel.normalizedTapPoint(CGPoint(x: 1.4, y: -0.3))
        XCTAssertEqual(point.x, 1.0, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.0, accuracy: 0.0001)
    }

    func testTheRegressionShapeCannotReoccur() {
        // The bug's signature: (0.5, 0.5) ending up at ~(0.0003, 0.0005).
        // A re-division by a 1920×1080 frame would land there; the pin
        // fails the moment any re-scaling is reintroduced.
        let point = PointAskSessionModel.normalizedTapPoint(CGPoint(x: 0.5, y: 0.5))
        XCTAssertGreaterThan(point.x, 0.1)
        XCTAssertGreaterThan(point.y, 0.1)
    }

    // MARK: - [YOLO] The detector label leads the ladder-1 answer

    /// The answer composition is the session model's static seam, so the
    /// label priority is pinned here rather than through a full session.
    @MainActor
    func testTheDetectorLabelLeadsTheLadderOneLineOverTheClassifier() {
        var findings = PointAskFindings()
        findings.detectedLabel = "bottle"
        findings.classLabel = "perfume"
        findings.ocrText = "FLORAL"
        let locale = Locale(identifier: "en-US")

        let composed = PointAskSessionModel.compose(findings,
                                                    locale: locale,
                                                    targetLanguage: .english)

        XCTAssertTrue(composed.spokenLine.contains("bottle"),
                      "the detector names the WHOLE object the elder tapped — "
                      + "its label leads the 'It looks like …' line")
        XCTAssertFalse(composed.spokenLine.contains("perfume"),
                       "the classifier's crop answer never overrides the detector's box label")
        XCTAssertTrue(composed.spokenLine.contains("FLORAL"),
                      "the label-says half still follows: 'It looks like a bottle. The label says: …'")
    }

    @MainActor
    func testTheDetectorLabelAloneIsACompleteLadderOneAnswer() {
        var findings = PointAskFindings()
        findings.detectedLabel = "cup"

        let composed = PointAskSessionModel.compose(findings,
                                                    locale: Locale(identifier: "en-US"),
                                                    targetLanguage: .english)

        XCTAssertFalse(composed.isFailure,
                       "the detector's name alone answers — never the honest-failure line")
        XCTAssertTrue(composed.spokenLine.contains("cup"))
    }

    @MainActor
    func testTheClassifierStillNamesAnObjectWhenThereIsNoDetectorLabel() {
        var findings = PointAskFindings()
        findings.classLabel = "bottle"

        let composed = PointAskSessionModel.compose(findings,
                                                    locale: Locale(identifier: "en-US"),
                                                    targetLanguage: .english)

        XCTAssertTrue(composed.spokenLine.contains("bottle"),
                      "the pre-YOLO ladder is intact: the classifier names the crop")
        XCTAssertFalse(composed.isFailure)
    }
}
