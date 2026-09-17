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
        // by a badge.
        XCTAssertNil(presentations[1].symbolName)
        XCTAssertEqual(presentations[1].accessibilityLabel, "No entry")
        XCTAssertEqual(presentations[1].accessibilityValue, resolved.text)
        XCTAssertTrue(presentations[1].speaksTranslation)
        guard case .callout = presentations[1].form else {
            XCTFail("a cloud translation is never drawn in place (CL-3)")
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
            guard let presentation = surface.presentations.first(where: { $0.id == region.id }),
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
            XCTFail("a dictionary translation of two words that fits is drawn in place")
            return
        }
        XCTAssertEqual(inPlace.lines.map(\.text), ["Opening hours"])
        XCTAssertEqual(inPlaceRect, screenRect(of: inPlaceRegion))

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

        let resolved = region(0, "खुल्ने समय", box: box(0.2, 0.3, 0.8, 0.4))
        let surface = makeSurface(regions: [resolved],
                                  results: [resolved.id: .resolved(originalText: resolved.text,
                                                                   translation: "Opening hours",
                                                                   tier: .cloud)])
        guard let presentation = surface.presentations.first else {
            XCTFail("the region must be placed")
            return
        }
        XCTAssertEqual(presentation.lines[0].pointSize, policy.minPointSize)
        XCTAssertEqual(presentation.lines[1].pointSize, policy.secondaryPointSize)
        XCTAssertEqual(presentation.lines[0].weight, .primary)

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

        let byIdentity = Dictionary(uniqueKeysWithValues: before.presentations.map { ($0.id, $0) })
        for presentation in after.presentations {
            if presentation.id == first.id {
                XCTAssertNotEqual(presentation, byIdentity[first.id],
                                  "the region whose result arrived must change")
            } else {
                XCTAssertEqual(presentation, byIdentity[presentation.id],
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
        let control = region(0, "प्रवेश निषेध", box: box(0.15, 0.86, 0.85, 0.92))
        let surface = makeSurface(regions: [control],
                                  results: [control.id: .resolved(originalText: control.text,
                                                                  translation: "No entry",
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
            XCTFail("a cloud translation is a callout")
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
        let callout = region(1, "प्रवेश निषेध क्षेत्र", box: box(0.2, 0.45, 0.8, 0.55))
        let same = region(2, "Wi-Fi", box: box(0.2, 0.70, 0.8, 0.80))
        let surface = makeSurface(
            regions: [inPlace, callout, same],
            results: [inPlace.id: .resolved(originalText: inPlace.text,
                                            translation: "Opening hours", tier: .dictionary),
                      callout.id: .resolved(originalText: callout.text,
                                            translation: "Restricted area", tier: .cloud),
                      same.id: .resolved(originalText: same.text,
                                         translation: same.text, tier: .dictionary)])

        let labels = Dictionary(uniqueKeysWithValues:
            surface.presentations.map { ($0.id, $0.accessibilityLabel) })
        XCTAssertEqual(labels[inPlace.id], "Opening hours")
        XCTAssertEqual(labels[callout.id], "Restricted area")
        XCTAssertEqual(labels[same.id], same.text,
                       "a translation identical to the original is announced once, not twice")

        let samePresentation = surface.presentations.first { $0.id == same.id }
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
}
