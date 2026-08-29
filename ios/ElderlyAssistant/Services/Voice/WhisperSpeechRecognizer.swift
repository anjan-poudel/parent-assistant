import Foundation
import AVFoundation
#if canImport(SwiftWhisper)
import SwiftWhisper
#endif

/// On-device Nepali (+ English fallback) speech recognizer backed by
/// whisper.cpp. Push-mode only — expects VoicePipeline to feed audio via
/// `feed(_:)` and call `finish()` when VAD detects end-of-utterance.
///
/// When the whisper.cpp SPM package isn't available in the build (see
/// `docs/voice-pipeline-setup.md`) or the model file hasn't been
/// downloaded yet, `isAvailable` is `false` and `startListening` fails
/// with `.localeUnsupported`. VoicePipeline is expected to keep using
/// `OnDeviceSpeechRecognizer` (en-US) until the Whisper path lights up —
/// via `VoicePipeline.setSpeechRecognizer(_:)`.
final class WhisperSpeechRecognizer: SpeechRecognizerProtocol {

    /// Configuration knobs. Loaded once at init from ModelStore + user
    /// preference. Not intended to change mid-session.
    struct Config {
        /// Primary language ISO code ("ne" for Nepali). Whisper's
        /// language-ID head auto-detects when nil.
        let primaryLanguage: String?
        /// Fallback if primary model isn't cached (e.g. "en" using
        /// whisper-base).
        let fallbackLanguage: String?
        /// Maximum utterance length before we auto-finish, seconds.
        let maxUtteranceSeconds: TimeInterval

        static let `default` = Config(
            primaryLanguage: "ne",
            fallbackLanguage: "en",
            maxUtteranceSeconds: 10
        )
    }

    private let modelStore: ModelStore
    private let observabilityBus: ObservabilityBus
    private let config: Config
    private let inferenceQueue = DispatchQueue(label: "whisper.stt",
                                               qos: .userInitiated)

    /// Held during a single utterance. int16 PCM at 16 kHz mono.
    private var utteranceBuffer: [Int16] = []
    private var completion: ((Result<String, RecognitionError>) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    private var listeningActive = false

    /// Where the LoRA (if any) is applied. Phase 1: skeleton only — logs
    /// and no-ops. See applyLoRA docs.
    private var activeLoRA: ModelID?

    /// Cached Whisper context. Held as `Any?` so this file compiles
    /// without the SwiftWhisper package present; the real cast to
    /// `SwiftWhisper.Whisper` happens inside the `#if canImport` guards.
    private var whisperInstance: Any?

    let ownsAudioCapture = false

    var isAvailable: Bool {
        // Whisper is available when the model is on disk AND the runtime
        // package is present in the build. The runtime check is a
        // `#if canImport(SwiftWhisper)` in the actual inference path; without
        // it we short-circuit `startListening` with .localeUnsupported.
        guard modelStore.isCached(ModelCatalog.whisperLargeV3Nepali) ||
              modelStore.isCached(ModelCatalog.whisperSmallMultilingual) ||
              modelStore.isCached(ModelCatalog.whisperBaseEn) else {
            return false
        }
        #if canImport(SwiftWhisper)
        return true
        #else
        return false
        #endif
    }

    init(modelStore: ModelStore,
         observabilityBus: ObservabilityBus,
         config: Config = .default) {
        self.modelStore = modelStore
        self.observabilityBus = observabilityBus
        self.config = config
    }

    // MARK: - LoRA hot-swap (skeleton)

    /// Applies a language / dialect / persona LoRA to the active Whisper
    /// context. Phase 1 is a skeleton — it just records which LoRA the
    /// pipeline *asked for* so upper layers can query state. The real
    /// `whisper_apply_lora` call lands in Phase 3 of the research doc.
    func applyLoRA(_ id: ModelID?) {
        activeLoRA = id
        observabilityBus.emit(ObservabilityEvent(
            component: "whisper_stt",
            eventType: "lora_hot_swap_skeleton",
            durationMs: nil,
            outcome: "info",
            errorCode: nil,
            metadata: ["state": id?.rawValue ?? "none"]
        ))
    }

    // MARK: - SpeechRecognizerProtocol

    func requestAuthorization(_ callback: @escaping (Bool) -> Void) {
        // Whisper needs mic + speech-recognition permissions like any
        // other STT. The AudioSessionManager already prompts for mic; we
        // rely on SFSpeechRecognizer's speech-permission prompt as well
        // because the fallback path uses it. So auth for Whisper alone
        // has no separate gate — return granted synchronously.
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
        let cap = min(timeout, config.maxUtteranceSeconds)
        let work = DispatchWorkItem { [weak self] in
            self?.emit("timeout", errorCode: "timed_out")
            self?.finish()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cap, execute: work)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        // Silently drop when not listening — normal transient state
        // between `finish()` and the pipeline flipping back to .idle.
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

        let audio = utteranceBuffer
        utteranceBuffer.removeAll()
        let completion = self.completion
        self.completion = nil

        observabilityBus.emit(ObservabilityEvent(
            component: "whisper_stt",
            eventType: "finish",
            durationMs: nil,
            outcome: audio.isEmpty ? "empty_buffer" : "have_audio",
            errorCode: nil,
            metadata: ["state": "samples=\(audio.count)"]
        ))

        inferenceQueue.async { [weak self] in
            self?.runInference(audio) { result in
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

    // MARK: - Inference (guarded)

    private func runInference(_ pcm: [Int16],
                              completion: @escaping (Result<String, RecognitionError>) -> Void) {
        #if canImport(SwiftWhisper)
        // 1. Locate + lazily load the model. `whisperInstance` is reused
        //    across calls — loading a 150 MB Whisper context takes seconds.
        let modelId: ModelID
        if modelStore.isCached(ModelCatalog.whisperLargeV3Nepali) {
            modelId = ModelCatalog.whisperLargeV3Nepali
        } else if modelStore.isCached(ModelCatalog.whisperSmallMultilingual) {
            modelId = ModelCatalog.whisperSmallMultilingual
        } else if modelStore.isCached(ModelCatalog.whisperBaseEn) {
            modelId = ModelCatalog.whisperBaseEn
        } else {
            emit("model_missing", errorCode: "no_cached_model")
            completion(.failure(.localeUnsupported))
            return
        }
        guard let modelURL = modelStore.path(for: modelId) else {
            emit("model_path_missing", errorCode: "no_path")
            completion(.failure(.localeUnsupported))
            return
        }

        let whisper: Whisper
        if let existing = whisperInstance as? Whisper {
            whisper = existing
        } else {
            // Sanity-check the file before handing to SwiftWhisper. A bad
            // download (HTML error page, wrong format) makes SwiftWhisper's
            // init store a null pointer, and the next inference call
            // segfaults the app. Catching it here means we fail cleanly
            // and the caller stays on the SFSpeechRecognizer fallback.
            guard Self.looksLikeGGMLFile(at: modelURL) else {
                emit("model_format_bad", errorCode: "not_ggml")
                completion(.failure(.recognitionFailed(
                    NSError(domain: "WhisperSTT", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "cached model file is not a valid GGML/GGUF whisper model — delete and re-download"])
                )))
                return
            }
            // Fresh instance — the shared `.default` is class-typed and
            // could be mutated by other consumers, silently clobbering
            // our language setting.
            let params = WhisperParams(strategy: .greedy)
            if let lang = config.primaryLanguage {
                params.language = WhisperLanguage(rawValue: lang) ?? .auto
            } else {
                params.language = .auto
            }
            // Force transcription (not translation-to-English) and
            // disable auto language detection so the language above
            // actually applies.
            params.translate = false
            params.no_context = true
            params.suppress_blank = true
            whisper = Whisper(fromFileURL: modelURL, withParams: params)
            whisperInstance = whisper
            emit("model_loaded", errorCode: nil)
        }

        // 2. Int16 [-32768, 32767] → Float32 [-1, 1] as SwiftWhisper expects.
        let floats: [Float] = pcm.map { Float($0) / 32_768.0 }

        // 3. Transcribe. SwiftWhisper's async API bridges to whisper.cpp
        //    `whisper_full` under the hood and returns segment text on
        //    completion.
        Task { [weak self] in
            do {
                let segments = try await whisper.transcribe(audioFrames: floats)
                let joined = segments.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if joined.isEmpty {
                    self?.emit("empty_transcript", errorCode: "empty")
                    completion(.failure(.recognitionFailed(
                        NSError(domain: "WhisperSTT", code: -2,
                                userInfo: [NSLocalizedDescriptionKey: "empty transcript"])
                    )))
                } else {
                    self?.emit("transcribed", errorCode: nil)
                    completion(.success(joined))
                }
            } catch {
                self?.emit("inference_failed", errorCode: "whisper_error")
                completion(.failure(.recognitionFailed(error)))
            }
        }
        #else
        emit("inference_unavailable", errorCode: "runtime_missing")
        completion(.failure(.localeUnsupported))
        #endif
    }

    /// Peek at the first bytes of the file to catch obvious junk
    /// (HTML error pages, empty files, wrong format) before whisper.cpp
    /// tries to `mmap` it and crashes on bad structure.
    ///
    /// whisper.cpp files store their 4-char magic as a little-endian
    /// uint32. On disk that means the bytes are reversed from the ASCII
    /// spelling — "ggml" becomes 0x6c 0x6d 0x67 0x67, "ggla" becomes
    /// 0x61 0x6c 0x67 0x67, etc. GGUF stores the magic as a byte string
    /// so its bytes are just "GGUF" on disk.
    static func looksLikeGGMLFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 8)) ?? Data()
        guard data.count >= 4 else { return false }
        let magic = data.prefix(4)
        let ggml = Data([0x6c, 0x6d, 0x67, 0x67])   // "ggml" LE uint32
        let ggla = Data([0x61, 0x6c, 0x67, 0x67])   // "ggla" LE uint32
        let ggjt = Data([0x74, 0x6a, 0x67, 0x67])   // "ggjt" LE uint32
        let gguf = Data([0x47, 0x47, 0x55, 0x46])   // "GGUF" (byte string)
        return magic == ggml || magic == ggla || magic == ggjt || magic == gguf
    }

    // MARK: - Observability

    private func emit(_ eventType: String, errorCode: String?) {
        observabilityBus.emit(ObservabilityEvent(
            component: "whisper_stt",
            eventType: eventType,
            durationMs: nil,
            outcome: errorCode == nil ? "info" : "failure",
            errorCode: errorCode,
            metadata: [:]
        ))
    }
}
