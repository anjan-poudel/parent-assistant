package com.elderlyassistant.services.medication

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class EscalationEngineTest {

    @Test
    fun `start fires initial reminder`() {
        val engine = EscalationEngine(System.currentTimeMillis())
        val result = engine.start()

        assertTrue(result.action is EscalationAction.FireReminder)
        assertEquals(0, (result.action as EscalationAction.FireReminder).refireCount)
    }

    @Test
    fun `acknowledge within window marks acknowledged`() {
        val engine = EscalationEngine(System.currentTimeMillis())
        engine.start()
        engine.reminderDelivered(System.currentTimeMillis())

        val result = engine.acknowledge(System.currentTimeMillis())

        assertEquals(EscalationAction.MarkAcknowledged, result.action)
        assertEquals(EscalationState.Acknowledged, engine.state)
    }

    @Test
    fun `acknowledge after deadline but within escalation still accepted`() {
        val engine = EscalationEngine(System.currentTimeMillis(), ackWindowMinutes = 5)
        engine.start()
        val deliveredAt = System.currentTimeMillis()
        engine.reminderDelivered(deliveredAt)

        val lateAck = deliveredAt + (6 * 60_000) // 6 minutes later
        val result = engine.acknowledge(lateAck)

        assertEquals(EscalationAction.MarkAcknowledged, result.action)
    }

    @Test
    fun `ack window expired triggers refire`() {
        val scheduledTime = System.currentTimeMillis()
        val engine = EscalationEngine(
            scheduledTime = scheduledTime,
            ackWindowMinutes = 5,
            maxRefireCount = 5,
            escalationWindowMinutes = 60,
            refireIntervalMinutes = 12
        )
        engine.start()
        engine.reminderDelivered(scheduledTime)

        val result = engine.ackWindowExpired(scheduledTime + (6 * 60_000))

        assertTrue(result.action is EscalationAction.FireReminder)
        assertEquals(1, (result.action as EscalationAction.FireReminder).refireCount)
    }

    @Test
    fun `five refires then escalate`() {
        val scheduledTime = System.currentTimeMillis()
        val engine = EscalationEngine(
            scheduledTime = scheduledTime,
            ackWindowMinutes = 5,
            maxRefireCount = 5,
            escalationWindowMinutes = 60,
            refireIntervalMinutes = 12
        )
        engine.start()
        engine.reminderDelivered(scheduledTime)

        for (i in 1..5) {
            val refireTime = scheduledTime + (i * 12 * 60_000L)
            engine.ackWindowExpired(refireTime)
        }

        val afterFifth = scheduledTime + (5 * 12 * 60_000L + 6 * 60_000L)
        val result = engine.ackWindowExpired(afterFifth)

        assertEquals(EscalationAction.EscalateToFamilyNotifier, result.action)
        assertEquals(EscalationState.Missed, engine.state)
    }

    @Test
    fun `escalation deadline enforced`() {
        val scheduledTime = System.currentTimeMillis()
        val engine = EscalationEngine(
            scheduledTime = scheduledTime,
            escalationWindowMinutes = 60
        )
        engine.start()
        engine.reminderDelivered(scheduledTime)

        val pastDeadline = scheduledTime + (61 * 60_000)
        val result = engine.ackWindowExpired(pastDeadline)

        assertEquals(EscalationAction.EscalateToFamilyNotifier, result.action)
    }

    @Test
    fun `recover from pending state`() {
        val engine = EscalationEngine(System.currentTimeMillis())
        val storedReminder = ScheduledReminder(
            id = java.util.UUID.randomUUID(),
            medicationEntryId = java.util.UUID.randomUUID(),
            scheduledAt = System.currentTimeMillis(),
            refireCount = 0,
            escalationDeadline = System.currentTimeMillis() + 3_600_000,
            state = ReminderState.PENDING,
            lastFiredAt = null,
            acknowledgedAt = null
        )

        val result = engine.recover(storedReminder, System.currentTimeMillis())

        assertTrue(result.action is EscalationAction.FireReminder)
    }

    @Test
    fun `recover from acknowledged does nothing`() {
        val engine = EscalationEngine(System.currentTimeMillis())
        val storedReminder = ScheduledReminder(
            id = java.util.UUID.randomUUID(),
            medicationEntryId = java.util.UUID.randomUUID(),
            scheduledAt = System.currentTimeMillis(),
            refireCount = 2,
            escalationDeadline = System.currentTimeMillis() + 3_600_000,
            state = ReminderState.ACKNOWLEDGED,
            lastFiredAt = System.currentTimeMillis(),
            acknowledgedAt = System.currentTimeMillis()
        )

        val result = engine.recover(storedReminder, System.currentTimeMillis())

        assertEquals(EscalationAction.NoAction, result.action)
    }
}
