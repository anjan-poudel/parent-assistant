import XCTest
import UIKit
@testable import ElderlyAssistant

// MARK: - Video spy (T-015)

/// Records the event write seam's video calls in one ordered log so the
/// transaction's ORDER is assertable without touching real bytes (T-015).
/// `onCommit` is the hook that lets a test interleave a gateway or storage
/// write with the commit — the same witness shape `RoutineSchedulerTests`
/// uses for C11.
private final class EventInstructionVideoStoreSpy: RoutineInstructionVideoStoring {
    var callLog: [String] = []
    var commitOwners: [InstructionOwner] = []
    var deleteAllOwners: [InstructionOwner] = []
    /// Bare filenames that "exist" for the owner, per the store's contract.
    var files: Set<String> = []
    var commitResult: Result<String, InstructionStorageError> =
        .success("instruction-new.mov")
    var deleteResult: Result<Void, InstructionStorageError> = .success(())
    var deleteAllResult: Result<Void, InstructionStorageError> = .success(())
    var discarded: [StagedInstructionVideo] = []
    /// Overrides the availability answer when set — models a name the
    /// store refuses or cannot read.
    var availabilityOverride: InstructionPlaybackAvailability?
    var onCommit: (() -> Void)?

    func commit(_ staged: StagedInstructionVideo,
                for owner: InstructionOwner) -> Result<String, InstructionStorageError> {
        callLog.append("commit")
        commitOwners.append(owner)
        onCommit?()
        if case .success(let filename) = commitResult {
            files.insert(filename)
        }
        return commitResult
    }

    func discard(_ staged: StagedInstructionVideo) -> Result<Void, InstructionStorageError> {
        callLog.append("discard")
        discarded.append(staged)
        return .success(())
    }

    func delete(_ filename: String,
                for owner: InstructionOwner) -> Result<Void, InstructionStorageError> {
        callLog.append("delete:\(filename)")
        if case .success = deleteResult {
            files.remove(filename)
        }
        return deleteResult
    }

    func deleteAll(for owner: InstructionOwner) -> Result<Void, InstructionStorageError> {
        callLog.append("deleteAll")
        deleteAllOwners.append(owner)
        if case .success = deleteAllResult {
            files.removeAll()
        }
        return deleteAllResult
    }

    func availability(filename: String,
                      owner: InstructionOwner) -> InstructionPlaybackAvailability {
        if let availabilityOverride { return availabilityOverride }
        if files.contains(filename) {
            return .available(URL(fileURLWithPath: "/tmp/\(filename)"))
        }
        return .missingFile
    }
}

/// `FreeFormEventService` — the read/write face over the native events
/// the app created (rich-events task, 2026-09-17; design §2), extended by
/// T-015 with the event owner's instruction transaction (design L2 §2.13,
/// §4.8, §5.6).
///
/// Free-form events ARE native `EKEvent`s in the default calendar, so
/// the interesting behaviour is at the SEAMS: which events the list
/// shows (the side index's membership, not the calendar), how the app
/// heals an index row whose event is gone, and the write-then-index
/// ordering that decides whether a failed photo write can destroy the
/// photo it was replacing. The gateway is an in-memory fake, the photo
/// store a throwaway directory and the video store an ordered spy, so
/// nothing touches EventKit, the Keychain or Application Support.
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
        /// Ordered write log shared with the video spy's hook where a test
        /// pins "the event exists before any instruction bytes move"
        /// (T-015, design §5.6).
        var callLog: [String] = []

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
            callLog.append("create")
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
            callLog.append("update")
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
            callLog.append("remove")
            records.remove(at: index)
            removedIdentifiers.append(identifier)
            return true
        }
        func removeEvents(matchingNotesFragment fragment: String) -> Int { 0 }
    }

    // MARK: - Harness

    private var gateway: FakeGateway!
    private var storage: MockEncryptedLocalStorage!
    private var extras: EventExtrasStore!
    private var photoRoot: URL!
    private var videoStore: EventInstructionVideoStoreSpy!
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
        storage = MockEncryptedLocalStorage()
        extras = EventExtrasStore(storage: storage)
        videoStore = EventInstructionVideoStoreSpy()
        bus = MockObservabilityBus()
        photoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("event-photo-tests-\(UUID().uuidString)")
        service = FreeFormEventService(
            gateway: gateway,
            extras: extras,
            photoStore: ContactPhotoStore(rootDirectory: photoRoot),
            instructionVideoStore: videoStore,
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

    // MARK: - Instruction harness (T-015)

    /// A staged video for the EVENT root — the owner the transaction must
    /// commit under (design §5.6, §4.3).
    private func makeStagedVideo(draftId: UUID = UUID()) -> StagedInstructionVideo {
        StagedInstructionVideo(
            draftId: draftId,
            root: .events,
            stagedURL: URL(fileURLWithPath: "/tmp/staged-\(draftId.uuidString).mov"),
            byteCount: 1024,
            metadata: InstructionVideoMetadata(durationSeconds: 12,
                                               hasVideoTrack: true,
                                               isPlayable: true),
            sourceExtension: "mov",
            stagedAt: now)
    }

    private func makeVideoCommit(caption: String? = nil) -> InstructionCommit {
        let staged = makeStagedVideo()
        return InstructionCommit(
            write: .set(InstructionPayload(kind: .video, caption: caption)),
            pendingMedia: .video(AcceptedInstructionVideo(staged: staged,
                                                          validatedAt: now)))
    }

    private func makeTextCommit(_ text: String) -> InstructionCommit {
        InstructionCommit(write: .set(InstructionPayload(kind: .text, text: text)),
                          pendingMedia: nil)
    }

    private var removeCommit: InstructionCommit {
        InstructionCommit(write: .remove, pendingMedia: nil)
    }

    /// Tracks `eventId` and stores `instruction` directly, through the
    /// store seam — the "event already had one" precondition.
    private func seedInstruction(_ instruction: Instruction, forEventId eventId: String) {
        extras.track(eventId: eventId)
        XCTAssertTrue(extras.setInstruction(instruction, forEventId: eventId))
    }

    private func assertSuccess(_ result: Result<Void, InstructionWriteError>,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        if case .failure(let error) = result {
            XCTFail("expected success, got \(error)", file: file, line: line)
        }
    }

    private func assertFailure(_ result: Result<Void, InstructionWriteError>,
                               equals expected: InstructionWriteError,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        switch result {
        case .success:
            XCTFail("expected \(expected), got success", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    private func instructionUpdatedEvents() -> [ObservabilityEvent] {
        bus.emittedEvents.filter { $0.eventType == "event_instruction_updated" }
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

        let outcome = service.save(form)

        XCTAssertEqual(outcome, FreeFormEventSaveOutcome(eventId: "evt-1",
                                                         instructionSaved: true))
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

        let outcome = service.save(form, editing: "evt-9")

        XCTAssertEqual(outcome?.eventId, "evt-9")
        XCTAssertEqual(outcome?.instructionSaved, true)
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

    // MARK: - Instructions (T-015, design L2 §2.13, §4.8, §5.6)

    /// No draft means no instruction work at all: the event save is
    /// exactly today's, the membership row is still written (that is what
    /// makes the event "one of ours"), and no bytes move.
    func testSaveWithoutInstructionIsUnchanged() {
        var form = FreeFormEventForm(startDate: date(hour: 14))
        form.title = "Dentist"

        let outcome = service.save(form)

        XCTAssertEqual(outcome,
                       FreeFormEventSaveOutcome(eventId: "evt-1",
                                                instructionSaved: true))
        XCTAssertEqual(gateway.created.count, 1)
        XCTAssertEqual(extras.eventIds, ["evt-1"])
        XCTAssertNil(extras.extras(forEventId: "evt-1")?.instruction)
        XCTAssertTrue(videoStore.callLog.isEmpty,
                      "no instruction draft -> no media, no delete, no commit")
        XCTAssertTrue(instructionUpdatedEvents().isEmpty)
    }

    /// The event exists before any instruction byte is committed, and the
    /// commit runs under the EVENT owner (design §5.6: "step 1 runs only
    /// after the event's resolvedId exists").
    func testSaveWithInstructionWritesEventFirst() throws {
        var form = FreeFormEventForm(startDate: date(hour: 14))
        form.title = "Dentist"
        var draft = InstructionDraft.loaded(instruction: nil)
        draft.setPendingVideo(AcceptedInstructionVideo(staged: makeStagedVideo(),
                                                       validatedAt: now),
                              caption: nil)
        form.instructionDraft = draft

        let fakeGateway = gateway!
        videoStore.onCommit = { fakeGateway.callLog.append("commit") }

        let outcome = try XCTUnwrap(service.save(form))

        XCTAssertEqual(outcome.eventId, "evt-1")
        XCTAssertTrue(outcome.instructionSaved)
        XCTAssertEqual(fakeGateway.callLog, ["create", "commit"],
                       "the event is created before the instruction is committed")
        XCTAssertEqual(videoStore.commitOwners, [.event("evt-1")],
                       "the event owner root, never the routine root")
        XCTAssertEqual(extras.extras(forEventId: "evt-1")?.instruction?.kind, "video")
        XCTAssertEqual(extras.extras(forEventId: "evt-1")?.instruction?.filename,
                       "instruction-new.mov")
    }

    /// A failed instruction write after a successful event save is a
    /// PARTIAL outcome, never nil: the event (and its photo) are exactly
    /// as today, the instruction did not change, and no bytes are orphaned.
    func testInstructionFailureReportsInstructionSaved() throws {
        var form = FreeFormEventForm(startDate: date(hour: 14))
        form.title = "Dentist"
        var draft = InstructionDraft.loaded(instruction: nil)
        draft.setPendingVideo(AcceptedInstructionVideo(staged: makeStagedVideo(),
                                                       validatedAt: now),
                              caption: nil)
        form.instructionDraft = draft
        videoStore.commitResult = .failure(.commitFailed)

        let outcome = try XCTUnwrap(service.save(form),
                                    "a saved event is never nil")

        XCTAssertEqual(outcome.eventId, "evt-1")
        XCTAssertFalse(outcome.instructionSaved,
                       "the surface can report the partial line honestly")
        XCTAssertNotNil(service.event(withId: "evt-1"),
                        "the event remains visible and editable")
        XCTAssertNil(extras.extras(forEventId: "evt-1")?.instruction,
                     "no instruction change is claimed")
        XCTAssertEqual(videoStore.discarded.count, 1,
                       "a failed commit discards the staged draft")
        XCTAssertTrue(videoStore.files.isEmpty, "no media is orphaned")
        XCTAssertTrue(instructionUpdatedEvents().isEmpty,
                      "a failed write emits no update event")
    }

    /// §5.6 A1/A2: the new bytes are durable before the extras row names
    /// them. The storage hook and the spy hook share one ordered log, so
    /// this is one array comparison.
    func testSetInstructionCommitsBeforePersist() {
        seedEvent(id: "evt-1")
        var log: [String] = []
        videoStore.onCommit = { log.append("commit") }
        storage.onWriteCompleted = { log.append("persist") }

        assertSuccess(service.setInstruction(makeVideoCommit(), forEventId: "evt-1"))

        XCTAssertEqual(Array(log.prefix(2)), ["commit", "persist"],
                       "bytes become durable before the index names them")
        XCTAssertEqual(videoStore.commitOwners, [.event("evt-1")])
        XCTAssertEqual(extras.extras(forEventId: "evt-1")?.instruction?.filename,
                       "instruction-new.mov")
    }

    /// A missing extras row is `.ownerNotFound` BEFORE anything is
    /// touched: no byte written, no byte deleted, no index write.
    func testMissingEventReturnsOwnerNotFound() {
        assertFailure(service.setInstruction(makeTextCommit("Take the blue pill"),
                                             forEventId: "never"),
                      equals: .ownerNotFound)

        XCTAssertTrue(videoStore.callLog.isEmpty,
                      "no bytes are written or deleted for an owner we do not have")
        XCTAssertEqual(storage.writeCallCount, 0, "the index is untouched")
        XCTAssertTrue(instructionUpdatedEvents().isEmpty)
    }

    /// §5.6 A1: a failed media commit leaves the previous instruction and
    /// its file exactly where they were.
    func testMediaCommitFailureKeepsPrevious() {
        seedEvent(id: "evt-1")
        let previous = Instruction(kind: "video", caption: "Old",
                                   filename: "instruction-old.mov")
        seedInstruction(previous, forEventId: "evt-1")
        videoStore.files = ["instruction-old.mov"]
        videoStore.commitResult = .failure(.commitFailed)

        assertFailure(service.setInstruction(makeVideoCommit(), forEventId: "evt-1"),
                      equals: .mediaWriteFailed(.commitFailed))

        XCTAssertEqual(extras.extras(forEventId: "evt-1")?.instruction, previous,
                       "the extras row still names the previous file")
        XCTAssertTrue(videoStore.files.contains("instruction-old.mov"),
                      "the previous file still exists")
        XCTAssertEqual(videoStore.discarded.count, 1,
                       "the staged draft is discarded")
        XCTAssertTrue(instructionUpdatedEvents().isEmpty)
    }

    /// §5.6 A2: a failed persist deletes the bytes committed for THIS
    /// attempt, so the row and disk cannot disagree.
    func testPersistFailureDoesNotOrphanNewBytes() {
        seedEvent(id: "evt-1")
        let previous = Instruction(kind: "video", caption: "Old",
                                   filename: "instruction-old.mov")
        seedInstruction(previous, forEventId: "evt-1")
        videoStore.files = ["instruction-old.mov"]
        videoStore.commitResult = .success("instruction-new.mov")
        storage.shouldFailWrite = true

        assertFailure(service.setInstruction(makeVideoCommit(), forEventId: "evt-1"),
                      equals: .persistenceFailed)

        XCTAssertEqual(extras.extras(forEventId: "evt-1")?.instruction, previous,
                       "the previous instruction survives the failed write")
        XCTAssertFalse(videoStore.files.contains("instruction-new.mov"),
                       "bytes committed for an index write that failed are deleted")
        XCTAssertTrue(videoStore.files.contains("instruction-old.mov"),
                      "the previous file is not touched by a rollback")
        XCTAssertTrue(instructionUpdatedEvents().isEmpty)
    }

    /// §2.13.4: delete removes the row, the photo and the event owner's
    /// whole video directory.
    func testDeleteEventDeletesAllMedia() throws {
        seedEvent(id: "evt-1")
        XCTAssertTrue(service.setPhoto(makeImage(), forEventId: "evt-1"))
        let photo = try XCTUnwrap(extras.extras(forEventId: "evt-1")?.photoFilename)
        seedInstruction(Instruction(kind: "video", filename: "instruction-old.mov"),
                        forEventId: "evt-1")
        videoStore.files = ["instruction-old.mov"]

        XCTAssertTrue(service.delete(eventId: "evt-1"))

        XCTAssertTrue(videoStore.callLog.contains("deleteAll"))
        XCTAssertEqual(videoStore.deleteAllOwners, [.event("evt-1")],
                       "teardown is for the event owner, never the routine root")
        XCTAssertFalse(fileExists(photo))
        XCTAssertNil(extras.extras(forEventId: "evt-1"))
    }

    /// A media-delete failure is observed and left to the sweep: it never
    /// changes the answer and never blocks the row removal.
    func testDeleteEventSurvivesMediaFailure() {
        seedEvent(id: "evt-1")
        videoStore.deleteAllResult = .failure(.deleteFailed)

        XCTAssertTrue(service.delete(eventId: "evt-1"),
                      "the returned Bool still reports the native removal")
        XCTAssertNil(extras.extras(forEventId: "evt-1"),
                     "the row is removed even when the media delete fails")
        XCTAssertEqual(videoStore.deleteAllOwners, [.event("evt-1")])
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "instruction_media_delete" && $0.outcome == "failed"
        })
    }

    /// §6.4: one `event_instruction_updated` on a real change — component
    /// `free_form_events`, outcome `saved`, `kind` + `count = 1`, and no
    /// identifier, title, text, caption, filename or URL.
    func testRealChangeEmitsEventInstructionUpdated() throws {
        seedEvent(id: "evt-1")

        assertSuccess(service.setInstruction(makeTextCommit("Take the blue pill"),
                                             forEventId: "evt-1"))

        let events = instructionUpdatedEvents()
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.component, "free_form_events")
        XCTAssertEqual(event.outcome, "saved")
        XCTAssertEqual(event.metadata, ["kind": "text", "count": "1"])
        XCTAssertNil(event.errorCode)
        XCTAssertNil(event.durationMs)

        // The identical write is a successful no-op: no persist, no event.
        assertSuccess(service.setInstruction(makeTextCommit("Take the blue pill"),
                                             forEventId: "evt-1"))
        XCTAssertEqual(instructionUpdatedEvents().count, 1,
                       "an unchanged instruction must not emit a second event")
    }

    // MARK: - Photos

    func testSaveWritesAPickedPhotoAndIndexesItOnlyAfterTheBytesLand() {
        var form = FreeFormEventForm(startDate: date(hour: 14))
        form.title = "Birthday"
        form.pickedPhoto = makeImage()

        let outcome = try! XCTUnwrap(service.save(form))
        let id = outcome.eventId
        let filename = try! XCTUnwrap(extras.extras(forEventId: id)?.photoFilename)

        XCTAssertTrue(outcome.instructionSaved)
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
