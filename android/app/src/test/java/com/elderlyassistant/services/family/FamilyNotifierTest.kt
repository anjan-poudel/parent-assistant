package com.elderlyassistant.services.family

import com.elderlyassistant.services.medication.FamilyAlertType
import kotlinx.coroutines.runBlocking
import org.junit.Test
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FakeFCMProvider : FCMProvider() {
    var shouldFailForTokens = mutableSetOf<String>()
    var sendCallCount = 0

    override suspend fun sendPush(payload: Map<String, Any>, deviceToken: String): Boolean {
        sendCallCount++
        return !shouldFailForTokens.contains(deviceToken)
    }
}

class FamilyNotifierTest {

    @Test
    fun `notifyAll sends to all family notification targets`() = runBlocking {
        val contacts = listOf(
            EmergencyContact(UUID.randomUUID(), "Contact1", "token1", true, true),
            EmergencyContact(UUID.randomUUID(), "Contact2", "token2", false, true),
            EmergencyContact(UUID.randomUUID(), "Contact3", "token3", true, false) // not a family target
        )
        val fakeFCM = FakeFCMProvider()
        val notifier = FCMFamilyNotifier(contacts, fakeFCM)

        val results = notifier.notifyAll(FamilyAlertType.MISSED_MEDICATION, System.currentTimeMillis())

        // Should have sent to 2 family targets, not the non-target contact
        assertEquals(2, fakeFCM.sendCallCount)
        assertEquals(2, results.size)
    }

    @Test
    fun `partial failure continues to remaining contacts`() = runBlocking {
        val contacts = listOf(
            EmergencyContact(UUID.randomUUID(), "Contact1", "token1", true, true),
            EmergencyContact(UUID.randomUUID(), "Contact2", "token2", true, true),
            EmergencyContact(UUID.randomUUID(), "Contact3", "token3", true, true)
        )
        val fakeFCM = FakeFCMProvider()
        fakeFCM.shouldFailForTokens.add("token2")
        val notifier = FCMFamilyNotifier(contacts, fakeFCM)

        val results = notifier.notifyAll(FamilyAlertType.MISSED_MEDICATION, System.currentTimeMillis())

        assertEquals(3, results.size)
        assertEquals(1, results.count { !it.success })
        assertEquals(2, results.count { it.success })
    }

    @Test
    fun `all failures still returns results`() = runBlocking {
        val contacts = listOf(
            EmergencyContact(UUID.randomUUID(), "Contact1", "token1", true, true)
        )
        val fakeFCM = FakeFCMProvider()
        fakeFCM.shouldFailForTokens.add("token1")
        val notifier = FCMFamilyNotifier(contacts, fakeFCM)

        val results = notifier.notifyAll(FamilyAlertType.EMERGENCY_CALL, System.currentTimeMillis())

        assertEquals(1, results.size)
        assertTrue(!results.first().success)
        assertEquals("fcm_delivery_failed", results.first().errorCode)
    }

    @Test
    fun `empty contacts returns empty results`() = runBlocking {
        val fakeFCM = FakeFCMProvider()
        val notifier = FCMFamilyNotifier(emptyList(), fakeFCM)

        val results = notifier.notifyAll(FamilyAlertType.INACTIVITY_ALERT, System.currentTimeMillis())

        assertEquals(0, results.size)
        assertEquals(0, fakeFCM.sendCallCount)
    }

    // MARK: - Caregiver event alerts (2026-09-13)

    private fun eventContext(title: String = "Amlodipine",
                             kind: EventNotifyKind = EventNotifyKind.MEDICATION_REMINDER) =
        FamilyAlertContext(kind = kind, eventIdHash = "0123456789ab",
            eventTitle = title, fireAt = System.currentTimeMillis())

    /**
     * Legacy alerts keep reporting no channel — the delivery surface was
     * never modelled for them, and the mirror must not invent one.
     */
    @Test
    fun `legacy alert carries no channel`() = runBlocking {
        val notifier = FCMFamilyNotifier(
            listOf(EmergencyContact(UUID.randomUUID(), "Contact1", "token1", true, true)))

        val results = notifier.notifyAll(FamilyAlertType.MISSED_MEDICATION,
            System.currentTimeMillis())

        assertNull(results.first().channel)
    }

    /** An event alert reports the contact's channel. */
    @Test
    fun `event alert carries the contact notify channel`() = runBlocking {
        val notifier = FCMFamilyNotifier(listOf(
            EmergencyContact(UUID.randomUUID(), "Contact1", "token1", true, true,
                notifyChannel = NotifyChannel.MESSENGER)))

        val results = notifier.notifyAll(FamilyAlertType.EVENT_REMINDER,
            System.currentTimeMillis(), eventContext())

        assertEquals(NotifyChannel.MESSENGER.key, results.first().channel)
    }

    /** Every kind of event alert rides the ONE wire type. */
    @Test
    fun `event alert rides the one event reminder wire type`() = runBlocking {
        val notifier = FCMFamilyNotifier(listOf(
            EmergencyContact(UUID.randomUUID(), "Contact1", "token1", true, true)))

        val results = notifier.notifyAll(FamilyAlertType.EVENT_REMINDER,
            System.currentTimeMillis(),
            eventContext(kind = EventNotifyKind.CALENDAR_EVENT))

        assertEquals(1, results.size)
        assertTrue(results.first().success)
    }

    /** The contact's notify channel defaults to SMS (the universal fallback). */
    @Test
    fun `notify channel defaults to SMS`() {
        val contact = EmergencyContact(UUID.randomUUID(), "Contact1", "token1", true, true)

        assertEquals(NotifyChannel.SMS, contact.notifyChannel)
    }

    /** The channel mapping is total and mirrors the iOS rules. */
    @Test
    fun `notify channel resolves from the calling app`() {
        assertEquals(NotifyChannel.SMS, NotifyChannel.resolve(CallApp.PHONE))
        assertEquals(NotifyChannel.SMS, NotifyChannel.resolve(CallApp.FACE_TIME))
        assertEquals(NotifyChannel.WHATSAPP, NotifyChannel.resolve(CallApp.WHATSAPP))
        assertEquals(NotifyChannel.MESSENGER, NotifyChannel.resolve(CallApp.MESSENGER))
        assertEquals(NotifyChannel.SMS,
            NotifyChannel.resolve(CallApp.MESSENGER, messengerHandleAvailable = false))
    }

    /**
     * An unconfigured per-contact pick (PHONE is the default) falls
     * through to the global default app instead of pinning the contact
     * to SMS; an explicit pick beats the global default.
     */
    @Test
    fun `per contact preference falls through when unconfigured`() {
        assertEquals(NotifyChannel.WHATSAPP,
            NotifyChannel.resolve(CallApp.PHONE, CallApp.WHATSAPP,
                messengerHandleAvailable = true))
        assertEquals(NotifyChannel.WHATSAPP,
            NotifyChannel.resolve(CallApp.WHATSAPP, CallApp.PHONE,
                messengerHandleAvailable = true))
    }

    /** The default 2-arg form still behaves exactly as before. */
    @Test
    fun `two argument entry point remains channel free`() = runBlocking {
        val fakeFCM = FakeFCMProvider()
        val notifier = FCMFamilyNotifier(listOf(
            EmergencyContact(UUID.randomUUID(), "Contact1", "token1", true, true,
                notifyChannel = NotifyChannel.WHATSAPP)), fakeFCM)

        val results = notifier.notifyAll(FamilyAlertType.EMERGENCY_CALL,
            System.currentTimeMillis())

        assertEquals(1, fakeFCM.sendCallCount)
        assertNull(results.first().channel)
    }
}
