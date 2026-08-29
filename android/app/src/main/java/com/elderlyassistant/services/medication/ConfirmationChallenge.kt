package com.elderlyassistant.services.medication

// MARK: - Confirmation Challenge (FR-D01, FR-D02)

sealed class ConfirmationState {
    object Idle : ConfirmationState()
    data class AwaitingResponse(val deadline: Long) : ConfirmationState()
    object Confirmed : ConfirmationState()
    object Denied : ConfirmationState()
    object TimedOut : ConfirmationState()
}

sealed class ConfirmationAction {
    data class IssueChallenge(val prompt: String) : ConfirmationAction()
    object RecordTaken : ConfirmationAction()
    object ReEnterEscalation : ConfirmationAction()
    object NoAction : ConfirmationAction()
}

enum class ConfirmationResponse {
    YES, NO
}

class ConfirmationChallenge(
    private val challengeTimeoutSeconds: Long = 30
) {
    var state: ConfirmationState = ConfirmationState.Idle
        private set

    fun start(medicationName: String, confirmationDescription: String?): ConfirmationAction {
        val prompt = if (!confirmationDescription.isNullOrEmpty()) {
            "You said you've taken your $medicationName. Is that the $confirmationDescription?"
        } else {
            "Did you take your $medicationName just now?"
        }
        val deadline = System.currentTimeMillis() + (challengeTimeoutSeconds * 1000)
        state = ConfirmationState.AwaitingResponse(deadline)
        return ConfirmationAction.IssueChallenge(prompt)
    }

    fun userResponds(response: ConfirmationResponse): ConfirmationAction {
        val awaiting = state as? ConfirmationState.AwaitingResponse
            ?: return ConfirmationAction.NoAction

        if (System.currentTimeMillis() > awaiting.deadline) {
            state = ConfirmationState.TimedOut
            return ConfirmationAction.ReEnterEscalation
        }

        return when (response) {
            ConfirmationResponse.YES -> {
                state = ConfirmationState.Confirmed
                ConfirmationAction.RecordTaken
            }
            ConfirmationResponse.NO -> {
                state = ConfirmationState.Denied
                ConfirmationAction.ReEnterEscalation
            }
        }
    }

    fun timeoutExpired(): ConfirmationAction {
        if (state !is ConfirmationState.AwaitingResponse) {
            return ConfirmationAction.NoAction
        }
        state = ConfirmationState.TimedOut
        return ConfirmationAction.ReEnterEscalation
    }

    fun reset() {
        state = ConfirmationState.Idle
    }
}
