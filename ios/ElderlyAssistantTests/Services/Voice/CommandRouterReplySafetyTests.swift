import XCTest
@testable import ElderlyAssistant

/// [NO-GIBBERISH] (2026-09-07) Router-level integration for the two
/// deterministic safeguards on the voice reply path:
///
///  (1) TOPIC PRE-ANSWERS — the weather/time/date/greeting table runs
///      after the emergency/med-ack safety net and before any model, so
///      "भोलिको मौसम कस्तो छ?" gets the honest pre-written answer even
///      while the brain is downloading — and NEVER gets shadowed by (or
///      itself shadows) a safety-critical utterance: emergency, med-ack
///      and call-ish utterances keep their existing routes.
///
///  (2) THE REPLY SANITY GATE — model-generated text (.query/.none
///      replies, guide steps, send-message acks, ack overrides) is spoken
///      ONLY when it passes `ReplySanityGate`; a rejection emits
///      `llama_response_rejected_sanity` with the machine-readable reason
///      as `errorCode` and the HONEST localized fallback is delivered
///      instead. The raw garbage text never reaches the speaker or the
///      visible card.
final class CommandRouterReplySafetyTests: XCTestCase {

    // MARK: - Doubles

    private final class RecordingSpeaker: Speaker {
        private let lock = NSLock()
        private var texts: [String] = []
        func speak(_ text: String, locale: Locale) async {
            lock.lock(); texts.append(text); lock.unlock()
        }
        func cancel() {}
        var spoken: [String] {
            lock.lock(); defer { lock.unlock() }
            return texts
        }
    }

    /// Records FULL events (eventType + errorCode + metadata) — needed to
    /// pin the rejection reason on `llama_response_rejected_sanity`.
    private final class FullRecordBus: ObservabilityBus {
        private(set) var events: [ObservabilityEvent] = []
        func emit(_ event: ObservabilityEvent) { events.append(event) }
        func events(named type: String) -> [ObservabilityEvent] {
            events.filter { $0.eventType == type }
        }
        func contains(_ type: String) -> Bool {
            events.contains { $0.eventType == type }
        }
        var errorCodes: [String] {
            events.compactMap { $0.errorCode }
        }
    }

    private final class Harness {
        let coordinator = StubCoordinator()
        let speaker = RecordingSpeaker()
        let bus = FullRecordBus()
        let router: CommandRouter
        let interpreter: StubCommandInterpreter

        init(result: InterpretedCommand?, available: Bool = true) {
            interpreter = StubCommandInterpreter(available: available, result: result)
            router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: speaker,
                                   interpreter: interpreter)
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let e = expectation(description: "waitUntil")
        var poll: (() -> Void)!
        poll = {
            if condition() { e.fulfill(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        DispatchQueue.main.async(execute: poll)
        wait(for: [e], timeout: 5)
    }

    private func text(_ key: String) -> String {
        L10n.str(key, locale: Locale(identifier: "ne-NP"))
    }

    /// A stub brain that would answer the weather question with garbage —
    /// used to prove the pre-answer wins WITHOUT consulting the brain.
    private func gibberishBrainResult() -> InterpretedCommand {
        makeCommand(action: .query, confidence: 0.99, reply: "\"मौसम\" {ठीक छ}")
    }

    /// `makeCommand` has no `message` slot — build send_message commands
    /// explicitly.
    private func messageCommand(message: String, reply: String) -> InterpretedCommand {
        InterpretedCommand(action: .sendMessage,
                           entryId: nil,
                           contact: "छोरा",
                           time: nil,
                           medication: nil,
                           message: message,
                           callType: nil,
                           requestedApp: nil,
                           topic: nil,
                           steps: nil,
                           confidence: 0.9,
                           reply: reply)
    }

    // MARK: - Topic pre-answers intercept before the interpreter

    func testWeatherQuestionYieldsPreAnswerNeverTheModel() {
        let h = Harness(result: gibberishBrainResult())

        let result = h.router.route(transcript: "भोलिको मौसम कस्तो छ?")

        XCTAssertEqual(result, .unrecognised(transcript: "भोलिको मौसम कस्तो छ?"))
        XCTAssertEqual(h.interpreter.callCount, 0,
                       "a topic pre-answer must never consult the interpreter")
        let expected = text("topic.weather.unavailable")
        XCTAssertEqual(h.coordinator.genericReplies, [expected],
                       "the pre-answer must be the visible reply — never model text")
        waitUntil { !h.speaker.spoken.isEmpty }
        XCTAssertEqual(h.speaker.spoken, [expected],
                       "the honest weather answer must be spoken")
        XCTAssertTrue(h.bus.contains("topic_pre_answer"))
        XCTAssertFalse(h.bus.contains("command_dispatched_to_llm"))
        XCTAssertFalse(h.bus.contains("llama_response_rejected_sanity"),
                       "no model text was ever produced, so nothing to reject")
    }

    func testWeatherPreAnswerWorksWhileBrainIsDownloading() {
        // Pre-answers run before the interpreter-availability check — the
        // weather question must get its answer even with NO brain yet,
        // and must NOT fall into the no-brain "downloading" speech.
        let h = Harness(result: nil, available: false)
        h.coordinator.brainReadiness = .downloadingBrain

        let result = h.router.route(transcript: "पानी पर्छ कि पर्दैन?")

        XCTAssertEqual(result, .unrecognised(transcript: "पानी पर्छ कि पर्दैन?"))
        let expected = text("topic.weather.unavailable")
        XCTAssertEqual(h.coordinator.genericReplies, [expected])
        waitUntil { !h.speaker.spoken.isEmpty }
        XCTAssertEqual(h.speaker.spoken, [expected])
        XCTAssertFalse(h.bus.contains("command_unrecognised"))
        XCTAssertTrue(h.bus.contains("topic_pre_answer"))
    }

    func testTimeQuestionYieldsClockBackedPreAnswer() {
        let h = Harness(result: gibberishBrainResult())
        // Seam the router's clock; the sentence itself is pinned in
        // TopicPreAnswerTests — here we pin the plumbing: the router's
        // clock feeds the table, the answer is carded + spoken, the
        // brain stays untouched. (Time zone is the host's, so the
        // expected text is computed the same way the router does.)
        let fixed = Date(timeIntervalSince1970: 1_752_854_400)   // deterministic instant
        h.router.clock = { fixed }
        let expected = TopicPreAnswer.reply(for: .time, locale: Locale(identifier: "ne-NP"),
                                            now: fixed, timeZone: .current)

        // "अहिले कति बजेको छ?" — NOT "कति बजे भयो?": "भयो" is a
        // whole-token med-ack keyword, and the deterministic safety net
        // correctly outranks the topic table.
        _ = h.router.route(transcript: "अहिले कति बजेको छ?")

        XCTAssertEqual(h.interpreter.callCount, 0)
        XCTAssertEqual(h.coordinator.genericReplies, [expected])
        waitUntil { !h.speaker.spoken.isEmpty }
        XCTAssertEqual(h.speaker.spoken, [expected])
        let topicEvents = h.bus.events(named: "topic_pre_answer")
        XCTAssertEqual(topicEvents.first?.metadata["topic"], "time")
    }

    func testGreetingPreAnswerResolvesInActiveLocale() {
        let h = Harness(result: gibberishBrainResult())
        h.coordinator.activeLocale = Locale(identifier: "en-US")

        _ = h.router.route(transcript: "hello")

        let expected = L10n.str("topic.greeting", locale: Locale(identifier: "en-US"))
        XCTAssertEqual(h.coordinator.genericReplies, [expected])
        waitUntil { !h.speaker.spoken.isEmpty }
        XCTAssertEqual(h.speaker.spoken, [expected])
        XCTAssertEqual(h.bus.events(named: "topic_pre_answer").first?.metadata["topic"], "greeting")
    }

    // MARK: - Safety-critical utterances are never shadowed by pre-answers

    func testEmergencyKeywordStillOutranksAWeatherPreAnswer() {
        let h = Harness(result: gibberishBrainResult())

        let result = h.router.route(transcript: "मद्दत गर्नुहोस्, मौसम कस्तो छ भन्नुस्")

        XCTAssertEqual(result, .emergencyTriggered)
        XCTAssertEqual(h.interpreter.callCount, 0)
        XCTAssertFalse(h.bus.contains("topic_pre_answer"),
                       "emergency must not be replaced by a weather answer")
        XCTAssertTrue(h.bus.contains("command_emergency_keyword"))
        waitUntil { !h.speaker.spoken.isEmpty }
        XCTAssertEqual(h.speaker.spoken, [text("router.emergencyAck")],
                       "the emergency acknowledgement is spoken — never a weather answer")
    }

    func testMedAckStillRunsAheadOfATopicPreAnswer() {
        let h = Harness(result: gibberishBrainResult())
        let entryId = UUID()
        h.coordinator.pendingEntryId = entryId

        let result = h.router.route(transcript: "औषधि खाएँ, अब मौसम हेर्न मन छ")

        XCTAssertEqual(result, .acknowledgedMedication)
        XCTAssertEqual(h.coordinator.challengeIssuedFor, entryId,
                       "the dementia challenge must issue — the ack path wins")
        XCTAssertFalse(h.bus.contains("topic_pre_answer"))
        XCTAssertEqual(h.interpreter.callCount, 0)
    }

    func testCallishUtteranceWithTopicWordIsBlockedNotPreAnswered() {
        // "मौसम बताउनेलाई फोन गर" (call the one who tells the weather):
        // call-ish → the sensitive-call guard excludes it from the topic
        // table, the interpreter abstains, and the existing BLOCK runs —
        // a pre-answer must never shadow the call intent.
        let h = Harness(result: nil)

        // The interpreter path is asynchronous — the synchronous return
        // is .unrecognised (as with every LLM dispatch); the BLOCK lands
        // in the interpret completion.
        let result = h.router.route(transcript: "मौसम बताउनेलाई फोन गर")

        waitUntil { h.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(result, .unrecognised(transcript: "मौसम बताउनेलाई फोन गर"))
        XCTAssertEqual(h.interpreter.callCount, 1)
        XCTAssertEqual(h.coordinator.genericReplies, [text("router.sensitiveBlocked")])
        XCTAssertFalse(h.bus.contains("topic_pre_answer"))
        XCTAssertTrue(h.bus.contains("command_sensitive_blocked_auth_unavailable"))
    }

    // MARK: - Reply sanity gate: garbage model text never reaches the ear

    func testJSONRemnantQueryReplyFallsBackToHonestMessage() {
        let h = Harness(result: makeCommand(action: .query, confidence: 0.95,
                                            reply: "सबै ठीक {\"nested\": \"json\"} छ"))

        _ = h.router.route(transcript: "के छ खबर?")

        waitUntil { h.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(h.coordinator.genericReplies, [text("router.modelReplyUnclear")],
                       "the honest fallback is carded — never the garbage")
        waitUntil { !h.speaker.spoken.isEmpty }
        XCTAssertEqual(h.speaker.spoken, [text("router.modelReplyUnclear")],
                       "the honest fallback is spoken — never the garbage")
        let rejections = h.bus.events(named: "llama_response_rejected_sanity")
        XCTAssertEqual(rejections.count, 1)
        XCTAssertEqual(rejections.first?.errorCode, "jsonRemnant")
        XCTAssertFalse(h.speaker.spoken.contains("nested"),
                       "raw model text must never reach the speaker")
        XCTAssertFalse(h.coordinator.genericReplies.contains { $0.contains("nested") },
                       "raw model text must never reach the visible card")
    }

    func testRepetitionLoopQueryReplyFallsBackToHonestMessage() {
        let h = Harness(result: makeCommand(action: .query, confidence: 0.95,
                                            reply: "यो यो यो यो जवाफ हो"))

        _ = h.router.route(transcript: "के छ खबर?")

        waitUntil { h.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(h.coordinator.genericReplies, [text("router.modelReplyUnclear")])
        waitUntil { !h.speaker.spoken.isEmpty }
        XCTAssertEqual(h.speaker.spoken, [text("router.modelReplyUnclear")])
        XCTAssertEqual(h.bus.events(named: "llama_response_rejected_sanity").first?.errorCode,
                       "repetition")
    }

    func testSymbolSoupQueryReplyFallsBackToHonestMessage() {
        let h = Harness(result: makeCommand(action: .query, confidence: 0.95,
                                            reply: "9:30 12.5% 4 5 6"))

        _ = h.router.route(transcript: "के छ खबर?")

        waitUntil { h.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(h.coordinator.genericReplies, [text("router.modelReplyUnclear")])
        XCTAssertEqual(h.bus.events(named: "llama_response_rejected_sanity").first?.errorCode,
                       "nonLanguage")
    }

    func testEmptyQueryReplyFallsBackToHonestMessage() {
        let h = Harness(result: makeCommand(action: .query, confidence: 0.95, reply: "  "))

        _ = h.router.route(transcript: "के छ खबर?")

        waitUntil { h.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(h.coordinator.genericReplies, [text("router.modelReplyUnclear")])
        XCTAssertEqual(h.bus.events(named: "llama_response_rejected_sanity").first?.errorCode,
                       "empty")
    }

    func testCleanQueryReplyStillSpokenRaw() {
        let answer = "काठमाडौंमा आज दिनभरि घाम लाग्नेछ।"
        let h = Harness(result: makeCommand(action: .query, confidence: 0.95, reply: answer))

        _ = h.router.route(transcript: "के छ खबर?")

        waitUntil { h.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(h.coordinator.genericReplies, [answer])
        waitUntil { !h.speaker.spoken.isEmpty }
        XCTAssertEqual(h.speaker.spoken, [answer])
        XCTAssertFalse(h.bus.contains("llama_response_rejected_sanity"),
                       "valid text must pass the gate untouched")
    }

    // MARK: - Gating at the other model-text speech sites

    func testGuideStepsGarbageFallBacksToHonestMessage() {
        let garbageSteps = InterpretedCommand(
            action: .guide, entryId: nil, contact: nil, time: nil,
            medication: nil, message: nil, callType: nil, requestedApp: nil,
            topic: "कुकर",
            steps: ["चरण", "चरण", "चरण", "चरण"],
            confidence: 0.9, reply: "")
        let h = Harness(result: garbageSteps)

        _ = h.router.route(transcript: "कुकर कसरी चलाउने?")

        waitUntil { h.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(h.coordinator.genericReplies, [text("router.modelReplyUnclear")],
                       "repetition-loop guide steps must not be read aloud")
        waitUntil { !h.speaker.spoken.isEmpty }
        XCTAssertEqual(h.speaker.spoken, [text("router.modelReplyUnclear")])
        XCTAssertEqual(h.bus.events(named: "llama_response_rejected_sanity").first?.errorCode,
                       "repetition")
    }

    func testGuideStepsCleanAreReadAloud() {
        let cleanSteps = InterpretedCommand(
            action: .guide, entryId: nil, contact: nil, time: nil,
            medication: nil, message: nil, callType: nil, requestedApp: nil,
            topic: "कुकर",
            steps: ["पहिले ढक्कन खोल्नुहोस्", "अनि बिजुली जोड्नुहोस्"],
            confidence: 0.9, reply: "")
        let h = Harness(result: cleanSteps)

        _ = h.router.route(transcript: "कुकर कसरी चलाउने?")

        // Steps are joined with an ASCII ". " separator (production
        // `speakGuideSteps`) — not a Devanagari danda.
        let joined = "पहिले ढक्कन खोल्नुहोस्. अनि बिजुली जोड्नुहोस्"
        waitUntil { h.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(h.coordinator.genericReplies, [joined])
        waitUntil { !h.speaker.spoken.isEmpty }
        XCTAssertEqual(h.speaker.spoken, [joined])
        XCTAssertFalse(h.bus.contains("llama_response_rejected_sanity"))
    }

    func testSendMessageGarbageAckIsSilencedButObservable() {
        let h = Harness(result: messageCommand(message: "नमस्ते दाई",
                                               reply: "ack ack ack ack"))
        h.coordinator.composeMessageOutcome = .nativeComposePresented

        // Neutral transcript — "नमस्ते भन्नुस्" would be intercepted by
        // the greeting pre-answer before the interpreter is consulted.
        _ = h.router.route(transcript: "छोरालाई एउटा सन्देश पठाउनुहोस्")

        waitUntil { h.coordinator.composeMessageRequests.count == 1 }
        XCTAssertEqual(h.coordinator.composeMessageRequests.first?.body, "नमस्ते दाई")
        XCTAssertTrue(h.speaker.spoken.isEmpty,
                      "the compose sheet is the visible outcome — a garbage ack is not spoken")
        XCTAssertTrue(h.coordinator.genericReplies.isEmpty)
        let rejections = h.bus.events(named: "llama_response_rejected_sanity")
        XCTAssertEqual(rejections.count, 1)
        XCTAssertEqual(rejections.first?.errorCode, "repetition")
    }

    func testSendMessageCleanAckIsSpoken() {
        let h = Harness(result: messageCommand(message: "नमस्ते दाई",
                                               reply: "ठीक छ, सन्देश तयार छ।"))
        h.coordinator.composeMessageOutcome = .nativeComposePresented

        // Neutral transcript — a greeting-bearing request would be
        // intercepted by the topic pre-answer instead of reaching the
        // send_message path.
        _ = h.router.route(transcript: "छोरालाई एउटा सन्देश पठाउनुहोस्")

        waitUntil { !h.speaker.spoken.isEmpty }
        XCTAssertEqual(h.speaker.spoken, ["ठीक छ, सन्देश तयार छ।"])
        XCTAssertFalse(h.bus.contains("llama_response_rejected_sanity"))
    }

    func testAckOverrideGarbageFallsBackToBaselineAckSpeech() {
        // Model-classified ack_med with a garbage reply override: the
        // baseline confirmation is spoken, the garbage never is.
        let h = Harness(result: makeCommand(action: .ackMed, confidence: 0.9,
                                            reply: "ठीक \"ठीक\" ठीक {json}"))
        let entryId = UUID()
        h.coordinator.pendingEntryId = entryId
        h.coordinator.challengePrompt = nil   // force the baseline ack path

        _ = h.router.route(transcript: "केही राम्रो कुरा बताउनुस्")

        waitUntil { !h.speaker.spoken.isEmpty }
        XCTAssertEqual(h.speaker.spoken, [text("router.confirmationYes")],
                       "baseline ack speech, never the garbage override")
        XCTAssertEqual(h.bus.events(named: "llama_response_rejected_sanity").first?.errorCode,
                       "jsonRemnant")
        XCTAssertTrue(h.bus.contains("command_ack_medication_baseline"))
    }

    func testAckOverrideCleanIsSpoken() {
        let override = "ठीक छ, तपाईंले आजको औषधि खानुभयो।"
        let h = Harness(result: makeCommand(action: .ackMed, confidence: 0.9,
                                            reply: override))
        let entryId = UUID()
        h.coordinator.pendingEntryId = entryId
        h.coordinator.challengePrompt = nil

        _ = h.router.route(transcript: "केही राम्रो कुरा बताउनुस्")

        waitUntil { !h.speaker.spoken.isEmpty }
        XCTAssertEqual(h.speaker.spoken, [override])
        XCTAssertFalse(h.bus.contains("llama_response_rejected_sanity"))
    }
}
