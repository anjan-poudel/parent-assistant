import XCTest
import AVFoundation
@testable import ElderlyAssistant

final class GeminiSpeechRecognizerTests: XCTestCase {

    private func makeClient(result: Result<(Data, URLResponse), Error>) -> GeminiClient {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let transport = FakeGeminiTransport()
        transport.nextResult = result
        return GeminiClient(configStore: store, observabilityBus: MockObservabilityBus(), transport: transport)
    }

    func testOwnsAudioCaptureIsFalse() {
        let stt = GeminiSpeechRecognizer(
            client: makeClient(result: .success(FakeGeminiTransport.jsonResponse(text: "x"))),
            observabilityBus: MockObservabilityBus())
        XCTAssertFalse(stt.ownsAudioCapture)
    }

    func testFinishWithNoAudioFailsWithoutCallingNetwork() {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let transport = FakeGeminiTransport()
        let client = GeminiClient(configStore: store, observabilityBus: MockObservabilityBus(), transport: transport)
        let stt = GeminiSpeechRecognizer(client: client, observabilityBus: MockObservabilityBus())

        let expectation = expectation(description: "completion fires")
        stt.startListening(timeout: 5) { result in
            switch result {
            case .failure(.recognitionFailed): break
            default: XCTFail("expected recognitionFailed for an empty utterance, got \(result)")
            }
            expectation.fulfill()
        }
        stt.finish()
        wait(for: [expectation], timeout: 2.0)
        XCTAssertNil(transport.lastRequest, "an empty utterance must not hit the network")
    }

    func testFeedThenFinishTranscribesSuccessfully() {
        let client = makeClient(result: .success(FakeGeminiTransport.jsonResponse(text: "मेरो औषधि खाएँ")))
        let stt = GeminiSpeechRecognizer(client: client, observabilityBus: MockObservabilityBus())

        let expectation = expectation(description: "completion fires")
        stt.startListening(timeout: 5) { result in
            switch result {
            case .success(let text): XCTAssertEqual(text, "मेरो औषधि खाएँ")
            case .failure(let err): XCTFail("expected success, got \(err)")
            }
            expectation.fulfill()
        }
        stt.feed(makePCMBuffer(samples: 1600))
        stt.finish()
        wait(for: [expectation], timeout: 2.0)
    }

    func testCancelSettlesWithCancelledAndDropsBuffer() {
        let client = makeClient(result: .success(FakeGeminiTransport.jsonResponse(text: "should not be used")))
        let stt = GeminiSpeechRecognizer(client: client, observabilityBus: MockObservabilityBus())

        let expectation = expectation(description: "completion fires")
        stt.startListening(timeout: 5) { result in
            switch result {
            case .failure(.cancelled): break
            default: XCTFail("expected cancelled, got \(result)")
            }
            expectation.fulfill()
        }
        stt.feed(makePCMBuffer(samples: 1600))
        stt.cancel()
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Collapsed path carries the web-search tool (intent-tools, 2026-09-07)

    func testCollapsedUnderstandCarriesGoogleSearchTool() {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let transport = FakeGeminiTransport()
        let payload = #"{"transcript": "मेरो औषधि खाएँ"}"#
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: payload))
        let bus = MockObservabilityBus()
        let client = GeminiClient(configStore: store, observabilityBus: bus, transport: transport)
        let stt = GeminiSpeechRecognizer(client: client, observabilityBus: bus)

        var understandingTranscript: String?
        stt.collapseContextProvider = {
            InterpreterContext(pendingMedications: [], userLanguageHint: "ne")
        }
        stt.onUnderstanding = { transcript, _ in understandingTranscript = transcript }

        let expectation = expectation(description: "completion fires")
        stt.startListening(timeout: 5) { result in
            switch result {
            case .success(let text): XCTAssertEqual(text, "मेरो औषधि खाएँ")
            case .failure(let err): XCTFail("expected success, got \(err)")
            }
            expectation.fulfill()
        }
        stt.feed(makePCMBuffer(samples: 1600))
        stt.finish()
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(understandingTranscript, "मेरो औषधि खाएँ",
                       "the collapse hook receives the transcript half")
        // The ONE collapsed call (STT + intent + reply) must carry the
        // google_search tool — grounding rides on this call by default,
        // because no transcript exists until after it returns (per-
        // utterance gating is impossible; the audio arrives only under
        // the cloud stack).
        let body = transport.lastRequest?.httpBody
        let json = try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
        let tools = json?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?.first?.keys.first, "google_search")
        // The (ungrounded here) call still reports its tool outcome.
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "intent_tool_websearch" && $0.outcome == "not_used"
        })
    }

    // MARK: - WAV encoding

    func testWavDataHasCorrectHeaderFields() {
        let samples: [Int16] = [0, 100, -100, 200]
        let data = GeminiSpeechRecognizer.wavData(fromPCM16: samples, sampleRate: 16_000)

        XCTAssertEqual(String(data: data.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data.subdata(in: 12..<16), encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: data.subdata(in: 36..<40), encoding: .ascii), "data")

        let sampleRate = data.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(sampleRate, 16_000)

        let dataSize = data.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(dataSize), samples.count * 2)
        XCTAssertEqual(data.count, 44 + samples.count * 2)
    }

    // MARK: - Cancel-while-finishing (TALK-CRASH-FIX, 2026-09-07)

    /// The recognizer-side half of the Talk-button crash: the pipeline's
    /// stop() cancels the recognizer while finish()'s network request is
    /// still in flight (tap the Talk button mid-listening). Contract the
    /// pipeline's recovery relies on: cancel settles the capture EXACTLY
    /// once, with `.cancelled`, and the request's late success is a
    /// silent no-op (single-shot settle). The crash itself lived in the
    /// pipeline — it ran its post-capture tail for a completion that
    /// arrived after stop() — and the pipeline's capture-generation
    /// guard now drops that tail; this test pins the recognizer's half
    /// of the handshake so a double-settling regression here is caught
    /// at the seam, not on a device.
    func testCancelMidFinishSettlesOnceAndDropsLateSuccess() {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let transport = SlowGeminiTransport(delay: 0.3)
        let client = GeminiClient(configStore: store,
                                  observabilityBus: MockObservabilityBus(),
                                  transport: transport)
        let stt = GeminiSpeechRecognizer(client: client,
                                         observabilityBus: MockObservabilityBus())

        var completionCount = 0
        var finalResult: Result<String, RecognitionError>?
        let settled = expectation(description: "exactly one completion")
        stt.startListening(timeout: 5) { result in
            completionCount += 1
            finalResult = result
            settled.fulfill()
        }
        stt.feed(makePCMBuffer(samples: 1600))
        stt.finish()    // request dispatched to the slow transport
        stt.cancel()    // pipeline stop() lands mid-request

        wait(for: [settled], timeout: 2.0)
        guard case .failure(.cancelled) = finalResult else {
            XCTFail("expected .cancelled (cancel must win over the in-flight request), got \(String(describing: finalResult))")
            return
        }
        // Grace window past the slow transport's 0.3s answer: a
        // double-settling recognizer would fire its second completion
        // here (with the late success) — and that late settle is exactly
        // the stale tail the pipeline crash came from.
        let grace = expectation(description: "grace window for a late settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { grace.fulfill() }
        wait(for: [grace], timeout: 1.0)
        XCTAssertEqual(completionCount, 1,
                       "the late network success must be a silent no-op, not a second completion")
    }

    // MARK: - Helpers

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
}

/// A `GeminiTransport` that delays before answering — lets a test hold a
/// request mid-flight long enough to cancel() it deterministically
/// (TALK-CRASH-FIX, 2026-09-07). File-private to this test file.
private final class SlowGeminiTransport: GeminiTransport {
    let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return FakeGeminiTransport.jsonResponse(text: "late")
    }
}
