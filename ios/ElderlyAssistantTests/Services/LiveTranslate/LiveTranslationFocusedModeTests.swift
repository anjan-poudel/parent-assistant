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
                             unreachable: Bool = false,
                             now: @escaping () -> Date = Date.init) -> Harness {
        var config = LiveTranslationPipelineTests.unpacedDispatchConfig()
        if let focusMaxBatchCalls { config.focusMaxBatchCalls = focusMaxBatchCalls }
        let bus = LiveTranslateSanitisingBus()
        let storage = LabelTranslationCacheTestStorage()
        let configStore = GeminiConfigStore(storage: storage)
        configStore.save("fake-key")
        let gate = LiveTranslateConsentGate(storage: storage, config: config, observabilityBus: bus)
        _ = gate.record(granted: true)
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
        return Harness(pipeline: pipeline, transport: transport, brain: brain, cache: cache)
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
                                                            mode: .focused,
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
                                                            mode: .focused,
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
                                                                mode: .focused,
                                                                regionCounts: [:])
        XCTAssertEqual(try XCTUnwrap(defaultCap?["r1"]).sourceTier, .onDeviceBrain,
                       "the shipped cap of three batches is enough for one string")
        XCTAssertEqual(answered.brain.calls.count, 1)

        let capped = makeHarness(brainAnswers: [askedText: answer], focusMaxBatchCalls: 0)
        let held = await capped.pipeline.resolveFocused([item("r1", askedText)],
                                                        mode: .focused,
                                                        regionCounts: [:])

        XCTAssertNil(held, "a plan the cap held answers nothing")
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

    // MARK: - The mode's own shape

    func testTheCascadeIsTheDefaultEverywhereAndTheModesAreTwo() {
        // The default is what keeps every caller that predates the mode on the
        // plan it shipped with — a live tick, a held frame, the prompt's retry
        // and the snapshot path are byte-for-byte what they were.
        XCTAssertEqual(TranslationMode.allCases, [.cascade, .focused])
        XCTAssertEqual(TranslationMode(rawValue: "cascade"), .cascade)
        XCTAssertEqual(TranslationMode(rawValue: "focused"), .focused)
        XCTAssertEqual(LiveTranslateConfig.default.focusMaxBatchCalls, 3)
    }
}
