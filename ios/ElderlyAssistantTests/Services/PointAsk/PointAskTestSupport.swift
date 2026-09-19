import CoreGraphics
import CoreVideo
import Foundation
@testable import ElderlyAssistant

// Test doubles and fixtures for the point, tap & ask suites. Helper file —
// the `LiveTranslate` suite's convention (LabelTranslationCacheTestStorage,
// LiveTranslateSanitisingBus): every fake here is a scripted double of a
// production seam, never a stand-in for production policy.

// MARK: - Pixel buffers

enum PointAskTestFrames {

    /// A BGRA buffer `width` × `height`, filled pixel by pixel by `fill`
    /// (which receives the pixel's coordinates, top-left origin).
    static func pixelBuffer(width: Int,
                            height: Int,
                            fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &buffer)
        precondition(status == kCVReturnSuccess)
        let created = buffer!
        CVPixelBufferLockBaseAddress(created, [])
        defer { CVPixelBufferUnlockBaseAddress(created, []) }
        let base = CVPixelBufferGetBaseAddress(created)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(created)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let (b, g, r, a) = fill(x, y)
                let offset = y * bytesPerRow + x * 4
                pointer[offset] = b
                pointer[offset + 1] = g
                pointer[offset + 2] = r
                pointer[offset + 3] = a
            }
        }
        return created
    }

    /// A buffer of one solid colour.
    static func solidPixelBuffer(width: Int,
                                 height: Int,
                                 rgba: (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
        pixelBuffer(width: width, height: height) { _, _ in rgba }
    }

    /// The BGRA value at one pixel, top-left origin, or nil when the buffer
    /// cannot be locked.
    static func rgba(atX x: Int, y: Int, in buffer: CVPixelBuffer) -> (UInt8, UInt8, UInt8, UInt8)? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (pointer[offset], pointer[offset + 1], pointer[offset + 2], pointer[offset + 3])
    }
}

// MARK: - Engine doubles

/// A scripted `LiveTextRecognitionEngine`: returns the regions it is given,
/// counts its passes, and can be made to throw or to hang (the pipeline's
/// stage-timeout tests set `delay` past the configured deadline).
final class StubPointAskOCREngine: LiveTextRecognitionEngine {

    var supportsTracking: Bool = false
    var regions: [LiveTextDetector.DetectedTextRegion] = []
    var error: Error?
    /// An artificial sleep before the pass answers, for deadline tests.
    var delay: TimeInterval?
    private(set) var passCount = 0

    func recognizeText(in pixelBuffer: CVPixelBuffer) throws -> [LiveTextDetector.DetectedTextRegion] {
        passCount += 1
        if let delay {
            Thread.sleep(forTimeInterval: delay)
        }
        if let error { throw error }
        return regions
    }

    func followRememberedRectangles(in pixelBuffer: CVPixelBuffer) throws -> [String: NormalizedBox] {
        [:]
    }

    func forgetRememberedRectangles() {}
}

/// A scripted `LiveObjectDetectionEngine`: returns the boxes it is given,
/// counts its passes, and can be made to throw — the resolver's stale-cache
/// tests drive the pass count through it.
final class StubPointAskObjectEngine: LiveObjectDetectionEngine {

    var supportsObjectDetection: Bool = true
    var boxes: [NormalizedBox] = []
    var error: Error?
    private(set) var passCount = 0

    func detectObjects(in pixelBuffer: CVPixelBuffer) throws -> [LiveTextDetector.DetectedSceneObject] {
        passCount += 1
        if let error { throw error }
        return boxes.map { LiveTextDetector.DetectedSceneObject(classLabel: nil,
                                                                normalizedBox: $0,
                                                                confidence: 1) }
    }
}

/// A scripted `PointAskClassificationEngine`.
final class StubPointAskClassifier: PointAskClassificationEngine {

    var supportsClassification: Bool = true
    var result: PointAskClassification?
    var error: Error?
    /// An artificial sleep before the pass answers, for deadline tests.
    var delay: TimeInterval?
    private(set) var passCount = 0

    func classify(_ crop: CVPixelBuffer) throws -> PointAskClassification? {
        passCount += 1
        if let delay {
            Thread.sleep(forTimeInterval: delay)
        }
        if let error { throw error }
        return result
    }
}

/// A scripted `PointAskMaskProbing`: the opt-in path's fake, and the reason
/// the resolver takes the protocol rather than the concrete engine.
final class StubPointAskMaskEngine: PointAskMaskProbing {

    var supportsMasks: Bool = true
    var contains: Bool = true
    var error: Error?
    private(set) var passCount = 0

    func maskContains(_ point: CGPoint, in pixelBuffer: CVPixelBuffer) throws -> Bool {
        passCount += 1
        if let error { throw error }
        return contains
    }
}

// MARK: - Convenience

enum PointAskBoxes {
    /// The left half of the frame.
    static let leftHalf = NormalizedBox(xMin: 0, yMin: 0, xMax: 0.5, yMax: 1)
    /// The right half of the frame.
    static let rightHalf = NormalizedBox(xMin: 0.5, yMin: 0, xMax: 1, yMax: 1)
}
