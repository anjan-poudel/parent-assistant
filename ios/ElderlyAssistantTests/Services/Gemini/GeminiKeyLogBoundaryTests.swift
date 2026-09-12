import XCTest
import AVFoundation
@testable import ElderlyAssistant

/// T-050 regression pin (security-test SECURITY-NO_GO, finding B2): the
/// Gemini API key and raw upstream bodies must never reach a log sink.
///
/// The leak of record: the key rode in the request URL's query string, a
/// forced transport failure rethrew the untouched `URLError` (whose
/// description embeds the failing URL), the emitter sites stringified it
/// with `String(describing:)` into `error_code`, and `LogSanitiser` copied
/// that field through unscrubbed — the key landed on the console.
///
/// The tests below exercise the configured-client error path (real
/// `GeminiClient` + real emitter sites + the real `ConsoleObservabilityBus`
/// sink), not a mock-free unit of the formatter.
///
/// NFR-016: the sentinel key below is deliberately not key-shaped, and the
/// upstream bodies are synthetic — no realistic secrets in tests.
final class GeminiKeyLogBoundaryTests: XCTestCase {

    private let sentinelKey = "sentinel-not-a-real-key-000"

    private func makeStore() -> GeminiConfigStore {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save(sentinelKey)
        return store
    }

    private func makeInterpreterContext() -> InterpreterContext {
        InterpreterContext(pendingMedications: [], userLanguageHint: "ne")
    }

    private func keyBearingURL() -> URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/x:generateContent?key=\(sentinelKey)")!
    }

    // MARK: - (a) The key is not carried in a URL

    func testUnaryRequestCarriesKeyInHeaderAndNotInURL() async throws {
        let transport = FakeGeminiTransport()
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: "ok"))
        let client = GeminiClient(configStore: makeStore(),
                                  observabilityBus: MockObservabilityBus(),
                                  transport: transport)

        _ = try await client.generateJSON(prompt: "irrelevant")

        let request = try XCTUnwrap(transport.lastRequest)
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertFalse(url.contains(sentinelKey), "the key must not be in the URL: \(url)")
        XCTAssertFalse(url.contains("key="), "no key query item at all: \(url)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), sentinelKey,
                       "the key travels in the header instead")
    }

    func testStreamingRequestCarriesKeyInHeaderAndNotInURL() async {
        let streaming = RecordingStreamingTransport()
        let client = GeminiClient(configStore: makeStore(),
                                  observabilityBus: MockObservabilityBus(),
                                  transport: FakeGeminiTransport(),
                                  streamingTransport: streaming)

        do {
            _ = try await client.understandStreaming(audioData: Data([0x00]),
                                                     mimeType: "audio/wav",
                                                     context: makeInterpreterContext(),
                                                     onPartialTranscript: { _ in })
            XCTFail("the forced transport failure must propagate")
        } catch {
            // expected — the request was built before the transport threw
        }

        let request = streaming.lastRequest
        XCTAssertNotNil(request)
        let url = request?.url?.absoluteString ?? ""
        XCTAssertFalse(url.contains(sentinelKey), "the key must not be in the streaming URL: \(url)")
        XCTAssertFalse(url.contains("key="))
        XCTAssertEqual(request?.value(forHTTPHeaderField: "x-goog-api-key"), sentinelKey)
    }

    // MARK: - (b) No emitter stringifies a URL-bearing error

    func testErrorCodeMapperEmitsContentFreeCodesWithDiagnosticValue() {
        XCTAssertEqual(ErrorCodeMapper.code(for: URLError(.timedOut)), "url_error_-1001")
        XCTAssertEqual(ErrorCodeMapper.code(for: URLError(.cannotConnectToHost)), "url_error_-1004")
        XCTAssertEqual(ErrorCodeMapper.code(for: GeminiClient.GeminiClientError.httpError(status: 503)),
                       "http_503")
        XCTAssertEqual(ErrorCodeMapper.code(for: GeminiClient.GeminiClientError.notConfigured),
                       "not_configured")
        XCTAssertEqual(ErrorCodeMapper.code(for: RecognitionError.timedOut), "timed_out")
        XCTAssertEqual(ErrorCodeMapper.code(for: RecognitionError.cancelled), "cancelled")
    }

    func testErrorCodeMapperNeverReadsDescriptions() {
        struct DescriptiveError: LocalizedError {
            let secret: String
            var errorDescription: String? { "boom secret=\(secret)" }
        }
        let code = ErrorCodeMapper.code(for: DescriptiveError(secret: sentinelKey))
        XCTAssertFalse(code.contains(sentinelKey))
        XCTAssertFalse(code.contains("boom"))
        XCTAssertFalse(code.contains(" "), "a code is identifier-shaped: \(code)")
    }

    /// The pre-fix shape — an error whose description carries a key-bearing
    /// URL — driven through a real emitter site (`interpret_failed`).
    func testInterpreterEmitterMapsAKeyBearingErrorToAContentFreeCode() {
        let transport = FakeGeminiTransport()
        transport.nextResult = .failure(URLError(.cannotConnectToHost, userInfo: [
            NSURLErrorFailingURLErrorKey: keyBearingURL(),
            NSURLErrorFailingURLStringErrorKey: keyBearingURL().absoluteString
        ]))
        let bus = MockObservabilityBus()
        let client = GeminiClient(configStore: makeStore(), observabilityBus: bus, transport: transport)
        let interpreter = GeminiCommandInterpreter(client: client, observabilityBus: bus)

        let done = expectation(description: "interpret completes")
        interpreter.interpret(transcript: "औषधि खाएँ", context: makeInterpreterContext()) { _ in
            done.fulfill()
        }
        wait(for: [done], timeout: 3.0)

        let event = bus.emittedEvents.first { $0.eventType == "interpret_failed" }
        let code = event?.errorCode ?? ""
        XCTAssertEqual(code, "url_error_-1004",
                       "the domain + code survives as the diagnostic value")
        XCTAssertFalse(code.contains(sentinelKey))
        XCTAssertFalse(code.contains("https"))
        XCTAssertFalse(code.contains(keyBearingURL().absoluteString))
    }

    /// The same shape through the Gemini STT emitter site
    /// (`transcribe_failed`), driven end to end with an audio buffer.
    func testGeminiSpeechRecognizerEmitterMapsAKeyBearingError() {
        let transport = FakeGeminiTransport()
        transport.nextResult = .failure(URLError(.timedOut, userInfo: [
            NSURLErrorFailingURLErrorKey: keyBearingURL(),
            NSURLErrorFailingURLStringErrorKey: keyBearingURL().absoluteString
        ]))
        let bus = MockObservabilityBus()
        let client = GeminiClient(configStore: makeStore(), observabilityBus: bus, transport: transport)
        let stt = GeminiSpeechRecognizer(client: client, observabilityBus: bus)

        let done = expectation(description: "recognition completes")
        stt.startListening(timeout: 5) { _ in done.fulfill() }
        stt.feed(makePCMBuffer(samples: 1600))
        stt.finish()
        wait(for: [done], timeout: 3.0)

        let event = bus.emittedEvents.first { $0.eventType == "transcribe_failed" }
        XCTAssertEqual(event?.errorCode, "url_error_-1001")
        XCTAssertFalse((event?.errorCode ?? "").contains(sentinelKey))
    }

    // MARK: - (c) The sink itself defends against future emitters

    func testRogueEmitterStringifyingAKeyBearingErrorIsBoundedAtTheConsoleSink() {
        let rogue = ObservabilityEvent(
            component: "future_feature",
            eventType: "future_failure",
            durationMs: nil,
            outcome: "failure",
            errorCode: String(describing: URLError(.cannotConnectToHost, userInfo: [
                NSURLErrorFailingURLErrorKey: keyBearingURL(),
                NSURLErrorFailingURLStringErrorKey: keyBearingURL().absoluteString
            ])),
            metadata: [:]
        )
        XCTAssertTrue((rogue.errorCode ?? "").contains(sentinelKey),
                      "sanity: the rogue event really does carry the key")

        let logged = captureConsoleSynchronously { ConsoleObservabilityBus().emit(rogue) }

        XCTAssertTrue(logged.contains("future_failure"),
                      "the event still reaches the sink (guard against a vacuous capture)")
        XCTAssertFalse(logged.contains(sentinelKey), "the sink must bound error_code: \(logged)")
        XCTAssertFalse(logged.contains("key="))
        XCTAssertFalse(logged.contains("https://"))
    }

    // MARK: - (d) No raw upstream body reaches logs

    func testHTTPErrorBodyIsNotEmittedOnlyTheStatusSurvives() async {
        let upstreamBody = #"{"error":{"status":"RESOURCE_EXHAUSTED","message":"quota for key \#(sentinelKey)"}}"#
        let response = HTTPURLResponse(url: URL(string: "https://generativelanguage.googleapis.com")!,
                                       statusCode: 429, httpVersion: nil, headerFields: nil)!
        let transport = FakeGeminiTransport()
        transport.nextResult = .success((Data(upstreamBody.utf8), response))
        let client = GeminiClient(configStore: makeStore(),
                                  observabilityBus: ConsoleObservabilityBus(),
                                  transport: transport)

        let logged = await captureConsoleAndAsync {
            do {
                _ = try await client.generateJSON(prompt: "irrelevant")
                XCTFail("expected an HTTP error")
            } catch GeminiClient.GeminiClientError.httpError(let status) {
                XCTAssertEqual(status, 429, "the status stays available for diagnostics")
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertTrue(logged.contains("429"), "the status still reaches the sink: \(logged)")
        XCTAssertFalse(logged.contains(sentinelKey), "the upstream body must not: \(logged)")
        XCTAssertFalse(logged.contains("RESOURCE_EXHAUSTED"))
    }

    // MARK: - End-to-end: forced transport failure on the real sink

    /// A configured client, a transport that fails exactly the way
    /// URLSession does (a `URLError` carrying the attempted URL), the real
    /// `ConsoleObservabilityBus` (LogSanitiser + print) as the sink.
    func testForcedTransportFailureLeaksNoKeyMaterialToTheConsoleSink() async {
        let client = GeminiClient(configStore: makeStore(),
                                  observabilityBus: ConsoleObservabilityBus(),
                                  transport: FailLikeURLSessionTransport())

        let logged = await captureConsoleAndAsync {
            do {
                _ = try await client.identifyAppliance(
                    imageData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                    mimeType: "image/jpeg", question: "के हो?", languageHint: "ne")
                XCTFail("the forced transport failure must propagate")
            } catch {
                // expected — the real error-handling path ran
            }
        }

        XCTAssertTrue(logged.contains("gemini_vision_identify"),
                      "the sink still reports the failure — guard against a vacuous capture: \(logged)")
        XCTAssertTrue(logged.contains("errorCode=url_error_"),
                      "the content-free code survives with diagnostic value: \(logged)")
        XCTAssertFalse(logged.contains(sentinelKey), "no key material: \(logged)")
        XCTAssertFalse(logged.contains("key="))
        XCTAssertFalse(logged.contains("https://"))
        XCTAssertFalse(logged.lowercased().contains("nserrorfailingurl"))
    }

    // MARK: - Helpers

    /// A `URLError` with the userInfo URLSession itself populates on a
    /// transport failure (the shape that used to carry the key).
    private final class FailLikeURLSessionTransport: GeminiTransport {
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let url = request.url ?? URL(string: "https://invalid.invalid")!
            throw URLError(.cannotConnectToHost, userInfo: [
                NSURLErrorFailingURLErrorKey: url,
                NSURLErrorFailingURLStringErrorKey: url.absoluteString,
                NSLocalizedDescriptionKey: "Could not connect to the server."
            ])
        }
    }

    /// Records the request and then fails — enough to inspect the streaming
    /// request shape without fabricating `URLSession.AsyncBytes`.
    private final class RecordingStreamingTransport: GeminiStreamingTransport {
        private(set) var lastRequest: URLRequest?
        func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            lastRequest = request
            throw URLError(.cannotConnectToHost)
        }
    }

    private func makePCMBuffer(samples: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: 16_000,
                                   channels: 1,
                                   interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples))!
        buffer.frameLength = AVAudioFrameCount(samples)
        return buffer
    }

    /// Runs `body` with process stdout redirected to a temp file and
    /// returns everything the real sink printed (T-050 is about what
    /// actually reaches the console, so the assertion is made against the
    /// printed line, not an in-memory event copy).
    private func captureConsoleAndAsync(_ body: () async -> Void) async -> String {
        let original = dup(STDOUT_FILENO)
        let path = NSTemporaryDirectory() + "/gemini-sink-\(UUID().uuidString).log"
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard original >= 0, fd >= 0 else {
            if fd >= 0 { close(fd) }
            if original >= 0 { close(original) }
            XCTFail("could not open the console-capture file")
            return ""
        }
        dup2(fd, STDOUT_FILENO)
        close(fd)

        await body()
        fflush(stdout)

        dup2(original, STDOUT_FILENO)
        close(original)

        let captured = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        return captured
    }

    /// Synchronous variant used by the sanitiser-bound test.
    private func captureConsoleSynchronously(_ body: () -> Void) -> String {
        let original = dup(STDOUT_FILENO)
        let path = NSTemporaryDirectory() + "/gemini-sink-\(UUID().uuidString).log"
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard original >= 0, fd >= 0 else {
            if fd >= 0 { close(fd) }
            if original >= 0 { close(original) }
            XCTFail("could not open the console-capture file")
            return ""
        }
        dup2(fd, STDOUT_FILENO)
        close(fd)

        body()
        fflush(stdout)

        dup2(original, STDOUT_FILENO)
        close(original)

        let captured = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        return captured
    }
}
