import SwiftUI

// [FOCUS-CAPTURE] The focused read's reading surface (Workstream B).
//
// The elder pointed at one thing and said "read that". What comes back is a
// *picture* of what they pointed at with the reading of it beneath — not the
// live surface with a box drawn on it. That is the whole point of the focus
// path: the live renderer's job is to keep up with a moving camera, and the
// elder who has stopped to point at a label is not moving. Keeping the live
// machinery on screen would give them a snapshot they cannot read: bubbles
// measured for the whole frame, boxes chasing a scene that is no longer there.
//
// So this view is deliberately a *second* surface with its own geometry, and
// it reuses nothing from the live placement pass. What it does reuse is the
// reading card — `LiveTranslateResultsCardView`, the same rows, the same
// tap-to-hear, the same "Translating…" for a string not yet answered — because
// a focused read is still *the feature reading text*, and the feature's
// reading surface should be one surface. Only the geometry above it is this
// view's own:
//
//   ┌─────────────────────────────┐
//   │  ← back to the camera       │  floating, always reachable
//   │                             │
//   │        the crop             │  aspect-fill, clipped to its frame,
//   │      (the evidence)         │  grown per LiveTranslateFocusLayout
//   ├─────────────────────────────┤
//   │  the panel (the answer)     │  ≤ 0.45 of the crop's height, at least
//   │   original → translation    │  one legible row, scrolls if it must
//   └─────────────────────────────┘
//
// The heights come from `LiveTranslateFocusLayout`, which is where the rule
// (≤ 0.45, growth to 1.4×, never below legibility) is written down and tested.
// This file only *draws* what that value says.
//
// The back control is a floating pill rather than a row in the column: it must
// not be one of the things competing for the picture's height, and it must be
// reachable whatever the layout resolved to. It is the *only* exit — the focus
// result is shown in place of the live surface, so without it the elder would
// be looking at a photograph with no way back to the camera.

/// The focused read as a picture to read: the crop, then the panel beneath it.
///
/// A pure function of its capture and its two callbacks — it holds no model and
/// asks nothing of one. The panel's rows are the capture's own
/// (`LiveTranslateResultsCardSurface`), so what is listed here is exactly what
/// was placed on the crop, in the order the placement put it in.
struct LiveTranslateFocusResultView: View {

    /// The packed crop: the picture, the rows and the placement.
    let capture: LiveTranslateFocusedCapture

    /// The language every string this view shows is resolved in.
    let locale: Locale

    /// The three numbers the layout rule is resolved with, from the session's
    /// own config (review finding: the injected config, not the shipped
    /// default). Defaulted to the shipped rule so a preview or a test that has
    /// no session still draws.
    var rule: LiveTranslateFocusLayout.Rule = .shipped

    /// The safe-area insets this surface is drawn inside, reported by the
    /// caller's own `GeometryProxy`.
    ///
    /// Passed in rather than read from a proxy of this view's own: the whole
    /// live surface ignores the safe area (the camera is drawn edge to edge),
    /// so a nested `GeometryReader`'s report is the one thing about the insets
    /// this view cannot be sure of — the caller that *owns* the ignoring is
    /// the reader that knows. The live chrome pads itself by exactly these
    /// (`LiveTranslateView.chrome(in:)`), and the panel here is bottom-anchored
    /// by design, so without them it landed in the home-indicator strip
    /// (review finding 13).
    var safeAreaInsets: EdgeInsets = EdgeInsets()

    /// Tap-to-hear, on the crop's own placements — the row hands back the
    /// region it was built from, exactly as the live card's does.
    let onSpeak: (TextRegionStabilizer.RegionIdentity) -> Void

    /// Back to the camera. The one exit from this surface.
    let onReturnToLive: () -> Void

    /// What the panel's content actually needs, in points, measured from the
    /// content itself rather than estimated.
    ///
    /// This is the one value the layout rule cannot compute on its own: the
    /// rule can bound the panel by the picture and grow the picture to buy it
    /// room, but "does it need the room" depends on how the text wrapped,
    /// which only the laid-out content knows. Starts at zero — the honest
    /// answer before anything has been laid out — and the resolver treats zero
    /// as "needs nothing", which yields the un-grown picture on the first
    /// pass and the real geometry on the second.
    @State private var panelContentHeight: CGFloat = 0

    /// The reading surface's identifier, for the UI tests that pin "the
    /// focused read is a picture above a card, and not the live overlay".
    static let identifier = "livetranslate.focus.result"
    static let imageIdentifier = "livetranslate.focus.image"
    static let backIdentifier = "livetranslate.focus.back"

    /// The exit's copy. A *new* key rather than `common.close`, because this
    /// control does not close the feature — it puts the camera back, which is
    /// a different promise and has to be a different sentence.
    static let backKey = "livetranslate.focus.back"
    static let backSymbolName = "arrow.uturn.backward"

    var body: some View {
        GeometryReader { proxy in
            let insets = safeAreaInsets
            // The space the column may use: the glass, less the home
            // indicator's strip at the bottom and the status bar's at the top
            // (review finding 13).
            let available = Self.availableSize(in: proxy.size, insets: insets)
            let layout = Self.layout(for: available,
                                     capture: capture,
                                     panelContentHeight: panelContentHeight,
                                     rule: rule)
            VStack(spacing: DesignTokens.interElementSpacing) {
                crop(height: layout.imageHeight, width: available.width)
                panel(height: layout.panelHeight,
                      scrolls: layout.panelScrolls)
            }
            // Bottom-anchored: the answer sits at the bottom of the screen
            // with the picture directly above it. When the crop is wide and
            // short there is slack, and the slack belongs at the top — under
            // the back control — rather than as a gap between the two, which
            // would read as the panel belonging to something else.
            .frame(width: available.width, height: available.height, alignment: .bottom)
            .padding(.top, insets.top)
            .padding(.bottom, insets.bottom)
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .overlay(alignment: .topLeading) { backControl }
        }
        .background(DesignTokens.background)
        .accessibilityIdentifier(Self.identifier)
    }

    /// The space the column may use inside a proxy's report: the glass, less
    /// the insets the caller owns.
    ///
    /// Static and pure so the subtraction is assertable on its own — the whole
    /// live surface ignores the safe area (the camera is drawn edge to edge),
    /// and the panel is bottom-anchored by design, so the bottom inset is the
    /// difference between the answer sitting on the home indicator's strip and
    /// sitting above it (review finding 13). Never negative: a proxy that
    /// reports less than its own insets is a view being laid out, not a reason
    /// to hand the rule a negative height to resolve.
    static func availableSize(in size: CGSize, insets: EdgeInsets) -> CGSize {
        CGSize(width: max(0, size.width - insets.leading - insets.trailing),
               height: max(0, size.height - insets.top - insets.bottom))
    }

    /// The rule, with this view's own floor, the column's own gap and the
    /// measured content height folded in. Static and pure so a test can
    /// resolve the same geometry without rendering anything.
    static func layout(for containerSize: CGSize,
                       capture: LiveTranslateFocusedCapture,
                       panelContentHeight: CGFloat,
                       rule: LiveTranslateFocusLayout.Rule = .shipped) -> LiveTranslateFocusLayout {
        LiveTranslateFocusLayout.resolve(containerSize: containerSize,
                                         imageSize: capture.framePixelSize,
                                         panelContentHeight: panelContentHeight,
                                         minimumPanelHeight: minimumPanelHeight,
                                         columnSpacing: DesignTokens.interElementSpacing,
                                         rule: rule)
    }

    /// The floor the picture may not eat into: one row of the panel at the
    /// app's own type floors — the original line's caption size, the
    /// translation's body size, the row's own padding inside the card
    /// (`DesignTokens.interElementSpacing * 4` covers the row's and the card's
    /// padding together).
    ///
    /// Computed, never stored: both type floors are dynamic-type-scaled, so an
    /// elder who has turned text size up gets a taller floor — and with it a
    /// taller panel — without this rule being re-decided anywhere.
    static var minimumPanelHeight: CGFloat {
        DesignTokens.minCaptionPointSize
            + DesignTokens.minBodyPointSize
            + DesignTokens.interElementSpacing * 4
    }

    // MARK: - The picture

    /// The crop, drawn to fill its frame's width and the layout's height.
    ///
    /// `.fill` then `.clipped()`, not `.fit`: the picture is allowed to be
    /// larger than its frame — that is what the layout's growth *is* — and
    /// clipping draws the middle of the crop rather than shrinking it. Nothing
    /// the elder pointed at is lost (the whole rect is in `capture.image`; the
    /// frame is a window onto it), and a picture that shrank to fit would be
    /// the one thing the rule forbids: the evidence becoming unreadable.
    private func crop(height: CGFloat, width: CGFloat) -> some View {
        Image(decorative: capture.image, scale: 1, orientation: .up)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: width, height: max(0, height))
            .clipped()
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(Self.imageIdentifier)
    }

    // MARK: - The answer

    /// The reading card, given exactly the height the rule allowed it.
    ///
    /// The card scrolls on its own (`LiveTranslateResultsCardView` is a
    /// `ScrollView`), so "the panel scrolls" needs nothing from this view
    /// beyond handing it a bounded frame: the rows keep their type floors and
    /// the elder scrolls to the rest. `scrolls` is passed only to say so in
    /// the accessibility value, where a test and a screen reader can both find
    /// it — the drawing is identical either way.
    private func panel(height: CGFloat, scrolls: Bool) -> some View {
        LiveTranslateResultsCardView(
            surface: LiveTranslateResultsCardSurface(rows: capture.rows,
                                                     emptyHint: L10n.str(Self.emptyHintKey,
                                                                         locale: locale)),
            onSpeak: onSpeak,
            onContentHeight: { measured in
                // The measurement round-trip. Guarded against the sub-point
                // churn SwiftUI reports for the same layout so a still hand
                // does not re-resolve the layout frame after frame.
                guard abs(measured - panelContentHeight) > 0.5 else { return }
                panelContentHeight = measured
            })
        .frame(maxWidth: .infinity)
        .frame(height: max(0, height))
        .accessibilityValue(Text(scrolls ? L10n.str(Self.scrollsKey, locale: locale) : ""))
    }

    /// A crop with nothing legible on it says so in the feature's own words —
    /// the same sentence the live surface uses for the same situation, since
    /// one situation deserves one sentence.
    static let emptyHintKey = "livetranslate.empty.hint"

    /// What the panel's accessibility value says when the answer is taller
    /// than the room the picture could buy it: there is more below. The card
    /// scrolls either way; this is how a reader who cannot see the cut edge
    /// knows there is one.
    static let scrollsKey = "livetranslate.focus.scrolls"

    // MARK: - The exit

    /// Back to the camera, as a floating pill over the top-left corner.
    ///
    /// The shipped chrome shape (`LiveTranslateView.closeControl`): the app's
    /// own dynamic-type-aware font, the token's minimum tap target in both
    /// directions, and a card-coloured capsule so it stays findable over
    /// whatever the crop happens to contain.
    private var backControl: some View {
        Button {
            onReturnToLive()
        } label: {
            HStack(spacing: DesignTokens.interElementSpacing) {
                Image(systemName: Self.backSymbolName)
                Text(L10n.str(Self.backKey, locale: locale))
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
        }
        .accessibilityIdentifier(Self.backIdentifier)
        .padding(DesignTokens.interElementSpacing)
    }
}
