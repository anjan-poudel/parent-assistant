import Foundation

#if canImport(SherpaOnnx)
import SherpaOnnx
#endif

// MARK: - Model-file lookup (bundle + ModelStore managed directory)

/// Where the sherpa-onnx KWS model directory comes from. Slice A of
/// voice-personalisation P0 replaces the Porcupine wake-word engine (free
/// tier ended 2026-06-30) with sherpa-onnx's streaming Zipformer keyword
/// spotter. Unlike Porcupine there is NO access key and NO trained `.ppn`:
/// the keyword is a plain-text runtime file (`keywords.txt`, one
/// BPE-tokenized line per keyword — "HEY SAHAYAK" needs no retraining,
/// docs/research-sections/speaker-fingerprint.md §5).
///
/// The model is a DIRECTORY artifact (sherpa layout, same shape as the TTS
/// voices): `encoder/decoder/joiner-*.int8.onnx` + `tokens.txt` +
/// `keywords.txt` (+ `bpe.model` for provenance), fetched into
/// `ios/ElderlyAssistant/Resources/Models/kws/` by
/// tools/fetch-kws-model.sh and bundled as `kws/` (project.yml folder
/// reference, mirroring `tts/`).
enum SherpaKWSModelFile {
    /// The bundle subdirectory the model dir lands in (project.yml folder
    /// reference `Resources/Models/kws` → bundle `kws/`).
    static let bundleSubdirectory = "kws"

    /// The runtime keyword file inside the model directory. Written by the
    /// fetch script; edited at runtime = new keywords, no retraining.
    static let keywordsFileName = "keywords.txt"

    /// The well-known catalog ID the app's wake-word path uses.
    static var catalogID: ModelID { ModelCatalog.sherpaKWSGigaSpeech }

    /// Absolute URL of the bundled model directory, or nil when this
    /// build has no KWS model (the normal state until
    /// tools/fetch-kws-model.sh has been run — the selection then falls
    /// back exactly as before).
    static func bundledDirectory(in bundle: Bundle = .main) -> URL? {
        guard let entry = ModelCatalog.entry(for: catalogID),
              let url = bundle.url(forResource: entry.filename,
                                   withExtension: nil,
                                   subdirectory: bundleSubdirectory) else {
            return nil
        }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path,
                                              isDirectory: &isDir)
            && isDir.boolValue ? url : nil
    }
}

/// Why a real sherpa engine could not be built. Every case is surfaced as
/// an observability event by `SherpaKWSWakeWordEngine.attempt` — honest
/// unavailability, never a silent stub.
enum SherpaKWSUnavailableReason: Error {
    /// No model directory anywhere (bundle or ModelStore).
    case modelDirectoryMissing
    /// The directory exists but lacks a required file.
    case missingRequiredFile(String)
    /// This build was compiled without the sherpa-onnx package.
    case runtimeNotLinked
    /// The ONNX files are present but sherpa refused to load them.
    case engineInitFailed
}

/// The exact sherpa-layout files the engine needs inside the model
/// directory. Only the int8 trio ships (fetched by tools/fetch-kws-model.sh
/// — the fp32 trio and test wavs are stripped to keep the bundle ~5 MB).
struct SherpaKWSModelFiles {
    let directory: URL
    let encoder: URL
    let decoder: URL
    let joiner: URL
    let tokens: URL
    let keywords: URL

    /// Locates every required file inside `directory`. Pure file-system
    /// check — no sherpa runtime involved, so tests can drive it with
    /// placeholder files.
    static func resolve(in directory: URL,
                        keywordsFileName: String = SherpaKWSModelFile.keywordsFileName) -> Result<SherpaKWSModelFiles, SherpaKWSUnavailableReason> {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue else {
            return .failure(.modelDirectoryMissing)
        }
        let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        func int8File(_ prefix: String) -> String? {
            // Pinned naming convention of the gigaspeech archive:
            // encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx.
            contents.first { $0.hasPrefix(prefix) && $0.hasSuffix(".int8.onnx") }
        }
        guard let encoderName = int8File("encoder-") else {
            return .failure(.missingRequiredFile("encoder-*.int8.onnx"))
        }
        guard let decoderName = int8File("decoder-") else {
            return .failure(.missingRequiredFile("decoder-*.int8.onnx"))
        }
        guard let joinerName = int8File("joiner-") else {
            return .failure(.missingRequiredFile("joiner-*.int8.onnx"))
        }
        guard contents.contains("tokens.txt") else {
            return .failure(.missingRequiredFile("tokens.txt"))
        }
        guard contents.contains(keywordsFileName) else {
            return .failure(.missingRequiredFile(keywordsFileName))
        }
        return .success(SherpaKWSModelFiles(
            directory: directory,
            encoder: directory.appendingPathComponent(encoderName),
            decoder: directory.appendingPathComponent(decoderName),
            joiner: directory.appendingPathComponent(joinerName),
            tokens: directory.appendingPathComponent("tokens.txt"),
            keywords: directory.appendingPathComponent(keywordsFileName)
        ))
    }
}

// MARK: - Engine

/// Real wake-word detector using sherpa-onnx's streaming keyword spotter
/// (Zipformer transducer, English gigaspeech 3.3M int8 — ~5 MB on disk,
/// Apache-2.0, official Swift/SPM bindings, iOS 15+).
///
/// Construction order (2026-09-08, slice A of voice-personalisation P0):
///  1. The MODEL is a bundled directory (`Resources/Models/kws/`, fetched
///     by tools/fetch-kws-model.sh — gitignored). On first use it is
///     installed into the ModelStore's managed directory (kind == .kws
///     directory install, Data Protection Complete) — or, when no
///     ModelStore is reachable (the current static selection seam), the
///     engine loads straight from the bundle, exactly like the Porcupine
///     `.ppn` it replaces.
///  2. `SherpaKWSWakeWordEngine.attempt(...)` validates the files and
///     constructs the engine. Model load happens HERE (once per launch —
///     the engine is fixed per launch), so `start()` cannot fail later
///     and take the whole VoicePipeline down with it.
///  3. Selection (`WakeWordEngineSelection.make`) returns this engine
///     whenever the toggle is ON and a model exists; otherwise the caller
///     falls back to `NullWakeWordEngine` (2026-09-08: the legacy
///     Porcupine chain is gone — sherpa is the only real engine).
///
/// Keyword: the Nepali wake phrase "ये कान्छी" is read from the model
/// directory's `keywords.txt` — pre-tokenized BPE lines written by the
/// fetch script (the sherpa runtime does not tokenize raw text itself;
/// every space-separated token must exist in tokens.txt or spotter init
/// fails). Editing that file at runtime changes the wake phrase without
/// retraining.
///
/// 2026-09-08 (measured, user recordings through this engine): the
/// English GigaSpeech model does NOT hear Nepali-accented "ये कान्छी"
/// as its English romanization — the keyword-biased decode locks the
/// कान्छी syllable as GUNCI and take-dependent whole-phrase decodes as
/// "IT CAN SEE", which is what keywords.txt ships (decode-derived lines,
/// each verified to fire; see tools/fetch-kws-model.sh and
/// WakeWordUserRecordingProbeTests). Honest gap (research §5): no
/// Nepali KWS model exists; GigaSpeech-English on Nepali speech is
/// inherently lossy, so utterance coverage is high but not guaranteed
/// and ambient-speech false positives are unmeasured.
final class SherpaKWSWakeWordEngine: WakeWordEngine {

    /// The USER-FACING phrase this engine listens for (romanized for
    /// display/metadata only). NOT the keywords.txt content — that file
    /// carries the decode-derived token lines written by
    /// tools/fetch-kws-model.sh and is the runtime source of truth.
    static let defaultKeyword = "YEAH KANCHHI"

    let requiredSampleRate: Double = 16_000
    /// Feed granularity the VoicePipeline tap uses. sherpa accepts any
    /// frame size (it buffers internally); 512 matches the frames the
    /// other engines already receive.
    let frameLength: Int = 512

    /// Invoked on the main queue when the keyword fires.
    var onDetection: (() -> Void)?

    #if canImport(SherpaOnnx)
    private let spotter: SherpaOnnxKeywordSpotterWrapper
    #endif
    private let observabilityBus: ObservabilityBus
    private var active = false

    // MARK: - Construction (model load happens here, not in start())

    init(files: SherpaKWSModelFiles,
         observabilityBus: ObservabilityBus? = nil) throws {
        self.observabilityBus = observabilityBus ?? NoopObservabilityBus()
        // A keywords file that exists but carries NO lines would build a
        // spotter that never fires (EncodeBase over an empty file) — a
        // silent stub. Reject it here, before any C call.
        guard let keywordsText = try? String(contentsOf: files.keywords,
                                             encoding: .utf8),
              !keywordsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.observabilityBus.emit(Self.event("kws_engine_init_failed",
                                                  outcome: "failure",
                                                  errorCode: "empty_keywords"))
            throw SherpaKWSUnavailableReason.engineInitFailed
        }
        #if canImport(SherpaOnnx)
        guard let spotter = Self.makeSpotter(files: files) else {
            self.observabilityBus.emit(Self.event("kws_engine_init_failed",
                                                  outcome: "failure",
                                                  errorCode: "init_failed"))
            throw SherpaKWSUnavailableReason.engineInitFailed
        }
        self.spotter = spotter
        #else
        // A build without the sherpa-onnx package linked (project.yml
        // pins it today) cannot detect anything — fail honestly at
        // selection time so the caller falls back, never a silent stub.
        self.observabilityBus.emit(Self.event("kws_runtime_unavailable",
                                              outcome: "failure",
                                              errorCode: "runtime_unavailable"))
        throw SherpaKWSUnavailableReason.runtimeNotLinked
        #endif
    }

    /// Selection entry point: returns a live engine when the model is
    /// installed and loadable, nil otherwise (with an honest event on the
    /// supplied bus). Never throws, never crashes.
    ///
    /// Model resolution order mirrors the TTS-voice pattern: the
    /// ModelStore's managed directory first (lazy install from the bundle
    /// on first use — Data Protection Complete), then the bundle copy
    /// directly when no store is available.
    static func attempt(modelStore: ModelStore? = nil,
                        bundle: Bundle = .main,
                        observabilityBus: ObservabilityBus? = nil) -> WakeWordEngine? {
        let bus = observabilityBus ?? NoopObservabilityBus()

        let directory: URL?
        if let modelStore {
            // Managed-directory path: install lazily from the bundle on
            // first use (Data Protection Complete), mirroring the TTS
            // voices.
            directory = modelStore.kwsModelDirectory(for: SherpaKWSModelFile.catalogID)
                ?? modelStore.installBundledKWSModel(for: SherpaKWSModelFile.catalogID,
                                                     bundle: bundle)
        } else {
            // Bundle-direct path: the current static selection seam has no
            // ModelStore reachable — read the bundle copy in place, like
            // the Porcupine .ppn this replaces.
            directory = SherpaKWSModelFile.bundledDirectory(in: bundle)
        }

        guard let directory else {
            bus.emit(Self.event("kws_engine_unavailable", outcome: "failure",
                                errorCode: "model_missing"))
            return nil
        }

        switch SherpaKWSModelFiles.resolve(in: directory) {
        case .success(let files):
            guard let engine = try? SherpaKWSWakeWordEngine(files: files,
                                                            observabilityBus: bus) else {
                // init already emitted the precise reason.
                return nil
            }
            bus.emit(Self.event("kws_engine_ready", outcome: "success",
                                errorCode: nil))
            return engine
        case .failure(let reason):
            if case .missingRequiredFile(let name) = reason {
                bus.emit(Self.event("kws_engine_unavailable", outcome: "failure",
                                    errorCode: "missing_file",
                                    detail: name))
            } else {
                bus.emit(Self.event("kws_engine_unavailable", outcome: "failure",
                                    errorCode: "model_missing"))
            }
            return nil
        }
    }

    // MARK: - WakeWordEngine

    func start() throws {
        // The model is fully loaded (constructed) by the time selection
        // hands this engine to the pipeline — same contract as the
        // Porcupine engine: nothing left to start.
        active = true
    }

    func stop() {
        active = false
        #if canImport(SherpaOnnx)
        // Drop half-buffered audio: a keyword that completed while the
        // gate was closed must not fire on stale chunks when listening
        // resumes. (sherpa also self-resets the context after ~1.5 s of
        // trailing blanks — this is the immediate, deterministic cut.)
        spotter.reset()
        #endif
    }

    func process(_ pcm: [Int16]) {
        guard active else { return }
        #if canImport(SherpaOnnx)
        // sherpa expects [-1, 1) float samples at the model's rate.
        let samples = pcm.map { Float($0) / 32_768.0 }
        spotter.acceptWaveform(samples: samples, sampleRate: 16_000)
        // Official sherpa loop: isReady() means ≥ one full chunk (320 ms)
        // is buffered; decode() then drains it and getResult() returns
        // anything fired during THAT decode (it resets readiness, so the
        // loop exits until the next chunk boundary). 512 samples arrive
        // per call (32 ms), so the loop body runs ~every tenth frame.
        while spotter.isReady() {
            spotter.decode()
            let result = spotter.getResult()
            if !result.keyword.isEmpty {
                // Match ANY fired keyword: this build's keywords file
                // carries the single "HEY SAHAYAK" line. The matched text
                // is deliberately NOT logged (PII-free observability —
                // a threshold slip could otherwise surface random
                // overheard speech in events).
                spotter.reset()
                DispatchQueue.main.async { [weak self] in
                    self?.onDetection?()
                }
            }
        }
        #endif
    }

    // MARK: - Internals

    #if canImport(SherpaOnnx)
    /// Builds the sherpa keyword spotter from the int8 model files.
    /// Returns nil when sherpa refuses the files (corrupt download etc.)
    /// — file-presence validation already happened in
    /// `SherpaKWSModelFiles.resolve`.
    private static func makeSpotter(files: SherpaKWSModelFiles) -> SherpaOnnxKeywordSpotterWrapper? {
        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: files.encoder.path,
            decoder: files.decoder.path,
            joiner: files.joiner.path
        )
        let model = sherpaOnnxOnlineModelConfig(
            tokens: files.tokens.path,
            transducer: transducer,
            numThreads: 1,          // int8 3.3M — one thread is ample for
                                    // the always-on path and keeps the ANE
                                    // / CPU budget predictable.
            provider: "cpu",
            debug: 0,
            modelType: "",
            modelingUnit: "bpe"
        )
        let features = sherpaOnnxFeatureConfig(sampleRate: 16_000,
                                               featureDim: 80)
        var config = sherpaOnnxKeywordSpotterConfig(
            featConfig: features,
            modelConfig: model,
            keywordsFile: files.keywords.path,
            maxActivePaths: 4,
            numTrailingBlanks: 1,
            keywordsScore: 1.0,
            keywordsThreshold: 0.25
        )
        let spotter = SherpaOnnxKeywordSpotterWrapper(config: &config)
        guard spotter.spotter != nil else { return nil }
        return spotter
    }
    #endif

    static func event(_ eventType: String, outcome: String,
                      errorCode: String?, detail: String? = nil) -> ObservabilityEvent {
        var metadata = ["state": SherpaKWSModelFile.catalogID.rawValue]
        if let detail {
            // e.g. the missing file NAME — never audio content.
            metadata["missing"] = detail
        }
        return ObservabilityEvent(
            component: "wake_word",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: metadata
        )
    }
}

/// PII-free no-op observability bus, used when the engine is built by the
/// pure selection path (no coordinator-injected bus yet). Integration
/// point: pass the app's real bus via `attempt(observabilityBus:)`.
private struct NoopObservabilityBus: ObservabilityBus {
    func emit(_ event: ObservabilityEvent) {}
}
