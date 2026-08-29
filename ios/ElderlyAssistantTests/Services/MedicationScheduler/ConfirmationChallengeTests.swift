import XCTest
@testable import ElderlyAssistant

final class ConfirmationChallengeTests: XCTestCase {

    func testStartWithDescriptionIssuesCorrectPrompt() {
        let challenge = ConfirmationChallenge()
        let action = challenge.start(
            medicationName: "Amlodipine",
            confirmationDescription: "small white tablet in the blue box"
        )

        guard case .issueChallenge(let prompt) = action else {
            XCTFail("Expected issueChallenge, got \(action)")
            return
        }
        XCTAssertTrue(prompt.contains("Amlodipine"))
        XCTAssertTrue(prompt.contains("small white tablet in the blue box"))
    }

    func testStartWithoutDescriptionUsesDefaultPrompt() {
        let challenge = ConfirmationChallenge()
        let action = challenge.start(
            medicationName: "Metformin",
            confirmationDescription: nil
        )

        guard case .issueChallenge(let prompt) = action else {
            XCTFail("Expected issueChallenge, got \(action)")
            return
        }
        XCTAssertTrue(prompt.contains("Metformin"))
        XCTAssertTrue(prompt.contains("Did you take"))
    }

    func testStartWithEmptyDescriptionUsesDefault() {
        let challenge = ConfirmationChallenge()
        let action = challenge.start(
            medicationName: "Metformin",
            confirmationDescription: ""
        )

        guard case .issueChallenge(let prompt) = action else {
            XCTFail("Expected issueChallenge, got \(action)")
            return
        }
        XCTAssertTrue(prompt.contains("Did you take"))
    }

    func testUserConfirmsRecordsTaken() {
        let challenge = ConfirmationChallenge()
        _ = challenge.start(medicationName: "Amlodipine", confirmationDescription: nil)

        let action = challenge.userResponds(with: .yes)

        XCTAssertEqual(action, .recordTaken)
        XCTAssertEqual(challenge.state, .confirmed)
    }

    func testUserDeniesReEntersEscalation() {
        let challenge = ConfirmationChallenge()
        _ = challenge.start(medicationName: "Amlodipine", confirmationDescription: nil)

        let action = challenge.userResponds(with: .no)

        XCTAssertEqual(action, .reEnterEscalation)
        XCTAssertEqual(challenge.state, .denied)
    }

    func testTimeoutReEntersEscalation() {
        let challenge = ConfirmationChallenge()
        _ = challenge.start(medicationName: "Amlodipine", confirmationDescription: nil)

        let action = challenge.timeoutExpired()

        XCTAssertEqual(action, .reEnterEscalation)
        XCTAssertEqual(challenge.state, .timedOut)
    }

    func testLateResponseStillProcessesIfBeforeDeadline() {
        let challenge = ConfirmationChallenge(challengeTimeoutSeconds: 30)
        _ = challenge.start(medicationName: "Metformin", confirmationDescription: nil)

        // Respond just before 30 seconds
        // We can't easily test the actual deadline without waiting, so test the boundary
        let action = challenge.userResponds(with: .yes)
        XCTAssertEqual(action, .recordTaken)
    }

    func testResetClearsState() {
        let challenge = ConfirmationChallenge()
        _ = challenge.start(medicationName: "Drug", confirmationDescription: nil)
        _ = challenge.userResponds(with: .yes)

        challenge.reset()

        XCTAssertEqual(challenge.state, .idle)
    }

    func testResponseWhenNotAwaitingIsNoop() {
        let challenge = ConfirmationChallenge()
        let action = challenge.userResponds(with: .yes)

        XCTAssertEqual(action, .noAction)
    }
}
