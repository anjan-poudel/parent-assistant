import SwiftUI

// C10's view — the cloud-activity indicator (T-016, FR-LCT-011).
//
// What this file exists to make true:
//
//  - **Symbol *and* label.** The design forbids an icon alone: a cloud glyph
//    says nothing to an elder who has not learned it. The label is the
//    catalog's plain-language sentence in the active language
//    (NFR-LCT-004), and the glyph carries no information the label does not.
//  - **The view has no way to suppress it.** Its only input is the surface's
//    `isActive`, which comes from `CloudActivityIndicatorModel` and from
//    nowhere else. There is deliberately no `hidden`, no `isEnabled`, no
//    "compact" and no settings input here — the "always show original text"
//    toggle changes the overlay's form and nothing else, so it cannot reach
//    this view even by accident (FR-LCT-011 scenario 3).
//  - **Nothing is drawn when inactive.** The correct display of "no cloud
//    request is in flight" is the absence of the indicator, not a dimmed or
//    greyed version of it.

/// The pure surface behind `CloudActivityIndicatorView`: whether a request is
/// in flight, and the copy to show in the active language.
struct CloudActivityIndicatorSurface: Equatable {

    /// The glyph. An SF Symbol name is a system identifier, not user-visible
    /// copy, so it is a constant here; the words are all in the catalog.
    static let symbolName = "cloud"

    /// The model's current state — the indicator's only input.
    let isActive: Bool
    /// The active language, resolved here rather than through the view
    /// hierarchy, so a Nepali session reads Nepali.
    let locale: Locale

    init(isActive: Bool, locale: Locale) {
        self.isActive = isActive
        self.locale = locale
    }

    /// The plain-language label, from the catalog, in the active language.
    var label: String {
        L10n.str("livetranslate.cloudIndicator.label", locale: locale)
    }
}

/// The elder-facing indicator: a small card with a glyph and a sentence.
struct CloudActivityIndicatorView: View {

    let surface: CloudActivityIndicatorSurface

    var body: some View {
        if surface.isActive {
            HStack(spacing: 8) {
                Image(systemName: CloudActivityIndicatorSurface.symbolName)
                    .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                Text(surface.label)
                    .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(surface.label))
            .accessibilityIdentifier("livetranslate.cloudIndicator")
        }
    }
}
