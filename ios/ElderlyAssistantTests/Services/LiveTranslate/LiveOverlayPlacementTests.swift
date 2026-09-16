import CoreGraphics
import XCTest
@testable import ElderlyAssistant

/// T-020 — the smart-mix overlay placement: the four-condition in-place
/// predicate, the anchored callout and its never-cover rule, determinism and
/// bounded cost (FR-LCT-015, FR-LCT-016, NFR-LCT-002, CL-3, D1).
///
/// The function is pure, so every claim below is made against scripted rect
/// sets and value inputs — no view, no camera, no tier, no clock.
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

    private func surfacePolicy(alwaysShowOriginal: Bool = false) -> LiveOverlayPlacement.Policy {
        LiveTranslateOverlaySurface.policy(config: .default, alwaysShowOriginal: alwaysShowOriginal)
    }

    private func rect(of region: TextRegionStabilizer.StableTextRegion) -> CGRect {
        LiveOverlayPlacement.screenRect(for: region.box, containerSize: container,
                                        framePixelSize: container)
    }

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
                                   safeArea: safeArea ?? CGRect(origin: .zero, size: container),
                                   occupiedRects: occupiedRects,
                                   policy: policy ?? surfacePolicy(),
                                   stateCopy: stateCopy,
                                   measure: measure)
    }

    private func calloutRect(_ placement: LiveOverlayPlacement.PlacedOverlay) -> CGRect? {
        guard case .callout(_, _, let pillRect) = placement.form else { return nil }
        return pillRect
    }

    private func inPlaceRect(_ placement: LiveOverlayPlacement.PlacedOverlay) -> CGRect? {
        guard case .inPlace(_, let rect) = placement.form else { return nil }
        return rect
    }

    // MARK: Scenario: in-place requires all four conditions

    /// A region whose four conditions all hold, with room to spare, so each
    /// test below can break exactly one of them.
    private func eligibleScene() -> (region: TextRegionStabilizer.StableTextRegion,
                                     result: TranslationResult) {
        let region = region(0, text: "गेट खोल्नुहोस्", box: (0.1, 0.4, 0.9, 0.6))
        return (region, .resolved(originalText: region.text,
                                  translation: "Open the gate",
                                  tier: .dictionary))
    }

    func testAllFourConditionsProduceTheInPlaceForm() {
        let (region, result) = eligibleScene()
        let placements = place([region], results: [region.id: result])

        XCTAssertEqual(placements.count, 1)
        XCTAssertEqual(inPlaceRect(placements[0]), rect(of: region),
                       "the background is sized to the region (FR-LCT-015)")
        XCTAssertEqual(placements[0].lines.map(\.text), ["Open the gate"],
                       "in place, the translation is the one thing drawn")
        XCTAssertEqual(placements[0].lines.first?.weight, .primary)
        XCTAssertEqual(placements[0].lines.first?.pointSize, surfacePolicy().minPointSize)
        XCTAssertFalse(placements[0].isClampedFallback)
    }

    func testBreakingTheTierAloneProducesACallout() {
        let (region, result) = eligibleScene()
        let cloud = TranslationResult.resolved(originalText: region.text,
                                               translation: "Open the gate",
                                               tier: .cloud)

        let eligibility = LiveOverlayPlacement.inPlaceEligibility(
            source: region.text, translation: cloud.text, regionRect: rect(of: region),
            policy: surfacePolicy(), tier: cloud.sourceTier, measure: LiveOverlayTextMetrics.measure)

        XCTAssertEqual(eligibility, .ineligible(.sourceTierIsNotDictionary))
        let placements = place([region], results: [region.id: cloud])
        XCTAssertNotNil(calloutRect(placements[0]))
        XCTAssertEqual(result.text, cloud.text, "only the tier differs between the two outcomes")
    }

    func testBreakingTheWordBoundAloneProducesACallout() {
        let (sign, _) = eligibleScene()
        let fourWords = region(1, text: "please open the gate", box: (0.1, 0.4, 0.9, 0.6))
        let result = TranslationResult.resolved(originalText: fourWords.text,
                                                translation: "गेट खोल्नुहोस्",
                                                tier: .dictionary)
        XCTAssertEqual(LiveOverlayPlacement.wordCount(fourWords.text), 4)
        XCTAssertEqual(LiveOverlayPlacement.inPlaceEligibility(
            source: fourWords.text, translation: result.text, regionRect: rect(of: fourWords),
            policy: surfacePolicy(), tier: .dictionary, measure: LiveOverlayTextMetrics.measure),
                       .ineligible(.sourceExceedsWordBound))
        XCTAssertNotNil(calloutRect(place([fourWords], results: [fourWords.id: result])[0]))
        XCTAssertEqual(rect(of: sign), rect(of: fourWords),
                       "only the source string changed, so the word bound is what ruled the form out")
    }

    func testBreakingTheFitAloneProducesACallout() {
        let (sign, _) = eligibleScene()
        let small = region(1, text: "गेट", box: (0.1, 0.4, 0.2, 0.42))
        let verbose = TranslationResult.resolved(
            originalText: small.text,
            translation: "Please open the gate by the side of the house before the evening",
            tier: .dictionary)

        XCTAssertEqual(LiveOverlayPlacement.inPlaceEligibility(
            source: small.text, translation: verbose.text, regionRect: rect(of: small),
            policy: surfacePolicy(), tier: .dictionary, measure: LiveOverlayTextMetrics.measure),
                       .ineligible(.translationDoesNotFitRegion))
        XCTAssertNotNil(calloutRect(place([small], results: [small.id: verbose])[0]))
        XCTAssertGreaterThan(rect(of: sign).width, 0)
    }

    func testTurningTheToggleOnAloneProducesACallout() {
        let (region, result) = eligibleScene()
        let on = surfacePolicy(alwaysShowOriginal: true)

        XCTAssertEqual(LiveOverlayPlacement.inPlaceEligibility(
            source: region.text, translation: result.text, regionRect: rect(of: region),
            policy: on, tier: .dictionary, measure: LiveOverlayTextMetrics.measure),
                       .ineligible(.alwaysShowOriginalIsOn))
        XCTAssertNotNil(calloutRect(place([region], results: [region.id: result], policy: on)[0]))
    }

    /// The four conditions are the four conditions: nothing else decides. A
    /// translation measured to *exactly* the region's size is still a fit —
    /// there is no hidden growth budget (D1) — and the boolean form is the
    /// same decision, not a second one.
    func testAMeasurementExactlyTheSizeOfTheRegionIsAFit() {
        let policy = surfacePolicy()
        let translation = "Open the gate"
        let measured = LiveOverlayTextMetrics.measure(translation, pointSize: policy.minPointSize,
                                               weight: .primary)
        let exactRect = CGRect(origin: .zero, size: measured)
        let onePointSmaller = CGRect(x: 0, y: 0,
                                     width: measured.width - 0.5,
                                     height: measured.height - 0.5)

        XCTAssertEqual(LiveOverlayPlacement.inPlaceEligibility(
            source: "gate", translation: translation, regionRect: exactRect, policy: policy,
            tier: .dictionary, measure: LiveOverlayTextMetrics.measure), .eligible,
                       "the fit at the minimum point size is the bound; a separate growth budget would "
                       + "reject a translation that fits exactly")
        XCTAssertEqual(LiveOverlayPlacement.inPlaceEligibility(
            source: "gate", translation: translation, regionRect: onePointSmaller, policy: policy,
            tier: .dictionary, measure: LiveOverlayTextMetrics.measure),
                       .ineligible(.translationDoesNotFitRegion),
                       "and half a point less is not a fit — the condition is a real measurement, not a "
                       + "constant that always passes")
        XCTAssertTrue(LiveOverlayPlacement.inlineEligible(
            source: "gate", translation: translation, regionRect: exactRect, policy: policy,
            tier: .dictionary, measure: LiveOverlayTextMetrics.measure),
                      "the boolean form must agree with the eligibility it renders")
    }

    func testTheWordBoundIsTheConfiguredBoundAndTheFeaturesOwnNormalization() {
        var config = LiveTranslateConfig.default
        config.inPlaceMaxSourceWordCount = 2
        let policy = LiveTranslateOverlaySurface.policy(config: config, alwaysShowOriginal: false)

        let two = region(0, text: "  Gate   open ", box: (0.1, 0.4, 0.9, 0.6))
        let three = region(1, text: "open the gate", box: (0.1, 0.4, 0.9, 0.6))

        XCTAssertEqual(LiveOverlayPlacement.wordCount(two.text), 2,
                       "trim and collapse are the feature's one normalization, not a local split")
        XCTAssertEqual(LiveOverlayPlacement.inPlaceEligibility(
            source: two.text, translation: "गेट", regionRect: rect(of: two), policy: policy,
            tier: .dictionary, measure: LiveOverlayTextMetrics.measure), .eligible)
        XCTAssertEqual(LiveOverlayPlacement.inPlaceEligibility(
            source: three.text, translation: "गेट", regionRect: rect(of: three), policy: policy,
            tier: .dictionary, measure: LiveOverlayTextMetrics.measure),
                       .ineligible(.sourceExceedsWordBound))
    }

    // MARK: Scenario: a cloud translation is never drawn in place

    /// CL-3's integration: the tier a *cached* string carries is the cache's
    /// own `Origin` mapping, and it — not the string's length, not the region's
    /// size — decides the form. The cloud string here fits comfortably; the
    /// only reason it is a callout is that a persisted entry is a cloud
    /// resolution (FR-LCT-008).
    func testACachedCloudStringIsNeverDrawnInPlaceEvenWhenItFits() throws {
        let storage = LabelTranslationCacheTestStorage()
        let bus = LiveTranslateSanitisingBus()
        let cache = LabelTranslationCache(storage: storage,
                                          observabilityBus: bus,
                                          dictionary: ["gate": "गेट खोल्नुहोस्"])
        try cache.store(text: "Opening hours", translation: "खुल्ने समय").get()

        let curated = try XCTUnwrap(try cache.lookup(text: "gate").get())
        let persisted = try XCTUnwrap(try cache.lookup(text: "Opening hours").get())
        XCTAssertEqual(curated.origin, .curatedDictionary)
        XCTAssertEqual(persisted.origin, .persisted)
        XCTAssertEqual(curated.tier, .dictionary)
        XCTAssertEqual(persisted.tier, .cloud)

        let dictionaryRegion = region(0, text: "gate", box: (0.05, 0.05, 0.95, 0.35))
        let cloudRegion = region(1, text: "Opening hours", box: (0.05, 0.55, 0.95, 0.85))
        let results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [
            dictionaryRegion.id: .resolved(originalText: dictionaryRegion.text,
                                           translation: curated.translation, tier: curated.tier),
            cloudRegion.id: .resolved(originalText: cloudRegion.text,
                                      translation: persisted.translation, tier: persisted.tier)
        ]

        // The proof that the tier alone decides: the cloud string satisfies
        // every other condition, fit included.
        XCTAssertEqual(LiveOverlayPlacement.inPlaceEligibility(
            source: cloudRegion.text, translation: persisted.translation,
            regionRect: rect(of: cloudRegion), policy: surfacePolicy(), tier: .dictionary,
            measure: LiveOverlayTextMetrics.measure), .eligible,
                       "the cloud string fits its region — the tier is the only thing ruling it out")

        let placements = place([dictionaryRegion, cloudRegion], results: results)
        XCTAssertNotNil(inPlaceRect(placements[0]), "the curated dictionary string is drawn in place")
        XCTAssertNotNil(calloutRect(placements[1]), "a cached cloud string is never drawn in place, fit or not")
        XCTAssertEqual(placements[1].result.sourceTier, .cloud)
        XCTAssertEqual(placements[0].result.sourceTier, .dictionary)
    }

    func testAnUnresolvedOutcomeIsIneligibleForTheTierAlone() {
        let (region, _) = eligibleScene()

        XCTAssertEqual(LiveOverlayPlacement.inPlaceEligibility(
            source: region.text, translation: region.text, regionRect: rect(of: region),
            policy: surfacePolicy(), tier: nil, measure: LiveOverlayTextMetrics.measure),
                       .ineligible(.sourceTierIsNotDictionary),
                       "nothing resolved ⇒ nothing is drawn in place, without a caller remembering to check")
    }

    // MARK: Scenario: measurement and rendering share one measurer

    func testTheFitDecisionMeasuresThroughTheInjectedClosureAtThePolicysSize() {
        let (region, result) = eligibleScene()
        var seen: [(text: String, pointSize: CGFloat, weight: LiveOverlayTextWeight)] = []
        let measure: LiveOverlayPlacement.Measure = { text, pointSize, weight in
            seen.append((text, pointSize, weight))
            return LiveOverlayTextMetrics.measure(text, pointSize: pointSize, weight: weight)
        }

        _ = place([region], results: [region.id: result], measure: measure)

        let policy = surfacePolicy()
        XCTAssertTrue(seen.contains { $0.text == result.text
            && $0.pointSize == policy.minPointSize && $0.weight == .primary },
                      "the fit was decided at the size and weight the view renders, or the two could diverge")
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

    // MARK: Scenario: a callout never covers its own region's text

    /// Twenty-five scripted regions across the whole container, every one of
    /// them a callout: no pill may cover the text of the region it belongs to.
    func testNoCalloutCoversItsOwnRegionAcrossAScriptedRectSet() {
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

        for placement in placements {
            guard let pillRect = calloutRect(placement) else {
                XCTFail("a degraded region is always a callout")
                continue
            }
            let own = rect(of: placement.region)
            XCTAssertFalse(pillRect.intersects(own),
                           "the callout for \(placement.region.id) covers its own region's printed text")
            // The anchor is the region rect's closest point to the pill, so it
            // is on the rect's edge when the pill sits squarely beside it —
            // hence the hairline inset rather than `contains`' half-open test.
            XCTAssertTrue(own.insetBy(dx: -0.001, dy: -0.001).contains(anchor(of: placement) ?? .zero),
                          "the leader line must land on the region it belongs to")
        }
    }

    func testTheAnchorOrderIsTheDesignsDeterministicOrder() {
        XCTAssertEqual(LiveOverlayPlacement.Anchor.allCases, [.above, .below, .right, .left],
                       "the candidates are tried above, below, right, left — in that order (FR-LCT-016)")
    }

    /// The preference below the hard constraint: among the anchors that do not
    /// cover the region's own text, the one that covers the fewest others
    /// wins. Here `above` is blocked by a second region and `below` is clear,
    /// so the run must not take the first candidate that merely passes.
    func testThePreferredAnchorIsTheOneOverlappingTheFewestOtherRegions() {
        let target = region(0, text: "Pharmacy", box: (0.35, 0.45, 0.65, 0.55))
        // Directly above the target, overlapping the whole band an `above`
        // pill would occupy.
        let blocker = region(1, text: "Closed", box: (0.30, 0.30, 0.70, 0.42))
        let results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [
            target.id: .degraded(originalText: target.text, reason: .noNetwork),
            blocker.id: .degraded(originalText: blocker.text, reason: .noNetwork)
        ]

        let placements = place([target, blocker], results: results)
        let placedTarget = placements.first { $0.region.id == target.id }
        guard let pillRect = placedTarget.flatMap(calloutRect) else {
            XCTFail("the target region got no callout")
            return
        }

        XCTAssertGreaterThanOrEqual(pillRect.minY, rect(of: target).maxY,
                                    "the pill was placed below the region rather than over its neighbour")
    }

    func testAFullySymmetricRegionTakesTheFirstAnchorInOrder() {
        let symmetric = region(0, text: "Open", box: (0.4, 0.45, 0.6, 0.55))
        let placements = place([symmetric],
                               results: [symmetric.id: .degraded(originalText: symmetric.text,
                                                                 reason: .noNetwork)])

        XCTAssertEqual(anchor(of: placements[0])?.y, rect(of: symmetric).minY,
                       "with every candidate equally good the earliest anchor holds — the same input twice "
                       + "must never pick two different anchors")
    }

    // MARK: Scenario: a callout shows both texts

    func testAResolvedCalloutShowsTheTranslationAndTheOriginal() {
        let region = region(0, text: "Opening hours", box: (0.05, 0.4, 0.95, 0.5))
        let result = TranslationResult.resolved(originalText: region.text,
                                                translation: "खुल्ने समय",
                                                tier: .cloud)
        let policy = surfacePolicy()
        let placements = place([region], results: [region.id: result])

        XCTAssertNotNil(calloutRect(placements[0]))
        XCTAssertEqual(placements[0].lines.map(\.text), ["खुल्ने समय", "Opening hours"],
                       "a callout shows the translation and the original — both (T-020)")
        XCTAssertEqual(placements[0].lines[0].weight, .primary)
        XCTAssertEqual(placements[0].lines[0].pointSize, policy.minPointSize)
        XCTAssertEqual(placements[0].lines[1].weight, .secondary)
        XCTAssertEqual(placements[0].lines[1].pointSize, policy.secondaryPointSize)
        XCTAssertLessThanOrEqual(placements[0].lines[1].pointSize, placements[0].lines[0].pointSize,
                                 "the supporting line is the smaller one")
    }

    func testAnUnresolvedCalloutShowsTheRecognizedTextAndTheHonestStateLine() {
        let region = region(0, text: "Pharmacy", box: (0.05, 0.4, 0.95, 0.5))
        let result = TranslationResult.degraded(originalText: region.text, reason: .noNetwork)
        let stateCopy = { (result: TranslationResult) -> String? in
            result.degraded ? "अनुवाद उपलब्ध छैन" : nil
        }

        let placements = place([region], results: [region.id: result], stateCopy: stateCopy)

        XCTAssertEqual(placements[0].lines.map(\.text), ["Pharmacy", "अनुवाद उपलब्ध छैन"],
                       "the elder sees what was recognized next to what is true about it — never a "
                       + "translated-looking string (FR-LCT-018)")
        XCTAssertEqual(placements[0].lines.first?.weight, .primary)
    }

    func testTheLeaderLineTargetsTheClosestPointOnTheRegion() {
        let region = region(0, text: "Pharmacy", box: (0.4, 0.45, 0.6, 0.55))
        let placements = place([region],
                               results: [region.id: .degraded(originalText: region.text,
                                                             reason: .noNetwork)])
        let own = rect(of: region)
        let pillRect = calloutRect(placements[0])!
        let anchor = anchor(of: placements[0])!

        XCTAssertEqual(anchor.x, min(max(pillRect.midX, own.minX), own.maxX), accuracy: 1e-9)
        XCTAssertEqual(anchor.y, min(max(pillRect.midY, own.minY), own.maxY), accuracy: 1e-9)
    }

    // MARK: Scenario: the full-screen corner case is recorded, not silently accepted

    func testARoomySceneIsAnchoredAndNotFlagged() {
        let region = region(0, text: "Pharmacy", box: (0.0, 0.25, 1.0, 1.0))
        let placements = place([region],
                               results: [region.id: .degraded(originalText: region.text,
                                                             reason: .noNetwork)])

        XCTAssertFalse(placements[0].isClampedFallback,
                       "a roomy side is an ordinary anchor, not the last resort")
        let pillRect = calloutRect(placements[0])!
        XCTAssertFalse(pillRect.intersects(rect(of: region)))
        XCTAssertGreaterThan(pillRect.minY, 0)
    }

    /// No candidate can satisfy the never-cover rule here: the region *is* the
    /// safe area, so every clamped pill still lands on it. The placement must
    /// still produce a pill inside the safe area, on the side with the most
    /// free space, and it must *say* that this is the corner case — that flag
    /// is what T-030's manual device validation targets.
    func testWhenNoAnchorCanSatisfyTheHardConstraintThePillIsClampedAndRecorded() {
        let region = region(0, text: "Pharmacy", box: (0.0, 0.0, 1.0, 1.0))
        let placements = place([region],
                               results: [region.id: .degraded(originalText: region.text,
                                                             reason: .noNetwork)])
        let safeArea = CGRect(origin: .zero, size: container)
        let pillRect = calloutRect(placements[0])!

        XCTAssertTrue(placements[0].isClampedFallback,
                      "the full-screen corner case must be recorded, not absorbed (OD5)")
        XCTAssertGreaterThanOrEqual(pillRect.minX, safeArea.minX)
        XCTAssertGreaterThanOrEqual(pillRect.minY, safeArea.minY)
        XCTAssertLessThanOrEqual(pillRect.maxX, safeArea.maxX)
        XCTAssertLessThanOrEqual(pillRect.maxY, safeArea.maxY)
        XCTAssertEqual(pillRect.minY, safeArea.minY, accuracy: 1e-9,
                       "the roomiest side here is above the region, so the pill pins to the top edge")
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
                ? .resolved(originalText: region.text, translation: "खुल्ने समय", tier: .cloud)
                : .degraded(originalText: region.text, reason: .noNetwork)
        }

        let first = place(regions, results: results)
        let second = place(Array(regions.reversed()), results: results)

        XCTAssertEqual(first, second,
                       "the placements are a function of the input set, not of the order it arrived in")
    }

    func testTheCostPerRegionIsBounded() {
        final class Counter { var value = 0 }
        let counter = Counter()
        let measure: LiveOverlayPlacement.Measure = { text, pointSize, weight in
            counter.value += 1
            return LiveOverlayTextMetrics.measure(text, pointSize: pointSize, weight: weight)
        }
        let regions = (0..<40).map { index in
            region(index, text: "Sign \(index)",
                   box: (0.05, 0.02 + Double(index) * 0.024, 0.6, 0.035 + Double(index) * 0.024))
        }

        let placements = place(regions, results: [:], measure: measure)

        XCTAssertEqual(placements.count, regions.count)
        XCTAssertLessThanOrEqual(counter.value, 3 * regions.count,
                                 "a fixed number of measurements per region — no loop that grows with "
                                 + "the scene (NFR-LCT-002)")
        XCTAssertGreaterThanOrEqual(counter.value, regions.count,
                                    "every region was actually measured; a skip would prove nothing")
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
                safeArea: CGRect(origin: .zero, size: container), policy: surfacePolicy(),
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
        let pillRect = calloutRect(placements[0])!

        XCTAssertGreaterThanOrEqual(pillRect.minY, 0)
        XCTAssertLessThanOrEqual(pillRect.maxY, container.height)
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

    // MARK: Helpers

    private func anchor(of placement: LiveOverlayPlacement.PlacedOverlay) -> CGPoint? {
        guard case .callout(_, let anchor, _) = placement.form else { return nil }
        return anchor
    }
}
