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
final class LocalIntentInterpreter: CommandInterpreter {

    struct Config {
        let confidenceThreshold: Double
        let maxTokens: Int
        let timeoutSeconds: Double
        static let `default` = Config(confidenceThreshold: 0.4,
                                      maxTokens: 192,
                                      timeoutSeconds: 3)
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
            self?.runInference(prompt: prompt) { json in
                let parsed = LlamaCommandInterpreter.parse(json: json)
                if let p = parsed, p.confidence < (self?.config.confidenceThreshold ?? 0.4) {
                    DispatchQueue.main.async { completion(nil) }
                } else {
                    DispatchQueue.main.async { completion(parsed) }
                }
            }
        }
    }

    // MARK: - Inference (guarded, with timeout)

    private func runInference(prompt: String,
                              completion: @escaping (String?) -> Void) {
        if let generateOverride {
            Task {
                do {
                    let out = try await generateOverride(prompt)
                    completion(out)
                } catch {
                    completion(nil)
                }
            }
            return
        }
        #if canImport(LLM)
        guard let modelURL = modelStore.path(for: modelId) else {
            emit("model_path_missing", outcome: "failure")
            completion(nil)
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
                    completion(nil)
                    return
                }
                llm = created
                llmInstance = llm
                emit("model_loaded", outcome: "success")
            }

            Task {
                await withTaskGroup(of: String??.self) { group in
                    group.addTask {
                        do {
                            // Grammar-constrained decoding (spec §8 /
                            // decision #4): `respond(to:as:)` drives the
                            // vendored fork's json-schema→grammar sampler
                            // — malformed JSON is structurally impossible.
                            let output = try await llm.respond(
                                to: prompt, as: StructuredIntent.self)
                            return output.rawOutput as String??
                        } catch {
                            return nil
                        }
                    }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: UInt64(self.config.timeoutSeconds * 1_000_000_000))
                        return nil
                    }
                    let result = await group.next() ?? nil
                    group.cancelAll()
                    if let output = (result ?? nil) as? String?, let output {
                        self.emit("inference_done", outcome: "success")
                        completion(output)
                    } else {
                        self.emit("inference_timeout", outcome: "failure")
                        completion(nil)
                    }
                }
            }
        }
        #else
        _ = prompt
        emit("inference_unavailable", outcome: "info")
        completion(nil)
        #endif
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

    private func emit(_ eventType: String, outcome: String) {
        observabilityBus.emit(ObservabilityEvent(
            component: "local_intent_interpreter",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: [:]
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
