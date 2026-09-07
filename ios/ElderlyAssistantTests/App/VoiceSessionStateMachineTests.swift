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
}
