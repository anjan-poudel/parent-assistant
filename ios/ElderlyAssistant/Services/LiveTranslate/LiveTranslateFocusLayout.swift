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
//     `panelHeightFraction` (0.45) of the drawn picture's height. The picture
//     is the reason the elder raised the phone; a panel that grew to fill the
//     screen would answer a question about something they can no longer see.
//  2. **The picture may grow to buy the panel room.** When 0.45 of the
//     aspect-fit picture is less than the panel needs, the picture is drawn
//     larger — up to `maximumImageGrowth` (1.4×) — which raises the allowance
//     with it. Growth is *scale*, never a second crop: the picture is drawn
//     through `.fill` and clipped, so growing it discards nothing the elder
//     pointed at (the pixels are all still there), it simply spends screen on
//     the text rather than on the margin around it.
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

    /// The panel's share of the drawn picture's height. A constant with no
    /// token of its own: it is this rule's own number, not a spacing.
    static let panelHeightFraction: CGFloat = 0.45

    /// How much larger than its aspect-fit size the picture may be drawn in
    /// order to buy the panel room.
    ///
    /// Read from the config rather than spelled here: it is an operational
    /// parameter of the feature, and `LiveTranslateConfig` is the one place a
    /// nominal value is spelled (NFR-LCT-011 — the source-hygiene scan fails a
    /// re-declared literal, which is how this one was caught).
    static var maximumImageGrowth: CGFloat {
        CGFloat(LiveTranslateConfig.default.focusImageMaxGrowth)
    }

    /// The growth step the search walks in. Coarse on purpose: the value that
    /// comes out is a screen height, and a hundredth of a point of panel is
    /// not a readability difference — the *floor* is what matters, and the
    /// floor is enforced exactly (see `minimumPanelHeight` below).
    static let growthStep: CGFloat = 0.05

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
    static func resolve(containerSize: CGSize,
                        imageSize: CGSize,
                        panelContentHeight: CGFloat,
                        minimumPanelHeight: CGFloat) -> LiveTranslateFocusLayout {
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

        // The floor is itself bounded by the container: a floor taller than
        // the screen would push the picture to a negative height, and a
        // negative frame is a crash waiting for a small enough window rather
        // than a rule.
        let floor = min(max(0, minimumPanelHeight), containerHeight)
        // What the picture may take: the container minus the floor. This is
        // rule 3, applied before the picture is measured at all.
        let imageCeiling = containerHeight - floor
        // The aspect-fit height — the picture as the elder would see it with
        // no panel under it at all (contained in *both* axes: a wide picture
        // is bounded by the width, which is what `.fill` then spends).
        let fitScale = min(containerWidth / imageSize.width,
                           containerHeight / imageSize.height)
        let baseHeight = imageSize.height * fitScale

        // Rule 2: the smallest growth in [1, 1.4] whose allowance covers the
        // panel's content. Walking upward and stopping at the first that
        // covers it keeps the picture as large as it needs to be and no
        // larger — an elder who does not need the room keeps the picture.
        //
        // Counted in whole steps and *clamped to the cap* rather than walked
        // with `stride(through:by:)`: `1 + 0.05 * 8` is not exactly 1.4 in
        // binary floating point, so a stride's last value lands on 1.35 and
        // the rule's own ceiling becomes unreachable — growth would stop short
        // of the one number the rule names.
        let stepCount = max(1, Int(((Self.maximumImageGrowth - 1) / Self.growthStep).rounded()))
        var growth: CGFloat = 1
        for index in 0...stepCount {
            growth = min(1 + CGFloat(index) * Self.growthStep, Self.maximumImageGrowth)
            let height = min(baseHeight * growth, imageCeiling)
            if height * Self.panelHeightFraction >= panelContentHeight { break }
        }
        let imageHeight = min(baseHeight * growth, imageCeiling)
        // Rule 1's bound, raised to rule 3's floor (the two disagree only in a
        // container too small for both, and legibility is the one that wins),
        // and finally bounded by what the container has left — the two heights
        // are drawn in one column, so the panel may not exceed the remainder.
        let allowance = imageHeight * Self.panelHeightFraction
        let panelCeiling = max(0, containerHeight - imageHeight)
        let panelHeight = min(max(allowance, floor), panelCeiling)
        return LiveTranslateFocusLayout(imageHeight: imageHeight,
                                        panelHeight: panelHeight,
                                        panelScrolls: panelHeight < panelContentHeight)
    }
}
