import XCTest
@testable import ElderlyAssistant

/// The voice `create_calendar_event` write path (caregiver
/// event-notifications task, 2026-09-13): where an event is written, and
/// how a spoken time expression becomes a start instant.
///
/// Both halves are pure/parameterised on purpose — the writer's calendar
/// choice is the one decision that makes the rest of the feature work
/// (see below), and the resolver is the only place a clock enters.
final class VoiceCalendarEventWriterTests: XCTestCase {

    // MARK: - Fakes

    /// In-memory `EventKitCalendarGateway`, recording what was written.
    /// Mirrors the double in `CalendarSyncServiceTests` (that one is
    /// file-private).
    private final class FakeGateway: EventKitCalendarGateway {
        var access: CalendarAccess = .fullAccess
        var grantResult = true
        var createResult = true
        private(set) var accessRequests = 0
        private(set) var created: [(draft: CalendarEventDraft,
                                    calendarIdentifier: String?)] = []

        var eventsAccess: CalendarAccess { access }

        func requestFullAccess() async -> Bool {
            accessRequests += 1
            return grantResult
        }

        func ensureSahayakCalendar(knownIdentifier: String?) -> String? { "sahayak-1" }

        func fetchEvents(from start: Date, to end: Date) -> [CalendarEventRecord] { [] }

        func createEvent(_ draft: CalendarEventDraft,
                         in calendarIdentifier: String?) -> String? {
            created.append((draft, calendarIdentifier))
            return createResult ? "evt-\(created.count)" : nil
        }

        func updateEvent(identifier: String, with draft: CalendarEventDraft) -> Bool { false }

        func removeEvent(identifier: String) -> Bool { false }

        func removeEvents(matchingNotesFragment fragment: String) -> Int { 0 }
    }

    private var gateway: FakeGateway!
    private var writer: EventKitCalendarEventWriter!
    private let start = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUp() {
        super.setUp()
        gateway = FakeGateway()
        writer = EventKitCalendarEventWriter(gateway: gateway)
    }

    // MARK: - Writer

    /// **The load-bearing decision.** `AppCoordinator` excludes the
    /// "Sahayak" mirror calendar from `ExternalCalendarService`'s import,
    /// so an event created there would never be re-imported, never armed
    /// with an in-app notification, and therefore never fire the
    /// caregiver event alert. Writing to the DEFAULT calendar (`in: nil`)
    /// is what makes the voice-created event flow import → arm → fire.
    func testCreateWritesToTheDefaultCalendarNotTheSahayakMirror() {
        _ = writer.create(title: "डाक्टर भेट्ने", startDate: start,
                          durationMinutes: EventKitCalendarEventWriter.defaultDurationMinutes)

        XCTAssertEqual(gateway.created.count, 1)
        XCTAssertNil(gateway.created.first?.calendarIdentifier,
                     "must write to the default calendar — a mirror-calendar event never fires an alert")
    }

    func testCreateSendsTheTitleStartAndDurationAsGiven() {
        _ = writer.create(title: "Doctor appointment", startDate: start, durationMinutes: 45)

        let draft = gateway.created.first?.draft
        XCTAssertEqual(draft?.title, "Doctor appointment")
        XCTAssertEqual(draft?.startDate, start)
        XCTAssertEqual(draft?.durationMinutes, 45)
    }

    /// No recurrence and no notes: the app's own notification is the fire
    /// signal (a native alarm would double-notify), and the elder never
    /// dictated a body.
    func testCreateSendsNoNotesAndNoRecurrence() {
        _ = writer.create(title: "Walk with Maya", startDate: start,
                          durationMinutes: EventKitCalendarEventWriter.defaultDurationMinutes)

        let draft = gateway.created.first?.draft
        XCTAssertNil(draft?.notes)
        XCTAssertNil(draft?.recurrence)
    }

    /// The elder says "डाक्टर भेट्ने", never a length — the default is a
    /// named constant so the coordinator and the tests agree on it.
    func testDefaultDurationIsHalfAnHour() {
        XCTAssertEqual(EventKitCalendarEventWriter.defaultDurationMinutes, 30)
    }

    /// A refused save must report failure so the caller speaks the honest
    /// unavailable line instead of claiming an event exists.
    func testCreateReportsFailureWhenTheStoreRefuses() {
        gateway.createResult = false

        let written = writer.create(title: "Doctor", startDate: start,
                                    durationMinutes: EventKitCalendarEventWriter.defaultDurationMinutes)

        XCTAssertFalse(written)
        XCTAssertEqual(gateway.created.count, 1, "the attempt is still recorded")
    }

    func testEventsAccessMirrorsTheGateway() {
        gateway.access = .denied
        XCTAssertEqual(writer.eventsAccess, .denied)

        gateway.access = .writeOnly
        XCTAssertEqual(writer.eventsAccess, .writeOnly)
    }

    func testRequestAccessForwardsToTheGateway() async {
        gateway.grantResult = false

        let granted = await writer.requestAccess()

        XCTAssertFalse(granted)
        XCTAssertEqual(gateway.accessRequests, 1)
    }

    // MARK: - Time resolution

    /// Pinned UTC calendar + pinned "now" — every case below is a pure
    /// statement about how a parsed time expression is interpreted.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The pinned "now": 2026-09-13 09:00 UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 13,
                                           hour: 9, minute: 0))!
    }

    private func resolve(_ components: DateComponents) -> Date? {
        CalendarEventTimeResolver.resolveEventDate(from: components, now: now,
                                                   calendar: calendar)
    }

    /// A full date-time (the shape `NepaliTimeParser` returns for "भोलि
    /// बिहान ८ बजे") is taken AS GIVEN — the speaker named the day, and
    /// respecting it is the whole point.
    func testFullDateTimeIsTakenAsGiven() {
        let resolved = resolve(DateComponents(year: 2026, month: 9, day: 20,
                                              hour: 8, minute: 30))

        XCTAssertEqual(resolved, calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 20, hour: 8, minute: 30)))
    }

    /// A full date-time in the PAST is still honored: the day was named
    /// explicitly, so the resolver's job is to resolve, not to correct.
    /// (The router's own guard is about an unresolvable time, not a past
    /// one; rolling a named past date forward would silently lie.)
    func testNamedDayIsNotRolledForwardWhenItIsInThePast() {
        let resolved = resolve(DateComponents(year: 2026, month: 9, day: 1,
                                              hour: 8, minute: 0))

        XCTAssertEqual(resolved, calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 1, hour: 8, minute: 0)))
    }

    /// A bare time-of-day still in the future means today ("डाक्टरलाई
    /// बेलुका ५ बजे फोन गर्ने").
    func testBareTimeLaterTodayStaysToday() {
        let resolved = resolve(DateComponents(hour: 17, minute: 0))

        XCTAssertEqual(resolved, calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 13, hour: 17, minute: 0)))
    }

    /// A bare time-of-day already past means TOMORROW: "बिहान ८ बजे" said
    /// at 9am is obviously the next morning, never an event created in
    /// the past (Calendar would happily store it and the alert would
    /// never fire).
    func testBareTimeAlreadyPastRollsToTomorrow() {
        let resolved = resolve(DateComponents(hour: 8, minute: 0))

        XCTAssertEqual(resolved, calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 14, hour: 8, minute: 0)))
    }

    /// "At or before now", not "before now": an event the elder is asking
    /// for at the CURRENT minute rolls forward rather than being created
    /// already-started.
    func testBareTimeAtTheCurrentMinuteRollsToTomorrow() {
        let resolved = resolve(DateComponents(hour: 9, minute: 0))

        XCTAssertEqual(resolved, calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 14, hour: 9, minute: 0)))
    }

    /// Seconds are dropped: the elder never names one, and a stale second
    /// would make an otherwise-identical event look different.
    func testResolutionDropsSeconds() {
        let resolved = resolve(DateComponents(hour: 17, minute: 30, second: 45))

        XCTAssertEqual(resolved, calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 13, hour: 17, minute: 30)))
    }

    /// The honest-failure case: components with no hour AND no minute
    /// cannot form a start time, and must NOT silently become midnight —
    /// a "midnight event" nobody asked for is worse than asking when.
    func testTimelessComponentsResolveToNilRatherThanMidnight() {
        XCTAssertNil(resolve(DateComponents()))
        XCTAssertNil(resolve(DateComponents(year: 2026, month: 9, day: 14)),
                     "a named day with no time is still not an event start")
        XCTAssertNil(resolve(DateComponents(year: 2026, month: 9, day: 14, hour: 8)),
                     "an hour without a minute cannot be spoken-scheduled")
    }

    /// An all-day-shaped parse (day words with no clock time) reaches the
    /// router as the no-time case, not as a midnight event — that path is
    /// covered above; this pins the OTHER half of the contract: whenever
    /// resolution DOES succeed, the result is a real, speakable instant.
    func testResolvedInstantsAreAlwaysTimeOfDayBearing() {
        for hour in [0, 8, 12, 23] {
            let resolved = resolve(DateComponents(hour: hour, minute: 15))
            XCTAssertNotNil(resolved)
            let parts = calendar.dateComponents([.hour, .minute], from: resolved!)
            XCTAssertEqual(parts.hour, hour)
            XCTAssertEqual(parts.minute, 15)
        }
    }
}
