package com.elderlyassistant.services.family

import com.elderlyassistant.services.medication.FamilyAlertType
import com.elderlyassistant.services.medication.NotificationResult
import java.security.MessageDigest
import java.util.UUID

// MARK: - FamilyNotifier Protocol (L2 §5.5)

interface FamilyNotifierProtocol {
    suspend fun notifyAll(alertType: FamilyAlertType, timestamp: Long): List<NotificationResult>
}

// MARK: - Android FCM Implementation

class FCMFamilyNotifier(
    private val contacts: List<EmergencyContact>,
    private val fcmProvider: FCMProvider = FCMProvider()
) : FamilyNotifierProtocol {

    override suspend fun notifyAll(alertType: FamilyAlertType, timestamp: Long): List<NotificationResult> {
        val targets = contacts.filter { it.isFamilyNotificationTarget }
        val results = mutableListOf<NotificationResult>()

        for (contact in targets) {
            val payload = buildPayload(alertType, timestamp)
            val success = fcmProvider.sendPush(payload, contact.deviceToken)

            results.add(NotificationResult(
                contactIdHash = idHash(contact.id),
                success = success,
                errorCode = if (success) null else "fcm_delivery_failed"
            ))
        }

        val failureCount = results.count { !it.success }
        if (failureCount > 0) {
            println("[FamilyNotifier] $failureCount/${results.size} notifications failed")
        }

        return results
    }

    private fun buildPayload(alertType: FamilyAlertType, timestamp: Long): Map<String, Any> {
        return mapOf(
            "message" to mapOf(
                "topic" to "family_alerts",
                "notification" to mapOf(
                    "title" to alertTitle(alertType),
                    "body" to alertBody(alertType)
                ),
                "data" to mapOf(
                    "alert_type" to alertType.name,
                    "timestamp" to timestamp.toString()
                )
            )
        )
    }

    private fun alertTitle(alertType: FamilyAlertType): String = when (alertType) {
        FamilyAlertType.EMERGENCY_CALL -> "Emergency Alert"
        FamilyAlertType.MISSED_MEDICATION -> "Missed Medication"
        FamilyAlertType.HEALTH_MONITORING_INTERRUPTED -> "Health Monitoring Interrupted"
        FamilyAlertType.CONFIGURATION_UPDATE_APPLIED -> "Configuration Updated"
        FamilyAlertType.POSSIBLE_DOUBLE_DOSE -> "Double Dose Alert"
        FamilyAlertType.INACTIVITY_ALERT -> "Inactivity Alert"
    }

    private fun alertBody(alertType: FamilyAlertType): String = when (alertType) {
        FamilyAlertType.EMERGENCY_CALL ->
            "Emergency alert: Your family member's health threshold has been exceeded."
        FamilyAlertType.MISSED_MEDICATION ->
            "Your family member has missed a scheduled medication."
        FamilyAlertType.HEALTH_MONITORING_INTERRUPTED ->
            "Health monitoring for your family member has been interrupted."
        FamilyAlertType.CONFIGURATION_UPDATE_APPLIED ->
            "Configuration update has been applied successfully."
        FamilyAlertType.POSSIBLE_DOUBLE_DOSE ->
            "Alert: Your family member may have attempted to take medication twice."
        FamilyAlertType.INACTIVITY_ALERT ->
            "Your family member has not interacted with their assistant for an extended period."
    }

    private fun idHash(id: UUID): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(id.toString().toByteArray())
        return hash.take(12).joinToString("") { "%02x".format(it) }
    }
}

// MARK: - FCM Provider Stub

class FCMProvider {
    suspend fun sendPush(payload: Map<String, Any>, deviceToken: String): Boolean {
        // Stub implementation -- T-028-b requires FCM integration
        // In production: use Firebase Admin SDK or FCM HTTP v1 API
        println("[FCMProvider] Push sent to token: ${deviceToken.take(8)}...")
        return true
    }
}

// MARK: - Emergency Contact (from L1 §5.1)

data class EmergencyContact(
    val id: UUID,
    val displayName: String,
    val deviceToken: String,
    val isEmergencyContact: Boolean,
    val isFamilyNotificationTarget: Boolean
)
