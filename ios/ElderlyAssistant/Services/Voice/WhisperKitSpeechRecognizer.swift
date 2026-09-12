import Foundation
import AVFoundation
import CoreML
#if canImport(WhisperKit)
import WhisperKit
#endif

// MARK: - First-use prewarm policy ([LAT-EVIDENCE], 2026-09-12)
//
// Device evidence: with the boot warm skipped, the FIRST transcribe paid
// the one-time CoreML/ANE specialization INSIDE the turn
// (`transcribed duration_ms=10633` for 2.7 s audio). The fix: at the
// start of a listening session, when the weights are not resident (the
// boot warm was skipped, or the post-turn hold lapsed), a background
// `prepare` runs on the whisper queue so the specialization compiles
// while the user speaks — off the turn path. NON-GATING: the transcribe
// never waits on it; when it is still running at `finish()`, `loadKit`
// joins the in-flight load instead of constructing a second instance
// (a duplicate would double the ~1.5 GB footprint).
//
/// The pure first-use prewarm decision.
enum WhisperFirstUsePrewarmPolicy {
    static func shouldPrewarm(isModelLoaded: Bool,
                              isAvailable: Bool,
                              isSimulator: Bool) -> Bool {
        // The simulator skip mirrors the boot warm doctrine
        // (OnDeviceSTTSelection): the CPU-only WhisperKit prepare is a
        // minutes-scale load that never helps a sim conversation.
        !isModelLoaded && isAvailable && !isSimulator
    }
}

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
    /// [TURN-TIMING] Turn-scoped stage tracer, property-injected by the
    /// coordinator (nil = timing off). Marks `asr_loaded` with the
    /// measured load ms when a model loads mid-turn.
    var turnTracer: VoiceTurnLatencyTracer?

    /// Which catalog artifact (a directory) to load in normal mode.
    private let preferredModelID: ModelID

    // Bench hooks (env-driven, set by AppCoordinator's
    // makeWhisperKitBenchRecognizer): use a local folder or a named
    // model that WhisperKit downloads itself (e.g. "large-v3-turbo").
    var modelFolderURL: URL?
    var modelName: String?

    /// [LAT-EVIDENCE] Test seam: when non-nil, runs INSTEAD of the real
    /// background prewarm at listening start (the policy decision is
    /// real; only the load is replaced). Bench/tests only.
    var firstUsePrewarmOverride: (() -> Void)?
    /// [LAT-EVIDENCE] Bench/test override for the simulator gate: the
    /// prewarm skips the simulator by doctrine (the CPU-only prepare
    /// never helps a sim conversation) — tests force the DEVICE path
    /// with `false` so the seam is exercisable on the simulator.
    var firstUsePrewarmSimulatorOverride: Bool?

    #if canImport(WhisperKit)
    /// [LAT-EVIDENCE] Dedupe for concurrent loads: the non-gating
    /// first-use prewarm and the first transcribe may both reach
    /// `loadKit` — the transcribe JOINS the in-flight load (see the
    /// header) instead of constructing a second instance.
    private final class LoadBox {
        let task: Task<WhisperKit, Error>
        init(_ task: Task<WhisperKit, Error>) { self.task = task }
    }
    private let loadStateLock = NSLock()
    private var pendingLoadBox: LoadBox?
    #endif

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

    /// [LAT-M1] True while the model weights are resident — loaded by the
    /// boot warm, a live turn, or the post-turn re-warm. The post-turn
    /// hold policy consults this: there is nothing to hold (or re-warm)
    /// when the recognizer never loaded (a fallback STT served the turn).
    /// Read on main while `kitInstance` is written on the inference
    /// queue — a benign existence check, worst case one turn's
    /// misattribution (same class as the coordinator's other engine
    /// state reads).
    var isModelLoaded: Bool { kitInstance != nil }

    init(observabilityBus: ObservabilityBus,
         modelStore: ModelStore? = nil,
         preferredModelID: ModelID = ModelCatalog.whisperKitNepaliMedium) {
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

        // [LAT-EVIDENCE] First-use prewarm: when the boot warm was
        // skipped (or the post-turn hold released the weights), begin a
        // background prepare NOW — before the first transcribe — so the
        // one-time CoreML/ANE specialization compiles off the turn path.
        // Non-gating: the transcribe never waits; loadKit joins the
        // in-flight load when the prepare is still running.
        #if canImport(WhisperKit)
        let isSimulator = firstUsePrewarmSimulatorOverride
            ?? WhisperKit.isRunningOnSimulator
        #else
        let isSimulator = firstUsePrewarmSimulatorOverride ?? true
        #endif
        if WhisperFirstUsePrewarmPolicy.shouldPrewarm(
            isModelLoaded: isModelLoaded,
            isAvailable: isAvailable,
            isSimulator: isSimulator) {
            if let firstUsePrewarmOverride {
                firstUsePrewarmOverride()
            } else {
                emit("first_use_prewarm", errorCode: nil, outcome: "started")
                inferenceQueue.async { [weak self] in
                    self?.prepare()
                }
            }
        }

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
        // [VAD-RT] Pure-Float normalization (32768 is an exact Float
        // power of two) — the old `/ 32_768.0` ran Double division per
        // sample on the live capture path.
        let floats = UnsafeBufferPointer(start: channelData, count: count)
            .map { Float($0) / 32768 }
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

    /// Drops the loaded model so its RAM (~1.5 GB for medium-class
    /// CoreML) is available to the LLM interpreter — same contract as
    /// `WhisperSpeechRecognizer.releaseModel()`, called from
    /// `AppCoordinator.recordTranscript`. The next utterance reloads on
    /// demand (the load is seconds on ANE, not the CPU minutes).
    func releaseModel() {
        kitInstance = nil
        loadedDescriptor = nil
    }

    // MARK: - Inference (guarded)

    /// Preloads the model off the critical path: call at hot-swap time
    /// ([STARTUP-R2]) and at first use ([LAT-EVIDENCE] — the
    /// listening-start prewarm when the boot warm was skipped) so the
    /// first utterance doesn't pay the load + CoreML specialization.
    func prepare() {
        warm()
    }

    /// Warm-start seam (`STTModelWarming`): preloads the model weights +
    /// CoreML specialization in the background and reports the outcome.
    /// `completion` (when given) is called on an arbitrary queue — never
    /// assumed main. Failures are honest and never throw: a missing
    /// model, a missing runtime, or a failed load are `.failed(reason)`
    /// results the boot's warm phase records (and moves past).
    func warm(completion: ((WarmStartEngineResult) -> Void)? = nil) {
        #if canImport(WhisperKit)
        guard let (descriptor, config) = loadDescriptor() else {
            completion?(.failed(reason: "no_model_path"))
            return
        }
        Task { [weak self] in
            guard let self else {
                completion?(.failed(reason: "deallocated"))
                return
            }
            do {
                _ = try await self.loadKit(descriptor: descriptor, config: config)
                completion?(.ready)
            } catch {
                #if DEBUG
                // B1/T-049 (review fix): Debug-build-only, and content-free
                // even here — a raw error object's description can carry a
                // key-bearing URL, an upstream body or a path. The
                // completion's "load_failed" reason is the Release-side
                // signal. Same construct as the inference-failure print
                // below. This print sits inside `#if canImport(WhisperKit)`,
                // which is NOT a Debug gate.
                let nsError = error as NSError
                print("[whisperkit_stt] warm failed domain=\(nsError.domain) "
                    + "code=\(nsError.code)")
                #endif
                completion?(.failed(reason: "load_failed"))
            }
        }
        #else
        completion?(.failed(reason: "runtime_missing"))
        #endif
    }

    /// Resolves the load descriptor: bench folder/name first, then the
    /// catalog directory artifact.
    private func loadDescriptor() -> (String, WhisperKitConfig)? {
        #if canImport(WhisperKit)
        let config = WhisperKitConfig()
        config.verbose = true
        // Absorb the one-time CoreML specialization into model load so the
        // first utterance doesn't pay it.
        config.prewarm = true
        if let folder = modelFolderURL {
            return ("folder:\(folder.path)", {
                config.modelFolder = folder.path
                return config
            }())
        }
        if let name = modelName {
            return ("name:\(name)", {
                config.model = name
                return config
            }())
        }
        if let url = modelStore?.directoryURL(for: preferredModelID) {
            return ("artifact:\(preferredModelID.rawValue)", {
                config.modelFolder = url.path
                return config
            }())
        }
        #endif
        return nil
    }

    /// Loads (or reuses) the WhisperKit instance for a descriptor.
    /// [LAT-EVIDENCE] Concurrent loaders JOIN one in-flight load: the
    /// non-gating first-use prewarm and the first transcribe may race to
    /// the load — a second construction would double the ~1.5 GB
    /// footprint. A failed load clears the pending slot so a later
    /// attempt starts fresh (a stale failure can never poison every
    /// future load).
    private func loadKit(descriptor: String, config: WhisperKitConfig) async throws -> WhisperKit {
        if let existing = kitInstance as? WhisperKit,
           loadedDescriptor == descriptor {
            return existing
        }
        let box: LoadBox
        loadStateLock.lock()
        if let pending = pendingLoadBox {
            box = pending
            loadStateLock.unlock()
        } else {
            let created = Task<WhisperKit, Error> { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.createKit(descriptor: descriptor, config: config)
            }
            let fresh = LoadBox(created)
            pendingLoadBox = fresh
            box = fresh
            loadStateLock.unlock()
        }
        do {
            let kit = try await box.task.value
            clearPendingLoad(box)
            return kit
        } catch {
            clearPendingLoad(box)
            throw error
        }
    }

    private func clearPendingLoad(_ box: LoadBox) {
        loadStateLock.lock()
        if pendingLoadBox === box { pendingLoadBox = nil }
        loadStateLock.unlock()
    }

    /// The one real construction (behind the dedupe): builds the kit,
    /// caches it, and reports the load.
    private func createKit(descriptor: String,
                           config: WhisperKitConfig) async throws -> WhisperKit {
        let loadStart = CFAbsoluteTimeGetCurrent()
        let created = try await WhisperKit(config)
        let loadMs = Int((CFAbsoluteTimeGetCurrent() - loadStart) * 1000)
        kitInstance = created
        loadedDescriptor = descriptor
        emit("model_loaded", errorCode: nil)
        // [TURN-TIMING] Model ready — the load ms rides as a point entry
        // when this load happened inside a live turn.
        turnTracer?.mark("asr_loaded", elapsedMs: loadMs)
        print("[whisperkit_stt] model_loaded \(descriptor) load_ms=\(loadMs)")
        // What hardware the components will actually run on.
        // NE = Neural Engine (ANE). The simulator forces
        // .cpuOnly — real devices get the NE path.
        let compute = config.computeOptions ?? ModelComputeOptions()
        print("[whisperkit_stt] GPU/ANE: audioEncoder=\(compute.audioEncoderCompute) "
            + "textDecoder=\(compute.textDecoderCompute) "
            + "mel=\(compute.melCompute) "
            + "simulator=\(WhisperKit.isRunningOnSimulator)")
        return created
    }

    private func runInference(_ audio: [Float],
                              completion: @escaping (Result<String, RecognitionError>) -> Void) {
        #if canImport(WhisperKit)
        guard let (descriptor, config) = loadDescriptor() else {
            emit("model_path_missing", errorCode: "no_path")
            completion(.failure(.localeUnsupported))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let kit = try await self.loadKit(descriptor: descriptor, config: config)

                let start = CFAbsoluteTimeGetCurrent()
                print("[whisperkit_stt] transcribing samples=\(audio.count)")
                let compute = config.computeOptions ?? ModelComputeOptions()
                print("[whisperkit_stt] GPU/ANE: audioEncoder=\(compute.audioEncoderCompute) "
                    + "textDecoder=\(compute.textDecoderCompute) mel=\(compute.melCompute) "
                    + "simulator=\(WhisperKit.isRunningOnSimulator)")
                // Force Nepali transcription — auto language detection on
                // short utterances produced English (translate-ish) output.
                // [SCRIPT-REGRESSION] while a dialect-bias plan is active
                // the forced "ne" is load-bearing: together with the
                // Devanagari-only prompt gate it keeps the decoder in
                // Nepali-language mode so transcripts stay Devanagari
                // instead of drifting to roman script under prompt bias.
                // The decision lives in `decodeLanguageCode` so tests can
                // pin it without the WhisperKit runtime.
                let biasPlan = resolvedDialectBias()
                var options = DecodingOptions(
                    task: .transcribe,
                    language: Self.decodeLanguageCode(biasPlanState: biasPlan.state))
                // [ACCENT-ADAPT] dialect-tagged prompt biasing (doc
                // accent-adaptation.md P0.3): composed lexicon + profile
                // terms + calibrated ids, capped at 100 tokens. A plan
                // that applies nothing (default label, disabled, no
                // material) leaves the options exactly as before — zero
                // behaviour change.
                if biasPlan.state == .active {
                    let tokenizer: ((String) -> [Int])? = kit.tokenizer.map {
                        tokenizer in { text in tokenizer.encode(text: text) }
                    }
                    switch Self.promptTokens(for: biasPlan,
                                             tokenizer: tokenizer) {
                    case .applied(let tokens):
                        options.promptTokens = tokens
                        emitBiasActive(biasPlan, tokenCount: tokens.count,
                                       runtime: "whisperkit")
                    case .notApplied(let reason):
                        reportDialectUnavailableOnce(
                            &dialectBiasingUnavailableReported,
                            event: "dialect_bias_unavailable",
                            reason: reason)
                    }
                } else if biasPlan.state == .disabledByUser {
                    reportDialectUnavailableOnce(
                        &dialectBiasDisabledReported,
                        event: "dialect_bias_disabled",
                        reason: "disabled_by_user",
                        outcome: "info")
                }
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
                    #if DEBUG
                    // Debug-build-only, per explicit request for on-device
                    // WER review — never compiled into Release (B1/T-049:
                    // transcript content is exactly the material NFR-016
                    // forbids in any log sink, and this print bypasses the
                    // sanitised observability bus). Same construct as the
                    // guarded prints in GeminiSpeechRecognizer.
                    print("[whisperkit_stt] transcript=" + joined)
                    #endif
                    completion(.success(joined))
                }
            } catch {
                emit("inference_failed", errorCode: "whisperkit_error")
                #if DEBUG
                // B1/T-049: Debug-build-only, and content-free even here —
                // a raw error object's description can carry a key-bearing
                // URL, an upstream body or a path. Domain + numeric code
                // is the diagnostic value; the bus event above carries the
                // content-free code in Release.
                let nsError = error as NSError
                print("[whisperkit_stt] inference_failed domain=\(nsError.domain) "
                    + "code=\(nsError.code)")
                #endif
                completion(.failure(.recognitionFailed(error)))
            }
        }
        #else
        emit("inference_unavailable", errorCode: "runtime_missing")
        completion(.failure(.localeUnsupported))
        #endif
    }

    // MARK: - Observability

    private func emit(_ eventType: String,
                      errorCode: String?,
                      component: String = "whisperkit_stt",
                      metadata: [String: String] = [:],
                      outcome: String? = nil) {
        observabilityBus.emit(ObservabilityEvent(
            component: component,
            eventType: eventType,
            durationMs: nil,
            outcome: outcome ?? (errorCode == nil ? "info" : "failure"),
            errorCode: errorCode,
            metadata: metadata
        ))
    }

    // MARK: - Dialect ID seam + decode biasing
    //
    // Seam contract (DialectIdentifier.swift / DialectBiasComposer.swift /
    // docs/research-sections/accent-adaptation.md §6 P0.3): the label +
    // seam are the deliverable; accent packs are server work. Everything
    // here is inert while the persisted label is `.default` — existing
    // STT behaviour is byte-identical in that state. A non-default label
    // biases the decode with the composed prompt (lexicon + profile terms
    // + calibrated ids, ≤100 tokens).

    /// Once-per-session honesty flags: an unavailable dialect path is
    /// reported a single time, never spammed per utterance.
    private var dialectEmbeddingUnavailableReported = false
    private var dialectBiasingUnavailableReported = false
    private var dialectBiasDisabledReported = false

    /// Per-user decode-biasing terms (contact names, medication names,
    /// app names) — injected by the coordinator, default empty. Called on
    /// the inference queue once per utterance; the composer caps and
    /// sanitises whatever it returns. PII never leaves the device.
    var biasProfileProvider: (() -> DialectBiasProfile)?

    /// Resolves the current adaptation (label + lexicon + profile terms +
    /// calibrated ids) into a plan. Pure composition decides whether this
    /// decode biases at all.
    private func resolvedDialectBias() -> DialectBiasPlan {
        let profile = biasProfileProvider?() ?? DialectBiasProfile()
        return DialectBiasResolver.resolve(profile: profile)
    }

    /// Final prompt-token list for an active plan, or an honest refusal.
    enum PromptTokenOutcome: Equatable, Sendable {
        case applied([Int])
        case notApplied(String)
    }

    /// [SCRIPT-REGRESSION] Language code for the WhisperKit decode
    /// options. Always "ne": while a dialect-bias plan is active the
    /// decoder MUST stay in Nepali-language mode — together with the
    /// Devanagari-only prompt gate this keeps transcripts Devanagari
    /// instead of drifting to roman script under prompt bias. The
    /// inactive states deliberately keep the pre-existing unconditional
    /// "ne" force (auto language detection on short utterances produced
    /// English output) — byte-identical to the pre-fix construction.
    /// Static + Foundation-only so unit tests pin it without the runtime.
    static func decodeLanguageCode(biasPlanState: DialectBiasPlan.State) -> String {
        switch biasPlanState {
        case .active:
            return "ne"
        case .disabledByUser, .defaultLabel, .noMaterial:
            return "ne"
        }
    }

    /// Static + CoreML-free so the merge/fallback logic is unit-testable
    /// without a loaded model: tokenizes `promptText` through the given
    /// tokenizer (nil = no runtime tokenizer — degrade to calibrated ids
    /// when present, else an honest refusal) and merges with the
    /// calibrated table ids under the 100-token cap.
    static func promptTokens(for plan: DialectBiasPlan,
                             tokenizer: ((String) -> [Int])?) -> PromptTokenOutcome {
        guard plan.state == .active else { return .notApplied("inactive") }
        var tokenized: [Int] = []
        if let text = plan.promptText, !text.isEmpty {
            // [SCRIPT-REGRESSION] script-consistency gate, defence in
            // depth (the composer already drops roman terms): a prompt
            // with no Devanagari term must never bias the decoder toward
            // roman-script output, so a roman-only prompt degrades to
            // calibrated ids or an honest refusal.
            guard DialectBiasComposer.containsDevanagariTerm(text) else {
                if plan.calibratedTokenIds.isEmpty {
                    return .notApplied("non_devanagari_prompt")
                }
                return .applied(DialectBiasComposer.mergeTokenIDs(
                    calibrated: plan.calibratedTokenIds, tokenized: []))
            }
            guard let tokenizer else {
                if plan.calibratedTokenIds.isEmpty {
                    return .notApplied("tokenizer_missing")
                }
                return .applied(DialectBiasComposer.mergeTokenIDs(
                    calibrated: plan.calibratedTokenIds, tokenized: []))
            }
            tokenized = tokenizer(text)
        }
        let merged = DialectBiasComposer.mergeTokenIDs(
            calibrated: plan.calibratedTokenIds, tokenized: tokenized)
        return merged.isEmpty ? .notApplied("merge_empty") : .applied(merged)
    }

    /// Per-utterance observability for an applied bias (PII-free: counts
    /// and the label only, never term content).
    private func emitBiasActive(_ plan: DialectBiasPlan,
                                tokenCount: Int,
                                runtime: String) {
        emit("dialect_bias_active", errorCode: nil,
             component: "dialect_id",
             metadata: [
                "label": plan.label.rawValue,
                "runtime": runtime,
                "token_count": "\(tokenCount)",
                "text_chars": "\(plan.promptText?.count ?? 0)",
                "lexicon_phrases": "\(plan.lexiconPhraseCount)",
                "contacts": "\(plan.contactCount)",
                "medications": "\(plan.medicationCount)",
                "apps": "\(plan.appCount)",
                "calibrated_tokens": "\(plan.calibratedTokenIds.count)",
             ])
    }

    /// Enrolment seam (called by the future enrolment flow, one short sample
    /// per attempt): mean-pooled encoder embedding for
    /// `DialectIdentifier.classify`. Uses only the pinned WhisperKit
    /// revision's public chain — `audioProcessor.padOrTrim` →
    /// `featureExtractor.logMelSpectrogram` → `audioEncoder.encodeFeatures`
    /// (`encoder_output_embeds`), all exposed as public properties/methods on
    /// the loaded `WhisperKit` instance (verified at rev ea872ffd).
    ///
    /// Runs the encoder a second time over the same audio as transcription —
    /// acceptable at enrolment (one-time, 5–30 s samples per research §4.4),
    /// never on the utterance path.
    ///
    /// Returns nil whenever the embedding cannot be produced (never throws —
    /// unavailability is the nil path) and emits
    /// `dialect_embedding_unavailable` with the reason once per session.
    func extractDialectEmbedding(from audio: [Float]) async -> [Float]? {
        #if canImport(WhisperKit)
        guard let kit = kitInstance as? WhisperKit else {
            reportDialectUnavailableOnce(&dialectEmbeddingUnavailableReported,
                                         event: "dialect_embedding_unavailable",
                                         reason: "model_not_loaded")
            return nil
        }
        do {
            // 480 000 frames = 30 s at 16 kHz — fine for enrolment samples
            // (research §4.4: 5–30 s). Explicit toLength: the parameter is on
            // the AudioProcessing protocol requirement itself.
            guard let padded = kit.audioProcessor.padOrTrim(fromArray: audio,
                                                            startAt: 0,
                                                            toLength: 480_000) else {
                reportDialectUnavailableOnce(&dialectEmbeddingUnavailableReported,
                                             event: "dialect_embedding_unavailable",
                                             reason: "audio_padding_failed")
                return nil
            }
            guard let mel = try await kit.featureExtractor
                .logMelSpectrogram(fromAudio: padded) else {
                reportDialectUnavailableOnce(&dialectEmbeddingUnavailableReported,
                                             event: "dialect_embedding_unavailable",
                                             reason: "mel_extraction_failed")
                return nil
            }
            guard let encoded = try await kit.audioEncoder.encodeFeatures(mel),
                  let multiArray = encoded as? MLMultiArray else {
                reportDialectUnavailableOnce(&dialectEmbeddingUnavailableReported,
                                             event: "dialect_embedding_unavailable",
                                             reason: "encoder_output_missing")
                return nil
            }
            let shape = multiArray.shape.map(\.intValue)
            guard let flat = Self.flatten(multiArray) else {
                reportDialectUnavailableOnce(&dialectEmbeddingUnavailableReported,
                                             event: "dialect_embedding_unavailable",
                                             reason: "unsupported_scalar_type")
                return nil
            }
            // Pool against the bundled table's dimension when present (the
            // classifier dimension check is the final honesty gate); fall
            // back to the tensor's last axis for bench/unknown models.
            let dimension = DialectCentroidTable.bundledCached?.embeddingDimension
                ?? (shape.last ?? 0)
            guard let vector = DialectEmbeddingVector.meanPooled(shape: shape,
                                                                 values: flat,
                                                                 embeddingDimension: dimension),
                  !vector.isEmpty else {
                reportDialectUnavailableOnce(&dialectEmbeddingUnavailableReported,
                                             event: "dialect_embedding_unavailable",
                                             reason: "invalid_embedding_shape")
                return nil
            }
            return vector
        } catch {
            // e.g. WhisperError.modelsUnavailable when the encoder CoreML
            // model is not loaded — same unavailable semantics as above.
            reportDialectUnavailableOnce(&dialectEmbeddingUnavailableReported,
                                         event: "dialect_embedding_unavailable",
                                         reason: "encoder_error")
            #if DEBUG
            // B1/T-049 (review fix): Debug-build-only, and content-free even
            // here — a raw error object's description can carry a
            // key-bearing URL, an upstream body or a path. The
            // `dialect_embedding_unavailable` / "encoder_error" event above
            // is the Release-side signal. This print sits inside
            // `#if canImport(WhisperKit)`, which is NOT a Debug gate.
            let nsError = error as NSError
            print("[dialect_id] extractDialectEmbedding failed "
                + "domain=\(nsError.domain) code=\(nsError.code)")
            #endif
            return nil
        }
        #else
        reportDialectUnavailableOnce(&dialectEmbeddingUnavailableReported,
                                     event: "dialect_embedding_unavailable",
                                     reason: "runtime_missing")
        return nil
        #endif
    }

    /// Applies the user's dialect label: persists it (decode biasing takes
    /// effect from the next utterance) and emits the PII-free
    /// `dialect_label_set` event — label raw value only, never audio or
    /// transcripts.
    func applyDialectLabel(_ label: DialectLabel) {
        DialectPreference.persist(label)
        emit("dialect_label_set", errorCode: nil,
             component: "dialect_id",
             metadata: ["label": label.rawValue])
        print("[dialect_id] dialect_label_set label=\(label.rawValue)")
    }

    /// MLMultiArray → flat row-major [Float], supporting float32 fast-path
    /// and float16 (ANE/GPU encoder output can be fp16). Returns nil for any
    /// other scalar type — the caller reports that honestly rather than
    /// guessing at byte layouts.
    private static func flatten(_ multiArray: MLMultiArray) -> [Float]? {
        if multiArray.dataType == .float32 {
            return multiArray.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }
        }
        if multiArray.dataType == .float16 {
            return multiArray.withUnsafeBytes { buffer in
                // No Float16→Float conversion initializer is guaranteed
                // across toolchains, so convert via IEEE-754 half bits
                // (Apple platforms are little-endian; MLMultiArray storage
                // is native-endian).
                buffer.bindMemory(to: UInt16.self).map(Self.float16BitsToFloat)
            }
        }
        return nil
    }

    /// IEEE-754 binary16 → binary32 (canonical conversion, deterministic
    /// across toolchains; used when the encoder emits fp16 activations).
    private static func float16BitsToFloat(_ bits: UInt16) -> Float {
        let sign: Float = (bits & 0x8000) == 0 ? 1 : -1
        let exponent = Int((bits >> 10) & 0x1F)
        let fraction = Int(bits & 0x03FF)
        switch exponent {
        case 0:
            // Zero or subnormal: value = fraction × 2⁻²⁴.
            return sign * Float(fraction) * 0x1p-24
        case 31:
            // Infinity or NaN (NaN payload discarded — encoder output
            // should never contain either; NaN would poison the mean pool).
            return fraction == 0 ? sign * Float.infinity : .nan
        default:
            // Normal: (1 + fraction/1024) × 2^(exponent − 15).
            let scale = Float(pow(2.0, Double(exponent - 15)))
            return sign * (1024 + Float(fraction)) / 1024 * scale
        }
    }

    private func reportDialectUnavailableOnce(_ reported: inout Bool,
                                              event: String,
                                              reason: String,
                                              outcome: String = "failure") {
        guard !reported else { return }
        reported = true
        emit(event, errorCode: reason, component: "dialect_id",
             outcome: outcome)
        print("[dialect_id] \(event) reason=\(reason) outcome=\(outcome)")
    }
}

// MARK: - Warm-start seam (boot warm phase)

/// WhisperKit is the one whisper runtime that can be warmed: `loadKit`
/// caches the instance for the first utterance, unlike the whisper.cpp
/// recognizer's per-attempt fresh contexts.
extension WhisperKitSpeechRecognizer: STTModelWarming {}
