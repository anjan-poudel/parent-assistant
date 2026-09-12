import Foundation

/// `IntentRouter`'s local brain as an availability-preference pair
/// (spec 2026-09-05 §4.0/§8; wiring-regression fix 2026-09-06):
///
///  - `preferred` — the fine-tuned intent model (`LocalIntentInterpreter`),
///    the local brain the spec designates once its GGUF is cached.
///  - `standIn` — the general LLaMA interpreter (`LlamaCommandInterpreter`),
///    the spec's "LLaMA today" interim for exactly this pre-bake-off gap.
///
/// While `preferred` is AVAILABLE it IS the brain: its answers AND its
/// abstentions pass through untouched, so `IntentRouter`'s band policy,
/// cloud escalation, and the fine-tuned model's calibrated abstention all
/// behave exactly as they would with the model sitting directly in the
/// local slot. `standIn` is consulted only when `preferred` is
/// unavailable — the world before the bake-off artifact ships.
///
/// Why this type exists: the merge that first installed the fine-tuned
/// model as the local brain (intent-engine merge 189c51b) replaced the
/// live LLaMA wiring outright. The fine-tuned GGUF is still a placeholder
/// (never downloadable), so every configuration that cannot reach the
/// cloud — the on-device Whisper stack, or Gemini with no API key — was
/// left with NO interpretation layer at all: every utterance came back
/// nil and the router spoke the generic "I didn't understand" re-prompt
/// despite the STT transcribing correctly. This chain restores the LLaMA
/// path for exactly those configurations without disturbing the
/// fine-tuned model's future role.
final class LocalBrainChain: CommandInterpreter, InterpreterFailureReporting {

    private let preferred: CommandInterpreter
    private let standIn: CommandInterpreter

    init(preferred: CommandInterpreter, standIn: CommandInterpreter) {
        self.preferred = preferred
        self.standIn = standIn
    }

    var isAvailable: Bool {
        preferred.isAvailable || standIn.isAvailable
    }

    /// [LAT-EVIDENCE] Forwards the inner interpreter's failure reason —
    /// whichever one served the last turn (the preferred model when
    /// available, else the stand-in) — so the router sees through the
    /// chain and escalates a FAILED local brain to the cloud.
    var lastInferenceFailureReason: String? {
        if preferred.isAvailable {
            return (preferred as? InterpreterFailureReporting)?
                .lastInferenceFailureReason
        }
        return (standIn as? InterpreterFailureReporting)?
            .lastInferenceFailureReason
    }

    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        if preferred.isAvailable {
            preferred.interpret(transcript: transcript, context: context,
                                completion: completion)
            return
        }
        guard standIn.isAvailable else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        standIn.interpret(transcript: transcript, context: context,
                          completion: completion)
    }
}
