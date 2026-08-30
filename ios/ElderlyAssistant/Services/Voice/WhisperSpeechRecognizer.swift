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
        /// When true, force `primaryLanguage` on genuine Nepali fine-tunes
        /// only. Stock multilingual small/base-en run with auto-detect —
        /// forcing "ne" on English/noise is how Whisper hallucinates
        /// Devanagari garbage.
        let forcePrimaryLanguage: Bool

        static let `default` = Config(
            primaryLanguage: "ne",
            fallbackLanguage: "en",
            maxUtteranceSeconds: 10,
            forcePrimaryLanguage: true
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
    /// Which model `whisperInstance` was loaded from — a context binds one
    /// set of weights, so a user switching models forces a reload.
    private var loadedModelId: ModelID?

    /// User's STT model choice from the UI picker (nil = automatic).
    /// Set by AppCoordinator and persisted there across launches.
    private var preferredModelID: ModelID?

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

    // MARK: - Model preference (UI selection)

    /// Applies the user's model choice. Takes effect on the next
    /// utterance; dropping the cached context when the model changed
    /// frees the old weights and makes the next inference pay the
    /// one-time load cost instead of running the wrong model.
    func setPreferredModel(_ id: ModelID?) {
        guard id != preferredModelID else { return }
        preferredModelID = id
        if whisperInstance != nil, loadedModelId != id {
            whisperInstance = nil
        }
        observabilityBus.emit(ObservabilityEvent(
            component: "whisper_stt",
            eventType: "preference_changed",
            durationMs: nil,
            outcome: "info",
            errorCode: nil,
            metadata: ["state": id?.rawValue ?? "automatic"]
        ))
    }

    /// The model the next utterance will use: the user's pick when it's
    /// cached, else the automatic order. Mirrors `selectModelId` but is
    /// side-effect-free (no RAM gating, no events) so the UI can call it
    /// for labels.
    func currentModelID() -> ModelID? {
        if let pref = preferredModelID, modelStore.isCached(pref) {
            return pref
        }
        let automaticOrder: [ModelID] = [
            ModelCatalog.whisperLargeV3Nepali,
            ModelCatalog.whisperSmallMultilingual,
            ModelCatalog.whisperBaseEn
        ]
        return automaticOrder.first { modelStore.isCached($0) }
    }

    /// Frees the loaded Whisper context. The next utterance reloads it
    /// lazily (a few seconds on CPU after the one-time CoreML compile).
    /// The router calls this once the transcript is in hand: large-v3
    /// (~1.5 GB resident) plus the LLaMA interpreter (~1.4 GB with its
    /// 2048-token compute buffer) together exceed the app's memory
    /// ceiling on 6 GB devices and crash llama.cpp's `output_reserve`.
    func releaseModel() {
        inferenceQueue.async { [weak self] in
            self?.whisperInstance = nil
            self?.loadedModelId = nil
        }
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
        //    Priority: small-multilingual first (validated + safe on all
        //    devices), then large-Nepali when RAM allows, then base-en.
        //    Large-v3-Nepali is downranked until the offline validation in
        //    docs/voice-gibberish-transcript-fix-plan.md §4 passes.
        guard let modelId = selectModelId() else {
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
        if let existing = whisperInstance as? Whisper, loadedModelId == modelId {
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
            // Force `primaryLanguage` on the genuine Nepali fine-tune
            // only (kiranpantha large-v3, standard tokenizer). The stock
            // small multilingual runs with auto-detect: forcing "ne" on
            // English/noise is exactly how Whisper hallucinates
            // Devanagari garbage (gibberish plan §5.1).
            // TranscriptSanityGuard stays as the downstream backstop.
            // Toggle via `Config.forcePrimaryLanguage`.
            let usePrimary = modelId == ModelCatalog.whisperLargeV3Nepali
                && config.forcePrimaryLanguage
            let langCode: String
            if usePrimary, let lang = config.primaryLanguage {
                params.language = WhisperLanguage(rawValue: lang) ?? .auto
                langCode = (params.language == .auto) ? "auto" : lang
            } else {
                params.language = .auto
                langCode = "auto"
            }
            // Force transcription (not translation-to-English).
            params.translate = false
            params.no_context = true
            params.suppress_blank = true
            let loadStart = CFAbsoluteTimeGetCurrent()
            whisper = Whisper(fromFileURL: modelURL, withParams: params)
            let loadMs = Int((CFAbsoluteTimeGetCurrent() - loadStart) * 1000)
            whisperInstance = whisper
            loadedModelId = modelId
            // `backend` reflects whether the CoreML encoder is installed
            // for this model — "ane" says whisper.cpp will attempt ANE,
            // "cpu" says it won't. WHISPER_COREML_ALLOW_FALLBACK means an
            // ANE-attempted load can still silently land on CPU, so the
            // label is "intent", not guaranteed runtime. The first load
            // after installing the encoder pays the one-time CoreML
            // compile here (minutes for large-v3 fp16).
            let backend = modelStore.isCoreMLCached(modelId) ? "ane" : "cpu"
            observabilityBus.emit(ObservabilityEvent(
                component: "whisper_stt",
                eventType: "model_loaded",
                durationMs: loadMs,
                outcome: "info",
                errorCode: nil,
                metadata: [
                    "model_id": modelId.rawValue,
                    "language": langCode,
                    "backend": backend,
                    "load_ms": "\(loadMs)"
                ]
            ))
            print("[whisper_stt] model_loaded id=\(modelId.rawValue) "
                + "backend=\(backend) load_ms=\(loadMs)")
        }

        // 2. Int16 [-32768, 32767] → Float32 [-1, 1] as SwiftWhisper expects.
        let floats: [Float] = pcm.map { Float($0) / 32_768.0 }

        // 3. Transcribe. SwiftWhisper's async API bridges to whisper.cpp
        //    `whisper_full` under the hood and returns segment text on
        //    completion.
        Task { [weak self] in
            let audioSeconds = Double(pcm.count) / 16_000.0
            print("[whisper_stt] transcribing id=\(modelId.rawValue) "
                + "audio_seconds=\(String(format: "%.1f", audioSeconds))")
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let segments = try await whisper.transcribe(audioFrames: floats)
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                let joined = segments.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if joined.isEmpty {
                    self?.emit("empty_transcript", errorCode: "empty")
                    print("[whisper_stt] empty_transcript duration_ms=\(ms)")
                    completion(.failure(.recognitionFailed(
                        NSError(domain: "WhisperSTT", code: -2,
                                userInfo: [NSLocalizedDescriptionKey: "empty transcript"])
                    )))
                } else {
                    self?.emit("transcribed", errorCode: nil)
                    self?.observabilityBus.emit(ObservabilityEvent(
                        component: "whisper_stt",
                        eventType: "inference_timing",
                        durationMs: ms,
                        outcome: "info",
                        errorCode: nil,
                        metadata: [
                            "model_id": modelId.rawValue,
                            "audio_seconds": String(format: "%.1f", audioSeconds),
                            "chars": "\(joined.count)"
                        ]
                    ))
                    print("[whisper_stt] transcribed duration_ms=\(ms) "
                        + "audio_seconds=\(String(format: "%.1f", audioSeconds)) "
                        + "chars=\(joined.count)")
                    completion(.success(joined))
                }
            } catch {
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                self?.emit("inference_failed", errorCode: "whisper_error")
                print("[whisper_stt] inference_failed duration_ms=\(ms) \(error)")
                completion(.failure(.recognitionFailed(error)))
            }
        }
        #else
        emit("inference_unavailable", errorCode: "runtime_missing")
        completion(.failure(.localeUnsupported))
        #endif
    }

    /// Pick which cached Whisper model to run.
    ///
    ///   1. The user's explicit pick from the UI (RAM-gated only for the
    ///      1.9 GB large-v3; the small models fit every supported device).
    ///   2. Automatic order is device-tier-aware: the large-v3 Nepali
    ///      fine-tune first when the device can hold it (6 GB class) —
    ///      the stock small produces gibberish on Nepali (109% WER in
    ///      the eval), so it is a low-RAM fallback, not the default on
    ///      capable devices. Then small multilingual, then base-en.
    private func selectModelId() -> ModelID? {
        if let pref = preferredModelID {
            if modelStore.isCached(pref) {
                if pref != ModelCatalog.whisperLargeV3Nepali
                    || fitsRAM(ModelCatalog.whisperLargeV3Nepali) {
                    return pref
                }
            } else {
                emit("preferred_model_not_cached", errorCode: "not_cached")
            }
        }
        if modelStore.isCached(ModelCatalog.whisperLargeV3Nepali) {
            if fitsRAM(ModelCatalog.whisperLargeV3Nepali) {
                return ModelCatalog.whisperLargeV3Nepali
            }
            // fitsRAM emitted model_skipped_ram — drop through to small.
        }
        if modelStore.isCached(ModelCatalog.whisperSmallMultilingual) {
            return ModelCatalog.whisperSmallMultilingual
        }
        if modelStore.isCached(ModelCatalog.whisperBaseEn) {
            return ModelCatalog.whisperBaseEn
        }
        return nil
    }

    /// True when the device's memory ceiling can hold the model. Emits
    /// `model_skipped_ram` when it can't.
    private func fitsRAM(_ id: ModelID) -> Bool {
        guard let entry = ModelCatalog.entry(for: id),
              MemoryProbe.canFit(entry.minDeviceRAMBytes) else {
            observabilityBus.emit(ObservabilityEvent(
                component: "whisper_stt",
                eventType: "model_skipped_ram",
                durationMs: nil,
                outcome: "info",
                errorCode: "ram_insufficient",
                metadata: ["state": id.rawValue]
            ))
            return false
        }
        return true
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
