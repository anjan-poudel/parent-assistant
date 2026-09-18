import SwiftUI
import UIKit
import XCTest
@testable import ElderlyAssistant

/// The green highlight and the gliding box (owner spec, 2026-09-18):
///
/// > "The whole idea was to overlay the extracted OCR text over the text in the
/// > picture, then translate once OCR is solid. Stabilise the extracted text and
/// > stabilise the overlay. The bounding box can be TRANSPARENT GREEN with DARK
/// > COLORED TEXT — text plus the transparent green overlay."
///
/// Two claims are asserted here that no other suite makes:
///
///  * **What the box looks like on screen** — a translucent green wash, dark
///    type inside it, and the print underneath still reading through. Measured
///    in pixels, because a colour is not a value a presentation can carry.
///  * **How the box travels** — the EMA step itself (`stepped(toward:factor:)`),
///    which is pure arithmetic and is therefore asserted exactly, plus the three
///    snaps: a first sight, a new identity, a kind change.
///
/// The geometric side of the same rework — the wash's padding, the tight fit,
/// the object box the block is anchored to — is asserted in
/// `LiveOverlayPlacementTests` and `LiveOverlayPlacementGeometryTests`, where
/// the placement's own claims live.
final class LiveTranslateGreenOverlayTests: XCTestCase {

    private let container = CGSize(width: 390, height: 844)
    private let nepali = Locale(identifier: "ne-NP")

    // MARK: - Fixtures

    private func box(_ xMin: Double, _ yMin: Double,
                     _ xMax: Double, _ yMax: Double) -> NormalizedBox {
        NormalizedBox(xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax)
    }

    private func region(_ rawValue: Int,
                        _ text: String,
                        box rectangle: NormalizedBox) -> TextRegionStabilizer.StableTextRegion {
        TextRegionStabilizer.StableTextRegion(
            id: TextRegionStabilizer.RegionIdentity(rawValue: rawValue),
            text: text,
            normalizedText: LiveTranslateTextNormalization.normalized(text),
            box: rectangle,
            detectedLanguage: "ne",
            confidence: 0.9)
    }

    private func identity(_ rawValue: Int) -> TextRegionStabilizer.RegionIdentity {
        TextRegionStabilizer.RegionIdentity(rawValue: rawValue)
    }

    /// The surface the view renders, built the way the app builds it, under
    /// whatever config the test is making a claim about.
    private func makeSurface(_ config: LiveTranslateConfig,
                             regions: [TextRegionStabilizer.StableTextRegion],
                             results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [:])
        -> LiveTranslateOverlaySurface {
        let policy = LiveTranslateOverlaySurface.policy(config: config, alwaysShowOriginal: false)
        let copy = LiveTranslateOverlaySurface(placements: [], policy: policy, locale: nepali)
        let placements = LiveOverlayPlacement.place(
            regions: regions, results: results,
            containerSize: container, framePixelSize: container,
            safeArea: CGRect(origin: .zero, size: container),
            occupiedRects: LiveTranslateOverlaySurface.chromeRects(containerSize: container),
            policy: policy,
            stateCopy: { copy.stateCopy(for: $0) })
        return LiveTranslateOverlaySurface(placements: placements, policy: policy, locale: nepali)
    }

    /// One resolved region drawn in place, at the box given — the fixture every
    /// pixel claim below is made on.
    private func resolvedSurface(_ config: LiveTranslateConfig = .default,
                                 box rectangle: NormalizedBox = NormalizedBox(xMin: 0.15, yMin: 0.30,
                                                                              xMax: 0.85, yMax: 0.40))
        -> (surface: LiveTranslateOverlaySurface, rect: CGRect, region: TextRegionStabilizer.StableTextRegion) {
        let sign = region(0, "खुल्ने समय", box: rectangle)
        let surface = makeSurface(config, regions: [sign],
                                  results: [sign.id: .resolved(originalText: sign.text,
                                                               translation: "Opening hours",
                                                               tier: .cloud)])
        let rect = surface.presentations.first?.frameRect ?? .zero
        return (surface, rect, sign)
    }

    // MARK: - The look: a green wash with dark type in it

    /// The headline claim of the rework, in pixels: inside the box the elder
    /// sees a **translucent green** fill with **dark** type drawn in it, and
    /// the wash is light enough that the printed sign underneath still reads
    /// through.
    @MainActor
    func testTheBoxIsATranslucentGreenWashWithDarkTypeInsideIt() throws {
        let (surface, rect, _) = resolvedSurface()
        let image = try XCTUnwrap(OverlayRenderProbe.render(surface, size: container))

        // Inset the sample by a couple of points: the box's own edge is
        // antialiased against the corner radius, and an edge pixel is not what
        // the elder looks at.
        let within = rect.insetBy(dx: 2, dy: 2)
        let swatch = try OverlayRenderProbe.swatch(in: image, within: within)

        XCTAssertGreaterThan(swatch.greenCast, 0.05,
                             "the box is washed green: measured green − red = "
                             + "\(String(format: "%.3f", swatch.greenCast))")
        XCTAssertGreaterThan(swatch.green, swatch.blue,
                             "and the green is the dominant channel: \(swatch)")
        XCTAssertGreaterThan(swatch.luminance, 0.35,
                            "the wash is translucent, not an opaque dark panel: over the app's "
                            + "white paper it measures \(String(format: "%.2f", swatch.luminance)):1")
        XCTAssertGreaterThan(swatch.darkFraction, 0.005,
                             "there is dark type inside the box — the re-rendered line, at "
                             + "\(String(format: "%.1f", swatch.darkFraction * 100))% of its area")
        XCTAssertLessThan(swatch.darkFraction, 0.30,
                          "and it is type in a wash, not a slab of ink: \(swatch.darkFraction) of "
                          + "the box is dark, where the pre-rework navy fill was all of it")
    }

    /// The other half of "translucent": what is *under* the wash is still
    /// there. Rendering the same frame with the wash turned down to nothing
    /// leaves only the type on white paper, and turning it up moves the box
    /// monotonically toward the token's own green — which is what makes the
    /// opacity a strength and not a switch.
    @MainActor
    func testTheWashLetsThePrintUnderneathThroughAndFollowsTheConfiguredOpacity() throws {
        func swatch(opacity: Double) throws -> OverlayRenderProbe.Swatch {
            var config = LiveTranslateConfig.default
            config.overlayHighlightOpacity = opacity
            let (surface, rect, _) = resolvedSurface(config)
            let image = try XCTUnwrap(OverlayRenderProbe.render(surface, size: container))
            return try OverlayRenderProbe.swatch(in: image, within: rect.insetBy(dx: 2, dy: 2))
        }

        let clear = try swatch(opacity: 0)
        let shipped = try swatch(opacity: LiveTranslateConfig.default.overlayHighlightOpacity)
        let heavy = try swatch(opacity: 0.9)

        XCTAssertLessThan(clear.greenCast, 0.02,
                          "no wash, no green: the box is only its type over the paper")
        XCTAssertGreaterThan(shipped.greenCast, clear.greenCast + 0.05,
                             "the shipped value is a wash the elder can see at arm's length")
        XCTAssertGreaterThan(heavy.greenCast, shipped.greenCast,
                             "more opacity, more green: the config's value is the wash's strength, "
                             + "and at 0.4 the wash is a tint where at 0.9 it is a fill")
    }

    /// The wash's strength and the type at the body floor are a *pair*: dark ink
    /// on the green, at the contrast the feature holds every other surface to.
    func testTheTypeInsideTheWashClearsTheContrastFloor() throws {
        // The wash over the app's own background (white), composited the way
        // the renderer composites it: token green at the configured opacity
        // over white. This is the surface the type actually sits on wherever
        // the camera sees light paper — which is what a menu, a sign and a
        // package are.
        let opacity = LiveTranslateConfig.default.overlayHighlightOpacity
        let green = try components(of: DesignTokens.overlayHighlight)
        let washed = (red: green.red * opacity + (1 - opacity),
                      green: green.green * opacity + (1 - opacity),
                      blue: green.blue * opacity + (1 - opacity))

        let ratio = contrast(components(of: DesignTokens.textPrimary), washed)
        XCTAssertGreaterThanOrEqual(ratio, 4.5,
                                    "the dark type the owner asked for, over the wash they asked "
                                    + "for, measures \(String(format: "%.2f", ratio)):1")
        XCTAssertGreaterThanOrEqual(ratio, 7.0,
                                    "and it is not a shadow of the navy-on-white pair it replaces: "
                                    + "the dark-on-green pair is a *high*-contrast one")
    }

    /// The token itself, pinned to the owner's green — and pinned *as its own
    /// token*: a state fill belongs to the vocabulary about the voice (white
    /// glyphs on an opaque fill, tuned the other way), so the highlight cannot
    /// borrow one without changing what the wash does to the print underneath.
    func testTheHighlightTokenIsItsOwnGreenAndNotAStateFill() {
        let green = components(of: DesignTokens.overlayHighlight)
        XCTAssertEqual(green.red, 0.204, accuracy: 1.0 / 255, "#34A853, as a token")
        XCTAssertEqual(green.green, 0.659, accuracy: 1.0 / 255)
        XCTAssertEqual(green.blue, 0.325, accuracy: 1.0 / 255)
        XCTAssertGreaterThan(green.green - green.red, 0.3,
                             "the wash reads as green only because the green channel carries it")
        for fill in [DesignTokens.stateSpeaking, DesignTokens.stateIdle, DesignTokens.stateError,
                     DesignTokens.card, DesignTokens.background] {
            XCTAssertFalse(components(of: fill) == green,
                           "the highlight token is a colour of its own")
        }
    }

    // MARK: - Colour arithmetic (the token table's own sRGB values)

    private func components(of color: Color)
        -> (red: Double, green: Double, blue: Double) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            XCTFail("the token is not readable as sRGB")
            return (0, 0, 0)
        }
        return (Double(red), Double(green), Double(blue))
    }

    /// WCAG contrast ratio, over straight sRGB components (the same math
    /// `DesignTokensTests` uses for the state fills).
    private func contrast(_ first: (red: Double, green: Double, blue: Double),
                          _ second: (red: Double, green: Double, blue: Double)) -> Double {
        func luminance(_ c: (red: Double, green: Double, blue: Double)) -> Double {
            func linear(_ v: Double) -> Double {
                v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
        }
        let high = max(luminance(first), luminance(second))
        let low = min(luminance(first), luminance(second))
        return (high + 0.05) / (low + 0.05)
    }

    /// The three knobs are the config's, the view reads them from the policy,
    /// and no call site spells one out — the same rule every other operational
    /// value in this feature follows (NFR-LCT-011).
    func testTheWashAndTheGlideComeFromTheConfigAndNotFromLiterals() {
        let overlay = FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/App/LiveTranslate/LiveTranslateOverlayView.swift"))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "policy\\.highlightOpacity", in: overlay),
                        "the wash's strength is the policy's value, which is the config's")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "lerp: surface\\.policy\\.boxLerpFactor", in: overlay),
                        "and so is the glide's rate: the view passes the config's factor into the "
                        + "geometry memory rather than naming a number")
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "opacity\\([0-9]", in: overlay),
                     "no opacity is spelled at a call site")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "DesignTokens\\.overlayHighlight", in: overlay),
                        "the green itself comes from the token table")

        var tuned = LiveTranslateConfig.default
        tuned.overlayHighlightOpacity = 0.3
        tuned.overlayHighlightPadding = 7
        tuned.overlayBoxLerpFactor = 0.5
        let policy = LiveTranslateOverlaySurface.policy(config: tuned, alwaysShowOriginal: false)
        XCTAssertEqual(policy.highlightOpacity, 0.3)
        XCTAssertEqual(policy.highlightPadding, 7)
        XCTAssertEqual(policy.boxLerpFactor, 0.5)
    }

    // MARK: - The glide: the EMA step, exactly

    /// One EMA step, as arithmetic: `factor` of the remaining distance on each
    /// coordinate, `0` freezing and `1` snapping to the pre-rework behaviour.
    func testOneEmaStepIsTheFactorOfTheRemainingDistance() {
        let from = LiveOverlayFormGeometry.inPlace(rect: CGRect(x: 100, y: 300, width: 120, height: 40))
        let to = LiveOverlayFormGeometry.inPlace(rect: CGRect(x: 140, y: 340, width: 160, height: 60))

        XCTAssertEqual(from.stepped(toward: to, factor: 0), from, "0 freezes the box")
        XCTAssertEqual(from.stepped(toward: to, factor: 1), to, "1 is the snap the rework replaces")
        XCTAssertEqual(from.stepped(toward: to, factor: 0.3),
                       .inPlace(rect: CGRect(x: 112, y: 312, width: 132, height: 46)),
                       "0.3 is three tenths of the way on every coordinate: x 100→112, y 300→312, "
                       + "w 120→132, h 40→46")
        XCTAssertEqual(from.stepped(toward: to, factor: 0.5),
                       .inPlace(rect: CGRect(x: 120, y: 320, width: 140, height: 50)))
    }

    /// A callout is one geometry: the pill and the leader target glide
    /// together, because a pill that arrived while its line still pointed at
    /// where the text used to be is the jitter FR-LCT-016 forbids.
    func testACalloutsPillAndItsLeaderGlideTogether() {
        let from = LiveOverlayFormGeometry.callout(anchor: CGPoint(x: 10, y: 20),
                                                   pillRect: CGRect(x: 100, y: 200, width: 80, height: 30))
        let to = LiveOverlayFormGeometry.callout(anchor: CGPoint(x: 30, y: 40),
                                                 pillRect: CGRect(x: 200, y: 300, width: 100, height: 50))

        XCTAssertEqual(from.stepped(toward: to, factor: 0.5),
                       .callout(anchor: CGPoint(x: 20, y: 30),
                                pillRect: CGRect(x: 150, y: 250, width: 90, height: 40)))
    }

    /// A *kind* change is not a move: whatever the rects say, the two surfaces
    /// have nothing to interpolate, so the step is the snap the memory's kind
    /// guard already decided on.
    func testAStepBetweenTwoDifferentKindsSnaps() {
        let box = LiveOverlayFormGeometry.inPlace(rect: CGRect(x: 100, y: 300, width: 120, height: 40))
        let panel = LiveOverlayFormGeometry.scrollablePanel(rect: CGRect(x: 104, y: 302, width: 122, height: 44))
        let pill = LiveOverlayFormGeometry.callout(anchor: CGPoint(x: 160, y: 320),
                                                   pillRect: CGRect(x: 100, y: 330, width: 120, height: 40))

        XCTAssertEqual(box.stepped(toward: panel, factor: 0.3), panel)
        XCTAssertEqual(panel.stepped(toward: box, factor: 0.3), box)
        XCTAssertEqual(box.stepped(toward: pill, factor: 0.3), pill)
    }

    /// A rect the placement never produces — a degenerate container can hand
    /// one in — snaps to the target rather than drawing a NaN the renderer
    /// would silently drop.
    func testANonFiniteRectSnapsRatherThanGliding() {
        let broken = LiveOverlayFormGeometry.inPlace(
            rect: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10))
        let good = LiveOverlayFormGeometry.inPlace(rect: CGRect(x: 100, y: 100, width: 100, height: 100))
        XCTAssertEqual(broken.stepped(toward: good, factor: 0.3), good)
    }

    // MARK: - The snaps: a new block appears where it is, never on its way there

    /// The owner's own rule — "EMA resets on identity change (new block = snap,
    /// no glide-in from far away)". Two different strings are two identities,
    /// and each is drawn where the placement put it on its very first frame,
    /// however far apart the two rects are.
    func testANewIdentityIsDrawnWhereItIsRatherThanGlidingInFromTheLastOne() {
        let memory = LiveOverlayGeometryMemory()
        let upper = makeSurface(.default, regions: [region(0, "खुल्ने समय", box: box(0.2, 0.10, 0.8, 0.16))])
        let lower = makeSurface(.default, regions: [region(1, "प्रवेश निषेध", box: box(0.2, 0.70, 0.8, 0.76))])

        let first = memory.held(upper.presentations, container: container,
                                stickiness: 0.06, lerp: 0.3).first
        let second = memory.held(lower.presentations, container: container,
                                 stickiness: 0.06, lerp: 0.3).first

        XCTAssertEqual(first?.frameRect, upper.presentations.first?.frameRect,
                       "a new block is drawn where it is, on the frame it appears")
        XCTAssertEqual(second?.frameRect, lower.presentations.first?.frameRect,
                       "and the next new block does not glide in from the last one's rect, "
                       + "however far it is away")
        XCTAssertNotEqual(first?.frameRect, second?.frameRect, "the premise: the two are far apart")
    }

    /// The same identity, however: a move is glided, not snapped — and the
    /// first step is exactly the factor, on the shipped surface, through the
    /// view's own call shape.
    func testAMoveOfTheSameIdentityIsGlidedRatherThanSnapped() {
        let memory = LiveOverlayGeometryMemory()
        let before = makeSurface(.default, regions: [region(0, "खुल्ने समय", box: box(0.2, 0.30, 0.8, 0.38))])
        let after = makeSurface(.default, regions: [region(0, "खुल्ने समय", box: box(0.2, 0.30, 0.8, 0.45))])
        let factor = CGFloat(LiveTranslateConfig.default.overlayBoxLerpFactor)

        let drawn = memory.held(before.presentations, container: container,
                                stickiness: 0.06, lerp: Double(factor)).first!.frameRect
        let moved = memory.held(after.presentations, container: container,
                                stickiness: 0.06, lerp: Double(factor)).first!.frameRect
        let target = after.presentations.first!.frameRect

        XCTAssertNotEqual(moved, drawn, "the same block moved visibly: the box sets off")
        XCTAssertNotEqual(moved, target, "and it does not land in one frame")
        XCTAssertEqual(moved.height, drawn.height + (target.height - drawn.height) * factor,
                       accuracy: 1e-6,
                       "the first step covers the configured share of the distance")
    }

    // MARK: - Anchoring: the block's rect is the object box clipped to its members

    /// The owner's third ask — "use object detection bounding boxes" — is the
    /// grouper's, and this pins the seam the overlay depends on: a block that
    /// came from a detected object carries the object's box **clipped to the
    /// text it holds**, and the green box the placement draws is anchored to
    /// that rect and not to the individual lines.
    func testABlockIsAnchoredToItsObjectBoxClippedToItsMembers() {
        let object = NormalizedBox(xMin: 0.10, yMin: 0.20, xMax: 0.90, yMax: 0.60)
        let lines = [
            SceneTextLine(text: "खुल्ने समय", normalizedBox: box(0.15, 0.24, 0.55, 0.30),
                          confidence: 0.9, detectedLanguage: "ne"),
            SceneTextLine(text: "बन्द हुने समय", normalizedBox: box(0.15, 0.34, 0.62, 0.40),
                          confidence: 0.9, detectedLanguage: "ne"),
        ]
        let blocks = SceneBlockGrouper.group(lines: lines,
                                             objects: [SceneObjectBox(classLabel: "menu",
                                                                      normalizedBox: object,
                                                                      confidence: 0.8)],
                                             limit: nil)
        guard let block = blocks.first else {
            return XCTFail("the grouper must group the object's lines into a block")
        }

        // The anchoring law, from the grouper's own side: the object is the
        // anchor, the members' union is the clip, and the block carries the
        // intersection of the two — never a slab over the whole of the object,
        // and never a rect that misses one of its own lines.
        XCTAssertEqual(block.normalizedBox, SceneBlockGrouper.objectBox(object, holding: lines),
                       "the block's rect is the grouper's object-box-clipped-to-members, and this "
                       + "is the value the placement is handed")
        // This fixture's object is the looser of the two boxes, so the clip is
        // the members' own union — the tightest form of the claim.
        XCTAssertEqual(block.normalizedBox.xMin, lines.map(\.normalizedBox.xMin).min())
        XCTAssertEqual(block.normalizedBox.yMin, lines.map(\.normalizedBox.yMin).min())
        XCTAssertEqual(block.normalizedBox.xMax, lines.map(\.normalizedBox.xMax).max())
        XCTAssertEqual(block.normalizedBox.yMax, lines.map(\.normalizedBox.yMax).max())
        XCTAssertGreaterThan(block.normalizedBox.xMin, object.xMin,
                             "the object's own edges are the anchor, not the slab: the block stops "
                             + "at the words it holds")
        XCTAssertLessThan(block.normalizedBox.xMax, object.xMax)

        // …and the seam: the overlay anchors its green box to exactly that rect.
        let anchored = region(0, block.text, box: block.normalizedBox)
        let surface = makeSurface(.default, regions: [anchored],
                                  results: [anchored.id: .resolved(originalText: anchored.text,
                                                                   translation: "Opening hours",
                                                                   tier: .cloud)])
        guard let drawn = surface.presentations.first?.frameRect else {
            return XCTFail("an object block must be placed")
        }
        let anchor = LiveOverlayPlacement.screenRect(for: block.normalizedBox,
                                                     containerSize: container,
                                                     framePixelSize: container)
        let padding = CGFloat(LiveTranslateConfig.default.overlayHighlightPadding)
        XCTAssertTrue(drawn.insetBy(dx: -1e-6, dy: -1e-6).contains(anchor),
                      "the green box covers the object box the block was anchored to")
        XCTAssertEqual(drawn.midX, anchor.midX, accuracy: 1e-6)
        XCTAssertEqual(drawn.midY, anchor.midY, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(drawn.width, anchor.width + 2 * padding - 1e-6,
                                    "and it is that rect grown by the highlight's padding, so the "
                                    + "wash is a halo around the object's own box")
    }
}
