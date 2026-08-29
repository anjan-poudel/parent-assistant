package com.elderlyassistant.services.medication

// MARK: - Escalation Engine (L2 §5.4)

sealed class EscalationAction {
    data class FireReminder(val refireCount: Int) : EscalationAction()
    data class WaitForAcknowledgement(val deadline: Long) : EscalationAction()
    object EscalateToFamilyNotifier : EscalationAction()
    object MarkMissed : EscalationAction()
    object MarkAcknowledged : EscalationAction()
    object NoAction : EscalationAction()
}

sealed class EscalationState {
    object Idle : EscalationState()
    data class ReminderFired(val refireCount: Int, val firedAt: Long) : EscalationState()
    data class AwaitingAcknowledgement(val refireCount: Int, val deadline: Long) : EscalationState()
    object Acknowledged : EscalationState()
    object Missed : EscalationState()
    object Completed : EscalationState()
}

data class EscalationResult(
    val state: EscalationState,
    val action: EscalationAction,
    val nextFireAt: Long?
)

class EscalationEngine(
    val scheduledTime: Long,               // epoch millis
    val ackWindowMinutes: Int = 5,
    val maxRefireCount: Int = 5,
    val escalationWindowMinutes: Int = 60,
    val refireIntervalMinutes: Int = 12
) {
    var state: EscalationState = EscalationState.Idle
        private set
    var currentRefireCount: Int = 0
        private set

    val escalationDeadline: Long
        get() = scheduledTime + (escalationWindowMinutes * 60_000L)

    fun nextRefireTime(after: Long): Long {
        val interval = refireIntervalMinutes * 60_000L * (currentRefireCount + 1)
        return scheduledTime + interval
    }

    private fun ackDeadline(firedAt: Long): Long {
        return firedAt + (ackWindowMinutes * 60_000L)
    }

    // MARK: - State transitions

    fun start(): EscalationResult {
        currentRefireCount = 0
        val now = System.currentTimeMillis()
        state = EscalationState.ReminderFired(0, now)
        return EscalationResult(state, EscalationAction.FireReminder(0), now)
    }

    fun reminderDelivered(deliveredAt: Long): EscalationResult {
        val deadline = ackDeadline(deliveredAt)
        state = EscalationState.AwaitingAcknowledgement(currentRefireCount, deadline)
        return EscalationResult(state, EscalationAction.WaitForAcknowledgement(deadline), null)
    }

    fun acknowledge(acknowledgedAt: Long): EscalationResult {
        val awaiting = state as? EscalationState.AwaitingAcknowledgement
            ?: return EscalationResult(state, EscalationAction.NoAction, null)

        if (acknowledgedAt <= awaiting.deadline) {
            state = EscalationState.Acknowledged
            return EscalationResult(state, EscalationAction.MarkAcknowledged, null)
        }

        return processAckAfterDeadline(acknowledgedAt)
    }

    fun ackWindowExpired(now: Long): EscalationResult {
        if (state !is EscalationState.AwaitingAcknowledgement) {
            return EscalationResult(state, EscalationAction.NoAction, null)
        }

        if (now >= escalationDeadline) {
            state = EscalationState.Missed
            return EscalationResult(state, EscalationAction.EscalateToFamilyNotifier, null)
        }

        currentRefireCount++

        if (currentRefireCount > maxRefireCount) {
            state = EscalationState.Missed
            return EscalationResult(state, EscalationAction.EscalateToFamilyNotifier, null)
        }

        val nextTime = nextRefireTime(now)
        state = EscalationState.ReminderFired(currentRefireCount, now)
        return EscalationResult(state, EscalationAction.FireReminder(currentRefireCount), nextTime)
    }

    fun markCompleted(): EscalationResult {
        state = EscalationState.Completed
        return EscalationResult(state, EscalationAction.NoAction, null)
    }

    // MARK: - Recovery (process kill + relaunch)

    fun recover(from: ScheduledReminder, now: Long): EscalationResult {
        currentRefireCount = from.refireCount
        state = from.state

        return when (from.state) {
            ReminderState.ACKNOWLEDGED, ReminderState.MISSED, ReminderState.COMPLETED ->
                EscalationResult(state, EscalationAction.NoAction, null)

            ReminderState.PENDING ->
                start()

            ReminderState.FIRED ->
                EscalationResult(
                    EscalationState.ReminderFired(currentRefireCount, now),
                    EscalationAction.FireReminder(currentRefireCount),
                    now
                )

            ReminderState.DOUBLE_DOSE_BLOCKED ->
                EscalationResult(state, EscalationAction.NoAction, null)
        }
    }

    // MARK: - Private

    private fun processAckAfterDeadline(acknowledgedAt: Long): EscalationResult {
        if (acknowledgedAt >= escalationDeadline) {
            state = EscalationState.Missed
            return EscalationResult(state, EscalationAction.EscalateToFamilyNotifier, null)
        }

        val finalRefireTime = scheduledTime + (refireIntervalMinutes * 60_000L * maxRefireCount)
        if (acknowledgedAt > finalRefireTime) {
            state = EscalationState.Missed
            return EscalationResult(state, EscalationAction.EscalateToFamilyNotifier, null)
        }

        state = EscalationState.Acknowledged
        return EscalationResult(state, EscalationAction.MarkAcknowledged, null)
    }
}
