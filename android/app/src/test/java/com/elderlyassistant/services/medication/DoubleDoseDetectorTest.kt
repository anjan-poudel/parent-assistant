package com.elderlyassistant.services.medication

import org.junit.Test
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class DoubleDoseDetectorTest {

    @Test
    fun `no duplicate when log is empty`() {
        val detector = DoubleDoseDetector()
        val now = System.currentTimeMillis()
        val entryId = UUID.randomUUID()

        val result = detector.check(entryId, 4, emptyList(), now)

        assertFalse(result.isDuplicate)
        assertNull(result.previousDoseAt)
    }

    @Test
    fun `no duplicate when log has only other medications`() {
        val detector = DoubleDoseDetector()
        val now = System.currentTimeMillis()
        val entryId = UUID.randomUUID()
        val otherEntryId = UUID.randomUUID()

        val otherLog = MedicationAdherenceLog(
            id = UUID.randomUUID(),
            medicationEntryId = otherEntryId,
            scheduledAt = now - 3_600_000,
            acknowledgedAt = now - 1_800_000,
            refireCount = 0,
            status = MedicationAdherenceStatus.ACKNOWLEDGED,
            familyAlerted = false,
            photoVerification = PhotoVerificationStatus.NOT_REQUIRED,
            confirmationPassed = true,
            confirmationDeniedAt = null
        )

        val result = detector.check(entryId, 4, listOf(otherLog), now)

        assertFalse(result.isDuplicate)
    }

    @Test
    fun `no duplicate when previous dose is outside window`() {
        val detector = DoubleDoseDetector()
        val now = System.currentTimeMillis()
        val entryId = UUID.randomUUID()

        val oldLog = MedicationAdherenceLog(
            id = UUID.randomUUID(),
            medicationEntryId = entryId,
            scheduledAt = now - (6 * 3_600_000),
            acknowledgedAt = now - (5 * 3_600_000),
            refireCount = 0,
            status = MedicationAdherenceStatus.ACKNOWLEDGED,
            familyAlerted = false,
            photoVerification = PhotoVerificationStatus.NOT_REQUIRED,
            confirmationPassed = true,
            confirmationDeniedAt = null
        )

        val result = detector.check(entryId, 4, listOf(oldLog), now)

        assertFalse(result.isDuplicate)
    }

    @Test
    fun `duplicate detected when within window`() {
        val detector = DoubleDoseDetector()
        val now = System.currentTimeMillis()
        val entryId = UUID.randomUUID()

        val recentLog = MedicationAdherenceLog(
            id = UUID.randomUUID(),
            medicationEntryId = entryId,
            scheduledAt = now - (3 * 3_600_000),
            acknowledgedAt = now - (2 * 3_600_000),
            refireCount = 0,
            status = MedicationAdherenceStatus.ACKNOWLEDGED,
            familyAlerted = false,
            photoVerification = PhotoVerificationStatus.NOT_REQUIRED,
            confirmationPassed = true,
            confirmationDeniedAt = null
        )

        val result = detector.check(entryId, 4, listOf(recentLog), now)

        assertTrue(result.isDuplicate)
        assertNotNull(result.previousDoseAt)
        assertNotNull(result.windowEndsAt)
    }

    @Test
    fun `missed doses are not counted as duplicates`() {
        val detector = DoubleDoseDetector()
        val now = System.currentTimeMillis()
        val entryId = UUID.randomUUID()

        val missedLog = MedicationAdherenceLog(
            id = UUID.randomUUID(),
            medicationEntryId = entryId,
            scheduledAt = now - (2 * 3_600_000),
            acknowledgedAt = null,
            refireCount = 5,
            status = MedicationAdherenceStatus.MISSED,
            familyAlerted = true,
            photoVerification = PhotoVerificationStatus.NOT_REQUIRED,
            confirmationPassed = false,
            confirmationDeniedAt = null
        )

        val result = detector.check(entryId, 4, listOf(missedLog), now)

        assertFalse(result.isDuplicate)
    }

    @Test
    fun `most recent dose used when multiple in log`() {
        val detector = DoubleDoseDetector()
        val now = System.currentTimeMillis()
        val entryId = UUID.randomUUID()

        val olderDose = MedicationAdherenceLog(
            id = UUID.randomUUID(),
            medicationEntryId = entryId,
            scheduledAt = now - (10 * 3_600_000),
            acknowledgedAt = now - (8 * 3_600_000),
            refireCount = 0,
            status = MedicationAdherenceStatus.ACKNOWLEDGED,
            familyAlerted = false,
            photoVerification = PhotoVerificationStatus.NOT_REQUIRED,
            confirmationPassed = true,
            confirmationDeniedAt = null
        )

        val recentDose = MedicationAdherenceLog(
            id = UUID.randomUUID(),
            medicationEntryId = entryId,
            scheduledAt = now - (3 * 3_600_000),
            acknowledgedAt = now - (2 * 3_600_000),
            refireCount = 0,
            status = MedicationAdherenceStatus.ACKNOWLEDGED,
            familyAlerted = false,
            photoVerification = PhotoVerificationStatus.NOT_REQUIRED,
            confirmationPassed = true,
            confirmationDeniedAt = null
        )

        val result = detector.check(entryId, 4, listOf(olderDose, recentDose), now)

        assertTrue(result.isDuplicate)
        assertEquals(recentDose.acknowledgedAt, result.previousDoseAt)
    }
}
