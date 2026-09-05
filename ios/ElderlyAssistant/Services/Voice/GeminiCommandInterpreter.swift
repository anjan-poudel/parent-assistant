import Foundation

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
/// for its inference timeout.
final class GeminiCommandInterpreter: CommandInterpreter {

    struct Config {
        let confidenceThreshold: Double
        static let `default` = Config(confidenceThreshold: 0.7)
    }

    private let client: GeminiClient
    private let observabilityBus: ObservabilityBus
    private let config: Config

    var isAvailable: Bool { client.isAvailable }

    init(client: GeminiClient, observabilityBus: ObservabilityBus, config: Config = .default) {
        self.client = client
        self.observabilityBus = observabilityBus
        self.config = config
    }

    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        guard isAvailable else {
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

        let prompt = Self.buildPrompt(transcript: clean, context: context)
        Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await self.client.generateJSON(prompt: prompt)
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
                self.emit("interpret_failed", outcome: "failure", errorCode: String(describing: error))
                await MainActor.run { completion(nil) }
            }
        }
    }

    // MARK: - Prompt

    /// Same field set as `LlamaGrammar.commandJSON` (action, entryId,
    /// contact, time, medication, message, confidence, reply) — described
    /// in prose here since Gemini's JSON mode is driven by the prompt +
    /// `responseMimeType`, not a GBNF grammar.
    static func buildPrompt(transcript: String, context: InterpreterContext) -> String {
        let meds = context.pendingMedications.isEmpty
            ? "(none)"
            : context.pendingMedications.joined(separator: ", ")
        return """
        You are Sahayak, a personal voice assistant for an elderly speaker.
        The user's pending medications are: \(meds).
        The user's language hint is: \(context.userLanguageHint).

        Reply with ONLY a single JSON object (no markdown fences, no
        commentary) with exactly these fields:
        {
          "action": one of "ack_med", "call", "emergency", "set_reminder",
                    "health_query", "music", "send_message", "query", "none",
          "entryId": string or null,
          "contact": string or null,
          "time": string or null,
          "medication": string or null,
          "message": string or null,
          "callType": string or null,
          "requestedApp": string or null,
          "confidence": number from 0 to 1,
          "reply": short string, a spoken reply in the user's language
        }

        Set action to "ack_med" if the user confirms they took medication,
        "call" if they want to make a phone call, "send_message" if they
        want to send a text message, "set_reminder" if they want a
        reminder at a time, "music" if they ask for a song or bhajan,
        "query" for any other question, otherwise "none".

        Set action to "emergency" for ANY plea for help, urgent pain,
        injury, a fall, feeling unable to breathe, chest pain, or fear for
        their safety — even if it's phrased as a question or mentions a
        symptom. Err toward "emergency" whenever there is real ambiguity
        between "emergency" and "health_query": a false alarm just causes
        one extra reassurance message, but missing a real emergency is
        far worse. For example, "मद्दत गर्नुहोस्, मलाई मिर्गौला दुखेको छ"
        (help, my kidney hurts) is "emergency", NOT "health_query" — it is
        a plea for help attached to pain, not a calm question about
        health. Reserve "health_query" for calm, non-urgent questions
        about health with no help-seeking or pain/injury/danger involved
        (e.g. "मेरो रक्तचाप कस्तो हुनुपर्छ" — what should my blood pressure
        be).
        For "set_reminder", set time to the time expression they used
        (keep the original wording, e.g. "बिहान ८ बजे") and medication to
        the medication name if mentioned, else null.
        For "call" and "send_message", set contact to who they named or
        described (a name, or a relationship like "son"/"छोरा"), else null.
        For "send_message", set message to the message body they dictated,
        else null.
        For "call", set callType to "video" if they asked for a video
        call (e.g. "भिडियो कल", "video call"), or "voice" if they asked
        for a plain phone call, else null if unclear. Set requestedApp to
        the specific app they named (e.g. "facetime", "whatsapp",
        "messenger", "viber"), else null if they didn't name one — don't
        guess an app they didn't mention.
        Set entryId to null unless you can identify a specific target.

        User said: "\(transcript)"
        """
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
