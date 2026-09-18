import CoreGraphics
import XCTest
@testable import ElderlyAssistant

/// Extract mode (owner verdict, 2026-09-18) — the half of the OCR-first rework
/// that is a *value* rather than a pipeline: what the overlay draws when the
/// elder is looking at the recognized text instead of a translation, and what
/// a tap on one of those blocks means.
///
/// The mode is deliberately not a second placement. The boxes, the growth
/// budget, the never-cover law, the ordering and the measured lines are the
/// same code; one flag decides which of the two things the elder is looking at
/// is the normal case, and the claims here are about exactly that difference:
///
///  - an untranslated region **is** placed, in place, carrying its own
///    recognized text — where the translated view would have found nothing to
///    draw (NFR-LCT-010's never-empty rule, which this mode makes the default
///    rather than the exception);
///  - the honest state sentence ("translating…") is not said about work the
///    mode has not started, and *is* said when a translation the elder asked
///    for did not arrive (FR-LCT-018);
///  - a tap on a block asks for **that** block (which the pipeline suite
///    pins end to end; here it is the presentation's own claim);
///  - every law the mode does *not* change still holds: the fit is measured
///    before the box is returned, the floor is never traded away for the fit,
///    and the FR-LCT-017 preference outlives the mode toggle.
final class LiveTranslateExtractModeTests: XCTestCase {

    private let container = CGSize(width: 390, height: 844)
    private let locale = Locale(identifier: "ne_NP")

    /// The catalog's pending sentence, as the app hands it in. The placement
    /// takes a closure precisely so it stays copy-free, so what this file
    /// asserts about the sentence is *whether it is asked for*, never what it
    /// says — the string is a stand-in for the catalog's own.
    private let stateSentence = "अनुवाद हुँदैछ"

    // MARK: - Builders

    private func region(_ rawID: Int = 0,
                        text: String,
                        box: (Double, Double, Double, Double) = (0.2, 0.30, 0.8, 0.40),
                        confidence: Double = 0.9) -> TextRegionStabilizer.StableTextRegion {
        TextRegionStabilizer.StableTextRegion(
            id: TextRegionStabilizer.RegionIdentity(rawValue: rawID),
            text: text,
            normalizedText: LiveTranslateTextNormalization.normalized(text),
            box: NormalizedBox(xMin: box.0, yMin: box.1, xMax: box.2, yMax: box.3),
            detectedLanguage: "en",
            confidence: confidence)
    }

    private func extractPolicy(alwaysShowOriginal: Bool = false) -> LiveOverlayPlacement.Policy {
        LiveTranslateOverlaySurface.policy(config: .default,
                                           alwaysShowOriginal: alwaysShowOriginal,
                                           extractionMode: true)
    }

    private func translatedViewPolicy(alwaysShowOriginal: Bool = false) -> LiveOverlayPlacement.Policy {
        LiveTranslateOverlaySurface.policy(config: .default,
                                           alwaysShowOriginal: alwaysShowOriginal,
                                           extractionMode: false)
    }

    private var bounds: CGRect { CGRect(origin: .zero, size: container) }

    /// The placement, with the state sentence the app's catalog supplies for
    /// anything unresolved — which is what makes "the mode does not say it"
    /// an assertion about the placement rather than about a closure the test
    /// forgot to pass.
    private func place(_ regions: [TextRegionStabilizer.StableTextRegion],
                       results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [:],
                       policy: LiveOverlayPlacement.Policy,
                       stateCopy: ((TranslationResult) -> String?)? = nil)
        -> [LiveOverlayPlacement.PlacedOverlay] {
        LiveOverlayPlacement.place(regions: regions,
                                   results: results,
                                   containerSize: container,
                                   framePixelSize: container,
                                   safeArea: bounds,
                                   policy: policy,
                                   stateCopy: stateCopy ?? { _ in self.stateSentence },
                                   measure: LiveOverlayTextMetrics.measure)
    }

    private func outcome(_ regionRect: CGRect,
                         result: TranslationResult,
                         policy: LiveOverlayPlacement.Policy) -> LiveOverlayPlacement.InPlaceOutcome {
        LiveOverlayPlacement.inPlaceOutcome(regionRect: regionRect,
                                            result: result,
                                            obstacles: [],
                                            bounds: bounds,
                                            policy: policy,
                                            measure: LiveOverlayTextMetrics.measure)
    }

    private func rect(of region: TextRegionStabilizer.StableTextRegion) -> CGRect {
        LiveOverlayPlacement.screenRect(for: region.box, containerSize: container,
                                        framePixelSize: container)
    }

    // MARK: - The extracted text is the content

    /// The mode's whole point: a region nothing has translated is drawn where
    /// it stood, in its own words, at the body floor.
    func testExtractModeDrawsTheRecognizedTextWhereItStood() throws {
        let sign = region(text: "PREWASH 40")
        let placed = place([sign], policy: extractPolicy())

        let placement = try XCTUnwrap(placed.first, "an extract-mode pass draws every region it read")
        guard case .inPlace(_, let box) = placement.form else {
            return XCTFail("the recognized text fits where it stood, so it stands there: \(placement.form)")
        }

        XCTAssertEqual(placement.lines.map(\.text), ["PREWASH 40"],
                       "the drawn line is the recognized string, not a translation and not a sentence about one")
        XCTAssertEqual(placement.lines.first?.pointSize, extractPolicy().minPointSize,
                       "the extracted text renders at the body floor — the size the panel floor is")
        XCTAssertEqual(placement.lines.first?.weight, .primary)

        // The never-empty rule: the box is drawn *over* the text it replaces,
        // so the recognized pixels are under an opaque fill rather than beside
        // it, and the region cannot appear twice on screen.
        let printed = rect(of: sign)
        XCTAssertLessThanOrEqual(box.minX, printed.minX + 1e-6)
        XCTAssertLessThanOrEqual(box.minY, printed.minY + 1e-6)
        XCTAssertGreaterThanOrEqual(box.maxX, printed.maxX - 1e-6)
        XCTAssertGreaterThanOrEqual(box.maxY, printed.maxY - 1e-6)
    }

    /// The same input, the two policies: the translated view finds nothing to
    /// draw and hands the region to a callout; extract mode stands the text
    /// where it is.
    func testTheTwoViewsDisagreeAboutARegionNothingHasTranslated() throws {
        let sign = region(text: "PREWASH 40")
        let pending = TranslationResult.pending(sign.text)
        let regionRect = rect(of: sign)

        let translatedView = outcome(regionRect, result: pending, policy: translatedViewPolicy())
        XCTAssertEqual(translatedView.condition, .noTranslationToDraw,
                       "the translated view has no translation to replace the text with — that "
                       + "is the state extract mode exists to stop being the normal case")

        let extracting = outcome(regionRect, result: pending, policy: extractPolicy())
        guard case .fits(_, let line) = extracting else {
            return XCTFail("extract mode draws the recognized text in place: \(extracting)")
        }
        XCTAssertEqual(line.text, "PREWASH 40")

        // And the mode is not a downgrade: once a region *has* been translated
        // — a block the elder tapped — both views draw the translation.
        let resolved = TranslationResult.resolved(originalText: sign.text,
                                                  translation: "पूर्व धुलाई",
                                                  tier: .onDeviceBrain)
        let resolvedTranslated = outcome(regionRect, result: resolved, policy: translatedViewPolicy())
        let resolvedExtracting = outcome(regionRect, result: resolved, policy: extractPolicy())
        guard case .fits(_, let translatedLine) = resolvedTranslated,
              case .fits(_, let extractingLine) = resolvedExtracting else {
            return XCTFail("a resolved region fits in place in both views: "
                           + "\(resolvedTranslated) / \(resolvedExtracting)")
        }
        XCTAssertEqual(translatedLine.text, resolved.text)
        XCTAssertEqual(extractingLine.text, resolved.text,
                       "a block that has been answered must not keep showing the text it was "
                       + "tapped to replace")
    }

    /// The state sentence: not said about work extract mode has not started,
    /// said when a translation the elder *did* ask for did not arrive.
    func testExtractModeSaysNothingAboutWorkItHasNotStartedAndEverythingAboutWorkThatFailed() {
        let sign = region(text: "PREWASH 40")
        let policy = extractPolicy()

        let pending = LiveOverlayPlacement.calloutLines(for: .pending(sign.text),
                                                        policy: policy,
                                                        stateCopy: { _ in self.stateSentence })
        XCTAssertEqual(pending.primary.text, "PREWASH 40",
                       "the pill reads the text it was going to translate")
        XCTAssertNil(pending.secondary,
                     "\"translating…\" describes work this mode deliberately has not started")

        let degraded = LiveOverlayPlacement.calloutLines(
            for: .degraded(originalText: sign.text, reason: .noTierResolved),
            policy: policy,
            stateCopy: { _ in self.stateSentence })
        XCTAssertEqual(degraded.primary.text, "PREWASH 40")
        XCTAssertEqual(degraded.secondary?.text, stateSentence,
                       "a degradation is reachable only after the elder asked for that block's "
                       + "translation, so it is said (FR-LCT-018)")

        // The translated view is untouched: a pending region there still
        // carries the sentence, because there the work *is* running.
        let translatedPending = LiveOverlayPlacement.calloutLines(
            for: .pending(sign.text),
            policy: translatedViewPolicy(),
            stateCopy: { _ in self.stateSentence })
        XCTAssertEqual(translatedPending.secondary?.text, stateSentence)
    }

    /// A block is one panel of its own lines in extract mode, where the
    /// translated view would have drawn the state sentence into it.
    func testExtractModeDrawsABlockAsItsOwnLines() throws {
        let block = ["PREWASH 40", "RINSE AID", "NO SPIN"].joined(separator: SceneBlock.lineSeparator)
        let sign = region(text: block, box: (0.2, 0.25, 0.8, 0.6))
        let policy = extractPolicy()

        let placement = try XCTUnwrap(place([sign], policy: policy).first)
        XCTAssertEqual(placement.lines.map(\.text), ["PREWASH 40", "RINSE AID", "NO SPIN"],
                       "the panel's rows are the block's recognized lines, in the order it read them")
        XCTAssertEqual(Set(placement.lines.map(\.pointSize)), [policy.minPointSize],
                       "every row is drawn at the one body floor")
        XCTAssertTrue(placement.lines.allSatisfy { $0.weight == .primary })
        XCTAssertFalse(placement.lines.contains { $0.text == stateSentence })

        // The contrast: the same block in the translated view, whose lines the
        // state sentence *is* while nothing has answered for it.
        let translatedView = try XCTUnwrap(place([sign], policy: translatedViewPolicy()).first)
        XCTAssertTrue(translatedView.lines.contains { $0.text == stateSentence },
                      "the translated view says it is working on this block: "
                      + "\(translatedView.lines.map(\.text))")
    }

    /// The laws the mode does **not** change. A long line in a small box is
    /// still refused the in-place form rather than shrunk until it fits: the
    /// body floor is not traded for the fit in either view.
    func testExtractModeStillRefusesToShrinkTextThatDoesNotFitItsRegion() {
        let long = "Members only beyond this point"
        let tiny = CGRect(x: 200, y: 400, width: 30, height: 10)

        let extracting = outcome(tiny, result: .pending(long), policy: extractPolicy())
        XCTAssertEqual(extracting.condition, .translationDoesNotFitRegion,
                       "the recognized text is drawn at the floor or not in place at all: \(extracting)")

        let translatedView = outcome(tiny, result: .pending(long), policy: translatedViewPolicy())
        XCTAssertEqual(translatedView.condition, .noTranslationToDraw,
                       "the translated view's first refusal is always the missing translation")
    }

    /// FR-LCT-017 outlives the mode toggle: an elder who asked for originals to
    /// stay visible gets that for a tapped block's translation too — and the
    /// preference is not consulted for a region that is already showing its
    /// original, because there is no conflict there to resolve.
    func testTheAlwaysShowOriginalPreferenceStillAppliesToATappedTranslation() {
        let sign = region(text: "PREWASH 40")
        let regionRect = rect(of: sign)
        let policy = extractPolicy(alwaysShowOriginal: true)

        let resolved = TranslationResult.resolved(originalText: sign.text,
                                                  translation: "पूर्व धुलाई",
                                                  tier: .dictionary)
        XCTAssertEqual(outcome(regionRect, result: resolved, policy: policy).condition,
                       .alwaysShowOriginalIsOn)

        // The callout it becomes carries both: the translation, and the
        // original the elder asked to keep.
        let lines = LiveOverlayPlacement.calloutLines(for: resolved,
                                                      policy: policy,
                                                      stateCopy: { _ in self.stateSentence })
        XCTAssertEqual(lines.primary.text, resolved.text)
        XCTAssertEqual(lines.secondary?.text, sign.text)

        // Untranslated: the original is what is drawn either way, so the
        // preference changes nothing and the text still stands in place.
        guard case .fits(_, let line) = outcome(regionRect, result: .pending(sign.text), policy: policy)
        else { return XCTFail("an untranslated region is not made a callout by the preference") }
        XCTAssertEqual(line.text, sign.text)
    }

    // MARK: - What a tap means

    /// Extract mode's bubble is the invitation to translate *that* block; the
    /// translated view's is tap-to-hear, and a block already answered offers
    /// its answer rather than asking twice.
    func testAnUntranslatedRegionIsATapTargetInExtractModeAndNotInTheTranslatedView() throws {
        let sign = region(text: "PREWASH 40")

        // The real placement, not a hand-built one: what the presentation says
        // is a function of the lines the placement measured.
        let pending = try XCTUnwrap(place([sign], policy: extractPolicy()).first)
        let extracting = LiveTranslateOverlaySurface(placements: [pending],
                                                     policy: extractPolicy(),
                                                     locale: locale).presentations
        let bubble = try XCTUnwrap(extracting.first)
        XCTAssertTrue(bubble.translatesOnTap,
                      "the block is the tap target: one tap, one block's translation")
        XCTAssertFalse(bubble.speaksTranslation,
                       "there is nothing to speak yet, so the tap must not be tap-to-hear")
        XCTAssertEqual(bubble.state, .pending)
        XCTAssertEqual(bubble.accessibilityLabel, sign.text,
                       "the announcement is the recognized text — never a translated-looking "
                       + "string for a region that was not translated")
        XCTAssertNil(bubble.accessibilityValue,
                     "there is one line on screen and it is the text: no state sentence is heard "
                     + "about work the mode has not started")

        let answered = try XCTUnwrap(place([sign],
                                           results: [sign.id: .resolved(originalText: sign.text,
                                                                        translation: "पूर्व धुलाई",
                                                                        tier: .dictionary)],
                                           policy: extractPolicy()).first)
        let answeredBubble = try XCTUnwrap(LiveTranslateOverlaySurface(placements: [answered],
                                                                      policy: extractPolicy(),
                                                                      locale: locale)
            .presentations.first)
        XCTAssertFalse(answeredBubble.translatesOnTap,
                       "a block that has been answered offers its translation, not a second ask")
        XCTAssertTrue(answeredBubble.speaksTranslation)
        XCTAssertEqual(answeredBubble.accessibilityLabel, "पूर्व धुलाई")
        XCTAssertEqual(answeredBubble.accessibilityValue, sign.text,
                       "the announcement carries both texts, so the elder hears what the "
                       + "translation replaced")

        let translatedView = try XCTUnwrap(place([sign], policy: translatedViewPolicy()).first)
        let translatedBubble = try XCTUnwrap(LiveTranslateOverlaySurface(placements: [translatedView],
                                                                         policy: translatedViewPolicy(),
                                                                         locale: locale)
            .presentations.first)
        XCTAssertFalse(translatedBubble.translatesOnTap,
                       "the translated view is unchanged: its bubbles are tap-to-hear or inert")
        XCTAssertFalse(translatedBubble.speaksTranslation)
        XCTAssertEqual(translatedBubble.accessibilityValue, stateSentence,
                       "and it still says the work is running, which is true there")
    }

    /// A region with no recognized text is not a target: asking a tier to
    /// translate nothing is not a thing the elder can mean.
    func testARegionWithNoTextIsNotATapTarget() throws {
        let blank = region(text: "   ")
        let placement = LiveOverlayPlacement.PlacedOverlay(region: blank,
                                                           result: .pending(blank.text),
                                                           form: .inPlace(regionID: blank.id,
                                                                          rect: rect(of: blank)))
        let bubble = try XCTUnwrap(LiveTranslateOverlaySurface(placements: [placement],
                                                               policy: extractPolicy(),
                                                               locale: locale)
            .presentations.first)
        XCTAssertFalse(bubble.translatesOnTap)
    }

    // MARK: - The chrome

    /// The mode toggle's surface: one word for one action, taken from the
    /// shipped catalog key rather than a second copy of the same word.
    func testTheTranslateAllControlNamesTheActionInTheActiveLanguage() {
        let off = TranslateAllSurface(isTranslatingOn: false, locale: locale)
        let on = TranslateAllSurface(isTranslatingOn: true, locale: locale)

        XCTAssertEqual(off.label, L10n.str("feeds.translate", locale: locale),
                       "the control is the catalog's word, resolved at the surface")
        XCTAssertEqual(on.label, off.label,
                       "the label is the action; which view is on is carried by state, not by wording")
        XCTAssertFalse(off.label.isEmpty)
        XCTAssertTrue(ApplianceLabelLocalizer.containsDevanagari(off.label),
                      "the Nepali surface reads Nepali: \(off.label)")
        XCTAssertEqual(TranslateAllSurface.symbolName, "translate")

        let english = TranslateAllSurface(isTranslatingOn: false,
                                          locale: Locale(identifier: "en_US"))
        XCTAssertFalse(english.label.isEmpty)
    }

    /// The strip the chrome lives in is reserved at the height the controls are
    /// drawn at — two rows, both elder-sized — so a callout cannot land under
    /// the mode toggle.
    func testTheChromeStripReservesBothControlRows() throws {
        let rows = LiveTranslateOverlaySurface.chromeControlRows
        let rects = LiveTranslateOverlaySurface.chromeRects(containerSize: container)
        let strip = try XCTUnwrap(rects.first)
        XCTAssertEqual(rects.count, 1)

        let expected = CGFloat(rows) * DesignTokens.minTapTargetSize
            + CGFloat(rows + 1) * DesignTokens.interElementSpacing
        XCTAssertEqual(rows, 2, "the strip holds the mode toggle above the preference")
        XCTAssertEqual(strip.height, expected, accuracy: 1e-9,
                       "the reservation names exactly the height the two rows draw at")
        XCTAssertEqual(strip.minY + strip.height, container.height, accuracy: 1e-9,
                       "the strip is the bottom band the controls are laid out in")
        XCTAssertEqual(strip.width, container.width)
    }
}
