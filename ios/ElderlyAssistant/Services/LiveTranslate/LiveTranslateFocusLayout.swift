import CoreGraphics

// [FOCUS-CAPTURE] The focused read's layout rule, stated once as arithmetic.
//
// A focused read is two things stacked: the crop, which is *evidence* — the
// pixels the elder pointed at — and the card under it, which is the *answer*
// (the translation panel, the original line, one row per recognized string,
// each row a tap that speaks). The two compete for one screen, and the rule
// that settles the competition is the plan's:
//
//  1. **The panel is bounded by the picture.** It may take at most
//     `Rule.panelHeightFraction` (45 %) of the drawn picture's height. The
//     picture is the reason the elder raised the phone; a panel that grew to
//     fill the screen would answer a question about something they can no
//     longer see.
//  2. **The picture may grow to buy the panel room — but only while growth
//     buys anything.** When 45 % of the aspect-fit picture is less than the
//     panel needs, the picture is drawn larger — up to `Rule.maximumImageGrowth`
//     (1.4×) — which raises the allowance with it. Growth is *scale*, never a
//     second crop: the picture is drawn through `.fill` and clipped, so
//     growing it discards nothing the elder pointed at (the pixels are all
//     still there), it simply spends screen on the text rather than on the
//     margin around it. **The search stops the moment a further step cannot
//     raise the resolved panel** (review finding 5): once the floor or the
//     container's own remainder pins the panel, every extra step enlarges the
//     picture for nothing — and a `.fill`ed picture that grew for nothing has
//     had its edges clipped for nothing, which is how the ends of the very
//     line the elder pointed at came off the glass.
//  3. **Legibility is a floor, not a preference.** The picture may never grow
//     so far that the panel falls below `minimumPanelHeight`, which is the
//     room one row needs at the app's type floors (`DesignTokens`
//     `minCaptionPointSize` — 18 pt — for the original line and
//     `minBodyPointSize` for the translation). A layout that made the answer
//     unreadable to show more of the question would have the trade backwards.
//  4. **What does not fit scrolls.** When even the fully-grown picture leaves
//     the panel less than its content needs, the panel keeps the allowance it
//     has and its content scrolls. The one thing it never does is truncate a
//     string or shrink the type below the floor: an elder reading a
//     prescription is exactly the reader this rule exists for.
//
// The type is deliberately a *value* with no view in it: the three rules are
// the part worth pinning, and a rule that can only be observed by rendering a
// view is a rule that gets re-decided by whoever next touches the layout. The
// view reads this and draws; the tests read this and assert.

/// The focused read's two heights, resolved for one container and one panel.
///
/// `Equatable` so a view can tell a re-layout that changed nothing from one
/// that moved — SwiftUI re-runs the resolver on every geometry change, and a
/// still hand answers the same value frame after frame.
struct LiveTranslateFocusLayout: Equatable {

    /// The rule's own numbers, as one value.
    ///
    /// A value and not three statics, because they are *injected*: the
    /// session's `LiveTranslateConfig` is the one place a nominal value is
    /// spelled, and a layout that read `LiveTranslateConfig.default` would be
    /// a second, invisible source of truth for a suite that drives a session
    /// with its own config (review finding: use the injected config on the
    /// layout path, not the shipped default). `shipped` is the default for a
    /// caller with no config to hand — the shipped numbers exactly once.
    struct Rule: Equatable {

        /// The panel's share of the drawn picture's height.
        let panelHeightFraction: CGFloat

        /// How much larger than its aspect-fit size the picture may be drawn
        /// in order to buy the panel room.
        let maximumImageGrowth: CGFloat

        /// The growth step the search walks in. Coarse on purpose: the value
        /// that comes out is a screen height, and a hundredth of a point of
        /// panel is not a readability difference — the *floor* is what matters,
        /// and the floor is enforced exactly.
        let growthStep: CGFloat

        init(panelHeightFraction: CGFloat,
             maximumImageGrowth: CGFloat,
             growthStep: CGFloat) {
            self.panelHeightFraction = panelHeightFraction
            self.maximumImageGrowth = maximumImageGrowth
            self.growthStep = growthStep
        }

        /// The three numbers a session's config carries.
        init(config: LiveTranslateConfig) {
            self.init(panelHeightFraction: CGFloat(config.focusPanelHeightFraction),
                      maximumImageGrowth: CGFloat(config.focusImageMaxGrowth),
                      growthStep: CGFloat(config.focusPanelGrowthStep))
        }

        /// The shipped numbers, for a caller with no config in hand (a
        /// preview, a test of the arithmetic itself).
        static let shipped = Rule(config: LiveTranslateConfig.default)
    }

    /// The height the crop is drawn at, in points. Always ≤ the container's
    /// height minus the panel's floor.
    let imageHeight: CGFloat

    /// The height the panel is drawn at, in points. Never less than the
    /// container could give it, and never more than the rule's allowance.
    let panelHeight: CGFloat

    /// Whether the panel's content is taller than `panelHeight` — so the panel
    /// scrolls, and nothing is truncated or shrunk to avoid it.
    let panelScrolls: Bool

    /// Whether this layout is usable at all: a container or a picture with no
    /// extent is a view that has not been laid out yet, and the honest answer
    /// for it is an empty layout rather than a guess.
    var isUsable: Bool { imageHeight > 0 || panelHeight > 0 }

    /// The rule, resolved.
    ///
    /// - Parameters:
    ///   - containerSize: the space the composition is drawn in, in points.
    ///   - imageSize: the crop's own pixel size (the capture's
    ///     `framePixelSize` — the picture is drawn at the container's scale,
    ///     so only the *aspect* of this matters).
    ///   - panelContentHeight: what the panel's content needs to be shown
    ///     whole, in points. The caller measures this; a value of zero is the
    ///     honest answer for a first pass before the content has been laid
    ///     out, and yields the picture's aspect-fit size with an allowance
    ///     that is never negative.
    ///   - minimumPanelHeight: the floor the picture may not eat into — the
    ///     room one row needs at the type floors. The picture is grown to buy
    ///     the panel room, and this is what stops that trade from being made
    ///     at the reader's expense.
    ///   - columnSpacing: the gap the column draws **between** the picture and
    ///     the panel, in points. It is part of the arithmetic rather than the
    ///     view's business (review finding 14): the two heights and the gap
    ///     are one column, so a rule that bounded the heights by the whole
    ///     container left a saturated layout one gap taller than the glass —
    ///     and the top of the picture, which is where the elder's subject
    ///     usually is, went off it.
    ///   - rule: the three numbers this rule is resolved with, from the
    ///     session's config.
    static func resolve(containerSize: CGSize,
                        imageSize: CGSize,
                        panelContentHeight: CGFloat,
                        minimumPanelHeight: CGFloat,
                        columnSpacing: CGFloat = 0,
                        rule: Rule = .shipped) -> LiveTranslateFocusLayout {
        let containerHeight = containerSize.height
        let containerWidth = containerSize.width
        // Nothing to lay out: a zero container (a first pass under SwiftUI's
        // zero proposal) or a picture with no extent.
        guard containerHeight > 0, containerWidth > 0,
              imageSize.width > 0, imageSize.height > 0 else {
            return LiveTranslateFocusLayout(imageHeight: 0,
                                            panelHeight: 0,
                                            panelScrolls: true)
        }

        // What the column has to divide: the container, less the gap it draws
        // between its two elements. Never negative — a gap larger than the
        // glass is a layout with nothing in it, not a negative one.
        let spacing = min(max(0, columnSpacing), containerHeight)
        let available = containerHeight - spacing
        // The floor is itself bounded by what the column has: a floor taller
        // than the screen would push the picture to a negative height, and a
        // negative frame is a crash waiting for a small enough window rather
        // than a rule.
        let floor = min(max(0, minimumPanelHeight), available)
        // What the picture may take: the column minus the floor. This is rule
        // 3, applied before the picture is measured at all.
        let imageCeiling = available - floor
        // The aspect-fit height — the picture as the elder would see it with
        // no panel under it at all (contained in *both* axes: a wide picture
        // is bounded by the width, which is what `.fill` then spends).
        let fitScale = min(containerWidth / imageSize.width,
                           available / imageSize.height)
        let baseHeight = imageSize.height * fitScale

        // The panel a picture of this height resolves to: rule 1's bound,
        // raised to rule 3's floor (the two disagree only in a container too
        // small for both, and legibility is the one that wins), and finally
        // bounded by what the column has left. One function, because the
        // search below has to ask "did this step buy anything?" of exactly
        // the number the caller will get.
        func panelHeight(forImageHeight height: CGFloat) -> CGFloat {
            let allowance = height * rule.panelHeightFraction
            let ceiling = max(0, available - height)
            return min(max(allowance, floor), ceiling)
        }

        // Rule 2: the smallest growth in [1, cap] that buys the panel enough
        // room — and **no step that buys nothing** (review finding 5). The
        // search stops the moment a further step cannot raise the resolved
        // panel: once the floor or the column's remainder pins it, growing the
        // picture enlarges the evidence and clips its edges for no answer's
        // sake at all.
        //
        // Counted in whole steps and *clamped to the cap* rather than walked
        // with `stride(through:by:)`: `1 + 0.05 * 8` is not exactly 1.4 in
        // binary floating point, so a stride's last value lands on 1.35 and
        // the rule's own ceiling becomes unreachable — growth would stop short
        // of the one number the rule names.
        let stepCount = max(1, Int(((rule.maximumImageGrowth - 1) / rule.growthStep).rounded()))
        var imageHeight = min(baseHeight, imageCeiling)
        var panel = panelHeight(forImageHeight: imageHeight)
        if panel < panelContentHeight {
            for index in 1...stepCount {
                let factor = min(1 + CGFloat(index) * rule.growthStep, rule.maximumImageGrowth)
                let candidate = min(baseHeight * factor, imageCeiling)
                let candidatePanel = panelHeight(forImageHeight: candidate)
                // Growth that cannot raise the panel is growth the elder pays
                // for with picture and gets nothing back.
                guard candidatePanel > panel else { break }
                imageHeight = candidate
                panel = candidatePanel
                if panel >= panelContentHeight { break }
            }
        }
        return LiveTranslateFocusLayout(imageHeight: imageHeight,
                                        panelHeight: panel,
                                        panelScrolls: panel < panelContentHeight)
    }
}
