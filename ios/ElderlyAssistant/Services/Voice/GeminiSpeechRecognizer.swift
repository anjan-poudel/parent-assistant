import Foundation
import AVFoundation

/// Speech recognition via the Gemini API (v2 pivot) — replaces
/// `WhisperSpeechRecognizer` as the "real" recognizer once an API key is
/// configured (`GeminiConfigStore`). Push-mode only, same contract as
/// every other recognizer in this file family: `VoicePipeline` feeds PCM
/// via `feed(_:)` and calls `finish()` on VAD end-of-utterance.
///
/// Deliberately a SEPARATE network call from intent interpretation
/// (`GeminiCommandInterpreter`) rather than one combined audio-in call —
/// see the design doc §Phase 0 note: this trades a small amount of extra
/// latency (two round trips instead of one) for reusing `VoicePipeline`
/// and `CommandRouter` completely unchanged. Combining them into a single
/// call is a reasonable follow-up once this simpler seam is verified live.
final class GeminiSpeechRecognizer: SpeechRecognizerProtocol {
    let ownsAudioCapture = false

    private let client: GeminiClient
    private let observabilityBus: ObservabilityBus
    private let languageHint: String
    private let sampleRate: UInt32 = 16_000

    private var utteranceBuffer: [Int16] = []
    private var completion: ((Result<String, RecognitionError>) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    private var listening = false
    private var inFlightTask: Task<Void, Never>?

    var isAvailable: Bool { client.isAvailable }

    init(client: GeminiClient, observabilityBus: ObservabilityBus, languageHint: String = "ne") {
        self.client = client
        self.observabilityBus = observabilityBus
        self.languageHint = languageHint
    }

    /// No on-device permission is needed for Gemini itself — the mic
    /// permission this recognizer depends on is already gated upstream by
    /// `AudioSessionManager`.
    func requestAuthorization(_ callback: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { callback(true) }
    }

    func startListening(timeout: TimeInterval,
                        completion: @escaping (Result<String, RecognitionError>) -> Void) {
        utteranceBuffer.removeAll()
        self.completion = completion
        listening = true
        armTimeout(timeout)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard listening, let channelData = buffer.int16ChannelData?.pointee else { return }
        let frameCount = Int(buffer.frameLength)
        utteranceBuffer.append(contentsOf: UnsafeBufferPointer(start: channelData, count: frameCount))
    }

    func finish() {
        guard listening else { return }
        listening = false
        cancelTimeout()

        let samples = utteranceBuffer
        utteranceBuffer.removeAll()
        guard !samples.isEmpty else {
            settle(.failure(.recognitionFailed(
                NSError(domain: "gemini_stt", code: 1, userInfo: [NSLocalizedDescriptionKey: "empty utterance"]))))
            return
        }

        let wav = Self.wavData(fromPCM16: samples, sampleRate: sampleRate)
        inFlightTask = Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await self.client.transcribe(
                    audioData: wav, mimeType: "audio/wav", languageHint: self.languageHint)
                self.emit("transcribed", outcome: "success")
                #if DEBUG
                // Debug-build-only, per explicit request while diagnosing
                // a live bug (2026-09-04) — never compiled into Release.
                print("[gemini_stt][DEBUG] transcript=\"\(transcript)\"")
                #endif
                self.settle(.success(transcript))
            } catch {
                self.emit("transcribe_failed", outcome: "failure", errorCode: String(describing: error))
                self.settle(.failure(.recognitionFailed(error)))
            }
        }
    }

    /// Soft cancel — mirrors `WhisperSpeechRecognizer.cancel()`'s contract:
    /// settle the CALLER immediately with `.cancelled` so `VoicePipeline`
    /// never blocks on this, but let any in-flight network request run to
    /// its own natural conclusion (success, or `GeminiClient`'s own HTTP
    /// timeout) instead of hard-aborting it. `Task.cancel()` would
    /// propagate to the underlying `URLSessionTask` and throw it away — if
    /// that request was about to succeed, hard-aborting wastes a real
    /// answer for nothing, since a network call (unlike a wedged on-device
    /// whisper.cpp call) will terminate on its own regardless. The
    /// eventual result is simply discarded: `settle` is single-shot and
    /// `completion` is already nil by the time it would fire.
    func cancel() {
        listening = false
        cancelTimeout()
        inFlightTask = nil
        utteranceBuffer.removeAll()
        settle(.failure(.cancelled))
    }

    // MARK: - Timeout

    private func armTimeout(_ seconds: TimeInterval) {
        cancelTimeout()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelTimeout() {
        timeoutWork?.cancel()
        timeoutWork = nil
    }

    /// Single-shot settle — a second call (e.g. a network response arriving
    /// after `cancel()` already settled with `.cancelled`) is a silent
    /// no-op because `completion` was already cleared.
    private func settle(_ result: Result<String, RecognitionError>) {
        guard let callback = completion else { return }
        completion = nil
        DispatchQueue.main.async { callback(result) }
    }

    private func emit(_ eventType: String, outcome: String, errorCode: String? = nil) {
        observabilityBus.emit(ObservabilityEvent(
            component: "gemini_stt",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: [:]
        ))
    }

    // MARK: - WAV encoding

    /// Minimal 44-byte-header PCM16 mono WAV — the smallest audio
    /// container Gemini's `inlineData` accepts without needing a codec.
    static func wavData(fromPCM16 samples: [Int16], sampleRate: UInt32, channels: UInt16 = 1) -> Data {
        var data = Data()
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * 2)
        let chunkSize = 36 + dataSize

        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: "RIFF".utf8)
        append(chunkSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append(UInt32(16))   // Subchunk1Size (16 for PCM)
        append(UInt16(1))    // AudioFormat = PCM
        append(channels)
        append(sampleRate)
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        append(dataSize)
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }
}
