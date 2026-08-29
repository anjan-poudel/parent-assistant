package com.elderlyassistant.services.medication

import com.elderlyassistant.services.family.FamilyNotifierProtocol
import org.junit.Before
import org.junit.Test
import java.time.LocalTime
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

// MARK: - Mock Dependencies

class MockEncryptedLocalStorage : EncryptedLocalStorage {
    private val store = mutableMapOf<String, Any>()
    var writeCallCount = 0
    var shouldFailWrite = false

    override fun <T> write(key: String, value: T): Result<Unit> {
        writeCallCount++
        return if (shouldFailWrite) {
            Result.failure(StorageError.EncryptedWriteFailed)
        } else {
            store[key] = value as Any
            Result.success(Unit)
        }
    }

    @Suppress("UNCHECKED_CAST")
    override fun <T> read(key: String, type: Class<T>): Result<T> {
        val value = store[key] ?: return Result.failure(StorageError.EncryptedReadFailed)
        return Result.success(value as T)
    }

    override fun delete(key: String): Result<Unit> {
        store.remove(key)
        return Result.success(Unit)
    }
}

class MockAlarmScheduler : PlatformAlarmScheduler {
    val scheduledReminders = mutableMapOf<UUID, Long>()
    val cancelledReminders = mutableSetOf<UUID>()
    val ackDeadlineChecks = mutableMapOf<UUID, Long>()
    var scheduleCallCount = 0

    override fun scheduleReminder(reminderId: UUID, entryId: UUID, medicationName: String, at: Long) {
        scheduleCallCount++
        scheduledReminders[reminderId] = at
    }

    override fun scheduleAckDeadlineCheck(reminderId: UUID, entryId: UUID, deadline: Long) {
        ackDeadlineChecks[reminderId] = deadline
    }

    override fun cancelReminder(reminderId: UUID) {
        cancelledReminders.add(reminderId)
        scheduledReminders.remove(reminderId)
    }

    override fun cancelAllReminders() {
        cancelledReminders.addAll(scheduledReminders.keys)
        scheduledReminders.clear()
    }
}

class MockObservabilityBus : ObservabilityBus {
    val emittedEvents = mutableListOf<ObservabilityEvent>()

    override fun emit(event: ObservabilityEvent) {
        emittedEvents.add(event)
    }
}

class MockFamilyNotifier : FamilyNotifierProtocol {
    var notifyCallCount = 0
    var lastAlertType: FamilyAlertType? = null
    var shouldFail = false

    override suspend fun notifyAll(alertType: FamilyAlertType, timestamp: Long): List<NotificationResult> {
        notifyCallCount++
        lastAlertType = alertType
        return listOf(NotificationResult("test_hash", !shouldFail, null))
    }
}

// MARK: - MedicationScheduler Tests

class MedicationSchedulerTest {

    private lateinit var scheduler: MedicationScheduler
    private lateinit var mockStorage: MockEncryptedLocalStorage
    private lateinit var mockAlarm: MockAlarmScheduler
    private lateinit var mockObservability: MockObservabilityBus
    private lateinit var mockFamilyNotifier: MockFamilyNotifier

    @Before
    fun setup() {
        mockStorage = MockEncryptedLocalStorage()
        mockAlarm = MockAlarmScheduler()
        mockObservability = MockObservabilityBus()
        mockFamilyNotifier = MockFamilyNotifier()
        scheduler = MedicationScheduler(mockStorage, mockAlarm, mockObservability, mockFamilyNotifier)
    }

    @Test
    fun `load schedule persists entries`() {
        val entry = makeMedicationEntry("Amlodipine", 8, 0)

        scheduler.loadSchedule(listOf(entry))

        assertTrue(mockStorage.writeCallCount > 0)
        assertTrue(scheduler.pendingReminders.isNotEmpty())
    }

    @Test
    fun `load schedule creates reminder for each entry`() {
        val entry1 = makeMedicationEntry("Amlodipine", 8, 0)
        val entry2 = makeMedicationEntry("Metformin", 20, 0)

        scheduler.loadSchedule(listOf(entry1, entry2))

        assertEquals(2, scheduler.pendingReminders.size)
    }

    @Test
    fun `no medication names in observability events`() {
        val entry = makeMedicationEntry("Amlodipine", 8, 0)
        scheduler.loadSchedule(listOf(entry))

        for (event in mockObservability.emittedEvents) {
            for ((_, value) in event.metadata) {
                assertFalse(
                    value.lowercase().contains("amlodipine"),
                    "Observability event metadata contains medication name: $value"
                )
            }
        }
    }

    @Test
    fun `pending reminders excludes completed`() {
        val entry = makeMedicationEntry("Amlodipine", 8, 0)
        scheduler.loadSchedule(listOf(entry))

        val pending = scheduler.pendingReminders
        assertTrue(pending.all { it.state != ReminderState.COMPLETED })
    }

    private fun makeMedicationEntry(
        name: String,
        hour: Int,
        minute: Int,
        confirmationDescription: String? = null,
        photoVerification: Boolean = false,
        doubleDoseWindowHours: Int = 4
    ): MedicationEntry {
        return MedicationEntry(
            id = UUID.randomUUID(),
            userProfileId = UUID.randomUUID(),
            medicationName = name,
            doseDescription = "One tablet",
            scheduleTimes = listOf(LocalTime.of(hour, minute)),
            frequency = MedicationFrequency.DAILY,
            ackWindowMinutes = 5,
            maxRefireCount = 5,
            escalationWindowMinutes = 60,
            doubleDoseWindowHours = doubleDoseWindowHours,
            photoVerificationEnabled = photoVerification,
            confirmationDescription = confirmationDescription
        )
    }
}
