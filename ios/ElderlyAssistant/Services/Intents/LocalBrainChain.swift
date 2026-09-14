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
///
/// [ENCODER-RUNTIME-CASCADE] A second, OPT-IN rule exists for the
/// internal-testing A/B (the encoder switch's cascade toggle): when the
/// chain is built with a `Cascade`, the preferred brain answers FIRST and
/// the stand-in answers the SAME turn whenever the preferred brain
/// abstained or came back below the router's ACCEPT band. `cascade: nil`
/// — the default, and every shipped call site — is the availability-only
/// rule documented above, unchanged. The cascade can only ADD a layer: it
/// selects between two brains the router would consult anyway, and it sits
/// downstream of `CommandRouter`'s keyword safety net like every other
/// interpreter decision.
final class LocalBrainChain: CommandInterpreter, InterpreterFailureReporting {

    /// [ENCODER-RUNTIME-CASCADE] Why a cascade turn left the preferred
    /// brain. Fixed vocabulary for the observability trail — event
    /// metadata only, never transcript or reply content (C9 policy).
    enum EscalationReason: String {
        /// No command, no failure report: the preferred brain's own
        /// calibrated abstention.
        case abstained
        /// No command AND a failure report (timeout / truncated output
        /// after the interpreter's own retry) — the distinction
        /// `IntentRouter`'s LAT-EVIDENCE path reads.
        case failed
        /// A command came back below the ACCEPT band — the encoder served
        /// nothing it would not have had to rephrase or drop.
        case subBandConfidence
    }

    /// [ENCODER-RUNTIME-CASCADE] Opt-in encoder-first behaviour for the
    /// internal-testing A/B. Nil (the default) keeps the exclusive rule.
    struct Cascade {
        /// The router's ACCEPT threshold: an answer at or above it IS the
        /// turn's answer; below it — or an abstention — the stand-in gets
        /// the turn. One band, the router's own, so "the encoder served"
        /// means exactly what it means in `IntentRouter.bandChecked`.
        let acceptThreshold: Double
        /// Called once per escalated turn, BEFORE the stand-in runs, with
        /// the reason the preferred brain did not serve. Metadata only.
        let onEscalated: ((EscalationReason) -> Void)?

        init(acceptThreshold: Double,
             onEscalated: ((EscalationReason) -> Void)? = nil) {
            self.acceptThreshold = acceptThreshold
            self.onEscalated = onEscalated
        }
    }

    private let preferred: CommandInterpreter
    private let standIn: CommandInterpreter
    private let cascade: Cascade?

    /// [TURN-TIMING-BREAKDOWN] Turn-scoped stage stopwatch for the
    /// `cascade_decision` stage. Nil (the default, and every non-gated
    /// build) makes the measurement a nil check: no clock read, no lock.
    /// Instrumentation only — the decision itself never reads it.
    private let timingRecorder: TurnTimingRecorder?

    /// Which brain answered the LAST turn (true = preferred), so the
    /// failure reason below describes the brain that actually served —
    /// under a cascade the preferred brain's timeout must not be reported
    /// as the reason a stand-in answer arrived. nil until the chain has
    /// answered a turn, where the availability-based rule below applies
    /// exactly as it did before this property existed.
    private var lastServedPreferred: Bool?

    init(preferred: CommandInterpreter,
         standIn: CommandInterpreter,
         cascade: Cascade? = nil,
         timingRecorder: TurnTimingRecorder? = nil) {
        self.preferred = preferred
        self.standIn = standIn
        self.cascade = cascade
        self.timingRecorder = timingRecorder
    }

    var isAvailable: Bool {
        preferred.isAvailable || standIn.isAvailable
    }

    /// [LAT-EVIDENCE] Forwards the inner interpreter's failure reason —
    /// whichever one served the last turn (the preferred model when
    /// available, else the stand-in; under a cascade, the brain that
    /// actually answered) — so the router sees through the chain and
    /// escalates a FAILED local brain to the cloud.
    var lastInferenceFailureReason: String? {
        let serving = (lastServedPreferred ?? preferred.isAvailable) ? preferred : standIn
        return (serving as? InterpreterFailureReporting)?.lastInferenceFailureReason
    }

    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        guard preferred.isAvailable else {
            // Availability-only substitution — the rule in every mode.
            serveFromStandIn(transcript: transcript, context: context,
                             completion: completion)
            return
        }
        guard let cascade else {
            lastServedPreferred = true
            preferred.interpret(transcript: transcript, context: context,
                                completion: completion)
            return
        }
        // [ENCODER-RUNTIME-CASCADE] Encoder-first: the preferred brain
        // gets the turn; the stand-in gets the SAME turn (one completion,
        // no second prompt) only when the preferred answer is not one the
        // router would have used as-is.
        preferred.interpret(transcript: transcript, context: context) { [weak self, cascade] command in
            guard let self else { completion(command); return }
            // [TURN-TIMING-BREAKDOWN] `cascade_decision` — the chain's own
            // serve-or-escalate work, from the preferred brain's answer to
            // the branch taken. Finished at EACH decision point (before
            // the stand-in is dispatched) so the stage can never absorb
            // the stand-in's own run; `finish()` is one-shot, so exactly
            // one duration is recorded per turn. Instrumentation only —
            // no branch below reads the span.
            let decisionSpan = self.timingRecorder?.start(.cascadeDecision)
            if let command, command.confidence >= cascade.acceptThreshold {
                decisionSpan?.finish()
                self.lastServedPreferred = true
                completion(command)
                return
            }
            guard self.standIn.isAvailable else {
                // Nothing is configured to escalate TO: the preferred
                // brain's own answer stands, so a cascade turn can never
                // be WORSE than the standalone rule.
                decisionSpan?.finish()
                self.lastServedPreferred = true
                completion(command)
                return
            }
            self.lastServedPreferred = false
            decisionSpan?.finish()
            cascade.onEscalated?(Self.escalationReason(for: command,
                                                       preferred: self.preferred))
            self.standIn.interpret(transcript: transcript, context: context,
                                   completion: completion)
        }
    }

    private func serveFromStandIn(transcript: String,
                                  context: InterpreterContext,
                                  completion: @escaping (InterpretedCommand?) -> Void) {
        guard standIn.isAvailable else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        lastServedPreferred = false
        standIn.interpret(transcript: transcript, context: context,
                          completion: completion)
    }

    /// Abstention and failure both arrive as nil; only the failure carries
    /// a reason (the same distinction `IntentRouter` draws).
    private static func escalationReason(for command: InterpretedCommand?,
                                         preferred: CommandInterpreter) -> EscalationReason {
        guard command == nil else { return .subBandConfidence }
        let failed = (preferred as? InterpreterFailureReporting)?
            .lastInferenceFailureReason != nil
        return failed ? .failed : .abstained
    }
}
