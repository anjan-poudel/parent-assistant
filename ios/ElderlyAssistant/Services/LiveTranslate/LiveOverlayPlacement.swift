import CoreGraphics
import Foundation

// C11 — `LiveOverlayPlacement` (T-020: FR-LCT-015, FR-LCT-016, NFR-LCT-002,
// NFR-LCT-012, D1, OD5). Reworked 2026-09-17 for the owner's live-device
// feedback: "the bubbles are everywhere and shaky and get stacked and
// clustered depending on text", "the white background of the bubbles covers
// everything".
//
// What this file exists to make true:
//
//  - **Replace-in-place is the default render.** Every region that has a
//    translation — dictionary *or* cloud — is drawn inside its own text box,
//    wrapped to that box, so the translation stands where the text stood
//    instead of a bubble floating over the picture. The old word bound (a
//    proxy for "short dictionary label") is gone: the fit is now decided by
//    measuring the translation against the box it would be drawn in, which is
//    what actually matters.
//  - **A block is one panel** (scene-block rework, 2026-09-18; owner direction:
//    "maximize text regions — bigger but fewer translations — and use object
//    detection bounding boxes"). A region whose text is several lines — the
//    grouper's blocks, which is what the detector reports since the rework — is
//    drawn as **one panel** on the block's own rect, its lines stacked inside it
//    at the body floor, never as one callout per line. A block the tier has not
//    answered for yet is the same panel carrying the honest state sentence (or,
//    with no state copy to draw, the block's own recognized lines): the surface
//    appears where the text stood and fills in, rather than a pill appearing
//    beside it and being replaced by it.
//    **A block that cannot stand as a panel falls back to the bounded panel,
//    and then to the panel on the block's own rect — never to nothing, and
//    never to a pill** (owner device verdict, 2026-09-18: "the camera says it
//    can't find anything to read"; owner refinement, 2026-09-18: a block too
//    tall for its own box is drawn as a *scrollable* panel, not as one pill).
//    The bounded panel is the same surface as the panel — the block's own
//    lines, in order, at the body floor, and now with the original stacked
//    under them where the preference asks for it — inside a box capped at
//    `panelMaxHeightFraction` of the container and scrolled when the lines
//    overflow it. Still one surface for the block — not one bubble per line —
//    and still at the body floor. The one thing the live overlay may never do
//    is drop a region it recognized: the empty state is for a scene with no
//    text in it, and showing it over text is the feature telling the elder
//    something untrue.
//  - **The live overlay has exactly two surfaces, and both are green.** Every
//    placement is an in-place box or a panel (plain, bounded, or — for a region
//    with no room at all — the panel on its own rect). The anchored callout is
//    **unreachable from this file**: `place` has no path that returns
//    `Form.callout`, which is the owner's device verdict made structural —
//    *"there are still some white-on-blue text boxes floating around"*
//    (2026-09-18). A translation that cannot be drawn in place is drawn where
//    the text stood, at the body floor, with a cap and a scroll; it is never
//    moved beside the text into a second surface the elder has to find, follow
//    and read. See `panelFallback` for why this is a property of the decision
//    rather than a configuration.
//  - **One predicate, three conditions.** `inPlaceOutcome` is the one
//    implementation, and `place` goes through it — a fourth condition cannot
//    be introduced at one call site and not the other.
//  - **The measurement is the render.** Every size decision goes through the
//    caller's `Measure` closure — the feature's one measurer
//    (`LiveOverlayTextMetrics`) — at the width the box will draw at, and the
//    emitted `lines` carry the exact strings, point sizes and weights that
//    were measured, so the view has no size to choose and nothing to
//    re-derive (risk R2, removed structurally).
//  - **Two boxes never stack.** The in-place box is *geometry first*: it is
//    the region's own rect grown by at most `inPlaceMaxGrowth`, and only into
//    space no other region's rect occupies — and where two regions are close,
//    each takes at most **half** the gap between them, so two boxes that both
//    grow meet at the midpoint and can touch but never overlap. That is the
//    "stacked and clustered" complaint answered with a property rather than a
//    tuning pass.
//  - **The box hugs the text it replaces.** `inPlaceMaxBox` is where the box
//    may reach; `inPlaceTightBox` is where it stops — the union of the
//    region's own printed rect and the measured text block plus the policy's
//    padding, and nothing more. A short translation is not left centred in a
//    slab of empty ink (the owner's device verdict, 2026-09-17), and because
//    the union can only shrink a box that was already proved clear of its
//    neighbours, the no-stacking property is untouched.
//  - **The geometric corner case is recorded, not absorbed.** When even the
//    bounded panel has nowhere to go the placement is still a panel — on the
//    region's own rect, moved inside the bounds and never resized — so the
//    corner case costs the elder a scroll, not a surface to find. A region
//    whose box is degenerate is the only thing that yields no placement, and
//    it is the one input the detector cannot produce (a region with no rect).
//  - **Nothing floats.** No placement is positioned relative to another, none
//    is drawn outside the box of the text it belongs to, and none carries a
//    leader line: the "white-on-blue text boxes floating around" the owner saw
//    were exactly the placements whose box was *not* the text's own (2026-09-18).
//  - **Pure, deterministic, total, bounded.** No clock, no I/O, no camera, no
//    storage, no await. The same inputs produce the same placements whatever
//    order the regions arrive in — the output is ordered canonically (top to
//    bottom, then left to right, then identity) and the work per region is a
//    fixed number of rect operations and text measurements.
//  - **The letterboxing math is the shipped one.** Region rects are mapped
//    through `ApplianceOverlayMapper.displayedImageRect` unchanged, so the
//    live overlay and the shipped appliance overlay agree on where a
//    normalized box lands (NFR-LCT-012).
//
// Every operational constant arrives in `Policy`, which the app layer builds
// from `LiveTranslateConfig` and `DesignTokens`; nothing here spells a value.

/// One line the overlay draws — the *whole* measurement key, not just the
/// text. Carrying the size and the weight is what makes "the view renders what
/// the placement measured" a property of the value rather than a convention:
/// the view has no font to pick (see `LiveOverlayTextMetrics`).
struct LiveOverlayTextLine: Equatable {
    let text: String
    let pointSize: CGFloat
    let weight: LiveOverlayTextWeight
}

/// What the elder sees and where. Pure and total: every input is a value and
/// every output is a value.
enum LiveOverlayPlacement {

    // MARK: - The text seam

    /// How the placement measures text: the string, the point size, the
    /// weight, and the width the text may wrap to. The real implementation is
    /// the feature's one measurer, and it is also the one the view renders
    /// with; a test can substitute a counting closure to prove the cost is
    /// bounded without changing what is measured.
    typealias Measure = (String, CGFloat, LiveOverlayTextWeight, CGFloat) -> CGSize

    // MARK: - Inputs

    /// The parameters one placement pass runs under.
    ///
    /// Everything here is supplied by the app layer: the config's values and
    /// the token table's, so neither this file nor a test spells a nominal
    /// value by hand. Deliberately no defaults: a policy is always built from
    /// the one config and the one token table.
    struct Policy: Equatable {
        /// The point size floor for in-place text (`inPlaceMinPointSize`),
        /// already reconciled with `minPointSize` by the app layer. In-place
        /// text may go below the app's body floor because it stands where
        /// type of roughly that size already stood; the reading card's floor
        /// does not.
        let inPlaceMinPointSize: CGFloat
        /// The ceiling on how far the in-place box may grow past the region's
        /// own text box, as a factor (`inPlaceMaxGrowth`). A ceiling, not an
        /// entitlement: the growth is taken only from free space, and only as
        /// far as the measured translation actually reaches.
        let inPlaceMaxGrowth: Double
        /// The room between the in-place box's edge and the text block it
        /// holds, in points (`inPlacePadding`). The in-place box is a
        /// replacement rather than a bubble, so this is the whole margin the
        /// translation has: tight enough that the box reads as the sign's own
        /// type replaced.
        let inPlacePadding: CGFloat
        /// The in-place box's corner radius, in points (`inPlaceCornerRadius`):
        /// a corner that hugs the text line height rather than the bubble
        /// token's pill radius.
        let inPlaceCornerRadius: CGFloat
        /// The room between the **detected text region** and the edge of the
        /// box drawn over it, in points (`overlayHighlightPadding`) — the
        /// owner's "small padding ~5pt" (2026-09-18).
        ///
        /// Distinct from `inPlacePadding`, and both are stated because they
        /// answer two different questions. `inPlacePadding` is the room the
        /// *translation* is given inside its own box (that is a typographic
        /// value). This one is the room the *detection* is given around it: the
        /// drawn box is never smaller than the region the app actually saw,
        /// grown by this much — so a short translation is still framed as a
        /// highlight over the recognized words rather than as a box that has
        /// shrunk onto them, and so the elder can see the app's claim without
        /// reading the text inside it.
        let highlightPadding: CGFloat
        /// How much of the picture the highlight fill lets through
        /// (`overlayHighlightOpacity`). Carried in the policy because the fill
        /// is a property of the *presentation* the placement describes, and the
        /// view decides nothing: a test can read what the overlay was told to
        /// draw without rendering it.
        let highlightOpacity: Double
        /// How far the drawn box travels toward a newly measured rect on each
        /// update, as an exponential moving average factor
        /// (`overlayBoxLerpFactor`). Consumed by the overlay's geometry memory
        /// rather than by the placement, and carried here for the reason
        /// `geometryStickiness` is: the two are the same mechanism's two halves
        /// — one decides *whether* a box moves, the other *how* — and a caller
        /// holding the policy holds both.
        let boxLerpFactor: Double
        /// The largest fraction of the container a **bounded panel**'s height
        /// may be (`panelMaxHeightFraction`). Carried in the policy for the
        /// same reason `geometryStickiness` is: it is a share of the container
        /// the rects were measured in, so it means the same thing to the
        /// placement that measures the panel and to the view that draws it.
        let panelMaxHeightFraction: Double
        /// How far a region's rect may drift from the rect last rendered for
        /// it before the overlay adopts the new geometry, as a fraction of the
        /// container dimension (`overlayGeometryStickiness`). Carried in the
        /// policy because it is measured in the same container the rects were
        /// measured in; consumed by the overlay's geometry memory, not by the
        /// placement itself.
        let geometryStickiness: Double
        /// The rendered point size floor for the primary line
        /// (`overlayMinPointSize`, floored by the app's body minimum).
        let minPointSize: CGFloat
        /// The point size of the supporting line — the original recognized
        /// text, or the honest state line (the app's caption minimum).
        let secondaryPointSize: CGFloat
        /// Inset between a **callout** pill's edge and its text block.
        ///
        /// No live placement consumes this any more: since the owner's device
        /// verdict on the white-on-blue boxes (2026-09-18) `place` produces no
        /// callout, and every surface it does produce is padded by
        /// `inPlacePadding` (which is deliberately tighter, because a
        /// replacement of the sign's own type is tight where a floating pill is
        /// not). It is carried because the renderer still draws a callout a
        /// caller built by hand — the reading card's own presentation, and the
        /// view's tests — and because a policy is built in one place: dropping
        /// the field would make that renderer the only caller choosing a
        /// padding token for itself.
        let pillPadding: CGFloat
        /// Vertical space between the lines of a surface that stacks them.
        let lineSpacing: CGFloat
        /// Gap between the region's rect and a **callout** pill's edge, for the
        /// same reason `pillPadding` is carried: the renderer still draws a
        /// hand-built callout, and no live placement reads it.
        let anchorGap: CGFloat
        /// The FR-LCT-017 preference. On ⇒ the in-place form is ineligible, so
        /// every resolved region shows its original alongside its translation —
        /// stacked in its own panel since the callout removal (owner device
        /// verdict, 2026-09-18; T-022's "pure callout mode" is now pure *panel*
        /// mode, and the preference's meaning — the original stays visible —
        /// is unchanged).
        let alwaysShowOriginal: Bool
        /// [BRAINTIER-MERGE-GAP] (2026-09-17) The word ceiling for the
        /// in-place form (D1). PR #33's merge kept the braintier TESTS but
        /// dropped the app-side half of the decision; this field restores
        /// the half the tests exercise. Defaulted (against the struct's
        /// usual no-defaults rule) so the shipped app-layer constructor
        /// kept compiling — the config-driven plumbing is the braintier
        /// session's follow-up.
        let maxSourceWordCount: Int = 4
        /// **Extract mode** (owner verdict, 2026-09-18): the overlay shows the
        /// recognized text rather than a translation, so a region with nothing
        /// translated is not an ineligible region — it is the normal case, and
        /// its own text is what stands where it stood.
        ///
        /// Defaulted, against this struct's usual no-defaults rule, for the
        /// same reason `maxSourceWordCount` is: every existing constructor and
        /// every existing placement test keeps its meaning. `false` is the
        /// translated view, which is what every caller before this rework
        /// asked for. `var` rather than `let` because a `let` with a default
        /// is dropped from the synthesized memberwise initializer, which would
        /// make the flag impossible to set to `true`.
        var extractionMode: Bool = false
    }

    // MARK: - Braintier eligibility seam (merge-gap patch, 2026-09-17)

    /// The braintier tests' entry point into the in-place decision
    /// (`worktree-live-translate-ux-braintier`, commit 37647f8). PR #33's
    /// merge kept those tests but dropped the app-side half of the API;
    /// this seam restores the shape the tests pin, implemented over the
    /// tier rule and the word bound the branch designed. The shipped
    /// `inPlaceOutcome` machinery above is untouched — this is an
    /// additive entry point, not a replacement.
    enum InPlaceEligibility: Equatable {
        case eligible
        case ineligible
    }

    /// The braintier total decision: only the curated dictionary tier may
    /// stand in place, the normalized source stays within the word bound,
    /// the translation fits the region at the floor size, and the
    /// always-show-original preference is off. No growth-budget condition
    /// (the fit at the floor *is* the bound, D1).
    static func inPlaceEligibility(source: String,
                                   translation: String,
                                   regionRect: CGRect,
                                   policy: Policy,
                                   tier: TranslationTier?,
                                   measure: Measure = LiveOverlayTextMetrics.measure) -> InPlaceEligibility {
        guard tier == .dictionary else { return .ineligible }

        guard wordCount(source) <= policy.maxSourceWordCount else { return .ineligible }

        let measured = measure(translation, policy.minPointSize, .primary, regionRect.width)
        guard measured.width <= regionRect.width, measured.height <= regionRect.height else {
            return .ineligible
        }

        guard !policy.alwaysShowOriginal else { return .ineligible }

        return .eligible
    }

    /// The word count the source bound is measured against: the feature's
    /// one normalization (trim, collapse, case-fold), split on spaces. An
    /// empty source counts as no words.
    static func wordCount(_ source: String) -> Int {
        LiveTranslateTextNormalization.normalized(source)
            .split(separator: " ", omittingEmptySubsequences: true)
            .count
    }

    // MARK: - Outputs

    /// Where one region's presentation is drawn. Exactly the design's shape:
    /// the view and the spoken ordering consume this, and nothing else.
    enum Form: Equatable {
        /// The translation replaces the region's text, on an opaque box that
        /// covers the region's own text box and no more free space than it
        /// needed.
        case inPlace(regionID: TextRegionStabilizer.RegionIdentity, rect: CGRect)
        /// The same one-panel surface for a **block** whose lines could not be
        /// stacked as a panel at the body floor inside the block's own grown
        /// box: bounded to `panelMaxHeightFraction` of the container, with the
        /// block's lines drawn inside it at that floor and scrolled when they
        /// overflow (owner refinement, 2026-09-18).
        ///
        /// It is a *form* and not a flag on `inPlace` because the view has to
        /// choose a different surface for it — a scroll view rather than a
        /// stack — and the view decides nothing: which surface a region is
        /// drawn on is a fact of the placement, exactly as the box is.
        case scrollablePanel(regionID: TextRegionStabilizer.RegionIdentity, rect: CGRect)
        /// A pill beside the region, with a leader line to `anchor` — the
        /// closest point on the region's rect to the pill, so the line always
        /// points at the region it belongs to.
        ///
        /// **`place` never produces this case.** It is the form the owner's
        /// device verdict retired from the live overlay ("there are still some
        /// white-on-blue text boxes floating around", 2026-09-18) and the two
        /// sites that emitted it are gone; the case survives because the
        /// renderer still draws one a *caller* built by hand, which is how the
        /// view's form-geometry tests (and, if a future reading surface wants a
        /// leader line, that surface) reach it. A test asserts on the type for
        /// every input `place` takes, so this cannot come back by
        /// configuration.
        case callout(regionID: TextRegionStabilizer.RegionIdentity,
                     anchor: CGPoint,
                     pillRect: CGRect)
    }

    /// One region's complete presentation.
    struct PlacedOverlay: Equatable {
        let region: TextRegionStabilizer.StableTextRegion
        let result: TranslationResult
        let form: Form
        /// The lines to draw, in order, exactly as measured: one for a
        /// single-line in-place form, every line of the block for a panel, one
        /// or two for a callout a caller built by hand. Empty only when a
        /// caller constructs a placement by hand.
        let lines: [LiveOverlayTextLine]
        /// True when a placement had to be clamped into the container instead
        /// of being positioned by its own law.
        ///
        /// Always false for what `place` returns: the two clamped-fallback
        /// sites were the callout's, and they went with it. Carried because the
        /// value is part of what the renderer and the reading card consume (a
        /// hand-built placement may set it), and because the field is what the
        /// tests that used to assert the corner case now read to assert its
        /// *absence* (OD5, T-030).
        let isClampedFallback: Bool

        init(region: TextRegionStabilizer.StableTextRegion,
             result: TranslationResult,
             form: Form,
             lines: [LiveOverlayTextLine] = [],
             isClampedFallback: Bool = false) {
            self.region = region
            self.result = result
            self.form = form
            self.lines = lines
            self.isClampedFallback = isClampedFallback
        }
    }

    // MARK: - The in-place predicate (D1)

    /// The conditions, named for their *violation*: `ineligible(_:)` reads as
    /// the reason the region's translation does not stand in place.
    enum InPlaceCondition: String, Equatable, CaseIterable {
        /// Nothing has translated the region yet (pending), or nothing could
        /// (degraded). Drawing the recognized text where it already stands
        /// would cover the original with itself and claim the region was
        /// fine, which is exactly what FR-LCT-018 forbids.
        case noTranslationToDraw
        /// The translation does not fit the region's box even at the in-place
        /// floor: the honest answer is the panel over the text rather than
        /// type too small to read (D1).
        case translationDoesNotFitRegion
        /// The always-show-original preference is on: originals stay visible
        /// beside translations, so nothing is drawn in place.
        case alwaysShowOriginalIsOn
    }

    /// The predicate's answer: the box and the line to draw, or the reason the
    /// region does not stand in place. Carrying the box in the value is what
    /// makes "the box the fit was decided on is the box that is drawn" a
    /// property rather than a coincidence of two call sites.
    enum InPlaceOutcome: Equatable {
        case fits(box: CGRect, line: LiveOverlayTextLine)
        case ineligible(InPlaceCondition)

        /// The violation, when there is one — the design's boolean form,
        /// rendered as a value rather than a second implementation.
        var condition: InPlaceCondition? {
            guard case .ineligible(let condition) = self else { return nil }
            return condition
        }

        /// The box to draw, when the translation fits in it.
        var box: CGRect? {
            guard case .fits(let box, _) = self else { return nil }
            return box
        }
    }

    /// **The** in-place decision (D1). Total: it answers for every outcome,
    /// including an unresolved one, so "is this resolved?" cannot be forgotten
    /// by a caller that only holds a result.
    ///
    /// Conditions are tested in a fixed order and the first violation is
    /// returned — the reason a region did not stand in place is then a fact a test
    /// (or a debugger) can read, not an inference.
    ///
    /// `obstacles` are the rects the box may not grow into: the app's own
    /// chrome, and every *other* region's rect. Passing rects rather than
    /// already-grown boxes is what keeps the decision order-independent — each
    /// region's growth budget is a function of its neighbours' printed text,
    /// not of the order they were visited in.
    static func inPlaceOutcome(regionRect: CGRect,
                               result: TranslationResult,
                               obstacles: [CGRect] = [],
                               bounds: CGRect,
                               policy: Policy,
                               measure: Measure = LiveOverlayTextMetrics.measure) -> InPlaceOutcome {
        // Extract mode (owner verdict, 2026-09-18). The line drawn where the
        // text stood is the text itself — the recognized string re-rendered at
        // the body floor, not the raw pixels the camera caught — so two of the
        // translated view's eligibility rules have nothing to say here:
        //
        //  * `noTranslationToDraw` is not a violation when no translation was
        //    asked for: an untranslated region is the normal case, and its own
        //    recognized text standing exactly where it stood is the whole
        //    point of the mode (NFR-LCT-010's never-empty rule, inverted into
        //    the default). A region whose recognized text is empty still has
        //    nothing to draw and is still ineligible.
        //  * `alwaysShowOriginalIsOn` is trivially satisfied: extract mode has
        //    no translation to sit beside, so the preference is not a conflict.
        //
        // Everything else is the translated view's law, unchanged and for the
        // same reasons: the box grows from free space only (so no two boxes
        // stack), the fit is measured before the box is returned, and text too
        // large for the region at the floor gets the honest panel over it rather
        // than being shrunk until it fits.
        //
        // A region that *is* resolved draws its translation here exactly as it
        // does in the translated view — a tapped block that has been answered
        // must not keep showing the text it was tapped to replace.
        if policy.extractionMode {
            let drawn = result.sourceTier != nil ? result.text : result.originalText
            guard !LiveTranslateTextNormalization.normalized(drawn).isEmpty else {
                return .ineligible(.noTranslationToDraw)
            }
            // The FR-LCT-017 preference outlives the mode change, and it is
            // consulted exactly where it still has something to say: a region
            // that *has* been translated (by a tap) would have its original
            // covered by the in-place box, and an elder who asked for originals
            // to stay visible asked about every translation on screen, not only
            // the continuously translated ones. For a region nothing has
            // translated there is no conflict to resolve — the original is what
            // this branch draws anyway — so the preference is not consulted
            // there.
            if result.sourceTier != nil, policy.alwaysShowOriginal {
                return .ineligible(.alwaysShowOriginalIsOn)
            }

            let box = inPlaceMaxBox(regionRect: regionRect,
                                    obstacles: obstacles,
                                    bounds: bounds,
                                    growth: policy.inPlaceMaxGrowth)
            let pointSize = panelPointSize(policy: policy)
            let measured = measure(drawn, pointSize, .primary, box.width)
            guard measured.width <= box.width, measured.height <= box.height else {
                return .ineligible(.translationDoesNotFitRegion)
            }
            return .fits(box: inPlaceTightBox(regionRect: regionRect,
                                              textSize: measured,
                                              ceiling: box,
                                              padding: policy.inPlacePadding,
                                              highlightPadding: policy.highlightPadding),
                         line: LiveOverlayTextLine(text: drawn,
                                                   pointSize: pointSize,
                                                   weight: .primary))
        }

        guard result.sourceTier != nil, !result.text.isEmpty else {
            return .ineligible(.noTranslationToDraw)
        }
        guard !policy.alwaysShowOriginal else { return .ineligible(.alwaysShowOriginalIsOn) }

        let box = inPlaceMaxBox(regionRect: regionRect,
                                obstacles: obstacles,
                                bounds: bounds,
                                growth: policy.inPlaceMaxGrowth)
        for pointSize in inPlacePointSizes(policy: policy) {
            let measured = measure(result.text, pointSize, .primary, box.width)
            guard measured.width <= box.width, measured.height <= box.height else { continue }
            return .fits(box: inPlaceTightBox(regionRect: regionRect,
                                              textSize: measured,
                                              ceiling: box,
                                              padding: policy.inPlacePadding,
                                              highlightPadding: policy.highlightPadding),
                         line: LiveOverlayTextLine(text: result.text,
                                                   pointSize: pointSize,
                                                   weight: .primary))
        }

        return .ineligible(.translationDoesNotFitRegion)
    }

    /// The box the in-place form is **drawn** in: the region's own printed rect
    /// (plus the green highlight's `highlightPadding`), the measured text block
    /// — plus the policy's `inPlacePadding` — and nothing else.
    ///
    /// `inPlaceMaxBox` is where the box *may* reach; this is where it *stops*.
    /// Until 2026-09-17 the drawn box was the ceiling itself, so a short
    /// translation sat centred in a slab of empty ink — which is exactly what
    /// the owner saw and named ("the bubbles are blue background with white
    /// text … they still jump around"). Making the box hug its own text is the
    /// second half of the answer, and the first is the geometry memory that
    /// stops the box moving at all.
    ///
    /// Four properties, all of them load-bearing:
    ///
    ///  1. **The region's own rect is always covered.** The box is the union
    ///     with it, never a rect placed inside it: the translation *stands in*
    ///     for the printed text, so the words it answers must be under the box,
    ///     and the box never stops short of the line's own edges. (Since the
    ///     green-overlay rework, 2026-09-18, "under" means under a wash the
    ///     elder can still read through — which makes covering the whole region
    ///     more important, not less: a box that clipped a line in half would
    ///     highlight half a sentence.)
    ///  2. **The text block and its padding are always inside.** The union
    ///     contains the padded block, so the view cannot clip what the fit
    ///     condition just measured — and the width is additionally floored at
    ///     the width the text was *measured* at, so the drawn box can never be
    ///     narrower than the wrap the measurement used (a narrower box would
    ///     re-wrap the text taller and clip it vertically).
    ///  3. **The ceiling still bounds it.** The union of two rects inside
    ///     `ceiling` is inside `ceiling`, so the no-two-boxes-stack property
    ///     `inPlaceMaxBox` establishes is untouched: the tight box is a subset
    ///     of the box that was proved not to overlap its neighbours.
    ///  4. **The detected region plus `highlightPadding` is inside it too.**
    ///     The green wash's job is to point at the print (owner spec: "the
    ///     bounding box can be transparent green with dark colored text …
    ///     small padding ~5pt"), so the box is the region grown by that much on
    ///     every side, clipped to the ceiling. See the band below.
    static func inPlaceTightBox(regionRect: CGRect,
                                textSize: CGSize,
                                ceiling: CGRect,
                                padding: CGFloat,
                                highlightPadding: CGFloat) -> CGRect {
        guard regionRect.width > 0, regionRect.height > 0,
              ceiling.width > 0, ceiling.height > 0 else { return ceiling }

        // Never narrower than the measurement width, never wider than the
        // ceiling, and never narrower than the text it replaces.
        let width = min(max(textSize.width + 2 * padding, regionRect.width), ceiling.width)
        let height = min(max(textSize.height + 2 * padding, regionRect.height), ceiling.height)
        let block = clamp(CGRect(x: regionRect.midX - width / 2,
                                 y: regionRect.midY - height / 2,
                                 width: width, height: height),
                          into: ceiling)
        // The **highlight band**: the region the app actually detected, grown by
        // the policy's `highlightPadding` on every side (owner spec,
        // 2026-09-18 — "the bounding box can be transparent green with dark
        // colored text", "small padding ~5pt"). It is the fourth property this
        // box has to have, and the reason the green wash reads as a highlight
        // *of the words* rather than as a label that happens to be nearby: the
        // box is never a tight shrink-wrap around the re-rendered translation,
        // which on a long sign is a different, larger rect than the print the
        // elder is looking at.
        //
        // Bounded by the same ceiling as everything else here — the grown rect
        // is clipped to it rather than clamped (a clamp moves a rect, so an
        // over-large band would push the box out past the space that was proved
        // clear of its neighbours and the no-two-boxes-stack property would go
        // with it). Where the ceiling gives no room for the band, the box is
        // simply the region's own rect: the padding is a comfort, never a
        // reason to overlap the sign next to this one.
        let band = regionRect.insetBy(dx: -highlightPadding, dy: -highlightPadding)
            .intersection(ceiling)
        return regionRect.union(block).union(band)
    }

    /// The point sizes the in-place form is tried at, **largest first**: the
    /// app's body floor, then the configured in-place floor. Two candidates at
    /// most, both from the config — a fixed scan, never a search, so the cost
    /// per region stays a constant a test can pin.
    ///
    /// The order is the point: a translation that reads comfortably at the
    /// body floor is drawn at the body floor, and only a region too small for
    /// that gets the smaller in-place size. A region too small for both gets a
    /// panel over it, which is the honest failure rather than unreadable type.
    static func inPlacePointSizes(policy: Policy) -> [CGFloat] {
        let floor = min(policy.inPlaceMinPointSize, policy.minPointSize)
        return floor < policy.minPointSize ? [policy.minPointSize, floor] : [policy.minPointSize]
    }

    /// The largest box the in-place form may occupy.
    ///
    /// Three rules, in this order:
    ///
    ///  1. **The region's own rect is the floor.** The box always contains it,
    ///     so the printed text it replaces is fully covered (the box is drawn
    ///     opaque). Growth is only ever outward from here.
    ///  2. **Another rect is a shared gap, and the two halves are each other's
    ///     bound.** Every other rect bounds the growth *on one axis* to at most
    ///     half the distance between the two rects across it. Two rects that
    ///     both grow therefore meet at the midpoint of the axis that separates
    ///     them: they can touch, never overlap — and because the separation is
    ///     complete on that one axis, the boxes cannot stack even where they
    ///     are diagonal neighbours.
    ///  3. **`growth` is a ceiling, not an entitlement.** `1.4` means at most
    ///     a fifth of the region's own size clear on each axis, so a translation
    ///     on a big sign cannot become a wall of text.
    ///
    /// The container's own edge is the only bound that may be taken in full:
    /// free space between the region and the safe area is nobody else's.
    ///
    /// **Which axis is bounded.** A rect directly above or below this one
    /// (overlapping it horizontally) is separated vertically, so it bounds the
    /// *vertical* growth only — a column of labels would otherwise never be
    /// able to widen. The rule is the mirror of that for a rect beside it. A
    /// rect that is *diagonal* — separated on both axes — could collide on
    /// either, so it bounds the axis it is further away on: that is the axis
    /// with room to give, the two rects take half of it each, and the pair is
    /// separated there whatever the other axis does.
    static func inPlaceMaxBox(regionRect: CGRect,
                              obstacles: [CGRect],
                              bounds: CGRect,
                              growth: Double) -> CGRect {
        guard regionRect.width > 0, regionRect.height > 0 else { return regionRect }

        var left = max(0, regionRect.minX - bounds.minX)
        var right = max(0, bounds.maxX - regionRect.maxX)
        var top = max(0, regionRect.minY - bounds.minY)
        var bottom = max(0, bounds.maxY - regionRect.maxY)

        func limitHorizontally(_ other: CGRect) {
            if other.maxX <= regionRect.minX {
                left = min(left, (regionRect.minX - other.maxX) / 2)
            } else if other.minX >= regionRect.maxX {
                right = min(right, (other.minX - regionRect.maxX) / 2)
            }
        }
        func limitVertically(_ other: CGRect) {
            if other.maxY <= regionRect.minY {
                top = min(top, (regionRect.minY - other.maxY) / 2)
            } else if other.minY >= regionRect.maxY {
                bottom = min(bottom, (other.minY - regionRect.maxY) / 2)
            }
        }

        for other in obstacles where other.width > 0 && other.height > 0 {
            let dx = max(0, max(regionRect.minX - other.maxX, other.minX - regionRect.maxX))
            let dy = max(0, max(regionRect.minY - other.maxY, other.minY - regionRect.maxY))
            switch (dx, dy) {
            case (0, 0):
                // Overlapping printed text: the region's own rect cannot be
                // given up, so there is no gap here to share.
                continue
            case (_, 0):
                limitHorizontally(other)
            case (0, _):
                limitVertically(other)
            default:
                if dx >= dy { limitHorizontally(other) } else { limitVertically(other) }
            }
        }

        let factor = growth > 1 ? growth : 1
        let extraX = regionRect.width * CGFloat(factor - 1) / 2
        let extraY = regionRect.height * CGFloat(factor - 1) / 2
        let growLeft = min(extraX, left)
        let growRight = min(extraX, right)
        let growTop = min(extraY, top)
        let growBottom = min(extraY, bottom)

        return CGRect(x: regionRect.minX - growLeft,
                      y: regionRect.minY - growTop,
                      width: regionRect.width + growLeft + growRight,
                      height: regionRect.height + growTop + growBottom)
    }

    // MARK: - Block panels (scene-block rework, 2026-09-18)

    /// Whether a region is a **block**: its text is more than one line.
    ///
    /// The grouper joins a block's members with `SceneBlock.lineSeparator`, so
    /// a separator in a region's text is the one deterministic signal that this
    /// region is a surface holding several lines rather than one recognized
    /// line. It is a property of the value, not a flag some caller has to
    /// remember to set, so a panel and a per-line placement cannot be confused
    /// at a call site.
    static func isBlock(_ region: TextRegionStabilizer.StableTextRegion) -> Bool {
        region.text.contains(SceneBlock.lineSeparator)
    }

    /// A block's lines, in order, at the one point size a panel is drawn at.
    ///
    /// Empty lines are dropped: a blank row is not text the elder reads, and
    /// drawing it would spend panel height on nothing. The order is the
    /// translation's own order — it is read top to bottom, the same way the
    /// block was recognized.
    static func panelLines(_ text: String, pointSize: CGFloat) -> [LiveOverlayTextLine] {
        text.components(separatedBy: SceneBlock.lineSeparator)
            .filter { !LiveTranslateTextNormalization.normalized($0).isEmpty }
            .map { LiveOverlayTextLine(text: $0, pointSize: pointSize, weight: .primary) }
    }

    /// The supporting lines a panel draws under its translation when the
    /// always-show-original preference is on: the block's original lines, in
    /// the same order, in the secondary weight.
    static func panelOriginalLines(_ text: String, policy: Policy) -> [LiveOverlayTextLine] {
        text.components(separatedBy: SceneBlock.lineSeparator)
            .filter { !LiveTranslateTextNormalization.normalized($0).isEmpty }
            .map { LiveOverlayTextLine(text: $0,
                                       pointSize: policy.secondaryPointSize,
                                       weight: .secondary) }
    }

    /// The point size a panel is drawn at: the body floor, and nothing else.
    ///
    /// The owner's bound is the reason there is no smaller candidate here
    /// ("translated lines inside at ≥18pt where the block allows"). A panel
    /// that cannot be drawn at the body floor is not shrunk until it fits —
    /// that is precisely the illegible small type the rework removes — so it
    /// stops being a *static* panel: the block is drawn as the bounded panel
    /// (the same lines, the same floor, a capped and scrollable box), or, with
    /// no box to draw in at all, as the panel on the block's own rect — the one
    /// surface that always has somewhere to go. The floor never moves; only the
    /// box around it does.
    static func panelPointSize(policy: Policy) -> CGFloat { policy.minPointSize }

    /// The size of a stack of lines: the widest line, the total height, and the
    /// policy's spacing between them. The one measurement a panel's fit is
    /// decided on, so the box that is drawn is the box that was measured.
    ///
    /// Lines wrap to `maxWidth` — the width of the box they will be drawn in —
    /// because a tall sign is exactly where wrapping has to be allowed to make
    /// a translation fit.
    static func panelTextSize(_ lines: [LiveOverlayTextLine],
                              lineSpacing: CGFloat,
                              maxWidth: CGFloat,
                              measure: Measure) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (index, line) in lines.enumerated() {
            let measured = measure(line.text, line.pointSize, line.weight, maxWidth)
            width = max(width, measured.width)
            if index > 0 { height += lineSpacing }
            height += measured.height
        }
        return CGSize(width: width, height: height)
    }

    /// The panel decision, in the same shape as the in-place one: the box and
    /// the lines to draw, or the honest "this block gets no live panel".
    enum PanelOutcome: Equatable {
        case fits(box: CGRect, lines: [LiveOverlayTextLine])
        case doesNotFit
    }

    /// **The** panel decision, for a resolved block.
    ///
    /// The box is the region's own rect grown into free space only
    /// (`inPlaceMaxBox`, so the half-gap law between two blocks holds exactly as
    /// it does between two lines), and the fit is the stacked block at the body
    /// floor. Anything that does not fit returns `.doesNotFit` — never a
    /// smaller, illegible version of the panel. What the caller draws instead is
    /// the **bounded panel** (`boundedPanelOutcome`): the decision here is
    /// "the whole block, at the floor, in the block's own box", and a block
    /// that does not get that is still a block the overlay shows.
    static func panelOutcome(regionRect: CGRect,
                             lines: [LiveOverlayTextLine],
                             obstacles: [CGRect] = [],
                             bounds: CGRect,
                             policy: Policy,
                             measure: Measure = LiveOverlayTextMetrics.measure) -> PanelOutcome {
        guard !lines.isEmpty, regionRect.width > 0, regionRect.height > 0 else { return .doesNotFit }

        let box = inPlaceMaxBox(regionRect: regionRect,
                                obstacles: obstacles,
                                bounds: bounds,
                                growth: policy.inPlaceMaxGrowth)
        guard box.width > 0, box.height > 0 else { return .doesNotFit }

        let size = panelTextSize(lines, lineSpacing: policy.lineSpacing,
                                 maxWidth: box.width, measure: measure)
        guard size.width <= box.width, size.height <= box.height else { return .doesNotFit }

        return .fits(box: inPlaceTightBox(regionRect: regionRect,
                                          textSize: size,
                                          ceiling: box,
                                          padding: policy.inPlacePadding,
                                          highlightPadding: policy.highlightPadding),
                     lines: lines)
    }

    // MARK: - Bounded panels (owner refinement, 2026-09-18)

    /// The tallest a bounded panel may be: `panelMaxHeightFraction` of the
    /// container, and never more than the safe area it is drawn in.
    ///
    /// The two bounds answer two different questions. The fraction is the
    /// elder's: however long a block's translation is, its panel is never more
    /// than a fixed share of what they are looking at. The safe area is the
    /// screen's: a panel may not run under the notch or into the home
    /// indicator, cap or no cap.
    static func panelMaxHeight(containerSize: CGSize,
                               bounds: CGRect,
                               policy: Policy) -> CGFloat {
        guard containerSize.height > 0, bounds.height > 0 else { return 0 }
        let fraction = max(0, CGFloat(policy.panelMaxHeightFraction))
        return min(containerSize.height * fraction, bounds.height)
    }

    /// The bounded panel's own decision, in the same shape as the panel's: the
    /// box the block's lines are drawn in, or the honest "even this has nowhere
    /// to go".
    enum BoundedPanelOutcome: Equatable {
        case fits(box: CGRect)
        case doesNotFit
    }

    /// **The** bounded-panel decision, for a block the plain panel could not
    /// hold.
    ///
    /// The box is the *block's own* grown box — the very rect `panelOutcome`
    /// measured against, so the half-gap law between two blocks holds here
    /// exactly as it does between two panels — cut down to the policy's cap.
    /// Capping the height rather than the whole box is deliberate: the block
    /// has already been proved to have this room, and what it does not have is
    /// the *vertical* room for every line at once. The lines are not shrunk and
    /// not dropped — the surface scrolls, which is the one thing a static panel
    /// cannot do.
    ///
    /// Nothing is measured here, and nothing needs to be: the lines are drawn
    /// at the floor the panel path already fixed, wrapped to the box the view
    /// draws (a scroll view absorbs however tall that turns out to be), and the
    /// cap bounds the box whatever the content does. A caller that gets a box
    /// back can draw every line it handed in.
    static func boundedPanelOutcome(regionRect: CGRect,
                                    obstacles: [CGRect] = [],
                                    bounds: CGRect,
                                    containerSize: CGSize,
                                    policy: Policy) -> BoundedPanelOutcome {
        guard regionRect.width > 0, regionRect.height > 0 else { return .doesNotFit }

        let ceiling = inPlaceMaxBox(regionRect: regionRect,
                                    obstacles: obstacles,
                                    bounds: bounds,
                                    growth: policy.inPlaceMaxGrowth)
        guard ceiling.width > 0, ceiling.height > 0 else { return .doesNotFit }

        let height = min(ceiling.height,
                         panelMaxHeight(containerSize: containerSize,
                                        bounds: bounds,
                                        policy: policy))
        guard height > 0 else { return .doesNotFit }

        // Centred on the text it stands over — the block's own middle, which is
        // where the elder is already looking — and then kept inside the box
        // that was proved clear of its neighbours. `clamp` moves a rect, never
        // resizes one, so the cap survives the move.
        let box = clamp(CGRect(x: ceiling.minX,
                               y: regionRect.midY - height / 2,
                               width: ceiling.width,
                               height: height),
                        into: ceiling)
        return .fits(box: box)
    }

    // MARK: - Placement

    /// Places every region: in place when the translation fits the region's own
    /// box, a scrollable panel on the region's own box otherwise, in reading
    /// order. **Nothing in the live path is ever a callout** (owner device
    /// verdict, 2026-09-18: "there are still some white-on-blue text boxes
    /// floating around") — the two rungs a region that cannot stand in place
    /// gets are both green surfaces standing where the text stood.
    ///
    /// **The rect a box is anchored to is `region.box`, whatever that box came
    /// from** (owner spec, 2026-09-18: "object-box anchoring where available").
    /// For a block that sits inside a detected object — a menu board, a sign,
    /// a poster — the grouper has already made that the object's box clipped to
    /// the union of its member lines (`SceneBlockGrouper.objectBox(_:holding:)`),
    /// so the green box covers the whole board rather than one line of it; for
    /// a free-standing region it is the text line's own rect. Nothing here has
    /// to know which: the placement consumes one rect and the same law applies
    /// to both, and an anchoring test pins the identity rather than trusting it.
    ///
    ///  - `safeArea` is the container-space rect the placement must stay inside
    ///    (the preview's safe area). An empty rect means "the whole container",
    ///    which is what a caller with no safe-area information has.
    ///  - `occupiedRects` are the already-placed controls: no box grows into
    ///    them — not an in-place box, not a panel, not the panel fallback.
    ///  - `stateCopy` supplies the honest line for an outcome that has no
    ///    translation (the catalog's pending/unavailable wording, in the active
    ///    language, T-021). It is a closure so this file stays copy-free — and
    ///    so the string a panel is *sized* around is the very string the view
    ///    draws.
    ///
    /// A region with no result is placed as pending, never dropped: a tier
    /// that has not answered yet must not make a recognized region disappear
    /// (NFR-LCT-010). A region whose box cannot be geometry, or a degenerate
    /// container/frame, yields no placement at all (nothing can be drawn in
    /// the right place); the stabiliser never publishes such a region, so the
    /// guard is a totality guard, not a policy.
    static func place(regions: [TextRegionStabilizer.StableTextRegion],
                      results: [TextRegionStabilizer.RegionIdentity: TranslationResult],
                      containerSize: CGSize,
                      framePixelSize: CGSize,
                      safeArea: CGRect,
                      occupiedRects: [CGRect] = [],
                      crop: LiveCameraCrop = .whole,
                      policy: Policy,
                      stateCopy: (TranslationResult) -> String?,
                      measure: Measure = LiveOverlayTextMetrics.measure) -> [PlacedOverlay] {
        guard containerSize.width > 0, containerSize.height > 0,
              framePixelSize.width > 0, framePixelSize.height > 0 else { return [] }

        let bounds = safeArea.width > 0 && safeArea.height > 0
            ? safeArea
            : CGRect(origin: .zero, size: containerSize)

        // Every region's on-screen rect, computed once: the placement of one
        // region needs the others only as rects it should avoid covering, and
        // recomputing them per region would make the cost quadratic in a way
        // that is not visible in the result but is visible in a profile.
        //
        // A region the window has moved away from gets no rect at all, so it is
        // not placed — there is no part of the frame it could be drawn on. It
        // is not *forgotten*: the region is still recognized, still translated
        // and still spoken, and it is placed again the moment the window covers
        // it, because the placement is recomputed for every publication.
        var rects: [TextRegionStabilizer.RegionIdentity: CGRect] = [:]
        for region in regions where region.box.isValid {
            guard crop.intersects(region.box) else { continue }
            let rect = screenRect(for: region.box, containerSize: containerSize,
                                  framePixelSize: framePixelSize, crop: crop)
            if rect.width > 0, rect.height > 0 { rects[region.id] = rect }
        }

        /// Every *other* region's printed rect, in identity order: the obstacles
        /// one region's box shares its gaps with. Identity order rather than
        /// dictionary order so the arithmetic is identical however the input
        /// array was ordered.
        func otherRects(_ id: TextRegionStabilizer.RegionIdentity) -> [CGRect] {
            rects.filter { $0.key != id }.sorted { $0.key < $1.key }.map(\.value)
        }

        // Every box is pure geometry (the region, its neighbours, the safe
        // area, the growth ceiling), so it is computed inside the decision that
        // returns it — the box a region gets does not depend on whether it was
        // visited first, or on what the regions before it were drawn as. Two of
        // these boxes never overlap — see `inPlaceMaxBox`.

        var placed: [PlacedOverlay] = []
        placed.reserveCapacity(regions.count)

        for region in placementOrder(regions) {
            guard let regionRect = rects[region.id] else { continue }
            let result = results[region.id] ?? .pending(region.text)

            // A **block** is one panel the snapshot can read in full and one
            // panel the overlay draws (scene-block rework): its lines are
            // stacked inside one box on the block's own rect, at the body
            // floor, never one surface per line. A block whose whole text
            // cannot be stacked at that size falls through to the **bounded
            // panel** — the same surface, capped to a share of the container
            // and scrolled — and a block with no box to draw in at all still
            // gets the panel, on its own rect: never nothing for it, and never
            // a pill beside it.
            //
            // A block the tier has not answered for yet is drawn the same way,
            // carrying the honest state sentence instead of a translation: the
            // surface appears where the text stood and fills in, rather than a
            // pill appearing beside it and being replaced. With no state copy
            // to draw (a caller that has none), the block's own recognized
            // lines stand in — a tier that has not answered must not make a
            // recognized region vanish (NFR-LCT-010).
            if Self.isBlock(region) {
                let resolved = result.sourceTier != nil && !result.text.isEmpty
                // Extract mode draws the block's own recognized lines while
                // nothing has translated it — not the state sentence. The
                // sentence this branch would otherwise use ("Translating…")
                // describes work extract mode is deliberately not doing: no
                // tier runs until a block is tapped, so every block on screen
                // would carry the same untrue line. A **degraded** result is
                // still said, because that one can only follow a tap that
                // asked for a translation and did not get one (FR-LCT-018).
                let text: String
                if resolved {
                    text = result.text
                } else if policy.extractionMode, !result.degraded {
                    text = result.originalText
                } else {
                    text = stateCopy(result) ?? result.originalText
                }
                let lines = panelLines(text, pointSize: panelPointSize(policy: policy))
                    + (resolved && policy.alwaysShowOriginal
                        ? panelOriginalLines(result.originalText, policy: policy)
                        : [])
                if !lines.isEmpty,
                   case .fits(let box, let panelLines) = panelOutcome(regionRect: regionRect,
                                                                      lines: lines,
                                                                      obstacles: occupiedRects + otherRects(region.id),
                                                                      bounds: bounds,
                                                                      policy: policy,
                                                                      measure: measure) {
                    placed.append(PlacedOverlay(region: region,
                                                result: result,
                                                form: .inPlace(regionID: region.id, rect: box),
                                                lines: panelLines))
                    continue
                }

                // A block whose lines do not fit even the block's own grown box
                // is drawn as the **bounded panel**: the same lines, at the
                // same body floor, in a box capped at a share of the container
                // and scrolled when they overflow (owner refinement,
                // 2026-09-18). This is the rung that keeps a long block a
                // *panel* — a surface the elder reads in place — instead of
                // handing it to a pill that shows its first line and hides the
                // rest. The cap is what stops the last-resort surface from
                // becoming the screen; the scroll is what stops the cap from
                // becoming a truncation.
                if !lines.isEmpty,
                   case .fits(let box) = boundedPanelOutcome(regionRect: regionRect,
                                                             obstacles: occupiedRects + otherRects(region.id),
                                                             bounds: bounds,
                                                             containerSize: containerSize,
                                                             policy: policy) {
                    placed.append(PlacedOverlay(region: region,
                                                result: result,
                                                form: .scrollablePanel(regionID: region.id,
                                                                       rect: box),
                                                lines: lines))
                    continue
                }

                // **A block that cannot stand as a panel still speaks.** The
                // panel is the form the owner asked for and it is tried first;
                // the bounded panel is tried second, and covers every block
                // with a box to draw in. What is left below is the rung for a
                // block with no line to draw at all, or one whose box cannot
                // hold a panel of any height — and it is **still the panel**,
                // on the block's own rect.
                //
                // This is the owner's device verdict on the rework, at the line
                // it is about: "the camera says it can't find anything to
                // read". A pass whose blocks all failed the panel fit used to
                // publish no presentation at all, which the overlay renders as
                // its empty state over a picture full of text the pass had just
                // read. A block the panel cannot hold is a block the *snapshot
                // card* reads best, not one the live overlay may silently drop.
                // The panel carries the block's own lines — there is no reason
                // to re-derive them, and every reason not to: the two paths
                // would answer differently for a state sentence. The state copy
                // is consulted only in the degenerate case where the block has
                // no line to draw at all (an empty recognized string and no
                // copy), so the panel is never an empty surface.
                let panelLines = lines.isEmpty
                    ? calloutLines(for: result, policy: policy, stateCopy: stateCopy).all
                    : lines
                placed.append(panelFallback(region: region,
                                            result: result,
                                            lines: panelLines,
                                            regionRect: regionRect,
                                            obstacles: occupiedRects + otherRects(region.id),
                                            bounds: bounds,
                                            containerSize: containerSize,
                                            policy: policy))
                continue
            }

            let lines = calloutLines(for: result, policy: policy, stateCopy: stateCopy)

            // The same obstacle set the box above was computed from, so the
            // box this decision returns is the box that is drawn.
            let outcome = inPlaceOutcome(regionRect: regionRect,
                                         result: result,
                                         obstacles: occupiedRects + otherRects(region.id),
                                         bounds: bounds,
                                         policy: policy,
                                         measure: measure)

            switch outcome {
            case .fits(let box, let line):
                placed.append(PlacedOverlay(region: region,
                                            result: result,
                                            form: .inPlace(regionID: region.id, rect: box),
                                            // The one line the in-place form
                                            // draws, at the size the fit
                                            // condition measured it at.
                                            lines: [line]))
            case .ineligible:
                // A region that cannot be drawn in place — the translation does
                // not fit its box at the body floor, nothing has translated it
                // yet, or the elder has asked for the original to stay visible
                // beside the translation — is drawn as the **bounded panel**:
                // the same green surface where the text stood, its lines at the
                // body floor, capped and scrolled. It is not moved beside the
                // text and it is not a floating pill (owner device verdict,
                // 2026-09-18: "there are still some white-on-blue text boxes
                // floating around" — the pill was the last of them).
                placed.append(panelFallback(region: region,
                                            result: result,
                                            lines: lines.all,
                                            regionRect: regionRect,
                                            obstacles: occupiedRects + otherRects(region.id),
                                            bounds: bounds,
                                            containerSize: containerSize,
                                            policy: policy))
            }
        }

        return readingOrder(placed)
    }

    /// The order regions are *visited* in, which is the order their boxes can
    /// see each other in: the same canonical reading order the output uses, so
    /// the same scene produces the same placements whatever order the detector
    /// reported its regions in.
    static func placementOrder(_ regions: [TextRegionStabilizer.StableTextRegion])
        -> [TextRegionStabilizer.StableTextRegion] {
        regions.sorted(by: { (lhs: TextRegionStabilizer.StableTextRegion,
                              rhs: TextRegionStabilizer.StableTextRegion) -> Bool in
            precedes((point: lhs.box.center, id: lhs.id), (point: rhs.box.center, id: rhs.id))
        })
    }

    /// Top to bottom, then left to right, then by identity — the feature's one
    /// canonical order (the stabiliser's, and the order a spoken "read this to
    /// me" walks). Geometric on purpose: the order is a property of where the
    /// text is, not of when it was seen.
    static func readingOrder(_ placed: [PlacedOverlay]) -> [PlacedOverlay] {
        placed.sorted(by: { (lhs: PlacedOverlay, rhs: PlacedOverlay) -> Bool in
            precedes((point: lhs.region.box.center, id: lhs.region.id),
                     (point: rhs.region.box.center, id: rhs.region.id))
        })
    }

    /// The one comparison behind both orders.
    private static func precedes(_ left: (point: (x: Double, y: Double),
                                          id: TextRegionStabilizer.RegionIdentity),
                                 _ right: (point: (x: Double, y: Double),
                                           id: TextRegionStabilizer.RegionIdentity))
        -> Bool {
        if left.point.y != right.point.y { return left.point.y < right.point.y }
        if left.point.x != right.point.x { return left.point.x < right.point.x }
        return left.id < right.id
    }

    // MARK: - Screen mapping (NFR-LCT-012)

    /// A normalized frame box as a container-space rect.
    ///
    /// The letterboxing is the shipped `ApplianceOverlayMapper`'s math,
    /// called unchanged: the frame is displayed aspect-fit (the preview's
    /// gravity, T-006), so both overlays agree on where a box lands.
    ///
    /// `crop` is the window the elder is looking through (owner follow-up,
    /// 2026-09-18). The mapping is then the *same* affine the preview layer is
    /// drawn with — `LiveCameraPresentation` — rather than a second copy of the
    /// arithmetic, which is what makes a box glued to its region stay glued
    /// while the picture is zoomed and panned: both are one function of the
    /// same crop. `.whole` is the identity crop, and it is what every caller
    /// before the window existed passed.
    static func screenRect(for box: NormalizedBox,
                           containerSize: CGSize,
                           framePixelSize: CGSize,
                           crop: LiveCameraCrop = .whole) -> CGRect {
        let displayed = ApplianceOverlayMapper.displayedImageRect(containerSize: containerSize,
                                                                  imageSize: framePixelSize)
        guard displayed.width > 0, displayed.height > 0 else { return .zero }
        return LiveCameraPresentation(crop: crop, pictureRect: displayed)
            .containerRect(ofFrameBox: box)
    }

    // MARK: - The lines a presentation draws

    /// A surface's two lines: the translation (or, when nothing translated, the
    /// recognized text) as primary text, and either the original recognized
    /// text or the honest state line as the smaller secondary text.
    ///
    /// The name is the callout's because the callout was its first consumer;
    /// every surface the placement now produces reads its lines from here (the
    /// panel takes `.all`, the in-place box the primary alone), and the
    /// renderer's hand-built callouts do too, so there is one line rule in the
    /// feature rather than one per surface.
    ///
    /// A degraded or pending region therefore shows what it *has* — the
    /// recognized text — next to what is true about it, and never a
    /// translated-looking string (FR-LCT-018).
    struct CalloutLines: Equatable {
        let primary: LiveOverlayTextLine
        let secondary: LiveOverlayTextLine?

        var all: [LiveOverlayTextLine] { secondary.map { [primary, $0] } ?? [primary] }
    }

    static func calloutLines(for result: TranslationResult,
                             policy: Policy,
                             stateCopy: (TranslationResult) -> String?) -> CalloutLines {
        let primary = LiveOverlayTextLine(text: result.text,
                                          pointSize: policy.minPointSize,
                                          weight: .primary)

        let supporting: String?
        if result.sourceTier != nil {
            // A translation exists: the original stays reachable beside it.
            supporting = result.originalText
        } else if policy.extractionMode, !result.degraded {
            // Extract mode, nothing translated: the one line is the
            // recognized text, and there is no second line to write. The state
            // sentence a pending region carries in the translated view
            // ("Translating…") would be a claim about work this mode has not
            // started — the box is already reading the text it was going to
            // translate, so it has nothing left to say. A **degraded** result,
            // reachable only after a tap asked for a translation, keeps its
            // sentence: that one is true, and it is the honesty FR-LCT-018
            // requires.
            supporting = nil
        } else {
            supporting = stateCopy(result)
        }

        // A supporting line identical to the primary one is not a second line:
        // drawing the same string twice would be noise, not information.
        var secondary: LiveOverlayTextLine?
        if let supporting, !supporting.isEmpty, supporting != primary.text {
            secondary = LiveOverlayTextLine(text: supporting,
                                            pointSize: policy.secondaryPointSize,
                                            weight: .secondary)
        }

        return CalloutLines(primary: primary, secondary: secondary)
    }

    // MARK: - The live fallback: the panel, never a pill (owner verdict, 2026-09-18)

    /// The **one** fallback the live overlay has: the scrollable panel, drawn
    /// on the region's own box.
    ///
    /// This is the rung that used to be the anchored callout, and the owner's
    /// device verdict on the build that had it is why it is not any more:
    /// "there are still some white-on-blue text boxes floating around". A
    /// floating box beside the text is a second surface to read and a second
    /// thing to chase while the picture moves; the panel is the same surface as
    /// the panel above it — the region's lines, in order, at the body floor,
    /// where the text stood — with the cap and the scroll the bounded panel
    /// already has. The two rungs differ in what they can promise, not in how
    /// they look: the bounded panel promises the block's own grown box, and
    /// this one promises *a box*, because a region recognized in a container
    /// with no room left still has its own rect.
    ///
    /// The removal is structural rather than conditional. There is no input to
    /// `place` that produces `Form.callout` — a test drives the dense, the
    /// degraded, the extract-mode, the always-show-original and the degenerate
    /// cases and asserts on the *type* — so the form cannot come back by
    /// configuration, and the placement below has no eighth rung to fall to.
    /// The case stays in `Form` for the renderer, which still draws a callout a
    /// caller built by hand (the view's tests do, and so may a future reading
    /// surface); the *placement* has no way to reach it.
    private static func panelFallback(region: TextRegionStabilizer.StableTextRegion,
                                      result: TranslationResult,
                                      lines: [LiveOverlayTextLine],
                                      regionRect: CGRect,
                                      obstacles: [CGRect],
                                      bounds: CGRect,
                                      containerSize: CGSize,
                                      policy: Policy) -> PlacedOverlay {
        let box = panelFallbackBox(regionRect: regionRect,
                                   obstacles: obstacles,
                                   bounds: bounds,
                                   containerSize: containerSize,
                                   policy: policy)
        return PlacedOverlay(region: region,
                             result: result,
                             form: .scrollablePanel(regionID: region.id, rect: box),
                             lines: lines)
    }

    /// The box the fallback panel is drawn in: the bounded panel's own box when
    /// the region has one, and otherwise the region's rect moved inside the
    /// bounds.
    ///
    /// Total for every region that has a rect at all, which is what makes the
    /// fallback a *form* rather than a hope — the property that lets `place`
    /// answer with a panel for every input, and therefore never with a pill.
    /// The second branch is not a policy: it is the arithmetic for a region
    /// whose own box has no room to give (a container whose safe area is all
    /// consumed, a rect the growth law cannot grow), and the box it returns is
    /// the region's own rect moved — never resized — so the panel starts where
    /// the text does even when it cannot fit on the screen.
    static func panelFallbackBox(regionRect: CGRect,
                                 obstacles: [CGRect] = [],
                                 bounds: CGRect,
                                 containerSize: CGSize,
                                 policy: Policy) -> CGRect {
        if case .fits(let box) = boundedPanelOutcome(regionRect: regionRect,
                                                     obstacles: obstacles,
                                                     bounds: bounds,
                                                     containerSize: containerSize,
                                                     policy: policy) {
            return box
        }
        return clamp(regionRect, into: bounds)
    }

    /// Moves a rect inside `bounds` without ever resizing it: a resized panel
    /// would clip text that the panel's own law promised to draw. A rect wider
    /// or taller than the bounds cannot fit at all, so it is aligned to the
    /// bounds' leading edge and left to overflow on the trailing side — the
    /// only positioning that keeps the start of the text inside the screen.
    private static func clamp(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        let x = rect.width >= bounds.width
            ? bounds.minX
            : min(max(rect.origin.x, bounds.minX), bounds.maxX - rect.width)
        let y = rect.height >= bounds.height
            ? bounds.minY
            : min(max(rect.origin.y, bounds.minY), bounds.maxY - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }
}
