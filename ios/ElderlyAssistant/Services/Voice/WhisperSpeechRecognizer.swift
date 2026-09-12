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
        /// Hard deadline for one inference attempt — model load *and*
        /// `whisper_full` together — in seconds. whisper.cpp is a blocking
        /// C++ call that Swift cannot interrupt, and it has been observed
        /// to wedge forever on device (distilled model + ANE/Metal hang
        /// class). When the deadline expires the attempt is abandoned, the
        /// wedged context is dropped, and the pipeline receives
        /// `.timedOut` so the voice UI recovers. 90 s: the distilled
        /// model's CPU encoder measured 76–96 s PER PASS on a desktop Mac
        /// — a 30 s budget can never succeed on the phone and only
        /// produced a timeout loop. Two strikes still downshift to the
        /// cheaper model (see the throttle path).
        let inferenceTimeoutSeconds: TimeInterval

        static let `default` = Config(
            primaryLanguage: "ne",
            fallbackLanguage: "en",
            // [VAD-TUNE] Raised 10 -> 22 to mirror
            // `VoicePipeline.captureTimeoutSeconds`: the local clamp must
            // not pre-empt the pipeline's total capture cap, or slow
            // elderly speech gets cut here before the pipeline cap ever
            // applies.
            maxUtteranceSeconds: 22,
            forcePrimaryLanguage: true,
            inferenceTimeoutSeconds: 180
        )
    }

    private let modelStore: ModelStore
    private let observabilityBus: ObservabilityBus
    /// [TURN-TIMING] Turn-scoped stage tracer, property-injected by the
    /// coordinator (nil = timing off). Marks `asr_loaded` with the
    /// measured load ms when a model loads mid-turn.
    var turnTracer: VoiceTurnLatencyTracer?
    private let config: Config

    /// Held during a single utterance. int16 PCM at 16 kHz mono.
    private var utteranceBuffer: [Int16] = []
    private var completion: ((Result<String, RecognitionError>) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    private var listeningActive = false

    /// Where the LoRA (if any) is applied. Phase 1: skeleton only — logs
    /// and no-ops. See applyLoRA docs.
    private var activeLoRA: ModelID?

    // MARK: - Inference attempt machinery
    //
    // whisper.cpp inference is a blocking C++ call that Swift cannot
    // interrupt or unwind: `whisper_full` (and, for a fresh load, the
    // model read inside `Whisper(fromFileURL:)`) occupies its thread until
    // it returns — and on the distilled model it has been observed to
    // never return. Defence in depth:
    //
    //  * One fresh serial queue + one fresh Whisper context per attempt.
    //    A wedged C++ call holds its queue thread and its context forever,
    //    so both are abandoned whole with the attempt — the next attempt
    //    never waits on the wedged queue and never touches the wedged
    //    context (reusing one would corrupt or hang `whisper_full` again,
    //    and freeing it while `whisper_full` runs would crash).
    //  * A main-queue watchdog settles the attempt with `.timedOut` after
    //    `Config.inferenceTimeoutSeconds`. It lives on the main queue so
    //    it fires even when the attempt's own thread is the one wedged.
    //  * After two consecutive watchdog kills the engine has proven it
    //    wedges on this device/model; further attempts fail fast with
    //    `.timedOut` instead of stacking another wedged (up to ~1.5 GB)
    //    context per utterance. A successful attempt, `releaseModel()`, or
    //    a model change resets the streak.
    //
    // The shared-context caching older builds did is gone: contexts are
    // per-attempt and die with the attempt (the router already dropped the
    // context after every transcript via `releaseModel`, so this costs
    // nothing in the normal flow) and a wedged context can never be
    // handed to a later attempt.
    private let stateLock = NSLock()
    private var attemptSequence = 0
    /// Serial queue owning the *current* attempt (model load + scheduling
    /// of the transcribe Task). Swapped for a fresh queue on every
    /// attempt.
    private var attemptQueue = DispatchQueue(label: "whisper.stt",
                                             qos: .userInitiated)
    /// One record per in-flight attempt. The record is removed — by the
    /// watchdog or by the attempt itself — exactly when the attempt
    /// settles, which is what makes settlement single-shot: a watchdog
    /// that fires after a real settle, or a C++ call that returns after
    /// the watchdog fired, both find no record and are ignored.
    private struct AttemptRecord {
        let watchdog: DispatchWorkItem
        let completion: (Result<String, RecognitionError>) -> Void
        /// strdup'd dialect `initial_prompt` text ([ACCENT-ADAPT], doc
        /// accent-adaptation.md P0.3). whisper.cpp tokenizes it inside
        /// `whisper_full`, so it must outlive the transcribe call: freed
        /// on a clean settle, INTENTIONALLY LEAKED when the watchdog
        /// kills a wedged attempt (a wedged whisper_full may still be
        /// reading it; the leak is bounded at ≤ ~1 KB × 2 wedged
        /// contexts, vs the ~500 MB contexts themselves).
        var promptBuffer: UnsafeMutablePointer<CChar>?
    }
    private var attempts: [Int: AttemptRecord] = [:]
    /// SwiftWhisper context the current attempt is transcribing with —
    /// kept only so `cancel()` can ask SwiftWhisper to abort at the next
    /// encoder pass (see `cancelInFlightTranscription`). Cleared on
    /// settle. Held as `Any?` so this file compiles without the
    /// SwiftWhisper package present.
    private var inFlightWhisper: Any?
    /// Consecutive attempts killed by the watchdog (see throttle above).
    private var consecutiveTimeouts = 0
    private let maxConsecutiveTimeouts = 2
    /// Contexts leaked by watchdog-killed attempts. whisper_free under a
    /// running whisper_full crashes, so a wedged context can never be
    /// freed — each one keeps its ~500 MB resident until the app dies.
    /// Recoveries that keep loading fresh contexts therefore OOM-kill the
    /// app (the "stuck on transcribing, then crashes" loop). Cap new
    /// loads once two contexts have leaked; further attempts fail fast
    /// until relaunch, bounding the damage at ~1 GB.
    private var wedgedContextCount = 0
    private let maxWedgedContexts = 2

    /// Test seam: replaces the whisper.cpp driver (model load + transcribe
    /// + settle) for one attempt. Signature: recognizer, pcm, attemptID.
    /// The override settles the attempt by calling
    /// `settleAttempt(_:with:timedOut:)` — or by doing nothing, which
    /// exercises the watchdog. Never set in production.
    internal var inferenceDriverOverride: ((WhisperSpeechRecognizer,
                                            [Int16], Int) -> Void)?

    /// Per-user decode-biasing terms (contact names, medication names,
    /// app names) — injected by the coordinator, default empty. Called on
    /// the attempt queue once per utterance; the composer caps and
    /// sanitises whatever it returns. PII never leaves the device.
    var biasProfileProvider: (() -> DialectBiasProfile)?

    /// User's STT model choice from the UI picker (nil = automatic).
    /// Set by AppCoordinator and persisted there across launches.
    private var preferredModelID: ModelID?

    let ownsAudioCapture = false

    var isAvailable: Bool {
        // Whisper is available when the model is on disk AND the runtime
        // package is present in the build. The runtime check is a
        // `#if canImport(SwiftWhisper)` in the actual inference path; without
        // it we short-circuit `startListening` with .localeUnsupported.
        guard modelStore.isCached(ModelCatalog.whisperMediumFinetunedNepali) ||
              modelStore.isCached(ModelCatalog.whisperFinetunedNepali) ||
              modelStore.isCached(ModelCatalog.whisperFinetunedNepaliQ8) ||
              modelStore.isCached(ModelCatalog.whisperSmallNepali) ||
              modelStore.isCached(ModelCatalog.whisperLargeV3Nepali) ||
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
    /// utterance (contexts are per-attempt, so there is nothing to evict
    /// here — the next attempt loads whatever model is current). A model
    /// change also resets the consecutive-timeout throttle so the new
    /// model gets a fresh budget of attempts.
    func setPreferredModel(_ id: ModelID?) {
        guard id != preferredModelID else { return }
        preferredModelID = id
        if id != nil {
            stateLock.lock()
            consecutiveTimeouts = 0
            stateLock.unlock()
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
            ModelCatalog.whisperMediumFinetunedNepali,
            ModelCatalog.whisperFinetunedNepali,
            ModelCatalog.whisperSmallMultilingual,
            ModelCatalog.whisperBaseEn
        ]
        return automaticOrder.first { modelStore.isCached($0) }
    }

    /// Frees the loaded Whisper context so LLaMA can have the RAM.
    /// The router calls this once the transcript is in hand: large-v3
    /// (~1.5 GB resident) plus the LLaMA interpreter (~1.4 GB with its
    /// 2048-token compute buffer) together exceed the app's memory
    /// ceiling on 6 GB devices and crash llama.cpp's `output_reserve`.
    ///
    /// Contexts are per-attempt now (see runInference): the context is
    /// released when its attempt settles, which happens before this call
    /// in the routed-success flow, so there is nothing left to free —
    /// kept as an explicit early-drop contract that also resets the
    /// consecutive-timeout throttle (a transcript arriving proves the
    /// engine can complete work again). Runs synchronously under the
    /// state lock; it must NOT touch any serial queue, because a wedged
    /// attempt may have left one blocked forever.
    func releaseModel() {
        stateLock.lock()
        consecutiveTimeouts = 0
        inFlightWhisper = nil
        stateLock.unlock()
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

    // MARK: - Dialect bias seam ([ACCENT-ADAPT], doc accent-adaptation.md P0.3)
    //
    // The whisper.cpp `--prompt` fallback path of the shared
    // `DialectBiasComposer` layer. Everything here is inert while the
    // persisted label is `.default` (unknown/low-confidence dialect ID
    // lands there) — existing STT behaviour is byte-identical in that
    // state. Applied as text: whisper.cpp tokenizes `initial_prompt`
    // itself, so the WhisperKit-only calibrated token ids are reported
    // unavailable rather than silently dropped.

    /// Once-per-session honesty flags (never spammed per utterance).
    private var biasUnavailableReported = false
    private var biasDisabledReported = false

    /// Resolves the current adaptation (label + lexicon + profile terms +
    /// calibrated ids) into a plan. Pure composition decides whether this
    /// decode biases at all.
    private func resolvedDialectBias() -> DialectBiasPlan {
        let profile = biasProfileProvider?() ?? DialectBiasProfile()
        return DialectBiasResolver.resolve(profile: profile)
    }

    /// strdup's the prompt text so whisper.cpp can read it across the
    /// transcribe call. Internal static so the round-trip is unit-testable.
    static func dupPromptCString(_ text: String) -> UnsafeMutablePointer<CChar>? {
        text.withCString { strdup($0) }
    }

    /// [SCRIPT-REGRESSION] Language + prompt decisions for one attempt,
    /// pure and Foundation-only so unit tests pin them without the
    /// SwiftWhisper runtime. `runInference` applies the result to
    /// `WhisperParams` verbatim:
    /// - While a dialect-bias plan is ACTIVE the language is forced to
    ///   "ne" regardless of model — the persisted dialect label means the
    ///   user speaks Nepali, and the decoder must stay in
    ///   Nepali-language mode so the Devanagari-only prompt gate holds.
    ///   This is the whisper.cpp half of the roman-script drift fix: on
    ///   stock multilingual models the old path ran language auto-detect
    ///   next to a roman-biasing `initial_prompt`, which pulled
    ///   transcripts into roman script.
    /// - Inactive states preserve the existing model-based logic
    ///   byte-identically (force "ne" on genuine Nepali fine-tunes only;
    ///   auto-detect elsewhere — forcing "ne" on English/noise is how
    ///   whisper hallucinates Devanagari garbage).
    /// - The prompt text is attached only when it carries at least one
    ///   Devanagari term (defence in depth; the composer already drops
    ///   roman terms).
    struct DecodeAdaptation: Equatable, Sendable {
        let languageCode: String
        let promptText: String?
    }

    static func decodeAdaptation(modelId: ModelID,
                                 config: Config,
                                 plan: DialectBiasPlan) -> DecodeAdaptation {
        let languageCode: String
        if plan.state == .active {
            languageCode = "ne"
        } else {
            let usePrimary = (modelId == ModelCatalog.whisperLargeV3Nepali
                              || modelId == ModelCatalog.whisperMediumFinetunedNepali
                              || modelId == ModelCatalog.whisperFinetunedNepali
                              || modelId == ModelCatalog.whisperSmallNepali)
                && config.forcePrimaryLanguage
            if usePrimary, let lang = config.primaryLanguage {
                languageCode = lang
            } else {
                languageCode = "auto"
            }
        }
        var promptText: String?
        if plan.state == .active,
           let text = plan.promptText, !text.isEmpty,
           DialectBiasComposer.containsDevanagariTerm(text) {
            promptText = text
        }
        return DecodeAdaptation(languageCode: languageCode, promptText: promptText)
    }

    /// Attaches the prompt buffer to the in-flight attempt record (whose
    /// clean settle frees it; watchdog kills leak it deliberately).
    private func attachPromptBuffer(_ buffer: UnsafeMutablePointer<CChar>,
                                    attemptID: Int) {
        stateLock.lock()
        attempts[attemptID]?.promptBuffer = buffer
        stateLock.unlock()
    }

    /// Per-utterance observability for an applied bias (PII-free: counts
    /// and the label only, never term content).
    private func emitBiasActive(_ plan: DialectBiasPlan,
                                tokenCount: Int?,
                                runtime: String) {
        var metadata: [String: String] = [
            "label": plan.label.rawValue,
            "runtime": runtime,
            "text_chars": "\(plan.promptText?.count ?? 0)",
            "lexicon_phrases": "\(plan.lexiconPhraseCount)",
            "contacts": "\(plan.contactCount)",
            "medications": "\(plan.medicationCount)",
            "apps": "\(plan.appCount)",
            "calibrated_tokens": "\(plan.calibratedTokenIds.count)",
        ]
        if let tokenCount {
            metadata["token_count"] = "\(tokenCount)"
        }
        observabilityBus.emit(ObservabilityEvent(
            component: "dialect_id",
            eventType: "dialect_bias_active",
            durationMs: nil,
            outcome: "info",
            errorCode: nil,
            metadata: metadata
        ))
    }

    private func reportBiasUnavailableOnce(reason: String) {
        guard !biasUnavailableReported else { return }
        biasUnavailableReported = true
        observabilityBus.emit(ObservabilityEvent(
            component: "dialect_id",
            eventType: "dialect_bias_unavailable",
            durationMs: nil,
            outcome: "failure",
            errorCode: reason,
            metadata: [:]
        ))
        print("[dialect_id] dialect_bias_unavailable reason=\(reason)")
    }

    private func reportBiasDisabledOnce() {
        guard !biasDisabledReported else { return }
        biasDisabledReported = true
        observabilityBus.emit(ObservabilityEvent(
            component: "dialect_id",
            eventType: "dialect_bias_disabled",
            durationMs: nil,
            outcome: "info",
            errorCode: "disabled_by_user",
            metadata: [:]
        ))
        print("[dialect_id] dialect_bias_disabled reason=disabled_by_user")
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

        // Fresh serial queue per attempt: a whisper.cpp call that wedges
        // holds its queue thread forever, so the queue is abandoned with
        // the attempt and the next attempt starts on a clean queue.
        stateLock.lock()
        attemptSequence += 1
        let attemptID = attemptSequence
        print("[whisper_stt] attempt \(attemptID) start samples=\(audio.count) "
            + "audio_seconds=\(String(format: "%.2f", Double(audio.count) / 16_000.0))")
        attemptQueue = DispatchQueue(label: "whisper.stt.a\(attemptID)",
                                     qos: .userInitiated)
        let queue = attemptQueue
        stateLock.unlock()

        queue.async { [weak self] in
            self?.runInference(audio, attemptID: attemptID) { result in
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
        // Best-effort abort of an in-flight transcribe. SwiftWhisper's
        // cancellation only takes effect at the next encoder pass — it
        // CANNOT interrupt a whisper_full that is already wedged inside
        // the encoder — so the attempt's watchdog stays armed as the real
        // recovery net and its eventual `.timedOut` completion is what
        // unsticks the pipeline.
        cancelInFlightTranscription()
    }

    // MARK: - Inference (guarded)

    /// Runs one inference attempt on the attempt's own serial queue and
    /// settles it exactly once — either when whisper.cpp returns or, if it
    /// wedges, when the main-queue watchdog fires. The completion captured
    /// at `finish()` is delivered on the main queue.
    private func runInference(_ pcm: [Int16],
                              attemptID: Int,
                              completion: @escaping (Result<String, RecognitionError>) -> Void) {
        // Arm the watchdog FIRST — every exit from this method (including
        // the early-failure and throttle paths) must settle the attempt,
        // or the watchdog would fire a second completion later.
        registerAttempt(attemptID, completion: completion)
        print("[whisper_stt] attempt \(attemptID) watchdog armed "
            + "deadline=\(config.inferenceTimeoutSeconds)s")

        #if canImport(SwiftWhisper)
        // Cap leaked contexts BEFORE anything that loads a model: two
        // wedged contexts are already ~1 GB of unfreeable memory — a
        // third load risks the jetsam kill that ended the "stuck on
        // transcribing, then crash" loop. Fail fast until relaunch.
        stateLock.lock()
        let contextCapped = wedgedContextCount >= maxWedgedContexts
        stateLock.unlock()
        if contextCapped {
            emit("inference_context_cap", errorCode: "timed_out")
            print("[whisper_stt] inference_context_cap wedged=\(wedgedContextCount) "
                + "attempt=\(attemptID) — failing fast to avoid OOM")
            settleAttempt(attemptID, with: .failure(.timedOut), timedOut: false)
            return
        }

        // After the FIRST watchdog kill the selected model has proven it
        // can't finish in budget. DOWN-SHIFT to the next cached model in
        // the safe order (small-multilingual → base-en) and retry with it
        // — failing fast only turned the timeout loop into an
        // instant-failure loop ("unstuck but back to where it started").
        // Downshifting immediately also keeps the total at TWO loaded
        // contexts, staying under the wedged-context cap above. A model
        // change or a routed transcript resets the streak.
        stateLock.lock()
        let throttled = consecutiveTimeouts >= 1
        stateLock.unlock()
        if throttled {
            if downshiftModel() {
                stateLock.lock()
                consecutiveTimeouts = 0
                stateLock.unlock()
                emit("inference_downshifted", errorCode: nil)
                print("[whisper_stt] inference_downshifted consecutive=\(consecutiveTimeouts) "
                    + "attempt=\(attemptID) model=\(preferredModelID?.rawValue ?? "nil")")
                // Fall through to the normal path with the new model.
            } else {
                emit("inference_throttled", errorCode: "timed_out")
                print("[whisper_stt] inference_throttled consecutive=\(consecutiveTimeouts) "
                    + "attempt=\(attemptID)")
                settleAttempt(attemptID, with: .failure(.timedOut), timedOut: true)
                return
            }
        }

        // Test seam (unit tests only) — replaces load + transcribe.
        if let override = inferenceDriverOverride {
            override(self, pcm, attemptID)
            return
        }

        // 1. Pick the model. Priority: the user's pick when cached and
        //    RAM-appropriate, else small-multilingual (validated + safe on
        //    all devices), then large-Nepali when RAM allows, then
        //    base-en. Large-v3-Nepali is downranked until the offline
        //    validation in docs/voice-gibberish-transcript-fix-plan.md §4
        //    passes.
        guard let modelId = selectModelId() else {
            emit("model_missing", errorCode: "no_cached_model")
            settleAttempt(attemptID, with: .failure(.localeUnsupported), timedOut: false)
            return
        }
        guard let modelURL = modelStore.path(for: modelId) else {
            emit("model_path_missing", errorCode: "no_path")
            settleAttempt(attemptID, with: .failure(.localeUnsupported), timedOut: false)
            return
        }

        // 2. Sanity-check the file before handing to SwiftWhisper. A bad
        //    download (HTML error page, wrong format) makes SwiftWhisper's
        //    init store a null pointer, and the next inference call
        //    segfaults the app. Catching it here means we fail cleanly
        //    and the caller stays on the SFSpeechRecognizer fallback.
        guard Self.looksLikeGGMLFile(at: modelURL) else {
            emit("model_format_bad", errorCode: "not_ggml")
            settleAttempt(attemptID, with: .failure(.recognitionFailed(
                NSError(domain: "WhisperSTT", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "cached model file is not a valid GGML/GGUF whisper model — delete and re-download"])
            )), timedOut: false)
            return
        }

        // 3. Load a FRESH context for this attempt. No sharing across
        //    attempts: a context whose whisper_full wedged can neither be
        //    reused (a second concurrent call on one context is not
        //    thread-safe) nor freed (whisper_free under a running
        //    whisper_full crashes), so it is abandoned with this attempt
        //    and the next one loads clean. Loading the 328 MB distilled
        //    model takes ~1-4 s — the router already dropped the context
        //    after every transcript via releaseModel(), so per-utterance
        //    loads are the pre-existing steady-state cost.
        //    The shared `.default` params are class-typed and could be
        //    mutated by other consumers, silently clobbering our language
        //    setting — always build a fresh WhisperParams.
        let params = WhisperParams(strategy: .greedy)
        // Language policy (see decodeAdaptation):
        // - ACTIVE bias plan → force "ne" regardless of model
        //   ([SCRIPT-REGRESSION]: keeps the decoder in Nepali-language
        //   mode so the Devanagari-only prompt gate holds — the old
        //   auto-detect + roman prompt path pulled transcripts into
        //   roman script on stock multilingual models).
        // - Otherwise the pre-existing model-based logic: force
        //   `primaryLanguage` on the genuine Nepali fine-tunes
        //   (kiranpantha large-v3 and the distilled small — both
        //   standard tokenizer). The stock small multilingual runs
        //   with auto-detect: forcing "ne" on English/noise is exactly
        //   how Whisper hallucinates Devanagari garbage (gibberish
        //   plan §5.1). TranscriptSanityGuard stays as the downstream
        //   backstop. Toggle via `Config.forcePrimaryLanguage`.
        let biasPlan = resolvedDialectBias()
        let adaptation = Self.decodeAdaptation(modelId: modelId,
                                               config: config,
                                               plan: biasPlan)
        let langCode: String
        if adaptation.languageCode == "auto" {
            params.language = .auto
            langCode = "auto"
        } else if let language = WhisperLanguage(rawValue: adaptation.languageCode) {
            // WhisperParams owns the C string: the setter strdups
            // (vendored WhisperParams.swift) and frees on deinit, and
            // `Whisper` retains `params` for the lifetime of the context
            // — unlike `initial_prompt`, no manual buffer ownership here.
            params.language = language
            langCode = adaptation.languageCode
        } else {
            // Unknown code degrades to auto (same fallback as the old
            // `WhisperLanguage(rawValue:) ?? .auto` path).
            params.language = .auto
            langCode = "auto"
        }
        // Force transcription (not translation-to-English).
        params.translate = false
        params.no_context = true
        params.suppress_blank = true
        // Window the CPU encoder. whisper_full's default (audio_ctx == 0)
        // feeds the WHOLE capture through the encoder as one window, and
        // encode cost grows roughly quadratically with the window — on the
        // CPU-pinned distilled model (1280-wide states, 12 layers) a
        // capture that runs long (VAD tail, noise holding the capture
        // open) can take minutes, and every attempt then dies to the STT
        // watchdog. Splitting at ~6 s bounds the cost of a long capture
        // while sub-6 s utterances stay on the default path (a single
        // window behaves exactly like audio_ctx == 0). ANE encoders are
        // cheap per call and take the full window — chunking there would
        // only add seams + per-call overhead, so leave them defaulted.
        if !usesANEBackend(modelId) {
            params.audio_ctx = Int32(Self.audioContextTokens(sampleCount: pcm.count))
            print("[whisper_stt] attempt \(attemptID) window audio_ctx=\(params.audio_ctx) "
                + "samples=\(pcm.count)")
        }
        // [ACCENT-ADAPT] dialect-tagged prompt (doc accent-adaptation.md
        // P0.3, the whisper.cpp `--prompt` fallback path): whisper.cpp
        // tokenizes `initial_prompt` itself (vendored whisper.cpp:4113)
        // and prepends it even with no_context = true (no_context only
        // clears the accumulated past-text context — whisper.cpp:4109).
        // The C string must outlive whisper_full → owned by the attempt
        // record, freed on clean settle, leaked on watchdog kill (see
        // AttemptRecord.promptBuffer). Text-only path: the calibrated
        // centroid-token ids are WhisperKit-only and are reported as
        // unavailable here rather than silently dropped.
        // [SCRIPT-REGRESSION] the prompt text comes from the gated
        // `adaptation` above: a roman-only prompt never reaches
        // whisper.cpp — it would bias the decoder toward roman-script
        // transcripts.
        if biasPlan.state == .active {
            if let text = adaptation.promptText {
                if let buffer = Self.dupPromptCString(text) {
                    params.initial_prompt = UnsafePointer(buffer)
                    attachPromptBuffer(buffer, attemptID: attemptID)
                    emitBiasActive(biasPlan, tokenCount: nil,
                                   runtime: "whisper_cpp")
                } else {
                    reportBiasUnavailableOnce(reason: "prompt_alloc_failed")
                }
            } else if biasPlan.promptText == nil || biasPlan.promptText!.isEmpty {
                reportBiasUnavailableOnce(reason: "calibrated_ids_only_unsupported")
            } else {
                // Roman-only prompt text: refuse honestly rather than
                // bias toward roman script.
                reportBiasUnavailableOnce(reason: "non_devanagari_prompt")
            }
        } else if biasPlan.state == .disabledByUser {
            reportBiasDisabledOnce()
        }
        let loadStart = CFAbsoluteTimeGetCurrent()
        let whisper = Whisper(fromFileURL: modelURL, withParams: params)
        let loadMs = Int((CFAbsoluteTimeGetCurrent() - loadStart) * 1000)
        // [TURN-TIMING] Model ready — the load ms rides as a point entry
        // when this load happened inside a live turn.
        turnTracer?.mark("asr_loaded", elapsedMs: loadMs)
        // `backend` is the whisper.cpp-side decision on where the encoder
        // runs. whisper.cpp only auto-loads a sibling `-encoder.mlmodelc`
        // for models whose dims exactly match a stock OpenAI arch (see
        // vendored whisper.cpp, whisper_init_state + the standard-dims
        // guard). The distilled small-Nepali student (1280-wide states,
        // 20 audio heads, 16 text heads) is pinned to CPU there; the
        // Swift-side `usesANEBackend` mirrors that guard for this label.
        let ane = usesANEBackend(modelId)
        let backend = ane ? "ane" : "cpu"
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
                "policy": (ane ? "ane" : "cpu_no_encoder"),
                "load_ms": "\(loadMs)"
            ]
        ))
        print("[whisper_stt] model_loaded id=\(modelId.rawValue) "
            + "backend=\(backend) load_ms=\(loadMs)")

        // 4. Int16 [-32768, 32767] → Float32 [-1, 1] as SwiftWhisper expects.
        // [VAD-RT] Pure-Float normalization (was a Double division per
        // sample over the whole utterance).
        let floats: [Float] = pcm.map { Float($0) / 32768 }

        // 5. Transcribe. SwiftWhisper's async API bridges to whisper.cpp
        //    `whisper_full` under the hood and returns segment text on
        //    completion. The Task is deliberately never cancelled on
        //    timeout: withCheckedThrowingContinuation auto-resumes with
        //    CancellationError on task cancellation, and SwiftWhisper
        //    later resumes the same continuation from its completion
        //    handler — a double resume traps. Abandoning the attempt is
        //    the recovery (fresh queue + fresh context next utterance).
        stateLock.lock()
        inFlightWhisper = whisper
        stateLock.unlock()
        Task { [weak self] in
            let audioSeconds = Double(pcm.count) / 16_000.0
            print("[whisper_stt] transcribing attempt=\(attemptID) "
                + "id=\(modelId.rawValue) "
                + "audio_seconds=\(String(format: "%.1f", audioSeconds))")
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let segments = try await whisper.transcribe(audioFrames: floats)
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                let joined = segments.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if joined.isEmpty {
                    self?.emit("empty_transcript", errorCode: "empty")
                    print("[whisper_stt] empty_transcript attempt=\(attemptID) "
                        + "duration_ms=\(ms)")
                    self?.settleAttempt(attemptID, with: .failure(.recognitionFailed(
                        NSError(domain: "WhisperSTT", code: -2,
                                userInfo: [NSLocalizedDescriptionKey: "empty transcript"])
                    )), timedOut: false)
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
                    print("[whisper_stt] transcribed attempt=\(attemptID) duration_ms=\(ms) "
                        + "audio_seconds=\(String(format: "%.1f", audioSeconds)) "
                        + "chars=\(joined.count)")
                    #if DEBUG
                    // Debug-build-only, per explicit request for on-device
                    // WER review — never compiled into Release (B1/T-049:
                    // transcript content is exactly the material NFR-016
                    // forbids in any log sink, and this print bypasses the
                    // sanitised observability bus). Same construct as the
                    // guarded prints in GeminiSpeechRecognizer.
                    print("[whisper_stt] transcript=" + joined)
                    #endif
                    self?.settleAttempt(attemptID, with: .success(joined), timedOut: false)
                }
            } catch {
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                // Map SwiftWhisper's explicit cancellation (cancel() landed
                // at an encoder-pass boundary) to .cancelled; everything
                // else is a recognizer error.
                let mapped: RecognitionError
                if let whisperError = error as? WhisperError {
                    mapped = whisperError == WhisperError.cancelled
                        ? .cancelled
                        : .recognitionFailed(error)
                } else {
                    mapped = .recognitionFailed(error)
                }
                self?.emit("inference_failed", errorCode: "whisper_error")
                // B1/T-049: never print the raw error object (its
                // description can carry a URL, an upstream body or a
                // path). Attempt/duration stay — they are PII-free
                // diagnostics — and the error is reduced to its
                // content-free domain + numeric code.
                let nsError = error as NSError
                print("[whisper_stt] inference_failed attempt=\(attemptID) "
                    + "duration_ms=\(ms) domain=\(nsError.domain) code=\(nsError.code)")
                self?.settleAttempt(attemptID, with: .failure(mapped), timedOut: false)
            }
        }
        #else
        emit("inference_unavailable", errorCode: "runtime_missing")
        settleAttempt(attemptID, with: .failure(.localeUnsupported), timedOut: false)
        #endif
    }

    // MARK: - Attempt bookkeeping + watchdog

    /// Registers the attempt's watchdog and completion. The watchdog runs
    /// on the main queue — never on the attempt's own queue, which is the
    /// thread whisper.cpp may be wedging.
    private func registerAttempt(_ attemptID: Int,
                                 completion: @escaping (Result<String, RecognitionError>) -> Void) {
        let work = DispatchWorkItem { [weak self] in
            self?.handleAttemptTimeout(attemptID)
        }
        stateLock.lock()
        attempts[attemptID] = AttemptRecord(watchdog: work, completion: completion)
        stateLock.unlock()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + config.inferenceTimeoutSeconds, execute: work)
    }

    /// Single-shot settlement. The first caller wins: it removes the
    /// attempt's record — cancelling the watchdog and turning any later
    /// watchdog fire, or any late C++ return, into a no-op — and delivers
    /// the result on the main queue. Returns false when the attempt was
    /// already settled. Internal (not private) so unit tests can settle
    /// an attempt from the `inferenceDriverOverride` seam.
    @discardableResult
    func settleAttempt(_ attemptID: Int,
                               with result: Result<String, RecognitionError>,
                               timedOut: Bool) -> Bool {
        stateLock.lock()
        guard let record = attempts.removeValue(forKey: attemptID) else {
            stateLock.unlock()
            return false
        }
        inFlightWhisper = nil
        if timedOut {
            consecutiveTimeouts += 1
            wedgedContextCount += 1
        } else {
            consecutiveTimeouts = 0
            // Clean settle: whisper_full has returned, the prompt buffer
            // is no longer readable. (Wedged kills intentionally leak it —
            // see AttemptRecord.promptBuffer.)
            if let promptBuffer = record.promptBuffer {
                free(promptBuffer)
            }
        }
        stateLock.unlock()
        record.watchdog.cancel()
        DispatchQueue.main.async { record.completion(result) }
        return true
    }

    /// Watchdog fired: whisper.cpp did not return within the deadline.
    /// A watchdog whose attempt settled in the same instant it fired (a
    /// DispatchWorkItem already dequeued can't be cancelled) finds no
    /// record and is a silent no-op.
    private func handleAttemptTimeout(_ attemptID: Int) {
        stateLock.lock()
        let stillPending = attempts[attemptID] != nil
        stateLock.unlock()
        guard stillPending else { return }
        emit("inference_timeout", errorCode: "timed_out")
        print("[whisper_stt] inference_timeout attempt=\(attemptID) "
            + "deadline=\(Int(config.inferenceTimeoutSeconds))s")
        settleAttempt(attemptID, with: .failure(.timedOut), timedOut: true)
    }

    /// True when whisper.cpp will run this model's encoder on the ANE.
    /// The vendored whisper.cpp auto-loads a sibling `-encoder.mlmodelc`
    /// ONLY for models whose dims exactly match a stock OpenAI arch (see
    /// whisper.cpp `whisper_init_state`); the distilled small-Nepali
    /// student has non-standard dims (1280-wide states, 20 audio heads,
    /// 16 text heads) and is pinned to CPU. This Swift-side mirror drives
    /// the observability label and unit tests — the C++ dims guard is the
    /// enforcement.
    /// Whether the ANE (CoreML) encoder is staged for this model. The
    /// distilled model is no longer pinned to CPU here — device evidence
    /// showed it transcribing fine before the pin, and whisper.cpp now
    /// loads whatever sibling encoder exists with CPU fallback.
    func usesANEBackend(_ modelId: ModelID) -> Bool {
        modelStore.isCoreMLCached(modelId)
    }

    /// Best-effort abort of the in-flight SwiftWhisper transcribe.
    /// SwiftWhisper's cancel() only stops `whisper_full` at the NEXT
    /// encoder pass (its `encoder_begin_callback`); it cannot interrupt a
    /// `whisper_full` already wedged inside the encoder, so this is purely
    /// an accelerator for the not-yet-wedged case — the watchdog is the
    /// guarantee.
    private func cancelInFlightTranscription() {
        #if canImport(SwiftWhisper)
        stateLock.lock()
        let candidate = inFlightWhisper as? Whisper
        stateLock.unlock()
        guard let candidate else { return }
        try? candidate.cancel {}
        #endif
    }

    /// Recovery downshift: the selected model timed out twice in a row —
    /// switch to the next cached model in the safe order so the loop
    /// becomes "slower but working" instead of fail-fast forever.
    /// Returns false when no alternative is cached.
    private func downshiftModel() -> Bool {
        let fallbacks: [ModelID] = [
            ModelCatalog.whisperSmallMultilingual,
            ModelCatalog.whisperBaseEn
        ]
        for id in fallbacks where id != preferredModelID && modelStore.isCached(id) {
            preferredModelID = id
            return true
        }
        return false
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
        if modelStore.isCached(ModelCatalog.whisperMediumFinetunedNepali) {
            return ModelCatalog.whisperMediumFinetunedNepali
        }
        if modelStore.isCached(ModelCatalog.whisperFinetunedNepali) {
            return ModelCatalog.whisperFinetunedNepali
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

    /// Maps a captured sample count onto whisper's `audio_ctx` window cap
    /// (encoder tokens — 1 token per 320 samples at 16 kHz, i.e. 20 ms).
    /// The floor (8 tokens) keeps tiny/noise captures on a sane window and
    /// the 300-token cap (~6 s) is the CPU-encode budget ceiling described
    /// at the call site. whisper_full rejects audio_ctx > n_audio_ctx
    /// (1500) with an error, so the cap is well inside the limit.
    static func audioContextTokens(sampleCount: Int) -> Int {
        guard sampleCount > 0 else { return 8 }
        let tokens = (sampleCount + 319) / 320
        return min(max(tokens, 8), 300)
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
