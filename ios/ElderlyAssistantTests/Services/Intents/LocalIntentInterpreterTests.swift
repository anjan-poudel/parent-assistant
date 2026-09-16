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
            interpreter.generateOverride = { _, _ in
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

    // MARK: - [LAT-EVIDENCE] Timeout bound + truncated-JSON retry

    func testDefaultTimeoutAlignsWithLlamaFamilyBound() {
        // Coupled numbers: the local interpreter shares the llama
        // family's 10 s inference bound (the 3 s default timed out real
        // generations — device log `inference_timeout` at ~3 s).
        XCTAssertEqual(LocalIntentInterpreter.Config.default.timeoutSeconds, 10,
                       "the local intent interpreter runs under the llama family's 10 s bound")
    }

    func testTruncatedJSONRetriesOnceAndSucceeds() {
        let storage = StubEncryptedStorage()
        let store = try! ModelStore(observabilityBus: NullObservabilityBus())
        let interpreter = LocalIntentInterpreter(
            modelStore: store, observabilityBus: NullObservabilityBus())
        var calls = 0
        interpreter.generateOverride = { _, _ in
            calls += 1
            if calls == 1 {
                // The device-log truncated class: a partial emission.
                return "{\"action\": \"query\", \"confidence\": 0.9"
            }
            return """
            {"action":"query","entryId":null,"contact":null,"time":null,
             "medication":null,"message":null,"callType":null,"requestedApp":null,
             "topic":null,"steps":null,"confidence":0.9,"reply":"ठीक छ"}
            """
        }

        let cmd = interpret(interpreter, "मौसम कस्तो छ")
        XCTAssertEqual(calls, 2, "a truncated JSON output retries exactly once")
        XCTAssertEqual(cmd?.action, .query)
        XCTAssertNil(interpreter.lastInferenceFailureReason)
    }

    func testTruncatedJSONTwiceIsAnHonestFailureNotAnApology() {
        let storage = StubEncryptedStorage()
        let store = try! ModelStore(observabilityBus: NullObservabilityBus())
        let bus = RecordingObservabilityBus()
        let interpreter = LocalIntentInterpreter(modelStore: store, observabilityBus: bus)
        var calls = 0
        interpreter.generateOverride = { _, _ in
            calls += 1
            return "{\"action\": \"query\", \"conf"
        }

        let cmd = interpret(interpreter, "मौसम कस्तो छ")
        XCTAssertNil(cmd)
        XCTAssertEqual(calls, 2, "one retry, then the failure is reported")
        XCTAssertEqual(interpreter.lastInferenceFailureReason, "truncated_json",
                       "the router reads this to escalate to the cloud — never a bare apology")
        XCTAssertTrue(bus.contains("inference_retry"))
        XCTAssertTrue(bus.contains("inference_truncated"))
    }

    func testGenerationErrorRetriesOnceThenFailsHonestly() {
        let storage = StubEncryptedStorage()
        let store = try! ModelStore(observabilityBus: NullObservabilityBus())
        let interpreter = LocalIntentInterpreter(
            modelStore: store, observabilityBus: NullObservabilityBus())
        var calls = 0
        interpreter.generateOverride = { _, _ in
            calls += 1
            throw NSError(domain: "t", code: 1)
        }

        XCTAssertNil(interpret(interpreter, "anything"))
        XCTAssertEqual(calls, 2, "a thrown generation (the real path's truncated-decode class) retries once")
        XCTAssertEqual(interpreter.lastInferenceFailureReason, "truncated_json")
    }

    func testGarbageIsAnAbstentionNotARetry() {
        // Complete garbage keeps the pre-existing abstention semantics —
        // no retry, no failure reason.
        let storage = StubEncryptedStorage()
        let store = try! ModelStore(observabilityBus: NullObservabilityBus())
        let interpreter = LocalIntentInterpreter(
            modelStore: store, observabilityBus: NullObservabilityBus())
        var calls = 0
        interpreter.generateOverride = { _, _ in
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

    // MARK: - [CASCADE-RUNTIME] Generation budget + the two stop classes

    /// The prompt the interpreter really builds for a transcript — used to
    /// reproduce the budget the turn allocates.
    private func promptFor(_ transcript: String) -> String {
        IntentPrompt.build(
            transcript: InputSanitiser.sanitise(transcript, level: .quarantine),
            context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne"))
    }

    /// The device failure this pins: the FIRST attempt ran on a context
    /// sized by the turn (prompt ceiling + the schema's upper bound + the
    /// margin), and the retry ran on a STRICTLY LARGER one — the shipped
    /// retry re-ran inside the same 1024-token allocation that had just
    /// truncated, so with greedy sampling and a fixed seed it reproduced
    /// the identical prefix and failed identically.
    func testTheRetryGrowsTheContextBudgetInsteadOfRepeatingIt() {
        let store = try! ModelStore(observabilityBus: NullObservabilityBus())
        let interpreter = LocalIntentInterpreter(
            modelStore: store, observabilityBus: NullObservabilityBus())
        var calls = 0
        interpreter.generateOverride = { _, _ in
            calls += 1
            if calls == 1 {
                return "{\"action\": \"query\", \"confidence\": 0.9"   // the device class
            }
            return """
            {"action":"query","entryId":null,"contact":null,"time":null,
             "medication":null,"message":null,"callType":null,"requestedApp":null,
             "topic":null,"steps":null,"confidence":0.9,"reply":"ठीक छ"}
            """
        }

        let transcript = "मौसम कस्तो छ"
        let cmd = interpret(interpreter, transcript)

        XCTAssertEqual(cmd?.action, .query, "the retry, on the bigger budget, succeeded")
        XCTAssertEqual(interpreter.attemptContextTokens.count, 2,
                       "one attempt + one retry — the budget record proves both ran")
        guard interpreter.attemptContextTokens.count == 2 else { return }
        let first = interpreter.attemptContextTokens[0]
        let retry = interpreter.attemptContextTokens[1]
        XCTAssertEqual(first, OnDeviceGenerationBudget.contextTokens(
            prompt: promptFor(transcript),
            schema: LocalIntentInterpreter.intentSchema,
            framingTokens: OnDeviceGenerationBudget.rawFramingTokens),
                       "attempt 0 runs on the turn's own requirement")
        XCTAssertGreaterThan(retry, first,
                             "the retry must not re-run inside the allocation that truncated")
        XCTAssertGreaterThanOrEqual(retry - first,
                                    OnDeviceGenerationBudget.contextQuantum,
                                    "growth is at least one quantum")
        XCTAssertGreaterThanOrEqual(
            retry, OnDeviceGenerationBudget.grownContextTokens(
                first, schema: LocalIntentInterpreter.intentSchema))
        XCTAssertLessThanOrEqual(retry, OnDeviceGenerationBudget.maximumContextTokens,
                                 "…and the ceiling still holds — the memory side is real")
    }

    /// The budget's contract for the LOCAL brain: a schema-complete JSON of
    /// the maximum size the design caps allow fits behind the prompt, with
    /// the safety margin, in the context the first attempt allocates.
    func testTheAllocatedContextFitsASchemaCompleteJSON() {
        let transcript = "मौसम कस्तो छ"
        let budget = OnDeviceGenerationBudget.contextTokens(
            prompt: promptFor(transcript),
            schema: LocalIntentInterpreter.intentSchema,
            framingTokens: OnDeviceGenerationBudget.rawFramingTokens)
        let ceiling = OnDeviceGenerationBudget.promptCeilingTokens(
            prompt: promptFor(transcript),
            framingTokens: OnDeviceGenerationBudget.rawFramingTokens)
        let bound = OnDeviceGenerationBudget.schemaUpperBoundTokens(
            for: LocalIntentInterpreter.intentSchema)
        XCTAssertGreaterThanOrEqual(
            budget - ceiling, bound + OnDeviceGenerationBudget.safetyMarginTokens,
            "prompt + a maximum-size JSON + the margin must fit — the shipped 1024 did not")
    }

    /// The class a budget cannot fix: the model ends the value itself. The
    /// runtime's `.completeJSON` policy skips up to
    /// `LLMCore.maxSkippedEndTokens` premature end tokens; the residue is a
    /// `premature_stop`, and the failure must say so — a bigger context is
    /// not the answer for it.
    func testPrematureStopIsReportedAsItsOwnFailureClass() {
        let store = try! ModelStore(observabilityBus: NullObservabilityBus())
        let bus = RecordingObservabilityBus()
        let interpreter = LocalIntentInterpreter(modelStore: store, observabilityBus: bus)
        var calls = 0
        interpreter.generateOverride = { _, _ in
            calls += 1
            return "{\"action\": \"query\", \"conf"   // open value, ended by an end token
        }
        interpreter.prematureStopOverride = { _ in true }

        XCTAssertNil(interpret(interpreter, "मौसम कस्तो छ"))
        XCTAssertEqual(calls, 2, "the retry still happens — the class is not assumed")
        XCTAssertEqual(interpreter.lastInferenceFailureReason, "premature_stop",
                       "the reason names the class the evidence points to, not a budget one")
        XCTAssertEqual(LocalIntentInterpreter.failureReason(prematureStop: true), "premature_stop")
        XCTAssertEqual(LocalIntentInterpreter.failureReason(prematureStop: false), "truncated_json")
    }

    /// The classes are told apart by the RUNTIME'S report, not by the text:
    /// the same truncated bytes are a budget failure when the context ran
    /// out and a premature stop when an end token ended the value. (The
    /// runtime's own `isCompleteJSONValue` predicate and its `#if DEBUG`
    /// log guards are compiled in the vendored package, which the app test
    /// bundle cannot `import`; the app-side decision is what is pinned
    /// here.)
    func testTheFailureReasonComesFromTheRuntimeReportNotTheText() {
        func reason(prematureStop: Bool) -> String? {
            let store = try! ModelStore(observabilityBus: NullObservabilityBus())
            let interpreter = LocalIntentInterpreter(
                modelStore: store, observabilityBus: NullObservabilityBus())
            interpreter.generateOverride = { _, _ in "{\"action\": \"query\", \"conf" }
            interpreter.prematureStopOverride = { _ in prematureStop }
            _ = interpret(interpreter, "मौसम कस्तो छ")
            return interpreter.lastInferenceFailureReason
        }
        XCTAssertEqual(reason(prematureStop: true), "premature_stop")
        XCTAssertEqual(reason(prematureStop: false), "truncated_json")
        XCTAssertNotEqual(reason(prematureStop: true), reason(prematureStop: false),
                          "the same bytes must not always report the same class")
    }
}
