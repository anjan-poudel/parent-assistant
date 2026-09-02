import Foundation
import Combine

/// UI-facing voice session states (spec §3.3).
///
/// Wraps — never duplicates — `VoicePipeline.State`. An adapter in
/// `AppCoordinator` maps pipeline states onto these and derives `speaking`
/// from the speaker lifecycle, so the pipeline never learns about UI states.
enum VoiceSessionState: Equatable {
    case idle
    case listening
    case transcribing
    case understanding
    case speaking
    case awaitingConfirmation
    case error
    case stopped

    /// Legal transitions (spec §3.3 diagram). Illegal ones assert in debug
    /// and no-op in release.
    func canTransition(to newState: VoiceSessionState) -> Bool {
        switch self {
        case .idle:
            // .speaking is reachable from idle: async replies (LLM) and
            // re-prompts arrive AFTER the pipeline has returned to idle.
            return [.listening, .speaking, .awaitingConfirmation, .error,
                    .stopped].contains(newState)
        case .listening, .transcribing, .understanding, .speaking:
            // Busy states accept .stopped — the manual escape hatch:
            // tapping the Talk button mid-cycle cancels and recycles the
            // pipeline (same recovery as the watchdog). They also accept
            // .awaitingConfirmation: the medication challenge is issued
            // while the router is still "understanding" the utterance.
            return [.transcribing, .understanding, .speaking, .idle,
                    .awaitingConfirmation, .error, .stopped].contains(newState)
        case .awaitingConfirmation:
            return [.idle, .error, .stopped].contains(newState)
        case .error:
            return [.idle, .stopped].contains(newState)
        case .stopped:
            // .error is reachable from stopped: pipeline start failures land
            // here (e.g. audio session / mic-permission errors at boot).
            return [.idle, .error].contains(newState)
        }
    }
}

/// Owns the single `@Published` session state. Mutations are confined to
/// the main queue by contract — callers (AppCoordinator) dispatch via
/// `DispatchQueue.main.async`, and the timeout callback dispatches to main
/// itself (spec §3.3, review H1). Not `@MainActor` so it stays
/// constructible from `AppCoordinator`'s nonisolated init.
///
/// The confirmation timeout (review C12, spec §3.3) lives here: entering
/// `awaitingConfirmation` arms a timer that returns to `idle` and notifies
/// the coordinator, which clears `pendingConfirmationEntryId` and speaks a
/// localized notice.
final class VoiceSessionStateMachine: ObservableObject {

    struct Config {
        /// Seconds before a pending confirmation challenge expires (C12).
        var confirmationTimeoutSeconds: UInt64 = 45
    }

    @Published private(set) var state: VoiceSessionState = .stopped

    /// Fired when the confirmation challenge times out (C12). The
    /// coordinator clears its pending entry and speaks the notice.
    var onConfirmationTimeout: (() -> Void)?

    private let config: Config
    private var confirmationTimer: Task<Void, Never>?

    init(config: Config = Config()) {
        self.config = config
    }

    func transition(to newState: VoiceSessionState) {
        guard state != newState else { return }
        guard state.canTransition(to: newState) else {
            #if DEBUG
            assertionFailure("Illegal VoiceSessionState transition: \(state) → \(newState)")
            #endif
            return
        }
        let wasAwaitingConfirmation = state == .awaitingConfirmation
        state = newState
        if wasAwaitingConfirmation {
            cancelConfirmationTimer()
        }
        if newState == .awaitingConfirmation {
            armConfirmationTimer()
        }
    }

    private func armConfirmationTimer() {
        cancelConfirmationTimer()
        let seconds = config.confirmationTimeoutSeconds
        confirmationTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            // All mutations stay on the main queue (H1).
            DispatchQueue.main.async {
                self.transition(to: .idle)
                self.onConfirmationTimeout?()
            }
        }
    }

    private func cancelConfirmationTimer() {
        confirmationTimer?.cancel()
        confirmationTimer = nil
    }
}
