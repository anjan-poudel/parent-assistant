import Foundation

// MARK: - Manual Talk readiness (startup review P0, 2026-09-10)
//
// Dedicated readiness for the MANUAL Talk control, independent of the
// global StartupBootStage and of wake-word readiness. Published ONLY by
// the voice pipeline's own start callback:
//
//  - `.loading(stage)`  — from app launch until the voicePipeline.start
//    completion handler runs (either outcome). The Talk hero stays
//    disabled and shows an honest loading presentation.
//  - `.ready`           — the voicePipeline.start callback succeeded.
//  - `.failed(failure)` — the callback reported failure. The UI shows
//    ONE explanation and ONE recovery action; the state is never
//    auto-recovered by a timer or by any other boot phase.
//
// Wake-word status is deliberately OUT of this type: manual Talk must
// become usable even when wake-word activation degrades to its Null
// implementation.
//
// Naming note: the top-level enum is `VoicePipelineReadiness` (not the
// review's literal `VoiceReadiness`) because that identifier is already
// taken by the fold-based `VoiceReadiness` ObservableObject in this
// folder (startup-r2 task).

/// Manual Talk readiness, driven by `voicePipeline.start`'s completion
/// callback AND the [LAT-M1] invariance boot contract (`TalkBootContract`):
///
///  - `.loading(.starting)`          — the start request is in flight.
///  - `.loading(.preparingEngines)`  — the start SUCCEEDED, but the boot
///    contract is still open (warms/KWS settling). The hero stays
///    disabled with the honest preparing label + per-feature status;
///    the warm budget expiry alone never settles this (no silent enable).
///  - `.ready`                       — start succeeded ∧ contract satisfied.
///  - `.degraded(TalkBootDegradation)` — start succeeded, some feature
///    failed/timed out: the hero is ENABLED with an honest banner naming
///    the cold features (never blocked forever, never silently enabled).
///  - `.failed(VoiceStartupFailure)` — the start callback failed (sticky).
enum VoicePipelineReadiness: Equatable {
    case loading(VoiceLoadingStage)
    case ready
    case degraded(TalkBootDegradation)
    case failed(VoiceStartupFailure)
}

/// Progressive loading phases for the Talk hero's stage label.
enum VoiceLoadingStage: Equatable {
    /// Pipeline start has been requested (or will be imminently).
    case starting
    /// [LAT-M1] The start succeeded; the boot contract (warms + KWS) is
    /// still settling — the hero shows the preparing label with the
    /// per-feature progress.
    case preparingEngines(TalkBootProgress)
}

/// Named, deterministic failure of the voice pipeline's boot-time start.
/// `reason` is a machine string for logs, not user-facing text.
enum VoiceStartupFailure: Equatable {
    case pipelineStartFailed(reason: String)
}

extension VoicePipelineReadiness {
    /// True while the hero must show its own loading presentation
    /// (spinner inside the disc, stage label, every activation and
    /// recovery gesture disabled).
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// True when the hero may start a conversation: fully ready, or
    /// degraded — the degraded hero is ENABLED (the first conversation
    /// honestly pays the cold engines' loads) with a banner naming them.
    var isTalkEnabled: Bool {
        switch self {
        case .ready, .degraded: return true
        case .loading, .failed: return false
        }
    }

    /// The named failure, when the pipeline's boot-time start failed.
    var failure: VoiceStartupFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    /// The cold-feature payload, when the contract settled degraded.
    var degradation: TalkBootDegradation? {
        if case .degraded(let degradation) = self { return degradation }
        return nil
    }
}
