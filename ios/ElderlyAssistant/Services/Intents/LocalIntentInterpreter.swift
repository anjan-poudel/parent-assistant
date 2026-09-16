import Foundation
#if canImport(LLM)
import LLM
#endif

/// The fine-tuned on-device intent model as `IntentRouter`'s local brain
/// (spec 2026-09-05 §8). Runs the ~1B QLoRA GGUF from the bake-off
/// (`ModelCatalog.intentNepali1B`) via the vendored LLM.swift (llama.cpp
/// + Metal), constrained at decode time by a JSON Schema — the v1 lesson
/// (grammar defined but never enforced at the sampler) resolved by the
/// runtime's json-schema→grammar sampler. Malformed JSON is structurally
/// impossible; `LlamaCommandInterpreter.parse(json:)` remains as
/// defense-in-depth.
///
/// Inference feeds the RAW prompt (`IntentPrompt.build`) with no chat
/// template — training used the identical plain-text format (see
/// tools/train-intent README §Training: training/inference prompt
/// identity). `generateConstrained` consumes raw input the same way.
///
/// Conforms to `CommandInterpreter` exactly like the LLaMA interpreter it
/// replaces as local brain — the router and band policy don't know or
/// care which model answered.
///
/// [LAT-EVIDENCE] (2026-09-12) Device log: `inference_timeout
/// outcome=failure` after ~3 s + `JSON Decoding failed ... Unexpected
/// end of file` — the 3 s timeout contradicted the coupled-numbers
/// family (llama ≤ 10 s) and clipped real generations; the truncated
/// decode produced a bare apology. The fix:
///   - the timeout aligns to 10 s (the llama family bound),
///   - a timeout OR a truncated/malformed JSON output retries ONCE (a
///     truncated decode is often transient),
///   - after a still-failing attempt the interpreter reports the honest
///     failure reason through `InterpreterFailureReporting`, and
///     `IntentRouter` escalates to the cloud when one is configured
///     (`local_failed_fallback`) — never a bare apology.
///
/// [CASCADE-RUNTIME] (2026-09-16) That retry did not fix the truncation
/// class it was written for: the retry ran under the SAME allocation as
/// the attempt that had just truncated. Two things changed:
///   1. The generation goes through `LLMCore.generateConstrained`
///      directly instead of `LLM.respond(to:as:)`. `respond` prepends a
///      "Matches this exact schema: …" block containing the whole schema
///      (~250 tokens) to the prompt AND accumulates conversation history
///      into every later prompt — on top of a 696-token template, inside a
///      1024-token context, that left ~20 tokens for the answer. The
///      observed device output is exactly that: `{"action": "call",
///      "entryId": null, "contact` (three fields) then `Unexpected end of
///      file`. The fine-tunes were trained on the bare template with the
///      JSON label appended (T-046), so dropping the block is also the
///      training-faithful prompt.
///   2. The context is sized from the turn (`OnDeviceGenerationBudget`)
///      and the RETRY gets a strictly larger budget, so a truncated turn
///      is never retried into the same wall. The runtime's termination
///      report keeps the two truncation classes honest:
///      `truncated_json` (context exhausted) and `premature_stop` (the
///      model ended the value itself, past the runtime's end-token guard).
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
    private let inferenceQueue = DispatchQueue(label: "local.intent", qos: .userInitiated)

    /// Cached LLM handle, held as `Any?` so this file compiles without
    /// the LLM package present.
    private var llmInstance: Any?

    /// [CASCADE-RUNTIME] The context the cached handle was allocated with
    /// (`OnDeviceGenerationBudget`). A bigger requirement re-creates the
    /// handle instead of truncating inside the smaller one.
    private(set) var allocatedContextTokens = 0

    /// [CASCADE-RUNTIME] The context budget each attempt of the LAST turn
    /// ran under, in attempt order — the observable proof that a retry
    /// grows the budget rather than repeating it. Cleared per turn.
    private(set) var attemptContextTokens: [Int] = []

    /// Test seam: replaces the llama.cpp call entirely. Receives the same
    /// two arguments the real runtime call receives — the raw prompt and
    /// the JSON schema (mirrors `LlamaCommandInterpreter.generateOverride`).
    var generateOverride: ((String, String) async throws -> String)?

    /// [CASCADE-RUNTIME] Test seam for the OTHER truncation class: reports
    /// that the runtime ended the value on an end token with the JSON still
    /// open (`termination == .endToken` — the model insisted past the
    /// runtime's `.completeJSON` skip allowance). No budget can fix that
    /// class, and the failure reason must say so. Default false: a seam
    /// output is a budget-class stop.
    var prematureStopOverride: ((String) -> Bool)?

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
         config: Config = .default) {
        self.modelStore = modelStore
        self.observabilityBus = observabilityBus
        self.modelId = modelId
        self.config = config
    }

    // MARK: - CommandInterpreter

    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        // [LAT-EVIDENCE] A fresh attempt starts clean.
        lastInferenceFailureReason = nil
        // [CASCADE-RUNTIME] So does the budget record: this turn's attempts.
        attemptContextTokens = []
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

    // MARK: - Attempts + retry ([LAT-EVIDENCE])

    /// One inference attempt's terminal state.
    private enum AttemptResult {
        /// The generation produced raw text (validity is decided at parse
        /// time). `prematureStop` is the runtime's report that an end token
        /// ended the value while it was still open — a failure class the
        /// parse cannot tell from a short-but-valid answer.
        case rawOutput(String, prematureStop: Bool)
        /// The generation threw (the real path's truncated-JSON decode
        /// class) — or the seam threw.
        case generationFailed
        /// The attempt outlived the 10 s bound.
        case timedOut
    }

    /// The honest reason for a generation that ended short, from the
    /// runtime's termination report. [CASCADE-RUNTIME]
    ///
    /// - `truncated_json` — the context bound was reached with the value
    ///   still open: the budget class, which the retry answers with a
    ///   bigger budget.
    /// - `premature_stop` — the model emitted an end token mid-value. The
    ///   runtime's `.completeJSON` policy already skips up to
    ///   `LLMCore.maxSkippedEndTokens` of those; this is the residue where
    ///   the model insisted, which no budget can fix.
    static func failureReason(prematureStop: Bool) -> String {
        prematureStop ? "premature_stop" : "truncated_json"
    }

    /// The context this attempt runs under. Attempt 0 uses the turn's
    /// requirement (never shrinking the cached handle); the retry uses a
    /// STRICTLY LARGER budget, so it never re-runs into the wall that just
    /// truncated it. [CASCADE-RUNTIME]
    private func contextBudget(prompt: String, attempt: Int) -> Int {
        let required = OnDeviceGenerationBudget.contextTokens(
            prompt: prompt,
            schema: Self.intentSchema,
            framingTokens: OnDeviceGenerationBudget.rawFramingTokens)
        let current = max(allocatedContextTokens, required)
        guard attempt > 0 else { return current }
        return OnDeviceGenerationBudget.grownContextTokens(current, schema: Self.intentSchema)
    }

    /// Runs ONE generation attempt (seam or real llama.cpp) and reports
    /// its terminal state.
    private func runAttempt(prompt: String,
                            attempt: Int,
                            completion: @escaping (AttemptResult) -> Void) {
        let contextTokens = contextBudget(prompt: prompt, attempt: attempt)
        attemptContextTokens.append(contextTokens)
        if let generateOverride {
            Task {
                do {
                    let out = try await generateOverride(prompt, Self.intentSchema)
                    completion(.rawOutput(out, prematureStop: prematureStopOverride?(out) ?? false))
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
            if let existing = llmInstance as? LLM, allocatedContextTokens >= contextTokens {
                llm = existing
            } else {
                if llmInstance != nil {
                    emit("model_context_grown", outcome: "info",
                         metadata: ["from_tokens": "\(allocatedContextTokens)",
                                    "to_tokens": "\(contextTokens)",
                                    "attempt": "\(attempt)"])
                    llmInstance = nil
                    allocatedContextTokens = 0
                }
                // Passthrough template: generation calls
                // `generateConstrained(from:jsonSchema:)` with the raw
                // prompt, so the only thing this Template must not do is
                // re-frame that prompt. The empty affixes keep it inert —
                // the string handed to the runtime is `IntentPrompt.build`'s
                // output, byte for byte (the training contract, T-046).
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
                                        maxTokenCount: Int32(contextTokens)) else {
                    emit("model_load_failed", outcome: "failure")
                    completion(.generationFailed)
                    return
                }
                llm = created
                llmInstance = llm
                allocatedContextTokens = contextTokens
                emit("model_loaded", outcome: "success",
                     metadata: ["context_tokens": "\(contextTokens)",
                                "attempt": "\(attempt)"])
            }

            Task {
                let result = await withTaskGroup(of: AttemptResult.self) { group in
                    group.addTask {
                        do {
                            // Grammar-constrained decoding (spec §8 /
                            // decision #4): the runtime converts the schema
                            // to a GBNF grammar and samples through it —
                            // malformed JSON is structurally impossible.
                            // `.completeJSON` keeps an end token from
                            // ending the value early (see the runtime).
                            let generation = try await llm.core.generateConstrained(
                                from: prompt,
                                jsonSchema: Self.intentSchema,
                                prematureEndTokenPolicy: .completeJSON)
                            let prematureStop = generation.termination == .endToken
                                && !LLMCore.isCompleteJSONValue(generation.output)
                            return .rawOutput(generation.output, prematureStop: prematureStop)
                        } catch {
                            // [LAT-EVIDENCE] The truncated-decode class:
                            // `JSON Decoding failed ... Unexpected end of
                            // file` — a failed generation, retried once.
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
    /// ONE retry on the failure classes, or the honest final failure.
    private func settleAttempt(prompt: String,
                               attempt: Int,
                               result: AttemptResult,
                               completion: @escaping (InterpretedCommand?) -> Void) {
        switch result {
        case .rawOutput(let json, let prematureStop):
            if let parsed = LlamaCommandInterpreter.parse(json: json) {
                if parsed.confidence < config.confidenceThreshold {
                    // Honest abstention — no retry, no failure.
                    DispatchQueue.main.async { completion(nil) }
                } else {
                    emit("inference_done", outcome: "success")
                    DispatchQueue.main.async { completion(parsed) }
                }
            } else if prematureStop || Self.isTruncatedJSON(json) {
                // [LAT-EVIDENCE] A brace-led partial emission — the
                // device-log truncated class. Retry once; a second
                // truncation is an honest failure the router escalates.
                // [CASCADE-RUNTIME] The reason names WHICH class: the
                // runtime reported an end token mid-value (`premature_stop`)
                // or the context bound ran out (`truncated_json`).
                retryOrFail(prompt: prompt, attempt: attempt,
                            reason: Self.failureReason(prematureStop: prematureStop),
                            completion: completion)
            } else {
                // Complete garbage — an abstention, exactly as before.
                DispatchQueue.main.async { completion(nil) }
            }
        case .generationFailed:
            // The runtime threw (a prompt that does not fit, a decode
            // failure): the same retry, on a bigger budget, is the honest
            // first response.
            retryOrFail(prompt: prompt, attempt: attempt,
                        reason: Self.failureReason(prematureStop: false),
                        completion: completion)
        case .timedOut:
            retryOrFail(prompt: prompt, attempt: attempt,
                        reason: "inference_timeout",
                        completion: completion)
        }
    }

    private func retryOrFail(prompt: String,
                             attempt: Int,
                             reason: String,
                             completion: @escaping (InterpretedCommand?) -> Void) {
        guard attempt == 0 else {
            emit(reason == "inference_timeout" ? "inference_timeout" : "inference_truncated",
                 outcome: "failure",
                 metadata: ["reason": reason,
                            // The budgets the two attempts ran under — the
                            // field evidence for "the retry really did try
                            // harder", and free of content (C9).
                            "budgets": attemptContextTokens.map(String.init).joined(separator: ",")])
            lastInferenceFailureReason = reason
            DispatchQueue.main.async { completion(nil) }
            return
        }
        emit("inference_retry", outcome: "info", metadata: ["reason": reason])
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
    ///
    /// [CASCADE-RUNTIME] This text is also the generation BUDGET's input:
    /// `OnDeviceGenerationBudget.schemaUpperBoundTokens(for:)` scans it so
    /// the context is sized to fit the largest JSON the schema can require.
    /// A field added here moves the budget with it — no second number to
    /// remember.
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

// [CASCADE-RUNTIME] The `StructuredIntent: Generatable` payload that
// `LLM.respond(to:as:)` used to decode into is gone with the call: the
// generation now goes through `LLMCore.generateConstrained` and the raw
// JSON goes through `LlamaCommandInterpreter.parse(json:)` — the same
// validation/clamping path every other brain's output takes.
