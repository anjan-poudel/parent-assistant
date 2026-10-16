import XCTest
@testable import ElderlyAssistant

final class GeminiCommandInterpreterTests: XCTestCase {

    private func makeClient(apiKey: String? = "fake-key",
                            result: Result<(Data, URLResponse), Error>) -> (GeminiClient, FakeGeminiTransport) {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        if let apiKey { store.save(apiKey) }
        let transport = FakeGeminiTransport()
        transport.nextResult = result
        let client = GeminiClient(configStore: store, observabilityBus: MockObservabilityBus(), transport: transport)
        return (client, transport)
    }

    func testUnavailableWhenNoAPIKeyYieldsNil() {
        let (client, _) = makeClient(apiKey: nil, result: .success(FakeGeminiTransport.jsonResponse(text: "{}")))
        let interp = GeminiCommandInterpreter(client: client, observabilityBus: MockObservabilityBus())
        XCTAssertFalse(interp.isAvailable)

        let expectation = expectation(description: "completion fires")
        interp.interpret(transcript: "औषधि खाएँ",
                         context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne")) { cmd in
            XCTAssertNil(cmd)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testValidHighConfidenceResponseYieldsCommand() {
        let json = """
        {"action":"ack_med","entryId":null,"contact":null,"time":null,"medication":null,"message":null,"confidence":0.95,"reply":"राम्रो"}
        """
        let (client, _) = makeClient(result: .success(FakeGeminiTransport.jsonResponse(text: json)))
        let interp = GeminiCommandInterpreter(client: client, observabilityBus: MockObservabilityBus())

        let expectation = expectation(description: "completion fires")
        interp.interpret(transcript: "मेरो औषधि खाएँ",
                         context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne")) { cmd in
            XCTAssertEqual(cmd?.action, .ackMed)
            XCTAssertEqual(cmd?.reply, "राम्रो")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testLowConfidenceResponseYieldsNil() {
        let json = """
        {"action":"query","entryId":null,"contact":null,"time":null,"medication":null,"message":null,"confidence":0.2,"reply":"?"}
        """
        let (client, _) = makeClient(result: .success(FakeGeminiTransport.jsonResponse(text: json)))
        let interp = GeminiCommandInterpreter(client: client, observabilityBus: MockObservabilityBus())

        let expectation = expectation(description: "completion fires")
        interp.interpret(transcript: "केही कुरा",
                         context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne")) { cmd in
            XCTAssertNil(cmd)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testNetworkFailureYieldsNilNotACrash() {
        struct NetworkDown: Error {}
        let (client, _) = makeClient(result: .failure(NetworkDown()))
        let interp = GeminiCommandInterpreter(client: client, observabilityBus: MockObservabilityBus())

        let expectation = expectation(description: "completion fires")
        interp.interpret(transcript: "फोन गर",
                         context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne")) { cmd in
            XCTAssertNil(cmd)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testDailyCapReachedYieldsHonestCommandNotNil() {
        // The day's Gemini budget is exhausted. Previously the cap error
        // was flattened to nil here and CommandRouter answered with the
        // generic "I didn't understand" re-prompt — false (the utterance
        // transcribed and routed fine; the budget was gone) and confusing
        // for the user. A capped interpretation must come back as a
        // deterministic `.none` command carrying the localized cap
        // message instead.
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let transport = FakeGeminiTransport()
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: "{}"))
        let bus = MockObservabilityBus()
        let governor = GeminiCostGovernor(storage: GeminiInMemoryStorage(),
                                          observabilityBus: bus)
        governor.setSoftDailyCap(10)
        for _ in 0..<10 { governor.recordCall() }
        XCTAssertFalse(governor.allowsCall())
        let client = GeminiClient(configStore: store, observabilityBus: bus,
                                  transport: transport, costGovernor: governor)
        let interp = GeminiCommandInterpreter(client: client, observabilityBus: bus)

        let expectation = expectation(description: "completion fires")
        interp.interpret(transcript: "भोलि मौसम कस्तो हुन्छ?",
                         context: InterpreterContext(pendingMedications: [],
                                                     userLanguageHint: "ne")) { cmd in
            XCTAssertNotNil(cmd, "a capped interpretation must not look like 'didn't understand'")
            XCTAssertEqual(cmd?.action, InterpretedCommand.Action.none)
            XCTAssertEqual(cmd?.confidence, 1.0,
                           "accept-band confidence so the router's band policy passes it through")
            let locale = Locale(identifier: "ne")
            XCTAssertEqual(cmd?.reply, "आजको जेमिनी जवाफको सीमा पुगिसक्यो। परिवारको कसैले सेटिङमा सीमा बढाउन सक्नुहुन्छ, नत्र पूरा जवाफ भोलि फेरि सुरु हुन्छ।")
            XCTAssertEqual(cmd?.reply, L10n.str("router.capReached", locale: locale))
            XCTAssertNotEqual(cmd?.reply, L10n.str("router.reprompt", locale: locale))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
        XCTAssertNil(transport.lastRequest,
                     "a capped attempt must not reach the network at all")
    }

    func testEmptyTranscriptYieldsNilWithoutCallingNetwork() {
        let (client, transport) = makeClient(result: .success(FakeGeminiTransport.jsonResponse(text: "{}")))
        let interp = GeminiCommandInterpreter(client: client, observabilityBus: MockObservabilityBus())

        let expectation = expectation(description: "completion fires")
        interp.interpret(transcript: "   ",
                         context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne")) { cmd in
            XCTAssertNil(cmd)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
        XCTAssertNil(transport.lastRequest, "should not hit the network for an empty/sanitised-empty transcript")
    }

    // MARK: - [GEMINI-SOLIDIFY] Failure-class reporting

    /// The failure taxonomy's classification, exercised through the REAL
    /// interpreter so the report and the outcome can never drift apart:
    /// each error shape records its class for the chain's bottom-out.
    private func interpretExpectingFailure(_ interp: GeminiCommandInterpreter,
                                           transcript: String = "भोलि मौसम कस्तो?") {
        let expectation = expectation(description: "completion fires")
        interp.interpret(transcript: transcript,
                         context: InterpreterContext(pendingMedications: [],
                                                     userLanguageHint: "ne")) { cmd in
            XCTAssertNil(cmd)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testTransportFailureRecordsTransportFailed() {
        let (client, _) = makeClient(result: .failure(URLError(.notConnectedToInternet)))
        let interp = GeminiCommandInterpreter(client: client, observabilityBus: MockObservabilityBus())

        interpretExpectingFailure(interp)

        XCTAssertEqual(interp.lastCloudFailureClass, .transportFailed)
    }

    func testRateLimitRecordsRateLimited() {
        let (client, _) = makeClient(result: .success(FakeGeminiTransport.jsonResponse(text: "ignored", statusCode: 429)))
        let interp = GeminiCommandInterpreter(client: client, observabilityBus: MockObservabilityBus())

        interpretExpectingFailure(interp)

        XCTAssertEqual(interp.lastCloudFailureClass, .rateLimited)
    }

    func testUnusableResponseRecordsInvalidResponse() {
        let payload: [String: Any] = ["promptFeedback": ["blockReason": "SAFETY"]]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
        let (client, _) = makeClient(result: .success((data, response)))
        let interp = GeminiCommandInterpreter(client: client, observabilityBus: MockObservabilityBus())

        interpretExpectingFailure(interp)

        XCTAssertEqual(interp.lastCloudFailureClass, .invalidResponse)
    }

    func testNotConfiguredRecordsNotConfigured() {
        let (client, _) = makeClient(apiKey: nil, result: .success(FakeGeminiTransport.jsonResponse(text: "{}")))
        let interp = GeminiCommandInterpreter(client: client, observabilityBus: MockObservabilityBus())

        interpretExpectingFailure(interp)

        XCTAssertEqual(interp.lastCloudFailureClass, .notConfigured)
    }

    func testQuotaCappedRecordsQuotaCappedWhileKeepingTheHonestCommand() {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let transport = FakeGeminiTransport()
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: "{}"))
        let bus = MockObservabilityBus()
        let governor = GeminiCostGovernor(storage: GeminiInMemoryStorage(),
                                          observabilityBus: bus)
        governor.setSoftDailyCap(10)
        for _ in 0..<10 { governor.recordCall() }
        let client = GeminiClient(configStore: store, observabilityBus: bus,
                                  transport: transport, costGovernor: governor)
        let interp = GeminiCommandInterpreter(client: client, observabilityBus: bus)

        let expectation = expectation(description: "completion fires")
        interp.interpret(transcript: "भोलि मौसम कस्तो?",
                         context: InterpreterContext(pendingMedications: [],
                                                     userLanguageHint: "ne")) { cmd in
            XCTAssertNotNil(cmd, "the cap still completes with the honest command, not nil")
            XCTAssertEqual(cmd?.action, InterpretedCommand.Action.none)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(interp.lastCloudFailureClass, .quotaCapped,
                       "the class is recorded even when the cap command carries the line")
    }

    func testClearCloudFailureResetsTheReport() {
        let (client, _) = makeClient(result: .failure(URLError(.timedOut)))
        let interp = GeminiCommandInterpreter(client: client, observabilityBus: MockObservabilityBus())

        interpretExpectingFailure(interp)
        XCTAssertEqual(interp.lastCloudFailureClass, .transportFailed)

        interp.clearCloudFailure()
        XCTAssertNil(interp.lastCloudFailureClass)
    }

    // MARK: - [GEMINI-SOLIDIFY] Cascade prompt identity

    /// The cascade's cloud leg must interpret the SAME prepared text the
    /// local brain builds — `IntentPrompt.build` with the same sanitised
    /// transcript and context. Pinned at the wire: the request body's
    /// prompt text equals the shared builder's output byte-for-byte, so
    /// a drift between the local brain's prepared text and what the
    /// cloud receives fails here.
    func testCloudRequestCarriesExactlyTheSharedPreparedText() {
        struct RequestProbe: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]
            }
            let contents: [Content]
        }

        let (client, transport) = makeClient(result: .success(
            FakeGeminiTransport.jsonResponse(
                text: "{\"intent\":\"query\",\"response\":\"ठीक छ\",\"confidence\":0.9}")))
        let interp = GeminiCommandInterpreter(client: client, observabilityBus: MockObservabilityBus())
        let transcript = "छोरालाई फोन गर"
        let context = InterpreterContext(pendingMedications: ["प्रेसरको औषधि"],
                                         userLanguageHint: "ne")

        let expectation = expectation(description: "completion fires")
        interp.interpret(transcript: transcript, context: context) { _ in
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        guard let body = transport.lastRequest?.httpBody,
              let probe = try? JSONDecoder().decode(RequestProbe.self, from: body) else {
            return XCTFail("the request body must decode")
        }
        let clean = InputSanitiser.sanitise(transcript, level: .quarantine)
        let localPrepared = IntentPrompt.build(transcript: clean, context: context)
        XCTAssertEqual(probe.contents.first?.parts.first?.text, localPrepared,
                       "the cloud prompt is the local brain's prepared text, byte-for-byte")
    }
}
