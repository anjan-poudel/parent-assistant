import CryptoKit
import UIKit

/// Prepares a captured photo for the vision call (design §5.3):
///
///  - **Uniform scale, NEVER crop** — the resize is load-bearing, not
///    cosmetic. Bounding boxes come back normalized to the frame Gemini
///    saw; the overlay renders them against the photo we display. A crop
///    before upload would shift every box on screen. Only a pure uniform
///    scale of the full frame is safe.
///  - Longest edge ≈1024px, JPEG ~0.7 — small enough for upload latency
///    and token cost, large enough that button labels stay legible
///    (design's recommended starting numbers, §11 item 4).
///  - Orientation is normalized into the pixels (a camera UIImage is
///    usually stored rotated with an EXIF flag), and the SAME normalized
///    image is what the view displays — so "the frame Gemini saw" and
///    "the frame on screen" are literally the same pixels.
enum ApplianceImagePreparer {

    static let maxLongEdge: CGFloat = 1024
    static let jpegQuality: CGFloat = 0.7
    /// Longest edge of the DOWNSCALED copy kept in the local cache
    /// (2026-09-06, local-cache-manuals): small enough that 40 entries of
    /// thumbnails stay trivial for on-device storage, uniform-scale of
    /// the same frame so normalized boxes still map. Enough resolution to
    /// re-render the step-card result UI from cache with zero network.
    static let thumbnailLongEdge: CGFloat = 256

    /// The cache/manuals-library copy of a capture: a ~256px uniform
    /// downscale of the ALREADY-prepared image (never a crop — boxes are
    /// normalized to the full frame, so any uniform scale of the same
    /// frame stays box-accurate), JPEG ~0.7.
    static func thumbnailJPEG(of preparedImage: UIImage,
                              maxLongEdge: CGFloat = ApplianceImagePreparer.thumbnailLongEdge,
                              jpegQuality: CGFloat = ApplianceImagePreparer.jpegQuality) -> Data? {
        prepare(preparedImage, maxLongEdge: maxLongEdge, jpegQuality: jpegQuality)?.jpegData
    }

    struct Prepared: Equatable {
        /// The orientation-normalized, uniformly downscaled image —
        /// display THIS, not the original capture.
        let image: UIImage
        /// JPEG bytes actually sent to Gemini (and the hash input).
        let jpegData: Data
        /// SHA-256 hex of `jpegData` — the cache's photo-hash key.
        let photoHash: String

        static func == (lhs: Prepared, rhs: Prepared) -> Bool {
            lhs.jpegData == rhs.jpegData && lhs.photoHash == rhs.photoHash
        }
    }

    /// Uniform-scale (never crop) `image` to at most `maxLongEdge` on its
    /// longest edge, normalize orientation, and encode as JPEG. Returns
    /// nil only when the image has no usable bitmap — callers treat that
    /// as a capture failure, not a "no such appliance".
    static func prepare(_ image: UIImage,
                        maxLongEdge: CGFloat = ApplianceImagePreparer.maxLongEdge,
                        jpegQuality: CGFloat = ApplianceImagePreparer.jpegQuality) -> Prepared? {
        let pixelSize = image.size
        guard pixelSize.width > 0, pixelSize.height > 0,
              image.cgImage != nil || image.ciImage != nil else { return nil }

        let scale = min(1, maxLongEdge / max(pixelSize.width, pixelSize.height))
        let targetSize = CGSize(width: (pixelSize.width * scale).rounded(.down),
                                height: (pixelSize.height * scale).rounded(.down))
        guard targetSize.width > 0, targetSize.height > 0 else { return nil }

        // Drawing (rather than CGImage cropping/scaling) bakes the EXIF
        // orientation into the pixels, so the result is always .up.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // targetSize is already in output pixels
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: jpegQuality) else { return nil }
        return Prepared(image: rendered, jpegData: jpeg, photoHash: sha256Hex(jpeg))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
