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

    /// **How many separate things are drawn along one horizontal line** — the
    /// claim a bounding box cannot make: one capsule and two sitting side by
    /// side have the same ink bounds, and only the gap between them tells them
    /// apart.
    ///
    /// The line is in container points (`image.scale` is applied here, as
    /// everywhere else in this probe) and is sampled in `step`-point slices, so
    /// a run is "a stretch of the line with ink on it" rather than "a lit
    /// pixel": antialiasing between two glyphs inside one capsule must not read
    /// as two controls.
    static func inkRunCount(in image: UIImage, atY y: CGFloat,
                            from minX: CGFloat = 0,
                            to maxX: CGFloat? = nil,
                            step: CGFloat = 2) throws -> Int {
        let pixels = try pixelBytes(of: image)
        let scale = image.scale
        let row = Int((y * scale).rounded())
        guard row >= 0, row < pixels.height else {
            throw NSError(domain: "OverlayRenderProbe", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "the line y=\(y) is outside the rendering",
            ])
        }
        let first = max(0, Int((minX * scale).rounded(.down)))
        let last = min(pixels.width, Int(((maxX ?? CGFloat(pixels.width) / scale) * scale).rounded(.up)))
        let slice = max(1, Int((step * scale).rounded()))
        var runs = 0
        var inRun = false
        var column = first
        while column < last {
            var hasInk = false
            for offset in 0..<slice where column + offset < last {
                let index = (row * pixels.width + column + offset) * 4
                let red = pixels.bytes[index]
                let green = pixels.bytes[index + 1]
                let blue = pixels.bytes[index + 2]
                let alpha = pixels.bytes[index + 3]
                if alpha > 0, red < 250 || green < 250 || blue < 250 {
                    hasInk = true
                    break
                }
            }
            if hasInk, !inRun { runs += 1 }
            inRun = hasInk
            column += slice
        }
        return runs
    }

    /// What a region of a rendering looks like, in colour terms: the average
    /// straight-sRGB components of its pixels, and the share of them that are
    /// darker than `darkBelow` in relative luminance.
    ///
    /// The colour half is what the green-highlight suite measures ("the box is
    /// a wash of green", "the wash lets the print through"); the dark half is
    /// the "there is dark type inside it" half of the same claim, which no
    /// average can show — half dark ink and half white paper averages to a
    /// grey that is neither.
    struct Swatch: Equatable {
        let red: Double
        let green: Double
        let blue: Double
        let darkFraction: Double

        var luminance: Double {
            func linear(_ v: Double) -> Double {
                v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// How green the region reads: its green channel less its red one. A
        /// grey or white surface measures ~0; the shipped wash measures well
        /// over 0.1 over white paper.
        var greenCast: Double { green - red }
    }

    /// The swatch of `rect` (container points), composited over whatever the
    /// rendering drew beneath it. `darkBelow` is the luminance under which a
    /// pixel counts as ink — 0.25 is comfortably darker than the app's
    /// `textPrimary` (#0B1F44 is ~0.015) and comfortably lighter than the
    /// green wash over paper (~0.63).
    static func swatch(in image: UIImage, within rect: CGRect,
                       darkBelow: Double = 0.25) throws -> Swatch {
        let pixels = try pixelBytes(of: image)
        let scale = image.scale
        let minX = max(0, Int((rect.minX * scale).rounded(.down)))
        let minY = max(0, Int((rect.minY * scale).rounded(.down)))
        let maxX = min(pixels.width, Int((rect.maxX * scale).rounded(.up)))
        let maxY = min(pixels.height, Int((rect.maxY * scale).rounded(.up)))
        guard maxX > minX, maxY > minY else {
            throw NSError(domain: "OverlayRenderProbe", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "the swatch rect \(rect) is outside the rendering",
            ])
        }

        var red = 0.0, green = 0.0, blue = 0.0
        var dark = 0
        var total = 0
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        for row in minY..<maxY {
            for column in minX..<maxX {
                let offset = (row * pixels.width + column) * 4
                let r = Double(pixels.bytes[offset]) / 255
                let g = Double(pixels.bytes[offset + 1]) / 255
                let b = Double(pixels.bytes[offset + 2]) / 255
                red += r; green += g; blue += b
                total += 1
                if 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) < darkBelow { dark += 1 }
            }
        }
        return Swatch(red: red / Double(total),
                      green: green / Double(total),
                      blue: blue / Double(total),
                      darkFraction: Double(dark) / Double(total))
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
