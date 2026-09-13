package com.elderlyassistant.services.family

import com.elderlyassistant.services.medication.FamilyAlertType
import com.elderlyassistant.services.medication.NotificationResult
import java.security.MessageDigest
import java.util.UUID

// MARK: - FamilyNotifier Protocol (L2 §5.5)

interface FamilyNotifierProtocol {
    suspend fun notifyAll(alertType: FamilyAlertType, timestamp: Long): List<NotificationResult>

    /**
     * Context-carrying form (caregiver event-notifications task,
     * 2026-09-13): `context` describes WHICH event fired, for the one
     * wire type [FamilyAlertType.EVENT_REMINDER] that covers event alerts
     * of every kind. Legacy alerts pass null.
     *
     * Default implementation: this conformer does not distinguish event
     * contexts (or this is a legacy alert) — behave exactly as before
     * this seam existed. Kotlin dispatches interface default methods
     * virtually, so a conformer's own override IS reached through a
     * protocol-typed reference (the Swift side needs an explicit
     * requirement for the same reason; see the iOS `FamilyNotifier`).
     *
     * Android has no event fire wiring yet — this seam exists so the
     * mirror stays shaped like iOS, not so anything calls it.
     */
    suspend fun notifyAll(
        alertType: FamilyAlertType,
        timestamp: Long,
        context: FamilyAlertContext?
    ): List<NotificationResult> = notifyAll(alertType, timestamp)
}

// MARK: - Notify channel

/**
 * Which text channel a caregiver event alert would ride (caregiver
 * event-notifications task, 2026-09-13) — DERIVED from the default
 * calling preference, exactly as on iOS, so a family that talks over
 * WhatsApp gets WhatsApp and a family that dials gets SMS.
 *
 * The wire format is the enum's `key` (`"sms"`, `"whatsApp"`,
 * `"messenger"`) — the same spelling the iOS `NotifyChannel` and the
 * future relay's payload use.
 */
enum class NotifyChannel(val key: String) {
    SMS("sms"),
    WHATSAPP("whatsApp"),
    MESSENGER("messenger");

    companion object {
        /**
         * Maps a resolved calling app to the channel a caregiver alert
         * rides. Pure and total.
         *
         * `messengerHandleAvailable` is the contact's own handle state:
         * Messenger addresses people by username, not phone number, so a
         * handle-less contact would dead-end the delivery and drops to
         * SMS instead.
         */
        fun resolve(app: CallApp, messengerHandleAvailable: Boolean = true): NotifyChannel =
            when (app) {
                CallApp.FACE_TIME, CallApp.PHONE -> SMS
                CallApp.WHATSAPP -> WHATSAPP
                CallApp.MESSENGER -> if (messengerHandleAvailable) MESSENGER else SMS
            }

        /**
         * The app-level rule: the contact's per-contact pick wins; a
         * `PHONE` pick IS the unconfigured default, so it falls through
         * to the global default app instead of pinning every contact to
         * SMS.
         */
        fun resolve(
            preferred: CallApp,
            defaultApp: CallApp,
            messengerHandleAvailable: Boolean
        ): NotifyChannel =
            resolve(if (preferred == CallApp.PHONE) defaultApp else preferred,
                messengerHandleAvailable)
    }
}

/**
 * The app vocabulary the notify channel is derived from — the Android
 * echo of the iOS `CallApp`. Only surfaces that can carry a text to a
 * caregiver matter here.
 */
enum class CallApp {
    FACE_TIME, PHONE, MESSENGER, WHATSAPP
}

// MARK: - Event context (in-memory only)

/**
 * What fired, for an [FamilyAlertType.EVENT_REMINDER] alert.
 *
 * **No-PII tension, documented on purpose.** The alert envelope carries
 * `alert_type` + `timestamp` and nothing else, which is why
 * `MISSED_MEDICATION` deliberately drops the medication name. An event
 * alert is different in kind — "your father's walk reminder fired" is
 * useless without knowing WHICH event — so this type carries
 * [eventTitle] AT ALL. It is **in-memory only**: never encoded into a
 * payload, never persisted, never logged. The future relay MUST
 * re-litigate title-on-wire explicitly.
 */
data class FamilyAlertContext(
    /** Which firing system produced the alert. */
    val kind: EventNotifyKind,
    /** Short hash of the firing entry/occurrence/event id — the PII-free handle. */
    val eventIdHash: String,
    /** The event's display title. Never logged, never encoded. */
    val eventTitle: String,
    /** When the reminder was scheduled to fire. */
    val fireAt: Long
)

/** One case per FIRING SYSTEM — the iOS `EventNotifyKind` mirror. */
enum class EventNotifyKind(val key: String) {
    MEDICATION_REMINDER("medicationReminder"),
    ROUTINE_REMINDER("routineReminder"),
    CALENDAR_EVENT("calendarEvent")
}

// MARK: - Android FCM Implementation

class FCMFamilyNotifier(
    private val contacts: List<EmergencyContact>,
    private val fcmProvider: FCMProvider = FCMProvider()
) : FamilyNotifierProtocol {

    override suspend fun notifyAll(alertType: FamilyAlertType, timestamp: Long): List<NotificationResult> =
        notifyAll(alertType, timestamp, context = null)

    override suspend fun notifyAll(
        alertType: FamilyAlertType,
        timestamp: Long,
        context: FamilyAlertContext?
    ): List<NotificationResult> {
        val targets = contacts.filter { it.isFamilyNotificationTarget }
        val results = mutableListOf<NotificationResult>()

        for (contact in targets) {
            val payload = buildPayload(alertType, timestamp)
            val success = fcmProvider.sendPush(payload, contact.deviceToken)

            results.add(NotificationResult(
                contactIdHash = idHash(contact.id),
                success = success,
                errorCode = if (success) null else "fcm_delivery_failed",
                // The channel is only meaningful once an event alert has
                // one: the legacy alerts never modelled a delivery
                // surface, so they keep reporting null.
                channel = if (context == null) null else contact.notifyChannel.key
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
        FamilyAlertType.EVENT_REMINDER -> "Reminder"
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
        FamilyAlertType.EVENT_REMINDER ->
            "A reminder you asked to be notified about has fired."
    }

    private fun idHash(id: UUID): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(id.toString().toByteArray())
        return hash.take(12).joinToString("") { "%02x".format(it) }
    }
}

// MARK: - FCM Provider Stub

/**
 * `open` so tests can substitute a recording double (the pre-existing
 * `FakeFCMProvider` in `FamilyNotifierTest` subclasses this). Production
 * code only ever uses the default instance.
 */
open class FCMProvider {
    open suspend fun sendPush(payload: Map<String, Any>, deviceToken: String): Boolean {
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
    val isFamilyNotificationTarget: Boolean,
    /**
     * Which text channel an event alert for this contact rides (caregiver
     * event-notifications task, 2026-09-13) — derived from the contact's
     * calling preference on the caller's side. Defaulted to [NotifyChannel.SMS]
     * (the universal fallback) so constructions that predate the field
     * stay valid.
     */
    val notifyChannel: NotifyChannel = NotifyChannel.SMS
)
