import Foundation
#if canImport(LLM)
import LLM
#endif

/// The fine-tuned on-device intent model as `IntentRouter`'s local brain
/// (spec 2026-09-05 §8). Runs the ~1B QLoRA GGUF from the bake-off
/// (`ModelCatalog.intentNepali1B`) via the vendored LLM.swift (llama.cpp
/// + Metal), constrained at decode time by a JSON Schema — the v1 lesson
/// (grammar defined but never enforced at the sampler) resolved by using
/// `LLMCore.generateWithConstraints(from:jsonSchema:)`, which converts
/// the schema to a llama.cpp grammar and samples through it. Malformed
/// JSON is structurally impossible; `LlamaCommandInterpreter.parse(json:)`
/// remains as defense-in-depth.
///
/// Inference feeds the RAW prompt (`IntentPrompt.build`) with no chat
/// template — training used the identical plain-text format (see
/// tools/train-intent README §Training: training/inference prompt
/// identity). `generateWithConstraints` consumes raw input the same way,
/// with the schema handed to the grammar converter as a PARAMETER — never
/// appended to the prompt.
///
/// [TRUNCATION-FIX] (2026-09-17) The former `respond(to:as:)` call
/// wrapped the prompt with the full JSON schema (+308 tokens), leaving
/// ~15 tokens of generation budget inside the shared 1,024-token
/// context — every Devanagari answer truncated mid-JSON ("दशैँ कहिले
/// हो" device failure), and the temp-0 fixed-seed retry replayed the
/// identical truncation. The fix:
///   - the raw prompt goes straight to `generateWithConstraints`
///     (composed prompt ≈ 700 tokens, ~320 of headroom),
///   - a pre-generation budget guard tokenizes the prompt and fails fast
///     (`inference_prompt_overflow`) instead of discovering the wall via
///     a truncated decode,
///   - ONLY timeouts retry (transient under CPU load); a budget-truncated
///     or failed generation is deterministic and fails honestly,
///     escalatable by `IntentRouter` — never a bare apology.
///
/// Conforms to `CommandInterpreter` exactly like the LLaMA interpreter it
/// replaces as local brain — the router and band policy don't know or
/// care which model answered.
final class LocalIntentInterpreter: CommandInterpreter, InterpreterFailureReporting {

    struct Config {
        let confidenceThreshold: Double
        let maxTokens: Int
        /// [LAT-EVIDENCE] 10 s — the coupled-numbers llama family bound
        /// (was 3 s, which timed out real generations; the retry runs
        /// under the SAME bound, so the local leg is 2 × 10 s worst
        /// case, still under the 60 s voice watchdog).
        let timeoutSeconds: Double
        static let `default` = Config(confidenceThreshold: 0.4,
                                      maxTokens: 192,
                                      timeoutSeconds: 10)
    }

    private let modelStore: ModelStore
    private let observabilityBus: ObservabilityBus
    private let modelId: ModelID
    private let config: Config
    /// [TRUNCATION-FIX] The residency ledger — the 1B handle is a REAL
    /// resident (the device log proved it), and an unregistered handle
    /// is invisible to every budget: the escalation then admitted the 4B
    /// brain on top of it and the pair got jetsam'd.
    private let lifecycle: ModelLifecycleManager
    private let inferenceQueue = DispatchQueue(label: "local.intent", qos: .userInitiated)

    /// Cached LLM handle, held as `Any?` so this file compiles without
    /// the LLM package present.
    private var llmInstance: Any?

    /// Test seam: replaces the llama.cpp call entirely.
    var generateOverride: ((String) async throws -> String)?

    /// [LAT-EVIDENCE] The honest reason the LAST attempt failed —
    /// "inference_timeout" or "truncated_json" — cleared at the start of
    /// each interpret. The router reads it after a nil result.
    private(set) var lastInferenceFailureReason: String?

    var isAvailable: Bool {
        if generateOverride != nil { return true }
        guard modelStore.isCached(modelId) else { return false }
        #if canImport(LLM)
        return true
        #else
        return false
        #endif
    }

    init(modelStore: ModelStore,
         observabilityBus: ObservabilityBus,
         modelId: ModelID = ModelCatalog.intentNepali1B,
         config: Config = .default,
         lifecycle: ModelLifecycleManager = .shared) {
        self.modelStore = modelStore
        self.observabilityBus = observabilityBus
        self.modelId = modelId
        self.config = config
        self.lifecycle = lifecycle
    }

    // MARK: - CommandInterpreter

    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        // [LAT-EVIDENCE] A fresh attempt starts clean.
        lastInferenceFailureReason = nil
        guard isAvailable else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let clean = InputSanitiser.sanitise(transcript, level: .quarantine)
        guard !clean.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let prompt = IntentPrompt.build(transcript: clean, context: context)
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            self.runAttempt(prompt: prompt, attempt: 0) { [weak self] result in
                guard let self else { return }
                self.settleAttempt(prompt: prompt, attempt: 0, result: result,
                                   completion: completion)
            }
        }
    }

    /// [TRUNCATION-FIX] Drop the resident handle. Called by the ledger's
    /// eviction closure and by the cascade before a heavier brain takes
    /// the turn. Mirrors `LlamaCommandInterpreter.unloadModel()`: a
    /// generation in flight is NOT interrupted — that stays the timeout's
    /// job (`llm.stop()`), because dropping the handle under a live
    /// decode pulls the context out from under it.
    func unload() {
        guard llmInstance != nil else { return }
        llmInstance = nil
        lifecycle.didUnload(.intentBrain, owner: self)
        emit("model_unloaded", outcome: "info")
    }

    // MARK: - Attempts + retry ([LAT-EVIDENCE] + [TRUNCATION-FIX])

    /// [TRUNCATION-FIX] The context budget the handle is created with —
    /// SHARED by prompt and output (n_ctx), so the prompt must leave
    /// generation headroom.
    static let contextTokenBudget = 1024
    /// Headroom reserved for the JSON answer: a complete 12-field reply
    /// with a Devanagari `reply` measures ~99 tokens; 128 leaves margin.
    static let outputHeadroomTokens = 128

    /// One inference attempt's terminal state.
    private enum AttemptResult {
        /// The generation produced raw text (validity is decided at
        /// parse time).
        case rawOutput(String)
        /// The generation threw — a runtime failure (the former
        /// truncated-JSON decode class) or the seam threw.
        case generationFailed
        /// The attempt outlived the 10 s bound.
        case timedOut
        /// [TRUNCATION-FIX] The composed prompt would leave less than
        /// `outputHeadroomTokens` of the shared context — fail fast, the
        /// attempt is doomed before the first token.
        case promptOverflow
    }

    /// Runs ONE generation attempt (seam or real llama.cpp) and reports
    /// its terminal state.
    private func runAttempt(prompt: String,
                            attempt: Int,
                            completion: @escaping (AttemptResult) -> Void) {
        if let generateOverride {
            Task {
                do {
                    let out = try await generateOverride(prompt)
                    completion(.rawOutput(out))
                } catch {
                    completion(.generationFailed)
                }
            }
            return
        }
        #if canImport(LLM)
        guard let modelURL = modelStore.path(for: modelId) else {
            emit("model_path_missing", outcome: "failure")
            completion(.generationFailed)
            return
        }
        do {
            let llm: LLM
            if let existing = llmInstance as? LLM {
                llm = existing
            } else {
                // [TRUNCATION-FIX] Gate + register with the residency
                // ledger BEFORE constructing the handle — the picker
                // brain's own contract. The gate can refuse for budget,
                // and the ledger now SEES this handle: evictions and
                // budget math stop pretending it does not exist.
                lifecycle.register(slot: .intentBrain, modelID: modelId,
                                   owner: self) { [weak self] in
                    self?.unload()
                }
                if case .denied(let reason) =
                    lifecycle.prepareLoad(of: .intentBrain, modelID: modelId) {
                    emit("model_load_denied:" + reason.rawValue, outcome: "failure")
                    lastInferenceFailureReason = "model_load_denied"
                    completion(.promptOverflow)
                    return
                }
                // Passthrough template: generation calls
                // `generateWithConstraints` with the raw prompt — the
                // template's chat framing is only used by `respond(to:)`,
                // which this class never calls.
                let rawTemplate = Template(
                    system: ("", ""), user: ("", ""), bot: ("", ""),
                    stopSequence: nil,
                    systemPrompt: ""
                )
                // [NO-GIBBERISH] (2026-09-07): deterministic sampling —
                // temp 0 + the FIXED seed in `OnDeviceSampling` (shared
                // with `LlamaCommandInterpreter`). Before this date the
                // handle was created with LLM.swift's defaults (temp 0.8,
                // RANDOM seed), so the same prompt could sample
                // differently on every run.
                guard let created = LLM(from: modelURL, template: rawTemplate,
                                        seed: OnDeviceSampling.fixedSeed,
                                        topK: OnDeviceSampling.topK,
                                        topP: OnDeviceSampling.topP,
                                        temp: OnDeviceSampling.temperature,
                                        repeatPenalty: OnDeviceSampling.repeatPenalty,
                                        repetitionLookback: OnDeviceSampling.repetitionLookback,
                                        maxTokenCount: Int32(Self.contextTokenBudget)) else {
                    emit("model_load_failed", outcome: "failure")
                    completion(.generationFailed)
                    return
                }
                llm = created
                llmInstance = llm
                lifecycle.didLoad(.intentBrain, owner: self)
                emit("model_loaded", outcome: "success")
            }

            Task {
                let result = await withTaskGroup(of: AttemptResult.self) { group in
                    group.addTask {
                        do {
                            // [TRUNCATION-FIX] Budget guard BEFORE the
                            // attempt: tokenize the composed prompt and
                            // fail fast when it would strangle the shared
                            // context — a near-full context truncates the
                            // generation mid-JSON, and under temp-0
                            // fixed-seed sampling that outcome is
                            // deterministic, not transient.
                            let tokenCount = await llm.encode(prompt).count
                            guard tokenCount <= Self.contextTokenBudget - Self.outputHeadroomTokens else {
                                self.emit("inference_prompt_overflow",
                                          outcome: "failure",
                                          metadata: ["reason": "prompt_overflow"])
                                self.lastInferenceFailureReason = "prompt_overflow"
                                return .promptOverflow
                            }
                            // [TRUNCATION-FIX] Pin the resident handle for
                            // the whole generation — a memory-pressure
                            // sweep must never pull it out from under the
                            // live decode.
                            self.lifecycle.beginUse(of: .intentBrain)
                            defer {
                                self.lifecycle.endUse(of: .intentBrain)
                                self.lifecycle.noteUse(of: .intentBrain)
                            }
                            // [TRUNCATION-FIX] Grammar-constrained decoding
                            // (spec §8 / decision #4) on the RAW prompt:
                            // the schema reaches the grammar converter as
                            // a PARAMETER, never appended to the prompt —
                            // `respond(to:as:)` wrapped the prompt with
                            // the full schema (+308 tokens of the shared
                            // 1,024 context), which was the "दशैँ कहिले
                            // हो" truncation root cause.
                            let output = try await llm.core.generateWithConstraints(
                                from: prompt,
                                jsonSchema: StructuredIntent.jsonSchema)
                            return .rawOutput(output)
                        } catch {
                            return .generationFailed
                        }
                    }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: UInt64(self.config.timeoutSeconds * 1_000_000_000))
                        return .timedOut
                    }
                    let first = await group.next() ?? .timedOut
                    group.cancelAll()
                    return first
                }
                completion(result)
            }
        }
        #else
        _ = prompt
        emit("inference_unavailable", outcome: "info")
        completion(.generationFailed)
        #endif
    }

    /// Decides what one attempt's terminal state means: parse + band, or
    /// ONE retry — timeouts only ([TRUNCATION-FIX]: under temp 0 + fixed
    /// seed every other failure class deterministically repeats, so
    /// retrying them only delays the honest escalation).
    private func settleAttempt(prompt: String,
                               attempt: Int,
                               result: AttemptResult,
                               completion: @escaping (InterpretedCommand?) -> Void) {
        switch result {
        case .rawOutput(let json):
            if let parsed = LlamaCommandInterpreter.parse(json: json) {
                if parsed.confidence < config.confidenceThreshold {
                    // Honest abstention — no retry, no failure.
                    DispatchQueue.main.async { completion(nil) }
                } else {
                    emit("inference_done", outcome: "success")
                    DispatchQueue.main.async { completion(parsed) }
                }
            } else if Self.isTruncatedJSON(json) {
                // [TRUNCATION-FIX] A brace-led partial emission is a
                // budget cut, not noise — deterministic, so no retry:
                // report the honest reason and let the router escalate.
                fail(reason: "truncated_json",
                     completion: completion)
            } else {
                // Complete garbage — an abstention, exactly as before.
                DispatchQueue.main.async { completion(nil) }
            }
        case .generationFailed:
            fail(reason: "inference_failed",
                 completion: completion)
        case .timedOut:
            // [LAT-EVIDENCE] Timeouts stay retried once — CPU contention
            // IS transient, unlike a budget cut or a runtime failure.
            retryOrFail(prompt: prompt, attempt: attempt,
                        completion: completion)
        case .promptOverflow:
            // Already reported by the guard in `runAttempt` — nothing
            // further to try.
            DispatchQueue.main.async { completion(nil) }
        }
    }

    /// The honest final failure: no retry, an event, and a nil result
    /// the router escalates (`local_failed_fallback`).
    private func fail(reason: String,
                      completion: @escaping (InterpretedCommand?) -> Void) {
        emit(reason == "inference_timeout" ? "inference_timeout"
             : reason == "truncated_json" ? "inference_truncated"
             : "inference_failed",
             outcome: "failure",
             metadata: ["reason": reason])
        lastInferenceFailureReason = reason
        DispatchQueue.main.async { completion(nil) }
    }

    private func retryOrFail(prompt: String,
                             attempt: Int,
                             completion: @escaping (InterpretedCommand?) -> Void) {
        guard attempt == 0 else {
            fail(reason: "inference_timeout", completion: completion)
            return
        }
        emit("inference_retry", outcome: "info", metadata: ["reason": "inference_timeout"])
        runAttempt(prompt: prompt, attempt: 1) { [weak self] result in
            guard let self else { return }
            self.settleAttempt(prompt: prompt, attempt: 1, result: result,
                               completion: completion)
        }
    }

    /// [LAT-EVIDENCE] Truncation heuristic: the output began as a JSON
    /// value but never completed (the device-log `Unexpected end of
    /// file` class) — a partial emission is a failure, not an
    /// abstention. Complete garbage (no leading brace/bracket) keeps the
    /// pre-existing abstention semantics.
    static func isTruncatedJSON(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    // MARK: - JSON Schema (grammar-constrained decoding)

    /// The intent/v2 output schema handed to llama.cpp's
    /// json-schema→grammar converter. Mirrors `LlamaGrammar.commandJSON`
    /// (the source of truth for the wire shape); keep in sync when the
    /// schema versions. The converter supports the subset used here:
    /// typed object properties, enums, string/number, nullable via type
    /// unions, and string arrays.
    static let intentSchema = """
    {
      "type": "object",
      "properties": {
        "action": {
          "type": "string",
          "enum": ["ack_med", "call", "emergency", "set_reminder",
                   "health_query", "music", "send_message", "guide",
                   "create_calendar_event", "suggest_video", "query", "none"]
        },
        "entryId": {"type": ["string", "null"]},
        "contact": {"type": ["string", "null"]},
        "time": {"type": ["string", "null"]},
        "medication": {"type": ["string", "null"]},
        "message": {"type": ["string", "null"]},
        "callType": {"type": ["string", "null"]},
        "requestedApp": {"type": ["string", "null"]},
        "topic": {"type": ["string", "null"]},
        "steps": {"type": ["array", "null"], "items": {"type": "string"}},
        "confidence": {"type": "number"},
        "reply": {"type": "string"}
      },
      "required": ["action", "entryId", "contact", "time", "medication",
                   "message", "callType", "requestedApp", "topic", "steps",
                   "confidence", "reply"]
    }
    """

    // MARK: - Observability (no transcript/output content — C9)

    private func emit(_ eventType: String,
                      outcome: String,
                      metadata: [String: String] = [:]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "local_intent_interpreter",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: metadata
        ))
    }
}


// MARK: - Constrained decoding payload

/// The `Generatable` conformance `LLM.respond(to:as:)` decodes into —
/// macro-free (the protocol needs only Codable + a static schema). The
/// raw JSON still goes through `LlamaCommandInterpreter.parse(json:)`
/// for the shared validation/clamping path.
struct StructuredIntent: Generatable {
    let action: String
    let entryId: String?
    let contact: String?
    let time: String?
    let medication: String?
    let message: String?
    let callType: String?
    let requestedApp: String?
    let topic: String?
    let steps: [String]?
    let confidence: Double
    let reply: String

    static let jsonSchema: String = LocalIntentInterpreter.intentSchema
}
