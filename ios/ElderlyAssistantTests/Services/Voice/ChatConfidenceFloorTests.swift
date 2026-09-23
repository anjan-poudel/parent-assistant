import XCTest
@testable import ElderlyAssistant

/// [CHAT] Stage 1 of the conversational-augmentation plan, confidence-floor
/// scope addition (2026-09-23): the DELIVERY end of the chat shape's
/// confidence floor.
///
/// The brain decodes every chat turn against `LlamaGrammar.chatJSONSchema`,
/// whose `confidence` field is the model's own estimate of its free-text
/// reply. Below `LlamaCommandInterpreter.Config.chatConfidenceFloor` the
/// model is telling us it is guessing — and a guess spoken in the
/// assistant's voice is worse than an admitted gap. So the router withholds
/// the text entirely and speaks the honest localized line
/// (`router.chatLowConfidence`, en + ne), observable as `chatLowConfidence`.
///
/// The interpreter deliberately does NOT filter this case out
/// (`ChatResponseShapeTests` pins that): nil from the brain means "the
/// command ladder owns this turn", and the ladder would ask the same brain a
/// different question rather than admit the gap. The floor is decided here,
/// where every other "this model answer is not good enough to speak"
/// decision already lives.
final class ChatConfidenceFloorTests: XCTestCase {

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

    private final class FullRecordBus: ObservabilityBus {
        private(set) var events: [ObservabilityEvent] = []
        func emit(_ event: ObservabilityEvent) { events.append(event) }
        func events(named type: String) -> [ObservabilityEvent] {
            events.filter { $0.eventType == type }
        }
        func contains(_ type: String) -> Bool {
            events.contains { $0.eventType == type }
        }
    }

    private final class Harness {
        let coordinator = StubCoordinator()
        let speaker = RecordingSpeaker()
        let bus = FullRecordBus()
        let router: CommandRouter
        let interpreter: StubCommandInterpreter

        /// `floor: nil` constructs the router exactly as production does
        /// (no floor argument), which is how the default value itself gets
        /// exercised.
        init(result: InterpretedCommand?, floor: Double? = nil) {
            interpreter = StubCommandInterpreter(available: true, result: result)
            if let floor {
                router = CommandRouter(coordinator: coordinator,
                                       observabilityBus: bus,
                                       speaker: speaker,
                                       interpreter: interpreter,
                                       chatConfidenceFloor: floor)
            } else {
                router = CommandRouter(coordinator: coordinator,
                                       observabilityBus: bus,
                                       speaker: speaker,
                                       interpreter: interpreter)
            }
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

    private func text(_ key: String, locale: String = "ne-NP") -> String {
        L10n.str(key, locale: Locale(identifier: locale))
    }

    /// The honest line, pinned as COPY (not as a key lookup): a missing
    /// catalog entry would otherwise compare equal to itself and pass.
    private let honestNe = "मलाई यसमा विश्वास छैन — म यो राम्ररी जवाफ दिन सक्दिनँ।"
    private let honestEn = "I'm not confident about this — I can't answer that well."

    /// A perfectly sane chat reply — the floor, not the sanity gate, is
    /// what withholds it in the below-floor tests.
    private let reply = "म ठीक छु, हजुर। तपाईंलाई कस्तो छ?"

    // MARK: - Below the floor: the honest line, never the guess

    func testBelowFloorChatReplyIsReplacedByTheHonestLine() {
        let h = Harness(result: makeCommand(action: .chat, confidence: 0.4, reply: reply))

        _ = h.router.route(transcript: "के छ खबर?")

        waitUntil { h.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(h.coordinator.genericReplies, [honestNe],
                       "the honest line is carded — the guess is not")
        waitUntil { h.speaker.spoken.count == 2 }
        XCTAssertEqual(h.speaker.spoken, [text("voiceAck.moment1"), honestNe],
                       "the honest line is spoken — the guess is not")
        XCTAssertFalse(h.speaker.spoken.contains(reply),
                       "model text under the floor must never reach the ear")
        XCTAssertFalse(h.coordinator.genericReplies.contains(reply),
                       "model text under the floor must never reach the card")
        XCTAssertFalse(h.bus.contains("command_llm_chat"),
                       "nothing was delivered as a chat answer — the event must not claim otherwise")
    }

    func testBelowFloorEmitsChatLowConfidenceWithBothNumbers() {
        let h = Harness(result: makeCommand(action: .chat, confidence: 0.42, reply: reply))

        _ = h.router.route(transcript: "के छ खबर?")

        waitUntil { !h.bus.events(named: "chatLowConfidence").isEmpty }
        let event = h.bus.events(named: "chatLowConfidence").first
        XCTAssertEqual(event?.component, "command_router")
        XCTAssertEqual(event?.metadata["confidence"], "0.42")
        XCTAssertEqual(event?.metadata["floor"], "0.60",
                       "the shipped floor is 0.6 — the event records what it was applied against")
    }

    func testBelowFloorNeverTurnsIntoASecondInference() {
        // The floor is a delivery decision, not a fall-through: the turn is
        // answered once, honestly, and the router does not go back to the
        // brain (or to any other stage) for a second opinion.
        let h = Harness(result: makeCommand(action: .chat, confidence: 0.1, reply: reply))

        _ = h.router.route(transcript: "के छ खबर?")

        waitUntil { h.speaker.spoken.count == 2 }
        XCTAssertEqual(h.interpreter.callCount, 1,
                       "one turn, one inference — the floor does not retry")
    }

    func testHonestLineFollowsTheActiveLanguage() {
        // The line is a catalog string (en + ne), resolved in the same
        // locale every other router line resolves in.
        let h = Harness(result: makeCommand(action: .chat, confidence: 0.3, reply: reply))
        h.coordinator.activeLocale = Locale(identifier: "en-US")

        _ = h.router.route(transcript: "के छ खबर?")

        waitUntil { h.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(h.coordinator.genericReplies, [honestEn],
                       "the same key resolves to the English copy for an English turn")
    }

    // MARK: - At and above the floor: the reply is spoken

    func testReplyExactlyAtTheFloorIsSpoken() {
        // `>=` against the floor: the floor is the lowest confidence that
        // is still delivered, not the first that is withheld.
        let h = Harness(result: makeCommand(action: .chat, confidence: 0.6, reply: reply))

        _ = h.router.route(transcript: "के छ खबर?")

        waitUntil { h.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(h.coordinator.genericReplies, [reply])
        waitUntil { h.speaker.spoken.count == 2 }
        XCTAssertEqual(h.speaker.spoken.last, reply)
        XCTAssertFalse(h.bus.contains("chatLowConfidence"))
    }

    func testMidBandChatTurnIsNotTurnedIntoARephraseQuestion() {
        // 0.65 is squarely in the rephrase band (0.4…0.7) that every
        // tier-free COMMAND goes through on its way to a yes/no question.
        // There is nothing to confirm about small talk — "did you mean…?"
        // has no referent — and the chat shape's floor owns this case:
        // above it the reply is spoken, below it the honest line is.
        let h = Harness(result: makeCommand(action: .chat, confidence: 0.65, reply: reply))

        _ = h.router.route(transcript: "के छ खबर?")

        waitUntil { h.coordinator.genericReplies.count == 1 }
        XCTAssertNil(h.coordinator.rephrasePended,
                     "a chat turn must never pend a rephrase confirmation")
        XCTAssertFalse(h.bus.contains("rephrase_question_started"))
        XCTAssertEqual(h.coordinator.genericReplies, [reply])
    }

    func testAboveFloorReplyIsSpokenAndObservable() {
        let h = Harness(result: makeCommand(action: .chat, confidence: 0.9, reply: reply))

        _ = h.router.route(transcript: "के छ खबर?")

        waitUntil { h.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(h.speaker.spoken.last, reply)
        XCTAssertTrue(h.bus.contains("command_llm_chat"),
                      "a delivered chat answer is observable as such")
        XCTAssertFalse(h.bus.contains("chatLowConfidence"))
    }

    func testDeliveredChatReplyStillPassesTheSanityGate() {
        // The floor is an ADDITION to the delivery path, not a bypass of
        // it: a confident chat reply made of JSON remnants is still
        // rejected by `ReplySanityGate` and replaced by the honest
        // unclear-line, exactly like a `query` answer.
        let garbage = "ठीक छ {\"nested\": \"json\"} हो"
        let h = Harness(result: makeCommand(action: .chat, confidence: 0.95, reply: garbage))

        _ = h.router.route(transcript: "के छ खबर?")

        waitUntil { h.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(h.coordinator.genericReplies, [text("router.modelReplyUnclear")])
        XCTAssertEqual(h.bus.events(named: "llama_response_rejected_sanity").first?.errorCode,
                       "jsonRemnant")
        XCTAssertFalse(h.speaker.spoken.contains(garbage))
    }

    // MARK: - The floor is configuration

    func testFloorIsTheRoutersOwnInjectedValue() {
        // Raising the floor above the reply's confidence changes the
        // outcome with no other change — proof that the gate reads the
        // router's configured floor and not a literal.
        let h = Harness(result: makeCommand(action: .chat, confidence: 0.8, reply: reply),
                        floor: 0.9)

        _ = h.router.route(transcript: "के छ खबर?")

        waitUntil { h.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(h.coordinator.genericReplies, [honestNe])
        XCTAssertFalse(h.speaker.spoken.contains(reply))

        let h2 = Harness(result: makeCommand(action: .chat, confidence: 0.8, reply: reply))
        _ = h2.router.route(transcript: "के छ खबर?")
        waitUntil { h2.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(h2.coordinator.genericReplies, [reply],
                       "the same reply clears the shipped 0.6 floor")
    }

    func testFloorDoesNotTouchCommandDelivery() {
        // The floor is the CHAT shape's, and so is the rephrase-gate
        // exclusion that makes it reachable. A COMMAND at the same low
        // confidence keeps its own pre-existing path: a mid-band tier-free
        // command is rephrase-questioned (spec §4, decision #6 — the
        // rephrase band, 0.4…0.7). Two things must hold, and this pins
        // both: the chat floor must not hijack a command into the honest
        // chat line, and the chat exclusion must not leak INTO the
        // rephrase band for real commands.
        let low = Harness(result: makeCommand(action: .query, confidence: 0.45,
                                              reply: "आज घाम लाग्छ।"))

        _ = low.router.route(transcript: "के छ खबर?")

        waitUntil { low.coordinator.rephrasePended != nil }
        XCTAssertFalse(low.bus.contains("chatLowConfidence"),
                       "the chat floor is the chat shape's alone")
        XCTAssertFalse(low.speaker.spoken.contains("आज घाम लाग्छ।"))
        XCTAssertFalse(low.coordinator.genericReplies.contains(honestNe),
                       "a command must never be answered with the chat honest line")

        // …and a command above the band is delivered exactly as before.
        let high = Harness(result: makeCommand(action: .query, confidence: 0.95,
                                               reply: "आज घाम लाग्छ।"))
        _ = high.router.route(transcript: "के छ खबर?")
        waitUntil { high.coordinator.genericReplies.count == 1 }
        XCTAssertEqual(high.coordinator.genericReplies, ["आज घाम लाग्छ।"])
        XCTAssertFalse(high.bus.contains("chatLowConfidence"))
    }
}
