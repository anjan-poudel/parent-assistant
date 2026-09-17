import CoreGraphics
import Foundation

// C11 — `LiveOverlayPlacement` (T-020: FR-LCT-015, FR-LCT-016, NFR-LCT-002,
// NFR-LCT-012, D1, OD5).
//
// What this file exists to make true:
//
//  - **One predicate, four conditions.** The in-place form is chosen only
//    when *all four* D1 conditions hold: the outcome is resolved from the
//    curated dictionary (a cloud translation is never drawn in place, however
//    well it fits), the normalized source is within the word bound, the
//    translation fits its region rect at the minimum point size, and the
//    always-show-original preference is off. `inPlaceEligibility` is the one
//    implementation; `inlineEligible` and `place` both delegate to it, so a
//    fifth condition cannot be introduced at one call site and not another.
//  - **The measurement is the render.** Every size decision goes through the
//    caller's `Measure` closure — the feature's one measurer
//    (`LiveOverlayTextMetrics`) — and the emitted `lines` carry the exact
//    strings, point sizes and weights that were measured, so the view has no
//    size to choose and nothing to re-derive (risk R2, removed structurally).
//  - **A callout never covers its own region's printed text.** That hard
//    constraint outranks the preferences (fewest other regions covered, then
//    nearest). A conflict is never resolved by covering the text it is about.
//  - **The geometric corner case is recorded, not absorbed.** When no
//    candidate anchor can satisfy the hard constraint (a genuinely full
//    screen) the pill is clamped on the side with the most free space and the
//    placement is flagged `isClampedFallback`, which is what T-030's manual
//    device validation targets (OD5).
//  - **Pure, deterministic, total, bounded.** No clock, no I/O, no camera, no
//    storage, no await. The same inputs produce the same placements — the
//    output is ordered canonically (top to bottom, then left to right, then
//    identity) and the work per region is a fixed number of rect operations.
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

    /// How the placement measures text. The real implementation is the
    /// feature's one measurer, and it is also the one the view renders with;
    /// a test can substitute a counting closure to prove the cost is bounded
    /// without changing what is measured.
    typealias Measure = (String, CGFloat, LiveOverlayTextWeight) -> CGSize

    // MARK: - Inputs

    /// The parameters one placement pass runs under.
    ///
    /// The first three are the design's (`maxSourceWordCount`, `minPointSize`,
    /// `alwaysShowOriginal`); the rest are the callout's text layout, supplied
    /// by the app layer from `DesignTokens` so the view can lay the very same
    /// lines out inside the very same pill without a second constant anywhere.
    /// Deliberately no defaults: a policy is always built from the one config
    /// and the one token table, never from a literal spelled here.
    struct Policy: Equatable {
        /// Source strings of at most this many words are eligible for the
        /// in-place form (`inPlaceMaxSourceWordCount`).
        let maxSourceWordCount: Int
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
    }

    // MARK: - Outputs

    /// Where one region's presentation is drawn. Exactly the design's shape:
    /// the view and the spoken ordering consume this, and nothing else.
    enum Form: Equatable {
        /// The translation replaces the region's text, on a background sized
        /// to the region.
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

    /// The four conditions, named for their *violation*: `ineligible(_:)`
    /// reads as the reason the region got a callout, in the design's order.
    enum InPlaceCondition: String, Equatable, CaseIterable {
        /// The outcome is not resolved, or its tier is the cloud: a cloud
        /// translation is never drawn in place, even when it would fit.
        case sourceTierIsNotDictionary
        /// The normalized source has more than `maxSourceWordCount` words.
        case sourceExceedsWordBound
        /// The translation does not fit the region rect at `minPointSize`.
        case translationDoesNotFitRegion
        /// The always-show-original preference is on: originals stay visible
        /// beside translations, so nothing is drawn in place.
        case alwaysShowOriginalIsOn
    }

    enum InPlaceEligibility: Equatable {
        case eligible
        case ineligible(InPlaceCondition)
    }

    /// **The** in-place decision (D1). Total: it answers for every outcome,
    /// including an unresolved one (`tier` nil), so "is this resolved?" cannot
    /// be forgotten by a caller that only holds a result.
    ///
    /// Conditions are tested in the design's order and the first violation is
    /// returned — the reason a region became a callout is then a fact a test
    /// (or a debugger) can read, not an inference.
    ///
    /// There is deliberately no "growth budget" condition: the fit at the
    /// minimum point size *is* the bound (D1).
    static func inPlaceEligibility(source: String,
                                   translation: String,
                                   regionRect: CGRect,
                                   policy: Policy,
                                   tier: TranslationTier?,
                                   measure: Measure = LiveOverlayTextMetrics.measure) -> InPlaceEligibility {
        guard tier == .dictionary else { return .ineligible(.sourceTierIsNotDictionary) }

        guard wordCount(source) <= policy.maxSourceWordCount else {
            return .ineligible(.sourceExceedsWordBound)
        }

        let measured = measure(translation, policy.minPointSize, .primary)
        guard measured.width <= regionRect.width, measured.height <= regionRect.height else {
            return .ineligible(.translationDoesNotFitRegion)
        }

        guard !policy.alwaysShowOriginal else { return .ineligible(.alwaysShowOriginalIsOn) }

        return .eligible
    }

    /// The design's boolean form. Delegates — it is a rendering of the same
    /// decision, never a second implementation of it.
    static func inlineEligible(source: String,
                               translation: String,
                               regionRect: CGRect,
                               policy: Policy,
                               tier: TranslationTier?,
                               measure: Measure = LiveOverlayTextMetrics.measure) -> Bool {
        inPlaceEligibility(source: source, translation: translation, regionRect: regionRect,
                           policy: policy, tier: tier, measure: measure) == .eligible
    }

    /// The word count the source bound is measured against: the feature's one
    /// normalization (trim, collapse, case-fold), split on spaces. An empty
    /// source counts as no words — the stabiliser never publishes an empty
    /// string, and a caller that passes one gets the honest arithmetic rather
    /// than a special case.
    static func wordCount(_ source: String) -> Int {
        LiveTranslateTextNormalization.normalized(source)
            .split(separator: " ", omittingEmptySubsequences: true)
            .count
    }

    // MARK: - Placement

    /// Places every region: in place when all four conditions hold, an
    /// anchored callout otherwise, in reading order.
    ///
    ///  - `safeArea` is the container-space rect the pill must stay inside
    ///    (the preview's safe area). An empty rect means "the whole container",
    ///    which is what a caller with no safe-area information has.
    ///  - `occupiedRects` are the already-placed controls the callout should
    ///    avoid, like any other region.
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

        var placed: [PlacedOverlay] = []
        placed.reserveCapacity(regions.count)

        for region in regions {
            guard let regionRect = rects[region.id] else { continue }
            let result = results[region.id] ?? .pending(region.text)
            let lines = calloutLines(for: result, policy: policy, stateCopy: stateCopy)

            if inlineEligible(source: region.text, translation: result.text,
                              regionRect: regionRect, policy: policy,
                              tier: result.sourceTier, measure: measure) {
                placed.append(PlacedOverlay(
                    region: region,
                    result: result,
                    form: .inPlace(regionID: region.id, rect: regionRect),
                    // The one line the in-place form draws, at the size the fit
                    // condition measured it at.
                    lines: [lines.primary]))
                continue
            }

            let obstacles = occupiedRects + rects
                .filter { $0.key != region.id }
                .sorted { $0.key < $1.key }
                .map(\.value)
            let callout = calloutPlacement(regionRect: regionRect,
                                           lines: lines.all,
                                           bounds: bounds,
                                           obstacles: obstacles,
                                           policy: policy,
                                           measure: measure)
            placed.append(PlacedOverlay(
                region: region,
                result: result,
                form: .callout(regionID: region.id, anchor: callout.anchor,
                               pillRect: callout.rect),
                lines: lines.all,
                isClampedFallback: callout.isClampedFallback))
        }

        return readingOrder(placed)
    }

    /// Top to bottom, then left to right, then by identity — the feature's one
    /// canonical order (the stabiliser's, and the order a spoken "read this to
    /// me" walks). Geometric on purpose: the order is a property of where the
    /// text is, not of when it was seen.
    static func readingOrder(_ placed: [PlacedOverlay]) -> [PlacedOverlay] {
        placed.sorted { lhs, rhs in
            let left = lhs.region.box.center
            let right = rhs.region.box.center
            if left.y != right.y { return left.y < right.y }
            if left.x != right.x { return left.x < right.x }
            return lhs.region.id < rhs.region.id
        }
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
    /// with, at the sizes and weights the lines themselves carry.
    static func pillSize(for lines: [LiveOverlayTextLine],
                         policy: Policy,
                         measure: Measure = LiveOverlayTextMetrics.measure) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (index, line) in lines.enumerated() {
            let measured = measure(line.text, line.pointSize, line.weight)
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
