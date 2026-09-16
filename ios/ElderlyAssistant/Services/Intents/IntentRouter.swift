import Foundation

/// First-class brain selection (spec 2026-09-05 §4.0) — the single
/// `CommandInterpreter` installed in `CommandRouter`. Layer order:
///
///   1. keyword safety net   — upstream in `CommandRouter`, NOT here
///      (emergency / explicit med-ack, zero model, zero network)
///   2. intent→command cache — ~0ms, exact normalized match, cacheable
///      actions only; never skips confirmation (spec §4.2)
///   3. cloud preparse       — the collapsed Gemini understand call's
///      result for THIS utterance, when cloud STT ran (spec §4 collapse
///      #1: one round trip did STT+intent — no second call)
///   4. local brain          — on-device model (fine-tuned intent model
///      later; LLaMA today) — every cache miss
///   5. cloud brain          — Gemini text interpretation — ONLY when
///      `cloudEnabled` ("if configured": the app is fully useful with
///      zero Gemini config — calls/messages/reminders/meds/music are all
///      local; cloud is enhancement for open-domain, never load-bearing)
///
/// Why local-first sequential and not a pre-classifier: routing before
/// interpretation requires knowing the intent (chicken-and-egg). The
/// local model's output IS the routing signal — a confident closed action
/// executes locally; an abstain IS the "open question" verdict that
/// escalates. A phone intent can never leak to the cloud by misrouting.
///
/// [LAT-M3] (2026-09-11) Cloud-FIRST variant (latency plan M3): when
/// `cloudFirstEnabled` AND `cloudEnabled` (armed by `AppCoordinator`
/// exactly where the stack consents to cloud), layers 4–5 are REORDERED
/// for open-domain latency — the per-turn `InterpreterSelector` picks
/// the cloud brain whenever a provider + key are configured and the
/// cost governor allows (`interpreter_selected`/`cloud_configured`),
/// falling back to the local ladder on failure
/// (`cloud_failed_fallback`, time-bounded by the coupled-numbers
/// family) and running local-only when there is no key
/// (`no_key`) or the budget is spent (`cost_blocked`). Layers 1–3 are
/// untouched, and the keyword safety net upstream in `CommandRouter`
/// never sees any model either way.
///
/// REPHRASE band (spec §4): brains are constructed with their threshold
/// at `rephraseThreshold` so mid-confidence commands REACH this class,
/// which owns the band policy: ≥accept → dispatch; band + tier-`confirm`
/// action → dispatch (the existing confirmation flow verifies aloud —
/// that IS the rephrase-as-question); band + tier-`free` action → nil
/// (fall through). Full speak-as-question for free actions lands with the
/// fine-tuned local model, whose calibrated abstention makes it safe.
///
/// [CLOUD-CASCADE] (2026-09-16) A CONFIGURABLE CLOUD CASCADE tier on top
/// of layer 4: when the large local brain's answer comes back BELOW the
/// configured threshold (default 0.97, the internal card) and a cloud
/// provider is configured + within budget, the turn is overruled and
/// routed to the online brain through the SAME layer-5 plumbing an
/// abstention uses (`escalateToCloud` — one cloud path, never a fork).
/// `cloudCascade` nil (the default, and every pre-cascade construction
/// site) leaves every branch below byte-identical. The tier is inert —
/// no cue, no event, no log — wherever no provider is configured, and it
/// sits downstream of `CommandRouter`'s keyword safety net like every
/// other interpretation decision.
final class IntentRouter: CommandInterpreter {

    struct Config {
        let acceptThreshold: Double
        let rephraseThreshold: Double
        /// How long a cloud-preparse result stays matchable to its
        /// transcript (the recognizer→router hop is immediate; the window
        /// only guards against a stale result binding to a LATER
        /// coincidentally-identical utterance).
        let preparseFreshnessSeconds: TimeInterval
        static let `default` = Config(acceptThreshold: 0.7,
                                      rephraseThreshold: 0.4,
                                      preparseFreshnessSeconds: 60)
    }

    private let cache: IntentCommandCache
    private let observabilityBus: ObservabilityBus
    private let config: Config
    /// [PIPELINE-TRACE] The debug trace's recorder — the `band` row is
    /// recorded here, where the band policy makes its call (score in, the
    /// branch taken out). Nil (the default, and tests) makes each call
    /// below a nil check. Instrumentation only: the policy never reads a
    /// row, and the returned command is byte-identical either way.
    private let traceRecorder: PipelineTraceRecorder?

    /// Optional brains — nil/unavailable means that layer simply doesn't
    /// run. Swapped by `AppCoordinator` as model availability changes.
    var localBrain: CommandInterpreter?
    var cloudBrain: CommandInterpreter?
    /// The "if configured" invariant's second half: even a configured
    /// cloud brain is only consulted when the household allows cloud at
    /// all (the on-device stack toggle sets this false).
    var cloudEnabled: Bool = true

    /// [LAT-M3] (2026-09-11) Arms CLOUD-FIRST interpretation (latency
    /// plan M3): while true AND `cloudEnabled` (the stack's cloud
    /// consent, maintained by `AppCoordinator.applyVoiceEngineStack`),
    /// every LLM-bound utterance runs through the per-turn
    /// `InterpreterSelector` and the cloud answers whenever a key +
    /// budget allow — the legacy local-first ladder otherwise. Default
    /// false keeps every pre-M3 construction site and test on the
    /// legacy ladder exactly.
    var cloudFirstEnabled: Bool = false
    /// [LAT-M3] Selection inputs, wired by `AppCoordinator` to
    /// `GeminiConfigStore.isConfigured` and
    /// `GeminiCostGovernor.allowsCall()`. Nil (the default) reads as
    /// "not configured" so a pre-M3 construction site that arms
    /// `cloudFirstEnabled` without wiring inputs selects local,
    /// honestly.
    var geminiKeyConfigured: (() -> Bool)?
    var geminiCostAllows: (() -> Bool)?

    /// [CLOUD-CASCADE] (2026-09-16) The cloud cascade tier: the provider
    /// seam (`CloudBrainEndpoint` — resolved from `AppCoordinator.cloudProvider`
    /// through `CloudBrainProviders`), the configurable threshold, and the
    /// two side effects of a firing turn (the spoken hold cue and the
    /// coordinator's activity/app-log trail).
    ///
    /// Nil (the default, and every test that wires no tier) is "no tier" —
    /// the ladder below is byte-identical to the pre-cascade behaviour, so
    /// nothing about the encoder→picker cascade or the cloud escalation
    /// changes for a configuration that does not arm this.
    var cloudCascade: CloudCascadeConfiguration?

    var isAvailable: Bool {
        // The cache always works, so the router is "available" whenever
        // ANY layer can answer — including none of the models, since a
        // cache hit needs no brain.
        true
    }

    init(cache: IntentCommandCache,
         observabilityBus: ObservabilityBus,
         config: Config = .default,
         traceRecorder: PipelineTraceRecorder? = nil) {
        self.cache = cache
        self.observabilityBus = observabilityBus
        self.config = config
        self.traceRecorder = traceRecorder
    }

    // MARK: - Cloud preparse bridge (collapse #1)

    private let preparseLock = NSLock()
    private var preparsed: (transcript: String, command: InterpretedCommand, at: Date)?

    /// Called by `GeminiSpeechRecognizer` when its collapsed understand
    /// call produced a command alongside the transcript — the transcript
    /// still arrives here via the normal pipeline route, and this result
    /// is waiting for it. Keyed by exact transcript match + freshness so
    /// a stale result can never bind to a different utterance.
    func noteCloudPreparsed(transcript: String, command: InterpretedCommand?) {
        preparseLock.lock()
        preparsed = command.map { (transcript: transcript, command: $0, at: Date()) }
        preparseLock.unlock()
    }

    private func takePreparsed(matching transcript: String) -> InterpretedCommand? {
        preparseLock.lock()
        defer { preparseLock.unlock() }
        guard let p = preparsed,
              p.transcript == transcript,
              Date().timeIntervalSince(p.at) < config.preparseFreshnessSeconds else { return nil }
        preparsed = nil   // single-shot: one utterance, one preparse
        return p.command
    }

    // MARK: - CommandInterpreter

    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        // Layer 2 — cache. Bypasses interpretation only; downstream
        // confirmation is untouched (spec §4.2 invariant 1).
        if let cached = cache.command(for: transcript) {
            emit("cache_hit", outcome: "success")
            DispatchQueue.main.async { completion(cached) }
            return
        }

        // Layer 3 — cloud preparse (this utterance's own collapsed-call
        // result). Band policy applies the same as any brain output.
        if let pre = takePreparsed(matching: transcript) {
            emit("cloud_preparse_used", outcome: "success")
            DispatchQueue.main.async { completion(self.bandChecked(pre, source: "preparse", final: true)) }
            return
        }

        // [LAT-M3] (2026-09-11) Cloud-FIRST selection (latency plan M3):
        // armed AND the stack consents to cloud → decide per turn which
        // interpreter answers. Cloud whenever a key + budget allow
        // (with a time-bounded llama fallback on failure); otherwise
        // the local ladder runs with cloud deselected for THIS turn (no
        // escalation on a no-key / budget-blocked day).
        if cloudFirstEnabled && cloudEnabled {
            let selection = InterpreterSelector.select(
                keyConfigured: geminiKeyConfigured?() ?? false,
                costAllows: geminiCostAllows?() ?? false)
            emitInterpreterSelected(selection)
            switch selection {
            case .cloud:
                interpretCloudFirst(transcript: transcript, context: context,
                                    completion: completion)
                return
            case .local:
                interpretLocalLadder(transcript: transcript, context: context,
                                     canEscalate: false, completion: completion)
                return
            }
        }

        // Legacy ladder (layers 4–5) — local first, cloud escalation
        // only when the stack allows cloud and a cloud brain exists.
        // [CLOUD-CASCADE] `escalationBrain` is the provider seam's
        // interpreter when a tier is wired, else the raw `cloudBrain`
        // slot — the same object in the shipped wiring, so this stays
        // byte-identical for every pre-cascade construction site.
        interpretLocalLadder(transcript: transcript, context: context,
                             canEscalate: cloudEnabled && escalationBrain?.isAvailable == true,
                             completion: completion)
    }

    // MARK: - Ladders

    /// The legacy local-first ladder: the local brain (layer 4) answers
    /// when available; its abstention (or a mid-band tier-free drop, when
    /// `canEscalate`) escalates to the cloud brain (layer 5).
    ///
    /// [LAT-EVIDENCE] A local brain that FAILED — inference timeout or
    /// truncated output, both after the interpreter's own retry, per
    /// `InterpreterFailureReporting` — escalates to the cloud whenever
    /// one is configured (the LAT-M3 selector's key + budget
    /// readiness), even where an abstention would not: a failure is
    /// never a bare apology while a cloud can answer. The escalation
    /// carries the honest `local_failed_fallback` selection event.
    private func interpretLocalLadder(transcript: String,
                                      context: InterpreterContext,
                                      canEscalate: Bool,
                                      completion: @escaping (InterpretedCommand?) -> Void) {
        if let local = localBrain, local.isAvailable {
            // Is escalation actually possible? A mid-band tier-free answer
            // is dropped for escalation ONLY when a cloud layer exists;
            // otherwise local is the final layer and the answer becomes
            // the rephrase question (spec §4 decision #6).
            local.interpret(transcript: transcript, context: context) { [weak self] command in
                guard let self else { completion(nil); return }
                // [CLOUD-CASCADE] The tier, checked BEFORE the band policy:
                // a sub-threshold local answer is not this turn's answer
                // while a configured online brain can take it. Ordered
                // ahead of the accept band on purpose — the whole point of
                // a 97 % threshold is that an ACCEPTED-but-unsure local
                // answer (0.70…0.97) still goes online. `canEscalate` is
                // the stack's own cloud consent, so a cloud-declining
                // configuration never reaches the tier at all.
                if let command, let cascade = self.cloudCascade, canEscalate,
                   cascade.escalates(localConfidence: command.confidence) {
                    self.escalateViaCloudCascade(cascade,
                                                 localCommand: command,
                                                 transcript: transcript,
                                                 context: context,
                                                 completion: completion)
                    return
                }
                if let command, let accepted = self.bandChecked(command, source: "local",
                                                                final: !canEscalate) {
                    completion(accepted)
                } else if canEscalate {
                    // [PIPELINE-TRACE] A nil command never reached the
                    // band policy (`bandChecked` was not called at all),
                    // so the escalation — not a band outcome — is what
                    // the row reports. A command that WAS banded and
                    // dropped already left its own (scored) row, and is
                    // deliberately not overwritten here.
                    if command == nil {
                        self.recordBandNoCommand("escalate", source: "local")
                    }
                    if (local as? InterpreterFailureReporting)?
                        .lastInferenceFailureReason != nil {
                        // The legacy ladder escalates any nil, but a
                        // FAILURE escalation is logged honestly.
                        self.emitLocalFailedFallback()
                    }
                    self.escalateToCloud(transcript: transcript, context: context,
                                         completion: completion)
                } else if (local as? InterpreterFailureReporting)?
                            .lastInferenceFailureReason != nil,
                          self.cloudEnabled,
                          self.cloudBrain?.isAvailable == true,
                          self.geminiKeyConfigured?() ?? false,
                          self.geminiCostAllows?() ?? false {
                    // The cloud-first `.local` lane: the selector
                    // refused the cloud for THIS turn, but a failed
                    // local brain re-checks the same readiness inputs —
                    // when a key + budget allow, the cloud answers with
                    // the honest reason event instead of a bare
                    // apology.
                    if command == nil {
                        self.recordBandNoCommand("escalate", source: "local")
                    }
                    self.emitLocalFailedFallback()
                    self.escalateToCloud(transcript: transcript, context: context,
                                         completion: completion)
                } else {
                    // [PIPELINE-TRACE] The turn ends in the router: a nil
                    // command never reached the band policy at all. A
                    // command that was banded and dropped keeps its own
                    // (scored) row.
                    if command == nil {
                        self.recordBandNoCommand("abstain", source: "local")
                    }
                    completion(nil)
                }
            }
            return
        }

        // Layer 5 — cloud, when allowed + configured.
        if canEscalate {
            escalateToCloud(transcript: transcript, context: context, completion: completion)
        } else {
            DispatchQueue.main.async { completion(nil) }
        }
    }

    /// [LAT-M3] The cloud-FIRST attempt: the cloud brain answers when it
    /// can; its failure — nil, or a confidence below the rephrase floor —
    /// falls back to the local brain with the honest
    /// `cloud_failed_fallback` selection event. A mid-band tier-`free`
    /// cloud answer is FINAL (returned as the rephrase question — see
    /// `bandChecked(final: true)`): the cloud already answered, and a
    /// llama retry would only add ~7 s of latency for a worse answer.
    ///
    /// Time-bounding (the coupled-numbers family): the cloud leg is
    /// bounded by `GeminiClient`'s own 25 s HTTP timeout, the local leg
    /// by the llama interpreter's 10 s inference timeout — 35 s worst
    /// case in total, the SAME bound as the legacy local-first ladder
    /// (10 s local + 25 s escalation), which stays inside
    /// `VoicePipeline.turnPendingSafetySeconds` (35 s) and the 60 s
    /// voice watchdog. The single `completion` fires exactly once on
    /// every path, so `CommandRouter`'s turn-reply-pending token
    /// resolves exactly as it does today.
    private func interpretCloudFirst(transcript: String,
                                     context: InterpreterContext,
                                     completion: @escaping (InterpretedCommand?) -> Void) {
        guard let cloud = cloudBrain, cloud.isAvailable else {
            // Selected, but the layer cannot run (client dropped) — the
            // honest fallback, same reason as a failed request.
            fallBackToLocal(transcript: transcript, context: context, completion: completion)
            return
        }
        cloud.interpret(transcript: transcript, context: context) { [weak self] command in
            guard let self else { completion(nil); return }
            if let command, let accepted = self.bandChecked(command, source: "cloud", final: true) {
                completion(accepted)
                return
            }
            self.fallBackToLocal(transcript: transcript, context: context,
                                 completion: completion)
        }
    }

    /// [LAT-M3] The cloud failure path: log the honest
    /// `cloud_failed_fallback` selection and let the local brain answer
    /// as the final layer (its mid-band tier-`free` output becomes the
    /// rephrase question, exactly as when local is final in the legacy
    /// ladder).
    private func fallBackToLocal(transcript: String,
                                 context: InterpreterContext,
                                 completion: @escaping (InterpretedCommand?) -> Void) {
        emitInterpreterSelected(.local(reason: .cloudFailedFallback))
        guard let local = localBrain, local.isAvailable else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        local.interpret(transcript: transcript, context: context) { [weak self] command in
            guard let self else { completion(nil); return }
            completion(command.flatMap { self.bandChecked($0, source: "local_fallback", final: true) })
        }
    }

    // MARK: - Band policy ([PIPELINE-TRACE] renderings)

    /// `set_reminder 0.55 via local` — what came into the policy: the
    /// action, its score, and which layer produced it (the `source` token
    /// is closed vocabulary: preparse / local / local_fallback / cloud).
    static func bandInput(_ command: InterpretedCommand, source: String) -> String {
        PipelineTraceSummary.text(
            "\(command.action.rawValue) \(PipelineTraceSummary.score(command.confidence)) via \(source)")
    }

    /// `accept/local score=0.83` — the branch taken, the layer, and the
    /// number. A closed-vocabulary token plus a numeric reading, so the
    /// RELEASE console line (which prints the decision and nothing else)
    /// still says where the turn's score landed.
    static func bandDecision(_ outcome: String, source: String,
                             confidence: Double) -> String {
        "\(outcome)/\(source) score=\(PipelineTraceSummary.score(confidence))"
    }

    /// The no-command row: the policy never saw a command, so there is no
    /// score to band — the token says which way the turn went instead
    /// (`escalate` when a higher layer takes it, `abstain` when the turn
    /// ends here, as it does in the router's final `else`).
    private func recordBandNoCommand(_ outcome: String, source: String) {
        traceRecorder?.record(.band,
                              input: "no command",
                              output: outcome == "escalate"
                                  ? "nothing to band — the cloud takes the turn"
                                  : "nothing to band — the turn ends here",
                              decision: "\(outcome)/\(source)")
    }

    // MARK: - Band policy

    /// ACCEPT at ≥acceptThreshold; REPHRASE band dispatches
    /// tier-`confirm` actions (their confirmation question verifies the
    /// interpretation out loud); mid-band tier-`free` actions are dropped
    /// ONLY while another layer could still do better (escalation). When
    /// `final` is true — no more layers — a mid-band tier-`free` command
    /// is RETURNED, and `CommandRouter` turns it into a yes/no
    /// rephrase-as-question (spec §4 REPHRASE band, open decision #6):
    /// asking costs one exchange; dropping costs the whole command.
    ///
    /// [PIPELINE-TRACE] Every branch below also closes the turn's `band`
    /// row — the one place that knows WHICH branch the score landed in
    /// (the caller only sees the return value, and the two drop reasons
    /// are indistinguishable from it). Instrumentation only: the span is
    /// opened and finished around the UNCHANGED checks, and no branch
    /// reads it.
    private func bandChecked(_ command: InterpretedCommand, source: String,
                             final: Bool = false) -> InterpretedCommand? {
        let traceSpan = traceRecorder?.start(
            .band, input: Self.bandInput(command, source: source))
        if command.confidence >= config.acceptThreshold {
            traceSpan?.finish(output: "in the accept band",
                              decision: Self.bandDecision("accept", source: source,
                                                          confidence: command.confidence))
            return command
        }
        guard command.confidence >= config.rephraseThreshold else {
            traceSpan?.finish(output: "below the rephrase floor — dropped",
                              decision: Self.bandDecision("drop", source: source,
                                                          confidence: command.confidence))
            return nil
        }
        guard ConfirmationTier.tier(for: command.action) == .confirm else {
            if final {
                emit("rephrase_band_question", outcome: "info")
                traceSpan?.finish(output: "mid-band, tier-free, no layers left — rephrase question",
                                  decision: Self.bandDecision("rephrase", source: source,
                                                              confidence: command.confidence))
                return command
            }
            emit("rephrase_band_dropped", outcome: "info")
            traceSpan?.finish(output: "mid-band, tier-free — dropped for the next layer",
                              decision: Self.bandDecision("escalate", source: source,
                                                          confidence: command.confidence))
            return nil
        }
        emit("rephrase_band_confirmed_via_tier1", outcome: "info")
        traceSpan?.finish(output: "mid-band, tier-confirm — confirmation question",
                          decision: Self.bandDecision("confirm", source: source,
                                                      confidence: command.confidence))
        return command
    }

    /// [CLOUD-CASCADE] The cloud brain an escalation reaches: the provider
    /// seam's interpreter when a tier is wired, else the raw `cloudBrain`
    /// slot. The two are the SAME object in the shipped wiring — the seam
    /// exists so the tier reads readiness from the provider, not so the
    /// ladder gains a second cloud. With no tier wired this is exactly the
    /// pre-cascade `cloudBrain`.
    private var escalationBrain: CommandInterpreter? {
        cloudCascade?.endpoint.interpreter ?? cloudBrain
    }

    private func escalateToCloud(transcript: String,
                                 context: InterpreterContext,
                                 completion: @escaping (InterpretedCommand?) -> Void) {
        guard cloudEnabled, let cloud = escalationBrain, cloud.isAvailable else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        cloud.interpret(transcript: transcript, context: context) { [weak self] command in
            guard let self else { completion(nil); return }
            completion(command.flatMap { self.bandChecked($0, source: "cloud", final: true) })
        }
    }

    // MARK: - Cloud cascade tier ([CLOUD-CASCADE])

    /// Routes a sub-threshold local answer to the online brain — the
    /// tier's ONE path, reached only from the local ladder above.
    ///
    /// Order is the contract, and each step happens exactly once per
    /// escalated turn:
    ///  1. the spoken hold cue — BEFORE the cloud call, so the user learns
    ///     why the wait just got longer while the request is still in
    ///     flight (the cue is the tier's only user-visible act);
    ///  2. the `cloud_cascade_escalated` observability event — threshold,
    ///     local confidence and provider id, no content (C9);
    ///  3. the coordinator's trail (`onEscalated`: the activity-log row and
    ///     the app log line);
    ///  4. the cloud call — the SAME `escalateToCloud` an abstention uses,
    ///     with its own band policy and its own 25 s HTTP bound.
    ///
    /// A cloud that returns nothing usable leaves the LOCAL answer
    /// standing, band-checked as the final layer — so a cascade turn can
    /// never be WORSE than the same turn without the tier (the rule the
    /// encoder cascade's "no escalation target" branch holds too), and a
    /// household never hears an apology where a usable local answer
    /// existed.
    ///
    /// Main queue by contract: every brain in the ladder completes on main
    /// (`LocalBrainChain`, the interpreters), and this runs inside that
    /// completion.
    private func escalateViaCloudCascade(_ cascade: CloudCascadeConfiguration,
                                         localCommand: InterpretedCommand,
                                         transcript: String,
                                         context: InterpreterContext,
                                         completion: @escaping (InterpretedCommand?) -> Void) {
        let escalation = CloudCascadeEscalation(provider: cascade.endpoint.provider.rawValue,
                                                threshold: cascade.threshold,
                                                localConfidence: localCommand.confidence)
        cascade.holdCue?()
        emitCloudCascadeEscalated(escalation)
        cascade.onEscalated?(escalation)
        escalateToCloud(transcript: transcript, context: context) { [weak self] command in
            guard let self else { completion(nil); return }
            guard let command else {
                completion(self.bandChecked(localCommand, source: "local", final: true))
                return
            }
            completion(command)
        }
    }

    /// [CLOUD-CASCADE] `cloud_cascade_escalated` on `voice_routing`: the
    /// large local brain answered below the configured threshold and the
    /// ONLINE brain takes the turn. The threshold, the local confidence
    /// and the provider id — never transcript or reply content (C9
    /// policy), and never the API key. Pair it with the cue the user
    /// heard to tell "sent to the cloud" from "answered on device".
    private func emitCloudCascadeEscalated(_ escalation: CloudCascadeEscalation) {
        observabilityBus.emit(ObservabilityEvent(
            component: "voice_routing",
            eventType: "cloud_cascade_escalated",
            durationMs: nil,
            outcome: "escalated",
            errorCode: nil,
            metadata: [
                "provider": escalation.provider,
                "threshold": PipelineTraceSummary.score(escalation.threshold),
                "confidence": PipelineTraceSummary.score(escalation.localConfidence)
            ]
        ))
    }

    // MARK: - Cache write (called post-confirmation by the coordinator)

    /// Spec §4.2: the cache learns from CONFIRMED, EXECUTED commands only.
    func recordConfirmedExecution(transcript: String, command: InterpretedCommand) {
        cache.record(transcript: transcript, command: command)
    }

    // MARK: - Observability (no transcript/reply content — C9 policy)

    private func emit(_ eventType: String, outcome: String) {
        observabilityBus.emit(ObservabilityEvent(
            component: "intent_router",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: [:]
        ))
    }

    /// [LAT-M3] The honest per-turn selection event: `interpreter`
    /// ("gemini" / "llama") plus the `reason` it was chosen
    /// (`InterpreterSelectionReason`). Emitted once per LLM-bound
    /// utterance in cloud-first mode — and again on the fallback, so a
    /// dashboard can tell "selected cloud" apart from "cloud failed,
    /// llama answered". No transcript or reply content (C9 policy).
    private func emitInterpreterSelected(_ selection: InterpreterSelection) {
        observabilityBus.emit(ObservabilityEvent(
            component: "intent_router",
            eventType: "interpreter_selected",
            durationMs: nil,
            outcome: "info",
            errorCode: nil,
            metadata: [
                "interpreter": selection.interpreterName,
                "reason": selection.reason.rawValue
            ]
        ))
    }

    /// [LAT-EVIDENCE] The honest reason event for a failure-driven
    /// escalation: the local brain FAILED (timeout / truncated output
    /// after its retry) and the cloud answers this turn —
    /// `interpreter_selected` with interpreter "gemini" and reason
    /// `local_failed_fallback` (the same wire shape as the selector's
    /// own events, so a dashboard reads them uniformly).
    private func emitLocalFailedFallback() {
        observabilityBus.emit(ObservabilityEvent(
            component: "intent_router",
            eventType: "interpreter_selected",
            durationMs: nil,
            outcome: "info",
            errorCode: nil,
            metadata: [
                "interpreter": "gemini",
                "reason": InterpreterSelectionReason.localFailedFallback.rawValue
            ]
        ))
    }
}
