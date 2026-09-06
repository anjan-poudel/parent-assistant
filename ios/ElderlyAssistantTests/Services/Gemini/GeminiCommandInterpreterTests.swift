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
}
