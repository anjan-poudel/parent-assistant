import SwiftUI

// T-033 — the freeze-frame control (owner directive; FR-LCT-001's session view,
// NFR-LCT-004, NFR-LCT-011).
//
// What this file exists to make true:
//
//  - **One capture button, and it says which way it goes.** Not frozen it
//    freezes the picture; frozen it returns to the live camera. One control,
//    two labels, so the elder is never asked to know that a second button
//    exists somewhere else.
//  - **Symbol *and* label.** The design forbids an icon alone (T-016's rule,
//    kept here): a pause glyph says nothing to an elder who has not learned
//    it. Both labels are the catalog's, in the active language, at the app's
//    body floor — and the control is at least `DesignTokens.minTapTargetSize`
//    in both directions.
//  - **Chrome, not overlay.** It is drawn by the session view inside the strip
//    the placement reserves (`LiveTranslateView.topChromeRects`), so no callout
//    can land on it — and, being chrome, it is not part of the overlay's
//    `placements` and cannot be dragged into the placement's own arithmetic.
//  - **No session knowledge.** The control is a pure function of its surface.
//    It cannot start a capture, cannot reach the camera and cannot decide
//    whether the picture is frozen: the model does, and hands the answer over.
//  - **Honest availability.** Before the camera is up there is nothing to
//    freeze, so the control is drawn disabled rather than pretending a tap
//    would work (and never hidden mid-session, which would make it appear to
//    vanish when the camera starts). A failed start has T-008's own surface
//    and gets no freeze control at all.

/// The pure surface behind `LiveTranslateSnapshotControl`: whether a frame is
/// held, whether the session can offer the control, and the language its label
/// is resolved in.
struct LiveTranslateSnapshotSurface: Equatable {

    /// The glyph names. SF Symbol names are system identifiers, not
    /// user-visible copy, so they are constants here; the words are all in the
    /// catalog.
    static let captureSymbolName = "pause.circle.fill"
    static let liveSymbolName = "play.circle.fill"

    /// Whether the session is holding a frozen frame.
    let isFrozen: Bool
    /// Whether the session has a camera picture to offer. A failed start
    /// renders T-008's surface and this control is not part of it.
    let isPresented: Bool
    /// Whether a tap would do something right now: the camera is running and a
    /// frame is in hand, or a frame is held and can be released.
    let isEnabled: Bool
    /// The active language, resolved here rather than through the view
    /// hierarchy, so a Nepali session reads Nepali.
    let locale: Locale

    init(isFrozen: Bool, isPresented: Bool, isEnabled: Bool, locale: Locale) {
        self.isFrozen = isFrozen
        self.isPresented = isPresented
        self.isEnabled = isEnabled
        self.locale = locale
    }

    /// The control's label, from the catalog, in the active language: what the
    /// tap will do, not what the current state is.
    var label: String {
        L10n.str(isFrozen ? "livetranslate.snapshot.live" : "livetranslate.snapshot.capture",
                 locale: locale)
    }

    /// The glyph beside the label. A pause for "hold this picture", a play for
    /// "go back to the live one".
    var symbolName: String {
        isFrozen ? Self.liveSymbolName : Self.captureSymbolName
    }
}

/// The elder-facing control: a labelled button in the session view's top strip.
struct LiveTranslateSnapshotControl: View {

    let surface: LiveTranslateSnapshotSurface
    /// One tap, one meaning: the model decides which way the toggle goes, so
    /// the control cannot act on a state it drew a frame ago.
    let onToggle: () -> Void

    /// The accessibility identifier, so the view's own tests and UI tests can
    /// find the control the directive counts ("one capture button").
    static let accessibilityIdentifier = "livetranslate.snapshot.toggle"

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: DesignTokens.interElementSpacing) {
                Image(systemName: surface.symbolName)
                Text(surface.label)
                    .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize,
                                                weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(DesignTokens.textPrimary)
            .padding(.horizontal, DesignTokens.interElementSpacing)
            .frame(minWidth: DesignTokens.minTapTargetSize,
                   minHeight: DesignTokens.minTapTargetSize)
            .background(DesignTokens.card)
            .clipShape(Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!surface.isEnabled)
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }
}
