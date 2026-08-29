import Foundation
#if canImport(LLM)
import LLM
#endif

/// LLM-driven interpretation of a transcript into a structured command.
///
/// Runs LLaMA 3.2 (1B or 3B) on-device via llama.cpp with GBNF grammar
/// constraint so the output is *always* well-formed JSON matching the
/// schema below. That eliminates a whole class of production bugs (partial
/// output, hallucinated fields, wrong casing) and is the reason we use a
/// small LLM here at all — an intent classifier can't handle the indirect,
/// underspecified, code-switched utterances elderly users produce.
///
/// The interpreter sits BEHIND `CommandRouter`. Router calls it first;
/// falls back to keyword matching on:
///   - interpreter unavailable (model not cached, runtime not linked)
///   - confidence < confidenceThreshold
///   - JSON somehow doesn't parse (defensive — GBNF should make it moot)
protocol CommandInterpreter: AnyObject {
    var isAvailable: Bool { get }
    /// Interpret a transcript. Nil result = "I couldn't parse this,
    /// caller should fall back". Completion runs on the main queue.
    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void)
}

/// Runtime context handed to the LLM as part of the prompt so it can
/// answer questions like "what's my medication schedule".
struct InterpreterContext {
    let pendingMedications: [String]   // display names only
    let userLanguageHint: String       // "ne" or "en"
}

/// Structured command emitted by the LLM. Matches the GBNF grammar exactly.
struct InterpretedCommand: Equatable {
    enum Action: String, Codable {
        case ackMed = "ack_med"
        case call
        case query
        case none
    }
    let action: Action
    let entryId: String?
    let contact: String?
    let confidence: Double
    let reply: String
}

// MARK: - GBNF grammar

/// The llama.cpp grammar handed to the sampler. Kept as source so it can be
/// unit-tested and version-bumped alongside the schema.
enum LlamaGrammar {
    static let commandJSON: String = """
    root   ::= "{" ws "\\"action\\"" ws ":" ws action ws "," ws
                    "\\"entryId\\"" ws ":" ws maybeString ws "," ws
                    "\\"contact\\"" ws ":" ws maybeString ws "," ws
                    "\\"confidence\\"" ws ":" ws number ws "," ws
                    "\\"reply\\"" ws ":" ws string ws "}"
    action ::= "\\"ack_med\\"" | "\\"call\\"" | "\\"query\\"" | "\\"none\\""
    maybeString ::= "null" | string
    string ::= "\\"" ([^"\\\\] | "\\\\" .)* "\\""
    number ::= ("0" | [1-9][0-9]*) ("." [0-9]+)?
    ws     ::= [ \\t\\n]*
    """
}

// MARK: - Null impl (compile-safe fallback)

final class NullCommandInterpreter: CommandInterpreter {
    var isAvailable: Bool { false }
    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        DispatchQueue.main.async { completion(nil) }
    }
}

// MARK: - LLaMA implementation (guarded)

/// Concrete llama.cpp-backed interpreter. Enabled once one of:
///  - LLM.swift (`import LLM`) SPM package is added AND the chosen LLaMA
///    3.2 GGUF is cached in `ModelStore`.
///  - Or a locally-vendored `llama` xcframework is linked.
///
/// The `#if canImport(LLM)` guard keeps the file compilable in Phase 1
/// without either being present.
final class LlamaCommandInterpreter: CommandInterpreter {

    struct Config {
        let confidenceThreshold: Double
        let maxTokens: Int
        let temperature: Float
        static let `default` = Config(confidenceThreshold: 0.7,
                                      maxTokens: 128,
                                      temperature: 0.2)
    }

    private let modelStore: ModelStore
    private let observabilityBus: ObservabilityBus
    private let config: Config
    private let inferenceQueue = DispatchQueue(label: "llama.command",
                                               qos: .userInitiated)

    /// Which base model is selected (1B or 3B). Read at each request from
    /// `ModelStore` so hot-swap works.
    private let preferredBaseId: ModelID
    /// Last requested LoRA — Phase-1 skeleton only.
    private var activeLoRA: ModelID?

    /// Cached LLM handle. Held as `Any?` so this file compiles without
    /// the LLM package present. Casts to `LLM.LLM` inside `#if canImport`.
    private var llmInstance: Any?

    var isAvailable: Bool {
        guard modelStore.isCached(preferredBaseId) else { return false }
        #if canImport(LLM)
        return true
        #else
        return false
        #endif
    }

    init(modelStore: ModelStore,
         observabilityBus: ObservabilityBus,
         preferredBaseId: ModelID = ModelCatalog.llama3_2_1B,
         config: Config = .default) {
        self.modelStore = modelStore
        self.observabilityBus = observabilityBus
        self.preferredBaseId = preferredBaseId
        self.config = config
    }

    // MARK: - LoRA skeleton

    func applyLoRA(_ id: ModelID?) {
        activeLoRA = id
        observabilityBus.emit(ObservabilityEvent(
            component: "llama_interpreter",
            eventType: "lora_hot_swap_skeleton",
            durationMs: nil,
            outcome: "info",
            errorCode: nil,
            metadata: ["state": id?.rawValue ?? "none"]
        ))
    }

    // MARK: - Interpret

    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        guard isAvailable else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let prompt = Self.buildPrompt(transcript: transcript, context: context)

        inferenceQueue.async { [weak self] in
            self?.runInference(prompt: prompt) { json in
                let parsed = Self.parse(json: json)
                if let p = parsed, p.confidence < (self?.config.confidenceThreshold ?? 0.7) {
                    // Below the threshold — treat as "not confident" so the
                    // router falls back to keyword matching.
                    DispatchQueue.main.async { completion(nil) }
                } else {
                    DispatchQueue.main.async { completion(parsed) }
                }
            }
        }
    }

    // MARK: - Prompt

    private static func buildPrompt(transcript: String,
                                    context: InterpreterContext) -> String {
        // From research-doc §6a.2. Kept short; the GBNF grammar handles
        // shape, so the prompt only guides content.
        let meds = context.pendingMedications.isEmpty
            ? "(none)"
            : context.pendingMedications.joined(separator: ", ")
        return """
        You are Sahayak, a personal assistant for an elderly speaker.
        The user's pending medications are: \(meds).
        The user's language hint is: \(context.userLanguageHint).
        Reply with a single JSON object matching the tool schema.
        Set action to "ack_med" if the user is confirming they took their
        medication, "call" if they want to make a call, "query" if they are
        asking a question, otherwise "none". Set entryId and contact to null
        unless you can identify a specific target. Set confidence to your
        certainty in [0, 1]. Set reply to a short response in the user's
        language.
        User said: "\(transcript)"
        """
    }

    // MARK: - Inference (guarded)

    private func runInference(prompt: String,
                              completion: @escaping (String?) -> Void) {
        #if canImport(LLM)
        guard let modelURL = modelStore.path(for: preferredBaseId) else {
            emit("model_path_missing", outcome: "failure")
            completion(nil)
            return
        }

        let llm: LLM
        if let existing = llmInstance as? LLM {
            llm = existing
        } else {
            // LLM.swift doesn't ship a Llama-3 template preset (`.llama` is
            // the Llama-2 `[INST]` format). Build one that matches
            // LLaMA 3.2's official chat header/EOT scheme so instruction
            // following actually works.
            let llama3Template = Template(
                system: (
                    "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n",
                    "<|eot_id|>"
                ),
                user: (
                    "<|start_header_id|>user<|end_header_id|>\n\n",
                    "<|eot_id|>"
                ),
                bot: (
                    "<|start_header_id|>assistant<|end_header_id|>\n\n",
                    "<|eot_id|>"
                ),
                stopSequence: "<|eot_id|>",
                systemPrompt: "You are Sahayak, a personal assistant. Reply ONLY with a JSON object matching the schema. No other text."
            )
            guard let created = LLM(from: modelURL, template: llama3Template) else {
                emit("model_load_failed", outcome: "failure")
                completion(nil)
                return
            }
            llm = created
            llmInstance = llm
            emit("model_loaded", outcome: "success")
        }

        // LLM.swift's `getCompletion(from:)` sends the raw string with
        // no template preprocessing — the Template we passed to `LLM(from:)`
        // only gets applied by `respond(to:)`. If we call getCompletion
        // with a bare prompt, LLaMA 3.2 gets no chat headers and no system
        // prompt, and instruction-following falls apart.
        //
        // Manually format with LLaMA 3.2's official chat scheme instead.
        let systemPrompt = "You are Sahayak, a personal assistant. Reply ONLY with a JSON object matching the schema. No other text."
        let formattedPrompt = """
        <|begin_of_text|><|start_header_id|>system<|end_header_id|>

        \(systemPrompt)<|eot_id|><|start_header_id|>user<|end_header_id|>

        \(prompt)<|eot_id|><|start_header_id|>assistant<|end_header_id|>


        """

        Task { [weak self] in
            let output = await llm.getCompletion(from: formattedPrompt)
            let preview = output.replacingOccurrences(of: "\n", with: " ")
                .prefix(160)
            self?.observabilityBus.emit(ObservabilityEvent(
                component: "llama_interpreter",
                eventType: "inference_done",
                durationMs: nil,
                outcome: "success",
                errorCode: nil,
                metadata: ["state": String(preview)]
            ))
            completion(output)
        }
        #else
        _ = prompt
        emit("inference_unavailable", outcome: "info")
        completion(nil)
        #endif
    }

    // MARK: - Parse

    static func parse(json raw: String?) -> InterpretedCommand? {
        guard let raw = raw else { return nil }
        // Small models often wrap output in ```json fences or add
        // explanatory prose. Extract the first {...} block.
        let extracted = Self.extractJSONObject(from: raw) ?? raw
        guard let data = extracted.data(using: .utf8) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(RawCommand.self, from: data)
            guard let action = InterpretedCommand.Action(rawValue: decoded.action) else {
                return nil
            }
            let clamped = max(0.0, min(1.0, decoded.confidence))
            return InterpretedCommand(
                action: action,
                entryId: decoded.entryId,
                contact: decoded.contact,
                confidence: clamped,
                reply: decoded.reply
            )
        } catch {
            return nil
        }
    }

    /// Best-effort extraction of the first balanced JSON object from a
    /// string that may include markdown fences or prose. Handles nested
    /// braces and quoted strings so we don't stop early on a `{` inside a
    /// reply string.
    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var idx = start
        while idx < text.endIndex {
            let c = text[idx]
            if escape {
                escape = false
            } else if c == "\\" {
                escape = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...idx])
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    // Codable shape matched to the GBNF grammar output.
    private struct RawCommand: Codable {
        let action: String
        let entryId: String?
        let contact: String?
        let confidence: Double
        let reply: String
    }

    // MARK: - Observability

    private func emit(_ eventType: String, outcome: String) {
        observabilityBus.emit(ObservabilityEvent(
            component: "llama_interpreter",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: [:]
        ))
    }
}
