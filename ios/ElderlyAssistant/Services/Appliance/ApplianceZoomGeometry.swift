import CoreGraphics

/// Pure math for the pinch-to-zoom step close-ups: scale clamping
/// (1×–4×) and pan clamping (the image can only travel so far before its
/// edge meets the panel's). No view code here — directly unit-tested.
enum ApplianceZoomGeometry {

    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 4

    /// Clamps a proposed zoom factor into [minScale, maxScale]. Total over
    /// CGFloat: NaN and infinities collapse to a bound.
    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return maxScale }
        return min(max(scale, minScale), maxScale)
    }

    /// Clamps a pan offset so the scaled content can't be dragged away
    /// from the panel: at zoom `z` the content overhangs by
    /// `(z - 1) × baseSize / 2` on each side, which is exactly how far it
    /// may travel in that axis. Returns .zero when not zoomed (nothing to
    /// pan). Total over CGFloat inputs.
    static func clampedOffset(_ offset: CGSize,
                              zoom: CGFloat,
                              baseSize: CGSize) -> CGSize {
        let clampedZoom = clampedScale(zoom)
        guard clampedZoom > 1, baseSize.width > 0, baseSize.height > 0,
              offset.width.isFinite, offset.height.isFinite else { return .zero }
        let limitX = (clampedZoom - 1) * baseSize.width / 2
        let limitY = (clampedZoom - 1) * baseSize.height / 2
        return CGSize(width: min(max(offset.width, -limitX), limitX),
                      height: min(max(offset.height, -limitY), limitY))
    }
}
