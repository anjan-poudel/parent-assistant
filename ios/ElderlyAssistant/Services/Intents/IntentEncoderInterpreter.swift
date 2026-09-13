import Foundation

/// [T-037-a] Raw output of one encoder graph evaluation.
///
/// Kept as plain logits (not probabilities, not decisions) so the decode
/// rule is a pure function that the test suite can drive with hand-built
/// numbers — no CoreML, no model file, no flakiness.
struct IntentEncoderLogits: Equatable {
    /// One score per `IntentEncoderManifest.intents` entry, in order.
    let intentLogits: [Float]
    /// One score row per token position; each row has one score per
    /// `IntentEncoderManifest.tags` entry, in order.
    let slotLogits: [[Float]]
}

/// Why the encoder could not produce a valid, in-schema command. These are
/// ABSTENTION reasons — the router's fail-soft ladder handles a nil result
/// exactly as it does for any other local brain. Machine-readable strings
/// only; they travel as event `errorCode` values and never contain user
/// content (C9 / NFR-016).
enum IntentEncoderAbstention: String, Equatable {
    /// Sanitisation produced an empty transcript — nothing to infer on.
    case emptyAfterSanitise = "empty_after_sanitise"
    /// The tokenizer cannot serve this input (vocabulary absent).
    case tokenizerUnavailable = "tokenizer_unavailable"
    /// The tokenizer's words do not line up with the sanitised text, so
    /// character offsets cannot be trusted.
    case wordAlignmentMismatch = "word_alignment_mismatch"
    /// Decoded intent id is not one of the 12 schema-v2 actions.
    case unknownIntent = "unknown_action"
    /// Decoded BIO tag names a slot type outside the schema-v2 set.
    case unknownSlotType = "unknown_slot_type"
    /// A span's character offsets do not exist in the sanitised transcript.
    case spanOffsetInvalid = "span_offset_invalid"
    /// Max softmax below the configured confidence threshold.
    case lowConfidence = "low_confidence"
}

/// A validated, verbatim slot occurrence.
///
/// `text` is always `sanitisedTranscript[start..<end]` — sliced from the
/// sanitised text, never reconstructed from token pieces, so what reaches
/// `NepaliTimeParser` / `ContactResolver` / the reminder-title path is
/// exactly what the user said (T-035 §8: "spans in, resolution in code").
///
/// OFFSET UNIT: Unicode scalars, base 0, end exclusive — the contract's
/// `slots.offsets.unit` / `base` / `end`. Word boundaries are whitespace,
/// which is never inside a grapheme cluster, so a span can never split a
/// Devanagari cluster even though the unit is the scalar.
struct IntentEncoderSpan: Equatable {
    let type: IntentEncoderSlotType
    /// Unicode-scalar offsets into the SANITISED transcript
    /// (`InputSanitiser.sanitise(_, level: .quarantine)` output), the
    /// contract's `offset_space`.
    let start: Int
    let end: Int
    /// `text == sanitisedTranscript[start..<end]`, always.
    let text: String
}

/// The pure decode outcome: either a schema-valid command (before the
/// confidence threshold is applied) or an abstention with its reason.
enum IntentEncoderDecodeOutcome: Equatable {
    case command(action: InterpretedCommand.Action,
                 confidence: Double,
                 slots: [IntentEncoderSlotType: IntentEncoderSpan])
    case abstain(IntentEncoderAbstention)
}

/// Runs the intent encoder graph. Implemented by `CoreMLIntentEncoderModel`
/// in production; tests inject stubs, so the interpreter's timeout,
/// sanitisation, decode and abstention paths are all testable without
/// CoreML or a 118 MB artifact.
protocol IntentEncoderModelRunning: AnyObject {
    var isLoaded: Bool { get }
    /// Loads weights. Throws an explicit, content-free error on failure.
    func load() throws
    /// Releases weights (memory pressure).
    func unload()
    /// Runs one prediction. `tokenIds`/`attentionMask` are shape `[1, n]`.
    func predict(tokenIds: [Int32],
                 attentionMask: [Int32]) throws -> IntentEncoderLogits
}

/// Errors a model runner may throw. Reasons are short machine strings —
/// never file paths, weights contents or user data.
enum IntentEncoderModelError: Error, Equatable {
    case coreMLUnavailable
    case loadFailed(String)
    case predictionFailed(String)
    case unexpectedOutput(String)
}

/// `CommandInterpreter` implementation backed by the on-device CoreML
/// intent encoder (T-036 artifact delivered through `ModelStore`).
///
/// ## Where it sits
///
/// Installed ONLY as `LocalBrainChain`'s `preferred` slot (behind a feature
/// gate, see `IntentEncoderFeature`); the LLaMA interpreter stays the
/// `standIn`. `IntentRouter`, `CommandRouter`, the keyword safety net,
/// `TranscriptSanityGuard`, `IntentCommandCache` and the confirmation flow
/// are untouched — and the keyword net (emergency, explicit med-ack) runs
/// upstream of the interpreter, so no encoder output can intercept or
/// suppress those paths.
///
/// ## Strictness (defense in depth replaces grammar enforcement)
///
/// The T-033 spike artifact was fine-tuned on a legacy LLM-format dataset
/// snapshot (not T-034 schema-v2 BIO data), so its outputs are validated
/// strictly: action ∈ schema-v2 enum, slot type ∈ schema-v2 set, span
/// offsets inside the SANITISED transcript, and the span text is sliced
/// verbatim from it. Any violation abstains (nil) — the runtime never
/// fabricates a slot. See `IntentEncoderSchema` and `IntentEncoderDecoder`.
///
/// ## Honest limits of this phase
///
///  - No Swift tokenizer for the XLM-R 250k vocabulary exists yet, so the
///    production instance is constructed with
///    `UnavailableIntentEncoderTokenizer` and `isAvailable` is false:
///    the app behaves exactly as it did before this class existed.
///  - The encoder produces no spoken reply (`reply` is empty). `.query` /
///    `.none` therefore route through `CommandRouter.deliverModelReply`,
///    whose existing `ReplySanityGate` speaks the honest "didn't catch
///    that" fallback rather than silence. Answer generation is the LLM
///    brain's job, not the classifier's.
final class IntentEncoderInterpreter: CommandInterpreter, InterpreterFailureReporting {

    /// Every value is a parameter, not a constant buried in the
    /// implementation — mirrors `LocalIntentInterpreter.Config` and the
    /// pinned `runtime.config` block of T-035's `encoder_contract.yaml`
    /// (`confidenceThreshold: 0.4`, `maxSequenceLength: 64`,
    /// `timeoutSeconds: 2.0`, `maxRetries: 0`,
    /// `retryOnArtifactLoadRace: true`).
    struct Config {
        /// Local brains are constructed at the router's REPHRASE floor
        /// (0.4) so the band policy stays in `IntentRouter`.
        let confidenceThreshold: Double
        /// Inference timeout (constitution: configurable, never hardcoded).
        /// 2 s is the encoder stage's p95 budget from the T-037 acceptance
        /// criteria — on expiry the interpreter reports
        /// "inference_timeout" and returns nil so the router's existing
        /// escalation path runs unchanged.
        ///
        /// FORWARD-PASS budget only: the graph load is resolved BEFORE
        /// this clock is armed (contract F-1 detects
        /// `forward_pass_exceeds_local_leg_budget`), so a slow successful
        /// load can never be reported as an inference timeout.
        let timeoutSeconds: Double
        /// Exactly ONE extra attempt when loading the graph failed, for
        /// the artifact-install race (contract `retryOnArtifactLoadRace`).
        ///
        /// There is deliberately NO retry on timeout or abstention:
        /// `LocalIntentInterpreter` retries once because its trigger is
        /// `truncated_json`, a sampling failure a retry can plausibly fix.
        /// The encoder does not sample — a timeout re-runs identical work
        /// for the same expected duration inside NFR-002's budget, and a
        /// decode verdict is not transient. The load race is the one
        /// genuine transient.
        var retryOnArtifactLoadRace: Bool = true

        static let `default` = Config(confidenceThreshold: 0.4,
                                      timeoutSeconds: 2.0)
    }

    private let modelStore: ModelStore
    private let observabilityBus: ObservabilityBus
    private let modelId: ModelID
    private let manifest: IntentEncoderManifest
    private let config: Config
    private let tokenizer: IntentEncoderTokenizing
    private let modelRunnerFactory: (URL) throws -> IntentEncoderModelRunning

    private let inferenceQueue = DispatchQueue(label: "intent.encoder",
                                               qos: .userInitiated)
    private let timeoutQueue = DispatchQueue(label: "intent.encoder.timeout")

    private let stateLock = NSLock()
    private var loadedRunner: IntentEncoderModelRunning?
    /// Set by `handleMemoryPressure()`; cleared by the next `interpret()`.
    private var unloadedForMemoryPressure = false

    /// [LAT-EVIDENCE] The honest reason the LAST attempt failed —
    /// "inference_timeout", "model_load_failed", "inference_failed" or
    /// "tokenizer_unavailable" — cleared at the start of each interpret.
    /// `IntentRouter` reads it after a nil result. Abstentions leave it nil
    /// (an abstention is not a failure).
    private(set) var lastInferenceFailureReason: String?

    init(modelStore: ModelStore,
         observabilityBus: ObservabilityBus,
         modelId: ModelID = ModelCatalog.intentEncoderSpike,
         manifest: IntentEncoderManifest = .t033Spike,
         tokenizer: IntentEncoderTokenizing = UnavailableIntentEncoderTokenizer(),
         config: Config = .default,
         modelRunnerFactory: @escaping (URL) throws -> IntentEncoderModelRunning
             = IntentEncoderInterpreter.defaultModelRunnerFactory) {
        self.modelStore = modelStore
        self.observabilityBus = observabilityBus
        self.modelId = modelId
        self.manifest = manifest
        self.tokenizer = tokenizer
        self.config = config
        self.modelRunnerFactory = modelRunnerFactory
    }

    /// Production runner — the CoreML mlprogram loaded from the ModelStore
    /// directory. Throws explicitly where CoreML is not linked.
    static func defaultModelRunnerFactory(url: URL) throws -> IntentEncoderModelRunning {
        #if canImport(CoreML)
        return CoreMLIntentEncoderModel(contentsOf: url)
        #else
        _ = url
        throw IntentEncoderModelError.coreMLUnavailable
        #endif
    }

    // MARK: - Availability

    /// The mlmodelc directory installed by `ModelStore.installCoreMLEncoder`.
    var installedModelDirectory: URL? {
        guard modelStore.isCoreMLCached(modelId) else { return nil }
        return modelStore.coreMLBundleFinalURL(for: modelId)
    }

    /// The label-set identity of the manifest this instance was built with
    /// — fixed vocabulary (model id / version only), used by the wiring
    /// event in `AppCoordinator`. Never user content.
    var manifestIdentity: (id: String, version: String) {
        (manifest.id, manifest.version)
    }

    /// True only when the artifact is installed, a tokenizer can actually
    /// encode, and the model has not been released for memory pressure.
    /// False is normal: the chain falls through to the LLaMA stand-in, and
    /// the app behaves exactly as it did before the encoder existed.
    var isAvailable: Bool {
        stateLock.lock()
        let unloaded = unloadedForMemoryPressure
        stateLock.unlock()
        guard !unloaded else { return false }
        return installedModelDirectory != nil && tokenizer.isReady
    }

    // MARK: - CommandInterpreter

    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        // A fresh attempt starts clean — the reason belongs to the last one.
        lastInferenceFailureReason = nil
        // Every abstention/failure event carries the attempt's duration
        // (uniform stage-latency signal, C9-safe: a number, nothing else).
        let started = Date()

        stateLock.lock()
        let wasUnloaded = unloadedForMemoryPressure
        if wasUnloaded { unloadedForMemoryPressure = false }
        stateLock.unlock()

        // Artifact + vocabulary must both be present. The tokenizer check
        // is deliberately first-class: without it the encoder cannot run at
        // all, and reporting that honestly is better than failing per-turn.
        guard installedModelDirectory != nil else {
            emit("encoder_unavailable", outcome: "info", errorCode: "model_not_cached")
            DispatchQueue.main.async { completion(nil) }
            return
        }
        guard tokenizer.isReady else {
            emit("encoder_unavailable", outcome: "info",
                 errorCode: IntentEncoderAbstention.tokenizerUnavailable.rawValue)
            lastInferenceFailureReason = IntentEncoderAbstention.tokenizerUnavailable.rawValue
            DispatchQueue.main.async { completion(nil) }
            return
        }

        // Sanitise BEFORE any token reaches the encoder (NFR-013 / spec
        // §5.2 — `quarantine` level, same as every other interpreter).
        let clean = InputSanitiser.sanitise(transcript, level: .quarantine)
        guard !clean.isEmpty else {
            emit("encoder_abstained", outcome: "info",
                 durationMs: Self.elapsedMs(since: started),
                 errorCode: IntentEncoderAbstention.emptyAfterSanitise.rawValue)
            DispatchQueue.main.async { completion(nil) }
            return
        }
        guard let tokenization = tokenizer.tokenize(
                sanitisedTranscript: clean,
                maxSequenceLength: manifest.maxSequenceLength) else {
            emit("encoder_unavailable", outcome: "info",
                 errorCode: IntentEncoderAbstention.tokenizerUnavailable.rawValue)
            lastInferenceFailureReason = IntentEncoderAbstention.tokenizerUnavailable.rawValue
            DispatchQueue.main.async { completion(nil) }
            return
        }

        // One-shot guard shared by BOTH timed phases below: whichever
        // finishes first completes the turn, the later one is a no-op.
        let attempt = AttemptToken()

        inferenceQueue.async { [weak self] in
            guard let self else { return }
            let manifest = self.manifest

            // PHASE 1 — graph load, OUTSIDE the timed section.
            //
            // `config.timeoutSeconds` is the FORWARD-PASS budget (T-035
            // contract F-1 detects `forward_pass_exceeds_local_leg_budget`,
            // and `inference_timeout` is reserved for it). Loading the
            // ~118 MB graph is I/O-bound and happens on the first use after
            // launch and after every memory-pressure unload; charging it to
            // the inference budget discarded a successful load and reported
            // a spurious `inference_timeout`. Load failures keep their own
            // machine reasons (`model_load_failed_*`).
            let runner: IntentEncoderModelRunning
            do {
                runner = try self.runnerForPrediction(wasUnloaded: wasUnloaded)
            } catch let error as IntentEncoderModelError {
                attempt.finish {
                    self.fail(Self.reason(for: error), started: started,
                              completion: completion)
                }
                return
            } catch {
                attempt.finish {
                    self.fail("inference_failed", started: started,
                              completion: completion)
                }
                return
            }

            // PHASE 2 — the forward pass, bounded by the inference budget.
            // The timer is armed HERE, after the load, so it covers only
            // the prediction. Timeout is enforced on the CALLER side
            // (CoreML prediction cannot be cancelled mid-flight): if the
            // bound expires first the turn completes as a failure and the
            // late result is discarded.
            self.timeoutQueue.asyncAfter(
                deadline: .now() + self.config.timeoutSeconds) { [weak self] in
                guard let self else { return }
                attempt.finish {
                    self.lastInferenceFailureReason = "inference_timeout"
                    self.emit("encoder_inference_timeout", outcome: "failure",
                              durationMs: Self.elapsedMs(since: started),
                              errorCode: "inference_timeout")
                    DispatchQueue.main.async { completion(nil) }
                }
            }

            do {
                let logits = try runner.predict(tokenIds: tokenization.tokenIds,
                                                attentionMask: tokenization.attentionMask)
                let outcome = IntentEncoderDecoder.decode(
                    logits: logits,
                    manifest: manifest,
                    tokenization: tokenization,
                    sanitisedTranscript: clean)
                attempt.finish {
                    self.settle(outcome, started: started,
                                completion: completion)
                }
            } catch let error as IntentEncoderModelError {
                attempt.finish {
                    self.fail(Self.reason(for: error), started: started,
                              completion: completion)
                }
            } catch {
                attempt.finish {
                    self.fail("inference_failed", started: started,
                              completion: completion)
                }
            }
        }
    }

    // MARK: - Model lifecycle

    /// (Re)creates and loads the runner from the ModelStore path. Called on
    /// the inference queue, so loading a CoreML model never blocks the main
    /// thread — including the reload after a memory-pressure unload, which
    /// is exactly why the reload lives here.
    private func runnerForPrediction(wasUnloaded: Bool) throws -> IntentEncoderModelRunning {
        stateLock.lock()
        let existing = loadedRunner
        stateLock.unlock()
        if let existing, existing.isLoaded { return existing }
        guard let url = installedModelDirectory else {
            throw IntentEncoderModelError.loadFailed("model_not_cached")
        }
        // Contract `runtime.config.retryOnArtifactLoadRace`: one extra
        // attempt only for a LOAD failure (a graph being written by an
        // in-flight install). A missing artifact is not a race.
        let maxAttempts = config.retryOnArtifactLoadRace ? 2 : 1
        var lastError = IntentEncoderModelError.loadFailed("coreml_load")
        for attempt in 1...maxAttempts {
            // A fresh runner object after an unload proves the reload came
            // back through the ModelStore path rather than a cached handle.
            do {
                let runner = try modelRunnerFactory(url)
                try runner.load()
                stateLock.lock()
                loadedRunner = runner
                stateLock.unlock()
                emit("encoder_model_loaded", outcome: "success",
                     extra: ["state": wasUnloaded
                             ? "reloaded_after_memory_pressure" : "loaded"])
                return runner
            } catch let error as IntentEncoderModelError {
                lastError = error
                if case .loadFailed(let detail) = error, detail == "model_not_cached" {
                    break
                }
                if attempt < maxAttempts {
                    emit("encoder_load_retry", outcome: "info",
                         errorCode: Self.reason(for: error),
                         extra: ["state": "artifact_load_race"])
                }
            } catch {
                lastError = .loadFailed("coreml_load")
                break
            }
        }
        throw lastError
    }

    /// UIKit memory warning (level 2 maps to `didReceiveMemoryWarning`):
    /// release the weights and report unavailable until the next use.
    /// The next `interpret()` reloads from ModelStore — no crash, no stale
    /// handle.
    func handleMemoryPressure() {
        stateLock.lock()
        unloadedForMemoryPressure = true
        let runner = loadedRunner
        loadedRunner = nil
        stateLock.unlock()
        runner?.unload()
        emit("encoder_model_unloaded", outcome: "info",
             errorCode: nil, extra: ["reason": "memory_pressure"])
    }

    /// The other half of the memory-pressure contract: the coordinator
    /// calls this at the start of the next voice turn, clearing the hold
    /// so `isAvailable` is honest again and the first `interpret()` reloads
    /// the weights from ModelStore. `interpret()` also clears the hold
    /// itself, so a direct caller cannot be wedged by a stale flag.
    func rearmAfterMemoryPressure() {
        stateLock.lock()
        let wasUnloaded = unloadedForMemoryPressure
        unloadedForMemoryPressure = false
        stateLock.unlock()
        if wasUnloaded {
            emit("encoder_rearmed", outcome: "info",
                 errorCode: nil, extra: ["state": "awaiting_next_use"])
        }
    }

    /// Test/observability seam: whether weights are currently resident.
    var isModelLoaded: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return loadedRunner?.isLoaded ?? false
    }

    // MARK: - Settling an attempt

    private func settle(_ outcome: IntentEncoderDecodeOutcome,
                        started: Date,
                        completion: @escaping (InterpretedCommand?) -> Void) {
        let durationMs = Self.elapsedMs(since: started)
        switch outcome {
        case .abstain(let reason):
            emit("encoder_abstained", outcome: "info",
                 durationMs: durationMs, errorCode: reason.rawValue)
            DispatchQueue.main.async { completion(nil) }
        case .command(let action, let confidence, let slots):
            guard confidence >= config.confidenceThreshold else {
                emit("encoder_abstained", outcome: "info",
                     durationMs: durationMs,
                     errorCode: IntentEncoderAbstention.lowConfidence.rawValue)
                DispatchQueue.main.async { completion(nil) }
                return
            }
            emit("encoder_inference_done", outcome: "success",
                 durationMs: durationMs)
            let command = Self.command(action: action, confidence: confidence,
                                       slots: slots)
            DispatchQueue.main.async { completion(command) }
        }
    }

    private func fail(_ reason: String,
                      started: Date,
                      completion: @escaping (InterpretedCommand?) -> Void) {
        lastInferenceFailureReason = reason
        emit("encoder_inference_failed", outcome: "failure",
             durationMs: Self.elapsedMs(since: started), errorCode: reason)
        DispatchQueue.main.async { completion(nil) }
    }

    private static func reason(for error: IntentEncoderModelError) -> String {
        switch error {
        case .coreMLUnavailable: return "coreml_unavailable"
        case .loadFailed(let detail): return "model_load_failed_\(detail)"
        case .predictionFailed(let detail): return "inference_failed_\(detail)"
        case .unexpectedOutput(let detail): return "output_shape_mismatch_\(detail)"
        }
    }

    /// Maps a schema-validated decode onto the shipped command model.
    /// `reply` is empty by design (see the class docs): a classifier has
    /// nothing to say, and pretending otherwise would be fabricated speech.
    ///
    /// Only slot types the schema can actually carry are mapped, and every
    /// value is the VERBATIM span surface (T-035 §8: spans in, resolution
    /// in code).
    ///
    /// DEFERRED (T-035 integration item I-1): §7.1 splits the `app` span
    /// into a closed-vocabulary `requestedApp` token (`whatsapp`/`facetime`
    /// /…) plus a derived `callType` (`voice`/`video`), and T-035 §7.2
    /// clitic-trims `contact` (`छोरालाई` → `छोरा`). Neither projection is
    /// implemented here: the spike artifact's tag head is `contact`/`time`
    /// only, so no `app` span can occur, and T-035 deliberately picks
    /// neither resolution for the `callType == "voice"` / `requestedApp ==
    /// nil` ambiguity. Until I-1 lands, `.app` maps verbatim to
    /// `requestedApp` and `callType` stays nil.
    static func command(action: InterpretedCommand.Action,
                        confidence: Double,
                        slots: [IntentEncoderSlotType: IntentEncoderSpan]) -> InterpretedCommand {
        InterpretedCommand(
            action: action,
            entryId: nil,
            contact: slots[.contact]?.text,
            time: slots[.time]?.text,
            medication: slots[.medication]?.text,
            message: slots[.message]?.text,
            callType: nil,
            requestedApp: slots[.app]?.text,
            topic: slots[.topic]?.text,
            steps: nil,
            pluginAction: nil,
            pluginEntities: nil,
            confidence: max(0.0, min(1.0, confidence)),
            reply: ""
        )
    }

    // MARK: - Observability (model id/version + duration + outcome only — C9)

    private func emit(_ eventType: String,
                      outcome: String,
                      durationMs: Int? = nil,
                      errorCode: String? = nil,
                      extra: [String: String] = [:]) {
        var metadata: [String: String] = [
            // The catalog artifact id (what ModelStore installs/verifies)…
            "model_id": modelId.rawValue,
            // …and the LABEL-SET identity that decides whether a decode is
            // trustworthy. Both are fixed vocabulary, never user content.
            "manifest_id": manifest.id,
            "model_version": manifest.version
        ]
        // Fixed-vocabulary extras only (e.g. "state", "reason"); never
        // transcript, span, contact or message content.
        for (key, value) in extra { metadata[key] = value }
        observabilityBus.emit(ObservabilityEvent(
            component: "intent_encoder",
            eventType: eventType,
            durationMs: durationMs,
            outcome: outcome,
            errorCode: errorCode,
            metadata: metadata
        ))
    }

    private static func elapsedMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }
}

/// One-shot completion guard shared by the prediction path and the timeout
/// timer — whichever finishes first wins, the other is a no-op.
private final class AttemptToken {
    private let lock = NSLock()
    private var finished = false

    func finish(_ body: () -> Void) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        body()
    }
}

/// The pure decode + validation rule (defense in depth replaces the GBNF
/// grammar the LLM path uses).
///
/// Mirrors `tools/train-intent/src/bakeoff_encoder.py`'s inference path:
///   - softmax over intent logits → max probability + argmax label;
///   - per-token slot argmax, then the FIRST token of each word decides the
///     word's tag (`word_ids` alignment — the rule training used);
///   - contiguous runs of one slot type become one span.
///
/// Then applies the runtime's own guarantees on top:
///   - every decoded intent must be a schema-v2 action;
///   - every decoded tag must be `O` or a schema-v2 slot type;
///   - every span must be a verbatim, in-range slice of the SANITISED
///     transcript;
///   - the tokenizer's words must line up with that transcript exactly.
/// Any violation → abstain.
enum IntentEncoderDecoder {

    static func decode(logits: IntentEncoderLogits,
                       manifest: IntentEncoderManifest,
                       tokenization: IntentEncoderTokenization,
                       sanitisedTranscript: String) -> IntentEncoderDecodeOutcome {
        // 1. Intent. Softmax is computed in Double to match the Python
        //    harness closely enough for the band policy. The manifest's
        //    `calibrationTemperature` (contract `calibration_temperature`,
        //    `applied_in: interpreter_code`) divides the logits first, so
        //    the confidence the band policy compares against 0.4/0.7 is
        //    the calibrated one; 1.0 is the identity.
        guard let best = argmaxSoftmax(logits.intentLogits,
                                       temperature: manifest.calibrationTemperature),
              let intentRaw = manifest.intent(at: best.index) else {
            return .abstain(.unknownIntent)
        }
        guard let action = IntentEncoderSchema.action(forRawValue: intentRaw) else {
            return .abstain(.unknownIntent)
        }
        let confidence = max(0.0, min(1.0, best.probability))

        // 2. Word-level BIO tags: first token of each word wins.
        guard let wordTags = wordLevelTagIndices(
                tokenization: tokenization,
                slotLogits: logits.slotLogits) else {
            return .abstain(.wordAlignmentMismatch)
        }

        // 3. Spans from contiguous runs of one slot type.
        //    Offsets are UNICODE SCALAR units (contract
        //    `slots.offsets.unit: unicode_scalar`, base 0, end exclusive)
        //    and the surface is a slice of the sanitised transcript, so
        //    the invariant `transcript[start:end] == text` holds by
        //    construction (contract `slots.offsets.invariant`).
        let wordOffsets = wordScalarOffsets(sanitisedTranscript)
        let textWords = wordOffsets.compactMap {
            scalarSlice(sanitisedTranscript, start: $0.start, end: $0.end)
        }
        guard textWords.count == wordOffsets.count else {
            return .abstain(.wordAlignmentMismatch)
        }
        // The tokenizer's word segmentation must be the one the offsets
        // were computed from — otherwise a span could name different text
        // than the model saw.
        guard textWords == tokenization.words else {
            return .abstain(.wordAlignmentMismatch)
        }

        var spans: [IntentEncoderSlotType: IntentEncoderSpan] = [:]
        var currentType: IntentEncoderSlotType?
        var runStartWord = 0
        var index = 0
        while index <= wordTags.count {
            let type: IntentEncoderSlotType?
            if index < wordTags.count {
                switch manifest.decode(tagIndex: wordTags[index]) {
                case .outside:
                    type = nil
                case .slot(let decoded):
                    type = decoded
                case .unknown:
                    // A tag the runtime has no schema-v2 contract for — the
                    // whole output abstains rather than dropping it silently.
                    return .abstain(.unknownSlotType)
                }
            } else {
                type = nil   // flush the trailing run
            }

            if type != currentType {
                if let closing = currentType {
                    let firstWord = runStartWord
                    let lastWord = index - 1
                    guard firstWord <= lastWord,
                          lastWord < wordOffsets.count else {
                        return .abstain(.spanOffsetInvalid)
                    }
                    let start = wordOffsets[firstWord].start
                    let end = wordOffsets[lastWord].end
                    guard let verbatim = scalarSlice(sanitisedTranscript,
                                                     start: start, end: end) else {
                        return .abstain(.spanOffsetInvalid)
                    }
                    // Defense in depth: the slice must equal the joined
                    // words the model tagged. (They are equal by
                    // construction; the check pins that invariant.)
                    let joined = tokenization.words[firstWord...lastWord]
                        .joined(separator: " ")
                    guard verbatim == joined else {
                        return .abstain(.spanOffsetInvalid)
                    }
                    // First run of a given type wins when the model tags the
                    // same slot type twice (documented decode rule; the
                    // command model carries one field per slot type).
                    if spans[closing] == nil {
                        spans[closing] = IntentEncoderSpan(type: closing,
                                                           start: start,
                                                           end: end,
                                                           text: verbatim)
                    }
                }
                currentType = type
                runStartWord = index
            }
            index += 1
        }

        return .command(action: action, confidence: confidence, slots: spans)
    }

    /// First-token-of-word tag ids, mirroring the Python decode rule.
    /// Nil when the alignment arrays are inconsistent (defensive: a
    /// tokenizer bug must abstain, not misalign spans).
    private static func wordLevelTagIndices(
        tokenization: IntentEncoderTokenization,
        slotLogits: [[Float]]) -> [Int]? {
        guard tokenization.tokenIds.count == tokenization.wordIndices.count,
              tokenization.tokenIds.count == slotLogits.count else { return nil }
        let wordCount = (tokenization.wordIndices.compactMap { $0 }.max() ?? -1) + 1
        guard wordCount == tokenization.words.count else { return nil }

        var firstTokenForWord = [Int?](repeating: nil, count: wordCount)
        for (position, wordIndex) in tokenization.wordIndices.enumerated() {
            guard let wordIndex else { continue }
            guard wordIndex >= 0, wordIndex < wordCount else { return nil }
            if firstTokenForWord[wordIndex] == nil {
                firstTokenForWord[wordIndex] = position
            }
        }
        var tags = [Int](repeating: 0, count: wordCount)
        for (word, position) in firstTokenForWord.enumerated() {
            guard let position else {
                // A word with no token cannot carry a validated span. The
                // caller abstains via the alignment check above; report
                // "outside" here only if the word count matched.
                return nil
            }
            guard position < slotLogits.count,
                  let best = argmax(slotLogits[position]) else { return nil }
            tags[word] = best
        }
        return tags
    }

    /// Unicode-scalar offsets of whitespace words, in order (contract
    /// `slots.offsets.unit: unicode_scalar`). Boundaries always sit on
    /// whitespace, which is never inside a grapheme cluster, so a word
    /// range can never cut a Devanagari cluster in half.
    static func wordScalarOffsets(_ text: String) -> [(start: Int, end: Int)] {
        let scalars = Array(text.unicodeScalars)
        var offsets: [(Int, Int)] = []
        var i = 0
        while i < scalars.count {
            while i < scalars.count,
                  CharacterSet.whitespacesAndNewlines.contains(scalars[i]) { i += 1 }
            let start = i
            while i < scalars.count,
                  !CharacterSet.whitespacesAndNewlines.contains(scalars[i]) { i += 1 }
            if i > start { offsets.append((start, i)) }
        }
        return offsets
    }

    /// The sanitised transcript's `[start, end)` scalar range as a String,
    /// or nil when the range does not exist. This is the ONLY way a span
    /// surface is produced — never a re-join of token pieces.
    static func scalarSlice(_ text: String, start: Int, end: Int) -> String? {
        guard start >= 0, start < end else { return nil }
        let scalars = text.unicodeScalars
        guard end <= scalars.count else { return nil }
        let lower = scalars.index(scalars.startIndex, offsetBy: start)
        let upper = scalars.index(lower, offsetBy: end - start)
        return String(scalars[lower..<upper])
    }

    // MARK: - Numeric helpers (pure, testable)

    /// Temperature-scaled softmax: the logits are DIVIDED by `temperature`
    /// before the max-subtraction and exponentiation (contract
    /// `calibration_temperature`). 1.0 is the identity. Any positive
    /// temperature leaves the argmax unchanged (the scaling is monotone)
    /// and only reshapes the probability; a non-finite or non-positive
    /// temperature falls back to 1.0 rather than producing NaNs.
    static func argmaxSoftmax(_ logits: [Float],
                              temperature: Double = 1.0)
    -> (index: Int, probability: Double)? {
        guard !logits.isEmpty else { return nil }
        let scale = (temperature.isFinite && temperature > 0) ? temperature : 1.0
        let scaled = logits.map { Double($0) / scale }
        var maxValue = scaled[0]
        for value in scaled where value > maxValue { maxValue = value }
        var sum = 0.0
        var bestIndex = 0
        var bestValue = -Double.greatestFiniteMagnitude
        for (index, value) in scaled.enumerated() {
            let exponented = exp(value - maxValue)
            sum += exponented
            if exponented > bestValue {
                bestValue = exponented
                bestIndex = index
            }
        }
        guard sum > 0 else { return nil }
        return (bestIndex, bestValue / sum)
    }

    private static func argmax(_ values: [Float]) -> Int? {
        guard !values.isEmpty else { return nil }
        var bestIndex = 0
        var best = values[0]
        for (index, value) in values.enumerated() where value > best {
            best = value
            bestIndex = index
        }
        return bestIndex
    }
}
