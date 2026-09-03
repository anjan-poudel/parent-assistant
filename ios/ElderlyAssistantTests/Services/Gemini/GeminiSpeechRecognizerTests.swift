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
