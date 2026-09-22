import CoreGraphics
import SwiftUI
import XCTest
@testable import ElderlyAssistant

/// [FOCUS-CAPTURE] The focused read's layout rule, pinned as arithmetic.
///
/// The plan asks for four things of this screen, and each of them is a way the
/// answer could be lost while the picture still looked fine:
///
///  1. The panel is **bounded by the picture** — at most 0.45 of the height the
///     crop is drawn at, because the picture is the reason the elder raised
///     the phone.
///  2. The picture **grows to buy the panel room**, up to 1.4× and no further.
///  3. It never grows so far that the panel falls below what one legible row
///     needs — legibility is a floor, not a preference.
///  4. What still does not fit **scrolls**; nothing is truncated and no type is
///     shrunk.
///
/// The suite asserts the rule's own numbers, not just its behaviour, because
/// the numbers *are* the rule: a 0.45 that quietly became 0.6, or a 1.4 that
/// became 2.0, would leave every "the panel fits" assertion below still green.
/// `testTheRulesOwnNumbersArePinned` is the one that fails if the plan is
/// edited by accident.
final class LiveTranslateFocusLayoutTests: XCTestCase {

    /// A phone-sized container, the shape this screen is designed for.
    private let container = CGSize(width: 400, height: 800)
    /// The floor the real view passes: one row at the app's type floors.
    private var floor: CGFloat { LiveTranslateFocusResultView.minimumPanelHeight }

    /// The rule every resolution below is asked for **explicitly**. The numbers
    /// live on `Rule` because they are config parameters (review finding: the
    /// injected config on the surface path), so the suite reads them from a rule
    /// it names rather than from statics that no longer exist — and the same
    /// value is what a production caller gets from its own config.
    private let rule = LiveTranslateFocusLayout.Rule.shipped

    private func resolve(containerSize: CGSize? = nil,
                         imageSize: CGSize = CGSize(width: 1000, height: 1000),
                         content: CGFloat,
                         minimum: CGFloat? = nil,
                         rule: LiveTranslateFocusLayout.Rule? = nil) -> LiveTranslateFocusLayout {
        LiveTranslateFocusLayout.resolve(containerSize: containerSize ?? container,
                                         imageSize: imageSize,
                                         panelContentHeight: content,
                                         minimumPanelHeight: minimum ?? floor,
                                         rule: rule ?? self.rule)
    }

    // MARK: - The rule's own numbers

    /// The rule's numbers, spelled here as numbers so that a change to any of
    /// them has to be a deliberate change to this test. The **growth step** is
    /// one of them (review finding: the stride the loop walks is a config
    /// parameter like the other two, so it is pinned like the other two — a
    /// step that quietly doubled would still satisfy every "the picture grew"
    /// assertion below).
    func testTheRulesOwnNumbersArePinned() {
        XCTAssertEqual(rule.panelHeightFraction, 0.45, accuracy: 0.0001)
        XCTAssertEqual(rule.maximumImageGrowth, 1.4, accuracy: 0.0001)
        XCTAssertEqual(rule.growthStep, 0.05, accuracy: 0.0001)
    }

    /// The shipped rule **is the shipped config's**, not a second spelling of
    /// the same numbers (review finding: the injected config on the layout
    /// path). A session builds its rule from its own config
    /// (`LiveTranslateSessionModel.focusRule`), so a config a suite drives has
    /// to be the config that draws; `.shipped` is only what stands in for a
    /// preview or a test with no session.
    func testTheShippedRuleIsTheConfigsOwnNumbers() {
        XCTAssertEqual(rule, LiveTranslateFocusLayout.Rule(config: LiveTranslateConfig.default))
        XCTAssertEqual(rule.panelHeightFraction,
                       LiveTranslateConfig.default.focusPanelHeightFraction,
                       accuracy: 0.0001)
        XCTAssertEqual(rule.growthStep,
                       LiveTranslateConfig.default.focusPanelGrowthStep,
                       accuracy: 0.0001)
        XCTAssertEqual(rule.maximumImageGrowth,
                       LiveTranslateConfig.default.focusImageMaxGrowth,
                       accuracy: 0.0001)
    }

    /// A rule built from a config is **that** config's: the numbers a suite
    /// arranges are the numbers the surface is drawn with, which is the whole
    /// point of carrying the rule rather than reading the default at draw time.
    func testARuleIsBuiltFromTheConfigItIsGiven() {
        var config = LiveTranslateConfig()
        config.focusPanelHeightFraction = 0.3
        config.focusPanelGrowthStep = 0.2
        config.focusImageMaxGrowth = 2.0

        let sessionRule = LiveTranslateFocusLayout.Rule(config: config)

        XCTAssertEqual(sessionRule.panelHeightFraction, 0.3, accuracy: 0.0001)
        XCTAssertEqual(sessionRule.growthStep, 0.2, accuracy: 0.0001)
        XCTAssertEqual(sessionRule.maximumImageGrowth, 2.0, accuracy: 0.0001)
        XCTAssertNotEqual(sessionRule, rule)
    }

    /// The floor is the app's own type tokens, not a literal of this screen's:
    /// one caption line (the original) plus one body line (the translation)
    /// plus the padding the card puts round them.
    func testTheLegibilityFloorIsMadeOfTheAppsOwnTypeTokens() {
        let expected = DesignTokens.minCaptionPointSize
            + DesignTokens.minBodyPointSize
            + DesignTokens.interElementSpacing * 4
        XCTAssertEqual(LiveTranslateFocusResultView.minimumPanelHeight,
                       expected,
                       accuracy: 0.0001)
        // And it is a floor worth having: taller than a single body line, so a
        // row cannot be squeezed to nothing and still satisfy the rule.
        XCTAssertGreaterThan(LiveTranslateFocusResultView.minimumPanelHeight,
                             DesignTokens.minBodyPointSize)
    }

    // MARK: - Rule 1: the panel is bounded by the picture

    /// A square crop in a taller container is drawn at the container's width,
    /// and the panel takes exactly 0.45 of that — no more, even with room to
    /// spare.
    func testThePanelIsBoundedByThePicture() {
        let layout = resolve(content: 10)
        // 400pt wide container, square picture: aspect-fit height is the width.
        XCTAssertEqual(layout.imageHeight, 400, accuracy: 0.001)
        XCTAssertEqual(layout.panelHeight,
                       400 * rule.panelHeightFraction,
                       accuracy: 0.001)
        XCTAssertFalse(layout.panelScrolls, "a one-line answer fits the allowance")
        XCTAssertTrue(layout.isUsable)
    }

    /// A crop whose content is shorter than the allowance is **not paid more
    /// than the cap**: the panel's grant is the allowance and not a point over
    /// it, and the picture keeps its aspect-fit height — a short answer does not
    /// push the picture down to make the panel look filled.
    ///
    /// **Pinned strictly** (review finding: the cap test's slack). The old
    /// assertion was `panelHeight < cap + 0.001`, which a rule that paid out
    /// `cap + 0.0005` for every short answer — or one that let the allowance
    /// drift with the content — would have satisfied. There is now no tolerance
    /// at all on the bound: the panel is the allowance, and it is `<=` the
    /// allowance the caller can compute for itself.
    ///
    /// The distinction this test draws is between the *grant* and the *content*:
    /// the grant is the rule's allowance — the bounded frame the view hands the
    /// card, and the height the column has to find — while the card inside it
    /// draws its own rows and scrolls if they do not fit. What must never happen
    /// is the grant itself exceeding 0.45 of the picture, and that is what is
    /// asserted here, tightly: the panel is the allowance and not a point more.
    /// Whether the card fills its frame or sits short inside it is
    /// `LiveTranslateResultsCardView`'s business, not this rule's — the rule's
    /// promise is only that the panel is never given more of the picture than
    /// 0.45, and that a short answer never grows the picture to make the panel
    /// look filled (`imageHeight` stays at the aspect-fit 400).
    func testTheAllowanceIsACapAndNotAQuota() {
        let small = resolve(content: 10)
        XCTAssertEqual(small.panelHeight, 400 * rule.panelHeightFraction,
                       accuracy: 0.001,
                       "the panel's grant is the allowance exactly")
        XCTAssertLessThanOrEqual(small.panelHeight, 400 * rule.panelHeightFraction,
                                 "and never a point more — the cap is what its name says")
        XCTAssertFalse(small.panelScrolls, "ten points of content in 180 fits")
        XCTAssertEqual(small.imageHeight, 400, accuracy: 0.001,
                       "and the picture keeps the height the answer did not take")
    }

    // MARK: - Rule 2: the picture grows to buy the panel room

    /// An answer that needs more than 0.45 of the aspect-fit picture makes the
    /// picture grow — the panel's room comes out of the margin, not out of the
    /// reader's type size.
    ///
    /// The answer asked for is 200 pt, and it is asked for on purpose: it is
    /// above the aspect-fit allowance (0.45 × 400 = 180) and it is *reachable*.
    /// A longer one is not reachable in this container by any growth — growing
    /// the picture buys allowance at 180 pt per unit of growth and spends
    /// ceiling at 400 pt per unit, so the two meet at g ≈ 1.379 and the most
    /// any growth can hand the panel is ≈ 248 pt. Asking for 250 would assert
    /// that the rule does the impossible; what it does instead is scroll, and
    /// `testALongAnswerScrollsRatherThanShrinking` is where that is pinned.
    func testThePictureGrowsToBuyThePanelRoom() {
        let base = resolve(content: 10).imageHeight
        let layout = resolve(content: 200)
        XCTAssertGreaterThan(layout.imageHeight, base,
                             "the picture grew rather than the panel shrinking")
        XCTAssertGreaterThan(layout.imageHeight, 400)
        XCTAssertGreaterThanOrEqual(layout.imageHeight,
                                    layout.panelHeight / rule.panelHeightFraction
                                        - 0.001,
                                    "0.45 of the drawn picture still covers the panel")
        XCTAssertFalse(layout.panelScrolls,
                       "the grown picture bought the panel enough room")
    }

    /// Growth stops at the rule's ceiling — and reaches *exactly* it. A stride
    /// walked in binary floating point lands on 1.35, which would put the
    /// ceiling the plan names permanently out of reach.
    ///
    /// The crop is a **wide** one on purpose. Growth is bounded twice: by the
    /// rule's 1.4× and by what the column has left (`available - height`, which
    /// falls as the picture rises). For a *square* crop in this container the
    /// second bound bites first — at ≈552 pt, under the 560 the ceiling names —
    /// so no square crop can ever be drawn at 1.4×, and asserting that it is
    /// would be asserting arithmetic this rule does not do (review finding 5:
    /// the search stops when a step cannot raise the panel). What the ceiling
    /// governs is a picture small enough that 1.4× of it still leaves the panel
    /// room: a 1000×900 crop fits the width at 360 pt, its 1.4× is 504, and
    /// that is the binding constraint. The square case is pinned separately, in
    /// `testGrowthStopsAtTheCrossoverWhenTheColumnBindsFirst`, as what it is.
    func testThePictureStopsGrowingAtTheCeiling() {
        let wide = CGSize(width: 1000, height: 900)
        let base = resolve(imageSize: wide, content: 10).imageHeight
        XCTAssertEqual(base, 360, accuracy: 0.001,
                       "the wide crop's aspect-fit height, at the container's width")
        // Content that no amount of growth can cover: the loop must run out.
        let layout = resolve(imageSize: wide, content: 10_000)
        XCTAssertEqual(layout.imageHeight,
                       base * rule.maximumImageGrowth,
                       accuracy: 0.001,
                       "growth ran to the ceiling and stopped there")
        XCTAssertEqual(layout.imageHeight, 504, accuracy: 0.001)
        XCTAssertTrue(layout.panelScrolls, "and the answer still does not fit")
    }

    /// When the column binds before the ceiling does, growth stops at the
    /// **crossover** — the height where 45 % of the picture and the column's
    /// remainder are the same number — and the last step the search refuses is
    /// the one that would have made the answer *shorter* (review finding 5:
    /// growth that cannot raise the resolved panel enlarges the picture and
    /// clips its edges for nothing).
    ///
    /// Both halves are pinned here, because the guard is only honest if the
    /// refused step really was worse: at 1.4× the panel would have been 240 pt
    /// against the 243 the search settled on, so the picture would have spent
    /// twenty more points of glass to give back three of answer.
    func testGrowthStopsAtTheCrossoverWhenTheColumnBindsFirst() {
        let layout = resolve(content: 10_000)
        XCTAssertEqual(layout.imageHeight, 540, accuracy: 0.001,
                       "the last step that bought the panel anything")
        XCTAssertLessThan(layout.imageHeight, 400 * rule.maximumImageGrowth,
                          "the ceiling is not what stopped it — the column was")
        // At the crossover the allowance is exactly what the panel gets: the
        // column's remainder (260) is still the larger of the two.
        XCTAssertEqual(layout.panelHeight,
                       layout.imageHeight * rule.panelHeightFraction,
                       accuracy: 0.001,
                       "the search settled where the allowance and the remainder meet")
        XCTAssertTrue(layout.panelScrolls)

        // The step the guard refused, taken deliberately by a rule that walks
        // straight to the cap: the picture reaches 1.4× and the panel falls.
        let oneStep = LiveTranslateFocusLayout.Rule(panelHeightFraction: rule.panelHeightFraction,
                                                    maximumImageGrowth: rule.maximumImageGrowth,
                                                    growthStep: 0.4)
        let overshot = resolve(content: 10_000, rule: oneStep)
        XCTAssertEqual(overshot.imageHeight, 560, accuracy: 0.001,
                       "a stride that leaps to the cap does reach it")
        XCTAssertLessThan(overshot.panelHeight, layout.panelHeight,
                          "and that is the trade the guard refuses: more picture, less answer")
    }

    /// The picture's growth is bounded by the container as well as by 1.4×: a
    /// picture may never be drawn past the space that exists, so the two
    /// heights together never exceed the screen.
    func testTheTwoHeightsNeverExceedTheContainer() {
        for content in [CGFloat(0), 100, 250, 1_000, 10_000] {
            let layout = resolve(content: content)
            XCTAssertLessThanOrEqual(layout.imageHeight + layout.panelHeight,
                                     container.height + 0.001,
                                     "content \(content) overflowed the container")
        }
    }

    // MARK: - Rule 3: legibility is a floor

    /// A crop taller than the screen — the case that would otherwise give the
    /// picture everything — still leaves the panel exactly its floor.
    func testThePictureNeverEatsTheLegibilityFloor() {
        let layout = resolve(imageSize: CGSize(width: 1000, height: 4000), content: 10)
        XCTAssertEqual(layout.panelHeight, floor, accuracy: 0.001)
        XCTAssertLessThanOrEqual(layout.imageHeight, container.height - floor + 0.001)
    }

    /// The floor is legibility, not luxury: the panel is never given less than
    /// a row's worth even when the picture would have taken the whole screen.
    func testTheFloorHoldsEvenWhenTheAnswerIsLongerThanTheScreen() {
        let layout = resolve(imageSize: CGSize(width: 1000, height: 4000), content: 5_000)
        XCTAssertGreaterThanOrEqual(layout.panelHeight, floor - 0.001)
        XCTAssertTrue(layout.panelScrolls)
    }

    // MARK: - Rule 4: what does not fit scrolls

    /// A long answer scrolls. It never becomes a truncated row and its type is
    /// never shrunk — the panel simply says there is more below.
    func testALongAnswerScrollsRatherThanShrinking() {
        let short = resolve(content: 40)
        XCTAssertFalse(short.panelScrolls)
        let long = resolve(content: 900)
        XCTAssertTrue(long.panelScrolls)
        // The type floors are not this type's business: it decides heights
        // only, so a scroll can never have been bought by shrinking them.
        XCTAssertGreaterThan(long.panelHeight, 0)
    }

    // MARK: - Degenerate input

    /// A container that has not been laid out yet resolves to nothing rather
    /// than to a guess — SwiftUI proposes zero on the first pass.
    func testAZeroContainerResolvesToNothing() {
        let layout = resolve(containerSize: .zero, content: 100)
        XCTAssertFalse(layout.isUsable)
        XCTAssertEqual(layout.imageHeight, 0)
        XCTAssertEqual(layout.panelHeight, 0)
    }

    /// A picture with no extent is the same honest nothing.
    func testAPictureWithNoExtentResolvesToNothing() {
        let layout = resolve(imageSize: .zero, content: 100)
        XCTAssertFalse(layout.isUsable)
    }

    /// A floor taller than the container cannot push the picture to a negative
    /// height: the clamp is the container's, not the floor's. A negative frame
    /// is a crash on a small enough window, not a rule.
    ///
    /// What that degenerate answer *is*: a floor of 5,000 pt in an 800 pt
    /// container resolves to the container, the picture gets no room at all,
    /// and the panel takes what exists. No scroll is asserted here — a panel
    /// the height of the whole glass showing 100 pt of content has nothing to
    /// scroll, and demanding one would be asserting the glass is smaller than
    /// it is (the scroll case is `testALongAnswerScrollsRatherThanShrinking`).
    func testAnOversizedFloorCannotProduceNegativeHeights() {
        let layout = resolve(content: 100, minimum: 5_000)
        XCTAssertGreaterThanOrEqual(layout.imageHeight, 0)
        XCTAssertGreaterThanOrEqual(layout.panelHeight, 0)
        XCTAssertLessThanOrEqual(layout.imageHeight + layout.panelHeight,
                                 container.height + 0.001,
                                 "the answer is still two heights in one column")
        XCTAssertEqual(layout.panelHeight, container.height, accuracy: 0.001,
                       "the panel takes the room the picture cannot use")
        XCTAssertTrue(layout.isUsable)
    }

    /// A negative or absent content height (the first pass) is treated as
    /// "needs nothing": the picture is not grown for a panel that has not been
    /// measured yet, so the first frame is the picture at its aspect-fit size
    /// and the second settles on the real geometry.
    func testAnUnmeasuredPanelDoesNotGrowThePicture() {
        let first = resolve(content: 0)
        XCTAssertEqual(first.imageHeight, 400, accuracy: 0.001)
        XCTAssertEqual(first.imageHeight, resolve(content: -10).imageHeight, accuracy: 0.001)
    }

    // MARK: - The view's own wiring

    /// The view resolves the rule with the capture's own pixel size and its own
    /// floor — the two things a caller could get wrong by passing the frame's
    /// size, or a literal floor, without any of the assertions above noticing.
    func testTheViewResolvesTheRuleFromTheCapturesOwnPixelSize() {
        let capture = LiveTranslateFocusResultFixture.capture(pixelSize: CGSize(width: 1000, height: 1000))
        let layout = LiveTranslateFocusResultView.layout(for: container,
                                                         capture: capture,
                                                         panelContentHeight: 10)
        XCTAssertEqual(layout.imageHeight, 400, accuracy: 0.001)
        XCTAssertEqual(layout.panelHeight,
                       layout.imageHeight * rule.panelHeightFraction,
                       accuracy: 0.001)
    }

    /// The panel is bottom-anchored, so the **bottom inset is load-bearing**:
    /// without it the last row of the answer lands in the home-indicator strip
    /// (review finding 13). The subtraction is the view's own, on the proxy's
    /// report — asserted here as arithmetic, because the two things that can go
    /// wrong (an inset not subtracted, a sign flipped) are invisible to every
    /// layout assertion above: the rule would resolve perfectly, one strip too
    /// low.
    func testTheSafeAreaIsTakenOutOfTheSpaceTheColumnGets() {
        let insets = EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0)
        let available = LiveTranslateFocusResultView.availableSize(in: container, insets: insets)
        XCTAssertEqual(available.width, 400, accuracy: 0.001)
        XCTAssertEqual(available.height, 800 - 47 - 34, accuracy: 0.001,
                       "the column is the glass less the status bar and the home indicator")

        // And the insets are the difference the *column* sees. The crop here is
        // taller than the glass on purpose: it is the case where the container,
        // rather than 0.45 of the picture, is what bounds the column — so the
        // whole of the inset shows up as a shorter picture-plus-panel column.
        // (A square crop resolves to the same total in both containers: its
        // panel is 0.45 of a picture whose fit is the *width*, and the insets
        // are all height. That equality is the rule working, not the insets
        // being ignored, which is why the discriminator is this crop.)
        let tall = LiveTranslateFocusResultFixture.capture(pixelSize: CGSize(width: 1000, height: 4000))
        let plain = LiveTranslateFocusResultView.layout(for: container,
                                                        capture: tall,
                                                        panelContentHeight: 200)
        let inset = LiveTranslateFocusResultView.layout(for: available,
                                                        capture: tall,
                                                        panelContentHeight: 200)
        // The column is the glass less the gap the picture and the panel draw
        // between them — that gap is part of the rule (`columnSpacing`), so the
        // two heights fill the glass *minus* it and not the glass itself.
        let gap = DesignTokens.interElementSpacing
        XCTAssertEqual(plain.imageHeight + plain.panelHeight,
                       container.height - gap, accuracy: 0.001,
                       "the tall crop fills the glass it was given, less the column's gap")
        XCTAssertEqual(inset.imageHeight + inset.panelHeight,
                       available.height - gap, accuracy: 0.001,
                       "the insets are taken out of the column, not left in the glass")
        XCTAssertLessThan(inset.imageHeight, plain.imageHeight,
                          "and it is the picture that gives the strip up")
    }

    /// A proxy that reports less than its own insets — a view being laid out,
    /// or a caller handing over a square it has already subtracted from — is a
    /// zero, not a negative: a negative height handed to the rule is a frame
    /// of negative height, which is a crash rather than a clip.
    func testInsetsLargerThanTheGlassResolveToNothing() {
        let available = LiveTranslateFocusResultView.availableSize(in: CGSize(width: 10, height: 10),
                                                                  insets: EdgeInsets(top: 60,
                                                                                     leading: 20,
                                                                                     bottom: 60,
                                                                                     trailing: 20))
        XCTAssertEqual(available.width, 0)
        XCTAssertEqual(available.height, 0)
    }

    /// Two resolutions of the same inputs are equal, so a view can tell a
    /// re-layout that moved nothing from one that did — the value is what
    /// SwiftUI compares, and a still hand must answer the same thing.
    ///
    /// The pair is 10 and 200, chosen where the rule actually moves. Two
    /// answers that both saturate (250 and 900, say) resolve to the *same*
    /// geometry — the picture at its ceiling, the panel at the container's
    /// remainder — and that equality is the rule's own answer for two cases it
    /// cannot tell apart, not a defect in the value.
    func testTheResolvedLayoutIsAValue() {
        XCTAssertEqual(resolve(content: 10), resolve(content: 10))
        XCTAssertNotEqual(resolve(content: 10), resolve(content: 200))
    }
}

/// A packed capture for the layout tests. Only the fields the layout reads need
/// to mean anything — a real crop's picture, rows and placement are pinned by
/// `LiveTranslateFocusCaptureTests`, which builds them through the real path.
enum LiveTranslateFocusResultFixture {

    static func capture(pixelSize: CGSize,
                        rows: [LiveTranslateResultsCardSurface.Row] = []) -> LiveTranslateFocusedCapture {
        LiveTranslateFocusedCapture(
            image: image(size: pixelSize),
            framePixelSize: pixelSize,
            pixelRect: CGRect(origin: .zero, size: pixelSize),
            // An empty publication, built through the shipped types rather
            // than by hand: the layout reads the picture's *size*, so the
            // placement and the policy only have to be legal values. The
            // policy comes from the app layer's own factory, because a
            // `Policy` has no defaults on purpose and this suite has no
            // business inventing one.
            publication: LiveTranslatePublication(
                sequence: 1,
                regions: [],
                outcomes: [:],
                placements: [],
                policy: LiveTranslateOverlaySurface.policy(config: .default,
                                                            alwaysShowOriginal: false)),
            rows: rows,
            deferredKeys: [])
    }

    /// A 1×1 opaque device-RGB image. The layout reads only the *aspect* of the
    /// picture, so a small one is a whole picture for this purpose.
    static func image(size: CGSize) -> CGImage {
        let context = CGContext(data: nil,
                                width: max(1, Int(size.width)),
                                height: max(1, Int(size.height)),
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        return context.makeImage()!
    }
}
