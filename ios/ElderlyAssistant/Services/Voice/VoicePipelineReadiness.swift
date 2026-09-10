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

/// Manual Talk readiness, driven solely by `voicePipeline.start`'s
/// completion callback.
enum VoicePipelineReadiness: Equatable {
    case loading(VoiceLoadingStage)
    case ready
    case failed(VoiceStartupFailure)
}

/// Progressive loading phases for the Talk hero's stage label.
enum VoiceLoadingStage: Equatable {
    /// Pipeline start has been requested (or will be imminently).
    case starting
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

    /// The named failure, when the pipeline's boot-time start failed.
    var failure: VoiceStartupFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}
