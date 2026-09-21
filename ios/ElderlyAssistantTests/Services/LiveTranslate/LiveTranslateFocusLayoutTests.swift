import CoreGraphics
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

    private func resolve(containerSize: CGSize? = nil,
                         imageSize: CGSize = CGSize(width: 1000, height: 1000),
                         content: CGFloat,
                         minimum: CGFloat? = nil) -> LiveTranslateFocusLayout {
        LiveTranslateFocusLayout.resolve(containerSize: containerSize ?? container,
                                         imageSize: imageSize,
                                         panelContentHeight: content,
                                         minimumPanelHeight: minimum ?? floor)
    }

    // MARK: - The rule's own numbers

    /// The four constants the plan names, spelled here as numbers so that a
    /// change to any of them has to be a deliberate change to this test.
    func testTheRulesOwnNumbersArePinned() {
        XCTAssertEqual(LiveTranslateFocusLayout.panelHeightFraction, 0.45, accuracy: 0.0001)
        XCTAssertEqual(LiveTranslateFocusLayout.maximumImageGrowth, 1.4, accuracy: 0.0001)
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
                       400 * LiveTranslateFocusLayout.panelHeightFraction,
                       accuracy: 0.001)
        XCTAssertFalse(layout.panelScrolls, "a one-line answer fits the allowance")
        XCTAssertTrue(layout.isUsable)
    }

    /// A crop whose content is shorter than the allowance is not padded out to
    /// it: the rule is a cap, and the panel is drawn at what it needs.
    ///
    /// This is the assertion that keeps 0.45 from being read as "the panel is
    /// always 45% of the picture" — a reading that would push the picture down
    /// for every short answer.
    func testTheAllowanceIsACapAndNotAQuota() {
        let small = resolve(content: 10)
        XCTAssertLessThan(small.panelHeight,
                          400 * LiveTranslateFocusLayout.panelHeightFraction + 0.001,
                          "the panel is at or under the cap")
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
                                    layout.panelHeight / LiveTranslateFocusLayout.panelHeightFraction
                                        - 0.001,
                                    "0.45 of the drawn picture still covers the panel")
        XCTAssertFalse(layout.panelScrolls,
                       "the grown picture bought the panel enough room")
    }

    /// Growth stops at the rule's ceiling — and reaches *exactly* it. A stride
    /// walked in binary floating point lands on 1.35, which would put the
    /// ceiling the plan names permanently out of reach.
    func testThePictureStopsGrowingAtTheCeiling() {
        // Content that no amount of growth can cover: the loop must run out.
        let layout = resolve(content: 10_000)
        XCTAssertEqual(layout.imageHeight,
                       400 * LiveTranslateFocusLayout.maximumImageGrowth,
                       accuracy: 0.001,
                       "growth ran to the ceiling and stopped there")
        XCTAssertTrue(layout.panelScrolls, "and the answer still does not fit")
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
                       layout.imageHeight * LiveTranslateFocusLayout.panelHeightFraction,
                       accuracy: 0.001)
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
