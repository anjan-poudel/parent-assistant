package com.elderlyassistant.services.family

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Firebase Cloud Messaging service for family notifications.
 * Receives push messages from the relay server / FCM.
 * Payload contains only alert type + timestamp — no PII or health values.
 */
class FCMService : FirebaseMessagingService() {

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)

        // Family alerts arrive via FCM data messages
        // Alert type and timestamp only — no health values, no PII
        val alertType = message.data["alert_type"]
        val timestamp = message.data["timestamp"]?.toLongOrNull()

        if (alertType != null) {
            // These are alerts received ON the primary device (not sent from it)
            // In production: delegate to EmergencyDispatcher or TTS engine
            println("[FCMService] Alert received: type=$alertType timestamp=$timestamp")
        }
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        // Register token with the relay server for family notification delivery
        println("[FCMService] New FCM token registered")
    }
}
