import XCTest
@testable import ElderlyAssistant

final class GeminiClientTests: XCTestCase {

    private var configStore: GeminiConfigStore!
    private var bus: MockObservabilityBus!
    private var transport: FakeGeminiTransport!

    override func setUp() {
        super.setUp()
        configStore = GeminiConfigStore(storage: GeminiInMemoryStorage())
        bus = MockObservabilityBus()
        transport = FakeGeminiTransport()
    }

    func testTranscribeThrowsNotConfiguredWithNoAPIKey() async {
        let client = GeminiClient(configStore: configStore, observabilityBus: bus, transport: transport)
        do {
            _ = try await client.transcribe(audioData: Data([1, 2, 3]), mimeType: "audio/wav", languageHint: "ne")
            XCTFail("expected notConfigured")
        } catch GeminiClient.GeminiClientError.notConfigured {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTranscribeReturnsTrimmedTextOnSuccess() async throws {
        configStore.save("fake-key")
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: "  मेरो औषधि खाएँ  "))
        let client = GeminiClient(configStore: configStore, observabilityBus: bus, transport: transport)

        let text = try await client.transcribe(audioData: Data([1, 2, 3]), mimeType: "audio/wav", languageHint: "ne")

        XCTAssertEqual(text, "मेरो औषधि खाएँ")
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "gemini_call" && $0.outcome == "success" })
    }

    func testGenerateJSONReturnsRawTextUntrimmed() async throws {
        configStore.save("fake-key")
        let json = "{\"action\":\"none\",\"confidence\":0.9,\"reply\":\"ok\"}"
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: json))
        let client = GeminiClient(configStore: configStore, observabilityBus: bus, transport: transport)

        let text = try await client.generateJSON(prompt: "irrelevant")

        XCTAssertEqual(text, json)
    }

    func testHTTPErrorStatusThrowsHTTPError() async {
        configStore.save("fake-key")
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: "ignored", statusCode: 429))
        let client = GeminiClient(configStore: configStore, observabilityBus: bus, transport: transport)

        do {
            _ = try await client.generateJSON(prompt: "x")
            XCTFail("expected httpError")
        } catch GeminiClient.GeminiClientError.httpError(let status, _) {
            XCTAssertEqual(status, 429)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testBlockedPromptThrowsBlockedByProvider() async {
        configStore.save("fake-key")
        let payload: [String: Any] = ["promptFeedback": ["blockReason": "SAFETY"]]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
        transport.nextResult = .success((data, response))
        let client = GeminiClient(configStore: configStore, observabilityBus: bus, transport: transport)

        do {
            _ = try await client.generateJSON(prompt: "x")
            XCTFail("expected blockedByProvider")
        } catch GeminiClient.GeminiClientError.blockedByProvider(let reason) {
            XCTAssertEqual(reason, "SAFETY")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTransportFailureIsPropagated() async {
        configStore.save("fake-key")
        struct NetworkDown: Error {}
        transport.nextResult = .failure(NetworkDown())
        let client = GeminiClient(configStore: configStore, observabilityBus: bus, transport: transport)

        do {
            _ = try await client.generateJSON(prompt: "x")
            XCTFail("expected propagated network error")
        } catch is NetworkDown {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

/// Fake `GeminiTransport` — lets tests control the HTTP response/error
/// without touching the network.
final class FakeGeminiTransport: GeminiTransport {
    var nextResult: Result<(Data, URLResponse), Error>!
    private(set) var lastRequest: URLRequest?

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        switch nextResult! {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    static func jsonResponse(text: String, statusCode: Int = 200) -> (Data, URLResponse) {
        let payload: [String: Any] = [
            "candidates": [["content": ["parts": [["text": text]]]]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!,
                                       statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}
