import Foundation

// MARK: - Talk-hero readiness copy (startup review P0-2, 2026-09-10;
// [LAT-M1] extended 2026-09-11)
//
// Home's hero consumes the SHARED CONTRACT TYPE `VoicePipelineReadiness`
// (Services/Voice/VoicePipelineReadiness.swift) and nothing else: no fold
// status, no `StartupBootStage`, no wake-word state. Manual Talk is gated
// by the manual pipeline's own start callback AND the [LAT-M1] invariance
// boot contract (warms + KWS) — a degraded KWS engine must never take the
// speak button down with it. This file holds the pure
// stage/failure/degradation → localized-copy mapping for the hero.

// MARK: - Hero copy (pure mapping)

/// Stage/failure/degradation → the hero's localized copy. Pure and
/// locale-injected so the mapping is unit-testable without a view tree
/// (the same seam `TalkStageVisuals` uses for the state tables).
enum TalkReadinessCopy {
    /// In-hero loading label for a pipeline start that is still in
    /// flight.
    static func loadingLabel(_ stage: VoiceLoadingStage, locale: Locale) -> String {
        switch stage {
        case .starting:
            return L10n.str("voice.readiness.loading.starting", locale: locale)
        case .preparingEngines:
            // [LAT-M1] The start succeeded; the boot contract is still
            // settling — the label stays honest about the wait.
            return L10n.str("voice.readiness.loading.preparingEngines", locale: locale)
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

    /// [LAT-M1] The honest caption under the hero while the boot
    /// contract is still preparing — the pending features, joined, so
    /// the wait is legible ("Preparing: speech · brain"). Empty when
    /// nothing is pending (never a stray caption).
    static func preparingEnginesCaption(_ progress: TalkBootProgress,
                                        locale: Locale) -> String {
        let names = progress.pendingFeatures.map { featureName($0, locale: locale) }
        guard !names.isEmpty else { return "" }
        return L10n.fmt("voice.readiness.preparing.caption", locale: locale,
                        names.joined(separator: " · "))
    }

    /// [LAT-M1] The honest cold-feature banner: the hero is ENABLED but
    /// the first conversation pays the listed engines' loads. Never
    /// silent, never blocking.
    static func degradedCaption(_ degradation: TalkBootDegradation,
                                locale: Locale) -> String {
        let names = degradation.coldFeatures.map { featureName($0, locale: locale) }
        guard !names.isEmpty else { return "" }
        return L10n.fmt("voice.readiness.degraded.caption", locale: locale,
                        names.joined(separator: " · "))
    }

    /// The extra status line the stage renders under the hero — the
    /// preparing per-feature caption and the degraded banner. Nil in
    /// every other readiness state.
    static func extraLine(_ readiness: VoicePipelineReadiness,
                          locale: Locale) -> String? {
        switch readiness {
        case .loading(.preparingEngines(let progress)):
            let line = preparingEnginesCaption(progress, locale: locale)
            return line.isEmpty ? nil : line
        case .degraded(let degradation):
            let line = degradedCaption(degradation, locale: locale)
            return line.isEmpty ? nil : line
        case .loading(.starting), .ready, .failed:
            return nil
        }
    }

    /// One feature's localized name for the joined captions (machine
    /// names never reach the user).
    static func featureName(_ feature: TalkBootFeature, locale: Locale) -> String {
        switch feature {
        case .whisper: return L10n.str("voice.feature.speech", locale: locale)
        case .primaryTTS: return L10n.str("voice.feature.voice", locale: locale)
        case .llama: return L10n.str("voice.feature.brain", locale: locale)
        case .kws: return L10n.str("voice.feature.wakeWord", locale: locale)
        }
    }

    /// VoiceOver label for the hero in each readiness state — the loading
    /// stage and the capability failure must both be announced (the
    /// review's VoiceOver acceptance), so the hero never reads as a live
    /// speak button while it is not one. The degraded hero IS live — its
    /// label is the state label, and the banner text below is the honest
    /// cold-feature note.
    static func accessibilityLabel(_ readiness: VoicePipelineReadiness,
                                   stateLabel: String,
                                   locale: Locale) -> String {
        switch readiness {
        case .loading(let stage):
            return loadingLabel(stage, locale: locale)
        case .failed(let failure):
            return failureExplanation(failure, locale: locale)
        case .ready, .degraded:
            return stateLabel
        }
    }
}
