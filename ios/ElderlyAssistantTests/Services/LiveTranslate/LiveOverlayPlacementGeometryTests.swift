import UIKit
import XCTest
@testable import ElderlyAssistant

/// T-020 — the mapping from a normalized region box to the rect the elder
/// sees, with the expected rectangles the shipped aspect-fit math was missing
/// (CL-8), in both orientations; and the measurement the placement makes
/// against what the view actually draws (FR-LCT-015, NFR-LCT-012, risk R2).
///
/// The pixel checks render off screen with `ImageRenderer`, the established
/// substitute for the accessibility tree: SwiftUI does not vend its
/// `_UIHostingView` elements to UIKit in a unit-test host, so a read-back
/// through UIKit would assert on an empty tree. Pixels cannot be empty by
/// accident, and a wrong font shows up in them.
final class LiveOverlayPlacementGeometryTests: XCTestCase {

    /// A phone-shaped portrait container and a camera-shaped landscape frame:
    /// the combination that letterboxes (bars top and bottom).
    private let portraitContainer = CGSize(width: 390, height: 844)
    private let landscapeFrame = CGSize(width: 1920, height: 1080)

    /// The same pair rotated: a portrait frame pillarboxes in a wide
    /// container, which is the other half of the mapping's reach.
    private let landscapeContainer = CGSize(width: 844, height: 390)
    private let portraitFrame = CGSize(width: 1080, height: 1920)

    private func policy(alwaysShowOriginal: Bool = false) -> LiveOverlayPlacement.Policy {
        LiveTranslateOverlaySurface.policy(config: .default, alwaysShowOriginal: alwaysShowOriginal)
    }

    // MARK: Scenario: the mapping math is covered by expected rectangles

    func testTheLetterboxedRectIsTheExpectedRectangleInAPortraitContainer() {
        let rect = LiveOverlayPlacement.screenRect(
            for: NormalizedBox(xMin: 0.25, yMin: 0.5, xMax: 0.5, yMax: 0.75),
            containerSize: portraitContainer,
            framePixelSize: landscapeFrame)

        // The frame is 16:9 displayed in a 390 × 844 container: it fits the
        // width (scale 0.203125), so it is 390 × 219.375, centred — the bars
        // are (844 − 219.375) / 2 = 312.3125 tall at each end.
        XCTAssertEqual(rect.minX, 97.5, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 422.0, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 97.5, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 54.84375, accuracy: 1e-9)
    }

    func testThePillarboxedRectIsTheExpectedRectangleInALandscapeContainer() {
        let rect = LiveOverlayPlacement.screenRect(
            for: NormalizedBox(xMin: 0.5, yMin: 0.5, xMax: 1.0, yMax: 1.0),
            containerSize: landscapeContainer,
            framePixelSize: portraitFrame)

        // Now the frame fits the height (scale 0.203125): 219.375 × 390,
        // centred horizontally — the bars are 312.3125 wide at each side.
        XCTAssertEqual(rect.minX, 422.0, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 195.0, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 109.6875, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 195.0, accuracy: 1e-9)
    }

    func testAnUnletterboxedContainerMapsOneToOne() {
        let rect = LiveOverlayPlacement.screenRect(
            for: NormalizedBox(xMin: 0.1, yMin: 0.2, xMax: 0.4, yMax: 0.6),
            containerSize: CGSize(width: 400, height: 800),
            framePixelSize: CGSize(width: 400, height: 800))

        // Component-wise with a tolerance: 0.3 × 400 is 120.00000000000001 in
        // binary floating point, and a rect equality here would fail on the
        // representation rather than on the mapping.
        XCTAssertEqual(rect.minX, 40, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 160, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 120, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 320, accuracy: 1e-9)
    }

    /// The mapping is the shipped mapper's, value for value — no second
    /// aspect-fit implementation to drift from it (NFR-LCT-012).
    func testTheMappingIsTheShippedMappersOwnMath() {
        let cases: [(box: NormalizedBox, container: CGSize, frame: CGSize)] = [
            (NormalizedBox(xMin: 0.1, yMin: 0.2, xMax: 0.3, yMax: 0.5), portraitContainer, landscapeFrame),
            (NormalizedBox(xMin: 0.0, yMin: 0.0, xMax: 1.0, yMax: 1.0), portraitContainer, landscapeFrame),
            (NormalizedBox(xMin: 0.4, yMin: 0.1, xMax: 0.9, yMax: 0.3), landscapeContainer, portraitFrame),
            (NormalizedBox(xMin: 0.2, yMin: 0.7, xMax: 0.25, yMax: 0.75), CGSize(width: 320, height: 480),
             CGSize(width: 640, height: 480))
        ]

        for entry in cases {
            let displayed = ApplianceOverlayMapper.displayedImageRect(containerSize: entry.container,
                                                                      imageSize: entry.frame)
            let expected = CGRect(x: displayed.minX + CGFloat(entry.box.xMin) * displayed.width,
                                  y: displayed.minY + CGFloat(entry.box.yMin) * displayed.height,
                                  width: CGFloat(entry.box.xMax - entry.box.xMin) * displayed.width,
                                  height: CGFloat(entry.box.yMax - entry.box.yMin) * displayed.height)
            let actual = LiveOverlayPlacement.screenRect(for: entry.box, containerSize: entry.container,
                                                         framePixelSize: entry.frame)
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 1e-9)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 1e-9)
            XCTAssertEqual(actual.width, expected.width, accuracy: 1e-9)
            XCTAssertEqual(actual.height, expected.height, accuracy: 1e-9)
        }
    }

    func testADegenerateFrameHasNoRectToDrawInto() {
        for frame in [CGSize.zero, CGSize(width: 0, height: 1080), CGSize(width: 1920, height: 0)] {
            XCTAssertEqual(LiveOverlayPlacement.screenRect(
                for: NormalizedBox(xMin: 0, yMin: 0, xMax: 1, yMax: 1),
                containerSize: portraitContainer, framePixelSize: frame), .zero)
        }
    }

    /// Rotation is a recomputation from the normalized box, never a
    /// transformation of a stale on-screen rectangle: the same box in the
    /// rotated container maps through the new container's own letterboxing.
    func testRotatingTheContainerRecomputesTheRectFromTheNormalizedBox() {
        let box = NormalizedBox(xMin: 0.25, yMin: 0.25, xMax: 0.75, yMax: 0.5)

        let portrait = LiveOverlayPlacement.screenRect(for: box, containerSize: portraitContainer,
                                                       framePixelSize: landscapeFrame)
        let landscape = LiveOverlayPlacement.screenRect(for: box, containerSize: landscapeContainer,
                                                        framePixelSize: portraitFrame)

        XCTAssertNotEqual(portrait, landscape)
        XCTAssertEqual(landscape, LiveOverlayPlacement.screenRect(
            for: box, containerSize: landscapeContainer, framePixelSize: portraitFrame),
                       "the same call twice is the same rect — nothing is cached between frames")
    }

    // MARK: The pill is sized for the lines it carries

    func testThePillIsAtLeastTheMeasuredBlockOfItsLines() {
        let policy = policy()
        let lines = [
            LiveOverlayTextLine(text: "खुल्ने समय", pointSize: policy.minPointSize, weight: .primary),
            LiveOverlayTextLine(text: "Opening hours", pointSize: policy.secondaryPointSize,
                                weight: .secondary)
        ]
        let size = LiveOverlayPlacement.pillSize(for: lines, policy: policy,
                                                 measure: LiveOverlayTextMetrics.measure)
        let primary = LiveOverlayTextMetrics.measure(lines[0].text, pointSize: lines[0].pointSize,
                                                     weight: .primary)
        let secondary = LiveOverlayTextMetrics.measure(lines[1].text,
                                                       pointSize: lines[1].pointSize,
                                                       weight: .secondary)

        XCTAssertGreaterThanOrEqual(size.width, max(primary.width, secondary.width) + 2 * policy.pillPadding)
        XCTAssertGreaterThanOrEqual(size.height,
                                    primary.height + secondary.height + policy.lineSpacing
                                    + 2 * policy.pillPadding)
    }

    func testAPillForNoLinesIsStillAPill() {
        let size = LiveOverlayPlacement.pillSize(for: [], policy: policy(),
                                                 measure: LiveOverlayTextMetrics.measure)
        XCTAssertEqual(size, CGSize(width: 2 * policy().pillPadding,
                                    height: 2 * policy().pillPadding))
    }

    // MARK: Scenario: measurement and rendering share one measurer
    //
    // Measured, not asserted: the bubble is rendered off screen and the ink
    // it produced is checked against the rect the placement measured for it.
    // A font, a size or a padding that had drifted from the measurement would
    // put text pixels outside that rect, and these tests would see them.

    @MainActor
    func testTheInPlaceTranslationIsDrawnInsideTheRectItWasMeasuredFor() throws {
        for translation in ["Open the gate", "गेट खोल्नुहोस्"] {
            let region = TextRegionStabilizer.StableTextRegion(
                id: TextRegionStabilizer.RegionIdentity(rawValue: 0),
                text: "गेट खोल्नुहोस्",
                normalizedText: "गेट खोल्नुहोस्",
                box: NormalizedBox(xMin: 0.15, yMin: 0.4, xMax: 0.85, yMax: 0.48),
                detectedLanguage: "ne",
                confidence: 0.9)
            let result = TranslationResult.resolved(originalText: region.text,
                                                    translation: translation,
                                                    tier: .dictionary)
            let placements = LiveOverlayPlacement.place(
                regions: [region], results: [region.id: result],
                containerSize: portraitContainer, framePixelSize: portraitContainer,
                safeArea: CGRect(origin: .zero, size: portraitContainer),
                policy: policy(), stateCopy: { _ in nil })
            let inPlaceRect = try XCTUnwrap(inPlaceRect(in: placements))
            let own = LiveOverlayPlacement.screenRect(for: region.box,
                                                       containerSize: portraitContainer,
                                                       framePixelSize: portraitContainer)
            // The drawn box is the box the fit was measured against, and it
            // covers the printed text it replaces: opaque over its own source
            // and nothing else (owner UX rework, 2026-09-17).
            XCTAssertTrue(inPlaceRect.insetBy(dx: -1e-9, dy: -1e-9).contains(own),
                          "the in-place box must cover the printed text it replaces")
            XCTAssertGreaterThanOrEqual(inPlaceRect.width, own.width,
                                        "and it is never narrower than the text it replaces")
            XCTAssertGreaterThanOrEqual(inPlaceRect.height, own.height)
            // The box the fit was decided on is a ceiling, not a promise: the
            // drawn box hugs the translation (`inPlaceTightBox`), so for a
            // translation that needs no more room than the sign it is the
            // sign's own rect — and it can never exceed what was proved clear
            // of the region's neighbours.
            let ceiling = LiveOverlayPlacement.inPlaceMaxBox(regionRect: own, obstacles: [],
                                                             bounds: CGRect(origin: .zero,
                                                                            size: portraitContainer),
                                                             growth: policy().inPlaceMaxGrowth)
            XCTAssertTrue(ceiling.insetBy(dx: -1e-9, dy: -1e-9).contains(inPlaceRect),
                          "the drawn box stays inside the ceiling the fit was measured against")
            let surface = LiveTranslateOverlaySurface(placements: placements, policy: policy(),
                                                      locale: Locale(identifier: "ne-NP"))

            let image = try XCTUnwrap(OverlayRenderProbe.render(surface, size: portraitContainer))
            try OverlayRenderProbe.assertInkInside(
                image, rect: inPlaceRect, allowed: chromeRects(),
                message: "the drawn translation \(translation) left the rect it was measured for")
        }
    }

    /// A callout is the fallback, so the fixture is a sign too small to hold
    /// its own translation: the pill then has to keep its text inside itself.
    @MainActor
    func testACalloutKeepsItsTextHorizontallyInsideItsPill() throws {
        let region = TextRegionStabilizer.StableTextRegion(
            id: TextRegionStabilizer.RegionIdentity(rawValue: 0),
            text: "Opening hours",
            normalizedText: "opening hours",
            box: NormalizedBox(xMin: 0.2, yMin: 0.5, xMax: 0.26, yMax: 0.52),
            detectedLanguage: "en",
            confidence: 0.9)
        let result = TranslationResult.resolved(originalText: region.text,
                                                translation: "खुल्ने समय",
                                                tier: .cloud)
        let placements = LiveOverlayPlacement.place(
            regions: [region], results: [region.id: result],
            containerSize: portraitContainer, framePixelSize: portraitContainer,
            safeArea: CGRect(origin: .zero, size: portraitContainer),
            policy: policy(), stateCopy: { _ in nil })
        let pillRect = try XCTUnwrap(calloutRect(in: placements))
        XCTAssertFalse(pillRect.intersects(
            LiveOverlayPlacement.screenRect(for: region.box, containerSize: portraitContainer,
                                            framePixelSize: portraitContainer)))
        // The anchor is above the region here, so the leader line is vertical
        // and any ink outside the pill's horizontal band is the bubble's own
        // text escaping the box it was measured for.
        let surface = LiveTranslateOverlaySurface(placements: placements, policy: policy(),
                                                  locale: Locale(identifier: "ne-NP"))

        let image = try XCTUnwrap(OverlayRenderProbe.render(surface, size: portraitContainer))
        // Above the chrome strip only: the strip carries the FR-LCT-017
        // control, whose own ink spans the width by design and would otherwise
        // be read as the bubble escaping its pill.
        let aboveChrome = CGRect(x: 0, y: 0, width: portraitContainer.width,
                                 height: chromeRects().first?.minY ?? portraitContainer.height)
        let drawn = try OverlayRenderProbe.ink(in: image, within: aboveChrome)

        XCTAssertFalse(drawn.isEmpty, "the callout rendered nothing")
        // A vertically anchored callout's only horizontal excursion is its
        // own pill, so an ink bound outside it is the bubble's text escaping
        // the box it was measured for.
        let scale = image.scale
        let tolerance = 1.5 * scale
        XCTAssertGreaterThanOrEqual(CGFloat(drawn.minX), (pillRect.minX * scale) - tolerance,
                                    "the callout's ink starts left of its pill")
        XCTAssertLessThanOrEqual(CGFloat(drawn.maxX), (pillRect.maxX * scale) + tolerance,
                                 "the callout's ink runs past its pill")
    }

    // MARK: Placement accessors

    private func chromeRects() -> [CGRect] {
        LiveTranslateOverlaySurface.chromeRects(containerSize: portraitContainer)
    }

    private func inPlaceRect(in placements: [LiveOverlayPlacement.PlacedOverlay]) -> CGRect? {
        guard case .inPlace(_, let rect) = placements.first?.form else { return nil }
        return rect
    }

    private func calloutRect(in placements: [LiveOverlayPlacement.PlacedOverlay]) -> CGRect? {
        guard case .callout(_, _, let pillRect) = placements.first?.form else { return nil }
        return pillRect
    }
}
