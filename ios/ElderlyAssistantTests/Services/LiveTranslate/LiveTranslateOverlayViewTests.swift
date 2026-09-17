import UIKit
import XCTest
@testable import ElderlyAssistant

/// T-021 — the overlay's states, its accessibility, and the two properties
/// that are about *when* it draws rather than *what* (FR-LCT-018,
/// NFR-LCT-002, NFR-LCT-003, NFR-LCT-004, NFR-LCT-005, NFR-LCT-010).
///
/// The split of responsibilities these tests rely on: `RegionPresentation` is
/// the pure value the view draws *and* announces, so "a degraded region shows
/// its original text with an honest reason" is asserted on a value rather than
/// inferred from pixels. The pixel checks (`OverlayRenderProbe`) cover the two
/// claims a value cannot carry — geometry and "something was actually drawn" —
/// and the source-level claims (no `@State`, no `await`, token-derived sizes
/// and colours) live in `LiveTranslateAppLayerHygieneTests`, which scans the
/// same three app-layer files this suite exercises.
final class LiveTranslateOverlayViewTests: XCTestCase {

    private let container = CGSize(width: 390, height: 844)
    private let nepali = Locale(identifier: "ne-NP")
    private let english = Locale(identifier: "en")
    private let config = LiveTranslateConfig.default

    // MARK: - Fixtures

    private func box(_ xMin: Double, _ yMin: Double,
                     _ xMax: Double, _ yMax: Double) -> NormalizedBox {
        NormalizedBox(xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax)
    }

    private func region(_ rawValue: Int,
                        _ text: String,
                        box rectangle: NormalizedBox,
                        language: String? = "ne",
                        confidence: Double = 0.9) -> TextRegionStabilizer.StableTextRegion {
        TextRegionStabilizer.StableTextRegion(
            id: TextRegionStabilizer.RegionIdentity(rawValue: rawValue),
            text: text,
            normalizedText: LiveTranslateTextNormalization.normalized(text),
            box: rectangle,
            detectedLanguage: language,
            confidence: confidence)
    }

    private func identity(_ rawValue: Int) -> TextRegionStabilizer.RegionIdentity {
        TextRegionStabilizer.RegionIdentity(rawValue: rawValue)
    }

    /// The surface the view renders: built exactly the way the app builds it —
    /// the placement runs first with the surface's own copy closure, so the
    /// string a pill was *sized* around is the string the view draws.
    ///
    /// The frame is the container's size here (no letterboxing), so a
    /// normalized box and its screen rect correspond 1:1 and this suite's
    /// assertions are about states, not about aspect-fit — that is
    /// `LiveOverlayPlacementGeometryTests`' subject.
    private func makeSurface(regions: [TextRegionStabilizer.StableTextRegion],
                            results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [:],
                            alwaysShowOriginal: Bool = false,
                            locale: Locale? = nil) -> LiveTranslateOverlaySurface {
        let locale = locale ?? nepali
        let policy = LiveTranslateOverlaySurface.policy(config: config,
                                                        alwaysShowOriginal: alwaysShowOriginal)
        let copy = LiveTranslateOverlaySurface(placements: [], policy: policy, locale: locale)
        let placements = LiveOverlayPlacement.place(
            regions: regions, results: results,
            containerSize: container, framePixelSize: container,
            safeArea: CGRect(origin: .zero, size: container),
            occupiedRects: LiveTranslateOverlaySurface.chromeRects(containerSize: container),
            policy: policy,
            stateCopy: { copy.stateCopy(for: $0) })
        return LiveTranslateOverlaySurface(placements: placements, policy: policy, locale: locale)
    }

    private func screenRect(of region: TextRegionStabilizer.StableTextRegion) -> CGRect {
        LiveOverlayPlacement.screenRect(for: region.box, containerSize: container,
                                        framePixelSize: container)
    }

    private var chrome: [CGRect] {
        LiveTranslateOverlaySurface.chromeRects(containerSize: container)
    }

    // MARK: - Scenario: each outcome state renders its own presentation

    func testEachOutcomeStateRendersItsOwnPresentation() {
        let pending = region(0, "खुल्ने समय", box: box(0.2, 0.10, 0.8, 0.16))
        let resolved = region(1, "प्रवेश निषेध", box: box(0.2, 0.40, 0.8, 0.46))
        let degraded = region(2, "बाहिर निस्कनुहोस्", box: box(0.2, 0.70, 0.8, 0.76))
        let surface = makeSurface(
            regions: [pending, resolved, degraded],
            results: [resolved.id: .resolved(originalText: resolved.text,
                                             translation: "No entry", tier: .cloud),
                      degraded.id: .degraded(originalText: degraded.text,
                                             reason: .providerRejected)])

        let presentations = surface.presentations
        XCTAssertEqual(presentations.map(\.state), [.pending, .resolved, .degraded],
                       "one presentation per region, in reading order, each with its own state")

        // Pending: an in-progress indication, and the recognized text is still
        // what the bubble draws (the elder is not shown an empty box).
        XCTAssertEqual(presentations[0].symbolName, RegionPresentation.pendingSymbolName)
        XCTAssertEqual(presentations[0].accessibilityLabel, pending.text)
        XCTAssertEqual(presentations[0].accessibilityValue,
                       L10n.str("livetranslate.state.pending", locale: nepali))
        XCTAssertFalse(presentations[0].speaksTranslation,
                       "nothing to speak yet: the bubble is not a button that does nothing")

        // Resolved: the translation, marked by being a translation rather than
        // by a badge. It stands where the text stood — the tier that answered
        // it is not a reason to float a bubble over the picture (owner UX
        // rework, 2026-09-17).
        XCTAssertNil(presentations[1].symbolName)
        XCTAssertEqual(presentations[1].accessibilityLabel, "No entry")
        XCTAssertEqual(presentations[1].accessibilityValue, resolved.text)
        XCTAssertTrue(presentations[1].speaksTranslation)
        guard case .inPlace = presentations[1].form else {
            XCTFail("a resolved translation is drawn in place")
            return
        }

        // Degraded: the recognized text, an honest reason, and no
        // translated-looking string anywhere in the presentation.
        XCTAssertEqual(presentations[2].symbolName, RegionPresentation.degradedSymbolName)
        XCTAssertEqual(presentations[2].accessibilityLabel, degraded.text)
        XCTAssertEqual(presentations[2].accessibilityValue,
                       L10n.str("livetranslate.state.unavailable", locale: nepali))
        XCTAssertFalse(presentations[2].speaksTranslation,
                       "a region with no translation has nothing to read aloud")
    }

    func testAPendingRegionShowsTheOriginalWithAnInProgressIndication() {
        let pending = region(0, "खुल्ने समय", box: box(0.2, 0.3, 0.8, 0.4))
        let surface = makeSurface(regions: [pending])

        guard let presentation = surface.presentations.first else {
            XCTFail("a region with no result yet is still placed")
            return
        }
        XCTAssertEqual(presentation.lines.count, 2,
                       "the recognized text and the in-progress line")
        XCTAssertEqual(presentation.lines[0].text, pending.text)
        XCTAssertEqual(presentation.lines[1].text,
                       L10n.str("livetranslate.state.pending", locale: nepali))
        XCTAssertEqual(presentation.lines[0].weight, .primary)
        XCTAssertEqual(presentation.lines[1].weight, .secondary)
    }

    // MARK: - Scenario: no region disappears because a tier failed

    func testADegradedRegionIsStillPresentWithItsOriginalTextAndAnHonestReason() {
        // Every reason the closed vocabulary has: none of them may remove a
        // region, and each must show the recognized text beside its cause.
        let reasons = TranslationUnavailableReason.allCases
        var regions: [TextRegionStabilizer.StableTextRegion] = []
        var results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [:]
        for (index, reason) in reasons.enumerated() {
            let column = Double(index % 3)
            let row = Double(index / 3)
            let region = region(index, "क्षेत्र \(index)",
                                box: box(0.05 + column * 0.32, 0.25 + row * 0.16,
                                         0.30 + column * 0.32, 0.32 + row * 0.16))
            regions.append(region)
            results[region.id] = .degraded(originalText: region.text, reason: reason)
        }
        let surface = makeSurface(regions: regions, results: results)

        XCTAssertEqual(surface.presentations.count, regions.count,
                       "degradation is never a removed overlay (NFR-LCT-010)")
        for region in regions {
            guard let presentation = surface.presentations.first(where: { $0.regionID == region.id }),
                  let result = results[region.id] else {
                XCTFail("\(region.id) disappeared after its tier failed")
                continue
            }
            XCTAssertEqual(presentation.state, .degraded)
            XCTAssertEqual(presentation.accessibilityLabel, region.text,
                           "the original text stays visible and announced")
            XCTAssertEqual(presentation.lines.first?.text, region.text,
                           "the bubble draws the recognized text while it has no translation")
            XCTAssertEqual(presentation.accessibilityValue, surface.stateCopy(for: result))
            XCTAssertEqual(presentation.symbolName, RegionPresentation.degradedSymbolName)
        }
    }

    func testTheQuarantinedWordingIsItsOwnHonestSentence() {
        let quarantined = makeSurface(regions: [region(0, "अक्षर", box: box(0.2, 0.3, 0.8, 0.4))],
                                      results: [identity(0): .degraded(originalText: "अक्षर",
                                                                       reason: .textQuarantined)])
        let unavailable = L10n.str("livetranslate.state.unavailable", locale: nepali)
        let quarantineCopy = L10n.str("livetranslate.state.quarantined", locale: nepali)

        XCTAssertEqual(quarantined.presentations.first?.accessibilityValue, quarantineCopy)
        XCTAssertNotEqual(quarantineCopy, unavailable,
                          "a withheld send is not the same fact as an unavailable translation: "
                          + "collapsing them tells the elder to retry something that will be withheld again")
    }

    // MARK: - Scenario: the original text is always reachable

    func testTheOriginalTextStaysReachableForAResolvedRegion() {
        // An in-place region hides its original by design (that is the smart
        // mix), so the escape hatch is the FR-LCT-017 path: the same region,
        // the same translation, laid out with the original beside it.
        let inPlaceRegion = region(0, "खुल्ने समय", box: box(0.2, 0.25, 0.8, 0.35))
        let results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [
            inPlaceRegion.id: .resolved(originalText: inPlaceRegion.text,
                                        translation: "Opening hours", tier: .dictionary)
        ]

        let smartMix = makeSurface(regions: [inPlaceRegion], results: results)
        guard let inPlace = smartMix.presentations.first else {
            XCTFail("the region must be placed")
            return
        }
        guard case .inPlace(_, let inPlaceRect) = inPlace.form else {
            XCTFail("a dictionary translation that fits is drawn in place")
            return
        }
        XCTAssertEqual(inPlace.lines.map(\.text), ["Opening hours"])
        XCTAssertTrue(inPlaceRect.insetBy(dx: -1e-9, dy: -1e-9).contains(screenRect(of: inPlaceRegion)),
                      "in place, the translation covers the text it replaced")
        XCTAssertLessThanOrEqual(inPlaceRect.width,
                                 screenRect(of: inPlaceRegion).width
                                 * CGFloat(LiveTranslateConfig.default.inPlaceMaxGrowth) + 1e-9,
                                 "and takes only the free space around it")

        let askedForOriginal = makeSurface(regions: [inPlaceRegion], results: results,
                                           alwaysShowOriginal: true)
        guard let callout = askedForOriginal.presentations.first else {
            XCTFail("the region must still be placed")
            return
        }
        XCTAssertEqual(callout.lines.map(\.text), ["Opening hours", inPlaceRegion.text],
                       "the original is displayed for that region and the translation stays available")
        XCTAssertEqual(callout.accessibilityLabel, "Opening hours")
        XCTAssertEqual(callout.accessibilityValue, inPlaceRegion.text)
        guard case .callout(_, let anchor, _) = callout.form else {
            XCTFail("asking for the original moves the region to the callout form")
            return
        }
        XCTAssertTrue(screenRect(of: inPlaceRegion).insetBy(dx: -0.5, dy: -0.5).contains(anchor),
                      "the leader still lands on the region the translation belongs to")
    }

    // MARK: - Scenario: the empty state tells the truth without being an error

    func testTheEmptyStateIsACalmCatalogSentence() {
        let surface = makeSurface(regions: [])

        XCTAssertTrue(surface.presentations.isEmpty)
        XCTAssertEqual(surface.emptyHint, L10n.str("livetranslate.empty.hint", locale: nepali))
        XCTAssertNotEqual(surface.emptyHint, "livetranslate.empty.hint",
                          "the hint resolves in the elder's language, never as the key")
        XCTAssertTrue(surface.emptyHint.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) },
                      "Nepali first")
        for word in ["error", "failed", "problem", "गल्ती", "फेल", "समस्या"] {
            XCTAssertFalse(surface.emptyHint.lowercased().contains(word.lowercased()),
                           "the empty state is not a failure: '\(word)' has no place in it")
        }
    }

    // MARK: - Scenario: text and controls meet the accessibility standards

    func testTextRendersAtOrAboveTheMinimumPointSizeInThePrimaryWeight() {
        let policy = LiveTranslateOverlaySurface.policy(config: config, alwaysShowOriginal: false)
        XCTAssertEqual(policy.minPointSize,
                       max(config.overlayMinPointSize, DesignTokens.minBodyPointSize))
        XCTAssertGreaterThanOrEqual(policy.minPointSize, config.overlayMinPointSize,
                                    "the configured floor is a floor")
        XCTAssertLessThanOrEqual(policy.secondaryPointSize, policy.minPointSize,
                                 "the supporting line never outgrows the translation")
        XCTAssertGreaterThanOrEqual(policy.secondaryPointSize, DesignTokens.minCaptionPointSize,
                                    "the supporting line is still elder-readable")

        // A sign too small for its translation: the two-line callout, where
        // both floors are visible at once.
        let resolved = region(0, "खुल्ने समय बिहान", box: box(0.2, 0.3, 0.24, 0.32))
        let surface = makeSurface(regions: [resolved],
                                  results: [resolved.id: .resolved(originalText: resolved.text,
                                                                   translation: "Opening hours",
                                                                   tier: .cloud)])
        guard let presentation = surface.presentations.first else {
            XCTFail("the region must be placed")
            return
        }
        guard case .callout = presentation.form else {
            XCTFail("the premise is a callout: the translation cannot be read in that box")
            return
        }
        XCTAssertEqual(presentation.lines[0].pointSize, policy.minPointSize)
        XCTAssertEqual(presentation.lines[1].pointSize, policy.secondaryPointSize)
        XCTAssertEqual(presentation.lines[0].weight, .primary)

        // …and in place, the line is at the body floor — the largest size the
        // fit is tried at — and never below the configured in-place floor.
        let roomy = region(1, "गेट खोल्नुहोस्", box: box(0.2, 0.6, 0.8, 0.7))
        let inPlace = makeSurface(regions: [roomy],
                                  results: [roomy.id: .resolved(originalText: roomy.text,
                                                                translation: "Opening hours",
                                                                tier: .cloud)])
        guard let inPlaceLine = inPlace.presentations.first?.lines.first else {
            XCTFail("the roomy region must be placed")
            return
        }
        XCTAssertEqual(inPlaceLine.pointSize, policy.minPointSize)
        XCTAssertGreaterThanOrEqual(inPlaceLine.pointSize,
                                    LiveTranslateConfig.default.inPlaceMinPointSize)

        // The weight is real, not a name: the font the measurer builds for the
        // primary line is bold, and the two weights do not measure alike (a
        // regular face measured as bold is exactly risk R2).
        let primary = LiveOverlayTextMetrics.uiFont(pointSize: policy.minPointSize, weight: .primary)
        let secondary = LiveOverlayTextMetrics.uiFont(pointSize: policy.secondaryPointSize,
                                                     weight: .secondary)
        XCTAssertTrue(primary.fontDescriptor.symbolicTraits.contains(.traitBold),
                      "the translation is bold")
        XCTAssertFalse(secondary.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertEqual(primary.pointSize, policy.minPointSize)
        XCTAssertGreaterThan(
            LiveOverlayTextMetrics.measure("Opening hours", pointSize: policy.minPointSize,
                                           weight: .primary).width,
            LiveOverlayTextMetrics.measure("Opening hours", pointSize: policy.minPointSize,
                                           weight: .secondary).width,
            "the measurement distinguishes the two weights")
    }

    // MARK: - Scenario: the render path never waits on a tier

    func testAResultArrivingChangesOnlyItsOwnRegionsPresentation() {
        let first = region(0, "खुल्ने समय", box: box(0.2, 0.10, 0.8, 0.16))
        let second = region(1, "प्रवेश निषेध", box: box(0.2, 0.40, 0.8, 0.46))
        let third = region(2, "बाहिर निस्कनुहोस्", box: box(0.2, 0.70, 0.8, 0.76))
        let regions = [first, second, third]
        var results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [
            second.id: .resolved(originalText: second.text, translation: "No entry", tier: .cloud),
            third.id: .degraded(originalText: third.text, reason: .noNetwork)
        ]

        let before = makeSurface(regions: regions, results: results)
        results[first.id] = .resolved(originalText: first.text, translation: "Opening hours",
                                      tier: .cloud)
        let after = makeSurface(regions: regions, results: results)

        let byIdentity = Dictionary(uniqueKeysWithValues: before.presentations.map { ($0.regionID, $0) })
        for presentation in after.presentations {
            if presentation.regionID == first.id {
                XCTAssertNotEqual(presentation, byIdentity[first.id],
                                  "the region whose result arrived must change")
            } else {
                XCTAssertEqual(presentation, byIdentity[presentation.regionID],
                               "an unchanged region's presentation must compare equal, so a "
                               + "translation arriving re-renders only its own region (NFR-LCT-002)")
            }
        }
        XCTAssertEqual(after.presentations.count, before.presentations.count)
    }

    // MARK: - Scenario: recycling keeps the view cost bounded

    func testALongSyntheticSessionKeepsTheViewCostBounded() {
        var stabilizer = TextRegionStabilizer(config: config)
        var highestPlacementCount = 0
        var identitiesBySign: [Int: Set<TextRegionStabilizer.RegionIdentity>] = [:]
        var textBySign: [Int: Set<String>] = [:]
        let policy = LiveTranslateOverlaySurface.policy(config: config, alwaysShowOriginal: false)

        for pass in 0..<60 {
            var observations: [LiveTextDetector.DetectedTextRegion] = []

            // Three signs the elder is standing in front of: same place every
            // pass, their text changing now and then — the identity-preserving
            // update the overlay has to carry in place. A view keyed by
            // identity is reused here; one keyed by text would be rebuilt on
            // every change, which is the cost this scenario exists to bound.
            for index in 0..<3 {
                let suffix = pass % 4 == 0 ? " अ" : ""
                observations.append(LiveTextDetector.DetectedTextRegion(
                    text: "स्थिर चिन्ह \(index)\(suffix)",
                    normalizedBox: box(0.05 + Double(index) * 0.3, 0.20,
                                       0.25 + Double(index) * 0.3, 0.26),
                    detectedLanguage: "ne",
                    confidence: 0.9))
            }

            // A crowd that comes and goes over two-pass cycles (the appear
            // hysteresis is two passes, so this is what actually publishes).
            if pass % 3 == 0 || pass % 3 == 1 {
                for index in 0..<20 {
                    observations.append(LiveTextDetector.DetectedTextRegion(
                        text: "भीड \(index)",
                        normalizedBox: box(0.02 + Double(index % 4) * 0.24,
                                           0.50 + Double(index / 4) * 0.08,
                                           0.22 + Double(index % 4) * 0.24,
                                           0.56 + Double(index / 4) * 0.08),
                        detectedLanguage: "ne",
                        confidence: 0.5 + Double(index) * 0.01))
                }
            }

            stabilizer.consume(regions: observations)
            let visible = stabilizer.visible
            XCTAssertLessThanOrEqual(visible.count, config.declutterMaxRegions,
                                     "the stabiliser's cap holds on pass \(pass)")

            let placements = LiveOverlayPlacement.place(
                regions: visible, results: [:],
                containerSize: container, framePixelSize: container,
                safeArea: CGRect(origin: .zero, size: container),
                occupiedRects: chrome, policy: policy, stateCopy: { _ in nil })

            XCTAssertEqual(placements.count, visible.count,
                           "exactly one overlay per visible region (pass \(pass))")
            XCTAssertEqual(Set(placements.map(\.region.id)).count, placements.count,
                           "overlays are keyed by region identity: a duplicate is a layer that "
                           + "accumulates instead of being reused (pass \(pass))")
            for placement in placements {
                guard let index = (0..<3).first(where: {
                    placement.region.text.hasPrefix("स्थिर चिन्ह \($0)")
                }) else { continue }
                identitiesBySign[index, default: []].insert(placement.region.id)
                textBySign[index, default: []].insert(placement.region.text)
            }
            highestPlacementCount = max(highestPlacementCount, placements.count)
        }

        XCTAssertEqual(highestPlacementCount, config.declutterMaxRegions,
                       "the session must actually reach the cap, or the bound is untested")
        for index in 0..<3 {
            XCTAssertGreaterThan(textBySign[index]?.count ?? 0, 1,
                                 "the fixture must actually change sign \(index)'s text, or "
                                 + "identity reuse is untested")
            XCTAssertEqual(identitiesBySign[index]?.count, 1,
                           "sign \(index)'s text changed under it and the overlay must carry the "
                           + "same identity across every change, so its view is reused rather "
                           + "than rebuilt: saw \(identitiesBySign[index]?.count ?? 0) identities")
        }
    }

    // MARK: - The overlay's own chrome

    func testCalloutsStayClearOfTheOverlaysChrome() {
        // A small sign near the bottom strip whose translation cannot be read
        // in place: the callout is the fallback, and it must not land on the
        // FR-LCT-017 control the strip reserves for.
        let control = region(0, "प्रवेश निषेध गरिएको छ", box: box(0.15, 0.86, 0.30, 0.88))
        let surface = makeSurface(regions: [control],
                                  results: [control.id: .resolved(
                                    originalText: control.text,
                                    translation: "Entry is restricted beyond this point",
                                    tier: .cloud)])

        guard let strip = chrome.first else {
            XCTFail("a normal container reserves a strip for the overlay's control")
            return
        }
        XCTAssertEqual(strip.height,
                       DesignTokens.minTapTargetSize + 2 * DesignTokens.interElementSpacing)
        XCTAssertEqual(strip.maxY, container.height)
        guard let presentation = surface.presentations.first,
              case .callout(_, let anchor, let pillRect) = presentation.form else {
            XCTFail("a translation that cannot be read in its box is a callout")
            return
        }
        XCTAssertFalse(pillRect.intersects(strip),
                       "the FR-LCT-017 control must stay reachable, never covered by a pill")
        XCTAssertTrue(screenRect(of: control).insetBy(dx: -0.5, dy: -0.5).contains(anchor))
    }

    func testADegenerateContainerReservesNoChrome() {
        XCTAssertEqual(
            LiveTranslateOverlaySurface.chromeRects(containerSize: CGSize(width: 390, height: 10)),
            [], "a container shorter than the control has no strip to reserve")
        XCTAssertEqual(
            LiveTranslateOverlaySurface.chromeRects(containerSize: CGSize(width: 0, height: 844)), [])
        XCTAssertEqual(LiveTranslateOverlaySurface.chromeRects(containerSize: .zero), [])
    }

    // MARK: - Scenario: the four states, rendered in Nepali

    /// The DoD's snapshot substitute: every state is drawn off screen at
    /// Retina scale in the Nepali locale and must (a) draw something, (b) draw
    /// the control in its chrome, and (c) look different from the other
    /// states — an elder must be able to tell "we could not translate this"
    /// from "this is the translation".
    @MainActor
    func testEveryStateRendersInNepaliAndTheStatesAreDistinguishable() throws {
        let pending = region(0, "खुल्ने समय", box: box(0.15, 0.30, 0.85, 0.38))
        let resolved = region(1, "प्रवेश निषेध", box: box(0.15, 0.45, 0.85, 0.53))
        let degraded = region(2, "बाहिर निस्कनुहोस्", box: box(0.15, 0.60, 0.85, 0.68))

        let states: [(name: String, surface: LiveTranslateOverlaySurface)] = [
            ("empty", makeSurface(regions: [])),
            ("pending", makeSurface(regions: [pending])),
            ("resolved", makeSurface(regions: [resolved],
                                     results: [resolved.id: .resolved(originalText: resolved.text,
                                                                      translation: "No entry",
                                                                      tier: .cloud)])),
            ("degraded", makeSurface(regions: [degraded],
                                     results: [degraded.id: .degraded(originalText: degraded.text,
                                                                      reason: .noNetwork)]))
        ]

        var signatures: [String: OverlayRenderProbe.Ink] = [:]
        for state in states {
            let image = try XCTUnwrap(OverlayRenderProbe.render(state.surface, size: container),
                                      "the \(state.name) state produced no image")
            let drawn = try OverlayRenderProbe.ink(in: image)
            XCTAssertFalse(drawn.isEmpty, "the \(state.name) state drew nothing")
            signatures[state.name] = drawn

            let inChrome = try OverlayRenderProbe.ink(in: image, within: chrome[0])
            XCTAssertFalse(inChrome.isEmpty,
                           "the FR-LCT-017 control is drawn in the chrome in the \(state.name) state")
        }

        XCTAssertEqual(signatures.count, 4)
        XCTAssertNotEqual(signatures["resolved"], signatures["degraded"],
                          "a degradation must not look like a translation")
        XCTAssertNotEqual(signatures["resolved"], signatures["pending"])
        XCTAssertNotEqual(signatures["pending"], signatures["degraded"])
        XCTAssertNotEqual(signatures["empty"], signatures["resolved"],
                          "the empty state must not look like a translated screen")
    }

    // MARK: - Accessibility labels

    func testAResolvedTranslationIsTheBubblesAccessibilityLabel() {
        let inPlace = region(0, "खुल्ने समय", box: box(0.2, 0.20, 0.8, 0.30))
        let cloud = region(1, "प्रवेश निषेध क्षेत्र", box: box(0.2, 0.45, 0.8, 0.55))
        let same = region(2, "Wi-Fi", box: box(0.2, 0.70, 0.8, 0.80))
        let surface = makeSurface(
            regions: [inPlace, cloud, same],
            results: [inPlace.id: .resolved(originalText: inPlace.text,
                                            translation: "Opening hours", tier: .dictionary),
                      cloud.id: .resolved(originalText: cloud.text,
                                          translation: "Restricted area", tier: .cloud),
                      same.id: .resolved(originalText: same.text,
                                         translation: same.text, tier: .dictionary)])

        let labels = Dictionary(uniqueKeysWithValues:
            surface.presentations.map { ($0.regionID, $0.accessibilityLabel) })
        XCTAssertEqual(labels[inPlace.id], "Opening hours")
        XCTAssertEqual(labels[cloud.id], "Restricted area")
        XCTAssertEqual(labels[same.id], same.text,
                       "a translation identical to the original is announced once, not twice")

        let samePresentation = surface.presentations.first { $0.regionID == same.id }
        XCTAssertEqual(samePresentation?.lines.map(\.text), [same.text],
                       "the same string is not drawn twice")
    }

    func testEveryStateAnnouncesInTheActiveLanguage() {
        let englishSurface = makeSurface(regions: [region(0, "खुल्ने समय", box: box(0.2, 0.3, 0.8, 0.4))],
                                         locale: english)
        let nepaliSurface = makeSurface(regions: [region(0, "खुल्ने समय", box: box(0.2, 0.3, 0.8, 0.4))],
                                        locale: nepali)

        XCTAssertEqual(englishSurface.presentations.first?.accessibilityValue,
                       L10n.str("livetranslate.state.pending", locale: english))
        XCTAssertEqual(nepaliSurface.presentations.first?.accessibilityValue,
                       L10n.str("livetranslate.state.pending", locale: nepali))
        XCTAssertNotEqual(englishSurface.emptyHint, nepaliSurface.emptyHint)
        XCTAssertEqual(englishSurface.presentations.first?.accessibilityLabel, "खुल्ने समय",
                       "the recognized text is shown as it was read, in either language")
    }

    // MARK: - Scenario: a moving region keeps its view (owner UX rework)

    /// The identity the drawn list is keyed by is the region's **normalized
    /// string**, not its region id. Region ids are re-issued as boxes are
    /// re-matched frame to frame, so an id-keyed list tears the view down and
    /// builds a new one on nearly every pass — the flicker and jumpiness the
    /// owner saw on the device. A string-keyed list keeps the view, and only
    /// its geometry moves, which is what lets the overlay interpolate it.
    func testAMovingRegionKeepsItsViewIdentityWhileItsRectMoves() {
        let before = makeSurface(regions: [region(0, "खुल्ने समय", box: box(0.2, 0.30, 0.8, 0.38))],
                                 results: [identity(0): .resolved(originalText: "खुल्ने समय",
                                                                  translation: "Opening hours",
                                                                  tier: .cloud)])
        let after = makeSurface(regions: [region(7, "खुल्ने समय", box: box(0.2, 0.34, 0.8, 0.42))],
                                results: [identity(7): .resolved(originalText: "खुल्ने समय",
                                                                 translation: "Opening hours",
                                                                 tier: .cloud)])

        guard let first = before.presentations.first, let second = after.presentations.first else {
            XCTFail("both frames must place the region")
            return
        }
        XCTAssertNotEqual(first.regionID, second.regionID,
                          "the premise: the stabiliser re-issued the region's identity between frames")
        XCTAssertEqual(first.id, second.id,
                       "the view identity is the string, so the region's view survives the move: "
                       + "same id ⇒ SwiftUI reuses it and animates the rect instead of rebuilding")
        XCTAssertEqual(first.id, LiveTranslateTextNormalization.normalized("खुल्ने समय"))
        XCTAssertNotEqual(first.frameRect, second.frameRect,
                          "and the geometry is what changed — the thing the view interpolates")
        XCTAssertEqual(first.accessibilityLabel, second.accessibilityLabel)
    }

    /// Two regions on screen carrying the same string stay two views: the
    /// second gets an ordinal, and ordinals are assigned in placement (reading)
    /// order, so the same scene numbers them the same way every frame and the
    /// two views cannot trade places.
    func testTwoRegionsWithTheSameStringGetDistinctStableIdentities() {
        let upper = region(0, "Wi-Fi", box: box(0.1, 0.20, 0.5, 0.26))
        let lower = region(1, "Wi-Fi", box: box(0.1, 0.70, 0.5, 0.76))
        let surface = makeSurface(regions: [upper, lower])

        let ids = surface.presentations.map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2, "two views, two keys: a duplicate key would collapse them")
        XCTAssertEqual(surface.presentations.map(\.identityOrdinal), [0, 1],
                       "assigned in reading order, so the same scene numbers them identically every frame")
        XCTAssertEqual(surface.presentations[0].id,
                       LiveTranslateTextNormalization.normalized("Wi-Fi"))
        XCTAssertEqual(surface.presentations[1].id,
                       LiveTranslateTextNormalization.normalized("Wi-Fi") + "#1")

        // Handed the same two regions in the other order, the identities follow
        // the geometry, not the array: the numbering is a property of where the
        // text is on screen.
        let reversed = makeSurface(regions: [lower, upper])
        XCTAssertEqual(reversed.presentations.map(\.id), ids)
    }

    // MARK: - Scenario: a box holds still until it has genuinely moved
    //
    // The owner's second device verdict: "they still jump around, though not as
    // much as before. Not usable." What was still moving are boxes whose
    // *string* never changed — the detector's per-pass jitter, and the fact
    // that an in-place box is derived from its region's rect *and its
    // neighbours'*, so one sign drifting re-measures every box near it.
    //
    // These are asserted on `LiveOverlayGeometryMemory` rather than through
    // pixels, and deliberately: `OverlayRenderProbe.render` builds a fresh view
    // every call, so a rendered frame is always a *first* frame — the pixel
    // path cannot show a sequence. The memory is the value the view's body
    // calls on every frame, so scripting its input is scripting the render.

    /// One frame: the memory's answer for the surface, as the view draws it.
    private func drawn(_ memory: LiveOverlayGeometryMemory,
                       _ surface: LiveTranslateOverlaySurface) -> [RegionPresentation] {
        memory.held(surface.presentations, container: container,
                    stickiness: config.overlayGeometryStickiness)
    }

    /// A one-region surface whose sign is resolved and drawn in place, at the
    /// normalized box given — the scripted frame the jitter tests move.
    private func surface(box rectangle: NormalizedBox,
                         region rawValue: Int = 0,
                         text: String = "खुल्ने समय",
                         translation: String = "Opening hours") -> LiveTranslateOverlaySurface {
        makeSurface(regions: [region(rawValue, text, box: rectangle)],
                    results: [identity(rawValue): .resolved(originalText: text,
                                                            translation: translation,
                                                            tier: .dictionary)])
    }

    /// A presentation built by hand, so a test can script two geometries that
    /// the shipped placement would not produce for the same sign — the form
    /// guard is about the *value*, and this is how it is exercised directly.
    private func presentation(_ text: String,
                             form: LiveOverlayPlacement.Form,
                             id rawValue: Int = 0) -> RegionPresentation {
        RegionPresentation(regionID: identity(rawValue),
                           identityKey: LiveTranslateTextNormalization.normalized(text),
                           identityOrdinal: 0,
                           state: .resolved,
                           form: form,
                           lines: [LiveOverlayTextLine(text: "Opening hours",
                                                       pointSize: DesignTokens.minBodyPointSize,
                                                       weight: .primary)],
                           isClampedFallback: false,
                           accessibilityLabel: "Opening hours",
                           accessibilityValue: text,
                           speaksTranslation: true)
    }

    /// The detector's box for a sign that has not changed its text jitters by
    /// ±2 % of the container every pass. The drawn box must not move at all.
    /// This is the complaint, scripted.
    func testASubThresholdJitterNeverMovesTheDrawnBox() {
        let memory = LiveOverlayGeometryMemory()
        let offsets: [(Double, Double)] = [(0, 0), (0.02, -0.02), (-0.02, 0.01),
                                           (0.01, 0.02), (-0.02, -0.02)]
        var rects: [CGRect] = []

        for (dx, dy) in offsets {
            let frame = surface(box: box(0.2 + dx, 0.30 + dy, 0.8 + dx, 0.38 + dy))
            guard let presentation = drawn(memory, frame).first else {
                return XCTFail("the region must be placed on every frame")
            }
            rects.append(presentation.frameRect)
        }

        XCTAssertEqual(rects.count, offsets.count)
        XCTAssertTrue(rects.allSatisfy { $0 == rects[0] },
                      "±2 % of the container is recognition jitter, not a move: the drawn box holds "
                      + "exactly where it was on every frame: \(rects)")
        XCTAssertEqual(memory.count, 1, "one region, one held rect")
        // The held rect is the sign's own printed rect — compared component by
        // component, because the box is the printed rect *unioned* with the
        // (here, smaller) text block, and a union is a fresh rectangle whose
        // origin can differ from the rect it was made from by one unit in the
        // last place. A tolerance of a millionth of a point is not a loosening
        // of the claim: it is the claim, "the box is where the sign is", spelled
        // in a way floating point can honour.
        let printed = screenRect(of: region(0, "खुल्ने समय", box: box(0.2, 0.30, 0.8, 0.38)))
        XCTAssertEqual(rects[0].minX, printed.minX, accuracy: 1e-6)
        XCTAssertEqual(rects[0].minY, printed.minY, accuracy: 1e-6)
        XCTAssertEqual(rects[0].width, printed.width, accuracy: 1e-6)
        XCTAssertEqual(rects[0].height, printed.height, accuracy: 1e-6)
    }

    /// Above the threshold the box follows, and it follows **on the frame that
    /// notices**: nothing is drawn from a value the memory has discarded, and
    /// the move is the view's to glide (T-021's smoothing).
    func testADriftBeyondTheThresholdIsAdoptedOnTheFrameItCrosses() {
        let memory = LiveOverlayGeometryMemory()
        let before = drawn(memory, surface(box: box(0.2, 0.30, 0.8, 0.38))).first
        let moved = surface(box: box(0.2, 0.30, 0.8, 0.44))
        let after = drawn(memory, moved).first

        guard let before, let after, let placed = moved.presentations.first else {
            return XCTFail("both frames must place the region")
        }
        XCTAssertNotEqual(after.frameRect, before.frameRect,
                          "6 % of the container is a move the elder can see, and it lands")
        XCTAssertEqual(after.frameRect, placed.frameRect,
                       "the frame that notices the move draws it: the memory is never one frame behind")
        XCTAssertEqual(memory.count, 1, "the same identity, at a new rect")
    }

    /// A creep too slow to cross the threshold in one pass still lands, because
    /// the comparison is against the rect **on screen**: the difference
    /// accumulates until it is one the elder could see. Six frames of the
    /// detector's 1.5 %-per-pass creep draw two rects, not six.
    func testASteadyCreepAccumulatesUntilItIsOneTheElderCanSee() {
        let memory = LiveOverlayGeometryMemory()
        var rects: [CGRect] = []
        for step in 0..<6 {
            let dy = 0.015 * Double(step)
            rects.append(drawn(memory, surface(box: box(0.2, 0.30 + dy, 0.8, 0.38 + dy))).first!.frameRect)
        }

        XCTAssertEqual(rects[0], rects[1], "1.5 % is below the threshold: held")
        XCTAssertEqual(rects[0], rects[2], "and again: the drift is measured against the drawn rect, "
                       + "not against the last measurement")
        XCTAssertNotEqual(rects[0], rects[3], "by the third step the accumulated drift is past the "
                          + "threshold, so the box lands where the sign is")
        XCTAssertEqual(rects[3], rects[5], "and then holds again at its new rect")
        XCTAssertEqual(Set(rects).count, 2,
                       "six frames, two drawn rects: the box moves less often than the detector does")
    }

    /// Size hysteresis, on the same rule: a 2 % change in the box's height is
    /// not a resize the elder can see, an 8 % one is.
    func testAHeightChangeBelowTheThresholdIsHeldAndOneAboveItLands() {
        let memory = LiveOverlayGeometryMemory()
        let base = drawn(memory, surface(box: box(0.2, 0.30, 0.8, 0.38))).first!
        let taller = surface(box: box(0.2, 0.30, 0.8, 0.40))
        let held = drawn(memory, taller).first!

        XCTAssertEqual(held.frameRect.height, base.frameRect.height, accuracy: 1e-9,
                       "a 2 % resize is not worth a redraw")
        XCTAssertEqual(held.frameRect, base.frameRect)

        let muchTaller = surface(box: box(0.2, 0.30, 0.8, 0.46))
        let landed = drawn(memory, muchTaller).first!
        XCTAssertEqual(landed.frameRect, muchTaller.presentations.first?.frameRect,
                       "8 % is a resize, and it is drawn immediately")
        XCTAssertGreaterThan(landed.frameRect.height, base.frameRect.height)
    }

    /// The memory is keyed by the *string*, so it survives the stabiliser
    /// re-issuing the region's identity — while the announcement and the tap
    /// keep addressing the region that is on screen now (`onTapRegion` takes
    /// the current id; a held rect must never hold a stale one).
    func testAHeldBoxSurvivesTheRegionIdentityBeingReissued() {
        let memory = LiveOverlayGeometryMemory()
        let first = drawn(memory, surface(box: box(0.2, 0.30, 0.8, 0.38), region: 0)).first!
        let second = drawn(memory, surface(box: box(0.2, 0.31, 0.8, 0.39), region: 7)).first!

        XCTAssertNotEqual(first.regionID, second.regionID,
                          "the premise: the stabiliser re-issued the region's identity")
        XCTAssertEqual(first.id, second.id, "the view identity is the string")
        XCTAssertEqual(second.frameRect, first.frameRect,
                       "a 1 % move under a re-issued id is not a move: the box holds")
        XCTAssertEqual(second.regionID, identity(7),
                       "but everything the elder reads or taps is the region on screen now")
        XCTAssertEqual(second.accessibilityLabel, first.accessibilityLabel)
    }

    /// A change of *form kind* is never held, however close the two rects
    /// happen to be: which form a region is drawn in is a decision the
    /// placement made (the translation fits in place, or the preference wants
    /// the original kept visible), not a position that can be stale. The rects
    /// here are a few points apart on purpose — a rect-only rule would hold
    /// them.
    func testAChangeOfFormIsNeverHeldHoweverCloseTheRectsAre() {
        let memory = LiveOverlayGeometryMemory()
        let sign = "खुल्ने समय"
        let inPlace = CGRect(x: 100, y: 300, width: 120, height: 40)
        let pill = CGRect(x: 100, y: 330, width: 120, height: 40)
        let anchor = CGPoint(x: 160, y: 320)

        let inPlaceForm = LiveOverlayPlacement.Form.inPlace(regionID: identity(0), rect: inPlace)
        let calloutForm = LiveOverlayPlacement.Form.callout(regionID: identity(0), anchor: anchor,
                                                            pillRect: pill)
        XCTAssertLessThanOrEqual(LiveOverlayFormGeometry(calloutForm).drift(
            from: LiveOverlayFormGeometry(inPlaceForm), in: container),
                                 CGFloat(config.overlayGeometryStickiness),
                                 "the premise: these two geometries are within the threshold of each other")

        // In place → callout: the elder asked for the original, so the box must
        // not stay on the text it would hide.
        _ = memory.held([presentation(sign, form: inPlaceForm)], container: container,
                        stickiness: config.overlayGeometryStickiness)
        let becameCallout = memory.held([presentation(sign, form: calloutForm)], container: container,
                                        stickiness: config.overlayGeometryStickiness)
        guard case .callout(_, let heldAnchor, let heldPill) = becameCallout.first?.form else {
            return XCTFail("an in-place box was held where the callout belongs: that hides the "
                           + "original the elder asked to see (FR-LCT-017)")
        }
        XCTAssertEqual(heldPill, pill)
        XCTAssertEqual(heldAnchor, anchor)

        // …and back again, when the translation fits in place once more.
        let becameInPlace = memory.held([presentation(sign, form: inPlaceForm)], container: container,
                                        stickiness: config.overlayGeometryStickiness)
        guard case .inPlace(_, let heldRect) = becameInPlace.first?.form else {
            return XCTFail("a callout was held where the in-place box belongs")
        }
        XCTAssertEqual(heldRect, inPlace)
    }

    /// The memory holds the identities that are on screen and releases the ones
    /// that left, so a long session cannot grow it (NFR-LCT-005).
    func testAnIdentityThatLeavesTheFrameIsReleased() {
        let memory = LiveOverlayGeometryMemory()
        _ = drawn(memory, surface(box: box(0.2, 0.30, 0.8, 0.38)))
        XCTAssertEqual(memory.count, 1)

        _ = drawn(memory, makeSurface(regions: []))
        XCTAssertEqual(memory.count, 0, "the region left the frame; so did its rect")
    }

    /// With no container to measure in there is no fraction to measure against,
    /// so nothing is held: the placement's own rects are drawn, never a frozen
    /// frame.
    func testADegenerateContainerHoldsNothing() {
        let memory = LiveOverlayGeometryMemory()
        let frame = surface(box: box(0.2, 0.30, 0.8, 0.38))
        let first = LiveOverlayFormGeometry(frame.presentations.first!.form)
        let second = LiveOverlayFormGeometry(surface(box: box(0.2, 0.35, 0.8, 0.43))
            .presentations.first!.form)
        XCTAssertEqual(first.drift(from: second, in: .zero), .infinity,
                       "no container, no fraction: nothing may be held")

        _ = memory.held(frame.presentations, container: .zero, stickiness: config.overlayGeometryStickiness)
        let again = memory.held(frame.presentations, container: .zero,
                                stickiness: config.overlayGeometryStickiness)
        XCTAssertEqual(again.first?.frameRect, frame.presentations.first?.frameRect)
    }

    /// What is left for the view to animate is a move the elder can see: the
    /// glide is a third of a second and eases out, and it is keyed on the drawn
    /// rect — the one the memory just adopted.
    func testTheDrawnBoxGlidesRatherThanJumping() {
        XCTAssertGreaterThanOrEqual(LiveTranslateOverlaySurface.positionSmoothingSeconds, 0.30,
                                    "shorter than this and a landing still reads as a jump")
        XCTAssertLessThanOrEqual(LiveTranslateOverlaySurface.positionSmoothingSeconds, 0.35,
                                 "longer and the box visibly lags the sign it is drawn over")

        let overlay = FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/App/LiveTranslate/LiveTranslateOverlayView.swift"))
        XCTAssertTrue(overlay.contains(".easeOut(duration: LiveTranslateOverlaySurface.positionSmoothingSeconds)"),
                      "the glide eases out: the box decelerates into its new rect")
        XCTAssertTrue(overlay.contains("value: presentation.frameRect"),
                      "and it is keyed on the rect that was drawn, so a held box does not animate")
    }

    // MARK: - Scenario: the snapshot's results card (owner UX rework)

    /// The card is the snapshot's reading surface, and it is derived from the
    /// overlay's own presentations — so the row count is the placement count by
    /// construction, and no row can say something the overlay would not.
    func testTheResultsCardHasOneRowPerPlacementAndItsRowsCarryTheSameFacts() {
        let resolved = region(0, "खुल्ने समय", box: box(0.2, 0.10, 0.8, 0.16))
        let tiny = region(1, "प्रवेश निषेध", box: box(0.2, 0.40, 0.26, 0.42))
        let degraded = region(2, "बाहिर निस्कनुहोस्", box: box(0.2, 0.70, 0.8, 0.76))
        let surface = makeSurface(
            regions: [resolved, tiny, degraded],
            results: [resolved.id: .resolved(originalText: resolved.text,
                                             translation: "Opening hours", tier: .cloud),
                      tiny.id: .resolved(originalText: tiny.text,
                                         translation: "No entry beyond this point, thank you",
                                         tier: .cloud),
                      degraded.id: .degraded(originalText: degraded.text, reason: .noNetwork)])

        let card = LiveTranslateResultsCardSurface(overlay: surface)

        XCTAssertEqual(card.rows.count, surface.placements.count,
                       "the row count is the placement count: nothing dropped, nothing invented")
        XCTAssertEqual(card.rows.count, surface.presentations.count)
        XCTAssertFalse(card.isEmpty)
        XCTAssertEqual(card.emptyHint, surface.emptyHint,
                       "one situation, one sentence: the card reuses the overlay's calm hint")

        for (row, presentation) in zip(card.rows, surface.presentations) {
            XCTAssertEqual(row.id, presentation.id,
                           "the card is keyed by the same identity the boxes are")
            XCTAssertEqual(row.regionID, presentation.regionID)
            XCTAssertEqual(row.translation, presentation.accessibilityLabel,
                           "the large line is what a screen reader announces: the two cannot drift")
            XCTAssertEqual(row.source, presentation.accessibilityValue)
            XCTAssertEqual(row.symbolName, presentation.symbolName)
            XCTAssertEqual(row.speaksTranslation, presentation.speaksTranslation)
        }

        XCTAssertEqual(card.rows.map(\.translation),
                       ["Opening hours", "No entry beyond this point, thank you", degraded.text],
                       "in reading order, and never a translated-looking string for a region "
                       + "that was not translated (FR-LCT-018)")
        XCTAssertEqual(card.rows.map(\.speaksTranslation), [true, true, false],
                       "a row with nothing to hear is not a button that does nothing")
        XCTAssertEqual(card.rows[2].source,
                       L10n.str("livetranslate.state.unavailable", locale: nepali))
    }

    func testAnEmptyFrameGivesAnEmptyCardWithTheCalmSentence() {
        let card = LiveTranslateResultsCardSurface(overlay: makeSurface(regions: []))

        XCTAssertTrue(card.rows.isEmpty)
        XCTAssertTrue(card.isEmpty)
        XCTAssertEqual(card.emptyHint, L10n.str("livetranslate.empty.hint", locale: nepali))
    }

    /// The card's type scale and hit target, at the values the view draws with:
    /// the translation at the app's body floor (≥18pt by the token table's own
    /// test), the original smaller beneath it, and every row a legal tap
    /// target. The view half is a source scan, so an edit that swapped a token
    /// for a literal would fail here.
    func testTheResultsCardDrawsAtTheAppsTypeScaleAndTapTarget() {
        XCTAssertGreaterThanOrEqual(DesignTokens.minBodyPointSize, 18,
                                    "the card's translation line is elder-readable")
        XCTAssertLessThan(DesignTokens.minCaptionPointSize, DesignTokens.minBodyPointSize,
                          "the original is the smaller line")
        XCTAssertGreaterThanOrEqual(DesignTokens.minTapTargetSize, 44,
                                    "a row is a target an elder-sized thumb can hit")

        let view = FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/App/LiveTranslate/LiveTranslateView.swift"))
        XCTAssertTrue(view.contains("Text(row.translation)"),
                      "the card draws the translation as the large line")
        XCTAssertTrue(view.contains("DesignTokens.warmFont(size: DesignTokens.minBodyPointSize"),
                      "and at the app's body floor, not a literal size")
        XCTAssertTrue(view.contains("DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize"),
                      "with the original at the app's caption floor beneath it")
        XCTAssertTrue(view.contains("minWidth: DesignTokens.minTapTargetSize"))
        XCTAssertTrue(view.contains("minHeight: DesignTokens.minTapTargetSize"))
    }
}
