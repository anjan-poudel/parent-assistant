import XCTest
@testable import ElderlyAssistant

/// Crop math for the per-step close-ups: padded box → crop rect in CGImage
/// PIXEL space + the box re-expressed inside the crop. Pure function,
/// direct unit tests (same treatment as ApplianceOverlayMapper).
final class ApplianceCropGeometryTests: XCTestCase {

    private func box(_ xMin: Double, _ yMin: Double,
                     _ xMax: Double, _ yMax: Double) -> NormalizedBox {
        NormalizedBox(xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax)
    }

    // MARK: - Core crop math (1024×1024 photo, default 1.8× padding)

    func testCenteredBoxGetsPaddingAndStaysCentered() {
        // Box 256×256px at center; 1.8× padding → 460.8px crop, centered.
        let crop = ApplianceCropGeometry.crop(
            for: box(0.25, 0.25, 0.5, 0.5),
            imagePixelSize: CGSize(width: 1024, height: 1024))
        XCTAssertNotNil(crop)
        let rect = crop!.rect
        XCTAssertEqual(rect.minX, 153.6, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 153.6, accuracy: 0.001)
        XCTAssertEqual(rect.width, 460.8, accuracy: 0.001)
        XCTAssertEqual(rect.height, 460.8, accuracy: 0.001)
        // Box re-expressed inside the crop, centered at (0.5, 0.5).
        XCTAssertEqual(crop!.boxInCrop.minX, 102.4 / 460.8, accuracy: 0.0001)
        XCTAssertEqual(crop!.boxInCrop.width, 256 / 460.8, accuracy: 0.0001)
        XCTAssertEqual(crop!.boxInCrop.midX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(crop!.boxInCrop.midY, 0.5, accuracy: 0.0001)
    }

    func testTinyBoxGetsMinSideFloor() {
        // Box ~20px at center: 1.8× would be ~37px — far too small to read
        // when displayed, so minSidePixels (180) must win.
        let crop = ApplianceCropGeometry.crop(
            for: box(0.49, 0.49, 0.51, 0.51),
            imagePixelSize: CGSize(width: 1024, height: 1024))
        let rect = crop!.rect
        XCTAssertEqual(rect.width, 180, accuracy: 0.001)
        XCTAssertEqual(rect.height, 180, accuracy: 0.001)
        XCTAssertEqual(rect.midX, 512, accuracy: 0.001)
        XCTAssertEqual(crop!.boxInCrop.midX, 0.5, accuracy: 0.0001)
    }

    func testEdgeBoxCropIsClampedInsideImage() {
        // Box touching the right/bottom photo edge: padding would push the
        // crop past the image, so it clamps to the edge (never extends
        // beyond) and the box's on-photo part stays fully inside.
        let crop = ApplianceCropGeometry.crop(
            for: box(0.95, 0.95, 1.0, 1.0),
            imagePixelSize: CGSize(width: 1024, height: 1024))
        let rect = crop!.rect
        XCTAssertEqual(rect.maxX, 1024, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 1024, accuracy: 0.001)
        XCTAssertEqual(rect.width, 180, accuracy: 0.001)
        XCTAssertEqual(crop!.boxInCrop.maxX, 1.0, accuracy: 0.0001)
        XCTAssertEqual(crop!.boxInCrop.maxY, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(crop!.boxInCrop.minX, 0.7)
    }

    func testPartiallyOutsideBoxKeepsVisiblePartAndOnPhotoCenter() {
        // Box 0.9…1.2 (runs past the right/bottom edge, still a valid
        // localization). The crop clamps to the edge and the ring box must
        // be the box ∩ photo — its center stays ON the photo.
        let crop = ApplianceCropGeometry.crop(
            for: box(0.9, 0.9, 1.2, 1.2),
            imagePixelSize: CGSize(width: 1024, height: 1024))
        let rect = crop!.rect
        XCTAssertEqual(rect.maxX, 1024, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 1024, accuracy: 0.001)
        XCTAssertEqual(crop!.boxInCrop.maxX, 1.0, accuracy: 0.0001)
        XCTAssertEqual(crop!.boxInCrop.maxY, 1.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(crop!.boxInCrop.midX, 1.0)
        XCTAssertEqual(crop!.boxInCrop.width, 102.4 / 552.96, accuracy: 0.0001)
    }

    func testOversizedCropCapsAtWholeImage() {
        // Small 120px image where even minSide exceeds the image: the crop
        // must degrade to the full image rather than extend past it.
        let crop = ApplianceCropGeometry.crop(
            for: box(0.5, 0.5, 0.6, 0.6),
            imagePixelSize: CGSize(width: 120, height: 120))
        XCTAssertEqual(crop!.rect, CGRect(x: 0, y: 0, width: 120, height: 120))
        XCTAssertEqual(crop!.boxInCrop.minX, 0.5, accuracy: 0.0001)
    }

    // MARK: - Guarantees over varied boxes

    func testCropNeverExceedsImageAndAlwaysContainsVisibleBox() {
        let samples: [NormalizedBox] = [
            box(0.1, 0.1, 0.3, 0.3),
            box(0.0, 0.0, 0.2, 0.2),
            box(0.7, 0.1, 0.95, 0.9),
            box(-0.1, -0.1, 0.2, 0.2),
            box(0.8, 0.8, 1.05, 1.05),
            box(0.5, 0.5, 0.52, 0.52),
            box(0.0, 0.0, 1.0, 1.0),
        ]
        for sample in samples {
            let crop = ApplianceCropGeometry.crop(
                for: sample,
                imagePixelSize: CGSize(width: 800, height: 600))
            guard let crop else {
                XCTFail("valid box \(sample) must crop")
                continue
            }
            // Within image bounds.
            XCTAssertGreaterThanOrEqual(crop.rect.minX, 0)
            XCTAssertGreaterThanOrEqual(crop.rect.minY, 0)
            XCTAssertLessThanOrEqual(crop.rect.maxX, 800)
            XCTAssertLessThanOrEqual(crop.rect.maxY, 600)
            // Box-in-crop normalized to the crop and on-photo only.
            XCTAssertLessThanOrEqual(crop.boxInCrop.maxX, 1.0 + 0.0001)
            XCTAssertLessThanOrEqual(crop.boxInCrop.maxY, 1.0 + 0.0001)
            XCTAssertGreaterThanOrEqual(crop.boxInCrop.minX, -0.0001)
            XCTAssertGreaterThanOrEqual(crop.boxInCrop.minY, -0.0001)
            XCTAssertGreaterThan(crop.boxInCrop.width, 0)
            XCTAssertGreaterThan(crop.boxInCrop.height, 0)
        }
    }

    // MARK: - Degenerate inputs → nil

    func testInvalidInputsReturnNil() {
        let size = CGSize(width: 1024, height: 1024)
        XCTAssertNil(ApplianceCropGeometry.crop(for: box(0.1, 0.1, 0.9, 0.9),
                                                imagePixelSize: .zero))
        XCTAssertNil(ApplianceCropGeometry.crop(for: box(0.6, 0.1, 0.3, 0.3),
                                                imagePixelSize: size),
                     "inverted box")
        XCTAssertNil(ApplianceCropGeometry.crop(for: box(0.5, 0.5, 0.5, 0.6),
                                                imagePixelSize: size),
                     "zero-width box")
        XCTAssertNil(ApplianceCropGeometry.crop(for: box(1.5, 1.5, 2, 2),
                                                imagePixelSize: size),
                     "fully outside box")
        XCTAssertNil(ApplianceCropGeometry.crop(
            for: NormalizedBox(xMin: .nan, yMin: 0.1, xMax: 0.3, yMax: 0.3),
            imagePixelSize: size))
        // Nonsensical padding (< 1 would clip the button itself) → nil.
        XCTAssertNil(ApplianceCropGeometry.crop(for: box(0.1, 0.1, 0.3, 0.3),
                                                imagePixelSize: size,
                                                paddingFactor: 0.5))
    }

    // MARK: - Pixels vs points (image scale)

    func testPixelSizeReadsCGImageNotUIImagePoints() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2   // 2× image: points ≠ pixels
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100),
                                               format: format)
        let image = renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        XCTAssertEqual(image.scale, 2)
        XCTAssertEqual(image.size, CGSize(width: 100, height: 100), "size is in POINTS")
        XCTAssertEqual(ApplianceCropGeometry.imagePixelSize(image),
                       CGSize(width: 200, height: 200),
                       "pixel size must be points × scale")
    }

    func testCropAndDisplaySizingThroughRealCGImage() {
        // End-to-end contract the view relies on: the crop rect is in
        // CGImage pixel space, cropping yields the expected pixel dims,
        // and re-wrapping with the source scale keeps point size correct.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100),
                                               format: format)
        let image = renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let pixelSize = ApplianceCropGeometry.imagePixelSize(image)!
        let crop = ApplianceCropGeometry.crop(for: box(0.25, 0.25, 0.5, 0.5),
                                              imagePixelSize: pixelSize)!
        // 50px box, 1.8× would be 90 < minSide 180 → 180px crop, pushed to
        // the top-left origin because the box center (75, 75) can't fit
        // half of 180 before the edge.
        XCTAssertEqual(crop.rect, CGRect(x: 0, y: 0, width: 180, height: 180))
        XCTAssertEqual(crop.boxInCrop.minX, 50 / 180, accuracy: 0.0001)

        let croppedCG = image.cgImage!.cropping(to: crop.rect)!
        XCTAssertEqual(croppedCG.width, 180)
        XCTAssertEqual(croppedCG.height, 180)
        let cropped = UIImage(cgImage: croppedCG, scale: image.scale,
                              orientation: image.imageOrientation)
        XCTAssertEqual(cropped.size, CGSize(width: 90, height: 90),
                       "points = pixels / scale, so the overlay mapper stays consistent")
    }
}
