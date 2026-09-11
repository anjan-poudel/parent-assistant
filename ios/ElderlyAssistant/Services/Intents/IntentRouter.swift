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

    var isAvailable: Bool {
        // The cache always works, so the router is "available" whenever
        // ANY layer can answer — including none of the models, since a
        // cache hit needs no brain.
        true
    }

    init(cache: IntentCommandCache,
         observabilityBus: ObservabilityBus,
         config: Config = .default) {
        self.cache = cache
        self.observabilityBus = observabilityBus
        self.config = config
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
        interpretLocalLadder(transcript: transcript, context: context,
                             canEscalate: cloudEnabled && cloudBrain?.isAvailable == true,
                             completion: completion)
    }

    // MARK: - Ladders

    /// The legacy local-first ladder: the local brain (layer 4) answers
    /// when available; its abstention (or a mid-band tier-free drop, when
    /// `canEscalate`) escalates to the cloud brain (layer 5).
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
                if let command, let accepted = self.bandChecked(command, source: "local",
                                                                final: !canEscalate) {
                    completion(accepted)
                } else if canEscalate {
                    self.escalateToCloud(transcript: transcript, context: context,
                                         completion: completion)
                } else {
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

    // MARK: - Band policy

    /// ACCEPT at ≥acceptThreshold; REPHRASE band dispatches
    /// tier-`confirm` actions (their confirmation question verifies the
    /// interpretation out loud); mid-band tier-`free` actions are dropped
    /// ONLY while another layer could still do better (escalation). When
    /// `final` is true — no more layers — a mid-band tier-`free` command
    /// is RETURNED, and `CommandRouter` turns it into a yes/no
    /// rephrase-as-question (spec §4 REPHRASE band, open decision #6):
    /// asking costs one exchange; dropping costs the whole command.
    private func bandChecked(_ command: InterpretedCommand, source: String,
                             final: Bool = false) -> InterpretedCommand? {
        if command.confidence >= config.acceptThreshold { return command }
        guard command.confidence >= config.rephraseThreshold else { return nil }
        guard ConfirmationTier.tier(for: command.action) == .confirm else {
            if final {
                emit("rephrase_band_question", outcome: "info")
                return command
            }
            emit("rephrase_band_dropped", outcome: "info")
            return nil
        }
        emit("rephrase_band_confirmed_via_tier1", outcome: "info")
        return command
    }

    private func escalateToCloud(transcript: String,
                                 context: InterpreterContext,
                                 completion: @escaping (InterpretedCommand?) -> Void) {
        guard cloudEnabled, let cloud = cloudBrain, cloud.isAvailable else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        cloud.interpret(transcript: transcript, context: context) { [weak self] command in
            guard let self else { completion(nil); return }
            completion(command.flatMap { self.bandChecked($0, source: "cloud", final: true) })
        }
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
}
