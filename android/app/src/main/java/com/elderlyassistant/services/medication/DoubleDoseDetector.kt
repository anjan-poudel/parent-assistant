package com.elderlyassistant.services.medication

import java.util.UUID

// MARK: - Double Dose Detector (FR-D03)

data class DoubleDoseCheckResult(
    val isDuplicate: Boolean,
    val previousDoseAt: Long?,
    val windowEndsAt: Long?
)

class DoubleDoseDetector {
    fun check(
        medicationEntryId: UUID,
        windowHours: Int,
        adherenceLog: List<MedicationAdherenceLog>,
        now: Long
    ): DoubleDoseCheckResult {
        val windowStart = now - (windowHours * 3600_000L)

        val previousDose = adherenceLog
            .filter { it.medicationEntryId == medicationEntryId }
            .filter { it.status == MedicationAdherenceStatus.ACKNOWLEDGED }
            .filter { (it.acknowledgedAt ?: 0) in windowStart..now }
            .maxByOrNull { it.acknowledgedAt ?: 0 }

        if (previousDose == null) {
            return DoubleDoseCheckResult(false, null, null)
        }

        val previousAt = previousDose.acknowledgedAt!!
        val windowEnds = previousAt + (windowHours * 3600_000L)

        return DoubleDoseCheckResult(true, previousAt, windowEnds)
    }
}
