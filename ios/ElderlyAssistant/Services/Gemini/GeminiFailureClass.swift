import Foundation

/// [GEMINI-SOLIDIFY] (2026-09-18) The cloud brain's failure taxonomy — the
/// ONE classification every Gemini error folds into, and the one thing the
/// user-facing layer consults to decide what to say.
///
/// Why five classes and not the nine `GeminiClientError` cases: the honest
/// spoken line is per FAILURE CLASS, not per wire detail. An empty response,
/// a policy block and a malformed payload are all "the cloud gave an answer
/// I couldn't use" to the elderly user; `rateLimited` and `quotaCapped` are
/// deliberately DISTINCT because they are honest refusals with different
/// remedies (wait vs. raise the cap) — and both are deliberately NOT
/// `transportFailed`, because the retry policy must never retry a refusal.
///
/// Retry coupling (Leg 1): ONLY `.transportFailed`-shaped transport errors
/// are retried (`GeminiClient.send(_:)` retries once, with backoff). A
/// quota/rate-limit refusal is an honest answer — repeating it costs money
/// and changes nothing, so no class except `transportFailed` ever reaches
/// the retry loop. The classification below is deliberately conservative:
/// an error the client did not itself produce (an `URLError` from the
/// transport seam, or anything unrecognised) is `transportFailed`, which is
/// the retryable class — an unknown error is far more likely a wire fault
/// than a refusal.
enum GeminiFailureClass: String, Equatable, CaseIterable {

    /// No API key — the cloud was never configured for this household.
    case notConfigured
    /// The day's Gemini budget is spent (`GeminiClientError.dailyCapReached`).
    case quotaCapped
    /// The provider refused the request as too frequent (HTTP 429).
    case rateLimited
    /// The transport could not complete an exchange — timeout, offline,
    /// connection lost, DNS, TLS, or anything unrecognised.
    case transportFailed
    /// The exchange completed but produced nothing usable — non-HTTP
    /// responses, non-2xx statuses (except 429), policy blocks, empty or
    /// undecodable bodies.
    case invalidResponse

    // MARK: - Spoken line

    /// The catalog key of the honest degradation line this class speaks
    /// when the turn bottoms out (see `CommandRouter.routeKeywordRemainder`).
    /// `quotaCapped` reuses the existing cap line — the same words the
    /// interpreter already speaks as a deterministic command
    /// (`GeminiCommandInterpreter`), so the two paths can never disagree.
    var spokenLineKey: String {
        switch self {
        case .notConfigured: return "router.cloud.notConfigured"
        case .quotaCapped: return "router.capReached"
        case .rateLimited: return "router.cloud.rateLimited"
        case .transportFailed: return "router.cloud.transportFailed"
        case .invalidResponse: return "router.cloud.invalidResponse"
        }
    }

    func spokenLine(locale: Locale) -> String {
        L10n.str(spokenLineKey, locale: locale)
    }

    // MARK: - Classification

    /// The total mapping from any thrown error to its class. Total and
    /// exhaustive: there is no default that guesses, so a new error shape
    /// must be classified deliberately.
    static func classify(_ error: Error) -> GeminiFailureClass {
        if let gemini = error as? GeminiClient.GeminiClientError {
            switch gemini {
            case .notConfigured, .invalidURL:
                // A request that cannot be built is a configuration defect,
                // not a wire fault — never retried, never "couldn't reach".
                return .notConfigured
            case .dailyCapReached:
                return .quotaCapped
            case .httpError(let status):
                return status == 429 ? .rateLimited : .invalidResponse
            case .invalidResponse, .emptyResponse, .blockedByProvider:
                return .invalidResponse
            }
        }
        if error is DecodingError {
            // A body that did not decode is an unusable answer, not a
            // transport fault — the request DID reach the provider.
            return .invalidResponse
        }
        // URLError and every other error the transport seam threw: the
        // exchange itself failed.
        return .transportFailed
    }
}

/// [GEMINI-SOLIDIFY] (2026-09-18) One interpreter's honest, per-turn report
/// of why its cloud leg failed — the house pattern's cloud sibling of
/// `InterpreterFailureReporting` (which reports LOCAL inference failures).
///
/// Consulted by `CommandRouter` ONLY when the whole chain has bottomed out
/// (no brain answered), so the user hears the real reason instead of the
/// generic "I didn't understand" re-prompt — which would be a lie when the
/// truth is a dead network or a spent budget. Read-and-cleared on use, and
/// cleared by `IntentRouter` at the start of every chain entry, so a
/// failure from a previous turn can never leak into a later one.
protocol CloudFailureReporting: AnyObject {
    /// The class of this turn's cloud failure, or nil when the cloud leg
    /// has not failed since the last clear.
    var lastCloudFailureClass: GeminiFailureClass? { get }
    /// Resets the report — a fresh attempt starts clean (the same rule
    /// `LocalIntentInterpreter` holds for `lastInferenceFailureReason`).
    func clearCloudFailure()
}
