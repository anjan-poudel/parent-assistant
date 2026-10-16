import XCTest
import UIKit
@testable import ElderlyAssistant

/// `FreeFormEventService` — the read/write face over the native events
/// the app created (rich-events task, 2026-09-17; design §2).
///
/// Free-form events ARE native `EKEvent`s in the default calendar, so
/// the interesting behaviour is at the SEAMS: which events the list
/// shows (the side index's membership, not the calendar), how the app
/// heals an index row whose event is gone, and the write-then-index
/// ordering that decides whether a failed photo write can destroy the
/// photo it was replacing. The gateway is an in-memory fake and the
/// photo store a throwaway directory, so nothing touches EventKit,
/// the Keychain or Application Support.
final class FreeFormEventServiceTests: XCTestCase {

    // MARK: - Fakes

    /// In-memory `EventKitCalendarGateway` with the writes recorded.
    private final class FakeGateway: EventKitCalendarGateway {
        var access: CalendarAccess = .fullAccess
        /// When true, `createEvent`/`updateEvent` refuse — the
        /// "EventKit declined" path.
        var refuseWrites = false
        private(set) var created: [(draft: CalendarEventDraft,
                                    calendarIdentifier: String?)] = []
        private(set) var updated: [(identifier: String, draft: CalendarEventDraft)] = []
        private(set) var removedIdentifiers: [String] = []
        var records: [CalendarEventRecord] = []

        var eventsAccess: CalendarAccess { access }

        func requestFullAccess() async -> Bool { true }
        func ensureSahayakCalendar(knownIdentifier: String?) -> String? { "sahayak-1" }
        func fetchEvents(from start: Date, to end: Date) -> [CalendarEventRecord] {
            records.filter { $0.startDate >= start && $0.startDate < end }
        }
        func fetchEvent(identifier: String) -> CalendarEventRecord? {
            records.first { $0.eventIdentifier == identifier }
        }
        func createEvent(_ draft: CalendarEventDraft,
                         in calendarIdentifier: String?) -> String? {
            guard !refuseWrites else { return nil }
            created.append((draft, calendarIdentifier))
            let identifier = "evt-\(created.count)"
            records.append(CalendarEventRecord(
                eventIdentifier: identifier,
                calendarIdentifier: calendarIdentifier ?? "default-calendar",
                title: draft.title, notes: draft.notes,
                startDate: draft.startDate, isAllDay: false,
                isCanceled: false, recurrence: draft.recurrence,
                location: draft.location, durationMinutes: draft.durationMinutes))
            return identifier
        }
        func updateEvent(identifier: String, with draft: CalendarEventDraft) -> Bool {
            guard !refuseWrites,
                  let index = records.firstIndex(where: { $0.eventIdentifier == identifier })
            else { return false }
            let existing = records[index]
            records[index] = CalendarEventRecord(
                eventIdentifier: identifier,
                calendarIdentifier: existing.calendarIdentifier,
                title: draft.title, notes: draft.notes,
                startDate: draft.startDate, isAllDay: existing.isAllDay,
                isCanceled: false, recurrence: draft.recurrence,
                location: draft.location, durationMinutes: draft.durationMinutes)
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
        func removeEvents(matchingNotesFragment fragment: String) -> Int { 0 }
    }

    // MARK: - Harness

    private var gateway: FakeGateway!
    private var extras: EventExtrasStore!
    private var photoRoot: URL!
    private var bus: MockObservabilityBus!
    private var service: FreeFormEventService!

    /// The pinned clock's day: 2026-09-17 (a Thursday), 10:00 local.
    private var now: Date { date(hour: 10) }

    private func date(hour: Int, minute: Int = 0, day: Int = 17) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        gateway = FakeGateway()
        extras = EventExtrasStore(storage: MockEncryptedLocalStorage())
        bus = MockObservabilityBus()
        photoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("event-photo-tests-\(UUID().uuidString)")
        service = FreeFormEventService(
            gateway: gateway,
            extras: extras,
            photoStore: ContactPhotoStore(rootDirectory: photoRoot),
            observability: bus)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: photoRoot)
        try super.tearDownWithError()
    }

    /// A recorded native event, tracked by the side index unless the
    /// caller says otherwise.
    @discardableResult
    private func seedEvent(id: String,
                           title: String = "Dr Sharma",
                           start: Date? = nil,
                           durationMinutes: Int = 30,
                           recurrence: EventRecurrence? = nil,
                           notes: String? = nil,
                           location: String? = nil,
                           isCanceled: Bool = false,
                           tracked: Bool = true) -> CalendarEventRecord {
        let record = CalendarEventRecord(
            eventIdentifier: id, calendarIdentifier: "default-calendar",
            title: title, notes: notes, startDate: start ?? date(hour: 11),
            isAllDay: false, isCanceled: isCanceled, recurrence: recurrence,
            location: location, durationMinutes: durationMinutes)
        gateway.records.append(record)
        if tracked { extras.track(eventId: id) }
        return record
    }

    /// A solid red image at scale 1 — no asset pipeline in the test host.
    private func makeImage(width: CGFloat = 40, height: CGFloat = 40) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                       format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func fileExists(_ filename: String) -> Bool {
        FileManager.default.fileExists(
            atPath: photoRoot.appendingPathComponent(filename).path)
    }

    // MARK: - The list

    func testUpcomingShowsTrackedEventsSoonestFirst() {
        seedEvent(id: "late", title: "Evening", start: date(hour: 18))
        seedEvent(id: "soon", title: "Morning", start: date(hour: 11))
        // An event in the calendar that the app did not create (a family
        // invitation, say) is NOT one of ours — the index decides.
        seedEvent(id: "imported", title: "Family lunch", start: date(hour: 12),
                  tracked: false)

        let events = service.upcoming(now: now)
        XCTAssertEqual(events.map(\.id), ["soon", "late"])
        XCTAssertEqual(events.map(\.title), ["Morning", "Evening"])
    }

    func testUpcomingDropsAOneOffThatAlreadyStartedButKeepsASeries() {
        seedEvent(id: "past", start: date(hour: 9))
        seedEvent(id: "series", start: date(hour: 9), recurrence: .daily)
        seedEvent(id: "later", start: date(hour: 11))

        XCTAssertEqual(service.upcoming(now: now).map(\.id), ["series", "later"],
                       "a series recurs forever, so its master's past start is not 'over'")
    }

    func testUpcomingPrunesAVanishedEventAndItsPhoto() {
        seedEvent(id: "gone", tracked: true)
        XCTAssertTrue(service.setPhoto(makeImage(), forEventId: "gone"))
        let filename = try! XCTUnwrap(extras.extras(forEventId: "gone")?.photoFilename)
        XCTAssertTrue(fileExists(filename))
        // The family deleted it in the Calendar app: the record is gone
        // but the index row and the JPEG are still here.
        gateway.records.removeAll()
        seedEvent(id: "alive", start: date(hour: 12))

        XCTAssertEqual(service.upcoming(now: now).map(\.id), ["alive"])
        XCTAssertNil(extras.extras(forEventId: "gone"),
                     "the index must not grow a tail of dead ids")
        XCTAssertFalse(fileExists(filename),
                       "the photo of an event that no longer exists is not reachable "
                       + "from anywhere — it must not be left on disk")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "event_vanished"
        }, "a pruned index row must be observable")
    }

    func testUpcomingSkipsACanceledEventAndPrunesIt() {
        seedEvent(id: "canceled", isCanceled: true)
        XCTAssertTrue(service.upcoming(now: now).isEmpty)
        XCTAssertNil(extras.extras(forEventId: "canceled"),
                     "canceled reads as deleted everywhere else in this codebase")
    }

    func testUpcomingCarriesThePhotoAndTheAddressToTheList() {
        seedEvent(id: "evt-1", location: "Tilganga, Kathmandu")
        XCTAssertTrue(service.setPhoto(makeImage(), forEventId: "evt-1"))

        let event = try! XCTUnwrap(service.upcoming(now: now).first)
        XCTAssertEqual(event.address, "Tilganga, Kathmandu",
                       "the address is read back from the native event, so a family "
                       + "correction is what the Go button geocodes")
        XCTAssertTrue(event.hasAddress)
        XCTAssertNotNil(event.photoFilename)
        XCTAssertNotNil(service.photo(for: event))
    }

    func testEventByIdIsNilForAVanishedOrCanceledEvent() {
        seedEvent(id: "evt-1", start: date(hour: 9))
        XCTAssertNotNil(service.event(withId: "evt-1"))
        XCTAssertNil(service.event(withId: "never"))
    }

    // MARK: - Creating

    func testSaveCreatesInTheDefaultCalendarAndTracksTheEvent() {
        var form = FreeFormEventForm(startDate: date(hour: 14))
        form.title = "  Dentist  "
        form.address = "Patan"
        form.durationMinutes = 60

        let id = service.save(form)

        XCTAssertEqual(id, "evt-1")
        XCTAssertEqual(gateway.created.count, 1)
        XCTAssertNil(gateway.created.first?.calendarIdentifier,
                     "the default calendar is where an elder's own appointments belong")
        XCTAssertEqual(gateway.created.first?.draft.title, "Dentist")
        XCTAssertEqual(gateway.created.first?.draft.location, "Patan")
        XCTAssertEqual(extras.eventIds, ["evt-1"],
                       "the id is indexed only once the event truly exists")
        XCTAssertEqual(service.trackedEventIds, ["evt-1"])
    }

    func testSaveRefusesAnUntitledEvent() {
        let form = FreeFormEventForm(startDate: date(hour: 14))
        XCTAssertNil(service.save(form))
        XCTAssertTrue(gateway.created.isEmpty)
        XCTAssertTrue(extras.isEmpty)
    }

    func testAFailedCreateTracksNothing() {
        gateway.refuseWrites = true
        var form = FreeFormEventForm(startDate: date(hour: 14))
        form.title = "Dentist"

        XCTAssertNil(service.save(form),
                     "nil is what keeps the form on screen with its draft")
        XCTAssertTrue(extras.isEmpty,
                      "an id that never landed would be a row the list can never resolve")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "event_save" && $0.outcome == "create_failed"
        })
    }

    func testSaveUpdatesInPlaceWithoutReindexing() {
        seedEvent(id: "evt-9", title: "Old title")
        var form = FreeFormEventForm(startDate: date(hour: 16))
        form.title = "New title"

        let id = service.save(form, editing: "evt-9")

        XCTAssertEqual(id, "evt-9")
        XCTAssertTrue(gateway.created.isEmpty, "an edit is not a second event")
        XCTAssertEqual(gateway.updated.map(\.identifier), ["evt-9"])
        XCTAssertEqual(extras.eventIds, ["evt-9"], "still exactly one row")
        XCTAssertEqual(service.event(withId: "evt-9")?.title, "New title")
    }

    func testAFailedUpdateAnswersNil() {
        seedEvent(id: "evt-9")
        gateway.refuseWrites = true
        var form = FreeFormEventForm(startDate: date(hour: 16))
        form.title = "New title"

        XCTAssertNil(service.save(form, editing: "evt-9"))
    }

    // MARK: - Photos

    func testSaveWritesAPickedPhotoAndIndexesItOnlyAfterTheBytesLand() {
        var form = FreeFormEventForm(startDate: date(hour: 14))
        form.title = "Birthday"
        form.pickedPhoto = makeImage()

        let id = try! XCTUnwrap(service.save(form))
        let filename = try! XCTUnwrap(extras.extras(forEventId: id)?.photoFilename)

        XCTAssertTrue(fileExists(filename), "the index points at a file that exists")
        XCTAssertNotNil(service.photo(forEventId: id))
        XCTAssertNotNil(service.photo(for: try! XCTUnwrap(service.event(withId: id))))
    }

    func testReplacingAPhotoDeletesTheOneItReplaced() {
        seedEvent(id: "evt-1")
        XCTAssertTrue(service.setPhoto(makeImage(), forEventId: "evt-1"))
        let first = try! XCTUnwrap(extras.extras(forEventId: "evt-1")?.photoFilename)

        XCTAssertTrue(service.setPhoto(makeImage(width: 60), forEventId: "evt-1"))
        let second = try! XCTUnwrap(extras.extras(forEventId: "evt-1")?.photoFilename)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(fileExists(second))
        XCTAssertFalse(fileExists(first), "the replaced JPEG would be unreachable garbage")
    }

    func testClearingAPhotoDeletesTheFileAndKeepsTheEventTracked() {
        seedEvent(id: "evt-1")
        XCTAssertTrue(service.setPhoto(makeImage(), forEventId: "evt-1"))
        let filename = try! XCTUnwrap(extras.extras(forEventId: "evt-1")?.photoFilename)

        XCTAssertTrue(service.setPhoto(nil, forEventId: "evt-1"))

        XCTAssertFalse(fileExists(filename))
        XCTAssertNil(extras.extras(forEventId: "evt-1")?.photoFilename)
        XCTAssertEqual(extras.eventIds, ["evt-1"], "the event is still one of ours")
    }

    func testSaveRemovesAPhotoTheElderTappedRemoveOn() {
        seedEvent(id: "evt-9")
        XCTAssertTrue(service.setPhoto(makeImage(), forEventId: "evt-9"))
        let filename = try! XCTUnwrap(extras.extras(forEventId: "evt-9")?.photoFilename)

        var form = FreeFormEventForm(event: try! XCTUnwrap(service.event(withId: "evt-9")))
        form.removedPhoto = true
        _ = service.save(form, editing: "evt-9")

        XCTAssertFalse(fileExists(filename))
        XCTAssertNil(extras.extras(forEventId: "evt-9")?.photoFilename)
    }

    /// An edit that picks no photo must not touch the one the event
    /// already has — "nothing new picked" is not "no photo".
    func testAnEditWithoutAPickLeavesTheStoredPhotoAlone() {
        seedEvent(id: "evt-9")
        XCTAssertTrue(service.setPhoto(makeImage(), forEventId: "evt-9"))
        let filename = try! XCTUnwrap(extras.extras(forEventId: "evt-9")?.photoFilename)

        var form = FreeFormEventForm(startDate: date(hour: 16))
        form.title = "Renamed"
        _ = service.save(form, editing: "evt-9")

        XCTAssertTrue(fileExists(filename))
        XCTAssertEqual(extras.extras(forEventId: "evt-9")?.photoFilename, filename)
    }

    func testAMissingPhotoFileReadsAsNoPhotoRatherThanFailing() {
        seedEvent(id: "evt-1")
        XCTAssertTrue(service.setPhoto(makeImage(), forEventId: "evt-1"))
        let filename = try! XCTUnwrap(extras.extras(forEventId: "evt-1")?.photoFilename)
        try? FileManager.default.removeItem(
            at: photoRoot.appendingPathComponent(filename))

        XCTAssertNil(service.photo(forEventId: "evt-1"),
                     "a missing photo is never an error — the card just does not show")
        XCTAssertNil(service.photo(forEventId: "never-tracked"))
    }

    // MARK: - Deleting

    func testDeleteRemovesTheNativeEventTheIndexRowAndThePhoto() {
        seedEvent(id: "evt-1")
        XCTAssertTrue(service.setPhoto(makeImage(), forEventId: "evt-1"))
        let filename = try! XCTUnwrap(extras.extras(forEventId: "evt-1")?.photoFilename)

        XCTAssertTrue(service.delete(eventId: "evt-1"))

        XCTAssertEqual(gateway.removedIdentifiers, ["evt-1"])
        XCTAssertNil(service.event(withId: "evt-1"))
        XCTAssertNil(extras.extras(forEventId: "evt-1"))
        XCTAssertFalse(fileExists(filename))
    }

    /// The family already deleted it natively (or EventKit refused): the
    /// event is not in the calendar either way, so the row and the bytes
    /// still go — the answer reports the native removal honestly.
    func testDeleteStillCleansUpWhenTheNativeRemovalFails() {
        XCTAssertTrue(service.setPhoto(makeImage(), forEventId: "ghost"))
        let filename = try! XCTUnwrap(extras.extras(forEventId: "ghost")?.photoFilename)

        XCTAssertFalse(service.delete(eventId: "ghost"),
                       "the caller is told EventKit removed nothing")
        XCTAssertNil(extras.extras(forEventId: "ghost"))
        XCTAssertFalse(fileExists(filename))
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "event_delete" && $0.outcome == "already_gone"
        })
    }

    // MARK: - The share reconcile's walk set

    func testTrackedEventIdsAreExactlyTheIndexedOnes() {
        seedEvent(id: "evt-1")
        seedEvent(id: "evt-2")
        seedEvent(id: "imported", tracked: false)

        XCTAssertEqual(service.trackedEventIds, ["evt-1", "evt-2"],
                       "the index is the only honest source of 'events this app owns' — "
                       + "an imported invitation's twin belongs to its organizer")
    }
}
