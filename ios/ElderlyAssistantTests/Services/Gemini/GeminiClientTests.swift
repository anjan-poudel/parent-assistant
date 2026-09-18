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
        } catch GeminiClient.GeminiClientError.httpError(let status) {
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

    // MARK: - [GEMINI-SOLIDIFY] One bounded retry, transport errors only

    func testDefaultConfigCarriesOneRetryWithBackoff() {
        let config = GeminiClient.Config.default
        XCTAssertEqual(config.timeoutSeconds, 25)
        XCTAssertEqual(config.maxTransportRetries, 1, "one bounded retry — the shipped bound")
        XCTAssertEqual(config.retryBackoffSeconds, 0.5)
    }

    func testTransportErrorRetriesOnceThenSucceeds() async throws {
        configStore.save("fake-key")
        transport.queuedResults = [
            .failure(URLError(.timedOut)),
            .success(FakeGeminiTransport.jsonResponse(text: "{}"))
        ]
        let client = GeminiClient(configStore: configStore, observabilityBus: bus,
                                  transport: transport,
                                  config: .init(timeoutSeconds: 25,
                                                maxTransportRetries: 1,
                                                retryBackoffSeconds: 0))

        _ = try await client.generateJSON(prompt: "x")

        XCTAssertEqual(transport.sendCount, 2, "a timed-out transport error is retried exactly once")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "gemini_transport_retry" && $0.outcome == "retrying"
        }, "the retry is observable")
    }

    func testTransportErrorRetriesOnceThenPropagates() async {
        configStore.save("fake-key")
        transport.queuedResults = [
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.networkConnectionLost))
        ]
        let client = GeminiClient(configStore: configStore, observabilityBus: bus,
                                  transport: transport,
                                  config: .init(timeoutSeconds: 25,
                                                maxTransportRetries: 1,
                                                retryBackoffSeconds: 0))

        do {
            _ = try await client.generateJSON(prompt: "x")
            XCTFail("expected the second transport failure to propagate")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
            XCTAssertEqual(transport.sendCount, 2, "the retry budget is exactly ONE extra attempt")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUnretryableTransportErrorsAreNeverRepeated() async {
        configStore.save("fake-key")
        transport.queuedResults = [
            .failure(URLError(.cancelled)),
            .success(FakeGeminiTransport.jsonResponse(text: "{}"))
        ]
        let client = GeminiClient(configStore: configStore, observabilityBus: bus,
                                  transport: transport,
                                  config: .init(timeoutSeconds: 25,
                                                maxTransportRetries: 1,
                                                retryBackoffSeconds: 0))

        do {
            _ = try await client.generateJSON(prompt: "x")
            XCTFail("expected cancellation to propagate")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
            XCTAssertEqual(transport.sendCount, 1,
                           "a cancellation is a decision, not a fault — never retried")
            XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "gemini_transport_retry" })
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRateLimitHTTPRefusalIsNeverRetried() async {
        configStore.save("fake-key")
        transport.queuedResults = [
            .success(FakeGeminiTransport.jsonResponse(text: "ignored", statusCode: 429)),
            .success(FakeGeminiTransport.jsonResponse(text: "{}"))
        ]
        let client = GeminiClient(configStore: configStore, observabilityBus: bus,
                                  transport: transport,
                                  config: .init(timeoutSeconds: 25,
                                                maxTransportRetries: 1,
                                                retryBackoffSeconds: 0))

        do {
            _ = try await client.generateJSON(prompt: "x")
            XCTFail("expected httpError")
        } catch GeminiClient.GeminiClientError.httpError(let status) {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(transport.sendCount, 1,
                           "a rate-limit refusal is an honest answer, not a failure to retry")
            XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "gemini_transport_retry" })
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - [GEMINI-SOLIDIFY] Test connection round-trip

    func testConnectionTestSucceedsOnARoundTrip() async {
        configStore.save("fake-key")
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: "{\"ok\": true}"))
        let client = GeminiClient(configStore: configStore, observabilityBus: bus, transport: transport)

        let outcome = await client.testConnection()

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(transport.sendCount, 1, "the test is one real round-trip")
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "gemini_call" && $0.outcome == "success" })
    }

    func testConnectionTestReportsTheFailureClass() async {
        configStore.save("fake-key")
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: "ignored", statusCode: 429))
        let client = GeminiClient(configStore: configStore, observabilityBus: bus, transport: transport)

        let outcome = await client.testConnection()

        XCTAssertEqual(outcome, .failure(.rateLimited),
                       "the test reports the failure CLASS, the same vocabulary the spoken lines use")
    }

    func testConnectionTestWithoutAKeyReportsNotConfigured() async {
        let client = GeminiClient(configStore: configStore, observabilityBus: bus, transport: transport)

        let outcome = await client.testConnection()

        XCTAssertEqual(outcome, .failure(.notConfigured))
        XCTAssertEqual(transport.sendCount, 0, "no network attempt without a key")
    }

    func testConnectionTestTransportFailureReportsTransportFailed() async {
        configStore.save("fake-key")
        transport.nextResult = .failure(URLError(.notConnectedToInternet))
        let client = GeminiClient(configStore: configStore, observabilityBus: bus, transport: transport)

        let outcome = await client.testConnection()

        XCTAssertEqual(outcome, .failure(.transportFailed))
    }

    func testConnectionTestPromptIsFixedAndContentFree() {
        XCTAssertTrue(GeminiClient.connectionTestPrompt.contains("{\"ok\": true}"))
        XCTAssertFalse(GeminiClient.connectionTestPrompt.contains("transcript"))
    }
}

// MARK: - Failure-class taxonomy ([GEMINI-SOLIDIFY])

final class GeminiFailureClassTests: XCTestCase {

    func testClassifiesEveryGeminiClientErrorDeliberately() {
        XCTAssertEqual(GeminiFailureClass.classify(GeminiClient.GeminiClientError.notConfigured),
                       .notConfigured)
        XCTAssertEqual(GeminiFailureClass.classify(GeminiClient.GeminiClientError.invalidURL),
                       .notConfigured, "a request that cannot be built is a configuration defect")
        XCTAssertEqual(GeminiFailureClass.classify(GeminiClient.GeminiClientError.dailyCapReached),
                       .quotaCapped)
        XCTAssertEqual(GeminiFailureClass.classify(GeminiClient.GeminiClientError.httpError(status: 429)),
                       .rateLimited)
        XCTAssertEqual(GeminiFailureClass.classify(GeminiClient.GeminiClientError.httpError(status: 500)),
                       .invalidResponse)
        XCTAssertEqual(GeminiFailureClass.classify(GeminiClient.GeminiClientError.httpError(status: 400)),
                       .invalidResponse, "a bad request is not retried and not a wire fault")
        XCTAssertEqual(GeminiFailureClass.classify(GeminiClient.GeminiClientError.invalidResponse),
                       .invalidResponse)
        XCTAssertEqual(GeminiFailureClass.classify(GeminiClient.GeminiClientError.emptyResponse),
                       .invalidResponse)
        XCTAssertEqual(GeminiFailureClass.classify(GeminiClient.GeminiClientError.blockedByProvider(reason: "SAFETY")),
                       .invalidResponse)
    }

    func testClassifiesTransportErrorsAsTransportFailed() {
        XCTAssertEqual(GeminiFailureClass.classify(URLError(.timedOut)), .transportFailed)
        XCTAssertEqual(GeminiFailureClass.classify(URLError(.notConnectedToInternet)), .transportFailed)
        struct UnknownTransportError: Error {}
        XCTAssertEqual(GeminiFailureClass.classify(UnknownTransportError()), .transportFailed,
                       "an unrecognised error from the transport seam is a transport failure")
    }

    func testClassifiesUndecodableBodiesAsInvalidResponse() {
        enum Sample: Error { case badJSON }
        // DecodingError is the shape JSONDecoder throws for a body that
        // does not decode — the request DID reach the provider.
        let decodingError = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "boom"))
        XCTAssertEqual(GeminiFailureClass.classify(decodingError), .invalidResponse)
    }

    func testEveryClassHasADistinctSpokenLineAndAllResolve() {
        let en = Locale(identifier: "en")
        let ne = Locale(identifier: "ne")
        var seen = Set<String>()
        for failureClass in GeminiFailureClass.allCases {
            let english = failureClass.spokenLine(locale: en)
            let nepali = failureClass.spokenLine(locale: ne)
            XCTAssertFalse(english.isEmpty, "every class speaks, never silence")
            XCTAssertFalse(nepali.isEmpty)
            XCTAssertTrue(seen.insert(english).inserted,
                          "distinct spoken lines — \(failureClass) duplicates another")
            seen.insert(nepali)
        }
    }

    func testQuotaCappedReusesTheCapLine() {
        XCTAssertEqual(GeminiFailureClass.quotaCapped.spokenLineKey, "router.capReached",
                       "the cap line is the ONE quota line — the interpreter's cap command "
                       + "and the bottom-out speak the same words")
        XCTAssertEqual(GeminiFailureClass.quotaCapped.spokenLine(locale: Locale(identifier: "ne")),
                       L10n.str("router.capReached", locale: Locale(identifier: "ne")))
    }

    func testTransportLineNamesTheOnDeviceFallback() {
        XCTAssertTrue(GeminiFailureClass.transportFailed
            .spokenLine(locale: Locale(identifier: "en"))
            .localizedCaseInsensitiveContains("on-device brain"))
        XCTAssertTrue(GeminiFailureClass.transportFailed
            .spokenLine(locale: Locale(identifier: "ne"))
            .contains("डिभाइसकै दिमाग"))
    }
}

/// Fake `GeminiTransport` — lets tests control the HTTP response/error
/// without touching the network.
final class FakeGeminiTransport: GeminiTransport {
    var nextResult: Result<(Data, URLResponse), Error>!
    /// [GEMINI-SOLIDIFY] A scripted queue for multi-attempt tests (the
    /// retry loop calls `send` repeatedly). When non-empty, each `send`
    /// consumes the first element; `nextResult` is the single-shot
    /// fallback and is untouched while the queue drains.
    var queuedResults: [Result<(Data, URLResponse), Error>] = []
    private(set) var lastRequest: URLRequest?
    private(set) var sendCount = 0

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        sendCount += 1
        if !queuedResults.isEmpty {
            let result = queuedResults.removeFirst()
            switch result {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }
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
