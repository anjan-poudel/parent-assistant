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
            // .speaking is reachable from idle AND stopped — the shared
            // rationale: async replies (LLM) and re-prompts arrive AFTER
            // the pipeline has returned to idle, and push speech (morning
            // briefing, notification read-aloud) may start BEFORE the
            // pipeline has been primed, while the session is idle/stopped.
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
            // .speaking is reachable from stopped, mirroring .idle above:
            // push speech — the launch morning briefing (fires before the
            // pipeline starts: log order briefing_fired →
            // pipeline_started), notification read-alouds — can begin
            // while the session is stopped, before the pipeline has been
            // primed. The round trip closes: .speaking → .stopped is
            // legal from the busy states above, and a speaking-ended
            // fallback through handlePipelineState lands .idle/.stopped
            // legally once the pipeline reports. .error is also reachable
            // from stopped: pipeline start failures land here (e.g. audio
            // session / mic-permission errors at boot).
            return [.idle, .speaking, .error].contains(newState)
        }
    }

    /// States in which holding the Talk button offers the "reset voice
    /// activation" path (TALK-CRASH-FIX, 2026-09-07). `.listening` /
    /// `.transcribing` / `.understanding` are the stuck-or-active cycle
    /// the user escapes; `.idle`, `.error` and `.stopped` make the reset
    /// a harmless re-prime of a dead pipeline. NOT offered in `.speaking`
    /// (the assistant is replying — a long hold there would swallow the
    /// tap that today stops the reply and recycles; the button must keep
    /// its plain tap semantics) nor `.awaitingConfirmation` (the yes/no
    /// challenge owns the dialog; the button is disabled there anyway).
    /// Pure state policy — no transition-table changes needed, because
    /// the reset itself travels existing legal transitions (busy → .stopped
    /// → .idle → [.speaking]).
    var supportsTalkReset: Bool {
        switch self {
        case .idle, .listening, .transcribing, .understanding, .error, .stopped:
            return true
        case .speaking, .awaitingConfirmation:
            return false
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

    /// Transitions to `newState`, bridging through `.idle` when the
    /// current state cannot reach it directly — but ONLY when both
    /// bridge edges are themselves legal (the same legal-edge-only rule
    /// the awaitingConfirmation opener keeps).
    ///
    /// [LAUNCH-TRANSITION-FIX] (2026-09-17) Device/simulator log:
    /// `Illegal VoiceSessionState transition: error → speaking` asserted
    /// at launch — the pipeline reported `.error` (mic/audio boot), then
    /// `.idle` while push speech was still playing
    /// (`handlePipelineState(.idle)` maps `speakingCount > 0` to
    /// `.speaking`). `error → speaking` has no direct edge, but
    /// `error → idle` and `idle → speaking` are both legal. The same
    /// bridge rescues `stopped → listening` (a capture event landing
    /// before the session has left `.stopped`).
    func transitionViaIdle(to newState: VoiceSessionState) {
        if state != newState,
           !state.canTransition(to: newState),
           state.canTransition(to: .idle),
           VoiceSessionState.idle.canTransition(to: newState) {
            transition(to: .idle)
        }
        transition(to: newState)
    }

    /// Opens the confirmation window unconditionally, bridging through
    /// `.idle` when the current state cannot reach `.awaitingConfirmation`
    /// directly (`.error` and `.stopped` cannot; every state can reach
    /// `.idle`).
    ///
    /// [APP-LAUNCHER F14] A caller that has just pended a question needs
    /// the window to EXIST, not merely to be attempted. A bare
    /// `transition(to: .awaitingConfirmation)` from `.error`/`.stopped` is
    /// an illegal transition: it asserts in debug, silently no-ops in
    /// release, and leaves the pended question with no timer and no
    /// clearer — it can only be resolved if the elder happens to answer
    /// before anything else moves the state. The bridge keeps the
    /// transition table's guarantees intact (it only ever travels legal
    /// edges) while making the window's existence a promise.
    ///
    /// Returns whether the window is open on the way out — always true
    /// today, since `.idle` is reachable from every state, but the callers
    /// get to depend on the answer rather than on that argument.
    @discardableResult
    func openConfirmationWindow() -> Bool {
        if state != .awaitingConfirmation {
            if !state.canTransition(to: .awaitingConfirmation) {
                guard state.canTransition(to: .idle) else { return false }
                transition(to: .idle)
            }
            transition(to: .awaitingConfirmation)
        }
        return state == .awaitingConfirmation
    }

    private func armConfirmationTimer() {
        cancelConfirmationTimer()
        let seconds = config.confirmationTimeoutSeconds
        confirmationTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            // All mutations stay on the main queue (H1).
            DispatchQueue.main.async {
                // [APP-LAUNCHER F6] Report an expiry only for a window that
                // is STILL open. Cancelling the timer is not enough: a
                // callback already queued on main survives cancellation, so
                // a question resolved by another route (the elder tapped
                // the app's tile instead of answering) could still hear
                // "Time is up" over the app it had just opened. The window
                // knows whether it is still awaiting an answer — ask it.
                guard self.state == .awaitingConfirmation else { return }
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
