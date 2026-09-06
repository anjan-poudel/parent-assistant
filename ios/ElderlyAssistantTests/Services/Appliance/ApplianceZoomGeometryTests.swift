import XCTest
@testable import ElderlyAssistant

/// Pure zoom/pan clamping for the pinch-to-zoom step close-ups.
final class ApplianceZoomGeometryTests: XCTestCase {

    // MARK: - Scale clamping (1×–4×)

    func testScaleClampsToBounds() {
        XCTAssertEqual(ApplianceZoomGeometry.clampedScale(1), 1)
        XCTAssertEqual(ApplianceZoomGeometry.clampedScale(4), 4)
        XCTAssertEqual(ApplianceZoomGeometry.clampedScale(2.5), 2.5)
        XCTAssertEqual(ApplianceZoomGeometry.clampedScale(0.5), 1, "below min clamps to 1×")
        XCTAssertEqual(ApplianceZoomGeometry.clampedScale(9), 4, "above max clamps to 4×")
        XCTAssertEqual(ApplianceZoomGeometry.clampedScale(0), 1)
        XCTAssertEqual(ApplianceZoomGeometry.clampedScale(-3), 1)
    }

    func testScaleClampHandlesNonFinite() {
        XCTAssertEqual(ApplianceZoomGeometry.clampedScale(.infinity), 4)
        XCTAssertEqual(ApplianceZoomGeometry.clampedScale(.nan), 4)
    }

    // MARK: - Pan clamping

    func testNoPanWhenNotZoomed() {
        XCTAssertEqual(ApplianceZoomGeometry.clampedOffset(
            CGSize(width: 500, height: -500), zoom: 1, baseSize: CGSize(width: 300, height: 200)),
            .zero)
    }

    func testPanLimitScalesWithZoomAndBaseSize() {
        // At 2× over a 300×200 panel the content overhangs by
        // (2-1)*300/2 = 150 horizontally and (2-1)*200/2 = 100 vertically.
        let limit = ApplianceZoomGeometry.clampedOffset(
            CGSize(width: 10_000, height: -10_000),
            zoom: 2, baseSize: CGSize(width: 300, height: 200))
        XCTAssertEqual(limit.width, 150)
        XCTAssertEqual(limit.height, -100)

        // At 4× the travel is 3× larger in each axis.
        let atMax = ApplianceZoomGeometry.clampedOffset(
            CGSize(width: 10_000, height: 10_000),
            zoom: 4, baseSize: CGSize(width: 300, height: 200))
        XCTAssertEqual(atMax.width, 450)
        XCTAssertEqual(atMax.height, 300)
    }

    func testInRangePanPassesThrough() {
        let offset = CGSize(width: 40, height: -25)
        XCTAssertEqual(ApplianceZoomGeometry.clampedOffset(
            offset, zoom: 2, baseSize: CGSize(width: 300, height: 200)), offset)
    }

    func testPanClampsBothSignsSymmetrically() {
        let base = CGSize(width: 300, height: 200)
        let positive = ApplianceZoomGeometry.clampedOffset(
            CGSize(width: 999, height: 999), zoom: 3, baseSize: base)
        let negative = ApplianceZoomGeometry.clampedOffset(
            CGSize(width: -999, height: -999), zoom: 3, baseSize: base)
        XCTAssertEqual(positive.width, 300)
        XCTAssertEqual(positive.height, 200)
        XCTAssertEqual(negative.width, -300)
        XCTAssertEqual(negative.height, -200)
    }

    func testOutOfRangeZoomClampsBeforePanLimit() {
        // A transient zoom > 4 must not widen the pan window.
        let offset = ApplianceZoomGeometry.clampedOffset(
            CGSize(width: 10_000, height: 0), zoom: 100, baseSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(offset.width, (4 - 1) * 100 / 2)
    }

    func testPanClampHandlesNonFinite() {
        XCTAssertEqual(ApplianceZoomGeometry.clampedOffset(
            CGSize(width: CGFloat.nan, height: CGFloat.infinity), zoom: 2,
            baseSize: CGSize(width: 300, height: 200)), .zero)
    }
}
