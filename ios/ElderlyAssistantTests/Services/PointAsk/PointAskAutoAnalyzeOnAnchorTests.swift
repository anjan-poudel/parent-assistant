import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import ElderlyAssistant

/// [AUTO-ANALYZE] `PointAskConfig.autoAnalyzeOnAnchor`: an anchor that is a
/// *question* versus an anchor that is a *target*.
///
/// The shipped flow is one-tap: the elder taps something, a box anchors, and
/// the answer's work starts with it — an elder who pointed at something wants
/// to know what it is, and a second confirming tap would be the feature asking
/// them to ask twice. That is `true`, and it is the default.
///
/// The live-translate focus capture is the one caller for which the anchor is
/// not the question: there the box is the region the elder wants *translated*,
/// and the question is asked by the control they press afterwards. Running the
/// answer's ladder on the anchor there would do a second, different answer's
/// work for a question nobody asked — and pay for it. So the flag exists, and
/// this suite pins the three things that make it a usable mode rather than a
/// dead end:
///
///  1. **Off means off**: the anchor still lands and stays `.boxAnchored`. The
///     evidence is the OCR engine's own pass count — the ladder never ran.
///  2. **The target is still named**: `anchoredTarget` returns the box and the
///     pixel rect the crop stage takes, so the caller can ask its own question
///     without re-resolving the tap.
///  3. **On is the default, and off is the same anchor**: with the shipped
///     config the very same tap proceeds to an answer, which is what says the
///     flag disables the *work* and not the anchor.
final class PointAskAutoAnalyzeOnAnchorTests: XCTestCase {

    // MARK: - Composition

    /// The suite's session model, assembled the way the app assembles it —
    /// the real consent gate, cache and client over the shipped seams, with
    /// only the recogniser scripted. The analysis classifier is the real
    /// `VisionPointAskClassifier` (the session builds it itself, by design),
    /// so nothing here depends on what a classifier makes of a flat frame.
    @MainActor
    private func makeModel(config: PointAskConfig,
                           ocrRegions: [LiveTextDetector.DetectedTextRegion] = [])
        -> (model: PointAskSessionModel, ocr: StubPointAskOCREngine) {
        let built = makeDependencies(config: config, ocrRegions: ocrRegions)
        return (PointAskSessionModel(dependencies: built.dependencies), built.ocr)
    }

    /// The composition itself, for the one test that has to hand it to a host
    /// rather than build a session from it.
    @MainActor
    private func makeDependencies(config: PointAskConfig,
                                  ocrRegions: [LiveTextDetector.DetectedTextRegion] = [])
        -> (dependencies: PointAskSessionDependencies, ocr: StubPointAskOCREngine) {
        let bus = LiveTranslateSanitisingBus()
        let gate = PointAskConsentGate(storage: LabelTranslationCacheTestStorage(),
                                       config: config,
                                       observabilityBus: bus)
        let suiteName = "pointask-auto-analyze-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = PointAskSettings(defaults: defaults, config: config)
        let cache = LabelTranslationCache(storage: LabelTranslationCacheTestStorage(),
                                          observabilityBus: bus,
                                          dictionary: [:])
        let configStore = GeminiConfigStore(storage: GeminiInMemoryStorage())
        configStore.save("fake-key")
        let client = GeminiClient(configStore: configStore,
                                  observabilityBus: bus,
                                  transport: FakeGeminiTransport())
        let ocr = StubPointAskOCREngine()
        ocr.regions = ocrRegions
        let dependencies = PointAskSessionDependencies(locale: Locale(identifier: "ne_NP"),
                                                       consentGate: gate,
                                                       settings: settings,
                                                       cache: cache,
                                                       client: client,
                                                       objectEngine: StubPointAskObjectEngine(),
                                                       ocrEngine: ocr,
                                                       observabilityBus: bus,
                                                       config: config,
                                                       speak: { _ in })
        return (dependencies: dependencies, ocr: ocr)
    }

    private let frameWidth = 640
    private let frameHeight = 480
    /// Where the finger lands: the middle of the picture.
    private let tapPoint = CGPoint(x: 0.5, y: 0.5)

    private func makeFrame() -> CameraFrame {
        CameraFrame(pixelBuffer: PointAskTestFrames.solidPixelBuffer(width: frameWidth,
                                                                     height: frameHeight,
                                                                     rgba: (255, 255, 255, 255)),
                    pixelSize: CGSize(width: frameWidth, height: frameHeight),
                    timestamp: CMTime(value: 1, timescale: 30),
                    zoomFactor: 1,
                    crop: .whole)
    }

    /// The repo's polling helper (`LiveTranslateSessionModelTests`), copied
    /// rather than shared because it is a `private` member of that class and
    /// the two suites are not in one file. The analysis is a task on the
    /// model's own stack, so a phase is waited for and never assumed.
    @MainActor
    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 5,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task<Never, Never>.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    private func detected(_ text: String) -> LiveTextDetector.DetectedTextRegion {
        LiveTextDetector.DetectedTextRegion(text: text,
                                            normalizedBox: NormalizedBox(xMin: 0.1, yMin: 0.1,
                                                                         xMax: 0.9, yMax: 0.9),
                                            detectedLanguage: nil,
                                            confidence: 1)
    }

    // MARK: - The default: the anchor is the question

    @MainActor
    func testTheAnchorStartsTheAnswerByDefault() async throws {
        // One tap here is the whole flow: `cloudEnabledDefault` is false, so
        // the answer is the local ladder's, and the recogniser's own pass
        // count is the evidence it ran.
        let composition = makeModel(config: PointAskConfig(), ocrRegions: [detected("FLORAL")])
        let model = composition.model
        model.receiveFrame(makeFrame())

        model.handleTap(atNormalizedPoint: tapPoint)

        await waitUntil("the anchored box's answer") {
            if case .answered = model.phase { return true }
            return false
        }
        XCTAssertGreaterThan(composition.ocr.passCount, 0,
                             "the anchor is the question: the ladder runs without a second tap")
        XCTAssertNotNil(model.answer)
    }

    @MainActor
    func testTheDefaultIsTrueAndNoCallerHasToAskForIt() {
        XCTAssertTrue(PointAskConfig().autoAnalyzeOnAnchor)
        XCTAssertTrue(PointAskConfig.default.autoAnalyzeOnAnchor)
        // A *default*, not the persisted state: the household has no
        // preference about it, so it is not one of the feature's keys.
        XCTAssertFalse(PointAskSettings.featureKeys
            .contains("pointask.autoAnalyzeOnAnchor"),
                       "the flag is an operational constant, not a stored preference")
    }

    // MARK: - The opt-out: the anchor is a target

    @MainActor
    func testWithAutoAnalyzeOffTheAnchorLandsAndTheLadderNeverRuns() async throws {
        let composition = makeModel(config: PointAskConfig(autoAnalyzeOnAnchor: false),
                                    ocrRegions: [detected("FLORAL")])
        let model = composition.model
        model.receiveFrame(makeFrame())

        model.handleTap(atNormalizedPoint: tapPoint)

        await waitUntil("the box to anchor") {
            if case .boxAnchored = model.phase { return true }
            return false
        }
        // The window the analysis would have used: the ladder is a task on the
        // model's own stack, so "it did not run" has to outlast a scheduler
        // turn rather than precede one.
        try? await Task.sleep(for: .milliseconds(200))

        guard case .boxAnchored = model.phase else {
            return XCTFail("the box must stay anchored: the question is the caller's, not the anchor's")
        }
        XCTAssertEqual(composition.ocr.passCount, 0, "no OCR pass for a question nobody asked")
        XCTAssertNil(model.answer, "no answer was composed")
    }

    @MainActor
    func testTheAnchoredTargetNamesTheBoxAndThePixelRectTheCallerNeeds() async throws {
        let composition = makeModel(config: PointAskConfig(autoAnalyzeOnAnchor: false))
        let model = composition.model
        model.receiveFrame(makeFrame())

        model.handleTap(atNormalizedPoint: tapPoint)

        await waitUntil("the box to anchor") {
            if case .boxAnchored = model.phase { return true }
            return false
        }
        let target = try XCTUnwrap(model.anchoredTarget,
                                   "a caller that owns the question reads the target from here")

        // The box the elder's finger is in, in the unit the overlay draws...
        XCTAssertLessThanOrEqual(target.box.xMin, tapPoint.x)
        XCTAssertGreaterThanOrEqual(target.box.xMax, tapPoint.x)
        XCTAssertLessThanOrEqual(target.box.yMin, tapPoint.y)
        XCTAssertGreaterThanOrEqual(target.box.yMax, tapPoint.y)
        XCTAssertGreaterThan(target.box.xMax - target.box.xMin, 0)
        XCTAssertGreaterThan(target.box.yMax - target.box.yMin, 0)
        // ...and the rect the crop stage takes, on the frame the camera
        // delivered. The crop is what the caller then crops and reads.
        let frameRect = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        XCTAssertTrue(frameRect.insetBy(dx: -1, dy: -1).contains(target.pixelRect),
                      "the target's rect \(target.pixelRect) must lie on the frame")
        XCTAssertGreaterThan(target.pixelRect.width, 0)
        XCTAssertGreaterThan(target.pixelRect.height, 0)
    }

    @MainActor
    func testTheTargetIsNamedInEveryPhaseThatHasOne() async throws {
        // The property reads the phase the analysis already keeps, so it names
        // the box for as long as the box exists — including after an answer,
        // when a caller may still want to act on what the elder pointed at.
        let composition = makeModel(config: PointAskConfig(), ocrRegions: [detected("FLORAL")])
        let model = composition.model
        model.receiveFrame(makeFrame())

        model.handleTap(atNormalizedPoint: tapPoint)

        await waitUntil("the anchored box's answer") {
            if case .answered = model.phase { return true }
            return false
        }
        let target = try XCTUnwrap(model.anchoredTarget,
                                   "an answered box is still the box the elder anchored")
        XCTAssertLessThanOrEqual(target.box.xMin, tapPoint.x)
        XCTAssertGreaterThanOrEqual(target.box.xMax, tapPoint.x)
        XCTAssertGreaterThan(target.pixelRect.width, 0)
    }

    @MainActor
    func testNothingIsAnchoredBeforeTheTap() {
        let composition = makeModel(config: PointAskConfig(autoAnalyzeOnAnchor: false))
        let model = composition.model
        model.receiveFrame(makeFrame())

        XCTAssertEqual(model.phase, .awaitingTap)
        XCTAssertNil(model.anchoredTarget, "there is no target until the elder names one")
    }

    // MARK: - The host: live translate's box is a target, not a question

    /// The live-translate session hands the app layer's composition to its own
    /// host seam (`LiveTranslateSessionDependencies.quietPointAsk`), and the
    /// app layer's config is on: in the standalone feature the anchor **is**
    /// the question. This host must not inherit that — an anchor that ran the
    /// ladder here would do a second, unasked answer's work and pay for it,
    /// while the focus capture is the thing that asks (findings 6, round 2).
    ///
    /// The control half is what makes the test discriminating: the very same
    /// dependencies, built into a session directly, do analyze on the same tap
    /// and the same frame — so the test fails if the flag were ignored rather
    /// than honoured, and it cannot pass by the tap anchoring nothing.
    @MainActor
    func testTheLiveTranslateHostDoesNotLetItsPointAskSessionAnalyzeAnAnchor() async throws {
        let built = makeDependencies(config: PointAskConfig(autoAnalyzeOnAnchor: true),
                                     ocrRegions: [detected("FLORAL")])

        // The control, before the host's copy exists: this composition on its
        // own is a question-answering session.
        let standalone = PointAskSessionModel(dependencies: built.dependencies)
        standalone.receiveFrame(makeFrame())
        standalone.handleTap(atNormalizedPoint: tapPoint)
        await waitUntil("the unhosted composition to start its ladder") {
            switch standalone.phase {
            case .awaitingTap, .boxAnchored: return false
            case .analyzing, .answered, .failed: return true
            }
        }

        // The host's copy, over the same dependencies: the same tap anchors,
        // and nothing asks.
        let hosted = LiveTranslateSessionDependencies.quietPointAsk(from: built.dependencies)
        hosted.receiveFrame(makeFrame())
        hosted.handleTap(atNormalizedPoint: tapPoint)
        await waitUntil("the hosted box to anchor") {
            if case .boxAnchored = hosted.phase { return true }
            return false
        }
        // The window the ladder would have used: a task on the model's own
        // stack, so "it did not run" has to outlast a scheduler turn.
        try? await Task.sleep(for: .milliseconds(200))

        guard case .boxAnchored = hosted.phase else {
            return XCTFail("the host's anchor must stay a target: the question is the focus capture's")
        }
        XCTAssertNotNil(hosted.anchoredTarget,
                        "the target is named for the caller that asks its own question")
        XCTAssertNil(hosted.answer, "no answer was composed for a question nobody asked")
    }
}
