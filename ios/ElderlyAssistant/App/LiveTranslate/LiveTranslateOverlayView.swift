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
//  - **A block too tall for its box scrolls, and does not shrink.** A **block**
//    is one panel holding every line at the body floor. When those lines are
//    taller than the box the block could be given, the panel is drawn *bounded*
//    — capped at the policy's fraction of the container, with the same rows at
//    the same floor inside a `ScrollView` — so the elder can read all of it
//    rather than the first line (owner refinement, 2026-09-18). The floor is
//    never traded away for the fit: small type is the failure the floor exists
//    to prevent, and a scroll is not.
//  - **The render path never waits.** The view holds no translation, starts
//    no task and observes nothing: a frame is a function of the surface and of
//    the geometry memory — which holds rects and nothing else — so a
//    translation arriving re-renders only the region whose placement changed
//    (NFR-LCT-002). The memory is the one piece of state the render path owns,
//    it is written only while a frame is being built, and it can neither await
//    a tier nor outlive the model's own publication: an identity that is no
//    longer placed is dropped from it on that same frame.
//  - **Identity-keyed, hence bounded.** One `ForEach`, keyed by the region's
//    normalized *string* rather than by its region id, and no array that
//    accumulates across cycles: a long session cannot grow the view tree
//    (NFR-LCT-005). Keying by string is what stops a moving region from being
//    torn down and rebuilt every pass (owner UX rework, 2026-09-17: "the
//    bubbles are everywhere and shaky"); the geometry then glides, because
//    the view it glides is the same view.
//  - **A box holds still until it has genuinely moved.** `LiveOverlayGeometryMemory`
//    keeps, per view identity, the rect that was last *drawn* for it, and a
//    newly measured rect is adopted only when it differs by more than
//    `overlayGeometryStickiness` of the container. This is the owner's second
//    device verdict answered (2026-09-17, after the first rework shipped:
//    "they still jump around, though not as much as before. Not usable"): the
//    in-place box is derived from the region's rect *and its neighbours'*, so
//    one sign drifting re-measures every box near it, and the detector's own
//    jitter accumulates past the pipeline's publish gate. Holding the drawn
//    rect is what makes a sign that has not changed read as still.
//  - **Dark, opaque, and readable over a photograph.** The in-place box and
//    the callout pill are filled with the app's ink and lettered in the app's
//    background (the secondary line in the brand's light tone), so a
//    translation never sits on a white slab over the picture it is
//    translating. The in-place box hugs its own text — the policy's
//    `inPlacePadding` and `inPlaceCornerRadius`, not the bubble token's — so
//    it reads as the sign's type replaced rather than as a bubble beside it.
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
    /// The normalized string this region's text resolves to — the **view
    /// identity**.
    ///
    /// Keying the drawn list by the string rather than by the region id is
    /// what makes a moving region reuse its view: the stabiliser re-issues
    /// region ids as boxes are re-matched frame to frame, so an id-keyed list
    /// tears down and rebuilds a view on nearly every pass — the flicker and
    /// the jumpiness the owner saw on the live preview. A string-keyed one
    /// keeps the view and `LiveTranslateOverlayView` animates it to its new
    /// rect, so a box *glides* and its text never blinks out.
    let identityKey: String
    /// Disambiguates two on-screen regions carrying the same string — the
    /// declutter pass merges the nearby ones, but two far-apart signs of the
    /// same word stay two regions — so the list's keys stay unique.
    let identityOrdinal: Int
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

    /// The identity the drawn list is keyed by: the normalized string, with an
    /// ordinal only when a second region on screen carries the same string.
    var id: String {
        identityOrdinal == 0 ? identityKey : "\(identityKey)#\(identityOrdinal)"
    }

    /// The rect the bubble is drawn in: the region itself for the in-place
    /// form, the bounded box for a scrollable panel, the anchored pill
    /// otherwise.
    var frameRect: CGRect {
        switch form {
        case .inPlace(_, let rect): return rect
        case .scrollablePanel(_, let rect): return rect
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

    /// The same presentation drawn at a different geometry — everything the
    /// elder reads, hears or taps is carried over unchanged, and only the rect
    /// moves. This is how the geometry memory holds a box still without
    /// touching a single word: what the region *says* is the placement's, and
    /// only where it says it is the memory's (see
    /// `LiveOverlayGeometryMemory`).
    func withForm(_ form: LiveOverlayPlacement.Form) -> RegionPresentation {
        RegionPresentation(regionID: regionID,
                           identityKey: identityKey,
                           identityOrdinal: identityOrdinal,
                           state: state,
                           form: form,
                           lines: lines,
                           isClampedFallback: isClampedFallback,
                           accessibilityLabel: accessibilityLabel,
                           accessibilityValue: accessibilityValue,
                           speaksTranslation: speaksTranslation)
    }
}

/// The geometry one region's form occupies on screen: the whole of what the
/// elder sees move, and nothing else — no text, no outcome, no tier.
///
/// A callout carries its leader line's target as well as its pill, because the
/// anchor is derived from the region's rect and would otherwise jitter under a
/// pill that is holding still, waving a line at a text that has not moved
/// (FR-LCT-016).
enum LiveOverlayFormGeometry: Equatable {
    case inPlace(rect: CGRect)
    case scrollablePanel(rect: CGRect)
    case callout(anchor: CGPoint, pillRect: CGRect)

    init(_ form: LiveOverlayPlacement.Form) {
        switch form {
        case .inPlace(_, let rect):
            self = .inPlace(rect: rect)
        case .scrollablePanel(_, let rect):
            self = .scrollablePanel(rect: rect)
        case .callout(_, let anchor, let pillRect):
            self = .callout(anchor: anchor, pillRect: pillRect)
        }
    }

    /// Which surface the geometry belongs to.
    ///
    /// A form *kind* is never a thing the memory may hold: which form a region
    /// is drawn in is a decision the placement made (the translation fits in
    /// place, the block needed the bounded panel, or the preference wants the
    /// original kept visible), not a position that can be stale. So the memory
    /// compares kinds first and adopts on any change of kind, however near the
    /// two rects happen to be — an in-place box and the pill that would stand
    /// beside it can be a few points apart on a small region, and the two
    /// panels can differ by nothing but the scroll they do or do not have.
    /// Holding one for the other would draw the wrong surface: a scrolled
    /// panel's rows clipped into a plain box has no scroll at all.
    enum Kind: Equatable {
        case box
        case scrollablePanel
        case callout
    }

    /// The rect the elder sees: the box for the in-place form, the bounded box
    /// for a scrollable panel, the pill for a callout — the same rect
    /// `RegionPresentation.frameRect` reports, so the two can never disagree
    /// about what "the box" is.
    var rect: CGRect {
        switch self {
        case .inPlace(let rect): return rect
        case .scrollablePanel(let rect): return rect
        case .callout(_, let pillRect): return pillRect
        }
    }

    /// The anchor, when this is a callout: the point the leader line is drawn
    /// to. Nil for a box, which has no line.
    var anchor: CGPoint? {
        guard case .callout(let anchor, _) = self else { return nil }
        return anchor
    }

    var kind: Kind {
        switch self {
        case .inPlace: return .box
        case .scrollablePanel: return .scrollablePanel
        case .callout: return .callout
        }
    }

    /// How far this geometry differs from `other`, as a fraction of the
    /// container dimension: the largest per-coordinate difference across both
    /// edges of the rect — so a move *and* a resize are the same measure — and,
    /// for callouts, the leader target's own movement.
    ///
    /// A degenerate container has no dimension to be a fraction of, and the
    /// honest answer there is "infinitely far": nothing is held, which is the
    /// behaviour of a caller that has no container to measure against.
    func drift(from other: LiveOverlayFormGeometry, in container: CGSize) -> CGFloat {
        guard container.width > 0, container.height > 0 else { return .infinity }
        let horizontal = abs(rect.minX - other.rect.minX) / container.width
        let vertical = max(abs(rect.minY - other.rect.minY), abs(rect.maxY - other.rect.maxY)) / container.height
        let widest = max(abs(rect.maxX - other.rect.maxX) / container.width,
                         max(abs(rect.width - other.rect.width) / container.width,
                             abs(rect.height - other.rect.height) / container.height))
        var drift = max(max(horizontal, vertical), widest)

        if let anchor, let otherAnchor = other.anchor {
            drift = max(drift,
                        max(abs(anchor.x - otherAnchor.x) / container.width,
                            abs(anchor.y - otherAnchor.y) / container.height))
        }
        return drift
    }

    /// This geometry as the form a region is drawn in.
    func form(for regionID: TextRegionStabilizer.RegionIdentity) -> LiveOverlayPlacement.Form {
        switch self {
        case .inPlace(let rect):
            return .inPlace(regionID: regionID, rect: rect)
        case .scrollablePanel(let rect):
            return .scrollablePanel(regionID: regionID, rect: rect)
        case .callout(let anchor, let pillRect):
            return .callout(regionID: regionID, anchor: anchor, pillRect: pillRect)
        }
    }
}

/// The rects the overlay is **drawing**, per view identity — the memory that
/// makes a box hold still (owner device verdict, 2026-09-17: "they still jump
/// around, though not as much as before. Not usable").
///
/// Why this exists at all: a region whose *string* has not changed can still be
/// handed a different rect, for two reasons neither of which is a move the
/// elder made.
///
///  - The pipeline's publish gate (`LiveTranslateConfig.publishBoxEpsilon`)
///    suppresses a cycle whose boxes all moved by at most 2 % — but only when
///    the *whole* cycle is that quiet, and against the last delivered
///    publication, so a steady creep republishes and one sign crossing the
///    threshold carries every other box's fresh measurement with it.
///  - An in-place box is not a function of its own region alone: it is the
///    region's rect grown into the free space its neighbours leave
///    (`LiveOverlayPlacement.inPlaceMaxBox`), then cut to the text it holds
///    (`inPlaceTightBox`). A sign walking across the frame therefore re-measures
///    the boxes *around* it, and those regions jump without moving.
///
/// So the memory is keyed by the view identity (the normalized string, plus an
/// ordinal where two regions share one) and holds the geometry that was last
/// drawn for that identity. A newly measured geometry is adopted only when its
/// `drift` from the drawn one exceeds `overlayGeometryStickiness` of the
/// container — which is the same rule for a move and for a resize, because
/// both are measured on the rect's own edges — and the comparison is against
/// the rects *on screen*, so a slow drift accumulates until it is one the
/// elder could see and then lands (gliding, through `positionSmoothingSeconds`).
///
/// The one thing this must never do is draw a rect the placement did not ask
/// for: a held geometry is by construction within the threshold of the
/// measured one (or it would have been adopted), and a change of form kind is
/// never held at all. That bound is also why the memory needs no reset of its
/// own: a container that changed under it — a rotation, a new session — hands
/// it rects that differ by far more than the threshold, so the first frame in
/// the new container is drawn from the placement's own geometry, and no frame
/// is ever drawn from a rect that points at nothing.
///
/// A reference type, deliberately: the memory is written while the frame is
/// being built, and a value type would have to be written back through view
/// state — an extra render pass per pass, for a cache that changes nothing the
/// elder reads. Nothing else here is stateful: every entry is a `CGRect` or a
/// point, an identity that is no longer placed is dropped on the frame that
/// drops it (so a long session cannot grow it, NFR-LCT-005), and no text,
/// outcome or tier is ever stored.
final class LiveOverlayGeometryMemory {

    /// The geometry last drawn for each view identity.
    private var drawn: [String: LiveOverlayFormGeometry] = [:]

    /// How many identities the memory is holding. A test reads it to show that
    /// an identity which left the frame is released rather than accumulated.
    var count: Int { drawn.count }

    /// The presentations **as they are drawn**: each one at the geometry the
    /// memory holds for its identity, or at the placement's own geometry when
    /// the drift past the threshold has been adopted.
    ///
    /// This is the view's one call per frame, and it is where adoption happens:
    /// a geometry that has drifted beyond the threshold replaces the held one
    /// here, so the very frame that notices the move is the frame that draws
    /// it — there is no second pass, and no frame is ever drawn from a value
    /// the memory has already discarded.
    func held(_ presentations: [RegionPresentation],
              container: CGSize,
              stickiness: Double) -> [RegionPresentation] {
        var next: [String: LiveOverlayFormGeometry] = [:]
        next.reserveCapacity(presentations.count)
        let limit = CGFloat(stickiness)

        let resolved = presentations.map { presentation -> RegionPresentation in
            let measured = LiveOverlayFormGeometry(presentation.form)
            guard let held = drawn[presentation.id] else {
                // Nothing held: this identity is drawn where the placement put
                // it, and that is now what "still" means for it.
                next[presentation.id] = measured
                return presentation
            }
            // A degenerate container measures every drift as infinite, so
            // nothing is ever held: a caller with no container to measure
            // against gets the placement's own rects, never a frozen frame.
            // A change of form kind is adopted for the same reason, whatever
            // the rects say.
            guard held.kind == measured.kind,
                  held.drift(from: measured, in: container) <= limit else {
                next[presentation.id] = measured
                return presentation
            }
            next[presentation.id] = held
            return presentation.withForm(held.form(for: presentation.regionID))
        }

        drawn = next
        return resolved
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

    /// How long a box takes to move to a new rect, in seconds. A rendering
    /// constant, not an operational one: it exists to absorb what movement is
    /// left after the geometry memory has held everything it can — a move that
    /// is genuinely above the stickiness threshold, and so a move the elder
    /// would follow with their eyes — not to stage an animation the elder has
    /// to wait for. Text stays readable throughout, because the view is not
    /// rebuilt: only its geometry is interpolated.
    ///
    /// Long enough to read as a glide rather than a jump (the owner's device
    /// verdict, 2026-09-17: "they still jump around … Not usable"), and short
    /// enough that a box does not visibly lag the sign it is drawn over: a
    /// third of a second is under the time it takes to bring a phone up and
    /// read the sign again, and well over the frame the detector works at.
    static let positionSmoothingSeconds: TimeInterval = 0.35

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
    ///
    /// The in-place box's own padding, corner radius and the geometry
    /// stickiness are the config's, unchanged: none of the three is an
    /// accessibility floor, and the in-place padding and corner are
    /// deliberately *not* the pill token's — a replacement of the sign's type
    /// is tight and square-cornered where a pill that floats beside the text
    /// is neither.
    static func policy(config: LiveTranslateConfig,
                       alwaysShowOriginal: Bool) -> LiveOverlayPlacement.Policy {
        let primary = max(config.overlayMinPointSize, DesignTokens.minBodyPointSize)
        let supporting = min(max(config.overlayMinPointSize, DesignTokens.minCaptionPointSize),
                             primary)
        return LiveOverlayPlacement.Policy(
            // In-place text may stand below the body floor — it stands where
            // type of roughly that size already stood — but never above it,
            // however the two values move relative to each other.
            inPlaceMinPointSize: min(config.inPlaceMinPointSize, primary),
            inPlaceMaxGrowth: config.inPlaceMaxGrowth,
            inPlacePadding: config.inPlacePadding,
            inPlaceCornerRadius: config.inPlaceCornerRadius,
            panelMaxHeightFraction: config.panelMaxHeightFraction,
            geometryStickiness: config.overlayGeometryStickiness,
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
    /// order, top to bottom), each carrying the view identity it is drawn
    /// under. The ordinal is assigned in that same order, so two regions that
    /// share a string get the same two identities every frame: the list cannot
    /// swap them and make the two views' contents trade places.
    var presentations: [RegionPresentation] {
        var ordinals: [String: Int] = [:]
        return placements.map { placement in
            let key = LiveTranslateTextNormalization.normalized(placement.region.text)
            let ordinal = ordinals[key, default: 0]
            ordinals[key] = ordinal + 1
            return presentation(for: placement, identityKey: key, identityOrdinal: ordinal)
        }
    }

    /// One region's placement as what is drawn and announced. The single-region
    /// call: no ordinal is needed because there is no second region to
    /// disambiguate from.
    func presentation(for placement: LiveOverlayPlacement.PlacedOverlay) -> RegionPresentation {
        presentation(for: placement,
                     identityKey: LiveTranslateTextNormalization.normalized(placement.region.text),
                     identityOrdinal: 0)
    }

    func presentation(for placement: LiveOverlayPlacement.PlacedOverlay,
                      identityKey: String,
                      identityOrdinal: Int) -> RegionPresentation {
        let state: RegionPresentation.State
        switch placement.result.outcome {
        case .pending: state = .pending
        case .resolved: state = .resolved
        case .degraded: state = .degraded
        }

        // The bubbles are drawn from the placement's lines — the same strings
        // the placement measured — so the announcement cannot claim a
        // translation the pixels do not show. A **block** is one panel holding
        // several lines, and its announcement is the whole of it: every primary
        // line in the order the panel draws them, then every supporting line,
        // so the elder hears the same block the panel shows instead of its
        // first row (scene-block rework, 2026-09-18). A single-line region is
        // the same expression with one line in it, and reads exactly as it did.
        let primaryLines = placement.lines.filter { $0.weight == .primary }.map(\.text)
        let supportingLines = placement.lines.filter { $0.weight == .secondary }.map(\.text)
        let primary = primaryLines.isEmpty
            ? placement.result.text
            : primaryLines.joined(separator: " ")
        var supporting = supportingLines.isEmpty
            ? nil
            : supportingLines.joined(separator: " ")
        if supporting == nil, placement.result.sourceTier != nil {
            // An in-place box draws the translation alone — the original is
            // *covered* by design — so the supporting line is not drawn and has
            // no place in `lines`. It is still what a screen reader should hear
            // beside the translation, and it is what the snapshot's results
            // card lists under every row (the card is built from these
            // presentations): so it is the value, and the box's announcement
            // carries both texts. A string identical to the label is not
            // repeated.
            let original = placement.result.originalText
            supporting = original.isEmpty || original == primary ? nil : original
        }

        return RegionPresentation(regionID: placement.region.id,
                                  identityKey: identityKey,
                                  identityOrdinal: identityOrdinal,
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

    /// The rects this view is currently drawing, per region identity — the one
    /// piece of state the render path owns, and the reason a box whose text has
    /// not changed holds still (`LiveOverlayGeometryMemory`). It holds
    /// geometry and nothing else: no translation, no outcome, no tier, so it
    /// cannot keep a stale *word* on screen even in principle.
    @State private var geometry = LiveOverlayGeometryMemory()

    init(surface: LiveTranslateOverlaySurface,
         onTapRegion: @escaping (TextRegionStabilizer.RegionIdentity) -> Void,
         onSetAlwaysShowOriginal: @escaping (Bool) -> Void) {
        self.surface = surface
        self.onTapRegion = onTapRegion
        self.onSetAlwaysShowOriginal = onSetAlwaysShowOriginal
    }

    var body: some View {
        // The container is read, not assumed: the memory measures a drift
        // against the same dimensions the placement measured its rects in, so
        // the threshold means the same fraction of the screen in both places.
        GeometryReader { proxy in
            let presentations = geometry.held(surface.presentations,
                                              container: proxy.size,
                                              stickiness: surface.policy.geometryStickiness)
            ZStack(alignment: .topLeading) {
                Color.clear

                // The leader lines are one layer under every bubble: one
                // `Path`, so a callout cannot draw a second one, and none is
                // drawn for an in-place region (there is nothing to point at).
                // The line follows the *drawn* pill and anchor, so a held pill
                // holds its leader too instead of waving at a rect it has left.
                Path { path in
                    for presentation in presentations {
                        guard case .callout(_, let anchor, let pillRect) = presentation.form
                        else { continue }
                        path.move(to: leaderStart(pillRect: pillRect, anchor: anchor))
                        path.addLine(to: anchor)
                    }
                }
                .stroke(DesignTokens.textSecondary, lineWidth: Self.leaderLineWidth)

                ForEach(presentations) { presentation in
                    bubble(presentation)
                        .frame(width: presentation.frameRect.width,
                               height: presentation.frameRect.height)
                        .offset(x: presentation.frameRect.minX, y: presentation.frameRect.minY)
                        // A box glides to its new rect instead of jumping. The
                        // view is identified by its *string*, so this animates
                        // the geometry of the same view — nothing is rebuilt,
                        // and the text never blinks out between frames
                        // (NFR-LCT-002). The memory has already absorbed every
                        // move below the stickiness threshold; what is left to
                        // glide is a move the elder can see.
                        .animation(.easeOut(duration: LiveTranslateOverlaySurface.positionSmoothingSeconds),
                                   value: presentation.frameRect)
                        .accessibilityIdentifier("livetranslate.overlay.region.\(presentation.regionID.rawValue)")
                }

                if presentations.isEmpty {
                    emptyState
                }

                AlwaysShowOriginalControl(
                    surface: AlwaysShowOriginalSurface(isOn: surface.policy.alwaysShowOriginal,
                                                       locale: surface.locale),
                    onSet: onSetAlwaysShowOriginal)
                    .padding(DesignTokens.interElementSpacing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .accessibilityIdentifier("livetranslate.overlay")
        }
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
            // Laid out with the *same* tight inset the box was sized with: the
            // box is the region's own rect unioned with the measured text
            // block plus this padding (`LiveOverlayPlacement.inPlaceTightBox`),
            // so insetting by it gives the text back exactly the block that was
            // measured — no re-wrap, nothing clipped (risk R2), and no slab of
            // empty ink around a short translation (the owner's device verdict,
            // 2026-09-17: "the bubbles are blue background with white text").
            //
            // The fill is the app's ink and the text is the app's background —
            // an opaque dark box, never a white one: it *replaces* the printed
            // text it covers, and the elder reads it against whatever the
            // camera sees, so the pair has to carry its own contrast (owner UX
            // rework, 2026-09-17). Being a colour *pair* from the token table,
            // it is equally high-contrast in either appearance mode; there is
            // no scheme-dependent branch that could go pale in light mode.
            //
            // The corner is the config's own, not the bubble token's: a radius
            // that hugs a line of type reads as the sign's own lettering
            // replaced, where the pill radius reads as a bubble laid over the
            // picture. The callout below keeps the token's.
            //
            // A **block** is drawn here as one panel: all of the placement's
            // lines, stacked in the order they were measured (owner direction,
            // 2026-09-18 — "bigger but fewer translations"; one surface per
            // object or merged text block, never one bubble per line). A
            // single-line region is the same code with one line in it, so the
            // per-line rendering the feature shipped is unchanged.
            panelRows(presentation)
                .padding(surface.policy.inPlacePadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignTokens.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: surface.policy.inPlaceCornerRadius))

        case .scrollablePanel:
            // The bounded panel (owner refinement, 2026-09-18): the same rows,
            // the same padding, the same fill and corner — inside a `ScrollView`
            // instead of a fixed stack, because the block's lines at the body
            // floor are taller than the box the placement could give them. The
            // box is the placement's (it is capped at a fraction of the
            // container and proved clear of its neighbours), so the scroll is
            // bounded by a rect the elder is already looking at, and every line
            // stays reachable instead of being clipped away or shrunk to fit.
            //
            // The rows are laid out at their natural height — nothing here may
            // compress them to the viewport, which is exactly the illegible
            // small type the floor exists to prevent — and the scroll indicator
            // is left on: a surface with more text under it has to say so.
            ScrollView(.vertical, showsIndicators: true) {
                panelRows(presentation)
                    .frame(maxWidth: .infinity)
            }
            .padding(surface.policy.inPlacePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignTokens.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: surface.policy.inPlaceCornerRadius))

        case .callout:
            // Laid out with the *same* policy values the pill was sized with.
            VStack(spacing: surface.policy.lineSpacing) {
                line(presentation.lines.first, colour: DesignTokens.background)
                if presentation.lines.count > 1 {
                    stateRow(presentation)
                }
            }
            .padding(surface.policy.pillPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignTokens.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
    }

    /// The rows a **panel** draws: every line the placement measured, in the
    /// order it measured them, at the size and weight each one carries — the
    /// translation first, then the original under it where the preference asked
    /// for it.
    ///
    /// One builder for both panel forms, deliberately: the plain panel and the
    /// bounded scrollable one are the *same surface* to the elder, and the only
    /// difference between them is whether the box around these rows scrolls.
    /// Two copies of this stack could drift into two appearances for one block.
    @ViewBuilder
    private func panelRows(_ presentation: RegionPresentation) -> some View {
        VStack(spacing: surface.policy.lineSpacing) {
            ForEach(Array(presentation.lines.enumerated()), id: \.offset) { _, textLine in
                line(textLine,
                     colour: textLine.weight == .secondary
                         ? DesignTokens.brandBlush
                         : DesignTokens.background)
            }
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
                    .foregroundColor(DesignTokens.brandBlush)
            }
            Text(supporting.text)
                .font(LiveOverlayTextMetrics.font(pointSize: supporting.pointSize,
                                                  weight: supporting.weight))
                // The supporting line on a dark pill: the brand's light tone,
                // which clears the fill by a wide margin where the grey
                // secondary ink would not.
                .foregroundColor(DesignTokens.brandBlush)
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
