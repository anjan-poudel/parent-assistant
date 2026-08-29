package com.elderlyassistant.services.family

import com.elderlyassistant.services.medication.FamilyAlertType
import kotlinx.coroutines.runBlocking
import org.junit.Test
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class FakeFCMProvider {
    var shouldFailForTokens = mutableSetOf<String>()
    var sendCallCount = 0

    suspend fun sendPush(payload: Map<String, Any>, deviceToken: String): Boolean {
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
}
