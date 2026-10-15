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

    /// Kept and extended (review-l2 R-2): the before-deadline check now
    /// rides an INJECTED shorter window — the call site passes a named
    /// value, never a literal — and the same injected seam is then driven
    /// past its window, where the timeout path re-enters escalation on
    /// the shorter window (not the named default).
    func testLateResponseStillProcessesIfBeforeDeadline() {
        let injectedWindowSeconds: TimeInterval = 0.25

        let beforeDeadline = ConfirmationChallenge(challengeTimeoutSeconds: injectedWindowSeconds)
        _ = beforeDeadline.start(medicationName: "Metformin", confirmationDescription: nil)

        XCTAssertEqual(beforeDeadline.challengeTimeoutSeconds, injectedWindowSeconds,
                       "the challenge holds the injected window, not the named default")
        guard case .awaitingResponse(let deadline) = beforeDeadline.state else {
            return XCTFail("expected awaitingResponse, got \(beforeDeadline.state)")
        }
        XCTAssertEqual(deadline.timeIntervalSinceNow, injectedWindowSeconds, accuracy: 0.5,
                       "the issued deadline is now plus the injected window")

        // A response inside the window still records.
        let action = beforeDeadline.userResponds(with: .yes)
        XCTAssertEqual(action, .recordTaken)

        // The same seam, window elapsed unanswered: the timeout path
        // re-enters escalation on the SHORTER injected window.
        let elapsed = ConfirmationChallenge(challengeTimeoutSeconds: injectedWindowSeconds)
        _ = elapsed.start(medicationName: "Metformin", confirmationDescription: nil)
        Thread.sleep(forTimeInterval: injectedWindowSeconds * 2)

        XCTAssertEqual(elapsed.userResponds(with: .yes), .reEnterEscalation)
        XCTAssertEqual(elapsed.state, .timedOut)
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

    // MARK: - Single-source challenge window (review-l2 R-2)

    /// The initializer default is a REFERENCE to
    /// `ConfirmationChallenge.defaultChallengeTimeoutSeconds` — no literal
    /// remains in the initializer — and the named home itself preserves
    /// the shipped FR-D02 window, so the hoist is behavior-preserving.
    func testDefaultTimeoutComposesFromTheNamedHome() {
        XCTAssertEqual(ConfirmationChallenge().challengeTimeoutSeconds,
                       ConfirmationChallenge.defaultChallengeTimeoutSeconds,
                       "constructing without a value yields exactly the named home")

        let shippedFRD02WindowSeconds: TimeInterval = 30
        XCTAssertEqual(ConfirmationChallenge.defaultChallengeTimeoutSeconds, shippedFRD02WindowSeconds,
                       "the named home carries the shipped 30-second window unchanged")
    }

    /// The walk's window type derives from the SAME named home (design-l2
    /// D4): `AckClarificationConfig()` equals the challenge timeout by
    /// construction, and a shorter window is injected through the
    /// initializer seam for tests.
    func testAckClarificationConfigComposesFromTheSameHome() {
        XCTAssertEqual(AckClarificationConfig().responseWindowSeconds,
                       ConfirmationChallenge.defaultChallengeTimeoutSeconds,
                       "no second constant: the walk window composes from the same home")

        let injectedWindowSeconds: TimeInterval = 5
        XCTAssertEqual(
            AckClarificationConfig(responseWindowSeconds: injectedWindowSeconds).responseWindowSeconds,
            injectedWindowSeconds,
            "tests can inject a shorter window through the same seam"
        )
    }
}
