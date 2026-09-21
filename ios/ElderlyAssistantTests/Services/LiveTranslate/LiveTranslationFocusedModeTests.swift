import CoreMedia
import XCTest
@testable import ElderlyAssistant

/// [FOCUS-CAPTURE] `TranslationMode`: the two things a *mode* is allowed to
/// change about the one plan, and the one thing it must not.
///
/// `LiveTranslationPipeline.resolveFocused` is the same plan as the live cycle
/// — the claim ledger, the terminal writer, the gate-then-tier order — so what
/// a suite can usefully pin about the mode is exactly its two declared effects:
///
///  1. **Who leads.** The cascade routes a string by class, so a sentence-class
///     string leads with the cloud when the cloud can lead. A focused read is
///     the elder pointing at one thing and asking *now*: the device leads every
///     string, whatever its class. The A/B below runs the same string through
///     both entry points with the same composition, so the difference asserted
///     is the mode and nothing else.
///  2. **How much may be spent.** A focused crop's strings are whatever the
///     recogniser found in the box the elder drew, which nothing this side of
///     the budget bounds, so `focusMaxBatchCalls` caps the plan's batches. The
///     cap **releases** rather than fails: a capture held by it answers nothing
///     and settles nothing, and the region waits for the next plan exactly as a
///     clock-held one does. A test that expected a degraded region here would be
///     pinning "we stopped asking" as a failure.
///
/// And the one thing it must not change: **who is reachable.** The mode moves
/// the device in front; it does not remove the cloud behind it. A focused read
/// the device cannot answer still goes to the gate and the tier, which is what
/// makes the mode a routing choice rather than an offline switch.
final class LiveTranslationFocusedModeTests: XCTestCase {

    // MARK: - Seams

    /// The pipeline's own recogniser seam. No frame is read here — a focused
    /// read is handed its items by its caller — so this answers with a pass
    /// that found nothing and is never asked to.
    private final class SilentFrameRecogniser: LiveTranslateFrameRecognising {
        func begin() -> Result<Void, LiveTranslateError> { .success(()) }
        func end() {}
        func recognize(_ frame: CameraFrame) async
            -> Result<LiveTextDetector.Pass, LiveTranslateError> {
            .success(LiveTextDetector.Pass(regions: [], trackedBoxes: [:]))
        }
    }

    /// The network's answer, scripted. Only the cascade scenario wants the
    /// cloud able to lead; the focused ones run it reachable too, so a request
    /// count of zero is a statement about the mode and not about a dead radio.
    private final class ScriptedNetwork: NetworkReachability, @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool

        init(reachable: Bool) { value = reachable }

        var isReachable: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    @MainActor
    private struct Harness {
        let pipeline: LiveTranslationPipeline
        let transport: TierTranslationTransport
        let brain: RecordingBrain
        let cache: LabelTranslationCache
        /// The real gate, so a scenario about the prompt can close it and a
        /// retry can open it — the same component the tier reads.
        let gate: LiveTranslateConsentGate
    }

    /// A sentence-class string: five words, over the short-form bound the
    /// device is proven on, so the class rule sends it to the cloud first.
    private let askedText = "Members only beyond this point"
    private let answer = "सदस्यहरू मात्र"

    private func item(_ id: String, _ text: String) -> CloudTranslationTier.Item {
        CloudTranslationTier.Item(id: id, text: text, detectedSourceLanguage: "en")
    }

    @MainActor
    private func makeHarness(brainAnswers: [String: String] = [:],
                             focusMaxBatchCalls: Int? = nil,
                             /// The brain's own pacing interval. The config
                             /// this suite builds on is **unpaced**
                             /// (`brainAttemptMinInterval == 0`), which is what
                             /// most scenarios want: a second plan is not
                             /// refused for having run a millisecond after the
                             /// first. A scenario about the *hold* is the one
                             /// that sets a real interval — with zero, a closed
                             /// clock cannot be arranged at all, because
                             /// `0 >= 0` is always an open one.
                             brainAttemptMinInterval: TimeInterval? = nil,
                             unreachable: Bool = false,
                             /// The household's consent state at build time. A
                             /// scenario about the prompt closes it, so the
                             /// ask it raises is a real `awaitingDecision` the
                             /// retry can pick up.
                             consent: Bool = true,
                             now: @escaping () -> Date = Date.init) -> Harness {
        var config = LiveTranslationPipelineTests.unpacedDispatchConfig()
        if let focusMaxBatchCalls { config.focusMaxBatchCalls = focusMaxBatchCalls }
        if let brainAttemptMinInterval { config.brainAttemptMinInterval = brainAttemptMinInterval }
        let bus = LiveTranslateSanitisingBus()
        let storage = LabelTranslationCacheTestStorage()
        let configStore = GeminiConfigStore(storage: storage)
        configStore.save("fake-key")
        let gate = LiveTranslateConsentGate(storage: storage, config: config, observabilityBus: bus)
        if consent { _ = gate.record(granted: true) }
        let governor = GeminiCostGovernor(storage: storage, observabilityBus: bus)
        let cache = LabelTranslationCache(storage: storage,
                                          config: config,
                                          observabilityBus: bus,
                                          dictionary: [:])
        let indicator = CloudActivityIndicatorModel(observabilityBus: bus, config: config)
        let transport = TierTranslationTransport()
        var clientConfig = GeminiClient.Config.default
        // One send per scripted answer: the request count is evidence below.
        clientConfig.maxTransportRetries = 0
        let client = GeminiClient(configStore: configStore,
                                  observabilityBus: bus,
                                  transport: transport,
                                  config: clientConfig,
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
        let brain = RecordingBrain()
        brain.answers = brainAnswers
        brain.attach(events: LiveTranslateEvents(bus: bus, config: config))
        let pipeline = LiveTranslationPipeline(locale: Locale(identifier: "ne_NP"),
                                               recogniser: SilentFrameRecogniser(),
                                               cache: cache,
                                               tier: tier,
                                               cloudNeed: controller,
                                               backpressure: nil,
                                               alwaysShowOriginal: false,
                                               geminiCloudEnabled: true,
                                               reachability: ScriptedNetwork(reachable: !unreachable),
                                               extractionMode: false,
                                               config: config,
                                               observabilityBus: bus,
                                               brain: brain,
                                               now: now,
                                               publish: { _ in })
        return Harness(pipeline: pipeline, transport: transport, brain: brain,
                       cache: cache, gate: gate)
    }

    /// The one answer the scripted transport gives, by wire id.
    @MainActor
    private func respond(_ harness: Harness) {
        let answer = self.answer
        harness.transport.autoRespond = { byID in
            let out = byID.mapValues { _ in answer }
            return String(data: try! JSONSerialization.data(withJSONObject: out),
                          encoding: .utf8)!
        }
    }

    // MARK: - Who leads: the A/B on one string

    @MainActor
    func testACascadeLeadsWithTheCloudForASentenceClassString() async throws {
        let harness = makeHarness()
        respond(harness)

        let settled = await harness.pipeline.resolveFrozen([item("r1", askedText)],
                                                           regionCounts: [:])
        let result = try XCTUnwrap(settled?["r1"])

        XCTAssertEqual(result.sourceTier, .cloud, "the class rule put the cloud in front")
        XCTAssertEqual(result.text, answer)
        XCTAssertEqual(harness.transport.requestCount, 1)
        XCTAssertTrue(harness.brain.calls.isEmpty,
                      "the cascade had no reason to spend a generation on a sentence")
    }

    @MainActor
    func testTheSameStringLeadsWithTheDeviceInAFocusedRead() async throws {
        // The same string, the same composition, the same reachable network —
        // only the entry point differs.
        let harness = makeHarness(brainAnswers: [askedText: answer])

        let settled = await harness.pipeline.resolveFocused([item("r1", askedText)],
                                                            regionCounts: [:])
        let result = try XCTUnwrap(settled?["r1"])

        XCTAssertEqual(result.sourceTier, .onDeviceBrain,
                       "a pointed-at read is answered by the device first, whatever its class")
        XCTAssertEqual(result.text, answer)
        XCTAssertEqual(harness.brain.calls, [[askedText]])
        XCTAssertEqual(harness.transport.requestCount, 0,
                       "with the device leading there is nothing for the network to do")
    }

    @MainActor
    func testTheFocusedModeMovesWhoLeadsAndNeverWhoIsReachable() async throws {
        // A device that cannot answer: the mode still routes onward.
        let harness = makeHarness(brainAnswers: [:])
        respond(harness)

        let settled = await harness.pipeline.resolveFocused([item("r1", askedText)],
                                                            regionCounts: [:])
        let result = try XCTUnwrap(settled?["r1"])

        XCTAssertEqual(result.sourceTier, .cloud,
                       "the device led and could not answer, so the cloud answered — "
                       + "the mode is a routing choice, not an offline switch")
        XCTAssertEqual(result.text, answer)
        XCTAssertEqual(harness.brain.calls, [[askedText]],
                       "the device was asked exactly once, in front")
        XCTAssertEqual(harness.transport.requestCount, 1)
    }

    // Deliberately no scenario here says "the network is down, so nothing is
    // sent". Reachability is the *router's* input — it decides whether the
    // cloud may lead — and not a send gate: an attempt is made and fails at the
    // transport. A test asserting a zero request count for an unreachable
    // scripted network would be pinning a fiction, and this suite's claims are
    // about the mode, not about the radio.

    // MARK: - How much may be spent

    @MainActor
    func testTheFocusBatchCapIsTheConfigsOwnAndZeroReleasesEverything() async throws {
        // The default cap answers. The escape hatch — zero batches — answers
        // nothing and, crucially, *fails* nothing: the region is released for
        // the next capture rather than settled degraded for a reason that is
        // only "we stopped asking".
        let answered = makeHarness(brainAnswers: [askedText: answer])
        let defaultCap = await answered.pipeline.resolveFocused([item("r1", askedText)],
                                                                regionCounts: [:])
        XCTAssertEqual(try XCTUnwrap(defaultCap?["r1"]).sourceTier, .onDeviceBrain,
                       "the shipped cap is enough for one string")
        XCTAssertEqual(answered.brain.calls.count, 1)

        let capped = makeHarness(brainAnswers: [askedText: answer], focusMaxBatchCalls: 0)
        let held = await capped.pipeline.resolveFocused([item("r1", askedText)],
                                                        regionCounts: [:])

        XCTAssertEqual(held?.isEmpty, true,
                       "a plan the cap held answers nothing — an empty result, which is the "
                       + "caller's 'not right now' (see the clock test below)")
        XCTAssertTrue(capped.brain.calls.isEmpty, "no generation was paid")
        XCTAssertEqual(capped.transport.requestCount, 0, "and nothing left the device")
    }

    @MainActor
    func testTheCapDoesNotReachTheCascade() async throws {
        // The cap is the *focused* path's. A live tick and a held frame are
        // bounded by what is on screen and have never needed one, so a config
        // that sets it to zero must not silence them.
        let harness = makeHarness(brainAnswers: [askedText: answer], focusMaxBatchCalls: 0)

        let settled = await harness.pipeline.resolveFrozen([item("r1", askedText)],
                                                           regionCounts: [:])

        XCTAssertEqual(try XCTUnwrap(settled?["r1"]).sourceTier, .onDeviceBrain,
                       "the cascade's budget is not the focused read's")
        XCTAssertEqual(harness.brain.calls, [[askedText]])
    }

    // MARK: - What a capture may write

    /// Review finding 3 — the mode's cache policy reaches **both** spends.
    ///
    /// The device is the tier that answers in both halves of this A/B (it leads
    /// every string in `.focused`, and the cascade falls to it when the cloud
    /// cannot answer), so what the persisted cache holds afterwards is the
    /// mode's doing and nothing else. The brain path wrote unconditionally, and
    /// that is exactly the crop-written-to-disk the `.readOnly` policy exists
    /// to prevent: the tier was told not to store the strings and the pipeline
    /// stored them behind its back.
    @MainActor
    func testAFocusedReadKeepsTheDevicesAnswersOffTheDisk() async throws {
        let focused = makeHarness(brainAnswers: [askedText: answer])
        let focusedSettled = await focused.pipeline.resolveFocused([item("r1", askedText)],
                                                                   regionCounts: [:])
        XCTAssertEqual(try XCTUnwrap(focusedSettled?["r1"]).sourceTier, .onDeviceBrain)
        XCTAssertNothingPersisted(focused, for: askedText)

        let cascade = makeHarness(brainAnswers: [askedText: answer])
        let cascadeSettled = await cascade.pipeline.resolveFrozen([item("r1", askedText)],
                                                                  regionCounts: [:])
        XCTAssertEqual(try XCTUnwrap(cascadeSettled?["r1"]).sourceTier, .onDeviceBrain)
        XCTAssertEqual(persistedTranslation(cascade, for: askedText), answer,
                       "the cascade's device answer is persisted, exactly as it always was")
    }

    /// Review finding 4 — the ask's mode survives the consent prompt.
    ///
    /// A focused capture whose strings reached the prompt is retried when the
    /// elder answers, and the retry rebuilds the request from the recorded ask.
    /// Without the mode it ran as a cascade's — `.persist` where the capture
    /// promised `.readOnly` — so the test's subject is what the persisted layer
    /// holds after the retry answered the string on the cloud.
    ///
    /// The device is not asked a second time here and that is the plan's own
    /// rule, not this scenario's: `brainAttemptedKeys` remembers that the
    /// device already declined these strings for this sighting, so the retry
    /// goes straight to the cloud. Which makes the request count the evidence
    /// that the retry ran at all, and the cache the evidence of the mode.
    @MainActor
    func testTheConsentRetryRunsAFocusedAsksStringsInTheirOwnMode() async throws {
        let harness = makeHarness(brainAnswers: [:], consent: false)

        let held = await harness.pipeline.resolveFocused([item("r1", askedText)],
                                                         regionCounts: ["r1": 1])
        XCTAssertNil(held, "the closed gate held the capture's string")
        XCTAssertEqual(harness.brain.calls.count, 1,
                       "the device was asked, in front, and could not answer")
        XCTAssertEqual(harness.transport.requestCount, 0, "nothing was sent behind a closed gate")

        // The elder has answered the prompt, and the cloud can answer now.
        _ = harness.gate.record(granted: true)
        respond(harness)

        await harness.pipeline.retryAwaitingResolution()

        XCTAssertEqual(harness.transport.requestCount, 1,
                       "the retry ran the ask's plan and reached the network — the "
                       + "assertion below is not about a retry that never ran")
        XCTAssertNothingPersisted(harness, for: askedText)
    }

    // MARK: - The ledger after a sighting

    /// Review finding 5 — a focused settlement is a *sighting's*, and the next
    /// sighting may drop it.
    ///
    /// The plan that answers a capture does not hold its keys for a frame
    /// (`holdsAnswers: false`): there is no still to keep them for, and a
    /// frozen epoch on a plan that never freezes the picture would put them
    /// behind a release that only a thaw can reach — the keys would outlive
    /// every sighting, and a degraded answer would come back as the same
    /// degraded answer for the rest of the session. So `reconcile` prunes them
    /// like any other sighting's, and the string is asked about again.
    @MainActor
    func testAFocusedSettlementIsPrunedWithTheSightingThatProducedIt() async throws {
        let harness = makeHarness(brainAnswers: [askedText: answer])
        let first = await harness.pipeline.resolveFocused([item("r1", askedText)],
                                                          regionCounts: [:])
        XCTAssertEqual(try XCTUnwrap(first?["r1"]).sourceTier, .onDeviceBrain)
        XCTAssertEqual(harness.brain.calls.count, 1)

        // The string leaves the picture: a pass that finds nothing prunes every
        // settlement no held frame owns.
        let frame = try makeFrame()
        await harness.pipeline.ingest(frame)
        await harness.pipeline.ingest(frame)

        // The device can no longer answer it, and nothing is scripted for the
        // cloud: a plan that answered from the ledger would answer anyway, and
        // one that asks again has to send.
        harness.brain.answers = [:]
        let second = await harness.pipeline.resolveFocused([item("r1", askedText)],
                                                           regionCounts: [:])

        XCTAssertEqual(harness.brain.calls.count, 2,
                       "the pruned key is askable again — a held key would have been "
                       + "answered from the ledger without a second ask")
        XCTAssertEqual(harness.transport.requestCount, 1,
                       "and with the ledger empty the string reached the network")
        XCTAssertNotNil(second, "the region is settled either way, not left pending")
    }

    // MARK: - How much may be spent

    /// Review finding 10 — the cap is the mode's structural maximum, so it must
    /// be a number the mode can actually reach.
    ///
    /// `.focused` puts the device in front of every string, so the cloud-first
    /// stage has nothing to spend: exactly two stages can reach a batch — the
    /// device and the cloud behind it — and the shipped cap of two is therefore
    /// *binding*, which is what makes the knob a knob. One is the narrowing it
    /// now declares: a capture that may spend a single batch is a device-only
    /// capture, and its strings are released unclaimed rather than settled
    /// degraded for having been cut off.
    @MainActor
    func testTheShippedCapIsExactlyEnoughAndOneNarrowsToTheDeviceOnly() async throws {
        let answered = makeHarness(brainAnswers: [:])
        respond(answered)
        let full = await answered.pipeline.resolveFocused([item("r1", askedText)],
                                                          regionCounts: [:])

        XCTAssertEqual(try XCTUnwrap(full?["r1"]).sourceTier, .cloud,
                       "two batches: the device, then the cloud behind it")
        XCTAssertEqual(answered.brain.calls.count, 1)
        XCTAssertEqual(answered.transport.requestCount, 1)

        let narrowed = makeHarness(brainAnswers: [:], focusMaxBatchCalls: 1)
        respond(narrowed)
        let held = await narrowed.pipeline.resolveFocused([item("r1", askedText)],
                                                          regionCounts: [:])

        XCTAssertEqual(narrowed.brain.calls.count, 1, "the device's one batch was spent")
        XCTAssertEqual(narrowed.transport.requestCount, 0, "the cloud's batch was the one held back")
        XCTAssertEqual(held?.isEmpty, true,
                       "a plan the cap held answers nothing and settles nothing")
    }

    /// **"Nothing" is two different answers, and the caller that waits has to
    /// tell them apart** (Workstream B, the clock hold).
    ///
    /// A plan whose every string was *released* — the clock held them, or the
    /// capture's cap did — has told its caller "not right now", and the only
    /// useful thing to do with that is wait for the clock and ask again. A plan
    /// the elder is being *asked about* has said the opposite: the answer is
    /// coming, so there is nothing to wait for and nothing to defer. Both plans
    /// answer nothing, and while the two were one `nil` a focused read whose
    /// single string the clock held looked exactly like an open prompt — the
    /// session deferred nothing, waited for nothing, and the card said
    /// "translating…" for the rest of the picture's life. That was the stall the
    /// hold exists to end, so the two are separate results here: an empty
    /// dictionary for a release, `nil` for a question.
    @MainActor
    func testAPlanTheClockHeldIsAnEmptyResultAndAnOpenPromptIsNil() async throws {
        // One date for the whole scenario: the interval the plan was told about
        // never elapses, so "the clock is closed" is a fact of the fixture
        // rather than of how long the test took.
        let frozen = Date(timeIntervalSinceReferenceDate: 0)
        let clocked = makeHarness(brainAnswers: [askedText: answer],
                                  brainAttemptMinInterval: 30,
                                  unreachable: true,
                                  now: { frozen })
        // A plan pays for a generation, and paying is what stamps the clock.
        let settled = await clocked.pipeline.resolveFrozen([item("r1", askedText)],
                                                           regionCounts: [:])
        XCTAssertEqual(try XCTUnwrap(settled?["r1"]).sourceTier, .onDeviceBrain,
                       "the device answered, which is what it costs to stamp the clock")
        XCTAssertEqual(clocked.brain.calls.count, 1)

        // A *different* string, so nothing about this read was already asked
        // for: the clock is the only thing that can release it.
        let held = await clocked.pipeline.resolveFocused([item("r2", askedText)],
                                                         regionCounts: [:])
        XCTAssertEqual(held?.isEmpty, true,
                       "a plan the clock held answers nothing — and says so by answering "
                       + "nothing, rather than by looking like a question")
        XCTAssertEqual(clocked.brain.calls.count, 1, "and pays for nothing")

        // The prompt, the other way to answer nothing: the household has not
        // consented, so the gate raises the elder's question over this string.
        let prompted = makeHarness(brainAnswers: [:], consent: false)
        let asked = await prompted.pipeline.resolveFocused([item("r1", askedText)],
                                                           regionCounts: [:])
        XCTAssertNil(asked,
                     "the elder is being asked: nothing may be applied, and nothing is "
                     + "deferred — the answer is coming, so there is nothing to wait for")
    }

    // MARK: - The persisted layer, read

    @MainActor
    private func persistedTranslation(_ harness: Harness,
                                      for text: String,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) -> String? {
        switch harness.cache.lookup(text: text,
                                    targetLanguage: LiveTranslationPipeline.defaultTargetLanguage) {
        case .success(let hit):
            return hit?.translation
        case .failure(let error):
            XCTFail("the persisted lookup failed: \(error)", file: file, line: line)
            return nil
        }
    }

    @MainActor
    private func XCTAssertNothingPersisted(_ harness: Harness,
                                           for text: String,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        switch harness.cache.lookup(text: text,
                                    targetLanguage: LiveTranslationPipeline.defaultTargetLanguage) {
        case .success(let hit):
            XCTAssertNil(hit,
                         "the persisted cache must not hold this string",
                         file: file, line: line)
        case .failure(let error):
            XCTFail("the persisted lookup failed: \(error)", file: file, line: line)
        }
    }

    private func makeFrame(width: Int = 640, height: Int = 480, pts: Int = 1) throws -> CameraFrame {
        let buffer = try SampleBufferFactory.make(width: width, height: height,
                                                  pts: CMTime(value: CMTimeValue(pts), timescale: 30))
        return try XCTUnwrap(CameraFrame(sampleBuffer: buffer))
    }

    // MARK: - The mode's own shape

    func testTheCascadeIsTheDefaultEverywhereAndTheModesAreTwo() {
        // The default is what keeps every caller that predates the mode on the
        // plan it shipped with — a live tick, a held frame, the prompt's retry
        // and the snapshot path are byte-for-byte what they were.
        XCTAssertEqual(TranslationMode.allCases, [.cascade, .focused])
        XCTAssertEqual(TranslationMode(rawValue: "cascade"), .cascade)
        XCTAssertEqual(TranslationMode(rawValue: "focused"), .focused)
        // Review finding 10: the cap is the mode's *structural* maximum, not a
        // round number above it. In `.focused` the device leads every string,
        // so the cloud-first stage has nothing to spend and exactly two stages
        // can reach `spendABatch()` — a cap of three could never bind, and a
        // knob that cannot bind is a knob nobody can turn.
        XCTAssertEqual(LiveTranslateConfig.default.focusMaxBatchCalls, 2)
        XCTAssertEqual(TranslationMode.cascade.cachePolicy, .persist)
        XCTAssertEqual(TranslationMode.focused.cachePolicy, .readOnly)
    }
}
