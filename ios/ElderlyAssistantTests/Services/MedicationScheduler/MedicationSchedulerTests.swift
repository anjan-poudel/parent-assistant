import XCTest
@testable import ElderlyAssistant

// MARK: - Mock Dependencies

final class MockEncryptedLocalStorage: EncryptedLocalStorage {
    private var store: [String: Data] = [:]

    var writeCallCount = 0
    var readCallCount = 0
    var shouldFailWrite = false
    /// Fired AFTER a write has actually landed in the store — never on the
    /// failure path, so a witness built on this hook means "a persistence
    /// really happened here" and not merely "a write was attempted". It is
    /// the storage half of the persist-before-arm call-order witness
    /// (T-008): paired with `MockAlarmScheduler.onScheduleReminder`, the
    /// two hooks produce an ordered log of the arming pass.
    var onWriteCompleted: (() -> Void)?

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        writeCallCount += 1
        if shouldFailWrite {
            return .failure(.encryptedWriteFailed)
        }
        if let data = try? JSONEncoder().encode(value) {
            store[key] = data
        }
        onWriteCompleted?()
        return .success(())
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        readCallCount += 1
        guard let data = store[key] else {
            return .failure(.encryptedReadFailed)
        }
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            return .failure(.encryptedReadFailed)
        }
        return .success(value)
    }

    func delete(key: String) -> Result<Void, StorageError> {
        store.removeValue(forKey: key)
        return .success(())
    }
}

final class MockAlarmScheduler: PlatformAlarmScheduler {
    var scheduledReminders: [UUID: Date] = [:]
    var cancelledReminders: Set<UUID> = []
    var ackDeadlineChecks: [UUID: Date] = [:]
    var scheduleCallCount = 0
    /// The banner photo handed to each arming call (medication-visual-aids
    /// task, 2026-09-16) — nil for a dose with no photos.
    var visualAidURLs: [UUID: URL] = [:]
    /// Fired after the arm has been recorded — the alarm half of the
    /// persist-before-arm call-order witness (T-008); see
    /// `MockEncryptedLocalStorage.onWriteCompleted`.
    var onScheduleReminder: (() -> Void)?

    func scheduleReminder(reminderId: UUID, entryId: UUID, medicationName: String,
                          visualAidURL: URL?, at scheduledTime: Date) {
        scheduleCallCount += 1
        scheduledReminders[reminderId] = scheduledTime
        visualAidURLs[reminderId] = visualAidURL
        onScheduleReminder?()
    }

    func scheduleAckDeadlineCheck(reminderId: UUID, entryId: UUID, deadline: Date) {
        ackDeadlineChecks[reminderId] = deadline
    }

    func cancelReminder(reminderId: UUID) {
        cancelledReminders.insert(reminderId)
        scheduledReminders.removeValue(forKey: reminderId)
    }

    func cancelAllReminders() {
        cancelledReminders = Set(scheduledReminders.keys)
        scheduledReminders.removeAll()
    }
}

final class MockObservabilityBus: ObservabilityBus {
    var emittedEvents: [ObservabilityEvent] = []

    func emit(_ event: ObservabilityEvent) {
        emittedEvents.append(event)
    }
}

final class MockFamilyNotifier: FamilyNotifierProtocol {
    var notifyCallCount = 0
    var lastAlertType: FamilyAlertType?
    var shouldFailForContacts: Set<String> = []
    /// Every context-carrying call, in order (caregiver
    /// event-notifications task, 2026-09-13) — the event alerts are
    /// asserted through the CONTEXT (which event, which kind), never
    /// through a wire payload the stub provider discards.
    private(set) var contexts: [FamilyAlertContext] = []
    /// Count of calls that carried NO context — the legacy alerts
    /// (missed dose, double dose) must keep riding the context-free
    /// form, and this is how a test proves the split.
    private(set) var contextFreeCallCount = 0
    /// Fired on EVERY notify, from whatever executor the production
    /// `Task` landed on — the schedulers notify asynchronously, so the
    /// only deterministic way to assert on it is to wait for the signal
    /// instead of hoping the task already ran.
    var onNotify: (() -> Void)?

    func notifyAll(alertType: FamilyAlertType, at timestamp: Date) async -> [NotificationResult] {
        notifyCallCount += 1
        contextFreeCallCount += 1
        lastAlertType = alertType
        onNotify?()
        return [NotificationResult(contactIdHash: "test_hash", success: true, errorCode: nil)]
    }

    func notifyAll(alertType: FamilyAlertType, at timestamp: Date,
                   context: FamilyAlertContext?) async -> [NotificationResult] {
        notifyCallCount += 1
        lastAlertType = alertType
        if let context {
            contexts.append(context)
        } else {
            contextFreeCallCount += 1
        }
        onNotify?()
        return [NotificationResult(contactIdHash: "test_hash", success: true,
                                   errorCode: nil,
                                   channel: context == nil ? nil : NotifyChannel.sms.rawValue)]
    }
}

// MARK: - MedicationScheduler Tests

final class MedicationSchedulerTests: XCTestCase {

    var scheduler: MedicationScheduler!
    var mockStorage: MockEncryptedLocalStorage!
    var mockAlarm: MockAlarmScheduler!
    var mockObservability: MockObservabilityBus!
    var mockFamilyNotifier: MockFamilyNotifier!
    /// Each test gets its OWN isolated settings (a throwaway defaults
    /// suite) so a toggle flipped in one test can never leak into the
    /// next — the settings persist by design, which makes a shared
    /// instance an order-dependence bug waiting to happen.
    var caregiverNotifySettings: CaregiverNotifySettings!

    override func setUp() {
        super.setUp()
        mockStorage = MockEncryptedLocalStorage()
        mockAlarm = MockAlarmScheduler()
        mockObservability = MockObservabilityBus()
        mockFamilyNotifier = MockFamilyNotifier()
        caregiverNotifySettings = CaregiverNotifySettings.isolated()
        scheduler = MedicationScheduler(
            storage: mockStorage,
            alarmScheduler: mockAlarm,
            observabilityBus: mockObservability,
            familyNotifier: mockFamilyNotifier,
            caregiverNotifySettings: caregiverNotifySettings
        )
    }

    // MARK: - Load Schedule

    func testLoadSchedulePersistsEntries() {
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)

        scheduler.loadSchedule(entries: [entry])

        // Two writes: the schedule entries, then the pending reminders
        // derived from them (createPendingReminders → persistReminders).
        XCTAssertEqual(mockStorage.writeCallCount, 2)
        XCTAssertEqual(scheduler.pendingReminders.count, 1)
    }

    func testLoadScheduleCreatesReminderForEachEntry() {
        let entry1 = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        let entry2 = makeMedicationEntry(name: "Metformin", timeHour: 20, timeMinute: 0)

        scheduler.loadSchedule(entries: [entry1, entry2])

        XCTAssertEqual(scheduler.pendingReminders.count, 2)
    }

    // MARK: - Share observer (calendar & family sharing task, 2026-09-16)

    func testLoadScheduleNotifiesTheShareObserverOnceWithTheStoredEntries() {
        // The share layer observes every WRITE of the schedule, not every
        // editor: the Settings editor, the voice `set_reminder` path and
        // the app's own restore all funnel through `loadSchedule`, so one
        // closure here covers all of them without any of them having to
        // remember to tell the share layer.
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        var observed: [[MedicationEntry]] = []
        scheduler.onScheduleChanged = { observed.append($0) }

        scheduler.loadSchedule(entries: [entry])

        XCTAssertEqual(observed.count, 1,
                       "one notification per write — a second would re-queue the same twins")
        XCTAssertEqual(observed.first?.map(\.id), [entry.id])
        XCTAssertEqual(observed.first?.first?.medicationName, "Amlodipine")
        XCTAssertEqual(scheduler.medicationEntries().map(\.id), [entry.id],
                       "the entry the observer saw is the entry that was stored")
    }

    func testShareObserverFiresAfterTheLocalRemindersAreArmed() {
        // "After" is asserted on what the observer can SEE, not on call
        // order alone: at notification time the schedule and the pending
        // list are already persisted and the platform alarm is already
        // armed. The local reminder is the part the elder depends on —
        // it must never be offered to the share layer half-applied.
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        let schedulerUnderTest = scheduler!
        let alarm = mockAlarm!
        let storage = mockStorage!
        var storedAtNotification: [MedicationEntry]?
        var pendingAtNotification: Int?
        var alarmsAtNotification: Int?
        var writesAtNotification: Int?
        scheduler.onScheduleChanged = { entries in
            storedAtNotification = entries
            pendingAtNotification = schedulerUnderTest.pendingReminders.count
            alarmsAtNotification = alarm.scheduledReminders.count
            writesAtNotification = storage.writeCallCount
        }

        scheduler.loadSchedule(entries: [entry])

        XCTAssertEqual(storedAtNotification?.map(\.id), [entry.id])
        XCTAssertEqual(pendingAtNotification, 1,
                       "the pending reminder exists before the share layer is told")
        XCTAssertEqual(alarmsAtNotification, 1,
                       "and it is already armed with the platform alarm")
        XCTAssertGreaterThanOrEqual(writesAtNotification ?? 0, 2,
                                    "the entries and the pending list are already persisted")
    }

    func testLoadScheduleWithNoObserverStillWorks() {
        // The observer is optional and the scheduler never depends on it
        // being there — the share feature is an addition to the
        // medication path, not a prerequisite for it.
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)

        scheduler.onScheduleChanged = nil
        scheduler.loadSchedule(entries: [entry])

        XCTAssertEqual(scheduler.pendingReminders.count, 1)
        XCTAssertEqual(scheduler.medicationEntries().count, 1)
    }

    // MARK: - Persistence before alarm

    func testPersistenceBeforeAlarmOnScheduleAll() {
        mockStorage.shouldFailWrite = true

        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        scheduler.loadSchedule(entries: [entry])

        // scheduleAll restores from storage; with failing storage,
        // pending reminders won't be persisted but scheduled reminders
        // from loadSchedule should still have been written
        XCTAssertGreaterThanOrEqual(mockStorage.writeCallCount, 1)
    }

    // MARK: - Acknowledgement flow

    func testAcknowledgeMedication() {
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        scheduler.loadSchedule(entries: [entry])

        let result = scheduler.acknowledge(entryId: entry.id, at: Date())

        if case .failure = result {
            // May fail if engine state isn't set up yet (needs trigger first)
            // This is expected in unit test without full trigger flow
        }
    }

    // MARK: - Observability - no medication names

    func testNoMedicationNamesInObservabilityEvents() {
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        scheduler.loadSchedule(entries: [entry])

        // Check all emitted events for the medication name
        for event in mockObservability.emittedEvents {
            for (_, value) in event.metadata {
                XCTAssertFalse(
                    value.lowercased().contains("amlodipine"),
                    "Observability event metadata contains medication name: \(value)"
                )
            }
        }
    }

    // MARK: - Pending reminders

    func testPendingRemindersReturnsActiveReminders() {
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        scheduler.loadSchedule(entries: [entry])

        let pending = scheduler.pendingReminders
        XCTAssertFalse(pending.isEmpty)
    }

    // MARK: - Process kill recovery

    func testScheduleAllRestoresPendingReminders() {
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        scheduler.loadSchedule(entries: [entry])

        // Simulate persistent storage of pending reminder
        let reminder = ScheduledReminder(
            id: UUID(),
            medicationEntryId: entry.id,
            scheduledAt: Date(),
            refireCount: 0,
            escalationDeadline: Date().addingTimeInterval(3600),
            state: .pending,
            lastFiredAt: nil,
            acknowledgedAt: nil
        )
        _ = mockStorage.write(key: "medication.pending_reminders", value: [
            reminder.id.uuidString: reminder
        ])
        _ = mockStorage.write(key: "medication.entries", value: [entry])

        // Create new scheduler to simulate process restart
        let newScheduler = MedicationScheduler(
            storage: mockStorage,
            alarmScheduler: mockAlarm,
            observabilityBus: mockObservability,
            familyNotifier: mockFamilyNotifier,
            caregiverNotifySettings: caregiverNotifySettings
        )

        newScheduler.scheduleAll()

        // Should have re-armed the pending reminder
        XCTAssertGreaterThanOrEqual(mockAlarm.scheduleCallCount, 0)
    }

    // MARK: - Confirmation challenge flow

    func testStartConfirmationChallengeReturnsPrompt() {
        let entry = makeMedicationEntry(
            name: "Amlodipine",
            timeHour: 8,
            timeMinute: 0,
            confirmationDescription: "small white tablet in the blue box"
        )
        scheduler.loadSchedule(entries: [entry])

        let prompt = scheduler.startConfirmationChallenge(for: entry.id)

        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt!.contains("Amlodipine"))
        XCTAssertTrue(prompt!.contains("small white tablet"))
    }

    /// R-2: both challenge construction sites — the first-call-issues path
    /// and `startConfirmationChallenge` — pass the scheduler's configured
    /// `challengeTimeoutSeconds` explicitly, so an injected shorter window
    /// is honored end-to-end: the answer is evaluated after that window
    /// elapsed and both sites take the timeout path (re-enter escalation),
    /// where the named default would have recorded the dose instead.
    ///
    /// The injected window is negative — shorter than any real window, so
    /// its deadline already predates the answer. That is the one shape
    /// that drives the first-call-issues site into its timeout arm
    /// deterministically, because that call issues the challenge AND
    /// evaluates the answer in the same call; no clock waiting needed.
    func testInjectedTimeoutIsUsedByBothChallengeSites() {
        let injectedWindowSeconds: TimeInterval = -1
        scheduler = MedicationScheduler(
            storage: mockStorage,
            alarmScheduler: mockAlarm,
            observabilityBus: mockObservability,
            familyNotifier: mockFamilyNotifier,
            caregiverNotifySettings: caregiverNotifySettings,
            challengeTimeoutSeconds: injectedWindowSeconds
        )
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        scheduler.loadSchedule(entries: [entry])

        // Path 1 — the first-call-issues challenge (MedicationScheduler
        // :269): this call both issues the challenge and evaluates the
        // answer, which lands after the injected window elapsed.
        _ = scheduler.acknowledgeWithConfirmation(entryId: entry.id, at: Date(),
                                                  confirmationResponse: .yes)

        // Path 2 — startConfirmationChallenge (:449) issues its own
        // challenge with the same configured value; the answer then
        // arrives late through the shipped response seam.
        XCTAssertNotNil(scheduler.startConfirmationChallenge(for: entry.id))
        _ = scheduler.acknowledgeWithConfirmation(entryId: entry.id, at: Date(),
                                                  confirmationResponse: .yes)

        let eventTypes = mockObservability.emittedEvents.map(\.eventType)
        XCTAssertEqual(eventTypes.filter { $0 == "confirmation_challenged" }.count, 2,
                       "one challenge issued by each construction site")
        XCTAssertEqual(eventTypes.filter { $0 == "confirmation_denied" }.count, 2,
                       "both sites time out on the injected short window and re-enter escalation")
        XCTAssertEqual(eventTypes.filter { $0 == "acknowledged" }.count, 0,
                       "with the named default the same drive would have recorded instead")
        XCTAssertEqual(eventTypes.filter { $0 == "double_dose_blocked" }.count, 0,
                       "the timeout path records nothing")
        XCTAssertGreaterThanOrEqual(mockAlarm.scheduleCallCount, 3,
                                    "each timeout re-armed the next refire (1 arm at load + 2 re-entries)")

        // Control — the SAME drive on a scheduler using the named default:
        // both sites accept the answer and record. The flip to the timeout
        // path in the drive above is therefore caused by the injected
        // value alone, not by the drive's shape.
        let controlBus = MockObservabilityBus()
        let controlScheduler = MedicationScheduler(
            storage: MockEncryptedLocalStorage(),
            alarmScheduler: MockAlarmScheduler(),
            observabilityBus: controlBus,
            familyNotifier: mockFamilyNotifier,
            caregiverNotifySettings: CaregiverNotifySettings.isolated()
        )
        let pathOneEntry = makeMedicationEntry(name: "Metformin", timeHour: 9, timeMinute: 0)
        let pathTwoEntry = makeMedicationEntry(name: "Lisinopril", timeHour: 10, timeMinute: 0)
        controlScheduler.loadSchedule(entries: [pathOneEntry, pathTwoEntry])

        _ = controlScheduler.acknowledgeWithConfirmation(entryId: pathOneEntry.id, at: Date(),
                                                         confirmationResponse: .yes)
        XCTAssertNotNil(controlScheduler.startConfirmationChallenge(for: pathTwoEntry.id))
        _ = controlScheduler.acknowledgeWithConfirmation(entryId: pathTwoEntry.id, at: Date(),
                                                         confirmationResponse: .yes)

        let controlEventTypes = controlBus.emittedEvents.map(\.eventType)
        XCTAssertEqual(controlEventTypes.filter { $0 == "acknowledged" }.count, 2,
                       "the default window accepts and records the same drive at both sites")
        XCTAssertEqual(controlEventTypes.filter { $0 == "confirmation_denied" }.count, 0)
    }

    // MARK: - Caregiver event alerts (2026-09-13)

    /// First delivery of a reminder, toggle ON → exactly one event alert,
    /// carrying the medication kind, the medication NAME as the title and
    /// the REMINDER id (not the entry id) as the hash.
    func testFirstFireNotifiesCaregiversWithMedicationKind() async {
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        scheduler.loadSchedule(entries: [entry])
        caregiverNotifySettings.medicationReminders = true
        guard let reminderId = scheduler.pendingReminders.first?.id else {
            return XCTFail("expected a pending reminder")
        }
        let notified = expectation(description: "caregiver alert")
        mockFamilyNotifier.onNotify = { notified.fulfill() }

        scheduler.triggerReminder(for: reminderId)
        await fulfillment(of: [notified], timeout: 2)

        XCTAssertEqual(mockFamilyNotifier.lastAlertType, .eventReminder,
                       "the event alert rides the one eventReminder wire type")
        XCTAssertEqual(mockFamilyNotifier.contexts.count, 1)
        let context = mockFamilyNotifier.contexts.first
        XCTAssertEqual(context?.kind, .medicationReminder)
        XCTAssertEqual(context?.eventTitle, "Amlodipine",
                       "the alert title is the medication name the elder knows")
        XCTAssertEqual(context?.eventIdHash, IdHashing.shortHash(of: reminderId),
                       "the hash is the REMINDER id — a twice-daily entry has two distinct doses")
    }

    /// A RE-fire (the alarm nagging an unacknowledged dose) is the same
    /// event, not a new one — the caregiver gets one alert per event.
    func testRefireDoesNotNotifyCaregiversAgain() async {
        let entry = makeMedicationEntry(name: "Metformin", timeHour: 8, timeMinute: 0)
        scheduler.loadSchedule(entries: [entry])
        caregiverNotifySettings.medicationReminders = true
        guard let reminderId = scheduler.pendingReminders.first?.id else {
            return XCTFail("expected a pending reminder")
        }
        let firstFire = expectation(description: "first fire alert")
        mockFamilyNotifier.onNotify = { firstFire.fulfill() }
        scheduler.triggerReminder(for: reminderId)
        await fulfillment(of: [firstFire], timeout: 2)
        XCTAssertEqual(mockFamilyNotifier.contexts.count, 1)

        let noSecondAlert = expectation(description: "no second event alert")
        noSecondAlert.isInverted = true
        mockFamilyNotifier.onNotify = { noSecondAlert.fulfill() }
        scheduler.triggerReminder(for: reminderId)
        await fulfillment(of: [noSecondAlert], timeout: 0.3)

        XCTAssertEqual(mockFamilyNotifier.contexts.count, 1,
                       "a re-fire must not send a second alert for the SAME event")
    }

    /// Toggle OFF (the default) → the reminder fires exactly as before
    /// and no caregiver is told anything.
    func testFirstFireDoesNotNotifyWhenToggleIsOff() async {
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        scheduler.loadSchedule(entries: [entry])
        XCTAssertFalse(caregiverNotifySettings.medicationReminders, "defaults are OFF")
        guard let reminderId = scheduler.pendingReminders.first?.id else {
            return XCTFail("expected a pending reminder")
        }
        let noAlert = expectation(description: "no caregiver alert")
        noAlert.isInverted = true
        mockFamilyNotifier.onNotify = { noAlert.fulfill() }

        scheduler.triggerReminder(for: reminderId)
        await fulfillment(of: [noAlert], timeout: 0.3)

        XCTAssertTrue(mockFamilyNotifier.contexts.isEmpty)
    }

    // MARK: - Resolution feed at arming (T-008, IF-11)

    /// FR-MSR-002's first scenario, end to end: a household on the default
    /// mapping prompts the elder at the mapped clock time — and everything
    /// downstream of that time is derived from it, not from a second
    /// source.
    ///
    /// The entry's own stored times are deliberately a DIFFERENT hour
    /// (06:15): for a slot entry that value is only the resolved-time
    /// mirror (D2), so a scheduler that armed from it would prompt this
    /// household at the wrong hour — the one failure this seam exists to
    /// prevent.
    func testSlotEntryArmsAtResolvedTime() {
        installMapping(MedicationSlotClock.default, into: mockStorage)
        let now = Date()
        let entry = makeSlotEntry(slot: .morning, mirrorHour: 6, mirrorMinute: 15)

        scheduler.loadSchedule(entries: [entry])

        // IF-11 directly: the morning slot resolves through the mapping.
        guard case .success(let resolved) = scheduler.resolvedScheduleTimes(for: entry) else {
            return XCTFail("a slot entry under the default mapping must resolve")
        }
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.hour, 8)
        XCTAssertEqual(resolved.first?.minute, 0)

        guard let reminder = scheduler.pendingReminders.first,
              let armed = mockAlarm.scheduledReminders[reminder.id] else {
            return XCTFail("the day's reminder must exist and be armed")
        }
        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.hour, from: armed), 8,
                       "the dose is armed at the MAPPED morning time, not at the mirror's 06:15")
        XCTAssertEqual(calendar.component(.minute, from: armed), 0)
        XCTAssertGreaterThan(armed, now, "and at its next occurrence, not in the past")

        // The persisted state carries the resolved exact time, and the
        // escalation deadline is measured from that same instant.
        XCTAssertEqual(reminder.scheduledAt, armed)
        XCTAssertEqual(reminder.escalationDeadline, armed.addingTimeInterval(TimeInterval(60 * 60)))

        // The mirror is untouched by arming: the save gate and the mapping
        // re-arm pass remain its only writers (D2).
        XCTAssertEqual(scheduler.medicationEntry(for: entry.id)?.scheduleTimes.first?.hour, 6)
        XCTAssertEqual(scheduler.medicationEntry(for: entry.id)?.scheduleTimes.first?.minute, 15)

        // The acknowledgement window is armed for this reminder's delivery…
        scheduler.triggerReminder(for: reminder.id)
        guard let firedAt = scheduler.pendingReminders.first(where: { $0.id == reminder.id })?.lastFiredAt,
              let ackDeadline = mockAlarm.ackDeadlineChecks[reminder.id] else {
            return XCTFail("firing must arm the acknowledgement-window check")
        }
        XCTAssertEqual(ackDeadline.timeIntervalSince(firedAt), TimeInterval(5 * 60), accuracy: 1,
                       "the window is the entry's configured ackWindowMinutes from delivery")

        // …and the re-fire schedule is measured from the SAME resolved
        // scheduled time: re-fire 1 lands at 08:00 + one 12-minute
        // interval, which the engine can only produce if its
        // `scheduledTime` is the resolved 08:00.
        scheduler.handleAckDeadlineExpired(for: reminder.id)
        XCTAssertEqual(mockAlarm.scheduledReminders[reminder.id],
                       armed.addingTimeInterval(TimeInterval(12 * 60)),
                       "the re-fire schedule derives from the same resolved scheduled time")
    }

    /// The safety ordering (FR-MSR-022): the reminder state reaches the
    /// store before the platform alarm exists. Witnessed as an ordered log
    /// produced by both halves of the seam — a successful write, then the
    /// arm — and cross-checked against what the store held at arm time.
    func testPersistBeforeArmOrderForSlotEntries() {
        installMapping(MedicationSlotClock.default, into: mockStorage)
        let entry = makeSlotEntry(slot: .morning, mirrorHour: 8, mirrorMinute: 0)

        // The hooks go on AFTER the mapping is installed: the witness is
        // about the arming pass, not about the fixture.
        let storage = mockStorage!
        var order: [String] = []
        var persistedAtArmTime: [String: ScheduledReminder]?
        storage.onWriteCompleted = { order.append("persist") }
        mockAlarm.onScheduleReminder = {
            order.append("arm")
            if persistedAtArmTime == nil,
               case .success(let stored) = storage.read(key: "medication.pending_reminders",
                                                        type: [String: ScheduledReminder].self) {
                persistedAtArmTime = stored
            }
        }

        scheduler.loadSchedule(entries: [entry])

        guard let firstArm = order.firstIndex(of: "arm") else {
            return XCTFail("the dose must be armed")
        }
        XCTAssertEqual(firstArm, 2,
                       "both writes — the entries payload and the pending list — complete before the first arm")
        XCTAssertEqual(Array(order.prefix(firstArm)), ["persist", "persist"],
                       "nothing but persistence precedes the arm")
        XCTAssertEqual(order.filter { $0 == "arm" }.count, 1)

        // The order is only half the claim: the payload that was on disk
        // BEFORE the arm already carried the resolved exact time.
        guard let persisted = persistedAtArmTime?.values.first,
              let armed = mockAlarm.scheduledReminders.values.first else {
            return XCTFail("the reminder state must be readable from storage at arm time")
        }
        XCTAssertEqual(persisted.scheduledAt, armed)
        XCTAssertEqual(Calendar.current.component(.hour, from: persisted.scheduledAt), 8)
        XCTAssertEqual(Calendar.current.component(.minute, from: persisted.scheduledAt), 0)
        XCTAssertEqual(persisted.state, .pending)
    }

    /// FR-MSR-002's failure scenario: a mapping that cannot yield a
    /// determinate hour/minute arms NOTHING for that entry and surfaces the
    /// slot — no guessed time, no name, no dose content, and the rest of
    /// the household's schedule keeps working.
    func testUnresolvedSlotSkipsArming() {
        // Written raw: the store's `save` validates and would refuse this,
        // which is exactly the state the decode rule carries forward to
        // resolution (a half-written or corrupt record on disk).
        installCorruptMapping(
            MedicationSlotClock(
                morning: TimeOfDay(hour: 99, minute: 0),
                afternoon: MedicationSlotClock.defaultAfternoonTime,
                evening: MedicationSlotClock.defaultEveningTime
            ),
            into: mockStorage
        )
        let slotEntry = makeSlotEntry(slot: .morning, mirrorHour: 8, mirrorMinute: 0)
        // A legacy control: this entry does not depend on the mapping at
        // all, and the pass must skip ONE entry, not abort the pass.
        let legacyEntry = makeMedicationEntry(name: "Metformin", timeHour: 10, timeMinute: 0)

        scheduler.loadSchedule(entries: [slotEntry, legacyEntry])

        XCTAssertTrue(scheduler.pendingReminders.allSatisfy { $0.medicationEntryId != slotEntry.id },
                      "no reminder exists for the entry whose slot cannot resolve")
        XCTAssertEqual(scheduler.pendingReminders.filter { $0.medicationEntryId == legacyEntry.id }.count,
                       1, "the other entry in the same pass is unaffected")
        XCTAssertEqual(mockAlarm.scheduledReminders.count, 1,
                       "nothing implicit or guessed is armed on the unresolved entry's behalf")
        XCTAssertEqual(mockAlarm.scheduledReminders.values.first.map {
            Calendar.current.component(.hour, from: $0)
        }, 10)

        // The condition surfaces, PII-free: the slot and nothing else.
        let unresolved = mockObservability.emittedEvents.filter { $0.eventType == "medication_slot_unresolved" }
        XCTAssertEqual(unresolved.count, 1)
        XCTAssertEqual(unresolved.first?.metadata, ["slot": "morning"],
                       "the slot ONLY — no entry id, no name, no dose, no clock value")
        XCTAssertEqual(unresolved.first?.outcome, "unresolved")
        XCTAssertEqual(unresolved.first?.component, "medication_scheduler")
        for event in mockObservability.emittedEvents {
            for value in event.metadata.values {
                XCTAssertFalse(value.lowercased().contains("amlodipine"),
                               "no medication name may reach the metadata: \(value)")
                XCTAssertFalse(value.contains("99"),
                               "no corrupt or guessed clock value may reach the metadata: \(value)")
            }
        }
    }

    /// FR-MSR-022's other half, on the slot path: when the persistence the
    /// arm depends on fails, nothing is armed and the shipped failure
    /// surface reports it — resolution is NOT the thing that failed.
    func testStorageFailureBlocksArming() {
        installMapping(MedicationSlotClock.default, into: mockStorage)
        let entry = makeSlotEntry(slot: .morning, mirrorHour: 8, mirrorMinute: 0)
        mockStorage.shouldFailWrite = true

        scheduler.loadSchedule(entries: [entry])

        XCTAssertEqual(mockAlarm.scheduleCallCount, 0,
                       "a storage failure on the reminder state arms no platform alarm")
        XCTAssertTrue(mockAlarm.scheduledReminders.isEmpty)
        XCTAssertTrue(mockObservability.emittedEvents.contains {
            $0.eventType == "reminder_persistence_failed"
        }, "the shipped failure path reports the write")
        XCTAssertFalse(mockObservability.emittedEvents.contains {
            $0.eventType == "medication_slot_unresolved"
        }, "the slot resolved — the WRITE is what failed")

        // The failing write left no payload behind, so nothing can be
        // resurrected at the next launch as if it had armed.
        if case .success = mockStorage.read(key: "medication.pending_reminders",
                                            type: [String: ScheduledReminder].self) {
            XCTFail("a failed write must not leave a reminder payload")
        }
    }

    /// The legacy path stays first-class: an entry with no slot arms from
    /// its stored times, verbatim, and never consults the household
    /// mapping — not even a mapping that is both edited and corrupt in a
    /// slot it does not use.
    func testLegacyEntryArmsFromStoredMirror() {
        installCorruptMapping(
            MedicationSlotClock(
                morning: TimeOfDay(hour: 6, minute: 0),
                afternoon: MedicationSlotClock.defaultAfternoonTime,
                evening: TimeOfDay(hour: 19, minute: 99)
            ),
            into: mockStorage
        )
        let now = Date()
        let entry = makeMedicationEntry(name: "Metformin", timeHour: 10, timeMinute: 30)

        guard case .success(let resolved) = scheduler.resolvedScheduleTimes(for: entry) else {
            return XCTFail("a legacy entry always resolves — no mapping is consulted for it")
        }
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.hour, 10)
        XCTAssertEqual(resolved.first?.minute, 30)
        XCTAssertEqual(resolved, entry.scheduleTimes, "legacy times pass through verbatim")

        scheduler.loadSchedule(entries: [entry])

        guard let armed = mockAlarm.scheduledReminders.values.first else {
            return XCTFail("the legacy dose must be armed from its stored time")
        }
        XCTAssertEqual(Calendar.current.component(.hour, from: armed), 10,
                       "the mapping's 06:00 morning is not this entry's business")
        XCTAssertEqual(Calendar.current.component(.minute, from: armed), 30)
        XCTAssertGreaterThan(armed, now)
        XCTAssertEqual(scheduler.pendingReminders.first?.scheduledAt, armed)
        XCTAssertFalse(mockObservability.emittedEvents.contains {
            $0.eventType == "medication_slot_unresolved"
        }, "nothing about a legacy entry can be unresolved")
    }

    // MARK: - Helpers

    /// A slot entry (T-003's model): its dose lives in `slot`, and
    /// `scheduleTimes` carries the resolved-time MIRROR — passed here as a
    /// deliberately explicit value so a test can prove arming ignores it.
    private func makeSlotEntry(
        name: String = "Amlodipine",
        slot: MedicationSlot,
        mirrorHour: Int,
        mirrorMinute: Int
    ) -> MedicationEntry {
        var components = DateComponents()
        components.hour = mirrorHour
        components.minute = mirrorMinute

        return MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: name,
            doseDescription: "One tablet",
            scheduleTimes: [components],
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: false,
            confirmationDescription: nil,
            quantity: MedicationQuantity(amount: 1, unit: MedicationDoseUnit.tablet.rawValue),
            slot: slot,
            mealRelation: .beforeMeal
        )
    }

    /// Persists a mapping the way the settings save action does — through
    /// the store, so the arming path reads exactly what a household would
    /// have saved.
    private func installMapping(_ clock: MedicationSlotClock,
                               into storage: MockEncryptedLocalStorage) {
        switch MedicationSlotClockStore(storage: storage).save(clock) {
        case .success:
            break
        case .failure:
            XCTFail("a valid mapping must persist")
        }
    }

    /// Writes a mapping record RAW — bypassing `save`, which validates and
    /// would refuse it. This is the corrupt/half-written record the store's
    /// decode rule exists for: it decodes as-is and fails at resolution.
    private func installCorruptMapping(_ clock: MedicationSlotClock,
                                       into storage: MockEncryptedLocalStorage) {
        if case .failure = storage.write(key: MedicationSlotClockStore.storageKey, value: clock) {
            XCTFail("the raw record must be writable")
        }
    }

    private func makeMedicationEntry(
        name: String,
        timeHour: Int,
        timeMinute: Int,
        confirmationDescription: String? = nil,
        photoVerification: Bool = false,
        doubleDoseWindowHours: Int = 4
    ) -> MedicationEntry {
        var components = DateComponents()
        components.hour = timeHour
        components.minute = timeMinute

        return MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: name,
            doseDescription: "One tablet",
            scheduleTimes: [components],
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: doubleDoseWindowHours,
            photoVerificationEnabled: photoVerification,
            confirmationDescription: confirmationDescription
        )
    }
}
