import XCTest
@testable import ElderlyAssistant

/// Pure mapping-rule tests: `ExternalCalendarService.mapEvents` /
/// `mapReminders` decide what may surface from a scan, and `stableKey`
/// builds the deterministic identity behind notifications and scoped
/// cancels. "Now" is a parameter, so every rule is pinned and
/// deterministic (no wall clock, no EventKit).
final class ExternalReminderMappingTests: XCTestCase {

    /// Pinned clock instant: 2026-09-07 10:00 local.
    private var now: Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 7, hour: 10, minute: 0))!
    }

    private func date(hour: Int, minute: Int = 0, day: Int = 7) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func makeEvent(id: String = "evt-1",
                           start: Date? = nil,
                           isAllDay: Bool = false,
                           declined: Bool = false,
                           hasAlarms: Bool = false,
                           notes: String? = nil,
                           calendarIdentifier: String? = nil,
                           title: String = "Doctor visit",
                           location: String? = nil) -> ScannedEvent {
        ScannedEvent(
            nativeIdentifier: id,
            title: title,
            notes: notes,
            startDate: start ?? date(hour: 11),
            isAllDay: isAllDay,
            isDeclined: declined,
            hasAlarms: hasAlarms,
            calendarIdentifier: calendarIdentifier,
            calendarName: "Family",
            location: location
        )
    }

    private func makeReminder(id: String = "rmd-1",
                              due: Date?,
                              isAllDay: Bool = false,
                              completed: Bool = false,
                              hasAlarms: Bool = false,
                              title: String = "Call the doctor") -> ScannedReminder {
        ScannedReminder(
            nativeIdentifier: id,
            title: title,
            notes: nil,
            dueDate: due,
            isAllDay: isAllDay,
            isCompleted: completed,
            hasAlarms: hasAlarms,
            calendarName: "Home List"
        )
    }

    // MARK: - stableKey

    func testStableKeyIsDeterministicSHA256() {
        let a = ExternalCalendarService.stableKey(
            source: .event, nativeIdentifier: "evt-1", startDate: date(hour: 11))
        let b = ExternalCalendarService.stableKey(
            source: .event, nativeIdentifier: "evt-1", startDate: date(hour: 11))
        XCTAssertEqual(a, b, "the same native item must map to the same key every pass")
        XCTAssertEqual(a.count, 64, "full SHA-256 hex, not a truncated hash")
    }

    func testStableKeyDistinguishesSourceIdentifierAndTime() {
        let base = date(hour: 11)
        let asEvent = ExternalCalendarService.stableKey(
            source: .event, nativeIdentifier: "x", startDate: base)
        let asReminder = ExternalCalendarService.stableKey(
            source: .reminder, nativeIdentifier: "x", startDate: base)
        let otherId = ExternalCalendarService.stableKey(
            source: .event, nativeIdentifier: "y", startDate: base)
        let moved = ExternalCalendarService.stableKey(
            source: .event, nativeIdentifier: "x", startDate: date(hour: 12))
        XCTAssertNotEqual(asEvent, asReminder)
        XCTAssertNotEqual(asEvent, otherId)
        XCTAssertNotEqual(asEvent, moved,
                          "a moved event is a new commitment — it must get a fresh key")
    }

    // MARK: - mapEvents keep rules

    func testMapEventsKeepsPlainFutureTimedEventWithAllFields() {
        let event = makeEvent(hasAlarms: true, notes: "room 4")
        let mapped = ExternalCalendarService.mapEvents([event], now: now)
        XCTAssertEqual(mapped.count, 1)
        let item = mapped[0]
        XCTAssertEqual(item.source, .event)
        XCTAssertEqual(item.title, "Doctor visit")
        XCTAssertEqual(item.notes, "room 4")
        XCTAssertEqual(item.startDate, date(hour: 11))
        XCTAssertFalse(item.isAllDay)
        XCTAssertTrue(item.hasOwnAlarm,
                      "items with their own native alarm are FLAGGED, not dropped")
        XCTAssertEqual(item.calendarName, "Family")
        XCTAssertEqual(item.id, ExternalCalendarService.stableKey(
            source: .event, nativeIdentifier: "evt-1", startDate: date(hour: 11)))
    }

    func testMapEventsDropsDeclinedInvitations() {
        let declined = makeEvent(declined: true)
        XCTAssertTrue(ExternalCalendarService.mapEvents([declined], now: now).isEmpty,
                      "a declined invitation is not a commitment")
    }

    func testMapEventsDropsOurOwnMirroredRoutineEvents() {
        let mirror = makeEvent(notes: CalendarSyncService.mirrorTag)
        XCTAssertTrue(ExternalCalendarService.mapEvents([mirror], now: now).isEmpty,
                      "the app's own mirrored routine events must never double-notify")
    }

    func testMapEventsDropsAlreadyStartedTimedEvents() {
        let started = makeEvent(id: "past", start: date(hour: 9))
        let atNow = makeEvent(id: "at-now", start: now)
        XCTAssertTrue(ExternalCalendarService.mapEvents([started, atNow], now: now).isEmpty)
    }

    func testMapEventsKeepsAllDayEventWhoseDayHasStarted() {
        // An all-day event is "today", not "already started" — midnight
        // passed but the day has not.
        let allDay = makeEvent(id: "holiday", start: date(hour: 0),
                               isAllDay: true)
        XCTAssertEqual(ExternalCalendarService.mapEvents([allDay], now: now).count, 1)
    }

    // MARK: - mapReminders keep rules

    func testMapRemindersKeepsFutureDueReminder() {
        let mapped = ExternalCalendarService.mapReminders(
            [makeReminder(due: date(hour: 12))], now: now)
        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0].source, .reminder)
        XCTAssertEqual(mapped[0].title, "Call the doctor")
        XCTAssertEqual(mapped[0].startDate, date(hour: 12))
        XCTAssertEqual(mapped[0].calendarName, "Home List")
    }

    func testMapRemindersKeepsAllDayReminder() {
        // Date-only due dates normalize (scanner side) to end-of-day;
        // the mapping keeps the flag so views caption "All day".
        let mapped = ExternalCalendarService.mapReminders(
            [makeReminder(due: date(hour: 23, minute: 59), isAllDay: true)], now: now)
        XCTAssertEqual(mapped.count, 1)
        XCTAssertTrue(mapped[0].isAllDay)
    }

    func testMapRemindersDropsCompletedDatelessAndPastDue() {
        let completed = makeReminder(id: "done", due: date(hour: 12),
                                     completed: true)
        let dateless = makeReminder(id: "no-due", due: nil)
        let pastDue = makeReminder(id: "late", due: date(hour: 9))
        let dueNow = makeReminder(id: "due-now", due: now)
        let mapped = ExternalCalendarService.mapReminders(
            [completed, dateless, pastDue, dueNow], now: now)
        XCTAssertTrue(mapped.isEmpty,
                      "completed / dateless / already-due reminders are not reminders of anything still ahead")
    }

    // MARK: - Deep-link gating (rich-events task, 2026-09-17)

    /// `action(for:)` decides whether an armed reminder gets an Open
    /// button at all (design §4). It is the ONLY place that decision is
    /// made — `UNExternalReminderScheduler` sets the category and the
    /// event id together when an action exists — so "there is a button"
    /// and "there is a destination" cannot drift apart.
    func testAnEventWithAnAddressGetsADeepLinkToItself() {
        let item = makeReminder(from: makeEvent(location: "Tilganga, Kathmandu"))
        let action = ExternalCalendarService.action(for: item)
        XCTAssertEqual(action, ExternalReminderAction(eventIdentifier: "evt-1"),
                       "the id is the NATIVE event identifier — the same id the "
                       + "side index and the detail screen key on")
    }

    func testAnEventWithoutAnAddressGetsNoAction() {
        XCTAssertNil(ExternalCalendarService.action(for: makeReminder(from: makeEvent())))
        XCTAssertNil(ExternalCalendarService.action(
            for: makeReminder(from: makeEvent(location: "   "))),
            "a whitespace-only location is no location — nowhere to go, no button")
    }

    /// Imported REMINDERS have no event behind them (their native id is
    /// nil by construction), and a location alone must never be enough:
    /// the deep link points at an event detail screen.
    func testAReminderSourceNeverGetsAnActionEvenWithALocation() {
        let item = ExternalReminder(
            id: "rmd-key", source: .reminder, title: "Call the doctor",
            notes: nil, startDate: date(hour: 12), isAllDay: false,
            hasOwnAlarm: false, calendarName: "Home List",
            nativeEventIdentifier: nil, location: "Kathmandu")
        XCTAssertNil(ExternalCalendarService.action(for: item))
    }

    /// An event that somehow reached the mapping without a native id —
    /// nothing to deep-link to, so no button.
    func testAnEventWithNoNativeIdentifierGetsNoAction() {
        let item = ExternalReminder(
            id: "key", source: .event, title: "Doctor visit", notes: nil,
            startDate: date(hour: 12), isAllDay: false, hasOwnAlarm: false,
            calendarName: "Family", nativeEventIdentifier: nil,
            location: "Kathmandu")
        XCTAssertNil(ExternalCalendarService.action(for: item))
    }

    /// The mapping carries the address and the native id through from the
    /// scan — the two fields the gate above reads.
    func testMapEventsCarriesLocationAndNativeIdentifierThrough() {
        let item = makeReminder(from: makeEvent(location: "Patan Durbar Square"))
        XCTAssertEqual(item.location, "Patan Durbar Square")
        XCTAssertEqual(item.nativeEventIdentifier, "evt-1")
        XCTAssertTrue(item.hasAddress)
    }

    /// The mapping carries `EKEvent.location` through verbatim (the
    /// scanner neither invents nor trims it); the "is that an address?"
    /// question is answered in ONE place — `hasAddress` — so the Go
    /// button, the Open action and the Google twin's location row can
    /// never disagree about a whitespace-only value.
    func testABlankLocationIsCarriedButReadsAsNoAddress() {
        let item = makeReminder(from: makeEvent(location: "   "))
        XCTAssertEqual(item.location, "   ",
                       "verbatim: the mapping is a pass-through, not a normalizer")
        XCTAssertFalse(item.hasAddress)
        XCTAssertNil(ExternalCalendarService.action(for: item))
    }

    private func makeReminder(from event: ScannedEvent) -> ExternalReminder {
        ExternalCalendarService.mapEvents([event], now: now).first!
    }

    // MARK: - Notification identity namespace

    func testNotificationIdentifierNamespace() {
        let key = ExternalCalendarService.stableKey(
            source: .reminder, nativeIdentifier: "rmd-1", startDate: date(hour: 12))
        let identifier = ExternalNotificationIdentity.identifier(for: key)
        XCTAssertTrue(identifier.hasPrefix(ExternalNotificationIdentity.prefix))
        XCTAssertEqual(ExternalNotificationIdentity.stableKey(from: identifier), key,
                       "identifier → stable key round-trip must be lossless")
        XCTAssertNil(ExternalNotificationIdentity.stableKey(from: "ack_check_123"),
                     "foreign identifiers (medication/routine) are outside the namespace")
    }
}
