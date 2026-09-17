import SwiftUI

// The FR-LCT-017 preference's touch entry point (T-022: FR-LCT-017,
// NFR-LCT-004, NFR-LCT-012, OD2). C14 owns the value; this file owns the
// control, its label, and the one writer both paths go through.
//
// What this file exists to make true:
//
//  - **One setting, two paths.** The touch control and the `set-show-original`
//    voice command (T-023) both write `LiveTranslateSettings.alwaysShowOriginal`
//    — one key, one setter — so the two cannot disagree. `AlwaysShowOriginalBinding`
//    is that single writer; a caller that needs the voice path takes it from
//    here rather than reaching into `UserDefaults`.
//  - **A display preference, never a privacy control.** It is drawn in the
//    overlay's own chrome, deliberately away from the consent surface and the
//    cloud indicator, because grouping it with either would imply it changes
//    what leaves the device. It cannot: withdrawing consent stops every send
//    in both states (T-015), and the indicator ignores it (T-016).
//  - **The label is the catalog's, in the active language.** Nepali first,
//    like every other elder-facing string (T-005).
//  - **An elder-sized target.** The control is at least
//    `DesignTokens.minTapTargetSize` in both directions and reports its state
//    to a screen reader with the selected trait, so "on" is not carried by
//    colour alone.

/// The pure surface behind `AlwaysShowOriginalControl`: the preference's
/// current value and the language its label is resolved in.
struct AlwaysShowOriginalSurface: Equatable {

    /// The glyph. An SF Symbol name is a system identifier, not user-visible
    /// copy, so it is a constant here; the words are all in the catalog.
    static let symbolName = "eye"

    let isOn: Bool
    let locale: Locale

    init(isOn: Bool, locale: Locale) {
        self.isOn = isOn
        self.locale = locale
    }

    /// The control's label, from the catalog, in the active language.
    var label: String {
        L10n.str("livetranslate.toggle.showOriginal", locale: locale)
    }
}

/// The elder-facing control: a labelled button that shows its state without
/// relying on colour alone.
struct AlwaysShowOriginalControl: View {

    let surface: AlwaysShowOriginalSurface
    /// The value the elder is asking for — an explicit set, not a flip, so the
    /// write says what the tap meant even if the surface it was drawn from is
    /// a frame old.
    let onSet: (Bool) -> Void

    var body: some View {
        Button {
            onSet(!surface.isOn)
        } label: {
            HStack(spacing: DesignTokens.interElementSpacing / 2) {
                Image(systemName: AlwaysShowOriginalSurface.symbolName)
                    .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize,
                                                weight: .semibold))
                Text(surface.label)
                    .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize,
                                                weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Both states are token colours: the on-state's label is the app
            // background (the token, not a bare `.white`), so nothing here
            // introduces a second place a colour is spelled.
            .foregroundColor(surface.isOn ? DesignTokens.background : DesignTokens.textPrimary)
            .padding(.horizontal, DesignTokens.interElementSpacing * 2)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .frame(maxWidth: .infinity)
            .background(surface.isOn ? DesignTokens.accent : DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The state reaches a screen reader as a trait, not as colour.
        .accessibilityAddTraits(surface.isOn ? [.isSelected] : [])
        .accessibilityIdentifier("livetranslate.toggle.showOriginal")
    }
}

/// The one writer for the preference: what the touch control calls, and what
/// the voice command calls (T-023). It holds `LiveTranslateSettings` — the
/// same value the overlay reads — so a write here is visible to the very next
/// rendered frame, with no cached copy in between.
struct AlwaysShowOriginalBinding: Equatable {

    private let settings: LiveTranslateSettings

    init(settings: LiveTranslateSettings) {
        self.settings = settings
    }

    /// The preference as the overlay will read it on its next frame.
    var isOn: Bool { settings.alwaysShowOriginal }

    /// The touch control's path: an explicit value.
    func set(_ value: Bool) {
        settings.setAlwaysShowOriginal(value)
    }

    /// The voice command's path (`set-show-original`, T-023): same setter,
    /// same key.
    func toggle() {
        settings.toggleAlwaysShowOriginal()
    }

    /// What the control draws right now, in the given language.
    func surface(locale: Locale) -> AlwaysShowOriginalSurface {
        AlwaysShowOriginalSurface(isOn: settings.alwaysShowOriginal, locale: locale)
    }
}
