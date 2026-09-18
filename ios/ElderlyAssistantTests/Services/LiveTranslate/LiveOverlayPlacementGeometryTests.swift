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

    /// The panel is the fallback, so the fixture is a sign too short to hold
    /// its own translation: the panel then has to keep its text inside itself.
    ///
    /// This is the same claim the deleted callout-pill test made, moved to the
    /// surface that replaced the pill: the rows are the placement's own lines
    /// at the sizes it measured, drawn through the feature's one font
    /// constructor, so a font, a size or a padding that had drifted from the
    /// measurement would put text pixels outside the box the placement drew
    /// (R2) — and, on the live overlay, outside the green wash the elder is
    /// reading.
    @MainActor
    func testThePanelKeepsItsTextInsideItsOwnBox() throws {
        let region = TextRegionStabilizer.StableTextRegion(
            id: TextRegionStabilizer.RegionIdentity(rawValue: 0),
            text: "Opening hours",
            normalizedText: "opening hours",
            box: NormalizedBox(xMin: 0.3, yMin: 0.4, xMax: 0.6, yMax: 0.5),
            detectedLanguage: "en",
            confidence: 0.9)
        let result = TranslationResult.resolved(
            originalText: region.text,
            translation: "Please open the gate by the side of the house before the evening",
            tier: .cloud)
        let placements = LiveOverlayPlacement.place(
            regions: [region], results: [region.id: result],
            containerSize: portraitContainer, framePixelSize: portraitContainer,
            safeArea: CGRect(origin: .zero, size: portraitContainer),
            policy: policy(), stateCopy: { _ in nil })
        let panelRect = try XCTUnwrap(panelRect(in: placements),
                                      "the premise: this translation cannot be read in the "
                                      + "sign's own box, so the region is the fallback panel")
        XCTAssertEqual(placements.count, 1)
        // The fallback stands on the text it replaces, which is the whole point
        // of removing the pill: the panel's box covers the sign's own rect.
        let own = LiveOverlayPlacement.screenRect(for: region.box, containerSize: portraitContainer,
                                                  framePixelSize: portraitContainer)
        XCTAssertTrue(panelRect.insetBy(dx: -1e-9, dy: -1e-9).contains(own),
                      "the panel covers the printed text it stands on")

        let surface = LiveTranslateOverlaySurface(placements: placements, policy: policy(),
                                                  locale: Locale(identifier: "ne-NP"))

        let image = try XCTUnwrap(OverlayRenderProbe.render(surface, size: portraitContainer))
        // Above the chrome strip only: the strip carries the FR-LCT-017
        // control, whose own ink spans the width by design and would otherwise
        // be read as the panel's text escaping its box.
        let aboveChrome = CGRect(x: 0, y: 0, width: portraitContainer.width,
                                 height: chromeRects().first?.minY ?? portraitContainer.height)
        let drawn = try OverlayRenderProbe.ink(in: image, within: aboveChrome)

        XCTAssertFalse(drawn.isEmpty, "the panel rendered nothing")
        // A panel's text wraps to its box, so an ink bound outside it is the
        // drawn rows escaping the box the placement measured them for.
        let scale = image.scale
        let tolerance = 1.5 * scale
        XCTAssertGreaterThanOrEqual(CGFloat(drawn.minX), (panelRect.minX * scale) - tolerance,
                                    "the panel's ink starts left of the box it was measured for")
        XCTAssertLessThanOrEqual(CGFloat(drawn.maxX), (panelRect.maxX * scale) + tolerance,
                                 "the panel's ink runs past the box it was measured for")
    }

    // MARK: Placement accessors

    private func chromeRects() -> [CGRect] {
        LiveTranslateOverlaySurface.chromeRects(containerSize: portraitContainer)
    }

    private func inPlaceRect(in placements: [LiveOverlayPlacement.PlacedOverlay]) -> CGRect? {
        guard case .inPlace(_, let rect) = placements.first?.form else { return nil }
        return rect
    }

    private func panelRect(in placements: [LiveOverlayPlacement.PlacedOverlay]) -> CGRect? {
        guard case .scrollablePanel(_, let rect) = placements.first?.form else { return nil }
        return rect
    }
}
