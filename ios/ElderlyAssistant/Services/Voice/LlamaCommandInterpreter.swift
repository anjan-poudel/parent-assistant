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
struct InterpretedCommand: Equatable, Codable {
    enum Action: String, Codable {
        case ackMed = "ack_med"
        case call
        case emergency
        case setReminder = "set_reminder"
        case healthQuery = "health_query"
        case music
        case query
        case sendMessage = "send_message"
        // intent/v2 (2026-09-05 spec §5): Guide class — steps are SPOKEN to
        // the user, never executed on-device; and the two new cloud-side
        // helper actions from the v2 pivot catalog (§3.2 of the pivot doc).
        case guide
        case createCalendarEvent = "create_calendar_event"
        case suggestVideo = "suggest_video"
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
    /// intent/v2 — entity for `guide`: the subject the user wants help
    /// with ("microwave", "tv remote"), free-form as spoken.
    let topic: String?
    /// intent/v2 — payload for `guide`: short instruction steps in the
    /// user's language. Guide steps are SPOKEN/SHOWN to the human and are
    /// never executed as device actions (spec §5 — the Action/Guide
    /// separation is what stops a generated "step 3: open whatsapp://…"
    /// from ever being treated as a device action).
    let steps: [String]?
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

    /// Memberwise init with the intent/v2 fields defaulted — pre-v2 call
    /// sites (and v1 test fixtures) construct commands without
    /// topic/steps and keep compiling unchanged.
    init(action: Action, entryId: String?, contact: String?, time: String?,
         medication: String?, message: String?, callType: String?,
         requestedApp: String?, topic: String? = nil, steps: [String]? = nil,
         pluginAction: String? = nil, pluginEntities: [String: String]? = nil,
         confidence: Double, reply: String) {
        self.action = action
        self.entryId = entryId
        self.contact = contact
        self.time = time
        self.medication = medication
        self.message = message
        self.callType = callType
        self.requestedApp = requestedApp
        self.topic = topic
        self.steps = steps
        self.pluginAction = pluginAction
        self.pluginEntities = pluginEntities
        self.confidence = confidence
        self.reply = reply
    }
}

// MARK: - GBNF grammar

/// The llama.cpp grammar handed to the sampler where the runtime supports
/// it. Kept as source so it can be unit-tested and version-bumped
/// alongside the schema.
///
/// Mirrors the STRUCTURED-RESPONSE CONTRACT (2026-09-06, [QUERY-FIX]) the
/// shared prompt teaches: `intent` + always-non-empty `response` +
/// `confidence`, plus `actionType`/`actionUrl` and the entity/slot fields.
/// `parse(json:)` additionally accepts the pre-contract legacy wire shape
/// (`action`/`reply`) so old cached payloads, the cloud collapsed path's
/// canned output, and the grammar-constrained fine-tuned local brain
/// (whose `intentSchema` still emits the legacy keys) keep working —
/// lenient in that one direction only.
enum LlamaGrammar {
    static let commandJSON: String = """
    root   ::= "{" ws "\\"intent\\"" ws ":" ws intent ws "," ws
                    "\\"response\\"" ws ":" ws string ws "," ws
                    "\\"confidence\\"" ws ":" ws number ws "," ws
                    "\\"actionType\\"" ws ":" ws maybeString ws "," ws
                    "\\"actionUrl\\"" ws ":" ws maybeString ws "," ws
                    "\\"entryId\\"" ws ":" ws maybeString ws "," ws
                    "\\"contact\\"" ws ":" ws maybeString ws "," ws
                    "\\"time\\"" ws ":" ws maybeString ws "," ws
                    "\\"medication\\"" ws ":" ws maybeString ws "," ws
                    "\\"message\\"" ws ":" ws maybeString ws "," ws
                    "\\"callType\\"" ws ":" ws maybeString ws "," ws
                    "\\"requestedApp\\"" ws ":" ws maybeString ws "," ws
                    "\\"topic\\"" ws ":" ws maybeString ws "," ws
                    "\\"steps\\"" ws ":" ws maybeStringArray ws "," ws
                    "\\"pluginAction\\"" ws ":" ws maybeString ws "," ws
                    "\\"pluginEntities\\"" ws ":" ws entityMap ws "}"
    intent ::= "\\"ack_med\\"" | "\\"call\\"" | "\\"emergency\\""
             | "\\"set_reminder\\"" | "\\"health_query\\"" | "\\"music\\""
             | "\\"send_message\\"" | "\\"guide\\""
             | "\\"create_calendar_event\\"" | "\\"suggest_video\\""
             | "\\"query\\"" | "\\"none\\""
    maybeString ::= "null" | string
    maybeStringArray ::= "null" | "[" ws (string ("," ws string)*)? "]"
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
    /// Optional — retained for wiring compatibility (`AppCoordinator`
    /// passes the shared registry). Plugin capability fragments are NOT
    /// composed into the on-device prompt: this runtime's context is
    /// 1,024 tokens and the full fragment text overflowed it — the
    /// silent empty completion behind the 2026-09-06 [QUERY-FIX] bug (the
    /// `inference_empty_output` guard in `runInference` makes any future
    /// overflow observable instead of silent). Plugin-bearing prompts are
    /// the cloud path's job (`GeminiCommandInterpreter`).
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
    /// the on-device model is 1B in a 1,024-token context, and the
    /// pre-[QUERY-FIX] prompt measured 2,361 tokens — an overflow that
    /// produced empty completions (the 2026-09-06 bug). The detailed
    /// schema/entity instructions live in the user turn via
    /// `IntentPrompt.build`; this string only carries identity, the two
    /// operating modes, output discipline, and the reply style.
    private static let chatSystemPrompt = """
    You are Sahayak, a voice assistant for an elderly speaker. Reply ONLY \
    with one JSON object matching the schema in the user's message — no \
    other text, no markdown fences. The "response" field must be a \
    non-empty string in the user's own language, plain and simple, short \
    sentences, warm and respectful — it will be spoken aloud.
    """

    /// Test seam: replaces the llama.cpp call entirely (same pattern as
    /// `LocalIntentInterpreter.generateOverride`). While set, the
    /// interpreter is "available" without any cached model, so the REAL
    /// router chain can be driven end-to-end in unit tests — the
    /// end-to-end regression suite replays the exact device utterance
    /// through CommandRouter → IntentRouter → LocalBrainChain → this
    /// interpreter on the seam.
    var generateOverride: ((String) async throws -> String)?

    /// Cached LLM handle. Held as `Any?` so this file compiles without
    /// the LLM package present. Casts to `LLM.LLM` inside `#if canImport`.
    private var llmInstance: Any?

    var isAvailable: Bool {
        if generateOverride != nil { return true }
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
        // Plugin fragments are deliberately NOT composed here — the
        // on-device context (1,024 tokens) cannot fit them (see the
        // pluginRegistry property docs); `IntentPrompt.build` defaults to
        // no plugins.
        let prompt = IntentPrompt.build(transcript: clean, context: context)

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
        // Test seam — mirrors `LocalIntentInterpreter.generateOverride`.
        // The returned string still runs through the SAME empty-output
        // guard as the real runtime below, so the seam cannot mask the
        // overflow failure mode it exists to test around.
        if let generateOverride {
            Task {
                do {
                    let out = try await generateOverride(prompt)
                    if out.isEmpty {
                        emit("inference_empty_output", outcome: "failure")
                        completion(nil)
                    } else {
                        emit("inference_done", outcome: "success")
                        completion(out)
                    }
                } catch {
                    completion(nil)
                }
            }
            return
        }
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
                    if output.isEmpty {
                        // The [QUERY-FIX] bug's exact failure shape
                        // (2026-09-06): when the formatted prompt exceeds
                        // the 1,024-token context, prepareContext fails and
                        // the runtime finishes with an EMPTY output that
                        // used to be reported as inference_done success —
                        // parse("") then returned nil and every utterance
                        // fell to the generic re-prompt despite correct
                        // transcription. Report it honestly as a failure
                        // so an overflow can never masquerade as a
                        // successful (empty) inference again.
                        emit("inference_empty_output", outcome: "failure")
                        completion(nil)
                    } else {
                        emit("inference_done", outcome: "success")
                        completion(output)
                    }
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

    /// Decodes the STRUCTURED-RESPONSE CONTRACT (2026-09-06): a single
    /// JSON object with `intent` (classified intent), `response` (the
    /// spoken reply — ALWAYS non-empty; for an open-domain question it IS
    /// the answer the router speaks), `confidence`, `actionType`/
    /// `actionUrl` (when the intent needs them), and the entity/slot
    /// fields the intent uses. `intent`→`action` and `response`→`reply`
    /// map onto the existing `InterpretedCommand` model; `actionType`/
    /// `actionUrl` are validated but not carried (no current consumer —
    /// they exist for deep-link actions that land later).
    ///
    /// The pre-contract LEGACY wire shape (`action`/`reply` + the same
    /// entity fields) is still accepted so the intent→command cache's
    /// stored payloads, the cloud collapsed path's canned JSON, and the
    /// grammar-constrained fine-tuned local brain (`LocalIntentInterpreter
    /// .intentSchema`) keep working unchanged.
    ///
    /// Contract enforcement: a missing/empty `response` (or `reply`)
    /// returns nil — dispatching a command whose reply is empty would
    /// make the router speak NOTHING, a silent dead-end worse than the
    /// generic re-prompt. A missing `confidence` defaults to 0.5 (the
    /// REPHRASE band — the router re-asks instead of silently acting).
    static func parse(json raw: String?) -> InterpretedCommand? {
        guard let raw = raw else { return nil }
        // Small models often wrap output in ```json fences or add
        // explanatory prose. Extract the first {...} block.
        let extracted = Self.extractJSONObject(from: raw) ?? raw
        guard let data = extracted.data(using: .utf8) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(CommandWireObject.self, from: data)
            let actionName = decoded.intent ?? decoded.action
            guard let actionName, let action = InterpretedCommand.Action(rawValue: actionName) else {
                return nil
            }
            let reply = decoded.response ?? decoded.reply ?? ""
            guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let clamped = max(0.0, min(1.0, decoded.confidence ?? 0.5))
            return InterpretedCommand(
                action: action,
                entryId: decoded.entryId,
                contact: decoded.contact,
                time: decoded.time,
                medication: decoded.medication,
                message: decoded.message,
                callType: decoded.callType,
                requestedApp: decoded.requestedApp,
                topic: decoded.topic,
                steps: decoded.steps,
                pluginAction: decoded.pluginAction,
                pluginEntities: decoded.pluginEntities,
                confidence: clamped,
                reply: reply
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

    /// One tolerant wire shape for BOTH schema generations: canonical
    /// (`intent`/`response`/`actionType`/`actionUrl`) and legacy
    /// (`action`/`reply`). All-optional decoding lets a payload from
    /// either generation decode; `parse` then requires intent-or-action
    /// and a non-empty response-or-reply. Optional `String?` properties
    /// decode missing keys as nil (synthesized `decodeIfPresent`), so v1
    /// payloads that never carried the intent/v2 keys still decode.
    private struct CommandWireObject: Codable {
        // Canonical contract keys.
        let intent: String?
        let response: String?
        let actionType: String?
        let actionUrl: String?
        // Legacy keys (pre-2026-09 contract).
        let action: String?
        let reply: String?
        // Entity/slot fields — shared by both shapes.
        let entryId: String?
        let contact: String?
        let time: String?
        let medication: String?
        let message: String?
        let callType: String?
        let requestedApp: String?
        let topic: String?
        let steps: [String]?
        let pluginAction: String?
        let pluginEntities: [String: String]?
        let confidence: Double?
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
