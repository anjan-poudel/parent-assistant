import XCTest
@testable import ElderlyAssistant

/// Service, planner and link-store tests for `CalendarSyncService`
/// against a fake `EventKitCalendarGateway` — the
/// `ExternalItemOpening`-seam style: canned permission truth plus an
/// in-memory event store whose fetches honour the predicate window.
/// Two-way mirroring (calendar-driven task, 2026-09-07) is decided by
/// PURE functions (`planNativeMutations` / `planMirrorOperations` /
/// `twoWaySyncDecision`); every rule below runs with zero OS permission
/// involvement. "Now" is anchored to REAL today at 10:00, like the
/// ExternalCalendarService suite.
final class CalendarSyncServiceTests: XCTestCase {

    // MARK: - Fakes

    /// In-memory `EventKitCalendarGateway`. `records` is the whole
    /// "store"; `fetchEvents` honours EKEventStore predicate semantics
    /// (only events whose start falls inside the window are returned).
    /// Every mutation is recorded for assertions.
    private final class FakeGateway: EventKitCalendarGateway {
        var access: CalendarAccess = .notDetermined
        var grantRequestResult = true
        private(set) var fullAccessRequests = 0
        private(set) var ensureSahayakCalls = 0
        private(set) var created: [(draft: CalendarEventDraft,
                                    calendarIdentifier: String?)] = []
        private(set) var updated: [(identifier: String, draft: CalendarEventDraft)] = []
        private(set) var removedIdentifiers: [String] = []
        private(set) var fragmentRemovalRequests: [String] = []
        private(set) var lastFragmentRemovalCount: Int?
        var records: [CalendarEventRecord] = []

        var eventsAccess: CalendarAccess { access }

        func requestFullAccess() async -> Bool {
            fullAccessRequests += 1
            return grantRequestResult
        }

        func ensureSahayakCalendar(knownIdentifier: String?) -> String? {
            ensureSahayakCalls += 1
            guard access == .fullAccess || access == .writeOnly else { return nil }
            // A remembered identifier short-circuits creation (the
            // production fast path); otherwise the calendar is "found"
            // once and answered with a stable id.
            return knownIdentifier ?? "sahayak-1"
        }

        func fetchEvents(from start: Date, to end: Date) -> [CalendarEventRecord] {
            records.filter { $0.startDate >= start && $0.startDate < end }
        }

        /// The by-identifier read (rich-events task, 2026-09-17) — the
        /// free-form share reconcile's lookup, answered from the same
        /// in-memory store the writers maintain, so a test can retime a
        /// record and see the reconcile follow.
        func fetchEvent(identifier: String) -> CalendarEventRecord? {
            records.first { $0.eventIdentifier == identifier }
        }

        func createEvent(_ draft: CalendarEventDraft,
                         in calendarIdentifier: String?) -> String? {
            guard access == .fullAccess || access == .writeOnly else { return nil }
            created.append((draft, calendarIdentifier))
            let identifier = "evt-\(created.count)"
            records.append(CalendarEventRecord(
                eventIdentifier: identifier,
                calendarIdentifier: calendarIdentifier ?? "default-calendar",
                title: draft.title, notes: draft.notes,
                startDate: draft.startDate, isAllDay: false,
                isCanceled: false, recurrence: draft.recurrence))
            return identifier
        }

        func updateEvent(identifier: String, with draft: CalendarEventDraft) -> Bool {
            guard let index = records.firstIndex(where: { $0.eventIdentifier == identifier })
            else { return false }
            let existing = records[index]
            records[index] = CalendarEventRecord(
                eventIdentifier: identifier,
                calendarIdentifier: existing.calendarIdentifier,
                title: draft.title, notes: draft.notes,
                startDate: draft.startDate, isAllDay: existing.isAllDay,
                isCanceled: false, recurrence: draft.recurrence)
            updated.append((identifier, draft))
            return true
        }

        func removeEvent(identifier: String) -> Bool {
            guard let index = records.firstIndex(where: { $0.eventIdentifier == identifier })
            else { return false }
            records.remove(at: index)
            removedIdentifiers.append(identifier)
            return true
        }

        func removeEvents(matchingNotesFragment fragment: String) -> Int {
            fragmentRemovalRequests.append(fragment)
            let mirrors = records.filter { $0.notes?.contains(fragment) == true }
            records.removeAll { $0.notes?.contains(fragment) == true }
            lastFragmentRemovalCount = mirrors.count
            return mirrors.count
        }
    }

    // MARK: - Harness

    /// Start of REAL today — the anchor for every item date below.
    private var startOfToday: Date { Calendar.current.startOfDay(for: Date()) }

    /// Pinned "now": 10:00 today. The suite's hour choice keeps daily
    /// next-occurrence math deterministic (a slot before 10:00 lands
    /// tomorrow, after 10:00 lands today).
    private var fakeNow: Date { time(10) }

    private func time(_ hour: Int, minute: Int = 0, dayOffset: Int = 0) -> Date {
        let base = dayOffset == 0
            ? startOfToday
            : Calendar.current.date(byAdding: .day, value: dayOffset, to: startOfToday)!
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
    }

    private func entry(id: UUID = UUID(), name: String? = nil,
                       category: RoutineCategory = .exercise,
                       hours: [Int] = [11],
                       frequency: RoutineFrequency = .daily,
                       weekdays: [Int] = [],
                       enabled: Bool = true) -> RoutineEntry {
        RoutineEntry(id: id, category: category, titleOverride: name,
                     scheduleTimes: hours.map { DateComponents(hour: $0, minute: 0) },
                     frequency: frequency, weekdays: weekdays, isEnabled: enabled)
    }

    /// A token'd Sahayak record — `notes` defaults to a well-formed
    /// `MirrorLinkToken` for `(entryId, slot)`.
    private func record(id: String = "evt-x", entryId: UUID, slot: Int,
                        hour: Int, minute: Int = 0, dayOffset: Int = 0,
                        title: String = "Mirrored event",
                        recurrence: EventRecurrence? = .daily,
                        isAllDay: Bool = false,
                        isCanceled: Bool = false,
                        notes: String? = nil) -> CalendarEventRecord {
        CalendarEventRecord(
            eventIdentifier: id,
            calendarIdentifier: "sahayak-1",
            title: title,
            notes: notes ?? MirrorLinkToken.notes(entryId: entryId, slot: slot),
            startDate: time(hour, minute: minute, dayOffset: dayOffset),
            isAllDay: isAllDay,
            isCanceled: isCanceled,
            recurrence: recurrence
        )
    }

    /// The title every mirror draft carries for `entry` — the mirror
    /// layer composes "<name> (<category label ne>)".
    private func mirrorTitle(for entry: RoutineEntry) -> String {
        let label = L10n.str(entry.category.displayNameKey,
                             locale: Locale(identifier: "ne"))
        return "\(entry.displayTitle(locale: Locale(identifier: "ne"))) (\(label))"
    }

    private func makeService(grant: Bool = true, access: CalendarAccess = .fullAccess)
        -> (service: CalendarSyncService, gateway: FakeGateway,
            linkStore: ExternalEventLinkStore) {
        let gateway = FakeGateway()
        gateway.grantRequestResult = grant
        gateway.access = access
        let linkStore = ExternalEventLinkStore()
        let service = CalendarSyncService(gateway: gateway, linkStore: linkStore,
                                          observabilityBus: MockObservabilityBus(),
                                          now: { [weak self] in self?.fakeNow ?? Date() })
        return (service, gateway, linkStore)
    }

    override func setUp() {
        super.setUp()
        // Intent + status + two-way mode + links all persist in
        // UserDefaults and restore in init — clean slate per test, or
        // the order tests run would decide their outcome.
        UserDefaults.standard.removeObject(forKey: "calendarSync.enabled")
        UserDefaults.standard.removeObject(forKey: "calendarSync.status")
        UserDefaults.standard.removeObject(forKey: "calendarSync.twoWayEnabled")
        UserDefaults.standard.removeObject(forKey: ExternalEventLinkStore.linksDefaultsKey)
        UserDefaults.standard.removeObject(forKey: ExternalEventLinkStore.sahayakCalendarDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "calendarSync.enabled")
        UserDefaults.standard.removeObject(forKey: "calendarSync.status")
        UserDefaults.standard.removeObject(forKey: "calendarSync.twoWayEnabled")
        UserDefaults.standard.removeObject(forKey: ExternalEventLinkStore.linksDefaultsKey)
        UserDefaults.standard.removeObject(forKey: ExternalEventLinkStore.sahayakCalendarDefaultsKey)
        super.tearDown()
    }

    // MARK: - Two-way decision matrix (pure, 2026-09-07)

    func testTwoWaySyncDecisionMatrix() {
        // Off is idle whatever the OS allows.
        XCTAssertEqual(CalendarSyncService.twoWaySyncDecision(
            eventsAccess: .fullAccess, twoWayEnabled: false), .idle)
        XCTAssertEqual(CalendarSyncService.twoWaySyncDecision(
            eventsAccess: .denied, twoWayEnabled: false), .idle)
        // Full access is the ONLY state that can actually reconcile.
        XCTAssertEqual(CalendarSyncService.twoWaySyncDecision(
            eventsAccess: .fullAccess, twoWayEnabled: true), .sync)
        // writeOnly can WRITE mirrors but cannot READ them back — never
        // enough for two-way; the card offers the full-access prompt.
        XCTAssertEqual(CalendarSyncService.twoWaySyncDecision(
            eventsAccess: .writeOnly, twoWayEnabled: true), .needsFullAccessPrompt)
        XCTAssertEqual(CalendarSyncService.twoWaySyncDecision(
            eventsAccess: .notDetermined, twoWayEnabled: true), .needsFullAccessPrompt)
        // Denied/restricted: honest caption, no sync.
        XCTAssertEqual(CalendarSyncService.twoWaySyncDecision(
            eventsAccess: .denied, twoWayEnabled: true), .unavailable)
        XCTAssertEqual(CalendarSyncService.twoWaySyncDecision(
            eventsAccess: .restricted, twoWayEnabled: true), .unavailable)
    }

    // MARK: - Link store + token (pure, 2026-09-07)

    func testLinkStoreRoundTripPruneAndClear() {
        let entryId = UUID()
        let key0 = ExternalEventLinkStore.appKey(entryId: entryId, slot: 0)
        let key1 = ExternalEventLinkStore.appKey(entryId: entryId, slot: 1)
        let store = ExternalEventLinkStore()
        XCTAssertTrue(store.isEmpty)

        store.set(identifier: "evt-1", for: key0)
        store.set(identifier: "evt-2", for: key1)
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.identifier(for: key0), "evt-1")
        XCTAssertTrue(store.hasLink(for: key1))

        XCTAssertEqual(store.prune(keeping: [key0]), 1)
        XCTAssertNil(store.identifier(for: key1))
        XCTAssertEqual(store.identifier(for: key0), "evt-1")

        store.removeLinks(for: entryId)
        XCTAssertTrue(store.isEmpty)
        store.set(identifier: "x", for: key0)
        store.clear()
        XCTAssertTrue(store.isEmpty)
    }

    func testLinkStoreRemembersSahayakCalendarIdentifier() {
        let store = ExternalEventLinkStore()
        XCTAssertNil(store.sahayakCalendarIdentifier)

        store.sahayakCalendarIdentifier = "sahayak-9"
        XCTAssertEqual(store.sahayakCalendarIdentifier, "sahayak-9")
        XCTAssertEqual(ExternalEventLinkStore().sahayakCalendarIdentifier, "sahayak-9",
                       "the id must survive a fresh store instance (UserDefaults-backed)")

        store.sahayakCalendarIdentifier = nil
        XCTAssertNil(store.sahayakCalendarIdentifier)
    }

    func testAppKeyPartsRoundTripAndRejectsForeignKeys() {
        let entryId = UUID()
        let key = ExternalEventLinkStore.appKey(entryId: entryId, slot: 3)
        let parts = ExternalEventLinkStore.appKeyParts(key)
        XCTAssertEqual(parts?.entryId, entryId)
        XCTAssertEqual(parts?.slot, 3)

        XCTAssertNil(ExternalEventLinkStore.appKeyParts("entry:\(entryId.uuidString)"),
                     "missing slot is not one of ours")
        XCTAssertNil(ExternalEventLinkStore.appKeyParts("entry:not-a-uuid:0"))
        XCTAssertNil(ExternalEventLinkStore.appKeyParts("other:\(entryId.uuidString):0"))
        XCTAssertNil(ExternalEventLinkStore.appKeyParts("entry:\(entryId.uuidString):-1"))
    }

    func testMirrorLinkTokenNotesAndParseRoundTrip() {
        let entryId = UUID()
        let notes = MirrorLinkToken.notes(entryId: entryId, slot: 2)
        XCTAssertTrue(notes.hasPrefix(CalendarSyncService.mirrorTag),
                      "the mirror tag stays the first line — legacy wipes and import exclusion catch token events too")

        let parsed = MirrorLinkToken.parse(notes)
        XCTAssertEqual(parsed?.entryId, entryId)
        XCTAssertEqual(parsed?.slot, 2)

        XCTAssertNil(MirrorLinkToken.parse(nil))
        XCTAssertNil(MirrorLinkToken.parse(CalendarSyncService.mirrorTag),
                     "fragment-only legacy notes carry no token")
        XCTAssertNil(MirrorLinkToken.parse("\(CalendarSyncService.mirrorTag)\nentry=broken\nslot=0"),
                     "a garbled hand edit must fail the whole parse, never half-match")
    }

    // MARK: - planNativeMutations (pure, 2026-09-07)

    func testNativeRetimeWhenRecordMovesTime() {
        let entryId = UUID()
        let entries = [entry(id: entryId, name: "Walk", hours: [11])]
        let links = [ExternalEventLinkStore.appKey(entryId: entryId, slot: 0): "evt-1"]
        // The family moved the 11:00 event to 14:00.
        let records = [record(id: "evt-1", entryId: entryId, slot: 0, hour: 14)]

        let mutations = CalendarSyncService.planNativeMutations(
            entries: entries, records: records, links: links)

        XCTAssertEqual(mutations, [.retimeSlot(entryId: entryId, fromHour: 11,
                                               fromMinute: 0, toHour: 14, toMinute: 0)])
    }

    func testNativeDropSlotWhenItsEventWasDeleted() {
        let entryId = UUID()
        let entries = [entry(id: entryId, name: "Walk", hours: [11, 16])]
        // Both slots were mirrored; the family deleted only the 16:00 event.
        let links = [ExternalEventLinkStore.appKey(entryId: entryId, slot: 0): "evt-1",
                     ExternalEventLinkStore.appKey(entryId: entryId, slot: 1): "evt-2"]
        let records = [record(id: "evt-1", entryId: entryId, slot: 0, hour: 11)]

        let mutations = CalendarSyncService.planNativeMutations(
            entries: entries, records: records, links: links)

        XCTAssertEqual(mutations, [.dropSlot(entryId: entryId, hour: 16, minute: 0)])
    }

    func testNativeDisableEntryWhenWholePresenceVanished() {
        let entryId = UUID()
        let entries = [entry(id: entryId, name: "Walk", hours: [11])]
        let links = [ExternalEventLinkStore.appKey(entryId: entryId, slot: 0): "evt-1"]

        let mutations = CalendarSyncService.planNativeMutations(
            entries: entries, records: [], links: links)

        XCTAssertEqual(mutations, [.disableEntry(entryId: entryId)])
    }

    func testNativeDisabledEntryIsNeverResurrected() {
        let entryId = UUID()
        // Disabled app-side (mirroring writes nothing for it), yet a
        // stale native event still exists — nothing may re-enable it.
        let entries = [entry(id: entryId, name: "Walk", hours: [11], enabled: false)]
        let links = [ExternalEventLinkStore.appKey(entryId: entryId, slot: 0): "evt-1"]
        let records = [record(id: "evt-1", entryId: entryId, slot: 0, hour: 11)]

        let mutations = CalendarSyncService.planNativeMutations(
            entries: entries, records: records, links: links)

        XCTAssertTrue(mutations.isEmpty,
                      "a disabled entry mirrors nothing and must never be brought back by a native event")
    }

    func testNativeNoOpsWhenShapesAreEqual() {
        let entryId = UUID()
        let entries = [entry(id: entryId, name: "Walk", hours: [11])]
        let links = [ExternalEventLinkStore.appKey(entryId: entryId, slot: 0): "evt-1"]
        let records = [record(id: "evt-1", entryId: entryId, slot: 0, hour: 11,
                              title: "Family renamed me")]

        let mutations = CalendarSyncService.planNativeMutations(
            entries: entries, records: records, links: links)

        XCTAssertTrue(mutations.isEmpty,
                      "time + recurrence match — a title edit is cosmetic and changes nothing app-side")
    }

    func testNativeWeeklyToDailyAndDailyToWeeklyRecurrence() {
        let entryId = UUID()
        // App says weekly [Mon, Wed]; the family edited the event to daily.
        let weeklyEntry = entry(id: entryId, name: "Walk", hours: [11],
                                frequency: .weekly, weekdays: [2, 4])
        let links = [ExternalEventLinkStore.appKey(entryId: entryId, slot: 0): "evt-1"]
        let records = [record(id: "evt-1", entryId: entryId, slot: 0, hour: 11,
                              recurrence: .daily)]
        let toDaily = CalendarSyncService.planNativeMutations(
            entries: [weeklyEntry], records: records, links: links)
        XCTAssertEqual(toDaily, [.setRecurrence(entryId: entryId,
                                                frequency: .daily, weekdays: [])])

        // And the reverse: app daily, family made the event weekly.
        let dailyEntry = entry(id: entryId, name: "Walk", hours: [11])
        let weeklyRecords = [record(id: "evt-1", entryId: entryId, slot: 0, hour: 11,
                                    recurrence: .weekly(weekdays: [1, 5]))]
        let toWeekly = CalendarSyncService.planNativeMutations(
            entries: [dailyEntry], records: weeklyRecords, links: links)
        XCTAssertEqual(toWeekly, [.setRecurrence(entryId: entryId,
                                                 frequency: .weekly, weekdays: [1, 5])])
    }

    func testNativeDailyEqualsWeeklyOnAllSevenDays() {
        let entryId = UUID()
        let entries = [entry(id: entryId, name: "Walk", hours: [11])]
        let links = [ExternalEventLinkStore.appKey(entryId: entryId, slot: 0): "evt-1"]
        // EventKit spells "every day" as a weekly rule on all 7 days —
        // the app's daily entry is the same shape.
        let records = [record(id: "evt-1", entryId: entryId, slot: 0, hour: 11,
                              recurrence: .weekly(weekdays: Array(1...7)))]

        let mutations = CalendarSyncService.planNativeMutations(
            entries: entries, records: records, links: links)
        XCTAssertTrue(mutations.isEmpty)
    }

    func testNativeAllDayFamilyShapeIsLeftEntirelyAlone() {
        let entryId = UUID()
        let entries = [entry(id: entryId, name: "Walk", hours: [11])]
        let links = [ExternalEventLinkStore.appKey(entryId: entryId, slot: 0): "evt-1"]
        // The family made our mirrored event all-day on purpose — the
        // app cannot express that and must neither retime nor fight it.
        let records = [record(id: "evt-1", entryId: entryId, slot: 0, hour: 0,
                              isAllDay: true)]

        let mutations = CalendarSyncService.planNativeMutations(
            entries: entries, records: records, links: links)
        XCTAssertTrue(mutations.isEmpty,
                      "an all-day token record counts as LIVE (no drop/disable) but plans no retime")
    }

    func testNativeForeignAndUnknownRecordsAreIgnored() {
        let entryId = UUID()
        let otherEntry = UUID()
        let entries = [entry(id: entryId, name: "Walk", hours: [11])]
        let links = [ExternalEventLinkStore.appKey(entryId: entryId, slot: 0): "evt-1"]
        let records = [
            // The walk's own live mirror record — unchanged shape, so
            // the plan stays silent about it (without it the entry's
            // ENTIRE native presence is gone and rule 4 disables it).
            record(id: "evt-1", entryId: entryId, slot: 0, hour: 11),
            // No fragment — the family's own event.
            CalendarEventRecord(eventIdentifier: "family-1", calendarIdentifier: "family-cal",
                                title: "Doctor", notes: nil, startDate: time(11),
                                isAllDay: false, isCanceled: false, recurrence: .daily),
            // Our token, but for an entry this plan does not know.
            record(id: "ghost", entryId: otherEntry, slot: 0, hour: 11)
        ]

        let mutations = CalendarSyncService.planNativeMutations(
            entries: entries, records: records, links: links)
        XCTAssertTrue(mutations.isEmpty,
                      "foreign events and unknown-entry tokens are never planned against")
    }

    func testNativeCanceledRecordCountsAsGone() {
        let entryId = UUID()
        let entries = [entry(id: entryId, name: "Walk", hours: [11])]
        let links = [ExternalEventLinkStore.appKey(entryId: entryId, slot: 0): "evt-1"]
        let records = [record(id: "evt-1", entryId: entryId, slot: 0, hour: 11,
                              isCanceled: true)]

        let mutations = CalendarSyncService.planNativeMutations(
            entries: entries, records: records, links: links)
        XCTAssertEqual(mutations, [.disableEntry(entryId: entryId)],
                       "a canceled mirror event behaves as deleted — the entry has no live presence")
    }

    // MARK: - planMirrorOperations (pure, 2026-09-07)

    func testMirrorCreatesMissingTokenEventsWithNextStartDrafts() {
        let entryId = UUID()
        let morning = entry(id: entryId, name: "Walk", category: .exercise,
                            hours: [11])
        // Slot at 07:00 — already past 10:00, so the draft anchors
        // tomorrow (the legacy writer's nextDate(.nextTime) semantics).
        let past = entry(id: UUID(), name: "Pills", category: .medication, hours: [7])

        let operations = CalendarSyncService.planMirrorOperations(
            entries: [morning, past], records: [], now: fakeNow)

        XCTAssertEqual(operations.count, 2)
        guard case .create(let appKey0, let draft0)? = operations.first(where: {
            if case .create(let key, _) = $0 { return key == ExternalEventLinkStore.appKey(entryId: entryId, slot: 0) }
            return false
        }) else {
            XCTFail("expected a create for the 11:00 slot")
            return
        }
        XCTAssertEqual(draft0.title, mirrorTitle(for: morning))
        XCTAssertEqual(draft0.notes, MirrorLinkToken.notes(entryId: entryId, slot: 0))
        XCTAssertEqual(draft0.durationMinutes, 30)
        XCTAssertEqual(draft0.recurrence, .daily)
        XCTAssertEqual(draft0.startDate, time(11), "11:00 is still ahead of the 10:00 clock — today")
        XCTAssertEqual(appKey0, ExternalEventLinkStore.appKey(entryId: entryId, slot: 0))

        guard case .create(_, let pastDraft)? = operations.first(where: {
            if case .create(let key, _) = $0,
               ExternalEventLinkStore.appKeyParts(key)?.entryId != entryId { return true }
            return false
        }) else {
            XCTFail("expected a create for the 07:00 slot")
            return
        }
        XCTAssertEqual(pastDraft.startDate, time(7, dayOffset: 1),
                       "a slot time already past anchors on the next matching day")
    }

    func testMirrorNoOpsWhenRecordMatchesEntry() {
        let entryId = UUID()
        let entries = [entry(id: entryId, name: "Walk", hours: [11])]
        let records = [record(id: "evt-1", entryId: entryId, slot: 0, hour: 11)]

        let operations = CalendarSyncService.planMirrorOperations(
            entries: entries, records: records, now: fakeNow)
        XCTAssertTrue(operations.isEmpty,
                      "equal shapes converge to silence — this is what stops a write-back fight")
    }

    func testMirrorUpdatesOnTimeMismatch() {
        let entryId = UUID()
        let entries = [entry(id: entryId, name: "Walk", hours: [11])]
        let records = [record(id: "evt-1", entryId: entryId, slot: 0, hour: 12)]

        let operations = CalendarSyncService.planMirrorOperations(
            entries: entries, records: records, now: fakeNow)

        XCTAssertEqual(operations.count, 1)
        guard case .update(let identifier, let draft)? = operations.first else {
            XCTFail("expected an update, got \(operations)")
            return
        }
        XCTAssertEqual(identifier, "evt-1")
        XCTAssertEqual(draft.startDate, time(11), "the app's time wins app-side — the mirror is corrected back")
        XCTAssertEqual(draft.title, mirrorTitle(for: entries[0]))
    }

    func testMirrorUpdatesOnRecurrenceMismatch() {
        let entryId = UUID()
        let entries = [entry(id: entryId, name: "Walk", hours: [11],
                             frequency: .weekly, weekdays: [2, 4])]
        let records = [record(id: "evt-1", entryId: entryId, slot: 0, hour: 11,
                              recurrence: .daily)]

        let operations = CalendarSyncService.planMirrorOperations(
            entries: entries, records: records, now: fakeNow)

        XCTAssertEqual(operations.count, 1)
        guard case .update(_, let draft)? = operations.first else {
            XCTFail("expected an update, got \(operations)")
            return
        }
        XCTAssertEqual(draft.recurrence, .weekly(weekdays: [2, 4]))
        XCTAssertGreaterThan(draft.startDate, fakeNow,
                             "the rewrite anchors on the next matching weekday occurrence")
    }

    func testMirrorRemovesEventsOfDisabledOrRemovedEntries() {
        let entryId = UUID()
        // Disabled app-side — its native mirror events must go.
        let disabled = entry(id: entryId, name: "Walk", hours: [11], enabled: false)
        let records = [record(id: "evt-1", entryId: entryId, slot: 0, hour: 11)]

        let operations = CalendarSyncService.planMirrorOperations(
            entries: [disabled], records: records, now: fakeNow)
        XCTAssertEqual(operations, [.remove(eventIdentifier: "evt-1")])

        // Removed outright (not even in the entries list) — same result.
        let absent = CalendarSyncService.planMirrorOperations(
            entries: [], records: records, now: fakeNow)
        XCTAssertEqual(absent, [.remove(eventIdentifier: "evt-1")])
    }

    func testMirrorRemovesFragmentOnlyLegacyOrphans() {
        let entryId = UUID()
        let entries = [entry(id: entryId, name: "Walk", hours: [11])]
        let records = [
            // A one-way mirror event from before two-way mode — the
            // fragment without a token marks it as a rebuild orphan.
            record(id: "legacy-1", entryId: entryId, slot: 0, hour: 11,
                   notes: CalendarSyncService.mirrorTag),
            // The family's own event — no fragment, never touched.
            CalendarEventRecord(eventIdentifier: "family-1", calendarIdentifier: "family-cal",
                                title: "Doctor", notes: nil, startDate: time(12),
                                isAllDay: false, isCanceled: false, recurrence: .daily)
        ]

        let operations = CalendarSyncService.planMirrorOperations(
            entries: entries, records: records, now: fakeNow)

        XCTAssertEqual(operations, [.create(appKey: ExternalEventLinkStore.appKey(entryId: entryId, slot: 0),
                                            draft: CalendarEventDraft(
                                                title: mirrorTitle(for: entries[0]),
                                                notes: MirrorLinkToken.notes(entryId: entryId, slot: 0),
                                                startDate: time(11),
                                                recurrence: .daily)),
                                    .remove(eventIdentifier: "legacy-1")],
                       "the token'd replacement is created and the fragment-only orphan removed; the family event is untouched")
    }

    func testMirrorNeverOverwritesUnrepresentableFamilyShapes() {
        let entryId = UUID()
        let entries = [entry(id: entryId, name: "Walk", hours: [11])]
        let records = [
            record(id: "allday-1", entryId: entryId, slot: 0, hour: 0, isAllDay: true),
            // Monthly recurrence → nil in app terms — same rule.
            record(id: "monthly-1", entryId: entryId, slot: 1, hour: 11,
                   recurrence: nil)
        ]
        // The entry only has one slot in reality; give it two so both
        // keys are desired and the family shapes must be respected.
        let twoSlot = entry(id: entryId, name: "Walk", hours: [11, 16])

        let operations = CalendarSyncService.planMirrorOperations(
            entries: [twoSlot], records: records, now: fakeNow)

        XCTAssertTrue(operations.isEmpty,
                      "the family re-shaped our events (all-day / monthly) — the app writes nothing over them")
    }

    // MARK: - Medication mirrors (rich-events task, 2026-09-17)

    /// A medication with one schedule time per `(hour, minute)` pair —
    /// the same daily-frequency record the medication store holds.
    private func medEntry(id: UUID = UUID(), name: String = "Amlodipine",
                          times: [(hour: Int, minute: Int)] = [(8, 0)]) -> MedicationEntry {
        MedicationEntry(
            id: id, userProfileId: UUID(), medicationName: name,
            doseDescription: "One tablet",
            scheduleTimes: times.map { DateComponents(hour: $0.hour, minute: $0.minute) },
            frequency: .daily, ackWindowMinutes: 5, maxRefireCount: 5,
            escalationWindowMinutes: 60, doubleDoseWindowHours: 4,
            photoVerificationEnabled: false, confirmationDescription: nil)
    }

    /// A medication mirror record — `notes` carry the `kind=medication`
    /// token, which is what makes it this planner's business and not the
    /// routine planner's.
    private func medRecord(id: String = "med-evt-x", entryId: UUID, slot: Int,
                           hour: Int, minute: Int = 0, dayOffset: Int = 0,
                           title: String = "Amlodipine",
                           recurrence: EventRecurrence? = .daily,
                           isAllDay: Bool = false,
                           isCanceled: Bool = false) -> CalendarEventRecord {
        CalendarEventRecord(
            eventIdentifier: id,
            calendarIdentifier: "sahayak-1",
            title: title,
            notes: MirrorLinkToken.notes(entryId: entryId, slot: slot,
                                         kind: .medication),
            startDate: time(hour, minute: minute, dayOffset: dayOffset),
            isAllDay: isAllDay,
            isCanceled: isCanceled,
            recurrence: recurrence
        )
    }

    private func medKey(_ entryId: UUID, slot: Int = 0) -> String {
        ExternalEventLinkStore.appKey(kind: .medication, entryId: entryId, slot: slot)
    }

    /// One recurring daily event per schedule time, in the Sahayak
    /// calendar, titled with the bare medication name — the same label
    /// the Google twin shows, so the family reads one name on both
    /// calendars.
    func testMedicationMirrorCreatesOneDailyEventPerScheduleTime() {
        let medId = UUID()
        let med = medEntry(id: medId, name: "Metformin",
                           times: [(8, 0), (20, 30)])

        let operations = CalendarSyncService.planMedicationMirrorOperations(
            medications: [med], records: [], now: fakeNow)

        XCTAssertEqual(operations, [
            .create(appKey: medKey(medId, slot: 0),
                    draft: CalendarEventDraft(
                        title: "Metformin",
                        notes: MirrorLinkToken.notes(entryId: medId, slot: 0,
                                                     kind: .medication),
                        startDate: time(8, dayOffset: 1),
                        recurrence: .daily)),
            .create(appKey: medKey(medId, slot: 1),
                    draft: CalendarEventDraft(
                        title: "Metformin",
                        notes: MirrorLinkToken.notes(entryId: medId, slot: 1,
                                                     kind: .medication),
                        startDate: time(20, minute: 30),
                        recurrence: .daily))
        ], "08:00 has passed the 10:00 clock → tomorrow; 20:30 is still ahead → today")
    }

    func testMedicationMirrorIsSilentWhenTheRecordMatches() {
        let medId = UUID()
        let records = [medRecord(entryId: medId, slot: 0, hour: 8, dayOffset: 1)]

        let operations = CalendarSyncService.planMedicationMirrorOperations(
            medications: [medEntry(id: medId, times: [(8, 0)])],
            records: records, now: fakeNow)

        XCTAssertTrue(operations.isEmpty,
                      "equal shapes converge to silence — no write-back fight")
    }

    func testMedicationMirrorUpdatesWhenTheTimeOrRuleDrifted() {
        let medId = UUID()
        // Same slot, but the native event sits at 08:30 and carries no
        // rule (a one-off the family created by hand off our mirror).
        let retimed = medRecord(id: "med-1", entryId: medId, slot: 0, hour: 8,
                                minute: 30, recurrence: nil)

        let operations = CalendarSyncService.planMedicationMirrorOperations(
            medications: [medEntry(id: medId, times: [(8, 0)])],
            records: [retimed], now: fakeNow)

        XCTAssertEqual(operations, [
            .update(eventIdentifier: "med-1",
                    draft: CalendarEventDraft(
                        title: "Amlodipine",
                        notes: MirrorLinkToken.notes(entryId: medId, slot: 0,
                                                     kind: .medication),
                        startDate: time(8, dayOffset: 1),
                        recurrence: .daily))
        ], "the app-side time is authoritative for its own mirror")
    }

    /// Rule 3: a shape the medication model cannot express (all-day, or
    /// a weekly rule) belongs to the family — never written over, in
    /// either direction.
    func testMedicationMirrorNeverOverwritesFamilyShapes() {
        let medId = UUID()
        let records = [
            medRecord(id: "allday-1", entryId: medId, slot: 0, hour: 0, isAllDay: true),
            medRecord(id: "weekly-1", entryId: medId, slot: 1, hour: 8,
                      recurrence: .weekly(weekdays: [2]))
        ]

        let operations = CalendarSyncService.planMedicationMirrorOperations(
            medications: [medEntry(id: medId, times: [(8, 0), (8, 0)])],
            records: records, now: fakeNow)

        XCTAssertTrue(operations.isEmpty,
                      "re-shaped by the family → the app writes nothing over them, "
                      + "and both slots are still desired so nothing is removed either")
    }

    func testMedicationMirrorRemovesEventsWhoseSlotIsGone() {
        let medId = UUID()
        let records = [
            medRecord(id: "med-0", entryId: medId, slot: 0, hour: 8, dayOffset: 1),
            medRecord(id: "med-1", entryId: medId, slot: 1, hour: 20)
        ]
        // The caregiver dropped the evening dose.
        let med = medEntry(id: medId, times: [(8, 0)])

        let operations = CalendarSyncService.planMedicationMirrorOperations(
            medications: [med], records: records, now: fakeNow)

        XCTAssertEqual(operations, [.remove(eventIdentifier: "med-1")])
    }

    func testMedicationMirrorIgnoresRoutineTokensAndRecreatesCanceledOnes() {
        let medId = UUID()
        let routineId = UUID()
        let records = [
            // A routine mirror — not this planner's business.
            record(id: "routine-1", entryId: routineId, slot: 0, hour: 8),
            // A canceled medication mirror behaves as deleted.
            medRecord(id: "med-canceled", entryId: medId, slot: 0, hour: 8,
                      dayOffset: 1, isCanceled: true)
        ]

        let operations = CalendarSyncService.planMedicationMirrorOperations(
            medications: [medEntry(id: medId, times: [(8, 0)])],
            records: records, now: fakeNow)

        XCTAssertEqual(operations, [
            .create(appKey: medKey(medId, slot: 0),
                    draft: CalendarEventDraft(
                        title: "Amlodipine",
                        notes: MirrorLinkToken.notes(entryId: medId, slot: 0,
                                                     kind: .medication),
                        startDate: time(8, dayOffset: 1),
                        recurrence: .daily))
        ])
    }

    // MARK: - Medication mutations (family edits flowing back)

    /// Rule 1: the family retimed our mirror → the entry takes their
    /// time. The mirror is the family's calendar view of the dose, so a
    /// retime there IS the new dose time.
    func testFamilyRetimeBecomesTheMedicationScheduleTime() {
        let medId = UUID()
        let records = [medRecord(entryId: medId, slot: 0, hour: 8, minute: 30)]
        let links = [medKey(medId, slot: 0): "med-1"]

        let mutations = CalendarSyncService.planMedicationMutations(
            medications: [medEntry(id: medId, times: [(8, 0)])],
            records: records, links: links)

        XCTAssertEqual(mutations, [.setScheduleTimes(
            entryId: medId, times: [DateComponents(hour: 8, minute: 30)])])
    }

    /// Rule 2: the family deleted the mirror → that time is dropped. The
    /// medication itself is never destroyed by a calendar edit — an
    /// empty schedule is a real outcome.
    func testFamilyDeleteDropsTheTimeAndNeverResurrectsIt() {
        let medId = UUID()
        let links = [medKey(medId, slot: 0): "med-1", medKey(medId, slot: 1): "med-2"]
        // Only slot 1 still has a live record.
        let records = [medRecord(id: "med-2", entryId: medId, slot: 1, hour: 20)]
        let med = medEntry(id: medId, times: [(8, 0), (20, 0)])

        let mutations = CalendarSyncService.planMedicationMutations(
            medications: [med], records: records, links: links)

        XCTAssertEqual(mutations, [.setScheduleTimes(
            entryId: medId, times: [DateComponents(hour: 20, minute: 0)])],
                       "the deleted 08:00 dose stays deleted — the link is what "
                       + "remembers it was ever mirrored")
    }

    func testEveryDoseDeletedLeavesAnEmptyScheduleNotADeletedMedication() {
        let medId = UUID()
        let links = [medKey(medId, slot: 0): "med-1"]

        let mutations = CalendarSyncService.planMedicationMutations(
            medications: [medEntry(id: medId, times: [(8, 0)])],
            records: [], links: links)

        XCTAssertEqual(mutations, [.setScheduleTimes(entryId: medId, times: [])],
                       "the entry keeps existing with no doses armed; the family's "
                       + "medication record is never destroyed by a calendar edit")
    }

    /// Rule 3 in the other direction: a family-owned shape proves the
    /// slot EXISTS (so it is not read as deleted) but its time is not
    /// the app's to copy.
    func testFamilyShapesAreNeitherCopiedNorTreatedAsDeleted() {
        let medId = UUID()
        let records = [
            medRecord(id: "allday-1", entryId: medId, slot: 0, hour: 0, isAllDay: true),
            medRecord(id: "weekly-1", entryId: medId, slot: 1, hour: 8,
                      minute: 15, recurrence: .weekly(weekdays: [2]))
        ]
        let links = [medKey(medId, slot: 0): "allday-1",
                     medKey(medId, slot: 1): "weekly-1"]

        let mutations = CalendarSyncService.planMedicationMutations(
            medications: [medEntry(id: medId, times: [(8, 0), (8, 0)])],
            records: records, links: links)

        XCTAssertTrue(mutations.isEmpty,
                      "no retime copied, and no slot dropped — the family owns these")
    }

    /// The link store plus the records are the only inputs: an entry with
    /// no links at all (never mirrored, or pruned) is left exactly as
    /// the app decided it.
    func testUnlinkedTimesAreNeverMutated() {
        let medId = UUID()
        let records = [medRecord(entryId: medId, slot: 0, hour: 8, minute: 30)]

        let mutations = CalendarSyncService.planMedicationMutations(
            medications: [medEntry(id: medId, times: [(8, 0)])],
            records: records, links: [:])

        XCTAssertTrue(mutations.isEmpty,
                      "no link → the app's own time, untouched (the record belongs "
                      + "to someone else's slot)")
    }

    func testRoutineLinksDoNotDriveMedicationMutations() {
        let medId = UUID()
        let records = [medRecord(entryId: medId, slot: 0, hour: 8, minute: 30)]
        // A routine-kind link whose slot number happens to match.
        let links = [ExternalEventLinkStore.appKey(entryId: medId, slot: 0): "med-1"]

        let mutations = CalendarSyncService.planMedicationMutations(
            medications: [medEntry(id: medId, times: [(8, 0)])],
            records: records, links: links)

        XCTAssertTrue(mutations.isEmpty,
                      "only medication-kind links are this planner's business")
    }

    // MARK: - The token and key that carry it

    func testMedicationTokenAndKeyRoundTripAndStayDistinctFromRoutines() {
        let medId = UUID()
        let notes = MirrorLinkToken.notes(entryId: medId, slot: 3, kind: .medication)

        XCTAssertTrue(notes.hasPrefix(CalendarSyncService.mirrorTag),
                      "the mirror tag must stay the first line — the import filter "
                      + "and the legacy wipe match on it")
        XCTAssertTrue(notes.contains("kind=medication"))
        let parsed = MirrorLinkToken.parse(notes)
        XCTAssertEqual(parsed?.kind, .medication)
        XCTAssertEqual(parsed?.entryId, medId)
        XCTAssertEqual(parsed?.slot, 3)

        // A routine token is byte-identical to what shipped before the
        // medication kind existed (no kind= line), and reads back routine.
        let routineNotes = MirrorLinkToken.notes(entryId: medId, slot: 0)
        XCTAssertFalse(routineNotes.contains("kind="),
                       "an extra line here would make old notes unparseable as routines")
        XCTAssertEqual(MirrorLinkToken.parse(routineNotes)?.kind, .routine)

        // The keys are namespaced, so a routine slot 0 and a medication
        // slot 0 for the same UUID can never collide.
        XCTAssertEqual(medKey(medId, slot: 0), "med:\(medId.uuidString):0")
        XCTAssertEqual(ExternalEventLinkStore.appKey(entryId: medId, slot: 0),
                       "entry:\(medId.uuidString):0")
        XCTAssertEqual(ExternalEventLinkStore.appKeyParts(medKey(medId, slot: 2))?.kind,
                       .medication)
        XCTAssertNil(ExternalEventLinkStore.appKeyParts("nonsense"))
    }

    /// A garbled token fails the parse outright — it must never be
    /// adopted as a routine mirror (the routine planner would look up a
    /// medication's UUID among the routine entries, find nothing, and
    /// leave an orphan neither planner cleans up).
    func testAnUnknownKindGarblesTheTokenRatherThanFallingBackToRoutine() {
        let medId = UUID()
        let notes = """
            \(CalendarSyncService.mirrorTag)
            entry=\(medId.uuidString)
            slot=0
            kind=inhaler
            """
        XCTAssertNil(MirrorLinkToken.parse(notes))

        let operations = CalendarSyncService.planMedicationMirrorOperations(
            medications: [medEntry(id: medId, times: [(8, 0)])],
            records: [CalendarEventRecord(
                eventIdentifier: "orphan", calendarIdentifier: "sahayak-1",
                title: "?", notes: notes, startDate: time(8, dayOffset: 1),
                isAllDay: false, isCanceled: false, recurrence: .daily)],
            now: fakeNow)

        XCTAssertEqual(operations, [
            .create(appKey: medKey(medId, slot: 0),
                    draft: CalendarEventDraft(
                        title: "Amlodipine",
                        notes: MirrorLinkToken.notes(entryId: medId, slot: 0,
                                                     kind: .medication),
                        startDate: time(8, dayOffset: 1),
                        recurrence: .daily))
        ], "the unreadable record resolves to neither kind, so the slot reads "
           + "as unmapped rather than as the family's answer")
    }

    // MARK: - Service: permission + legacy mirror (ported behaviour)

    func testPermissionDeniedSetsDeniedStatusAndMirrorsNothing() async {
        let (service, gateway, _) = makeService(grant: false, access: .denied)
        service.isEnabled = true
        await service.enableAndSync(entries: [entry(name: "खाना", category: .medication,
                                                    hours: [8])])
        XCTAssertEqual(service.status, .denied)
        XCTAssertTrue(gateway.created.isEmpty,
                      "denied permission must mirror nothing — local-only mode, no partial state")
        XCTAssertEqual(gateway.fullAccessRequests, 1)
    }

    func testWriteOnlyGrantStillMirrorsLegacyOneWay() async {
        // iOS 17 write-only access CAN write mirror events — the one-way
        // mirror is fully usable; only two-way needs read access.
        let (service, gateway, _) = makeService(grant: true, access: .writeOnly)
        service.isEnabled = true
        let व्यायाम = RoutineEntry(category: .exercise, titleOverride: "व्यायाम",
                                   scheduleTimes: [DateComponents(hour: 7, minute: 30)],
                                   isEnabled: true)
        let औषधि = RoutineEntry(category: .medication, titleOverride: "औषधि",
                                scheduleTimes: [DateComponents(hour: 8, minute: 0)],
                                isEnabled: true)
        await service.enableAndSync(entries: [व्यायाम, औषधि])
        XCTAssertEqual(service.status, .enabled)
        XCTAssertEqual(gateway.created.count, 2)
        XCTAssertEqual(gateway.created.map { $0.draft.title }.sorted(),
                       ["औषधि (औषधि)", "व्यायाम (व्यायाम)"].sorted(),
                       "each mirrored event is titled with the entry name + its routine category label")
        XCTAssertTrue(gateway.created.allSatisfy { $0.calendarIdentifier == nil },
                      "the one-way mirror writes to the DEFAULT calendar")
        XCTAssertEqual(gateway.created.first?.draft.notes, CalendarSyncService.mirrorTag)
        XCTAssertEqual(service.twoWayEnabled, false)
    }

    func testSyncNowIsANoOpWhenNotEnabled() {
        let (service, gateway, _) = makeService()
        // isEnabled defaults false, status notRequested.
        service.syncNow(entries: [entry(name: "x", hours: [9])])
        XCTAssertTrue(gateway.created.isEmpty)
        XCTAssertTrue(gateway.fragmentRemovalRequests.isEmpty)
    }

    func testLegacyRebuildRemovesOnlyMirrorEvents() async {
        let (service, gateway, _) = makeService()
        service.isEnabled = true
        gateway.records = [
            CalendarEventRecord(eventIdentifier: "own-1", calendarIdentifier: "family",
                                title: "user's own event", notes: nil,
                                startDate: time(12), isAllDay: false,
                                isCanceled: false, recurrence: nil),
            record(id: "old-mirror", entryId: UUID(), slot: 0, hour: 9,
                   notes: CalendarSyncService.mirrorTag)
        ]
        await service.enableAndSync(entries: [entry(name: "new", hours: [10])])
        XCTAssertEqual(gateway.lastFragmentRemovalCount, 1,
                       "rebuild removes only our mirrored events, never the user's own")
        XCTAssertEqual(gateway.records.count, 2,
                       "the user's event survives; the fresh legacy mirror joins it")
        XCTAssertEqual(gateway.created.map { $0.draft.title },
                       [mirrorTitle(for: entry(name: "new", hours: [10]))])
    }

    // MARK: - Two-way service flows (2026-09-07)

    func testEnableTwoWayRevertsIntentWhenFullAccessIsDenied() async {
        // writeOnly grant: the legacy mirror stays usable, but two-way
        // cannot read — the intent reverts to OFF with an honest status.
        let (service, gateway, _) = makeService(grant: true, access: .writeOnly)
        service.isEnabled = true
        await service.enableAndSync(entries: [])
        let legacyCreated = gateway.created.count

        await service.enableTwoWayAndSync(entries: [])
        XCTAssertEqual(service.twoWayEnabled, false,
                       "an ON state that can never reconcile is a lie — the intent reverts")
        XCTAssertEqual(service.status, .enabled, "the legacy mirror itself is still fine")
        XCTAssertEqual(gateway.created.count, legacyCreated,
                       "no Sahayak two-way writes happen without read access")

        // Full denial: status says denied.
        let (deniedService, deniedGateway, _) = makeService(grant: false, access: .denied)
        deniedService.isEnabled = true
        await deniedService.enableAndSync(entries: [])
        await deniedService.enableTwoWayAndSync(entries: [])
        XCTAssertEqual(deniedService.twoWayEnabled, false)
        XCTAssertEqual(deniedService.status, .denied)
        XCTAssertTrue(deniedGateway.created.isEmpty)
    }

    func testEnableTwoWayBuildsSahayakMirrorAndCleansLegacyOrphans() async {
        let (service, gateway, linkStore) = makeService()
        service.isEnabled = true
        let walk = entry(name: "Walk", category: .exercise, hours: [11, 16])
        // A pre-two-way one-way mirror event (fragment, no token) + the
        // family's own event.
        gateway.records = [
            CalendarEventRecord(eventIdentifier: "legacy-1",
                                calendarIdentifier: "default-calendar",
                                title: "Walk (व्यायाम)",
                                notes: CalendarSyncService.mirrorTag,
                                startDate: time(11), isAllDay: false,
                                isCanceled: false, recurrence: .daily),
            CalendarEventRecord(eventIdentifier: "family-1", calendarIdentifier: "family",
                                title: "Doctor", notes: nil, startDate: time(12),
                                isAllDay: false, isCanceled: false, recurrence: nil)
        ]

        await service.enableAndSync(entries: [walk])   // legacy pass first
        XCTAssertEqual(gateway.lastFragmentRemovalCount, 1,
                       "the legacy rebuild wipes the pre-existing mirror event")
        await service.enableTwoWayAndSync(entries: [walk])

        XCTAssertEqual(service.twoWayEnabled, true)
        XCTAssertEqual(linkStore.sahayakCalendarIdentifier, "sahayak-1")
        // Two token'd events created in the Sahayak calendar.
        let sahayakCreates = gateway.created.filter { $0.calendarIdentifier == "sahayak-1" }
        XCTAssertEqual(sahayakCreates.count, 2, "both slots are mirrored into the Sahayak calendar")
        XCTAssertEqual(sahayakCreates.compactMap { MirrorLinkToken.parse($0.draft.notes) }.count, 2,
                       "every two-way event carries a parseable link token")
        // Migration: the two legacy events the one-way pass just wrote
        // are fragment-only orphans now — removed by the two-way rebuild.
        XCTAssertEqual(gateway.removedIdentifiers.count, 2)
        XCTAssertTrue(gateway.records.contains { $0.eventIdentifier == "family-1" },
                      "the family's own event is never touched")
        XCTAssertEqual(gateway.records.filter {
            $0.notes?.contains(CalendarSyncService.mirrorTag) == true
        }.count, 2, "what remains tagged is exactly the token'd Sahayak pair")
        // Links recorded for every mirrored slot.
        XCTAssertEqual(linkStore.count, 2)
        XCTAssertTrue(linkStore.snapshot.values.allSatisfy { $0.hasPrefix("evt-") })
        // The rebuilt mirror is idempotent: another pass plans nothing.
        let before = gateway.created.count
        service.syncNow(entries: [walk])
        XCTAssertEqual(gateway.created.count, before,
                       "equal shapes converge — resyncing never duplicates events")
    }

    func testSyncNowTwoWayStallsHonestlyWithoutFullAccess() async {
        let (service, gateway, _) = makeService(grant: true, access: .writeOnly)
        service.isEnabled = true
        await service.enableAndSync(entries: [entry(name: "Walk", hours: [11])])
        let legacyCount = gateway.created.count

        // Two-way ON but access is only writeOnly (a corner the UI
        // prevents, but syncNow must still refuse honestly).
        service.twoWayEnabled = true
        service.syncNow(entries: [entry(name: "Walk", hours: [11])])

        XCTAssertEqual(gateway.created.count, legacyCount,
                       "two-way mirroring stalls — never half-runs without read access")
        XCTAssertEqual(gateway.ensureSahayakCalls, 0)
    }

    func testTurningTwoWayOffMigratesBackToLegacyMirror() async {
        let (service, gateway, linkStore) = makeService()
        service.isEnabled = true
        let walk = entry(name: "Walk", hours: [11])

        await service.enableAndSync(entries: [walk])             // legacy events
        await service.enableTwoWayAndSync(entries: [walk])       // Sahayak token events
        XCTAssertTrue(service.twoWayEnabled)
        XCTAssertEqual(gateway.records.filter { $0.notes?.contains(CalendarSyncService.mirrorTag) == true }.count, 1)

        service.disableTwoWayAndSyncIfMirrorEnabled(entries: [walk])

        XCTAssertEqual(service.twoWayEnabled, false)
        XCTAssertEqual(gateway.lastFragmentRemovalCount, 1,
                       "the legacy wipe removes the Sahayak token events too (fragment first line)")
        XCTAssertTrue(gateway.records.allSatisfy {
            MirrorLinkToken.parse($0.notes) == nil
        }, "no two-way token survives the migration — the fragment events the "
            + "legacy mirror itself writes stay (they tag the one-way mirror "
            + "so the next wipe can find it)")
        XCTAssertEqual(gateway.created.last?.calendarIdentifier, nil,
                       "mode switch back = default-calendar one-way mirror, byte-compatible with before")
        // Stale links are harmless while two-way is off (never read);
        // the next two-way pass re-creates and overwrites them.
        XCTAssertEqual(linkStore.count, 1)
    }

    // MARK: - Service: reconcile (2026-09-07)

    func testReconcileDeliversPlannedNativeMutations() async {
        let (service, gateway, linkStore) = makeService()
        service.isEnabled = true
        let walk = entry(name: "Walk", hours: [11])
        await service.enableAndSync(entries: [walk])   // status .enabled
        service.twoWayEnabled = true
        // A Sahayak mirror exists and the family moved it to 14:00.
        let key = ExternalEventLinkStore.appKey(entryId: walk.id, slot: 0)
        linkStore.set(identifier: "evt-1", for: key)
        gateway.records = [record(id: "evt-1", entryId: walk.id, slot: 0, hour: 14)]
        var delivered: [CalendarSyncService.RoutineCalendarMutation] = []
        service.onNativeChanges = { delivered = $0 }

        await service.reconcileNativeChanges(entries: [walk])

        XCTAssertEqual(delivered, [.retimeSlot(entryId: walk.id, fromHour: 11,
                                               fromMinute: 0, toHour: 14, toMinute: 0)])
    }

    func testReconcileSilentWhenNothingDiffers() async {
        let (service, gateway, linkStore) = makeService()
        service.isEnabled = true
        let walk = entry(name: "Walk", hours: [11])
        await service.enableAndSync(entries: [walk])
        service.twoWayEnabled = true
        let key = ExternalEventLinkStore.appKey(entryId: walk.id, slot: 0)
        linkStore.set(identifier: "evt-1", for: key)
        gateway.records = [record(id: "evt-1", entryId: walk.id, slot: 0, hour: 11)]
        var deliveredCount = 0
        service.onNativeChanges = { deliveredCount = $0.count }

        await service.reconcileNativeChanges(entries: [walk])

        XCTAssertEqual(deliveredCount, 0,
                       "equal shapes produce no mutations and no write-back churn")
    }

    func testReconcileSkipsWhenModeOrAccessIsNotEnough() async {
        let (service, gateway, _) = makeService()
        service.isEnabled = true
        let walk = entry(name: "Walk", hours: [11])
        await service.enableAndSync(entries: [walk])
        // Two-way off: nothing reconciles.
        await service.reconcileNativeChanges(entries: [walk])
        XCTAssertEqual(gateway.ensureSahayakCalls, 0)

        // Two-way on but only writeOnly access: the guard refuses.
        service.twoWayEnabled = true
        let (writeOnlyService, writeOnlyGateway, _) = makeService(grant: true,
                                                                  access: .writeOnly)
        writeOnlyService.isEnabled = true
        await writeOnlyService.enableAndSync(entries: [walk])
        writeOnlyService.twoWayEnabled = true
        await writeOnlyService.reconcileNativeChanges(entries: [walk])
        XCTAssertEqual(writeOnlyGateway.ensureSahayakCalls, 0)
    }

    // MARK: - Status persistence (2026-09-07 fix)

    func testEnabledStatusRestoresAcrossInstances() async {
        let (first, _, _) = makeService()
        first.isEnabled = true
        await first.enableAndSync(entries: [])
        XCTAssertEqual(first.status, .enabled)

        // A relaunching app must know the truth WITHOUT re-prompting —
        // the restored state is what lets `start()` re-mirror directly.
        let (second, _, _) = makeService()
        XCTAssertEqual(second.status, .enabled)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "calendarSync.status"), "enabled")
    }

    func testDeniedAndErrorStatusesRestore() {
        UserDefaults.standard.set("denied", forKey: "calendarSync.status")
        XCTAssertEqual(makeService().0.status, .denied)

        UserDefaults.standard.set("error", forKey: "calendarSync.status")
        XCTAssertEqual(makeService().0.status, .error(""),
                       "the error message is session diagnostics; the state itself restores")
    }

    func testDisablingPersistsNotRequestedAndClearsTwoWayIntent() {
        UserDefaults.standard.set("enabled", forKey: "calendarSync.status")
        let (service, _, _) = makeService()
        XCTAssertEqual(service.status, .enabled)
        service.twoWayEnabled = true

        service.isEnabled = false

        XCTAssertEqual(service.twoWayEnabled, false,
                       "two-way is a mode OF the mirror — turning the mirror off clears it")
        XCTAssertEqual(service.status, .notRequested)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "calendarSync.status"), "notRequested")
        XCTAssertEqual(makeService().0.status, .notRequested,
                       "turning the mirror off must survive a relaunch")
    }
}
