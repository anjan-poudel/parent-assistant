import Foundation

/// [CNR T-168 / OD-5, design-l1 §9] The cloud chat generation config.
///
/// The reviewed, explicit chat temperature: `0.3` — parity with the
/// on-device chat value (FR-CNR-003 / OD-1) so the two paths hold ONE style
/// contract instead of drifting in perceived register. Set ONLY on the chat
/// call (`GeminiCommandInterpreter.respondToChat`); every other Gemini call
/// site (voice transcription, the translation tier, the command `interpret`
/// path, plugins, vision) sends the shipped shape with no sampling
/// parameter at all — the value in the code IS the reviewed decision
/// (FR-CNR-011).
enum GeminiChatConfig {
    /// Cloud chat temperature, equal to the on-device chat value.
    static let temperature: Double = 0.3
}

/// LLM-driven intent interpretation via the Gemini API (v2 pivot) —
/// replaces `LlamaCommandInterpreter` as `CommandRouter`'s interpreter.
/// Conforms to the same `CommandInterpreter` protocol, decodes into the
/// same `InterpretedCommand` shape, and reuses
/// `LlamaCommandInterpreter.parse(json:)` for JSON extraction/validation —
/// the wire shape didn't need to change, only what produces it.
///
/// Sits behind `CommandRouter` exactly like the LLaMA path did: the
/// deterministic keyword layer is still tried FIRST for the closed
/// safety-critical vocabulary (see `CommandRouter.route`), and this is the
/// fallback/enrichment layer for open-domain interpretation. On any
/// failure (network, timeout, low confidence, malformed JSON) this
/// reports `nil`, and the router falls back to keyword matching — the
/// same "new failure path" pattern `LlamaCommandInterpreter` already used
/// for its inference timeout. The ONE exception is the daily cost cap
/// (`GeminiClientError.dailyCapReached`): that is not a comprehension
/// failure, and reporting nil would make the router claim "I didn't
/// understand" — so the cap completes with a deterministic `.none`
/// command carrying the localized cap message instead (see `interpret`).
///
/// [GEMINI-SOLIDIFY] (2026-09-18) Every failure is additionally reported
/// through `CloudFailureReporting`: the failure CLASS is recorded on the
/// way out, and `CommandRouter` reads it if the whole chain bottoms out,
/// so the user hears the honest reason (no network / rate limit / bad
/// answer) instead of the generic "I didn't understand" re-prompt — which
/// would be a lie about what actually happened.
///
/// [CNR T-168] It also conforms to `ChatResponding` (`respondToChat`): the
/// cloud chat lane's responder, answering a chat turn with the shared chat
/// prompt, the spec-authored persona and the explicit chat temperature.
final class GeminiCommandInterpreter: CommandInterpreter, ChatResponding, CloudFailureReporting {

    /// [CNR T-168 / FR-CNR-002] The cloud reply persona — re-authored from
    /// the style spec (`tools/train-intent/seeds/nepali-chat-style-spec`:
    /// its `register` and `ai_isms` rule text, distilled into the spec's
    /// `persona_clause`), NOT from the on-device prompt text. The spec's
    /// clause is embedded byte-identically on its own line inside this
    /// minimal transport wrapper (role + the answer's language); T-170's
    /// mirror check byte-compares that clause against the spec, so the
    /// local and cloud personas cannot drift.
    ///
    /// The clause, cited the way the spec's own drift check reads it (run
    /// `python3 tools/train-intent/src/style_spec.py --check-consumers
    /// <this file>`):
    ///
    /// @style-spec-section: persona_clause
    /// तपाईं with honorific verbs (हजुर, भन्नुभयो, गर्नुभयो) — never तिमी; at most TWO short sentences, ONE idea each; at most one particle (है, नि, ल, ला, अनि, हुन्छ नि); health and tech nouns stay as spoken in Nepali (प्रेसर, डाक्टर, मेडिसिन); numbers, times, money and percents as words, never symbols; never a list, never repeat their words, never speak as an AI, no canned service phrases.
    /// @style-spec-section-end: persona_clause
    ///
    /// Sent as the API's system instruction — for the chat call (the chat
    /// persona) and for the command `interpret` call (the same upgraded
    /// persona; `interpret()`'s code is unchanged and its request SHAPE —
    /// no temperature parameter ever — is pinned byte-for-byte by
    /// `CloudChatResponderTests`).
    static let replyPersona = """
    You are Sahayak, a warm voice companion for an elderly Nepali speaker. Answer in the speaker's own language; a Nepali answer keeps this register exactly:
    तपाईं with honorific verbs (हजुर, भन्नुभयो, गर्नुभयो) — never तिमी; at most TWO short sentences, ONE idea each; at most one particle (है, नि, ल, ला, अनि, हुन्छ नि); health and tech nouns stay as spoken in Nepali (प्रेसर, डाक्टर, मेडिसिन); numbers, times, money and percents as words, never symbols; never a list, never repeat their words, never speak as an AI, no canned service phrases.
    """

    struct Config {
        let confidenceThreshold: Double
        static let `default` = Config(confidenceThreshold: 0.7)
    }

    private let client: GeminiClient
    private let observabilityBus: ObservabilityBus
    private let config: Config
    /// Optional — when set, prompt composition includes applicable
    /// plugins' intent fragments (see `IntentPrompt.build`). Nil keeps
    /// the pre-plugin behavior exactly.
    private let pluginRegistry: PluginRegistry?

    // MARK: - CloudFailureReporting

    /// The classified failure of the most recent cloud attempt. Main
    /// queue by contract (the interpreter's completions land on main;
    /// `clearCloudFailure` runs at chain entry, also main) — the same
    /// confinement rule `lastInferenceFailureReason` holds on the local
    /// interpreters.
    private(set) var lastCloudFailureClass: GeminiFailureClass?

    func clearCloudFailure() {
        lastCloudFailureClass = nil
    }

    var isAvailable: Bool { client.isAvailable }

    init(client: GeminiClient, observabilityBus: ObservabilityBus,
         config: Config = .default, pluginRegistry: PluginRegistry? = nil) {
        self.client = client
        self.observabilityBus = observabilityBus
        self.config = config
        self.pluginRegistry = pluginRegistry
    }

    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        // A fresh attempt starts clean (same rule as
        // `lastInferenceFailureReason` on the local interpreters).
        lastCloudFailureClass = nil
        guard isAvailable else {
            // Defensive honesty: the ladder never asks an unavailable
            // interpreter, but if one is asked, the bottom of the chain
            // must say WHY the cloud did not answer.
            lastCloudFailureClass = .notConfigured
            DispatchQueue.main.async { completion(nil) }
            return
        }
        // Sanitise BEFORE the transcript reaches any prompt string
        // (constitution NFR-013 — same policy as the LLaMA path).
        let clean = InputSanitiser.sanitise(transcript, level: .quarantine)
        guard !clean.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        #if DEBUG
        // Debug-build-only, per explicit request while diagnosing a live
        // bug (2026-09-04) — never compiled into Release. Logs what's
        // ACTUALLY sent (post-sanitisation) vs. the raw transcript, since
        // InputSanitiser could itself be the bug.
        if clean != transcript {
            print("[gemini_interpreter][DEBUG] sanitised transcript changed: raw=\"\(transcript)\" clean=\"\(clean)\"")
        }
        #endif

        let activePlugins = pluginRegistry?.activePlugins(
            for: Locale(identifier: context.userLanguageHint)) ?? []
        let prompt = IntentPrompt.build(transcript: clean, context: context,
                                        activePlugins: activePlugins)
        Task { [weak self] in
            guard let self else { return }
            do {
                // [INTENT-TOOLS] (2026-09-07) Web-search grounding is ON
                // for the cloud brain's interpretation by default: this
                // class IS the cloud-only interpreter, and its questions
                // are exactly the open-domain ones Google Search exists
                // for (live weather, "कुन डाक्टर राम्रो छ?", news).
                // Gemini decides per question whether to search
                // (observable via `intent_tool_websearch` grounded vs
                // not_used), and the cost governor counts each attempt
                // once at the transport boundary — no bypass.
                let raw = try await self.client.generateJSON(
                    prompt: prompt,
                    useSearchGrounding: true,
                    // [REPLY-POLISH] The persona block travels as the
                    // API's system instruction — the intent prompt stays
                    // byte-identical, the reply style is the cloud's own
                    // contract.
                    systemInstruction: Self.replyPersona)
                #if DEBUG
                print("[gemini_interpreter][DEBUG] raw JSON=\"\(raw)\"")
                #endif
                let parsed = LlamaCommandInterpreter.parse(json: raw)
                #if DEBUG
                print("[gemini_interpreter][DEBUG] parsed action=\(parsed?.action.rawValue ?? "nil") "
                      + "confidence=\(parsed?.confidence ?? -1) reply=\"\(parsed?.reply ?? "nil")\"")
                #endif
                self.emit("interpret_done", outcome: parsed == nil ? "parse_failed" : "success")
                await MainActor.run {
                    if let parsed, parsed.confidence < self.config.confidenceThreshold {
                        completion(nil)
                    } else {
                        completion(parsed)
                    }
                }
            } catch {
                // T-050/B2: content-free code, never the error's
                // description (it embeds the failing URL — see
                // `ErrorCodeMapper`).
                self.emit("interpret_failed", outcome: "failure",
                          errorCode: ErrorCodeMapper.code(for: error))
                // [GEMINI-SOLIDIFY] Report the CLASS for the chain's
                // bottom-out honesty line — recorded whatever the
                // outcome below, so the report is never a guess.
                self.lastCloudFailureClass = GeminiFailureClass.classify(error)
                await MainActor.run {
                    guard let geminiError = error as? GeminiClient.GeminiClientError,
                          case .dailyCapReached = geminiError else {
                        completion(nil)
                        return
                    }
                    // Honesty at the cap (fix 2026-09-06): the day's
                    // Gemini budget is exhausted — a COMPREHENSION failure
                    // this is not, so completing nil would send the router
                    // to its generic "I didn't understand" re-prompt and
                    // lie about why nothing happened. Complete with a
                    // deterministic `.none` command (confidence 1.0 → the
                    // accept band, so `IntentRouter`'s band policy passes
                    // it through final) whose reply is the localized cap
                    // message; `CommandRouter` speaks it verbatim.
                    let locale = Locale(identifier: context.userLanguageHint)
                    let reply = L10n.str("router.capReached", locale: locale)
                    completion(InterpretedCommand(
                        action: .none, entryId: nil, contact: nil, time: nil,
                        medication: nil, message: nil, callType: nil,
                        requestedApp: nil, confidence: 1.0, reply: reply))
                }
            }
        }
    }

    // MARK: - ChatResponding ([CNR] T-168)

    /// [CNR T-168 / FR-CNR-002, FR-CNR-010, FR-CNR-011, FR-CNR-012] The
    /// cloud chat lane's responder — the `ChatResponding` counterpart of
    /// `interpret` for SMALL-TALK turns (a greeting, thanks, a goodbye,
    /// how they feel).
    ///
    /// Pipeline: `InputSanitiser` (the SAME shipping policy and level as
    /// `interpret`, `.quarantine`) → `IntentPrompt.buildChat` → the
    /// spec-authored `replyPersona` as the API's system instruction →
    /// `generateJSON` with the explicit chat `GenerationConfig`
    /// (`GeminiChatConfig.temperature`, OD-5). Grounding stays a property
    /// of the INTERPRETATION call: a chat turn carries no search tool.
    ///
    /// Egress scope (FR-CNR-010): what leaves is the sanitised transcript
    /// (rendered into the prompt by the chat template) plus the persona
    /// system instruction — and nothing else. There is exactly ONE
    /// content, this turn (no history); `pendingMedications` is the one
    /// intent-path context field the chat template never renders and it
    /// is constructed AWAY below so it cannot become reachable through a
    /// future template change; plugins are never composed (the chat
    /// builder takes none, and this path never consults the registry).
    /// The cost governor and the header-only key are inherited unchanged
    /// from `GeminiClient.send` — no bypass exists on this path.
    ///
    /// Failure semantics mirror `interpret` where the shapes agree and
    /// differ only where the chat contract must:
    ///  - no usable key → `nil`, `.notConfigured`, WITHOUT any network
    ///    call (and without even building a prompt).
    ///  - an empty-after-sanitise transcript → `nil` (nothing was
    ///    attempted; no failure CLASS is invented).
    ///  - a malformed, empty, or slot-bearing cloud answer → `nil`,
    ///    `.invalidResponse` — never a fabricated or partial reply. The
    ///    turn's same-turn fallback is the router's (T-175), so this
    ///    responder never speaks a substitute of its own. A daily-cap
    ///    error maps the same way here (plain classified `nil`): the
    ///    honest cap COMMAND is a property of the interpreter lane, not
    ///    of a chat turn.
    ///  - no confidence gate: the local chat shape deliberately
    ///    completes below its floor (the delivery layer's honest line —
    ///    a low-confidence chat answer is still a chat answer, never a
    ///    command-ladder fall-through), and the cloud lane keeps that
    ///    contract identical. Only the SHAPE is gated here: a non-nil
    ///    result must be `.chat` (a chat turn never executes).
    ///  - completion runs on the main queue (the `ChatResponding`
    ///    contract).
    func respondToChat(transcript: String,
                       context: InterpreterContext,
                       completion: @escaping (InterpretedCommand?) -> Void) {
        // A fresh attempt starts clean (same rule as `interpret`).
        lastCloudFailureClass = nil
        guard isAvailable else {
            // Defensive honesty, same as `interpret`: the ladder never
            // asks an unavailable responder, but if one is asked, the
            // bottom of the chain must say WHY the cloud did not answer —
            // and an unconfigured client must never have made a network
            // call by the time it says so.
            lastCloudFailureClass = .notConfigured
            DispatchQueue.main.async { completion(nil) }
            return
        }
        // Same sanitiser policy/level as `interpret` (constitution
        // NFR-013): the transcript is neutralised BEFORE it can reach
        // the chat prompt string.
        let clean = InputSanitiser.sanitise(transcript, level: .quarantine)
        guard !clean.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        // Egress cut (FR-CNR-010): only what the chat template renders
        // travels. `pendingMedications` is dropped here — the builder
        // never reads it, and constructing the context without it keeps
        // the dose list unreachable even if the template changes; the
        // guarded `addressAs` term is part of the chat template by design
        // (§6.3, byte-mirrored by T-170), exactly as the local chat path
        // passes it.
        let chatContext = InterpreterContext(pendingMedications: [],
                                             userLanguageHint: context.userLanguageHint,
                                             addressAs: context.addressAs)
        let prompt = IntentPrompt.buildChat(transcript: clean, context: chatContext)
        Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await self.client.generateJSON(
                    prompt: prompt,
                    // Grounding is an interpretation-call property; a
                    // chat turn offers no search tool.
                    useSearchGrounding: false,
                    systemInstruction: Self.replyPersona,
                    temperature: GeminiChatConfig.temperature)
                guard let parsed = LlamaCommandInterpreter.parse(json: raw),
                      parsed.action == .chat else {
                    // Malformed or empty (parse → nil), or a slot-bearing
                    // command off a prompt that never taught slots: a
                    // chat turn must never execute, so this is unusable.
                    // nil + classified — the router's same-turn fallback
                    // owns the turn; never a fabricated or partial reply.
                    self.lastCloudFailureClass = .invalidResponse
                    self.emit("chat_respond_unusable", outcome: "failure",
                              errorCode: "unusable_answer")
                    await MainActor.run { completion(nil) }
                    return
                }
                self.emit("chat_respond_done", outcome: "success")
                await MainActor.run { completion(parsed) }
            } catch {
                // Content-free code, never the error's description (see
                // `ErrorCodeMapper`); the CLASS feeds the chain's
                // bottom-out honesty line, exactly like `interpret`.
                self.emit("chat_respond_failed", outcome: "failure",
                          errorCode: ErrorCodeMapper.code(for: error))
                self.lastCloudFailureClass = GeminiFailureClass.classify(error)
                await MainActor.run { completion(nil) }
            }
        }
    }

    // MARK: - Observability

    /// No transcript or reply content in metadata — same PII policy as
    /// `LlamaCommandInterpreter`.
    private func emit(_ eventType: String, outcome: String, errorCode: String? = nil) {
        observabilityBus.emit(ObservabilityEvent(
            component: "gemini_interpreter",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: [:]
        ))
    }
}
