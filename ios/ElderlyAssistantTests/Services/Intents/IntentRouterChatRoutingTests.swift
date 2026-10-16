import XCTest
@testable import ElderlyAssistant

/// Stage 1 of the conversational-augmentation plan: where the chat class
/// enters the router's ladder.
///
/// Contract under test: a chit-chat utterance is asked of the LOCAL brain's
/// chat entry point (`ChatResponding.respondToChat` — the chat prompt +
/// `LlamaGrammar.chatJSONSchema`), every command utterance keeps the
/// command entry point byte-for-byte, and a brain without the chat shape
/// is asked exactly as it is today.
final class IntentRouterChatRoutingTests: XCTestCase {

    /// A local brain that is chat-capable and records WHICH entry point
    /// served the turn — the property under test is precisely that
    /// distinction, which a spy that only counted calls could not tell.
    private final class ChatCapableBrainSpy: CommandInterpreter, ChatResponding {
        var commandResult: InterpretedCommand? = makeCommand(action: .none)
        var chatResult: InterpretedCommand? = makeCommand(action: .chat,
                                                          confidence: 0.9,
                                                          reply: "नमस्ते हजुर!")
        private(set) var commandTranscripts: [String] = []
        private(set) var chatTranscripts: [String] = []

        var isAvailable: Bool { true }

        func interpret(transcript: String,
                       context: InterpreterContext,
                       completion: @escaping (InterpretedCommand?) -> Void) {
            commandTranscripts.append(transcript)
            DispatchQueue.main.async { completion(self.commandResult) }
        }

        func respondToChat(transcript: String,
                           context: InterpreterContext,
                           completion: @escaping (InterpretedCommand?) -> Void) {
            chatTranscripts.append(transcript)
            DispatchQueue.main.async { completion(self.chatResult) }
        }
    }

    private func makeRouter() -> IntentRouter {
        let cache = IntentCommandCache(storage: StubEncryptedStorage())
        return IntentRouter(cache: cache, observabilityBus: NullObservabilityBus())
    }

    private func ctx() -> InterpreterContext {
        InterpreterContext(pendingMedications: [], userLanguageHint: "ne")
    }

    private func interpret(_ router: IntentRouter, _ transcript: String) -> InterpretedCommand? {
        let exp = expectation(description: "interpret")
        var out: InterpretedCommand?
        router.interpret(transcript: transcript, context: ctx()) { result in
            out = result
            exp.fulfill()
        }
        waitForExpectations(timeout: 2)
        return out
    }

    private let chatUtterance = "तपाईंलाई कस्तो छ?"
    private let commandUtterance = "छोरालाई फोन गर"

    // MARK: - Routing

    func testChatUtteranceTakesTheChatEntryOfTheLocalBrain() {
        let router = makeRouter()
        let brain = ChatCapableBrainSpy()
        router.localBrain = brain
        router.cloudEnabled = false

        let result = interpret(router, chatUtterance)

        XCTAssertEqual(brain.chatTranscripts, [chatUtterance],
                       "a chit-chat utterance must be asked through the chat entry")
        XCTAssertTrue(brain.commandTranscripts.isEmpty,
                      "and never through the command entry")
        XCTAssertEqual(result?.action, .chat)
        XCTAssertEqual(result?.reply, "नमस्ते हजुर!")
    }

    func testCommandUtteranceKeepsTheCommandEntry() {
        let router = makeRouter()
        let brain = ChatCapableBrainSpy()
        brain.commandResult = makeCommand(action: .call, contact: "छोरा")
        router.localBrain = brain
        router.cloudEnabled = false

        let result = interpret(router, commandUtterance)

        XCTAssertEqual(brain.commandTranscripts, [commandUtterance],
                       "a command must be asked exactly as it is today")
        XCTAssertTrue(brain.chatTranscripts.isEmpty,
                      "the chat shape must never see a command")
        XCTAssertEqual(result?.action, .call)
    }

    func testBrainWithoutTheChatShapeKeepsTodaysPath() {
        // The pre-chat wiring: a local brain that only implements
        // `CommandInterpreter` must be asked exactly as before, chat
        // utterance or not.
        let router = makeRouter()
        let brain = StubCommandInterpreter(result: makeCommand(action: .none))
        router.localBrain = brain
        router.cloudEnabled = false

        _ = interpret(router, chatUtterance)

        XCTAssertEqual(brain.callCount, 1,
                       "without a chat shape the utterance takes today's path")
        XCTAssertEqual(brain.lastTranscript, chatUtterance)
    }

    func testChatAbstentionFallsBackToTodaysLadder() {
        // Stage 1 ships BEFORE the brain is trained for the chat shape, so
        // an abstention on the chat prompt is the expected outcome on
        // today's model. The turn must then be answered the way it is
        // today — never dropped to a bare apology.
        let router = makeRouter()
        let brain = ChatCapableBrainSpy()
        brain.chatResult = nil
        brain.commandResult = makeCommand(action: .none, reply: "आजको मौसम बदली छ।")
        router.localBrain = brain
        router.cloudEnabled = false

        let result = interpret(router, chatUtterance)

        XCTAssertEqual(brain.chatTranscripts, [chatUtterance])
        XCTAssertEqual(brain.commandTranscripts, [chatUtterance],
                       "the chat abstention must fall through to the command ladder")
        XCTAssertEqual(result?.reply, "आजको मौसम बदली छ।")
    }

    func testChatReplyIsNotBandGated() {
        // A chat reply is not a command: there is nothing to confirm,
        // rephrase or execute, so the band policy does not apply — the
        // spoken-reply contract is enforced downstream by the speak-path
        // sanity gate instead (`CommandRouter.sanitisedModelReply`).
        let router = makeRouter()
        let brain = ChatCapableBrainSpy()
        brain.chatResult = makeCommand(action: .chat, confidence: 0.1, reply: "नमस्ते।")
        router.localBrain = brain
        router.cloudEnabled = false

        let result = interpret(router, chatUtterance)

        XCTAssertEqual(result?.reply, "नमस्ते।",
                       "a sub-band chat reply is still this turn's answer")
    }

    func testChatClassificationPrecedesTheLocalBrainOnTheCloudFirstLocalLane() {
        // Cloud-first armed but the selector picks LOCAL (no key): the
        // local lane is where the chat class lives, so the chat entry is
        // still the one that serves the turn.
        let router = makeRouter()
        let brain = ChatCapableBrainSpy()
        router.localBrain = brain
        router.cloudEnabled = true
        router.cloudFirstEnabled = true
        router.geminiKeyConfigured = { false }
        router.geminiCostAllows = { true }

        let result = interpret(router, chatUtterance)

        XCTAssertEqual(brain.chatTranscripts, [chatUtterance])
        XCTAssertEqual(result?.action, .chat)
    }
}
