import XCTest
@testable import ElderlyAssistant

final class VoiceSessionStateMachineTests: XCTestCase {

    @MainActor
    func testLegalTransitionsFollowSpecDiagram() {
        let machine = VoiceSessionStateMachine()
        XCTAssertEqual(machine.state, .stopped)

        machine.transition(to: .idle)
        XCTAssertEqual(machine.state, .idle)

        machine.transition(to: .listening)
        machine.transition(to: .transcribing)
        machine.transition(to: .understanding)
        machine.transition(to: .speaking)
        machine.transition(to: .idle)
        XCTAssertEqual(machine.state, .idle)
    }

    @MainActor
    func testChallengeIsReachableFromUnderstanding() {
        let machine = VoiceSessionStateMachine()
        machine.transition(to: .idle)
        machine.transition(to: .listening)
        machine.transition(to: .transcribing)
        machine.transition(to: .understanding)
        // The router issues the challenge while still "understanding".
        machine.transition(to: .awaitingConfirmation)
        XCTAssertEqual(machine.state, .awaitingConfirmation)
        machine.transition(to: .idle)
        XCTAssertEqual(machine.state, .idle)
    }

    @MainActor
    func testIllegalTransitionsAreRejectedByTheTable() {
        // The canTransition table itself is the contract — assert the
        // rejections directly (attempting them would hit the debug
        // assertion).
        XCTAssertTrue(VoiceSessionState.idle.canTransition(to: .listening))
        XCTAssertFalse(VoiceSessionState.speaking.canTransition(to: .listening))
        XCTAssertFalse(VoiceSessionState.awaitingConfirmation.canTransition(to: .listening))
        XCTAssertTrue(VoiceSessionState.stopped.canTransition(to: .error))
        XCTAssertTrue(VoiceSessionState.error.canTransition(to: .idle))
        // The medication challenge fires while the router is still
        // understanding — that transition must stay legal.
        XCTAssertTrue(VoiceSessionState.understanding.canTransition(to: .awaitingConfirmation))
        // Async replies and re-prompts speak AFTER the pipeline is back
        // at idle — that transition must stay legal too.
        XCTAssertTrue(VoiceSessionState.idle.canTransition(to: .speaking))
    }

    /// C12: the confirmation challenge expires and returns to idle.
    @MainActor
    func testConfirmationTimeoutFiresAndClears() {
        let machine = VoiceSessionStateMachine(
            config: .init(confirmationTimeoutSeconds: 1))
        let timeoutExpectation = expectation(description: "confirmation timeout")
        machine.onConfirmationTimeout = {
            timeoutExpectation.fulfill()
        }
        machine.transition(to: .idle)
        machine.transition(to: .listening)
        machine.transition(to: .transcribing)
        machine.transition(to: .understanding)
        machine.transition(to: .awaitingConfirmation)

        wait(for: [timeoutExpectation], timeout: 3.0)
        XCTAssertEqual(machine.state, .idle)
    }

    /// C12: answering before the deadline cancels the timer — no late
    /// timeout callback after the user already said yes/no.
    @MainActor
    func testAnsweringCancelsTheTimeoutTimer() {
        let machine = VoiceSessionStateMachine(
            config: .init(confirmationTimeoutSeconds: 1))
        var timedOut = false
        machine.onConfirmationTimeout = { timedOut = true }
        machine.transition(to: .idle)
        machine.transition(to: .awaitingConfirmation)
        machine.transition(to: .idle)   // user answered

        let lateCheck = expectation(description: "no late timeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            XCTAssertFalse(timedOut, "timeout fired after the answer cancelled it")
            lateCheck.fulfill()
        }
        wait(for: [lateCheck], timeout: 3.0)
    }

    // MARK: - Confirmation window (voice app launcher F6, F14)

    /// [F14] `openConfirmationWindow()` opens the window from states the
    /// transition table cannot reach `.awaitingConfirmation` from directly.
    ///
    /// A launch question can arrive while the session sits in `.error`
    /// (the pipeline just failed) or `.stopped` (before the pipeline is
    /// primed). The old bare `transition(to: .awaitingConfirmation)` could
    /// only no-op there — assert in debug, silently do nothing in release —
    /// leaving the pended question with no timer and no clearer. The
    /// bridge through `.idle` keeps every edge legal and the timer real.
    @MainActor
    func testOpenConfirmationWindowBridgesFromErrorAndStopped() {
        for start in [VoiceSessionState.error, .stopped] {
            let machine = VoiceSessionStateMachine(
                config: .init(confirmationTimeoutSeconds: 1))
            let timeoutExpectation = expectation(description: "window armed from \(start)")
            machine.onConfirmationTimeout = { timeoutExpectation.fulfill() }
            machine.transition(to: start)
            XCTAssertEqual(machine.state, start)

            XCTAssertTrue(machine.openConfirmationWindow())
            XCTAssertEqual(machine.state, .awaitingConfirmation,
                           "the window is open, not merely attempted")
            wait(for: [timeoutExpectation], timeout: 3.0)
            XCTAssertEqual(machine.state, .idle)
        }
    }

    /// [F14] The window is idempotent: a flow that pends while the window
    /// is already open keeps the ORIGINAL budget (no re-arm, no second
    /// timer racing the first).
    @MainActor
    func testTransitionViaIdleBridgesErrorToSpeaking() {
        // [LAUNCH-TRANSITION-FIX] The device log asserted `error →
        // speaking` at launch: the pipeline reported `.error` (mic boot),
        // then `.idle` while push speech still played. Both bridge edges
        // are legal — `error → idle`, `idle → speaking` — so the bridge
        // travels them instead of hitting the illegal direct edge.
        let machine = VoiceSessionStateMachine()
        machine.transition(to: .error)
        XCTAssertEqual(machine.state, .error)

        machine.transitionViaIdle(to: .speaking)
        XCTAssertEqual(machine.state, .speaking,
                       "error → speaking must bridge through idle")
    }

    /// [LAUNCH-TRANSITION-FIX] A capture event landing while the session
    /// is still `.stopped` (recycle + immediate capture) has no direct
    /// edge to `.listening` — the bridge travels `stopped → idle →
    /// listening`, both legal.
    @MainActor
    func testTransitionViaIdleBridgesStoppedToListening() {
        let machine = VoiceSessionStateMachine()
        XCTAssertEqual(machine.state, .stopped)

        machine.transitionViaIdle(to: .listening)
        XCTAssertEqual(machine.state, .listening,
                       "stopped → listening must bridge through idle")
    }

    /// [LAUNCH-TRANSITION-FIX] Direct legal edges are untouched by the
    /// bridge — no spurious `.idle` hop in the middle of a live cycle.
    @MainActor
    func testTransitionViaIdleLeavesLegalEdgesUntouched() {
        let machine = VoiceSessionStateMachine()
        machine.transition(to: .idle)
        machine.transitionViaIdle(to: .listening)
        XCTAssertEqual(machine.state, .listening,
                       "an idle → listening edge needs no bridge")

        machine.transitionViaIdle(to: .transcribing)
        XCTAssertEqual(machine.state, .transcribing,
                       "an already-legal edge must land in ONE step")
    }

    /// [F14] The window is idempotent: a flow that pends while the window
    /// is already open keeps the ORIGINAL budget (no re-arm, no second
    /// timer racing the first).
    @MainActor
    func testOpenConfirmationWindowIsIdempotent() {
        let machine = VoiceSessionStateMachine(
            config: .init(confirmationTimeoutSeconds: 1))
        var timeouts = 0
        machine.onConfirmationTimeout = { timeouts += 1 }
        machine.transition(to: .idle)
        XCTAssertTrue(machine.openConfirmationWindow())
        XCTAssertTrue(machine.openConfirmationWindow())
        XCTAssertEqual(machine.state, .awaitingConfirmation)

        let settled = expectation(description: "exactly one expiry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            XCTAssertEqual(timeouts, 1, "re-opening must not arm a second timer")
            settled.fulfill()
        }
        wait(for: [settled], timeout: 3.0)
    }

    /// [F6] A window that was CLOSED before its deadline never reports an
    /// expiry — even though the callback may already be queued on main.
    ///
    /// This is what keeps a tap-resolved launch question silent: the elder
    /// tapped the app's tile instead of answering, the pend was cleared and
    /// the window closed, and the queued expiry must not announce "Time is
    /// up, I won't open it" over the app that had just opened.
    @MainActor
    func testExpiryIsNotReportedForAWindowClosedEarly() {
        let machine = VoiceSessionStateMachine(
            config: .init(confirmationTimeoutSeconds: 1))
        var timedOut = false
        machine.onConfirmationTimeout = { timedOut = true }
        machine.transition(to: .idle)
        XCTAssertTrue(machine.openConfirmationWindow())
        machine.transition(to: .idle)   // resolved by another route

        let lateCheck = expectation(description: "no expiry for a closed window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            XCTAssertFalse(timedOut, "a closed window must not report an expiry")
            lateCheck.fulfill()
        }
        wait(for: [lateCheck], timeout: 3.0)
    }

    // MARK: - Talk-crash regression anchors (TALK-CRASH-FIX, 2026-09-07)

    /// The DEBUG assertion crashes behind "the app crashes when I tap the
    /// Talk button while it's listening" were ILLEGAL transitions this
    /// machine's own table rejected. Pinning the rejection the fix
    /// guarantees never gets attempted:
    ///
    ///  `.stopped → .understanding` — a stale capture completion
    ///      (settled by the recycle's cancel()) used to run the
    ///      pipeline's post-capture tail (`state = .routing` →
    ///      `.understanding`) against the session `recoverVoiceCycle()`
    ///      had just left `.stopped`. The pipeline's capture-generation
    ///      guard now drops stale tails before they reach this mapping.
    ///
    /// The table ALSO used to reject `.stopped → .speaking` — the
    /// re-prompt speaking before the recycle's restart completed;
    /// `recoverVoiceCycle` still defers that speech to the restart
    /// completion (`.stopped → .idle → .speaking`). STOPPED-SPEAKING-FIX
    /// (2026-09-08) makes it LEGAL, mirroring `.idle`: push speech — the
    /// launch morning briefing (fires before the pipeline starts:
    /// briefing_fired → pipeline_started), notification read-alouds — can
    /// legitimately start while the session is `.stopped`, before the
    /// pipeline has been primed. `.speaking → .stopped` stays legal so
    /// the round trip closes when the utterance ends and the pipeline
    /// state re-lands.
    @MainActor
    func testStoppedAcceptsPushSpeechButRejectsTheStaleCaptureTail() {
        XCTAssertFalse(VoiceSessionState.stopped.canTransition(to: .understanding),
                       "a stale capture tail must never drive .stopped → .understanding")
        XCTAssertTrue(VoiceSessionState.stopped.canTransition(to: .speaking),
                      "push speech (launch briefing, read-aloud) may start while .stopped")
        XCTAssertTrue(VoiceSessionState.speaking.canTransition(to: .stopped),
                      ".speaking → .stopped must stay legal so the round trip closes")
    }

    /// The reset path needs NO new transition-table semantics: holding
    /// the Talk button mid-capture recycles the pipeline, which travels
    /// existing legal transitions (busy → .stopped on stop, .stopped →
    /// .idle on restart). A tap after the reset still re-prompts through
    /// the legal .idle → .speaking async-reply transition.
    @MainActor
    func testResetPathIsFullyLegalWithoutNewTransitions() {
        let machine = VoiceSessionStateMachine()
        machine.transition(to: .idle)
        machine.transition(to: .listening)   // user holds the Talk button mid-capture
        machine.transition(to: .stopped)     // recycle: pipeline stop()
        XCTAssertEqual(machine.state, .stopped)
        machine.transition(to: .idle)        // recycle: restart lands
        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(VoiceSessionState.idle.canTransition(to: .speaking))
        XCTAssertEqual(machine.state, .idle)
    }

    // MARK: - Launch push-speech anchors (STOPPED-SPEAKING-FIX, 2026-09-08)

    /// Launch-briefing shape of the crash this fix removes: the morning
    /// briefing speaks BEFORE the voice pipeline starts (log order
    /// briefing_fired → pipeline_started) while the session is still
    /// `.stopped` — `SpeechNoteForwarder.onStarted` →
    /// `noteSpeakingStarted()` → `speakingCount` 0→1 promotes the
    /// pre-speech-excluded `.stopped` session through
    /// `handlePipelineState` to `.speaking`. That used to hit the DEBUG
    /// assertionFailure ("Illegal VoiceSessionState transition:
    /// stopped → speaking"). The promotion must land `.speaking`, and a
    /// speaking-ended fallback to `.idle` (the pipeline has since
    /// reported) must close the round trip legally.
    @MainActor
    func testLaunchBriefingSpeaksFromStoppedAndSettlesToIdle() {
        let machine = VoiceSessionStateMachine()
        XCTAssertEqual(machine.state, .stopped)   // briefing fires pre-pipeline
        machine.transition(to: .speaking)          // speakingCount 0→1 promotion
        XCTAssertEqual(machine.state, .speaking)
        machine.transition(to: .idle)              // utterance ended, pipeline idle
        XCTAssertEqual(machine.state, .idle)
    }

    /// `supportsTalkReset` — the hold-to-reset offer set: the stuck /
    /// active cycle plus the dead states get the reset; `.speaking` and
    /// `.awaitingConfirmation` keep plain tap semantics.
    @MainActor
    func testTalkResetIsOfferedExactlyFromTheResetStates() {
        let offered: [VoiceSessionState] = [.idle, .listening, .transcribing,
                                            .understanding, .error, .stopped]
        for state in offered {
            XCTAssertTrue(state.supportsTalkReset, "\(state) should offer the hold-to-reset")
        }
        for state in [VoiceSessionState.speaking, .awaitingConfirmation] {
            XCTAssertFalse(state.supportsTalkReset,
                           "\(state) must NOT offer the hold-to-reset")
        }
    }

    // MARK: - Slot answer window (T-135, FR-MTC-013/014)

    /// FR-MTC-014: the new edges are the confirmation edges MIRRORED —
    /// entry from `.idle` and the busy states (exactly the set that
    /// accepts `.awaitingConfirmation`), exit to `[.idle, .error,
    /// .stopped]`. `.awaitingConfirmation`, `.error` and `.stopped` have
    /// no direct entry: the opener bridges them through `.idle` (asserted
    /// in the open-from-every-state row below), and a bare transition
    /// there stays refused. The refusals are asserted on the table itself
    /// — attempting one would hit the debug assertion, exactly as the
    /// confirmation rows above note.
    @MainActor
    func testSlotAnswerEdgesMirrorTheConfirmationTable() {
        // Entry: `.idle` and the busy set.
        XCTAssertTrue(VoiceSessionState.idle.canTransition(to: .awaitingSlotAnswer))
        for busy in [VoiceSessionState.listening, .transcribing, .understanding, .speaking] {
            XCTAssertTrue(busy.canTransition(to: .awaitingSlotAnswer),
                          "\(busy) must reach the slot answer window directly")
        }
        // No direct entry from the remaining states — the bridge carries
        // them.
        XCTAssertFalse(VoiceSessionState.awaitingConfirmation
            .canTransition(to: .awaitingSlotAnswer))
        XCTAssertFalse(VoiceSessionState.error.canTransition(to: .awaitingSlotAnswer))
        XCTAssertFalse(VoiceSessionState.stopped.canTransition(to: .awaitingSlotAnswer))
        // Exit: the confirmation window's own exits...
        XCTAssertTrue(VoiceSessionState.awaitingSlotAnswer.canTransition(to: .idle))
        XCTAssertTrue(VoiceSessionState.awaitingSlotAnswer.canTransition(to: .error))
        XCTAssertTrue(VoiceSessionState.awaitingSlotAnswer.canTransition(to: .stopped))
        // ...and nothing else — no direct edge to another window or the
        // busy states (resolutions leave through the funnel's legal
        // edges; the two windows never coexist).
        XCTAssertFalse(VoiceSessionState.awaitingSlotAnswer.canTransition(to: .listening))
        XCTAssertFalse(VoiceSessionState.awaitingSlotAnswer
            .canTransition(to: .awaitingConfirmation))
        // The dialogue window owns the turn: no hold-to-reset, exactly
        // like the confirmation challenge (FR-MTC-014).
        XCTAssertFalse(VoiceSessionState.awaitingSlotAnswer.supportsTalkReset,
                       "the slot answer window must not offer the hold-to-reset")
    }

    /// FR-MTC-014 scenario 1: the window opens from EVERY legal state —
    /// directly from `.idle`/the busy set, through the `.idle` bridge
    /// from `.awaitingConfirmation`/`.error`/`.stopped` (both windows
    /// never coexist: bridging out of a confirmation challenge closes
    /// it), and idempotently when it is already open. Every attempt lands
    /// `.awaitingSlotAnswer` and the exits travel the legal edges.
    @MainActor
    func testOpenSlotAnswerWindowBridgesFromEveryLegalState() {
        // (start, the legal drive into it from the initial `.stopped`).
        let drives: [(VoiceSessionState, [VoiceSessionState])] = [
            (.idle, [.idle]),
            (.listening, [.idle, .listening]),
            (.transcribing, [.idle, .listening, .transcribing]),
            (.understanding, [.idle, .listening, .transcribing, .understanding]),
            (.speaking, [.idle, .speaking]),
            (.awaitingConfirmation, [.idle, .awaitingConfirmation]),
            (.awaitingSlotAnswer, [.idle, .awaitingSlotAnswer]),
            (.error, [.error]),
            (.stopped, []),
        ]
        for (start, drive) in drives {
            let machine = VoiceSessionStateMachine()   // default 45 s window
            for step in drive { machine.transition(to: step) }
            XCTAssertEqual(machine.state, start, "legal drive into \(start)")

            XCTAssertTrue(machine.openSlotAnswerWindow(),
                          "the window must open from \(start)")
            XCTAssertEqual(machine.state, .awaitingSlotAnswer,
                           "the window is open, not merely attempted (from \(start))")
            XCTAssertTrue(machine.openSlotAnswerWindow(),
                          "re-opening from \(start) reports the open window")
            XCTAssertEqual(machine.state, .awaitingSlotAnswer)

            // Leaving follows the mirrored exit edges (the funnel's
            // route); the close cancels the timer.
            machine.transition(to: .idle)
            XCTAssertEqual(machine.state, .idle)
        }
    }

    /// NFR-MTC-001: the answer window adds NO new timing literal — the
    /// frame deadline reuses the machine instance's confirmation config
    /// field (`Config.confirmationTimeoutSeconds`, 45 s). The 1 s-injected
    /// expiry row below proves the slot timer READS that field; this row
    /// pins the shipped default the 22 s/45 s/60 s coupling names.
    @MainActor
    func testAnswerWindowValueStaysSingleSourcedAt45Seconds() {
        XCTAssertEqual(VoiceSessionStateMachine.Config().confirmationTimeoutSeconds, 45,
                       "the slot window must stay owned by the confirmation config field")
    }

    /// FR-MTC-013/014: the window expires on the injected instance-config
    /// value (1 s here — proof the slot timer reads
    /// `confirmationTimeoutSeconds` and not a literal), returns to
    /// `.idle`, and is SILENT: the slot callback fires and the
    /// confirmation timeout recorder is never touched (ADR-MTC-08 — the
    /// coordinator's slot handler speaks nothing; no spoken line exists
    /// on this path).
    @MainActor
    func testSlotAnswerTimeoutFiresSilentlyAndReturnsToIdle() {
        let machine = VoiceSessionStateMachine(
            config: .init(confirmationTimeoutSeconds: 1))
        let slotExpiry = expectation(description: "slot answer window expiry")
        var slotTimeouts = 0
        var confirmationTimeouts = 0
        machine.onSlotAnswerTimeout = {
            slotTimeouts += 1
            slotExpiry.fulfill()
        }
        machine.onConfirmationTimeout = { confirmationTimeouts += 1 }

        machine.transition(to: .idle)
        XCTAssertTrue(machine.openSlotAnswerWindow())
        XCTAssertEqual(machine.state, .awaitingSlotAnswer,
                       "the window is open, not merely attempted")

        wait(for: [slotExpiry], timeout: 3.0)
        XCTAssertEqual(machine.state, .idle,
                       "the expired window returns to idle through a legal edge")
        XCTAssertEqual(slotTimeouts, 1)
        XCTAssertEqual(confirmationTimeouts, 0,
                       "the slot expiry must never touch the confirmation recorder")
    }

    /// FR-MTC-013 / L2-D6: a re-probe restamps the deadline — the frame
    /// gets a full fresh window from the refresh, and the ORIGINAL
    /// deadline passing must not close the refreshed window. The final
    /// single-fire count also proves the refresh cancelled the old timer
    /// (an un-cancelled one would fire a second callback).
    @MainActor
    func testRefreshRestampsTheFullSlotWindow() {
        let machine = VoiceSessionStateMachine(
            config: .init(confirmationTimeoutSeconds: 2))
        var slotTimeouts = 0
        let slotExpiry = expectation(description: "refreshed slot window expiry")
        machine.onSlotAnswerTimeout = {
            slotTimeouts += 1
            slotExpiry.fulfill()
        }
        machine.transition(to: .idle)
        XCTAssertTrue(machine.openSlotAnswerWindow())

        // Re-probe at half the window (t0 + 1.0 of 2.0): full restamp.
        let refreshed = expectation(description: "re-probe refresh")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(machine.refreshSlotAnswerWindow())
            XCTAssertEqual(machine.state, .awaitingSlotAnswer)
            refreshed.fulfill()
        }
        wait(for: [refreshed], timeout: 2.0)

        // The ORIGINAL deadline (t0 + 2.0) passes with no callback; the
        // refreshed one is still ~0.7 s away.
        let originalDeadlinePassed = expectation(description: "original deadline passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {   // ≈ t0 + 2.3
            XCTAssertEqual(slotTimeouts, 0,
                           "the original deadline must not close a refreshed window")
            originalDeadlinePassed.fulfill()
        }
        wait(for: [originalDeadlinePassed], timeout: 2.0)

        wait(for: [slotExpiry], timeout: 2.0)   // ≈ t0 + 3.0
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(slotTimeouts, 1,
                       "one window, one expiry: the refresh cancelled the old timer")
    }

    /// FR-MTC-014 scenario 2: every resolution cancels the slot timer —
    /// a window closed before its deadline never fires its callback
    /// (mirror of the confirmation `testAnsweringCancelsTheTimeoutTimer`
    /// row).
    @MainActor
    func testResolvingTheSlotWindowCancelsTheTimer() {
        let machine = VoiceSessionStateMachine(
            config: .init(confirmationTimeoutSeconds: 1))
        var slotTimeouts = 0
        machine.onSlotAnswerTimeout = { slotTimeouts += 1 }
        machine.transition(to: .idle)
        XCTAssertTrue(machine.openSlotAnswerWindow())
        machine.transition(to: .idle)   // answer merged / cancel / barge-in

        let settled = expectation(description: "no late slot timeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            XCTAssertEqual(slotTimeouts, 0,
                           "a resolved window must not fire its timeout")
            XCTAssertEqual(machine.state, .idle)
            settled.fulfill()
        }
        wait(for: [settled], timeout: 3.0)
    }

    /// FR-MTC-014 scenario 3 ([F6] mirrored): a late callback is a no-op
    /// once the state moved on. The window is left through a NON-idle
    /// legal edge, so a callback that ran would be visible twice over:
    /// it would count a timeout AND drag the session back to `.idle` —
    /// the state must still read `.error` when the deadline passes. (The
    /// still-open guard re-checks the state on arrival because a callback
    /// already queued on main survives cancellation.)
    @MainActor
    func testLateSlotTimerCallbackIsDroppedOnceTheStateMovedOn() {
        let machine = VoiceSessionStateMachine(
            config: .init(confirmationTimeoutSeconds: 1))
        var slotTimeouts = 0
        machine.onSlotAnswerTimeout = { slotTimeouts += 1 }
        machine.transition(to: .idle)
        XCTAssertTrue(machine.openSlotAnswerWindow())
        machine.transition(to: .error)   // a legal exit before the deadline

        let settled = expectation(description: "the late callback is a no-op")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            XCTAssertEqual(slotTimeouts, 0,
                           "the late slot callback must be a no-op")
            XCTAssertEqual(machine.state, .error,
                           "a fired callback would have moved the session to .idle")
            settled.fulfill()
        }
        wait(for: [settled], timeout: 3.0)
    }

    /// The opener is idempotent: opening while the window is already open
    /// keeps the ORIGINAL budget (no second timer racing the first) —
    /// the same discipline `testOpenConfirmationWindowIsIdempotent`
    /// pins for the confirmation challenge.
    @MainActor
    func testOpenSlotAnswerWindowReopenIsIdempotent() {
        let machine = VoiceSessionStateMachine(
            config: .init(confirmationTimeoutSeconds: 1))
        var slotTimeouts = 0
        machine.onSlotAnswerTimeout = { slotTimeouts += 1 }
        machine.transition(to: .idle)
        XCTAssertTrue(machine.openSlotAnswerWindow())
        XCTAssertTrue(machine.openSlotAnswerWindow())
        XCTAssertEqual(machine.state, .awaitingSlotAnswer)

        let settled = expectation(description: "exactly one expiry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            XCTAssertEqual(slotTimeouts, 1,
                           "re-opening must not arm a second timer")
            settled.fulfill()
        }
        wait(for: [settled], timeout: 3.0)
    }

    /// `refreshSlotAnswerWindow()` never OPENS a window — it restamps one
    /// that is already open (the re-probe path). Outside
    /// `.awaitingSlotAnswer` it reports false and changes nothing.
    @MainActor
    func testRefreshIsRefusedOutsideTheSlotWindow() {
        let machine = VoiceSessionStateMachine()
        XCTAssertFalse(machine.refreshSlotAnswerWindow())
        XCTAssertEqual(machine.state, .stopped)

        machine.transition(to: .idle)
        XCTAssertFalse(machine.refreshSlotAnswerWindow())
        XCTAssertEqual(machine.state, .idle)
    }
}
