import Foundation

// MARK: - Talk-hero readiness copy (startup review P0-2, 2026-09-10)
//
// Home's hero consumes the SHARED CONTRACT TYPE `VoicePipelineReadiness`
// (Services/Voice/VoicePipelineReadiness.swift) and nothing else: no fold
// status, no `StartupBootStage`, no wake-word state. Manual Talk is gated
// by the manual pipeline's own start callback — a degraded KWS engine must
// never take the speak button down with it. This file holds the pure
// stage/failure → localized-copy mapping for the hero.

// MARK: - Hero copy (pure mapping)

/// Stage/failure → the hero's localized copy. Pure and locale-injected so
/// the mapping is unit-testable without a view tree (the same seam
/// `TalkStageVisuals` uses for the state tables).
enum TalkReadinessCopy {
    /// In-hero loading label for a pipeline start that is still in flight.
    static func loadingLabel(_ stage: VoiceLoadingStage, locale: Locale) -> String {
        switch stage {
        case .starting:
            return L10n.str("voice.readiness.loading.starting", locale: locale)
        }
    }

    /// The ONE explanation a failed boot-time start shows — it names the
    /// unavailable capability (manual voice activation) and nothing else;
    /// `VoiceStartupFailure`'s machine `reason` is for logs, never for the
    /// user.
    static func failureExplanation(_ failure: VoiceStartupFailure, locale: Locale) -> String {
        switch failure {
        case .pipelineStartFailed:
            return L10n.str("voice.readiness.failed.pipelineStart", locale: locale)
        }
    }

    /// The ONE deterministic recovery action's label.
    static func failureRecovery(locale: Locale) -> String {
        L10n.str("voice.readiness.failed.retry", locale: locale)
    }

    /// VoiceOver label for the hero in each readiness state — the loading
    /// stage and the capability failure must both be announced (the
    /// review's VoiceOver acceptance), so the hero never reads as a live
    /// speak button while it is not one.
    static func accessibilityLabel(_ readiness: VoicePipelineReadiness,
                                   stateLabel: String,
                                   locale: Locale) -> String {
        switch readiness {
        case .loading(let stage):
            return loadingLabel(stage, locale: locale)
        case .failed(let failure):
            return failureExplanation(failure, locale: locale)
        case .ready:
            return stateLabel
        }
    }
}
