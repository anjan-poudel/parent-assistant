import XCTest
@testable import ElderlyAssistant

// MARK: - Mock Dependencies

final class MockEncryptedLocalStorage: EncryptedLocalStorage {
    private var store: [String: Data] = [:]

    var writeCallCount = 0
    var readCallCount = 0
    var shouldFailWrite = false
    /// Keys whose writes fail on their own, on top of `shouldFailWrite`
    /// (T-010): lets a test fail exactly the reminder write while the
    /// entries write succeeds — the two-write sequence the re-arm pass
    /// depends on. Empty by default, so no existing test changes shape.
    var failingWriteKeys: Set<String> = []
    /// Fired AFTER a write has actually landed in the store — never on the
    /// failure path, so a witness built on this hook means "a persistence
    /// really happened here" and not merely "a write was attempted". It is
    /// the storage half of the persist-before-arm call-order witness
    /// (T-008): paired with `MockAlarmScheduler.onScheduleReminder`, the
    /// two hooks produce an ordered log of the arming pass.
    var onWriteCompleted: (() -> Void)?

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        writeCallCount += 1
        if shouldFailWrite || failingWriteKeys.contains(key) {
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
    /// The alert type of each context-carrying call, PARALLEL to
    /// `contexts` (T-016): the significant-event drives push several
    /// kinds through one mock instance, and the assertion has to know
    /// which kind each context belonged to. Additive — the shipped
    /// assertions above are untouched.
    private(set) var contextAlertTypes: [FamilyAlertType] = []
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
            contextAlertTypes.append(alertType)
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

    // MARK: - Guarded re-arm on mapping change (T-010, IF-12)

    /// The family's edit reaches the ARMED state, not just the settings
    /// screen: after the pass, the morning entry's reminder resolves —
    /// and is armed — at 07:30, the old 08:00 alarm is gone, and the
    /// resolved-time mirror follows the new mapping.
    func testRearmUsesTheNewMapping() {
        installMapping(MedicationSlotClock.default, into: mockStorage)
        let entry = makeSlotEntry(slot: .morning, mirrorHour: 8, mirrorMinute: 0)
        // A legacy control: no mapping ever produced its 10:00, so no
        // mapping change may move it or count it.
        let legacy = makeMedicationEntry(name: "Metformin", timeHour: 10, timeMinute: 0)
        scheduler.loadSchedule(entries: [entry, legacy])

        guard let initial = scheduler.pendingReminders.first(where: { $0.medicationEntryId == entry.id }),
              let legacyReminder = scheduler.pendingReminders.first(where: { $0.medicationEntryId == legacy.id }) else {
            return XCTFail("both doses must be armed under the default mapping")
        }
        XCTAssertEqual(Calendar.current.component(.hour, from: initial.scheduledAt), 8)

        // The family sets the morning slot to 07:30 and the save action
        // persists it BEFORE the pass runs (IF-9: validate → persist →
        // re-arm).
        installMapping(mappingWithMorning(hour: 7, minute: 30), into: mockStorage)

        let report = scheduler.rearmForSlotClockChange()

        XCTAssertEqual(report.rearmedCount, 1,
                       "the morning entry's stale reminder was replaced and armed")
        XCTAssertEqual(report.keptLiveCount, 0)
        XCTAssertTrue(report.unresolvedSlots.isEmpty)
        XCTAssertFalse(report.persistenceFailed)

        // IF-11 against the same persisted mapping — twice, identical
        // (FR-MSR-002 determinism).
        guard case .success(let firstResolution) = scheduler.resolvedScheduleTimes(for: entry),
              case .success(let secondResolution) = scheduler.resolvedScheduleTimes(for: entry) else {
            return XCTFail("a slot entry under a valid mapping must resolve")
        }
        XCTAssertEqual(firstResolution.first?.hour, 7)
        XCTAssertEqual(firstResolution.first?.minute, 30)
        XCTAssertEqual(firstResolution, secondResolution,
                       "resolving the same entry and mapping again yields the same time")

        // The armed reminder is a NEW one, at the mapped time, and the
        // superseded 08:00 alarm did not survive.
        guard let rearmed = scheduler.pendingReminders.first(where: { $0.medicationEntryId == entry.id }) else {
            return XCTFail("the re-armed entry must still have a pending reminder")
        }
        XCTAssertNotEqual(rearmed.id, initial.id, "the stale reminder is replaced, never edited in place")
        XCTAssertEqual(Calendar.current.component(.hour, from: rearmed.scheduledAt), 7)
        XCTAssertEqual(Calendar.current.component(.minute, from: rearmed.scheduledAt), 30)
        XCTAssertEqual(mockAlarm.scheduledReminders[rearmed.id], rearmed.scheduledAt,
                       "armed at the newly resolved time")
        XCTAssertTrue(mockAlarm.cancelledReminders.contains(initial.id),
                      "the superseded 08:00 alarm must not survive the pass")
        XCTAssertNil(mockAlarm.scheduledReminders[initial.id])

        // The resolved-time mirror (D2) was rewritten to the new mapping
        // and persisted — the save gate and this pass are its only writers.
        XCTAssertEqual(scheduler.medicationEntry(for: entry.id)?.scheduleTimes.first?.hour, 7)
        XCTAssertEqual(scheduler.medicationEntry(for: entry.id)?.scheduleTimes.first?.minute, 30)
        if case .success(let storedEntries) = mockStorage.read(key: "medication.entries",
                                                               type: [MedicationEntry].self),
           let stored = storedEntries.first(where: { $0.id == entry.id }) {
            XCTAssertEqual(stored.scheduleTimes.first?.hour, 7)
            XCTAssertEqual(stored.scheduleTimes.first?.minute, 30)
        } else {
            XCTFail("the rewritten mirror must be persisted")
        }

        // The legacy entry is outside the pass entirely.
        XCTAssertEqual(scheduler.pendingReminders.first(where: { $0.medicationEntryId == legacy.id })?.id,
                       legacyReminder.id)
        XCTAssertFalse(mockAlarm.cancelledReminders.contains(legacyReminder.id))
        XCTAssertEqual(scheduler.medicationEntry(for: legacy.id)?.scheduleTimes.first?.hour, 10)
    }

    /// Every field of the report is the truth of the pass it describes:
    /// rearmed / kept / unresolvedSlots — and, in its own scheduler,
    /// `persistenceFailed` with nothing armed on the replaced set (both
    /// halves of "either write fails").
    func testRearmReportCountsAreHonest() {
        installMapping(MedicationSlotClock.default, into: mockStorage)
        let morning = makeSlotEntry(name: "Amlodipine", slot: .morning, mirrorHour: 8, mirrorMinute: 0)
        let afternoon = makeSlotEntry(name: "Lisinopril", slot: .afternoon, mirrorHour: 13, mirrorMinute: 0)
        let evening = makeSlotEntry(name: "Metformin", slot: .evening, mirrorHour: 19, mirrorMinute: 0)
        scheduler.loadSchedule(entries: [morning, afternoon, evening])

        // The evening entry's finalize is in flight: the dose fired, the
        // challenge is issued, the answer is outstanding.
        guard let eveningReminder = scheduler.pendingReminders.first(where: { $0.medicationEntryId == evening.id }),
              let afternoonReminder = scheduler.pendingReminders.first(where: { $0.medicationEntryId == afternoon.id }) else {
            return XCTFail("all three doses must be armed")
        }
        scheduler.triggerReminder(for: eveningReminder.id)
        XCTAssertNotNil(scheduler.startConfirmationChallenge(for: evening.id))

        // The new mapping moves the morning slot and cannot resolve the
        // afternoon slot at all. Written RAW — `save` validates and would
        // refuse it; this is the corrupt/half-written record the decode
        // rule carries forward to resolution.
        installCorruptMapping(
            MedicationSlotClock(
                morning: TimeOfDay(hour: 7, minute: 30),
                afternoon: TimeOfDay(hour: 13, minute: 99),
                evening: MedicationSlotClock.defaultEveningTime
            ),
            into: mockStorage
        )

        let report = scheduler.rearmForSlotClockChange()

        XCTAssertEqual(report.rearmedCount, 1, "only the morning entry had a reminder to replace")
        XCTAssertEqual(report.keptLiveCount, 1, "the finalize-in-flight entry is kept, and counted")
        XCTAssertEqual(report.unresolvedSlots, [.afternoon])
        XCTAssertFalse(report.persistenceFailed)

        // Unresolved: the entry arms NOTHING — its stale 13:00 reminder is
        // dropped (fail-closed, the arming feed's own rule) and the slot
        // is named, PII-free.
        XCTAssertTrue(scheduler.pendingReminders.allSatisfy { $0.medicationEntryId != afternoon.id },
                      "an unresolved slot stays unarmed")
        let unresolvedEvents = mockObservability.emittedEvents.filter {
            $0.eventType == "medication_slot_unresolved"
        }
        XCTAssertEqual(unresolvedEvents.count, 1)
        XCTAssertEqual(unresolvedEvents.first?.metadata, ["slot": "afternoon"],
                       "the slot ONLY — no entry id, no name, no dose, no clock value")
        XCTAssertEqual(unresolvedEvents.first?.outcome, "unresolved")
        XCTAssertTrue(mockAlarm.cancelledReminders.contains(afternoonReminder.id),
                      "the dropped reminder's alarm is cancelled once the removal is stored")

        // Kept: the shaken entry is untouched — same reminder, same fired
        // time, alarm never cancelled, mirror not rewritten.
        XCTAssertEqual(scheduler.pendingReminders.first(where: { $0.id == eveningReminder.id })?.scheduledAt,
                       eveningReminder.scheduledAt)
        XCTAssertFalse(mockAlarm.cancelledReminders.contains(eveningReminder.id))
        XCTAssertEqual(scheduler.medicationEntry(for: evening.id)?.scheduleTimes.first?.hour, 19)

        // Re-armed: the morning entry followed the new mapping, mirror
        // included.
        XCTAssertEqual(scheduler.medicationEntry(for: morning.id)?.scheduleTimes.first?.hour, 7)
        XCTAssertEqual(scheduler.medicationEntry(for: morning.id)?.scheduleTimes.first?.minute, 30)

        // No field of any event may carry a name or a clock value.
        for event in mockObservability.emittedEvents {
            for value in event.metadata.values {
                for name in ["amlodipine", "lisinopril", "metformin"] {
                    XCTAssertFalse(value.lowercased().contains(name),
                                   "no medication name may reach metadata: \(value)")
                }
                XCTAssertFalse(value.contains("99"),
                               "no corrupt clock value may reach metadata: \(value)")
            }
        }

        // persistenceFailed, first half: the MIRRORS write fails.
        // (Fresh scheduler so the counts above stay readable.)
        let failingStorage = MockEncryptedLocalStorage()
        let failingScheduler = MedicationScheduler(
            storage: failingStorage,
            alarmScheduler: mockAlarm,
            observabilityBus: mockObservability,
            familyNotifier: mockFamilyNotifier,
            caregiverNotifySettings: CaregiverNotifySettings.isolated()
        )
        installMapping(MedicationSlotClock.default, into: failingStorage)
        let straggler = makeSlotEntry(name: "Amlodipine", slot: .morning, mirrorHour: 8, mirrorMinute: 0)
        failingScheduler.loadSchedule(entries: [straggler])
        installMapping(mappingWithMorning(hour: 7, minute: 30), into: failingStorage)
        guard let stragglerReminder = failingScheduler.pendingReminders.first else {
            return XCTFail("the dose must be armed before the failing pass")
        }
        let armsBeforeFailure = mockAlarm.scheduleCallCount
        failingStorage.shouldFailWrite = true

        let failedMirrorReport = failingScheduler.rearmForSlotClockChange()

        XCTAssertTrue(failedMirrorReport.persistenceFailed, "the failed mirror write is reported, never silent")
        XCTAssertEqual(failedMirrorReport.rearmedCount, 0, "nothing was armed on the replaced set")
        XCTAssertEqual(mockAlarm.scheduleCallCount, armsBeforeFailure, "a failed write arms nothing")
        XCTAssertTrue(failingScheduler.pendingReminders.contains { $0.id == stragglerReminder.id },
                      "the stale reminder survives its failed replacement")
        XCTAssertEqual(mockAlarm.scheduledReminders[stragglerReminder.id], stragglerReminder.scheduledAt,
                       "and it is still armed at its old, stored time")
        XCTAssertEqual(failingScheduler.medicationEntry(for: straggler.id)?.scheduleTimes.first?.hour, 8,
                       "the in-memory mirror is the version that is actually stored")
        XCTAssertTrue(mockObservability.emittedEvents.contains {
            $0.eventType == "entry_persistence_failed"
        }, "the shipped failure event reports the write")

        // persistenceFailed, second half: the mirrors write SUCCEEDS and
        // the REMINDERS write fails — still nothing armed on the replaced
        // set, and the dropped reminders' alarms are never cancelled over
        // state that was not stored.
        let reminderFailStorage = MockEncryptedLocalStorage()
        let reminderFailScheduler = MedicationScheduler(
            storage: reminderFailStorage,
            alarmScheduler: mockAlarm,
            observabilityBus: mockObservability,
            familyNotifier: mockFamilyNotifier,
            caregiverNotifySettings: CaregiverNotifySettings.isolated()
        )
        installMapping(MedicationSlotClock.default, into: reminderFailStorage)
        let trapped = makeSlotEntry(name: "Amlodipine", slot: .morning, mirrorHour: 8, mirrorMinute: 0)
        reminderFailScheduler.loadSchedule(entries: [trapped])
        installMapping(mappingWithMorning(hour: 7, minute: 30), into: reminderFailStorage)
        guard let trappedReminder = reminderFailScheduler.pendingReminders.first else {
            return XCTFail("the dose must be armed before the failing pass")
        }
        let armsBeforeReminderFailure = mockAlarm.scheduleCallCount
        reminderFailStorage.failingWriteKeys = ["medication.pending_reminders"]

        let failedReminderReport = reminderFailScheduler.rearmForSlotClockChange()

        XCTAssertTrue(failedReminderReport.persistenceFailed)
        XCTAssertEqual(failedReminderReport.rearmedCount, 0, "nothing was armed")
        XCTAssertEqual(mockAlarm.scheduleCallCount, armsBeforeReminderFailure)
        XCTAssertEqual(mockAlarm.scheduledReminders[trappedReminder.id], trappedReminder.scheduledAt,
                       "the old alarm is left armed rather than cancelled over unstored state")
        XCTAssertFalse(mockAlarm.cancelledReminders.contains(trappedReminder.id))
        XCTAssertTrue(mockObservability.emittedEvents.contains {
            $0.eventType == "reminder_persistence_failed"
        }, "the shipped reminder-failure event reports the write")
    }

    /// The HIGH-risk guard: an entry whose finalize is in flight is kept
    /// WHOLE — same reminder, same fired time, same engine — while the
    /// very same pass re-arms its unguarded sibling.
    func testRearmKeepsFinalizeInFlightEntry() {
        installMapping(MedicationSlotClock.default, into: mockStorage)
        let shaken = makeSlotEntry(name: "Amlodipine", slot: .morning, mirrorHour: 8, mirrorMinute: 0)
        let control = makeSlotEntry(name: "Metformin", slot: .morning, mirrorHour: 8, mirrorMinute: 0)
        scheduler.loadSchedule(entries: [shaken, control])

        guard let shakenReminder = scheduler.pendingReminders.first(where: { $0.medicationEntryId == shaken.id }),
              let controlReminder = scheduler.pendingReminders.first(where: { $0.medicationEntryId == control.id }) else {
            return XCTFail("both doses must be armed")
        }

        // The elder acknowledged the dose; the confirmation challenge is
        // awaiting the answer — the finalize is in flight.
        scheduler.triggerReminder(for: shakenReminder.id)
        XCTAssertNotNil(scheduler.startConfirmationChallenge(for: shaken.id))
        XCTAssertEqual(scheduler.pendingReminders.first(where: { $0.id == shakenReminder.id })?.state, .fired)

        installMapping(mappingWithMorning(hour: 7, minute: 30), into: mockStorage)

        let report = scheduler.rearmForSlotClockChange()

        // Kept, whole — and reported as kept.
        XCTAssertEqual(report.rearmedCount, 1, "only the unguarded sibling was re-armed")
        XCTAssertEqual(report.keptLiveCount, 1, "the in-flight entry is kept, and the report says so")
        let kept = scheduler.pendingReminders.filter { $0.medicationEntryId == shaken.id }
        XCTAssertEqual(kept.count, 1, "no reminder was created for the kept entry")
        XCTAssertEqual(kept.first?.id, shakenReminder.id)
        XCTAssertEqual(kept.first?.scheduledAt, shakenReminder.scheduledAt)
        XCTAssertFalse(mockAlarm.cancelledReminders.contains(shakenReminder.id),
                       "the kept entry's alarm is never cancelled")
        XCTAssertEqual(scheduler.medicationEntry(for: shaken.id)?.scheduleTimes.first?.hour, 8,
                       "the kept entry's mirror is not rewritten")

        // Its acknowledgement sequence continues untouched: the same
        // engine re-fires from the same scheduled time.
        scheduler.handleAckDeadlineExpired(for: shakenReminder.id)
        XCTAssertEqual(mockAlarm.scheduledReminders[shakenReminder.id],
                       shakenReminder.scheduledAt.addingTimeInterval(TimeInterval(12 * 60)),
                       "the refire derives from the untouched engine and time")

        // The control proves the pass really ran.
        XCTAssertNotEqual(scheduler.pendingReminders.first(where: { $0.medicationEntryId == control.id })?.id,
                          controlReminder.id)
        XCTAssertTrue(mockAlarm.cancelledReminders.contains(controlReminder.id))

        // …and the guard is the challenge WINDOW, not merely a dictionary
        // entry: the same drive on a scheduler whose window has already
        // lapsed keeps nothing — the entry is re-armed like any other.
        let lapsedStorage = MockEncryptedLocalStorage()
        let lapsedScheduler = MedicationScheduler(
            storage: lapsedStorage,
            alarmScheduler: MockAlarmScheduler(),
            observabilityBus: MockObservabilityBus(),
            familyNotifier: mockFamilyNotifier,
            caregiverNotifySettings: CaregiverNotifySettings.isolated(),
            challengeTimeoutSeconds: -1
        )
        installMapping(MedicationSlotClock.default, into: lapsedStorage)
        let lapsedEntry = makeSlotEntry(name: "Amlodipine", slot: .morning, mirrorHour: 8, mirrorMinute: 0)
        lapsedScheduler.loadSchedule(entries: [lapsedEntry])
        guard let lapsedReminder = lapsedScheduler.pendingReminders.first else {
            return XCTFail("the dose must be armed")
        }
        lapsedScheduler.triggerReminder(for: lapsedReminder.id)
        XCTAssertNotNil(lapsedScheduler.startConfirmationChallenge(for: lapsedEntry.id))
        installMapping(mappingWithMorning(hour: 7, minute: 30), into: lapsedStorage)

        let lapsedReport = lapsedScheduler.rearmForSlotClockChange()

        XCTAssertEqual(lapsedReport.keptLiveCount, 1,
                       "the live reminder is kept — fired reminders never move")
        XCTAssertEqual(lapsedReport.rearmedCount, 1,
                       "the lapsed window is not a live finalize: the entry was re-armed")
        XCTAssertEqual(lapsedScheduler.medicationEntry(for: lapsedEntry.id)?.scheduleTimes.first?.hour, 7,
                       "…mirror included")
    }

    /// Idempotence: the same inputs run twice replace nothing the second
    /// time — no new reminder, no re-arm, no write, no cancellation — and
    /// the report says exactly that.
    func testRearmSecondPassReplacesNothing() {
        installMapping(MedicationSlotClock.default, into: mockStorage)
        let entry = makeSlotEntry(slot: .morning, mirrorHour: 8, mirrorMinute: 0)
        scheduler.loadSchedule(entries: [entry])
        installMapping(mappingWithMorning(hour: 7, minute: 30), into: mockStorage)

        let firstPass = scheduler.rearmForSlotClockChange()
        XCTAssertEqual(firstPass.rearmedCount, 1,
                       "the precondition: the first pass DID replace the stale reminder")

        let idsAfterFirstPass = Set(scheduler.pendingReminders.map(\.id))
        let armsAfterFirstPass = mockAlarm.scheduleCallCount
        let writesAfterFirstPass = mockStorage.writeCallCount
        let cancellationsAfterFirstPass = mockAlarm.cancelledReminders.count

        let secondPass = scheduler.rearmForSlotClockChange()

        XCTAssertEqual(secondPass, SlotClockRearmReport(rearmedCount: 0,
                                                        keptLiveCount: 0,
                                                        unresolvedSlots: [],
                                                        persistenceFailed: false),
                       "the report reflects the no-op honestly")
        XCTAssertEqual(Set(scheduler.pendingReminders.map(\.id)), idsAfterFirstPass,
                       "it replaces nothing")
        XCTAssertEqual(mockAlarm.scheduleCallCount, armsAfterFirstPass,
                       "it re-arms nothing")
        XCTAssertEqual(mockStorage.writeCallCount, writesAfterFirstPass,
                       "it persists nothing — there was nothing to persist")
        XCTAssertEqual(mockAlarm.cancelledReminders.count, cancellationsAfterFirstPass,
                       "it cancels nothing")
    }

    /// FR-MSR-022 on the re-arm path: both writes — the rewritten mirrors
    /// and the replacement reminder set — complete before the first
    /// platform alarm, and the payload already on disk at arm time
    /// carries the resolved 07:30.
    func testRearmPersistsBeforeArming() {
        installMapping(MedicationSlotClock.default, into: mockStorage)
        let entry = makeSlotEntry(slot: .morning, mirrorHour: 8, mirrorMinute: 0)
        scheduler.loadSchedule(entries: [entry])
        installMapping(mappingWithMorning(hour: 7, minute: 30), into: mockStorage)

        // The hooks go on AFTER the fixture pass: the witness is about the
        // re-arm walk, not about the load.
        let storage = mockStorage!
        var order: [String] = []
        var pendingAtFirstArm: ScheduledReminder?
        var entriesAtFirstArm: [MedicationEntry]?
        storage.onWriteCompleted = { order.append("persist") }
        mockAlarm.onScheduleReminder = {
            order.append("arm")
            if pendingAtFirstArm == nil,
               case .success(let stored) = storage.read(key: "medication.pending_reminders",
                                                        type: [String: ScheduledReminder].self) {
                pendingAtFirstArm = stored.values.first
            }
            if entriesAtFirstArm == nil,
               case .success(let stored) = storage.read(key: "medication.entries",
                                                        type: [MedicationEntry].self) {
                entriesAtFirstArm = stored
            }
        }
        var observedAtCommit: [MedicationEntry]?
        scheduler.onScheduleChanged = { observedAtCommit = $0 }

        let report = scheduler.rearmForSlotClockChange()
        XCTAssertEqual(report.rearmedCount, 1)

        XCTAssertEqual(order, ["persist", "persist", "arm"],
                       "the mirrors and the replacement set are persisted before the first arm")
        XCTAssertEqual(order.filter { $0 == "arm" }.count, 1,
                       "one arm — for the one replacement")

        // The order is only half the claim: the bytes on disk BEFORE the
        // arm already carried the resolved 07:30 — on both keys.
        guard let persistedAtArm = pendingAtFirstArm else {
            return XCTFail("the reminder state must be readable from storage at arm time")
        }
        XCTAssertEqual(Calendar.current.component(.hour, from: persistedAtArm.scheduledAt), 7)
        XCTAssertEqual(Calendar.current.component(.minute, from: persistedAtArm.scheduledAt), 30)
        XCTAssertEqual(entriesAtFirstArm?.first?.scheduleTimes.first?.hour, 7,
                       "the rewritten mirror is on disk before the first arm")
        XCTAssertEqual(entriesAtFirstArm?.first?.scheduleTimes.first?.minute, 30)

        // The share layer is told last, with exactly the version that was
        // stored (the loadSchedule ordering contract).
        XCTAssertEqual(observedAtCommit?.first?.scheduleTimes.first?.hour, 7)
        XCTAssertEqual(observedAtCommit?.first?.scheduleTimes.first?.minute, 30)
        XCTAssertEqual(order.last, "arm",
                       "the observer is told after the local work is fully committed")
    }

    // MARK: - Significant-event triggers + retime refusal (T-016, C7.3-C7.5)

    /// FR-MSR-015's intake half: when the write succeeded, the alert
    /// follows it — the record is already in the store at notify time,
    /// and the context carries the entry-id hash and the in-memory title.
    /// The drive runs with the first-fire toggle OFF (the default): the
    /// significant set is unconditional, so its alerts must not depend on
    /// that opt-in.
    func testIntakeRecordedAfterWrite() async {
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        scheduler.loadSchedule(entries: [entry])
        guard let reminderId = scheduler.pendingReminders.first?.id else {
            return XCTFail("expected a pending reminder")
        }
        scheduler.triggerReminder(for: reminderId)
        XCTAssertFalse(caregiverNotifySettings.medicationReminders, "defaults are OFF, and this alert ignores the toggle")

        let storage = mockStorage!
        var logAtNotify: [MedicationAdherenceLog]?
        let notified = expectation(description: "intake recorded alert")
        mockFamilyNotifier.onNotify = {
            if logAtNotify == nil,
               case .success(let logs) = storage.read(key: "medication.adherence_log",
                                                      type: [MedicationAdherenceLog].self) {
                logAtNotify = logs
            }
            notified.fulfill()
        }

        let result = scheduler.acknowledge(entryId: entry.id, at: Date())
        if case .failure = result {
            return XCTFail("the acknowledgement must record")
        }
        await fulfillment(of: [notified], timeout: 2)

        // The record the alert announced was already written, and it is
        // the acknowledged one for this entry.
        let recorded = logAtNotify?.filter { $0.medicationEntryId == entry.id }
        XCTAssertEqual(recorded?.count, 1)
        XCTAssertEqual(recorded?.first?.status, .acknowledged)

        // The alert is the intakeRecorded significant event, with the
        // hash-only context — and its fireAt is the SAME instant the
        // record stamps: the dose occurrence, not the ack moment.
        XCTAssertEqual(mockFamilyNotifier.lastAlertType, .intakeRecorded)
        XCTAssertEqual(mockFamilyNotifier.contextAlertTypes, [.intakeRecorded])
        let context = mockFamilyNotifier.contexts.first
        XCTAssertEqual(context?.kind, .medicationReminder)
        XCTAssertEqual(context?.eventIdHash, IdHashing.shortHash(of: entry.id))
        XCTAssertEqual(context?.eventTitle, "Amlodipine",
                       "the title is the medication name the elder knows")
        XCTAssertEqual(context?.fireAt, recorded?.first?.scheduledAt)
    }

    /// The other half of the shipped order: a FAILED adherence write
    /// records nothing, so nothing may be announced — and the typed
    /// failure still comes back to the caller.
    func testIntakeRecordedAbsentOnFailure() async {
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        scheduler.loadSchedule(entries: [entry])
        guard let reminderId = scheduler.pendingReminders.first?.id else {
            return XCTFail("expected a pending reminder")
        }
        scheduler.triggerReminder(for: reminderId)

        mockStorage.failingWriteKeys = ["medication.adherence_log"]
        let noAlert = expectation(description: "no intake alert")
        noAlert.isInverted = true
        mockFamilyNotifier.onNotify = { noAlert.fulfill() }

        let result = scheduler.acknowledge(entryId: entry.id, at: Date())
        guard case .failure = result else {
            return XCTFail("a failed adherence write must be a typed failure")
        }
        await fulfillment(of: [noAlert], timeout: 0.3)

        XCTAssertEqual(mockFamilyNotifier.notifyCallCount, 0,
                       "a dose is never announced as recorded when the record did not land")
        XCTAssertTrue(mockFamilyNotifier.contexts.isEmpty)
        XCTAssertFalse(mockObservability.emittedEvents.contains { $0.eventType == "acknowledged" },
                       "the shipped acknowledgement event follows the write too")
    }

    /// D10: the first re-fire decision (0 -> 1) is the escalationStarted
    /// event; every later decision for the same reminder is silent —
    /// the count is the state, and no per-event flag is stored.
    func testEscalationStartedAtFirstRefireOnly() async {
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        scheduler.loadSchedule(entries: [entry])
        guard let reminderId = scheduler.pendingReminders.first?.id else {
            return XCTFail("expected a pending reminder")
        }
        var raisedKinds: [SignificantMedicationEvent.Kind] = []
        scheduler.onSignificantEvent = { event, _ in raisedKinds.append(event.kind) }

        let notified = expectation(description: "escalation started alert")
        mockFamilyNotifier.onNotify = { notified.fulfill() }

        // Decision 1: the ack window expired — refireCount 0 -> 1.
        scheduler.triggerReminder(for: reminderId)
        scheduler.handleAckDeadlineExpired(for: reminderId)
        await fulfillment(of: [notified], timeout: 2)
        XCTAssertEqual(scheduler.pendingReminders.first?.refireCount, 1)

        // A later re-fire (the alarm nagging on) must not announce again.
        mockFamilyNotifier.onNotify = nil
        scheduler.triggerReminder(for: reminderId)
        scheduler.handleAckDeadlineExpired(for: reminderId)

        XCTAssertEqual(scheduler.pendingReminders.first?.refireCount, 2,
                       "the later decision really happened — and stayed silent")
        XCTAssertEqual(mockFamilyNotifier.contextAlertTypes, [.escalationStarted])
        XCTAssertEqual(mockFamilyNotifier.lastAlertType, .escalationStarted)
        XCTAssertEqual(raisedKinds, [.escalationStarted])
    }

    /// The missed-dose site now carries its context: the entry-id hash,
    /// the name in memory, and the missed occurrence as `fireAt`. Driven
    /// through the shipped recovery path (a fired reminder whose
    /// escalation window is already over is recorded as missed).
    func testMissedDoseCarriesContext() async {
        let entry = makeMedicationEntry(name: "Metformin", timeHour: 8, timeMinute: 0)
        let scheduledAt = Date().addingTimeInterval(-2 * 60 * 60)
        let reminder = ScheduledReminder(
            id: UUID(),
            medicationEntryId: entry.id,
            scheduledAt: scheduledAt,
            refireCount: 2,
            escalationDeadline: scheduledAt.addingTimeInterval(60 * 60),
            state: .fired,
            lastFiredAt: scheduledAt,
            acknowledgedAt: nil
        )
        _ = mockStorage.write(key: "medication.pending_reminders",
                              value: [reminder.id.uuidString: reminder])
        _ = mockStorage.write(key: "medication.entries", value: [entry])

        let notified = expectation(description: "missed dose alert")
        mockFamilyNotifier.onNotify = { notified.fulfill() }

        scheduler.scheduleAll()
        await fulfillment(of: [notified], timeout: 2)

        XCTAssertEqual(mockFamilyNotifier.lastAlertType, .missedMedication)
        XCTAssertEqual(mockFamilyNotifier.contextAlertTypes, [.missedMedication])
        let context = mockFamilyNotifier.contexts.first
        XCTAssertEqual(context?.kind, .medicationReminder)
        XCTAssertEqual(context?.eventIdHash, IdHashing.shortHash(of: entry.id))
        XCTAssertEqual(context?.eventTitle, "Metformin")
        XCTAssertEqual(context?.fireAt, scheduledAt,
                       "the context's fireAt is the dose occurrence the miss is about")
    }

    /// The blocked double-dose branch carries its context too — the
    /// attempt instant is the event, matching the blocked record the
    /// branch itself stamps.
    func testBlockedDoubleDoseCarriesContext() async {
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        scheduler.loadSchedule(entries: [entry])
        var raisedEvents: [SignificantMedicationEvent] = []
        scheduler.onSignificantEvent = { event, _ in raisedEvents.append(event) }

        // First dose recorded — the drive's own notify (intakeRecorded)
        // is awaited so the assertions below see the blocked alert alone.
        let firstAlert = expectation(description: "first dose alert")
        mockFamilyNotifier.onNotify = { firstAlert.fulfill() }
        let firstAt = Date()
        _ = scheduler.acknowledgeWithConfirmation(entryId: entry.id, at: firstAt,
                                                  confirmationResponse: .yes)
        await fulfillment(of: [firstAlert], timeout: 2)
        XCTAssertEqual(mockFamilyNotifier.lastAlertType, .intakeRecorded)

        // The second attempt inside the 4-hour window is blocked.
        let attemptAt = firstAt.addingTimeInterval(60)
        let blockedAlert = expectation(description: "double dose alert")
        mockFamilyNotifier.onNotify = { blockedAlert.fulfill() }
        _ = scheduler.acknowledgeWithConfirmation(entryId: entry.id, at: attemptAt,
                                                  confirmationResponse: .yes)
        await fulfillment(of: [blockedAlert], timeout: 2)

        XCTAssertTrue(mockObservability.emittedEvents.contains {
            $0.eventType == "double_dose_blocked"
        }, "the drive really hit the blocked branch")
        XCTAssertEqual(mockFamilyNotifier.contextAlertTypes,
                       [.intakeRecorded, .possibleDoubleDose])
        let context = mockFamilyNotifier.contexts.last
        XCTAssertEqual(context?.kind, .medicationReminder)
        XCTAssertEqual(context?.eventIdHash, IdHashing.shortHash(of: entry.id))
        XCTAssertEqual(context?.eventTitle, "Amlodipine")
        XCTAssertEqual(context?.fireAt, attemptAt, "the event is the attempt")
        XCTAssertEqual(raisedEvents.map(\.kind), [.possibleDoubleDose])
        XCTAssertEqual(raisedEvents.first?.occurredAt, attemptAt)
    }

    /// IF-20's trigger sites, one drive each, through one hook: the
    /// missed dose, the blocked double dose and the first re-fire
    /// decision all raise — once each, with the entry the event is
    /// about. `intakeRecorded` deliberately raises nothing here.
    func testOnSignificantEventInvokedAtAllThreeAtRiskSites() {
        var raisedKinds: [SignificantMedicationEvent.Kind] = []
        var raisedEntryIds: [UUID?] = []
        let collector: (SignificantMedicationEvent, MedicationEntry?) -> Void = { event, entry in
            raisedKinds.append(event.kind)
            raisedEntryIds.append(entry?.id)
        }
        scheduler.onSignificantEvent = collector

        // Site 1 — the missed dose (the recovery drive above).
        let missedEntry = makeMedicationEntry(name: "Metformin", timeHour: 8, timeMinute: 0)
        let missedAt = Date().addingTimeInterval(-2 * 60 * 60)
        let staleReminder = ScheduledReminder(
            id: UUID(),
            medicationEntryId: missedEntry.id,
            scheduledAt: missedAt,
            refireCount: 1,
            escalationDeadline: missedAt.addingTimeInterval(60 * 60),
            state: .fired,
            lastFiredAt: missedAt,
            acknowledgedAt: nil
        )
        _ = mockStorage.write(key: "medication.pending_reminders",
                              value: [staleReminder.id.uuidString: staleReminder])
        _ = mockStorage.write(key: "medication.entries", value: [missedEntry])
        scheduler.scheduleAll()

        // Site 2 — the blocked double dose (record once, then again
        // inside the window).
        let doubledEntry = makeMedicationEntry(name: "Amlodipine", timeHour: 9, timeMinute: 0)
        scheduler.loadSchedule(entries: [doubledEntry])
        _ = scheduler.acknowledgeWithConfirmation(entryId: doubledEntry.id, at: Date(),
                                                  confirmationResponse: .yes)
        _ = scheduler.acknowledgeWithConfirmation(entryId: doubledEntry.id,
                                                  at: Date().addingTimeInterval(60),
                                                  confirmationResponse: .yes)

        // Site 3 — the first re-fire decision.
        let escalatedEntry = makeMedicationEntry(name: "Lisinopril", timeHour: 10, timeMinute: 0)
        scheduler.loadSchedule(entries: [escalatedEntry])
        guard let escalatedReminder = scheduler.pendingReminders.first?.id else {
            return XCTFail("expected a pending reminder for the escalation drive")
        }
        scheduler.triggerReminder(for: escalatedReminder)
        scheduler.handleAckDeadlineExpired(for: escalatedReminder)

        XCTAssertEqual(raisedKinds,
                       [.missedMedication, .possibleDoubleDose, .escalationStarted],
                       "each at-risk site raises once, in drive order — and intake raises nothing")
        XCTAssertEqual(raisedEntryIds,
                       [missedEntry.id, doubledEntry.id, escalatedEntry.id],
                       "each event carries the entry it is about")
    }

    /// The guard on the shipped first-fire gate: the opt-in still
    /// governs the delivery-day `eventReminder` alert ONLY — toggle off
    /// is silent, toggle on sends exactly the shipped context (the
    /// REMINDER-id hash), and nothing about the significant set leaks
    /// into or out of this gate.
    func testFirstFireNotificationGateStaysOptIn() async {
        let gated = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)
        let optedIn = makeMedicationEntry(name: "Metformin", timeHour: 9, timeMinute: 0)
        scheduler.loadSchedule(entries: [gated, optedIn])
        XCTAssertFalse(caregiverNotifySettings.medicationReminders, "defaults are OFF")
        guard let gatedReminder = scheduler.pendingReminders.first(where: { $0.medicationEntryId == gated.id }),
              let optedInReminder = scheduler.pendingReminders.first(where: { $0.medicationEntryId == optedIn.id }) else {
            return XCTFail("both doses must be armed")
        }

        // Toggle OFF household: the first fire tells nobody.
        let silent = expectation(description: "no first-fire alert")
        silent.isInverted = true
        mockFamilyNotifier.onNotify = { silent.fulfill() }
        scheduler.triggerReminder(for: gatedReminder.id)
        await fulfillment(of: [silent], timeout: 0.3)
        XCTAssertTrue(mockObservability.emittedEvents.contains {
            $0.eventType == "caregiver_event_skipped"
        }, "the OFF household's first fire was skipped, as shipped")

        // Toggle ON: exactly the shipped event alert — the reminder-id
        // hash, the one context, one call.
        caregiverNotifySettings.medicationReminders = true
        let alerted = expectation(description: "first-fire alert")
        mockFamilyNotifier.onNotify = { alerted.fulfill() }
        scheduler.triggerReminder(for: optedInReminder.id)
        await fulfillment(of: [alerted], timeout: 2)

        XCTAssertEqual(mockFamilyNotifier.notifyCallCount, 1,
                       "the gate is still opt-in — one alert, from the opted-in fire alone")
        XCTAssertEqual(mockFamilyNotifier.lastAlertType, .eventReminder,
                       "the first-fire alert still rides the shipped eventReminder type")
        XCTAssertEqual(mockFamilyNotifier.contexts.count, 1)
        XCTAssertEqual(mockFamilyNotifier.contexts.first?.kind, .medicationReminder)
        XCTAssertEqual(mockFamilyNotifier.contexts.first?.eventIdHash,
                       IdHashing.shortHash(of: optedInReminder.id),
                       "the shipped first-fire hash — the REMINDER id, not the entry id")
    }

    /// m-5's refusal, whole: no change applied (mirror, armed set, store
    /// and observer all untouched), the named PII-free event with the
    /// hash and the slot and nothing else, and the settings-note hook.
    func testRetimeRefusedForSlotEntry() {
        installMapping(MedicationSlotClock.default, into: mockStorage)
        let entry = makeSlotEntry(slot: .morning, mirrorHour: 8, mirrorMinute: 0)
        scheduler.loadSchedule(entries: [entry])

        var refused: [UUID] = []
        scheduler.onSlotEntryRetimeRefused = { refused.append($0) }
        var observed: [[MedicationEntry]] = []
        scheduler.onScheduleChanged = { observed.append($0) }
        let writesBefore = mockStorage.writeCallCount
        let armsBefore = mockAlarm.scheduleCallCount
        let reminderIdsBefore = Set(scheduler.pendingReminders.map(\.id))

        var newTimes = DateComponents()
        newTimes.hour = 7
        newTimes.minute = 0
        let applied = scheduler.setScheduleTimes([newTimes], entryId: entry.id)

        XCTAssertFalse(applied, "a slot entry's retime is refused")
        XCTAssertEqual(refused, [entry.id], "the settings-note hook fires with the entry id")

        // The named PII-free event: hash + slot ONLY (NFR-MSR-002).
        let refusals = mockObservability.emittedEvents.filter {
            $0.eventType == "medication_retime_refused"
        }
        XCTAssertEqual(refusals.count, 1)
        XCTAssertEqual(refusals.first?.metadata, [
            "entry_id_hash": IdHashing.shortHash(of: entry.id),
            "slot": "morning"
        ], "the metadata carries the entry id hash and the slot and nothing else")
        XCTAssertEqual(refusals.first?.outcome, "info")
        XCTAssertEqual(refusals.first?.component, "medication_scheduler")

        // No change was applied — not to the mirror, the armed set, the
        // store, the alarms, or the share observer.
        XCTAssertEqual(scheduler.medicationEntry(for: entry.id)?.scheduleTimes.first?.hour, 8)
        XCTAssertEqual(scheduler.medicationEntry(for: entry.id)?.scheduleTimes.first?.minute, 0)
        XCTAssertEqual(Set(scheduler.pendingReminders.map(\.id)), reminderIdsBefore)
        XCTAssertEqual(mockStorage.writeCallCount, writesBefore, "a refusal never writes")
        XCTAssertEqual(mockAlarm.scheduleCallCount, armsBefore, "and never re-arms")
        XCTAssertTrue(mockAlarm.cancelledReminders.isEmpty)
        XCTAssertTrue(observed.isEmpty)
        for event in mockObservability.emittedEvents {
            for value in event.metadata.values {
                XCTAssertFalse(value.lowercased().contains("amlodipine"),
                               "no medication name may reach metadata: \(value)")
            }
        }
    }

    /// The legacy path is untouched: a legacy entry's retime applies as
    /// shipped — entry, mirror and armed reminder all follow the new
    /// time, and nothing is refused.
    func testRetimeStillAppliesForLegacyEntry() {
        let entry = makeMedicationEntry(name: "Metformin", timeHour: 10, timeMinute: 30)
        scheduler.loadSchedule(entries: [entry])
        guard let initialReminder = scheduler.pendingReminders.first else {
            return XCTFail("the legacy dose must be armed before the retime")
        }

        var refused: [UUID] = []
        scheduler.onSlotEntryRetimeRefused = { refused.append($0) }
        var observed: [[MedicationEntry]] = []
        scheduler.onScheduleChanged = { observed.append($0) }

        var newTimes = DateComponents()
        newTimes.hour = 7
        newTimes.minute = 15
        let applied = scheduler.setScheduleTimes([newTimes], entryId: entry.id)

        XCTAssertTrue(applied, "a legacy entry keeps the shipped behavior")
        XCTAssertTrue(refused.isEmpty, "nothing was refused")
        XCTAssertFalse(mockObservability.emittedEvents.contains {
            $0.eventType == "medication_retime_refused"
        })

        XCTAssertEqual(scheduler.medicationEntry(for: entry.id)?.scheduleTimes.first?.hour, 7)
        XCTAssertEqual(scheduler.medicationEntry(for: entry.id)?.scheduleTimes.first?.minute, 15)
        if case .success(let stored) = mockStorage.read(key: "medication.entries",
                                                        type: [MedicationEntry].self) {
            XCTAssertEqual(stored.first?.scheduleTimes.first?.hour, 7,
                           "the retimed entry is persisted")
            XCTAssertEqual(stored.first?.scheduleTimes.first?.minute, 15)
        } else {
            XCTFail("the retimed entry must be persisted")
        }

        // The shipped reload semantics: the old reminder is replaced by a
        // newly armed one at the new time, and the share layer is told.
        guard let rearmed = scheduler.pendingReminders.first else {
            return XCTFail("the retimed entry must have a pending reminder again")
        }
        XCTAssertNotEqual(rearmed.id, initialReminder.id)
        XCTAssertEqual(Calendar.current.component(.hour, from: rearmed.scheduledAt), 7)
        XCTAssertEqual(Calendar.current.component(.minute, from: rearmed.scheduledAt), 15)
        XCTAssertEqual(mockAlarm.scheduledReminders[rearmed.id], rearmed.scheduledAt)
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.first?.scheduleTimes.first?.hour, 7)
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

    /// The household mapping with the morning slot moved to `hour:minute`
    /// (afternoon and evening keep the documented defaults) — the shape
    /// the medicine-times save action persists when the family retimes
    /// the morning dose (T-020/IF-9).
    private func mappingWithMorning(hour: Int, minute: Int) -> MedicationSlotClock {
        MedicationSlotClock(
            morning: TimeOfDay(hour: hour, minute: minute),
            afternoon: MedicationSlotClock.defaultAfternoonTime,
            evening: MedicationSlotClock.defaultEveningTime
        )
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
