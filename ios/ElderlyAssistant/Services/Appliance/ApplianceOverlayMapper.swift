import CoreGraphics

/// Coordinate mapping for the appliance overlay (design §5.1). SwiftUI's
/// `.aspectRatio(.fit)` letterboxes the displayed photo inside its
/// container but does not expose the displayed rect — so we compute it
/// here, as a pure function of (containerSize, imageSize), and unit-test
/// it directly (design §10 calls this math out as "exactly the kind of
/// pure, easily-wrong function that should get direct unit tests").
enum ApplianceOverlayMapper {

    /// The rect the photo actually occupies inside `containerSize` when
    /// rendered aspect-fit: uniformly scaled to fit, centered in the
    /// leftover (letterbox) space.
    ///
    /// `imageSize` is `UIImage.size` (points) — SwiftUI lays the `Image`
    /// out from the same value, so both sides of the mapping stay
    /// consistent; normalized boxes are resolution-independent fractions
    /// of the frame, so points-vs-pixels cancels out.
    static func displayedImageRect(containerSize: CGSize, imageSize: CGSize) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }
        let scale = min(containerSize.width / imageSize.width,
                        containerSize.height / imageSize.height)
        let displayedSize = CGSize(width: imageSize.width * scale,
                                   height: imageSize.height * scale)
        let origin = CGPoint(x: (containerSize.width - displayedSize.width) / 2,
                             y: (containerSize.height - displayedSize.height) / 2)
        return CGRect(origin: origin, size: displayedSize)
    }

    /// Maps a normalized (0–1, origin top-left) box CENTER into container
    /// coordinates — the point where the overlay circle is drawn (§5.1).
    static func screenPoint(forBoxCenterNormalized normalized: (x: Double, y: Double),
                            containerSize: CGSize, imageSize: CGSize) -> CGPoint {
        let rect = displayedImageRect(containerSize: containerSize, imageSize: imageSize)
        return CGPoint(x: rect.origin.x + CGFloat(normalized.x) * rect.size.width,
                       y: rect.origin.y + CGFloat(normalized.y) * rect.size.height)
    }

    /// Convenience for a whole control.
    static func screenPoint(for control: GroundedControl,
                            containerSize: CGSize, imageSize: CGSize) -> CGPoint {
        screenPoint(forBoxCenterNormalized: control.normalizedBox.center,
                    containerSize: containerSize, imageSize: imageSize)
    }
}
