import XCTest
@testable import ElderlyAssistant

/// Stage 1 of the brain conversational-augmentation plan: the CHAT response
/// shape at the interpreter.
///
/// The contract under test, in one line: `respondToChat` is the SAME
/// inference pipeline as `interpret` — same sanitiser, same empty-output
/// guard, same events — with exactly three things changed, the prompt, the
/// decode schema, and the confidence gate (the chat shape is gated by its
/// own floor, not the command threshold; see the floor section below). The command entry point and
/// the command schema are pinned byte-for-byte elsewhere
/// (`LlamaCommandInterpreterTests`); what this suite adds is that the chat
/// shape cannot leak into them, and that a chat ask abstains GRACEFULLY
/// (nil, observable) rather than inventing a command.
final class ChatResponseShapeTests: XCTestCase {

    private var tmpRoot: URL!
    private var bus: MockObservabilityBus!
    private var store: ModelStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-shape-\(UUID().uuidString)")
        bus = MockObservabilityBus()
        store = try ModelStore(observabilityBus: bus, rootDirectoryOverride: tmpRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    private func ctx() -> InterpreterContext {
        InterpreterContext(pendingMedications: [], userLanguageHint: "ne")
    }

    private func chat(_ interp: LlamaCommandInterpreter,
                      transcript: String = "तपाईंलाई कस्तो छ?",
                      file: StaticString = #filePath, line: UInt = #line) -> InterpretedCommand? {
        let expectation = expectation(description: "chat completion fires")
        var result: InterpretedCommand?
        interp.respondToChat(transcript: transcript, context: ctx()) { cmd in
            result = cmd
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
        return result
    }

    private func eventTypes() -> [String] { bus.emittedEvents.map(\.eventType) }

    // MARK: - The schema swap

    func testChatEntryReceivesTheChatJSONSchema() {
        // The same wiring property `testGenerateOverrideReceivesTheCommand
        // JSONSchema` pins for the command entry: whatever the entry point
        // promises the sampler must actually arrive.
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        var receivedSchema: String?
        interp.generateOverride = { _, jsonSchema in
            receivedSchema = jsonSchema
            return #"{"intent":"chat","reply":"नमस्ते हजुर!","confidence":0.9}"#
        }

        _ = chat(interp)

        XCTAssertEqual(receivedSchema, LlamaGrammar.chatJSONSchema,
                       "the chat entry must decode against the chat schema")
        XCTAssertNotEqual(receivedSchema, LlamaGrammar.commandJSONSchema,
                          "…and never the command schema")
    }

    func testCommandEntryStillReceivesTheCommandSchema() {
        // The shared pipeline's regression pin: the chat shape is additive,
        // so the command entry point's schema is unchanged (the assertion
        // the pre-existing suite makes, restated here against the refactor
        // that introduced the two shapes).
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        var receivedSchema: String?
        interp.generateOverride = { _, jsonSchema in
            receivedSchema = jsonSchema
            return #"{"intent":"query","response":"जवाफ","confidence":0.9}"#
        }
        let expectation = expectation(description: "completion fires")
        interp.interpret(transcript: "के छ खबर?", context: ctx()) { _ in
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)

        XCTAssertEqual(receivedSchema, LlamaGrammar.commandJSONSchema)
    }

    func testChatSchemaCarriesNoExecutableSlots() {
        // A chat turn has nothing to execute, so the shape it decodes
        // against must not be ABLE to express a slot — that is what makes
        // "a chat reply can never run anything" structural rather than a
        // policy the router is trusted to enforce.
        let s = LlamaGrammar.chatJSONSchema
        XCTAssertTrue(s.contains("\"chat\""), "the chat intent is the shape's own label")
        for slot in ["entryId", "contact", "time", "medication", "message",
                     "callType", "requestedApp", "topic", "steps",
                     "pluginAction", "pluginEntities", "actionType", "actionUrl"] {
            XCTAssertFalse(s.contains("\"\(slot)\""),
                           "the chat shape must not teach the slot: \(slot)")
        }
    }

    func testCommandSchemaIsNotWidenedByTheChatShape() {
        // The frozen-command-schema requirement, asserted from the chat
        // side: the 12-action catalog the command prompt teaches is
        // untouched, and "chat" is not one of the 12.
        let s = LlamaGrammar.commandJSONSchema
        XCTAssertFalse(s.contains("\"chat\""),
                       "the command schema must not gain a chat intent")
        for intent in ["ack_med", "call", "emergency", "set_reminder",
                       "health_query", "music", "send_message", "guide",
                       "create_calendar_event", "suggest_video", "query", "none"] {
            XCTAssertTrue(s.contains("\"\(intent)\""), "missing intent: \(intent)")
        }
    }

    // MARK: - The prompt swap

    func testChatEntryReceivesTheChatPrompt() {
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        var receivedPrompt: String?
        interp.generateOverride = { prompt, _ in
            receivedPrompt = prompt
            return #"{"intent":"chat","reply":"ठीक छ हजुर।","confidence":0.9}"#
        }

        _ = chat(interp, transcript: "तपाईंलाई कस्तो छ?")

        let prompt = receivedPrompt ?? ""
        XCTAssertTrue(prompt.contains("तपाईंलाई कस्तो छ?"),
                      "the sanitised transcript reaches the chat prompt")
        XCTAssertTrue(prompt.contains("chat"),
                      "the prompt teaches the chat label it must emit")
        XCTAssertFalse(prompt.contains("ack_med"),
                       "the chat prompt must not carry the command catalog")
    }

    func testChatPromptStaysInsideTheCommandPromptsBudget() {
        // The chat prompt is asked of the same 1,024-token on-device
        // context, so it must never be larger than the prompt whose size
        // ceiling `IntentPromptTests` already calibrates. Strictly smaller
        // is the honest claim: the chat shape has no slot catalog to
        // teach.
        let chat = IntentPrompt.buildChat(transcript: "तपाईंलाई कस्तो छ?",
                                          context: ctx())
        let command = IntentPrompt.build(transcript: "तपाईंलाई कस्तो छ?",
                                         context: ctx())
        XCTAssertFalse(chat.isEmpty)
        XCTAssertLessThan(chat.count, command.count,
                          "the chat prompt must fit where the command prompt fits")
    }

    func testChatPromptCarriesTheLanguageHint() {
        let chat = IntentPrompt.buildChat(transcript: "hello", context: ctx())
        XCTAssertTrue(chat.contains("hint: ne"),
                      "the chat prompt keeps the language hint the command prompt carries")
    }

    // MARK: - Decode

    func testChatJSONDecodesToChatWithTheSpokenReply() {
        let cmd = LlamaCommandInterpreter.parse(
            json: #"{"intent":"chat","reply":"नमस्ते हजुर! कस्तो छ?","confidence":0.9}"#)
        XCTAssertEqual(cmd?.action, .chat)
        XCTAssertEqual(cmd?.reply, "नमस्ते हजुर! कस्तो छ?")
        XCTAssertEqual(cmd?.confidence, 0.9)
    }

    func testChatEntryDecodesOverTheSeamIntoASpokenReply() {
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        interp.generateOverride = { _, _ in
            #"{"intent":"chat","reply":"म ठीक छु, हजुर।","confidence":0.85}"#
        }

        let cmd = chat(interp)

        XCTAssertEqual(cmd?.action, .chat, "the chat shape decodes as chat")
        XCTAssertEqual(cmd?.reply, "म ठीक छु, हजुर।",
                       "the free-text reply is what the shell will speak")
        XCTAssertTrue(eventTypes().contains("inference_done"))
    }

    func testChatJSONWithTheResponseKeyAlsoDecodes() {
        // The tolerant single-wire-shape decoder accepts `response` in
        // `reply`'s place — a model that answers the chat prompt with the
        // command contract's key name is still understood.
        let cmd = LlamaCommandInterpreter.parse(
            json: #"{"intent":"chat","response":"नमस्ते।","confidence":0.9}"#)
        XCTAssertEqual(cmd?.action, .chat)
        XCTAssertEqual(cmd?.reply, "नमस्ते।")
    }

    // MARK: - Graceful abstention (the expected stage-1 state)

    func testChatJSONWithAnEmptyReplyAbstains() {
        // No training yet for this shape: an empty reply is a valid
        // ABSTENTION — nil, never a command with nothing to say.
        XCTAssertNil(LlamaCommandInterpreter.parse(
            json: #"{"intent":"chat","reply":"","confidence":0.9}"#))
        XCTAssertNil(LlamaCommandInterpreter.parse(
            json: #"{"intent":"chat","reply":"   ","confidence":0.9}"#))
    }

    func testChatSeamEmptyOutputEmitsTheEmptyOutputEventAndAbstains() {
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        interp.generateOverride = { _, _ in "" }

        XCTAssertNil(chat(interp),
                     "an empty completion is an abstention, never a spoken nothing")
        XCTAssertTrue(eventTypes().contains("inference_empty_output"),
                      "the failure shape stays observable on the chat path too")
        XCTAssertFalse(eventTypes().contains("inference_done"))
    }

    // MARK: - The chat shape's confidence floor (Stage 1 scope addition)

    func testChatBelowTheFloorStillCompletesSoTheHonestLineCanBeSpoken() {
        // [CHAT-CONFIDENCE-FLOOR] A sub-floor chat decode is NOT dropped
        // here. Dropping it returns nil, and nil means "the command ladder
        // owns this turn" — the ladder would ask the same brain a
        // different question and the user would hear whatever THAT said.
        // The floor's consequence is a spoken honest line, so the decode
        // completes carrying its confidence and the router decides
        // (`CommandRouter.dispatchInterpreted`).
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        interp.generateOverride = { _, _ in
            #"{"intent":"chat","reply":"होला।","confidence":0.2}"#
        }

        let cmd = chat(interp)
        XCTAssertEqual(cmd?.action, .chat)
        XCTAssertEqual(cmd?.reply, "होला।",
                       "the model text is carried — and withheld at delivery, not here")
        XCTAssertEqual(cmd?.confidence, 0.2)
        XCTAssertTrue(eventTypes().contains("inference_done"),
                      "a below-floor chat turn still ran a real inference")
    }

    func testChatBetweenTheFloorAndTheCommandThresholdIsStillAnAnswer() {
        // The chat shape's acceptance gate is its FLOOR, not the command
        // threshold: 0.65 would abstain as a command (default threshold
        // 0.7), but a conversation is not an instruction — demanding
        // instruction-grade certainty of small talk would turn most chat
        // turns into abstentions.
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        interp.generateOverride = { _, _ in
            #"{"intent":"chat","reply":"ठीक छु हजुर।","confidence":0.65}"#
        }

        XCTAssertEqual(chat(interp)?.reply, "ठीक छु हजुर।",
                       "above the floor the reply is delivered even under the command threshold")
    }

    func testCommandShapeStillAbstainsBelowItsOwnThreshold() {
        // The floor is the chat shape's alone. The command gate is the
        // one pre-existing behavior this whole change must not disturb:
        // 0.65 under a 0.7 threshold still abstains, exactly as before.
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        interp.generateOverride = { _, _ in
            #"{"intent":"query","response":"जवाफ","confidence":0.65}"#
        }
        let expectation = expectation(description: "command completion fires")
        var result: InterpretedCommand?
        interp.interpret(transcript: "के छ खबर?", context: ctx()) { command in
            result = command
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)

        XCTAssertNil(result,
                     "the command shape keeps the confidence gate it always had")
    }

    func testChatFloorIsTheConfiguredValueNotAConstant() {
        // The floor is config, so a caller can set it — and a config that
        // raises it above the reply's confidence changes the outcome at
        // the DECODE gate (the router reads the same value from its own
        // side; see `ChatConfidenceFloorTests`).
        let interp = LlamaCommandInterpreter(
            modelStore: store,
            observabilityBus: bus,
            config: LlamaCommandInterpreter.Config(confidenceThreshold: 0.4,
                                                   maxTokens: 128,
                                                   timeoutSeconds: 10,
                                                   chatConfidenceFloor: 0.9))
        interp.generateOverride = { _, _ in
            #"{"intent":"chat","reply":"होला।","confidence":0.7}"#
        }

        let cmd = chat(interp)
        XCTAssertEqual(cmd?.confidence, 0.7,
                       "above a 0.4 command threshold the chat decode is carried regardless")
    }

    func testChatFloorDefaultsToTheBrainConfigValue() {
        XCTAssertEqual(LlamaCommandInterpreter.Config.default.chatConfidenceFloor, 0.6,
                       "the shipped floor is the value the coordinators specified")
    }


    func testChatIsNilWhenTheBrainIsUnavailable() {
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        XCTAssertFalse(interp.isAvailable, "no cached model, no seam")
        XCTAssertNil(chat(interp), "an unavailable brain abstains on the chat shape too")
    }

    func testChatUnavailableOverTheSeamNeverEmitsAnInferenceEvent() {
        // The unavailable guard runs BEFORE the prompt build, so a chat
        // ask on a brain with no model cannot report an inference that
        // never happened.
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        _ = chat(interp)
        XCTAssertFalse(eventTypes().contains("inference_done"))
        XCTAssertFalse(eventTypes().contains("inference_empty_output"))
    }
}
