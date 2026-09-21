import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import ElderlyAssistant

/// [FOCUS-CAPTURE] The focused read: one crop, read once, split, resolved by
/// the shared plan, packed.
///
/// The suite is written against the four claims the path's own header makes,
/// because each of them is a way the feature could go wrong quietly:
///
///  1. **The crop is the picture.** Everything downstream measures against the
///     crop's own pixel size, the image the elder is shown is built from the
///     crop, and the frame is never what is read or drawn.
///  2. **The splitter runs in the caller.** A crop of a paragraph reaches the
///     tiers as sentences — and, just as important, the tiers are never handed
///     a string the splitter did not produce.
///  3. **Nothing from a capture is persisted.** The persisted layers are read
///     (a curated label still answers with no network) and not written: the
///     storage double's write count is the evidence.
///  4. **The result is a value.** Image, rows and placement, packed for the
///     caller — a crop with no text on it is an honest empty answer and not a
///     failure, and a crop that makes no sense is refused rather than clamped.
final class LiveTranslateFocusCaptureTests: XCTestCase {

    // MARK: - Doubles

    /// A scripted crop pass: the strings it is told to find, and the buffers it
    /// was actually handed — so "the crop was what Vision read" is readable
    /// back rather than assumed.
    private final class StubCropRecogniser: LiveTranslateCropRecognising {
        var regions: [LiveTextDetector.DetectedTextRegion] = []
        var failure: LiveTranslateError?
        private(set) var passes = 0
        private(set) var buffers: [CVPixelBuffer] = []

        func recognizeCrop(_ pixelBuffer: CVPixelBuffer) async
            -> Result<[LiveTextDetector.DetectedTextRegion], LiveTranslateError> {
            passes += 1
            buffers.append(pixelBuffer)
            if let failure { return .failure(failure) }
            return .success(regions)
        }
    }

    /// A scripted plan: the answers it hands back for the items it is asked
    /// about, plus every ask it received, so "what the tiers were shown" is
    /// assertable. The mode is not recorded because it is no longer a
    /// parameter: `resolveFocused` fixes it inside the pipeline (review round
    /// 2, finding 7), and `LiveTranslationFocusedModeTests` is where the mode's
    /// two effects are pinned.
    private final class StubFocusedCycle: LiveTranslateFocusedCycle {
        var answers: [String: TranslationResult] = [:]
        /// The ledger a **re-pack** reads: what a later plan settled for these
        /// strings. Empty by default, which is the state a capture's own plan
        /// leaves behind.
        var settled: [String: TranslationResult] = [:]
        /// When true the plan refuses to answer at all (the pipeline's
        /// "nothing settled in time" shape).
        var refuses = false
        private(set) var asks: [(items: [CloudTranslationTier.Item],
                                 regionCounts: [String: Int])] = []
        private var sequence = 0

        var askedTexts: [String] { asks.flatMap { $0.items.map(\.text) } }

        func resolveFocused(_ items: [CloudTranslationTier.Item],
                            regionCounts: [String: Int]) async -> [String: TranslationResult]? {
            asks.append((items, regionCounts))
            guard !refuses else { return nil }
            var answered: [String: TranslationResult] = [:]
            for item in items where answers[item.id] != nil {
                answered[item.id] = answers[item.id]
            }
            return answered
        }

        func settledAnswers(for items: [CloudTranslationTier.Item])
            -> [String: TranslationResult] {
            var ledger: [String: TranslationResult] = [:]
            for item in items where settled[item.id] != nil {
                ledger[item.id] = settled[item.id]
            }
            return ledger
        }

        func nextPublicationSequence() async -> Int {
            sequence += 1
            return sequence
        }
    }

    private struct Composition {
        let path: LiveTranslateFocusCapture
        let recogniser: StubCropRecogniser
        let cycle: StubFocusedCycle
        let storage: LabelTranslationCacheTestStorage
        let bus: LiveTranslateSanitisingBus
    }

    private let config = LiveTranslateConfig.default
    private let locale = Locale(identifier: "ne-NP")

    private func makeComposition(regions: [LiveTextDetector.DetectedTextRegion] = [],
                                 dictionary: [String: String] = [:],
                                 failure: LiveTranslateError? = nil) -> Composition {
        let storage = LabelTranslationCacheTestStorage()
        let bus = LiveTranslateSanitisingBus()
        let cache = LabelTranslationCache(storage: storage,
                                          config: config,
                                          observabilityBus: bus,
                                          dictionary: dictionary)
        let recogniser = StubCropRecogniser()
        recogniser.regions = regions
        recogniser.failure = failure
        let cycle = StubFocusedCycle()
        let path = LiveTranslateFocusCapture(recogniser: recogniser,
                                             cycle: cycle,
                                             cache: cache,
                                             memoryCache: LiveTranslateMemoryCache(config: config),
                                             locale: locale)
        return Composition(path: path, recogniser: recogniser, cycle: cycle,
                           storage: storage, bus: bus)
    }

    // MARK: - Fixtures

    private let frameSize = CGSize(width: 640, height: 480)
    /// The rect the elder pointed at: a 200 × 100 pixel crop of the frame.
    private var cropRect: CGRect { CGRect(x: 120, y: 90, width: 200, height: 100) }

    private func makeFrame(width: Int = 640, height: Int = 480) -> CameraFrame {
        let buffer = PointAskTestFrames.solidPixelBuffer(width: width, height: height,
                                                         rgba: (255, 255, 255, 255))
        return CameraFrame(pixelBuffer: buffer,
                           pixelSize: CGSize(width: width, height: height),
                           timestamp: CMTime(value: 1, timescale: 30),
                           zoomFactor: 1,
                           crop: .whole)
    }

    private var layout: LiveTranslateLayout {
        LiveTranslateLayout(containerSize: CGSize(width: 390, height: 844),
                            safeArea: CGRect(x: 0, y: 47, width: 390, height: 763),
                            occupiedRects: [])
    }

    private var policy: LiveOverlayPlacement.Policy {
        LiveTranslateOverlaySurface.policy(config: config, alwaysShowOriginal: false)
    }

    private func detected(_ text: String,
                          box: NormalizedBox = NormalizedBox(xMin: 0.1, yMin: 0.2,
                                                             xMax: 0.9, yMax: 0.4),
                          language: String? = "en",
                          confidence: Double = 0.9) -> LiveTextDetector.DetectedTextRegion {
        LiveTextDetector.DetectedTextRegion(text: text, normalizedBox: box,
                                            detectedLanguage: language,
                                            confidence: confidence)
    }

    private func resolved(_ text: String, _ translation: String) -> TranslationResult {
        .resolved(originalText: text, translation: translation, tier: .cloud)
    }

    private func capture(_ composition: Composition,
                         rect: CGRect? = nil) async -> LiveTranslateFocusedCapture? {
        let frame = makeFrame()
        let result = await composition.path.capture(in: frame,
                                                    pixelRect: rect ?? cropRect,
                                                    layout: layout,
                                                    policy: policy)
        guard case .success(let capture) = result else { return nil }
        return capture
    }

    // MARK: - The crop is the picture

    func testTheCropProducedIsTheRectsOwnSizeAndNotTheFrames() async throws {
        let composition = makeComposition()
        let attempt = await capture(composition)
        let capture = try XCTUnwrap(attempt)

        XCTAssertEqual(capture.framePixelSize, cropRect.size,
                       "a focused read is the crop, so its geometry is the crop's")
        XCTAssertEqual(capture.pixelRect, cropRect)
        XCTAssertEqual(capture.image.width, Int(cropRect.width))
        XCTAssertEqual(capture.image.height, Int(cropRect.height))
        XCTAssertNotEqual(capture.framePixelSize, frameSize)
    }

    func testThePassIsHandedTheCropAndNotTheFrame() async throws {
        let composition = makeComposition()
        let attempt = await capture(composition)
        _ = try XCTUnwrap(attempt)

        let handed = try XCTUnwrap(composition.recogniser.buffers.first)
        XCTAssertEqual(CVPixelBufferGetWidth(handed), Int(cropRect.width))
        XCTAssertEqual(CVPixelBufferGetHeight(handed), Int(cropRect.height))
        XCTAssertEqual(composition.recogniser.passes, 1, "one crop is one pass")
    }

    func testARectThatWouldNotMakeACropIsRefusedRatherThanClamped() async {
        let composition = makeComposition()

        // Entirely outside the frame: the crop stage's own rule is to refuse,
        // because a clamped sliver is not the thing the elder pointed at.
        let result = await composition.path.capture(in: makeFrame(),
                                                    pixelRect: CGRect(x: 900, y: 900,
                                                                      width: 40, height: 40),
                                                    layout: layout,
                                                    policy: policy)

        guard case .failure(let error) = result else {
            return XCTFail("a rect outside the frame must not produce a capture")
        }
        XCTAssertEqual(error, .ocrUnavailable(.requestCreationFailed))
        XCTAssertEqual(composition.recogniser.passes, 0, "no pass over a rect that is not a crop")
    }

    // MARK: - Nothing to read, and a pass that failed

    func testACropWithNoTextOnItIsAnEmptyAnswerAndNotAFailure() async throws {
        let composition = makeComposition(regions: [])
        let attempt = await capture(composition)
        let capture = try XCTUnwrap(attempt)

        XCTAssertTrue(capture.isEmpty)
        XCTAssertTrue(capture.rows.isEmpty)
        XCTAssertTrue(capture.placements.isEmpty)
        XCTAssertTrue(composition.cycle.asks.isEmpty, "an empty crop asks the tiers nothing")
    }

    func testAPassThatCouldNotRunIsAFailureAndNeverAnEmptyCrop() async {
        let composition = makeComposition(regions: [detected("Light")],
                                          failure: .ocrPassFailed(.requestFailed))

        let result = await composition.path.capture(in: makeFrame(),
                                                    pixelRect: cropRect,
                                                    layout: layout,
                                                    policy: policy)

        guard case .failure(let error) = result else {
            return XCTFail("a failed pass must not read as a crop with nothing on it")
        }
        XCTAssertEqual(error, .ocrPassFailed(.requestFailed))
        XCTAssertTrue(composition.cycle.asks.isEmpty)
    }

    // MARK: - The splitter runs in the caller

    func testASentenceOfAParagraphIsItsOwnStringToTheTiers() async throws {
        let paragraph = "Shut the gate. The dog is loose."
        let composition = makeComposition(regions: [detected(paragraph)])
        composition.cycle.answers = [:]
        let attempt = await capture(composition)
        _ = try XCTUnwrap(attempt)

        let asked = composition.cycle.askedTexts
        XCTAssertEqual(asked.count, 2)
        XCTAssertFalse(asked.contains(paragraph),
                       "the whole block is a string no tier was measured on")
        XCTAssertTrue(asked.contains("Shut the gate."))
        XCTAssertTrue(asked.contains("The dog is loose."))
    }

    func testASingleStringCropReachesTheTiersWhole() async throws {
        let composition = makeComposition(regions: [detected("Light")])
        let attempt = await capture(composition)
        _ = try XCTUnwrap(attempt)

        XCTAssertEqual(composition.cycle.askedTexts, ["Light"])
    }

    func testTwoSentencesThatNormalizeTheSameAreOneAskWithBothRegionsCounted() async throws {
        // The crop shows the same sentence twice — a bilingual sign, or two
        // lines of the same directions. One ask, and the multiplicity travels
        // with it so a degradation covers both regions.
        let composition = makeComposition(regions: [detected("Shut the gate."),
                                                    detected("Shut the gate.")])
        let attempt = await capture(composition)
        _ = try XCTUnwrap(attempt)

        XCTAssertEqual(composition.cycle.asks.count, 1)
        let ask = try XCTUnwrap(composition.cycle.asks.first)
        XCTAssertEqual(ask.items.count, 1)
        XCTAssertEqual(ask.regionCounts.count, 1)
        XCTAssertEqual(ask.regionCounts.values.first, 2)
    }

    // MARK: - A surplus string is deferred, not left translating forever
    // (review round 2, finding 4)

    /// The plan is handed every pending string and answers what its budget
    /// allows; the rest are **deferred** — released for a later plan, not
    /// failed, and not "still translating" for as long as the picture is on
    /// screen.
    @MainActor
    func testASurplusStringThePlanLeavesIsDeferredRatherThanStillTranslating() async throws {
        let composition = makeComposition(regions: [detected("Light"),
                                                    detected("Members only beyond this point")])
        composition.cycle.answers = ["light|ne": resolved("Light", "बत्ती")]

        let attempt = await capture(composition)
        let capture = try XCTUnwrap(attempt)

        XCTAssertEqual(composition.cycle.asks.count, 1, "one ask carries both strings")
        XCTAssertEqual(capture.deferredKeys, ["members only beyond this point|ne"],
                       "the string the plan did not answer is deferred, by key")
        let surface = LiveTranslateOverlaySurface(placements: [], policy: policy, locale: locale)
        let awaiting = try XCTUnwrap(capture.rows.first { $0.translation == "Members only beyond this point" })
        XCTAssertEqual(awaiting.source,
                       surface.stateCopy(for: .degraded(originalText: "",
                                                        reason: .noTierResolved)),
                       "the row says the translation is not available right now, not "
                       + "'translating…' for the rest of the picture's life")
        let answered = try XCTUnwrap(capture.rows.first { $0.translation == "बत्ती" })
        XCTAssertEqual(answered.source, "Light", "the answered row is untouched")
        // The **outcome** is still pending: a deferral is a promise that the
        // next plan for this key will carry it, and a settled outcome would
        // close that door.
        let deferredRegion = try XCTUnwrap(capture.publication.regions
            .first { $0.text == "Members only beyond this point" })
        guard case .pending = capture.publication.outcomes[deferredRegion.id]?.outcome else {
            return XCTFail("a deferred row stays pending in the publication, not settled")
        }
    }

    /// The plan answered *nothing* because the question is open — the deferral
    /// marking is not for that case: those rows are waiting on the elder, and
    /// the replay will answer them.
    @MainActor
    func testAPlanThatIsHeldByAnOpenQuestionDefersNothing() async throws {
        let composition = makeComposition(regions: [detected("Light")])
        composition.cycle.refuses = true

        let attempt = await capture(composition)
        let capture = try XCTUnwrap(attempt)

        XCTAssertTrue(capture.deferredKeys.isEmpty,
                      "'the plan may apply nothing' is not 'the plan released this string'")
    }

    // MARK: - The ledger, read again (review round 2, finding 3)

    /// A later plan settles the crop's strings — the consent replay, the live
    /// tick behind it — and the standing picture re-reads the ledger and draws
    /// them: no second crop, no second pass, no second payment.
    @MainActor
    func testALaterSettlementIsDrawnOntoTheStandingCaptureAndLeavesTheLedgerAlone() async throws {
        let composition = makeComposition(regions: [detected("Members only beyond this point")])
        // The capture's own plan is held by the open question: nothing is
        // answered and nothing is deferred (`refuses` is the nil shape).
        composition.cycle.refuses = true
        let packedAttempt = await capture(composition)
        let packed = try XCTUnwrap(packedAttempt)
        let asksWhenPacked = composition.cycle.asks.count

        // The elder answers, the replay runs, and the answer lands in the
        // ledger — which is all a plan does.
        composition.cycle.answers = ["members only beyond this point|ne":
                                        resolved("Members only beyond this point", "सदस्यहरू मात्र")]
        composition.cycle.settled = composition.cycle.answers

        let updatedAttempt = await composition.path.updated(packed,
                                                            layout: layout,
                                                            policy: policy)
        let updated = try XCTUnwrap(updatedAttempt)

        XCTAssertEqual(composition.cycle.asks.count, asksWhenPacked,
                       "a re-pack is a render: no plan, no ask and no payment")
        XCTAssertEqual(updated.rows.first?.translation, "सदस्यहरू मात्र")
        XCTAssertEqual(updated.publication.regions.map(\.text),
                       packed.publication.regions.map(\.text),
                       "the same read, answered — not a second read")
        XCTAssertEqual(updated.pixelRect, packed.pixelRect)
        XCTAssertEqual(updated.image.width, packed.image.width)
        XCTAssertTrue(updated.deferredKeys.isEmpty)
        XCTAssertGreaterThan(updated.publication.sequence, packed.publication.sequence,
                             "the picture that replaces another takes the next order")

        // And with nothing new in the ledger the caller keeps the picture it
        // has: no re-place for an unchanged card.
        let unchanged = await composition.path.updated(updated, layout: layout, policy: policy)
        XCTAssertNil(unchanged)
    }

    // MARK: - The device layers, and what is never written

    func testACuratedLabelIsAnsweredOnTheDeviceWithNoAskAtAll() async throws {
        // The dictionary layer is keyed by *normalized* text (`ApplianceLabelLocalizer`'s
        // own keys are lowercase) — the same table the appliance helper renders
        // from, reached through the same key the persisted layer derives.
        let composition = makeComposition(regions: [detected("Light")],
                                          dictionary: ["light": "बत्ती"])
        let attempt = await capture(composition)
        let capture = try XCTUnwrap(attempt)

        XCTAssertTrue(composition.cycle.asks.isEmpty,
                      "the dictionary answered it; there is nothing left to ask")
        XCTAssertEqual(capture.rows.first?.translation, "बत्ती")
    }

    /// **The read is a read-only read** (review round 2, finding 8), and the
    /// seeding is what makes that a claim rather than a coincidence.
    ///
    /// Seeded through a **second session** — a second `LabelTranslationCache`
    /// over the same storage — because a same-session seed marks the key as
    /// already touched and pre-coalesces the very write this test is about: the
    /// first version of this test seeded through the cache the path holds, so
    /// it observed a write-free read whatever the policy did. With the key
    /// untouched in this session, a hit's LRU touch would rewrite the whole
    /// encrypted payload, and the assertion below is what would see it.
    @MainActor
    func testACaptureReadsTheStoredLayerWithoutWritingToIt() async throws {
        let composition = makeComposition(regions: [detected("Members only beyond this point")])
        let seedingSession = LabelTranslationCache(storage: composition.storage,
                                                   config: config,
                                                   observabilityBus: composition.bus,
                                                   dictionary: [:])
        XCTAssertTrue(seedingSession.store(text: "Members only beyond this point",
                                           translation: "सदस्यहरू मात्र").isSuccess)
        let writesBefore = composition.storage.writeCount(forKey: LabelTranslationCache.storageKey)
        XCTAssertGreaterThan(writesBefore, 0, "the seed is a write, or the rest proves nothing")

        let attempt = await capture(composition)
        let capture = try XCTUnwrap(attempt)

        XCTAssertEqual(capture.rows.first?.translation, "सदस्यहरू मात्र",
                       "the persisted layer still answers the crop — the read is kept")
        XCTAssertTrue(composition.cycle.asks.isEmpty, "and nothing is left to ask")
        XCTAssertEqual(composition.storage.writeCount(forKey: LabelTranslationCache.storageKey),
                       writesBefore,
                       "pointing at a letter must not rewrite the store — not even the "
                       + "payload a hit's LRU touch used to write")
        XCTAssertEqual(composition.storage.deleteCount, 0)
    }

    func testAnAnswerThisRunAlreadyHasIsReusedInMemoryTheSecondTime() async throws {
        let composition = makeComposition(regions: [detected("Members only beyond this point")])
        composition.cycle.answers = ["members only beyond this point|ne":
                                        resolved("Members only beyond this point", "सदस्यहरू मात्र")]

        let attempt = await capture(composition)

        _ = try XCTUnwrap(attempt)
        XCTAssertEqual(composition.cycle.asks.count, 1)

        let secondAttempt = await capture(composition)

        let second = try XCTUnwrap(secondAttempt)

        XCTAssertEqual(composition.cycle.asks.count, 1,
                       "the same tap a moment later is not a second tier call")
        XCTAssertEqual(second.rows.first?.translation, "सदस्यहरू मात्र")
    }

    func testTheRememberedAnswerIsRestatedOntoThisCropsOwnText() async throws {
        // The memory is keyed by *normalized* text, so a later crop whose
        // recognized string differs only in case is answered from the first —
        // and the answer must be re-stated onto the string this crop is
        // actually showing, or the row would render another crop's text under
        // this crop's box.
        let composition = makeComposition(regions: [detected("shut the gate")])
        composition.cycle.answers = ["shut the gate|ne": resolved("shut the gate", "गेट बन्द गर्नुहोस्")]
        let attempt = await capture(composition)
        _ = try XCTUnwrap(attempt)

        composition.recogniser.regions = [detected("SHUT THE GATE")]
        let secondAttempt = await capture(composition)
        let second = try XCTUnwrap(secondAttempt)

        XCTAssertEqual(composition.cycle.asks.count, 1,
                       "the same string in another case is the same ask")
        let row = try XCTUnwrap(second.rows.first)
        XCTAssertEqual(row.translation, "गेट बन्द गर्नुहोस्")
        XCTAssertEqual(row.source, "SHUT THE GATE",
                       "a remembered answer must be restated onto this crop's own text")
    }

    // MARK: - The packed result

    func testTheCardListsTheCropsStringsWithTheirTranslations() async throws {
        let composition = makeComposition(regions: [detected("Light")])
        composition.cycle.answers = ["light|ne": resolved("Light", "बत्ती")]

        let attempt = await capture(composition)

        let capture = try XCTUnwrap(attempt)

        XCTAssertEqual(capture.rows.count, 1)
        let row = try XCTUnwrap(capture.rows.first)
        XCTAssertEqual(row.translation, "बत्ती")
        XCTAssertEqual(row.source, "Light")
    }

    func testNothingPackedIsAnythingButTheCropInMemory() async throws {
        let composition = makeComposition(regions: [detected("Light")])
        composition.cycle.answers = ["light|ne": resolved("Light", "बत्ती")]

        let attempt = await capture(composition)

        let capture = try XCTUnwrap(attempt)

        // The capture is a value: a picture in memory, its rows and its
        // placement. There is no URL, no file and no photo library in it.
        XCTAssertGreaterThan(capture.image.width, 0)
        XCTAssertEqual(capture.rows.count, 1)
        XCTAssertEqual(capture.publication.regions.count, 1)
    }

    // MARK: - The plan refused

    func testAPlanThatSettlesNothingLeavesTheStringsUntranslatedAndKnown() async throws {
        let composition = makeComposition(regions: [detected("Light")])
        composition.cycle.refuses = true

        let attempt = await capture(composition)

        let capture = try XCTUnwrap(attempt)

        // The crop's strings are still named — an unanswered region is not a
        // region that was never read — and no row claims a translation: the
        // large line is the recognized text itself (never a translated-looking
        // string, FR-LCT-018), the state sentence is the supporting line, and
        // the row is not offered as something to hear.
        XCTAssertEqual(capture.rows.count, 1)
        let row = try XCTUnwrap(capture.rows.first)
        XCTAssertEqual(row.translation, "Light", "an untranslated row shows the text it read")
        XCTAssertEqual(row.source,
                       LiveTranslateOverlaySurface(placements: [], policy: policy, locale: locale)
                            .stateCopy(for: .pending("Light")),
                       "the small line is the honest state sentence")
        XCTAssertFalse(row.speaksTranslation, "a row with nothing to say is not a button")
        XCTAssertNotNil(row.symbolName, "a waiting region carries its state glyph")
        XCTAssertFalse(capture.isEmpty, "a region the plan could not settle is still a row")
    }

    // MARK: - The memory cache dies with the run

    func testTheRunOwnsItsMemoryCacheAndNothingSharedHoldsIt() async throws {
        let composition = makeComposition(regions: [detected("Light")])
        composition.cycle.answers = ["light|ne": resolved("Light", "बत्ती")]
        let attempt = await capture(composition)
        _ = try XCTUnwrap(attempt)

        // A second composition — a second run — starts with its own memory.
        let fresh = makeComposition(regions: [detected("Light")])
        let freshAttempt = await capture(fresh)
        _ = try XCTUnwrap(freshAttempt)

        XCTAssertEqual(fresh.cycle.asks.count, 1,
                       "an answer from another run must not be reused")
    }
}
