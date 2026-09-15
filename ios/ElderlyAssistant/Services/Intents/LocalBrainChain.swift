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
///
/// [CORRECTION-ANYBRAIN] The chain is ALSO the local slot's input seam.
/// `CommandRouter`'s safety net and `IntentRouter`'s band policy read the
/// transcript the router was handed; the two pre-intent layers — the
/// STT-error corrector and the dialect canonicalizer — act on the input of
/// whichever brain serves the local slot, so they are useful regardless of
/// which of them answers. This chain is that boundary: with an `InputSeam`
/// attached it runs `sanitise → correct → canonicalize` ONCE per turn,
/// hands the pair to a brain that consumes it (`PreparedTranscriptInterpreting`
/// — the encoder, which must NOT run the layers a second time) and the
/// pair's prepared text to every other brain. `inputSeam: nil` (the
/// default, and the nested chain's construction) is the byte-identical
/// pass-through: the transcript reaches the brain exactly as the router
/// sent it.
///
/// Routing, timeouts, escalation reasons and the stand-in selection are
/// untouched by the seam: it changes the STRING a brain reads, never which
/// brain is asked or what is done with its answer.
final class LocalBrainChain: CommandInterpreter, InterpreterFailureReporting,
                             PreparedTranscriptInterpreting {

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

    /// [CORRECTION-ANYBRAIN] The local slot's input seam (§4.6's composition,
    /// relocated from `IntentEncoderInterpreter`): the corrected →
    /// canonicalized pair for one turn.
    ///
    /// `prepare` is handed `InputSanitiser.sanitise(_:level:.quarantine)`
    /// output — the sanitiser stays the injection boundary and stays FIRST,
    /// so a table rewrite can never resurrect text the clamp removed — and
    /// returns the pair `IntentInputCanonicalization.prepare` builds. The
    /// chain runs it exactly ONCE per turn, whichever brain ends up serving.
    ///
    /// The policies are NOT held here: the shipped seam resolves them from
    /// the stored switches on every call, so flipping either switch in
    /// Settings acts on the next turn with no re-install (neither layer is a
    /// brain, and neither is consulted for the slot's shape).
    struct InputSeam {
        let prepare: (String) -> IntentTranscriptPair

        init(prepare: @escaping (String) -> IntentTranscriptPair) {
            self.prepare = prepare
        }
    }

    private let preferred: CommandInterpreter
    private let standIn: CommandInterpreter
    private let cascade: Cascade?

    /// [CORRECTION-ANYBRAIN] The input seam this chain owns, or nil for the
    /// byte-identical pass-through. Only the OUTER chain of a local slot
    /// carries one (`IntentEncoderWiring.localBrainSlot`): the nested chain
    /// `deferredEncoderPreference` installs in the `preferred` slot receives
    /// an already-prepared pair, and giving it a seam of its own would run
    /// the layers a second time on their own output.
    private let inputSeam: InputSeam?

    /// [TURN-TIMING-BREAKDOWN] Turn-scoped stage stopwatch for the
    /// `cascade_decision` stage. Nil (the default, and every non-gated
    /// build) makes the measurement a nil check: no clock read, no lock.
    /// Instrumentation only — the decision itself never reads it.
    private let timingRecorder: TurnTimingRecorder?

    /// [PIPELINE-TRACE] The debug trace's recorder — the same decision the
    /// timing span above measures, told in full (the preferred brain's
    /// answer in, the branch taken out, the escalation vocabulary as the
    /// decision). Nil (the default, and every non-gated build) makes every
    /// call below a nil check. Instrumentation only: no branch here reads
    /// a row.
    private let traceRecorder: PipelineTraceRecorder?

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
         timingRecorder: TurnTimingRecorder? = nil,
         inputSeam: InputSeam? = nil,
         traceRecorder: PipelineTraceRecorder? = nil) {
        self.preferred = preferred
        self.standIn = standIn
        self.cascade = cascade
        self.timingRecorder = timingRecorder
        self.inputSeam = inputSeam
        self.traceRecorder = traceRecorder
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
        interpret(turn: turnInput(for: transcript),
                  context: context, completion: completion)
    }

    /// [CORRECTION-ANYBRAIN] The other half of the local slot's input
    /// contract: an enclosing chain has ALREADY run the seam, so this chain
    /// forwards the pair it was handed instead of preparing it a second time
    /// — the nested `preferred` chain `deferredEncoderPreference` installs
    /// is entered this way, and so is this chain when it is itself nested.
    ///
    /// No seam runs here, and none may be attached: the layers ran once, at
    /// the slot's input, and re-running them on their own output is the
    /// `correct∘correct` the relocation exists to prevent.
    func interpret(preparedInput pair: IntentTranscriptPair,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        interpret(turn: TurnInput(pair: pair,
                                  plainText: Self.plainText(for: pair,
                                                            raw: pair.original)),
                  context: context, completion: completion)
    }

    /// One turn's input at the local slot. Built by exactly one of the two
    /// entry points above, then threaded through the UNCHANGED decision
    /// logic below.
    private struct TurnInput {
        /// The prepared pair, or nil on a chain with no seam (the
        /// pass-through shape, and every pre-relocation call site).
        let pair: IntentTranscriptPair?
        /// What a brain that does not consume the pair reads.
        let plainText: String
    }

    /// The seam, run ONCE — or not at all on a chain that does not own one.
    private func turnInput(for transcript: String) -> TurnInput {
        guard let inputSeam else {
            return TurnInput(pair: nil, plainText: transcript)
        }
        // The sanitiser is the boundary and comes first (§4.6): the seam is
        // handed sanitised text and nothing else.
        let clean = InputSanitiser.sanitise(transcript, level: .quarantine)
        let pair = inputSeam.prepare(clean)
        return TurnInput(pair: pair,
                         plainText: Self.plainText(for: pair, raw: transcript))
    }

    /// What a brain that does not consume the pair is handed.
    ///
    /// An INERT pair (both layers off, or neither matched anything) passes
    /// the transcript through byte-identically — the pre-relocation path,
    /// and the reason the shipped default is unchanged. Once a layer has
    /// rewritten something, the prepared text is what the brain must read,
    /// or the switch would appear to do nothing. `raw` is the transcript as
    /// this chain received it (the nested chain has only the pair, and uses
    /// its `original` — the sanitised transcript — instead).
    private static func plainText(for pair: IntentTranscriptPair,
                                  raw: String) -> String {
        pair.isIdentity ? raw : pair.pickerBrainInput
    }

    private func interpret(turn: TurnInput,
                           context: InterpreterContext,
                           completion: @escaping (InterpretedCommand?) -> Void) {
        guard preferred.isAvailable else {
            // Availability-only substitution — the rule in every mode.
            // [PIPELINE-TRACE] The cascade stage did not run: this turn
            // never reached it (the encoder-first brain is missing), and
            // the row says which precondition failed rather than
            // vanishing.
            traceRecorder?.recordOff([.cascade], reason: "preferred_unavailable")
            serveFromStandIn(turn: turn, context: context,
                             completion: completion)
            return
        }
        guard let cascade else {
            // [PIPELINE-TRACE] No cascade configured — the availability
            // pair only, so the stage is off with the stage's own reason
            // token (one source, so a reworded token cannot drift).
            traceRecorder?.recordOff([.cascade],
                                     reason: PipelineTraceStage.cascade.offReason)
            lastServedPreferred = true
            dispatch(to: preferred, turn: turn, context: context,
                     completion: completion)
            return
        }
        // [ENCODER-RUNTIME-CASCADE] Encoder-first: the preferred brain
        // gets the turn; the stand-in gets the SAME turn (one completion,
        // no second prompt) only when the preferred answer is not one the
        // router would have used as-is.
        dispatch(to: preferred, turn: turn, context: context) { [weak self, cascade] command in
            guard let self else { completion(command); return }
            // [TURN-TIMING-BREAKDOWN] `cascade_decision` — the chain's own
            // serve-or-escalate work, from the preferred brain's answer to
            // the branch taken. Finished at EACH decision point (before
            // the stand-in is dispatched) so the stage can never absorb
            // the stand-in's own run; `finish()` is one-shot, so exactly
            // one duration is recorded per turn. Instrumentation only —
            // no branch below reads the span.
            let decisionSpan = self.timingRecorder?.start(.cascadeDecision)
            // [PIPELINE-TRACE] The cascade's own row, opened on the same
            // edge: the preferred brain's answer is the input, the branch
            // taken is the output, and the escalation vocabulary is the
            // decision. Finished at EACH branch below, before the
            // stand-in is dispatched, so the row can never absorb the
            // stand-in's run; `finish` is one-shot, so exactly one row is
            // recorded per turn. Instrumentation only.
            let traceSpan = self.traceRecorder?.start(
                .cascade,
                input: Self.answerSummary(of: command, preferred: self.preferred))
            if let command, command.confidence >= cascade.acceptThreshold {
                decisionSpan?.finish()
                traceSpan?.finish(output: "served at the band", decision: "served")
                self.lastServedPreferred = true
                completion(command)
                return
            }
            guard self.standIn.isAvailable else {
                // Nothing is configured to escalate TO: the preferred
                // brain's own answer stands, so a cascade turn can never
                // be WORSE than the standalone rule.
                decisionSpan?.finish()
                traceSpan?.finish(output: "preferred answer stands — no escalation target",
                                  decision: "served_no_target")
                self.lastServedPreferred = true
                completion(command)
                return
            }
            self.lastServedPreferred = false
            decisionSpan?.finish()
            let reason = Self.escalationReason(for: command, preferred: self.preferred)
            traceSpan?.finish(output: "escalated to the stand-in",
                              decision: reason.rawValue)
            cascade.onEscalated?(reason)
            self.dispatch(to: self.standIn, turn: turn, context: context,
                          completion: completion)
        }
    }

    /// Hands one turn's input to one brain: the PAIR to a brain that consumes
    /// it (and therefore runs no seam of its own), the prepared text to every
    /// other. Routing is not decided here — the caller has already decided
    /// which brain serves; this only chooses the input's shape.
    private func dispatch(to brain: CommandInterpreter,
                          turn: TurnInput,
                          context: InterpreterContext,
                          completion: @escaping (InterpretedCommand?) -> Void) {
        if let pair = turn.pair,
           let consumer = brain as? PreparedTranscriptInterpreting {
            consumer.interpret(preparedInput: pair, context: context,
                               completion: completion)
            return
        }
        brain.interpret(transcript: turn.plainText, context: context,
                        completion: completion)
    }

    private func serveFromStandIn(turn: TurnInput,
                                  context: InterpreterContext,
                                  completion: @escaping (InterpretedCommand?) -> Void) {
        guard standIn.isAvailable else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        lastServedPreferred = false
        dispatch(to: standIn, turn: turn, context: context,
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

    /// [PIPELINE-TRACE] One line describing what the preferred brain
    /// handed the cascade: the action and confidence when it produced a
    /// command, or the content-free failure token it produced instead of
    /// one (the same `InterpreterFailureReporting` reason the
    /// LAT-EVIDENCE path reads). The action name is a schema token, never
    /// a slot value — this summary reaches the card, and the RELEASE
    /// console line beside it carries only the decision.
    private static func answerSummary(of command: InterpretedCommand?,
                                      preferred: CommandInterpreter) -> String {
        if let command {
            return PipelineTraceSummary.text(
                "\(command.action.rawValue) \(PipelineTraceSummary.score(command.confidence))")
        }
        guard let failure = (preferred as? InterpreterFailureReporting)?
            .lastInferenceFailureReason else {
            return "no command"
        }
        return PipelineTraceSummary.text("no command (\(failure))")
    }
}

/// [CORRECTION-ANYBRAIN] A local brain that consumes the slot's PREPARED
/// turn input — the corrected → canonicalized pair — instead of a bare
/// transcript.
///
/// The seam (`IntentInputCanonicalization.prepare`) is run ONCE, by the
/// chain that owns it (`LocalBrainChain.InputSeam`), and handed to whichever
/// brain serves: a conforming brain reads the pair, every other brain reads
/// the pair's prepared text. Implementing this protocol is how a brain says
/// two things at once:
///
///  1. it wants the layers' OUTPUT (not the raw transcript), and
///  2. it will NOT run the layers itself — the pair IS the seam's result, so
///     the `correct∘correct` a second preparation would produce is
///     structurally impossible on the shipped path.
///
/// `IntentEncoderInterpreter` implements it (it used to run the seam
/// internally); its `interpret(transcript:)` entry point keeps preparing for
/// direct callers, but the slot never reaches the encoder that way.
/// `LocalBrainChain` implements it too, so a nested chain forwards the pair
/// rather than re-preparing it.
protocol PreparedTranscriptInterpreting: AnyObject {
    func interpret(preparedInput pair: IntentTranscriptPair,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void)
}
