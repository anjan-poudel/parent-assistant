import XCTest
@testable import ElderlyAssistant

/// intent/v2 wire-shape tests against the shared strict parser
/// (`LlamaCommandInterpreter.parse(json:)`), which both interpreters use.
final class IntentSchemaV2Tests: XCTestCase {

    func testGuideWithTopicAndStepsParses() {
        let json = """
        {"action":"guide","entryId":null,"contact":null,"time":null,
         "medication":null,"message":null,"callType":null,"requestedApp":null,
         "topic":"microwave",
         "steps":["ढोका खोल्नुहोस्","भाँडो भित्र राख्नुहोस्","१ मिनेट बटन थिच्नुहोस्"],
         "confidence":0.92,"reply":"माइक्रोवेभमा तताउने तरिका"}
        """
        let cmd = LlamaCommandInterpreter.parse(json: json)
        XCTAssertEqual(cmd?.action, .guide)
        XCTAssertEqual(cmd?.topic, "microwave")
        XCTAssertEqual(cmd?.steps?.count, 3)
        XCTAssertEqual(cmd?.steps?.first, "ढोका खोल्नुहोस्")
    }

    func testNewV2ActionsParse() {
        for action in ["create_calendar_event", "suggest_video"] {
            let json = """
            {"action":"\(action)","entryId":null,"contact":null,"time":null,
             "medication":null,"message":null,"callType":null,"requestedApp":null,
             "topic":null,"steps":null,"confidence":0.8,"reply":"ठीक छ"}
            """
            XCTAssertNotNil(LlamaCommandInterpreter.parse(json: json),
                            "\(action) must parse")
        }
    }

    func testV1PayloadWithoutNewFieldsStillParses() {
        // Backward compatibility: a v1 model/response that never carries
        // topic/steps decodes with nils (RawCommand optionals).
        let json = """
        {"action":"call","entryId":null,"contact":"maiya","time":null,
         "medication":null,"message":null,"callType":null,"requestedApp":null,
         "confidence":0.9,"reply":"ठीक छ"}
        """
        let cmd = LlamaCommandInterpreter.parse(json: json)
        XCTAssertEqual(cmd?.action, .call)
        XCTAssertEqual(cmd?.contact, "maiya")
        XCTAssertNil(cmd?.topic)
        XCTAssertNil(cmd?.steps)
    }

    func testNullStepsParses() {
        let json = """
        {"action":"guide","entryId":null,"contact":null,"time":null,
         "medication":null,"message":null,"callType":null,"requestedApp":null,
         "topic":"tv remote","steps":null,"confidence":0.7,"reply":"..."}
        """
        let cmd = LlamaCommandInterpreter.parse(json: json)
        XCTAssertEqual(cmd?.action, .guide)
        XCTAssertNil(cmd?.steps)
    }

    func testConfidenceStillClamped() {
        let json = """
        {"action":"query","entryId":null,"contact":null,"time":null,
         "medication":null,"message":null,"callType":null,"requestedApp":null,
         "topic":null,"steps":null,"confidence":1.7,"reply":"..."}
        """
        XCTAssertEqual(LlamaCommandInterpreter.parse(json: json)?.confidence, 1.0)
    }

    func testInterpretedCommandIsCodable() throws {
        // The intent→command cache persists InterpretedCommand — Codable
        // round-trip is a hard requirement of spec §4.2.
        let original = makeCommand(action: .call, contact: "maiya", confidence: 0.83)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InterpretedCommand.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
