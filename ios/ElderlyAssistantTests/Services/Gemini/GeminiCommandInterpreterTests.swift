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
