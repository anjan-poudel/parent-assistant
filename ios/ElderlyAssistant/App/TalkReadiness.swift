import Foundation

// MARK: - Manual Talk readiness (startup review P0-2, 2026-09-10)
//
// Home's hero consumes the SHARED CONTRACT TYPE `VoicePipelineReadiness`
// (Services/Voice/VoicePipelineReadiness.swift) and nothing else: no fold
// status, no `StartupBootStage`, no wake-word state. Manual Talk is gated
// by the manual pipeline's own start callback — a degraded KWS engine must
// never take the speak button down with it.
//
// ---------------------------------------------------------------------
// TEMPORARY BRIDGE — DELETE ON MERGE
// ---------------------------------------------------------------------
// The contract's publisher (`AppCoordinator.voicePipelineReadiness`,
// written only from `voicePipeline.start`'s completion callback) lands
// from the sibling startup branch. Until it merges, this extension adapts
// the coordinator's EXISTING published fold onto the same contract type,
// so HomeView and TalkButton are already written against the final shape:
//
//   * `.ready`              → `.ready`
//   * `.degraded(reason:)`  → `.failed(.pipelineStartFailed(reason:))`
//   * `.preparing`          → `.loading(.starting)`
//
// POST-MERGE: delete this file and read
// `coordinator.voicePipelineReadiness` directly in `HomeView`. The
// branch-specific name below deliberately differs from the sibling's
// property so the two never collide as redeclarations in the meantime.
//
// `voiceReadinessStatus` / `VoiceReadiness` / `TalkHeroGating` keep their
// own callers and tests in `Services/Voice/VoiceReadiness.swift` (owned by
// a sibling; post-merge cleanup removes them). After this change Home's
// hero is no longer one of those callers.

extension AppCoordinator {
    /// Manual Talk readiness in the shared contract's shape — the value
    /// `TalkButton` gates on.
    var talkReadiness: VoicePipelineReadiness {
        switch voiceReadinessStatus {
        case .ready:
            return .ready
        case .degraded(let reason):
            return .failed(.pipelineStartFailed(reason: reason))
        case .preparing:
            return .loading(.starting)
        }
    }
}

extension VoicePipelineReadiness {
    /// True while the hero must show its own loading presentation
    /// (spinner inside the disc, stage label, every activation and
    /// recovery gesture disabled).
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// The named failure, when the pipeline's boot-time start failed.
    var failure: VoiceStartupFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}

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
