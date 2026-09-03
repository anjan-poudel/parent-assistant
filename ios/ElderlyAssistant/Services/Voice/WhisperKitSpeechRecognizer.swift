import Foundation
import AVFoundation
#if canImport(WhisperKit)
import WhisperKit
#endif

/// ANE-accelerated recognizer on the WhisperKit runtime (memory:
/// ios-stt-runtime-decision — the vendored whisper.cpp predates Metal,
/// WhisperKit is the maintained CoreML/ANE path for 128-mel models).
///
/// Push-mode like `WhisperSpeechRecognizer`: the pipeline's tap feeds
/// int16 PCM via `feed(_:)`, `finish()` runs transcription. The
/// `#if canImport(WhisperKit)` guard keeps this file compilable before
/// the package product is linked.
final class WhisperKitSpeechRecognizer: SpeechRecognizerProtocol {

    let ownsAudioCapture = false

    private let modelStore: ModelStore?
    private let observabilityBus: ObservabilityBus

    /// Which catalog artifact (a directory) to load in normal mode.
    private let preferredModelID: ModelID

    // Bench hooks (env-driven, set by AppCoordinator's
    // makeWhisperKitBenchRecognizer): use a local folder or a named
    // model that WhisperKit downloads itself (e.g. "large-v3-turbo").
    var modelFolderURL: URL?
    var modelName: String?

    /// Held as `Any?` so this file compiles without the package; cast to
    /// `WhisperKit.WhisperKit` inside the guards.
    private var kitInstance: Any?
    private var loadedDescriptor: String?

    private var utteranceBuffer: [Float] = []
    private var completion: ((Result<String, RecognitionError>) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    private var listeningActive = false
    /// Main-queue watchdog that guarantees the pipeline completion fires
    /// even if WhisperKit hangs (or the first-run model download stalls).
    private var inferenceWatchdog: DispatchWorkItem?
    /// The attempt's pending pipeline completion — settled exactly once
    /// by the inference result or the watchdog.
    private var pendingCompletion: ((Result<String, RecognitionError>) -> Void)?
    private var settled = false
    private let inferenceQueue = DispatchQueue(label: "whisperkit.stt",
                                               qos: .userInitiated)

    var isAvailable: Bool {
        #if canImport(WhisperKit)
        if modelFolderURL != nil || modelName != nil {
            return true   // bench mode
        }
        guard let modelStore,
              modelStore.directoryURL(for: preferredModelID) != nil else {
            return false
        }
        return true
        #else
        return false
        #endif
    }

    init(observabilityBus: ObservabilityBus,
         modelStore: ModelStore? = nil,
         preferredModelID: ModelID = ModelCatalog.whisperKitNepali) {
        self.modelStore = modelStore
        self.observabilityBus = observabilityBus
        self.preferredModelID = preferredModelID
    }

    // MARK: - SpeechRecognizerProtocol

    func requestAuthorization(_ callback: @escaping (Bool) -> Void) {
        // Mic permission is handled by the audio session; WhisperKit has
        // no separate gate.
        DispatchQueue.main.async { callback(true) }
    }

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

        // Hard cap in case VAD doesn't fire finish().
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
        let floats = UnsafeBufferPointer(start: channelData, count: count)
            .map { Float($0) / 32_768.0 }
        utteranceBuffer.append(contentsOf: floats)
    }

    func finish() {
        guard listeningActive else { return }
        listeningActive = false
        timeoutWork?.cancel()
        timeoutWork = nil

        let audio = utteranceBuffer
        utteranceBuffer.removeAll()
        let completion = self.completion
        self.completion = nil

        emit("finish", errorCode: audio.isEmpty ? "empty_buffer" : nil)
        print("[whisperkit_stt] finish samples=\(audio.count) "
            + "audio_seconds=\(String(format: "%.2f", Double(audio.count) / 16_000.0))")

        pendingCompletion = completion
        settled = false
        armInferenceWatchdog()
        inferenceQueue.async { [weak self] in
            self?.runInference(audio) { result in
                self?.settle(with: result)
            }
        }
    }

    /// Single-shot settlement: the first result (real or watchdog) wins.
    private func settle(with result: Result<String, RecognitionError>) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.settled else { return }
            guard let completion = self.pendingCompletion else { return }
            self.settled = true
            self.inferenceWatchdog?.cancel()
            self.inferenceWatchdog = nil
            self.pendingCompletion = nil
            completion(result)
        }
    }

    /// 300 s covers the first-run on-device model download (~954 MB);
    /// once a model is loaded, 60 s is generous for ANE inference.
    private func armInferenceWatchdog() {
        inferenceWatchdog?.cancel()
        let budget: TimeInterval = loadedDescriptor == nil ? 300 : 60
        let work = DispatchWorkItem { [weak self] in
            print("[whisperkit_stt] inference_timeout budget=\(budget)s")
            self?.emit("inference_timeout", errorCode: "timed_out")
            self?.settle(with: .failure(.timedOut))
        }
        inferenceWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + budget, execute: work)
    }

    func cancel() {
        listeningActive = false
        timeoutWork?.cancel()
        timeoutWork = nil
        utteranceBuffer.removeAll()
        if let completion {
            self.completion = nil
            DispatchQueue.main.async { completion(.failure(.cancelled)) }
        }
    }

    // MARK: - Inference (guarded)

    private func runInference(_ audio: [Float],
                              completion: @escaping (Result<String, RecognitionError>) -> Void) {
        #if canImport(WhisperKit)
        // Resolve the load descriptor: bench folder/name first, then the
        // catalog directory artifact.
        let descriptor: String
        let config = WhisperKitConfig()
        config.verbose = true
        // Absorb the one-time CoreML specialization into model load so the
        // first utterance doesn't pay it.
        config.prewarm = true
        if let folder = modelFolderURL {
            descriptor = "folder:\(folder.path)"
            config.modelFolder = folder.path
        } else if let name = modelName {
            descriptor = "name:\(name)"
            config.model = name
        } else if let url = modelStore?.directoryURL(for: preferredModelID) {
            descriptor = "artifact:\(preferredModelID.rawValue)"
            config.modelFolder = url.path
        } else {
            emit("model_path_missing", errorCode: "no_path")
            completion(.failure(.localeUnsupported))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let kit: WhisperKit
                if let existing = kitInstance as? WhisperKit,
                   loadedDescriptor == descriptor {
                    kit = existing
                } else {
                    let loadStart = CFAbsoluteTimeGetCurrent()
                    let created = try await WhisperKit(config)
                    let loadMs = Int((CFAbsoluteTimeGetCurrent() - loadStart) * 1000)
                    kitInstance = created
                    loadedDescriptor = descriptor
                    emit("model_loaded", errorCode: nil)
                    print("[whisperkit_stt] model_loaded \(descriptor) load_ms=\(loadMs)")
                    // What hardware the components will actually run on.
                    // NE = Neural Engine (ANE). The simulator forces
                    // .cpuOnly — real devices get the NE path.
                    let compute = config.computeOptions ?? ModelComputeOptions()
                    print("[whisperkit_stt] compute audioEncoder=\(compute.audioEncoderCompute) "
                        + "textDecoder=\(compute.textDecoderCompute) "
                        + "mel=\(compute.melCompute) "
                        + "simulator=\(WhisperKit.isRunningOnSimulator)")
                    kit = created
                }

                let start = CFAbsoluteTimeGetCurrent()
                print("[whisperkit_stt] transcribing samples=\(audio.count)")
                let compute = config.computeOptions ?? ModelComputeOptions()
                print("[whisperkit_stt] GPU/ANE: audioEncoder=\(compute.audioEncoderCompute) "
                    + "textDecoder=\(compute.textDecoderCompute) mel=\(compute.melCompute) "
                    + "simulator=\(WhisperKit.isRunningOnSimulator)")
                // Force Nepali transcription — auto language detection on
                // short utterances produced English (translate-ish) output.
                let options = DecodingOptions(task: .transcribe, language: "ne")
                let results = try await kit.transcribe(audioArrays: [audio],
                                                       decodeOptions: options)
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                let joined = results.first??.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if joined.isEmpty {
                    print("[whisperkit_stt] empty_transcript duration_ms=\(ms)")
                    completion(.failure(.recognitionFailed(
                        NSError(domain: "WhisperKitSTT", code: -2,
                                userInfo: [NSLocalizedDescriptionKey: "empty transcript"]))))
                } else {
                    print("[whisperkit_stt] transcribed duration_ms=\(ms) chars=\(joined.count)")
                    print("[whisperkit_stt] transcript=" + joined)
                    completion(.success(joined))
                }
            } catch {
                emit("inference_failed", errorCode: "whisperkit_error")
                print("[whisperkit_stt] inference_failed \(error)")
                completion(.failure(.recognitionFailed(error)))
            }
        }
        #else
        emit("inference_unavailable", errorCode: "runtime_missing")
        completion(.failure(.localeUnsupported))
        #endif
    }

    // MARK: - Observability

    private func emit(_ eventType: String, errorCode: String?) {
        observabilityBus.emit(ObservabilityEvent(
            component: "whisperkit_stt",
            eventType: eventType,
            durationMs: nil,
            outcome: errorCode == nil ? "info" : "failure",
            errorCode: errorCode,
            metadata: [:]
        ))
    }
}
