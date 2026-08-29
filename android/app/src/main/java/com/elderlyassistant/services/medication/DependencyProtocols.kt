package com.elderlyassistant.services.medication

import java.util.UUID

// MARK: - Protocol stubs for dependencies (T-002, T-004)

sealed class StorageError(message: String) : Throwable(message) {
    object EncryptedWriteFailed : StorageError("encrypted write failed")
    object EncryptedReadFailed : StorageError("encrypted read failed")
}

sealed class SafetyError(message: String) : Throwable(message) {
    object HealthPermissionRevoked : SafetyError("health permission revoked")
    data class EmergencyCallFailed(val reason: String) : SafetyError("emergency call failed: $reason")
    object ReminderPersistenceFailed : SafetyError("reminder persistence failed")
    data class FamilyNotificationFailed(val reason: String) : SafetyError("family notification failed: $reason")
}

interface EncryptedLocalStorage {
    fun <T> write(key: String, value: T): Result<Unit>
    fun <T> read(key: String, type: Class<T>): Result<T>
    fun delete(key: String): Result<Unit>
}

data class ObservabilityEvent(
    val component: String,
    val eventType: String,
    val durationMs: Int?,
    val outcome: String,
    val errorCode: String?,
    val metadata: Map<String, String>
)

interface ObservabilityBus {
    fun emit(event: ObservabilityEvent)
}
