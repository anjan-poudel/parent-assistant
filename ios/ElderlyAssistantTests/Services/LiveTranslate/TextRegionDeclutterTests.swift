import XCTest
@testable import ElderlyAssistant

/// T-010 — decluttering: same-string neighbours merge, and the cap keeps what
/// a person can actually read (C03, OD5).
///
/// Everything here is asserted on the **emitted set**, not on a private
/// helper: `visible` is the one set the overlay renders and the tier
/// translates, so "exactly one overlay per kept region" is a statement about
/// that set.
final class TextRegionDeclutterTests: XCTestCase {

    // MARK: - Fixtures

    private func box(_ x: Double, _ y: Double,
                     width: Double = 0.2, height: Double = 0.05) -> NormalizedBox {
        NormalizedBox(xMin: x, yMin: y, xMax: x + width, yMax: y + height)
    }

    private func region(_ text: String,
                        _ normalizedBox: NormalizedBox,
                        id: Int,
                        confidence: Double = 0.9) -> TextRegionStabilizer.StableTextRegion {
        TextRegionStabilizer.StableTextRegion(
            id: TextRegionStabilizer.RegionIdentity(rawValue: id),
            text: text,
            normalizedText: LiveTranslateTextNormalization.normalized(text),
            box: normalizedBox,
            detectedLanguage: "en",
            confidence: confidence)
    }

    private func immediateConfig() -> LiveTranslateConfig {
        var config = LiveTranslateConfig()
        config.regionAppearPasses = 1
        config.regionMissPasses = 1
        return config
    }

    // MARK: - Merge

    func testSameStringNeighboursMergeIntoOneRegionWithTheLongestTextAndTheUnionBox() {
        // Two boxes within `declutterMergeCentroidDistance` of each other, the
        // same word seen twice (a sign read in two pieces).
        let left = region("Start", box(0.10, 0.20, width: 0.10, height: 0.05), id: 0)
        let right = region("START ", box(0.14, 0.21, width: 0.12, height: 0.05), id: 1)

        let result = TextRegionStabilizer.declutter([left, right], config: LiveTranslateConfig())

        XCTAssertEqual(result.count, 1, "the same string on neighbouring boxes is one overlay")
        guard let merged = result.first else { return }
        XCTAssertEqual(merged.normalizedText, "start")
        XCTAssertEqual(merged.text, "START ", "the longest rendering of the string is kept")
        XCTAssertEqual(merged.box.xMin, 0.10, accuracy: 1e-9)
        XCTAssertEqual(merged.box.yMin, 0.20, accuracy: 1e-9)
        XCTAssertEqual(merged.box.xMax, 0.26, accuracy: 1e-9)
        XCTAssertEqual(merged.box.yMax, 0.26, accuracy: 1e-9,
                       "the box is the union, so the overlay still points at all of the text")
        XCTAssertEqual(merged.id, left.id, "the lower identity carries the merged region")
    }

    func testDifferentStringsOnTheSameBoxNeverMergeAndAreNeverConcatenated() {
        let push = region("Push", box(0.20, 0.30), id: 0)
        let pull = region("Pull", box(0.20, 0.30), id: 1)

        let result = TextRegionStabilizer.declutter([push, pull], config: LiveTranslateConfig())
        XCTAssertEqual(result.count, 2, "different strings are different regions")
        XCTAssertEqual(result.map(\.text), ["Push", "Pull"])
        XCTAssertFalse(result.contains { $0.text.contains("PushPull") },
                       "no concatenation of two labels is ever produced")
    }

    func testSameStringRegionsFurtherApartThanTheMergeDistanceOnBothAxesStayTwoRegions() {
        let topLeft = region("Save", box(0.10, 0.10), id: 0)
        let bottomRight = region("Save", box(0.60, 0.60), id: 1)

        XCTAssertEqual(TextRegionStabilizer.declutter([topLeft, bottomRight],
                                                      config: LiveTranslateConfig()).count, 2,
                       "the same word in two far-apart places is two regions")
    }

    /// The merge rule is "closer than the merge distance on **either** axis"
    /// (T-010, design §C03 item 1), which is what the implementation does —
    /// pinned here because it has a consequence worth seeing: two occurrences
    /// of one word in the same column share an x-axis separation of zero and
    /// therefore merge, with a union box that still covers both. Recorded as
    /// an open item in the group notes for the OD5 device spike rather than
    /// silently "fixed" against the written rule.
    func testTheMergeRuleIsPerAxisSoSameStringRegionsSharingAColumnAxisMerge() {
        let top = region("Save", box(0.10, 0.05), id: 0)
        let bottom = region("Save", box(0.10, 0.80), id: 1)

        let merged = TextRegionStabilizer.declutter([top, bottom], config: LiveTranslateConfig())
        XCTAssertEqual(merged.count, 1, "dx is zero, so the either-axis rule merges them")
        guard let box = merged.first?.box else { return XCTFail("nothing merged") }
        XCTAssertEqual(box.xMin, 0.10, accuracy: 1e-9)
        XCTAssertEqual(box.yMin, 0.05, accuracy: 1e-9)
        XCTAssertEqual(box.xMax, 0.30, accuracy: 1e-9)
        XCTAssertEqual(box.yMax, 0.85, accuracy: 1e-9,
                       "the union still covers both occurrences")
    }

    func testMergingIsAppliedUntilNothingQualifies() {
        // Three copies of one word, each within range of the next but not of
        // the one after: the union of the first two reaches the third.
        let a = region("Open", box(0.10, 0.30, width: 0.05, height: 0.05), id: 0)
        let b = region("Open", box(0.14, 0.30, width: 0.05, height: 0.05), id: 1)
        let c = region("Open", box(0.17, 0.30, width: 0.05, height: 0.05), id: 2)

        let result = TextRegionStabilizer.declutter([a, b, c], config: LiveTranslateConfig())
        XCTAssertEqual(result.count, 1, "the merge is applied until no pair qualifies: \(result.count) left")
        guard let box = result.first?.box else { return XCTFail("nothing merged") }
        XCTAssertEqual(box.xMin, 0.10, accuracy: 1e-9)
        XCTAssertEqual(box.yMin, 0.30, accuracy: 1e-9)
        XCTAssertEqual(box.xMax, 0.22, accuracy: 1e-9)
        XCTAssertEqual(box.yMax, 0.35, accuracy: 1e-9,
                       "the merged box spans every piece the word was read in")
    }

    // MARK: - Cap

    func testTheCapKeepsTheHighestConfidenceRegionsTieBrokenByPosition() {
        var config = LiveTranslateConfig()
        config.declutterMaxRegions = 3

        // Six regions, two of them tied on confidence.
        let candidates = [
            region("A", box(0.05, 0.10), id: 0, confidence: 0.60),
            region("B", box(0.05, 0.20), id: 1, confidence: 0.95),
            region("C", box(0.05, 0.30), id: 2, confidence: 0.80),
            region("D", box(0.05, 0.40), id: 3, confidence: 0.80),
            region("E", box(0.05, 0.50), id: 4, confidence: 0.50),
            region("F", box(0.05, 0.60), id: 5, confidence: 0.70)
        ]

        let kept = TextRegionStabilizer.declutter(candidates, config: config)
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(kept.map(\.text), ["B", "C", "D"],
                       "highest confidence first, then the higher region (y), then left (x)")
    }

    func testTheCapTieBreaksByXWhenTwoRegionsShareAConfidenceAndARow() {
        var config = LiveTranslateConfig()
        config.declutterMaxRegions = 2

        let candidates = [
            region("Right", box(0.60, 0.20), id: 0, confidence: 0.9),
            region("Left", box(0.10, 0.20), id: 1, confidence: 0.9),
            region("Lower", box(0.10, 0.60), id: 2, confidence: 0.4)
        ]

        let kept = TextRegionStabilizer.declutter(candidates, config: config)
        XCTAssertEqual(kept.map(\.text), ["Left", "Right"],
                       "a full confidence/position tie is broken deterministically, and the "
                       + "emitted set is in reading order")
    }

    func testTheCapIsNotAnErrorAndTheSameRegionReturnsWithTheSameIdentityWhenRoomAppears() {
        var config = LiveTranslateConfig()
        config.regionAppearPasses = 1
        config.regionMissPasses = 2
        config.declutterMaxRegions = 2
        var stabilizer = TextRegionStabilizer(config: config)

        func observation(_ text: String, _ y: Double, confidence: Double)
            -> LiveTextDetector.DetectedTextRegion {
            LiveTextDetector.DetectedTextRegion(text: text,
                                                normalizedBox: box(0.10, y),
                                                detectedLanguage: "en",
                                                confidence: confidence)
        }
        let alpha = observation("Alpha", 0.10, confidence: 0.95)
        let beta = observation("Beta", 0.50, confidence: 0.80)
        let gamma = observation("Gamma", 0.80, confidence: 0.60)

        // Three regions detected, two published: no error, no degraded marker —
        // a capped pass is an ordinary pass.
        let first = stabilizer.consume(regions: [alpha, beta, gamma])
        XCTAssertEqual(first, [.appeared(id: TextRegionStabilizer.RegionIdentity(rawValue: 0)),
                               .appeared(id: TextRegionStabilizer.RegionIdentity(rawValue: 1))])
        XCTAssertEqual(stabilizer.visible.map(\.text), ["Alpha", "Beta"])
        XCTAssertEqual(stabilizer.activeRegionCount, 3,
                       "a capped region is tracked, not destroyed — it is simply not emitted")

        // The crowd persists: nothing churns.
        XCTAssertEqual(stabilizer.consume(regions: [beta, gamma]), [])

        // Alpha ages out (its second consecutive miss). Gamma now fits the
        // cap and returns with its ORIGINAL identity — no re-detection
        // flicker, no new identifier.
        let returned = stabilizer.consume(regions: [beta, gamma])
        XCTAssertEqual(returned, [.disappeared(id: TextRegionStabilizer.RegionIdentity(rawValue: 0)),
                                  .appeared(id: TextRegionStabilizer.RegionIdentity(rawValue: 2))])
        XCTAssertEqual(stabilizer.visible.map(\.text), ["Beta", "Gamma"])
    }

    /// A structural half of "the cap is not an error": the stabiliser has no
    /// channel to report one through.
    func testTheStabiliserCannotReportAFailureThroughItsResult() {
        let source = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Services/LiveTranslate/TextRegionStabilizer.swift")
        let code = FeatureSourceScan.codeText(of: source)
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "(?<![A-Za-z0-9_])throw(?![A-Za-z0-9_])", in: code),
                     "region stabilisation has no failure it could throw")
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "Result<", in: code),
                     "consume returns events, not a Result — a capped region is not an error")
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "(?<![A-Za-z0-9_])fatalError(?![A-Za-z0-9_])", in: code))
    }

    // MARK: - One overlay per region, deterministic and order-independent

    func testExactlyOneOverlayPerKeptRegion() {
        var config = LiveTranslateConfig()
        config.declutterMaxRegions = 4
        let candidates = [
            region("One", box(0.10, 0.10), id: 0, confidence: 0.9),
            region("one", box(0.12, 0.11), id: 1, confidence: 0.8),
            region("Two", box(0.10, 0.30), id: 2, confidence: 0.7),
            region("Three", box(0.10, 0.50), id: 3, confidence: 0.6),
            region("Four", box(0.10, 0.70), id: 4, confidence: 0.5),
            region("Five", box(0.10, 0.90), id: 5, confidence: 0.4)
        ]

        let kept = TextRegionStabilizer.declutter(candidates, config: config)
        XCTAssertLessThanOrEqual(kept.count, config.declutterMaxRegions)
        XCTAssertEqual(Set(kept.map(\.id)).count, kept.count, "one overlay per region, never two")
        // The merged pair collapsed to a single overlay, and the two lowest
        // confidence regions lost the cap.
        XCTAssertEqual(kept.map(\.text), ["One", "Two", "Three", "Four"])
    }

    func testTheSameCandidatesInTwoOrdersProduceIdenticalRegions() {
        var config = LiveTranslateConfig()
        config.declutterMaxRegions = 3
        let candidates = [
            region("Alpha", box(0.10, 0.10), id: 0, confidence: 0.9),
            region("alpha", box(0.13, 0.11), id: 1, confidence: 0.85),
            region("Beta", box(0.10, 0.40), id: 2, confidence: 0.7),
            region("Gamma", box(0.10, 0.70), id: 3, confidence: 0.6),
            region("Delta", box(0.60, 0.70), id: 4, confidence: 0.5)
        ]

        let forwards = TextRegionStabilizer.declutter(candidates, config: config)
        let backwards = TextRegionStabilizer.declutter(Array(candidates.reversed()), config: config)
        let shuffled = TextRegionStabilizer.declutter([candidates[3], candidates[0],
                                                       candidates[4], candidates[2], candidates[1]],
                                                      config: config)

        XCTAssertEqual(forwards, backwards, "the merge and the cap are total rules, not scan-order accidents")
        XCTAssertEqual(forwards, shuffled)
        XCTAssertFalse(forwards.isEmpty)
    }

    func testDeclutterRunsBeforeEmissionSoTheRenderSetAndTheRequestSetAgree() {
        var config = immediateConfig()
        config.declutterMaxRegions = 1
        var stabilizer = TextRegionStabilizer(config: config)

        let scene = [LiveTextDetector.DetectedTextRegion(text: "First",
                                                         normalizedBox: box(0.10, 0.10),
                                                         detectedLanguage: "en",
                                                         confidence: 0.99),
                     LiveTextDetector.DetectedTextRegion(text: "Second",
                                                         normalizedBox: box(0.10, 0.40),
                                                         detectedLanguage: "en",
                                                         confidence: 0.50)]
        _ = stabilizer.consume(regions: scene)
        XCTAssertEqual(stabilizer.visible.map(\.text), ["First"],
                       "what is rendered is what would be requested — the cap applies before "
                       + "either, so a capped region is never translated")
    }
}
