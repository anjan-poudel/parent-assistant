import XCTest
@testable import ElderlyAssistant

/// T-009 — `TextRegionStabilizer` (C03). Region identity, the two-sided
/// hysteresis, the change-only event gate, determinism, and the one
/// normalization shared with the cache key.
///
/// The stabiliser is pure and time-free by construction, so every check here
/// is a scripted pass sequence: no clock, no async, no OCR — the same input
/// always produces the same output, which is exactly what the determinism
/// scenario asserts.
final class TextRegionStabilizerTests: XCTestCase {

    // MARK: - Fixtures

    private func box(_ x: Double, _ y: Double,
                     width: Double = 0.2, height: Double = 0.06) -> NormalizedBox {
        NormalizedBox(xMin: x, yMin: y, xMax: x + width, yMax: y + height)
    }

    private func observation(_ text: String,
                             _ normalizedBox: NormalizedBox,
                             confidence: Double = 0.9,
                             language: String? = "en") -> LiveTextDetector.DetectedTextRegion {
        LiveTextDetector.DetectedTextRegion(text: text,
                                            normalizedBox: normalizedBox,
                                            detectedLanguage: language,
                                            confidence: confidence)
    }

    /// A config whose hysteresis is satisfied in one pass, so a scenario can
    /// test the *event gate* rather than the flicker bound. The hysteresis
    /// itself gets its own scenarios with the shipped shape.
    private func immediateConfig() -> LiveTranslateConfig {
        var config = LiveTranslateConfig()
        config.regionAppearPasses = 1
        config.regionMissPasses = 1
        return config
    }

    // MARK: - Stable identity

    func testARegionIsPublishedOnceTheAppearHysteresisIsSatisfiedAndKeepsItsIdentity() {
        var stabilizer = TextRegionStabilizer(config: LiveTranslateConfig())
        let sign = box(0.1, 0.2)

        // Pass 1: first sighting — tracked, deliberately not painted yet.
        XCTAssertEqual(stabilizer.consume(regions: [observation("Start", sign)]), [])
        XCTAssertTrue(stabilizer.visible.isEmpty, "one sighting is not yet a region")

        // Pass 2: the second consecutive sighting publishes it.
        let second = stabilizer.consume(regions: [observation("Start", sign)])
        guard case .appeared(let identity) = second.first, second.count == 1 else {
            return XCTFail("expected exactly one appeared event, got \(second)")
        }

        // Pass 3: identical input, identity unchanged, nothing emitted.
        XCTAssertEqual(stabilizer.consume(regions: [observation("Start", sign)]), [])
        XCTAssertEqual(stabilizer.visible.map(\.id), [identity])
        XCTAssertEqual(stabilizer.visible.map(\.text), ["Start"])
    }

    func testAnIdentityIsReleasedOnRemovalAndNeverReissued() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        let appeared = stabilizer.consume(regions: [observation("Push", box(0.4, 0.5))])
        guard case .appeared(let first) = appeared.first else {
            return XCTFail("expected an appeared event, got \(appeared)")
        }
        XCTAssertEqual(stabilizer.consume(regions: []), [.disappeared(id: first)])

        let second = stabilizer.consume(regions: [observation("Push", box(0.4, 0.5))])
        guard case .appeared(let secondIdentity) = second.first else {
            return XCTFail("expected the label to be re-detected, got \(second)")
        }
        XCTAssertNotEqual(secondIdentity, first,
                          "a released identity must not be resurrected (it would let a stale "
                          + "translation attach to a new region)")
    }

    // MARK: - Text change on the same identity

    func testAChangedStringOnTheSameBoxKeepsTheIdentityAndReportsATextChange() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        let sign = box(0.1, 0.2)
        let appeared = stabilizer.consume(regions: [observation("Start", sign)])
        guard case .appeared(let identity) = appeared.first else {
            return XCTFail("expected an appeared event, got \(appeared)")
        }

        let changed = stabilizer.consume(regions: [observation("Stop", sign)])
        XCTAssertEqual(changed, [.textChanged(id: identity)],
                       "a new string on the same region is a change on ONE identity, "
                       + "not a removal plus an unrelated appearance")
        XCTAssertEqual(stabilizer.visible.map(\.text), ["Stop"])
        XCTAssertEqual(stabilizer.visible.map(\.id), [identity])
    }

    func testAMovedBoxWithTheSameStringIsNotATranslationEvent() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        _ = stabilizer.consume(regions: [observation("Open", box(0.2, 0.3))])

        // The same text, nudged inside the match thresholds.
        let moved = stabilizer.consume(regions: [observation("Open", box(0.21, 0.31))])
        XCTAssertEqual(moved, [], "a moved box with unchanged text is not a translation event")
        XCTAssertEqual(stabilizer.visible.map(\.box), [box(0.21, 0.31)],
                       "the geometry follows the region even when nothing is emitted")
        XCTAssertEqual(stabilizer.visible.count, 1)
    }

    // MARK: - Matching

    func testGeometryAndStringDecideTheMatch() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        let appeared = stabilizer.consume(regions: [observation("Save", box(0.1, 0.1))])
        guard case .appeared(let first) = appeared.first else {
            return XCTFail("expected an appeared event, got \(appeared)")
        }

        // Overlapping and same string: the same region.
        XCTAssertEqual(stabilizer.consume(regions: [observation("Save", box(0.12, 0.12))]), [])
        XCTAssertEqual(stabilizer.visible.map(\.id), [first])

        // A second, disjoint box elsewhere on screen is a new region, and the
        // first stays put — the same string twice on screen is two regions.
        let secondPass = stabilizer.consume(regions: [observation("Save", box(0.1, 0.1)),
                                                      observation("Save", box(0.7, 0.7))])
        guard case .appeared(let second) = secondPass.first, secondPass.count == 1 else {
            return XCTFail("a disjoint box is a second region, got \(secondPass)")
        }
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(stabilizer.visible.count, 2)
        XCTAssertEqual(stabilizer.visible.map(\.id), [first, second])
    }

    func testAnEmptyOrUnplaceableObservationIsNeverARegion() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())

        // Nothing to translate, or a box that cannot be geometry: neither can
        // become a region, and neither is an error.
        XCTAssertEqual(stabilizer.consume(regions: [observation("   ", box(0.1, 0.1))]), [])
        XCTAssertEqual(stabilizer.consume(regions: [
            observation("Start", NormalizedBox(xMin: 0.5, yMin: 0.5, xMax: 0.5, yMax: 0.5))
        ]), [])
        XCTAssertTrue(stabilizer.visible.isEmpty)
        XCTAssertEqual(stabilizer.activeRegionCount, 0)
    }

    // MARK: - Hysteresis

    func testAFirstSightingDoesNotPaintAndAReappearingFlickerDoesNotPublish() {
        var stabilizer = TextRegionStabilizer(config: LiveTranslateConfig())
        let sign = box(0.3, 0.3)

        XCTAssertEqual(stabilizer.consume(regions: [observation("Timer", sign)]), [])
        // A missed pass between sightings resets the consecutive count, so a
        // flickering region never reaches the appear bound.
        XCTAssertEqual(stabilizer.consume(regions: []), [])
        XCTAssertEqual(stabilizer.consume(regions: [observation("Timer", sign)]), [])
        XCTAssertEqual(stabilizer.consume(regions: []), [])
        XCTAssertTrue(stabilizer.visible.isEmpty, "the overlay must not flicker on")
    }

    func testOneMissedPassKeepsTheRegionAndTheSecondRemovesItOnce() {
        var stabilizer = TextRegionStabilizer(config: LiveTranslateConfig())
        let sign = box(0.3, 0.3)
        _ = stabilizer.consume(regions: [observation("Timer", sign)])
        let appeared = stabilizer.consume(regions: [observation("Timer", sign)])
        guard case .appeared(let identity) = appeared.first else {
            return XCTFail("expected an appeared event, got \(appeared)")
        }

        // One miss: the region (and therefore its translation) survives.
        XCTAssertEqual(stabilizer.consume(regions: []), [])
        XCTAssertEqual(stabilizer.visible.map(\.id), [identity])

        // The second consecutive miss releases it — once.
        XCTAssertEqual(stabilizer.consume(regions: []), [.disappeared(id: identity)])
        XCTAssertTrue(stabilizer.visible.isEmpty)
        XCTAssertEqual(stabilizer.consume(regions: []), [],
                       "a region is removed exactly once, not once per empty pass")
    }

    // MARK: - Change-only gate

    func testAnUnchangedSceneEmitsNothingAfterThePublishPass() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        let scene = [observation("Power", box(0.05, 0.05), confidence: 0.9),
                     observation("Volume", box(0.05, 0.2), confidence: 0.8)]
        let firstPass = stabilizer.consume(regions: scene)
        XCTAssertEqual(firstPass.count, 2, "both regions appear on the first pass: \(firstPass)")

        for pass in 2...6 {
            XCTAssertEqual(stabilizer.consume(regions: scene), [],
                           "pass \(pass) of an unchanged scene must emit nothing "
                           + "(the translation gate is change-only)")
        }
        XCTAssertEqual(stabilizer.visible.count, 2)
    }

    func testATrackedPassMovesGeometryWithoutChangingTextOrEmitting() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        _ = stabilizer.consume(regions: [observation("Menu", box(0.1, 0.4))])

        let moved = stabilizer.consume(regions: [], tracked: ["Menu": box(0.14, 0.44)])
        XCTAssertEqual(moved, [], "tracking is geometry only; it cannot change a string")
        XCTAssertEqual(stabilizer.visible.map(\.box), [box(0.14, 0.44)])
    }

    // MARK: - Totality and determinism

    /// The DoD's "determinism test run twice": the same scripted sequence on
    /// two fresh stabilisers produces the same events (in the same order) and
    /// the same visible set (including identities).
    func testTheSamePassSequenceTwiceProducesTheSameEventsAndRegions() {
        func script(_ stabilizer: inout TextRegionStabilizer) -> [(String, [TextRegionStabilizer.RegionChangeEvent])] {
            var log: [(String, [TextRegionStabilizer.RegionChangeEvent])] = []
            func step(_ name: String,
                      regions: [LiveTextDetector.DetectedTextRegion],
                      tracked: [String: NormalizedBox] = [:]) {
                log.append((name, stabilizer.consume(regions: regions, tracked: tracked)))
            }
            step("publish two",
                 regions: [observation("Start", box(0.1, 0.1)), observation("Stop", box(0.6, 0.1))])
            step("unchanged",
                 regions: [observation("Start", box(0.1, 0.1)), observation("Stop", box(0.6, 0.1))])
            step("text change", regions: [observation("Start", box(0.1, 0.1)),
                                          observation("Cancel", box(0.6, 0.1))])
            step("tracking", regions: [], tracked: ["Start": box(0.12, 0.12)])
            step("empty", regions: [])
            step("reappear", regions: [observation("Start", box(0.12, 0.12))])
            return log
        }

        var first = TextRegionStabilizer(config: immediateConfig())
        var second = TextRegionStabilizer(config: immediateConfig())
        let firstLog = script(&first)
        let secondLog = script(&second)

        XCTAssertFalse(firstLog.isEmpty)
        for (stepA, stepB) in zip(firstLog, secondLog) {
            XCTAssertEqual(stepA.0, stepB.0)
            XCTAssertEqual(stepA.1, stepB.1, "step '\(stepA.0)' differed between two identical runs")
        }
        XCTAssertEqual(first.visible, second.visible)
        XCTAssertFalse(first.visible.isEmpty)
    }

    /// The two orders of the SAME candidates: the render set is a property of
    /// the scene, not of the order the detector happened to report it in.
    func testTheVisibleSetDoesNotDependOnTheOrderObservationsArriveIn() {
        let scene = [observation("Top", box(0.1, 0.05), confidence: 0.9),
                     observation("Middle", box(0.1, 0.4), confidence: 0.8),
                     observation("Bottom", box(0.1, 0.8), confidence: 0.7)]

        func visible(_ regions: [LiveTextDetector.DetectedTextRegion]) -> [TextRegionStabilizer.StableTextRegion] {
            var stabilizer = TextRegionStabilizer(config: immediateConfig())
            _ = stabilizer.consume(regions: regions)
            return stabilizer.visible
        }

        let forwards = visible(scene)
        let backwards = visible(Array(scene.reversed()))
        let shuffled = visible([scene[1], scene[2], scene[0]])

        XCTAssertEqual(forwards.map(\.text), ["Top", "Middle", "Bottom"],
                       "the emitted set is ordered by where the text is, top to bottom")
        XCTAssertEqual(forwards.map(\.text), backwards.map(\.text))
        XCTAssertEqual(forwards.map(\.box), backwards.map(\.box))
        XCTAssertEqual(forwards.map(\.text), shuffled.map(\.text))
        XCTAssertEqual(forwards.map(\.box), shuffled.map(\.box))
    }

    func testResetDropsEveryRegionAndNeverReissuesAnIdentity() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        let appeared = stabilizer.consume(regions: [observation("Wash", box(0.2, 0.2))])
        guard case .appeared(let before) = appeared.first else {
            return XCTFail("expected an appeared event, got \(appeared)")
        }

        stabilizer.reset()
        XCTAssertTrue(stabilizer.visible.isEmpty)
        XCTAssertEqual(stabilizer.activeRegionCount, 0)

        let after = stabilizer.consume(regions: [observation("Wash", box(0.2, 0.2))])
        guard case .appeared(let afterIdentity) = after.first else {
            return XCTFail("expected the label to be re-detected, got \(after)")
        }
        XCTAssertNotEqual(afterIdentity, before,
                          "a reset clears the scene, not the identity space")
    }

    // MARK: - Normalization is the cache key

    func testTheNormalizedTextIsExactlyTheCacheKeyPrefix() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        _ = stabilizer.consume(regions: [observation("  Keep   Warm  ", box(0.3, 0.3))])

        guard let region = stabilizer.visible.first else { return XCTFail("no region published") }
        XCTAssertEqual(region.normalizedText, "keep warm")

        let key = LabelTranslationCache.normalizationKey(text: region.text,
                                                         targetLanguage: .nepali)
        XCTAssertEqual(key, region.normalizedText + "|" + AppLanguage.nepali.rawValue,
                       "a region maps to exactly one cache key (FR-LCT-007)")
        XCTAssertEqual(LiveTranslateTextNormalization.normalizedText(fromKey: key), region.normalizedText)
    }

    func testNormalizationTrimsCollapsesAndCaseFoldsButNeverStemsOrFoldsSynonyms() {
        XCTAssertEqual(LiveTranslateTextNormalization.normalized("  Start \n\t"), "start")
        XCTAssertEqual(LiveTranslateTextNormalization.normalized("Keep\t\twarm"), "keep warm")
        // No stemming, no synonym folding, no partial matching: a near-miss is
        // a different string, and therefore a different key.
        XCTAssertNotEqual(LiveTranslateTextNormalization.normalized("starting"),
                          LiveTranslateTextNormalization.normalized("start"))
        XCTAssertNotEqual(LiveTranslateTextNormalization.normalized("start"),
                          LiveTranslateTextNormalization.normalized("begin"))
    }

    // MARK: - Devanagari fixture (pin, do not "fix")

    /// The known behaviour: Swift's `String` is a collection of extended
    /// grapheme clusters, so Devanagari conjuncts and dependent-vowel signs
    /// form single `Character`s. Partial-word matching on those clusters
    /// fails (`String.contains` cannot see inside one), which is exactly why
    /// this feature matches WHOLE normalized strings and never substrings.
    /// This fixture pins the behaviour rather than "fixing" it: a later change
    /// that starts splitting clusters — or that quietly introduces prefix
    /// matching — fails here.
    func testDevanagariCharacterClustersArePinnedAndMatchingStaysWholeString() {
        // A conjunct is ONE character: the cluster survives normalization
        // intact rather than being split into its scalar parts.
        XCTAssertEqual(LiveTranslateTextNormalization.normalized("क्ष"), "क्ष")
        XCTAssertEqual(LiveTranslateTextNormalization.normalized("क्ष").count, 1)

        // A dependent-vowel sign changes the cluster, and therefore the key:
        // "म" and "मा" are different words, and a prefix match would conflate
        // them.
        XCTAssertNotEqual(LiveTranslateTextNormalization.normalized("म"),
                          LiveTranslateTextNormalization.normalized("मा"))
        XCTAssertNotEqual(LiveTranslateTextNormalization.normalized("नमस्ते"),
                          LiveTranslateTextNormalization.normalized("नमस्ते जी"))

        // Whitespace collapsing around clusters keeps them whole.
        XCTAssertEqual(LiveTranslateTextNormalization.normalized("  नमस्ते   संसार "),
                       "नमस्ते संसार")
        XCTAssertEqual(LiveTranslateTextNormalization.normalized("  नमस्ते   संसार ").count,
                       "नमस्ते संसार".count)
    }

    func testADependentVowelSignOnTheSameBoxIsATextChangeNotASilentNoOp() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        let sign = box(0.2, 0.2)
        let appeared = stabilizer.consume(regions: [observation("म", sign, language: "ne")])
        guard case .appeared(let identity) = appeared.first else {
            return XCTFail("expected an appeared event, got \(appeared)")
        }

        let changed = stabilizer.consume(regions: [observation("मा", sign, language: "ne")])
        XCTAssertEqual(changed, [.textChanged(id: identity)],
                       "a cluster-level difference is a different string, never a partial-word match")
        XCTAssertEqual(stabilizer.visible.map(\.text), ["मा"])
    }

    // MARK: - Content-free events

    func testNoRecognizedStringCanTravelInAnEvent() {
        // Structural: every case's payload is an identity, and only that, so
        // there is no parameter a recognized string could travel in.
        let source = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Services/LiveTranslate/TextRegionStabilizer.swift")
        let code = FeatureSourceScan.codeText(of: source)
        for name in ["appeared", "textChanged", "disappeared"] {
            let pattern = "case \(name)\\(id: RegionIdentity\\)"
            XCTAssertNotNil(FeatureSourceScan.firstMatch(of: pattern, in: code),
                            "event case \(name) must carry a region identity and nothing else")
        }

        // Behavioural: a real scene's event stream, run through the shipped
        // sanitising bus, carries no recognized string.
        let bus = LiveTranslateSanitisingBus()
        let events = LiveTranslateEvents(bus: bus, config: .default)
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        let secret = "परीक्षण क्षेत्र"
        let pass = stabilizer.consume(regions: [observation(secret, box(0.31, 0.31))])
        XCTAssertEqual(pass.count, 1)

        for event in pass {
            let described = String(describing: event)
            XCTAssertFalse(described.contains(secret),
                           "the event payload must not carry recognized text: \(described)")
            XCTAssertFalse(described.contains("परीक्षण"))
            switch event {
            case .appeared: events.regionAppeared()
            case .textChanged: events.textChange(regionCount: stabilizer.visible.count)
            case .disappeared: events.regionRemoved()
            }
        }
        for event in bus.events {
            let line = String(describing: event) + event.metadata.values.joined()
            XCTAssertFalse(line.contains("परीक्षण"),
                           "no sanitised event may carry the recognized string: \(line)")
        }
        XCTAssertEqual(bus.eventTypes, ["region_appeared"],
                       "the published region is recorded once, by type only")
    }
}
