import XCTest
@testable import ElderlyAssistant

/// [INTENT-TOOLS] (2026-09-07) Web-search tool-config wiring on the cloud
/// (Gemini) stack: Google Search grounding rides on the intent-path
/// requests (the interpreter's `generateJSON` and the collapsed
/// `understand`), the request body actually carries the `google_search`
/// tool, a grounded response is observable as `intent_tool_websearch`
/// grounded (ungrounded = not_used), requests WITHOUT the flag carry NO
/// tool config at all, and grounded requests still count through the
/// shared cost governor — the tool is never a billing or cap bypass.
/// (The tool DECISION itself is Gemini's per question; these tests pin
/// the wiring and the observability around it, not the model.)
final class IntentToolWebSearchTests: XCTestCase {

    private let query = "भोलि काठमाडौंमा पानी पर्छ?"
    private let commandJSON = """
    {"action":"query","entryId":null,"contact":null,"time":null,"medication":null,\
    "message":null,"callType":null,"requestedApp":null,"confidence":0.9,\
    "reply":"भोलि काठमाडौंमा हल्का पानी पर्ने सम्भावना छ।"}
    """

    // MARK: - Helpers

    private func makeConfiguredClient(bus: MockObservabilityBus? = nil,
                                      transport: FakeGeminiTransport? = nil,
                                      costGovernor: GeminiCostGovernor? = nil)
        -> (GeminiClient, FakeGeminiTransport, MockObservabilityBus) {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let bus = bus ?? MockObservabilityBus()
        let transport = transport ?? FakeGeminiTransport()
        let client = GeminiClient(configStore: store, observabilityBus: bus,
                                  transport: transport, costGovernor: costGovernor)
        return (client, transport, bus)
    }

    /// The wire-format `tools` array of the LAST sent request (nil when
    /// the request carried no tool config) — decoded with
    /// JSONSerialization so the assertion pins the exact JSON shape
    /// Gemini sees, independent of `GeminiRequest`'s Codable layout.
    private func sentTools(_ transport: FakeGeminiTransport) -> [[String: Any]]? {
        guard let body = transport.lastRequest?.httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return json["tools"] as? [[String: Any]]
    }

    private func webSearchEvents(_ bus: MockObservabilityBus) -> [ObservabilityEvent] {
        bus.emittedEvents.filter { $0.eventType == "intent_tool_websearch" }
    }

    /// A successful response whose candidate carries `groundingMetadata`
    /// — the wire shape Google returns when the model actually used the
    /// `google_search` tool (cited live results).
    private func groundedJSONResponse(text: String) -> (Data, URLResponse) {
        let payload: [String: Any] = [
            "candidates": [[
                "content": ["parts": [["text": text]]],
                "groundingMetadata": [:]
            ]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }

    /// The interpreter must be KEPT ALIVE across `wait(for:)` by the test
    /// method: its `interpret` work runs in a `Task { [weak self] … }`, so
    /// an interpreter that goes out of scope before the task body starts
    /// silently never calls completion (2026-09-07 — the original helper
    /// scoped it away and every call timed out).
    private func makeInterpreter(client: GeminiClient) -> GeminiCommandInterpreter {
        GeminiCommandInterpreter(client: client, observabilityBus: MockObservabilityBus())
    }

    // MARK: - Interpreter requests carry the google_search tool

    func testInterpreterRequestCarriesGoogleSearchTool() {
        let (client, transport, bus) = makeConfiguredClient()
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: commandJSON))
        let interp = makeInterpreter(client: client)

        let expectation = expectation(description: "completion fires")
        interp.interpret(transcript: query,
                         context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne")) { cmd in
            XCTAssertNotNil(cmd, "the plain (ungrounded) response still parses into a command")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let tools = sentTools(transport)
        XCTAssertEqual(tools?.count, 1, "exactly one tool may be configured")
        XCTAssertEqual(tools?.first?.keys.first, "google_search",
                       "the request body must carry google_search (Google Search grounding)")
        // The model answered from knowledge alone here → observable as
        // not_used, never silently assumed.
        XCTAssertEqual(webSearchEvents(bus).map(\.outcome), ["not_used"])
    }

    func testGroundedInterpreterResponseEmitsGroundedOutcome() {
        let (client, transport, bus) = makeConfiguredClient()
        transport.nextResult = .success(groundedJSONResponse(text: commandJSON))
        let interp = makeInterpreter(client: client)

        let expectation = expectation(description: "completion fires")
        interp.interpret(transcript: query,
                         context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne")) { cmd in
            XCTAssertEqual(cmd?.action, .query)
            XCTAssertEqual(cmd?.reply, "भोलि काठमाडौंमा हल्का पानी पर्ने सम्भावना छ।")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(webSearchEvents(bus).map(\.outcome), ["grounded"],
                       "a response with groundingMetadata is a REAL web search")
        XCTAssertNotNil(sentTools(transport))
    }

    // MARK: - Requests without the flag carry NO tool config

    func testPlainGenerateJSONCarriesNoToolConfigAndNoToolEvent() async throws {
        let (client, transport, bus) = makeConfiguredClient()
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: "plain"))

        let text = try await client.generateJSON(prompt: "hello")
        XCTAssertEqual(text, "plain")
        XCTAssertNil(sentTools(transport),
                     "a non-grounded request must not grow a tools array")
        XCTAssertTrue(webSearchEvents(bus).isEmpty,
                      "no tool configured → no intent_tool_websearch event")
    }

    func testUnderstandCarriesToolOnlyWhenGroundingIsAsked() async throws {
        // Collapse path, grounding ON — the recognizer's wiring.
        let (client, transport, bus) = makeConfiguredClient()
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: commandJSON))
        let understanding = try await client.understand(
            audioData: Data([1, 2, 3]), mimeType: "audio/wav",
            context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne"),
            useSearchGrounding: true)
        XCTAssertEqual(understanding.transcript, "")
        XCTAssertEqual(sentTools(transport)?.first?.keys.first, "google_search")
        XCTAssertEqual(webSearchEvents(bus).map(\.outcome), ["not_used"])

        // Grounding OFF — the pre-intent-tools contract, byte for byte.
        let (client2, transport2, bus2) = makeConfiguredClient()
        transport2.nextResult = .success(FakeGeminiTransport.jsonResponse(text: commandJSON))
        _ = try await client2.understand(
            audioData: Data([1, 2, 3]), mimeType: "audio/wav",
            context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne"),
            useSearchGrounding: false)
        XCTAssertNil(sentTools(transport2))
        XCTAssertTrue(webSearchEvents(bus2).isEmpty)
    }

    // MARK: - Cost governor interaction — grounding is never a bypass

    func testGroundedRequestsStillCountAndCapStillBlocksThem() async throws {
        let storage = GeminiInMemoryStorage()
        let bus = MockObservabilityBus()
        let governor = GeminiCostGovernor(storage: storage, observabilityBus: bus,
                                          now: { Date() })
        governor.setSoftDailyCap(10)
        let (client, transport, _) = makeConfiguredClient(bus: bus, costGovernor: governor)
        transport.nextResult = .success(groundedJSONResponse(text: "grounded answer"))

        _ = try await client.generateJSON(prompt: query, useSearchGrounding: true)
        XCTAssertEqual(webSearchEvents(bus).map(\.outcome), ["grounded"])

        // Burn the rest of the day's budget. A second grounded attempt
        // must be refused by the SAME gate as every other call — the
        // google_search tool changes nothing about billing.
        for _ in 0..<9 { governor.recordCall() }
        XCTAssertFalse(governor.allowsCall())

        let (cappedClient, cappedTransport, _) = makeConfiguredClient(bus: bus, costGovernor: governor)
        do {
            _ = try await cappedClient.generateJSON(prompt: query, useSearchGrounding: true)
            XCTFail("a capped grounded request must throw dailyCapReached")
        } catch GeminiClient.GeminiClientError.dailyCapReached {
            // expected — the tool does not bypass the governor
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(cappedTransport.lastRequest,
                     "a capped attempt must not reach the network at all")
        XCTAssertEqual(webSearchEvents(bus).map(\.outcome), ["grounded"],
                       "a refused attempt emits no tool event — nothing was searched")
    }

    // MARK: - SSE grounded probe (pure function)

    func testSSEFrameGroundedProbe() {
        XCTAssertTrue(GeminiClient.sseFrameIsGrounded(
            #"data: {"candidates":[{"groundingMetadata":{},"content":{"parts":[{"text":"x"}]}}]}"#))
        XCTAssertFalse(GeminiClient.sseFrameIsGrounded(
            #"data: {"candidates":[{"content":{"parts":[{"text":"x"}]}}]}"#),
            "a frame WITHOUT groundingMetadata is not a search")
        XCTAssertFalse(GeminiClient.sseFrameIsGrounded("data: [DONE]"))
        XCTAssertFalse(GeminiClient.sseFrameIsGrounded("event: message"))
        XCTAssertFalse(GeminiClient.sseFrameIsGrounded(""))
        XCTAssertFalse(GeminiClient.sseFrameIsGrounded("not json at all"))
    }
}
