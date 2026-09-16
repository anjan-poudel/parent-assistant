import SwiftUI
import UIKit
import XCTest
@testable import ElderlyAssistant

/// Off-screen rendering probe for the overlay's pixel-level claims (T-020,
/// T-021).
///
/// **Why pixels.** SwiftUI does not vend its `_UIHostingView` accessibility
/// elements to UIKit in a unit-test host, so `accessibilityLabel` set in a
/// view is not readable back from a rendered tree — a test that tried would
/// assert on an empty tree and pass for the wrong reason. `ImageRenderer`
/// draws the same content into a bitmap with no window and no host, so what a
/// test can measure is what the elder can see. The pure surfaces
/// (`RegionPresentation`, `AlwaysShowOriginalSurface`) carry the announcements
/// and are asserted directly; the pixels cover geometry and "did anything
/// draw at all", which the pure values cannot lie about.
///
/// This is the `CameraPermissionSurfaceTests` precedent, extracted so the
/// overlay's suites share one renderer rather than three.
enum OverlayRenderProbe {

    /// What was drawn, in device pixels: the bounding box of every pixel that
    /// is not the background, and how many there are. Comparable as a
    /// *signature* — `count` plus the bounds — which is enough to distinguish
    /// two renderings without comparing megabytes of bytes.
    struct Ink: Equatable {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
        let count: Int

        var isEmpty: Bool { count == 0 }
    }

    /// Renders the overlay at a fixed size over the app's background colour.
    /// `scale = 2` matches a Retina phone, so antialiasing behaves as it does
    /// on device.
    @MainActor
    static func render(_ surface: LiveTranslateOverlaySurface,
                       size: CGSize,
                       scale: CGFloat = 2) -> UIImage? {
        render(LiveTranslateOverlayView(surface: surface,
                                        onTapRegion: { _ in },
                                        onSetAlwaysShowOriginal: { _ in }),
               size: size, scale: scale)
    }

    /// The same rendering for any other surface (T-033's capture control): one
    /// renderer and one ink scan for every pixel-level claim in the feature,
    /// rather than a probe per view.
    @MainActor
    static func render<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2) -> UIImage? {
        let renderer = ImageRenderer(content: view
            .frame(width: size.width, height: size.height)
            .background(DesignTokens.background))
        renderer.scale = scale
        return renderer.uiImage
    }

    /// Every drawn pixel, as a signature. `within` restricts the scan to a
    /// container-space (point) rect, converted to pixels here.
    static func ink(in image: UIImage, within rect: CGRect? = nil) throws -> Ink {
        let pixels = try pixelBytes(of: image)
        let scale = image.scale
        let scan: (minX: Int, minY: Int, maxX: Int, maxY: Int)
        if let rect {
            scan = (Int((rect.minX * scale).rounded(.down)), Int((rect.minY * scale).rounded(.down)),
                    Int((rect.maxX * scale).rounded(.up)), Int((rect.maxY * scale).rounded(.up)))
        } else {
            scan = (0, 0, pixels.width, pixels.height)
        }

        var minX = pixels.width
        var minY = pixels.height
        var maxX = -1
        var maxY = -1
        var count = 0
        for row in max(0, scan.minY)..<min(pixels.height, scan.maxY) {
            for column in max(0, scan.minX)..<min(pixels.width, scan.maxX) {
                let offset = (row * pixels.width + column) * 4
                let red = pixels.bytes[offset]
                let green = pixels.bytes[offset + 1]
                let blue = pixels.bytes[offset + 2]
                let alpha = pixels.bytes[offset + 3]
                // "Ink" is anything the app drew: the card and accent fills
                // are not the white background, and neither is any text.
                guard alpha > 0, red < 250 || green < 250 || blue < 250 else { continue }
                count += 1
                minX = min(minX, column)
                minY = min(minY, row)
                maxX = max(maxX, column)
                maxY = max(maxY, row)
            }
        }
        return Ink(minX: minX, minY: minY, maxX: maxX, maxY: maxY, count: count)
    }

    /// Asserts that everything drawn lies inside `rect` (union with any
    /// `allowed` extras, like the overlay's own chrome strip), within a
    /// one-and-a-half point antialiasing tolerance. Fails loudly when nothing
    /// was drawn at all: an empty rendering must never satisfy a containment
    /// check.
    static func assertInkInside(_ image: UIImage,
                                rect: CGRect,
                                allowed: [CGRect] = [],
                                message: String,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let drawn = try ink(in: image)
        guard !drawn.isEmpty else {
            XCTFail("nothing was drawn: \(message)", file: file, line: line)
            return
        }
        var bounds = rect
        for extra in allowed { bounds = bounds.union(extra) }
        let scale = image.scale
        let tolerance = 1.5 * scale
        XCTAssertGreaterThanOrEqual(CGFloat(drawn.minX), (bounds.minX * scale) - tolerance,
                                    message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(CGFloat(drawn.minY), (bounds.minY * scale) - tolerance,
                                    message, file: file, line: line)
        XCTAssertLessThanOrEqual(CGFloat(drawn.maxX), (bounds.maxX * scale) + tolerance,
                                 message, file: file, line: line)
        XCTAssertLessThanOrEqual(CGFloat(drawn.maxY), (bounds.maxY * scale) + tolerance,
                                 message, file: file, line: line)
    }

    private static func pixelBytes(of image: UIImage) throws -> (bytes: [UInt8], width: Int,
                                                                  height: Int, scale: CGFloat) {
        let cgImage = try XCTUnwrap(image.cgImage, "the rendering has no bitmap")
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height, image.scale)
    }
}
