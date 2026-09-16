import Foundation
import CryptoKit

// MARK: - MedicationScheduler Implementation (L2 §5.4)

final class MedicationScheduler: MedicationSchedulerProtocol {

    private let storage: EncryptedLocalStorage
    private let alarmScheduler: PlatformAlarmScheduler
    private let observabilityBus: ObservabilityBus
    private let doubleDoseDetector: DoubleDoseDetector
    private let familyNotifier: FamilyNotifierProtocol
    /// Per-event-type caregiver notification preferences (caregiver
    /// event-notifications task, 2026-09-13). Read at FIRE time — the
    /// reminder itself carries no "notify" flag, so flipping the toggle
    /// changes every subsequent fire and nothing that already fired.
    private let caregiverNotifySettings: CaregiverNotifySettings
    /// Photo store for the entries' visual aids (medication-visual-aids
    /// task, 2026-09-16). Optional with a nil default so every existing
    /// test harness constructs a scheduler unchanged, and so a medicine
    /// with no photos — the overwhelming majority — never touches the
    /// disk on the arming path. `AppCoordinator` passes the app's shared
    /// MEDICATION store (the prefixed one), which is what puts the right
    /// box photo in the right dose's banner.
    private let visualAidStore: VisualAidStore?

    private var entries: [UUID: MedicationEntry] = [:]
    /// Escalation engines are keyed by REMINDER id, not medication entry id.
    /// A twice-daily entry produces two concurrent reminders; keying by entry
    /// id makes the second overwrite the first, corrupting the morning dose's
    /// escalation math (review finding C4).
    private var engines: [UUID: EscalationEngine] = [:]
    private var adherenceLog: [MedicationAdherenceLog] = []
    private var pendingRemindersList: [UUID: ScheduledReminder] = [:]
    private var confirmationChallenges: [UUID: ConfirmationChallenge] = [:]
    private var didRestore = false

    /// Active locale for user-facing text produced by this service (the
    /// confirmation-challenge prompts). Injected by `AppCoordinator` from
    /// `activeLocale`; the English default matches the legacy hardcoded
    /// strings.
    var locale: Locale = Locale(identifier: "en")

    /// Fired after the schedule changes, with the new entry list
    /// (calendar & family sharing, 2026-09-16).
    ///
    /// Every write path already funnels through `loadSchedule` — the
    /// Settings editor, the voice `set_reminder` path and the app's own
    /// restore — so one seam here observes all of them without any of
    /// them having to remember to tell the share layer. The list is
    /// passed rather than left for the observer to re-read so the
    /// observer sees exactly the version that was stored.
    ///
    /// Deliberately a plain closure and not a delegate/protocol: the
    /// only consumer is `CalendarShareService`, failures there must
    /// never affect the scheduler's own behavior, and a closure the
    /// coordinator assigns once is the smallest thing that works.
    var onScheduleChanged: (([MedicationEntry]) -> Void)?

    private let storageKeyReminders = "medication.pending_reminders"
    private let storageKeyAdherenceLog = "medication.adherence_log"
    private let storageKeyEntries = "medication.entries"

    var pendingReminders: [ScheduledReminder] {
        Array(pendingRemindersList.values).filter { $0.state != .completed }
    }

    /// Configured medication entries — used by the Settings medication
    /// schedule editor and the voice `set_reminder` path to read/append
    /// entries through the same storage the scheduler persists to.
    func medicationEntries() -> [MedicationEntry] {
        Array(entries.values).sorted { $0.medicationName < $1.medicationName }
    }

    /// One entry by id, or nil when it does not exist (deleted since the
    /// alarm was armed, or never loaded). Read by the Settings photo
    /// editor and by `MedicationVisualAidFireHandler` at FIRE time
    /// (medication-visual-aids task, 2026-09-16).
    func medicationEntry(for id: UUID) -> MedicationEntry? {
        entries[id]
    }

    /// The photo to attach to this entry's armed notifications: its FIRST
    /// visual aid, or nil when the entry has none, no store is wired, or
    /// the file has gone missing. One image per notification is the
    /// platform's limit (a `UNNotificationAttachment` is singular), and
    /// "the first photo the family added" is the one that matters — the
    /// full set is what the in-app dose screen pages through.
    ///
    /// The `entry.visualAids.first` guard comes first on purpose: a
    /// medicine with no photos must not touch the disk at all on the
    /// arming path.
    private func visualAidURL(for entry: MedicationEntry) -> URL? {
        guard let visualAidStore, let aid = entry.visualAids.first else { return nil }
        return visualAidStore.existingFileURL(aid, for: entry.id)
    }

    /// Replaces one entry's visual aids (the photo editor's save path,
    /// medication-visual-aids task 2026-09-16) — the medication analogue
    /// of `RoutineScheduler.setVisualAids`.
    ///
    /// Deliberately NOT `loadSchedule`: that rebuilds every pending
    /// reminder and drops the escalation engines, which is exactly right
    /// for an EDIT to the schedule and exactly wrong for attaching a photo.
    /// A photo must never reschedule a dose, reset an escalation window or
    /// disturb an acknowledgement in flight — so this persists the entry
    /// payload and touches nothing else. The armed notifications keep their
    /// existing trigger; the photo reaches the elder through the dose
    /// screen at fire time, which reads the entry.
    ///
    /// The FILES are the caller's business (`VisualAidStore.save` on add,
    /// `delete` on remove) — this mutator owns only the model payload.
    @discardableResult
    func setVisualAids(_ aids: [VisualAid], entryId: UUID) -> Bool {
        guard var entry = entries[entryId] else { return false }
        entry.visualAids = aids
        entries[entryId] = entry
        // The same payload shape `loadSchedule` writes (sorted by name),
        // so a photo edit and a schedule edit leave identical bytes.
        guard case .success = storage.write(key: storageKeyEntries,
                                            value: medicationEntries()) else {
            emit("entry_persistence_failed",
                 metadata: ["entry_id_hash": idHash(entryId)])
            return false
        }
        emit("entry_visual_aids_updated",
             metadata: ["entry_id_hash": idHash(entryId),
                        "count": String(aids.count)])
        return true
    }

    init(
        storage: EncryptedLocalStorage,
        alarmScheduler: PlatformAlarmScheduler,
        observabilityBus: ObservabilityBus,
        familyNotifier: FamilyNotifierProtocol,
        caregiverNotifySettings: CaregiverNotifySettings,
        visualAidStore: VisualAidStore? = nil
    ) {
        self.storage = storage
        self.alarmScheduler = alarmScheduler
        self.observabilityBus = observabilityBus
        self.familyNotifier = familyNotifier
        self.caregiverNotifySettings = caregiverNotifySettings
        self.visualAidStore = visualAidStore
        self.doubleDoseDetector = DoubleDoseDetector()
    }

    // MARK: - Load Schedule

    func loadSchedule(entries newEntries: [MedicationEntry]) {
        entries.removeAll()
        engines.removeAll()
        pendingRemindersList.removeAll()

        for entry in newEntries {
            entries[entry.id] = entry
        }

        _ = storage.write(key: storageKeyEntries, value: newEntries)

        emit("schedule_loaded", metadata: ["entry_count": "\(newEntries.count)"])

        createPendingReminders(for: newEntries, now: Date())

        // Last, and after the local work is fully committed: an observer
        // must never see a half-applied schedule, and the local
        // reminders are the part the elder depends on — they are armed
        // before anything is offered to the share layer.
        onScheduleChanged?(newEntries)
    }

    // MARK: - Schedule All

    func scheduleAll() {
        restoreState()
        rearmAllPendingReminders()
    }

    // MARK: - Acknowledge (Baseline FR-026 to FR-029)

    func acknowledge(entryId: UUID, at acknowledgedAt: Date) -> Result<Void, SafetyError> {
        guard let entry = entries[entryId] else {
            return .failure(.reminderPersistenceFailed)
        }

        guard let reminderId = activeReminderId(for: entryId),
              let engine = engines[reminderId] else {
            return .failure(.reminderPersistenceFailed)
        }

        let escalationResult = engine.acknowledge(at: acknowledgedAt)

        switch escalationResult.action {
        case .markAcknowledged:
            return finalizeAcknowledgement(
                entry: entry,
                entryId: entryId,
                at: acknowledgedAt,
                refireCount: engine.currentRefireCount
            )

        case .escalateToFamilyNotifier:
            recordMissedDose(entryId: entryId, entry: entry)
            return .success(())

        case .noAction, .fireReminder, .waitForAcknowledgement, .markMissed:
            return .success(())
        }
    }

    func acknowledgeWithConfirmation(
        entryId: UUID,
        at acknowledgedAt: Date,
        confirmationResponse: ConfirmationResponse
    ) -> Result<Void, SafetyError> {
        guard let entry = entries[entryId] else {
            return .failure(.reminderPersistenceFailed)
        }

        // If no challenge was issued yet for this entry, issue one now so the
        // caller-facing flow is: call once with a response → prompt appears →
        // call again with the answer. Silently accepting the first response
        // would defeat the dementia FR-D01 confirmation guarantee.
        let challenge = confirmationChallenges[entryId] ?? {
            let new = ConfirmationChallenge(locale: locale)
            confirmationChallenges[entryId] = new
            _ = new.start(
                medicationName: entry.medicationName,
                confirmationDescription: entry.confirmationDescription
            )
            emit("confirmation_challenged", metadata: ["entry_id_hash": idHash(entryId)])
            return new
        }()

        let confirmationAction = challenge.userResponds(with: confirmationResponse)

        switch confirmationAction {
        case .recordTaken:
            confirmationChallenges.removeValue(forKey: entryId)
            return checkDoubleDoseAndRecord(entry: entry, entryId: entryId, at: acknowledgedAt)

        case .reEnterEscalation:
            confirmationChallenges.removeValue(forKey: entryId)
            emit("confirmation_denied", metadata: ["entry_id_hash": idHash(entryId)])
            return reEnterEscalation(entryId: entryId, entry: entry)

        case .noAction:
            return .success(())

        case .issueChallenge:
            return .success(())
        }
    }

    // MARK: - Trigger Reminder (called by platform alarm)

    func triggerReminder(for reminderId: UUID) {
        guard var reminder = pendingRemindersList[reminderId] else {
            return
        }

        guard let entry = entries[reminder.medicationEntryId] else {
            return
        }

        let engine: EscalationEngine
        if let existing = engines[reminderId] {
            engine = existing
        } else {
            engine = makeEngine(for: entry, from: reminder)
            engines[reminderId] = engine
            _ = engine.start()
        }

        // FIRST-fire gate, read BEFORE `lastFiredAt` below overwrites it
        // (caregiver event-notifications task, 2026-09-13). A re-fire is
        // the SAME event firing again — the alarm nagging an
        // unacknowledged dose — so the caregiver wants the event, not one
        // push per refire. `lastFiredAt` is the only "has this fired
        // before" bit the reminder carries, and it is already persisted
        // for the escalation engine's own reasons: no new per-event flag.
        let isFirstFire = reminder.lastFiredAt == nil

        let escalationResult = engine.reminderDelivered(at: Date())
        reminder.state = engine.toReminderState()
        reminder.lastFiredAt = Date()
        pendingRemindersList[reminderId] = reminder

        // Persist updated state
        persistReminders()

        emit("reminder_fired", metadata: [
            "entry_id_hash": idHash(entry.id),
            "refire_count": "\(engine.currentRefireCount)"
        ])

        if isFirstFire {
            notifyCaregiversOfFirstFire(entry: entry, reminder: reminder)
        }

        // Schedule ack-window expiry check
        if case .waitForAcknowledgement(let deadline) = escalationResult.action {
            alarmScheduler.scheduleAckDeadlineCheck(
                reminderId: reminderId,
                entryId: entry.id,
                deadline: deadline
            )
        }
    }

    /// Caregiver alert for the first delivery of a medication reminder
    /// (caregiver event-notifications task, 2026-09-13).
    ///
    /// The event id is the REMINDER id, not the medication entry id: a
    /// twice-daily entry produces two concurrent reminders, and "the
    /// morning dose" vs "the evening dose" has to be two distinct events
    /// for the caregiver reading the alert stream. The medication NAME is
    /// the alert's title (the elder's own words for it — the same string
    /// the confirmation challenge and the notification body use) and it
    /// stays in memory; the bus records only the hashed id and the kind.
    private func notifyCaregiversOfFirstFire(entry: MedicationEntry,
                                             reminder: ScheduledReminder) {
        guard caregiverNotifySettings.isEnabled(for: .medicationReminder) else {
            emit("caregiver_event_skipped",
                 metadata: ["kind": EventNotifyKind.medicationReminder.rawValue])
            return
        }
        let context = FamilyAlertContext(
            kind: .medicationReminder,
            eventIdHash: idHash(reminder.id),
            eventTitle: entry.medicationName,
            fireAt: reminder.scheduledAt
        )
        emit("caregiver_event_fired",
             metadata: ["kind": EventNotifyKind.medicationReminder.rawValue,
                        "event_id_hash": context.eventIdHash])
        Task { [familyNotifier] in
            _ = await familyNotifier.notifyAll(
                alertType: .eventReminder,
                at: Date(),
                context: context
            )
        }
    }

    // MARK: - Ack Deadline Expired (called by platform alarm)

    func handleAckDeadlineExpired(for reminderId: UUID) {
        guard let reminder = pendingRemindersList[reminderId] else {
            return
        }

        guard let entry = entries[reminder.medicationEntryId] else {
            return
        }

        guard let engine = engines[reminderId] else {
            return
        }

        let result = engine.ackWindowExpired(at: Date())

        switch result.action {
        case .fireReminder(let refireCount):
            emit("refire", metadata: [
                "entry_id_hash": idHash(entry.id),
                "refire_count": "\(refireCount)"
            ])

            var updated = reminder
            updated.refireCount = refireCount
            updated.state = engine.toReminderState()
            pendingRemindersList[reminderId] = updated
            persistReminders()

            if let nextFireAt = result.nextFireAt {
                alarmScheduler.scheduleReminder(
                    reminderId: reminderId,
                    entryId: entry.id,
                    medicationName: entry.medicationName,
                    visualAidURL: visualAidURL(for: entry),
                    at: nextFireAt
                )
            }

        case .escalateToFamilyNotifier:
            recordMissedDose(entryId: entry.id, entry: entry)

        case .noAction, .markAcknowledged, .waitForAcknowledgement, .markMissed:
            break
        }
    }

    // MARK: - Start Confirmation Challenge (called after initial ack)

    /// Issues (or re-issues) the confirmation challenge for `entryId`.
    /// The returned prompt should be spoken to the user; the response then
    /// arrives via `acknowledgeWithConfirmation(entryId:at:confirmationResponse:)`,
    /// which reads the per-entry `ConfirmationChallenge` state left here.
    func startConfirmationChallenge(for entryId: UUID) -> String? {
        guard let entry = entries[entryId] else { return nil }

        let challenge = confirmationChallenges[entryId] ?? {
            let new = ConfirmationChallenge(locale: locale)
            confirmationChallenges[entryId] = new
            return new
        }()

        let action = challenge.start(
            medicationName: entry.medicationName,
            confirmationDescription: entry.confirmationDescription
        )

        if case .issueChallenge(let prompt) = action {
            emit("confirmation_challenged", metadata: ["entry_id_hash": idHash(entryId)])
            return prompt
        }
        return nil
    }

    // MARK: - Private

    private func finalizeAcknowledgement(
        entry: MedicationEntry,
        entryId: UUID,
        at acknowledgedAt: Date,
        refireCount: Int
    ) -> Result<Void, SafetyError> {
        let reminderId = activeReminderId(for: entryId)
        let logEntry = MedicationAdherenceLog(
            id: UUID(),
            medicationEntryId: entryId,
            scheduledAt: reminderId.flatMap { engines[$0]?.scheduledTime } ?? Date(),
            acknowledgedAt: acknowledgedAt,
            refireCount: refireCount,
            status: .acknowledged,
            familyAlerted: false,
            photoVerification: entry.photoVerificationEnabled ? .pending : .notRequired,
            confirmationPassed: true,
            confirmationDeniedAt: nil
        )

        adherenceLog.append(logEntry)

        // Persist adherence log
        if case .failure = storage.write(key: storageKeyAdherenceLog, value: adherenceLog) {
            return .failure(.reminderPersistenceFailed)
        }

        // Clean up pending reminder + its engine
        if let reminderId = reminderId {
            pendingRemindersList.removeValue(forKey: reminderId)
            alarmScheduler.cancelReminder(reminderId: reminderId)
            if let engine = engines.removeValue(forKey: reminderId) {
                _ = engine.markCompleted()
            }
        }

        persistReminders()

        emit("acknowledged", metadata: [
            "entry_id_hash": idHash(entryId),
            "refire_count": "\(refireCount)"
        ])

        return .success(())
    }

    private func checkDoubleDoseAndRecord(
        entry: MedicationEntry,
        entryId: UUID,
        at acknowledgedAt: Date
    ) -> Result<Void, SafetyError> {
        let doseCheck = doubleDoseDetector.check(
            medicationEntryId: entryId,
            windowHours: entry.doubleDoseWindowHours,
            adherenceLog: adherenceLog,
            now: acknowledgedAt
        )

        if doseCheck.isDuplicate {
            // Block double dose (FR-D03)
            let blockedLog = MedicationAdherenceLog(
                id: UUID(),
                medicationEntryId: entryId,
                scheduledAt: Date(),
                acknowledgedAt: acknowledgedAt,
                refireCount: 0,
                status: .doubleDoseAttempt,
                familyAlerted: false,
                photoVerification: .notRequired,
                confirmationPassed: false,
                confirmationDeniedAt: nil
            )
            adherenceLog.append(blockedLog)
            _ = storage.write(key: storageKeyAdherenceLog, value: adherenceLog)

            emit("double_dose_blocked", metadata: ["entry_id_hash": idHash(entryId)])

            // Alert caregiver asynchronously
            Task {
                let _ = await familyNotifier.notifyAll(
                    alertType: .possibleDoubleDose,
                    at: acknowledgedAt
                )
            }

            return .success(())  // Not a persistence failure -- dose intentionally blocked
        }

        // No duplicate -- record the dose. Per-entry challenge state was
        // already cleared by acknowledgeWithConfirmation before we got here.
        return finalizeAcknowledgement(
            entry: entry,
            entryId: entryId,
            at: acknowledgedAt,
            refireCount: activeReminderId(for: entryId).flatMap { engines[$0]?.currentRefireCount } ?? 0
        )
    }

    private func recordMissedDose(entryId: UUID, entry: MedicationEntry) {
        let reminderId = activeReminderId(for: entryId)
        let logEntry = MedicationAdherenceLog(
            id: UUID(),
            medicationEntryId: entryId,
            scheduledAt: reminderId.flatMap { engines[$0]?.scheduledTime } ?? Date(),
            acknowledgedAt: nil,
            refireCount: entry.maxRefireCount,
            status: .missed,
            familyAlerted: true,
            photoVerification: .notRequired,
            confirmationPassed: false,
            confirmationDeniedAt: nil
        )

        adherenceLog.append(logEntry)
        _ = storage.write(key: storageKeyAdherenceLog, value: adherenceLog)

        // Remove pending reminder + its engine
        if let reminderId = reminderId {
            pendingRemindersList.removeValue(forKey: reminderId)
            engines.removeValue(forKey: reminderId)
            alarmScheduler.cancelReminder(reminderId: reminderId)
        }
        persistReminders()

        emit("missed", metadata: ["entry_id_hash": idHash(entryId)])
        emit("family_alerted", metadata: ["entry_id_hash": idHash(entryId)])

        // Fire family notification asynchronously
        Task {
            let _ = await familyNotifier.notifyAll(
                alertType: .missedMedication,
                at: Date()
            )
        }
    }

    private func reEnterEscalation(entryId: UUID, entry: MedicationEntry) -> Result<Void, SafetyError> {
        guard let reminderId = activeReminderId(for: entryId),
              let engine = engines[reminderId] else {
            return .failure(.reminderPersistenceFailed)
        }

        // Find the next re-fire time
        let nextTime = engine.nextRefireTime(after: Date())

        if Date() < engine.escalationDeadline {
            alarmScheduler.scheduleReminder(
                reminderId: reminderId,
                entryId: entryId,
                medicationName: entry.medicationName,
                visualAidURL: visualAidURL(for: entry),
                at: nextTime
            )
        }

        return .success(())
    }

    private func restoreState() {
        // Only hydrate from disk once per process. `scheduleAll()` is called on
        // every BGTask wake; a second restore would clobber in-memory mutations
        // (e.g. an acknowledgement received but not yet persisted).
        guard !didRestore else { return }
        didRestore = true

        if let storedReminders: [String: ScheduledReminder] = try? storage.read(
            key: storageKeyReminders,
            type: [String: ScheduledReminder].self
        ).get() {
            var restored: [UUID: ScheduledReminder] = [:]
            for (key, reminder) in storedReminders {
                if let uuid = UUID(uuidString: key) {
                    restored[uuid] = reminder
                }
            }
            pendingRemindersList = restored
        }

        if let storedLog: [MedicationAdherenceLog] = try? storage.read(
            key: storageKeyAdherenceLog,
            type: [MedicationAdherenceLog].self
        ).get() {
            adherenceLog = storedLog
        }

        if let storedEntries: [MedicationEntry] = try? storage.read(
            key: storageKeyEntries,
            type: [MedicationEntry].self
        ).get() {
            entries = Dictionary(uniqueKeysWithValues: storedEntries.map { ($0.id, $0) })
        }
    }

    private func rearmAllPendingReminders() {
        let now = Date()

        for (reminderId, reminder) in pendingRemindersList {
            guard reminder.state != .acknowledged,
                  reminder.state != .missed,
                  reminder.state != .completed else {
                continue
            }

            guard let entry = entries[reminder.medicationEntryId] else {
                continue
            }

            // Never-fire reminders (state == .pending) are future doses.
            // They must be re-armed for their scheduled time, NOT fired now
            // — otherwise every app relaunch prompts early medication.
            if reminder.state == .pending {
                if reminder.scheduledAt > now {
                    alarmScheduler.scheduleReminder(
                        reminderId: reminderId,
                        entryId: entry.id,
                        medicationName: entry.medicationName,
                        visualAidURL: visualAidURL(for: entry),
                        at: reminder.scheduledAt
                    )
                } else {
                    // Scheduled time passed while the app was dead and the
                    // platform alarm never delivered (or was lost). Start the
                    // escalation cycle now so the dose is not silently skipped.
                    triggerReminder(for: reminderId)
                }
                continue
            }

            let engine = makeEngine(for: entry, from: reminder)
            engines[reminderId] = engine

            let recoveryResult = engine.recover(from: reminder, at: now)

            switch recoveryResult.action {
            case .fireReminder:
                // Fired before the kill; delivery not confirmed. Re-fire now
                // if still within the escalation window (FR-029).
                if now < engine.escalationDeadline {
                    triggerReminder(for: reminderId)
                } else {
                    recordMissedDose(entryId: entry.id, entry: entry)
                }

            case .escalateToFamilyNotifier:
                if now >= engine.escalationDeadline {
                    recordMissedDose(entryId: entry.id, entry: entry)
                }

            case .noAction, .markAcknowledged, .waitForAcknowledgement, .markMissed:
                break
            }
        }
    }

    private func createPendingReminders(for entries: [MedicationEntry], now: Date) {
        let calendar = Calendar.current

        for entry in entries {
            for scheduleTime in entry.scheduleTimes {
                guard let scheduledAt = nextOccurrence(of: scheduleTime, after: now, calendar: calendar) else {
                    continue
                }

                let reminder = ScheduledReminder(
                    id: UUID(),
                    medicationEntryId: entry.id,
                    scheduledAt: scheduledAt,
                    refireCount: 0,
                    escalationDeadline: scheduledAt.addingTimeInterval(TimeInterval(entry.escalationWindowMinutes * 60)),
                    state: .pending,
                    lastFiredAt: nil,
                    acknowledgedAt: nil
                )
                pendingRemindersList[reminder.id] = reminder
                // Engines are keyed per-reminder (C4) — a twice-daily entry
                // gets two independent escalation engines.
                engines[reminder.id] = makeEngine(for: entry, from: reminder)
            }
        }

        guard persistReminders() else { return }

        for reminder in pendingRemindersList.values {
            guard let entry = self.entries[reminder.medicationEntryId] else { continue }
            alarmScheduler.scheduleReminder(
                reminderId: reminder.id,
                entryId: entry.id,
                medicationName: entry.medicationName,
                visualAidURL: visualAidURL(for: entry),
                at: reminder.scheduledAt
            )
        }
    }

    private func nextOccurrence(of time: DateComponents, after now: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second ?? 0

        guard let today = calendar.date(from: components) else { return nil }
        if today > now {
            return today
        }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }

    private func makeEngine(for entry: MedicationEntry, from reminder: ScheduledReminder) -> EscalationEngine {
        EscalationEngine(
            scheduledTime: reminder.scheduledAt,
            ackWindowMinutes: entry.ackWindowMinutes,
            maxRefireCount: entry.maxRefireCount,
            escalationWindowMinutes: entry.escalationWindowMinutes
        )
    }

    /// The reminder currently tracking `entryId`'s dose. An entry with
    /// multiple daily times may have several pending reminders; the active
    /// one is the earliest-scheduled. Engine lookups must go through this
    /// rather than assuming `engines[entryId]` exists (C4).
    private func activeReminderId(for entryId: UUID) -> UUID? {
        pendingRemindersList
            .filter { $0.value.medicationEntryId == entryId }
            .sorted { $0.value.scheduledAt < $1.value.scheduledAt }
            .first?.key
    }

    @discardableResult
    private func persistReminders() -> Bool {
        let dict = pendingRemindersList.reduce(into: [String: ScheduledReminder]()) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
        switch storage.write(key: storageKeyReminders, value: dict) {
        case .success:
            return true
        case .failure:
            emit("reminder_persistence_failed", metadata: [:])
            return false
        }
    }

    // MARK: - Observability

    private func idHash(_ id: UUID) -> String {
        IdHashing.shortHash(of: id)
    }

    private func emit(_ eventType: String, metadata: [String: String]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "medication_scheduler",
            eventType: eventType,
            durationMs: nil,
            outcome: "success",
            errorCode: nil,
            metadata: metadata
        ))
    }
}
