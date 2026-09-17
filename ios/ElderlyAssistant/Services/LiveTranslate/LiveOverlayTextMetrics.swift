import CoreGraphics
import SwiftUI
import UIKit

// C11's text seam (T-020/T-021, FR-LCT-015, NFR-LCT-003) — the design's
// risk R2, removed structurally rather than by discipline.
//
// The risk: the in-place predicate decides "this translation fits the region
// at the minimum point size" by *measuring*, and the view then *draws* it. If
// the two used different fonts — a different weight, a different design — a
// bubble could be declared fitting and then clip its own translation, which
// is the D1 rule silently violated.
//
// The removal: there is exactly **one** place that turns a size into a font
// (`uiFont`), the measurer measures with that font, the view renders with
// `Font(uiFont(...))` of the same call, and the placement carries the
// measurement key (`pointSize` + `weight`) inside the line it measured. The
// view therefore has nothing to choose: it draws the line at the size and
// weight it was measured at, or it does not draw it at all.

/// Which of the overlay's two text roles a line is. A semantic name, not a
/// font weight: the mapping (primary ⇒ bold, secondary ⇒ regular) lives in
/// one place below, and both the measurer and the view read that one place.
///
/// The design's words: the translation is "primary text (≥ 18 pt, bold, high
/// contrast)" and the original recognized text is "smaller secondary text".
enum LiveOverlayTextWeight: Equatable, CaseIterable {
    /// The translation — or, when nothing translated, the recognized text.
    case primary
    /// The supporting line: the original recognized text, or the honest
    /// state indication.
    case secondary
}

/// The feature's one measurer for overlay text.
enum LiveOverlayTextMetrics {

    /// The single font decision for overlay text. Rounded system face, the
    /// same face `DesignTokens.warmFont` names, so an elder reads the overlay
    /// in the app's own voice — and the Devanagari note on `warmFont` applies
    /// unchanged (the system's fallback Devanagari face is used, no tofu).
    static func uiFont(pointSize: CGFloat, weight: LiveOverlayTextWeight) -> UIFont {
        let uiWeight: UIFont.Weight = weight == .primary ? .bold : .regular
        let base = UIFont.systemFont(ofSize: pointSize, weight: uiWeight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    /// The rendering side of the same decision. Built from the `UIFont` the
    /// measurer uses, so the two cannot be given different fonts: there is no
    /// second constructor to call.
    static func font(pointSize: CGFloat, weight: LiveOverlayTextWeight) -> Font {
        Font(uiFont(pointSize: pointSize, weight: weight))
    }

    /// How much room `text` needs when the view draws it at `pointSize` in
    /// `weight`. Deliberately the whole line box (`NSString.size` includes
    /// ascender, descender and leading), not the ink extent: a pill sized to
    /// ink would clip the line it holds.
    ///
    /// The result is rounded **up** to whole points so a fractional advance
    /// can never make a "fitting" translation land a hair outside its region,
    /// and an empty string measures as nothing rather than as a line.
    static func measure(_ text: String,
                        pointSize: CGFloat,
                        weight: LiveOverlayTextWeight) -> CGSize {
        guard !text.isEmpty, pointSize > 0 else { return .zero }
        let size = (text as NSString).size(withAttributes: [
            .font: uiFont(pointSize: pointSize, weight: weight)
        ])
        return CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }
}
