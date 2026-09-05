import XCTest
@testable import ElderlyAssistant

/// Photo preparation for the vision call (design §5.3): uniform scale,
/// NO crop (load-bearing for the overlay mapping), orientation
/// normalization, and the photo-hash.
final class ApplianceImagePreparerTests: XCTestCase {

    private func makeImage(width: CGFloat, height: CGFloat,
                           orientation: UIImage.Orientation = .up) -> UIImage {
        // scale = 1 is load-bearing: the default format renders at the
        // SIMULATOR'S display scale (3x on Plus-class devices), which would
        // triple the cgImage's pixels and make every size assertion below
        // device-dependent. 1 point == 1 pixel keeps fixtures exact.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                               format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
        guard let cg = rendered.cgImage else { return rendered }
        return UIImage(cgImage: cg, scale: 1, orientation: orientation)
    }

    func testLandscapeImageScalesUniformlyToMaxLongEdge() {
        let prepared = ApplianceImagePreparer.prepare(makeImage(width: 2048, height: 1024))
        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.image.size.width ?? 0, 1024, accuracy: 0.5)
        XCTAssertEqual(prepared?.image.size.height ?? 0, 512, accuracy: 0.5,
                       "aspect ratio must be preserved exactly — no crop (§5.3)")
    }

    func testPortraitImageScalesUniformly() {
        let prepared = ApplianceImagePreparer.prepare(makeImage(width: 1024, height: 4096))
        XCTAssertEqual(prepared?.image.size.width ?? 0, 256, accuracy: 0.5)
        XCTAssertEqual(prepared?.image.size.height ?? 0, 1024, accuracy: 0.5)
    }

    func testSmallImageIsNotUpscaled() {
        let prepared = ApplianceImagePreparer.prepare(makeImage(width: 400, height: 300))
        XCTAssertEqual(prepared?.image.size.width ?? 0, 400, accuracy: 0.5)
        XCTAssertEqual(prepared?.image.size.height ?? 0, 300, accuracy: 0.5)
    }

    func testRotatedCaptureIsBakedIntoPixels() {
        // A camera-style image: 100×200 bitmap flagged .right. The
        // prepared output must be the ORIENTED frame (200×100) with the
        // rotation baked in, so the frame Gemini sees and the frame the
        // overlay draws on are the same pixels.
        let prepared = ApplianceImagePreparer.prepare(
            makeImage(width: 100, height: 200, orientation: .right))
        XCTAssertEqual(prepared?.image.size.width ?? 0, 200, accuracy: 0.5)
        XCTAssertEqual(prepared?.image.size.height ?? 0, 100, accuracy: 0.5)
        XCTAssertEqual(prepared?.image.imageOrientation, .up)
    }

    func testPhotoHashIsSha256OfTheJPEGBytes() {
        let prepared = ApplianceImagePreparer.prepare(makeImage(width: 64, height: 64))
        XCTAssertEqual(prepared?.photoHash,
                       ApplianceImagePreparer.sha256Hex(prepared?.jpegData ?? Data()))
        XCTAssertEqual(prepared?.photoHash.count, 64, "SHA-256 hex is 64 chars")
    }

    func testSameImageProducesSameHashAcrossPrepareCalls() {
        let image = makeImage(width: 128, height: 128)
        let a = ApplianceImagePreparer.prepare(image)
        let b = ApplianceImagePreparer.prepare(image)
        XCTAssertEqual(a?.photoHash, b?.photoHash,
                       "the photo-hash cache key depends on deterministic output")
    }

    func testJPEGDataIsRealJPEG() {
        let prepared = ApplianceImagePreparer.prepare(makeImage(width: 64, height: 64))
        guard let data = prepared?.jpegData, data.count > 2 else {
            XCTFail("no JPEG data")
            return
        }
        XCTAssertEqual(data[data.startIndex], 0xFF)
        XCTAssertEqual(data[data.startIndex + 1], 0xD8, "JPEG SOI magic bytes")
    }

    func testDegenerateImageReturnsNil() {
        XCTAssertNil(ApplianceImagePreparer.prepare(UIImage()),
                     "a zero-size, bitmap-less image is a capture failure, not guidance")
    }
}
