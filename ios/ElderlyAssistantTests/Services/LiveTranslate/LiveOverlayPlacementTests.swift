import CoreGraphics
import XCTest
@testable import ElderlyAssistant

/// T-020 — the overlay placement: replace-in-place as the default render, the
/// three-condition ineligibility predicate, the panel that takes over when the
/// in-place box cannot hold the text, the no-two-boxes-stack property,
/// determinism and bounded cost (FR-LCT-015, FR-LCT-016, NFR-LCT-002, CL-3, D1).
///
/// Reworked 2026-09-17 for the owner's live-device feedback — "the bubbles are
/// everywhere and shaky and get stacked and clustered depending on text" — and
/// again on 2026-09-18 for the verdict that outlived that rework: "there are
/// still some white-on-blue text boxes floating around". The claims below are
/// the final rework's: a translation stands where the text stood, a region the
/// box cannot hold becomes the panel on that same rect, and **no input to this
/// function is drawn as a callout at all** — every call site in this file
/// asserts the form's *absence*, and one test asserts it on the type. The
/// function is pure, so every claim is made against scripted rect sets and
/// value inputs — no view, no camera, no tier, no clock.
final class LiveOverlayPlacementTests: XCTestCase {

    private let container = CGSize(width: 390, height: 844)

    // MARK: Builders

    private func region(_ rawID: Int,
                        text: String,
                        box: (Double, Double, Double, Double),
                        confidence: Double = 0.9)
        -> TextRegionStabilizer.StableTextRegion {
        TextRegionStabilizer.StableTextRegion(
            id: TextRegionStabilizer.RegionIdentity(rawValue: rawID),
            text: text,
            normalizedText: LiveTranslateTextNormalization.normalized(text),
            box: NormalizedBox(xMin: box.0, yMin: box.1, xMax: box.2, yMax: box.3),
            detectedLanguage: "en",
            confidence: confidence)
    }

    private func translated(_ region: TextRegionStabilizer.StableTextRegion,
                            _ translation: String,
                            tier: TranslationTier = .dictionary) -> TranslationResult {
        .resolved(originalText: region.text, translation: translation, tier: tier)
    }

    private func surfacePolicy(alwaysShowOriginal: Bool = false) -> LiveOverlayPlacement.Policy {
        LiveTranslateOverlaySurface.policy(config: .default, alwaysShowOriginal: alwaysShowOriginal)
    }

    private func rect(of region: TextRegionStabilizer.StableTextRegion) -> CGRect {
        LiveOverlayPlacement.screenRect(for: region.box, containerSize: container,
                                        framePixelSize: container)
    }

    private var bounds: CGRect { CGRect(origin: .zero, size: container) }

    @discardableResult
    private func place(_ regions: [TextRegionStabilizer.StableTextRegion],
                       results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [:],
                       policy: LiveOverlayPlacement.Policy? = nil,
                       safeArea: CGRect? = nil,
                       occupiedRects: [CGRect] = [],
                       stateCopy: (TranslationResult) -> String? = { _ in nil },
                       measure: LiveOverlayPlacement.Measure = LiveOverlayTextMetrics.measure)
        -> [LiveOverlayPlacement.PlacedOverlay] {
        LiveOverlayPlacement.place(regions: regions,
                                   results: results,
                                   containerSize: container,
                                   framePixelSize: container,
                                   safeArea: safeArea ?? bounds,
                                   occupiedRects: occupiedRects,
                                   policy: policy ?? surfacePolicy(),
                                   stateCopy: stateCopy,
                                   measure: measure)
    }

    /// The in-place decision for one rect, with the shipped policy and no
    /// obstacles: the form the primitive tests below call directly.
    private func outcome(_ regionRect: CGRect,
                         result: TranslationResult,
                         policy: LiveOverlayPlacement.Policy? = nil,
                         obstacles: [CGRect] = [],
                         measure: LiveOverlayPlacement.Measure = LiveOverlayTextMetrics.measure)
        -> LiveOverlayPlacement.InPlaceOutcome {
        LiveOverlayPlacement.inPlaceOutcome(regionRect: regionRect, result: result,
                                            obstacles: obstacles, bounds: bounds,
                                            policy: policy ?? surfacePolicy(), measure: measure)
    }

    /// **The form that must not come out of `place`.** Every test that used to
    /// inspect a pill now asserts its absence and reads the surface that took
    /// its place, because the owner's device verdict on the build that had the
    /// pill is this file's hardest constraint: "there are still some
    /// white-on-blue text boxes floating around".
    ///
    /// `Form.callout` and the renderer's callout branch still exist — the
    /// snapshot card and the view's own tests build one by hand — but the
    /// *placement* has no rung that reaches it, and this helper is how each of
    /// these tests says so out loud instead of assuming it.
    @discardableResult
    private func assertNoCallout(_ placement: LiveOverlayPlacement.PlacedOverlay,
                                 _ what: String = "a live placement",
                                 file: StaticString = #filePath,
                                 line: UInt = #line) -> Bool {
        guard case .callout = placement.form else { return true }
        XCTFail("\(what) came back as a floating callout (\(placement.form)): the live overlay "
                + "has two surfaces and both are green — the in-place box and the panel "
                + "(FR-LCT-016, owner device verdict 2026-09-18)",
                file: file, line: line)
        return false
    }

    private func inPlaceRect(_ placement: LiveOverlayPlacement.PlacedOverlay) -> CGRect? {
        guard case .inPlace(_, let rect) = placement.form else { return nil }
        return rect
    }

    /// The panel's box, when the region is drawn as one: the fallback form the
    /// live overlay has — the panel's own box when the region has the room for
    /// it, the capped and scrolled box when it does not. Both are this one form.
    private func scrollableRect(_ placement: LiveOverlayPlacement.PlacedOverlay) -> CGRect? {
        guard case .scrollablePanel(_, let rect) = placement.form else { return nil }
        return rect
    }

    /// No two rects in `rects` share any area. Touching is allowed (a box may
    /// meet its neighbour at the midpoint of the gap between them), so an
    /// overlap of a millionth of a point — double rounding at an exact meeting
    /// point — is not a stack.
    private func assertNoStacking(_ rects: [CGRect],
                                  _ what: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        for first in rects.indices {
            for second in rects.indices where second > first {
                let overlap = rects[first].intersection(rects[second])
                XCTAssertTrue(overlap.isNull || overlap.width <= 1e-6 || overlap.height <= 1e-6,
                              "\(what) \(first) and \(second) are stacked: "
                              + "\(rects[first]) ∩ \(rects[second]) = \(overlap)",
                              file: file, line: line)
            }
        }
    }

    // MARK: Scenario: replace-in-place is the default render

    /// A region with a translation to draw and room to draw it in.
    private func resolvedScene() -> (region: TextRegionStabilizer.StableTextRegion,
                                     result: TranslationResult) {
        let region = region(0, text: "गेट खोल्नुहोस्", box: (0.1, 0.4, 0.9, 0.6))
        return (region, translated(region, "Open the gate"))
    }

    /// The rework's headline: **every** resolved translation is drawn in place,
    /// whatever tier answered it. The old rule made a cloud translation a
    /// callout by construction (the "smart mix" word bound), which is what put
    /// a bubble over the text it was translating on the owner's device.
    func testAResolvedTranslationIsDrawnInPlaceWhateverTierAnsweredIt() {
        let region = region(0, text: "गेट खोल्नुहोस्", box: (0.1, 0.4, 0.9, 0.6))
        let dictionary = translated(region, "Open the gate", tier: .dictionary)
        let cloud = translated(region, "Open the gate", tier: .cloud)

        for result in [dictionary, cloud] {
            let placements = place([region], results: [region.id: result])
            XCTAssertEqual(placements.count, 1)
            XCTAssertNotNil(inPlaceRect(placements[0]),
                            "a resolved \(result.sourceTier!) translation stands where the text stood")
            assertNoCallout(placements[0],
                            "a translation that can be read in place")
            XCTAssertFalse(placements[0].isClampedFallback)
        }
    }

    /// The source is fully covered and only free space is taken: the box always
    /// contains the region's own printed text, and it never grows past the
    /// configured ceiling.
    func testTheInPlaceBoxCoversTheRegionAndGrowsOnlyWithinTheCeiling() {
        let (region, result) = resolvedScene()
        let policy = surfacePolicy()
        let placements = place([region], results: [region.id: result])
        let own = rect(of: region)
        let box = inPlaceRect(placements[0])!

        XCTAssertTrue(box.insetBy(dx: -1e-9, dy: -1e-9).contains(own),
                      "the box covers the printed text it replaces, or the original shows through")
        XCTAssertLessThanOrEqual(box.width, own.width * CGFloat(policy.inPlaceMaxGrowth) + 1e-9,
                                 "the growth ceiling is a ceiling (FR-LCT-015)")
        XCTAssertLessThanOrEqual(box.height, own.height * CGFloat(policy.inPlaceMaxGrowth) + 1e-9)
        XCTAssertGreaterThanOrEqual(box.width, own.width)
        XCTAssertGreaterThanOrEqual(box.height, own.height)
        XCTAssertTrue(bounds.insetBy(dx: -1e-9, dy: -1e-9).contains(box),
                      "the box stays inside the safe area it was measured against")
    }

    /// In place, the translation is the one thing drawn — the original is
    /// covered by design, and the FR-LCT-017 preference is the way to see both.
    func testTheInPlaceFormDrawsOnlyTheTranslation() {
        let (region, result) = resolvedScene()
        let policy = surfacePolicy()
        let placements = place([region], results: [region.id: result])

        XCTAssertEqual(placements[0].lines.map(\.text), [result.text],
                       "in place, the translation is the one thing drawn")
        XCTAssertEqual(placements[0].lines.first?.weight, .primary)
        XCTAssertLessThanOrEqual(placements[0].lines.first?.pointSize ?? 0, policy.minPointSize,
                                 "the largest size the fit is tried at is the app's body floor")
        XCTAssertGreaterThanOrEqual(placements[0].lines.first?.pointSize ?? 0,
                                    policy.inPlaceMinPointSize,
                                    "and never below the configured in-place floor")
    }

    /// The word bound is gone: a long source whose *translation* is short is
    /// drawn in place, because what matters is whether the translation fits,
    /// not how many words the sign had on it.
    func testALongSourceIsDrawnInPlaceWhenItsTranslationFits() {
        let sign = region(0, text: "please open the gate", box: (0.1, 0.4, 0.9, 0.6))
        let result = translated(sign, "गेट खोल्नुहोस्")

        guard case .fits = outcome(rect(of: sign), result: result) else {
            return XCTFail("the source's word count is not a condition any more")
        }
        XCTAssertNotNil(inPlaceRect(place([sign], results: [sign.id: result])[0]))
    }

    // MARK: The form that cannot be reached

    /// **The type-level law.** Not one input to `place` produces `Form.callout`:
    /// not the sign whose translation fits, not the translation that cannot be
    /// read in place, not a pending or a degraded region, not the
    /// always-show-original preference, not extract mode, not a block of twenty
    /// lines, not a region that is the whole screen, not a frame where every
    /// region is one of those.
    ///
    /// This is asserted across the input space rather than at the cases somebody
    /// remembered, because the way the pill came back the first time was a
    /// branch nobody was looking at — a fit failure falling through to it. The
    /// form stays in `Form` for the renderer (the snapshot card and the view's
    /// own tests build one by hand), but the placement has no rung that reaches
    /// it, and this is the test that says so.
    func testNoInputToThePlacementProducesACallout() {
        let sign = region(0, text: "Pharmacy", box: (0.1, 0.4, 0.9, 0.6))
        let small = region(1, text: "गेट", box: (0.1, 0.4, 0.2, 0.42))
        let block = blockRegion(2, lines: ["START", "2 MIN"], box: (0.10, 0.30, 0.70, 0.60))
        let tallBlock = blockRegion(3, lines: (1...12).map { "लाइन \($0)" },
                                    box: (0.42, 0.44, 0.50, 0.50))
        let wholeScreen = region(4, text: "Pharmacy", box: (0.0, 0.0, 1.0, 1.0))
        let long = "Please open the gate by the side of the house before the evening"
        let degraded = { (region: TextRegionStabilizer.StableTextRegion) -> TranslationResult in
            .degraded(originalText: region.text, reason: .noNetwork)
        }
        let extract = LiveTranslateOverlaySurface.policy(config: .default,
                                                        alwaysShowOriginal: false,
                                                        extractionMode: true)

        let scenes: [(String, [LiveOverlayPlacement.PlacedOverlay])] = [
            ("a translation that fits in place",
             place([sign], results: [sign.id: translated(sign, "खोल्नुहोस्")])),
            ("a translation too long for its own box",
             place([small], results: [small.id: translated(small, long)])),
            ("a cloud translation",
             place([sign], results: [sign.id: translated(sign, "खोल्नुहोस्", tier: .cloud)])),
            ("a region no tier has answered for", place([sign], results: [:])),
            ("a pending region", place([sign], results: [sign.id: .pending(sign.text)])),
            ("a pending region with a state sentence",
             place([sign], results: [sign.id: .pending(sign.text)],
                   stateCopy: { _ in "पर्खंदै" })),
            ("a degraded region", place([sign], results: [sign.id: degraded(sign)])),
            ("a degraded region with a state sentence",
             place([sign], results: [sign.id: degraded(sign)],
                   stateCopy: { _ in "अनुवाद उपलब्ध छैन" })),
            ("the always-show-original preference",
             place([sign], results: [sign.id: translated(sign, "खोल्नुहोस्")],
                   policy: surfacePolicy(alwaysShowOriginal: true))),
            ("extract mode, untranslated", place([sign], results: [:], policy: extract)),
            ("extract mode, tapped and answered",
             place([sign], results: [sign.id: translated(sign, "खोल्नुहोस्")], policy: extract)),
            ("a block that fits its own box",
             place([block], results: [block.id: translated(block, "सुरु\n२ मिनेट")])),
            ("a block that cannot stand as a panel",
             place([tallBlock], results: [tallBlock.id: translated(
                 tallBlock, (1...12).map { "लाइन \($0)" }.joined(separator: "\n"))])),
            ("a block no tier has answered for", place([tallBlock], results: [:])),
            ("a region that is the whole safe area",
             place([wholeScreen], results: [wholeScreen.id: degraded(wholeScreen)])),
            ("a container whose safe area is empty",
             place([sign], results: [sign.id: degraded(sign)], safeArea: .zero)),
            ("a scene where every region needs the fallback",
             place([sign, small, block, tallBlock, wholeScreen],
                   results: [sign.id: degraded(sign), small.id: degraded(small),
                             block.id: degraded(block), tallBlock.id: degraded(tallBlock),
                             wholeScreen.id: degraded(wholeScreen)])),
            ("a scene where nothing has an answer", place([sign, small, block], results: [:]))
        ]

        for (name, placements) in scenes {
            XCTAssertFalse(placements.isEmpty, "\(name): a scene must place something")
            for placement in placements {
                assertNoCallout(placement, "\(name)")
            }
        }
    }

    // MARK: Scenario: the three conditions, named for their violation

    func testTheConditionListIsTheClosedSetTheDesignNames() {
        XCTAssertEqual(LiveOverlayPlacement.InPlaceCondition.allCases,
                       [.noTranslationToDraw, .translationDoesNotFitRegion, .alwaysShowOriginalIsOn],
                       "one reason to fall back for each way in place can be wrong (D1)")
        XCTAssertEqual(Set(LiveOverlayPlacement.InPlaceCondition.allCases.map(\.rawValue)).count,
                       LiveOverlayPlacement.InPlaceCondition.allCases.count)
    }

    func testAPendingRegionHasNoTranslationToDraw() {
        let region = region(0, text: "Pharmacy", box: (0.1, 0.4, 0.9, 0.5))
        let result = TranslationResult.pending(region.text)

        XCTAssertEqual(outcome(rect(of: region), result: result),
                       .ineligible(.noTranslationToDraw),
                       "drawing the recognized text where it already stands would cover the "
                       + "original with itself and claim the region was translated (FR-LCT-018)")
        let placement = place([region], results: [region.id: result])[0]
        assertNoCallout(placement, "a pending region")
        XCTAssertNotNil(scrollableRect(placement),
                        "it is the panel on its own rect — the surface that stands where the "
                        + "text stood rather than a bubble appearing beside it")
    }

    func testADegradedRegionHasNoTranslationToDraw() {
        let region = region(0, text: "Pharmacy", box: (0.1, 0.4, 0.9, 0.5))
        let result = TranslationResult.degraded(originalText: region.text, reason: .noNetwork)

        XCTAssertEqual(outcome(rect(of: region), result: result),
                       .ineligible(.noTranslationToDraw))
    }

    /// A region with no result at all is placed as pending — the condition
    /// holds without a caller remembering to check.
    func testAMissingResultIsNoTranslationToDraw() {
        let region = region(0, text: "Pharmacy", box: (0.1, 0.4, 0.9, 0.5))
        let placement = place([region], results: [:])[0]

        XCTAssertEqual(placement.result.outcome, .pending(originalText: "Pharmacy"))
        assertNoCallout(placement, "a region whose tier has not answered")
        XCTAssertNotNil(scrollableRect(placement),
                        "the region is drawn on its own rect, not beside it")
        XCTAssertEqual(placement.lines.map(\.text), ["Pharmacy"])
    }

    /// The second rung, and the one the callout used to hold: a translation too
    /// long to stand at the body floor in this sign's own box is drawn as the
    /// **panel**, on the sign's own rect — never shrunk into illegibility and
    /// never floated beside the text.
    func testATranslationThatCannotBeReadInPlaceFallsBackToThePanel() {
        let (sign, _) = resolvedScene()
        let small = region(1, text: "गेट", box: (0.1, 0.4, 0.2, 0.42))
        let verbose = translated(
            small,
            "Please open the gate by the side of the house before the evening")

        XCTAssertEqual(outcome(rect(of: small), result: verbose).condition,
                       .translationDoesNotFitRegion,
                       "type too small to read is the honest failure, not a translation nobody can read")
        let placement = place([small], results: [small.id: verbose])[0]
        assertNoCallout(placement, "a translation that does not fit its own box")
        XCTAssertNotNil(scrollableRect(placement),
                        "the too-long translation is drawn as the panel, in full")
        XCTAssertEqual(placement.lines.map(\.text), [verbose.text, small.text],
                       "both lines the surface carries: the translation, and the original it "
                       + "stands on top of")
        XCTAssertGreaterThan(rect(of: sign).width, 0)
    }

    func testTurningTheToggleOnAloneProducesThePanel() {
        let (region, result) = resolvedScene()
        let on = surfacePolicy(alwaysShowOriginal: true)

        XCTAssertEqual(outcome(rect(of: region), result: result, policy: on),
                       .ineligible(.alwaysShowOriginalIsOn),
                       "the FR-LCT-017 preference wants the original beside the translation, "
                       + "which the in-place box cannot draw (T-022)")
        let placement = place([region], results: [region.id: result], policy: on)[0]
        assertNoCallout(placement, "the always-show-original preference")
        XCTAssertNotNil(scrollableRect(placement),
                        "the preference is honoured on the panel, which carries both texts")
    }

    /// The conditions are tested in a fixed order, so *why* a region left the
    /// in-place form is a fact rather than an inference: here the fit would fail
    /// too, and the preference is still the reason reported.
    func testTheFirstViolationInOrderIsTheOneReported() {
        let (region, _) = resolvedScene()
        let on = surfacePolicy(alwaysShowOriginal: true)
        let unfittable = translated(region, String(repeating: "long ", count: 40))

        XCTAssertEqual(outcome(rect(of: region), result: unfittable, policy: on).condition,
                       .alwaysShowOriginalIsOn)
        XCTAssertEqual(outcome(rect(of: region),
                               result: .degraded(originalText: region.text, reason: .noNetwork),
                               policy: on).condition,
                       .noTranslationToDraw,
                       "nothing to draw outranks everything: there is no translation to place")
    }

    // MARK: Scenario: the fit is a measurement, and it has a floor

    /// The point sizes the in-place form is tried at: the app's body floor
    /// first, then the configured in-place floor — never a scan that grows with
    /// the string, and never a size nobody chose.
    func testThePointSizeLadderIsLargestFirstAndEndsAtTheConfiguredFloor() {
        let policy = surfacePolicy()

        XCTAssertEqual(LiveOverlayPlacement.inPlacePointSizes(policy: policy),
                       [policy.minPointSize, policy.inPlaceMinPointSize])
        XCTAssertEqual(policy.inPlaceMinPointSize, LiveTranslateConfig.default.inPlaceMinPointSize,
                       "the floor is the config's, not a literal in the placement")

        var raised = LiveTranslateConfig.default
        raised.inPlaceMinPointSize = 400
        let floored = LiveTranslateOverlaySurface.policy(config: raised, alwaysShowOriginal: false)
        XCTAssertEqual(LiveOverlayPlacement.inPlacePointSizes(policy: floored),
                       [floored.minPointSize],
                       "an in-place floor above the body floor is clamped to it: in-place text "
                       + "never outgrows the app's own body text")
    }

    /// A translation too large for the body floor but small enough for the
    /// in-place floor is drawn in place at that floor — the fallback to a size
    /// the config allows, rather than to a callout.
    func testATranslationThatOnlyFitsAtTheInPlaceFloorIsDrawnInPlaceAtThatFloor() {
        let policy = surfacePolicy()
        let translation = "Members only beyond this point"
        let regionRect = CGRect(x: 100, y: 300, width: 100, height: 40)
        let box = LiveOverlayPlacement.inPlaceMaxBox(regionRect: regionRect, obstacles: [],
                                                     bounds: bounds,
                                                     growth: policy.inPlaceMaxGrowth)
        let atBodyFloor = LiveOverlayTextMetrics.measure(translation, pointSize: policy.minPointSize,
                                                         weight: .primary, width: box.width)
        let atInPlaceFloor = LiveOverlayTextMetrics.measure(translation,
                                                            pointSize: policy.inPlaceMinPointSize,
                                                            weight: .primary, width: box.width)
        XCTAssertGreaterThan(atBodyFloor.height, box.height,
                             "the premise: the translation does not fit at the body floor")
        XCTAssertLessThanOrEqual(atInPlaceFloor.height, box.height,
                                 "the premise: it does fit at the in-place floor")

        let sign = region(0, text: "यहाँ भित्र", box: (0.1, 0.1, 0.2, 0.2))
        let result = translated(sign, translation)
        guard case .fits(let fittedBox, let line) = outcome(regionRect, result: result,
                                                            policy: policy) else {
            return XCTFail("a translation that fits at the in-place floor is drawn in place")
        }
        XCTAssertEqual(line.pointSize, policy.inPlaceMinPointSize)
        XCTAssertEqual(line.text, translation)
        // The box the fit was decided on is the box that is drawn — as the
        // ceiling, not as the rect: the drawn box hugs the text it holds
        // (`inPlaceTightBox`), so it is the same box *at most*, never a box
        // that reaches past what was proved clear of its neighbours.
        XCTAssertLessThanOrEqual(fittedBox.width, box.width + 1e-9)
        XCTAssertLessThanOrEqual(fittedBox.height, box.height + 1e-9)
        XCTAssertTrue(box.insetBy(dx: -1e-9, dy: -1e-9).contains(fittedBox),
                      "the drawn box stays inside the ceiling the fit was measured against")
        XCTAssertGreaterThanOrEqual(line.pointSize, LiveTranslateConfig.default.inPlaceMinPointSize,
                                    "the 16pt floor the owner asked to be configurable")
    }

    /// The floor and the ceiling are read from the policy, and the policy is
    /// built from the config: moving either value moves the render.
    func testTheFloorAndTheCeilingAreTheConfigsValues() {
        var wider = LiveTranslateConfig.default
        wider.inPlaceMaxGrowth = 2.0
        let policy = LiveTranslateOverlaySurface.policy(config: wider, alwaysShowOriginal: false)

        let regionRect = CGRect(x: 100, y: 300, width: 100, height: 40)
        let box = LiveOverlayPlacement.inPlaceMaxBox(regionRect: regionRect, obstacles: [],
                                                     bounds: bounds,
                                                     growth: policy.inPlaceMaxGrowth)

        XCTAssertEqual(policy.inPlaceMaxGrowth, wider.inPlaceMaxGrowth)
        XCTAssertEqual(box.width, 200, accuracy: 1e-9,
                       "a ceiling of 2.0 puts half the region's width of free space on each side")
        XCTAssertEqual(box.midX, regionRect.midX, accuracy: 1e-9)
        XCTAssertEqual(box.midY, regionRect.midY, accuracy: 1e-9)
    }

    // MARK: Scenario: the box hugs the text it replaces (owner device verdict)

    /// The drawn box is the **text block plus the configured padding**, not the
    /// ceiling the fit was decided on: a short translation is no longer centred
    /// in a slab of empty ink, which is what the owner saw and named ("the
    /// bubbles are blue background with white text"). The ceiling is still the
    /// bound — the box never reaches past what was proved clear of its
    /// neighbours — and the region's own printed rect is still covered.
    func testTheInPlaceBoxIsTheTextBlockAndItsPaddingAndNothingElse() {
        let policy = surfacePolicy()
        let padding = policy.inPlacePadding
        let translation = "Members only beyond this point"
        let text = LiveOverlayTextMetrics.measure(translation, pointSize: policy.minPointSize,
                                                  weight: .primary)
        // A sign comfortably narrower and shorter than its own translation, so
        // the box has to grow — and must stop at the text, not at the ceiling.
        let regionRect = CGRect(x: 100, y: 300, width: text.width - 40, height: text.height)
        let ceiling = LiveOverlayPlacement.inPlaceMaxBox(regionRect: regionRect, obstacles: [],
                                                         bounds: bounds,
                                                         growth: policy.inPlaceMaxGrowth)
        let box = LiveOverlayPlacement.inPlaceTightBox(regionRect: regionRect,
                                                       textSize: text,
                                                       ceiling: ceiling,
                                                       padding: padding,
                                                       highlightPadding: policy.highlightPadding)

        XCTAssertGreaterThan(text.width + 2 * padding, regionRect.width,
                             "the premise: the translation needs more room than the sign has")
        XCTAssertGreaterThan(ceiling.width, regionRect.width,
                             "the premise: there is free space to grow into")
        // The floor: never narrower or shorter than the text (within the
        // ceiling) needs, so the view cannot clip what the fit measured.
        XCTAssertGreaterThanOrEqual(box.width + 1e-9, min(text.width + 2 * padding, ceiling.width))
        XCTAssertGreaterThanOrEqual(box.height + 1e-9, min(text.height + 2 * padding, ceiling.height))
        // …and the ceiling of the ceiling: never bigger than the padded block,
        // so the box is a replacement rather than a slab.
        XCTAssertLessThanOrEqual(box.width,
                                 max(regionRect.width, min(text.width + 2 * padding, ceiling.width)) + 1e-9,
                                 "a box wider than the text it holds is the bubble the owner rejected")
        XCTAssertLessThanOrEqual(box.height,
                                 max(regionRect.height,
                                     min(text.height + 2 * padding, ceiling.height)) + 1e-9)
        XCTAssertLessThan(box.width, ceiling.width,
                          "the box stops well inside the ceiling the fit was measured against")
        // The three properties the rework must not have traded away.
        XCTAssertTrue(box.insetBy(dx: -1e-9, dy: -1e-9).contains(regionRect),
                      "the printed text it replaces is covered")
        XCTAssertTrue(ceiling.insetBy(dx: -1e-9, dy: -1e-9).contains(box),
                      "and the box can only shrink a rect already proved clear of its neighbours")
        XCTAssertTrue(box.insetBy(dx: -1e-9, dy: -1e-9).contains(
            regionRect.insetBy(dx: -policy.highlightPadding, dy: -policy.highlightPadding)
                .intersection(ceiling)),
                      "and the detected region is in it at the highlight's own padding, so the "
                      + "green wash points at the print and not only at the re-rendered type")
    }

    /// A translation shorter than the sign it replaces: the box is the sign's
    /// own rect, grown by the highlight padding — it never shrinks below the
    /// printed text and never pads it out into a bubble. The growth is the
    /// owner's "small padding ~5pt" (2026-09-18): the wash is a halo around the
    /// words the elder is looking at, not a frame exactly on their edges.
    func testAShortTranslationInABigSignDrawsTheSignsOwnRectAndTheHighlightPadding() {
        let policy = surfacePolicy()
        let (region, result) = resolvedScene()
        let own = rect(of: region)
        let padding = policy.highlightPadding

        guard case .fits(let box, _) = outcome(own, result: result) else {
            return XCTFail("the premise: the translation fits in place")
        }
        // Component-wise, to a millionth of a point: the box is the printed
        // rect *unioned* with the text block and the highlight band, and a union
        // is a new rectangle whose edges may land one unit in the last place
        // away from the rect it was made from. The claim is geometric — "the box
        // is the sign's own rect plus the padding" — so the comparison is too.
        XCTAssertGreaterThan(padding, 0, "the premise: the highlight has a padding to add")
        XCTAssertEqual(box.minX, own.minX - padding, accuracy: 1e-6)
        XCTAssertEqual(box.minY, own.minY - padding, accuracy: 1e-6)
        XCTAssertEqual(box.width, own.width + 2 * padding, accuracy: 1e-6)
        XCTAssertEqual(box.height, own.height + 2 * padding, accuracy: 1e-6)
    }

    /// The in-place look is the config's, and it is deliberately not the
    /// bubble token's: the owner's verdict was that the boxes read as bubbles
    /// floating over the picture. Tight padding, a corner that hugs a line of
    /// type, and no leader line — the callout keeps the pill's values because
    /// it *is* a surface beside the text.
    func testTheInPlacePaddingAndCornerAreTheConfigsAndNotTheBubbleTokens() {
        let policy = surfacePolicy()
        let config = LiveTranslateConfig.default

        XCTAssertEqual(policy.inPlacePadding, config.inPlacePadding,
                       "the drawn inset is the configured one (NFR-LCT-011)")
        XCTAssertEqual(policy.inPlaceCornerRadius, config.inPlaceCornerRadius)
        XCTAssertGreaterThanOrEqual(policy.inPlacePadding, 4,
                                    "the translation still needs breathing room")
        XCTAssertLessThanOrEqual(policy.inPlacePadding, 6,
                                 "more than this and a short translation floats in a bubble again "
                                 + "(owner device verdict, 2026-09-17)")
        XCTAssertLessThan(policy.inPlaceCornerRadius, DesignTokens.bubbleCornerRadius,
                          "the in-place corner hugs the text line; the pill's radius is a bubble's")
        XCTAssertNotEqual(policy.inPlacePadding, policy.pillPadding,
                          "the callout and the in-place box are different surfaces: one value "
                          + "cannot serve both")
    }

    /// The geometry stickiness is the config's too, and it is carried in the
    /// policy because it is measured in the same container the rects were: the
    /// overlay reads it from there rather than spelling a threshold of its own.
    func testTheGeometryStickinessIsTheConfigsValue() {
        let config = LiveTranslateConfig.default
        XCTAssertEqual(surfacePolicy().geometryStickiness, config.overlayGeometryStickiness,
                       "one threshold, and the config owns it")
        XCTAssertGreaterThan(config.overlayGeometryStickiness, 0)
        XCTAssertLessThan(config.overlayGeometryStickiness, 0.1,
                          "a threshold that big would let a box sit half a screen from its sign")

        var looser = config
        looser.overlayGeometryStickiness = 0.08
        XCTAssertEqual(LiveTranslateOverlaySurface.policy(config: looser,
                                                          alwaysShowOriginal: false).geometryStickiness,
                       0.08,
                       "moving the config moves what the overlay holds")
    }

    /// The green highlight's own values are the config's, carried in the policy
    /// for the one construction site to fill — and each is read by exactly the
    /// layer that owns it, so no two layers can disagree about the look the
    /// owner asked for (2026-09-18).
    func testTheHighlightValuesAreTheConfigsValues() {
        let config = LiveTranslateConfig.default
        let policy = surfacePolicy()

        XCTAssertEqual(policy.highlightPadding, config.overlayHighlightPadding,
                       "the placement grows the detected region by this, so the wash covers the print")
        XCTAssertEqual(policy.highlightOpacity, config.overlayHighlightOpacity,
                       "the view washes the box at this, so the print reads through it")
        XCTAssertEqual(policy.boxLerpFactor, config.overlayBoxLerpFactor,
                       "the geometry memory glides at this, so a moving box does not jump")

        var tuned = config
        tuned.overlayHighlightOpacity = 0.75
        tuned.overlayHighlightPadding = 12
        tuned.overlayBoxLerpFactor = 0.5
        let moved = LiveTranslateOverlaySurface.policy(config: tuned, alwaysShowOriginal: false)
        XCTAssertEqual(moved.highlightOpacity, 0.75)
        XCTAssertEqual(moved.highlightPadding, 12)
        XCTAssertEqual(moved.boxLerpFactor, 0.5)

        // Bands, not pins: the values are the owner's to tune on a device, and
        // each band is the range in which the look still works — under the low
        // end the highlight stops reading as a highlight, over the high end it
        // buries the text it is drawn over or the box lags its sign.
        XCTAssertGreaterThanOrEqual(policy.highlightOpacity, 0.25)
        XCTAssertLessThanOrEqual(policy.highlightOpacity, 0.5)
        XCTAssertGreaterThanOrEqual(policy.highlightPadding, 3)
        XCTAssertLessThanOrEqual(policy.highlightPadding, 8)
        XCTAssertGreaterThan(policy.boxLerpFactor, 0)
        XCTAssertLessThanOrEqual(policy.boxLerpFactor, 1)
    }

    /// The padding is the placement's (it is geometry), and the other two are
    /// the view's (an opacity and a glide rate are not geometry): each value is
    /// read by the one layer that can honour it, and the scan is what stops a
    /// second reader appearing.
    func testThePlacementReadsItsOwnHighlightValueAndNotTheViews() {
        let file = FeatureSourceScan.iosDirectory().appendingPathComponent(
            "ElderlyAssistant/Services/LiveTranslate/LiveOverlayPlacement.swift")
        let code = FeatureSourceScan.codeText(of: file)
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "policy\\.highlightPadding", in: code),
                        "the placement is where the detected region is grown: it reads the padding")
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "\\.highlightOpacity", in: code),
                     "a colour wash is not placement: the view reads the opacity, the placement "
                     + "only carries it")
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "\\.boxLerpFactor", in: code),
                     "nor is a glide rate: the geometry memory owns the EMA")
    }

    /// The placement **carries** the threshold and never **reads** it: the
    /// policy is where a value measured in the container's own dimensions
    /// belongs, so the overlay reads it from one place (`LiveTranslateOverlaySurface.policy`)
    /// rather than spelling a threshold of its own — but holding a rect is the
    /// overlay's business, so no function of the placement may consult it. A
    /// read is a member access; the declaration is not one, and neither is the
    /// doc comment above it (the scan sees comment-stripped code).
    func testThePlacementDoesNotUseTheGeometryStickiness() {
        let file = FeatureSourceScan.iosDirectory().appendingPathComponent(
            "ElderlyAssistant/Services/LiveTranslate/LiveOverlayPlacement.swift")
        let code = FeatureSourceScan.codeText(of: file)
        XCTAssertFalse(code.isEmpty)
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "let geometryStickiness: Double", in: code),
                        "the policy carries the configured threshold, so the overlay reads it from "
                        + "the config's one construction site")
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "\\.geometryStickiness", in: code),
                     "and the placement never reads it: the placement is a pure function of its "
                     + "inputs, and holding a rect is the overlay's business, not the placement's")
    }

    /// The measurement is made at the width the box will draw at: a fit decided
    /// unwrapped would pass for a translation the view then clips.
    func testTheFitIsMeasuredThroughTheInjectedClosureAtTheBoxesWidth() {
        let (region, result) = resolvedScene()
        let policy = surfacePolicy()
        var seen: [(text: String, pointSize: CGFloat, weight: LiveOverlayTextWeight, width: CGFloat)] = []
        let measure: LiveOverlayPlacement.Measure = { text, pointSize, weight, width in
            seen.append((text, pointSize, weight, width))
            return LiveOverlayTextMetrics.measure(text, pointSize: pointSize,
                                                  weight: weight, width: width)
        }

        let placements = place([region], results: [region.id: result], measure: measure)
        let box = inPlaceRect(placements[0])!

        XCTAssertFalse(seen.isEmpty)
        for measurement in seen {
            // At least the drawn box's width, never less: the fit is measured
            // against the ceiling it may reach, and the drawn box is that
            // ceiling (or the text's own tight box inside it). A measurement
            // *narrower* than the drawn box would be a wrap the view does not
            // reproduce, which is risk R2 (owner UX rework, 2026-09-17).
            XCTAssertGreaterThanOrEqual(measurement.width, box.width - 1e-9,
                                        "the text is measured against the box it is drawn in, "
                                        + "not an unbounded line")
        }
        XCTAssertTrue(seen.contains { $0.text == result.text
            && $0.pointSize == policy.minPointSize && $0.weight == .primary },
                      "the fit was decided at the size and weight the view renders, or the two could diverge")
        XCTAssertTrue(seen.allSatisfy { $0.pointSize == policy.minPointSize
            || $0.pointSize == policy.inPlaceMinPointSize },
                      "and every size tried is one of the two the policy names — the ladder is a "
                      + "fixed scan, not a search that shrinks until something fits")
        XCTAssertEqual(seen.first?.pointSize, policy.minPointSize,
                       "largest first: the body floor is tried before the in-place floor")
    }

    /// The structural half of "the two cannot diverge": the placement never
    /// constructs a font — it measures through the closure it is given — and
    /// the overlay view draws its bubble text through the feature's one font
    /// constructor, which is the measurer's own.
    func testThereIsExactlyOneFontPathBetweenMeasuringAndDrawing() {
        let ios = FeatureSourceScan.iosDirectory()
        let placement = ios.appendingPathComponent(
            "ElderlyAssistant/Services/LiveTranslate/LiveOverlayPlacement.swift")
        let overlay = ios.appendingPathComponent(
            "ElderlyAssistant/App/LiveTranslate/LiveTranslateOverlayView.swift")
        let control = ios.appendingPathComponent(
            "ElderlyAssistant/App/LiveTranslate/AlwaysShowOriginalControl.swift")

        let placementCode = FeatureSourceScan.codeText(of: placement)
        for forbidden in ["UIFont", "Font\\.system", "withDesign", "size\\(withAttributes"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: forbidden, in: placementCode),
                         "\(forbidden) in the placement is a second measurement path (R2)")
        }

        let overlayCode = FeatureSourceScan.codeText(of: overlay)
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "LiveOverlayTextMetrics\\.font\\(", in: overlayCode),
                        "the bubble text must be drawn through the one font constructor the measurer uses")
        for forbidden in ["UIFont", "Font\\.system", "withDesign", "\\.font\\(\\.system"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: forbidden, in: overlayCode),
                         "\(forbidden) in the overlay is a font the measurement never saw (R2)")
        }
        // The chrome's control is not measured overlay text: it draws in the
        // house font, which no measurement is claimed against.
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "DesignTokens\\.warmFont\\(",
                                                     in: FeatureSourceScan.codeText(of: control)))
    }

    // MARK: Scenario: no two boxes stack

    /// A dense scene — thirty signs on a five-column grid, each with room for
    /// its own short translation — renders with **no callouts at all** and with
    /// thirty boxes that do not overlap each other or any other region's
    /// printed text. This is the owner's "stacked and clustered" complaint
    /// answered as a property: the boxes share the gaps between the regions,
    /// each taking at most half of one.
    func testADenseSceneOfReadableSignsRendersEntirelyInPlaceAndNothingStacks() {
        var regions: [TextRegionStabilizer.StableTextRegion] = []
        var results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [:]
        let translations = ["गेट", "खुला", "बन्द", "निस्कने", "प्रवेश"]
        for row in 0..<6 {
            for column in 0..<5 {
                let id = row * 5 + column
                let xMin = 0.03 + Double(column) * 0.16
                let yMin = 0.04 + Double(row) * 0.15
                let region = region(id, text: "चिन्ह \(id)",
                                    box: (xMin, yMin, xMin + 0.13, yMin + 0.10))
                regions.append(region)
                results[region.id] = translated(region, translations[column])
            }
        }

        let placements = place(regions, results: results)

        XCTAssertEqual(placements.count, regions.count, "no region may vanish")
        for placement in placements {
            XCTAssertNotNil(inPlaceRect(placement),
                            "\(placement.region.id) fell back to a panel although its translation fits "
                            + "in place: the panel is the last resort, not the dense-scene render "
                            + "(owner UX rework)")
        }

        let boxes = placements.compactMap(inPlaceRect)
        XCTAssertEqual(boxes.count, regions.count)
        assertNoStacking(boxes, "in-place box")
        for placement in placements {
            let own = rect(of: placement.region)
            let box = inPlaceRect(placement)!
            XCTAssertTrue(box.insetBy(dx: -1e-9, dy: -1e-9).contains(own),
                          "the box covers its own region's printed text")
        }
    }

    /// Two regions that are **diagonal** neighbours — separated on both axes,
    /// close on both — must not stack either. They are separated on the axis
    /// they are further apart on, and each takes at most half of that gap.
    func testDiagonalNeighboursShareTheGapOnTheAxisTheyAreFurtherApartOn() {
        let lowerLeft = region(0, text: "गेट", box: (0.10, 0.40, 0.30, 0.48))
        let upperRight = region(1, text: "खुला", box: (0.33, 0.30, 0.53, 0.38))
        let results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [
            lowerLeft.id: translated(lowerLeft, "Gate"),
            upperRight.id: translated(upperRight, "Open")
        ]

        let placements = place([lowerLeft, upperRight], results: results)
        let boxes = placements.compactMap(inPlaceRect)
        XCTAssertEqual(boxes.count, 2, "both signs are readable in place")
        assertNoStacking(boxes, "diagonal in-place box")
    }

    /// The same property where the boxes are far bigger than the text: a row of
    /// tall signs whose ceiling would have them overlap if the growth were not
    /// bounded by the gap.
    func testARowOfNeighboursMeetsAtTheMidpointInsteadOfOverlapping() {
        var regions: [TextRegionStabilizer.StableTextRegion] = []
        var results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [:]
        for column in 0..<8 {
            let id = column
            let xMin = 0.02 + Double(column) * 0.125
            let region = region(id, text: "चिन्ह \(id)", box: (xMin, 0.45, xMin + 0.10, 0.55))
            regions.append(region)
            results[region.id] = translated(region, "Open")
        }

        let boxes = place(regions, results: results).compactMap(inPlaceRect)

        XCTAssertEqual(boxes.count, regions.count)
        assertNoStacking(boxes, "neighbouring box")
        for column in 0..<(boxes.count - 1) {
            let left = boxes[column]
            let right = boxes[column + 1]
            XCTAssertLessThanOrEqual(left.maxX, right.minX + 1e-9,
                                     "left to right, in reading order, no box crosses another")
            XCTAssertGreaterThanOrEqual(left.maxX, rect(of: regions[column]).maxX - 1e-9)
        }
    }

    // MARK: Scenario: a panel stands on the text it replaces

    /// A frame of unfittable signs **at the density the app can actually
    /// publish**: the stabiliser caps one frame at `declutterMaxRegions`, so
    /// these are the most fallback surfaces a frame can carry. Every one of them
    /// is a panel standing on its own region's rect — which, unlike the pill it
    /// replaces, *does* cover that region's printed text: that is the point of
    /// the form, "overlay text on top of the original text" — and, at this
    /// density, no two panels stack: the owner's "stacked and clustered"
    /// complaint answered for the fallback form, not only for the boxes.
    func testPanelsAtTheAppsOwnDensityStandOnTheirOwnTextAndNeverStack() {
        let cap = LiveTranslateConfig.default.declutterMaxRegions
        var regions: [TextRegionStabilizer.StableTextRegion] = []
        var results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [:]
        for index in 0..<cap {
            let column = Double(index % 3)
            let row = Double(index / 3)
            let xMin = 0.04 + column * 0.32
            let yMin = 0.04 + row * 0.28
            let region = region(index, text: "Sign \(index)",
                                box: (xMin, yMin, xMin + 0.14, yMin + 0.10))
            results[region.id] = .degraded(originalText: region.text, reason: .noNetwork)
            regions.append(region)
        }

        let placements = place(regions, results: results)
        XCTAssertEqual(placements.count, regions.count, "no region may vanish")

        var panels: [CGRect] = []
        for placement in placements {
            assertNoCallout(placement, "a degraded region at the published density")
            guard let panelRect = scrollableRect(placement) else {
                XCTFail("a degraded region is the panel on its own rect, never a bubble "
                        + "beside it: \(placement.form)")
                continue
            }
            panels.append(panelRect)
            let own = rect(of: placement.region)
            XCTAssertTrue(panelRect.insetBy(dx: -1e-9, dy: -1e-9).contains(own),
                          "the panel for \(placement.region.id) stands on its own region's "
                          + "printed text")
            XCTAssertTrue(bounds.insetBy(dx: -0.001, dy: -0.001).contains(panelRect),
                          "and it stays inside the safe area")
        }
        XCTAssertEqual(panels.count, regions.count)
        assertNoStacking(panels, "panel")
    }

    /// The same scripted set, deliberately past what a frame can carry
    /// (twenty-five simultaneous fallbacks is nearly three times the
    /// stabiliser's cap). The *totality* claim still holds absolutely — every
    /// region is placed, every placement is a panel, and every panel has a box
    /// on the screen that stands on the text it belongs to. What an
    /// over-constrained frame can lose is the no-stacking property, which is
    /// why the cap is what keeps the app out of this regime; the pill's old
    /// hard constraint is not recoverable here at all, because both of the
    /// surfaces this stage has are drawn *on* the text by design.
    func testAnOverConstrainedFrameStillPlacesEveryRegionAsAPanelOnItsOwnText() {
        var regions: [TextRegionStabilizer.StableTextRegion] = []
        var results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [:]
        for row in 0..<5 {
            for column in 0..<5 {
                let id = row * 5 + column
                let xMin = 0.02 + Double(column) * 0.19
                let yMin = 0.02 + Double(row) * 0.19
                let region = region(id, text: "Sign \(id)",
                                    box: (xMin, yMin, xMin + 0.15, yMin + 0.12))
                results[region.id] = .degraded(originalText: region.text, reason: .noNetwork)
                regions.append(region)
            }
        }

        let placements = place(regions, results: results)
        XCTAssertEqual(placements.count, regions.count, "no region may vanish")

        var panels: [CGRect] = []
        for placement in placements {
            assertNoCallout(placement, "a degraded region in an over-constrained frame")
            guard let panelRect = scrollableRect(placement) else {
                XCTFail("every region here has a rect, so every region gets a panel: "
                        + "\(placement.form)")
                continue
            }
            panels.append(panelRect)
            XCTAssertTrue(bounds.insetBy(dx: -0.001, dy: -0.001).contains(panelRect),
                          "the panel for \(placement.region.id) is still inside the screen")
            XCTAssertTrue(panelRect.insetBy(dx: -1e-9, dy: -1e-9).contains(rect(of: placement.region)),
                          "…and still stands on its own region's printed text")
        }
        XCTAssertEqual(panels.count, regions.count)
    }

    // MARK: Scenario: a panel shows both texts

    /// The fallback surface's two lines, at the sizes the elder reads them at.
    func testAResolvedPanelShowsTheTranslationAndTheOriginal() {
        // A sign far too small for its translation at any allowed size: the two
        // lines are what the panel exists for.
        let region = region(0, text: "यो सानो चिन्ह हो", box: (0.05, 0.4, 0.15, 0.42))
        let result = translated(region, "This is a small sign with a long translation", tier: .cloud)
        let policy = surfacePolicy()
        let placements = place([region], results: [region.id: result])

        assertNoCallout(placements[0], "a translation too long for its own box")
        XCTAssertNotNil(scrollableRect(placements[0]))
        XCTAssertEqual(placements[0].lines.map(\.text),
                       ["This is a small sign with a long translation", "यो सानो चिन्ह हो"],
                       "a panel shows the translation and the original — both (T-020)")
        XCTAssertEqual(placements[0].lines[0].weight, .primary)
        XCTAssertEqual(placements[0].lines[0].pointSize, policy.minPointSize)
        XCTAssertEqual(placements[0].lines[1].weight, .secondary)
        XCTAssertEqual(placements[0].lines[1].pointSize, policy.secondaryPointSize)
        XCTAssertLessThanOrEqual(placements[0].lines[1].pointSize, placements[0].lines[0].pointSize,
                                 "the supporting line is the smaller one")
        XCTAssertGreaterThanOrEqual(placements[0].lines[0].pointSize,
                                    LiveTranslateConfig.default.overlayMinPointSize,
                                    "Nepali primary text is elder-readable on a panel (FR-LCT-015)")
    }

    func testAnUnresolvedPanelShowsTheRecognizedTextAndTheHonestStateLine() {
        let region = region(0, text: "Pharmacy", box: (0.05, 0.4, 0.95, 0.5))
        let result = TranslationResult.degraded(originalText: region.text, reason: .noNetwork)
        let stateCopy = { (result: TranslationResult) -> String? in
            result.degraded ? "अनुवाद उपलब्ध छैन" : nil
        }

        let placements = place([region], results: [region.id: result], stateCopy: stateCopy)

        assertNoCallout(placements[0], "a degraded region")
        XCTAssertEqual(placements[0].lines.map(\.text), ["Pharmacy", "अनुवाद उपलब्ध छैन"],
                       "the elder sees what was recognized next to what is true about it — never a "
                       + "translated-looking string (FR-LCT-018)")
        XCTAssertEqual(placements[0].lines.first?.weight, .primary)
    }

    // MARK: Scenario: the fallback always has a box

    /// A region that fills the safe area is the case the old callout recorded
    /// as a clamped corner case (`isClampedFallback`). The panel needs no such
    /// flag: its box *is* the region's own grown box, which this frame has, so
    /// the placement is an ordinary one and nothing is flagged.
    func testARoomySceneIsDrawnAsAnOrdinaryPanelAndNotFlagged() {
        let region = region(0, text: "Pharmacy", box: (0.0, 0.25, 1.0, 1.0))

        let placements = place([region],
                               results: [region.id: .degraded(originalText: region.text,
                                                             reason: .noNetwork)])
        let placement = placements[0]

        assertNoCallout(placement, "a region with room around it")
        XCTAssertFalse(placement.isClampedFallback,
                       "the flag is never set: `place` has no clamped fallback any more (OD5)")
        guard let panelRect = scrollableRect(placement) else {
            return XCTFail("the fallback is the panel: \(placement.form)")
        }
        let own = rect(of: region)
        XCTAssertTrue(bounds.insetBy(dx: -1e-9, dy: -1e-9).contains(panelRect),
                      "the panel is inside the screen")
        // This region is taller than the panel cap, so the panel is the capped
        // band across the middle of the text it stands on: the whole width it
        // has, centred on the region, and the cap reached rather than undershot
        // (the elder's share of the container, spent on the line they are
        // already looking at).
        XCTAssertEqual(panelRect.midY, own.midY, accuracy: 1e-9,
                       "it stands over the middle of the text it replaces")
        XCTAssertEqual(panelRect.width, bounds.width, accuracy: 1e-9,
                       "…at the width the region has to give")
        XCTAssertEqual(panelRect.height, container.height * 0.45, accuracy: 1e-9,
                       "…and at the configured share of the container")
    }

    /// The region *is* the safe area: its own rect has no room to grow in and
    /// the panel takes it as it is. The placement still produces a surface the
    /// elder can read, inside the screen — which is the property the clamped
    /// pill used to have to be rescued by a flag for.
    func testAFullScreenRegionStillGetsAPanelInsideTheScreen() {
        let region = region(0, text: "Pharmacy", box: (0.0, 0.0, 1.0, 1.0))

        let placements = place([region],
                               results: [region.id: .degraded(originalText: region.text,
                                                             reason: .noNetwork)])
        let placement = placements[0]

        assertNoCallout(placement, "a full-screen region")
        guard let panelRect = scrollableRect(placement) else {
            return XCTFail("even this region gets a panel — the box is its own rect: "
                           + "\(placement.form)")
        }
        XCTAssertTrue(bounds.insetBy(dx: -1e-9, dy: -1e-9).contains(panelRect),
                      "the panel is inside the screen even though the region is the whole of it")
        XCTAssertEqual(panelRect.width, bounds.width, accuracy: 1e-9)
        XCTAssertEqual(panelRect.midY, rect(of: region).midY, accuracy: 1e-9,
                       "centred on the text it replaces: the region's own rect is the only "
                       + "anchor this frame has to give")
    }

    // MARK: Scenario: placement is pure, deterministic and bounded

    func testTheSameInputsProduceIdenticalPlacementsTwice() {
        let regions = (0..<6).map { index in
            region(index, text: "Sign \(index)",
                   box: (0.05 + Double(index) * 0.15, 0.1 + Double(index) * 0.12,
                         0.15 + Double(index) * 0.15, 0.2 + Double(index) * 0.12))
        }
        var results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [:]
        for (index, region) in regions.enumerated() {
            results[region.id] = index.isMultiple(of: 2)
                ? translated(region, "खुल्ने समय", tier: .cloud)
                : .degraded(originalText: region.text, reason: .noNetwork)
        }

        let first = place(regions, results: results)
        let second = place(Array(regions.reversed()), results: results)

        XCTAssertEqual(first, second,
                       "the placements are a function of the input set, not of the order it arrived in")
        for placement in first { assertNoCallout(placement, "a mixed scene") }
        assertNoStacking(first.compactMap(inPlaceRect), "in-place box")
        assertNoStacking(first.compactMap(scrollableRect), "panel")
    }

    func testTheCostPerRegionIsBounded() {
        final class Counter { var value = 0 }
        let counter = Counter()
        let measure: LiveOverlayPlacement.Measure = { text, pointSize, weight, width in
            counter.value += 1
            return LiveOverlayTextMetrics.measure(text, pointSize: pointSize,
                                                  weight: weight, width: width)
        }
        // Forty one-line signs, each with a translation far too long to stand in
        // its own box: every region takes the full in-place scan and then the
        // panel.
        let regions = (0..<40).map { index in
            region(index, text: "Sign \(index)",
                   box: (0.05, 0.02 + Double(index) * 0.024, 0.6, 0.035 + Double(index) * 0.024))
        }
        let results = Dictionary(uniqueKeysWithValues: regions.map {
            ($0.id, translated($0, "this translation is far too long for a sign this small"))
        })

        let placements = place(regions, results: results, measure: measure)

        XCTAssertEqual(placements.count, regions.count)
        // Two in-place candidates at most (the body floor, then the in-place
        // floor) — and nothing at all for the panel rung: the panel's box is a
        // rect law, not a fit, and its lines are drawn at the one floor the
        // panel path already fixed. So the cost per region is a constant that
        // neither the scene nor the string can move (NFR-LCT-002), and it went
        // *down* when the pill was removed.
        XCTAssertLessThanOrEqual(counter.value, 2 * regions.count,
                                 "a fixed number of measurements per region — no loop that grows with "
                                 + "the scene (NFR-LCT-002)")
        XCTAssertGreaterThanOrEqual(counter.value, regions.count,
                                    "every region was actually measured; a skip would prove nothing")
        for placement in placements { assertNoCallout(placement, "an unfittable translation") }

        // The panel rung, on its own: a scene of pending regions draws a surface
        // for every one of them without asking a single measurement question.
        counter.value = 0
        let pending = place(regions, results: [:], measure: measure)
        XCTAssertEqual(pending.count, regions.count)
        XCTAssertEqual(counter.value, 0,
                       "the panel is total without being measured: it has a box for every "
                       + "region that has a rect, and draws no text it has to size first")
    }

    func testThePlacementReadsNoClockPerformsNoIOAndAwaitsNothing() {
        let file = FeatureSourceScan.iosDirectory().appendingPathComponent(
            "ElderlyAssistant/Services/LiveTranslate/LiveOverlayPlacement.swift")
        let code = FeatureSourceScan.codeText(of: file)
        XCTAssertFalse(code.isEmpty)

        for forbidden in ["\\bDate\\b", "CFAbsoluteTime", "URLSession", "FileManager", "DispatchQueue",
                          "\\bTask\\b", "\\bawait\\b", "NotificationCenter", "UserDefaults",
                          "Bundle\\.", "ProcessInfo", "print\\(", "NSLog", "os_log"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: forbidden, in: code),
                         "\(forbidden) in the placement makes a frame's cost unbounded — this stage must "
                         + "be pure (NFR-LCT-002)")
        }
    }

    // MARK: Totality: nothing disappears, nothing is drawn at the origin

    func testARegionWithNoResultIsPlacedAsPendingWithItsRecognizedText() {
        let region = region(0, text: "Pharmacy", box: (0.1, 0.4, 0.9, 0.5))
        let placements = place([region], results: [:])

        XCTAssertEqual(placements.count, 1, "a tier that has not answered must not remove a region")
        XCTAssertEqual(placements[0].result.outcome, .pending(originalText: "Pharmacy"))
        XCTAssertEqual(placements[0].lines.map(\.text), ["Pharmacy"],
                       "with no state copy supplied the recognized text is still what is drawn")
    }

    func testADegenerateContainerOrFrameYieldsNoPlacements() {
        let region = region(0, text: "Pharmacy", box: (0.1, 0.4, 0.9, 0.5))
        let results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [
            region.id: .pending(region.text)
        ]

        for (size, frame) in [(CGSize.zero, container), (container, CGSize.zero)] {
            let placements = LiveOverlayPlacement.place(
                regions: [region], results: results, containerSize: size, framePixelSize: frame,
                safeArea: bounds, policy: surfacePolicy(),
                stateCopy: { _ in nil })
            XCTAssertEqual(placements, [], "nothing can be positioned in a degenerate container")
        }
    }

    func testARegionWhoseBoxCannotBeGeometryIsNotDrawnAtTheOrigin() {
        let broken = region(0, text: "Pharmacy", box: (0.5, 0.5, 0.5, 0.5))
        XCTAssertFalse(broken.box.isValid)

        XCTAssertEqual(place([broken], results: [:]), [],
                       "the stabiliser never publishes such a region; the placement's guard is totality, "
                       + "not a licence to draw nonsense at (0, 0)")
    }

    func testAnEmptySafeAreaFallsBackToTheContainerRect() {
        let region = region(0, text: "Pharmacy", box: (0.1, 0.05, 0.9, 0.15))
        let results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [
            region.id: .degraded(originalText: region.text, reason: .noNetwork)
        ]
        let placements = place([region], results: results, safeArea: .zero)
        let panelRect = scrollableRect(placements[0])!

        XCTAssertGreaterThanOrEqual(panelRect.minY, 0)
        XCTAssertLessThanOrEqual(panelRect.maxY, container.height)
    }

    func testTheOutputIsInReadingOrder() {
        let bottom = region(0, text: "Bottom", box: (0.1, 0.8, 0.4, 0.9))
        let topRight = region(1, text: "Top right", box: (0.6, 0.1, 0.9, 0.2))
        let topLeft = region(2, text: "Top left", box: (0.1, 0.1, 0.4, 0.2))
        let results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [
            bottom.id: .degraded(originalText: bottom.text, reason: .noNetwork),
            topRight.id: .degraded(originalText: topRight.text, reason: .noNetwork),
            topLeft.id: .degraded(originalText: topLeft.text, reason: .noNetwork)
        ]

        let placements = place([bottom, topRight, topLeft], results: results)

        XCTAssertEqual(placements.map(\.region.id.rawValue), [2, 1, 0],
                       "top to bottom, then left to right — the order a spoken reading walks (C12)")
    }

    // MARK: Block panels (scene-block rework, 2026-09-18)

    /// A **block**: one region whose text is several lines, which is exactly
    /// what the grouper's separator means to the placement.
    private func blockRegion(_ rawID: Int,
                             lines: [String],
                             box: (Double, Double, Double, Double))
        -> TextRegionStabilizer.StableTextRegion {
        region(rawID, text: lines.joined(separator: "\n"), box: box)
    }

    func testAResolvedBlockIsOnePanelCarryingEveryLineInOrder() {
        let block = blockRegion(1, lines: ["START", "2 MIN"], box: (0.10, 0.30, 0.70, 0.60))
        let policy = surfacePolicy()
        let result = translated(block, "सुरु\n२ मिनेट", tier: .cloud)

        let placements = place([block], results: [block.id: result])

        XCTAssertEqual(placements.count, 1,
                       "a block is one surface: no per-line callouts in live mode")
        let panel = placements[0]
        XCTAssertNotNil(inPlaceRect(panel), "a resolved block stands on its own rect")
        assertNoCallout(panel, "a resolved block")
        XCTAssertEqual(panel.lines.map(\.text), ["सुरु", "२ मिनेट"],
                       "the translated lines in the order they were recognized")
        XCTAssertEqual(panel.lines.map(\.pointSize),
                       [policy.minPointSize, policy.minPointSize],
                       "one panel is drawn at one size — the body floor — not per-line sizes")
        XCTAssertEqual(Set(panel.lines.map(\.weight)), [.primary])
    }

    func testThePanelFloorIsTheBodyFloorAndItIsAboveTheOwnersBound() {
        let policy = surfacePolicy()
        XCTAssertEqual(LiveOverlayPlacement.panelPointSize(policy: policy), policy.minPointSize,
                       "a panel is drawn at the body floor or not at all: shrinking it is "
                       + "exactly the illegible small type the rework removes")
        XCTAssertGreaterThanOrEqual(policy.minPointSize, 18,
                                    "the owner's bound on a live translation line")
    }

    func testAlwaysShowOriginalStacksTheOriginalLinesUnderTheTranslation() {
        let block = blockRegion(1, lines: ["OPEN", "7AM"], box: (0.10, 0.30, 0.70, 0.60))
        let policy = surfacePolicy(alwaysShowOriginal: true)
        let result = translated(block, "खुला\nबिहान ७", tier: .cloud)

        let placements = place([block], results: [block.id: result], policy: policy)

        XCTAssertEqual(placements.first?.lines.map(\.text), ["खुला", "बिहान ७", "OPEN", "7AM"],
                       "the preference is honoured in the panel too, translation first")
        XCTAssertEqual(placements.first?.lines.filter { $0.weight == .secondary }.map(\.pointSize),
                       [policy.secondaryPointSize, policy.secondaryPointSize])
    }

    // MARK: Bounded panels (owner refinement, 2026-09-18)

    /// The owner's device verdict, at the line it is about: **a block the panel
    /// cannot hold is still published.**
    ///
    /// The rework's first cut left `place` with a bare `continue` here, so a
    /// pass whose blocks all failed the panel fit produced no placements at
    /// all — and the overlay renders an empty placement list as its empty
    /// state, "I don't see any text yet", over a picture full of text the pass
    /// had just read. Since most regions of a real scene are multi-line blocks
    /// (the object grouping merges them), that was most scenes on the owner's
    /// device: "the camera says it can't find anything to read".
    ///
    /// The owner's refinement (2026-09-18) then named the form such a block
    /// gets: not a pill showing its first line, but the **bounded panel** — the
    /// same surface, every line, the same body floor, in a box capped at
    /// `panelMaxHeightFraction` of the container and scrolled rather than
    /// truncated. The policy itself is unchanged — a panel is drawn at the
    /// floor or not at all, never shrunk — so this pins both halves: the panel
    /// decision still refuses an illegible fit, and the refusal degrades to a
    /// surface carrying *all* of the block's lines.
    func testABlockTooTallForItsOwnBoxIsDrawnAsABoundedScrollablePanel() {
        // Four translated lines at the body floor need well over 100 pt; this
        // block's own printed box is 50 pt tall and may grow 40 % — so the
        // plain panel cannot hold them, and the bounded one is the answer.
        let block = blockRegion(1, lines: ["one", "two", "three", "four"],
                                box: (0.42, 0.44, 0.50, 0.50))
        let policy = surfacePolicy()
        let result = translated(block, "एक\nदुई\nतीन\nचार", tier: .cloud)

        let outcome = LiveOverlayPlacement.panelOutcome(regionRect: rect(of: block),
                                                        lines: LiveOverlayPlacement.panelLines(
                                                            result.text,
                                                            pointSize: policy.minPointSize),
                                                        bounds: bounds,
                                                        policy: policy)
        XCTAssertEqual(outcome, .doesNotFit,
                       "the panel rule is unchanged: the lines are drawn at the floor, so a box "
                       + "too short for them is not a panel — which is this test's premise")

        let placements = place([block], results: [block.id: result])

        XCTAssertEqual(placements.count, 1,
                       "a block the panel cannot hold is still published: an empty placement "
                       + "list is the overlay's empty state over text the pass read")
        let panel = placements[0]
        guard let box = scrollableRect(panel) else {
            return XCTFail("the block is drawn as the bounded panel — every line it has, at the "
                           + "floor, in a box the elder reads in place: \(panel.form)")
        }
        XCTAssertEqual(LiveOverlayPlacement.boundedPanelOutcome(regionRect: rect(of: block),
                                                                bounds: bounds,
                                                                containerSize: container,
                                                                policy: policy),
                       .fits(box: box),
                       "the decision's own box is the box that was drawn: the two cannot "
                       + "disagree about where the panel is")
        assertNoCallout(panel, "a block too tall for its own box")
        XCTAssertEqual(panel.lines.map(\.text), ["एक", "दुई", "तीन", "चार"],
                       "the block's translated lines, in order — all of them, not the ones that "
                       + "happened to fit the block's own box")
        XCTAssertEqual(Set(panel.lines.map(\.pointSize)), [policy.minPointSize],
                       "the bounded panel is drawn at the body floor, like every live surface: "
                       + "the cap costs scroll, never type size")
        XCTAssertEqual(Set(panel.lines.map(\.weight)), [.primary])

        // The box: the block's own grown box, cleared and on screen.
        let own = rect(of: block)
        XCTAssertLessThanOrEqual(box.height, own.height * CGFloat(policy.inPlaceMaxGrowth) + 1e-9,
                                 "the panel takes only the room the half-gap law gives this "
                                 + "block — the same ceiling the plain panel is measured against")
        XCTAssertLessThanOrEqual(box.width, own.width * CGFloat(policy.inPlaceMaxGrowth) + 1e-9)
        XCTAssertTrue(bounds.insetBy(dx: -1e-9, dy: -1e-9).contains(box),
                      "and it stays inside the safe area the rects were measured in")
        XCTAssertEqual(box.midY, own.midY, accuracy: 1e-6,
                       "it stands over the text it replaces")
    }

    /// The cap itself, at the value the owner named: a bounded panel never
    /// takes more than its fraction of the container, and a block whose own
    /// grown box is *taller* than the cap is drawn at exactly the cap — the
    /// bound is reached, not undershot, so the elder gets the most room the
    /// rule allows.
    func testTheBoundedPanelIsCappedAtTheConfiguredFractionOfTheContainer() {
        let lines = (1...24).map { "लाइन \($0)" }
        let block = blockRegion(1, lines: lines, box: (0.10, 0.10, 0.90, 0.50))
        let policy = surfacePolicy()
        let result = translated(block, lines.joined(separator: "\n"), tier: .cloud)

        let placements = place([block], results: [block.id: result])
        guard let box = scrollableRect(placements[0]) else {
            return XCTFail("a page of text is the bounded panel's case: \(placements[0].form)")
        }

        let cap = container.height * CGFloat(policy.panelMaxHeightFraction)
        XCTAssertLessThanOrEqual(box.height, cap + 1e-9,
                                 "the last-resort surface is bounded: a block may not become "
                                 + "the screen")
        XCTAssertEqual(box.height, cap, accuracy: 1e-6,
                       "…and the bound is what it is drawn at, not less")
        XCTAssertLessThan(box.height,
                          rect(of: block).height * CGFloat(policy.inPlaceMaxGrowth),
                          "the premise: this block's own grown box is taller than the cap")
        XCTAssertEqual(placements[0].lines.count, 24,
                       "the cap costs scroll, never lines")
        if let chrome = LiveTranslateOverlaySurface.chromeRects(containerSize: container).first {
            XCTAssertLessThanOrEqual(box.maxY, chrome.minY,
                                     "and the panel stays clear of the overlay's own control")
        }
    }

    /// The cap is the config's value, a fraction of the container — not a point
    /// size, not a literal in the placement, and never past the safe area.
    func testTheBoundedPanelsCapIsTheConfigsFractionAndTheSafeAreasRoom() {
        let policy = surfacePolicy()
        XCTAssertEqual(policy.panelMaxHeightFraction,
                       LiveTranslateConfig.default.panelMaxHeightFraction,
                       "the cap the placement measures against is the config's value")
        XCTAssertEqual(policy.panelMaxHeightFraction, 0.45)
        XCTAssertEqual(LiveOverlayPlacement.panelMaxHeight(containerSize: container,
                                                           bounds: bounds,
                                                           policy: policy),
                       container.height * 0.45, accuracy: 1e-6,
                       "…a fraction of the container the rects were measured in, so a "
                       + "rotation or another device gets the same share of the view")
        XCTAssertEqual(LiveOverlayPlacement.panelMaxHeight(
            containerSize: container,
            bounds: CGRect(x: 0, y: 0, width: 390, height: 300),
            policy: policy),
                       300,
                       "…and never taller than the safe area it is drawn in")
    }

    /// The plain panel keeps its block: the bounded form is the fallback for a
    /// block that does not fit, never a second way to draw one that does.
    func testABlockThatFitsIsAPlainPanelAndNeverAScrollingOne() {
        let block = blockRegion(1, lines: ["START", "2 MIN"], box: (0.10, 0.30, 0.70, 0.60))

        let placements = place([block],
                               results: [block.id: translated(block, "सुरु\n२ मिनेट", tier: .cloud)])

        XCTAssertNotNil(inPlaceRect(placements[0]),
                        "a block whose lines fit its box is the plain panel it always was")
        XCTAssertNil(scrollableRect(placements[0]),
                     "nothing scrolls when there is nothing to scroll")
    }

    /// The half-gap law is the same law for the new form: two blocks that both
    /// need the bounded panel still meet at the midpoint of the gap between
    /// them rather than stacking.
    func testTwoBoundedPanelsNeverStack() {
        let lines = (1...24).map { "लाइन \($0)" }
        let text = lines.joined(separator: "\n")
        let first = blockRegion(1, lines: lines, box: (0.03, 0.10, 0.45, 0.50))
        let second = blockRegion(2, lines: lines, box: (0.55, 0.10, 0.97, 0.50))

        let placements = place([first, second],
                               results: [first.id: translated(first, text, tier: .cloud),
                                         second.id: translated(second, text, tier: .cloud)])

        XCTAssertEqual(placements.count, 2)
        let boxes = placements.compactMap(scrollableRect)
        XCTAssertEqual(boxes.count, 2, "both blocks are bounded panels: \(placements.map(\.form))")
        assertNoStacking(boxes, "the two bounded panels")
    }

    /// The FR-LCT-017 preference reaches the bounded panel exactly as it
    /// reaches the plain one: the translation first, the original under it.
    func testABoundedPanelCarriesTheOriginalLinesUnderTheTranslation() {
        let original = ["one", "two", "three", "four"]
        let block = blockRegion(1, lines: original, box: (0.42, 0.44, 0.50, 0.50))
        let policy = surfacePolicy(alwaysShowOriginal: true)
        let result = translated(block, "एक\nदुई\nतीन\nचार", tier: .cloud)

        let placements = place([block], results: [block.id: result], policy: policy)
        guard let panel = placements.first else {
            return XCTFail("the block must be placed")
        }

        XCTAssertNotNil(scrollableRect(panel), "this block's lines do not fit its own box")
        XCTAssertEqual(panel.lines.map(\.text), ["एक", "दुई", "तीन", "चार"] + original,
                       "every translated line, then every original one, in the order the "
                       + "panel draws them")
        XCTAssertEqual(panel.lines.filter { $0.weight == .secondary }.map(\.pointSize),
                       Array(repeating: policy.secondaryPointSize, count: original.count),
                       "the original stays the supporting line, at the supporting size")
    }

    func testTwoPanelsNeverStack() {
        let first = blockRegion(1, lines: ["A1", "A2"], box: (0.05, 0.05, 0.45, 0.25))
        let second = blockRegion(2, lines: ["B1", "B2"], box: (0.55, 0.05, 0.95, 0.25))
        let placements = place([first, second],
                               results: [first.id: translated(first, "क\nख", tier: .cloud),
                                         second.id: translated(second, "ग\nघ", tier: .cloud)])

        XCTAssertEqual(placements.count, 2)
        let boxes = placements.compactMap(inPlaceRect)
        XCTAssertEqual(boxes.count, 2, "both blocks are panels")
        XCTAssertFalse(boxes[0].intersects(boxes[1]),
                       "the half-gap law holds for panels exactly as it does for lines")
    }

    func testAnUnresolvedBlockIsTheSamePanelCarryingTheHonestState() {
        let block = blockRegion(1, lines: ["START", "2 MIN"], box: (0.10, 0.30, 0.70, 0.60))

        let placements = place([block], stateCopy: { _ in "पर्खंदै" })

        XCTAssertEqual(placements.count, 1,
                       "a tier that has not answered must not make a recognized block vanish")
        XCTAssertNotNil(inPlaceRect(placements[0]),
                        "the surface stands where the text stood and fills in, rather than "
                        + "a box appearing beside it to be replaced")
        assertNoCallout(placements[0], "a block no tier has answered for")
        XCTAssertEqual(placements[0].lines.map(\.text), ["पर्खंदै"])
    }

    func testAnUnresolvedBlockWithNoStateCopyStillShowsItsOwnLines() {
        let block = blockRegion(1, lines: ["START", "2 MIN"], box: (0.10, 0.30, 0.70, 0.60))

        let placements = place([block], stateCopy: { _ in nil })

        XCTAssertEqual(placements.map { $0.lines.map(\.text) }, [["START", "2 MIN"]],
                       "with nothing honest to say yet, the block's own recognized lines "
                       + "stand in — the region never vanishes (NFR-LCT-010)")
    }

    func testPanelLinesDropBlankRowsAndKeepTheRecognizedOrder() {
        let lines = LiveOverlayPlacement.panelLines("first\n\nsecond\n\n", pointSize: 21)
        XCTAssertEqual(lines.map(\.text), ["first", "second"],
                       "a blank row is not text the elder reads, and drawing it spends "
                       + "panel height on nothing")
        XCTAssertEqual(lines.map(\.weight), [.primary, .primary])
    }

    func testPanelTextSizeStacksItsLinesWithThePolicySpacing() {
        let lines = [LiveOverlayTextLine(text: "one", pointSize: 20, weight: .primary),
                     LiveOverlayTextLine(text: "two", pointSize: 20, weight: .primary),
                     LiveOverlayTextLine(text: "three", pointSize: 20, weight: .primary)]
        let measure: LiveOverlayPlacement.Measure = { text, pointSize, _, width in
            CGSize(width: min(CGFloat(text.count) * pointSize, width), height: pointSize)
        }
        let size = LiveOverlayPlacement.panelTextSize(lines, lineSpacing: 4,
                                                      maxWidth: 500, measure: measure)
        XCTAssertEqual(size.height, 3 * 20 + 2 * 4, "three lines, two gaps")
        XCTAssertEqual(size.width, 5 * 20, "the widest line decides the width")
    }

    func testABlockIsASingleLineRegionOnlyWhenItHoldsOneLine() {
        let single = region(1, text: "EXIT", box: (0.1, 0.1, 0.4, 0.2))
        let multi = blockRegion(2, lines: ["EXIT", "FIRE"], box: (0.1, 0.4, 0.4, 0.6))

        XCTAssertFalse(LiveOverlayPlacement.isBlock(single),
                       "one recognized line is the path it always was")
        XCTAssertTrue(LiveOverlayPlacement.isBlock(multi),
                      "the grouper's separator is the one deterministic signal of a block")
    }

}
