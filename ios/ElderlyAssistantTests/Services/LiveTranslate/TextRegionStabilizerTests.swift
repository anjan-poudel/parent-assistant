import XCTest
@testable import ElderlyAssistant

/// T-009 — `TextRegionStabilizer` (C03). Region identity, the two-sided
/// hysteresis, the change-only event gate, determinism, and the one
/// normalization shared with the cache key.
///
/// The stabiliser reads no clock of its own — the one time it needs (the
/// departure grace) is a parameter — so every check here is a scripted pass
/// sequence: no async, no OCR, and for the timing section a clock the test
/// states rather than waits on. The same input always produces the same
/// output, which is exactly what the determinism scenario asserts.
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

    // MARK: - String-keyed identity across camera movement

    /// A config whose hysteresis is satisfiable in one pass but whose miss
    /// bound leaves a region alive across a gap, so the string-identity
    /// *window* can be observed rather than assumed.
    private func windowedConfig(missPasses: Int, window: Int) -> LiveTranslateConfig {
        var config = LiveTranslateConfig()
        config.regionAppearPasses = 1
        config.regionMissPasses = missPasses
        config.regionStringIdentityPasses = window
        return config
    }

    /// The owner-reported defect, at the level it is decided: a camera
    /// movement carries the box past every geometry threshold, and the region
    /// keeps its identity and simply adopts the new box.
    ///
    /// The move is chosen to defeat **both** halves of the geometry gate —
    /// no overlap at all, and a centroid distance above
    /// `regionMatchCentroidDistance` — because a match that still qualifies
    /// geometrically would pass whether or not the string rule exists.
    func testAPureCameraMoveKeepsTheIdentityAndAdoptsTheNewBox() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        let appeared = stabilizer.consume(regions: [observation("Wash", box(0.05, 0.05, width: 0.10, height: 0.05))])
        guard case .appeared(let identity) = appeared.first else {
            return XCTFail("expected an appeared event, got \(appeared)")
        }

        // A 0.40 downward pan: disjoint boxes, centroid distance 0.40 — past
        // both `regionMatchIoU` and `regionMatchCentroidDistance`.
        let moved = box(0.05, 0.45, width: 0.10, height: 0.05)
        XCTAssertEqual(stabilizer.consume(regions: [observation("Wash", moved)]), [],
                       "a camera movement is not a translation event")
        XCTAssertEqual(stabilizer.visible.map(\.id), [identity],
                       "the same string keeps the same identity however far its box moved")
        XCTAssertEqual(stabilizer.visible.map(\.box), [moved],
                       "geometry-only drift adopts the new box, never a new identity")
        XCTAssertEqual(stabilizer.activeRegionCount, 1)
    }

    /// The same claim as a scripted pan: every frame moves the box, no frame
    /// is a new region, and the whole movement emits nothing after the
    /// publish pass. This is the frame sequence the device shake produced.
    func testAScriptedCameraPanEmitsNothingAndBirthsNoIdentity() {
        var stabilizer = TextRegionStabilizer(config: LiveTranslateConfig())
        // Each step is a 0.40 pan: disjoint from the previous box, and past
        // the centroid gate, so only the string can hold the region together.
        let pan: [Double] = [0.05, 0.45, 0.85, 0.45, 0.05]

        var published: TextRegionStabilizer.RegionIdentity?
        for (frame, y) in pan.enumerated() {
            let events = stabilizer.consume(regions: [observation("Wash", box(0.05, y, width: 0.10, height: 0.05))])
            switch frame {
            case 0:
                XCTAssertEqual(events, [], "the first sighting is not yet a region")
            case 1:
                guard case .appeared(let identity) = events.first, events.count == 1 else {
                    return XCTFail("expected one appeared event on frame 1, got \(events)")
                }
                published = identity
            default:
                XCTAssertEqual(events, [],
                               "frame \(frame) of a pure camera movement must re-resolve nothing")
            }
        }

        XCTAssertEqual(stabilizer.visible.map(\.id), [published].compactMap { $0 })
        XCTAssertEqual(stabilizer.visible.map(\.box),
                       [box(0.05, 0.05, width: 0.10, height: 0.05)],
                       "the overlay followed the pan to the box it ended on")
        XCTAssertEqual(stabilizer.activeRegionCount, 1,
                       "five frames of movement produced one region, not five")
    }

    /// The window's positive half: a region missed once is still claimable by
    /// its string, so a movement that straddles a dropped frame does not
    /// create a second identity for the same sign.
    func testAStringIdentitySurvivesAMissedPassWithinItsWindow() {
        var stabilizer = TextRegionStabilizer(config: windowedConfig(missPasses: 2, window: 2))
        let appeared = stabilizer.consume(regions: [observation("Exit", box(0.05, 0.05, width: 0.10, height: 0.05))])
        guard case .appeared(let identity) = appeared.first else {
            return XCTFail("expected an appeared event, got \(appeared)")
        }

        // One dropped frame: the region survives on hysteresis alone.
        XCTAssertEqual(stabilizer.consume(regions: []), [])

        // The sign is recognized again far away — geometry alone would call
        // this a new region.
        let reappeared = box(0.85, 0.85, width: 0.10, height: 0.05)
        XCTAssertEqual(stabilizer.consume(regions: [observation("Exit", reappeared)]), [])
        XCTAssertEqual(stabilizer.visible.map(\.id), [identity])
        XCTAssertEqual(stabilizer.visible.map(\.box), [reappeared])
    }

    /// The window's negative half, and the pin on "the identifier of a
    /// removed region is never resurrected": a region the stabiliser has been
    /// missing for longer than `regionStringIdentityPasses` is not the same
    /// region, however identical its text is.
    func testAStringOutsideItsIdentityWindowIsANewRegion() {
        var stabilizer = TextRegionStabilizer(config: windowedConfig(missPasses: 4, window: 2))
        let appeared = stabilizer.consume(regions: [observation("Exit", box(0.05, 0.05, width: 0.10, height: 0.05))])
        guard case .appeared(let identity) = appeared.first else {
            return XCTFail("expected an appeared event, got \(appeared)")
        }

        // Three consecutive misses: alive on the miss bound, outside the
        // window (pass 4 minus last seen at pass 1 is 3 > window 2).
        for pass in 2...4 {
            XCTAssertEqual(stabilizer.consume(regions: []), [], "pass \(pass) is a miss, not a removal")
        }
        XCTAssertEqual(stabilizer.visible.map(\.id), [identity],
                       "the region is still alive — this is the window expiring, not the region")

        let returned = stabilizer.consume(regions: [observation("Exit", box(0.85, 0.85,
                                                                           width: 0.10, height: 0.05))])
        guard case .appeared(let born) = returned.last, returned.count == 2 else {
            return XCTFail("expected the old region to age out and a new one to appear, got \(returned)")
        }
        XCTAssertEqual(returned.first, .disappeared(id: identity))
        XCTAssertNotEqual(born, identity,
                          "a sighting outside the window is a new region, not a resurrected one")
    }

    /// Geometry is still the tiebreaker, and still the *fallback*: a
    /// different string on a moved-but-overlapping box is a text change on
    /// the same identity, never a new region — the string rule must not
    /// hijack it.
    func testADifferentStringOnAMovedBoxIsATextChangeOnTheSameIdentity() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        let appeared = stabilizer.consume(regions: [observation("Start", box(0.10, 0.10))])
        guard case .appeared(let identity) = appeared.first else {
            return XCTFail("expected an appeared event, got \(appeared)")
        }

        // Overlapping (IoU ≈ 0.43, above `regionMatchIoU`), different string.
        XCTAssertEqual(stabilizer.consume(regions: [observation("Stop", box(0.12, 0.12))]),
                       [.textChanged(id: identity)])
        XCTAssertEqual(stabilizer.visible.map(\.id), [identity])
        XCTAssertEqual(stabilizer.visible.map(\.text), ["Stop"])
    }

    /// Two occurrences of one string on one screen stay two regions through a
    /// pan: each observation takes the occurrence nearest it, because
    /// `seen` makes the earlier choice unavailable to the later one. Without
    /// that, the string rule would collapse both signs onto one identity.
    func testTwoOccurrencesOfOneStringKeepTheirOwnIdentitiesThroughAPan() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        let top = box(0.05, 0.05, width: 0.10, height: 0.05)
        let bottom = box(0.45, 0.55, width: 0.10, height: 0.05)

        let appeared = stabilizer.consume(regions: [observation("Save", top),
                                                    observation("Save", bottom)])
        XCTAssertEqual(appeared.count, 2, "two disjoint occurrences are two regions: \(appeared)")
        let identities = stabilizer.visible.map(\.id)
        XCTAssertEqual(identities.count, 2)

        // A 0.40 downward pan: each box is disjoint from its predecessor and
        // 0.40 away from it — past the centroid gate — while staying nearer
        // its own occurrence than the other one. Only the string can hold
        // each region together, and each observation must take its own.
        let movedTop = box(0.05, 0.45, width: 0.10, height: 0.05)
        let movedBottom = box(0.45, 0.95, width: 0.10, height: 0.05)
        XCTAssertEqual(stabilizer.consume(regions: [observation("Save", movedTop),
                                                    observation("Save", movedBottom)]), [])
        XCTAssertEqual(stabilizer.visible.map(\.id), identities,
                       "each occurrence kept its own identity through the pan")
        XCTAssertEqual(stabilizer.visible.map(\.box), [movedTop, movedBottom])
        XCTAssertEqual(stabilizer.activeRegionCount, 2,
                       "a pan moves two regions; it does not create or merge any")
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

    // MARK: - Departure grace (owner device verdict, 2026-09-17)

    /// A fixed base so every timing assertion states its own clock; no test in
    /// this section reads the wall or waits for anything.
    private let clockStart = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: TimeInterval) -> Date {
        clockStart.addingTimeInterval(seconds)
    }

    /// Publishes one region under the **shipped** hysteresis and returns its
    /// identity. Sightings land at the nominal cadence (0.25 s), which is the
    /// cadence a scene still being recognized runs at.
    private func publishedRegion(_ stabilizer: inout TextRegionStabilizer,
                                 text: String = "Timer",
                                 box sign: NormalizedBox) -> TextRegionStabilizer.RegionIdentity {
        _ = stabilizer.consume(regions: [observation(text, sign)], at: at(0))
        let appeared = stabilizer.consume(regions: [observation(text, sign)], at: at(0.25))
        guard case .appeared(let identity) = appeared.first else {
            XCTFail("expected an appeared event, got \(appeared)")
            return TextRegionStabilizer.RegionIdentity(rawValue: -1)
        }
        return identity
    }

    /// The owner's complaint, as a test: "the translation sticks around even
    /// when the camera moved away."
    ///
    /// The expensive case is the one where the camera has *left* — the scene
    /// is now still, so the tap is at the reduced cadence (0.7 s), and two
    /// missed passes are 1.4 s of overlay hanging over text that is gone. The
    /// grace bounds the departure in the unit the elder sees, so the box
    /// clears on the first pass after it — one cycle plus the grace.
    func testAPublishedRegionClearsWithinOneCycleOfItsDepartureEvenAtTheReducedCadence() {
        let config = LiveTranslateConfig()
        var stabilizer = TextRegionStabilizer(config: config)
        let identity = publishedRegion(&stabilizer, box: box(0.3, 0.3))

        // One pass after the grace window closes — the grace, not the
        // pass-count rule, is what bounds a departure at the reduced cadence.
        let departed = stabilizer.consume(regions: [],
                                          at: at(0.25 + config.overlayDepartureGraceSeconds + 0.01))
        XCTAssertEqual(departed, [.disappeared(id: identity)],
                       "one cycle plus the departure grace must clear the overlay: the region "
                       + "left the publication, so nothing may still be drawn for it")
        XCTAssertTrue(stabilizer.visible.isEmpty)
    }

    /// The anti-jitter the pass-count hysteresis exists for, which the grace
    /// must not spend: one dropped frame at the nominal cadence is 0.25 s, well
    /// inside the grace, and leaves the box exactly where it was.
    func testASingleMissedPassInsideTheGraceKeepsTheBoxOnScreen() {
        let config = LiveTranslateConfig()
        var stabilizer = TextRegionStabilizer(config: config)
        let identity = publishedRegion(&stabilizer, box: box(0.3, 0.3))

        XCTAssertEqual(stabilizer.consume(regions: [], at: at(0.25 + config.overlayDepartureGraceSeconds / 2)), [],
                       "one missed pass is not a departure")
        XCTAssertEqual(stabilizer.visible.map(\.id), [identity])
    }

    /// The boundary, stated: the grace is the *oldest* a last sighting may be,
    /// so a sighting exactly one grace behind the current pass has left.
    func testTheGraceIsInclusiveAtItsBoundary() {
        let config = LiveTranslateConfig()
        var stabilizer = TextRegionStabilizer(config: config)
        let identity = publishedRegion(&stabilizer, box: box(0.3, 0.3))

        XCTAssertEqual(stabilizer.consume(regions: [], at: at(0.25 + config.overlayDepartureGraceSeconds)),
                       [.disappeared(id: identity)])
    }

    /// The clock is the *last sighting*, not the last miss: a region seen again
    /// after a missed pass starts its departure window over, so a scene that
    /// flickers a region in and out never accumulates its way to a departure.
    func testTheGraceIsMeasuredFromTheLastSightingNotFromTheFirstMiss() {
        var stabilizer = TextRegionStabilizer(config: LiveTranslateConfig())
        let sign = box(0.3, 0.3)
        let identity = publishedRegion(&stabilizer, box: sign)

        XCTAssertEqual(stabilizer.consume(regions: [], at: at(0.5)), [])
        // Seen again — the window restarts here, not at the first miss.
        XCTAssertEqual(stabilizer.consume(regions: [observation("Timer", sign)], at: at(0.75)), [])
        XCTAssertEqual(stabilizer.consume(regions: [], at: at(1.0)), [],
                       "0.25 s after the last sighting is inside the grace, however long the "
                       + "region has been tracked")
        XCTAssertEqual(stabilizer.visible.map(\.id), [identity])
    }

    /// A region the detector is still *following* is still on screen, so a
    /// tracking pass refreshes the departure clock. Without that, a region the
    /// OCR skipped while the overlay followed its box would be cleared out from
    /// under a camera that never left it.
    func testATrackedPassRefreshesTheDepartureClock() {
        var stabilizer = TextRegionStabilizer(config: LiveTranslateConfig())
        let identity = publishedRegion(&stabilizer, box: box(0.3, 0.3))

        XCTAssertEqual(stabilizer.consume(regions: [],
                                          tracked: ["Timer": box(0.32, 0.3)],
                                          at: at(0.95)), [],
                       "a followed region is seen, not missed")
        XCTAssertEqual(stabilizer.consume(regions: [], at: at(1.3)), [],
                       "0.35 s after the tracked pass is inside the grace")
        XCTAssertEqual(stabilizer.visible.map(\.id), [identity])
    }

    /// Appearance hysteresis is untouched by the grace. A region that was
    /// cleared and is then seen again keeps its identity — the grace
    /// un-publishes, it does not release — but re-enters the emitted set only
    /// after `regionAppearPasses` fresh consecutive sightings.
    func testARegionClearedByTheGraceRepaysTheAppearHysteresisBeforeItIsDrawnAgain() {
        let config = LiveTranslateConfig()
        var stabilizer = TextRegionStabilizer(config: config)
        let sign = box(0.3, 0.3)
        let identity = publishedRegion(&stabilizer, box: sign)
        let departedAt = 0.25 + config.overlayDepartureGraceSeconds + 0.01
        XCTAssertEqual(stabilizer.consume(regions: [], at: at(departedAt)),
                       [.disappeared(id: identity)])

        // First sighting after the departure: not yet painted.
        XCTAssertEqual(stabilizer.consume(regions: [observation("Timer", sign)],
                                          at: at(departedAt + 0.25)), [])
        XCTAssertTrue(stabilizer.visible.isEmpty,
                      "a region that left the publication pays the appear hysteresis again")

        // Second consecutive sighting: back, on the identity it kept.
        let returned = stabilizer.consume(regions: [observation("Timer", sign)],
                                          at: at(departedAt + 0.5))
        XCTAssertEqual(returned, [.appeared(id: identity)],
                       "the grace clears the overlay without releasing the identity")
    }

    /// Drift-following while visible is untouched: a region that is seen every
    /// pass never comes near the grace, so its box keeps tracking the sign at
    /// the reduced cadence — the sticky-geometry behaviour, not a regression.
    func testARegionThatIsSeenOnEveryPassFollowsItsBoxAtAnyCadence() {
        var stabilizer = TextRegionStabilizer(config: LiveTranslateConfig())
        let sign = box(0.3, 0.3)
        let identity = publishedRegion(&stabilizer, box: sign)

        // The scene holds still: one pass every 0.7 s, box drifting with the
        // camera, each within the match thresholds.
        for (step, y) in [0.32, 0.34, 0.36, 0.38].enumerated() {
            let moved = box(0.3, y)
            XCTAssertEqual(stabilizer.consume(regions: [observation("Timer", moved)],
                                              at: at(0.95 + Double(step) * 0.7)), [],
                           "a seen region emits nothing and is never treated as departed")
            XCTAssertEqual(stabilizer.visible.map(\.box), [moved],
                           "the overlay keeps following the box")
        }
        XCTAssertEqual(stabilizer.visible.map(\.id), [identity])
    }

    // MARK: - Block identity (scene-block rework, 2026-09-18)

    /// A region as the grouper hands it over: one surface, carrying the
    /// identity of the block it is.
    private func block(_ identity: String,
                       _ text: String,
                       _ normalizedBox: NormalizedBox,
                       confidence: Double = 0.9) -> LiveTextDetector.DetectedTextRegion {
        LiveTextDetector.DetectedTextRegion(text: text,
                                            normalizedBox: normalizedBox,
                                            detectedLanguage: nil,
                                            confidence: confidence,
                                            blockIdentity: identity)
    }

    /// A member line misread is not a new panel, and this is the case that says
    /// how far a block key reaches: exactly as far as *adding* what the plain
    /// rule would do.
    ///
    /// The two keys are not equal — the key is the member set, and one of its
    /// members came back differently — but they are not disjoint either: they
    /// share the lines that were read the same way. So this is not the
    /// unambiguous conflict that refuses a match, and the box that did not move
    /// keeps the region, exactly as it would for a region carrying no key at
    /// all.
    ///
    /// A key that refused here would re-key the panel mid-read for an OCR
    /// stumble: the elder's overlay goes blank for the grace window and the
    /// session re-asks what it has already answered.
    func testAMisreadMemberLineDoesNotRekeyThePanel() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        let appeared = stabilizer.consume(regions: [
            block("text\u{1}start\u{1}2 min", "START\n2 MIN", box(0.2, 0.3, width: 0.3, height: 0.2))
        ])
        guard case .appeared(let regionID) = appeared.first else {
            return XCTFail("expected an appeared event, got \(appeared)")
        }

        let misread = stabilizer.consume(regions: [
            block("text\u{1}start\u{1}2 m1n", "START\n2 M1N",
                  box(0.2, 0.3, width: 0.32, height: 0.2))
        ])
        XCTAssertEqual(stabilizer.visible.map(\.id), [regionID],
                       "the panel kept its identifier across the misread line: \(misread)")
        XCTAssertEqual(misread, [.textChanged(id: regionID)],
                       "…and it reports the new reading rather than keeping the stale one")
    }

    /// And the converse, which is what makes the test above mean something: a
    /// *different* block's text on that geometry is a new surface, not the old
    /// panel with new words.
    func testADifferentBlocksTextOnTheSameGeometryIsANewRegion() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        let menu = "text\u{1}cold drinks\u{1}water rs 20"
        let elsewhere = "text\u{1}play\u{1}volume"
        let appeared = stabilizer.consume(regions: [
            block(menu, "Cold Drinks\nWater Rs 20", box(0.2, 0.3, width: 0.3, height: 0.2))
        ])
        guard case .appeared(let firstID) = appeared.first else {
            return XCTFail("expected an appeared event, got \(appeared)")
        }

        _ = stabilizer.consume(regions: [
            block(elsewhere, "PLAY\nVOLUME", box(0.2, 0.3, width: 0.3, height: 0.2))
        ])
        XCTAssertEqual(stabilizer.visible.count, 1)
        XCTAssertNotEqual(stabilizer.visible.map(\.id), [firstID],
                          "a different block is a different surface, however still its box was")
    }

    /// The owner's device regression at this level (2026-09-18): the object pass
    /// changes its mind between passes, so the same lines are grouped as one
    /// panel on one pass and as their own blocks on the next.
    ///
    /// Those are two *groupings* of one surface, and a region must keep its
    /// identifier through both. When it did not — when the regrouping was read
    /// as a new surface — every pass minted new regions, the appear hysteresis
    /// was never reached again, and the overlay drew nothing over text it had
    /// just read.
    func testARegroupingOfOneSurfaceKeepsItsRegion() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        let panelIdentity = "text\u{1}prewash 40\u{1}rinse aid"
        let firstPiece = "text\u{1}prewash 40"
        let secondPiece = "text\u{1}rinse aid"
        let geometry = box(0.2, 0.3, width: 0.3, height: 0.2)

        // The text pass groups the lines separately…
        _ = stabilizer.consume(regions: [
            block(firstPiece, "PREWASH 40", geometry),
            block(secondPiece, "RINSE AID", box(0.2, 0.55, width: 0.3, height: 0.06))
        ])
        let identities = stabilizer.visible.map(\.id)
        XCTAssertEqual(identities.count, 2)

        // …the object lands and groups them into its panel…
        _ = stabilizer.consume(regions: [block(panelIdentity, "PREWASH 40\nRINSE AID", geometry)])
        XCTAssertTrue(identities.contains(stabilizer.visible[0].id),
                      "the panel is one of the pieces' own region, carried forward: "
                      + "\(stabilizer.visible.map(\.id))")

        // …and the object pass comes back empty, which is the device's own log.
        _ = stabilizer.consume(regions: [
            block(firstPiece, "PREWASH 40", geometry),
            block(secondPiece, "RINSE AID", box(0.2, 0.55, width: 0.3, height: 0.06))
        ])

        XCTAssertTrue(stabilizer.visible.contains { identities.contains($0.id) },
                      "a reappearance of the pieces is not a new surface either: the region "
                      + "that carried them is still on screen")
        XCTAssertFalse(stabilizer.visible.isEmpty,
                       "…and the overlay was never asked to draw nothing")
    }

    /// A block claim outranks a string claim: when the grouper says these lines
    /// are one surface, the region does not need its text — or its box — to
    /// have survived.
    ///
    /// The panel is drawn, the object pass then comes back empty, and the same
    /// lines arrive as the piece they are: a *regrouping*, on a box that moved
    /// with it. The piece's key is contained in the panel's, so the claim
    /// carries the match with no geometry to help it, and the panel is updated
    /// in place rather than replaced by a second region drawn over the first.
    func testABlockClaimOutranksAStringClaim() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        let panel = "text\u{1}cold drinks\u{1}water rs 20"
        let piece = "text\u{1}cold drinks"
        _ = stabilizer.consume(regions: [
            block(panel, "Cold Drinks\nWater Rs 20", box(0.1, 0.1, width: 0.4, height: 0.3))
        ])
        let identity = stabilizer.visible.map(\.id)

        // The object went away: one line of the panel is now its own block, and
        // its box is nowhere near where the panel's was.
        let regrouped = stabilizer.consume(regions: [
            block(piece, "Cold Drinks", box(0.1, 0.5, width: 0.4, height: 0.1))
        ])
        XCTAssertEqual(regrouped, [.textChanged(id: identity[0])],
                       "one surface, one translation event — though the grouping and the box both moved")
        XCTAssertEqual(stabilizer.visible.map(\.id), identity,
                       "the regrouping did not mint a second region for the same text")
    }

    /// A region that arrived without a block identity (a test fake, a plain
    /// OCR pass) is matched exactly as it always was: the field is an
    /// additional signal, never a required one.
    func testARegionWithoutABlockIdentityStillMatchesByItsString() {
        var stabilizer = TextRegionStabilizer(config: immediateConfig())
        let appeared = stabilizer.consume(regions: [observation("Wash", box(0.05, 0.05))])
        guard case .appeared(let identity) = appeared.first else {
            return XCTFail("expected an appeared event, got \(appeared)")
        }
        _ = stabilizer.consume(regions: [observation("Wash", box(0.05, 0.45, width: 0.10, height: 0.05))])
        XCTAssertEqual(stabilizer.visible.map(\.id), [identity],
                       "a nil block identity leaves the string-identity rule in charge")
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
