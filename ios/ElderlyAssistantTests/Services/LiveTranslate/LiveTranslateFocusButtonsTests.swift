import SwiftUI
import XCTest
@testable import ElderlyAssistant

/// [FOCUS-BUTTONS] The anchored box's two actions (Workstream B, item 2).
///
/// The focused read made the anchored box a *target* as well as a pointer, so
/// the box now offers two questions at the moment the elder points: "translate
/// this" and "what is it?". Neither is hidden behind a mode — a mode is a thing
/// the elder has to remember — which makes the **row** the thing to prove:
///
///  1. **Two actions, side by side, under the box** — and nowhere else on the
///     glass. Two capsules and one have the same ink bounds, so the run count
///     along the row's own line is the claim, not the bounding box.
///  2. **It cannot leave the glass.** The row is wider than the box it belongs
///     to, so it is *not* simply offset to the box's leading edge: it is given
///     the container's width and aligned to the half the anchor is in. The
///     right-edge case below is the failure that decision exists to prevent.
///  3. **The box stays a pointer.** A stroke, not a fill: the picture under it
///     is the thing the elder tapped, and a control drawn *inside* it would be
///     drawn over the object it acts on.
///  4. **The touch and the words are one path.** The wiring is a claim about
///     code, so it is scanned: the overlay hands the box's first action out,
///     and the session view routes that parameter to the same
///     `translateFocusedRegion` the spoken "translate here" calls.
///
/// The rendering is `OverlayRenderProbe`'s, so what is measured is what the
/// elder can see — a unit-test host vends no accessibility tree, and a test
/// that reached for one would assert on an empty tree and pass for the wrong
/// reason.
final class LiveTranslateFocusButtonsTests: XCTestCase {

    private let nepali = Locale(identifier: "ne-NP")
    private let container = CGSize(width: 390, height: 844)

    /// The whole frame drawn into the whole glass — the identity mapping, so a
    /// box's container rect is its normalized box scaled by the container and
    /// nothing else.
    private var presentation: LiveCameraPresentation {
        LiveCameraPresentation(crop: .whole,
                               pictureRect: CGRect(origin: .zero, size: container))
    }

    private func surface(box: NormalizedBox) -> PointAskOverlaySurface {
        PointAskOverlaySurface(box: box,
                               state: .box,
                               chipLabel: L10n.str("pointask.chip.label", locale: nepali),
                               cardLines: [])
    }

    /// The box, drawn the way the overlay draws it. The trailing frame is not
    /// decoration: the overlay places this view in a `topLeading` `ZStack`
    /// inside its `GeometryReader`, so a container-space offset is a
    /// container-space position. Without it the box's own small stack would be
    /// centred in the glass and every rect measured below would be measured
    /// from the wrong origin.
    @MainActor
    private func render(box: NormalizedBox, bottomInset: CGFloat = 0) throws -> UIImage {
        let view = PointAskOverlayBoxView(
            surface: surface(box: box),
            presentation: presentation,
            onChipTap: {},
            containerSize: container,
            bottomInset: bottomInset,
            translateLabel: L10n.str(PointAskOverlayBoxView.translateKey, locale: nepali),
            onTranslateTap: {})
            .frame(width: container.width, height: container.height, alignment: .topLeading)
        return try XCTUnwrap(OverlayRenderProbe.render(view, size: container),
                             "the anchored box must render")
    }

    /// Everything below the box's own bottom edge — where its actions hang.
    /// Scanned wide (the anchor may be anywhere) and tall: copy that must wrap
    /// wraps rather than truncating, so the row's height is not a constant.
    private func regionUnder(_ box: NormalizedBox) -> CGRect {
        let boxRect = presentation.containerRect(ofFrameBox: box)
        return CGRect(x: 0, y: boxRect.maxY,
                      width: container.width, height: container.height - boxRect.maxY)
    }

    /// Where the row may be: the glass less one edge inset on each side, from
    /// the box's bottom edge down. This is the row's own clamp, and the rect
    /// the "nothing is drawn outside it" claim is measured against.
    private func rowClamp(_ box: NormalizedBox) -> CGRect {
        let boxRect = presentation.containerRect(ofFrameBox: box)
        return CGRect(x: DesignTokens.interElementSpacing,
                      y: boxRect.maxY,
                      width: container.width - 2 * DesignTokens.interElementSpacing,
                      height: container.height - boxRect.maxY)
    }

    /// The line the two actions are counted on: the vertical middle of what the
    /// row actually drew, rather than an assumed offset — the row's height
    /// depends on how the copy wraps in the active language, and a scan line at
    /// a guessed y would count zero runs and pass for the wrong reason.
    private func rowMiddle(of image: UIImage,
                           under box: NormalizedBox) throws -> (y: CGFloat, ink: OverlayRenderProbe.Ink) {
        let ink = try OverlayRenderProbe.ink(in: image, within: regionUnder(box))
        XCTAssertFalse(ink.isEmpty, "the anchored box drew no actions under it")
        return (CGFloat(ink.minY + ink.maxY) / (2 * image.scale), ink)
    }

    private func actionsOnRow(of image: UIImage, under box: NormalizedBox) throws -> Int {
        let middle = try rowMiddle(of: image, under: box)
        let region = regionUnder(box)
        return try OverlayRenderProbe.inkRunCount(in: image, atY: middle.y,
                                                  from: region.minX, to: region.maxX)
    }

    // MARK: - The two actions

    /// An anchor in the left half: the box, and the two actions under it, on
    /// the glass and on nothing else.
    @MainActor
    func testAnAnchoredBoxOffersTwoActionsUnderIt() throws {
        let box = NormalizedBox(xMin: 0.1, yMin: 0.2, xMax: 0.5, yMax: 0.3)
        let image = try render(box: box)
        let boxRect = presentation.containerRect(ofFrameBox: box)

        XCTAssertEqual(boxRect.minX, 39, accuracy: 0.5, "the box maps through the presentation")

        // **Two** actions, not one: the row's own line is crossed by two drawn
        // runs, and the gap between them is the space between two controls.
        XCTAssertEqual(try actionsOnRow(of: image, under: box), 2,
                       "the anchored box offers exactly two actions, side by side")

        // And they hang from the anchor rather than floating down the glass.
        let middle = try rowMiddle(of: image, under: box)
        XCTAssertLessThanOrEqual(CGFloat(middle.ink.minY) / image.scale, boxRect.maxY + 4,
                                 "the actions hang from the box's own bottom edge")

        // Nothing is drawn anywhere else: every drawn pixel is the box's own
        // stroke or the row under it — so neither action can be pushed off the
        // glass, nor painted over the picture the elder is reading.
        try OverlayRenderProbe.assertInkInside(image,
                                               rect: boxRect,
                                               allowed: [rowClamp(box)],
                                               message: "the box and its two actions are the "
                                                      + "whole of what this surface draws")
    }

    /// The right edge of the glass — the case the row's alignment exists for.
    /// An anchor near the edge is where a row offset to the box's leading edge
    /// would push the second action off the screen; the row is instead laid
    /// against the whole glass and aligned to the half the anchor is in.
    @MainActor
    func testARowOnARightEdgeAnchorStaysOnTheGlass() throws {
        let box = NormalizedBox(xMin: 0.6, yMin: 0.2, xMax: 0.95, yMax: 0.3)
        let image = try render(box: box)
        let boxRect = presentation.containerRect(ofFrameBox: box)

        XCTAssertGreaterThan(boxRect.midX, container.width / 2,
                             "this anchor is in the right half, or the case is not the case")
        XCTAssertEqual(try actionsOnRow(of: image, under: box), 2,
                       "both actions are still drawn at the glass's edge")
        try OverlayRenderProbe.assertInkInside(image,
                                               rect: boxRect,
                                               allowed: [rowClamp(box)],
                                               message: "the row is clamped into the glass, not "
                                                      + "pushed off it by the anchor's edge")
    }

    /// The row follows the anchor's side of the glass: a right-half anchor puts
    /// the actions to the right, a left-half anchor to the left. Measured on
    /// the row's own line, so the box's stroke — which sits above it — cannot
    /// be mistaken for the row's leading edge.
    @MainActor
    func testTheActionsStayOnTheSideOfTheThingTheyActOn() throws {
        let left = NormalizedBox(xMin: 0.1, yMin: 0.2, xMax: 0.5, yMax: 0.3)
        let right = NormalizedBox(xMin: 0.6, yMin: 0.2, xMax: 0.95, yMax: 0.3)
        let leftImage = try render(box: left)
        let rightImage = try render(box: right)

        func rowInk(_ image: UIImage, _ box: NormalizedBox) throws -> OverlayRenderProbe.Ink {
            let middle = try rowMiddle(of: image, under: box)
            return try OverlayRenderProbe.ink(in: image,
                                              within: CGRect(x: 0, y: middle.y - 2,
                                                             width: container.width, height: 4))
        }

        let leftInk = try rowInk(leftImage, left)
        let rightInk = try rowInk(rightImage, right)
        XCTAssertGreaterThan(rightInk.minX, leftInk.minX + 2,
                             "the actions stay on the side of the thing they act on")
    }

    /// The box is the elder's pointer, not a control: a stroke, so the object
    /// they pointed at is still readable through it. A control drawn *inside*
    /// the box would cover exactly the thing it was asked about.
    @MainActor
    func testTheBoxItselfIsAStrokeAndNotAButton() throws {
        let box = NormalizedBox(xMin: 0.1, yMin: 0.2, xMax: 0.5, yMax: 0.3)
        let image = try render(box: box)
        let boxRect = presentation.containerRect(ofFrameBox: box)

        // Inset past the stroke's own width: what is left is the box's inside,
        // and nothing is drawn there.
        let interior = boxRect.insetBy(dx: PointAskOverlayBoxView.boxLineWidth * 2,
                                       dy: PointAskOverlayBoxView.boxLineWidth * 2)
        XCTAssertTrue(try OverlayRenderProbe.ink(in: image, within: interior).isEmpty,
                      "the box is a stroke: the picture under it is the thing the elder tapped")
        XCTAssertGreaterThan(try OverlayRenderProbe.ink(in: image, within: boxRect).count, 0,
                             "and it is drawn — an invisible box would make the two actions "
                             + "unplaceable rather than honest")
    }

    // MARK: - The two controls, and the one label

    /// The two actions are distinct controls with distinct identifiers, and the
    /// translation's words are the catalog's — resolved by the caller that
    /// knows the active language, never minted in the view.
    @MainActor
    func testTheTwoActionsAreDistinctControlsWithOneCatalogBackedLabel() {
        XCTAssertNotEqual(PointAskOverlayBoxView.translateIdentifier,
                          PointAskOverlayBoxView.chipIdentifier)
        XCTAssertEqual(PointAskOverlayBoxView.chipIdentifier, "pointask.chip",
                       "the object question keeps the shipped identifier the UI tests know")
        XCTAssertEqual(PointAskOverlayBoxView.translateKey, "livetranslate.focus.translate")

        let english = Locale(identifier: "en-US")
        for locale in [nepali, english] {
            XCTAssertFalse(L10n.str(PointAskOverlayBoxView.translateKey, locale: locale).isEmpty,
                           "the translate action has no copy in \(locale)")
            XCTAssertFalse(L10n.str("pointask.chip.label", locale: locale).isEmpty,
                           "the object question has no copy in \(locale)")
        }
        XCTAssertNotEqual(L10n.str(PointAskOverlayBoxView.translateKey, locale: nepali),
                          L10n.str(PointAskOverlayBoxView.translateKey, locale: english),
                          "the row is drawn in the active language, not in English twice")
    }

    // MARK: - Where the row goes (review finding 7)

    /// The row hangs under the anchor while the glass has room for it: its top
    /// edge is the box's bottom edge plus the gap, exactly — the row and the
    /// thing it acts on read as one object.
    func testTheRowHangsUnderTheAnchorWhenTheGlassHasRoom() {
        let boxRect = CGRect(x: 39, y: 169, width: 156, height: 84)
        let origin = PointAskOverlayBoxView.actionRowOriginY(below: boxRect,
                                                             containerHeight: 844,
                                                             bottomInset: 34,
                                                             rowHeight: 48,
                                                             spacing: 8)
        XCTAssertEqual(origin, boxRect.maxY + 8, accuracy: 0.001)
    }

    /// An anchor near the floor **flips the row above itself** rather than
    /// sliding it up over the box or pushing it under the home indicator.
    ///
    /// The offset this replaced was `min(boxRect.maxY + spacing, boxRect.maxY)`
    /// — `boxRect.maxY` for every input, a clamp that clamped nothing — so a
    /// low anchor put both actions in the indicator's strip, half off the
    /// usable glass. The floor is `containerHeight - bottomInset`.
    func testAnAnchorNearTheFloorFlipsTheRowAboveItself() {
        let boxRect = CGRect(x: 39, y: 740, width: 156, height: 60)
        let origin = PointAskOverlayBoxView.actionRowOriginY(below: boxRect,
                                                             containerHeight: 844,
                                                             bottomInset: 34,
                                                             rowHeight: 48,
                                                             spacing: 8)
        XCTAssertLessThan(origin, boxRect.minY,
                          "the row is above the anchor, not over it and not under the glass")
        XCTAssertLessThanOrEqual(origin + 48, boxRect.minY - 8 + 0.001,
                                 "and it clears the anchor by the same gap it would have hung by")
        XCTAssertLessThanOrEqual(origin + 48, 844 - 34 + 0.001,
                                 "nothing of the row is in the home indicator's strip")
    }

    /// A glass too short for two rows and an anchor takes the top of the glass:
    /// **on screen** beats perfectly placed, and a negative origin — a row drawn
    /// above the top edge, where nobody can tap it — is never the answer.
    func testACrowdedGlassPutsTheRowAtTheTopRatherThanAboveIt() {
        let boxRect = CGRect(x: 0, y: 30, width: 100, height: 40)
        let origin = PointAskOverlayBoxView.actionRowOriginY(below: boxRect,
                                                             containerHeight: 90,
                                                             bottomInset: 34,
                                                             rowHeight: 48,
                                                             spacing: 8)
        XCTAssertGreaterThanOrEqual(origin, 0, "a row above the glass is an untappable row")
        XCTAssertEqual(origin, 0, accuracy: 0.001, "the last resort is the top of the glass")
    }

    /// A box in the bottom half of the glass: the row is drawn **above** it, so
    /// the two actions are not sitting on the home indicator's strip. Measured
    /// on the drawing, not on the arithmetic: the row's clamp is only worth
    /// anything if the offset it produces is what reaches the glass.
    @MainActor
    func testARowUnderALowAnchorIsDrawnAboveItAndAboveTheStrip() throws {
        let box = NormalizedBox(xMin: 0.1, yMin: 0.88, xMax: 0.5, yMax: 0.95)
        let boxRect = presentation.containerRect(ofFrameBox: box)
        let floor = container.height - safeBottom
        let image = try render(box: box, bottomInset: safeBottom)

        // Nothing at all is drawn in the home indicator's strip.
        XCTAssertTrue(try OverlayRenderProbe.ink(in: image,
                                                 within: CGRect(x: 0, y: floor,
                                                                width: container.width,
                                                                height: container.height - floor))
                        .isEmpty,
                      "the strip below the safe area is left to the system")

        // And the actions are above the box: the region between the top of the
        // glass and the anchor's top edge carries the row's ink.
        let above = try OverlayRenderProbe.ink(in: image,
                                               within: CGRect(x: 0, y: 0,
                                                              width: container.width,
                                                              height: boxRect.minY))
        XCTAssertFalse(above.isEmpty, "the row flipped above the anchor and was drawn")
        let middle = CGFloat(above.minY + above.maxY) / (2 * image.scale)
        XCTAssertEqual(try OverlayRenderProbe.inkRunCount(in: image, atY: middle,
                                                          from: 0, to: container.width),
                       2,
                       "both actions came with it")
    }

    /// The strip the tests reserve: one home indicator, as a `GeometryProxy`
    /// reports it on the phones this screen is designed for.
    private var safeBottom: CGFloat { 34 }

    // MARK: - The wiring (a claim about code, so it is scanned)

    /// **The touch and the words are one path.** The overlay hands the box's
    /// first action out as its own parameter, so the host decides what it
    /// means; the session view routes that parameter to the same
    /// `translateFocusedRegion(box:pixelRect:measuredOn:)` the spoken command
    /// calls, measured on the anchored frame — the live picture the box is
    /// drawn on, not a rect held from the tap that anchored it.
    @MainActor
    func testTheOverlaysFirstActionRoutesToTheFocusPath() throws {
        let root = FeatureSourceScan.iosDirectory()

        let overlay = FeatureSourceScan.codeText(of: root
            .appendingPathComponent("ElderlyAssistant/App/LiveTranslate/"
                                    + "LiveTranslateOverlayView.swift"))
        for pattern in [#"translateLabel: L10n\.str\(PointAskOverlayBoxView\.translateKey,"#,
                        #"onTranslateTap: onPointAskTranslateTap\)"#] {
            XCTAssertNotNil(FeatureSourceScan.firstMatch(of: pattern, in: overlay),
                            "the overlay draws the catalog's label and hands the action out: "
                            + "\(pattern)")
        }

        let view = FeatureSourceScan.codeText(of: root
            .appendingPathComponent("ElderlyAssistant/App/LiveTranslate/"
                                    + "LiveTranslateView.swift"))
        for pattern in [#"onPointAskTranslateTap: \{"#,
                        #"guard let target = model\.pointAsk\?\.anchoredTarget else \{ return \}"#,
                        #"model\.translateFocusedRegion\(box: target\.box,"#,
                        #"measuredOn: model\.anchoredFrame\)"#] {
            XCTAssertNotNil(FeatureSourceScan.firstMatch(of: pattern, in: view),
                            "the session view routes the touch to the focused read: \(pattern)")
        }
    }
}
