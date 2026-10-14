import XCTest
import UIKit
import ImageIO
@testable import ElderlyAssistant

/// The ImageIO downsampling contract (native-responsiveness pass,
/// 2026-10-14). `DownsampledImageCache.downsampled(from:maxPixelEdge:)`
/// is the decode path behind the picked-photo flows (events + family
/// contacts): a pure function of the encoded bytes, so the properties
/// the UI and the jetsam budget rely on are pinned here —
///
///   1. the output bitmap NEVER exceeds the requested edge (the whole
///      point: a camera-roll photo must not materialize full-size —
///      `UIImage(data:)` decoded the full bitmap first, ~190 MB at the
///      peak for a 48 MP shot),
///   2. an image already within the edge comes back at NATIVE size
///      (ImageIO never upscales — the same never-upscale rule the old
///      `downsampled(_:maxPixelEdge:)` pair held), and
///   3. undecodable bytes return nil, which callers treat as "no
///      photo" exactly like the old `UIImage(data:)` guard.
///
/// Orientation baking (`kCGImageSourceCreateThumbnailWithTransform`) is
/// pinned too: EXIF-rotated bytes decode to UPRIGHT pixels — the same
/// visible result drawing the old path produced.
final class DownsampledImageCacheTests: XCTestCase {

    // MARK: - Fixtures

    /// A solid-colour JPEG at `width`×`height` pixels — the encoded
    /// bytes the picker hands the decode path.
    private func jpegData(width: Int, height: Int) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    /// JPEG bytes whose STORED pixels are `width`×`height` but whose
    /// EXIF orientation is `orientation` — i.e. the stored bitmap needs
    /// the transform applied to render upright.
    private func orientedJPEGData(width: Int, height: Int,
                                  orientation: Int) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, "public.jpeg" as CFString, 1, nil))
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        CGImageDestinationAddImage(destination,
                                   try XCTUnwrap(image.cgImage),
                                   properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    // MARK: - The decode-size contract

    /// A 1000×500 photo decoded for a 100-pixel edge must come back at
    /// most 100 pixels on its longest side, aspect preserved — the full
    /// bitmap is never materialized (this is the memory win, so the
    /// assertion IS the point).
    func testLargePhotoIsDecodedAtTheRequestedEdge() throws {
        let data = try jpegData(width: 1000, height: 500)
        let thumb = try XCTUnwrap(
            DownsampledImageCache.downsampled(from: data, maxPixelEdge: 100))
        let cg = try XCTUnwrap(thumb.cgImage)

        XCTAssertLessThanOrEqual(max(cg.width, cg.height), 100,
                                 "the decoded bitmap must not exceed the requested edge")
        XCTAssertEqual(Double(cg.width) / Double(cg.height), 2.0, accuracy: 0.1,
                       "downsampling must preserve the photo's aspect ratio")
    }

    /// An image already within the edge is NEVER upscaled — 50×40
    /// bytes asked for a 200-pixel edge come back 50×40, the same
    /// native-size rule the old renderer path held.
    func testSmallPhotoComesBackAtNativeSize() throws {
        let data = try jpegData(width: 50, height: 40)
        let thumb = try XCTUnwrap(
            DownsampledImageCache.downsampled(from: data, maxPixelEdge: 200))
        let cg = try XCTUnwrap(thumb.cgImage)

        XCTAssertEqual(cg.width, 50, "an image within the edge must not be upscaled")
        XCTAssertEqual(cg.height, 40)
    }

    /// Undecodable bytes read as "no photo" (nil) — the caller's
    /// fallback path, never a crash.
    func testUndecodableBytesReturnNil() {
        let garbage = Data("not-a-jpeg-at-all".utf8)
        XCTAssertNil(DownsampledImageCache.downsampled(from: garbage, maxPixelEdge: 100))
        XCTAssertNil(DownsampledImageCache.downsampled(from: Data(), maxPixelEdge: 100))
    }

    /// EXIF orientation is BAKED into upright pixels
    /// (`kCGImageSourceCreateThumbnailWithTransform`): 100×50 stored
    /// pixels tagged "rotate 90°" decode to a 50-wide × 100-tall
    /// bitmap, which is what drawing the old path produced. Without the
    /// transform the output would stay landscape and every rotated
    /// camera-roll photo would import sideways.
    func testExifOrientationIsBakedIntoUprightPixels() throws {
        let data = try orientedJPEGData(width: 100, height: 50, orientation: 6)
        let thumb = try XCTUnwrap(
            DownsampledImageCache.downsampled(from: data, maxPixelEdge: 400))
        let cg = try XCTUnwrap(thumb.cgImage)

        XCTAssertGreaterThan(cg.height, cg.width,
                             "EXIF orientation 6 must decode to an upright (portrait) bitmap")
        XCTAssertEqual(Set([cg.width, cg.height]), Set([50, 100]),
                       "the transform rotates, never rescales")
    }

    // MARK: - The cache contract around it

    /// One decode per (source key, rendered size): a second request for
    /// the same key and size is a memory hit and never calls `load`
    /// again — the class doc's load-at-most-once promise.
    func testThumbnailLoadsOncePerSourceAndSize() throws {
        let cache = DownsampledImageCache()
        let source = try XCTUnwrap(UIImage(data: try jpegData(width: 200, height: 200)))
        var loads = 0

        let first = cache.thumbnail(forKey: "test.source", pointSize: 44,
                                    displayScale: 2) { loads += 1; return source }
        let second = cache.thumbnail(forKey: "test.source", pointSize: 44,
                                     displayScale: 2) { loads += 1; return source }

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(loads, 1, "a cache hit must never call the load closure")
    }
}
