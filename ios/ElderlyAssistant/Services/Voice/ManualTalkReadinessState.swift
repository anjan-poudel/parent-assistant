import Foundation

// MARK: - Manual Talk readiness machine (startup review P0-2, 2026-09-10)
//
// `AppCoordinator.voicePipelineReadiness` holds this machine's current
// value; the coordinator is the only writer. The contract the review
// asks for is encoded HERE so it is unit-tested rather than merely
// documented:
//
//  - `.ready` is reachable from EXACTLY ONE method — `noteStartSucceeded`,
//    called from the successful `voicePipeline.start` completion
//    callback. No timer, no other boot phase, and nothing about the
//    wake-word engine can set it.
//  - A failure is never auto-recovered. `.failed` persists until a real
//    retry re-runs the start callback (the Talk hero's tap-to-retry
//    path); a later success then upgrades it to `.ready`.
//  - Wake-word (KWS) engine state cannot move manual Talk either way:
//    manual Talk must be usable when the real engine degrades to the
//    Null implementation. `noteWakeWordEngineSettled(isReal:)` exists as
//    the explicit, no-op half of that rule — the coordinator calls it on
//    the real KWS path, and the tests pin that it changes nothing.
//
// The type is a plain value type (no clock, no queues) so every rule
// above is testable without a view tree, an AppCoordinator, or a real
// voice stack.

/// The manual-Talk readiness state machine.
struct ManualTalkReadinessState: Equatable {

    /// The value the coordinator publishes (`voicePipelineReadiness`).
    private(set) var value: VoicePipelineReadiness

    init() { value = Self.initial }

    /// Launch value: loading from the very first frame, before any
    /// request has been made. Kept as a static so the coordinator's
    /// `@Published` initial value and this machine cannot drift apart.
    static let initial: VoicePipelineReadiness = .loading(.starting)

    /// The `voicePipeline.start` request has been issued. Readiness stays
    /// `.loading` — ASKING the pipeline to start is not the same as it
    /// having started; only the callback settles the state.
    mutating func noteStartRequested() {
        // A retry re-issues the request; it must not wipe a previous
        // failure before the new callback answers. `.ready` is likewise
        // never reset here (the hero is already live).
        guard case .loading = value else { return }
        value = .loading(.starting)
    }

    /// The `voicePipeline.start` completion callback reported success —
    /// the ONE path to `.ready`.
    mutating func noteStartSucceeded() {
        value = .ready
    }

    /// The `voicePipeline.start` completion callback reported failure.
    /// `reason` is a machine string for logs; the UI maps the failure
    /// case, never the raw text.
    mutating func noteStartFailed(reason: String) {
        value = .failed(.pipelineStartFailed(reason: reason))
    }

    /// The wake-word (KWS) engine construction settled — real sherpa
    /// engine or Null fallback. DELIBERATELY does not touch readiness:
    /// wake-word activation is a separate capability, and manual Talk
    /// must come up even when the wake-word engine is Null.
    mutating func noteWakeWordEngineSettled(isReal: Bool) {
        // No state change by design — see the header contract.
        _ = isReal
    }
}
