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
    /// Whether a tap on this bubble **asks for its translation** (extract mode,
    /// owner verdict 2026-09-18) rather than speaking one.
    ///
    /// Extract mode shows the recognized text and translates nothing until it
    /// is asked, so the tap that was tap-to-hear in the translated view is
    /// tap-to-translate here: the region the elder points at is the region the
    /// tier work runs for, and no other. A *resolved* region offers
    /// `speaksTranslation` instead — it has already been asked, and the useful
    /// thing to do with an answer is hear it.
    ///
    /// It is a fact of the placement and the policy, not a decision the view
    /// makes, exactly as `speaksTranslation` is: `false` (the default) is the
    /// translated view's behaviour, so every caller before this rework is
    /// unchanged.
    var translatesOnTap: Bool = false

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
                           speaksTranslation: speaksTranslation,
                           translatesOnTap: translatesOnTap)
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

    /// Whether every coordinate this geometry draws with is a real number.
    ///
    /// The placement's own guards mean it never hands in a rect that is not, but
    /// a degenerate container can, and a NaN cannot be glided: a blend of one is
    /// still a NaN, and the renderer drops such a box without saying so.
    var isFinite: Bool {
        switch self {
        case .inPlace(let rect), .scrollablePanel(let rect):
            return rect.minX.isFinite && rect.minY.isFinite
                && rect.width.isFinite && rect.height.isFinite
        case .callout(let anchor, let pillRect):
            return anchor.x.isFinite && anchor.y.isFinite
                && pillRect.minX.isFinite && pillRect.minY.isFinite
                && pillRect.width.isFinite && pillRect.height.isFinite
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

    /// This geometry with each coordinate moved `factor` of the remaining
    /// distance toward `target` — one step of an exponential moving average,
    /// and the reason a box that has decided to move *travels* instead of
    /// landing (owner spec, 2026-09-18: "the rendered box glides toward each
    /// new measured rect with an EMA … slow drift follows continuously instead
    /// of stepping in threshold jumps").
    ///
    /// Per coordinate — origin and size, not per edge — so the two rects are
    /// blended the way a camera dissolves one framing into another: the box
    /// keeps its own proportions' momentum and there is no frame in which the
    /// near edge has arrived while the far one has not. Interpolating edges
    /// instead would draw a rect whose width is a blend of two widths and whose
    /// origin is a blend of two origins anyway; the two agree only for a pure
    /// translation, and the per-coordinate form is the one that is symmetric
    /// under x/y.
    ///
    /// A callout glides its pill *and* its leader target together: the two are
    /// one geometry, and a pill that arrived while the line still pointed at
    /// where the text used to be would be the very jitter FR-LCT-016 forbids.
    ///
    /// `factor` is clamped: `0` returns this geometry unchanged (the box is
    /// frozen), `1` returns the target outright (the pre-rework snap). A
    /// non-finite geometry — a rect the placement never produces, but which a
    /// degenerate container can hand in — is never glided and never blended: the
    /// drawable end of the glide is what is drawn (the target in the ordinary
    /// case, this geometry when the target is the broken one). A change of form
    /// kind is not a move to glide through either: the two surfaces have nothing
    /// to interpolate (a pill and a panel), so the target is returned and the
    /// caller's snap rule and this one agree by construction.
    func stepped(toward target: LiveOverlayFormGeometry, factor: CGFloat) -> LiveOverlayFormGeometry {
        guard kind == target.kind else { return target }
        guard isFinite else { return target.isFinite ? target : self }
        guard target.isFinite else { return self }
        let t = min(max(factor, 0), 1)
        guard t > 0 else { return self }
        guard t < 1 else { return target }

        func glide(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
            from + (to - from) * t
        }
        func glide(_ from: CGRect, _ to: CGRect) -> CGRect {
            CGRect(x: glide(from.minX, to.minX), y: glide(from.minY, to.minY),
                   width: glide(from.width, to.width), height: glide(from.height, to.height))
        }

        switch (self, target) {
        case let (.inPlace(from), .inPlace(to)):
            return .inPlace(rect: glide(from, to))
        case let (.scrollablePanel(from), .scrollablePanel(to)):
            return .scrollablePanel(rect: glide(from, to))
        case let (.callout(fromAnchor, fromPill), .callout(toAnchor, toPill)):
            return .callout(anchor: CGPoint(x: glide(fromAnchor.x, toAnchor.x),
                                            y: glide(fromAnchor.y, toAnchor.y)),
                            pillRect: glide(fromPill, toPill))
        default:
            return target
        }
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
/// ordinal where two regions share one) and holds, for each identity, **two**
/// geometries:
///
///  - the **target** — the last rect the placement asked for and the memory
///    agreed to move to. A newly measured rect replaces the target only when
///    its `drift` from the current target exceeds `overlayGeometryStickiness`
///    of the container, which is the same rule for a move and for a resize
///    because both are measured on the rect's own edges. This is the threshold
///    half of the stabilization and it is unchanged by the EMA rework: jitter
///    below the threshold does not move the target at all.
///  - the **rendered** — the rect actually on screen, which every frame takes
///    one EMA step (`stepped(toward:factor:)`, `overlayBoxLerpFactor`) toward
///    the target. This is the second half (owner spec, 2026-09-18): "the
///    rendered box glides toward each new measured rect with an EMA … slow
///    drift follows continuously instead of stepping in threshold jumps".
///
/// Two states rather than one is the whole design. Keeping only "the drawn
/// rect" and holding it until the next threshold crossing would leave a box
/// that has been asked to move *stuck* mid-flight — the threshold is a
/// distance, so a glide that stops part of the way is still a permanent offset
/// from the text — and keeping only "the last measurement" would put the
/// threshold inside the EMA, where sub-threshold jitter would still creep.
/// With both, sub-threshold jitter is absorbed twice: it never becomes a
/// target, and any target it does become is approached over several frames
/// rather than landed on.
///
/// **Snaps** (no glide at all, whatever the rects say): the first sight of an
/// identity, a change of form kind, and a degenerate container. The first two
/// are the owner's own rule — "EMA resets on identity change (new block =
/// snap, no glide-in from far away)" — and the third is the honest answer of a
/// caller with no container to measure against: every drift is infinite there,
/// so nothing is held and the placement's own rects are drawn, unfrozen.
///
/// The one thing this must never do is draw a rect the placement did not ask
/// for: a rendered rect is always on the segment between the previous rendered
/// rect and a target the placement produced, both of which are inside the
/// ceiling the placement proved clear of its neighbours, and a change of form
/// kind is never glided through at all. That bound is also why the memory
/// needs no reset of its own: a container that changed under it — a rotation,
/// a new session — hands it rects that differ by far more than the threshold,
/// so the target jumps and the glide starts from the old rect toward a rect in
/// the new container, and no frame is ever drawn from a rect that points at
/// nothing.
///
/// A reference type, deliberately: the memory is written while the frame is
/// being built, and a value type would have to be written back through view
/// state — an extra render pass per pass, for a cache that changes nothing the
/// elder reads. Nothing else here is stateful: every entry is a pair of
/// `CGRect`s, a point, or an enum tag, an identity that is no longer placed is
/// dropped on the frame that drops it (so a long session cannot grow it,
/// NFR-LCT-005), and no text, outcome or tier is ever stored.
final class LiveOverlayGeometryMemory {

    /// What the memory knows about one view identity: where it is drawn, and
    /// where the placement last asked it to be.
    private struct Entry {
        var rendered: LiveOverlayFormGeometry
        var target: LiveOverlayFormGeometry
    }

    private var entries: [String: Entry] = [:]

    /// How many identities the memory is holding. A test reads it to show that
    /// an identity which left the frame is released rather than accumulated.
    var count: Int { entries.count }

    /// The presentations **as they are drawn**: each one at the geometry the
    /// memory has glided to for its identity, or at the placement's own
    /// geometry where the rule above says snap.
    ///
    /// This is the view's one call per frame, and it is where target adoption,
    /// the glide and the snap all happen — so the very frame that notices a
    /// move is the frame that starts drawing it, there is no second pass, and
    /// no frame is ever drawn from a value the memory has already discarded.
    ///
    /// `lerp` is `LiveTranslateConfig.overlayBoxLerpFactor`: the share of the
    /// remaining distance the box covers per frame (`0` freezes it, `1` snaps
    /// it, `0.3` is the shipped glide).
    func held(_ presentations: [RegionPresentation],
              container: CGSize,
              stickiness: Double,
              lerp: Double) -> [RegionPresentation] {
        var next: [String: Entry] = [:]
        next.reserveCapacity(presentations.count)
        let limit = CGFloat(stickiness)
        let factor = CGFloat(lerp)

        let resolved = presentations.map { presentation -> RegionPresentation in
            let measured = LiveOverlayFormGeometry(presentation.form)
            // A container with no dimension to be a fraction of measures every
            // drift as infinite; nothing is held or glided there, and the
            // placement's own rect is drawn on this frame whatever the memory
            // remembers (a frozen frame is worse than a jump).
            guard container.width > 0, container.height > 0,
                  let entry = entries[presentation.id],
                  entry.rendered.kind == measured.kind,
                  entry.target.kind == measured.kind else {
                next[presentation.id] = Entry(rendered: measured, target: measured)
                return presentation
            }
            // The threshold: a measurement the placement already asked for
            // (within the stickiness of the target) leaves the target alone,
            // and the box keeps gliding to where it was already going.
            let target = measured.drift(from: entry.target, in: container) > limit
                ? measured
                : entry.target
            let rendered = entry.rendered.stepped(toward: target, factor: factor)
            next[presentation.id] = Entry(rendered: rendered, target: target)
            return presentation.withForm(rendered.form(for: presentation.regionID))
        }

        entries = next
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

    /// The fill every highlight box is drawn with: the token table's green,
    /// washed at the configured opacity — the one place the two meet, so the
    /// view (and the callers that render it off-screen) never assembles a
    /// colour at a call site, and a device check can change how heavy the wash
    /// is without touching the token table.
    ///
    /// The ink drawn *inside* it is `DesignTokens.textPrimary`, the app's
    /// darkest type colour, for the reason stated at the in-place branch: dark
    /// on green is what the owner asked to see, and it clears the wash by
    /// roughly 10:1 where the old pair (white on navy) could only be read by
    /// covering the sign up.
    var highlightFill: Color {
        DesignTokens.overlayHighlight.opacity(policy.highlightOpacity)
    }

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
    ///
    /// The green highlight's own three values ride through the same way
    /// (`overlayHighlightOpacity`, `overlayHighlightPadding`,
    /// `overlayBoxLerpFactor`), for the same reason: they are the owner's
    /// tuning knobs for the look they asked for, not accessibility floors. The
    /// padding is the placement's (it is what the detected region is grown by
    /// before the wash is drawn over it), the opacity is the view's (it is the
    /// wash itself), and the lerp factor is the geometry memory's (it is how
    /// fast a box travels) — one policy value each, so no call site picks one
    /// of them out of the config behind the others' backs.
    static func policy(config: LiveTranslateConfig,
                       alwaysShowOriginal: Bool,
                       extractionMode: Bool = false) -> LiveOverlayPlacement.Policy {
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
            highlightPadding: config.overlayHighlightPadding,
            highlightOpacity: config.overlayHighlightOpacity,
            boxLerpFactor: config.overlayBoxLerpFactor,
            panelMaxHeightFraction: config.panelMaxHeightFraction,
            geometryStickiness: config.overlayGeometryStickiness,
            minPointSize: primary,
            secondaryPointSize: supporting,
            pillPadding: DesignTokens.interElementSpacing,
            lineSpacing: DesignTokens.interElementSpacing / 2,
            anchorGap: DesignTokens.interElementSpacing,
            alwaysShowOriginal: alwaysShowOriginal,
            // Extract mode is a display mode of this overlay, not a second
            // placement: the boxes, the floors and the never-cover law are the
            // same, and the flag only tells the placement which of the two
            // things the elder is looking at (the text, or its translation) is
            // the normal case.
            extractionMode: extractionMode)
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
                                  speaksTranslation: placement.result.sourceTier != nil,
                                  translatesOnTap: translatesOnTap(placement))
    }

    /// Whether this region's bubble is the extract-mode tap-to-translate
    /// target: the mode is on, the region carries text, and no tier has
    /// answered for it yet.
    ///
    /// A tapped region leaves the set the moment its tier answers
    /// (`sourceTier != nil`), so the same bubble that was an invitation to
    /// translate becomes the bubble that speaks the translation — one control,
    /// one meaning at a time, and no second tap target appearing beside it.
    /// A region with no recognized text has nothing to ask about, so it is not
    /// made a button that would translate nothing.
    private func translatesOnTap(_ placement: LiveOverlayPlacement.PlacedOverlay) -> Bool {
        policy.extractionMode
            && placement.result.sourceTier == nil
            && !LiveTranslateTextNormalization.normalized(placement.result.originalText).isEmpty
    }

    // MARK: Chrome

    /// The strip the overlay's own controls live in, reserved so a callout
    /// does not land under them: the caller passes this to
    /// `LiveOverlayPlacement.place(… occupiedRects: …)`, and the view lays the
    /// controls out inside it. Deliberately full width — the reservation is
    /// conservative because the label's intrinsic width is a layout fact this
    /// pure value cannot know.
    ///
    /// **Two rows, not one** (extract mode, owner verdict 2026-09-18): the
    /// strip holds the mode toggle (extract ⇄ translated) *and* the
    /// always-show-original preference, one above the other, and a reservation
    /// that names the same height the controls are drawn at is what keeps a
    /// callout from landing under the lower one. Reserved whether or not the
    /// controls are drawn (a frame can be held, the mode can change), because a
    /// strip that appeared and disappeared with a mode would be a strip the
    /// placement was told about at a different moment than the one it drew in.
    static let chromeControlRows = 2

    static func chromeRects(containerSize: CGSize) -> [CGRect] {
        let height = CGFloat(chromeControlRows) * DesignTokens.minTapTargetSize
            + CGFloat(chromeControlRows + 1) * DesignTokens.interElementSpacing
        guard containerSize.width > 0, containerSize.height > height else { return [] }
        return [CGRect(x: 0, y: containerSize.height - height,
                       width: containerSize.width, height: height)]
    }
}

/// The extract-mode toggle's pure surface: which of the two views of the scene
/// is on, and the language its label is resolved in.
///
/// One control, two states, and the state is the **mode** — not a second
/// preference beside the always-show-original one. Off is the extract mode the
/// feature opens in (the recognized text, standing where the text stood, and
/// no tier work until a block is tapped); on is the translated view the feature
/// had before this rework (every visible region translated continuously).
struct TranslateAllSurface: Equatable {

    /// The glyph. An SF Symbol name is a system identifier, not user-visible
    /// copy, so it is a constant here; the words are all in the catalog.
    static let symbolName = "translate"

    /// True when the translated view is on — i.e. the elder has asked for
    /// everything on screen to be translated, not just the block they tapped.
    let isTranslatingOn: Bool
    let locale: Locale

    init(isTranslatingOn: Bool, locale: Locale) {
        self.isTranslatingOn = isTranslatingOn
        self.locale = locale
    }

    /// The control's label, from the catalog, in the active language.
    ///
    /// The shipped `feeds.translate` entry ("Translate" / "अनुवाद गर्नुहोस्")
    /// rather than a second copy of the same word — the same reuse the close
    /// control already makes of `common.close`, and for the same reason: one
    /// word for one action, already translated and already reviewed.
    var label: String {
        L10n.str("feeds.translate", locale: locale)
    }
}

/// The elder-facing mode control: a labelled button that shows which view is on
/// without relying on colour alone, at an elder-sized target, in the overlay's
/// own chrome (deliberately away from the consent surface and the cloud
/// indicator: which view is on screen changes nothing about what leaves the
/// device).
struct TranslateAllControl: View {

    let surface: TranslateAllSurface
    /// The value the elder is asking for — an explicit set, not a flip, so the
    /// write says what the tap meant even if the surface it was drawn from is
    /// a frame old.
    let onSet: (Bool) -> Void

    var body: some View {
        Button {
            onSet(!surface.isTranslatingOn)
        } label: {
            HStack(spacing: DesignTokens.interElementSpacing / 2) {
                Image(systemName: TranslateAllSurface.symbolName)
                    .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize,
                                                weight: .semibold))
                Text(surface.label)
                    .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize,
                                                weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Both states are token colours, exactly as the preference
            // control's are: the on-state's label is the app background (the
            // token, not a bare `.white`), so nothing here introduces a second
            // place a colour is spelled.
            .foregroundColor(surface.isTranslatingOn ? DesignTokens.background : DesignTokens.textPrimary)
            .padding(.horizontal, DesignTokens.interElementSpacing * 2)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .frame(maxWidth: .infinity)
            .background(surface.isTranslatingOn ? DesignTokens.accent : DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The state reaches a screen reader as a trait, not as colour.
        .accessibilityAddTraits(surface.isTranslatingOn ? [.isSelected] : [])
        .accessibilityIdentifier("livetranslate.toggle.translateAll")
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
    /// Extract mode's per-region request: the elder tapped a block and asked
    /// for *that* block's translation, and for no other region's. The session
    /// runs the tiers for the one region and publishes its answer into the same
    /// placement the bubble is already drawn from.
    let onTranslateRegion: (TextRegionStabilizer.RegionIdentity) -> Void
    /// The mode toggle's touch path: true ⇒ the translated view (every visible
    /// region translated continuously), false ⇒ extract mode.
    let onSetTranslateAll: (Bool) -> Void
    /// [POINT-ASK] The tap box + "What is this?" chip (design:
    /// docs/superpowers/specs/2026-09-19-point-tap-ask-design.md). Nil when
    /// the host session has no point-ask wiring — the overlay then draws
    /// exactly what it always drew.
    let pointAsk: PointAskOverlaySurface?
    /// [POINT-ASK] The window the picture is drawn through — the same
    /// presentation the host computes, so the tap box's normalized frame
    /// box lands on the picture where the elder tapped it, under the same
    /// zoom, pan and stabilization as every other box on screen.
    let presentation: LiveCameraPresentation
    /// [POINT-ASK] The chip's tap: the elder's "what is this?". Only the
    /// anchored chip offers it.
    let onPointAskChipTap: () -> Void
    /// [POINT-ASK] The anchored box's *other* action (Workstream B): read this
    /// crop and translate it. The host routes it to the focused read, and the
    /// default draws only the chip the overlay has always drawn — correct for
    /// every construction site that predates the focused read, and for the
    /// render probe, which passes no point-ask surface at all.
    let onPointAskTranslateTap: () -> Void

    /// The safe area's bottom inset, in points, reported by the host's own
    /// `GeometryProxy` (review finding 7).
    ///
    /// The action row hangs under the anchor and is bottom-clamped; the clamp
    /// needs the glass's *usable* floor, and the host is the reader that has
    /// it — the live surface ignores the safe area, so a proxy read here is
    /// the one thing about the insets this view cannot be sure of. Zero for
    /// every construction site that predates the row.
    let safeAreaBottomInset: CGFloat

    /// The rects this view is currently drawing, per region identity — the one
    /// piece of state the render path owns, and the reason a box whose text has
    /// not changed holds still (`LiveOverlayGeometryMemory`). It holds
    /// geometry and nothing else: no translation, no outcome, no tier, so it
    /// cannot keep a stale *word* on screen even in principle.
    @State private var geometry = LiveOverlayGeometryMemory()

    init(surface: LiveTranslateOverlaySurface,
         onTapRegion: @escaping (TextRegionStabilizer.RegionIdentity) -> Void,
         onSetAlwaysShowOriginal: @escaping (Bool) -> Void,
         onTranslateRegion: @escaping (TextRegionStabilizer.RegionIdentity) -> Void = { _ in },
         onSetTranslateAll: @escaping (Bool) -> Void = { _ in },
         pointAsk: PointAskOverlaySurface? = nil,
         presentation: LiveCameraPresentation =
            LiveCameraPresentation(crop: .whole, pictureRect: .zero),
         onPointAskChipTap: @escaping () -> Void = {},
         onPointAskTranslateTap: @escaping () -> Void = {},
         safeAreaBottomInset: CGFloat = 0) {
        self.surface = surface
        self.onTapRegion = onTapRegion
        self.onSetAlwaysShowOriginal = onSetAlwaysShowOriginal
        self.onTranslateRegion = onTranslateRegion
        self.onSetTranslateAll = onSetTranslateAll
        self.pointAsk = pointAsk
        self.presentation = presentation
        self.onPointAskChipTap = onPointAskChipTap
        self.onPointAskTranslateTap = onPointAskTranslateTap
        self.safeAreaBottomInset = safeAreaBottomInset
    }

    var body: some View {
        // The container is read, not assumed: the memory measures a drift
        // against the same dimensions the placement measured its rects in, so
        // the threshold means the same fraction of the screen in both places.
        GeometryReader { proxy in
            let presentations = geometry.held(surface.presentations,
                                              container: proxy.size,
                                              stickiness: surface.policy.geometryStickiness,
                                              lerp: surface.policy.boxLerpFactor)
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
                        // move below the stickiness threshold, and it has taken
                        // its own EMA step toward whatever is left (see
                        // `LiveOverlayGeometryMemory`); this curve is the
                        // *within-a-step* smoothing, so the box does not land on
                        // each new rect in a visible tick before the next one
                        // arrives.
                        .animation(.easeOut(duration: LiveTranslateOverlaySurface.positionSmoothingSeconds),
                                   value: presentation.frameRect)
                        .accessibilityIdentifier("livetranslate.overlay.region.\(presentation.regionID.rawValue)")
                }

                // [POINT-ASK] The tap box + chip, drawn above the region
                // bubbles: it is the elder's *pointer* — the thing they
                // tapped — and the regions are the scene's text. One box
                // at a time (the surface carries at most one).
                if let pointAsk {
                    PointAskOverlayBoxView(
                        surface: pointAsk,
                        presentation: self.presentation,
                        onChipTap: onPointAskChipTap,
                        // The row's own clamp needs the glass, and the glass is
                        // this reader's (`proxy`), not the box's: the box is
                        // mapped through the presentation and knows only the
                        // rect it came from (Workstream B).
                        containerSize: proxy.size,
                        bottomInset: safeAreaBottomInset,
                        translateLabel: L10n.str(PointAskOverlayBoxView.translateKey,
                                                 locale: surface.locale),
                        onTranslateTap: onPointAskTranslateTap)
                }

                if presentations.isEmpty {
                    emptyState
                }

                // The chrome strip: the mode toggle over the preference, both
                // full width, both elder-sized — the two-storey layout the
                // strip's own reservation names (`chromeRects`).
                VStack(spacing: DesignTokens.interElementSpacing) {
                    TranslateAllControl(
                        surface: TranslateAllSurface(
                            isTranslatingOn: !surface.policy.extractionMode,
                            locale: surface.locale),
                        onSet: onSetTranslateAll)
                    AlwaysShowOriginalControl(
                        surface: AlwaysShowOriginalSurface(isOn: surface.policy.alwaysShowOriginal,
                                                           locale: surface.locale),
                        onSet: onSetAlwaysShowOriginal)
                }
                .padding(DesignTokens.interElementSpacing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
        if presentation.translatesOnTap {
            // Extract mode: the bubble is the invitation to translate *this*
            // region. One tap is one region's tier work — the session is told
            // which region, and translates that one.
            Button {
                onTranslateRegion(presentation.regionID)
            } label: {
                drawn(presentation)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(presentation.accessibilityLabel))
            .accessibilityValue(Text(presentation.accessibilityValue ?? ""))
        } else if presentation.speaksTranslation {
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
            // The fill is the owner's transparent green wash over the print,
            // and the text inside it is the app's darkest ink (owner spec,
            // 2026-09-18: "the whole idea was to overlay the extracted OCR text
            // over the text in the picture, then translate once OCR is solid …
            // the bounding box can be TRANSPARENT GREEN with DARK COLORED
            // TEXT"). It replaces the opaque navy-and-white box of 2026-09-17,
            // which the same owner had already rejected on the device ("the
            // bubbles are blue background with white text") for the reason this
            // fixes: an opaque box *buries* the sign it is drawn over, so the
            // elder cannot check the translation against the print — and when
            // the box is held or gliding, they cannot even tell which words it
            // is about. The wash lets the original read through at
            // `overlayHighlightOpacity` (about two fifths), which is heavy
            // enough to see the highlight at arm's length and light enough that
            // the printed text under it is still legible.
            //
            // Dark ink on that wash rather than white on navy: #0B1F44 over
            // #34A853 at 40 % on paper measures ~10.5:1, and even where the
            // camera sees something dark the wash is over the *print* — the
            // pairing was chosen for the surface it is actually drawn on, not
            // for the worst pixel the sensor could hand it.
            //
            // The corner is the config's own, not the bubble token's: a radius
            // that hugs a line of type reads as the sign's own lettering
            // highlighted, where the pill radius reads as a bubble laid over
            // the picture. The callout below keeps the token's.
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
                .background(surface.highlightFill)
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
            .background(surface.highlightFill)
            .clipShape(RoundedRectangle(cornerRadius: surface.policy.inPlaceCornerRadius))

        case .callout:
            // The one surface that keeps its opaque ink (green-overlay rework,
            // 2026-09-18). Every other form is drawn *over the text it is about*
            // — the print under the wash is the thing the elder is comparing
            // against, which is why it may show through. A callout is the form
            // the placement falls back to when the region has nowhere to draw a
            // box at all: it floats beside the text, over whatever part of the
            // picture happens to be there, with a leader line pointing home.
            // Nothing is underneath it to read, and a green wash over an
            // unknown patch of photograph is exactly where dark type loses its
            // contrast — so the pill carries its own background, as it did
            // before the rework, and the leader line stays the secondary ink.
            //
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
    ///
    /// **One ink for both weights** (green-overlay rework, 2026-09-18). The old
    /// pair said which line was which by colour — white for the translation,
    /// pale pink for the original — because it was drawn on an opaque navy box.
    /// On the green wash there is no such pair to be had: the pink is invisible,
    /// and every lower-contrast grey in the token table (the secondary ink at
    /// #6B7280 measures ~3.1:1 on this wash) drops the original line under the
    /// 4.5:1 floor this feature holds itself to. So the two lines are
    /// distinguished the way the type scale already distinguishes them — the
    /// translation is the bold line at the body floor, the original the regular
    /// line at the caption floor, under it — which is also the difference that
    /// survives for an elder who cannot see colour at all.
    @ViewBuilder
    private func panelRows(_ presentation: RegionPresentation) -> some View {
        VStack(spacing: surface.policy.lineSpacing) {
            ForEach(Array(presentation.lines.enumerated()), id: \.offset) { _, textLine in
                line(textLine, colour: DesignTokens.textPrimary)
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

// MARK: - Point, tap & ask (the tap box + chip)

/// The point-ask overlay's drawn half: the anchored box, the "What is
/// this?" chip under it, and the answer card once the analysis has
/// answered (design: docs/superpowers/specs/2026-09-19-point-tap-ask-design.md
/// §4 — box + chip <100 ms after the tap, one box at a time).
///
/// A pure function of its surface, like everything else the overlay draws:
/// the box's normalized frame rect is mapped through the same camera
/// presentation as every region bubble, so the box sits on the thing the
/// elder tapped under the same zoom, pan and stabilization; the chip's
/// words come from the catalog in the active language (`pointask.chip.label`).
/// No state, no task, no decision — the surface's `state` is the whole of
/// what changes.
struct PointAskOverlayBoxView: View {

    let surface: PointAskOverlaySurface
    let presentation: LiveCameraPresentation
    let onChipTap: () -> Void
    /// The container the box is mapped into, for the action row's own clamp
    /// (Workstream B): the row is wider than the box it hangs under, so placing
    /// it needs the whole glass rather than just the anchor.
    let containerSize: CGSize
    /// The safe area's bottom inset, in points: the floor the action row may
    /// not go under (review finding 7). The caller reports it; zero is the
    /// honest default for a surface with no glass to speak of.
    var bottomInset: CGFloat = 0
    /// The anchor's **first** action's copy (Workstream B, "translate here"):
    /// read this crop and translate it. Resolved text rather than a key,
    /// because the caller is the view that knows the active language — the
    /// same rule `surface.chipLabel` follows.
    let translateLabel: String
    /// The anchor's first action, performed. The host routes it to the same
    /// `translateFocusedRegion` the spoken "translate here" calls, so the finger
    /// and the words cannot come to mean two different things.
    let onTranslateTap: () -> Void

    /// [BOX-ALIGNMENT] (2026-09-20) The box maps LIVE through the same
    /// `presentation.containerRect` the region bubbles use — the exact
    /// mapping that already aligns with the scene. An earlier "stability"
    /// pin held the rect from the FIRST presentation (pre-layout), which
    /// locked a wrong-geometry rect on screen — the "doesn't align with
    /// the object" device report. Correct alignment beats static
    /// placement; the brief settle motion while the crop stabilises is
    /// the honest trade.
    static let pendingSymbolName = "ellipsis.circle"

    var body: some View {
        guard let box = surface.box, presentation.isUsable else { return AnyView(EmptyView()) }
        let boxRect = presentation.containerRect(ofFrameBox: box)
        let chipRect = chipRect(below: boxRect)
        return AnyView(
            ZStack(alignment: .topLeading) {
                // The box: the elder's pointer. A stroke, not a fill — the
                // picture under it is the thing they tapped, and a wash
                // over it would hide it (the green overlay's own lesson:
                // an opaque cover is the failure, not the style).
                RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius)
                    .stroke(DesignTokens.accent,
                            style: StrokeStyle(lineWidth: Self.boxLineWidth))
                    .frame(width: boxRect.width, height: boxRect.height)
                    .offset(x: boxRect.minX, y: boxRect.minY)
                    .animation(.easeOut(duration: LiveTranslateOverlaySurface.positionSmoothingSeconds),
                               value: boxRect)
                    .accessibilityIdentifier("pointask.box")

                switch surface.state {
                case .box:
                    actionRow(below: boxRect)
                case .analyzing:
                    pendingChip(chipRect: chipRect)
                case .answered:
                    answerCard(below: boxRect)
                case .idle:
                    EmptyView()
                }
            }
        )
    }

    /// The two actions an anchored box offers (Workstream B).
    ///
    /// Until the focused read existed this surface offered one: the chip, which
    /// asks the object question. An anchored box is now also the *target* of a
    /// translation — the elder pointed at a sign, and "read that" is as
    /// reasonable a question as "what is that" — so both are drawn, side by
    /// side, at the anchor. Neither is hidden behind a mode: a mode is a thing
    /// the elder has to remember, and the two questions are equally likely at
    /// the moment they point.
    ///
    /// **The row is wider than the box it belongs to**, which is why it is not
    /// simply offset to the box's leading edge the way the single chip was: an
    /// elder who anchored something near the right edge would push the second
    /// button off the glass. It is given the container's own width (less the
    /// edge inset) and aligned to whichever side of the glass the anchor is on —
    /// a position that needs no measurement, cannot overflow, and keeps both
    /// actions on the side of the thing they act on. Copy wraps inside its
    /// button if it must, rather than being truncated: an elder who cannot read
    /// half a label has been given a button they cannot use.
    private func actionRow(below boxRect: CGRect) -> some View {
        HStack(spacing: DesignTokens.interElementSpacing) {
            actionButton(label: translateLabel,
                         identifier: Self.translateIdentifier,
                         action: onTranslateTap)
            actionButton(label: surface.chipLabel,
                         identifier: Self.chipIdentifier,
                         action: onChipTap)
        }
        .frame(width: actionRowWidth,
               alignment: boxRect.midX < containerSize.width / 2 ? .leading : .trailing)
        .offset(x: DesignTokens.interElementSpacing,
                y: Self.actionRowOriginY(below: boxRect,
                                         containerHeight: containerSize.height,
                                         bottomInset: bottomInset,
                                         rowHeight: Self.actionRowHeight,
                                         spacing: DesignTokens.interElementSpacing))
    }

    /// One action row is one tap target tall at the app's floor. The button's
    /// own `minHeight` is what draws it; this is the same number, named so the
    /// clamp below can do arithmetic with it.
    static let actionRowHeight: CGFloat = DesignTokens.minTapTargetSize

    /// Where the row's top edge goes: under the anchor when the glass has room
    /// for it, and **above** the anchor when it has not (review finding 7).
    ///
    /// The offset this replaced read
    /// `min(boxRect.maxY + spacing, boxRect.maxY)` — which is `boxRect.maxY`
    /// for every input, a clamp that clamped nothing. An anchor near the
    /// bottom of the glass therefore put both actions flush against the screen
    /// edge and, under the home indicator's strip, half off the usable glass;
    /// a two-line label ran off it entirely. The row is clamped to the safe
    /// area's floor (`containerHeight - bottomInset`) — the same floor the
    /// live chrome reserves for itself — and flipped above the anchor rather
    /// than slid up over it: a row that slid would cover the very thing it
    /// acts on. When neither side has room (a glass shorter than two rows and
    /// an anchor) the row takes the top of the glass, which is the honest
    /// last resort — on screen beats perfectly placed.
    static func actionRowOriginY(below boxRect: CGRect,
                                 containerHeight: CGFloat,
                                 bottomInset: CGFloat,
                                 rowHeight: CGFloat,
                                 spacing: CGFloat) -> CGFloat {
        let floor = max(0, containerHeight - max(0, bottomInset))
        let below = boxRect.maxY + spacing
        if below + rowHeight <= floor { return below }
        return max(0, boxRect.minY - spacing - rowHeight)
    }

    /// The width the row may occupy: the glass, less one edge inset on each
    /// side. A container that has not been laid out yields zero, which draws an
    /// empty row rather than one laid out against a size nobody has measured.
    private var actionRowWidth: CGFloat {
        max(0, containerSize.width - 2 * DesignTokens.interElementSpacing)
    }

    /// One action: a real button at the app's minimum tap target, in the active
    /// language, on the card surface — the chip's own drawing, kept for both.
    private func actionButton(label: String,
                              identifier: String,
                              action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(label)
                .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize,
                                            weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DesignTokens.interElementSpacing * 2)
                .frame(minHeight: DesignTokens.minTapTargetSize)
        }
        .buttonStyle(.plain)
        .background(DesignTokens.card)
        .clipShape(Capsule())
        .accessibilityIdentifier(identifier)
    }

    /// The two actions' identifiers: the object question keeps the shipped
    /// `pointask.chip` (the UI tests and the pending chip's own identifier are
    /// built around it), and the new translation sits beside it as
    /// `pointask.chip.translate`.
    static let chipIdentifier = "pointask.chip"
    static let translateIdentifier = "pointask.chip.translate"

    /// The translation action's copy — the feature's own key for "translate
    /// here" (`livetranslate.command.translateHere`'s touch half), resolved in
    /// the active language by the caller that knows it.
    static let translateKey = "livetranslate.focus.translate"

    /// The chip while the analysis runs: the same surface, with the
    /// pending glyph instead of the words — the analysis is in flight,
    /// not awaiting an answer the chip could ask for.
    private func pendingChip(chipRect: CGRect) -> some View {
        Image(systemName: Self.pendingSymbolName)
            .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize,
                                        weight: .semibold))
            .foregroundColor(DesignTokens.textPrimary)
            .padding(.horizontal, DesignTokens.interElementSpacing * 2)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .background(DesignTokens.card)
            .clipShape(Capsule())
            .frame(width: chipRect.width, height: chipRect.height)
            .offset(x: chipRect.minX, y: chipRect.minY)
            .accessibilityIdentifier("pointask.chip.pending")
    }

    /// The answer card: the composed lines, in the active language, under
    /// the box they answer for. Fills as soon as the analysis lands — the
    /// spoken answer is first, the card is the reading surface.
    private func answerCard(below anchorRect: CGRect) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.interElementSpacing / 2) {
            ForEach(Array(surface.cardLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignTokens.interElementSpacing * 2)
        .frame(maxWidth: DesignTokens.minTapTargetSize * 6, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .offset(x: min(max(anchorRect.minX, DesignTokens.interElementSpacing),
                       anchorRect.minX),
                y: anchorRect.maxY + DesignTokens.interElementSpacing)
        .accessibilityIdentifier("pointask.answer.card")
    }

    /// Where the chip sits: under the box, at the box's own leading edge,
    /// clamped into the container so a box near the bottom cannot push
    /// the chip off the glass. Wide enough for the elder's tap target in
    /// either language.
    ///
    /// The clamp is `actionRowOriginY`'s, and deliberately the same one
    /// (review finding 7): the leading-edge clamp below is honest — the chip is
    /// the box's own width, so it cannot start past the box — but the vertical
    /// one was `min(boxRect.maxY + spacing, boxRect.maxY)`, which is
    /// `boxRect.maxY` for every input. A box near the floor therefore put the
    /// pending chip in the home-indicator strip. It flips above the box on the
    /// same rule the action row does, so the two never disagree about where
    /// "under the anchor" stops being possible.
    private func chipRect(below boxRect: CGRect) -> CGRect {
        let chipWidth = boxRect.width + 2 * DesignTokens.interElementSpacing
        let chipHeight = DesignTokens.minTapTargetSize + 2 * DesignTokens.interElementSpacing
        return CGRect(x: min(max(boxRect.minX, DesignTokens.interElementSpacing),
                             boxRect.minX),
                      y: Self.actionRowOriginY(below: boxRect,
                                               containerHeight: containerSize.height,
                                               bottomInset: bottomInset,
                                               rowHeight: chipHeight,
                                               spacing: DesignTokens.interElementSpacing),
                      width: chipWidth,
                      height: chipHeight)
    }

    /// The box's stroke. A visual constant with no token of its own; it
    /// lives here so it is stated once (the leader line's precedent).
    static let boxLineWidth: CGFloat = 3
}
