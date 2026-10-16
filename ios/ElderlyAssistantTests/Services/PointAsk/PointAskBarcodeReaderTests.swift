import CoreGraphics
import XCTest
@testable import ElderlyAssistant

/// [POINT-TAP-ASK] (2026-09-19) Barcode-reader contract (pure seams —
/// the Vision detection itself is a smoke-tested thin wrapper):
///  - `parsedPayloads` trims surrounding whitespace/newlines, drops
///    nil/blank payloads, and collapses duplicates first-seen-first;
///  - `detect(in:)` over an image with no barcode returns [] (the honest
///    no-detection outcome) and never throws.
///
/// Positive detections need real barcode artwork — a device verification
/// item (scan a food pack), not a unit-test fixture.
final class PointAskBarcodeReaderTests: XCTestCase {

    // MARK: - Parsing matrix

    func testParsesCleanPayloadsInOrder() {
        XCTAssertEqual(PointAskBarcodeReader.parsedPayloads([
            "3017620422003", "8901063010013", "5010212654864"
        ]), ["3017620422003", "8901063010013", "5010212654864"])
    }

    func testTrimsSurroundingWhitespaceAndNewlines() {
        XCTAssertEqual(PointAskBarcodeReader.parsedPayloads([
            "  3017620422003 ", "\n8901063010013\t", " 5010212654864\n"
        ]), ["3017620422003", "8901063010013", "5010212654864"])
    }

    func testDropsNilAndBlankPayloads() {
        // A symbology hit without a decoded payload is not a barcode
        // anyone can look up.
        XCTAssertEqual(PointAskBarcodeReader.parsedPayloads([
            nil, "", "   ", "\n", "3017620422003"
        ]), ["3017620422003"])
    }

    func testCollapsesDuplicatePayloadsKeepingFirstOccurrence() {
        // The same barcode occupying several scan lines is ONE barcode.
        XCTAssertEqual(PointAskBarcodeReader.parsedPayloads([
            "3017620422003", "8901063010013", "3017620422003", " 3017620422003 "
        ]), ["3017620422003", "8901063010013"])
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(PointAskBarcodeReader.parsedPayloads([]), [])
        XCTAssertEqual(PointAskBarcodeReader.parsedPayloads([nil, "", "  "]), [])
    }

    func testNonASCIIPayloadsPassThroughUntouched() {
        // Shape-agnostic by contract: the reader reports, the FOOD gate
        // (`ProductLookupTool.isFoodBarcode`) decides what may leave the
        // device. A Devanagari payload must not be mangled here.
        XCTAssertEqual(PointAskBarcodeReader.parsedPayloads(["३०१७६२०४२२००३"]),
                       ["३०१७६२०४२२००३"])
    }

    // MARK: - Vision seam smoke test

    func testDetectOnBlankImageFindsNothingAndNeverThrows() {
        let image = Self.blankImage()
        XCTAssertEqual(PointAskBarcodeReader.detect(in: image), [])
    }

    /// 4×4 white CGImage via a bitmap context — enough for a smoke test
    /// that the Vision seam runs headless and returns the honest empty
    /// result on an image with nothing to detect.
    private static func blankImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 4, height: 4,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()!
    }
}
