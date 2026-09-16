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
    /// Fixed seed — dated so the constant is self-explaining in logs. The
    /// vendored runtime used to print it on every load ("GNERATING WITH
    /// SEEED: 20260907"); that debug print is gone ([CASCADE-RUNTIME],
    /// 2026-09-16), so this constant and the `model_loaded` event are the
    /// only place the seed is visible now.
    static let fixedSeed: UInt32 = 20_260_907
    static let temperature: Float = 0
    static let topK: Int32 = 40
    static let topP: Float = 0.95
    static let repeatPenalty: Float = 1.2
    static let repetitionLookback: Int32 = 64
}

/// [CASCADE-RUNTIME] (2026-09-16) How large an on-device generation context
/// must be for a SCHEMA-COMPLETE JSON to fit behind its prompt.
///
/// WHY: the vendored runtime treats `maxTokenCount` as the WHOLE context
/// (`n_ctx`, and `n_batch` with it) and its generation loop stops once
/// `n_ctx` tokens have passed THROUGH THE CONTEXT — prompt included. The
/// real output room is therefore `n_ctx − promptTokens`, and both
/// interpreters shipped `maxTokenCount: 1024` against prompts 700–1,000
/// tokens long. Twenty tokens of room is what produced the device failure
/// this fixes: a JSON cut off after three fields (`{"action": "call",
/// "entryId": null, "contact`), identically on the retry (greedy sampling
/// with a fixed seed), then `inference_truncated` → escalation. Nothing in
/// the runtime said "cut short": the loop exited off the end of its
/// `while`, so a partial JSON looked like a finished one.
///
/// WHAT is sized here: prompt ceiling (measured template + utterance +
/// this brain's framing, or the turn's own estimate when that is larger)
/// + the schema's upper bound + a safety margin, rounded up to a quantum
/// and clamped to [`minimumContextTokens`, `maximumContextTokens`]. The
/// retry's budget (`grownContextTokens`) is strictly larger, so a retry is
/// never the same allocation that just truncated.
///
/// The memory side is real and deliberate. Context sizing drives `n_batch`,
/// and with `llama_context_params.embeddings` on, llama.cpp reserves its
/// output buffer for `n_batch` tokens — the vendored `LLMCore` comment
/// records a 2048-token context overflowing a 6 GB device inside
/// `llama_context::output_reserve`. So the ceiling stays at 1536 (half of
/// that measured-bad allocation) and the encoder's weights are released
/// before the picker brain allocates its own
/// (`IntentEncoderInterpreter.unloadForCascadeEscalation`).
enum OnDeviceGenerationBudget {

    // MARK: - Prompt side

    /// The measured training/inference template — `IntentPrompt`:
    /// "696 qwen3 / 677 gemma tokens". The utterance and any framing sit on
    /// top of it.
    static let measuredTemplateTokens = 696

    /// Room for one spoken utterance after the template.
    static let utteranceAllowanceTokens = 64

    /// Chat-framing affixes for a `.raw` brain: none (T-046 — the
    /// fine-tunes were trained on the bare template with no wrapper).
    static let rawFramingTokens = 0
    /// Wrapper tokens for the schemes that do affix a chat turn (llama3 /
    /// qwen3).
    static let chatFramingTokens = 64

    /// Slack between (prompt ceiling + schema bound) and the context.
    static let safetyMarginTokens = 64

    // MARK: - Schema side (design caps, per value kind)

    /// A slot string — a name, a time, an app id, a medication.
    static let slotStringTokens = 16
    /// Free text the model SPEAKS or sends: `reply` / `response` /
    /// `message`. One Nepali sentence.
    static let freeTextValueTokens = 48
    /// A string array (`steps`) or a string map (`pluginEntities`): three
    /// entries at the slot cap, plus punctuation.
    static let collectionValueTokens = 50
    /// `"key":` plus its separating comma or brace.
    static let keyOverheadTokens = 4
    /// A `confidence` number.
    static let numberValueTokens = 4
    /// The keys whose values are spoken/sent text and earn the free-text
    /// cap; every other string field is a slot.
    static let freeTextFieldNames: Set<String> = ["reply", "response", "message"]

    // MARK: - Context bounds

    static let contextQuantum = 128
    /// Never allocate less than the shipped 1024-token context.
    static let minimumContextTokens = 1024
    /// Half of the 2048-token context the vendored runtime recorded as
    /// overflowing a 6 GB device with Whisper resident. The single knob to
    /// turn if a field device reports pressure.
    static let maximumContextTokens = 1536

    // MARK: - Prompt estimate

    /// The prompt's token count, estimated as the app estimates elsewhere
    /// (`/4` for ASCII) but counting non-ASCII at 2 bytes per token: these
    /// prompts carry Devanagari, where 4-chars-per-token badly under-counts.
    static func estimatedPromptTokens(_ prompt: String) -> Int {
        var ascii = 0
        var wide = 0
        for scalar in prompt.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { wide += 1 }
        }
        return ascii / 4 + wide / 2
    }

    /// The room the prompt is allowed: the measured template + utterance +
    /// this brain's framing, or the turn's own estimate when that is larger.
    /// `prompt` nil = the floor — what `warm()` sizes its context from.
    static func promptCeilingTokens(prompt: String? = nil, framingTokens: Int) -> Int {
        let floor = measuredTemplateTokens + utteranceAllowanceTokens + framingTokens
        guard let prompt, !prompt.isEmpty else { return floor }
        return max(floor, estimatedPromptTokens(prompt))
    }

    /// The framing allowance for a brain's chat scheme. (`ChatFormat` is
    /// the interpreter's own nested type, hence the qualified spelling —
    /// the same one `framingTokens(forBrain:)` below uses.)
    static func framingTokens(for kind: LlamaCommandInterpreter.ChatFormat.Kind) -> Int {
        kind == .raw ? rawFramingTokens : chatFramingTokens
    }

    // MARK: - Schema upper bound (computed from the schema text)

    /// One top-level property of a JSON-schema object.
    struct SchemaField: Equatable {
        enum Kind: Equatable {
            /// A string enum; carries its longest literal's length in
            /// characters (the sampler can emit any one of them).
            case enumeration(longestLiteral: Int)
            case number
            /// A string — a slot, or free text when the key says so.
            case string
            /// An array or a map.
            case collection
        }
        let name: String
        let kind: Kind
    }

    /// The `properties` of `schema`, in declaration order.
    ///
    /// Deliberately a small hand-rolled scan rather than a JSON decoder:
    /// this runs on the inference path, and anything it cannot classify
    /// falls back to the SLOT cap (a bounded over-reservation) rather than
    /// failing. An unparsable schema yields no fields, and
    /// `schemaUpperBoundTokens` then reserves one free-text value — never
    /// zero.
    static func schemaFields(in schema: String) -> [SchemaField] {
        let characters = Array(schema)
        guard let bodyStart = propertiesBodyStart(in: characters) else { return [] }

        var keys: [(name: String, literalStart: Int, valueStart: Int)] = []
        var index = bodyStart
        var depth = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                var end = index + 1
                var literal = ""
                while end < characters.count, characters[end] != "\"" {
                    if characters[end] == "\\", end + 1 < characters.count {
                        literal.append(characters[end + 1])
                        end += 2
                        continue
                    }
                    literal.append(characters[end])
                    end += 1
                }
                let afterLiteral = end + 1
                if depth == 0,
                   let colon = firstNonSpace(in: characters, from: afterLiteral),
                   characters[colon] == ":" {
                    keys.append((literal, index, colon + 1))
                }
                index = afterLiteral
                continue
            }
            if character == "{" || character == "[" {
                depth += 1
            } else if character == "}" || character == "]" {
                depth -= 1
                if depth < 0 { break }   // the `properties` object closed
            }
            index += 1
        }

        return keys.enumerated().map { offset, key in
            let end = offset + 1 < keys.count ? keys[offset + 1].literalStart : characters.count
            let value = String(characters[key.valueStart..<max(key.valueStart, end)])
            return SchemaField(name: key.name, kind: kind(ofFieldValue: value))
        }
    }

    /// The most tokens a schema-complete JSON can need: every top-level
    /// field present, each at the design cap for its kind, plus its key.
    static func schemaUpperBoundTokens(for schema: String) -> Int {
        let fields = schemaFields(in: schema)
        guard !fields.isEmpty else { return freeTextValueTokens + keyOverheadTokens }
        var total = 2   // the surrounding braces
        for field in fields {
            total += keyOverheadTokens + valueTokens(for: field)
        }
        return total
    }

    static func valueTokens(for field: SchemaField) -> Int {
        switch field.kind {
        case .enumeration(let longestLiteral):
            return max(2, longestLiteral / 3 + 2)   // the quotes + the literal
        case .number:
            return numberValueTokens
        case .string:
            return freeTextFieldNames.contains(field.name) ? freeTextValueTokens : slotStringTokens
        case .collection:
            return collectionValueTokens
        }
    }

    static func kind(ofFieldValue value: String) -> SchemaField.Kind {
        if value.contains("\"enum\"") {
            return .enumeration(longestLiteral: longestQuotedLiteral(in: value))
        }
        if value.contains("\"array\"") || value.contains("\"object\"") {
            return .collection
        }
        if value.contains("\"number\"") || value.contains("\"integer\"") {
            return .number
        }
        return .string
    }

    /// The longest quoted literal in a fragment — the widest member of an
    /// enum. Never below 1, so an unparsable list still costs something.
    static func longestQuotedLiteral(in fragment: String) -> Int {
        var longest = 0
        var current: Int?
        var escaped = false
        for character in fragment {
            guard let length = current else {
                if character == "\"" { current = 0 }
                continue
            }
            if escaped {
                escaped = false
                current = length + 1
            } else if character == "\\" {
                escaped = true
                current = length + 1
            } else if character == "\"" {
                current = nil
                longest = max(longest, length)
            } else {
                current = length + 1
            }
        }
        return max(longest, 1)
    }

    // MARK: - Context sizing

    static func roundedUp(_ tokens: Int) -> Int {
        guard tokens > 0 else { return contextQuantum }
        return ((tokens + contextQuantum - 1) / contextQuantum) * contextQuantum
    }

    static func clamped(_ tokens: Int) -> Int {
        min(maximumContextTokens, max(minimumContextTokens, tokens))
    }

    /// The context one turn requires. `prompt` nil = the floor, so `warm()`
    /// and a regular turn size their handle the same way.
    static func contextTokens(prompt: String? = nil,
                              schema: String,
                              framingTokens: Int) -> Int {
        let required = promptCeilingTokens(prompt: prompt, framingTokens: framingTokens)
            + schemaUpperBoundTokens(for: schema)
            + safetyMarginTokens
        return clamped(roundedUp(required))
    }

    /// The RETRY's budget: strictly larger than `current`, so the retry is
    /// never the same allocation that just truncated, and never larger than
    /// the context ceiling.
    static func grownContextTokens(_ current: Int, schema: String) -> Int {
        let grown = max(roundedUp(current + schemaUpperBoundTokens(for: schema)),
                        current + contextQuantum)
        return clamped(grown)
    }

    /// Folds in a brain's framing when it is known by id, ignoring the
    /// stored preference's absence (the floor framing is the conservative
    /// one for the schemes that do add affixes).
    static func framingTokens(forBrain id: ModelID) -> Int {
        framingTokens(for: LlamaCommandInterpreter.chatFormat(for: id).kind)
    }

    // MARK: - Scan helpers

    private static func propertiesBodyStart(in characters: [Character]) -> Int? {
        let needle = Array("\"properties\"")
        guard characters.count >= needle.count else { return nil }
        var start = 0
        while start <= characters.count - needle.count {
            var offset = 0
            while offset < needle.count, characters[start + offset] == needle[offset] { offset += 1 }
            if offset == needle.count,
               // The KEY is followed by its colon and THEN the object
               // (`"properties": {`). Skipping only the whitespace compared
               // the colon against `{`, so every real schema read as
               // unparsable and the bound silently fell back to a single
               // free-text value — the schema was sized from a number that
               // did not depend on the schema at all.
               let colon = firstNonSpace(in: characters, from: start + needle.count),
               characters[colon] == ":",
               let bodyStart = firstNonSpace(in: characters, from: colon + 1),
               characters[bodyStart] == "{" {
                return bodyStart + 1
            }
            start += 1
        }
        return nil
    }

    private static func firstNonSpace(in characters: [Character], from index: Int) -> Int? {
        var index = index
        while index < characters.count {
            if !characters[index].isWhitespace { return index }
            index += 1
        }
        return nil
    }
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
    /// [TURN-TIMING-BREAKDOWN] Turn-scoped stage stopwatch for the picker
    /// brain's two stages (prompt build / inference). Nil — no build
    /// without `INTENT_ENCODER` ([ENCODER-ALWAYS-ON] the default one has
    /// it) — makes each
    /// measurement a nil check around the UNCHANGED calls. Instrumentation
    /// only: no prompt byte, no sampling parameter and no decision reads it.
    private let timingRecorder: TurnTimingRecorder?
    /// [PIPELINE-TRACE] The debug trace's recorder — the picker brain's
    /// two stages written out in full (the prompt that went in, the JSON
    /// that came back, the FINAL LLM round-trip's own milliseconds). Nil
    /// (the default, and every non-gated build) makes every call below a
    /// nil check. Instrumentation only: no prompt byte, no sampling
    /// parameter and no decision reads a row.
    private let traceRecorder: PipelineTraceRecorder?
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

    /// [CASCADE-RUNTIME] The context the cached handle was allocated with
    /// (`OnDeviceGenerationBudget`). A turn whose budget exceeds it
    /// re-creates the handle rather than truncating inside it.
    private var allocatedContextTokens = 0

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
         pluginRegistry: PluginRegistry? = nil,
         timingRecorder: TurnTimingRecorder? = nil,
         traceRecorder: PipelineTraceRecorder? = nil) {
        self.modelStore = modelStore
        self.observabilityBus = observabilityBus
        self.preferredBaseId = preferredBaseId
        self.config = config
        self.pluginRegistry = pluginRegistry
        self.timingRecorder = timingRecorder
        self.traceRecorder = traceRecorder
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
            // [PIPELINE-TRACE] The picker never ran — no cached brain
            // model. Both of its stages are marked off (never omitted)
            // with the reason the row can act on.
            traceRecorder?.recordOff([.pickerPrompt, .pickerInference],
                                     reason: "picker_unavailable")
            DispatchQueue.main.async { completion(nil) }
            return
        }
        // Sanitise BEFORE the transcript reaches any prompt string
        // (NFR-013 / review H3 / spec §5.2).
        let clean = InputSanitiser.sanitise(transcript, level: .quarantine)
        guard !clean.isEmpty else {
            // [PIPELINE-TRACE] Same shape as the encoder's abstention
            // token for the same condition: there is nothing to prompt
            // with.
            traceRecorder?.recordOff([.pickerPrompt, .pickerInference],
                                     reason: "empty_after_sanitise")
            DispatchQueue.main.async { completion(nil) }
            return
        }
        // Plugin fragments are deliberately NOT composed here — the
        // on-device context (1,024 tokens) cannot fit them (see the
        // pluginRegistry property docs); `IntentPrompt.build` defaults to
        // no plugins.
        //
        // [TURN-TIMING-BREAKDOWN] `picker_prompt_build` — the prompt
        // construction only (sanitisation above is deliberately outside
        // the span: it is a guard keystone, not prompt assembly, and it
        // runs before the transcript can reach any prompt string).
        // [PIPELINE-TRACE] The row opens on the sanitised input and
        // closes with the built prompt's SIZE — an estimate, because no
        // tokenizer in this process measures the llama.cpp prompt (see
        // `PipelineTraceSummary.estimatedPromptTokenCount`) — which is
        // the number that explains an overflow.
        let promptTrace = traceRecorder?.start(
            .pickerPrompt,
            input: PipelineTraceSummary.text(clean))
        let prompt = timingRecorder.measure(.pickerPromptBuild) {
            IntentPrompt.build(transcript: clean, context: context)
        }
        promptTrace?.finish(
            output: PipelineTraceSummary.estimatedPromptTokens(prompt),
            decision: "built",
            tokenCount: PipelineTraceSummary.estimatedPromptTokenCount(prompt))

        inferenceQueue.async { [weak self] in
            // [TURN-TIMING-BREAKDOWN] `picker_inference` — opened when the
            // round-trip starts and closed by the completion, which
            // `runInference` calls exactly once on every path (seam,
            // success, empty output, timeout). The first picker turn's
            // llama.cpp model load lands inside this span — the same
            // honest conflation the tracer's coarse `llm` stage carries.
            let inferenceSpan = self?.timingRecorder?.start(.pickerInference)
            // [PIPELINE-TRACE] The FINAL LLM's own row: same edges as the
            // timing span above, so the milliseconds the card shows for
            // `picker LLM` are exactly the ones the breakdown reports.
            let traceSpan = self?.traceRecorder?.start(
                .pickerInference,
                input: PipelineTraceSummary.estimatedPromptTokens(prompt))
            self?.runInference(prompt: prompt) { json in
                inferenceSpan?.finish()
                let parsed = Self.parse(json: json)
                let failure = self?.lastInferenceFailureReason
                let threshold = self?.config.confidenceThreshold ?? 0.7
                traceSpan?.finish(
                    output: Self.traceSummary(of: parsed, failure: failure),
                    decision: Self.traceDecision(of: parsed, threshold: threshold,
                                                 failure: failure),
                    tokenCount: PipelineTraceSummary.estimatedPromptTokenCount(prompt))
                if let p = parsed, p.confidence < threshold {
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
    ///
    /// INHERITED ROW (2026-09-14): `intentQwen4BSlotCanon` (the v16
    /// slot-canonical retrain) has not been through `framing_check.py`
    /// itself yet, so its row is the `.raw` determination of the seed-43
    /// 4B it retrains — the same `train_qlora.py` bare-prompt training
    /// contract, which is what `.raw` encodes. Re-run the check on the v16
    /// artifact when it is published and replace the inherited row with
    /// its own measurement; the offered-brain test
    /// (`BrainModelSelectionTests`) requires SOME row, and the LLaMA 3.2
    /// fallback would mis-frame it.
    static let measuredFramings: [ModelID: ChatFormat.Kind] = [
        // — offered picker brains (ModelCatalog.availableBrainEntries) —
        ModelCatalog.intentQwen4BSlotCanon: .raw,   // inherited (see above)
        ModelCatalog.intentQwenS43:   .qwen3,
        ModelCatalog.qwen4BNepali:    .raw,
        ModelCatalog.qwen3_4BInstruct: .qwen3,
        ModelCatalog.qwen3_1_7BInstruct: .qwen3,
        // — hidden but still resolvable through a stored preference —
        // The seed-43 4B (superseded by the slot-canonical retrain above):
        // its `.raw` row is the T-046 measurement of the shipped v15
        // Q3_K_M artifact — same bare-prompt training contract, kept so a
        // stale stored preference is not mis-framed.
        ModelCatalog.intentQwen4BS43: .raw,
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
    ///
    /// [CASCADE-RUNTIME] (2026-09-16) The context is sized from the TURN's
    /// prompt and the JSON schema's upper bound
    /// (`OnDeviceGenerationBudget`), not the fixed 1024 it used to be. That
    /// fixed context is the truncation defect: `respond`-era prompts plus
    /// the answer shared 1024 tokens, so a long turn left the sampler a
    /// handful of tokens and returned JSON cut mid-value as though it were
    /// complete. A prompt that needs a LARGER context than the cached
    /// handle has re-creates the handle (the old one is released first, so
    /// growth never doubles residency) and says so in the event metadata.
    /// `warm()` passes no prompt and gets the floor, so it never grows the
    /// handle for a turn that has not happened.
    private func loadLLMHandle(prompt: String? = nil) -> Result<LLM, LLMLoadFailure> {
        let format = Self.chatFormat(for: preferredBaseId)
        let requiredContext = OnDeviceGenerationBudget.contextTokens(
            prompt: prompt,
            schema: LlamaGrammar.commandJSONSchema,
            framingTokens: OnDeviceGenerationBudget.framingTokens(for: format.kind))
        if let existing = llmInstance as? LLM, allocatedContextTokens >= requiredContext {
            return .success(existing)
        }
        guard let modelURL = modelStore.path(for: preferredBaseId) else {
            emit("model_path_missing", outcome: "failure")
            return .failure(.modelPathMissing)
        }
        if llmInstance != nil {
            emit("model_context_grown", outcome: "info",
                 metadata: ["from_tokens": "\(allocatedContextTokens)",
                            "to_tokens": "\(requiredContext)"])
            llmInstance = nil
            allocatedContextTokens = 0
        }
        // [CASCADE-RUNTIME] The context budget, not a constant: the prompt
        // ceiling (measured template + utterance + this brain's framing)
        // plus the schema-complete JSON's upper bound plus a margin — see
        // `OnDeviceGenerationBudget` for the numbers and for the memory
        // reason the ceiling is 1536 rather than the 2048 this call site
        // crashed 6 GB devices with.
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
        // `.raw` note (T-046): the empty affixes make this Template render
        // "system + user" with no wrapper, while `formattedPrompt` — the
        // path the interpreter actually uses — sends the user turn ALONE
        // (`systemPrompt` is deliberately dropped there; the fine-tunes
        // never saw a system turn). The Template is inert on the
        // `generateWithConstraints` path (`LLMCore` samples the string we
        // hand it and never applies this template), so the two agree in
        // production. It becomes a real inconsistency only if a future
        // path calls `respond(to:)`/`getCompletion(from:)` for a `.raw`
        // brain — route those through `formattedPrompt` first.
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
                                maxTokenCount: Int32(requiredContext)) else {
            emit("model_load_failed", outcome: "failure")
            return .failure(.modelLoadFailed)
        }
        llmInstance = created
        allocatedContextTokens = requiredContext
        emit("model_loaded", outcome: "success",
             metadata: ["context_tokens": "\(requiredContext)"])
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

        #if canImport(LLM)
        let llm: LLM
        // [CASCADE-RUNTIME] The handle is sized from THIS prompt: see
        // `loadLLMHandle(prompt:)`. The load happens after formatting so a
        // long utterance can grow the context before the first decode
        // instead of being cut off inside it.
        switch loadLLMHandle(prompt: formattedPrompt) {
        case .success(let handle):
            llm = handle
        case .failure:
            // The load helper already emitted the honest failure event
            // (model_path_missing / model_load_failed).
            completion(nil)
            return
        }

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
            // [CASCADE-RUNTIME] `incomplete` is the honest failure shape the
            // runtime used to hide: a generation that ended (on the context
            // bound, or on an end token) with a JSON value still open. Both
            // are reported as a failure reason so the chain escalates rather
            // than treating a half-JSON as an abstention.
            enum InferenceOutcome {
                case success(String)
                case failed
                case incomplete(String)
                case timedOut
            }
            await withTaskGroup(of: InferenceOutcome.self) { group in
                group.addTask {
                    do {
                        let generation = try await llm.core.generateConstrained(
                            from: formattedPrompt,
                            jsonSchema: LlamaGrammar.commandJSONSchema,
                            prematureEndTokenPolicy: .completeJSON)
                        guard !generation.output.isEmpty else { return .failed }
                        if generation.termination == .endToken,
                           !LLMCore.isCompleteJSONValue(generation.output) {
                            return .incomplete("premature_stop")
                        }
                        return .success(generation.output)
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
                case .incomplete(let reason):
                    // [CASCADE-RUNTIME] The model stopped with the JSON
                    // still open: the sampler skipped its end tokens up to
                    // the bound and it stopped there anyway. Hand the text
                    // to the parser as before, but say it failed — a
                    // half-JSON parsed as "no command" is exactly the
                    // silent-failure class the escalation exists for.
                    emit("inference_truncated", outcome: "failure",
                         metadata: ["reason": reason])
                    lastInferenceFailureReason = "inference_truncated"
                    completion(nil)
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

    // MARK: - Pipeline trace ([PIPELINE-TRACE]) summaries

    /// `set_reminder 0.82 reply=…` — the FINAL LLM's answer, action and
    /// confidence first and the spoken reply behind it (bounded by
    /// `PipelineTraceSummary.text`). The card may name the reply — it is
    /// the same on-device posture as the "Last correction" line — while
    /// the RELEASE console line beside it carries the decision only.
    static func traceSummary(of command: InterpretedCommand?,
                             failure: String?) -> String {
        guard let command else {
            guard let failure else { return "no command" }
            return PipelineTraceSummary.text("no command (\(failure))")
        }
        var text = "\(command.action.rawValue) "
            + "\(PipelineTraceSummary.score(command.confidence))"
        if !command.reply.isEmpty { text += " reply=\(command.reply)" }
        return PipelineTraceSummary.text(text)
    }

    /// `command` / `abstained(low_confidence)` / `failed(<reason>)` —
    /// closed vocabulary: the picker's own threshold gate applied, or the
    /// runtime's failure token when nothing parsed. Token-only, because a
    /// Release console prints this field.
    static func traceDecision(of command: InterpretedCommand?,
                              threshold: Double,
                              failure: String?) -> String {
        if let command {
            return command.confidence < threshold
                ? "abstained(low_confidence)" : "command"
        }
        guard let failure else { return "abstained(no_command)" }
        return "failed(\(failure))"
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
    private func emit(_ eventType: String, outcome: String,
                      metadata: [String: String] = [:]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "llama_interpreter",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: metadata
        ))
    }
}
