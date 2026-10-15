import XCTest
@testable import ElderlyAssistant

/// T-022 — the medication slot-model release gate (FR-MSR-022, NFR-MSR-006,
/// FR-MSR-018; T-022's five named integration pins).
///
/// The unit suites own their own seams one at a time. This suite is the
/// closing pass that drives the REAL `MedicationScheduler` — the real
/// escalation engine, the real two-write arming order — over the shared
/// medication mocks (`MedicationSchedulerTests`' storage / alarm / bus /
/// notifier fakes, which live at file scope for exactly this reuse) and
/// pins the five end-to-end claims the release gate must never let drift:
///
///  - **`testPersistBeforeArmOrderingOnSlotPath`** — FR-MSR-022 on the
///    slot path: both writes (the entries payload and the pending list)
///    complete before the first platform alarm, and the bytes already on
///    disk at arm time carry the RESOLVED exact time (08:00 through the
///    household mapping), not the mirror or a guess.
///  - **`testKillAndRelaunchRefiresWithinUnexpiredWindow`** — the process
///    kill boundary: a reminder persisted as `.fired` with its escalation
///    window still open re-fires on relaunch, its stored deadline is
///    untouched (the window resumes from the dose's own scheduled time),
///    the next ack expiry still produces re-fire 1 measured from that same
///    time, and a future dose in the same store stays future.
///  - **`testFutureDoseStaysFutureAfterRelaunch`** — the same relaunch
///    pass, discriminated: a `.pending` future dose is re-armed at its own
///    hour and never fired, while the overdue `.pending` control in the
///    SAME store fires now — so "stays future" is a measured difference,
///    not a vacuous pass.
///  - **`testLegacyPayloadMigrationRoundTripNoFieldLoss`** — the T-003
///    decode boundary (NFR-MSR-006): a pre-slot payload with none of the
///    newer keys loads through the hand-written decode with every legacy
///    field intact and every slot-model field at its documented default,
///    the legacy times still feed the arming resolution verbatim, and a
///    re-encode → decode round trip loses no field in either direction.
///  - **`testStorageFailureBlocksAlarmEndToEnd`** — FR-MSR-022's failure
///    leg: a refused entries write is the caller's `false` with nothing
///    adopted, nothing armed and the share observer never told; a refused
///    reminder write leaves the entry adopted but arms nothing and reports
///    through the shipped `reminder_persistence_failed` event.
///
/// Recipe: the scheduler is constructed per test over a fresh in-memory
/// store (the `MedicationSchedulerTests` composition, unchanged), the kill
/// boundary is the STORE — the persisted bytes a killed process leaves
/// behind, read back by a FRESH scheduler instance — and every assertion
/// reads the mock-visible effect the production seam would really produce
/// (armed times, ack-deadline checks, emitted events, stored payloads).
final class MedicationSchedulesIntegrationTests: XCTestCase {

    var mockStorage: MockEncryptedLocalStorage!
    var mockAlarm: MockAlarmScheduler!
    var mockObservability: MockObservabilityBus!
    var mockFamilyNotifier: MockFamilyNotifier!
    /// An isolated settings suite per test, exactly like the unit suite:
    /// the first-fire toggle persists by design, so a shared instance
    /// would be an order-dependence bug waiting to happen.
    var caregiverNotifySettings: CaregiverNotifySettings!

    override func setUp() {
        super.setUp()
        mockStorage = MockEncryptedLocalStorage()
        mockAlarm = MockAlarmScheduler()
        mockObservability = MockObservabilityBus()
        mockFamilyNotifier = MockFamilyNotifier()
        caregiverNotifySettings = CaregiverNotifySettings.isolated()
    }

    // MARK: - Named tests (T-022)

    /// FR-MSR-022, the slot path end to end: the reminder state reaches
    /// the store before the platform alarm exists. Witnessed as an ordered
    /// log produced by both halves of the seam — a completed write, then
    /// the arm — and cross-checked against what the store held at arm
    /// time. The household mapping's morning is 07:30 while the entry's
    /// mirror says 08:00, so the resolved time on BOTH the persisted
    /// payload and the arm is a measured resolution through the mapping —
    /// the mirror is provably not what armed.
    func testPersistBeforeArmOrderingOnSlotPath() {
        installMapping(mappingWithMorning(hour: 7, minute: 30), into: mockStorage)
        let entry = makeSlotEntry(slot: .morning, mirrorHour: 8, mirrorMinute: 0)
        let scheduler = makeScheduler()

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
        XCTAssertEqual(persisted.scheduledAt, armed,
                       "the persisted state and the arm carry the same instant")
        XCTAssertEqual(Calendar.current.component(.hour, from: persisted.scheduledAt), 7,
                       "the slot resolved through the household mapping (07:30), not the 08:00 mirror")
        XCTAssertEqual(Calendar.current.component(.minute, from: persisted.scheduledAt), 30)
        XCTAssertEqual(Calendar.current.component(.hour, from: armed), 7)
        XCTAssertEqual(Calendar.current.component(.minute, from: armed), 30)
        XCTAssertEqual(persisted.state, .pending)
    }

    /// The process-kill boundary (FR-029 recovery), end to end: the store
    /// holds exactly what a killed process leaves behind — a dose that
    /// fired ten minutes ago, was never acknowledged, and whose 60-minute
    /// escalation window is still open — plus a future dose. A FRESH
    /// scheduler over the same store:
    ///
    ///  - re-fires the killed dose (its delivery was never confirmed);
    ///  - opens a fresh ack window for THAT fire, while the escalation
    ///    deadline itself stays the stored one — the window resumes from
    ///    the dose's own scheduled time, never restarts;
    ///  - still produces re-fire 1 when the ack window expires, measured
    ///    from the same scheduled time (+12 min), not from relaunch;
    ///  - and re-arms the future dose at its own hour without firing it.
    func testKillAndRelaunchRefiresWithinUnexpiredWindow() {
        let now = Date()
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)

        // The killed process's persisted state: fired 10 minutes ago,
        // unacknowledged, deadline 50 minutes out.
        let firedAt = now.addingTimeInterval(-600)
        let killedReminder = ScheduledReminder(
            id: UUID(),
            medicationEntryId: entry.id,
            scheduledAt: firedAt,
            refireCount: 0,
            escalationDeadline: firedAt.addingTimeInterval(
                TimeInterval(entry.escalationWindowMinutes * 60)),
            state: .fired,
            lastFiredAt: firedAt,
            acknowledgedAt: nil
        )
        let futureAt = now.addingTimeInterval(7200)
        let futureReminder = ScheduledReminder(
            id: UUID(),
            medicationEntryId: entry.id,
            scheduledAt: futureAt,
            refireCount: 0,
            escalationDeadline: futureAt.addingTimeInterval(3600),
            state: .pending,
            lastFiredAt: nil,
            acknowledgedAt: nil
        )
        _ = mockStorage.write(key: "medication.pending_reminders", value: [
            killedReminder.id.uuidString: killedReminder,
            futureReminder.id.uuidString: futureReminder
        ])
        _ = mockStorage.write(key: "medication.entries", value: [entry])

        // The relaunch: a fresh scheduler instance over the same store.
        let relaunched = makeScheduler()
        let beforeRelaunch = Date()
        relaunched.scheduleAll()
        let afterRelaunch = Date()

        // The re-fire: delivery was never confirmed, the window is open.
        let fired = mockObservability.emittedEvents.filter { $0.eventType == "reminder_fired" }
        XCTAssertEqual(fired.count, 1, "the killed dose re-fires exactly once on relaunch")
        XCTAssertEqual(fired.first?.metadata["entry_id_hash"], IdHashing.shortHash(of: entry.id))
        XCTAssertEqual(fired.first?.metadata["refire_count"], "0",
                       "the re-fire resumes the stored count — it is not a fresh escalation")
        XCTAssertEqual(fired.first?.component, "medication_scheduler")

        // A fresh ack window opens for THIS fire...
        guard let ackDeadline = mockAlarm.ackDeadlineChecks[killedReminder.id] else {
            return XCTFail("the re-fire arms the ack-deadline check")
        }
        XCTAssertGreaterThanOrEqual(ackDeadline, beforeRelaunch.addingTimeInterval(5 * 60))
        XCTAssertLessThanOrEqual(ackDeadline, afterRelaunch.addingTimeInterval(5 * 60),
                                 "the ack window is the entry's configured 5 minutes from THIS delivery")

        // ...while the escalation deadline is untouched: the window
        // resumes from the dose's own scheduled time, it never restarts.
        let stored = readStoredReminders()
        guard let storedFired = stored[killedReminder.id.uuidString] else {
            return XCTFail("the re-fired reminder must be persisted")
        }
        XCTAssertEqual(storedFired.scheduledAt, firedAt,
                       "the scheduled time survives the relaunch")
        XCTAssertEqual(storedFired.escalationDeadline, killedReminder.escalationDeadline,
                       "the remaining window is resumed, not re-minted")
        XCTAssertEqual(storedFired.state, .fired)
        XCTAssertEqual(storedFired.refireCount, 0)
        XCTAssertNotNil(storedFired.lastFiredAt)
        XCTAssertNil(storedFired.acknowledgedAt)
        XCTAssertTrue(relaunched.pendingReminders.contains { $0.id == killedReminder.id },
                      "nothing was recorded as missed while the window was still open")

        // The future dose in the same store stays future across the same
        // relaunch: re-armed at its own hour, not fired.
        XCTAssertEqual(mockAlarm.scheduledReminders[futureReminder.id], futureAt,
                       "a pending future dose is re-armed at its scheduled time")
        XCTAssertNil(mockAlarm.ackDeadlineChecks[futureReminder.id],
                     "no ack window opens for a dose that has not fired")
        XCTAssertEqual(stored[futureReminder.id.uuidString]?.state, .pending)
        XCTAssertNil(stored[futureReminder.id.uuidString]?.lastFiredAt)

        // The remaining window still produces re-fires: the next expiry
        // re-fires number 1, measured from the ORIGINAL scheduled time
        // (+12 minutes), not from relaunch.
        relaunched.handleAckDeadlineExpired(for: killedReminder.id)
        let refire = mockObservability.emittedEvents.filter { $0.eventType == "refire" }
        XCTAssertEqual(refire.count, 1, "the resumed window re-fires on its own schedule")
        XCTAssertEqual(refire.first?.metadata["refire_count"], "1")
        XCTAssertEqual(mockAlarm.scheduledReminders[killedReminder.id],
                       firedAt.addingTimeInterval(TimeInterval(12 * 60)),
                       "the re-fire schedule derives from the same scheduled time")
    }

    /// A relaunch must never prompt a dose early: a `.pending` future dose
    /// is re-armed for its own hour and stays `.pending`, never fired. The
    /// differential control lives in the SAME store: a `.pending` dose
    /// whose time passed while the app was dead DOES fire now (the shipped
    /// catch-up branch) — so the future dose's stillness is a measured
    /// difference, not a vacuous pass.
    func testFutureDoseStaysFutureAfterRelaunch() {
        let now = Date()
        let entry = makeMedicationEntry(name: "Amlodipine", timeHour: 8, timeMinute: 0)

        let futureAt = now.addingTimeInterval(7200)
        let upcoming = ScheduledReminder(
            id: UUID(),
            medicationEntryId: entry.id,
            scheduledAt: futureAt,
            refireCount: 0,
            escalationDeadline: futureAt.addingTimeInterval(3600),
            state: .pending,
            lastFiredAt: nil,
            acknowledgedAt: nil
        )
        let overdueAt = now.addingTimeInterval(-600)
        let overdue = ScheduledReminder(
            id: UUID(),
            medicationEntryId: entry.id,
            scheduledAt: overdueAt,
            refireCount: 0,
            escalationDeadline: overdueAt.addingTimeInterval(3600),
            state: .pending,
            lastFiredAt: nil,
            acknowledgedAt: nil
        )
        _ = mockStorage.write(key: "medication.pending_reminders", value: [
            upcoming.id.uuidString: upcoming,
            overdue.id.uuidString: overdue
        ])
        _ = mockStorage.write(key: "medication.entries", value: [entry])

        let relaunched = makeScheduler()
        relaunched.scheduleAll()

        // The future dose stays future.
        XCTAssertEqual(mockAlarm.scheduledReminders[upcoming.id], futureAt,
                       "re-armed at its scheduled time, never fired early")
        XCTAssertNil(mockAlarm.ackDeadlineChecks[upcoming.id],
                     "no ack window opens for a dose that has not fired")
        XCTAssertEqual(readStoredReminders()[upcoming.id.uuidString]?.state, .pending,
                       "its persisted state is untouched")
        XCTAssertNil(readStoredReminders()[upcoming.id.uuidString]?.lastFiredAt)

        // The differential control: the overdue dose in the same pass DID
        // fire — exactly one fire in total, and it belongs to the overdue
        // reminder's ack window.
        XCTAssertNotNil(mockAlarm.ackDeadlineChecks[overdue.id],
                        "the dose whose time passed while dead fires now")
        XCTAssertEqual(readStoredReminders()[overdue.id.uuidString]?.state, .fired)
        XCTAssertEqual(mockObservability.emittedEvents.filter { $0.eventType == "reminder_fired" }.count,
                       1, "exactly the overdue dose fired in the pass")
    }

    /// The T-003 decode boundary (NFR-MSR-006), driven through the real
    /// store and the real scheduler: a payload an older install wrote —
    /// none of `purpose`, `visualAids`, `quantity`, `slot` or
    /// `mealRelation` keys — loads with every legacy field intact and the
    /// slot-model fields at their documented defaults (nil / empty, no
    /// backfill, no inference). The legacy times still feed the arming
    /// resolution VERBATIM. A mid-generation payload carrying `purpose`
    /// and `visualAids` round-trips those too, and a re-encode → decode of
    /// the CURRENT model loses no field in either direction.
    func testLegacyPayloadMigrationRoundTripNoFieldLoss() throws {
        // The oldest shape: every pre-purpose, pre-slot key, nothing else.
        let legacyTimes = [DateComponents(hour: 8, minute: 0), DateComponents(hour: 20, minute: 0)]
        let legacy = LegacyPayloadEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: "Amlodipine",
            doseDescription: "One tablet",
            scheduleTimes: legacyTimes,
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: false,
            confirmationDescription: "small white tablet in the blue box"
        )
        // Precondition, asserted on the fixture's own wire bytes: the
        // payload carries none of the newer keys — the legacy shape is
        // what it looks like, not merely what it is called.
        let legacyBytes = try JSONEncoder().encode([legacy])
        let legacyText = try XCTUnwrap(String(data: legacyBytes, encoding: .utf8))
        for key in ["purpose", "visualAids", "quantity", "slot", "mealRelation"] {
            XCTAssertFalse(legacyText.contains("\"\(key)\""),
                           "precondition: the legacy payload must not carry \(key)")
        }
        _ = mockStorage.write(key: "medication.entries", value: [legacy])

        // The relaunch reads the legacy bytes through the real store.
        let relaunched = makeScheduler()
        relaunched.scheduleAll()

        guard let decoded = relaunched.medicationEntry(for: legacy.id) else {
            return XCTFail("a legacy payload must load through the hand-written decode")
        }
        // Every legacy field, verbatim.
        XCTAssertEqual(decoded.id, legacy.id)
        XCTAssertEqual(decoded.userProfileId, legacy.userProfileId)
        XCTAssertEqual(decoded.medicationName, "Amlodipine")
        XCTAssertEqual(decoded.doseDescription, "One tablet")
        XCTAssertEqual(decoded.scheduleTimes, legacyTimes)
        XCTAssertEqual(decoded.frequency, .daily)
        XCTAssertEqual(decoded.ackWindowMinutes, 5)
        XCTAssertEqual(decoded.maxRefireCount, 5)
        XCTAssertEqual(decoded.escalationWindowMinutes, 60)
        XCTAssertEqual(decoded.doubleDoseWindowHours, 4)
        XCTAssertEqual(decoded.photoVerificationEnabled, false)
        XCTAssertEqual(decoded.confirmationDescription, "small white tablet in the blue box")

        // The slot-model fields: the decode defaults — nothing inferred.
        XCTAssertNil(decoded.purpose, "no backfill of any kind")
        XCTAssertEqual(decoded.visualAids, [])
        XCTAssertNil(decoded.quantity)
        XCTAssertNil(decoded.slot)
        XCTAssertNil(decoded.mealRelation)

        // The legacy times still feed the arming resolution verbatim.
        guard case .success(let resolved) = relaunched.resolvedScheduleTimes(for: decoded) else {
            return XCTFail("a legacy entry always resolves")
        }
        XCTAssertEqual(resolved, legacyTimes,
                       "legacy times pass through the arming feed untouched")

        // The round trip: re-encode the CURRENT model, decode again — no
        // field loss in either direction (the "no schedule is ever lost
        // to a missing key" claim, measured on the bytes).
        let reencoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(MedicationEntry.self, from: reencoded)
        assertNoFieldLoss(decoded, roundTripped, label: "oldest legacy payload")

        // A mid-generation payload: purpose and visual aids exist, the
        // slot-model keys still do not. Both halves must round-trip.
        let withAids = LegacyPayloadEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: "Metformin",
            doseDescription: "Two tablets",
            scheduleTimes: [DateComponents(hour: 13, minute: 30)],
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: true,
            confirmationDescription: nil,
            purpose: "bloodPressure",
            visualAids: [VisualAid(filename: "box.jpg", caption: "the blue box")]
        )
        let withAidsBytes = try JSONEncoder().encode([withAids])
        let withAidsText = try XCTUnwrap(String(data: withAidsBytes, encoding: .utf8))
        for key in ["quantity", "slot", "mealRelation"] {
            XCTAssertFalse(withAidsText.contains("\"\(key)\""),
                           "precondition: the mid-generation payload must not carry \(key)")
        }
        _ = mockStorage.write(key: "medication.entries", value: [withAids])

        let second = makeScheduler()
        second.scheduleAll()
        guard let decodedAids = second.medicationEntry(for: withAids.id) else {
            return XCTFail("a mid-generation payload must load too")
        }
        XCTAssertEqual(decodedAids.purpose, "bloodPressure")
        XCTAssertEqual(decodedAids.visualAids.map(\.filename), ["box.jpg"])
        XCTAssertEqual(decodedAids.visualAids.first?.caption, "the blue box")
        XCTAssertEqual(decodedAids.scheduleTimes, [DateComponents(hour: 13, minute: 30)])
        XCTAssertNil(decodedAids.quantity)
        XCTAssertNil(decodedAids.slot)
        XCTAssertNil(decodedAids.mealRelation)

        let aidsReencoded = try JSONEncoder().encode(decodedAids)
        let aidsRoundTripped = try JSONDecoder().decode(MedicationEntry.self, from: aidsReencoded)
        assertNoFieldLoss(decodedAids, aidsRoundTripped, label: "mid-generation payload")
        let aidsText = try XCTUnwrap(String(data: aidsReencoded, encoding: .utf8))
        XCTAssertTrue(aidsText.contains("\"purpose\""),
                      "the forward migration carries purpose")
        XCTAssertTrue(aidsText.contains("\"visualAids\""),
                      "the forward migration carries the visual aids")
    }

    /// FR-MSR-022's failure leg, end to end through `loadSchedule`:
    ///
    ///  - a refused ENTRIES write is the caller's `false` — nothing is
    ///    adopted, nothing is armed, the share observer is never told, and
    ///    no payload is left behind to be resurrected at the next launch;
    ///  - a refused REMINDER write (entries landed) adopts the entry but
    ///    arms NO platform alarm and reports through the shipped
    ///    `reminder_persistence_failed` event — the unpersisted pending
    ///    state never reaches an alarm.
    func testStorageFailureBlocksAlarmEndToEnd() {
        installMapping(MedicationSlotClock.default, into: mockStorage)
        let entry = makeSlotEntry(slot: .morning, mirrorHour: 8, mirrorMinute: 0)
        let scheduler = makeScheduler()
        var observedWrites = 0
        scheduler.onScheduleChanged = { _ in observedWrites += 1 }

        // Half 1: the entries write itself refuses.
        mockStorage.shouldFailWrite = true
        XCTAssertFalse(scheduler.loadSchedule(entries: [entry]),
                       "the failed persist is the caller's failure — never a silent success")
        XCTAssertEqual(mockAlarm.scheduleCallCount, 0,
                       "a storage failure arms no platform alarm, end to end")
        XCTAssertTrue(mockAlarm.scheduledReminders.isEmpty)
        XCTAssertTrue(mockAlarm.ackDeadlineChecks.isEmpty)
        XCTAssertEqual(observedWrites, 0,
                       "the share observer must never see a schedule that was not stored")
        XCTAssertTrue(mockObservability.emittedEvents.contains {
            $0.eventType == "entry_persistence_failed"
        }, "the shipped failure path reports the refused entries write")
        XCTAssertTrue(scheduler.medicationEntries().isEmpty,
                      "the schedule the store never received is not adopted in memory")
        XCTAssertTrue(scheduler.pendingReminders.isEmpty)
        if case .success = mockStorage.read(key: "medication.pending_reminders",
                                            type: [String: ScheduledReminder].self) {
            XCTFail("a failed write must not leave a reminder payload")
        }
        if case .success = mockStorage.read(key: "medication.entries",
                                            type: [MedicationEntry].self) {
            XCTFail("a failed write must not leave an entries payload")
        }

        // Half 2: the entries write lands and only the pending-state write
        // refuses.
        mockObservability.emittedEvents.removeAll()
        mockStorage.shouldFailWrite = false
        mockStorage.failingWriteKeys = ["medication.pending_reminders"]

        XCTAssertTrue(scheduler.loadSchedule(entries: [entry]),
                      "the entries write lands this time — the failure points are distinct")
        XCTAssertEqual(mockAlarm.scheduleCallCount, 0,
                       "the unpersisted pending state arms no platform alarm")
        XCTAssertTrue(mockAlarm.scheduledReminders.isEmpty)
        XCTAssertTrue(mockObservability.emittedEvents.contains {
            $0.eventType == "reminder_persistence_failed"
        }, "the reminder-write failure keeps its shipped report")
        XCTAssertEqual(observedWrites, 1,
                       "the observer was told about the STORED schedule, and nothing more was claimed for it")
        if case .success = mockStorage.read(key: "medication.pending_reminders",
                                            type: [String: ScheduledReminder].self) {
            XCTFail("a failed reminder write must not leave a reminder payload")
        }
    }

    // MARK: - Fixture and helpers

    private func makeScheduler() -> MedicationScheduler {
        MedicationScheduler(
            storage: mockStorage,
            alarmScheduler: mockAlarm,
            observabilityBus: mockObservability,
            familyNotifier: mockFamilyNotifier,
            caregiverNotifySettings: caregiverNotifySettings
        )
    }

    private func readStoredReminders() -> [String: ScheduledReminder] {
        guard case .success(let stored) = mockStorage.read(key: "medication.pending_reminders",
                                                           type: [String: ScheduledReminder].self) else {
            XCTFail("the reminder payload must be readable")
            return [:]
        }
        return stored
    }

    /// The payload shape the first installs wrote (T-003's legacy shape):
    /// every key the model had before the slot model, and — for the
    /// oldest fixture — none of the newer ones. `nil` optionals are
    /// omitted by the synthesized encode, exactly as the real installs
    /// omitted them.
    private struct LegacyPayloadEntry: Encodable {
        let id: UUID
        let userProfileId: UUID
        let medicationName: String
        let doseDescription: String
        let scheduleTimes: [DateComponents]
        let frequency: MedicationFrequency
        let ackWindowMinutes: Int
        let maxRefireCount: Int
        let escalationWindowMinutes: Int
        let doubleDoseWindowHours: Int
        let photoVerificationEnabled: Bool
        let confirmationDescription: String?
        var purpose: String? = nil
        var visualAids: [VisualAid]? = nil
    }

    /// Field-by-field equality of two decoded entries — the "no field
    /// loss" claim, asserted on every field the model has TODAY, so a
    /// field added later is checked the moment it exists.
    private func assertNoFieldLoss(_ first: MedicationEntry, _ second: MedicationEntry,
                                   label: String) {
        XCTAssertEqual(first.id, second.id, "\(label): id")
        XCTAssertEqual(first.userProfileId, second.userProfileId, "\(label): userProfileId")
        XCTAssertEqual(first.medicationName, second.medicationName, "\(label): medicationName")
        XCTAssertEqual(first.doseDescription, second.doseDescription, "\(label): doseDescription")
        XCTAssertEqual(first.scheduleTimes, second.scheduleTimes, "\(label): scheduleTimes")
        XCTAssertEqual(first.frequency, second.frequency, "\(label): frequency")
        XCTAssertEqual(first.ackWindowMinutes, second.ackWindowMinutes, "\(label): ackWindowMinutes")
        XCTAssertEqual(first.maxRefireCount, second.maxRefireCount, "\(label): maxRefireCount")
        XCTAssertEqual(first.escalationWindowMinutes, second.escalationWindowMinutes,
                       "\(label): escalationWindowMinutes")
        XCTAssertEqual(first.doubleDoseWindowHours, second.doubleDoseWindowHours,
                       "\(label): doubleDoseWindowHours")
        XCTAssertEqual(first.photoVerificationEnabled, second.photoVerificationEnabled,
                       "\(label): photoVerificationEnabled")
        XCTAssertEqual(first.confirmationDescription, second.confirmationDescription,
                       "\(label): confirmationDescription")
        XCTAssertEqual(first.purpose, second.purpose, "\(label): purpose")
        XCTAssertEqual(first.visualAids, second.visualAids, "\(label): visualAids")
        XCTAssertEqual(first.quantity, second.quantity, "\(label): quantity")
        XCTAssertEqual(first.slot, second.slot, "\(label): slot")
        XCTAssertEqual(first.mealRelation, second.mealRelation, "\(label): mealRelation")
    }

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
}
