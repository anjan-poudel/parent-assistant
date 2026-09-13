import Foundation
#if canImport(LLM)
import LLM
#endif

/// LLM-driven interpretation of a transcript into a structured command.
///
/// Runs LLaMA 3.2 (1B or 3B) on-device via llama.cpp. [NO-GIBBERISH]
/// (2026-09-07): the canonical output schema is NOW enforced AT THE
/// SAMPLER — `runInference` calls `LLMCore.generateWithConstraints
/// (from:jsonSchema:)` with `LlamaGrammar.commandJSONSchema`, which
/// converts the schema to a llama.cpp GBNF grammar and samples through it
/// (malformed JSON is structurally impossible). Prior to that date the
/// GBNF grammar below was defined but NEVER reached the runtime: the
/// interpreter sampled UNCONSTRAINED via `getCompletion(from:)`, which
/// explained the field's unconstrained-model output. Decoding against the
/// same schema (tolerant of BOTH the canonical contract and the legacy
/// wire shape) plus a defensive JSON-object extraction remains as
/// defense-in-depth; any parse failure still falls back to the router's
/// keyword layer. Sampling is deterministic (temperature 0, fixed seed —
/// see `OnDeviceSampling`): same prompt ⇒ same output, so a bad reply is
/// reproducible and can be pinned down instead of showing once.
///
/// The interpreter's spoken text is additionally sanity-gated at the
/// router (`ReplySanityGate`) — untrustworthy output is NEVER spoken raw;
/// it falls back to an honest re-prompt.
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

/// [LAT-EVIDENCE] (2026-09-12) A local interpreter that distinguishes a
/// FAILED inference (timeout / truncated output — both retried once by
/// the interpreter itself) from an ABSTENTION. `IntentRouter` consults
/// it after a nil local result: a failure escalates to the cloud with
/// the honest `local_failed_fallback` selection event instead of a bare
/// apology, an abstention keeps today's semantics exactly.
protocol InterpreterFailureReporting: AnyObject {
    /// The honest reason the LAST attempt failed — "inference_timeout"
    /// or "truncated_json" — cleared when the next interpret starts.
    /// Event metadata, never user copy.
    var lastInferenceFailureReason: String? { get }
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

    /// [NO-GIBBERISH] (2026-09-07) The JSON Schema handed to llama.cpp's
    /// json-schema→GBNF converter (`LLMCore.generateWithConstraints(from:
    /// jsonSchema:)`) — the canonical STRUCTURED-RESPONSE CONTRACT made
    /// structurally enforceable at the sampler, mirroring `commandJSON`
    /// above field-for-field (same keys, same 12-intent enum, same
    /// entity nullability). Keep the two in sync when the wire shape
    /// versions; the grammar test pins this mirror.
    ///
    /// Required list mirrors `properties` insertion order so the converter
    /// emits keys in the same fixed order the hand-written grammar does.
    /// `pluginEntities` is a nullable string map (values typed, so the
    /// converter builds a proper object rule — see the plugin entity
    /// grammar above).
    static let commandJSONSchema: String = """
    {
      "type": "object",
      "properties": {
        "intent": {"type": "string", "enum": ["ack_med", "call", "emergency",
          "set_reminder", "health_query", "music", "send_message", "guide",
          "create_calendar_event", "suggest_video", "query", "none"]},
        "response": {"type": "string"},
        "confidence": {"type": "number"},
        "actionType": {"type": ["string", "null"]},
        "actionUrl": {"type": ["string", "null"]},
        "entryId": {"type": ["string", "null"]},
        "contact": {"type": ["string", "null"]},
        "time": {"type": ["string", "null"]},
        "medication": {"type": ["string", "null"]},
        "message": {"type": ["string", "null"]},
        "callType": {"type": ["string", "null"]},
        "requestedApp": {"type": ["string", "null"]},
        "topic": {"type": ["string", "null"]},
        "steps": {"type": ["array", "null"], "items": {"type": "string"}},
        "pluginAction": {"type": ["string", "null"]},
        "pluginEntities": {"type": ["object", "null"],
          "additionalProperties": {"type": "string"}}
      },
      "required": ["intent", "response", "confidence", "actionType",
        "actionUrl", "entryId", "contact", "time", "medication", "message",
        "callType", "requestedApp", "topic", "steps", "pluginAction",
        "pluginEntities"]
    }
    """
}

/// [NO-GIBBERISH] Deterministic on-device sampling (2026-09-07), shared by
/// BOTH on-device brains (`LlamaCommandInterpreter` and
/// `LocalIntentInterpreter`). Before this date both brains created their
/// `LLM` handle with the vendored runtime's DEFAULTS — temperature 0.8 and
/// a RANDOM seed (LLM.swift's `LLM(from:)` defaults) — so the same prompt
/// could sample differently on every run: a reply that was gibberish once
/// could be fine the next time, which made the field's "sometimes
/// gibberish" reports unreproducible. Temperature 0 (greedy) plus a fixed
/// seed makes sampling deterministic: the same transcript produces the
/// same output, a bad output reproduces, and the determinism removes the
/// random-seed class of one-off garbage entirely. topK/topP/repeatPenalty/
/// repetitionLookback are passed explicitly (they equal the runtime
/// defaults) so a future LLM.swift default bump cannot silently change
/// on-device behavior.
enum OnDeviceSampling {
    /// Fixed seed — dated so the constant is self-explaining in logs
    /// ("GNERATING WITH SEEED" debug print in LLM.swift).
    static let fixedSeed: UInt32 = 20_260_907
    static let temperature: Float = 0
    static let topK: Int32 = 40
    static let topP: Float = 0.95
    static let repeatPenalty: Float = 1.2
    static let repetitionLookback: Int32 = 64
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
final class LlamaCommandInterpreter: CommandInterpreter, LLMInterpreterWarming,
    InterpreterFailureReporting {

    struct Config {
        let confidenceThreshold: Double
        let maxTokens: Int
        /// Inference timeout (spec §5.2, review H2). On expiry the
        /// interpreter reports nil so the router falls back to keyword
        /// matching — this is a NEW failure path, not preserved behavior.
        let timeoutSeconds: Double
        // [NO-GIBBERISH] (2026-09-07): sampling temperature/seed are NOT
        // configurable — determinism is a correctness invariant here, so
        // every interpreter samples through `OnDeviceSampling` (temp 0,
        // fixed seed) regardless of configuration.
        static let `default` = Config(confidenceThreshold: 0.7,
                                      maxTokens: 128,
                                      timeoutSeconds: 10)
    }

    private let modelStore: ModelStore
    private let observabilityBus: ObservabilityBus
    private let config: Config
    /// [LAT-EVIDENCE] The honest reason the LAST inference failed
    /// ("inference_timeout" / "inference_empty_output") — the router
    /// consults it after a nil result to escalate to the cloud instead
    /// of a bare apology. Cleared at the start of each interpret.
    private(set) var lastInferenceFailureReason: String?
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
    private(set) var preferredBaseId: ModelID
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
    You are Sahayak, a voice assistant for an elderly speaker. Reply with \
    ONLY one JSON object (no fences, no other text); its "response" must \
    be a non-empty spoken reply in the user's language.
    """

    /// Test seam: replaces the llama.cpp call entirely (same pattern as
    /// `LocalIntentInterpreter.generateOverride`). While set, the
    /// interpreter is "available" without any cached model, so the REAL
    /// router chain can be driven end-to-end in unit tests — the
    /// end-to-end regression suite replays the exact device utterance
    /// through CommandRouter → IntentRouter → LocalBrainChain → this
    /// interpreter on the seam.
    ///
    /// [NO-GIBBERISH] (2026-09-07) Signature is `(prompt, jsonSchema)` so
    /// the seam mirrors the grammar-constrained runtime call exactly: the
    /// override observes the SAME schema that reaches llama.cpp, and the
    /// grammar-wiring test pins that the schema flows to the seam. The
    /// returned string still runs through the same empty-output guard as
    /// the real runtime, so the seam cannot mask the overflow failure mode
    /// it exists to test around.
    var generateOverride: ((String, String) async throws -> String)?

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

    /// The base model this interpreter currently loads (read-only outside;
    /// swap via `switchBaseModel`). Exposed so the coordinator can align
    /// download policy with the live choice.
    var baseModelID: ModelID { preferredBaseId }

    /// The applied LoRA id, if any (read-only; test-observable so a base
    /// swap provably drops the old base's adapter).
    var activeLoRAID: ModelID? { activeLoRA }

    /// Hot-swaps the brain model (Settings "Assistant brain" picker,
    /// 2026-09-06): points inference at the new GGUF and drops the loaded
    /// llama.cpp handle + any LoRA so the NEXT inference re-loads from the
    /// new model. A swap never touches the running pipeline — the router
    /// just sees `isAvailable` flip to the new model's cache state.
    func switchBaseModel(to id: ModelID) {
        preferredBaseId = id
        llmInstance = nil
        activeLoRA = nil
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
        // [LAT-EVIDENCE] A fresh attempt starts clean — the failure
        // reason belongs to the LAST attempt only.
        lastInferenceFailureReason = nil
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

    // MARK: - Chat format (per-model family)

    /// The special-token scheme a brain model speaks. Pure data — no LLM
    /// package types — so the format choice and prompt bytes are
    /// unit-testable without the runtime linked.
    struct ChatFormat: Equatable {
        enum Kind: Equatable {
            case llama3
            case qwen3
            /// NO chat-template wrap at all: the user turn is the bare
            /// `IntentPrompt` text. This is the shape the intent fine-tunes
            /// were trained on — `train_qlora.py`'s `to_text` tokenizes the
            /// raw prompt template plus the JSON label, and the golden-corpus
            /// eval documents the matching contract ("never pass the prompt
            /// through a chat template here"). Training/inference prompt
            /// identity is a hard requirement (`IntentPrompt` doc).
            case raw
        }
        let kind: Kind
        let systemPrefix: String
        let systemSuffix: String
        let userPrefix: String
        let userSuffix: String
        let botPrefix: String
        let botSuffix: String
        let stopSequence: String
    }

    /// The framing each catalog id was MEASURED to require — one row per id
    /// the app can resolve, not a model-FAMILY guess (T-046, 2026-09-13).
    ///
    /// Before this table, `chatFormat(for:)` switched on exactly the two
    /// stock Qwen3 ids and sent everything else — including the two
    /// Qwen3-derived intent fine-tunes the picker offers, and the shipped
    /// default brain — to the LLaMA 3.2 branch, a scheme their checkpoints
    /// were never trained on.
    ///
    /// Evidence lives beside this task and is re-runnable:
    /// `tools/train-intent/src/framing_check.py` scores every id under all
    /// three candidate framings against the held-out golden corpus through
    /// the app's own decode grammar (the `commandJSONSchema` GBNF the
    /// on-device runtime samples through), recording per-row outcomes,
    /// prompt token counts against the 1,024-token context, and emergency
    /// rows per framing. Result tables:
    /// `tools/train-intent/eval/framing_summary.json`,
    /// `framing_rows.jsonl` and the applied verdicts in
    /// `framing_determination.json`.
    ///
    /// Two kinds of id appear here and the check treats them differently:
    /// the intent fine-tunes (trained on this app's own prompt contract) are
    /// decided by the measurement, while the general-purpose brains — never
    /// trained on that contract — are only checked for an outright decode
    /// failure; the golden corpus cannot certify a template change for a
    /// model it never trained, so their publisher's template stands and the
    /// numbers are recorded instead (see the determination table's
    /// `policy` field).
    ///
    /// A hidden id that a stale stored preference can still resolve is
    /// listed here too — `resolvedBrainModelID` returns any id that still
    /// has a catalog entry, so "not offered" is not "not reachable".
    static let measuredFramings: [ModelID: ChatFormat.Kind] = [
        // — offered picker brains (ModelCatalog.availableBrainEntries) —
        ModelCatalog.intentQwen4BS43: .raw,
        ModelCatalog.intentQwenS43:   .qwen3,
        ModelCatalog.qwen4BNepali:    .raw,
        ModelCatalog.qwen3_4BInstruct: .qwen3,
        ModelCatalog.qwen3_1_7BInstruct: .qwen3,
        // — hidden but still resolvable through a stored preference —
        ModelCatalog.intentNepali1B:  .raw,
        ModelCatalog.llama3_2_1B:     .llama3,
        ModelCatalog.llama3_2_3B:     .llama3
    ]

    /// The framing recorded for `id`, or nil when the id has no measured
    /// determination — see `measuredFramings` for what "measured" means and
    /// `chatFormat(for:)` for what happens to an id that lands here.
    static func measuredFraming(for id: ModelID) -> ChatFormat.Kind? {
        measuredFramings[id]
    }

    /// Which chat format the model id requires: the MEASURED determination
    /// when the id has one, else the shipped LLaMA 3.2 scheme.
    ///
    /// The fallback exists for ids the catalog keeps but this task did not
    /// measure — `intentGemma1B` (hidden, and already disqualified by the
    /// emergency hard gate; its Gemma 3 `<start_of_turn>` template is a
    /// fourth scheme `ChatFormat` cannot express, filed as its own follow-up
    /// rather than hacked in here). It is NOT a silent default for offered
    /// brains: `BrainModelSelectionTests.testEveryOfferedBrainHasAMeasuredFraming`
    /// fails for any OFFERED id that reaches it.
    static func chatFormat(for id: ModelID) -> ChatFormat {
        chatFormat(kind: measuredFramings[id] ?? .llama3)
    }

    /// The concrete format for a kind — the single place each scheme's bytes
    /// are written down.
    static func chatFormat(kind: ChatFormat.Kind) -> ChatFormat {
        switch kind {
        case .qwen3:
            return ChatFormat(
                kind: .qwen3,
                systemPrefix: "<|im_start|>system\n",
                systemSuffix: "<|im_end|>\n",
                userPrefix: "<|im_start|>user\n",
                userSuffix: "<|im_end|>\n",
                botPrefix: "<|im_start|>assistant\n",
                botSuffix: "<|im_end|>",
                stopSequence: "<|im_end|>"
            )
        case .raw:
            // No affixes at all. The system turn is deliberately NOT sent:
            // training never had one (the system content is already inside
            // the template text), so adding one would be the very
            // training/inference mismatch this table exists to remove.
            //
            // The stop sequence is the Qwen3 family EOS the fine-tunes were
            // taught to emit after the JSON label (`train_qlora.py` appends
            // it per family). It is inert on the path this interpreter
            // actually uses — `generateWithConstraints` terminates on the
            // grammar and the model's own end tokens and never consults the
            // `Template`'s stop sequence (see `LLMCore`) — but an empty
            // string here would be a landmine for the unused streaming
            // paths, so it stays explicit.
            return ChatFormat(
                kind: .raw,
                systemPrefix: "", systemSuffix: "",
                userPrefix: "", userSuffix: "",
                botPrefix: "", botSuffix: "",
                stopSequence: "<|endoftext|>"
            )
        case .llama3:
            return ChatFormat(
                kind: .llama3,
                systemPrefix: "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n",
                systemSuffix: "<|eot_id|>",
                userPrefix: "<|start_header_id|>user<|end_header_id|>\n\n",
                userSuffix: "<|eot_id|>",
                botPrefix: "<|start_header_id|>assistant<|end_header_id|>\n\n",
                botSuffix: "<|eot_id|>",
                stopSequence: "<|eot_id|>"
            )
        }
    }

    /// The raw completion prompt for a family. The LLaMA 3.2 branch is
    /// BYTE-IDENTICAL to the shipped literal (the model is tuned to this
    /// exact framing; a formatting change would silently shift its
    /// instruction-following). The Qwen3 branch mirrors Qwen3-Instruct's
    /// official chat template. The raw branch is the prompt ALONE — no
    /// wrapper, no system turn — because that is the text the fine-tunes
    /// were trained on (see `ChatFormat.Kind.raw`).
    static func formattedPrompt(prompt: String, system: String, format: ChatFormat) -> String {
        switch format.kind {
        case .llama3:
            // Exact bytes of the shipped multiline literal (verified
            // against git HEAD — one leading newline, double newlines
            // between segments, triple at the end).
            return "\n<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n"
                + "\(system)<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n"
                + "\(prompt)<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n\n"
        case .qwen3:
            // Qwen3-Instruct's official chat template shape.
            return "<|im_start|>system\n\(system)<|im_end|>\n"
                + "<|im_start|>user\n\(prompt)<|im_end|>\n"
                + "<|im_start|>assistant\n"
        case .raw:
            // Deliberately ignores `system`: training appended the label to
            // the bare template with no system turn, and `IntentPrompt.build`
            // already opens with the assistant's identity and rules. Adding
            // the system message here would re-introduce the mismatch.
            return prompt
        }
    }

    // MARK: - Warm seam ([LAT-M1])

    /// `LLMInterpreterWarming`: loads the base model's weights and
    /// allocates its context on the interpreter's own queue — NO
    /// inference — so the first utterance's `interpret` skips the load.
    /// The same outcome contract as the STT/TTS warms: never throws,
    /// honest failures. The `generateOverride` test seam stands in for
    /// the whole runtime, so it reports `.ready` without touching
    /// llama.cpp.
    func warm(completion: @escaping (WarmStartEngineResult) -> Void) {
        guard isAvailable else {
            completion(.failed(reason: "model_not_cached"))
            return
        }
        if generateOverride != nil {
            completion(.ready)
            return
        }
        inferenceQueue.async { [weak self] in
            guard let self else {
                completion(.failed(reason: "deallocated"))
                return
            }
            #if canImport(LLM)
            switch self.loadLLMHandle() {
            case .success:
                completion(.ready)
            case .failure(let error):
                completion(.failed(reason: error.reason))
            }
            #else
            completion(.failed(reason: "runtime_missing"))
            #endif
        }
    }

    // MARK: - Inference (guarded, with timeout — spec §5.2)

    #if canImport(LLM)
    /// The two honest load-failure shapes (`Result` requires an `Error`
    /// failure type; the machine reason string the warm seam reports is
    /// derived, never shown).
    private enum LLMLoadFailure: Error {
        case modelPathMissing
        case modelLoadFailed
        var reason: String {
            switch self {
            case .modelPathMissing: return "model_path_missing"
            case .modelLoadFailed: return "model_load_failed"
            }
        }
    }

    /// Loads (or reuses) the llama.cpp handle for the current base model:
    /// weights + context allocation, NO inference. Shared by the warm
    /// seam and the first inference — whichever runs first wins the load
    /// and the other reuses the cached handle. Emits the honest failure
    /// event on each failure shape (the caller maps the reason).
    private func loadLLMHandle() -> Result<LLM, LLMLoadFailure> {
        if let existing = llmInstance as? LLM {
            return .success(existing)
        }
        guard let modelURL = modelStore.path(for: preferredBaseId) else {
            emit("model_path_missing", outcome: "failure")
            return .failure(.modelPathMissing)
        }
        // 1024-token context (default 2048): our prompts are ~150
        // tokens + 128 output, and the smaller n_batch halves
        // llama.cpp's compute buffers — with Whisper resident,
        // 2048 overflowed the app's memory ceiling and crashed
        // `llama_context::output_reserve` on 6 GB devices.
        // [NO-GIBBERISH] (2026-09-07): deterministic sampling — temp 0
        // + the FIXED seed in `OnDeviceSampling` — passed at LLM
        // creation. Before this date the handle was created with
        // LLM.swift's defaults (temp 0.8, RANDOM seed), so the same
        // prompt sampled differently on every run (the unreproducible
        // one-off gibberish class). Every other parameter is explicit
        // so a future runtime default bump cannot silently change
        // behavior here. The template remains per-model (`template`
        // from the brain picker — LLaMA 3.2 and Qwen3 share this
        // call site).
        let format = Self.chatFormat(for: preferredBaseId)
        let template = Template(
            system: (format.systemPrefix, format.systemSuffix),
            user: (format.userPrefix, format.userSuffix),
            bot: (format.botPrefix, format.botSuffix),
            stopSequence: format.stopSequence,
            systemPrompt: Self.chatSystemPrompt
        )
        guard let created = LLM(from: modelURL, template: template,
                                seed: OnDeviceSampling.fixedSeed,
                                topK: OnDeviceSampling.topK,
                                topP: OnDeviceSampling.topP,
                                temp: OnDeviceSampling.temperature,
                                repeatPenalty: OnDeviceSampling.repeatPenalty,
                                repetitionLookback: OnDeviceSampling.repetitionLookback,
                                maxTokenCount: 1024) else {
            emit("model_load_failed", outcome: "failure")
            return .failure(.modelLoadFailed)
        }
        llmInstance = created
        emit("model_loaded", outcome: "success")
        return .success(created)
    }
    #endif

    private func runInference(prompt: String,
                              completion: @escaping (String?) -> Void) {
        // Test seam — mirrors `LocalIntentInterpreter.generateOverride`.
        // The returned string still runs through the SAME empty-output
        // guard as the real runtime below, so the seam cannot mask the
        // overflow failure mode it exists to test around.
        if let generateOverride {
            Task {
                do {
                    // [NO-GIBBERISH] (2026-09-07) The seam receives the
                    // same schema the real runtime call receives below, so
                    // the grammar-wiring tests can assert the schema
                    // reaches the point of the llama.cpp call.
                    let out = try await generateOverride(prompt,
                                                         LlamaGrammar.commandJSONSchema)
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
        let llm: LLM
        switch loadLLMHandle() {
        case .success(let handle):
            llm = handle
        case .failure:
            // The load helper already emitted the honest failure event
            // (model_path_missing / model_load_failed).
            completion(nil)
            return
        }

        // Per-model chat format (2026-09-06): the brain is now
        // selectable, and Qwen3 speaks a different special-token
        // scheme than LLaMA 3.2. `chatFormat(for:)` carries both —
        // the LLaMA branch is byte-identical to the shipped
        // hard-coded template.
        let format = Self.chatFormat(for: preferredBaseId)

        // LLM.swift's `getCompletion(from:)` sends the raw string with
        // no template preprocessing — the Template we passed to `LLM(from:)`
        // only gets applied by `respond(to:)`. Format manually with the
        // SELECTED BRAIN's own chat scheme (`format` comes from the
        // per-model template — LLaMA 3.2 and Qwen3 schemes both live
        // here). The runtime's `generateWithConstraints` consumes the raw
        // string, exactly like `getCompletion(from:)` did.
        let formattedPrompt = Self.formattedPrompt(
            prompt: prompt,
            system: Self.chatSystemPrompt,
            format: format
        )

        Task {
            // [NO-GIBBERISH] (2026-09-07) Grammar-constrained generation:
            // `LlamaGrammar.commandJSONSchema` is converted by llama.cpp to
            // a GBNF grammar and the sampler is chained through it (see
            // `LLMCore.generateWithConstraints`) — the canonical JSON
            // contract is STRUCTURALLY enforced at decode time, and the
            // reply text is constrained to a JSON string (no quotes,
            // backslashes or control characters can leak into it). This is
            // what replaced the pre-2026-09-07 `getCompletion(from:)`
            // unconstrained sampling call — the field's gibberish output
            // class. `.failed` covers both an EMPTY completion (the
            // [QUERY-FIX] overflow failure shape — when the prompt exceeds
            // the 1,024-token context `prepareContext` throws and the
            // runtime reports it honestly instead of an empty "success")
            // and any other runtime error; `.timedOut` is the sleep task
            // winning the race.
            enum InferenceOutcome { case success(String); case failed; case timedOut }
            await withTaskGroup(of: InferenceOutcome.self) { group in
                group.addTask {
                    do {
                        let output = try await llm.core.generateWithConstraints(
                            from: formattedPrompt,
                            jsonSchema: LlamaGrammar.commandJSONSchema)
                        return output.isEmpty ? .failed : .success(output)
                    } catch {
                        return .failed
                    }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(self.config.timeoutSeconds * 1_000_000_000))
                    // Interrupt the in-flight generation so the next
                    // utterance does not race a still-decoding context.
                    llm.stop()
                    return .timedOut
                }
                // First result wins; on timeout the sleep task returns
                // .timedOut first and the interpreter reports "not
                // confident" so the router falls back to keyword matching.
                let result = await group.next() ?? .timedOut
                group.cancelAll()
                switch result {
                case .success(let output):
                    emit("inference_done", outcome: "success")
                    completion(output)
                case .failed:
                    // The [QUERY-FIX] bug's exact failure shape
                    // (2026-09-06): when the formatted prompt exceeds
                    // the 1,024-token context, prepareContext fails and
                    // the runtime used to finish with an EMPTY output that
                    // was reported as inference_done success — parse("")
                    // then returned nil and every utterance fell to the
                    // generic re-prompt despite correct transcription.
                    // Report it honestly as a failure so an overflow can
                    // never masquerade as a successful inference again.
                    emit("inference_empty_output", outcome: "failure")
                    // [LAT-EVIDENCE] A runtime failure is a FAILURE, not
                    // an abstention — the router escalates to the cloud.
                    lastInferenceFailureReason = "inference_empty_output"
                    completion(nil)
                case .timedOut:
                    emit("inference_timeout", outcome: "failure")
                    lastInferenceFailureReason = "inference_timeout"
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
