import CoreGraphics
import CoreMedia
import XCTest
@testable import ElderlyAssistant

/// T-026 — the join point. Every Gherkin scenario in the task file, over the
/// real components the pipeline sequences (the cache, the gate, the prompt
/// controller, the tier and its transport) with only the platform seams
/// stubbed: the frame recogniser, the backpressure flag and the publication
/// sink.
///
/// The suite is deliberately written against the pipeline's *published*
/// values: a scenario is a claim about what a consumer can observe, so the
/// assertions read the same `LiveTranslatePublication` the session model
/// renders rather than reaching into the actor's private state. The evidence
/// accessors (`inFlightAttemptCount`, `publishedSequence`, ...) exist for the
/// properties that must hold *between* publications — boundedness and
/// teardown — and are used only there.
final class LiveTranslationPipelineTests: XCTestCase {

    private let config = LiveTranslateConfig.default

    /// A string the injected curated table answers, and its translation.
    private let curatedText = "Light"
    private let curatedTranslation = "बत्ती"

    /// A string no layer can answer on device, so it reaches the cloud path.
    private let cloudText = "Members only beyond this point"

    /// A second uncurated string, for the tests that need two independent
    /// cloud questions.
    private let secondCloudText = "Push the green button"

    // MARK: - Doubles

    /// The frame tick, scripted: what one pass returns, and what was asked.
    ///
    /// Not an actor: the pipeline awaits one `recognize` at a time (the cycle
    /// flag), so there is no concurrency to protect against.
    final class ScriptedFrameRecogniser: LiveTranslateFrameRecognising {

        enum Step {
            case regions([LiveTextDetector.DetectedTextRegion])
            case failure(LiveTranslateError)
        }

        /// Consumed in order; exhausted steps fall back to `defaultStep`.
        var steps: [Step] = []
        var defaultStep: Step = .regions([])
        private(set) var beginCount = 0
        private(set) var endCount = 0
        private(set) var recognizeCount = 0

        func begin() -> Result<Void, LiveTranslateError> {
            beginCount += 1
            return .success(())
        }

        func end() { endCount += 1 }

        func recognize(_ frame: CameraFrame) async -> Result<LiveTextDetector.Pass, LiveTranslateError> {
            recognizeCount += 1
            let step = steps.isEmpty ? defaultStep : steps.removeFirst()
            switch step {
            case .regions(let regions):
                return .success(LiveTextDetector.Pass(regions: regions, trackedBoxes: [:]))
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    /// T-006's flag, watched: the transitions are the evidence that the tap
    /// stops accepting frames for exactly the Vision pass and nothing else.
    final class BackpressureSpy: LiveTranslateBackpressure {
        private(set) var transitions: [Bool] = []
        var ocrPassInFlight = false {
            didSet { transitions.append(ocrPassInFlight) }
        }
        var isSet: Bool { ocrPassInFlight }
    }

    /// The consumer side of the pipeline: a publication arrives whole or not
    /// at all, and only a counter crosses the boundary.
    actor PublicationRecorder {
        private(set) var publications: [LiveTranslatePublication] = []

        func record(_ publication: LiveTranslatePublication) {
            publications.append(publication)
        }

        var count: Int { publications.count }
        var sequences: [Int] { publications.map(\.sequence) }
        var latest: LiveTranslatePublication? { publications.last }
    }

    // MARK: - Harness

    @MainActor
    private struct Harness {
        let pipeline: LiveTranslationPipeline
        let recogniser: ScriptedFrameRecogniser
        let backpressure: BackpressureSpy
        let cache: LabelTranslationCache
        /// The cache's own channel, separate from the store the gate, the
        /// governor and the provider config share — so a fault injected into
        /// one of them is provably a fault in that one component.
        let cacheStorage: LabelTranslationCacheTestStorage
        let gate: LiveTranslateConsentGate
        let controller: ConsentPromptController
        let tier: CloudTranslationTier
        let transport: TierTranslationTransport
        let recorder: PublicationRecorder
        let governor: GeminiCostGovernor
        let bus: LiveTranslateSanitisingBus
        let configStore: GeminiConfigStore
        let config: LiveTranslateConfig
    }

    /// The production composition, with only the platform seams doubled: the
    /// real cache (over an in-memory encrypted store), the real gate, the
    /// real prompt controller, the real tier and the real client over a
    /// stubbed transport.
    @MainActor
    private func makeHarness(consent: Bool = true,
                             configured: Bool = true,
                             transport: TierTranslationTransport = TierTranslationTransport(),
                             dictionary: [String: String]? = nil,
                             recogniser: ScriptedFrameRecogniser = ScriptedFrameRecogniser(),
                             config: LiveTranslateConfig = .default) -> Harness {
        let bus = LiveTranslateSanitisingBus()
        let cacheStorage = LabelTranslationCacheTestStorage()
        let storage = LabelTranslationCacheTestStorage()
        let configStore = GeminiConfigStore(storage: storage)
        if configured { configStore.save("fake-key") }
        let gate = LiveTranslateConsentGate(storage: storage, config: config, observabilityBus: bus)
        if consent { _ = gate.record(granted: true) }
        let governor = GeminiCostGovernor(storage: storage, observabilityBus: bus)
        let cache = LabelTranslationCache(storage: cacheStorage,
                                          config: config,
                                          observabilityBus: bus,
                                          dictionary: dictionary ?? [self.curatedText.lowercased(): self.curatedTranslation])
        let indicator = CloudActivityIndicatorModel(observabilityBus: bus, config: config)
        let client = GeminiClient(configStore: configStore,
                                  observabilityBus: bus,
                                  transport: transport,
                                  costGovernor: governor)
        let tier = CloudTranslationTier(cache: cache,
                                        consentGate: gate,
                                        costGovernor: governor,
                                        client: client,
                                        config: config,
                                        observabilityBus: bus,
                                        indicator: indicator)
        let controller = ConsentPromptController(gate: gate,
                                                 config: config,
                                                 observabilityBus: bus,
                                                 locale: Locale(identifier: "ne_NP"))
        let recorder = PublicationRecorder()
        let backpressure = BackpressureSpy()
        let recogniser = recogniser
        let pipeline = LiveTranslationPipeline(locale: Locale(identifier: "ne_NP"),
                                               recogniser: recogniser,
                                               cache: cache,
                                               tier: tier,
                                               cloudNeed: controller,
                                               backpressure: backpressure,
                                               alwaysShowOriginal: false,
                                               config: config,
                                               observabilityBus: bus,
                                               publish: { publication in
                                                   await recorder.record(publication)
                                               })
        return Harness(pipeline: pipeline, recogniser: recogniser, backpressure: backpressure,
                       cache: cache, cacheStorage: cacheStorage, gate: gate, controller: controller,
                       tier: tier, transport: transport, recorder: recorder, governor: governor,
                       bus: bus, configStore: configStore, config: config)
    }

    // MARK: - Awaiting readers
    //
    // Every value that crosses an actor boundary is read into a local before
    // it is asserted on: `XCTAssert*` takes autoclosures, which cannot carry
    // an `await`, and hoisting keeps the assertion reading as the claim it
    // makes.

    private func publications(_ harness: Harness) async -> [LiveTranslatePublication] {
        await harness.recorder.publications
    }

    private func publicationCount(_ harness: Harness) async -> Int {
        await harness.recorder.count
    }

    private func latest(_ harness: Harness,
                        file: StaticString = #filePath,
                        line: UInt = #line) async throws -> LiveTranslatePublication {
        let value = await harness.recorder.latest
        return try XCTUnwrap(value, file: file, line: line)
    }

    private func publishedSequence(_ harness: Harness) async -> Int {
        await harness.pipeline.publishedSequence
    }

    private func inFlightAttempts(_ harness: Harness) async -> Int {
        await harness.pipeline.inFlightAttemptCount
    }

    private func inFlightKeys(_ harness: Harness) async -> Set<String> {
        await harness.pipeline.inFlightKeys
    }

    private func activeRegions(_ harness: Harness) async -> Int {
        await harness.pipeline.activeRegionCount
    }

    // MARK: - Fixtures

    private func makeFrame(width: Int = 640, height: Int = 480, pts: Int = 1) throws -> CameraFrame {
        let buffer = try SampleBufferFactory.make(width: width, height: height,
                                                  pts: CMTime(value: CMTimeValue(pts), timescale: 30))
        return try XCTUnwrap(CameraFrame(sampleBuffer: buffer))
    }

    private func box(_ xMin: Double, _ yMin: Double, _ xMax: Double, _ yMax: Double) -> NormalizedBox {
        NormalizedBox(xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax)
    }

    private func detected(_ text: String,
                          box: NormalizedBox = NormalizedBox(xMin: 0.2, yMin: 0.4, xMax: 0.6, yMax: 0.5),
                          language: String? = "en",
                          confidence: Double = 0.9) -> LiveTextDetector.DetectedTextRegion {
        LiveTextDetector.DetectedTextRegion(text: text, normalizedBox: box,
                                            detectedLanguage: language, confidence: confidence)
    }

    /// The session's geometry, reported before the first frame (T-027's view
    /// does this in `onAppear`).
    private var layout: LiveTranslateLayout {
        LiveTranslateLayout(containerSize: CGSize(width: 390, height: 844),
                            safeArea: CGRect(x: 0, y: 47, width: 390, height: 763),
                            occupiedRects: [CGRect(x: 0, y: 780, width: 390, height: 64)])
    }

    /// A well-formed provider envelope for a request whose items are exactly
    /// these texts, in this order.
    ///
    /// The wire ids are the request's own positions, not the strings:
    /// `CloudTranslationTier.send` hands the client
    /// `TranslationItem(id: String(index))` for each target, and the shipped
    /// parser validates every returned key against the ids it asked with
    /// (anything else is counted as an unexpected id and discarded). So a
    /// scripted reply keyed by the text — or by the cache's normalization
    /// key, which is the id the tier uses *internally* — is a reply that
    /// carries no requested id at all, and every region in that batch degrades
    /// as `cloudResponseUnusable`. Building the reply here from the batch's
    /// order keeps a scripted answer honest about the contract it stands in
    /// for; a test that needs the ids themselves uses `respondingTransport()`.
    private static func okJSON(_ texts: [String]) -> String {
        let byID = Dictionary(uniqueKeysWithValues: texts.enumerated().map { index, text in
            (String(index), "ने:" + text)
        })
        return String(data: try! JSONSerialization.data(withJSONObject: byID), encoding: .utf8)!
    }

    /// Answers every request from its own items, deterministically.
    private static func respondingTransport() -> TierTranslationTransport {
        let transport = TierTranslationTransport()
        transport.autoRespond = { byID in
            let out = byID.mapValues { "ने:" + $0 }
            return String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!
        }
        return transport
    }

    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 5,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task<Never, Never>.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    private func region(_ text: String,
                        in publication: LiveTranslatePublication) -> TextRegionStabilizer.StableTextRegion? {
        publication.regions.first { $0.text == text }
    }

    /// How many requests carried this string — counted on the decoded bodies,
    /// so "asked the cloud about it" is a fact about what was actually sent
    /// rather than a count of requests that happened to be made.
    private func requests(carrying text: String, in harness: Harness) -> Int {
        harness.transport.requests.filter { request in
            TranslationRecordingTransport.items(in: request).values.contains(text)
        }.count
    }

    /// Every visible region in a publication has an outcome, and every
    /// outcome belongs to a visible region. This is the shape of "never a
    /// blank bubble and never a silent drop": a region cannot be published
    /// without a rendered state, and an outcome cannot outlive its region.
    private func assertEveryRegionIsRendered(_ publication: LiveTranslatePublication,
                                             file: StaticString = #filePath,
                                             line: UInt = #line) {
        XCTAssertEqual(Set(publication.outcomes.keys),
                       Set(publication.regions.map(\.id)),
                       "a publication must carry exactly one outcome per visible region",
                       file: file, line: line)
        for placement in publication.placements {
            XCTAssertEqual(publication.outcomes[placement.region.id], placement.result,
                           "the drawn placement and the outcome it was measured from must be one value",
                           file: file, line: line)
        }
    }

    // MARK: - Scenario: A full cycle produces one coherent publication

    @MainActor
    func testScenarioAFullCycleProducesOneCoherentPublication() async throws {
        let harness = makeHarness()
        await harness.pipeline.updateLayout(layout)

        let frame = try makeFrame()
        harness.recogniser.defaultStep = .regions([detected(curatedText)])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        let stream = await publications(harness)
        XCTAssertFalse(stream.isEmpty, "a cycle that has visible text must publish")

        // The whole stream, not just the last value: a half-updated state
        // would have to appear here, and it cannot.
        for publication in stream {
            assertEveryRegionIsRendered(publication)
        }

        let resolved = try await latest(harness)
        XCTAssertEqual(resolved.regions.count, 1)
        XCTAssertEqual(resolved.regions.first?.text, curatedText)
        XCTAssertEqual(resolved.placements.count, 1, "one visible region, one placement")
        XCTAssertEqual(resolved.result(for: resolved.regions[0]),
                       .resolved(originalText: curatedText, translation: curatedTranslation, tier: .dictionary))
        XCTAssertTrue(resolved.hasVisibleText)

        // The publication is one value: the region, its outcome and the rect
        // it is drawn in are read together, and the counter says which one is
        // newest without any consumer comparing timestamps.
        let sequence = await publishedSequence(harness)
        XCTAssertEqual(resolved.sequence, sequence)
        let awaited1 = await publicationCount(harness)
        XCTAssertEqual(resolved.sequence, awaited1)
    }

    // MARK: - Scenario: The dictionary path needs no network at all

    @MainActor
    func testScenarioTheDictionaryPathNeedsNoNetworkAtAll() async throws {
        // No provider key and no consent record: the scene is entirely
        // curated, so neither is ever consulted (FR-LCT-020, NFR-LCT-010).
        let harness = makeHarness(consent: false, configured: false)
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(curatedText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(curatedText, in: publication))
        guard case .resolved(_, let translation, let tier) = publication.result(for: region).outcome else {
            return XCTFail("a curated scene must resolve without the cloud")
        }
        XCTAssertEqual(translation, curatedTranslation)
        XCTAssertEqual(tier, .dictionary)
        XCTAssertFalse(publication.placements.isEmpty, "the overlay shows the translation")

        XCTAssertEqual(harness.transport.requestCount, 0, "no network call may be attempted")
        XCTAssertEqual(harness.governor.callsToday, 0, "a dictionary hit spends no provider budget")
        XCTAssertFalse(harness.controller.isPromptPresented,
                       "a curated scene must never show the consent prompt")
        XCTAssertEqual(harness.gate.inFlightRegistrationCount, 0)
    }

    // MARK: - Scenario: Unresolved strings reach the cloud tier only through the gate

    @MainActor
    func testScenarioAnUnresolvedStringIsResolvedThroughTheGate() async throws {
        let harness = makeHarness(consent: true, transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        await waitUntil("the cloud attempt to land") {
            guard let latest = await harness.recorder.latest, let region = latest.regions.first else { return false }
            if case .resolved = latest.result(for: region).outcome { return true }
            return false
        }

        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(cloudText, in: publication))
        guard case .resolved(_, let translation, let tier) = publication.result(for: region).outcome else {
            return XCTFail("a consented cloud string must resolve")
        }
        XCTAssertEqual(tier, .cloud)
        XCTAssertEqual(translation, "ने:" + cloudText)
        XCTAssertEqual(harness.transport.requestCount, 1, "one question, one request")
    }

    @MainActor
    func testScenarioAStringTheDeviceCanAnswerNeverPromptsOrSends() async throws {
        // The prompt is presented at the point of *first cloud need*: a scene
        // whose strings the device can answer must not reach the gate at all.
        let harness = makeHarness(consent: false, configured: false,
                                  dictionary: [cloudText.lowercased(): "ने:curated"])
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        XCTAssertFalse(harness.controller.isPromptPresented)
        XCTAssertEqual(harness.transport.requestCount, 0)
        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(cloudText, in: publication))
        XCTAssertEqual(publication.result(for: region).text, "ने:curated")
    }

    @MainActor
    func testScenarioAnUnansweredPromptKeepsTheRegionPendingAndSendsNothing() async throws {
        let harness = makeHarness(consent: false, transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        let frame = try makeFrame()

        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        // The question is asked off the tick (the attempt is a session-scoped
        // task), so the prompt appears asynchronously — and the assertion
        // waits for the state rather than for a duration.
        await waitUntil("the prompt to be presented") { harness.controller.isPromptPresented }
        XCTAssertTrue(harness.controller.isPromptPresented, "first cloud need presents the prompt")
        XCTAssertEqual(harness.transport.requestCount, 0, "nothing is sent while the elder is deciding")
        let whilePrompted = try await latest(harness)
        let stillPending = try XCTUnwrap(region(cloudText, in: whilePrompted))
        guard case .pending = whilePrompted.result(for: stillPending).outcome else {
            return XCTFail("an unanswered prompt is not a failure: the region stays pending, never degraded")
        }

        // The answer arrives; the next tick (the retry at the OCR cadence) is
        // what carries it, and the attempt is not held behind the prompt.
        if case .failure(let error) = harness.controller.grant() {
            return XCTFail("a grant must be recorded: \(error)")
        }
        await harness.pipeline.ingest(frame)
        await waitUntil("the granted attempt to land") { harness.transport.requestCount == 1 }

        let afterAnswer = try await latest(harness)
        let answered = try XCTUnwrap(region(cloudText, in: afterAnswer))
        guard case .resolved = afterAnswer.result(for: answered).outcome else {
            return XCTFail("the answer releases the pending attempt")
        }
    }

    @MainActor
    func testScenarioALosingDecisionDegradesTheRegionWithTheHonestReason() async throws {
        // Declined before the session started: the gate denies, no request is
        // made, and the region says why it has no translation.
        let harness = makeHarness(consent: false)
        _ = harness.gate.record(granted: false)
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await waitUntil("the denial to settle") {
            guard let latest = await harness.recorder.latest, let region = latest.regions.first else { return false }
            if case .degraded = latest.result(for: region).outcome { return true }
            return false
        }

        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(cloudText, in: publication))
        XCTAssertEqual(publication.result(for: region).outcome,
                       .degraded(originalText: cloudText, reason: .consentNotGranted))
        XCTAssertEqual(publication.result(for: region).text, cloudText,
                       "a degraded region still shows what was recognized")
        XCTAssertEqual(harness.transport.requestCount, 0, "a losing decision is not a request")
        XCTAssertFalse(harness.controller.isPromptPresented,
                       "a recorded decline is not re-prompted automatically")
    }

    // MARK: - Scenario: Publication ordering is monotone and never wall-clock derived

    @MainActor
    func testScenarioPublicationOrderingIsMonotoneAndNeverWallClockDerived() async throws {
        let harness = makeHarness(transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(curatedText),
                                                   detected(cloudText, box: box(0.1, 0.1, 0.4, 0.2))])

        let frame = try makeFrame()
        for _ in 0..<6 {
            await harness.pipeline.ingest(frame)
        }
        await waitUntil("the cloud attempt to land") { harness.transport.requestCount == 1 }
        await harness.pipeline.ingest(frame)

        let sequences = await harness.recorder.sequences
        XCTAssertGreaterThan(sequences.count, 3)
        for (previous, next) in zip(sequences, sequences.dropFirst()) {
            XCTAssertLessThan(previous, next, "AM-6: the counter never regresses, not even on a repeat cycle")
        }
        XCTAssertEqual(sequences, Array(1...sequences.count),
                       "one publication, one counter step: no gaps and no rewind")

        // The ordering signal is the counter and nothing else: the published
        // value carries no time field to infer an order from, which the shape
        // of `LiveTranslatePublication` fixes at compile time.
        let counter = await publishedSequence(harness)
        XCTAssertEqual(counter, sequences.last)
    }

    // MARK: - Scenario: One terminal outcome per region per cycle

    @MainActor
    func testScenarioOneTerminalOutcomePerRegionPerCycle() async throws {
        let harness = makeHarness(transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await waitUntil("the cloud resolution to land") { harness.transport.requestCount == 1 }
        await waitUntil("the resolved outcome to be published") {
            guard let latest = await harness.recorder.latest, let region = latest.regions.first else { return false }
            if case .resolved = latest.result(for: region).outcome { return true }
            return false
        }

        let resolvedAt = await publicationCount(harness)
        let requestsWhenResolved = harness.transport.requestCount

        // The same region, unchanged, for ten more cycles.
        for _ in 0..<10 {
            await harness.pipeline.ingest(frame)
        }

        XCTAssertEqual(harness.transport.requestCount, requestsWhenResolved,
                       "a settled string is not re-sent on every tick (AM-8/CL-1)")
        let awaited2 = await inFlightKeys(harness)
        XCTAssertTrue(awaited2.isEmpty)

        let stream = await publications(harness)
        XCTAssertGreaterThan(stream.count, resolvedAt)
        for publication in stream.dropFirst(resolvedAt) {
            guard let region = region(cloudText, in: publication) else {
                return XCTFail("an unchanged region must stay visible")
            }
            guard case .resolved = publication.result(for: region).outcome else {
                return XCTFail("a resolved region never returns to pending while its text is unchanged")
            }
        }
        let awaited3 = await inFlightAttempts(harness)
        XCTAssertEqual(awaited3, 0)
    }

    // MARK: - Scenario: A camera movement is not a new question
    //
    // The owner-reported defect, end to end on the published stream: the
    // camera moves, the sign's box leaves every geometry threshold, and the
    // question the session already answered must not be asked again — nor may
    // "translating…" ever appear over a string that has a translation.

    @MainActor
    func testScenarioAPureCameraMoveReResolvesNothingAndFlashesNoPendingState() async throws {
        let harness = makeHarness(transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)
        let frame = try makeFrame()

        // The sign resolves once, at the box it was first seen in.
        harness.recogniser.defaultStep = .regions([detected(cloudText, box: box(0.2, 0.05, 0.6, 0.15))])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await waitUntil("the string to resolve") { harness.transport.requestCount == 1 }
        await waitUntil("the resolution to be published") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == self.cloudText }) else { return false }
            if case .resolved = latest.result(for: region).outcome { return true }
            return false
        }

        let requestsWhenResolved = harness.transport.requestCount
        let resolvedAt = await publicationCount(harness)
        let settled = try await latest(harness)
        let settledRegion = try XCTUnwrap(region(cloudText, in: settled))

        // The camera pans: same string, boxes 0.40 apart — disjoint, and past
        // `regionMatchCentroidDistance`, so geometry alone calls every frame a
        // brand-new sign.
        let pan: [Double] = [0.45, 0.85, 0.45, 0.05]
        harness.recogniser.steps = pan.map { y in
            .regions([detected(cloudText, box: box(0.2, y, 0.6, y + 0.1))])
        }
        for _ in pan { await harness.pipeline.ingest(frame) }
        try? await Task<Never, Never>.sleep(for: .milliseconds(60))

        // Nothing was asked, and nothing leaked between the frames that could
        // have been asked about: one question, still.
        XCTAssertEqual(harness.transport.requestCount, requestsWhenResolved,
                       "a camera movement is not a new question (no re-resolution)")
        XCTAssertEqual(requests(carrying: cloudText, in: harness), 1,
                       "the string was asked about exactly once, before the movement began")
        let awaitedInFlight = await inFlightKeys(harness)
        XCTAssertTrue(awaitedInFlight.isEmpty)

        // The identity is stable and the terminal outcome is what every
        // publication after the movement carries: at no point does the
        // consumer see the region pending over a string that is answered.
        let stream = await publications(harness)
        XCTAssertGreaterThan(stream.count, resolvedAt, "the movement is published: the box really moved")
        for publication in stream.dropFirst(resolvedAt) {
            guard let moved = region(cloudText, in: publication) else {
                return XCTFail("the region must stay visible for the whole pan")
            }
            XCTAssertEqual(moved.id, settledRegion.id,
                           "the same string keeps one identity across the movement")
            guard case .resolved = publication.result(for: moved).outcome else {
                return XCTFail("an answered string must never be republished pending "
                               + "(it would flash as translating): \(publication.result(for: moved))")
            }
            assertEveryRegionIsRendered(publication)
        }

        let afterMove = try await latest(harness)
        let movedRegion = try XCTUnwrap(region(cloudText, in: afterMove))
        XCTAssertEqual(movedRegion.box.yMin, 0.05, accuracy: 1e-9,
                       "geometry-only drift still adopts the new box")
    }

    /// The complement of the test above, so the fix is not over-broad: a
    /// string that genuinely *changes* on the same region is a new question,
    /// and it is asked.
    @MainActor
    func testScenarioAChangedStringOnTheSameRegionIsANewQuestion() async throws {
        let harness = makeHarness(transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)
        let frame = try makeFrame()

        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await waitUntil("the first string to resolve") { harness.transport.requestCount == 1 }
        let beforeChange = try await latest(harness)
        let firstRegion = try XCTUnwrap(region(cloudText, in: beforeChange))
        XCTAssertEqual(requests(carrying: cloudText, in: harness), 1)

        // The same box now reads a different string: same region, new text.
        harness.recogniser.defaultStep = .regions([detected(secondCloudText)])
        await harness.pipeline.ingest(frame)
        await waitUntil("the new string to be asked") {
            self.requests(carrying: self.secondCloudText, in: harness) == 1
        }
        await waitUntil("the new string to resolve") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == self.secondCloudText })
            else { return false }
            if case .resolved = latest.result(for: region).outcome { return true }
            return false
        }

        let afterChange = try await latest(harness)
        let changed = try XCTUnwrap(region(secondCloudText, in: afterChange))
        XCTAssertEqual(changed.id, firstRegion.id,
                       "a text change is a change on ONE identity (the box did not move)")
        guard case .resolved(_, let translation, _) = afterChange.result(for: changed).outcome else {
            return XCTFail("a changed string is a question, and it gets an answer")
        }
        XCTAssertEqual(translation, "ने:" + secondCloudText)
        XCTAssertEqual(requests(carrying: secondCloudText, in: harness), 1,
                       "a changed string is a question the session has not asked")
        XCTAssertEqual(requests(carrying: cloudText, in: harness), 1,
                       "and the previous string's one answer is not disturbed by it")
    }

    // MARK: - Scenario: A reborn region inherits the answer its string already has

    /// Two occurrences of one string, one answer. When the stabiliser releases
    /// one occurrence's identity and the same sign is picked up again, the
    /// new region inherits the settled outcome **in the cycle that publishes
    /// it** — no pending flash, and no second question.
    ///
    /// The second occurrence is what makes this observable rather than
    /// theoretical: the string stays on screen throughout, which is exactly
    /// the condition under which the settled answer is still held.
    @MainActor
    func testScenarioARebornRegionInheritsTheSettledOutcomeInTheSameCycle() async throws {
        let harness = makeHarness(transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)
        let frame = try makeFrame()

        let first = box(0.05, 0.05, 0.35, 0.15)
        let second = box(0.55, 0.70, 0.85, 0.80)

        // Both occurrences are on screen and share one question.
        harness.recogniser.defaultStep = .regions([detected(cloudText, box: first),
                                                   detected(cloudText, box: second)])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await waitUntil("the shared string to resolve") { harness.transport.requestCount == 1 }
        await waitUntil("both occurrences to be resolved") {
            guard let latest = await harness.recorder.latest, latest.regions.count == 2 else { return false }
            return latest.regions.allSatisfy {
                if case .resolved = latest.result(for: $0).outcome { return true }
                return false
            }
        }
        XCTAssertEqual(requests(carrying: cloudText, in: harness), 1,
                       "one string, one question — two occurrences do not double the cost")
        let before = try await latest(harness)
        let identitiesWhenWhole = Set(before.regions.map(\.id))
        XCTAssertEqual(identitiesWhenWhole.count, 2)

        // The first sign is out of frame long enough for its identity to be
        // released, while the second keeps the string on screen — which is
        // what leaves the settled answer held rather than pruned.
        harness.recogniser.steps = [.regions([detected(cloudText, box: second)]),
                                    .regions([detected(cloudText, box: second)])]
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        let afterRelease = try await latest(harness)
        XCTAssertEqual(afterRelease.regions.count, 1, "the first occurrence aged out")
        let awaitedBeforeReturn = await activeRegions(harness)
        XCTAssertEqual(awaitedBeforeReturn, 1)
        let publicationsBeforeReturn = await publicationCount(harness)

        // It comes back, far from where it was: the string is shown again by a
        // region that did not exist a moment ago, and the question was already
        // answered.
        harness.recogniser.steps = [.regions([detected(cloudText, box: first),
                                              detected(cloudText, box: second)]),
                                    .regions([detected(cloudText, box: first),
                                              detected(cloudText, box: second)])]
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        try? await Task<Never, Never>.sleep(for: .milliseconds(60))

        // The premise, asserted rather than assumed: a region really was born
        // (otherwise this says nothing about the born-new-region path).
        let awaitedAfterReturn = await activeRegions(harness)
        XCTAssertEqual(awaitedAfterReturn, 2, "the returned sign is a new region")
        let rebornAt = await publicationCount(harness)
        XCTAssertGreaterThan(rebornAt, publicationsBeforeReturn)

        // From the moment the new region is published it is already terminal:
        // no pending flash, and no second request.
        let stream = await publications(harness)
        for publication in stream.dropFirst(publicationsBeforeReturn) {
            for region in publication.regions {
                guard case .pending = publication.result(for: region).outcome else { continue }
                return XCTFail("a region born for an answered string was published pending "
                               + "(it would flash as translating): \(region.id)")
            }
            assertEveryRegionIsRendered(publication)
        }
        let reborn = try XCTUnwrap(stream.last)
        XCTAssertEqual(reborn.regions.count, 2)
        XCTAssertEqual(Set(reborn.regions.map(\.id)).count, 2, "two occurrences, two identities")
        XCTAssertEqual(requests(carrying: cloudText, in: harness), 1,
                       "the born-new-region path inherits the answer instead of asking again")
    }

    // MARK: - Scenario: The publish epsilon stops the shake, not the update

    @MainActor
    func testScenarioASubEpsilonWobbleIsNotPublishedAndAVisibleMoveIs() async throws {
        // A curated string, so nothing asynchronous can publish between the
        // ticks and make the deltas below a claim about the wrong cycle.
        let harness = makeHarness()
        await harness.pipeline.updateLayout(layout)
        let frame = try makeFrame()

        harness.recogniser.defaultStep = .regions([detected(curatedText, box: box(0.2, 0.4, 0.6, 0.5))])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        let epsilon = harness.config.publishBoxEpsilon
        XCTAssertEqual(epsilon, 0.02, "2% of the container dimension, as documented")
        XCTAssertEqual(harness.transport.requestCount, 0)
        let settledCount = await publicationCount(harness)
        let settledSequence = await publishedSequence(harness)
        XCTAssertEqual(settledCount, settledSequence)
        let settledSnapshot = try await latest(harness)
        let settledRegion = try XCTUnwrap(region(curatedText, in: settledSnapshot))

        // Recognition jitter: the same string, the same identity, boxes that
        // move by well under the epsilon from the published baseline.
        harness.recogniser.steps = [
            .regions([detected(curatedText, box: box(0.2 + epsilon / 2, 0.4, 0.6 + epsilon / 2, 0.5))]),
            .regions([detected(curatedText, box: box(0.2, 0.4 + epsilon / 2, 0.6, 0.5 + epsilon / 2))]),
            .regions([detected(curatedText, box: box(0.2 + epsilon / 4, 0.4, 0.6, 0.5 + epsilon / 4))]),
        ]
        for _ in harness.recogniser.steps { await harness.pipeline.ingest(frame) }

        let afterWobble = await publicationCount(harness)
        XCTAssertEqual(afterWobble, settledCount,
                       "a wobble nobody can see must not re-render the overlay")
        let sequenceAfterWobble = await publishedSequence(harness)
        XCTAssertEqual(sequenceAfterWobble, settledSequence,
                       "a suppressed cycle does not advance the ordering counter either")
        let wobbledSnapshot = try await latest(harness)
        let latestRegion = try XCTUnwrap(region(curatedText, in: wobbledSnapshot))
        XCTAssertEqual(latestRegion.id, settledRegion.id)
        XCTAssertEqual(harness.transport.requestCount, 0)

        // A movement the elder could see publishes, in full, at the new box —
        // and still asks nothing: the translation gate is keyed by text.
        harness.recogniser.steps = [
            .regions([detected(curatedText, box: box(0.2 + epsilon * 2, 0.4, 0.6 + epsilon * 2, 0.5))])
        ]
        await harness.pipeline.ingest(frame)

        let afterMove = await publicationCount(harness)
        XCTAssertEqual(afterMove, settledCount + 1,
                       "a position update above the epsilon is published")
        let movedSnapshot = try await latest(harness)
        let movedRegion = try XCTUnwrap(region(curatedText, in: movedSnapshot))
        XCTAssertEqual(movedRegion.id, settledRegion.id)
        XCTAssertEqual(movedRegion.box.xMin, 0.2 + epsilon * 2, accuracy: 1e-9)
        XCTAssertEqual(harness.transport.requestCount, 0,
                       "a position update never re-triggers translation work")
        let sequenceAfterMove = await publishedSequence(harness)
        XCTAssertEqual(sequenceAfterMove, settledSequence + 1)

        // The counter the pipeline reports and the stream the consumer saw are
        // the same run of consecutive integers: a suppression is invisible
        // from both sides or it is a bug.
        let sequences = await harness.recorder.sequences
        XCTAssertEqual(sequences, Array(1...sequences.count))
        XCTAssertEqual(sequenceAfterMove, sequences.count)
    }

    // MARK: - Scenario: Resume after an interruption recovers honestly

    @MainActor
    func testScenarioResumeAfterAnInterruptionRecoversHonestly() async throws {
        // Two strings, the states the scenario names: one already resolved
        // before the interruption, and one whose request is in flight when it
        // lands. The interrupted request answers with the transport's
        // non-retryable refusal, so the interruption is a genuine interruption
        // — nothing about it was ever answered or stored.
        let transport = TierTranslationTransport()
        transport.answers = [
            .ok(Self.okJSON([cloudText])),
            .http(400),
            .ok(Self.okJSON([secondCloudText])),
        ]

        let harness = makeHarness(transport: transport)
        await harness.pipeline.updateLayout(layout)
        let frame = try makeFrame()

        // 1. `cloudText` resolves before the interruption — and the premise is
        //    asserted, not assumed: a string that was never answered would
        //    make "recovers from the cache" a claim about nothing.
        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await waitUntil("the first string to resolve") {
            guard harness.transport.requestCount == 1 else { return false }
            return await harness.pipeline.inFlightAttemptCount == 0
        }
        XCTAssertEqual(requests(carrying: cloudText, in: harness), 1)
        let beforeInterruption = try await latest(harness)
        let resolvedBefore = try XCTUnwrap(region(cloudText, in: beforeInterruption))
        guard case .resolved(_, let firstTranslation, _) = beforeInterruption.result(for: resolvedBefore).outcome else {
            return XCTFail("the scenario's first state is a resolved string")
        }
        XCTAssertEqual(firstTranslation, "ने:" + cloudText)

        // 2. `secondCloudText` appears and its request is held open, so it is
        //    provably in flight when the interruption lands.
        let latch = TransportLatch()
        let arrival = TransportArrival()
        transport.latch = latch
        transport.arrival = arrival
        harness.recogniser.defaultStep = .regions([detected(cloudText),
                                                   detected(secondCloudText, box: box(0.1, 0.1, 0.4, 0.2))])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await arrival.wait()
        XCTAssertEqual(harness.transport.requestCount, 2)
        let awaited4 = await inFlightAttempts(harness)
        XCTAssertEqual(awaited4, 1, "one send is in flight")

        // The interruption: backgrounded, paused, then back.
        await harness.pipeline.pause()
        await harness.pipeline.resume()

        // The stabiliser restarted from empty, and the publication that
        // follows says exactly that: no claim about a frame it has not seen.
        let afterResume = try await latest(harness)
        XCTAssertTrue(afterResume.regions.isEmpty,
                      "a resumed session makes no claim about a scene it has not looked at")
        XCTAssertFalse(afterResume.hasVisibleText)

        // The held send ends — the interruption did not answer it, and an
        // unanswered question stores nothing. The pipeline released its own
        // bookkeeping for it on resume; the tier's claim is released when the
        // send ends, which is what makes the question askable again.
        await latch.open()
        await waitUntil("the interrupted send to end") { await harness.tier.inFlightKeyCount == 0 }

        // 3. The scene comes back. Both strings are new regions now.
        harness.recogniser.defaultStep = .regions([detected(cloudText),
                                                   detected(secondCloudText, box: box(0.1, 0.1, 0.4, 0.2))])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        // The interrupted string is re-attempted once, under the normal rules.
        await waitUntil("the interrupted string to be re-attempted") {
            harness.transport.requestCount == 3
        }
        XCTAssertEqual(requests(carrying: secondCloudText, in: harness), 2)

        // The re-attempt asked about the interrupted string and nothing else:
        // the answer that was already paid for is not in the batch, which is
        // the same claim the request count makes from the other side.
        let lastRequest = try XCTUnwrap(harness.transport.requests.last)
        let lastItems = TranslationRecordingTransport.items(in: lastRequest)
        XCTAssertEqual(Set(lastItems.values), [secondCloudText],
                       "the re-attempt asks only the string that was interrupted")

        // The already-resolved string is answered by the cache — the same
        // question was already paid for, and it is not asked again. Asserted
        // here, after the re-attempt's request has arrived, because that is
        // the moment a second question about it would have been asked; and it
        // is asked as a property of the *request*, not of the tier, since
        // "from the cache" and "from the cloud" are the same tier to the
        // elder (the cache's persisted origin maps to `.cloud`).
        XCTAssertEqual(requests(carrying: cloudText, in: harness), 1,
                       "a previously resolved string reappears from the cache with no new request")

        // The re-attempt lands, and the session is whole again.
        await waitUntil("the re-attempt to resolve") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == self.secondCloudText })
            else { return false }
            if case .resolved = latest.result(for: region).outcome { return true }
            return false
        }
        let recovered = try await latest(harness)
        XCTAssertEqual(recovered.regions.count, 2, "visible text re-enters resolution after a resume")
        for text in [cloudText, secondCloudText] {
            let region = try XCTUnwrap(region(text, in: recovered))
            guard case .resolved = recovered.result(for: region).outcome else {
                return XCTFail("every resumed string must end in a rendered state")
            }
        }

        // Settled again: a further cycle asks nothing.
        let requestsAfterRecovery = harness.transport.requestCount
        await harness.pipeline.ingest(frame)
        try? await Task<Never, Never>.sleep(for: .milliseconds(60))
        XCTAssertEqual(harness.transport.requestCount, requestsAfterRecovery)
    }

    @MainActor
    func testResumeReattemptsADegradedStringOnceUnderTheGate() async throws {
        // A degraded string is settled while it is degraded, and a resume is
        // the one re-attempt the design asks for: the string is asked again,
        // once, and the gate decides again (AM-1).
        //
        // A 400 is the transport's non-retryable refusal (the tier's own
        // retryability table, row 15), so one attempt is exactly one request
        // and "once" is countable.
        let transport = TierTranslationTransport()
        transport.answers = [.http(400), .http(400), .http(400)]
        let harness = makeHarness(transport: transport)
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await waitUntil("the region to degrade") {
            guard let latest = await harness.recorder.latest, let region = latest.regions.first else { return false }
            if case .degraded = latest.result(for: region).outcome { return true }
            return false
        }
        let attemptsBeforeResume = harness.transport.requestCount

        // Cycles with no change ask nothing: the degraded string is settled.
        await harness.pipeline.ingest(frame)
        XCTAssertEqual(harness.transport.requestCount, attemptsBeforeResume)

        await harness.pipeline.pause()
        await harness.pipeline.resume()
        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        await waitUntil("the single re-attempt") {
            harness.transport.requestCount > attemptsBeforeResume
        }
        try? await Task<Never, Never>.sleep(for: .milliseconds(60))
        XCTAssertEqual(harness.transport.requestCount, attemptsBeforeResume + 1,
                       "a resume re-attempts a degraded string exactly once")
    }

    // MARK: - Scenario: A component failure degrades one region, not the session

    @MainActor
    func testScenarioADetectionFailureDropsNoRegionAndStopsNothing() async throws {
        let harness = makeHarness()
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(curatedText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        let beforeFailure = try await latest(harness)
        XCTAssertEqual(beforeFailure.regions.count, 1)

        // A failed pass makes no claim about the scene: it is not evidence
        // that the text went away, so nothing is dropped or degraded.
        harness.recogniser.steps = [.failure(.ocrPassFailed(.requestFailed))]
        await harness.pipeline.ingest(frame)
        let awaited5 = await activeRegions(harness)
        XCTAssertEqual(awaited5, 1)

        // The next tick is the retry, and the session keeps working.
        harness.recogniser.steps = [.regions([detected(curatedText)])]
        await harness.pipeline.ingest(frame)

        let afterFailure = try await latest(harness)
        XCTAssertEqual(afterFailure.regions.count, 1)
        assertEveryRegionIsRendered(afterFailure)
        XCTAssertEqual(afterFailure.sequence, beforeFailure.sequence + 1,
                       "a failed pass publishes nothing: the counter does not move for it")
    }

    @MainActor
    func testScenarioACloudFailureDegradesOneRegionAndTheOtherStillResolves() async throws {
        // One curated region and one uncurated region whose request fails.
        let transport = TierTranslationTransport()
        transport.answers = [.failure(URLError(.notConnectedToInternet)),
                             .failure(URLError(.notConnectedToInternet))]
        let harness = makeHarness(transport: transport)
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(curatedText),
                                                   detected(cloudText, box: box(0.1, 0.1, 0.4, 0.2))])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await waitUntil("both regions to terminate") {
            guard let latest = await harness.recorder.latest, latest.regions.count == 2 else { return false }
            return latest.regions.allSatisfy { visible in
                if case .pending = latest.result(for: visible).outcome { return false }
                return true
            }
        }

        let publication = try await latest(harness)
        assertEveryRegionIsRendered(publication)
        let curated = try XCTUnwrap(region(curatedText, in: publication))
        let uncurated = try XCTUnwrap(region(cloudText, in: publication))
        guard case .resolved(_, _, .dictionary) = publication.result(for: curated).outcome else {
            return XCTFail("the failure of one region must not touch another")
        }
        guard case .degraded(_, let reason) = publication.result(for: uncurated).outcome else {
            return XCTFail("a failed region degrades with the original text, never a blank bubble")
        }
        XCTAssertEqual(publication.result(for: uncurated).text, cloudText,
                       "a degraded region still shows what was recognized")
        XCTAssertNotEqual(reason, .consentNotGranted, "the honest reason is the one that happened")

        // The session stays usable: the next cycle publishes again.
        let before = await publicationCount(harness)
        await harness.pipeline.ingest(frame)
        let awaited6 = await publicationCount(harness)
        XCTAssertGreaterThan(awaited6, before)
    }

    @MainActor
    func testScenarioACacheReadFailureIsAMissAndNotAnElderFacingError() async throws {
        // The cache's channel is unreadable. A read fault is not an
        // elder-facing error: the string goes on to the next tier, and the
        // region still terminates in a rendered state.
        let harness = makeHarness(transport: Self.respondingTransport())
        harness.cacheStorage.failsReads = true
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await waitUntil("the region to terminate") {
            guard let latest = await harness.recorder.latest, let region = latest.regions.first else { return false }
            if case .pending = latest.result(for: region).outcome { return false }
            return true
        }
        let publication = try await latest(harness)
        assertEveryRegionIsRendered(publication)
        XCTAssertFalse(harness.controller.isPromptPresented == true && harness.transport.requestCount == 0,
                       "a cache fault must not be mistaken for a consent question")
    }

    // MARK: - Scenario: Per-cycle work is bounded

    @MainActor
    func testScenarioPerCycleWorkIsBounded() async throws {
        let harness = makeHarness(transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)

        // A dense but legal scene: exactly the declutter cap, all uncurated,
        // so the first cycle that sees them asks the cloud one question.
        let cap = harness.config.declutterMaxRegions
        let dense = (0..<cap).map { index in
            detected("uncurated \(index)",
                     box: box(0.1, 0.05 * Double(index), 0.5, 0.05 * Double(index) + 0.04))
        }
        harness.recogniser.defaultStep = .regions(dense)

        let frame = try makeFrame()
        let cycles = 120
        for cycle in 0..<cycles {
            await harness.pipeline.ingest(frame)
            if cycle == 2 {
                await waitUntil("the batch to land") { harness.transport.requestCount >= 1 }
            }
        }
        try? await Task<Never, Never>.sleep(for: .milliseconds(80))

        // Work: one batch for the scene, and nothing queued behind it.
        XCTAssertLessThanOrEqual(harness.transport.requestCount, 1,
                                 "a settled scene is not re-asked cycle after cycle")
        let awaited7 = await inFlightAttempts(harness)
        XCTAssertEqual(awaited7, 0,
                       "no attempt outlives the cycles that made it")
        let awaited8 = await inFlightKeys(harness)
        XCTAssertTrue(awaited8.isEmpty)

        // Regions: bounded by the cap, so a dense scene cannot grow the
        // state the pipeline retains.
        let awaited9 = await activeRegions(harness)
        XCTAssertLessThanOrEqual(awaited9, cap)

        // Ticks: one publication per cycle at most, all of them counted, so
        // nothing accumulated behind the OCR pass or the cloud attempt. The
        // budget is the cycles plus the two publications that are not ticks:
        // the layout report and the one cloud resolution.
        let sequences = await harness.recorder.sequences
        XCTAssertLessThanOrEqual(sequences.count, cycles + 2)
        XCTAssertEqual(sequences, Array(1...sequences.count))
        let awaited10 = await publishedSequence(harness)
        XCTAssertEqual(awaited10, sequences.count)

        // The backpressure flag brackets the pass and nothing else: it is
        // never left set, and it never nests.
        XCTAssertFalse(harness.backpressure.isSet, "the flag is cleared when the pass ends")
        var previous = false
        for value in harness.backpressure.transitions {
            XCTAssertNotEqual(previous, value, "the pass-in-flight flag must alternate, never nest")
            previous = value
        }
        XCTAssertEqual(harness.backpressure.transitions.last, false)

        // Closing releases the one thing that was still held: the scene.
        await harness.pipeline.close()
        let awaited11 = await activeRegions(harness)
        XCTAssertEqual(awaited11, 0)
    }

    // MARK: - Scenario: The pipeline is deterministic for a fixed input sequence

    @MainActor
    func testScenarioThePipelineIsDeterministicForAFixedInputSequence() async throws {
        let first = try await runScriptedSession()
        let second = try await runScriptedSession()
        XCTAssertEqual(first, second,
                       "the same passes and the same responses must produce the same publications")
    }

    /// One scripted session, run to completion: a fixed pass sequence over
    /// the two strings, with a deterministic transport.
    @MainActor
    private func runScriptedSession() async throws -> [LiveTranslatePublication] {
        let harness = makeHarness(transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)

        let frame = try makeFrame()
        let curated = detected(curatedText)
        let uncurated = detected(cloudText, box: box(0.1, 0.1, 0.4, 0.2))
        harness.recogniser.steps = [
            .regions([curated]),
            .regions([curated, uncurated]),
            .regions([curated, uncurated]),
            .failure(.ocrPassFailed(.requestFailed)),
            .regions([curated, uncurated]),
            .regions([curated, uncurated]),
        ]
        for _ in harness.recogniser.steps {
            await harness.pipeline.ingest(frame)
        }
        try? await Task<Never, Never>.sleep(for: .milliseconds(120))
        await harness.pipeline.ingest(frame)
        return await publications(harness)
    }

    // MARK: - Scenario: Closing cancels in-flight work and tears everything down

    @MainActor
    func testScenarioClosingCancelsInFlightWorkAndTearsEverythingDown() async throws {
        let transport = TierTranslationTransport()
        let latch = TransportLatch()
        let arrival = TransportArrival()
        transport.latch = latch
        transport.arrival = arrival

        let harness = makeHarness(transport: transport)
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await arrival.wait()
        let awaited12 = await inFlightAttempts(harness)
        XCTAssertEqual(awaited12, 1, "one send is in flight")

        await harness.pipeline.close()

        // Teardown, in the order the design fixes: the flag is released, the
        // attempt tree is cancelled and recognition is ended.
        XCTAssertFalse(harness.backpressure.isSet, "close releases the frame tap")
        let awaited13 = await inFlightAttempts(harness)
        XCTAssertEqual(awaited13, 0, "the task tree is cancelled")
        XCTAssertEqual(harness.recogniser.endCount, 1, "recognition is released exactly once")

        let publicationsAtClose = await publicationCount(harness)
        let sequenceAtClose = await publishedSequence(harness)

        // The cancelled request is answered late. Nothing may observe it.
        await latch.open()
        try? await Task<Never, Never>.sleep(for: .milliseconds(120))
        let awaited14 = await publicationCount(harness)
        XCTAssertEqual(awaited14, publicationsAtClose,
                       "no publication occurs after close")
        let awaited15 = await publishedSequence(harness)
        XCTAssertEqual(awaited15, sequenceAtClose,
                       "the counter does not advance after close")

        // And no further tick does anything at all.
        await harness.pipeline.ingest(frame)
        await harness.pipeline.updateLayout(LiveTranslateLayout(containerSize: CGSize(width: 500, height: 500),
                                                               safeArea: .zero,
                                                               occupiedRects: []))
        await harness.pipeline.resume()
        try? await Task<Never, Never>.sleep(for: .milliseconds(60))
        let awaited16 = await publicationCount(harness)
        XCTAssertEqual(awaited16, publicationsAtClose)
        XCTAssertEqual(harness.recogniser.recognizeCount, 2, "a closed pipeline runs no pass")
    }

    /// The DoD bullet, named: the counter is the ordering contract and it is
    /// asserted directly, cycle by cycle, against every publication.
    @MainActor
    func testAM6TheMonotoneOrderingCounterNeverRegresses() async throws {
        let harness = makeHarness(transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(curatedText),
                                                   detected(cloudText, box: box(0.1, 0.1, 0.4, 0.2))])

        let frame = try makeFrame()
        var observed: [Int] = []
        for _ in 0..<15 {
            await harness.pipeline.ingest(frame)
            observed.append(await publishedSequence(harness))
        }
        await harness.pipeline.updateAlwaysShowOriginal(true)
        observed.append(await publishedSequence(harness))
        await harness.pipeline.updateLayout(layout)

        // Quiescent first, so the comparison below cannot race a late cloud
        // attempt's publication.
        await waitUntil("the pipeline to go quiet") { await harness.pipeline.inFlightAttemptCount == 0 }
        try? await Task<Never, Never>.sleep(for: .milliseconds(60))

        for (previous, next) in zip(observed, observed.dropFirst()) {
            XCTAssertLessThanOrEqual(previous, next)
        }

        // Nothing can publish now, so the counter and the delivered stream
        // are directly comparable — and both have to be the same run of
        // consecutive integers.
        let finalCounter = await publishedSequence(harness)
        let sequences = await harness.recorder.sequences
        XCTAssertEqual(finalCounter, sequences.count,
                       "the counter the pipeline reports is the counter the consumer last received")
        XCTAssertEqual(sequences, Array(1...sequences.count),
                       "every step of the counter is delivered: no consumer can observe a rewind or a gap")
        // The samples taken during the loop are a prefix of what was
        // delivered: the counter never ran ahead of the consumer.
        let lastObserved = try XCTUnwrap(observed.last)
        let lastDelivered = try XCTUnwrap(sequences.last)
        XCTAssertLessThanOrEqual(lastObserved, lastDelivered)
    }

    // MARK: - Integration against the real detector

    /// A clock a test can advance by handing it to a component that asks for
    /// one — the detector's cadence is time-derived, and a hand-driven test
    /// must not be at the mercy of the wall clock.
    final class AdvancingClock {
        private var value: TimeInterval = 0
        func next() -> TimeInterval {
            value += 1
            return value
        }
    }

    @MainActor
    func testIntegrationThePipelineDrivesTheRealDetectorThroughTheSeam() async throws {
        // The recogniser seam is the shipped detector itself, over a scripted
        // Vision engine: a real pass shape, the real failure taxonomy and the
        // detector's own lifecycle, end to end into a publication.
        let bus = LiveTranslateSanitisingBus()
        let cacheStorage = LabelTranslationCacheTestStorage()
        let supportStorage = LabelTranslationCacheTestStorage()
        let store = GeminiConfigStore(storage: supportStorage)
        store.save("fake-key")
        let gate = LiveTranslateConsentGate(storage: supportStorage, config: config, observabilityBus: bus)
        _ = gate.record(granted: true)
        let governor = GeminiCostGovernor(storage: supportStorage, observabilityBus: bus)
        let cache = LabelTranslationCache(storage: cacheStorage, config: config, observabilityBus: bus,
                                          dictionary: [curatedText.lowercased(): curatedTranslation])
        let engine = ScriptedRecognitionEngine()
        engine.regions = [detected(curatedText), detected(cloudText, box: box(0.1, 0.1, 0.4, 0.2))]
        // A clock that clears the OCR interval keeps every hand-delivered
        // frame an OCR pass rather than a tracking pass.
        let clock = AdvancingClock()
        let detector = LiveTextDetector(observabilityBus: bus, engine: engine, now: clock.next)
        let indicator = CloudActivityIndicatorModel(observabilityBus: bus, config: config)
        let client = GeminiClient(configStore: store, observabilityBus: bus,
                                  transport: Self.respondingTransport(), costGovernor: governor)
        let tier = CloudTranslationTier(cache: cache, consentGate: gate, costGovernor: governor,
                                        client: client, config: config, observabilityBus: bus,
                                        indicator: indicator)
        let controller = ConsentPromptController(gate: gate, config: config,
                                                 observabilityBus: bus, locale: Locale(identifier: "ne_NP"))
        let recorder = PublicationRecorder()
        let pipeline = LiveTranslationPipeline(locale: Locale(identifier: "ne_NP"),
                                               recogniser: detector,
                                               cache: cache,
                                               tier: tier,
                                               cloudNeed: controller,
                                               backpressure: nil,
                                               alwaysShowOriginal: false,
                                               config: config,
                                               observabilityBus: bus,
                                               publish: { await recorder.record($0) })
        _ = detector.begin()
        await pipeline.updateLayout(layout)

        let frame = try makeFrame()
        await pipeline.ingest(frame)
        await pipeline.ingest(frame)
        await pipeline.ingest(frame)

        let lastPublished = await recorder.latest
        let published = try XCTUnwrap(lastPublished)
        XCTAssertEqual(published.regions.count, 2, "the real detector's regions reach the publication")
        XCTAssertGreaterThanOrEqual(engine.recognizeCallCount, 3)
        let curated = try XCTUnwrap(region(curatedText, in: published))
        XCTAssertEqual(published.result(for: curated).text, curatedTranslation)

        await waitUntil("the cloud attempt to finish") {
            await pipeline.inFlightAttemptCount == 0
        }
        let attempts = await pipeline.inFlightAttemptCount
        XCTAssertEqual(attempts, 0, "the detector's pass leaves nothing behind")

        await pipeline.close()
        XCTAssertEqual(engine.forgetCallCount, 1, "close ends the detector, which forgets its rectangles")
    }
}
