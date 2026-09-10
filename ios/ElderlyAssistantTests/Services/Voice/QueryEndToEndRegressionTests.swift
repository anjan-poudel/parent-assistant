import XCTest
@testable import ElderlyAssistant

/// [QUERY-FIX] end-to-end regression suite (2026-09-06), updated for
/// [NO-GIBBERISH] (2026-09-07).
///
/// Replays the exact device failure chain that motivated the fix. On the
/// device, the Nepali weather question "भोलिको मौसम कस्तो छ?" transcribed
/// CORRECTLY, the LLaMA interpreter reported `inference_done` success, and
/// the router then spoke the generic apology (router.reprompt). Root cause:
/// the formatted prompt measured 2,361 tokens against a 1,024-token context
/// (`LLM(from:maxTokenCount: 1024)`), the runtime finished with an EMPTY
/// completion that was reported as success, `parse("")` returned nil, and
/// every utterance fell through to `command_unrecognised`.
///
/// [NO-GIBBERISH] change (2026-09-07): the weather transcript is now a
/// deterministic TOPIC PRE-ANSWER (`TopicPreAnswer`) — it never reaches
/// the brain at all, so the model-path assertions below exercise a NEUTRAL
/// open question (`openQuestionTranscript`) instead, and a dedicated test
/// pins the weather pre-answer behavior end-to-end.
///
/// These tests drive the REAL production chain — `CommandRouter` →
/// `IntentRouter` (with a real cache) → `LocalBrainChain` → the real
/// `LlamaCommandInterpreter` — with the llama.cpp call replaced by
/// `generateOverride` (the same seam `LocalIntentInterpreter` already had),
/// plus the Gemini cloud path against a stubbed transport. They pin the
/// STRUCTURED-RESPONSE CONTRACT: the brain answers with JSON carrying
/// `intent` + an always-non-empty `response` (for a query, the actual
/// answer), and the router SPEAKS that response via
/// `noteGenericReply` + `speak` — never the apology.
final class QueryEndToEndRegressionTests: XCTestCase {

    private var tmpRoot: URL!
    private var store: ModelStore!
    private var bus: RecordingObservabilityBus!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("query-e2e-\(UUID().uuidString)")
        store = try ModelStore(observabilityBus: MockObservabilityBus(),
                               rootDirectoryOverride: tmpRoot)
        bus = RecordingObservabilityBus()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    // MARK: - Recording doubles

    private final class RecordingSpeaker: Speaker {
        private let lock = NSLock()
        private(set) var texts: [String] = []
        func speak(_ text: String, locale: Locale) async {
            lock.lock(); texts.append(text); lock.unlock()
        }
        func cancel() {}
        var spoken: [String] {
            lock.lock(); defer { lock.unlock() }
            return texts
        }
    }

    /// The production-shaped wiring under test, with all doubles kept
    /// strongly referenced here (CommandRouter holds its coordinator
    /// weakly).
    private final class Harness {
        let coordinator = StubCoordinator()
        let speaker = RecordingSpeaker()
        let router: CommandRouter

        init(interpreter: CommandInterpreter, bus: RecordingObservabilityBus) {
            router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: speaker,
                                   interpreter: interpreter)
        }
    }

    private func makeLocalHarness(overrideJSON: String) -> Harness {
        // Preferred brain (fine-tuned intent model) is NOT cached in this
        // empty store, so the chain consults the stand-in — exactly the
        // configuration the device was in when the bug was logged.
        let standIn = LlamaCommandInterpreter(modelStore: store,
                                              observabilityBus: bus)
        standIn.generateOverride = { _, _ in overrideJSON }
        let preferred = LocalIntentInterpreter(modelStore: store,
                                               observabilityBus: bus)
        let chain = LocalBrainChain(preferred: preferred, standIn: standIn)

        let cache = IntentCommandCache(storage: StubEncryptedStorage())
        let intentRouter = IntentRouter(cache: cache,
                                        observabilityBus: bus,
                                        config: .default)
        intentRouter.localBrain = chain
        intentRouter.cloudEnabled = false   // on-device stack: no cloud
        return Harness(interpreter: intentRouter, bus: bus)
    }

    /// Waits until `condition` is true, pumping the main run loop (the
    /// whole interpreter chain completes on the main queue).
    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let e = expectation(description: "waitUntil")
        var poll: (() -> Void)!
        poll = {
            if condition() { e.fulfill(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        DispatchQueue.main.async(execute: poll)
        wait(for: [e], timeout: timeout)
    }

    /// The exact device utterance — now a deterministic TOPIC PRE-ANSWER
    /// (weather), see the dedicated test below.
    private let weatherTranscript = "भोलिको मौसम कस्तो छ?"

    /// A neutral open question with NO topic keywords — the transcript the
    /// model-path tests exercise since the weather question no longer
    /// reaches the brain.
    private let openQuestionTranscript = "के छ खबर?"

    /// The canonical contract answer a well-behaved brain returns for an
    /// open question (real, spoken, Nepali — the router must speak it).
    private let modelAnswer = "तपाईंका लागि केही राम्रा कुरा छन्।"

    private func canonicalQueryJSON(response: String, confidence: Double = 0.9) -> String {
        """
        {"intent":"query","response":"\(response)","confidence":\(confidence),"actionType":null,"actionUrl":null}
        """
    }

    private func repromptText() -> String {
        L10n.str("router.reprompt", locale: Locale(identifier: "ne-NP"))
    }

    /// [VOICE-ACK] The pre-ack committed on the LLM round-trip — spoken
    /// before every model reply or honest fallback in these end-to-end
    /// pins.
    private func preAckText() -> String {
        L10n.str("voiceAck.moment1", locale: Locale(identifier: "ne-NP"))
    }

    // MARK: - The device repro, fixed (model path, neutral question)

    func testOpenQuestionYieldsSpokenAnswerNotApologyEndToEnd() {
        // The canonical structured response: intent=query with a NON-EMPTY
        // response. The router must speak the response
        // (noteGenericReply + speak) — NOT the generic "माफ गर्नुहोस्"
        // apology, and NOT command_unrecognised.
        let harness = makeLocalHarness(
            overrideJSON: canonicalQueryJSON(response: modelAnswer))

        harness.router.route(transcript: openQuestionTranscript)

        waitUntil { harness.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(harness.coordinator.genericReplies, [modelAnswer],
                       "the query answer must reach the visible reply channel")
        waitUntil { harness.speaker.spoken.count == 2 }
        XCTAssertEqual(harness.speaker.spoken, [preAckText(), modelAnswer],
                       "the query answer must be SPOKEN — never the apology")

        XCTAssertTrue(bus.contains("command_dispatched_to_llm"))
        XCTAssertTrue(bus.contains("command_llm_query"))
        XCTAssertFalse(bus.contains("command_unrecognised"),
                       "a parseable structured answer must never hit command_unrecognised")
        XCTAssertTrue(bus.contains("inference_done"))
    }

    func testLegacyWireShapeFromFineTunedBrainStillSpokenEndToEnd() {
        // The grammar-constrained fine-tuned local brain
        // (LocalIntentInterpreter.intentSchema) still emits the LEGACY
        // shape (action/reply). The tolerant parse must keep that path
        // speakable too — this is the designed primary brain.
        let harness = makeLocalHarness(overrideJSON: """
        {"action":"query","entryId":null,"contact":null,"time":null,"medication":null,"message":null,"callType":null,"requestedApp":null,"confidence":0.9,"reply":"\(modelAnswer)"}
        """)

        harness.router.route(transcript: openQuestionTranscript)

        waitUntil { harness.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(harness.coordinator.genericReplies, [modelAnswer])
        XCTAssertFalse(bus.contains("command_unrecognised"))
    }

    func testEmptySpokenResponseIsNeverDispatchedSilently() {
        // Contract enforcement at the router level: a brain that answers
        // with an EMPTY response must NOT be dispatched (speaking nothing
        // is a silent dead-end). The router falls back to the honest
        // re-prompt instead.
        let harness = makeLocalHarness(
            overrideJSON: canonicalQueryJSON(response: ""))

        harness.router.route(transcript: openQuestionTranscript)

        waitUntil { self.bus.contains("command_unrecognised") }
        XCTAssertTrue(bus.contains("command_unrecognised"))
        XCTAssertFalse(bus.contains("command_llm_query"),
                       "an empty-response interpretation must never dispatch")
        XCTAssertTrue(harness.coordinator.genericReplies.isEmpty,
                      "an empty-response command must not reach noteGenericReply")
        waitUntil { harness.speaker.spoken.count == 2 }
        XCTAssertEqual(harness.speaker.spoken, [preAckText(), repromptText()],
                       "the honest re-prompt is spoken — never silence")
    }

    func testEmptyInferenceOutputIsObservedAndFallsBackToHonestReprompt() {
        // The device's exact pre-fix failure shape: inference returns an
        // EMPTY completion. Pre-fix it was logged as inference_done
        // success and every utterance fell to the apology. Post-fix the
        // empty output is an observable failure (inference_empty_output)
        // and the router speaks the honest re-prompt — an overflow can
        // never masquerade as a successful (empty) inference again.
        let harness = makeLocalHarness(overrideJSON: "")

        harness.router.route(transcript: openQuestionTranscript)

        waitUntil { self.bus.contains("inference_empty_output") }
        XCTAssertTrue(bus.contains("inference_empty_output"),
                      "the overflow failure shape must be observable")
        XCTAssertFalse(bus.contains("inference_done"),
                       "an empty completion must never report success")
        XCTAssertTrue(bus.contains("command_unrecognised"))
        waitUntil { harness.speaker.spoken.count == 2 }
        XCTAssertEqual(harness.speaker.spoken, [preAckText(), repromptText()])
    }

    // MARK: - [NO-GIBBERISH] weather pre-answer intercepts before the brain

    func testWeatherQuestionYieldsDeterministicPreAnswerNotTheModel() {
        // [NO-GIBBERISH] (2026-09-07) The exact device utterance is now a
        // deterministic TOPIC PRE-ANSWER: "भोलिको मौसम कस्तो छ?" must get
        // the honest pre-written weather reply — even with a brain whose
        // seam would return EMPTY output (proving the brain is never
        // consulted: no empty-output failure, no dispatch event, no
        // inference event).
        let harness = makeLocalHarness(overrideJSON: "")

        harness.router.route(transcript: weatherTranscript)

        waitUntil { !harness.coordinator.genericReplies.isEmpty }
        let expected = L10n.str("topic.weather.unavailable",
                                locale: Locale(identifier: "ne-NP"))
        XCTAssertEqual(harness.coordinator.genericReplies, [expected],
                       "the weather pre-answer must reach the visible reply channel")
        waitUntil { !harness.speaker.spoken.isEmpty }
        XCTAssertEqual(harness.speaker.spoken, [expected],
                       "the weather pre-answer must be SPOKEN — honest, never gibberish")

        XCTAssertTrue(bus.contains("topic_pre_answer"),
                      "the deterministic answer must be observable as a pre-answer")
        XCTAssertFalse(bus.contains("command_dispatched_to_llm"),
                       "a topic pre-answer must never consult the brain")
        XCTAssertFalse(bus.contains("inference_empty_output"))
        XCTAssertFalse(bus.contains("command_unrecognised"))
    }

    // MARK: - Gemini (cloud) path — same contract, stubbed transport

    private func makeGeminiHarness(json: String) -> Harness {
        let configStore = GeminiConfigStore(storage: GeminiInMemoryStorage())
        configStore.save("fake-key")
        let transport = FakeGeminiTransport()
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: json))
        let client = GeminiClient(configStore: configStore,
                                  observabilityBus: MockObservabilityBus(),
                                  transport: transport)
        let gemini = GeminiCommandInterpreter(client: client,
                                              observabilityBus: bus)
        return Harness(interpreter: gemini, bus: bus)
    }

    func testGeminiCanonicalQueryAnswerSpokenEndToEnd() {
        // The Gemini interpreter consumes the SAME shared
        // IntentPrompt.build + LlamaCommandInterpreter.parse, so a
        // canonical query answer from the stubbed API must be spoken, not
        // reprompted.
        let harness = makeGeminiHarness(
            json: canonicalQueryJSON(response: modelAnswer, confidence: 0.95))

        harness.router.route(transcript: openQuestionTranscript)

        waitUntil { harness.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(harness.coordinator.genericReplies, [modelAnswer])
        XCTAssertFalse(bus.contains("command_unrecognised"))
        XCTAssertTrue(bus.contains("command_llm_query"))
    }

    func testGeminiEmptyResponseNeverDispatchedSilently() {
        // Same empty-response enforcement on the cloud path: never speak
        // nothing, never dispatch a reply-less command.
        let harness = makeGeminiHarness(
            json: canonicalQueryJSON(response: "", confidence: 0.95))

        harness.router.route(transcript: openQuestionTranscript)

        waitUntil { self.bus.contains("command_unrecognised") }
        XCTAssertFalse(bus.contains("command_llm_query"))
        waitUntil { harness.speaker.spoken.count == 2 }
        XCTAssertEqual(harness.speaker.spoken, [preAckText(), repromptText()])
    }
}
