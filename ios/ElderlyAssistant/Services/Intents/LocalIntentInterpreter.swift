import Foundation
#if canImport(LLM)
import LLM
#endif

/// The fine-tuned on-device intent model as `IntentRouter`'s local brain
/// (spec 2026-09-05 §8). Runs the ~1B QLoRA GGUF from the bake-off
/// (`ModelCatalog.intentNepali1B`) via the vendored LLM.swift (llama.cpp
/// + Metal), constrained at decode time by a JSON Schema — the v1 lesson
/// (grammar defined but never enforced at the sampler) resolved by using
/// `LLM.generateWithConstraints(from:jsonSchema:)`, which converts the
/// schema to a llama.cpp grammar and samples through it. Malformed JSON
/// is structurally impossible; `LlamaCommandInterpreter.parse(json:)`
/// remains as defense-in-depth.
///
/// Inference feeds the RAW prompt (`IntentPrompt.build`) with no chat
/// template — training used the identical plain-text format (see
/// tools/train-intent README §Training: training/inference prompt
/// identity). `generateWithConstraints` consumes raw input the same way.
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
        /// The generation produced raw text (validity is decided at
        /// parse time).
        case rawOutput(String)
        /// The generation threw (the real path's truncated-JSON decode
        /// class) — or the seam threw.
        case generationFailed
        /// The attempt outlived the 10 s bound.
        case timedOut
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
                                        maxTokenCount: 1024) else {
                    emit("model_load_failed", outcome: "failure")
                    completion(.generationFailed)
                    return
                }
                llm = created
                llmInstance = llm
                emit("model_loaded", outcome: "success")
            }

            Task {
                let result = await withTaskGroup(of: AttemptResult.self) { group in
                    group.addTask {
                        do {
                            // Grammar-constrained decoding (spec §8 /
                            // decision #4): `respond(to:as:)` drives the
                            // vendored fork's json-schema→grammar sampler
                            // — malformed JSON is structurally impossible.
                            let output = try await llm.respond(
                                to: prompt, as: StructuredIntent.self)
                            return .rawOutput(output.rawOutput ?? "")
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
                // [LAT-EVIDENCE] A brace-led partial emission — the
                // device-log truncated class. Retry once; a second
                // truncation is an honest failure the router escalates.
                retryOrFail(prompt: prompt, attempt: attempt,
                            reason: "truncated_json",
                            completion: completion)
            } else {
                // Complete garbage — an abstention, exactly as before.
                DispatchQueue.main.async { completion(nil) }
            }
        case .generationFailed:
            retryOrFail(prompt: prompt, attempt: attempt,
                        reason: "truncated_json",
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
                 metadata: ["reason": reason])
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
