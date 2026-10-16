import XCTest
import UIKit
@testable import ElderlyAssistant

/// Records routine alarm calls — the `MockAlarmScheduler` analogue for
/// `RoutineAlarmScheduling`.
final class MockRoutineAlarmScheduler: RoutineAlarmScheduling {
    /// `visualAidURL` rides along (photo-visual-aids task, 2026-09-16) so
    /// the tests can assert the scheduler handed the reminder's photo to
    /// the notification, and that it passes nil when there is none.
    var scheduled: [UUID: (entryId: UUID, title: String, visualAidURL: URL?, at: Date)] = [:]
    var scheduleCalls: [UUID: Int] = [:]
    var cancelled: [UUID] = []

    func scheduleRoutineReminder(occurrenceId: UUID, entryId: UUID,
                                 title: String, visualAidURL: URL?,
                                 at scheduledTime: Date) {
        scheduled[occurrenceId] = (entryId, title, visualAidURL, scheduledTime)
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
    /// Shared with the medication tests' mock (same test module) — the
    /// caregiver-alert seam is one protocol for every firing system.
    var notifier: MockFamilyNotifier!
    /// Isolated per test: the settings persist, so a shared instance
    /// would leak a flipped toggle into the next test.
    var caregiverNotifySettings: CaregiverNotifySettings!
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
        notifier = MockFamilyNotifier()
        caregiverNotifySettings = CaregiverNotifySettings.isolated()
        scheduler = RoutineScheduler(store: store, alarmScheduler: alarm,
                                     observabilityBus: bus,
                                     familyNotifier: notifier,
                                     caregiverNotifySettings: caregiverNotifySettings,
                                     now: { [weak self] in
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
                                          familyNotifier: notifier,
                                          caregiverNotifySettings: caregiverNotifySettings,
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

    // MARK: - onScheduleChanged seam (calendar-driven task, 2026-09-07)

    func testOnScheduleChangedFiresOncePerMutation() {
        var fires = 0
        scheduler.onScheduleChanged = { fires += 1 }

        let entry = makeEntry(hour: 11)
        XCTAssertTrue(scheduler.addEntry(entry))
        scheduler.setEnabled(entry.id, enabled: false)
        scheduler.setEnabled(entry.id, enabled: true)
        scheduler.removeEntry(id: entry.id)

        XCTAssertEqual(fires, 4,
                       "add / disable / enable / remove each fire the seam exactly once")
    }

    func testOnScheduleChangedDoesNotFireOnScheduleAll() {
        store.add(makeEntry(hour: 11))
        var fires = 0
        scheduler.onScheduleChanged = { fires += 1 }

        scheduler.scheduleAll()
        scheduler.scheduleAll()

        XCTAssertEqual(fires, 0,
                       "launch/BGTask re-queues must not re-trigger side channels per occurrence")
    }

    func testOnScheduleChangedNotFiredWhenMutationFails() {
        var fires = 0
        scheduler.onScheduleChanged = { fires += 1 }
        storage.shouldFailWrite = true

        let entry = makeEntry(hour: 11)
        XCTAssertFalse(scheduler.addEntry(entry))   // persistence failed → nothing changed
        XCTAssertEqual(fires, 0, "a failed add changes nothing, so the seam stays silent")

        storage.shouldFailWrite = false
        XCTAssertTrue(scheduler.addEntry(entry))
        XCTAssertEqual(fires, 1)
    }

    // MARK: - Native-edit mutators (calendar-driven task, 2026-09-07)

    func testRetimeSlotPersistsRearmsAndFiresTheSeam() {
        let entry = makeEntry(hour: 11)
        scheduler.addEntry(entry)
        let oldIds = Set(alarm.scheduled.keys)
        XCTAssertEqual(oldIds.count, 2, "today + tomorrow at 11:00")
        var fires = 0
        scheduler.onScheduleChanged = { fires += 1 }

        let retimed = scheduler.retimeSlot(entryId: entry.id, fromHour: 11,
                                           fromMinute: 0, toHour: 14, toMinute: 0)

        XCTAssertTrue(retimed)
        XCTAssertEqual(scheduler.entries().first?.scheduleTimes,
                       [DateComponents(hour: 14, minute: 0)])
        XCTAssertEqual(RoutineStore(storage: storage).loadEntries().first?.scheduleTimes,
                       [DateComponents(hour: 14, minute: 0)], "durable across store instances")
        XCTAssertEqual(Set(alarm.cancelled), oldIds,
                       "the 11:00 occurrences are cancelled (identity is time-keyed)")
        XCTAssertEqual(alarm.scheduled.count, 2)
        XCTAssertTrue(alarm.scheduled.values.allSatisfy {
            Calendar.current.component(.hour, from: $0.at) == 14
        })
        XCTAssertEqual(fires, 1)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "entry_retimed" })
    }

    func testRetimeSlotIsANoOpWhenFromTimeIsGone() {
        let entry = makeEntry(hour: 11)
        scheduler.addEntry(entry)
        let scheduleBefore = scheduler.entries().first?.scheduleTimes
        var fires = 0
        scheduler.onScheduleChanged = { fires += 1 }

        let retimed = scheduler.retimeSlot(entryId: entry.id, fromHour: 9,
                                           fromMinute: 0, toHour: 14, toMinute: 0)

        XCTAssertFalse(retimed, "a from-time that no slot has changes nothing")
        XCTAssertEqual(scheduler.entries().first?.scheduleTimes, scheduleBefore)
        XCTAssertEqual(fires, 0)
    }

    func testDropSlotRemovesExactlyThatTime() {
        let entry = RoutineEntry(category: .walk,
                                 scheduleTimes: [DateComponents(hour: 11, minute: 0),
                                                 DateComponents(hour: 16, minute: 0)],
                                 isEnabled: true)
        scheduler.addEntry(entry)
        XCTAssertEqual(alarm.scheduled.count, 4, "two slots × two days")
        var fires = 0
        scheduler.onScheduleChanged = { fires += 1 }

        let dropped = scheduler.dropSlot(entryId: entry.id, hour: 11, minute: 0)

        XCTAssertTrue(dropped)
        XCTAssertEqual(scheduler.entries().first?.scheduleTimes,
                       [DateComponents(hour: 16, minute: 0)])
        XCTAssertEqual(alarm.scheduled.count, 2, "only the 16:00 occurrences remain armed")
        XCTAssertEqual(alarm.cancelled.count, 2, "the 11:00 pair is cancelled")
        XCTAssertEqual(fires, 1)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "slot_dropped" })
    }

    func testDropSlotRefusesToEmptyTheList() {
        let entry = makeEntry(hour: 11)
        scheduler.addEntry(entry)

        let dropped = scheduler.dropSlot(entryId: entry.id, hour: 11, minute: 0)

        XCTAssertFalse(dropped,
                       "an entry whose last slot goes is DISABLED by the planner, never emptied here")
        XCTAssertEqual(scheduler.entries().first?.scheduleTimes,
                       [DateComponents(hour: 11, minute: 0)])
        XCTAssertEqual(alarm.scheduled.count, 2, "nothing re-armed, nothing cancelled")
    }

    func testUpdateRecurrenceStoresWeeklyDaysSortedAndDailyClearsThem() {
        let entry = makeEntry(hour: 11)
        scheduler.addEntry(entry)
        var fires = 0
        scheduler.onScheduleChanged = { fires += 1 }

        XCTAssertTrue(scheduler.updateRecurrence(entryId: entry.id, frequency: .weekly,
                                                 weekdays: [5, 2]))
        let weekly = scheduler.entries().first
        XCTAssertEqual(weekly?.frequency, .weekly)
        XCTAssertEqual(weekly?.weekdays, [2, 5], "stored sorted — comparison-normalized everywhere")

        XCTAssertTrue(scheduler.updateRecurrence(entryId: entry.id, frequency: .daily,
                                                 weekdays: []))
        let daily = scheduler.entries().first
        XCTAssertEqual(daily?.frequency, .daily)
        XCTAssertTrue(daily?.weekdays.isEmpty ?? false)
        XCTAssertEqual(fires, 2)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "entry_recurrence_updated" })
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

    // MARK: - Caregiver event alerts (2026-09-13)

    /// A delivered routine occurrence tells the family — with the SAME
    /// display title the notification body and the calendar mirror use,
    /// so the caregiver reads the words the elder heard.
    func testMarkDeliveredNotifiesCaregiversWithRoutineKind() async {
        let entry = makeEntry(hour: 11)
        store.add(entry)
        scheduler.scheduleAll()
        caregiverNotifySettings.routineReminders = true
        guard let occurrence = scheduler.todaysOccurrences().first else {
            return XCTFail("expected a pending occurrence today")
        }
        let notified = expectation(description: "caregiver alert")
        notifier.onNotify = { notified.fulfill() }

        scheduler.markDelivered(occurrenceId: occurrence.id)
        await fulfillment(of: [notified], timeout: 2)

        XCTAssertEqual(notifier.lastAlertType, .eventReminder)
        XCTAssertEqual(notifier.contexts.count, 1)
        let context = notifier.contexts.first
        XCTAssertEqual(context?.kind, .routineReminder)
        XCTAssertEqual(context?.eventTitle, entry.displayTitle(locale: scheduler.locale))
        XCTAssertEqual(context?.eventIdHash, IdHashing.shortHash(of: occurrence.id))
        XCTAssertEqual(context?.fireAt, occurrence.scheduledAt)
    }

    /// Foreground and background delivery of the SAME notification both
    /// land here — the second call finds the occurrence already
    /// `.delivered` and must not alert again.
    func testMarkDeliveredAlertsOnceForTheSameOccurrence() async {
        store.add(makeEntry(hour: 11))
        scheduler.scheduleAll()
        caregiverNotifySettings.routineReminders = true
        guard let occurrence = scheduler.todaysOccurrences().first else {
            return XCTFail("expected a pending occurrence today")
        }
        let first = expectation(description: "first alert")
        notifier.onNotify = { first.fulfill() }
        scheduler.markDelivered(occurrenceId: occurrence.id)
        await fulfillment(of: [first], timeout: 2)

        let noSecond = expectation(description: "no second alert")
        noSecond.isInverted = true
        notifier.onNotify = { noSecond.fulfill() }
        scheduler.markDelivered(occurrenceId: occurrence.id)
        await fulfillment(of: [noSecond], timeout: 0.3)

        XCTAssertEqual(notifier.contexts.count, 1)
    }

    /// Toggle OFF (the default): routines behave exactly as before the
    /// caregiver-alert wiring — delivered, and nobody told.
    func testMarkDeliveredDoesNotNotifyWhenToggleIsOff() async {
        store.add(makeEntry(hour: 11))
        scheduler.scheduleAll()
        XCTAssertFalse(caregiverNotifySettings.routineReminders, "defaults are OFF")
        guard let occurrence = scheduler.todaysOccurrences().first else {
            return XCTFail("expected a pending occurrence today")
        }
        let noAlert = expectation(description: "no caregiver alert")
        noAlert.isInverted = true
        notifier.onNotify = { noAlert.fulfill() }

        scheduler.markDelivered(occurrenceId: occurrence.id)
        await fulfillment(of: [noAlert], timeout: 0.3)

        XCTAssertEqual(scheduler.todaysOccurrences().first?.state, .delivered,
                       "the delivery itself is unaffected by the notify toggle")
        XCTAssertTrue(notifier.contexts.isEmpty)
    }

    // MARK: - Visual aids (photo-visual-aids task, 2026-09-16)

    private var tmpVisualAids: URL!

    /// A scheduler wired to a throwaway photo store — the production
    /// shape (`AppCoordinator` passes the app's shared store).
    private func makeSchedulerWithPhotoStore() -> (RoutineScheduler, VisualAidStore) {
        tmpVisualAids = FileManager.default.temporaryDirectory
            .appendingPathComponent("routine-aid-tests-\(UUID().uuidString)")
        let photoStore = VisualAidStore(rootDirectory: tmpVisualAids)
        let photoScheduler = RoutineScheduler(
            store: store, alarmScheduler: alarm, observabilityBus: bus,
            familyNotifier: notifier, caregiverNotifySettings: caregiverNotifySettings,
            visualAidStore: photoStore,
            now: { [weak self] in self?.fakeNow ?? Date() }
        )
        return (photoScheduler, photoStore)
    }

    private func makeImage(_ side: CGFloat = 40) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                       format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    override func tearDown() {
        if let tmpVisualAids { try? FileManager.default.removeItem(at: tmpVisualAids) }
        tmpVisualAids = nil
        super.tearDown()
    }

    /// The reminder's first photo reaches the alarm scheduler, which is
    /// what puts the medicine box in the firing banner — the whole point
    /// of the attachment path.
    func testScheduledReminderCarriesTheFirstAidsURL() throws {
        let (photoScheduler, photoStore) = makeSchedulerWithPhotoStore()
        var entry = makeEntry(hour: 11)
        let aid = try XCTUnwrap(photoStore.save(makeImage(), for: entry.id))
        entry.visualAids = [aid]

        photoScheduler.addEntry(entry)

        let armed = try XCTUnwrap(alarm.scheduled.values.first)
        XCTAssertEqual(armed.visualAidURL?.lastPathComponent, aid.filename)
        XCTAssertEqual(armed.title, entry.displayTitle(locale: photoScheduler.locale))
    }

    /// An entry with no photos arms exactly as it did before the feature
    /// — nil is the signal for "text-only banner".
    func testScheduledReminderWithoutPhotosPassesNilURL() {
        let (photoScheduler, _) = makeSchedulerWithPhotoStore()
        photoScheduler.addEntry(makeEntry(hour: 11))

        XCTAssertEqual(alarm.scheduled.count, 2)
        XCTAssertTrue(alarm.scheduled.values.allSatisfy { $0.visualAidURL == nil })
    }

    /// A model entry whose file is gone (deleted by hand, or a restore
    /// that lost the container's Application Support) must not hand a
    /// missing URL to the notification system — that would fail the
    /// attachment and, worse, could drop the whole reminder.
    func testMissingPhotoFileArmsWithNilURL() {
        let (photoScheduler, photoStore) = makeSchedulerWithPhotoStore()
        var entry = makeEntry(hour: 11)
        let aid = VisualAid(filename: "never-written.jpg")
        entry.visualAids = [aid]
        XCTAssertNil(photoStore.existingFileURL(aid, for: entry.id))

        photoScheduler.addEntry(entry)

        XCTAssertTrue(alarm.scheduled.values.allSatisfy { $0.visualAidURL == nil },
                      "a missing file must degrade to a text-only reminder")
    }

    /// `setVisualAids` is the photo editor's save path: durable, and
    /// re-armed so the banner picks the photo up immediately.
    func testSetVisualAidsPersistsAndRearms() throws {
        let (photoScheduler, photoStore) = makeSchedulerWithPhotoStore()
        let entry = makeEntry(hour: 11)
        photoScheduler.addEntry(entry)
        XCTAssertTrue(alarm.scheduled.values.allSatisfy { $0.visualAidURL == nil })

        let aid = try XCTUnwrap(photoStore.save(makeImage(), for: entry.id))
        XCTAssertTrue(photoScheduler.setVisualAids([aid], entryId: entry.id))

        XCTAssertEqual(photoScheduler.entry(for: entry.id)?.visualAids, [aid],
                       "durable across the store")
        XCTAssertEqual(RoutineStore(storage: storage).loadEntries().first?.visualAids, [aid])
        XCTAssertEqual(alarm.scheduled.count, 2)
        XCTAssertTrue(alarm.scheduled.values.allSatisfy {
            $0.visualAidURL?.lastPathComponent == aid.filename
        }, "the re-arm is what carries the photo into the already-armed window")
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "entry_visual_aids_updated" })
    }

    func testSetVisualAidsOnAnUnknownEntryIsANoOp() {
        let (photoScheduler, _) = makeSchedulerWithPhotoStore()
        XCTAssertFalse(photoScheduler.setVisualAids([VisualAid(filename: "a.jpg")],
                                                    entryId: UUID()))
        XCTAssertTrue(alarm.scheduled.isEmpty)
    }

    /// Deleting a reminder deletes its photos — a picture of a medicine
    /// box must not outlive the reminder it was attached to.
    func testRemoveEntryDeletesItsPhotos() throws {
        let (photoScheduler, photoStore) = makeSchedulerWithPhotoStore()
        var entry = makeEntry(hour: 11)
        let aid = try XCTUnwrap(photoStore.save(makeImage(), for: entry.id))
        entry.visualAids = [aid]
        photoScheduler.addEntry(entry)

        photoScheduler.removeEntry(id: entry.id)

        XCTAssertNil(photoStore.load(aid, for: entry.id),
                     "the entry's whole photo directory must be gone")
    }

    /// The scheduler is usable without a photo store at all (every
    /// existing harness) — nothing touches the disk and reminders arm
    /// text-only.
    func testSchedulerWithoutAPhotoStoreStillArms() {
        store.add(makeEntry(hour: 11))

        scheduler.scheduleAll()

        XCTAssertEqual(alarm.scheduled.count, 2)
        XCTAssertTrue(alarm.scheduled.values.allSatisfy { $0.visualAidURL == nil })
    }
}
