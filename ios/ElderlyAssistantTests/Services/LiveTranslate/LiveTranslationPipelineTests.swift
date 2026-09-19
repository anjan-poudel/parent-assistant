import CoreGraphics
import CoreMedia
import Foundation
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

    /// A third, for the burst the pacing has to hold (two strings are enough
    /// to show a batch, three are enough to show a batch that was
    /// *accumulated* rather than merely grouped) and for the switch's
    /// scenario (a question asked while the switch is closed has to be one
    /// the session has never asked before, or "nothing was sent" could be
    /// the settled-set rule rather than the switch).
    private let thirdCloudText = "Beware of the dog"

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
    ///
    /// `ocrSceneStale` is recorded here too, and for the same reason: the
    /// protocol's own default is a no-op, so this spy is the only place the
    /// pipeline's staleness claim is observable. Only transitions are written
    /// by the pipeline, so the recorded list is a list of announcements.
    final class BackpressureSpy: LiveTranslateBackpressure {
        private(set) var transitions: [Bool] = []
        var ocrPassInFlight = false {
            didSet { transitions.append(ocrPassInFlight) }
        }
        var isSet: Bool { ocrPassInFlight }

        private(set) var staleAnnouncements: [Bool] = []
        var ocrSceneStale = false {
            didSet { staleAnnouncements.append(ocrSceneStale) }
        }
    }

    /// Tier 1, scripted — the on-device brain the pipeline asks before the
    /// cloud. It stands in for `LocalBrainTranslationTier` at the same seam
    /// the pipeline actually takes (`LocalBrainTranslating`), so what these
    /// tests pin is the *cascade*: which tier answers, in what order, and what
    /// reaches the gate.
    ///
    /// It emits through the shipped event API when it reports itself
    /// unavailable, exactly as the real tier does, so the pipeline-level
    /// claim "no brain, event, and on to the cloud" is made against the real
    /// vocabulary rather than against a fake's own invention.
    ///
    /// A class with a lock rather than an actor, so the harness can wire it up
    /// and the tests can read what it was asked without an `await` at every
    /// call site: the pipeline is the only writer that matters, and it awaits
    /// one attempt at a time.
    final class RecordingBrain: LocalBrainTranslating, @unchecked Sendable {

        private let lock = NSLock()
        private var storedAnswers: [String: String] = [:]
        private var storedUnavailable = false
        private var storedHangs = false
        private var storedCalls: [[String]] = []
        private var storedReleaseCount = 0
        private var events: LiveTranslateEvents?

        /// The strings this brain answers, and what it answers with.
        var answers: [String: String] {
            get { lock.lock(); defer { lock.unlock() }; return storedAnswers }
            set { lock.lock(); defer { lock.unlock() }; storedAnswers = newValue }
        }

        /// When true, every attempt reports itself unusable, the way the real
        /// tier does on a device with no model installed.
        var unavailable: Bool {
            get { lock.lock(); defer { lock.unlock() }; return storedUnavailable }
            set { lock.lock(); defer { lock.unlock() }; storedUnavailable = newValue }
        }

        /// When true, the generation never comes back on its own: it sleeps
        /// until it is cancelled. The shape of a 4B decode that is still
        /// thinking — or stuck — when the stage deadline passes.
        var hangs: Bool {
            get { lock.lock(); defer { lock.unlock() }; return storedHangs }
            set { lock.lock(); defer { lock.unlock() }; storedHangs = newValue }
        }

        /// Every batch this brain was handed, in order.
        var calls: [[String]] {
            lock.lock(); defer { lock.unlock() }; return storedCalls
        }

        var releaseCount: Int {
            lock.lock(); defer { lock.unlock() }; return storedReleaseCount
        }

        /// The harness wires this to the bus it built, so an unavailable
        /// brain is reported on the pipeline's own channel with the shipped
        /// emitter rather than a vocabulary of the fake's own.
        func attach(events: LiveTranslateEvents) {
            lock.lock(); defer { lock.unlock() }
            self.events = events
        }

        func translate(_ strings: [String]) async -> LocalBrainTranslationOutcome {
            lock.lock()
            storedCalls.append(strings)
            let answers = storedAnswers
            let unavailable = storedUnavailable
            let hangs = storedHangs
            let events = self.events
            lock.unlock()

            if hangs {
                // Cancellation-aware, like a real generation: the pipeline
                // cancels the stage when its deadline passes, so this returns
                // into nothing rather than blocking the test.
                try? await Task<Never, Never>.sleep(for: .seconds(30))
                return .none
            }

            guard !unavailable else {
                events?.brainTranslationUnavailable(.modelNotInstalled, stage: .availability)
                return .none
            }
            var translations: [String: String] = [:]
            for text in strings {
                if let answer = answers[text] { translations[text] = answer }
            }
            return LocalBrainTranslationOutcome(translations: translations, durationMs: 1)
        }

        func release() async {
            lock.lock(); defer { lock.unlock() }
            storedReleaseCount += 1
        }
    }

    /// A scripted clock.
    ///
    /// The departure grace (`overlayDepartureGraceSeconds`) is the one rule in
    /// this feature that reads a time, so the scenario that asserts it moves
    /// this rather than sleeping: the pipeline is handed `{ clock.now }`, and
    /// every pass states its own instant. Nothing here depends on how long a
    /// test takes to run, and no test waits on the wall.
    final class ScriptedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Date

        init(start: Date = Date(timeIntervalSinceReferenceDate: 0)) {
            stored = start
        }

        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return stored
        }

        func advance(by seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            stored = stored.addingTimeInterval(seconds)
        }
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

    /// The shipped config with the two dispatch-pacing intervals taken out.
    ///
    /// The pacing (`translationDispatchMinInterval`,
    /// `brainAttemptMinInterval`) is the subject of its own section below; every
    /// other scenario in this suite is about what a dispatch *contains* and in
    /// what order, and nearly all of them drive several passes back to back on
    /// a clock that has not moved — which in production is one pacing window.
    /// Leaving the shipped intervals in would make those scenarios wait on the
    /// wall clock to say what they mean, and would make each of them a claim
    /// about pacing as well as about the cascade. Zero is the documented escape
    /// hatch (both keys make every dispatch immediate at 0), exactly as
    /// `immediateConfig()` is for the stabiliser's flicker bounds.
    ///
    /// The shipped values are pinned by `LiveTranslateConfigTests`, and the
    /// section that follows this harness runs the real intervals against a
    /// scripted clock.
    static func unpacedDispatchConfig() -> LiveTranslateConfig {
        var config = LiveTranslateConfig.default
        config.translationDispatchMinInterval = 0
        config.brainAttemptMinInterval = 0
        return config
    }

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
        let brain: RecordingBrain
        let config: LiveTranslateConfig
    }

    /// [RELIABILITY-ROUTER] The network's answer, scripted. A scenario that
    /// wants the cloud to be ABLE to lead says so; everything else gets the
    /// conservative no-path answer and the order the cascade shipped with.
    final class ScriptedReachability: NetworkReachability, @unchecked Sendable {
        private let lock = NSLock()
        private var reachable: Bool

        init(reachable: Bool) {
            self.reachable = reachable
        }

        var isReachable: Bool {
            lock.lock(); defer { lock.unlock() }
            return reachable
        }

        func set(reachable: Bool) {
            lock.lock(); defer { lock.unlock() }
            self.reachable = reachable
        }
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
                             brain: RecordingBrain? = nil,
                             handsInABrain: Bool = true,
                             cacheChannel: EncryptedLocalStorage? = nil,
                             now: @escaping () -> Date = Date.init,
                             config: LiveTranslateConfig = LiveTranslationPipelineTests.unpacedDispatchConfig(),
                             /// Extract mode's initial state (owner verdict,
                             /// 2026-09-18). Defaulted so every scenario that
                             /// predates the mode keeps the translated view it
                             /// asserts about.
                             extractionMode: Bool = false,
                             /// The session's scene-digest salt. Production
                             /// draws it at random and never logs it; the
                             /// harness pins it, so a scenario can assert the
                             /// *value* the digest events carry instead of
                             /// only its shape.
                             regionDigestSalt: UInt = 0x51_7a2f_1b3c_4d5e,
                             /// The cloud tier's master switch (owner
                             /// directive, 2026-09-19), as the session model
                             /// would hand it over from the household's
                             /// settings.
                             ///
                             /// **On by default here, and deliberately so.**
                             /// The pipeline's own default is the config's —
                             /// off — but these scenarios were written about
                             /// the cascade, the consent gate and the cache,
                             /// and each of them needs the tier to be
                             /// reachable for what it asserts to be the thing
                             /// under test. A scenario about the *switch*
                             /// passes `false` and says so.
                             geminiCloudEnabled: Bool = true,
                             /// [RELIABILITY-ROUTER] The network's answer.
                             ///
                             /// **No path by default, and deliberately so.**
                             /// The pipeline's own default is the same, and
                             /// with it the router keeps the device in front
                             /// for every class — which is what these
                             /// scenarios were written against. A scenario
                             /// about the router passes a scripted answer and
                             /// says which one it means.
                             reachability: NetworkReachability = UnavailableReachability()) -> Harness {
        let bus = LiveTranslateSanitisingBus()
        // The brain is behind its own seam, so these tests never build a
        // `ModelStore` or touch a model file: the cascade is what is under
        // test here, and the tier's own suite covers inference. A caller that
        // wants to script answers builds the fake first and hands it in.
        let brain = brain ?? RecordingBrain()
        brain.attach(events: LiveTranslateEvents(bus: bus, config: config))
        // The one test of the production wiring hands in nothing at all, so
        // the pipeline builds the shipped tier over the process's own store.
        let handedInBrain: LocalBrainTranslating? = handsInABrain ? brain : nil
        // The cache's channel is injectable so a scenario can put the real
        // T-032 cipher under the live path; the default in-memory double keeps
        // the ordinary scenarios free of crypto and keeps the fault-injection
        // scenarios able to reach `failsReads` through the harness.
        let cacheDouble = LabelTranslationCacheTestStorage()
        let cacheStorage: EncryptedLocalStorage = cacheChannel ?? cacheDouble
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
                                               geminiCloudEnabled: geminiCloudEnabled,
                                               reachability: reachability,
                                               extractionMode: extractionMode,
                                               config: config,
                                               observabilityBus: bus,
                                               brain: handedInBrain,
                                               now: now,
                                               regionDigestSalt: regionDigestSalt,
                                               publish: { publication in
                                                   await recorder.record(publication)
                                               })
        return Harness(pipeline: pipeline, recogniser: recogniser, backpressure: backpressure,
                       cache: cache, cacheStorage: cacheDouble, gate: gate, controller: controller,
                       tier: tier, transport: transport, recorder: recorder, governor: governor,
                       bus: bus, configStore: configStore, brain: brain, config: config)
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

    // MARK: - Scenario: the cloud tier's master switch (owner directive, 2026-09-19)
    //
    // The directive: the cloud tier does not cascade. A household that has
    // never turned it on gets no request, no prompt and an honest degraded
    // region; a household that turns it on gets exactly the consent-gated
    // path that existed before. The first two tests below are the same scene
    // with one value changed — the switch — which is what makes the switch the
    // cause of the difference rather than a coincidence of the fixtures.

    @MainActor
    func testScenarioWithTheSwitchOffTheTierIsNeverAskedAndNeverPrompts() async throws {
        // Consent granted, provider key present, transport answering: every
        // reason a request could be made is in place except the switch.
        //
        // The prompt must not appear either. The switch is checked **before**
        // the household is asked (the owner's requirement in one line), which
        // is the whole difference between a switch that is off and a decision
        // that was declined: nobody is nagged about a tier they never turned
        // on.
        let harness = makeHarness(consent: true, configured: true,
                                  transport: Self.respondingTransport(),
                                  geminiCloudEnabled: false)
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await waitUntil("the closed switch to settle the region") {
            guard let latest = await harness.recorder.latest, let region = latest.regions.first else { return false }
            if case .degraded = latest.result(for: region).outcome { return true }
            return false
        }
        await settleTheCycle()

        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(cloudText, in: publication))
        XCTAssertEqual(publication.result(for: region).outcome,
                       .degraded(originalText: cloudText, reason: .cloudDisabled),
                       "the honest reason is its own — not consent, not the network")
        XCTAssertEqual(publication.result(for: region).text, cloudText,
                       "a degraded region still shows what was recognized")

        XCTAssertEqual(harness.transport.requestCount, 0,
                       "the switch off means no request, not a late one")
        XCTAssertEqual(requests(carrying: cloudText, in: harness), 0)
        XCTAssertFalse(harness.controller.isPromptPresented,
                       "a household that has not turned the cloud on is not prompted about it")
        XCTAssertEqual(harness.bus.events(named: "consent_prompt_shown").count, 0,
                       "no prompt event was emitted either")
        XCTAssertEqual(harness.governor.callsToday, 0, "a tier that was never asked spends nothing")
        XCTAssertEqual(harness.gate.inFlightRegistrationCount, 0,
                       "no attempt proof was minted for a tier that was never asked")
    }

    @MainActor
    func testScenarioWithTheSwitchOnTheSameSceneTakesTheConsentGatedPath() async throws {
        // The other half of the same scene: the same grant, the same provider
        // key, the same transport, the switch on. Nothing else differs from
        // the test above it.
        let harness = makeHarness(consent: true, configured: true,
                                  transport: Self.respondingTransport(),
                                  geminiCloudEnabled: true)
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await waitUntil("the consented attempt to land") {
            guard let latest = await harness.recorder.latest, let region = latest.regions.first else { return false }
            if case .resolved = latest.result(for: region).outcome { return true }
            return false
        }

        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(cloudText, in: publication))
        guard case .resolved(_, let translation, let tier) = publication.result(for: region).outcome else {
            return XCTFail("with the switch on, a consented string resolves through the cloud")
        }
        XCTAssertEqual(tier, .cloud)
        XCTAssertEqual(translation, "ने:" + cloudText)
        XCTAssertEqual(harness.transport.requestCount, 1, "one question, one request")
        XCTAssertEqual(harness.gate.inFlightRegistrationCount, 0, "the attempt was proven and released")
    }

    @MainActor
    func testScenarioTheSwitchTakesEffectInTheRunningSessionWithoutARestart() async throws {
        // The Settings leaf writes the store; the session model pushes the
        // value into the running pipeline. Both directions have to take effect
        // on the next question, with no restart and no new session.
        let harness = makeHarness(consent: true, configured: true,
                                  transport: Self.respondingTransport(),
                                  geminiCloudEnabled: false)
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await waitUntil("the first question to degrade under the closed switch") {
            guard let latest = await harness.recorder.latest, let region = latest.regions.first else { return false }
            if case .degraded = latest.result(for: region).outcome { return true }
            return false
        }
        XCTAssertEqual(harness.transport.requestCount, 0)

        // The household turns it on. The string that already degraded stays
        // settled: turning a switch on is not a reason to re-send everything,
        // and the design's re-ask is a *resume* (which the pipeline's own doc
        // states). What changes is the next question.
        await harness.pipeline.updateGeminiCloudEnabled(true)
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await settleTheCycle()
        XCTAssertEqual(harness.transport.requestCount, 0,
                       "a settled region is not re-opened by the switch alone")

        harness.recogniser.defaultStep = .regions([detected(cloudText),
                                                   detected(secondCloudText, box: box(0.1, 0.1, 0.4, 0.2))])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await waitUntil("the new question to be answered") {
            self.requests(carrying: self.secondCloudText, in: harness) == 1
        }
        let answered = try await latest(harness)
        let second = try XCTUnwrap(region(secondCloudText, in: answered))
        guard case .resolved(_, _, let tier) = answered.result(for: second).outcome else {
            return XCTFail("a question asked with the switch on must reach the gate")
        }
        XCTAssertEqual(tier, .cloud)
        XCTAssertEqual(requests(carrying: cloudText, in: harness), 0,
                       "the string that degraded while the switch was off is still not sent")

        // Off again. The next question — one this session has never asked —
        // degrades without a request, which is the switch closing rather than
        // the settled set doing the work.
        await harness.pipeline.updateGeminiCloudEnabled(false)
        harness.recogniser.defaultStep = .regions([detected(cloudText),
                                                   detected(secondCloudText, box: box(0.1, 0.1, 0.4, 0.2)),
                                                   detected(thirdCloudText, box: box(0.1, 0.6, 0.5, 0.7))])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await waitUntil("the third question to degrade") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == self.thirdCloudText }) else {
                return false
            }
            if case .degraded = latest.result(for: region).outcome { return true }
            return false
        }
        await settleTheCycle()

        let closed = try await latest(harness)
        let third = try XCTUnwrap(region(thirdCloudText, in: closed))
        XCTAssertEqual(closed.result(for: third).outcome,
                       .degraded(originalText: thirdCloudText, reason: .cloudDisabled))
        XCTAssertEqual(requests(carrying: thirdCloudText, in: harness), 0,
                       "the switch was closed again before the question was asked")
        XCTAssertEqual(requests(carrying: secondCloudText, in: harness), 1,
                       "the string answered while it was on is not re-sent")
        XCTAssertFalse(harness.controller.isPromptPresented)
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

    // MARK: - Scenario: The stabilization moves the picture, never the identities
    //
    // The owner's device log (2026-09-18) showed `ocr_pass regionCount=4` and
    // `text_change regionCount=4` on **every** pass with the count never
    // changing, and `region_removed`/`region_appeared` pairs mid-stream over a
    // scene nobody had touched: the identities were being re-keyed while the
    // reading was not. The prime hypothesis was that the frame stabilization
    // had leaked into the matching space — a correction applied to the boxes
    // between OCR and the stabiliser re-keys every region on every pass, since
    // no two passes would ever put a box where the last one did. It had not
    // leaked (the churn was one-line block keys; see
    // `TextRegionStabilizerTests`), but the contract it named is the one this
    // feature is most likely to lose next, so it is pinned here end to end:
    // recognition reads the **raw** frame, the pipeline's published boxes are
    // the raw boxes whatever the correction says, and the identities follow the
    // text rather than the window. The view-side composition is untouched and
    // stays the merged one-map rule: the *placements* follow the window, and
    // the scenarios below assert that they do, so a pipeline that ignored the
    // reported window entirely could not pass them by accident.

    /// Four one-line signs at boxes that never move, all well inside the window
    /// every stabilization offset these scenarios use leaves on screen — the
    /// composed window is `whole` inset by the margin with an offset of at most
    /// that margin, so `[0.05, 0.95]` at the extremes.
    private func oneLineSigns() -> [LiveTextDetector.DetectedTextRegion] {
        [detected("Closed", box: box(0.10, 0.10, 0.40, 0.20)),
         detected("Push", box: box(0.55, 0.10, 0.85, 0.20)),
         detected("Exit", box: box(0.10, 0.35, 0.40, 0.45)),
         detected("Mind the step", box: box(0.55, 0.35, 0.90, 0.45))]
    }

    /// The four signs as the **grouper** hands them over: each carrying the
    /// identity of the one-line block it is — `"text\u{1}<reading>"`, the exact
    /// form the device's log was produced with, and therefore a *different* key
    /// the moment the reading differs. This is the case that churned, and a fake
    /// that leaves `blockIdentity` nil cannot exercise it.
    private func grouped(_ readings: [String],
                         boxes: [NormalizedBox]) -> [LiveTextDetector.DetectedTextRegion] {
        zip(readings, boxes).map { reading, box in
            LiveTextDetector.DetectedTextRegion(text: reading,
                                                normalizedBox: box,
                                                detectedLanguage: "en",
                                                confidence: 0.9,
                                                blockIdentity: "text\u{1}" + reading)
        }
    }

    /// The four signs answered on device, so a scenario about identity has no
    /// cloud work in flight while it counts publications — the counts below are
    /// then a fact about the passes and not about when a request landed.
    private var oneLineSignTranslations: [String: String] {
        ["closed": "बन्द", "clased": "बन्द",
         "push": "धकेल्नु", "push the": "धकेल्नु",
         "exit": "निस्कने", "exil": "निस्कने",
         "mind the step": "सिँढी ध्यान", "mind the stops": "सिँढी ध्यान"]
    }

    /// The layout the view reports while the picture is being held still: its
    /// window is the frame's own, composed with the correction. This is the
    /// one-map rule from the view's side, and it is the *only* place the
    /// correction becomes geometry.
    private func layout(pushedThrough stabilization: FrameStabilization) -> LiveTranslateLayout {
        var layout = self.layout
        layout.crop = LiveCameraCrop.whole.stabilized(by: stabilization)
        return layout
    }

    /// The oscillation these scenarios drive: a correction that never settles,
    /// panning the picture left and right by more than the follow dead zone on
    /// every pass, with the window composed from it exactly as the view does.
    private func oscillatingStabilization(pass: Int, margin: Double) -> FrameStabilization {
        FrameStabilization(offset: pass.isMultiple(of: 2)
                                ? CGPoint(x: 0.02, y: -0.01)
                                : CGPoint(x: -0.02, y: 0.01),
                           margin: margin)
    }

    @MainActor
    func testScenarioAnOscillatingStabilizationNeverReKeysTheScene() async throws {
        let harness = makeHarness(dictionary: oneLineSignTranslations,
                                  regionDigestSalt: 0x51_7a2f_1b3c_4d5e)
        var frame = try makeFrame()
        harness.recogniser.defaultStep = .regions(oneLineSigns())

        // Two warm-up passes at the identity window: the signs reach the
        // stabiliser's appearance hysteresis and are published once.
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        let settled = try await latest(harness)
        XCTAssertEqual(settled.regions.count, 4, "the four signs are on screen")

        // Ten passes of a correction that never settles. The scene does not
        // change at all: same four signs, same readings, same boxes.
        var identities = Set(settled.regions.map(\.id))
        var boxesPerPass: [Set<[Double]>] = [boxes(settled.regions.map(\.box))]
        var formsPerPass: [[LiveOverlayPlacement.Form]] = []
        for pass in 0..<10 {
            let stabilization = oscillatingStabilization(pass: pass,
                                                          margin: harness.config.frameStabMargin)
            // The view reports the composed window (it moved), and the frame
            // carries the correction to it (it moved too). Neither is an input
            // to what a region *is*.
            await harness.pipeline.updateLayout(layout(pushedThrough: stabilization))
            frame.stabilization = stabilization
            await harness.pipeline.ingest(frame)

            let published = try await latest(harness)
            XCTAssertEqual(published.regions.count, 4,
                           "pass \(pass): the four signs stay on screen")
            identities.formUnion(published.regions.map(\.id))
            boxesPerPass.append(boxes(published.regions.map(\.box)))
            formsPerPass.append(published.placements.map(\.form))
            assertEveryRegionIsRendered(published)
        }

        // One identity per sign and not one more: ten passes, four identities.
        XCTAssertEqual(identities.count, 4,
                       "the correction re-keyed a region: the window moved and the boxes did not")
        // The published boxes are the raw ones — the scripted boxes, unchanged
        // by the correction that was panning the picture the whole time — and
        // they are the same boxes on every pass, so the text the elder is
        // reading never jumps with the window.
        let rawBoxes = boxes(oneLineSigns().map(\.normalizedBox))
        for (pass, passBoxes) in boxesPerPass.enumerated() {
            XCTAssertEqual(passBoxes, rawBoxes,
                           "pass \(pass): a published box moved with the stabilization")
        }
        // The picture *is* being panned: the placements follow the composed
        // window, or the one-map rule has been lost and this test proves nothing.
        XCTAssertNotEqual(formsPerPass[0], formsPerPass[1],
                          "the placements must follow the window the view reported")

        // The churn events, which is what the owner read off the console: one
        // appearance per sign, no departure, and one change event for a scene
        // whose reading never changed.
        XCTAssertEqual(harness.bus.events(named: "region_appeared").count, 4,
                       "each sign appears once and is never re-keyed")
        XCTAssertEqual(harness.bus.events(named: "region_removed").count, 0,
                       "nothing left the screen, so nothing may be reported as gone")
        XCTAssertEqual(harness.bus.events(named: "text_change").count, 1,
                       "twelve passes, one reading: the change event must not fire per pass")
    }

    /// The boxes of a set of regions as a comparable value. `NormalizedBox` is
    /// not `Hashable`, and the point here is a set comparison — a re-keyed
    /// region would arrive as a different box under the same text.
    private func boxes(_ boxes: [NormalizedBox]) -> Set<[Double]> {
        Set(boxes.map { [$0.xMin, $0.yMin, $0.xMax, $0.yMax] })
    }

    /// The owner's own defect shape, end to end on the published stream: a scene
    /// of one-line signs whose readings wobble the way OCR wobbles, over a
    /// picture the correction is panning at the same time. The reading really
    /// does change — that is a change event, and the digest below is what says
    /// *which* — and the identity must not. The `region_removed` /
    /// `region_appeared` pairs are what the owner read off the console, and a
    /// scene that stood still must not produce them.
    @MainActor
    func testScenarioAOneLineWobbleOverAFollowedPictureKeepsEveryIdentity() async throws {
        let harness = makeHarness(dictionary: oneLineSignTranslations)
        var frame = try makeFrame()

        // The same four signs, a plausible misread each — same boxes, one line.
        let boxes = oneLineSigns().map(\.normalizedBox)
        let steady = grouped(["Closed", "Push", "Exit", "Mind the step"], boxes: boxes)
        let wobbly = grouped(["Clased", "Push the", "Exil", "Mind the stops"], boxes: boxes)

        var identities: Set<TextRegionStabilizer.RegionIdentity> = []
        for pass in 0..<10 {
            // Each reading stands for two consecutive passes. The wobble is the
            // same wobble the device produced; what changed is that a reading
            // the OCR holds for one pass only no longer counts as the sign's
            // reading at all (see `readingConsensusPasses`), so a scripted
            // one-pass alternation would now pin the *absence* of change rather
            // than the presence of it. Two passes is the shipped persistence
            // rule, and the claim this scenario makes — a reading that really
            // did change is a change, and the identity is untouched by it —
            // needs the reading to really change.
            harness.recogniser.defaultStep = .regions((pass / 2).isMultiple(of: 2) ? steady : wobbly)
            let stabilization = oscillatingStabilization(pass: pass,
                                                          margin: harness.config.frameStabMargin)
            await harness.pipeline.updateLayout(layout(pushedThrough: stabilization))
            frame.stabilization = stabilization
            await harness.pipeline.ingest(frame)

            let published = try await latest(harness)
            // The first pass only tracks: a region is published once it has
            // been seen twice (the appearance hysteresis).
            if pass > 0 {
                XCTAssertEqual(published.regions.count, 4, "pass \(pass): four signs, one per box")
            }
            identities.formUnion(published.regions.map(\.id))
            assertEveryRegionIsRendered(published)
        }

        // Four identities for ten passes of changing readings: the identity
        // followed the *text's* answer and never the wobble.
        XCTAssertEqual(identities.count, 4,
                       "a wobbling one-line reading re-keyed its region — the device defect")
        XCTAssertEqual(harness.bus.events(named: "region_appeared").count, 4,
                       "each sign appears once; an appear/remove pair is the churn")
        XCTAssertEqual(harness.bus.events(named: "region_removed").count, 0)
        XCTAssertGreaterThan(harness.bus.events(named: "text_change").count, 1,
                             "the reading really did change, and text_change is the event for it")
    }

    // MARK: - Scenario: the reading consensus (owner device report, 2026-09-19)

    /// The owner's acceptance instrument, end to end: **on a scene whose
    /// readings flicker but whose regions do not, `regionSetHash` is a
    /// constant.**
    ///
    /// The device log this work answers shows the opposite — `regionCount`
    /// standing still and `regionSetHash` moving on every pass — and the digest
    /// is the number the next device capture is read against. It is a constant
    /// here for exactly the reason the screen is still: the reading the set is
    /// folded from is the consensus one, so a pass that reads the sign
    /// differently is a pass that changed nothing the elder can see.
    ///
    /// The single `text_change` is the publish pass, which is a real change —
    /// four regions arriving where there were none. Everything after it is the
    /// wobble, and the wobble logs nothing.
    @MainActor
    func testScenarioAFlickeringReadingLeavesTheSceneDigestConstant() async throws {
        let salt: UInt = 0x51_7a2f_1b3c_4d5e
        let harness = makeHarness(dictionary: oneLineSignTranslations, regionDigestSalt: salt)
        await harness.pipeline.updateLayout(layout)
        let frame = try makeFrame()

        let boxes = oneLineSigns().map(\.normalizedBox)
        let readings = ["Closed", "Push", "Exit", "Mind the step"]
        let steady = grouped(readings, boxes: boxes)
        let wobbly = grouped(["Clased", "Push the", "Exil", "Mind the stops"], boxes: boxes)

        for pass in 0..<12 {
            harness.recogniser.defaultStep = .regions(pass.isMultiple(of: 2) ? steady : wobbly)
            await harness.pipeline.ingest(frame)
        }

        // The screen: four regions, one identity each, the readings it was
        // first given — none of them the wobble.
        let published = try await latest(harness)
        XCTAssertEqual(published.regions.count, 4)
        XCTAssertEqual(published.regions.map(\.text).sorted(), readings.sorted(),
                       "a reading that never persisted reached the overlay")

        // The instrument: one change event for the whole scene (the publish),
        // and one digest value, which is the digest of the readings on screen.
        let digestEvents = harness.bus.events(named: "text_change")
        XCTAssertEqual(digestEvents.count, 1,
                       "the flicker reached the change gate on \(digestEvents.count - 1) pass(es) "
                       + "beyond the publish — that is the hash the owner watched move")
        let logged = try XCTUnwrap(digestEvents.first?.metadata["regionSetHash"])
        XCTAssertEqual(logged, LiveTranslateEvents.regionSetHashHex(
            LiveTranslateRegionSetDigest.digest(
                of: readings.map { LiveTranslateTextNormalization.normalized($0) }, salt: salt)),
                       "the digest is over the consensus reading, which is what is on screen")

        // The identity half of the device defect stays fixed too, in the same
        // run: the rework before this one is not allowed to regress behind it.
        XCTAssertEqual(harness.bus.events(named: "region_appeared").count, 4)
        XCTAssertEqual(harness.bus.events(named: "region_removed").count, 0)
    }

    /// The translation half of the same claim: **a flickering variant is never
    /// a new question.**
    ///
    /// The change-only gate is keyed by the region's text, so a reading that
    /// wobbles per pass used to ask the tiers about each variant in turn —
    /// one cloud question per pass for a sign nobody had moved. With the
    /// reading held, the variant is never the region's key, so it is never
    /// sent: one question for the sign, whatever the OCR did behind it.
    @MainActor
    func testScenarioAFlickeringReadingIsNeverANewTranslationQuestion() async throws {
        // The harness's dictionary answers the curated fixture string only, so
        // both strings below are uncurated and the one that *is* asked goes all
        // the way to the transport: the count below is a fact about what was
        // actually sent.
        let harness = makeHarness(transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)
        let frame = try makeFrame()

        let sign = box(0.20, 0.40, 0.60, 0.50)
        let steady = grouped([cloudText], boxes: [sign])
        let flicker = grouped([secondCloudText], boxes: [sign])

        for pass in 0..<8 {
            harness.recogniser.defaultStep = .regions(pass.isMultiple(of: 2) ? steady : flicker)
            await harness.pipeline.ingest(frame)
        }
        await waitUntil("the sign's one question to be asked") {
            self.requests(carrying: self.cloudText, in: harness) == 1
        }

        let published = try await latest(harness)
        XCTAssertEqual(published.regions.map(\.id).count, 1, "one sign, one region")
        XCTAssertEqual(published.regions.map(\.text), [cloudText],
                       "the variant is not the region's reading, so it is not the region's text")
        XCTAssertEqual(requests(carrying: secondCloudText, in: harness), 0,
                       "a one-pass variant was sent to be translated — every flicker would be "
                       + "another question, which is the traffic the gate exists to stop")
        XCTAssertEqual(requests(carrying: cloudText, in: harness), 1,
                       "the reading on screen is asked once")
    }

    /// The same scene and the same ten passes, run with and without a
    /// correction on the frames, for the comparison below.
    @MainActor
    private func runStaticScene(withCorrection: Bool) async throws
        -> (count: Int, sequence: Int, stream: [LiveTranslatePublication]) {
        let harness = makeHarness(dictionary: oneLineSignTranslations)
        await harness.pipeline.updateLayout(layout)
        var frame = try makeFrame()
        harness.recogniser.defaultStep = .regions(oneLineSigns())
        for pass in 0..<10 {
            if withCorrection {
                frame.stabilization = oscillatingStabilization(
                    pass: pass, margin: harness.config.frameStabMargin)
            }
            await harness.pipeline.ingest(frame)
        }
        return (await publicationCount(harness),
                await publishedSequence(harness),
                await publications(harness))
    }

    /// The same oscillation with the window held still proves the *other* half:
    /// the stabilization is not an input to the publication sequence either.
    /// Two harnesses, one script, one difference (`frame.stabilization`), and
    /// the counters must not be able to tell them apart.
    @MainActor
    func testScenarioACorrectionTheViewNeverReportsChangesNoPublication() async throws {
        let plain = try await runStaticScene(withCorrection: false)
        let corrected = try await runStaticScene(withCorrection: true)

        XCTAssertEqual(corrected.count, plain.count,
                       "a correction the view has not composed into the layout is not news")
        XCTAssertEqual(corrected.sequence, plain.sequence)
        XCTAssertEqual(corrected.stream, plain.stream,
                       "the frame's correction must not reach the published value at all")
    }

    // MARK: - Scenario: The scene digest is the elder's screen and nothing else

    /// The diagnostic the owner's next device capture reads. It has to answer
    /// exactly one question — *did the reading change, or did the identity?* —
    /// and it has to be able to answer it without carrying a character of the
    /// scene. So: the same reading twice is the same value, a changed reading
    /// is a different one, and the value is a 32-bit digest of the visible
    /// **normalized** strings under a salt that is drawn per session and never
    /// logged.
    @MainActor
    func testScenarioTheSceneDigestFollowsTheReadingAndNothingElse() async throws {
        let salt: UInt = 0x51_7a2f_1b3c_4d5e
        let harness = makeHarness(dictionary: oneLineSignTranslations, regionDigestSalt: salt)
        await harness.pipeline.updateLayout(layout)
        var frame = try makeFrame()

        let signs = oneLineSigns()
        harness.recogniser.defaultStep = .regions(signs)
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        // One change event for one reading, whatever the window was doing, and
        // its value is exactly the digest of the normalized strings on screen.
        let first = harness.bus.events(named: "text_change")
        XCTAssertEqual(first.count, 1)
        let logged = try XCTUnwrap(first.first?.metadata["regionSetHash"])
        let expected = LiveTranslateRegionSetDigest.digest(
            of: signs.map { LiveTranslateTextNormalization.normalized($0.text) }, salt: salt)
        XCTAssertEqual(logged, LiveTranslateEvents.regionSetHashHex(expected),
                       "the digest is taken over the normalized visible set")

        // The same set in another order is the same set: the digest is over the
        // scene, not over the order a pass happened to see it in.
        XCTAssertEqual(LiveTranslateRegionSetDigest.digest(
            of: signs.reversed().map { LiveTranslateTextNormalization.normalized($0.text) }, salt: salt),
                       expected)
        // The same call twice is the same value — the owner compares two lines
        // of one log, so "stable within a session" has to be exact — and a
        // different session's salt is a different one, which is what makes the
        // value unguessable from the scene rather than a lookup table for it.
        XCTAssertEqual(LiveTranslateRegionSetDigest.digest(
            of: signs.map { LiveTranslateTextNormalization.normalized($0.text) }, salt: salt), expected)
        XCTAssertNotEqual(LiveTranslateRegionSetDigest.digest(
            of: signs.map { LiveTranslateTextNormalization.normalized($0.text) }, salt: salt &+ 1), expected)
        // The set's own boundary is part of the input, so two different readings
        // cannot collide through their concatenation.
        XCTAssertNotEqual(LiveTranslateRegionSetDigest.digest(of: ["ab", "c"], salt: salt),
                          LiveTranslateRegionSetDigest.digest(of: ["a", "bc"], salt: salt))
        // A different reading — one sign re-read — is a different value, and it
        // still says nothing about what changed.
        let changed = LiveTranslateRegionSetDigest.digest(
            of: signs.dropLast().map { LiveTranslateTextNormalization.normalized($0.text) } + ["Mind the gap"],
            salt: salt)
        XCTAssertNotEqual(changed, expected)

        // What reaches the log has no source string in it — not one of them, and
        // not a run of one: the value is nine characters of hex and a colon.
        for text in signs.map(\.text) + ["Mind the gap"] {
            XCTAssertFalse(logged.contains(text), "\(text) is readable in the logged value")
            let characters = Array(text)
            for length in 3...characters.count {
                for start in 0...(characters.count - length) {
                    let run = String(characters[start..<(start + length)])
                    XCTAssertFalse(logged.contains(run),
                                   "\"\(run)\" of \(text) is recoverable from the logged value")
                }
            }
        }
        XCTAssertTrue(logged.range(of: "^[0-9a-f]{4}:[0-9a-f]{4}$",
                                   options: .regularExpression) != nil,
                      "the logged digest is not a bare hex rendering: \(logged)")
        XCTAssertEqual(harness.bus.events(named: "text_change").first?.metadata["regionCount"], "4")
    }

    // MARK: - Scenario: A camera that leaves clears the overlay, and a camera
    // that comes back costs nothing
    //
    // Two owner-device defects, one scripted session. The translation used to
    // hang over text the camera had left — the departure was bounded in
    // *passes*, and two passes at the reduced still-scene cadence is 1.4 s of
    // stale overlay — and the string the cloud had already been paid for used
    // to be asked again when the camera came back to it, because the answer
    // was held for the regions on screen rather than for the text.

    @MainActor
    func testScenarioACameraThatLeavesClearsTheOverlayAndAComebackIsAnsweredFromTheCache() async throws {
        let clock = ScriptedClock()
        let harness = makeHarness(transport: Self.respondingTransport(), now: { clock.now })
        await harness.pipeline.updateLayout(layout)
        let frame = try makeFrame()

        // 1. The sign resolves once, at the nominal cadence.
        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        await harness.pipeline.ingest(frame)
        clock.advance(by: 0.25)
        await harness.pipeline.ingest(frame)
        await waitUntil("the string to resolve") { harness.transport.requestCount == 1 }
        await waitUntil("the resolution to be published") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == self.cloudText }) else { return false }
            if case .resolved = latest.result(for: region).outcome { return true }
            return false
        }
        let resolved = try await latest(harness)
        let resolvedRegion = try XCTUnwrap(region(cloudText, in: resolved))
        XCTAssertEqual(requests(carrying: cloudText, in: harness), 1)
        XCTAssertEqual(harness.brain.calls.count, 1,
                       "the cloud string is asked of the on-device tier first")

        // 2. The camera leaves the sign. The scene is now still, so the tap is
        //    at the reduced cadence (0.7 s) — one pass of it is one miss, and
        //    the wall-clock grace (recalibrated 2026-09-18) is what bounds the
        //    departure, not the pass count.
        harness.recogniser.defaultStep = .regions([])
        clock.advance(by: LiveTranslateConfig().overlayDepartureGraceSeconds + 0.1)
        await harness.pipeline.ingest(frame)

        let departed = try await latest(harness)
        XCTAssertNil(region(cloudText, in: departed),
                     "a region that left the publication must clear its overlay within one "
                     + "cycle plus the departure grace — nothing may still be drawn for it")
        XCTAssertTrue(departed.regions.isEmpty)
        assertEveryRegionIsRendered(departed)

        // 3. The camera comes back to the same sign. It resolves again — and
        //    the resolution costs nothing: the persisted cache answers it.
        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        clock.advance(by: 0.7)
        await harness.pipeline.ingest(frame)
        clock.advance(by: 0.25)
        await harness.pipeline.ingest(frame)
        await waitUntil("the returned string to be answered") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == self.cloudText }) else { return false }
            if case .resolved = latest.result(for: region).outcome { return true }
            return false
        }

        XCTAssertEqual(requests(carrying: cloudText, in: harness), 1,
                       "the same text is one question for the session: the second resolution is a "
                       + "cache hit, not a second request the family pays for")
        XCTAssertEqual(harness.transport.requestCount, 1)
        XCTAssertEqual(harness.brain.calls.count, 1,
                       "a cache hit is answered before the brain is asked again, so the return "
                       + "costs no generation either")
        let persistedHits = harness.bus.events(named: "cache_hit")
            .filter { $0.metadata["origin"] == "persisted" }
        XCTAssertGreaterThanOrEqual(persistedHits.count, 1,
                                    "the second resolution is recorded as what it is: a persisted hit")

        let returned = try await latest(harness)
        let returnedRegion = try XCTUnwrap(region(cloudText, in: returned))
        XCTAssertEqual(returnedRegion.id, resolvedRegion.id,
                       "the string kept its identity across the departure, so the overlay returns "
                       + "to the region it left")
        guard case .resolved(_, let translation, let tier) = returned.result(for: returnedRegion).outcome else {
            return XCTFail("a cached string resolves; the elder sees the same translation again")
        }
        XCTAssertEqual(translation, "ने:" + cloudText, "the same text resolves to the same translation")
        XCTAssertEqual(tier, .cloud, "a persisted entry is cloud-produced and says so (no request claimed)")
        let awaited = await inFlightAttempts(harness)
        XCTAssertEqual(awaited, 0)
    }

    /// The cache write, end to end through the live path and the shipped
    /// T-032 cipher: what the cloud resolved is on the encrypted channel in
    /// the shape the next session reads, and what the dictionary answered is
    /// not on the channel at all.
    ///
    /// The point of driving the *real* decorator here rather than the
    /// in-memory double is that "the cache is written" is not the claim the
    /// feature makes — "the next session's lookup is a hit, without a second
    /// request" is, and that path runs through the cipher.
    @MainActor
    func testScenarioACloudResolutionIsWrittenThroughTheCipherSeamAndServesTheNextSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTranslationPipelineTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = LiveTranslateTestCipherKeyStore()
        // The shipped composition (AppCoordinator): the cipher wrapping the
        // encrypted file channel, with the key held elsewhere.
        let cipher = LiveTranslateCipherStorage(wrapping: EncryptedFileStorage(rootDirectory: root),
                                                keyStore: keyStore)

        let harness = makeHarness(transport: Self.respondingTransport(), cacheChannel: cipher)
        await harness.pipeline.updateLayout(layout)
        let frame = try makeFrame()

        // One curated string and one the device cannot answer, in one scene:
        // the whole point is to see which of the two reaches the channel.
        harness.recogniser.defaultStep = .regions([detected(curatedText, box: box(0.1, 0.1, 0.4, 0.2)),
                                                   detected(cloudText, box: box(0.2, 0.4, 0.6, 0.5))])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await waitUntil("both strings to terminate") {
            guard let latest = await harness.recorder.latest,
                  latest.regions.count == 2 else { return false }
            return latest.regions.allSatisfy { region in
                if case .pending = latest.result(for: region).outcome { return false }
                return true
            }
        }
        XCTAssertEqual(harness.transport.requestCount, 1, "the curated string never reaches the cloud")

        // The bytes on the channel are the cipher's envelope, not the payload.
        let sealed = try XCTUnwrap(cipher.readRawData(key: LabelTranslationCache.storageKey),
                                   "a cloud resolution must be persisted, or the camera coming back "
                                   + "to the same text pays for it again")
        XCTAssertEqual(Array(sealed.prefix(LiveTranslateCipherStorage.Envelope.magic.count)),
                       LiveTranslateCipherStorage.Envelope.magic,
                       "the live path writes the cache through the cipher, never in the clear (T-032)")
        let raw = String(decoding: sealed, as: UTF8.self)
        XCTAssertFalse(raw.contains(cloudText), "no recognized text on the channel in the clear")
        XCTAssertFalse(raw.contains("ने:" + cloudText), "no translation on the channel in the clear")

        // Decoded through the cipher: exactly one entry, and it is the cloud
        // string's key. The curated string is served by lookup and is never
        // written (FR-LCT-019).
        guard case .success(let payload) = cipher.read(key: LabelTranslationCache.storageKey,
                                                       type: LabelTranslationCache.Persisted.self) else {
            return XCTFail("the channel must hold one decodable payload")
        }
        XCTAssertEqual(payload.schemaVersion, LabelTranslationCache.Persisted.currentSchemaVersion)
        XCTAssertEqual(payload.entries.map(\.key),
                       [LabelTranslationCache.normalizationKey(text: cloudText, targetLanguage: .nepali)],
                       "only the cloud-resolved string is persisted")

        // The next session: a fresh cache over the same channel, no pipeline
        // and no transport at all. This is the lookup that must not cost a
        // request.
        let nextSession = LabelTranslationCache(storage: cipher,
                                                 observabilityBus: LiveTranslateSanitisingBus())
        guard case .success(.some(let hit)) = nextSession.lookup(text: cloudText) else {
            return XCTFail("the next session must answer a cloud-resolved string from the cache")
        }
        XCTAssertEqual(hit.translation, "ने:" + cloudText)
        XCTAssertEqual(hit.origin, .persisted)
        XCTAssertEqual(hit.tier, .cloud)
    }

    /// The consent half of the caching rule: a cache hit is not egress, so it
    /// must not re-open the question the elder has already answered. The
    /// prompt is presented once — at the first cloud need — and never again
    /// for a string the device can already answer.
    @MainActor
    func testScenarioACacheHitNeverRePromptsForConsent() async throws {
        let clock = ScriptedClock()
        let harness = makeHarness(consent: false, transport: Self.respondingTransport(),
                                  now: { clock.now })
        await harness.pipeline.updateLayout(layout)
        let frame = try makeFrame()

        // First cloud need: the prompt, the grant, the resolution.
        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        await harness.pipeline.ingest(frame)
        clock.advance(by: 0.25)
        await harness.pipeline.ingest(frame)
        await waitUntil("the prompt to be presented") { harness.controller.isPromptPresented }
        XCTAssertEqual(harness.bus.events(named: "consent_prompt_shown").count, 1)
        if case .failure(let error) = harness.controller.grant() {
            return XCTFail("a grant must be recorded: \(error)")
        }
        await harness.pipeline.ingest(frame)
        await waitUntil("the granted attempt to land") { harness.transport.requestCount == 1 }
        await waitUntil("the resolution to be published") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == self.cloudText }) else { return false }
            if case .resolved = latest.result(for: region).outcome { return true }
            return false
        }

        // The camera leaves the sign and comes back to it.
        harness.recogniser.defaultStep = .regions([])
        clock.advance(by: 0.7)
        await harness.pipeline.ingest(frame)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        clock.advance(by: 0.7)
        await harness.pipeline.ingest(frame)
        clock.advance(by: 0.25)
        await harness.pipeline.ingest(frame)
        await waitUntil("the returned string to be answered from the cache") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == self.cloudText }) else { return false }
            if case .resolved = latest.result(for: region).outcome { return true }
            return false
        }

        XCTAssertEqual(harness.transport.requestCount, 1, "a cache hit is not a send")
        XCTAssertFalse(harness.controller.isPromptPresented,
                       "nothing leaves the device for a cached string, so there is nothing to consent to")
        XCTAssertEqual(harness.bus.events(named: "consent_prompt_shown").count, 1,
                       "the prompt is presented once, at the first cloud need; a cache hit does not "
                       + "re-ask the elder for a translation the device already holds")
    }

    /// The complement of the Fix-1 half, so the grace is not over-broad: a
    /// scene that is *seen* every pass — including through a tracking pass,
    /// which is what following a moving box looks like — never loses its
    /// overlay, however long the session runs.
    @MainActor
    func testScenarioARegionThatIsSeenOnEveryPassIsNeverClearedByTheGrace() async throws {
        let clock = ScriptedClock()
        let harness = makeHarness(transport: Self.respondingTransport(), now: { clock.now })
        await harness.pipeline.updateLayout(layout)
        let frame = try makeFrame()

        // The drift-following case from the owner's own complaint: a pan that
        // keeps the same string on screen, boxes moving with it.
        harness.recogniser.defaultStep = .regions([detected(cloudText, box: box(0.2, 0.4, 0.6, 0.5))])
        await harness.pipeline.ingest(frame)
        clock.advance(by: 0.25)
        await harness.pipeline.ingest(frame)
        await waitUntil("the string to resolve") { harness.transport.requestCount == 1 }

        for step in 1...6 {
            let y = 0.40 + Double(step) * 0.05
            harness.recogniser.defaultStep = .regions([detected(cloudText, box: box(0.2, y, 0.6, y + 0.1))])
            clock.advance(by: 0.7)
            await harness.pipeline.ingest(frame)
        }

        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(cloudText, in: publication),
                                   "a region that is seen on every pass is never a departure")
        guard case .resolved = publication.result(for: region).outcome else {
            return XCTFail("and it never flashes back to pending")
        }
        XCTAssertEqual(region.box.yMin, 0.40 + 6 * 0.05, accuracy: 1e-9,
                       "the overlay keeps following the box: the grace does not freeze geometry")
        XCTAssertEqual(harness.transport.requestCount, 1, "and the pan asks nothing new")
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
        //
        // Two passes, because a reading belongs to the region only once the OCR
        // has stood behind it twice (owner device report, 2026-09-19: a
        // one-pass misread is the flicker the reading consensus exists to keep
        // off the screen). The claim under test is about a string that really
        // changed, so the script gives the change the evidence it needs; the
        // first of these two passes is the candidate and asks nothing.
        harness.recogniser.defaultStep = .regions([detected(secondCloudText)])
        await harness.pipeline.ingest(frame)
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
        let detector = LiveTextDetector(observabilityBus: bus,
                                        engine: engine,
                                        objectEngine: StubObjectDetectionEngine(),
                                        now: clock.next)
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
                                               geminiCloudEnabled: true,
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

    // MARK: - Scenario: The cascade is dictionary, then the on-device brain,
    // then the consent-gated cloud (FR-LCT-008 as amended 2026-09-17)
    //
    // These four claims are what the tier insertion is for:
    //   1. a curated string is never asked of a 4B model,
    //   2. a string the brain answers never leaves the device — no consent, no
    //      request, no budget,
    //   3. a string the brain cannot answer is not dropped: it reaches the
    //      cloud exactly as it did when tier 1 did not exist,
    //   4. the whole cycle's unresolved strings are ONE generation.

    /// Gives the session's task tree the window an assertion that something
    /// did *not* happen needs — the same window the positive assertions get
    /// from `waitUntil`.
    private func settleTheCycle() async {
        try? await Task<Never, Never>.sleep(for: .milliseconds(60))
    }

    /// The brain's translation of an uncurated string. Nepali target, so the
    /// string reads like a real answer rather than a marker.
    private let brainTranslation = "यहाँ भित्र प्रवेश मात्र"

    @MainActor
    func testScenarioACuratedSceneNeverReachesTheBrain() async throws {
        let harness = makeHarness()
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(curatedText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)
        await settleTheCycle()

        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(curatedText, in: publication))
        XCTAssertEqual(publication.result(for: region).sourceTier, .dictionary)

        let brainCalls = harness.brain.calls
        XCTAssertTrue(brainCalls.isEmpty,
                      "tier 0 answers it; the cascade does not escalate past an answered question")
    }

    @MainActor
    func testScenarioABrainAnswerIsNeverSentToTheCloud() async throws {
        // Consent declined and no provider key: the brain path must not need
        // either (it leaves nothing to consent to) and must not consult them.
        let harness = makeHarness(consent: false, configured: false)
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        harness.brain.answers = [cloudText: brainTranslation]

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        let asked = cloudText
        await waitUntil("the brain's answer to be published") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == asked }) else {
                return false
            }
            return latest.result(for: region).sourceTier == .onDeviceBrain
        }

        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(cloudText, in: publication))
        XCTAssertEqual(publication.result(for: region).text, brainTranslation)
        XCTAssertEqual(publication.result(for: region).sourceTier, .onDeviceBrain,
                       "a local answer must be attributed to the tier that produced it")

        XCTAssertEqual(harness.transport.requestCount, 0, "the cloud is never asked")
        XCTAssertEqual(harness.governor.callsToday, 0, "a local answer spends no provider budget")
        XCTAssertFalse(harness.controller.isPromptPresented,
                       "nothing leaves the device, so there is nothing to consent to (OD-13)")
        XCTAssertEqual(harness.gate.inFlightRegistrationCount, 0)
    }

    @MainActor
    func testScenarioABrainFailureFallsThroughToTheCloud() async throws {
        // The fake answers nothing: a brain that hit no failure class the tier
        // reports distinctly still hands the string back, and the cascade
        // continues. The tier's own suite covers which reason each failure
        // maps to.
        let harness = makeHarness(consent: true,
                                  transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        // The claim is about what a consumer can see, so the wait is on the
        // publication rather than on the request count: a request that has
        // been made but not answered is not yet an answer.
        let asked = cloudText
        await waitUntil("the cloud answer to be published") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == asked }) else {
                return false
            }
            return latest.result(for: region).sourceTier == .cloud
        }

        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(cloudText, in: publication))
        XCTAssertEqual(publication.result(for: region).sourceTier, .cloud)
        XCTAssertEqual(requests(carrying: cloudText, in: harness), 1,
                       "an unanswered string is not dropped — it is asked of the next tier")
        let brainCalls = harness.brain.calls
        XCTAssertEqual(brainCalls, [[cloudText]], "the brain was asked first, once")
    }

    @MainActor
    func testScenarioAnUnavailableBrainIsReportedAndSkipsToTheCloud() async throws {
        let harness = makeHarness(consent: true,
                                  transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        harness.brain.unavailable = true

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        let asked = cloudText
        await waitUntil("the cloud answer to be published") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == asked }) else {
                return false
            }
            return latest.result(for: region).sourceTier == .cloud
        }

        // The device has no brain: the tier says so in its own vocabulary and
        // the cycle continues. Never a silent stub, never a stalled cycle.
        let unavailable = harness.bus.events(named: "brain_translation_unavailable")
        XCTAssertEqual(unavailable.count, 1, "one reason per sighting, not one per frame")
        XCTAssertEqual(unavailable.first?.metadata["reason"], "model_not_installed")
        XCTAssertEqual(unavailable.first?.outcome, "degraded")

        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(cloudText, in: publication))
        XCTAssertEqual(publication.result(for: region).sourceTier, .cloud)
    }

    @MainActor
    func testScenarioAGrantedPromptDoesNotReAskTheBrain() async throws {
        // The prompt cycle releases the attempt so the next tick can carry it;
        // "the next tick" is not a reason to pay for the same generation again.
        // One sighting, one ask — including the sighting an elder answered in
        // the middle of.
        let harness = makeHarness(consent: false, transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        await waitUntil("the prompt to be presented") { harness.controller.isPromptPresented }
        if case .failure(let error) = harness.controller.grant() {
            return XCTFail("a grant must be recorded: \(error)")
        }
        await harness.pipeline.ingest(frame)

        let asked = cloudText
        await waitUntil("the cloud answer to be published") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == asked }) else {
                return false
            }
            return latest.result(for: region).sourceTier == .cloud
        }

        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(cloudText, in: publication))
        XCTAssertEqual(publication.result(for: region).sourceTier, .cloud,
                       "a released attempt is still owed to the gate after the answer")
        XCTAssertEqual(harness.brain.calls, [[cloudText]],
                       "the sighting paid for one generation, not one per tick")
    }

    @MainActor
    func testScenarioOneCycleIsOneBatchAndOneSightingIsOneAsk() async throws {
        let harness = makeHarness(consent: true,
                                  transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([
            detected(cloudText, box: box(0.1, 0.2, 0.4, 0.3)),
            detected(secondCloudText, box: box(0.5, 0.2, 0.8, 0.3))
        ])

        let frame = try makeFrame()
        // Four ticks: both regions become visible on the second, and the third
        // and fourth are the ones that would re-ask a brain that let them.
        for _ in 0..<4 { await harness.pipeline.ingest(frame) }

        await waitUntil("the brain to be asked") {
            let calls = harness.brain.calls
            return !calls.isEmpty
        }
        await settleTheCycle()

        let brainCalls = harness.brain.calls
        XCTAssertEqual(brainCalls.count, 1,
                       "the cycle's unresolved strings are ONE generation, and a sighting asks once")
        XCTAssertEqual(Set(brainCalls[0]), [cloudText, secondCloudText],
                       "both of the cycle's unresolved strings travel in the same batch")
    }

    @MainActor
    func testScenarioOnlyTheStringsTheBrainCouldNotAnswerReachTheGate() async throws {
        let harness = makeHarness(consent: true,
                                  transport: Self.respondingTransport())
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([
            detected(cloudText, box: box(0.1, 0.2, 0.4, 0.3)),
            detected(secondCloudText, box: box(0.5, 0.2, 0.8, 0.3))
        ])
        // The brain answers exactly one of the two.
        harness.brain.answers = [cloudText: brainTranslation]

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        let asked = secondCloudText
        await waitUntil("the cloud answer to be published") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == asked }) else {
                return false
            }
            return latest.result(for: region).sourceTier == .cloud
        }

        XCTAssertEqual(requests(carrying: cloudText, in: harness), 0,
                       "a string the brain answered does not also go to the cloud")
        XCTAssertEqual(requests(carrying: secondCloudText, in: harness), 1,
                       "a string the brain could not answer is not lost on the way")

        let publication = try await latest(harness)
        let answered = try XCTUnwrap(region(cloudText, in: publication))
        let remainder = try XCTUnwrap(region(secondCloudText, in: publication))
        XCTAssertEqual(publication.result(for: answered).sourceTier, .onDeviceBrain)
        XCTAssertEqual(publication.result(for: remainder).sourceTier, .cloud)
    }

    // MARK: - Scenario: the reliability router (round-3 ship, 2026-09-19)
    //
    // The approved direction: an on-device answer SETTLES only for the classes
    // the model is proven on — short labels, menus and pharma lines, the shapes
    // every passing probe row has — and the sentence class goes to the cloud
    // when there is a path, falling back to the device when there is not.
    //
    // `cloudText` is five words, so it is the sentence class; `secondCloudText`
    // and `thirdCloudText` are four, so they are the proven one. The
    // discriminator's own suite is `TranslationReliabilityRouterTests`; what is
    // here is the WIRING — which tier actually leads a live cycle, and what
    // becomes of a string the gate cannot pass on.

    /// The cloud leads, even though the device could have answered: the class
    /// decides, not availability, so the on-device generation is never paid
    /// for at all.
    @MainActor
    func testScenarioASentenceLeadsWithTheCloudWhenThereIsAPath() async throws {
        let harness = makeHarness(consent: true,
                                  transport: Self.respondingTransport(),
                                  reachability: ScriptedReachability(reachable: true))
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        // Armed and willing: if the device is asked, it answers.
        harness.brain.answers = [cloudText: brainTranslation]

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        let asked = cloudText
        await waitUntil("the cloud answer to be published") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == asked }) else {
                return false
            }
            return latest.result(for: region).sourceTier == .cloud
        }

        XCTAssertEqual(harness.brain.calls.count, 0,
                       "the sentence class does not pay for an on-device "
                       + "generation when the cloud can take it")
        XCTAssertEqual(requests(carrying: asked, in: harness), 1)
        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(asked, in: publication))
        XCTAssertEqual(publication.result(for: region).sourceTier, .cloud)
    }

    /// The same sentence, one value changed — there is no path — and the device
    /// leads it. Nothing is sent, and the region is not left to degrade on a
    /// cloud that cannot answer: this is the route the offline phone takes.
    @MainActor
    func testScenarioWithNoPathTheSameSentenceStaysOnTheDevice() async throws {
        let harness = makeHarness(consent: true,
                                  transport: Self.respondingTransport(),
                                  reachability: ScriptedReachability(reachable: false))
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        harness.brain.answers = [cloudText: brainTranslation]

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        await waitUntil("the on-device answer to be published") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == self.cloudText }) else {
                return false
            }
            return latest.result(for: region).sourceTier == .onDeviceBrain
        }

        XCTAssertEqual(requests(carrying: cloudText, in: harness), 0,
                       "with no path nothing is sent at all")
        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(cloudText, in: publication))
        XCTAssertEqual(publication.result(for: region).sourceTier, .onDeviceBrain)
    }

    /// The cloud may lead — there is a path and the switch is on — but the gate
    /// will not pass the batch on, because the household has already declined.
    /// The reservation is what keeps the sentence translatable on the device
    /// instead of degrading it with the gate's reason.
    @MainActor
    func testScenarioASentenceTheGateCannotPassOnFallsBackToTheDevice() async throws {
        let harness = makeHarness(consent: false,
                                  transport: Self.respondingTransport(),
                                  reachability: ScriptedReachability(reachable: true))
        _ = harness.gate.record(granted: false)
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        harness.brain.answers = [cloudText: brainTranslation]

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        await waitUntil("the on-device fallback to be published") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == self.cloudText }) else {
                return false
            }
            return latest.result(for: region).sourceTier == .onDeviceBrain
        }

        XCTAssertEqual(harness.transport.requestCount, 0, "a denial is not a request")
        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(cloudText, in: publication))
        XCTAssertEqual(publication.result(for: region).outcome,
                       .resolved(originalText: cloudText,
                                 translation: brainTranslation,
                                 tier: .onDeviceBrain),
                       "the fallback is the device, not a degraded region")
    }

    @MainActor
    func testScenarioAHungBrainDoesNotAbsorbTheCycle() async throws {
        // The generation is the one step with no upper bound of its own: a 4B
        // decode on a phone can still be running when the next frame arrives.
        // The stage deadline is the pipeline's own, and what it buys is this
        // test's claim — a brain that does not come back does not keep the
        // region pending for the rest of the session. The strings go to the
        // cloud in the same cycle, and the stage that lost the race is named.
        var config = LiveTranslationPipelineTests.unpacedDispatchConfig()
        config.brainTranslationTimeoutSeconds = 0.05
        config.brainTranslationStageGraceSeconds = 0.05
        let brain = RecordingBrain()
        brain.hangs = true
        let harness = makeHarness(consent: true,
                                  transport: Self.respondingTransport(),
                                  brain: brain,
                                  config: config)
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        let asked = cloudText
        await waitUntil("the cloud answer to be published") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == asked }) else {
                return false
            }
            return latest.result(for: region).sourceTier == .cloud
        }

        XCTAssertEqual(brain.calls, [[cloudText]],
                       "the stage was attempted: the deadline is a bound on waiting, not a veto")
        let timeout = harness.bus.events(named: "brain_translation_unavailable")
        XCTAssertEqual(timeout.first?.metadata["reason"], "inference_timeout",
                       "a stage that never returned is reported with the token that says what happened")
        // …and with the stage that says WHOSE deadline it was. The tier's own
        // bound (`deadline`) and the caller's (`stage_deadline`) are different
        // diagnoses — "the model is too slow" against "the tier never got to
        // its own bound" — and on the device they were indistinguishable
        // (2026-09-17: the tier reported the second as `inference_failed`).
        XCTAssertEqual(timeout.first?.metadata["failureStage"], "stage_deadline",
                       "the caller's own deadline is the stage this record names")
        XCTAssertEqual(requests(carrying: cloudText, in: harness), 1,
                       "the region is not stranded: what the brain did not answer reaches the gate")
        let attempts = await inFlightAttempts(harness)
        XCTAssertEqual(attempts, 0, "the abandoned attempt releases its claim")

        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(cloudText, in: publication))
        XCTAssertEqual(publication.result(for: region).sourceTier, .cloud)
    }

    @MainActor
    func testScenarioTheRequestLeavesOnlyAfterTheBrainWasAsked() async throws {
        // The dispatch chain, pinned in order rather than in counts: at the
        // moment the cloud request arrives, the brain has already been asked
        // and has already answered (with nothing). Consent is granted here, so
        // the gate is a pass-through and the claim is about the tiers above it.
        let brain = RecordingBrain()
        let transport = Self.respondingTransport()
        var brainAtSend: [[[String]]] = []
        transport.onRequest = { _ in brainAtSend.append(brain.calls) }
        let harness = makeHarness(consent: true, transport: transport, brain: brain)
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        let asked = cloudText
        await waitUntil("the cloud answer to be published") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == asked }) else {
                return false
            }
            return latest.result(for: region).sourceTier == .cloud
        }

        XCTAssertEqual(brainAtSend, [[[cloudText]]],
                       "the brain is asked first, once, for exactly what left the device")
        XCTAssertFalse(harness.controller.isPromptPresented,
                       "a granted decision is recorded, so nothing is re-asked of the elder")
        XCTAssertEqual(requests(carrying: cloudText, in: harness), 1,
                       "a granted decision is a request that actually fires")
    }

    @MainActor
    func testThePipelineAnnouncesAStaleSceneOnlyAfterTheConfiguredIdleCycles() async throws {
        // The reduced cadence belongs to the frame source, but the *decision*
        // belongs to the pipeline: only the pipeline can see that the OCR
        // passes are finding nothing. The threshold is the config's, and the
        // announcement is a transition — said once, not once per frame.
        var config = LiveTranslationPipelineTests.unpacedDispatchConfig()
        config.stalePassesBeforeReducedCadence = 3
        let harness = makeHarness(consent: true,
                                  transport: Self.respondingTransport(),
                                  config: config)
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        let frame = try makeFrame()

        for _ in 0..<2 { await harness.pipeline.ingest(frame) }
        XCTAssertEqual(harness.backpressure.staleAnnouncements, [],
                       "two idle cycles are not yet staleness")

        for _ in 0..<3 { await harness.pipeline.ingest(frame) }
        XCTAssertEqual(harness.backpressure.staleAnnouncements, [true],
                       "the third idle cycle announces staleness, and announces it once")
    }

    @MainActor
    func testScenarioClosingTheSessionReleasesTheBrain() async throws {
        let harness = makeHarness()
        await harness.pipeline.close()

        let releaseCount = harness.brain.releaseCount
        XCTAssertEqual(releaseCount, 1,
                       "a closed session leaves no model parked in memory")
    }

    @MainActor
    func testTheProductionCompositionBuildsTheShippedTierAndStillReachesTheCloud() async throws {
        // The one test that lets the pipeline build its own tier (no brain
        // handed in). On a device or simulator with no brain installed that
        // tier reports itself unavailable and the cascade behaves exactly as
        // it did before tier 1 existed — which is the property the production
        // wiring has to have.
        let harness = makeHarness(consent: true,
                                  transport: Self.respondingTransport(),
                                  handsInABrain: false)
        await harness.pipeline.updateLayout(layout)
        harness.recogniser.defaultStep = .regions([detected(cloudText)])

        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        let asked = cloudText
        await waitUntil("the cloud answer to be published") {
            guard let latest = await harness.recorder.latest,
                  let region = latest.regions.first(where: { $0.text == asked }) else {
                return false
            }
            return latest.result(for: region).sourceTier == .cloud
        }

        let publication = try await latest(harness)
        let region = try XCTUnwrap(region(cloudText, in: publication))
        XCTAssertEqual(publication.result(for: region).sourceTier, .cloud)
    }

    // MARK: - Extract mode (owner verdict, 2026-09-18)
    //
    // The three scenarios below are the mode's whole contract, and they are
    // deliberately written against the **published** values like every other
    // scenario here: what the elder can observe is a publication, so a claim
    // about the mode is a claim about one. The other half of each claim is
    // what the tier machinery was *asked* — `brain.calls` and the transport's
    // `requestCount` are the evidence that "no translation runs by default"
    // is a fact about the work not done, not a fact about what happened to be
    // drawn.

    /// Extract mode is the default and it publishes the recognized text
    /// itself — with **no** tier work of any kind behind it.
    ///
    /// The dictionary is the sharpest probe available for the "no work" half:
    /// `curatedText` is a string the injected curated table answers, so a
    /// translated view would have shown `curatedTranslation` on the first
    /// cycle with no network and no brain at all. Extract mode publishes it
    /// still pending *and* draws the recognized string in its place, which is
    /// the whole of the mode: the text the camera found, standing where it
    /// found it, and nothing claiming to be a translation of it.
    @MainActor
    func testScenarioExtractModePublishesTheRecognizedTextAndRunsNoTierWork() async throws {
        let transport = TierTranslationTransport()
        let brain = RecordingBrain()
        let harness = makeHarness(transport: transport, brain: brain, extractionMode: true)
        await harness.pipeline.updateLayout(layout)

        let frame = try makeFrame()
        harness.recogniser.defaultStep = .regions([detected(curatedText)])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        let publication = try await latest(harness)
        XCTAssertTrue(publication.policy.extractionMode,
                      "the published policy is the one the placements were measured under, "
                      + "so it is where the mode is observable")
        XCTAssertEqual(publication.regions.count, 1)
        XCTAssertEqual(publication.regions.first?.text, curatedText)

        // The recognized text is what is drawn, at the panel floor, in place.
        let placement = try XCTUnwrap(publication.placements.first)
        XCTAssertEqual(placement.lines.map(\.text), [curatedText],
                       "extract mode draws the recognized string where the text stood")
        XCTAssertEqual(placement.lines.first?.pointSize, publication.policy.minPointSize,
                       "the extracted text renders at the body floor, not at the "
                       + "in-place-only floor a translation may drop to")
        XCTAssertFalse(placement.isClampedFallback)

        // Nothing claims to be a translation, and nothing was asked to make
        // one — not the curated table, not the brain, not the cloud.
        let region = try XCTUnwrap(region(curatedText, in: publication))
        XCTAssertEqual(publication.result(for: region), .pending(curatedText),
                       "a region the curated table could answer is still pending: extract "
                       + "mode does not translate what nobody asked about")
        XCTAssertTrue(brain.calls.isEmpty, "extract mode ran a generation: \(brain.calls)")
        XCTAssertEqual(transport.requestCount, 0,
                       "extract mode reached the network: \(transport.requests.count) request(s)")

        // The never-empty rule holds in this mode too: the region is drawn,
        // not dropped, and every drawn box is a real placement.
        XCTAssertTrue(publication.hasVisibleText)
        assertEveryRegionIsRendered(publication)
    }

    /// A **block** (a region whose text is several grouped lines) draws its
    /// own recognized lines in extract mode, in the grouper's order.
    @MainActor
    func testScenarioExtractModeDrawsABlockAsItsOwnRecognizedLines() async throws {
        let block = ["PREWASH 40", "RINSE AID"].joined(separator: SceneBlock.lineSeparator)
        let harness = makeHarness(extractionMode: true)
        await harness.pipeline.updateLayout(layout)

        let frame = try makeFrame()
        harness.recogniser.defaultStep = .regions([
            detected(block, box: box(0.2, 0.3, 0.75, 0.55))
        ])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        let publication = try await latest(harness)
        let placement = try XCTUnwrap(publication.placements.first)
        XCTAssertEqual(placement.lines.map(\.text), ["PREWASH 40", "RINSE AID"],
                       "a block is one panel carrying its own recognized lines, never "
                       + "the translated view's state sentence")
        XCTAssertEqual(Set(placement.lines.map(\.pointSize)),
                       [publication.policy.minPointSize],
                       "every line of the panel is drawn at the one body floor")
        let region = try XCTUnwrap(publication.regions.first)
        XCTAssertEqual(publication.result(for: region), .pending(block))
    }

    /// The tap: one block is asked about, and **exactly** one.
    ///
    /// Two regions, one the curated table can answer and one it cannot. The
    /// tap on the first resolves it from the device with nothing asked of the
    /// brain or the cloud; the tap on the second asks the brain for that one
    /// string — not for the scene — and the first stays resolved. A scene-wide
    /// dispatch would show up here as a batch carrying both strings, which is
    /// the failure this pins.
    @MainActor
    func testScenarioATapTranslatesExactlyTheTappedBlock() async throws {
        let transport = TierTranslationTransport()
        let brain = RecordingBrain()
        brain.answers = [cloudText: "ने:the far sign"]
        let harness = makeHarness(transport: transport, brain: brain, extractionMode: true)
        await harness.pipeline.updateLayout(layout)

        let frame = try makeFrame()
        harness.recogniser.defaultStep = .regions([
            detected(curatedText, box: box(0.2, 0.15, 0.6, 0.25)),
            detected(cloudText, box: box(0.2, 0.6, 0.7, 0.7)),
        ])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        let before = try await latest(harness)
        let curated = try XCTUnwrap(region(curatedText, in: before))
        let uncurated = try XCTUnwrap(region(cloudText, in: before))
        XCTAssertEqual(before.result(for: curated), .pending(curatedText))
        XCTAssertEqual(before.result(for: uncurated), .pending(cloudText))

        // The tap on the device-answerable block: the curated table answers,
        // and nothing else is asked about anything.
        await harness.pipeline.translateRegion(curated.id)
        let afterFirstTap = try await latest(harness)
        let curatedAfter = try XCTUnwrap(region(curatedText, in: afterFirstTap))
        let uncuratedAfter = try XCTUnwrap(region(cloudText, in: afterFirstTap))
        XCTAssertEqual(afterFirstTap.result(for: curatedAfter),
                       .resolved(originalText: curatedText,
                                 translation: curatedTranslation,
                                 tier: .dictionary))
        XCTAssertEqual(afterFirstTap.result(for: uncuratedAfter), .pending(cloudText),
                       "the other block was translated by a tap that was not about it")
        XCTAssertTrue(brain.calls.isEmpty,
                      "the device answered, so the brain should not have been asked: \(brain.calls)")
        XCTAssertEqual(transport.requestCount, 0)

        // A resolved block draws its translation — the text it was tapped to
        // replace must not stay on screen under a claim that it was answered.
        XCTAssertEqual(afterFirstTap.placements.first { $0.region.id == curatedAfter.id }?
            .lines.first?.text, curatedTranslation)

        // The tap on the one the device cannot answer: the brain is asked for
        // that string and no other.
        await harness.pipeline.translateRegion(uncurated.id)
        let asked = cloudText
        await waitUntil("the tapped block's answer to be published") {
            guard let latest = await harness.recorder.latest,
                  let sign = latest.regions.first(where: { $0.text == asked }) else {
                return false
            }
            return latest.result(for: sign).sourceTier == .onDeviceBrain
        }

        let afterSecondTap = try await latest(harness)
        XCTAssertEqual(brain.calls, [[cloudText]],
                       "a tap dispatched \(brain.calls) — the batch must carry the tapped "
                       + "block's string and nothing else")
        XCTAssertEqual(transport.requestCount, 0,
                       "the on-device brain answered; nothing should have left the device")
        let curatedStill = try XCTUnwrap(region(curatedText, in: afterSecondTap))
        XCTAssertEqual(afterSecondTap.result(for: curatedStill).sourceTier, .dictionary,
                       "a tap on one block must not disturb another's answer")
    }

    /// Translate-all, and back again.
    ///
    /// Leaving extract mode is the translated view's cycle, run in the same
    /// turn: everything the device can answer is answered and the view is
    /// published. Entering it again republishes under the extract policy —
    /// and the answers stay: the mode decides what is *drawn* and what may be
    /// *started*, never what has already been paid for.
    @MainActor
    func testScenarioTranslateAllRestoresTheTranslatedViewAndKeepsItsAnswers() async throws {
        let transport = TierTranslationTransport()
        let brain = RecordingBrain()
        let harness = makeHarness(transport: transport, brain: brain, extractionMode: true)
        await harness.pipeline.updateLayout(layout)

        let frame = try makeFrame()
        harness.recogniser.defaultStep = .regions([detected(curatedText)])
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        let extracting = try await latest(harness)
        XCTAssertTrue(extracting.policy.extractionMode)
        XCTAssertEqual(extracting.placements.first?.lines.map(\.text), [curatedText])

        // Translate-all: the translated view, resolved in the same turn.
        await harness.pipeline.updateExtractMode(false)
        let translated = try await latest(harness)
        XCTAssertFalse(translated.policy.extractionMode)
        let sign = try XCTUnwrap(region(curatedText, in: translated))
        XCTAssertEqual(translated.result(for: sign),
                       .resolved(originalText: curatedText,
                                 translation: curatedTranslation,
                                 tier: .dictionary),
                       "leaving extract mode resolves what the device can answer, in the "
                       + "turn the elder asked for it")
        XCTAssertEqual(translated.placements.first?.lines.first?.text, curatedTranslation,
                       "the translated view draws the translation in place")
        XCTAssertTrue(brain.calls.isEmpty)
        XCTAssertEqual(transport.requestCount, 0)

        // And back: the recognized text is the default view again, and the
        // answer the elder already has is not thrown away with it.
        await harness.pipeline.updateExtractMode(true)
        let extractingAgain = try await latest(harness)
        XCTAssertTrue(extractingAgain.policy.extractionMode)
        let regionAgain = try XCTUnwrap(region(curatedText, in: extractingAgain))
        XCTAssertEqual(extractingAgain.result(for: regionAgain).sourceTier, .dictionary,
                       "entering extract mode dropped an answer that had already been paid for")
        XCTAssertEqual(extractingAgain.placements.first?.lines.first?.text, curatedTranslation,
                       "a block that has been translated keeps its translation: the mode "
                       + "changes what an *unanswered* block draws, never what an answered "
                       + "one does")
    }

    // MARK: - Scenario: the dispatch pacing (owner device report, 2026-09-19)
    //
    // The device log these three claims answer is a `cache_miss` and a fresh
    // attempt on *every* pass — several per second for as long as a sign stayed
    // in frame — over a brain whose 5 s idle-unload meant the next attempt
    // loaded the same gigabyte again, ending in memory-pressure kills.
    //
    // The clock is the subject here, so every test below hands the pipeline a
    // `ScriptedClock` and states its own instants. The shipped intervals are in
    // force (`LiveTranslateConfig.default`): what is pinned is what the device
    // will actually do, not what the harness made convenient.

    /// A burst of strings that arrives inside one pacing window leaves as
    /// **one** dispatch — one generation, one request — and the strings that
    /// arrive while the window is shut are neither dropped nor sent.
    @MainActor
    func testScenarioABurstOfStringsInsideOneWindowIsOneDispatch() async throws {
        let clock = ScriptedClock()
        let transport = Self.respondingTransport()
        let brain = RecordingBrain()
        let config = LiveTranslateConfig.default
        let harness = makeHarness(transport: transport, brain: brain,
                                  now: { clock.now }, config: config)
        await harness.pipeline.updateLayout(layout)
        let frame = try makeFrame()

        // The first sign, and the dispatch it earns: a session's first is
        // immediate, because nothing has been paid for yet.
        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        await harness.pipeline.ingest(frame)
        clock.advance(by: 0.1)
        await harness.pipeline.ingest(frame)
        await waitUntil("the first string to be dispatched") { harness.transport.requestCount == 1 }

        // Two more signs arrive inside the window. Each takes its two passes to
        // be published (`regionAppearPasses`), and every tick in between is
        // held: the window is 1.5 s wide and the clock has moved 0.4.
        let scene = [detected(cloudText),
                     detected(secondCloudText, box: box(0.1, 0.1, 0.4, 0.2)),
                     detected(thirdCloudText, box: box(0.5, 0.1, 0.9, 0.2))]
        harness.recogniser.defaultStep = .regions(Array(scene.prefix(2)))
        clock.advance(by: 0.1)
        await harness.pipeline.ingest(frame)
        clock.advance(by: 0.1)
        await harness.pipeline.ingest(frame)
        harness.recogniser.defaultStep = .regions(scene)
        clock.advance(by: 0.1)
        await harness.pipeline.ingest(frame)
        clock.advance(by: 0.1)
        await harness.pipeline.ingest(frame)
        await settleTheCycle()

        XCTAssertEqual(transport.requestCount, 1,
                       "four passes inside one window dispatched \(transport.requestCount) times")
        XCTAssertEqual(requests(carrying: secondCloudText, in: harness), 0,
                       "a string that arrived inside the window was dispatched before it opened")
        XCTAssertEqual(requests(carrying: thirdCloudText, in: harness), 0)
        XCTAssertEqual(brain.calls, [[cloudText]],
                       "the held strings were not generated for either: \(brain.calls)")

        // The window opens — both of them, the dispatch's and the brain's — and
        // everything that accumulated goes out together.
        clock.advance(by: config.brainAttemptMinInterval)
        await harness.pipeline.ingest(frame)
        await waitUntil("the accumulated strings to be dispatched") { harness.transport.requestCount == 2 }

        let batched = TranslationRecordingTransport.items(in: transport.requests[1]).values
        XCTAssertEqual(Set(batched), [secondCloudText, thirdCloudText],
                       "the two strings that waited went out as one batch, not one each")
        XCTAssertEqual(brain.calls.count, 2,
                       "the burst cost \(brain.calls.count) generation(s): \(brain.calls)")
        XCTAssertEqual(Set(brain.calls[1]), [secondCloudText, thirdCloudText],
                       "one generation carried the whole accumulated batch")
    }

    /// The brain's own window, isolated: a string that arrives inside it is
    /// **held**, not dropped and not asked about — and it is asked about the
    /// moment the window opens, on device, with nothing leaving the device.
    @MainActor
    func testScenarioAStringInsideTheBrainWindowWaitsForItRatherThanBeingDropped() async throws {
        let clock = ScriptedClock()
        let transport = Self.respondingTransport()
        let brain = RecordingBrain()
        brain.answers = [cloudText: brainTranslation, secondCloudText: brainTranslation]
        let config = LiveTranslateConfig.default
        let harness = makeHarness(transport: transport, brain: brain,
                                  now: { clock.now }, config: config)
        await harness.pipeline.updateLayout(layout)
        let frame = try makeFrame()

        // The first sign: one generation, answered on device in the first pass.
        harness.recogniser.defaultStep = .regions([detected(cloudText)])
        await harness.pipeline.ingest(frame)
        clock.advance(by: 0.1)
        await harness.pipeline.ingest(frame)
        await waitUntil("the first string to be answered on device") {
            guard let latest = await harness.recorder.latest,
                  let sign = latest.regions.first(where: { $0.text == self.cloudText }) else { return false }
            return latest.result(for: sign).sourceTier == .onDeviceBrain
        }

        // The second sign appears 0.1 s later: well inside the brain's 8 s
        // window, and published (so it *is* a question) on the pass after.
        harness.recogniser.defaultStep = .regions([detected(cloudText),
                                                   detected(secondCloudText, box: box(0.1, 0.1, 0.4, 0.2))])
        clock.advance(by: 0.1)
        await harness.pipeline.ingest(frame)
        clock.advance(by: 0.1)
        await harness.pipeline.ingest(frame)
        clock.advance(by: 2)
        await harness.pipeline.ingest(frame)
        await settleTheCycle()

        XCTAssertEqual(brain.calls, [[cloudText]],
                       "the second string was generated for inside the window: \(brain.calls)")
        let held = try await latest(harness)
        let waiting = try XCTUnwrap(region(secondCloudText, in: held))
        XCTAssertEqual(held.result(for: waiting), .pending(secondCloudText),
                       "a string held by the window is still a question: it is pending, not dropped")
        XCTAssertTrue(held.hasVisibleText, "and the never-empty rule holds while it waits")

        // The window opens: the held string is asked about, on device.
        clock.advance(by: config.brainAttemptMinInterval)
        await harness.pipeline.ingest(frame)
        await waitUntil("the held string to be answered on device") {
            guard let latest = await harness.recorder.latest,
                  let sign = latest.regions.first(where: { $0.text == self.secondCloudText }) else { return false }
            return latest.result(for: sign).sourceTier == .onDeviceBrain
        }

        XCTAssertEqual(brain.calls, [[cloudText], [secondCloudText]],
                       "the waiting string was asked for exactly once, when its window opened")
        XCTAssertEqual(transport.requestCount, 0,
                       "the brain answered both, so nothing should have left the device")
    }

    /// The elder's own ask is not a pass: a tap inside the background windows
    /// still translates, and still moves them.
    ///
    /// Extract mode is where tap-to-translate lives, and both of its windows
    /// are shut when the second tap lands — 0.1 s after the first, against a
    /// 1.5 s dispatch window and an 8 s brain window. A tap that waited for
    /// either of them would be the mode failing at the one thing it does.
    @MainActor
    func testScenarioATapIsNotHeldByTheBackgroundWindows() async throws {
        let clock = ScriptedClock()
        let transport = Self.respondingTransport()
        let brain = RecordingBrain()
        brain.answers = [cloudText: brainTranslation, secondCloudText: brainTranslation]
        let config = LiveTranslateConfig.default
        let harness = makeHarness(transport: transport, brain: brain, now: { clock.now },
                                  config: config, extractionMode: true)
        await harness.pipeline.updateLayout(layout)
        let frame = try makeFrame()

        harness.recogniser.defaultStep = .regions([
            detected(cloudText, box: box(0.2, 0.15, 0.6, 0.25)),
            detected(secondCloudText, box: box(0.2, 0.6, 0.7, 0.7)),
            detected(thirdCloudText, box: box(0.2, 0.8, 0.7, 0.9)),
        ])
        await harness.pipeline.ingest(frame)
        clock.advance(by: 0.1)
        await harness.pipeline.ingest(frame)

        let extracting = try await latest(harness)
        let first = try XCTUnwrap(region(cloudText, in: extracting))
        let second = try XCTUnwrap(region(secondCloudText, in: extracting))
        XCTAssertEqual(extracting.regions.count, 3,
                       "extract mode published no dispatch of its own")
        XCTAssertTrue(brain.calls.isEmpty)
        XCTAssertEqual(transport.requestCount, 0)

        await harness.pipeline.translateRegion(first.id)
        await waitUntil("the first tapped block to be answered") {
            guard let latest = await harness.recorder.latest,
                  let sign = latest.regions.first(where: { $0.text == self.cloudText }) else { return false }
            return latest.result(for: sign).sourceTier == .onDeviceBrain
        }

        clock.advance(by: 0.1)
        await harness.pipeline.translateRegion(second.id)
        await waitUntil("the second tapped block to be answered") {
            guard let latest = await harness.recorder.latest,
                  let sign = latest.regions.first(where: { $0.text == self.secondCloudText }) else { return false }
            return latest.result(for: sign).sourceTier == .onDeviceBrain
        }

        XCTAssertEqual(brain.calls, [[cloudText], [secondCloudText]],
                       "each tap was translated on its own turn: \(brain.calls)")

        // …and the taps moved the clocks behind them: the scene-wide dispatch
        // that follows (leaving extract mode) is held, and reaches the brain
        // only when the window it left behind has passed.
        await harness.pipeline.updateExtractMode(false)
        clock.advance(by: 0.1)
        await harness.pipeline.ingest(frame)
        await settleTheCycle()
        XCTAssertEqual(brain.calls.count, 2,
                       "the background cycle ran inside the window the taps had just used: "
                       + "\(brain.calls)")

        clock.advance(by: config.brainAttemptMinInterval)
        harness.recogniser.defaultStep = .regions([
            detected(cloudText, box: box(0.2, 0.15, 0.6, 0.25)),
            detected(secondCloudText, box: box(0.2, 0.6, 0.7, 0.7)),
            detected(thirdCloudText, box: box(0.2, 0.8, 0.7, 0.9)),
        ])
        await harness.pipeline.ingest(frame)
        await waitUntil("the untapped block to reach the cloud") {
            harness.transport.requestCount == 1
        }
        XCTAssertEqual(requests(carrying: thirdCloudText, in: harness), 1,
                       "the block nobody tapped was dispatched once the window opened")
    }
}
