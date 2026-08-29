package com.elderlyassistant.services.medication

import com.elderlyassistant.services.family.FamilyNotifierProtocol
import kotlinx.coroutines.*
import java.security.MessageDigest
import java.util.UUID

// MARK: - MedicationScheduler Implementation (L2 §5.4)

class MedicationScheduler(
    private val storage: EncryptedLocalStorage,
    private val alarmScheduler: PlatformAlarmScheduler,
    private val observabilityBus: ObservabilityBus,
    private val familyNotifier: FamilyNotifierProtocol
) {
    private val entries = mutableMapOf<UUID, MedicationEntry>()
    private val engines = mutableMapOf<UUID, EscalationEngine>()
    private val adherenceLog = mutableListOf<MedicationAdherenceLog>()
    private val pendingRemindersList = mutableMapOf<UUID, ScheduledReminder>()
    private val confirmationChallenges = mutableMapOf<UUID, ConfirmationChallenge>()
    private var didRestore = false

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private companion object {
        const val STORAGE_KEY_REMINDERS = "medication.pending_reminders"
        const val STORAGE_KEY_ADHERENCE_LOG = "medication.adherence_log"
        const val STORAGE_KEY_ENTRIES = "medication.entries"
    }

    val pendingReminders: List<ScheduledReminder>
        get() = pendingRemindersList.values.filter { it.state != ReminderState.COMPLETED }

    // MARK: - Load Schedule

    fun loadSchedule(newEntries: List<MedicationEntry>) {
        entries.clear()
        newEntries.forEach { entries[it.id] = it }

        storage.write(STORAGE_KEY_ENTRIES, newEntries)

        emit("schedule_loaded", mapOf("entry_count" to newEntries.size.toString()))

        scheduleAll()
    }

    // MARK: - Schedule All

    fun scheduleAll() {
        restoreState()
        rearmAllPendingReminders()
    }

    // MARK: - Acknowledge (Baseline FR-026 to FR-029)

    fun acknowledge(entryId: UUID, acknowledgedAt: Long): Result<Unit> {
        val entry = entries[entryId] ?: return Result.failure(SafetyError.ReminderPersistenceFailed)
        val engine = engines[entryId] ?: return Result.failure(SafetyError.ReminderPersistenceFailed)

        val result = engine.acknowledge(acknowledgedAt)

        return when (result.action) {
            is EscalationAction.MarkAcknowledged ->
                finalizeAcknowledgement(entry, entryId, acknowledgedAt, engine.currentRefireCount)

            is EscalationAction.EscalateToFamilyNotifier -> {
                recordMissedDose(entryId, entry)
                Result.success(Unit)
            }

            else -> Result.success(Unit)
        }
    }

    fun acknowledgeWithConfirmation(
        entryId: UUID,
        acknowledgedAt: Long,
        confirmationResponse: ConfirmationResponse
    ): Result<Unit> {
        val entry = entries[entryId] ?: return Result.failure(SafetyError.ReminderPersistenceFailed)
        val challenge = ConfirmationChallenge() // In production: stored per-entry
        val action = challenge.userResponds(confirmationResponse)

        return when (action) {
            is ConfirmationAction.RecordTaken ->
                checkDoubleDoseAndRecord(entry, entryId, acknowledgedAt)

            is ConfirmationAction.ReEnterEscalation -> {
                emit("confirmation_denied", mapOf("entry_id_hash" to idHash(entryId)))
                reEnterEscalation(entryId, entry)
            }

            else -> Result.success(Unit)
        }
    }

    // MARK: - Trigger Reminder (called by platform alarm)

    fun triggerReminder(reminderId: UUID) {
        val reminder = pendingRemindersList[reminderId] ?: return
        val entry = entries[reminder.medicationEntryId] ?: return

        val engine = engines.getOrPut(reminder.medicationEntryId) {
            makeEngine(entry, reminder).also { it.start() }
        }

        val result = engine.reminderDelivered(System.currentTimeMillis())
        pendingRemindersList[reminderId] = reminder.copy(
            state = engine.state.toReminderState(),
            lastFiredAt = System.currentTimeMillis()
        )
        persistReminders()

        emit("reminder_fired", mapOf(
            "entry_id_hash" to idHash(entry.id),
            "refire_count" to engine.currentRefireCount.toString()
        ))

        if (result.action is EscalationAction.WaitForAcknowledgement) {
            val deadline = (result.action as EscalationAction.WaitForAcknowledgement).deadline
            alarmScheduler.scheduleAckDeadlineCheck(reminderId, entry.id, deadline)
        }
    }

    // MARK: - Ack Deadline Expired

    fun handleAckDeadlineExpired(reminderId: UUID) {
        val reminder = pendingRemindersList[reminderId] ?: return
        val entry = entries[reminder.medicationEntryId] ?: return
        val engine = engines[reminder.medicationEntryId] ?: return

        val result = engine.ackWindowExpired(System.currentTimeMillis())
        when (val action = result.action) {
            is EscalationAction.FireReminder -> {
                emit("refire", mapOf(
                    "entry_id_hash" to idHash(entry.id),
                    "refire_count" to action.refireCount.toString()
                ))
                pendingRemindersList[reminderId] = reminder.copy(
                    refireCount = action.refireCount,
                    state = engine.state.toReminderState()
                )
                persistReminders()
                result.nextFireAt?.let { nextTime ->
                    alarmScheduler.scheduleReminder(reminderId, entry.id, entry.medicationName, nextTime)
                }
            }

            is EscalationAction.EscalateToFamilyNotifier ->
                recordMissedDose(entry.id, entry)

            else -> {}
        }
    }

    // MARK: - Private

    private fun finalizeAcknowledgement(
        entry: MedicationEntry,
        entryId: UUID,
        acknowledgedAt: Long,
        refireCount: Int
    ): Result<Unit> {
        val logEntry = MedicationAdherenceLog(
            id = UUID.randomUUID(),
            medicationEntryId = entryId,
            scheduledAt = engines[entryId]?.scheduledTime ?: System.currentTimeMillis(),
            acknowledgedAt = acknowledgedAt,
            refireCount = refireCount,
            status = MedicationAdherenceStatus.ACKNOWLEDGED,
            familyAlerted = false,
            photoVerification = if (entry.photoVerificationEnabled)
                PhotoVerificationStatus.PENDING else PhotoVerificationStatus.NOT_REQUIRED,
            confirmationPassed = true,
            confirmationDeniedAt = null
        )
        adherenceLog.add(logEntry)

        if (storage.write(STORAGE_KEY_ADHERENCE_LOG, adherenceLog).isFailure) {
            return Result.failure(SafetyError.ReminderPersistenceFailed)
        }

        val reminderId = pendingRemindersList.entries
            .firstOrNull { it.value.medicationEntryId == entryId }?.key
        if (reminderId != null) {
            pendingRemindersList.remove(reminderId)
            alarmScheduler.cancelReminder(reminderId)
        }
        persistReminders()
        engines[entryId]?.markCompleted()

        emit("acknowledged", mapOf(
            "entry_id_hash" to idHash(entryId),
            "refire_count" to refireCount.toString()
        ))
        return Result.success(Unit)
    }

    private fun checkDoubleDoseAndRecord(
        entry: MedicationEntry,
        entryId: UUID,
        acknowledgedAt: Long
    ): Result<Unit> {
        val detector = DoubleDoseDetector()
        val doseCheck = detector.check(entryId, entry.doubleDoseWindowHours, adherenceLog, acknowledgedAt)

        if (doseCheck.isDuplicate) {
            adherenceLog.add(MedicationAdherenceLog(
                id = UUID.randomUUID(),
                medicationEntryId = entryId,
                scheduledAt = System.currentTimeMillis(),
                acknowledgedAt = acknowledgedAt,
                refireCount = 0,
                status = MedicationAdherenceStatus.DOUBLE_DOSE_ATTEMPT,
                familyAlerted = false,
                photoVerification = PhotoVerificationStatus.NOT_REQUIRED,
                confirmationPassed = false,
                confirmationDeniedAt = null
            ))
            storage.write(STORAGE_KEY_ADHERENCE_LOG, adherenceLog)
            emit("double_dose_blocked", mapOf("entry_id_hash" to idHash(entryId)))

            scope.launch {
                familyNotifier.notifyAll(FamilyAlertType.POSSIBLE_DOUBLE_DOSE, System.currentTimeMillis())
            }
            return Result.success(Unit)
        }

        return finalizeAcknowledgement(entry, entryId, acknowledgedAt, engines[entryId]?.currentRefireCount ?: 0)
    }

    private fun recordMissedDose(entryId: UUID, entry: MedicationEntry) {
        adherenceLog.add(MedicationAdherenceLog(
            id = UUID.randomUUID(),
            medicationEntryId = entryId,
            scheduledAt = engines[entryId]?.scheduledTime ?: System.currentTimeMillis(),
            acknowledgedAt = null,
            refireCount = entry.maxRefireCount,
            status = MedicationAdherenceStatus.MISSED,
            familyAlerted = true,
            photoVerification = PhotoVerificationStatus.NOT_REQUIRED,
            confirmationPassed = false,
            confirmationDeniedAt = null
        ))
        storage.write(STORAGE_KEY_ADHERENCE_LOG, adherenceLog)

        val reminderId = pendingRemindersList.entries
            .firstOrNull { it.value.medicationEntryId == entryId }?.key
        if (reminderId != null) {
            pendingRemindersList.remove(reminderId)
            alarmScheduler.cancelReminder(reminderId)
        }
        persistReminders()

        emit("missed", mapOf("entry_id_hash" to idHash(entryId)))
        emit("family_alerted", mapOf("entry_id_hash" to idHash(entryId)))

        scope.launch {
            familyNotifier.notifyAll(FamilyAlertType.MISSED_MEDICATION, System.currentTimeMillis())
        }
    }

    private fun reEnterEscalation(entryId: UUID, entry: MedicationEntry): Result<Unit> {
        val engine = engines[entryId] ?: return Result.failure(SafetyError.ReminderPersistenceFailed)
        val nextTime = engine.nextRefireTime(System.currentTimeMillis())

        if (System.currentTimeMillis() < engine.escalationDeadline) {
            val reminderId = pendingRemindersList.entries
                .firstOrNull { it.value.medicationEntryId == entryId }?.key
            if (reminderId != null) {
                alarmScheduler.scheduleReminder(reminderId, entryId, entry.medicationName, nextTime)
            }
        }
        return Result.success(Unit)
    }

    private fun restoreState() {
        // Only hydrate once per process. `scheduleAll()` is invoked on every
        // service start / boot; re-reading here would clobber in-memory
        // mutations that haven't yet been persisted.
        if (didRestore) return
        didRestore = true

        @Suppress("UNCHECKED_CAST")
        storage.read(STORAGE_KEY_REMINDERS, Map::class.java).onSuccess { data ->
            (data as? Map<*, *>)?.forEach { (rawKey, rawValue) ->
                val key = when (rawKey) {
                    is UUID -> rawKey
                    is String -> runCatching { UUID.fromString(rawKey) }.getOrNull()
                    else -> null
                }
                val value = rawValue as? ScheduledReminder
                if (key != null && value != null) {
                    pendingRemindersList[key] = value
                }
            }
        }
        @Suppress("UNCHECKED_CAST")
        storage.read(STORAGE_KEY_ADHERENCE_LOG, List::class.java).onSuccess { data ->
            (data as? List<*>)?.filterIsInstance<MedicationAdherenceLog>()?.let {
                adherenceLog.addAll(it)
            }
        }
        @Suppress("UNCHECKED_CAST")
        storage.read(STORAGE_KEY_ENTRIES, List::class.java).onSuccess { data ->
            (data as? List<*>)?.filterIsInstance<MedicationEntry>()?.forEach {
                entries[it.id] = it
            }
        }
    }

    private fun rearmAllPendingReminders() {
        val now = System.currentTimeMillis()

        for ((reminderId, reminder) in pendingRemindersList) {
            if (reminder.state in listOf(ReminderState.ACKNOWLEDGED, ReminderState.MISSED, ReminderState.COMPLETED)) {
                continue
            }
            val entry = entries[reminder.medicationEntryId] ?: continue
            val engine = makeEngine(entry, reminder)
            engines[reminder.medicationEntryId] = engine

            when (val result = engine.recover(reminder, now).action) {
                is EscalationAction.FireReminder -> triggerReminder(reminderId)
                is EscalationAction.EscalateToFamilyNotifier -> {
                    if (now >= engine.escalationDeadline) {
                        recordMissedDose(entry.id, entry)
                    }
                }
                else -> {}
            }
        }
    }

    private fun makeEngine(entry: MedicationEntry, reminder: ScheduledReminder): EscalationEngine {
        return EscalationEngine(
            scheduledTime = reminder.scheduledAt,
            ackWindowMinutes = entry.ackWindowMinutes,
            maxRefireCount = entry.maxRefireCount,
            escalationWindowMinutes = entry.escalationWindowMinutes
        )
    }

    private fun persistReminders() {
        storage.write(STORAGE_KEY_REMINDERS, pendingRemindersList.toMap())
    }

    // MARK: - Observability

    private fun idHash(id: UUID): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(id.toString().toByteArray())
        return hash.take(12).joinToString("") { "%02x".format(it) }
    }

    private fun emit(eventType: String, metadata: Map<String, String>) {
        observabilityBus.emit(ObservabilityEvent(
            component = "medication_scheduler",
            eventType = eventType,
            durationMs = null,
            outcome = "success",
            errorCode = null,
            metadata = metadata
        ))
    }
}

// Extension to map EscalationState to ReminderState
private fun EscalationState.toReminderState(): ReminderState = when (this) {
    is EscalationState.Idle -> ReminderState.PENDING
    is EscalationState.ReminderFired -> ReminderState.FIRED
    is EscalationState.AwaitingAcknowledgement -> ReminderState.FIRED
    is EscalationState.Acknowledged -> ReminderState.ACKNOWLEDGED
    is EscalationState.Missed -> ReminderState.MISSED
    is EscalationState.Completed -> ReminderState.COMPLETED
}
