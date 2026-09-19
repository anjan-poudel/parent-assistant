import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The crop stage (design §1 item 6, research §Q6 stage 2):
//
//  - **Crop-only egress.** Whatever the pipeline sends, it is the tapped
//    box — never the frame, never anything outside it. The crop is a
//    *copy* into a buffer of the box's own size, so the cropped buffer's
//    validity never depends on the frame's lifetime (the same guarantee
//    `CameraFrame.cropped(to:)` documents for its copy).
//  - **≤768 px JPEG re-encode.** The upload is a fresh JPEG at
//    `maxUploadSide` on the long side, encoded from the crop's pixels with
//    **no metadata** — the `CGImageDestination` is handed empty properties,
//    so nothing (EXIF, GPS, device, timestamp) is carried. The crop of a
//    pixel buffer carries no metadata to begin with; the encode is where
//    that fact is made structural rather than accidental.
//  - **The local passes keep the full-res crop.** OCR and classification
//    read the raw cropped buffer — downscaling is *only* for the upload,
//    and the two sizes never mix.

enum PointAskCrop {

    /// Crops `pixelBuffer` to `pixelRect` — pixel coordinates, top-left
    /// origin — into a new buffer of the rect's own size. Returns nil for
    /// a rect that is empty, degenerate or outside the frame: the crop
    /// stage refuses rather than inventing pixels past the frame's edge.
    ///
    /// Implemented as a DIRECT row copy, not through Core Image: the CI
    /// render path double-mirrored the origin (CIImage-from-pixelBuffer
    /// is top-left in practice, so the compensating flip returned the
    /// mirror quadrant on device-grade tests), and the copy cannot get
    /// origins wrong — destination row 0 IS source row 0. No colour
    /// conversion either, so the crop's bytes are the frame's bytes.
    static func cropped(_ pixelBuffer: CVPixelBuffer, pixelRect: CGRect) -> CVPixelBuffer? {
        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard frameWidth > 0, frameHeight > 0 else { return nil }
        // Refuse BEFORE clamping: a degenerate request is not a crop, even
        // when the clamp would rescue a sliver of it.
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        let frameRect = CGRect(x: 0, y: 0, width: CGFloat(frameWidth), height: CGFloat(frameHeight))
        let clamped = pixelRect.intersection(frameRect).integral
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }

        let x = Int(clamped.minX)
        let y = Int(clamped.minY)
        let width = Int(clamped.width)
        let height = Int(clamped.height)

        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &output) == kCVReturnSuccess,
              let output else { return nil }

        let srcLock = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let dstLock = CVPixelBufferLockBaseAddress(output, [])
        guard srcLock == kCVReturnSuccess, dstLock == kCVReturnSuccess else {
            if srcLock == kCVReturnSuccess { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            if dstLock == kCVReturnSuccess { CVPixelBufferUnlockBaseAddress(output, []) }
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(output, [])
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let dstBase = CVPixelBufferGetBaseAddress(output) else { return nil }
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(output)
        let src = srcBase.assumingMemoryBound(to: UInt8.self)
        let dst = dstBase.assumingMemoryBound(to: UInt8.self)
        let rowBytes = width * 4
        for row in 0..<height {
            let srcOffset = (y + row) * srcBytesPerRow + x * 4
            let dstOffset = row * dstBytesPerRow
            memcpy(dst + dstOffset, src + srcOffset, rowBytes)
        }
        return output
    }

    /// The cloud upload: the crop re-encoded as a JPEG whose long side is
    /// at most `maxSide` pixels, with no EXIF or any other metadata. The
    /// one path a crop takes out of the device (research §Q6 stage 2:
    /// <15 ms; the re-encode is the cost of the privacy guarantee).
    static func jpegUploadData(from crop: CVPixelBuffer, maxSide: Int) -> Data? {
        guard let image = downscaledCGImage(from: crop, maxSide: maxSide) else { return nil }
        return Self.jpegData(of: image)
    }

    /// A `CGImage` of the crop, no larger than `maxSide` on the long side.
    /// Same-size when the crop is already within the bound — no pointless
    /// resampling.
    static func downscaledCGImage(from crop: CVPixelBuffer, maxSide: Int) -> CGImage? {
        let width = CVPixelBufferGetWidth(crop)
        let height = CVPixelBufferGetHeight(crop)
        guard width > 0, height > 0, maxSide > 0 else { return nil }
        let context = Self.context
        var image = CIImage(cvPixelBuffer: crop)
        let longSide = max(width, height)
        if longSide > maxSide {
            let scale = CGFloat(maxSide) / CGFloat(longSide)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return context.createCGImage(image, from: image.extent)
    }

    /// JPEG encoding with empty properties — the structural "no EXIF"
    /// half of the upload guarantee. `nil` when the encoder cannot write
    /// the pixels at all; the caller treats that as a crop failure, never
    /// as a reason to send anything else.
    ///
    /// The bytes come back from the MUTABLE DATA the destination wrote
    /// into — the previous version cast the destination itself, which is
    /// a CGImageDestination, never an NSMutableData, so every upload
    /// path returned nil (device-test catch 2026-09-19).
    static func jpegData(of image: CGImage, quality: CGFloat = 0.8) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        // ImageIO embeds an APP1 (EXIF) segment even with empty metadata —
        // strip EVERY APPn/COM segment so the upload is pixels only. The
        // walk keeps SOI, the structural segments (DQT/DHT/SOF/SOS) and
        // the entropy data, and rebuilds the byte stream without APPn.
        return strippedOfAppSegments(data as Data)
    }

    /// Rebuilds a JPEG without its APPn (FFE0–FFEF) and COM (FFFE)
    /// segments — the structural "no EXIF / no XMP / no ICC" guarantee,
    /// made byte-level rather than relying on encoder flags (ImageIO
    /// appends an APP1 regardless of the empty metadata dictionary).
    /// Returns the input unchanged when it is not recognizably a JPEG,
    /// so a future encoder change can never turn this into a data-loss
    /// path.
    static func strippedOfAppSegments(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return data }
        var out: [UInt8] = [0xFF, 0xD8]
        var index = 2
        var inEntropy = false
        while index < bytes.count - 1 {
            if inEntropy {
                out.append(bytes[index])
                index += 1
                continue
            }
            guard bytes[index] == 0xFF else {
                out.append(bytes[index])
                index += 1
                continue
            }
            let marker = bytes[index + 1]
            if marker == 0xD9 {
                out.append(0xFF); out.append(0xD9)
                break
            }
            guard index + 4 <= bytes.count else { return data }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let segmentLength = 2 + length
            if (0xE0...0xEF).contains(marker) || marker == 0xFE {
                index += segmentLength
                continue
            }
            if marker == 0xDA {
                inEntropy = true
            }
            if index + segmentLength <= bytes.count {
                out.append(contentsOf: bytes[index ..< index + segmentLength])
                index += segmentLength
            } else {
                out.append(contentsOf: bytes[index...])
                break
            }
        }
        return Data(out)
    }

    /// One context for the whole stage — renderers are expensive, and the
    /// downscale pass is a per-tap cost, not a per-frame one.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])
}
