import Foundation

// MARK: - Confirmation Challenge (FR-D01, FR-D02)

enum ConfirmationState: Equatable {
    case idle
    case awaitingResponse(deadline: Date)
    case confirmed
    case denied
    case timedOut
}

enum ConfirmationAction: Equatable {
    case issueChallenge(prompt: String)
    case recordTaken
    case reEnterEscalation
    case noAction
}

final class ConfirmationChallenge {
    let challengeTimeoutSeconds: TimeInterval   // default: 30 per FR-D02
    private(set) var state: ConfirmationState

    init(challengeTimeoutSeconds: TimeInterval = 30) {
        self.challengeTimeoutSeconds = challengeTimeoutSeconds
        self.state = .idle
    }

    func start(medicationName: String, confirmationDescription: String?) -> ConfirmationAction {
        let prompt: String
        if let desc = confirmationDescription, !desc.isEmpty {
            prompt = "You said you've taken your \(medicationName). Is that the \(desc)?"
        } else {
            prompt = "Did you take your \(medicationName) just now?"
        }
        let deadline = Date().addingTimeInterval(challengeTimeoutSeconds)
        state = .awaitingResponse(deadline: deadline)
        return .issueChallenge(prompt: prompt)
    }

    func userResponds(with response: ConfirmationResponse) -> ConfirmationAction {
        guard case .awaitingResponse(let deadline) = state else {
            return .noAction
        }

        if Date() > deadline {
            state = .timedOut
            return .reEnterEscalation
        }

        switch response {
        case .yes:
            state = .confirmed
            return .recordTaken
        case .no:
            state = .denied
            return .reEnterEscalation
        }
    }

    func timeoutExpired() -> ConfirmationAction {
        guard case .awaitingResponse = state else {
            return .noAction
        }
        state = .timedOut
        return .reEnterEscalation
    }

    func reset() {
        state = .idle
    }
}

enum ConfirmationResponse {
    case yes
    case no
}
