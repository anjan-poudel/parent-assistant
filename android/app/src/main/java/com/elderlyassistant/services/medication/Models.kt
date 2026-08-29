package com.elderlyassistant.services.medication

import java.time.LocalTime
import java.util.UUID

// MARK: - Medication Entry (from L1 §5.1 + dementia supplement)

enum class MedicationFrequency {
    DAILY, WEEKLY, CUSTOM
}

enum class MedicationAdherenceStatus {
    PENDING, ACKNOWLEDGED, MISSED, DOUBLE_DOSE_ATTEMPT
}

enum class PhotoVerificationStatus {
    NOT_REQUIRED, PENDING, CAPTURED, DELIVERED, UNAVAILABLE
}

data class MedicationEntry(
    val id: UUID,
    val userProfileId: UUID,
    val medicationName: String,
    val doseDescription: String,
    val scheduleTimes: List<LocalTime>,
    val frequency: MedicationFrequency,
    val ackWindowMinutes: Int = 5,
    val maxRefireCount: Int = 5,
    val escalationWindowMinutes: Int = 60,
    val doubleDoseWindowHours: Int = 4,
    val photoVerificationEnabled: Boolean = false,
    val confirmationDescription: String? = null
)

// MARK: - Scheduled Reminder (runtime, persisted before OS alarm)

data class ScheduledReminder(
    val id: UUID,
    val medicationEntryId: UUID,
    val scheduledAt: Long,          // epoch millis
    var refireCount: Int,
    var escalationDeadline: Long,  // epoch millis
    var state: ReminderState,
    var lastFiredAt: Long?,
    var acknowledgedAt: Long?
)

enum class ReminderState {
    PENDING, FIRED, ACKNOWLEDGED, MISSED, DOUBLE_DOSE_BLOCKED, COMPLETED
}

// MARK: - Medication Adherence Log (from L1 §5.1)

data class MedicationAdherenceLog(
    val id: UUID,
    val medicationEntryId: UUID,
    val scheduledAt: Long,
    val acknowledgedAt: Long?,
    val refireCount: Int,
    val status: MedicationAdherenceStatus,
    val familyAlerted: Boolean,
    val photoVerification: PhotoVerificationStatus,
    val confirmationPassed: Boolean,
    val confirmationDeniedAt: Long?
)

// MARK: - Verification Photo (dementia FR-D04a-D04e)

data class VerificationPhoto(
    val id: UUID,
    val adherenceLogId: UUID,
    val capturedAt: Long,
    var deliveredAt: Long?,
    var deletedFromDeviceAt: Long?,
    val imageData: ByteArray       // max 200KB compressed
)

// MARK: - Family Alert Types

enum class FamilyAlertType {
    EMERGENCY_CALL,
    MISSED_MEDICATION,
    HEALTH_MONITORING_INTERRUPTED,
    CONFIGURATION_UPDATE_APPLIED,
    POSSIBLE_DOUBLE_DOSE,
    INACTIVITY_ALERT
}

data class NotificationResult(
    val contactIdHash: String,
    val success: Boolean,
    val errorCode: String?
)
