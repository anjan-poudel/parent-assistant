import Foundation
#if canImport(LLM)
import LLM
#endif

/// LLM-driven interpretation of a transcript into a structured command.
///
/// Runs LLaMA 3.2 (1B or 3B) on-device via llama.cpp. The GBNF grammar
/// below is the single source of truth for the JSON schema; LLM.swift does
/// not expose sampler-level grammar constraints, so well-formedness is
/// enforced here by strict decoding against the same schema plus a
/// defensive JSON-object extraction — and any parse failure falls back to
/// the router's keyword layer (review H2's "enforce or drop the claim":
/// the claim is enforced as output validation, and the grammar stays
/// unit-tested as the schema definition).
///
/// The interpreter sits BEHIND `CommandRouter`. Router calls it first;
/// falls back to keyword matching on:
///   - interpreter unavailable (model not cached, runtime not linked)
///   - confidence < confidenceThreshold
///   - inference timeout (spec §5.2 — new failure path, default 10s)
///   - JSON doesn't parse (defensive)
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

/// Structured command emitted by the LLM. Matches the GBNF grammar exactly
/// (spec §5.1 catalog, §5.2 entities).
struct InterpretedCommand: Equatable {
    enum Action: String, Codable {
        case ackMed = "ack_med"
        case call
        case emergency
        case setReminder = "set_reminder"
        case healthQuery = "health_query"
        case music
        case query
        case sendMessage = "send_message"
        /// Escape hatch for capability contributed by a registered
        /// `AssistantPlugin` (see Services/Plugins). Core never learns
        /// plugin action names — they travel in `pluginAction`, and this
        /// single case is the only core change a plugin ever needs
        /// (docs/superpowers/specs/2026-09-05-plugin-architecture-design.md).
        case plugin = "plugin"
        case none
    }
    let action: Action
    let entryId: String?
    let contact: String?
    /// Entity: a time expression as spoken ("बिहान ८ बजे", "8:00") —
    /// resolved by `NepaliTimeParser` in the `set_reminder` handler.
    let time: String?
    /// Entity: medication name, matched against the scheduler's list by
    /// the handler when available.
    let medication: String?
    /// Entity: the message body for `send_message`, in the user's
    /// language, as dictated (trial wiring — spec: presents the native
    /// compose sheet pre-filled, since iOS never sends SMS silently).
    let message: String?
    /// Entity for `call`: "voice" or "video", as best determined from
    /// phrasing (2026-09-05 "intent is king" call routing). Nil defaults
    /// to a voice call.
    let callType: String?
    /// Entity for `call`: an app the user explicitly named ("facetime",
    /// "whatsapp", "messenger", "viber"), else null. Only FaceTime and
    /// WhatsApp have any real integration on iOS — anything else falls
    /// back to FaceTime with a disclosed notice
    /// (`AppCoordinator.resolveCallMethod`).
    let requestedApp: String?
    /// Only meaningful when action == .plugin — the plugin-namespaced
    /// action to dispatch (e.g. "nepali_calendar.query").
    let pluginAction: String?
    /// Generic entity bag for plugin actions — plugins declare the keys
    /// they need in their own prompt fragment rather than growing named
    /// optional fields here per feature (that would recreate the
    /// "core file grows per feature" problem the plugin system avoids).
    let pluginEntities: [String: String]?
    let confidence: Double
    let reply: String
}

// MARK: - GBNF grammar

/// The llama.cpp grammar handed to the sampler where the runtime supports
/// it. Kept as source so it can be unit-tested and version-bumped
/// alongside the schema.
enum LlamaGrammar {
    static let commandJSON: String = """
    root   ::= "{" ws "\\"action\\"" ws ":" ws action ws "," ws
                    "\\"entryId\\"" ws ":" ws maybeString ws "," ws
                    "\\"contact\\"" ws ":" ws maybeString ws "," ws
                    "\\"time\\"" ws ":" ws maybeString ws "," ws
                    "\\"medication\\"" ws ":" ws maybeString ws "," ws
                    "\\"message\\"" ws ":" ws maybeString ws "," ws
                    "\\"callType\\"" ws ":" ws maybeString ws "," ws
                    "\\"requestedApp\\"" ws ":" ws maybeString ws "," ws
                    "\\"pluginAction\\"" ws ":" ws maybeString ws "," ws
                    "\\"pluginEntities\\"" ws ":" ws entityMap ws "," ws
                    "\\"confidence\\"" ws ":" ws number ws "," ws
                    "\\"reply\\"" ws ":" ws string ws "}"
    action ::= "\\"ack_med\\"" | "\\"call\\"" | "\\"emergency\\""
             | "\\"set_reminder\\"" | "\\"health_query\\"" | "\\"music\\""
             | "\\"send_message\\"" | "\\"query\\"" | "\\"plugin\\"" | "\\"none\\""
    maybeString ::= "null" | string
    entityMap ::= "null" | "{" ws ("\\"" ([^"\\\\] | "\\\\" .)* "\\"" ws ":" ws string (ws "," ws "\\"" ([^"\\\\] | "\\\\" .)* "\\"" ws ":" ws string)*)? ws "}"
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
        /// Inference timeout (spec §5.2, review H2). On expiry the
        /// interpreter reports nil so the router falls back to keyword
        /// matching — this is a NEW failure path, not preserved behavior.
        let timeoutSeconds: Double
        static let `default` = Config(confidenceThreshold: 0.7,
                                      maxTokens: 128,
                                      temperature: 0.2,
                                      timeoutSeconds: 10)
    }

    private let modelStore: ModelStore
    private let observabilityBus: ObservabilityBus
    private let config: Config
    /// Optional — when set, prompt composition includes applicable
    /// plugins' intent fragments (see `IntentPrompt.build`).
    private let pluginRegistry: PluginRegistry?
    private let inferenceQueue = DispatchQueue(label: "llama.command",
                                               qos: .userInitiated)

    /// Which base model is selected (1B or 3B). Read at each request from
    /// `ModelStore` so hot-swap works.
    private let preferredBaseId: ModelID
    /// Last requested LoRA — Phase-1 skeleton only.
    private var activeLoRA: ModelID?

    /// The single template-level system prompt used for BOTH the
    /// `Template(systemPrompt:)` handed to `LLM(from:)` and the manually
    /// formatted chat header in `runInference` — previously duplicated as
    /// two inline copies that could drift apart. Kept deliberately SHORT:
    /// the on-device model is 1B and long system prompts hurt it. The
    /// detailed schema/entity instructions live in the user turn via
    /// `IntentPrompt.build` — this string only carries identity, the two
    /// operating modes, output discipline, and the reply style, matching
    /// the elderly-assistance customization in `IntentPrompt`.
    private static let chatSystemPrompt = """
    You are Sahayak, a voice assistant for an elderly speaker who is not \
    a native English speaker and finds technology difficult. You operate \
    in exactly two modes: (1) deciphering the user's intent into a \
    structured command, or (2) answering an open-form question or \
    statement. Reply ONLY with a single JSON object matching the schema \
    in the user's message — no other text. Write the reply field in \
    plain, simple language with short sentences, warm and respectful, in \
    the user's own language — it will be spoken aloud to them.
    """

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
         config: Config = .default,
         pluginRegistry: PluginRegistry? = nil) {
        self.modelStore = modelStore
        self.observabilityBus = observabilityBus
        self.preferredBaseId = preferredBaseId
        self.config = config
        self.pluginRegistry = pluginRegistry
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
        // Sanitise BEFORE the transcript reaches any prompt string
        // (NFR-013 / review H3 / spec §5.2).
        let clean = InputSanitiser.sanitise(transcript, level: .quarantine)
        guard !clean.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let activePlugins = pluginRegistry?.activePlugins(
            for: Locale(identifier: context.userLanguageHint)) ?? []
        let prompt = IntentPrompt.build(transcript: clean, context: context,
                                        activePlugins: activePlugins)

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

    // MARK: - Inference (guarded, with timeout — spec §5.2)

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
                systemPrompt: Self.chatSystemPrompt
            )
            // 1024-token context (default 2048): our prompts are ~150
            // tokens + 128 output, and the smaller n_batch halves
            // llama.cpp's compute buffers — with Whisper resident,
            // 2048 overflowed the app's memory ceiling and crashed
            // `llama_context::output_reserve` on 6 GB devices.
            guard let created = LLM(from: modelURL, template: llama3Template,
                                    maxTokenCount: 1024) else {
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
        let systemPrompt = Self.chatSystemPrompt
        let formattedPrompt = """
        <|begin_of_text|><|start_header_id|>system<|end_header_id|>

        \(systemPrompt)<|eot_id|><|start_header_id|>user<|end_header_id|>

        \(prompt)<|eot_id|><|start_header_id|>assistant<|end_header_id|>


        """

        Task {
            await withTaskGroup(of: String??.self) { group in
                group.addTask {
                    await llm.getCompletion(from: formattedPrompt) as String??
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(self.config.timeoutSeconds * 1_000_000_000))
                    return nil
                }
                // First result wins; on timeout the sleep task returns nil
                // first and the interpreter reports "not confident" so the
                // router falls back to keyword matching.
                let result = await group.next() ?? nil
                group.cancelAll()
                if let output = (result ?? nil) as? String?, let output {
                    emit("inference_done", outcome: "success")
                    completion(output)
                } else {
                    emit("inference_timeout", outcome: "failure")
                    completion(nil)
                }
            }
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
                time: decoded.time,
                medication: decoded.medication,
                message: decoded.message,
                callType: decoded.callType,
                requestedApp: decoded.requestedApp,
                pluginAction: decoded.pluginAction,
                pluginEntities: decoded.pluginEntities,
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
        let time: String?
        let medication: String?
        let message: String?
        let callType: String?
        let requestedApp: String?
        let pluginAction: String?
        let pluginEntities: [String: String]?
        let confidence: Double
        let reply: String
    }

    // MARK: - Observability

    /// Emits an event with NO transcript or output content — review C9:
    /// metadata must not carry transcript-derived PII.
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
