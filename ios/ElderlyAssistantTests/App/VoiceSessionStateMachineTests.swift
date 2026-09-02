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
        XCTAssertFalse(VoiceSessionState.listening.canTransition(to: .speaking))
        XCTAssertFalse(VoiceSessionState.speaking.canTransition(to: .listening))
        XCTAssertFalse(VoiceSessionState.awaitingConfirmation.canTransition(to: .listening))
        XCTAssertTrue(VoiceSessionState.stopped.canTransition(to: .error))
        XCTAssertTrue(VoiceSessionState.error.canTransition(to: .idle))
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
}
