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
    case awaitingSlotAnswer
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
            // Both answer windows are reachable here too: the confirmation
            // challenge (medication yes/no) and the slot answer window
            // (FR-MTC-014) open on a question the assistant has just
            // decided to ask.
            return [.listening, .speaking, .awaitingConfirmation,
                    .awaitingSlotAnswer, .error, .stopped].contains(newState)
        case .listening, .transcribing, .understanding, .speaking:
            // Busy states accept .stopped — the manual escape hatch:
            // tapping the Talk button mid-cycle cancels and recycles the
            // pipeline (same recovery as the watchdog). They also accept
            // .awaitingConfirmation: the medication challenge is issued
            // while the router is still "understanding" the utterance.
            // .awaitingSlotAnswer joins for the same reason: a dialogue
            // probe is decided and opened while the router is still
            // understanding its trigger.
            return [.transcribing, .understanding, .speaking, .idle,
                    .awaitingConfirmation, .awaitingSlotAnswer, .error,
                    .stopped].contains(newState)
        case .awaitingConfirmation:
            return [.idle, .error, .stopped].contains(newState)
        case .awaitingSlotAnswer:
            // The slot answer window (FR-MTC-014) mirrors the confirmation
            // challenge's exits: every resolution — answer merged, cancel,
            // barge-in, escape, timeout — leaves to `.idle` (with `.error`
            // and `.stopped` for the pipeline backstops), and the opener
            // bridges in through `.idle` when a state cannot reach the
            // window directly. No direct edge to the OTHER window: the two
            // windows never coexist.
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
    /// challenge owns the dialog; the button is disabled there anyway)
    /// nor `.awaitingSlotAnswer` (FR-MTC-014: the slot probe dialogue owns
    /// the turn in exactly the same way).
    /// Pure state policy — no transition-table changes needed, because
    /// the reset itself travels existing legal transitions (busy → .stopped
    /// → .idle → [.speaking]).
    var supportsTalkReset: Bool {
        switch self {
        case .idle, .listening, .transcribing, .understanding, .error, .stopped:
            return true
        case .speaking, .awaitingConfirmation, .awaitingSlotAnswer:
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
/// localized notice. The `awaitingSlotAnswer` answer window (FR-MTC-014)
/// mirrors that machinery — same single config value, own timer and own
/// SILENT callback — beside it, never through it.
final class VoiceSessionStateMachine: ObservableObject {

    struct Config {
        /// Seconds before a pending confirmation challenge expires (C12).
        /// The single source for BOTH windows (confirmation and the
        /// dialogue slot answer window, FR-MTC-013/014) — the slot timer
        /// reads this same field and introduces no second literal.
        var confirmationTimeoutSeconds: UInt64 = 45
    }

    @Published private(set) var state: VoiceSessionState = .stopped

    /// Fired when the confirmation challenge times out (C12). The
    /// coordinator clears its pending entry and speaks the notice.
    var onConfirmationTimeout: (() -> Void)?

    /// Fired when the `awaitingSlotAnswer` window times out (FR-MTC-013).
    /// SILENT by contract (ADR-MTC-08): the coordinator resolves the
    /// frame as timed-out and speaks nothing — deliberately unlike the
    /// confirmation notice — and never calls the confirmation timeout
    /// recorder. The confirmation callback above is untouched.
    var onSlotAnswerTimeout: (() -> Void)?

    private let config: Config
    private var confirmationTimer: Task<Void, Never>?
    private var slotAnswerTimer: Task<Void, Never>?

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
        let wasAwaitingSlotAnswer = state == .awaitingSlotAnswer
        state = newState
        if wasAwaitingConfirmation {
            cancelConfirmationTimer()
        }
        if wasAwaitingSlotAnswer {
            cancelSlotAnswerTimer()
        }
        if newState == .awaitingConfirmation {
            armConfirmationTimer()
        }
        if newState == .awaitingSlotAnswer {
            armSlotAnswerTimer()
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

    /// Opens the slot answer window (`awaitingSlotAnswer`, FR-MTC-014)
    /// unconditionally — the exact mirror of `openConfirmationWindow()`.
    /// Only `.idle` and the busy set reach `.awaitingSlotAnswer`
    /// directly; `.awaitingConfirmation`, `.error` and `.stopped` bridge
    /// through `.idle` first (every state can reach `.idle`), so every
    /// edge travelled is legal and "the window must EXIST, not merely be
    /// attempted" (F14) holds for the dialogue probe exactly as it does
    /// for the confirmation challenge. Opening is idempotent: while the
    /// window is already open the original timer and budget stand.
    ///
    /// Bridging OUT of `.awaitingConfirmation` closes that challenge
    /// (through `.idle`, which cancels its timer), which is what keeps
    /// the two windows mutually exclusive by construction.
    @discardableResult
    func openSlotAnswerWindow() -> Bool {
        if state != .awaitingSlotAnswer {
            if !state.canTransition(to: .awaitingSlotAnswer) {
                guard state.canTransition(to: .idle) else { return false }
                transition(to: .idle)
            }
            transition(to: .awaitingSlotAnswer)
        }
        return state == .awaitingSlotAnswer
    }

    /// Restamps an OPEN slot answer window with a full fresh budget —
    /// the re-probe path (L2-D6: a re-probe IS a probe speech). True only
    /// when the session is already awaiting the slot answer; it never
    /// opens or bridges a window (that is `openSlotAnswerWindow()`'s
    /// job), so a stray call outside the window changes nothing.
    @discardableResult
    func refreshSlotAnswerWindow() -> Bool {
        guard state == .awaitingSlotAnswer else { return false }
        armSlotAnswerTimer()
        return true
    }

    /// The answer-window length in seconds (review-l2 C-1): the ONE value
    /// `config.confirmationTimeoutSeconds` (`:120`) owns, exposed as an
    /// instance accessor so `AppCoordinator` can construct its
    /// `DialogueManager` from this single source. `config` is a private
    /// instance field, so no type-level access exists and no caller may
    /// re-declare the 45; passing it at construction is C-1's other
    /// sanctioned shape and this accessor is what feeds it.
    var answerWindowSeconds: TimeInterval {
        TimeInterval(config.confirmationTimeoutSeconds)
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

    /// Arms the slot answer window timer — the exact mirror of
    /// `armConfirmationTimer()`. The window value is read from the SAME
    /// instance config field (`config.confirmationTimeoutSeconds`,
    /// 45 s); this timer adds no literal of its own.
    private func armSlotAnswerTimer() {
        cancelSlotAnswerTimer()
        let seconds = config.confirmationTimeoutSeconds
        slotAnswerTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            // All mutations stay on the main queue (H1).
            DispatchQueue.main.async {
                // The F6 still-open guard, mirrored: report an expiry only
                // for a window that is STILL open. Cancelling the timer is
                // not enough — a callback already queued on main survives
                // cancellation, so a frame resolved by another route (an
                // answer, a cancel, a barge-in) must not have its old
                // window close again. The arrival is silent either way
                // (FR-MTC-013); the coordinator's callback resolves the
                // frame and speaks nothing.
                guard self.state == .awaitingSlotAnswer else { return }
                self.transition(to: .idle)
                self.onSlotAnswerTimeout?()
            }
        }
    }

    private func cancelSlotAnswerTimer() {
        slotAnswerTimer?.cancel()
        slotAnswerTimer = nil
    }
}
