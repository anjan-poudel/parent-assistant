import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// [POINT-TAP-ASK] (2026-09-19) Barcode-reading service for the
/// point-tap-ask pipeline (Phase 2 standalone slice). Wraps Vision's
/// `VNDetectBarcodesRequest` behind a small seam so the pipeline never
/// talks to Vision directly: the crop (Phase 1's `PointAskCrop`) hands
/// this reader a cropped `CGImage`/`CVPixelBuffer`, and the reader hands
/// back the payload string(s) of every barcode found.
///
/// Design: a caseless enum of pure statics (house tool pattern, like
/// `CalculatorTool`). The Vision seam (`detect(in:)`) is deliberately
/// thin — request creation plus one `VNImageRequestHandler.perform` —
/// because `VNBarcodeObservation` cannot be constructed in tests (its
/// `payloadStringValue` is read-only); everything else is the pure
/// `parsedPayloads(_:)` seam, which the unit tests pin with a full
/// parsing matrix.
///
/// Honesty contract:
///  - The reader reports ONLY what Vision detected — a nil/blank payload
///    (a symbology was recognized but no payload decoded) is dropped,
///    never guessed or reconstructed.
///  - Duplicate payloads (the same barcode occupying several scan lines)
///    are collapsed to one entry, first-seen order preserved.
///  - A Vision failure (`handler.perform` throws) reads as "no barcodes",
///    exactly like an image with nothing to detect — the pipeline falls
///    back to its no-scan path, never a fabricated code.
///
/// The food-shape gate (`ProductLookupTool.isFoodBarcode`) is a separate
/// seam: this reader is deliberately shape-agnostic, so a QR payload or a
/// coupon code is still reported and the caller decides whether it may
/// leave the device.
enum PointAskBarcodeReader {

    // MARK: - Pure parsing

    /// Reduces raw Vision payload strings to the clean, unique set the
    /// pipeline uses. Each surviving entry is:
    ///
    ///  - trimmed of surrounding whitespace/newlines (Vision pads some
    ///    symbology payloads, e.g. EAN-13 scans with stray spacing);
    ///  - non-empty (a symbology hit without a decoded payload is not a
    ///    barcode anyone can look up);
    ///  - unique — first occurrence wins, order preserved.
    ///
    /// Pure and total: any input, no Vision dependency, no nil output.
    static func parsedPayloads(_ raw: [String?]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in raw {
            guard let trimmed = entry?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    // MARK: - Vision seam

    /// Runs `VNDetectBarcodesRequest` over a (cropped) image and returns
    /// the parsed payload strings. Synchronous — `VNImageRequestHandler`
    /// performs in-place; the pipeline calls this off the main thread.
    /// Any Vision error returns [] (honest no-detection), never throws.
    static func detect(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return parsedPayloads(request.results?.compactMap { $0.payloadStringValue } ?? [])
    }

    /// The same detection over a `CVPixelBuffer` (the camera path, when
    /// the crop already lives in pixel-buffer form). Same honesty rules.
    static func detect(in buffer: CVPixelBuffer) -> [String] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return parsedPayloads(request.results?.compactMap { $0.payloadStringValue } ?? [])
    }
}
