import Foundation

// MARK: - Talk-hero readiness copy (startup review P0-2, 2026-09-10)
//
// Home's hero consumes `VoicePipelineReadiness`, driven only by the voice
// pipeline's start callback. This file maps pipeline loading/failure/readiness
// to localized hero and accessibility copy.

// MARK: - Hero copy (pure mapping)

/// Pipeline readiness to localized hero copy. Locale injection keeps the
/// mapping unit-testable without a view tree.
enum TalkReadinessCopy {
    /// In-hero loading label for a pipeline start that is still in
    /// flight.
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

    /// VoiceOver label for the hero in each readiness state. Loading and
    /// capability failure are announced so the hero never reads as actionable
    /// before pipeline start succeeds.
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
