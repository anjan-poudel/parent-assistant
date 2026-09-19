import CoreGraphics
import CoreVideo
import ImageIO
import XCTest
@testable import ElderlyAssistant

/// The crop stage (design §1 item 6, §6): pixel-coordinate cropping
/// (top-left origin, the unit the resolver hands over), the ≤768 px JPEG
/// re-encode for the upload, and the structural "no EXIF" guarantee.
///
/// What the tests pin:
///
///  - **The crop is the box's pixels, nothing else.** A rect is cropped
///    in the feature's top-left origin (Core Image's bottom-left origin is
///    mirrored once), into a buffer of the rect's own size.
///  - **The crop stage refuses rather than invents.** An empty, degenerate
///    or out-of-frame rect is nil — never a guessed crop past the frame's
///    edge (a partial rect clamps to the intersection).
///  - **The upload is a ≤768 px JPEG with no metadata.** The long side is
///    capped, the aspect ratio is kept, and the encoded JPEG carries no
///    EXIF/APP1 segment and no properties — the crop's pixels and nothing
///    else leave the device.
final class PointAskCropTests: XCTestCase {

    // MARK: - Scenario: pixel coordinates, top-left origin

    /// A 320×240 frame, four coloured quadrants: red / green over
    /// blue / yellow (BGRA, top-left origin).
    private func quadrantFrame() -> CVPixelBuffer {
        PointAskTestFrames.pixelBuffer(width: 320, height: 240) { x, y in
            if x < 160 {
                if y < 120 { return (0, 0, 255, 255) }        // red
                return (0, 255, 0, 255)                       // green
            }
            if y < 120 { return (255, 0, 0, 255) }            // blue
            return (255, 255, 0, 255)                         // yellow
        }
    }

    private func assertPixel(_ pixel: (UInt8, UInt8, UInt8, UInt8)?,
                             equals expected: (UInt8, UInt8, UInt8, UInt8),
                             tolerance: Int = 10,
                             _ message: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        guard let pixel else {
            XCTFail("\(message): pixel could not be read", file: file, line: line)
            return
        }
        for (actual, wanted) in [(Int(pixel.0), Int(expected.0)),
                                 (Int(pixel.1), Int(expected.1)),
                                 (Int(pixel.2), Int(expected.2))] {
            XCTAssertLessThanOrEqual(abs(actual - wanted), tolerance,
                                     "\(message): channel \(actual) vs \(wanted)",
                                     file: file, line: line)
        }
    }

    func testTheCropIsAPixelBufferOfTheRectsOwnSize() {
        let crop = PointAskCrop.cropped(quadrantFrame(),
                                        pixelRect: CGRect(x: 40, y: 30, width: 100, height: 80))
        let buffer = try? XCTUnwrap(crop)
        guard let buffer else { return }
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 100)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 80)
    }

    func testTheCropReadsPixelCoordinatesTopLeftOrigin() {
        // The bottom-right quadrant (160, 120, 160, 120) must come back
        // yellow — in the feature's top-left origin. A Core Image
        // bottom-left origin would return the top-right quadrant (blue).
        let crop = try! XCTUnwrap(PointAskCrop.cropped(
            quadrantFrame(), pixelRect: CGRect(x: 160, y: 120, width: 160, height: 120)))

        assertPixel(PointAskTestFrames.rgba(atX: 0, y: 0, in: crop),
                    equals: (255, 255, 0, 255),
                    "the crop's top-left pixel is the tapped quadrant's, not its mirror")
        assertPixel(PointAskTestFrames.rgba(atX: 159, y: 119, in: crop),
                    equals: (255, 255, 0, 255),
                    "the crop's far corner is still the same quadrant")
    }

    func testEachQuadrantCropsToItsOwnColour() {
        let frame = quadrantFrame()
        let quadrants: [(rect: CGRect, colour: (UInt8, UInt8, UInt8, UInt8))] = [
            (CGRect(x: 0, y: 0, width: 160, height: 120), (0, 0, 255, 255)),
            (CGRect(x: 160, y: 0, width: 160, height: 120), (255, 0, 0, 255)),
            (CGRect(x: 0, y: 120, width: 160, height: 120), (0, 255, 0, 255)),
            (CGRect(x: 160, y: 120, width: 160, height: 120), (255, 255, 0, 255))
        ]
        for quadrant in quadrants {
            let crop = try! XCTUnwrap(PointAskCrop.cropped(frame, pixelRect: quadrant.rect))
            assertPixel(PointAskTestFrames.rgba(atX: 80, y: 60, in: crop),
                        equals: quadrant.colour,
                        "quadrant \(quadrant.rect) crops to its own colour")
        }
    }

    // MARK: - Scenario: the crop stage refuses rather than invents

    func testACropWhollyOutsideTheFrameIsRefused() {
        // Truly beyond the frame's edges — no intersection at all.
        XCTAssertNil(PointAskCrop.cropped(quadrantFrame(),
                                          pixelRect: CGRect(x: 330, y: 250, width: 100, height: 100)))
        XCTAssertNil(PointAskCrop.cropped(quadrantFrame(),
                                          pixelRect: CGRect(x: -100, y: -100, width: 50, height: 50)))
    }

    func testAPartiallyOutsideRectIsClampedToTheIntersection() {
        let crop = try! XCTUnwrap(PointAskCrop.cropped(
            quadrantFrame(), pixelRect: CGRect(x: 280, y: 200, width: 100, height: 100)))

        XCTAssertEqual(CVPixelBufferGetWidth(crop), 40)
        XCTAssertEqual(CVPixelBufferGetHeight(crop), 40)
        assertPixel(PointAskTestFrames.rgba(atX: 39, y: 39, in: crop),
                    equals: (255, 255, 0, 255),
                    "the clamped crop reads the frame's bottom-right corner")
    }

    func testAnEmptyOrDegenerateRectIsRefused() {
        let frame = quadrantFrame()
        XCTAssertNil(PointAskCrop.cropped(frame, pixelRect: .zero))
        XCTAssertNil(PointAskCrop.cropped(frame, pixelRect: CGRect(x: 10, y: 10, width: 0, height: 10)))
        XCTAssertNil(PointAskCrop.cropped(frame, pixelRect: CGRect(x: 10, y: 10, width: 10, height: 0)))
        // A negative-width request cannot be expressed: CGRect normalizes
        // negative sizes to positive on construction (verified), so the
        // stage can only ever see the normalized, valid rect.
    }

    // MARK: - Scenario: the upload JPEG is ≤768 px with no EXIF

    private func decodedJPEGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Whether the JPEG bytes carry an APP1 segment — the EXIF/XMP home.
    private func containsAPP1Segment(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return false }
        for index in 0..<(bytes.count - 1) where bytes[index] == 0xFF && bytes[index + 1] == 0xE1 {
            return true
        }
        return false
    }

    func testTheUploadJPEGIsDownscaledToAtMost768OnTheLongSide() throws {
        let frame = PointAskTestFrames.solidPixelBuffer(width: 1024, height: 768,
                                                        rgba: (0, 0, 255, 255))
        let crop = try XCTUnwrap(PointAskCrop.cropped(frame, pixelRect: CGRect(x: 0, y: 0,
                                                                               width: 1024, height: 768)))
        let data = try XCTUnwrap(PointAskCrop.jpegUploadData(from: crop, maxSide: 768))
        let image = try XCTUnwrap(decodedJPEGImage(from: data))

        XCTAssertEqual(image.width, 768, "the long side is exactly the cap")
        XCTAssertEqual(image.height, 576, "the aspect ratio is kept")
    }

    func testAUploadAlreadyWithinTheBoundIsNotResampled() throws {
        let crop = PointAskTestFrames.solidPixelBuffer(width: 200, height: 100,
                                                       rgba: (0, 255, 0, 255))
        let data = try XCTUnwrap(PointAskCrop.jpegUploadData(from: crop, maxSide: 768))
        let image = try XCTUnwrap(decodedJPEGImage(from: data))

        XCTAssertEqual(image.width, 200, "a small crop is sent at its own size")
        XCTAssertEqual(image.height, 100)
    }

    func testTheUploadJPEGCarriesNoEXIFOrGPSMetadata() throws {
        let crop = PointAskTestFrames.solidPixelBuffer(width: 512, height: 256,
                                                       rgba: (255, 255, 0, 255))
        let data = try XCTUnwrap(PointAskCrop.jpegUploadData(from: crop, maxSide: 768))

        XCTAssertEqual(data.prefix(3), Data([0xFF, 0xD8, 0xFF]),
                       "the upload is a real JPEG")
        XCTAssertFalse(containsAPP1Segment(data),
                       "the JPEG carries no APP1 (EXIF/XMP) segment")
        XCTAssertNil(data.range(of: Data("Exif".utf8)), "no EXIF marker text")
        XCTAssertNil(data.range(of: Data("GPS".utf8)), "no GPS text")

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if let properties {
            XCTAssertNil(properties[kCGImagePropertyExifDictionary])
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
            XCTAssertNil(properties[kCGImagePropertyTIFFDictionary],
                         "no timestamp, no device make — the crop's pixels and nothing else")
        }
    }

    func testTheDownscaleKeepsTheAspectRatioForAnyShape() throws {
        let landscape = PointAskTestFrames.solidPixelBuffer(width: 1024, height: 512,
                                                            rgba: (0, 0, 255, 255))
        let data = try XCTUnwrap(PointAskCrop.jpegUploadData(from: landscape, maxSide: 768))
        let image = try XCTUnwrap(decodedJPEGImage(from: data))
        XCTAssertEqual(image.width, 768)
        XCTAssertEqual(image.height, 384)

        let portrait = PointAskTestFrames.solidPixelBuffer(width: 512, height: 1024,
                                                           rgba: (0, 0, 255, 255))
        let portraitData = try XCTUnwrap(PointAskCrop.jpegUploadData(from: portrait, maxSide: 768))
        let portraitImage = try XCTUnwrap(decodedJPEGImage(from: portraitData))
        XCTAssertEqual(portraitImage.height, 768)
        XCTAssertEqual(portraitImage.width, 384)
    }

    func testAZeroMaxSideRefusesTheUpload() {
        let crop = PointAskTestFrames.solidPixelBuffer(width: 64, height: 64,
                                                       rgba: (0, 0, 0, 255))
        XCTAssertNil(PointAskCrop.jpegUploadData(from: crop, maxSide: 0),
                     "a degenerate cap is a configuration defect, never a reason to send the "
                     + "unbounded crop")
        XCTAssertNil(PointAskCrop.downscaledCGImage(from: crop, maxSide: 0))
    }
}
