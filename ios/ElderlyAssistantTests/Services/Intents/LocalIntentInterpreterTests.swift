import XCTest
@testable import ElderlyAssistant

/// LocalIntentInterpreter (spec §8) via the generateOverride seam —
/// everything except llama.cpp itself: availability, sanitisation,
/// threshold, parse-failure behavior.
final class LocalIntentInterpreterTests: XCTestCase {

    private func makeInterpreter(
        result: String?,
        available: Bool = true
    ) -> (LocalIntentInterpreter, StubEncryptedStorage) {
        let storage = StubEncryptedStorage()
        let store = try! ModelStore(observabilityBus: NullObservabilityBus())
        let interpreter = LocalIntentInterpreter(
            modelStore: store, observabilityBus: NullObservabilityBus())
        if available {
            interpreter.generateOverride = { _ in
                guard let result else { throw NSError(domain: "t", code: 1) }
                return result
            }
        }
        return (interpreter, storage)
    }

    private func interpret(_ i: LocalIntentInterpreter, _ t: String) -> InterpretedCommand? {
        let exp = expectation(description: "interpret")
        var out: InterpretedCommand?
        i.interpret(transcript: t,
                    context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne")) { r in
            out = r
            exp.fulfill()
        }
        waitForExpectations(timeout: 3)
        return out
    }

    func testUnavailableWithoutModelOrOverride() {
        let (interpreter, _) = makeInterpreter(result: nil, available: false)
        XCTAssertFalse(interpreter.isAvailable)
        XCTAssertNil(interpret(interpreter, "माइयालाई फोन गर"))
    }

    func testParsesValidJSON() {
        let json = """
        {"action":"call","entryId":null,"contact":"माइया","time":null,
         "medication":null,"message":null,"callType":null,"requestedApp":null,
         "topic":null,"steps":null,"confidence":0.92,"reply":"ठीक छ"}
        """
        let (interpreter, _) = makeInterpreter(result: json)
        let cmd = interpret(interpreter, "माइयालाई फोन गर")
        XCTAssertEqual(cmd?.action, .call)
        XCTAssertEqual(cmd?.contact, "माइया")
    }

    func testBelowThresholdReturnsNil() {
        let json = """
        {"action":"music","entryId":null,"contact":null,"time":null,
         "medication":null,"message":null,"callType":null,"requestedApp":null,
         "topic":null,"steps":null,"confidence":0.2,"reply":"..."}
        """
        let (interpreter, _) = makeInterpreter(result: json)
        XCTAssertNil(interpret(interpreter, "केही बजाउ"))
    }

    func testGarbageReturnsNil() {
        let (interpreter, _) = makeInterpreter(result: "not json at all")
        XCTAssertNil(interpret(interpreter, "anything"))
    }

    func testGenerationErrorReturnsNil() {
        let (interpreter, _) = makeInterpreter(result: nil)
        XCTAssertNil(interpret(interpreter, "anything"))
    }

    func testSchemaCoversAllV2Actions() {
        // The grammar-constrained schema must name every v2 action, or
        // the model literally cannot emit it.
        for action in ["ack_med", "call", "emergency", "set_reminder", "health_query",
                       "music", "send_message", "guide", "create_calendar_event",
                       "suggest_video", "query", "none"] {
            XCTAssertTrue(LocalIntentInterpreter.intentSchema.contains("\"\(action)\""),
                          "\(action) missing from the constrained schema")
        }
        XCTAssertTrue(LocalIntentInterpreter.intentSchema.contains("\"steps\""))
        XCTAssertTrue(LocalIntentInterpreter.intentSchema.contains("\"topic\""))
    }
}
