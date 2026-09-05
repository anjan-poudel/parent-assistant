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

    // MARK: - Parse

    func testParseValidJSONYieldsCommand() throws {
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

    // MARK: - Grammar

    func testGrammarIncludesAllRequiredFields() {
        let g = LlamaGrammar.commandJSON
        XCTAssertTrue(g.contains("\\\"action\\\""))
        XCTAssertTrue(g.contains("\\\"entryId\\\""))
        XCTAssertTrue(g.contains("\\\"contact\\\""))
        XCTAssertTrue(g.contains("\\\"time\\\""))
        XCTAssertTrue(g.contains("\\\"medication\\\""))
        XCTAssertTrue(g.contains("\\\"confidence\\\""))
        XCTAssertTrue(g.contains("\\\"reply\\\""))
        // Actions enumerated exactly.
        XCTAssertTrue(g.contains("\\\"ack_med\\\""))
        XCTAssertTrue(g.contains("\\\"call\\\""))
        XCTAssertTrue(g.contains("\\\"emergency\\\""))
        XCTAssertTrue(g.contains("\\\"set_reminder\\\""))
        XCTAssertTrue(g.contains("\\\"health_query\\\""))
        XCTAssertTrue(g.contains("\\\"music\\\""))
        XCTAssertTrue(g.contains("\\\"query\\\""))
        XCTAssertTrue(g.contains("\\\"none\\\""))
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
}
