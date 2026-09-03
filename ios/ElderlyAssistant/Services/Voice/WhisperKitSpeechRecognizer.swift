import Foundation
import AVFoundation
#if canImport(WhisperKit)
import WhisperKit
#endif

/// ANE-accelerated STT via WhisperKit (CoreML) — replaces SwiftWhisper on
/// the on-device path. Push-mode: the pipeline feeds PCM buffers and calls
/// `finish()` on end-of-utterance, the same contract as the SwiftWhisper
/// adapter, so the VAD-gated capture flow is unchanged.
///
/// Model loading is lazy on first use. The model folder is a converted
/// WhisperKit CoreML bundle (see docs/voice-pipeline-setup.md — generated
/// with `whisperkit generate model`); ModelCatalog/download plumbing for
/// bundle artifacts lands separately.
final class WhisperKitSpeechRecognizer: SpeechRecognizerProtocol {

    /// Location of the converted WhisperKit model bundle. Nil until the
    /// catalog/download service provides bundle artifacts.
    var modelFolderURL: URL?

    /// Alternative: a WhisperKit HF model name backed by an official
    /// pre-converted bundle (e.g. "large-v3-turbo") — the SDK downloads
    /// it itself. Used for the first on-device latency bench while the
    /// custom teacher bundle conversion is sorted out.
    var modelName: String?

    var isAvailable: Bool {
        #if canImport(WhisperKit)
        return modelFolderURL != nil || modelName != nil
        #else
        return false
        #endif
    }

    let ownsAudioCapture = false

    private let observabilityBus: ObservabilityBus
    private let inferenceQueue = DispatchQueue(label: "whisperkit.stt",
                                               qos: .userInteractive)
    private var listeningActive = false
    private var utteranceBuffer: [Int16] = []
    private var completion: ((Result<String, RecognitionError>) -> Void)?
    private var timeoutWork: DispatchWorkItem?

    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    private var initTask: Task<WhisperKit?, Never>?
    #endif

    init(observabilityBus: ObservabilityBus) {
        self.observabilityBus = observabilityBus
    }

    // MARK: - Auth

    func requestAuthorization(_ callback: @escaping (Bool) -> Void) {
        // WhisperKit reads audio buffers we feed it — the mic permission
        // gate is owned by the pipeline's AudioSessionManager, same as
        // the SwiftWhisper adapter (no separate speech-recognition gate).
        DispatchQueue.main.async { callback(true) }
    }

    // MARK: - Capture lifecycle

    func startListening(timeout: TimeInterval,
                        completion: @escaping (Result<String, RecognitionError>) -> Void) {
        guard isAvailable else {
            DispatchQueue.main.async { completion(.failure(.localeUnsupported)) }
            return
        }
        cancel()
        listeningActive = true
        utteranceBuffer.removeAll()
        self.completion = completion

        let work = DispatchWorkItem { [weak self] in
            self?.emit("timeout", errorCode: "timed_out")
            self?.finish()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard listeningActive else { return }
        guard let channelData = buffer.int16ChannelData?.pointee else { return }
        let count = Int(buffer.frameLength)
        utteranceBuffer.append(contentsOf: UnsafeBufferPointer(start: channelData,
                                                               count: count))
    }

    func finish() {
        guard listeningActive else { return }
        listeningActive = false
        timeoutWork?.cancel()
        timeoutWork = nil

        let samples = utteranceBuffer
        utteranceBuffer.removeAll()
        let completion = self.completion
        self.completion = nil

        emit("finish", errorCode: nil)
        guard !samples.isEmpty else {
            DispatchQueue.main.async { completion?(.failure(.timedOut)) }
            return
        }

        inferenceQueue.async { [weak self] in
            self?.runInference(samples) { result in
                DispatchQueue.main.async { completion?(result) }
            }
        }
    }

    func cancel() {
        listeningActive = false
        timeoutWork?.cancel()
        timeoutWork = nil
        utteranceBuffer.removeAll()
        if let completion = completion {
            self.completion = nil
            DispatchQueue.main.async { completion(.failure(.cancelled)) }
        }
    }

    // MARK: - Inference

    private func runInference(_ samples: [Int16],
                              completion: @escaping (Result<String, RecognitionError>) -> Void) {
        #if canImport(WhisperKit)
        guard let folder = modelFolderURL else {
            completion(.failure(.localeUnsupported))
            return
        }

        let floatSamples = samples.map { Float($0) / 32768.0 }

        Task { [weak self] in
            guard let self else { return }
            do {
                let kit: WhisperKit
                if let existing = whisperKit {
                    kit = existing
                } else {
                    // First use: load the model (cached thereafter).
                    // Prefer the local converted bundle; fall back to the
                    // SDK's built-in download for official model names.
                    let loaded: WhisperKit?
                    if let folder = modelFolderURL {
                        loaded = try await WhisperKit(modelFolder: folder.path)
                    } else if let name = modelName {
                        loaded = try await WhisperKit(model: name)
                    } else {
                        loaded = nil
                    }
                    guard let loaded else {
                        completion(.failure(.localeUnsupported))
                        return
                    }
                    whisperKit = loaded
                    kit = loaded
                    emit("model_loaded", errorCode: nil)
                }
                let result = try await kit.transcribe(audioArray: floatSamples)
                let text = result.first?.text ?? ""
                emit("inference_done", errorCode: nil)
                completion(.success(text))
            } catch {
                emit("inference_failed", errorCode: String(describing: error))
                completion(.failure(.recognitionFailed(error)))
            }
        }
        #else
        emit("inference_unavailable", errorCode: nil)
        completion(.failure(.localeUnsupported))
        #endif
    }

    // MARK: - Observability

    private func emit(_ eventType: String, errorCode: String?) {
        observabilityBus.emit(ObservabilityEvent(
            component: "whisperkit_stt",
            eventType: eventType,
            durationMs: nil,
            outcome: errorCode == nil ? "success" : "failure",
            errorCode: errorCode,
            metadata: [:]
        ))
    }
}
