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

        let prompt = IntentPrompt.build(transcript: clean, context: context)
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
