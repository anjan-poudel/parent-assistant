import Foundation

/// [LAT-M3] (2026-09-11) Open-domain interpreter selection — latency
/// compliance plan M3: whenever a cloud provider + API key are configured
/// AND the day's cost budget still allows, open-domain (LLM-bound)
/// utterances interpret through the CLOUD interpreter (the ~1.5–2.5 s
/// Gemini round trip); otherwise the on-device llama interpreter answers
/// as before (~7 s). The decision is per-turn and PURE — the same two
/// inputs every time — so it is unit-testable with no network and no
/// interpreter, and `IntentRouter` logs the outcome as the
/// `interpreter_selected` observability event.
///
/// The deterministic ladder stages in `CommandRouter` (safety net,
/// emergency, med-ack, alarms/timers, directions, news, briefing,
/// YouTube, topic pre-answers) all run BEFORE any interpreter is
/// consulted, so this selection never touches them — they stay
/// model-free on every configuration.
enum InterpreterSelection: Equatable {
    /// The cloud interpreter (`GeminiCommandInterpreter`) answers.
    case cloud
    /// The local interpreter (the llama chain) answers, for `reason`.
    case local(reason: InterpreterSelectionReason)
    /// [LAT-EVIDENCE] The local brain FAILED (timeout / truncated
    /// output after its retry) and the cloud answers this turn — the
    /// honest `local_failed_fallback` reason.
    case cloudAfterLocalFailure

    /// The honest reason this selection happened — logged as the
    /// `reason` metadata of the `interpreter_selected` event.
    var reason: InterpreterSelectionReason {
        switch self {
        case .cloud: return .cloudConfigured
        case .local(let reason): return reason
        case .cloudAfterLocalFailure: return .localFailedFallback
        }
    }

    /// Which interpreter the selection picked — the event's
    /// `interpreter` metadata ("gemini" / "llama").
    var interpreterName: String {
        switch self {
        case .cloud, .cloudAfterLocalFailure: return "gemini"
        case .local: return "llama"
        }
    }
}

/// Why the selector picked what it picked. The raw values are the stable
/// wire strings logged in the `interpreter_selected` event's `reason`
/// metadata — never rename without updating whatever consumes the log.
enum InterpreterSelectionReason: String, Equatable {
    /// A cloud provider + API key are configured and the day's Gemini
    /// budget still allows calls — the cloud answers.
    case cloudConfigured = "cloud_configured"
    /// The day's Gemini cost cap blocks further calls — local only.
    case costBlocked = "cost_blocked"
    /// No API key is configured — local only.
    case noKey = "no_key"
    /// Cloud was selected but failed mid-request (network, timeout,
    /// parse, below the rephrase floor) — fell back to local.
    case cloudFailedFallback = "cloud_failed_fallback"
    /// [LAT-EVIDENCE] (2026-09-12) The local brain FAILED (inference
    /// timeout / truncated output, both after its one retry) and the
    /// cloud answers this turn — the honest reason a failure-driven
    /// escalation happened instead of a bare apology.
    case localFailedFallback = "local_failed_fallback"
}

/// The pure selection rule. Cloud wins exactly when a key is configured
/// AND the cost governor allows a call; every other combination is
/// local. The key check runs FIRST so a missing key is reported as
/// `no_key` even on a budget-blocked day (the primary reason, not a side
/// effect).
struct InterpreterSelector {
    static func select(keyConfigured: Bool, costAllows: Bool) -> InterpreterSelection {
        guard keyConfigured else { return .local(reason: .noKey) }
        guard costAllows else { return .local(reason: .costBlocked) }
        return .cloud
    }
}
