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

    // MARK: - [LAT-EVIDENCE] Timeout bound + [TRUNCATION-FIX] no-retry failures

    func testDefaultTimeoutAlignsWithLlamaFamilyBound() {
        // Coupled numbers: the local interpreter shares the llama
        // family's 10 s inference bound (the 3 s default timed out real
        // generations — device log `inference_timeout` at ~3 s).
        XCTAssertEqual(LocalIntentInterpreter.Config.default.timeoutSeconds, 10,
                       "the local intent interpreter runs under the llama family's 10 s bound")
    }

    func testTruncatedJSONFailsFastWithoutRetry() {
        // [TRUNCATION-FIX] A brace-led partial emission is a budget cut
        // (the "दशैँ कहिले हो" class), and under temp 0 + fixed seed it
        // deterministically repeats — the retry only delayed the honest
        // escalation. One attempt, honest failure reason.
        let storage = StubEncryptedStorage()
        let store = try! ModelStore(observabilityBus: NullObservabilityBus())
        let bus = RecordingObservabilityBus()
        let interpreter = LocalIntentInterpreter(modelStore: store, observabilityBus: bus)
        var calls = 0
        interpreter.generateOverride = { _ in
            calls += 1
            return "{\"action\": \"query\", \"confidence\": 0.9"
        }

        let cmd = interpret(interpreter, "मौसम कस्तो छ")
        XCTAssertNil(cmd)
        XCTAssertEqual(calls, 1, "a truncated JSON output is deterministic — no retry")
        XCTAssertEqual(interpreter.lastInferenceFailureReason, "truncated_json",
                       "the router reads this to escalate to the cloud — never a bare apology")
        XCTAssertTrue(bus.contains("inference_truncated"))
        XCTAssertFalse(bus.contains("inference_retry"),
                       "the deterministic replay retry is gone")
    }

    func testGenerationErrorFailsHonestlyWithoutRetry() {
        // [TRUNCATION-FIX] A thrown generation reports its own honest
        // reason (the truncated-JSON class no longer reaches this path)
        // and does not retry — the failure is not transient.
        let storage = StubEncryptedStorage()
        let store = try! ModelStore(observabilityBus: NullObservabilityBus())
        let bus = RecordingObservabilityBus()
        let interpreter = LocalIntentInterpreter(modelStore: store, observabilityBus: bus)
        var calls = 0
        interpreter.generateOverride = { _ in
            calls += 1
            throw NSError(domain: "t", code: 1)
        }

        XCTAssertNil(interpret(interpreter, "anything"))
        XCTAssertEqual(calls, 1, "a thrown generation does not retry")
        XCTAssertEqual(interpreter.lastInferenceFailureReason, "inference_failed")
        XCTAssertTrue(bus.contains("inference_failed"))
        XCTAssertFalse(bus.contains("inference_retry"))
    }

    func testGarbageIsAnAbstentionNotARetry() {
        // Complete garbage keeps the pre-existing abstention semantics —
        // no retry, no failure reason.
        let storage = StubEncryptedStorage()
        let store = try! ModelStore(observabilityBus: NullObservabilityBus())
        let interpreter = LocalIntentInterpreter(
            modelStore: store, observabilityBus: NullObservabilityBus())
        var calls = 0
        interpreter.generateOverride = { _ in
            calls += 1
            return "not json at all"
        }

        XCTAssertNil(interpret(interpreter, "anything"))
        XCTAssertEqual(calls, 1, "garbage is not a truncation — the model abstained")
        XCTAssertNil(interpreter.lastInferenceFailureReason)
    }

    func testIsTruncatedJSONClassifiesPartialEmissions() {
        XCTAssertTrue(LocalIntentInterpreter.isTruncatedJSON(
            "{\"action\": \"query\", \"conf"))
        XCTAssertTrue(LocalIntentInterpreter.isTruncatedJSON("  {\"a"))
        XCTAssertFalse(LocalIntentInterpreter.isTruncatedJSON("not json at all"))
        XCTAssertFalse(LocalIntentInterpreter.isTruncatedJSON(""))
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
