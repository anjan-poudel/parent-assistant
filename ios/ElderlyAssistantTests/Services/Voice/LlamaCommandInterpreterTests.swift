import XCTest
@testable import ElderlyAssistant

final class LlamaCommandInterpreterTests: XCTestCase {

    private var tmpRoot: URL!
    private var bus: MockObservabilityBus!
    private var store: ModelStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("llama-tests-\(UUID().uuidString)")
        bus = MockObservabilityBus()
        store = try ModelStore(observabilityBus: bus, rootDirectoryOverride: tmpRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    // MARK: - Availability

    func testUnavailableWhenModelNotCached() {
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        XCTAssertFalse(interp.isAvailable)
    }

    func testInterpretYieldsNilWhenUnavailable() {
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        let ctx = InterpreterContext(pendingMedications: [], userLanguageHint: "en")

        let expectation = expectation(description: "completion fires")
        interp.interpret(transcript: "I took my medicine", context: ctx) { cmd in
            XCTAssertNil(cmd)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - LoRA skeleton

    func testApplyLoRALogs() {
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        interp.applyLoRA(ModelID("llama-lora-nepali"))
        let events = bus.emittedEvents.filter { $0.eventType == "lora_hot_swap_skeleton" }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.metadata["state"], "llama-lora-nepali")
    }

    // MARK: - Parse (STRUCTURED-RESPONSE CONTRACT, 2026-09-06)

    /// Canonical contract JSON — what the shared `IntentPrompt` now teaches
    /// the model to emit: `intent` + always-non-empty `response` +
    /// `confidence`, with `actionType`/`actionUrl` when the intent needs
    /// them.
    func testParseCanonicalQueryJSONYieldsQueryCommandWithSpokenReply() throws {
        let json = """
        {"intent":"query","response":"भोलि काठमाडौंमा हल्का बदली छ।","confidence":0.92,"actionType":null,"actionUrl":null}
        """
        let cmd = try XCTUnwrap(LlamaCommandInterpreter.parse(json: json))
        XCTAssertEqual(cmd.action, .query)
        XCTAssertEqual(cmd.reply, "भोलि काठमाडौंमा हल्का बदली छ।")
        XCTAssertEqual(cmd.confidence, 0.92, accuracy: 0.001)
    }

    func testParseCanonicalCallJSONCarriesEntitiesAndIgnoresActionFields() throws {
        // actionType/actionUrl are validated but not carried — no consumer
        // exists yet; they must not break parsing when present.
        let json = """
        {"intent":"call","response":"म छोरालाई फोन गर्छु","confidence":0.88,"actionType":"MAKE_CALL","actionUrl":"tel://9801234567","contact":"छोरा","callType":"voice","requestedApp":null,"entryId":null,"time":null,"medication":null,"message":null,"topic":null,"steps":null}
        """
        let cmd = try XCTUnwrap(LlamaCommandInterpreter.parse(json: json))
        XCTAssertEqual(cmd.action, .call)
        XCTAssertEqual(cmd.contact, "छोरा")
        XCTAssertEqual(cmd.callType, "voice")
        XCTAssertEqual(cmd.reply, "म छोरालाई फोन गर्छु")
    }

    func testParsePrefersCanonicalIntentOverLegacyAction() throws {
        // A payload carrying BOTH generations must follow the canonical
        // key — the contract intent is the one the model was told to emit.
        let json = """
        {"intent":"query","action":"emergency","response":"आज मौसम सफा छ","reply":"उफ्","confidence":0.9}
        """
        let cmd = try XCTUnwrap(LlamaCommandInterpreter.parse(json: json))
        XCTAssertEqual(cmd.action, .query)
        XCTAssertEqual(cmd.reply, "आज मौसम सफा छ")
    }

    func testParseRejectsEmptyOrMissingSpokenResponse() {
        // Contract enforcement: dispatching a command with an empty reply
        // would make the router speak NOTHING — a silent dead-end worse
        // than the generic re-prompt. This guard is what stops a model
        // that "succeeded" without producing an answer from being
        // dispatched.
        let emptyResponse = """
        {"intent":"query","response":"","confidence":0.9}
        """
        XCTAssertNil(LlamaCommandInterpreter.parse(json: emptyResponse))
        let missingResponse = """
        {"intent":"query","confidence":0.9}
        """
        XCTAssertNil(LlamaCommandInterpreter.parse(json: missingResponse))
        let blankLegacyReply = """
        {"action":"query","reply":"   ","confidence":0.9}
        """
        XCTAssertNil(LlamaCommandInterpreter.parse(json: blankLegacyReply))
    }

    func testParseDefaultsMissingConfidenceToRephraseBand() throws {
        // A model that omits confidence gets 0.5 — the REPHRASE band — so
        // the router re-asks instead of silently acting on an unjudged
        // interpretation.
        let json = """
        {"intent":"query","response":"जवाफ"}
        """
        let cmd = try XCTUnwrap(LlamaCommandInterpreter.parse(json: json))
        XCTAssertEqual(cmd.confidence, 0.5, accuracy: 0.001)
        XCTAssertEqual(cmd.action, .query)
    }

    func testParseRejectsUnknownIntent() {
        let json = """
        {"intent":"do_a_backflip","response":"…","confidence":0.9}
        """
        XCTAssertNil(LlamaCommandInterpreter.parse(json: json))
    }

    /// Legacy wire shape (`action`/`reply`) — pre-contract payloads from
    /// the intent→command cache, the cloud collapsed path, and the
    /// grammar-constrained fine-tuned local brain keep parsing unchanged.
    func testParseValidLegacyJSONYieldsCommand() throws {
        let json = """
        {"action":"ack_med","entryId":null,"contact":null,"confidence":0.92,"reply":"Okay, marked as taken."}
        """
        let cmd = try XCTUnwrap(LlamaCommandInterpreter.parse(json: json))
        XCTAssertEqual(cmd.action, .ackMed)
        XCTAssertNil(cmd.entryId)
        XCTAssertNil(cmd.contact)
        XCTAssertEqual(cmd.confidence, 0.92, accuracy: 0.001)
        XCTAssertEqual(cmd.reply, "Okay, marked as taken.")
    }

    func testParseClampsConfidenceToRange() {
        let json = """
        {"action":"none","entryId":null,"contact":null,"confidence":1.7,"reply":"…"}
        """
        let cmd = LlamaCommandInterpreter.parse(json: json)
        XCTAssertEqual(cmd?.confidence, 1.0)
    }

    func testParseRejectsUnknownAction() {
        let json = """
        {"action":"do_a_backflip","entryId":null,"contact":null,"confidence":0.9,"reply":"…"}
        """
        XCTAssertNil(LlamaCommandInterpreter.parse(json: json))
    }

    func testParseRejectsMalformedJSON() {
        XCTAssertNil(LlamaCommandInterpreter.parse(json: "not-json"))
        XCTAssertNil(LlamaCommandInterpreter.parse(json: nil))
    }

    // MARK: - Grammar (mirrors the canonical contract)

    func testGrammarIncludesAllCanonicalFields() {
        let g = LlamaGrammar.commandJSON
        XCTAssertTrue(g.contains("\\\"intent\\\""), "canonical intent key")
        XCTAssertTrue(g.contains("\\\"response\\\""), "canonical response key")
        XCTAssertTrue(g.contains("\\\"confidence\\\""))
        XCTAssertTrue(g.contains("\\\"actionType\\\""))
        XCTAssertTrue(g.contains("\\\"actionUrl\\\""))
        // Entity/slot fields.
        XCTAssertTrue(g.contains("\\\"entryId\\\""))
        XCTAssertTrue(g.contains("\\\"contact\\\""))
        XCTAssertTrue(g.contains("\\\"time\\\""))
        XCTAssertTrue(g.contains("\\\"medication\\\""))
        XCTAssertTrue(g.contains("\\\"message\\\""))
        XCTAssertTrue(g.contains("\\\"callType\\\""))
        XCTAssertTrue(g.contains("\\\"requestedApp\\\""))
        XCTAssertTrue(g.contains("\\\"topic\\\""))
        XCTAssertTrue(g.contains("\\\"steps\\\""))
        // The legacy keys are gone from the taught grammar — parse keeps
        // accepting them for old payloads, but the grammar is the
        // contract definition and must not teach the pre-contract shape.
        XCTAssertFalse(g.contains("\\\"action\\\""), "legacy key must not be taught")
        XCTAssertFalse(g.contains("\\\"reply\\\""), "legacy key must not be taught")
        // All twelve contract intents enumerated exactly.
        let intents = ["ack_med", "call", "send_message", "set_reminder",
                       "emergency", "health_query", "music",
                       "create_calendar_event", "suggest_video", "guide",
                       "query", "none"]
        for intent in intents {
            XCTAssertTrue(g.contains("\\\"\(intent)\\\""), "missing intent: \(intent)")
        }
    }

    func testCommandJSONSchemaMirrorsGrammarAndContract() {
        // [NO-GIBBERISH] (2026-09-07) `commandJSONSchema` is what actually
        // reaches llama.cpp's json-schema→grammar converter on the runtime
        // path — it must mirror the hand-written `commandJSON` grammar
        // field-for-field, teach the same 12-intent contract, and never
        // teach the legacy keys.
        let s = LlamaGrammar.commandJSONSchema
        for key in ["intent", "response", "confidence", "actionType",
                    "actionUrl", "entryId", "contact", "time", "medication",
                    "message", "callType", "requestedApp", "topic", "steps",
                    "pluginAction", "pluginEntities"] {
            XCTAssertTrue(s.contains("\"\(key)\""), "schema missing key: \(key)")
        }
        let intents = ["ack_med", "call", "send_message", "set_reminder",
                       "emergency", "health_query", "music",
                       "create_calendar_event", "suggest_video", "guide",
                       "query", "none"]
        for intent in intents {
            XCTAssertTrue(s.contains("\"\(intent)\""), "schema missing intent: \(intent)")
        }
        XCTAssertFalse(s.contains("\"action\""), "legacy key must not be taught")
        XCTAssertFalse(s.contains("\"reply\""), "legacy key must not be taught")
        // Nullable entities and typed array/object values — the converter
        // supports exactly this subset (same shapes `intentSchema` uses).
        XCTAssertTrue(s.contains("\"steps\": {\"type\": [\"array\", \"null\"]"),
                      "steps must be a nullable string array")
        XCTAssertTrue(s.contains("\"pluginEntities\": {\"type\": [\"object\", \"null\"]"),
                      "pluginEntities must be a nullable string map")
        XCTAssertTrue(s.contains("\"additionalProperties\": {\"type\": \"string\"}"))
        XCTAssertTrue(s.contains("\"required\""))
    }

    func testParsePluginActionAndEntities() {
        let json = """
        {"action":"plugin","entryId":null,"contact":null,"time":null,"medication":null,"message":null,"callType":null,"requestedApp":null,"pluginAction":"nepali_calendar.query","pluginEntities":{"question":"आज के हो"},"confidence":0.9,"reply":"खोज्दैछु"}
        """
        let cmd = LlamaCommandInterpreter.parse(json: json)
        XCTAssertEqual(cmd?.action, .plugin)
        XCTAssertEqual(cmd?.pluginAction, "nepali_calendar.query")
        XCTAssertEqual(cmd?.pluginEntities?["question"], "आज के हो")
    }

    func testParsePluginEntitiesDefaultsToNilWhenAbsent() {
        let json = """
        {"action":"ack_med","entryId":null,"contact":null,"confidence":0.9,"reply":"ठिक"}
        """
        let cmd = LlamaCommandInterpreter.parse(json: json)
        XCTAssertEqual(cmd?.action, .ackMed)
        XCTAssertNil(cmd?.pluginAction)
        XCTAssertNil(cmd?.pluginEntities)
    }

    func testParseExtractsTimeAndMedicationEntities() {
        let json = """
        {"action":"set_reminder","entryId":null,"contact":null,"time":"बिहान ८ बजे","medication":"प्रेसरको औषधि","confidence":0.92,"reply":"ठीक छ"}
        """
        let cmd = LlamaCommandInterpreter.parse(json: json)
        XCTAssertEqual(cmd?.action, .setReminder)
        XCTAssertEqual(cmd?.time, "बिहान ८ बजे")
        XCTAssertEqual(cmd?.medication, "प्रेसरको औषधि")
    }

    // MARK: - generateOverride seam ([QUERY-FIX], 2026-09-06)
    //
    // Lets the REAL router chain (CommandRouter → IntentRouter →
    // LocalBrainChain) run end-to-end in unit tests with no cached model,
    // mirroring `LocalIntentInterpreter.generateOverride`. The override
    // output still runs through the same empty-output guard as the real
    // runtime, so the seam cannot mask the overflow failure mode it exists
    // to test around.

    private func makeSeamedInterpreter(json: String) -> LlamaCommandInterpreter {
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        interp.generateOverride = { _, _ in json }
        return interp
    }

    private func interpret(_ interp: LlamaCommandInterpreter,
                           transcript: String = "भोलिको मौसम कस्तो छ?",
                           file: StaticString = #filePath, line: UInt = #line) -> InterpretedCommand? {
        let ctx = InterpreterContext(pendingMedications: [], userLanguageHint: "ne")
        let expectation = expectation(description: "completion fires")
        var result: InterpretedCommand?
        interp.interpret(transcript: transcript, context: ctx) { cmd in
            result = cmd
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
        return result
    }

    func testGenerateOverrideMakesInterpreterAvailableWithoutCachedModel() {
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        XCTAssertFalse(interp.isAvailable, "no model cached")
        interp.generateOverride = { _, _ in "{}" }
        XCTAssertTrue(interp.isAvailable, "seam must stand in for the llama.cpp runtime")
    }

    func testGenerateOverrideCanonicalJSONYieldsQueryCommand() throws {
        let answer = "भोलि काठमाडौंमा हल्का बदली छ।"
        let json = """
        {"intent":"query","response":"\(answer)","confidence":0.9,"actionType":null,"actionUrl":null}
        """
        let cmd = try XCTUnwrap(interpret(makeSeamedInterpreter(json: json)))
        XCTAssertEqual(cmd.action, .query)
        XCTAssertEqual(cmd.reply, answer)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "inference_done" })
    }

    func testGenerateOverrideLegacyJSONStillYieldsCommand() throws {
        // The fine-tuned local brain's grammar still emits the legacy
        // shape; the tolerant parse must keep it dispatchable.
        let json = """
        {"action":"query","entryId":null,"contact":null,"confidence":0.9,"reply":"हुन्छ"}
        """
        let cmd = try XCTUnwrap(interpret(makeSeamedInterpreter(json: json)))
        XCTAssertEqual(cmd.action, .query)
        XCTAssertEqual(cmd.reply, "हुन्छ")
    }

    func testGenerateOverrideEmptyOutputYieldsNilAndEmitsEmptyOutputEvent() {
        // The [QUERY-FIX] bug's exact failure shape: an EMPTY completion
        // used to be reported as inference_done success and then silently
        // dropped. The guard must report it as a failure and never hand an
        // empty string to the parser.
        let cmd = interpret(makeSeamedInterpreter(json: ""))
        XCTAssertNil(cmd)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "inference_empty_output" },
                      "empty output must be observable, never a silent success")
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "inference_done" })
    }

    func testGenerateOverrideWhitespaceOnlyOutputYieldsNil() {
        let cmd = interpret(makeSeamedInterpreter(json: "   \n  "))
        XCTAssertNil(cmd)
    }

    func testGenerateOverrideThrowingYieldsNil() {
        struct SeamFailure: Error {}
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        interp.generateOverride = { _, _ in throw SeamFailure() }
        XCTAssertNil(interpret(interp))
    }

    // MARK: - [NO-GIBBERISH] grammar wiring (2026-09-07)

    func testGenerateOverrideReceivesTheCommandJSONSchema() {
        // The seam mirrors the runtime call `(prompt, jsonSchema)` — this
        // pins that the canonical schema actually reaches the point where
        // llama.cpp is invoked (the pre-2026-09-07 defect was a defined
        // grammar that never reached the runtime call).
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        var receivedSchema: String?
        interp.generateOverride = { _, jsonSchema in
            receivedSchema = jsonSchema
            return """
            {"intent":"query","response":"जवाफ","confidence":0.9,"actionType":null,"actionUrl":null}
            """
        }
        let ctx = InterpreterContext(pendingMedications: [], userLanguageHint: "ne")
        let expectation = expectation(description: "completion fires")
        interp.interpret(transcript: "के छ खबर?", context: ctx) { _ in
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
        XCTAssertEqual(receivedSchema, LlamaGrammar.commandJSONSchema,
                       "the schema the seam receives must be the canonical command schema")
    }

    func testInterpretPassesSanitisedTranscriptAndContextIntoPrompt() {
        // Pins that the seam receives the exact formatted on-device prompt
        // (canonical contract, meds, language hint, transcript) — so the
        // real runtime and the e2e tests exercise the same prompt.
        let interp = LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
        var receivedPrompt: String?
        interp.generateOverride = { prompt, _ in
            receivedPrompt = prompt
            return """
            {"intent":"query","response":"जवाफ","confidence":0.9,"actionType":null,"actionUrl":null}
            """
        }
        let ctx = InterpreterContext(pendingMedications: ["प्रेसरको औषधि"], userLanguageHint: "ne")
        let expectation = expectation(description: "completion fires")
        interp.interpret(transcript: "भोलिको मौसम कस्तो छ?", context: ctx) { _ in
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
        let prompt = try? XCTUnwrap(receivedPrompt)
        XCTAssertTrue(prompt?.contains("भोलिको मौसम कस्तो छ?") == true)
        XCTAssertTrue(prompt?.contains("प्रेसरको औषधि") == true)
        XCTAssertTrue(prompt?.contains("\"intent\"") == true)
        XCTAssertFalse(prompt?.contains("\"action\"") == true)
    }
}
