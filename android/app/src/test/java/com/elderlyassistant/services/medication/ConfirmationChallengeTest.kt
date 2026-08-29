package com.elderlyassistant.services.medication

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ConfirmationChallengeTest {

    @Test
    fun `start with description issues correct prompt`() {
        val challenge = ConfirmationChallenge()
        val action = challenge.start("Amlodipine", "small white tablet in the blue box")

        assertTrue(action is ConfirmationAction.IssueChallenge)
        val prompt = (action as ConfirmationAction.IssueChallenge).prompt
        assertTrue(prompt.contains("Amlodipine"))
        assertTrue(prompt.contains("small white tablet in the blue box"))
    }

    @Test
    fun `start without description uses default prompt`() {
        val challenge = ConfirmationChallenge()
        val action = challenge.start("Metformin", null)

        assertTrue(action is ConfirmationAction.IssueChallenge)
        val prompt = (action as ConfirmationAction.IssueChallenge).prompt
        assertTrue(prompt.contains("Metformin"))
        assertTrue(prompt.contains("Did you take"))
    }

    @Test
    fun `user confirms records taken`() {
        val challenge = ConfirmationChallenge()
        challenge.start("Amlodipine", null)

        val action = challenge.userResponds(ConfirmationResponse.YES)

        assertEquals(ConfirmationAction.RecordTaken, action)
        assertEquals(ConfirmationState.Confirmed, challenge.state)
    }

    @Test
    fun `user denies re-enters escalation`() {
        val challenge = ConfirmationChallenge()
        challenge.start("Amlodipine", null)

        val action = challenge.userResponds(ConfirmationResponse.NO)

        assertEquals(ConfirmationAction.ReEnterEscalation, action)
        assertEquals(ConfirmationState.Denied, challenge.state)
    }

    @Test
    fun `timeout re-enters escalation`() {
        val challenge = ConfirmationChallenge()
        challenge.start("Amlodipine", null)

        val action = challenge.timeoutExpired()

        assertEquals(ConfirmationAction.ReEnterEscalation, action)
        assertEquals(ConfirmationState.TimedOut, challenge.state)
    }

    @Test
    fun `response when not awaiting is noop`() {
        val challenge = ConfirmationChallenge()

        val action = challenge.userResponds(ConfirmationResponse.YES)

        assertEquals(ConfirmationAction.NoAction, action)
    }

    @Test
    fun `reset clears state after confirmation`() {
        val challenge = ConfirmationChallenge()
        challenge.start("Drug", null)
        challenge.userResponds(ConfirmationResponse.YES)

        challenge.reset()

        assertEquals(ConfirmationState.Idle, challenge.state)
    }
}
