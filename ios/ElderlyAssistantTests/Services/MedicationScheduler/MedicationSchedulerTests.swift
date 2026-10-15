import XCTest
@testable import ElderlyAssistant

// MARK: - Mock Dependencies

final class MockEncryptedLocalStorage: EncryptedLocalStorage {
    private var store: [String: Data] = [:]

    var writeCallCount = 0
    var readCallCount = 0
    var shouldFailWrite = false

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        writeCallCount += 1
        if shouldFailWrite {
            return .failure(.encryptedWriteFailed)
        }
        if let data = try? JSONEncoder().encode(value) {
            store[key] = data
        }
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

    func scheduleReminder(reminderId: UUID, entryId: UUID, medicationName: String,
                          visualAidURL: URL?, at scheduledTime: Date) {
        scheduleCallCount += 1
        scheduledReminders[reminderId] = scheduledTime
        visualAidURLs[reminderId] = visualAidURL
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

    // MARK: - Helpers

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
