import XCTest
@testable import ElderlyAssistant

/// Records routine alarm calls — the `MockAlarmScheduler` analogue for
/// `RoutineAlarmScheduling`.
final class MockRoutineAlarmScheduler: RoutineAlarmScheduling {
    var scheduled: [UUID: (entryId: UUID, title: String, at: Date)] = [:]
    var scheduleCalls: [UUID: Int] = [:]
    var cancelled: [UUID] = []

    func scheduleRoutineReminder(occurrenceId: UUID, entryId: UUID,
                                 title: String, at scheduledTime: Date) {
        scheduled[occurrenceId] = (entryId, title, scheduledTime)
        scheduleCalls[occurrenceId, default: 0] += 1
    }

    func cancelRoutineReminder(occurrenceId: UUID) {
        cancelled.append(occurrenceId)
        scheduled.removeValue(forKey: occurrenceId)
    }

    func cancelRoutineReminders(occurrenceIds: [UUID]) {
        for id in occurrenceIds {
            cancelled.append(id)
            scheduled.removeValue(forKey: id)
        }
    }
}

/// Scheduler tests mirror MedicationSchedulerTests' approach: in-memory
/// storage, a recording alarm fake, and — via the injected clock — a
/// pinned "now" so window/weekday behavior is deterministic.
final class RoutineSchedulerTests: XCTestCase {

    var storage: MockEncryptedLocalStorage!
    var store: RoutineStore!
    var alarm: MockRoutineAlarmScheduler!
    var bus: MockObservabilityBus!
    var scheduler: RoutineScheduler!
    var fakeNow: Date!

    /// Pinned "now": 2026-09-07 10:00 local.
    private func pinnedNow(hour: Int = 10, minute: Int = 0) -> Date {
        let date = Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 7, hour: hour, minute: minute))
        guard let date else {
            XCTFail("could not build pinned date")
            return Date()
        }
        return date
    }

    override func setUp() {
        super.setUp()
        storage = MockEncryptedLocalStorage()
        store = RoutineStore(storage: storage)
        alarm = MockRoutineAlarmScheduler()
        bus = MockObservabilityBus()
        fakeNow = pinnedNow()
        scheduler = RoutineScheduler(store: store, alarmScheduler: alarm,
                                     observabilityBus: bus, now: { [weak self] in
                                         self?.fakeNow ?? Date()
                                     })
    }

    private func makeEntry(category: RoutineCategory = .walk,
                           hour: Int = 11, minute: Int = 0,
                           enabled: Bool = true,
                           frequency: RoutineFrequency = .daily,
                           weekdays: [Int] = []) -> RoutineEntry {
        RoutineEntry(category: category,
                     scheduleTimes: [DateComponents(hour: hour, minute: minute)],
                     frequency: frequency,
                     weekdays: weekdays,
                     isEnabled: enabled)
    }

    // MARK: - Window generation

    func testScheduleAllArmsFutureOccurrencesForTodayAndTomorrow() {
        store.add(makeEntry(hour: 11))

        scheduler.scheduleAll()

        // Today 11:00 + tomorrow 11:00 (now is 10:00) — both future, both armed.
        XCTAssertEqual(alarm.scheduled.count, 2)
    }

    func testPastOccurrencesExpireInsteadOfFiringLate() {
        store.add(makeEntry(hour: 9))   // already past at 10:00

        scheduler.scheduleAll()

        // Today's 09:00 expired (never armed — a stale walk reminder is
        // noise, not safety); tomorrow's 09:00 armed.
        XCTAssertEqual(alarm.scheduled.count, 1)
        let todays = scheduler.todaysOccurrences()
        XCTAssertEqual(todays.count, 1)
        XCTAssertEqual(todays.first?.state, .expired)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "occurrence_expired_unfired" })
    }

    func testDisabledEntryProducesNoOccurrences() {
        store.add(makeEntry(hour: 11, enabled: false))

        scheduler.scheduleAll()

        XCTAssertTrue(alarm.scheduled.isEmpty)
        XCTAssertTrue(scheduler.todaysOccurrences().isEmpty)
    }

    func testMultiTimeEntryArmsEachTime() {
        let entry = RoutineEntry(category: .exercise,
                                 scheduleTimes: [DateComponents(hour: 11),
                                                 DateComponents(hour: 16)],
                                 isEnabled: true)
        store.add(entry)

        scheduler.scheduleAll()

        // Two times × two days in the window.
        XCTAssertEqual(alarm.scheduled.count, 4)
    }

    func testWeeklyEntryFiresOnlyOnMatchingWeekdays() {
        let calendar = Calendar.current
        let todayWeekday = calendar.component(.weekday, from: fakeNow)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: fakeNow) else {
            XCTFail("date arithmetic failed")
            return
        }
        let tomorrowWeekday = calendar.component(.weekday, from: tomorrow)

        // Matches today but not tomorrow.
        store.add(makeEntry(hour: 11, frequency: .weekly, weekdays: [todayWeekday]))
        // Matches tomorrow but not today.
        store.add(makeEntry(category: .gym, hour: 12, frequency: .weekly,
                            weekdays: [tomorrowWeekday]))

        scheduler.scheduleAll()

        // Today: only the first entry's 11:00. Tomorrow: only the
        // second's 12:00 (consecutive days always have distinct
        // weekdays, so the two entries never fire on the same day).
        XCTAssertEqual(alarm.scheduled.count, 2)
        let todays = scheduler.todaysOccurrences().filter { $0.state == .pending }
        XCTAssertEqual(todays.count, 1)
        let hour = calendar.component(.hour, from: todays.first?.scheduledAt ?? fakeNow)
        XCTAssertEqual(hour, 11)
    }

    // MARK: - Persistence before alarm

    func testPersistenceFailurePreventsArming() {
        store.add(makeEntry(hour: 11))
        storage.shouldFailWrite = true

        scheduler.scheduleAll()

        XCTAssertTrue(alarm.scheduled.isEmpty,
                      "occurrences must persist BEFORE alarms arm (medication path's rule)")
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "occurrence_persistence_failed" })
    }

    // MARK: - Re-arm identity + restore

    func testRepeatedScheduleAllKeepsOccurrenceIdentity() {
        store.add(makeEntry(hour: 11))

        scheduler.scheduleAll()
        let firstIds = Set(alarm.scheduled.keys)
        scheduler.scheduleAll()
        let secondIds = Set(alarm.scheduled.keys)

        XCTAssertEqual(firstIds, secondIds,
                       "re-arming must keep occurrence ids stable (no duplicate alarms)")
    }

    func testRestoreAcrossRelaunchRearmsWindow() {
        store.add(makeEntry(hour: 11))
        scheduler.scheduleAll()
        let originalIds = Set(alarm.scheduled.keys)

        // Simulate relaunch: fresh scheduler over the SAME storage.
        let relaunched = RoutineScheduler(store: RoutineStore(storage: storage),
                                          alarmScheduler: alarm,
                                          observabilityBus: bus,
                                          now: { [weak self] in self?.fakeNow ?? Date() })
        relaunched.scheduleAll()

        XCTAssertEqual(Set(alarm.scheduled.keys), originalIds,
                       "FR-025: relaunch re-queues the day's pending reminders with stable ids")
    }

    // MARK: - Mutations

    func testAddEntryPersistsAndArms() {
        let entry = makeEntry(hour: 11)

        XCTAssertTrue(scheduler.addEntry(entry))

        XCTAssertEqual(scheduler.entries().count, 1)
        XCTAssertEqual(alarm.scheduled.count, 2)
        // New store instance sees it (durable).
        XCTAssertEqual(RoutineStore(storage: storage).loadEntries().count, 1)
    }

    func testSetEnabledFalseCancelsAlarms() {
        let entry = makeEntry(hour: 11)
        scheduler.addEntry(entry)
        XCTAssertEqual(alarm.scheduled.count, 2)

        scheduler.setEnabled(entry.id, enabled: false)

        XCTAssertTrue(alarm.scheduled.isEmpty)
        XCTAssertEqual(alarm.cancelled.count, 2,
                       "disabling cancels this entry's alarms — and ONLY those")
        XCTAssertTrue(scheduler.todaysOccurrences().isEmpty)
    }

    func testRemoveEntryCancelsAndDrops() {
        let entry = makeEntry(hour: 11)
        scheduler.addEntry(entry)

        scheduler.removeEntry(id: entry.id)

        XCTAssertTrue(scheduler.entries().isEmpty)
        XCTAssertTrue(alarm.scheduled.isEmpty)
    }

    // MARK: - Today's list

    func testTodaysOccurrencesFiltersAndSorts() {
        store.add(makeEntry(category: .exercise, hour: 16))
        store.add(makeEntry(category: .walk, hour: 11))

        scheduler.scheduleAll()

        let todays = scheduler.todaysOccurrences()
        XCTAssertEqual(todays.count, 2)
        XCTAssertLessThan(todays[0].scheduledAt, todays[1].scheduledAt)
    }

    func testMarkDeliveredUpdatesState() {
        store.add(makeEntry(hour: 11))
        scheduler.scheduleAll()
        guard let occurrence = scheduler.todaysOccurrences().first else {
            XCTFail("expected a pending occurrence today")
            return
        }
        let callsBefore = alarm.scheduleCalls[occurrence.id] ?? 0

        scheduler.markDelivered(occurrenceId: occurrence.id)

        XCTAssertEqual(scheduler.todaysOccurrences().first?.state, .delivered)
        // Delivered occurrences are not re-armed on the next pass (their
        // notification already fired — there is nothing to deliver again).
        scheduler.scheduleAll()
        XCTAssertEqual(alarm.scheduleCalls[occurrence.id] ?? 0, callsBefore)
    }
}
