import XCTest
@testable import ElderlyAssistant

/// Coordinate-mapping math for the overlay (design §5.1, §10 — pure
/// function, direct unit tests). Letterboxed aspect-fit cases only;
/// no SwiftUI involved.
final class ApplianceOverlayMapperTests: XCTestCase {

    func testExactFitNoLetterbox() {
        let rect = ApplianceOverlayMapper.displayedImageRect(
            containerSize: CGSize(width: 400, height: 400),
            imageSize: CGSize(width: 400, height: 400))
        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(rect.size.width, 400, accuracy: 0.001)
        XCTAssertEqual(rect.size.height, 400, accuracy: 0.001)
    }

    func testSquareImageInTallContainerLetterboxesTopAndBottom() {
        // 400×400 image in a 400×800 container: fills the width, centered
        // vertically with 200pt bars.
        let rect = ApplianceOverlayMapper.displayedImageRect(
            containerSize: CGSize(width: 400, height: 800),
            imageSize: CGSize(width: 400, height: 400))
        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 200, accuracy: 0.001)
        XCTAssertEqual(rect.size, CGSize(width: 400, height: 400))
    }

    func testWideImageInTallContainerScalesDown() {
        // 800×400 image in a 400×600 container: scale = 0.5 (width-bound),
        // displayed 400×200 centered → y offset 200.
        let rect = ApplianceOverlayMapper.displayedImageRect(
            containerSize: CGSize(width: 400, height: 600),
            imageSize: CGSize(width: 800, height: 400))
        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 200, accuracy: 0.001)
        XCTAssertEqual(rect.size.width, 400, accuracy: 0.001)
        XCTAssertEqual(rect.size.height, 200, accuracy: 0.001)
    }

    func testPortraitImageInLandscapeContainerLetterboxesLeftAndRight() {
        // 400×800 image in an 800×400 container: scale = 0.5
        // (height-bound), displayed 200×400 centered → x offset 300.
        let rect = ApplianceOverlayMapper.displayedImageRect(
            containerSize: CGSize(width: 800, height: 400),
            imageSize: CGSize(width: 400, height: 800))
        XCTAssertEqual(rect.origin.x, 300, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(rect.size, CGSize(width: 200, height: 400))
    }

    func testScreenPointMapsNormalizedCenterThroughLetterbox() {
        // Same geometry as testWideImage…: box center (0.5, 0.5) lands at
        // the container's center (200, 300).
        let point = ApplianceOverlayMapper.screenPoint(
            forBoxCenterNormalized: (0.5, 0.5),
            containerSize: CGSize(width: 400, height: 600),
            imageSize: CGSize(width: 800, height: 400))
        XCTAssertEqual(point.x, 200, accuracy: 0.001)
        XCTAssertEqual(point.y, 300, accuracy: 0.001)
    }

    func testScreenPointOffCenter() {
        // Box center (0.25, 0.75) in the portrait-in-landscape geometry:
        // displayed rect origin (300, 0), size (200, 400) →
        // (300 + 0.25*200, 0 + 0.75*400) = (350, 300).
        let point = ApplianceOverlayMapper.screenPoint(
            forBoxCenterNormalized: (0.25, 0.75),
            containerSize: CGSize(width: 800, height: 400),
            imageSize: CGSize(width: 400, height: 800))
        XCTAssertEqual(point.x, 350, accuracy: 0.001)
        XCTAssertEqual(point.y, 300, accuracy: 0.001)
    }

    func testScreenPointScalesUpWhenImageSmallerThanContainer() {
        // 100×100 image in a 400×400 container: scale = 4 (up), box
        // (0.1, 0.9) → (40, 360).
        let point = ApplianceOverlayMapper.screenPoint(
            forBoxCenterNormalized: (0.1, 0.9),
            containerSize: CGSize(width: 400, height: 400),
            imageSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(point.x, 40, accuracy: 0.001)
        XCTAssertEqual(point.y, 360, accuracy: 0.001)
    }

    func testZeroSizesReturnZeroRect() {
        XCTAssertEqual(ApplianceOverlayMapper.displayedImageRect(
            containerSize: .zero, imageSize: CGSize(width: 100, height: 100)), .zero)
        XCTAssertEqual(ApplianceOverlayMapper.displayedImageRect(
            containerSize: CGSize(width: 100, height: 100), imageSize: .zero), .zero)
        XCTAssertEqual(ApplianceOverlayMapper.displayedImageRect(
            containerSize: CGSize(width: 100, height: 100),
            imageSize: CGSize(width: 0, height: 100)), .zero)
    }

    func testWholeControlConvenienceMatchesBoxCenter() {
        let control = GroundedControl(
            label: "START", stepNumber: 1,
            normalizedBox: NormalizedBox(xMin: 0.2, yMin: 0.4, xMax: 0.6, yMax: 0.8),
            confidence: 0.9)
        let viaControl = ApplianceOverlayMapper.screenPoint(
            for: control,
            containerSize: CGSize(width: 400, height: 600),
            imageSize: CGSize(width: 800, height: 400))
        let viaCenter = ApplianceOverlayMapper.screenPoint(
            forBoxCenterNormalized: (0.4, 0.6),
            containerSize: CGSize(width: 400, height: 600),
            imageSize: CGSize(width: 800, height: 400))
        XCTAssertEqual(viaControl.x, viaCenter.x, accuracy: 0.0001)
        XCTAssertEqual(viaControl.y, viaCenter.y, accuracy: 0.0001)
    }
}
