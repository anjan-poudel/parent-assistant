import SwiftUI
import UIKit

// C11's elder-facing surface (T-021: FR-LCT-018, NFR-LCT-002, NFR-LCT-003,
// NFR-LCT-004, NFR-LCT-005, NFR-LCT-010).
//
// What this file exists to make true:
//
//  - **The view decides nothing.** Tier attribution, degradation, quarantine
//    and the in-place/callout choice are all facts of the placements it is
//    handed (T-020, T-026). `RegionPresentation` is the pure mapping from a
//    placement to what is drawn and announced, so "a degraded region shows an
//    honest unavailable indication" is a value a test can read rather than a
//    claim about pixels.
//  - **Nothing disappears because a tier failed.** A pending, degraded or
//    quarantined region still has a bubble with its recognized text; the only
//    state without bubbles is "no text was detected", and that state says so
//    in words (NFR-LCT-010).
//  - **The render path never waits.** The view holds no `@State`, starts no
//    task and observes nothing: a frame is a pure function of the surface, so
//    a translation arriving re-renders only the region whose placement
//    changed (NFR-LCT-002).
//  - **Identity-keyed, hence bounded.** One `ForEach` keyed by the region's
//    stable identity, and no array that accumulates across cycles: a long
//    session cannot grow the view tree (NFR-LCT-005).
//  - **Accessibility is structural.** Text is drawn at the size and weight the
//    placement measured it at, through the feature's one font constructor
//    (`LiveOverlayTextMetrics`); colours and the minimum hit target come from
//    `DesignTokens`; each bubble's accessibility label is its translation, and
//    its value is the supporting line (NFR-LCT-003).
//  - **Copy is catalog-only, in the active language.** Every word the elder
//    reads resolves through `L10n` at the surface, never a literal in the
//    view (T-005).

/// What one region looks like and what a screen reader announces for it.
///
/// Pure and `Equatable`: the "each outcome state renders its own
/// presentation" rule lives here, where it can be asserted directly, instead
/// of in the view, where SwiftUI's accessibility tree is not readable from a
/// unit-test host.
struct RegionPresentation: Equatable, Identifiable {

    /// The three per-region states, from `TranslationOutcome` and nothing
    /// else (FR-LCT-018).
    enum State: String, Equatable, CaseIterable {
        case pending, resolved, degraded
    }

    /// The glyph that marks a state which has no translation. An SF Symbol
    /// name is a system identifier, not user-visible copy, so it is a constant
    /// here — and it is always *paired* with the catalog sentence, never shown
    /// alone (the `CloudActivityIndicatorView` precedent). There is no symbol
    /// for `resolved`: a translation is marked by being a translation, not by
    /// a badge.
    static let pendingSymbolName = "ellipsis.circle"
    static let degradedSymbolName = "info.circle"

    let regionID: TextRegionStabilizer.RegionIdentity
    let state: State
    let form: LiveOverlayPlacement.Form
    /// The lines to draw, exactly as the placement measured them.
    let lines: [LiveOverlayTextLine]
    /// The recorded full-screen corner case: the pill was clamped rather than
    /// anchored (OD5, T-030's manual validation item).
    let isClampedFallback: Bool
    /// What a screen reader announces first — the translation for a resolved
    /// region, and the recognized text otherwise. Never a translated-looking
    /// string for a region that was not translated (NFR-LCT-003, FR-LCT-018).
    let accessibilityLabel: String
    /// The supporting line: the original text beside a translation, or the
    /// honest state sentence when there is none.
    let accessibilityValue: String?
    /// Whether there is a translation to speak (C12's tap-to-hear). A bubble
    /// with nothing to say is not a button that does nothing.
    let speaksTranslation: Bool

    var id: TextRegionStabilizer.RegionIdentity { regionID }

    /// The rect the bubble is drawn in: the region itself for the in-place
    /// form, the anchored pill otherwise.
    var frameRect: CGRect {
        switch form {
        case .inPlace(_, let rect): return rect
        case .callout(_, _, let pillRect): return pillRect
        }
    }

    /// The glyph for a state that needs one, or nil for `resolved`.
    var symbolName: String? {
        switch state {
        case .resolved: return nil
        case .pending: return Self.pendingSymbolName
        case .degraded: return Self.degradedSymbolName
        }
    }
}

/// The pure surface behind `LiveTranslateOverlayView`: the placements, the
/// policy they were computed with, and the active language.
///
/// The policy is stored, not re-derived, so the view lays the measured lines
/// out with the very values the placement sized them with — the second half of
/// "the measurement is the render" (the first half is `LiveOverlayTextLine`).
struct LiveTranslateOverlaySurface: Equatable {

    let placements: [LiveOverlayPlacement.PlacedOverlay]
    let policy: LiveOverlayPlacement.Policy
    let locale: Locale

    /// The stroke width of a callout's leader line. A visual constant with no
    /// token of its own; it lives here so it is stated once.
    static let leaderLineWidth: CGFloat = 1.5

    init(placements: [LiveOverlayPlacement.PlacedOverlay],
         policy: LiveOverlayPlacement.Policy,
         locale: Locale) {
        self.placements = placements
        self.policy = policy
        self.locale = locale
    }

    // MARK: Building the policy (the one place config meets tokens)

    /// The placement policy the overlay runs under.
    ///
    /// This is where `LiveTranslateConfig`'s operational parameters meet
    /// `DesignTokens`' accessibility floors, so neither is spelled at a call
    /// site: the primary line is at least the app's body minimum (and at least
    /// the configured `overlayMinPointSize`), the supporting line is at least
    /// the caption minimum, and the supporting line never outgrows the primary
    /// one however those two floors move.
    static func policy(config: LiveTranslateConfig,
                       alwaysShowOriginal: Bool) -> LiveOverlayPlacement.Policy {
        let primary = max(config.overlayMinPointSize, DesignTokens.minBodyPointSize)
        let supporting = min(max(config.overlayMinPointSize, DesignTokens.minCaptionPointSize),
                             primary)
        return LiveOverlayPlacement.Policy(
            maxSourceWordCount: config.inPlaceMaxSourceWordCount,
            minPointSize: primary,
            secondaryPointSize: supporting,
            pillPadding: DesignTokens.interElementSpacing,
            lineSpacing: DesignTokens.interElementSpacing / 2,
            anchorGap: DesignTokens.interElementSpacing,
            alwaysShowOriginal: alwaysShowOriginal)
    }

    // MARK: Copy

    /// The honest state sentence for an outcome that has no translation, in
    /// the active language. `nil` for a resolved outcome.
    ///
    /// Quarantine keeps its own wording: it is a *legal* outcome of the
    /// sanitisation gate, not a failure the elder can fix, and collapsing it
    /// into the unavailable sentence would tell them to retry something that
    /// will be withheld again (T-005's copy rules).
    func stateCopy(for result: TranslationResult) -> String? {
        switch result.outcome {
        case .resolved:
            return nil
        case .pending:
            return L10n.str("livetranslate.state.pending", locale: locale)
        case .degraded(_, let reason):
            return reason == .textQuarantined
                ? L10n.str("livetranslate.state.quarantined", locale: locale)
                : L10n.str("livetranslate.state.unavailable", locale: locale)
        }
    }

    /// The empty state's hint. A calm statement of what is true — no cause, no
    /// instruction to retry, nothing that reads as a failure.
    var emptyHint: String {
        L10n.str("livetranslate.empty.hint", locale: locale)
    }

    // MARK: Presentations

    /// One presentation per placement, in the placement's order (reading
    /// order, top to bottom).
    var presentations: [RegionPresentation] {
        placements.map(presentation(for:))
    }

    func presentation(for placement: LiveOverlayPlacement.PlacedOverlay) -> RegionPresentation {
        let state: RegionPresentation.State
        switch placement.result.outcome {
        case .pending: state = .pending
        case .resolved: state = .resolved
        case .degraded: state = .degraded
        }

        // The bubbles are drawn from the placement's lines — the same strings
        // the placement measured — so the announcement cannot claim a
        // translation the pixels do not show.
        let primary = placement.lines.first?.text ?? placement.result.text
        let supporting = placement.lines.count > 1 ? placement.lines[1].text : nil

        return RegionPresentation(regionID: placement.region.id,
                                  state: state,
                                  form: placement.form,
                                  lines: placement.lines,
                                  isClampedFallback: placement.isClampedFallback,
                                  accessibilityLabel: primary,
                                  accessibilityValue: supporting,
                                  speaksTranslation: placement.result.sourceTier != nil)
    }

    // MARK: Chrome

    /// The strip the overlay's own control lives in, reserved so a callout
    /// does not land under it: the caller passes this to
    /// `LiveOverlayPlacement.place(… occupiedRects: …)`, and the view lays the
    /// control out inside it. Deliberately full width — the reservation is
    /// conservative because the label's intrinsic width is a layout fact this
    /// pure value cannot know.
    static func chromeRects(containerSize: CGSize) -> [CGRect] {
        let height = DesignTokens.minTapTargetSize + 2 * DesignTokens.interElementSpacing
        guard containerSize.width > 0, containerSize.height > height else { return [] }
        return [CGRect(x: 0, y: containerSize.height - height,
                       width: containerSize.width, height: height)]
    }
}

/// The overlay: every region's bubble over the live preview, plus the
/// always-show-original control in the chrome.
///
/// Positioning is absolute in the container's coordinate space — the rects the
/// placement produced are the rects drawn — and the whole view is a pure
/// function of its surface, so nothing here can start a translation, await
/// one, or hold a stale copy of one.
struct LiveTranslateOverlayView: View {

    let surface: LiveTranslateOverlaySurface
    /// Tap-to-hear (C12): speaks this region's translation. Only resolved
    /// bubbles offer it, because only they have something to say.
    let onTapRegion: (TextRegionStabilizer.RegionIdentity) -> Void
    /// The touch path of the FR-LCT-017 preference (T-022): the value the
    /// elder asked for. It writes through `AlwaysShowOriginalBinding` →
    /// `LiveTranslateSettings`, the same setting the voice command writes.
    let onSetAlwaysShowOriginal: (Bool) -> Void

    init(surface: LiveTranslateOverlaySurface,
         onTapRegion: @escaping (TextRegionStabilizer.RegionIdentity) -> Void,
         onSetAlwaysShowOriginal: @escaping (Bool) -> Void) {
        self.surface = surface
        self.onTapRegion = onTapRegion
        self.onSetAlwaysShowOriginal = onSetAlwaysShowOriginal
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            // The leader lines are one layer under every bubble: one `Path`,
            // so a callout cannot draw a second one, and none is drawn for an
            // in-place region (there is nothing to point at).
            Path { path in
                for presentation in surface.presentations {
                    guard case .callout(_, let anchor, let pillRect) = presentation.form else { continue }
                    path.move(to: leaderStart(pillRect: pillRect, anchor: anchor))
                    path.addLine(to: anchor)
                }
            }
            .stroke(DesignTokens.textSecondary, lineWidth: Self.leaderLineWidth)

            ForEach(surface.presentations) { presentation in
                bubble(presentation)
                    .frame(width: presentation.frameRect.width,
                           height: presentation.frameRect.height)
                    .offset(x: presentation.frameRect.minX, y: presentation.frameRect.minY)
                    .accessibilityIdentifier("livetranslate.overlay.region.\(presentation.regionID.rawValue)")
            }

            if surface.presentations.isEmpty {
                emptyState
            }

            AlwaysShowOriginalControl(
                surface: AlwaysShowOriginalSurface(isOn: surface.policy.alwaysShowOriginal,
                                                   locale: surface.locale),
                onSet: onSetAlwaysShowOriginal)
                .padding(DesignTokens.interElementSpacing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .accessibilityIdentifier("livetranslate.overlay")
    }

    // MARK: Bubbles

    /// One region's bubble. The drawn content is exactly the placement's rect;
    /// the hit target is grown to the token's minimum *around* it, so an
    /// elder-sized target never moves the thing it targets.
    @ViewBuilder
    private func bubble(_ presentation: RegionPresentation) -> some View {
        if presentation.speaksTranslation {
            Button {
                onTapRegion(presentation.regionID)
            } label: {
                drawn(presentation)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(presentation.accessibilityLabel))
            .accessibilityValue(Text(presentation.accessibilityValue ?? ""))
        } else {
            drawn(presentation)
                .frame(minWidth: DesignTokens.minTapTargetSize,
                       minHeight: DesignTokens.minTapTargetSize)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(presentation.accessibilityLabel))
                .accessibilityValue(Text(presentation.accessibilityValue ?? ""))
        }
    }

    @ViewBuilder
    private func drawn(_ presentation: RegionPresentation) -> some View {
        switch presentation.form {
        case .inPlace:
            // Sized to the region, and laid out with no inset: the fit
            // condition measured the translation against the whole rect, so a
            // padding here would be a second, smaller box than the one the
            // measurement was made against (risk R2).
            line(presentation.lines.first, colour: DesignTokens.textPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))

        case .callout:
            // Laid out with the *same* policy values the pill was sized with.
            VStack(spacing: surface.policy.lineSpacing) {
                line(presentation.lines.first, colour: DesignTokens.textPrimary)
                if presentation.lines.count > 1 {
                    stateRow(presentation)
                }
            }
            .padding(surface.policy.pillPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
    }

    /// The supporting line: the original text beside a translation, or the
    /// honest state sentence with its glyph.
    @ViewBuilder
    private func stateRow(_ presentation: RegionPresentation) -> some View {
        let supporting = presentation.lines[1]
        HStack(spacing: DesignTokens.interElementSpacing / 2) {
            if let symbol = presentation.symbolName {
                Image(systemName: symbol)
                    .font(LiveOverlayTextMetrics.font(pointSize: supporting.pointSize,
                                                      weight: supporting.weight))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            Text(supporting.text)
                .font(LiveOverlayTextMetrics.font(pointSize: supporting.pointSize,
                                                  weight: supporting.weight))
                .foregroundColor(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func line(_ textLine: LiveOverlayTextLine?, colour: Color) -> some View {
        if let textLine {
            Text(textLine.text)
                .font(LiveOverlayTextMetrics.font(pointSize: textLine.pointSize,
                                                  weight: textLine.weight))
                .foregroundColor(colour)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Empty state

    /// No text is currently detected. Not an error: a calm sentence in a card,
    /// in the elder's language, with the toggle still reachable.
    private var emptyState: some View {
        Text(surface.emptyHint)
            .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize))
            .foregroundColor(DesignTokens.textPrimary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(DesignTokens.interElementSpacing * 2)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
            .padding(DesignTokens.interElementSpacing * 2)
            // The one element not positioned by a rect: centred in the
            // container, where the elder is already looking.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("livetranslate.overlay.empty")
    }

    // MARK: Geometry

    /// Where the leader line leaves the pill: the pill rect's closest point to
    /// the anchor, which is the same relationship the placement fixed between
    /// the pill and its region.
    private func leaderStart(pillRect: CGRect, anchor: CGPoint) -> CGPoint {
        CGPoint(x: min(max(anchor.x, pillRect.minX), pillRect.maxX),
                y: min(max(anchor.y, pillRect.minY), pillRect.maxY))
    }

    private static var leaderLineWidth: CGFloat { LiveTranslateOverlaySurface.leaderLineWidth }
}
