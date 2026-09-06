import CoreGraphics
import UIKit

/// Crop math for the per-step close-up images (appliance helper step
/// cards). Converts a `NormalizedBox` (0–1 fractions of the photo) into a
/// PADDED crop rectangle in the PIXEL coordinate space of the photo's
/// CGImage — the space `CGImage.cropping(to:)` operates in. Pure function
/// of (box, imagePixelSize), unit-tested directly.
///
/// Pixels vs points: `UIImage.size` is in POINTS, `CGImage` dimensions are
/// in PIXELS (= points × image scale). Callers must pass pixel dimensions
/// (`imagePixelSize(_:)` reads them straight off the CGImage, so this
/// stays right even for non-1x images).
enum ApplianceCropGeometry {

    /// A padded crop plus the box's placement inside it.
    struct Crop: Equatable {
        /// The crop rectangle in source-image pixel coordinates — fully
        /// inside the image, never letterboxed/negative.
        let rect: CGRect
        /// The part of the control's box that is visible in the photo,
        /// re-expressed as a normalized (0–1) rectangle OF THE CROP. When
        /// the box extends past the photo edge the circle must not be
        /// centered on an invisible point, so this is the box ∩ crop
        /// intersection, not the raw box.
        let boxInCrop: CGRect
    }

    /// How much context to keep around the button: crop side ≈ 1.8× the
    /// box side, so the circled button dominates the card.
    static let defaultPaddingFactor: CGFloat = 1.8
    /// Smallest crop side (pixels), so a tiny button still produces a
    /// readable close-up instead of a few-pixel sliver.
    static let defaultMinSidePixels: CGFloat = 180

    /// Builds the padded, image-bounds-clamped crop for `box`.
    /// Returns nil for an unusable box (invalid/zero extent) or a
    /// zero-sized image — the caller falls back to text-only step text.
    static func crop(for box: NormalizedBox,
                     imagePixelSize: CGSize,
                     paddingFactor: CGFloat = ApplianceCropGeometry.defaultPaddingFactor,
                     minSidePixels: CGFloat = ApplianceCropGeometry.defaultMinSidePixels) -> Crop? {
        let imageW = imagePixelSize.width
        let imageH = imagePixelSize.height
        guard imageW > 0, imageH > 0, paddingFactor >= 1, minSidePixels >= 0,
              box.isValid else { return nil }

        let boxRect = CGRect(x: CGFloat(box.xMin) * imageW,
                             y: CGFloat(box.yMin) * imageH,
                             width: CGFloat(box.xMax - box.xMin) * imageW,
                             height: CGFloat(box.yMax - box.yMin) * imageH)
        guard boxRect.width > 0, boxRect.height > 0 else { return nil }

        // Padded target size: ≥ factor× the box, ≥ minSide, never beyond
        // the image itself (a 1024px photo is the prepared size; minSide
        // must not force a crop larger than the whole image).
        let cropWidth = min(max(boxRect.width * paddingFactor, minSidePixels), imageW)
        let cropHeight = min(max(boxRect.height * paddingFactor, minSidePixels), imageH)
        guard cropWidth > 0, cropHeight > 0 else { return nil }

        // Center on the box, then clamp fully inside the image. Clamping
        // can only move the crop inward, so (per the invariants below)
        // the box's on-photo part stays visible.
        let cropRect = CGRect(x: min(max(boxRect.midX - cropWidth / 2, 0), imageW - cropWidth),
                              y: min(max(boxRect.midY - cropHeight / 2, 0), imageH - cropHeight),
                              width: cropWidth, height: cropHeight)

        // box ∩ crop = the control's visible pixels (crop ⊇ box when the
        // box is fully inside the photo; otherwise the in-photo part).
        let visibleBox = boxRect.intersection(cropRect)
        guard visibleBox.width > 0, visibleBox.height > 0 else { return nil }

        let boxInCrop = CGRect(x: (visibleBox.minX - cropRect.minX) / cropRect.width,
                               y: (visibleBox.minY - cropRect.minY) / cropRect.height,
                               width: visibleBox.width / cropRect.width,
                               height: visibleBox.height / cropRect.height)
        return Crop(rect: cropRect, boxInCrop: boxInCrop)
    }

    /// The bitmap's true pixel dimensions — what `cropping(to:)` and this
    /// geometry are expressed in. `UIImage.size` (points) equals this only
    /// when `image.scale == 1`; never derive pixels from `size` directly.
    static func imagePixelSize(_ image: UIImage) -> CGSize? {
        guard let cgImage = image.cgImage else { return nil }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }
}
