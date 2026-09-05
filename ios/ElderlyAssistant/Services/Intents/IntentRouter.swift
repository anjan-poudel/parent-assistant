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
            DispatchQueue.main.async { completion(self.bandChecked(pre, source: "preparse")) }
            return
        }

        // Layer 4 — local brain.
        if let local = localBrain, local.isAvailable {
            local.interpret(transcript: transcript, context: context) { [weak self] command in
                guard let self else { completion(nil); return }
                if let command, let accepted = self.bandChecked(command, source: "local") {
                    completion(accepted)
                } else {
                    self.escalateToCloud(transcript: transcript, context: context, completion: completion)
                }
            }
            return
        }

        // Layer 5 — cloud, when allowed + configured.
        escalateToCloud(transcript: transcript, context: context, completion: completion)
    }

    // MARK: - Band policy

    /// ACCEPT at ≥acceptThreshold; REPHRASE band dispatches only
    /// tier-`confirm` actions (their confirmation question verifies the
    /// interpretation out loud); anything weaker → nil = fall through.
    private func bandChecked(_ command: InterpretedCommand, source: String) -> InterpretedCommand? {
        if command.confidence >= config.acceptThreshold { return command }
        guard command.confidence >= config.rephraseThreshold else { return nil }
        guard ConfirmationTier.tier(for: command.action) == .confirm else {
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
            completion(command.flatMap { self.bandChecked($0, source: "cloud") })
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
}
