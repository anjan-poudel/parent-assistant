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
//  - **A callout is the rare fallback**, not the common case. It exists for
//    the two honest exceptions: text that cannot be drawn legibly in place at
//    the in-place floor, and the always-show-original preference, which by
//    definition wants the original kept visible *beside* the translation.
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
//  - **A callout never covers its own region's printed text.** That hard
//    constraint outranks the preferences (fewest other regions covered, then
//    nearest). A conflict is never resolved by covering the text it is about.
//  - **The geometric corner case is recorded, not absorbed.** When no
//    candidate anchor can satisfy the hard constraint (a genuinely full
//    screen) the pill is clamped on the side with the most free space and the
//    placement is flagged `isClampedFallback`, which is what T-030's manual
//    device validation targets (OD5).
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
        /// type of roughly that size already stood; the callout and card
        /// floors do not.
        let inPlaceMinPointSize: CGFloat
        /// The ceiling on how far the in-place box may grow past the region's
        /// own text box, as a factor (`inPlaceMaxGrowth`). A ceiling, not an
        /// entitlement: the growth is taken only from free space.
        let inPlaceMaxGrowth: Double
        /// The rendered point size floor for the primary line
        /// (`overlayMinPointSize`, floored by the app's body minimum).
        let minPointSize: CGFloat
        /// The point size of the supporting line — the original recognized
        /// text, or the honest state line (the app's caption minimum).
        let secondaryPointSize: CGFloat
        /// Inset between the pill's edge and its text block.
        let pillPadding: CGFloat
        /// Vertical space between the pill's two lines.
        let lineSpacing: CGFloat
        /// Gap between the region's rect and the pill.
        let anchorGap: CGFloat
        /// The FR-LCT-017 preference. On ⇒ the in-place form is ineligible, so
        /// every resolved region shows its original alongside its translation
        /// (pure callout mode, T-022).
        let alwaysShowOriginal: Bool
        /// [BRAINTIER-MERGE-GAP] (2026-09-17) The word ceiling for the
        /// in-place form (D1). PR #33's merge kept the braintier TESTS but
        /// dropped the app-side half of the decision; this field restores
        /// the half the tests exercise. Defaulted (against the struct's
        /// usual no-defaults rule) so the shipped app-layer constructor
        /// kept compiling — the config-driven plumbing is the braintier
        /// session's follow-up.
        let maxSourceWordCount: Int = 4
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
        /// A pill beside the region, with a leader line to `anchor` — the
        /// closest point on the region's rect to the pill, so the line always
        /// points at the region it belongs to.
        case callout(regionID: TextRegionStabilizer.RegionIdentity,
                     anchor: CGPoint,
                     pillRect: CGRect)
    }

    /// One region's complete presentation.
    struct PlacedOverlay: Equatable {
        let region: TextRegionStabilizer.StableTextRegion
        let result: TranslationResult
        let form: Form
        /// The lines to draw, in order, exactly as measured: one for the
        /// in-place form, one or two for a callout. Empty only when a caller
        /// constructs a placement by hand.
        let lines: [LiveOverlayTextLine]
        /// True when no candidate anchor could satisfy the never-cover
        /// constraint and the pill was clamped instead: the geometric corner
        /// case OD5 records for manual device validation (T-030).
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
    /// the reason the region got a callout instead of standing in place.
    enum InPlaceCondition: String, Equatable, CaseIterable {
        /// Nothing has translated the region yet (pending), or nothing could
        /// (degraded). Drawing the recognized text where it already stands
        /// would cover the original with itself and claim the region was
        /// fine, which is exactly what FR-LCT-018 forbids.
        case noTranslationToDraw
        /// The translation does not fit the region's box even at the in-place
        /// floor: the honest answer is a callout beside the text rather than
        /// type too small to read (D1).
        case translationDoesNotFitRegion
        /// The always-show-original preference is on: originals stay visible
        /// beside translations, so nothing is drawn in place.
        case alwaysShowOriginalIsOn
    }

    /// The predicate's answer: the box and the line to draw, or the reason the
    /// region gets a callout. Carrying the box in the value is what makes "the
    /// box the fit was decided on is the box that is drawn" a property rather
    /// than a coincidence of two call sites.
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
    /// returned — the reason a region became a callout is then a fact a test
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
            return .fits(box: box,
                         line: LiveOverlayTextLine(text: result.text,
                                                   pointSize: pointSize,
                                                   weight: .primary))
        }

        return .ineligible(.translationDoesNotFitRegion)
    }

    /// The point sizes the in-place form is tried at, **largest first**: the
    /// app's body floor, then the configured in-place floor. Two candidates at
    /// most, both from the config — a fixed scan, never a search, so the cost
    /// per region stays a constant a test can pin.
    ///
    /// The order is the point: a translation that reads comfortably at the
    /// body floor is drawn at the body floor, and only a region too small for
    /// that gets the smaller in-place size. A region too small for both gets a
    /// callout, which is the honest failure rather than unreadable type.
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

    // MARK: - Placement

    /// Places every region: in place when the translation fits the region's own
    /// box, an anchored callout otherwise, in reading order.
    ///
    ///  - `safeArea` is the container-space rect the placement must stay inside
    ///    (the preview's safe area). An empty rect means "the whole container",
    ///    which is what a caller with no safe-area information has.
    ///  - `occupiedRects` are the already-placed controls: the pills avoid
    ///    them, and the in-place boxes do not grow into them.
    ///  - `stateCopy` supplies the honest line for an outcome that has no
    ///    translation (the catalog's pending/unavailable wording, in the active
    ///    language, T-021). It is a closure so this file stays copy-free — and
    ///    so the string the pill is *sized* around is the very string the view
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
        var rects: [TextRegionStabilizer.RegionIdentity: CGRect] = [:]
        for region in regions where region.box.isValid {
            let rect = screenRect(for: region.box, containerSize: containerSize,
                                  framePixelSize: framePixelSize)
            if rect.width > 0, rect.height > 0 { rects[region.id] = rect }
        }

        /// Every *other* region's printed rect, in identity order: the obstacles
        /// one region's box shares its gaps with. Identity order rather than
        /// dictionary order so the arithmetic is identical however the input
        /// array was ordered.
        func otherRects(_ id: TextRegionStabilizer.RegionIdentity) -> [CGRect] {
            rects.filter { $0.key != id }.sorted { $0.key < $1.key }.map(\.value)
        }

        // The in-place box is pure geometry (the region, its neighbours, the
        // safe area, the growth ceiling), so it is computed before any outcome
        // is looked at: the box a region gets does not depend on whether it
        // was visited first, or on what the meanwhile-placed callouts did. Two
        // of these boxes never overlap — see `inPlaceMaxBox`.
        var boxes: [TextRegionStabilizer.RegionIdentity: CGRect] = [:]
        for (id, rect) in rects {
            boxes[id] = inPlaceMaxBox(regionRect: rect,
                                      obstacles: occupiedRects + otherRects(id),
                                      bounds: bounds,
                                      growth: policy.inPlaceMaxGrowth)
        }

        /// Every other region's box, in identity order: what a *callout* must
        /// stay clear of. A box is used rather than the printed rect because
        /// the drawn boxes are what the elder sees — a pill that avoided a rect
        /// but covered the box drawn over it would be covering text.
        func otherBoxes(_ id: TextRegionStabilizer.RegionIdentity) -> [CGRect] {
            boxes.filter { $0.key != id }.sorted { $0.key < $1.key }.map(\.value)
        }

        var placed: [PlacedOverlay] = []
        placed.reserveCapacity(regions.count)
        // The pills already placed in this pass. A pill avoids the region
        // boxes *and* the pills before it, so two callouts cannot stack either.
        var pills: [CGRect] = []

        for region in placementOrder(regions) {
            guard let regionRect = rects[region.id] else { continue }
            let result = results[region.id] ?? .pending(region.text)
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
                let callout = calloutPlacement(
                    regionRect: regionRect,
                    lines: lines.all,
                    bounds: bounds,
                    obstacles: occupiedRects + otherBoxes(region.id) + pills,
                    policy: policy,
                    measure: measure)
                pills.append(callout.rect)
                placed.append(PlacedOverlay(region: region,
                                            result: result,
                                            form: .callout(regionID: region.id,
                                                           anchor: callout.anchor,
                                                           pillRect: callout.rect),
                                            lines: lines.all,
                                            isClampedFallback: callout.isClampedFallback))
            }
        }

        return readingOrder(placed)
    }

    /// The order regions are *visited* in, which is the order the pills can
    /// see each other in: the same canonical reading order the output uses, so
    /// the same scene produces the same pills whatever order the detector
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
    static func screenRect(for box: NormalizedBox,
                           containerSize: CGSize,
                           framePixelSize: CGSize) -> CGRect {
        let displayed = ApplianceOverlayMapper.displayedImageRect(containerSize: containerSize,
                                                                  imageSize: framePixelSize)
        guard displayed.width > 0, displayed.height > 0 else { return .zero }
        return CGRect(x: displayed.minX + CGFloat(box.xMin) * displayed.width,
                      y: displayed.minY + CGFloat(box.yMin) * displayed.height,
                      width: CGFloat(box.xMax - box.xMin) * displayed.width,
                      height: CGFloat(box.yMax - box.yMin) * displayed.height)
    }

    // MARK: - The lines a presentation draws

    /// The pill's two lines: the translation (or, when nothing translated, the
    /// recognized text) as primary text, and either the original recognized
    /// text or the honest state line as the smaller secondary text.
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

    /// The size of the pill that holds `lines`: the measured text block plus
    /// the policy's padding. Measured with the same closure the view renders
    /// with, at the sizes and weights the lines themselves carry. Unwrapped:
    /// a pill is sized to its lines as written, which is what makes it compact.
    static func pillSize(for lines: [LiveOverlayTextLine],
                         policy: Policy,
                         measure: Measure = LiveOverlayTextMetrics.measure) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (index, line) in lines.enumerated() {
            let measured = measure(line.text, line.pointSize, line.weight, .greatestFiniteMagnitude)
            width = max(width, measured.width)
            if index > 0 { height += policy.lineSpacing }
            height += measured.height
        }
        return CGSize(width: width + 2 * policy.pillPadding,
                      height: height + 2 * policy.pillPadding)
    }

    // MARK: - Callout anchors (FR-LCT-016)

    /// The candidate anchors, in the deterministic order the design fixes:
    /// above, below, right, left. `CaseIterable`'s order *is* that order, and
    /// a test pins it, so "tried in order" cannot drift into "tried in
    /// whatever order the code happens to enumerate".
    enum Anchor: String, CaseIterable, Equatable {
        case above, below, right, left
    }

    private struct CalloutResult {
        let rect: CGRect
        let anchor: CGPoint
        let isClampedFallback: Bool
    }

    /// Chooses the pill's rect and the leader line's target.
    ///
    /// Each candidate is clamped inside the safe area *before* the hard
    /// constraint is tested, because the pill that is drawn is the clamped
    /// one: a candidate that only passes unclamped has not passed. Among the
    /// candidates that do pass, the fewest other regions/controls covered
    /// wins, then the nearest to the region, then the earliest anchor.
    private static func calloutPlacement(regionRect: CGRect,
                                         lines: [LiveOverlayTextLine],
                                         bounds: CGRect,
                                         obstacles: [CGRect],
                                         policy: Policy,
                                         measure: Measure) -> CalloutResult {
        let size = pillSize(for: lines, policy: policy, measure: measure)

        var best: (rect: CGRect, overlaps: Int, distance: CGFloat)?
        for anchor in Anchor.allCases {
            let candidate = clamp(anchorRect(anchor, regionRect: regionRect, size: size,
                                             gap: policy.anchorGap),
                                  into: bounds)
            // The hard constraint: never cover the region's own printed text.
            guard !candidate.intersects(regionRect) else { continue }

            let overlaps = obstacles.reduce(0) { $0 + ($1.intersects(candidate) ? 1 : 0) }
            let distance = hypot(candidate.midX - regionRect.midX,
                                 candidate.midY - regionRect.midY)
            if let current = best {
                if overlaps > current.overlaps { continue }
                if overlaps == current.overlaps, distance >= current.distance { continue }
            }
            best = (candidate, overlaps, distance)
        }

        if let best {
            return CalloutResult(rect: best.rect,
                                 anchor: leaderTarget(pillRect: best.rect, regionRect: regionRect),
                                 isClampedFallback: false)
        }

        // No anchor can satisfy the hard constraint — a genuinely full screen.
        // Clamp on the side with the most free space and record it: this is
        // the case OD5 hands to manual device validation (T-030), not
        // something to absorb silently.
        let side = sideWithMostFreeSpace(regionRect: regionRect, bounds: bounds)
        let rect = clamp(anchorRect(side, regionRect: regionRect, size: size,
                                    gap: policy.anchorGap),
                         into: bounds)
        return CalloutResult(rect: rect,
                             anchor: leaderTarget(pillRect: rect, regionRect: regionRect),
                             isClampedFallback: true)
    }

    /// The pill's rect for one anchor, before clamping: centred on the
    /// region's cross axis, one gap clear of its edge.
    private static func anchorRect(_ anchor: Anchor,
                                   regionRect: CGRect,
                                   size: CGSize,
                                   gap: CGFloat) -> CGRect {
        switch anchor {
        case .above:
            return CGRect(x: regionRect.midX - size.width / 2,
                          y: regionRect.minY - gap - size.height,
                          width: size.width, height: size.height)
        case .below:
            return CGRect(x: regionRect.midX - size.width / 2,
                          y: regionRect.maxY + gap,
                          width: size.width, height: size.height)
        case .right:
            return CGRect(x: regionRect.maxX + gap,
                          y: regionRect.midY - size.height / 2,
                          width: size.width, height: size.height)
        case .left:
            return CGRect(x: regionRect.minX - gap - size.width,
                          y: regionRect.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
    }

    /// Moves a pill inside `bounds` without ever resizing it: a resized pill
    /// would clip text that was measured to fit. A pill wider or taller than
    /// the bounds cannot fit at all, so it is aligned to the bounds' leading
    /// edge and left to overflow on the trailing side — the only positioning
    /// that keeps the start of the text inside the screen.
    private static func clamp(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        let x = rect.width >= bounds.width
            ? bounds.minX
            : min(max(rect.origin.x, bounds.minX), bounds.maxX - rect.width)
        let y = rect.height >= bounds.height
            ? bounds.minY
            : min(max(rect.origin.y, bounds.minY), bounds.maxY - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// The point on the region's rect the leader line points at: the region
    /// rect's closest point to the pill's centre. Always on or inside the
    /// region's rect, so the line always lands on the text it belongs to.
    private static func leaderTarget(pillRect: CGRect, regionRect: CGRect) -> CGPoint {
        CGPoint(x: min(max(pillRect.midX, regionRect.minX), regionRect.maxX),
                y: min(max(pillRect.midY, regionRect.minY), regionRect.maxY))
    }

    /// The last resort's side: the one with the most free space between the
    /// region and the safe area's edge, ties going to the earlier anchor. It
    /// is a measurement, not a preference — with nothing that satisfies the
    /// hard constraint, the honest choice is the roomiest side.
    private static func sideWithMostFreeSpace(regionRect: CGRect, bounds: CGRect) -> Anchor {
        var best: (anchor: Anchor, space: CGFloat)?
        for anchor in Anchor.allCases {
            let space: CGFloat
            switch anchor {
            case .above: space = max(0, regionRect.minY - bounds.minY)
            case .below: space = max(0, bounds.maxY - regionRect.maxY)
            case .left: space = max(0, regionRect.minX - bounds.minX)
            case .right: space = max(0, bounds.maxX - regionRect.maxX)
            }
            if let current = best, space <= current.space { continue }
            best = (anchor, space)
        }
        return best?.anchor ?? .above
    }
}
