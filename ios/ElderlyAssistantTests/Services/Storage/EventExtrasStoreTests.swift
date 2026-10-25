import XCTest
@testable import ElderlyAssistant

/// The free-form events' encrypted side index (rich-events task,
/// 2026-09-17; design §2).
///
/// The index exists for the ONE thing EventKit cannot hold — a photo —
/// and its membership is ALSO the app's "this event is ours" marker, so
/// these tests are about both jobs at once: a photo filename round-trips,
/// and an event with no photo is still remembered.
///
/// Storage is a `MockEncryptedLocalStorage` (the `EncryptedLocalStorage`
/// seam every store test uses), so nothing here touches the Keychain and
/// a byte payload can be planted to prove the decode is tolerant.
final class EventExtrasStoreTests: XCTestCase {

    /// The one key the whole index lives under — spelled here rather than
    /// shared, so a rename in the store fails this test loudly instead of
    /// silently splitting the index across two keys (the storage has no
    /// key enumeration; a split payload is unfindable after a relaunch).
    private let storageKey = "eventExtras.byEventId"

    private var storage: MockEncryptedLocalStorage!
    private var store: EventExtrasStore!

    override func setUp() {
        super.setUp()
        storage = MockEncryptedLocalStorage()
        store = EventExtrasStore(storage: storage)
    }

    // MARK: - Fresh state

    func testAFreshStoreIsEmptyRatherThanFailing() {
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(store.eventIds.isEmpty)
        XCTAssertNil(store.extras(forEventId: "evt-1"))
    }

    // MARK: - Tracking

    func testTrackingAnEventRemembersItWithNoPhoto() {
        XCTAssertTrue(store.track(eventId: "evt-1"))

        XCTAssertEqual(store.eventIds, ["evt-1"])
        XCTAssertEqual(store.count, 1)
        // "Tracked, no photo" and "not ours" have to be distinguishable —
        // that is why the payload is a struct and not a bare filename.
        let extras = store.extras(forEventId: "evt-1")
        XCTAssertNotNil(extras, "a tracked event must have a row")
        XCTAssertNil(extras?.photoFilename)
    }

    func testTrackingIsIdempotentAndKeepsAnExistingPhoto() {
        XCTAssertTrue(store.setPhotoFilename("a.jpg", forEventId: "evt-1"))
        XCTAssertTrue(store.track(eventId: "evt-1"),
                      "the save path calls track on every save — the second one must succeed")

        XCTAssertEqual(store.count, 1, "tracking twice must not duplicate the row")
        XCTAssertEqual(store.extras(forEventId: "evt-1")?.photoFilename, "a.jpg",
                       "a re-track must not wipe the photo the row already carried")
    }

    func testSettingAPhotoTracksTheEventToo() {
        XCTAssertTrue(store.setPhotoFilename("b.jpg", forEventId: "evt-9"))

        XCTAssertEqual(store.eventIds, ["evt-9"],
                       "a photo row without tracking would be a contradiction")
        XCTAssertEqual(store.photoFilename("evt-9"), "b.jpg")
    }

    func testClearingAPhotoKeepsTheEventTracked() {
        store.setPhotoFilename("c.jpg", forEventId: "evt-3")

        XCTAssertTrue(store.setPhotoFilename(nil, forEventId: "evt-3"))

        XCTAssertEqual(store.eventIds, ["evt-3"], "the event is still ours")
        XCTAssertNil(store.photoFilename("evt-3"))
    }

    // MARK: - Removal

    func testRemoveAnswersWhatItDroppedSoTheCallerCanDeleteTheFile() {
        store.setPhotoFilename("d.jpg", forEventId: "evt-4")

        let dropped = store.remove(eventId: "evt-4")

        // The index owns the row, the photo store owns the bytes: the
        // caller needs the filename back to delete it, and nil would
        // strand the JPEG on disk forever.
        XCTAssertEqual(dropped?.photoFilename, "d.jpg")
        XCTAssertTrue(store.isEmpty)
    }

    func testRemoveAnswersNilForAnEventThatWasNeverTracked() {
        XCTAssertNil(store.remove(eventId: "evt-never"),
                     "nothing was dropped, so there is nothing to clean up")
    }

    // MARK: - Persistence

    func testTheIndexSurvivesARelaunch() {
        store.setPhotoFilename("e.jpg", forEventId: "evt-5")
        store.track(eventId: "evt-6")

        // A second store over the same storage IS a relaunch: the map is
        // one payload, so there is nothing else to restore.
        let reopened = EventExtrasStore(storage: storage)

        XCTAssertEqual(reopened.eventIds, ["evt-5", "evt-6"])
        XCTAssertEqual(reopened.extras(forEventId: "evt-5")?.photoFilename, "e.jpg")
        XCTAssertNil(reopened.extras(forEventId: "evt-6")?.photoFilename)
    }

    // MARK: - Tolerant decode

    func testAPayloadWrittenBeforeThePhotoFieldExistedStillReads() {
        // Exactly what an older build's payload looks like: the event is
        // tracked, the photo key is simply absent. A `keyNotFound` throw
        // here would take the whole index with it — losing the Events
        // list to rescue one photo.
        storage.write(key: storageKey, value: ["evt-old": [String: String]()])

        XCTAssertEqual(store.eventIds, ["evt-old"])
        XCTAssertNil(store.extras(forEventId: "evt-old")?.photoFilename)

        // And it is still writable, so the next save upgrades the row.
        XCTAssertTrue(store.setPhotoFilename("new.jpg", forEventId: "evt-old"))
        XCTAssertEqual(store.extras(forEventId: "evt-old")?.photoFilename, "new.jpg")
    }

    func testAnUnreadablePayloadReadsAsNoEventsRatherThanThrowing() {
        // The shape a future/other version might leave behind.
        storage.write(key: storageKey, value: "not an index at all")

        XCTAssertTrue(store.isEmpty,
                      "an unreadable payload is the state a fresh install is in — "
                      + "an empty list, never a crash")
        // And the store still works: tracking starts a clean payload.
        XCTAssertTrue(store.track(eventId: "evt-1"))
        XCTAssertEqual(store.eventIds, ["evt-1"])
    }

    // MARK: - Write failures

    func testAFailedWriteIsReportedAndLeavesTheIndexUnchanged() {
        store.track(eventId: "evt-1")
        storage.shouldFailWrite = true

        XCTAssertFalse(store.track(eventId: "evt-2"),
                       "a refused write must be reported, not assumed")
        XCTAssertEqual(store.eventIds, ["evt-1"])

        storage.shouldFailWrite = false
        XCTAssertTrue(store.track(eventId: "evt-2"))
        XCTAssertEqual(store.eventIds, ["evt-1", "evt-2"])
    }

    // MARK: - Instruction field (reminders/instructions, T-014)

    /// A video instruction fixture — the kind the editor writes for an
    /// instruction that carries media.
    private func videoInstruction(filename: String = "clip.mov",
                                  caption: String? = "After breakfast") -> Instruction {
        Instruction(kind: InstructionKind.video.rawValue,
                    caption: caption,
                    filename: filename)
    }

    func testSetPhotoFilenamePreservesInstruction() {
        XCTAssertTrue(store.setPhotoFilename("a.jpg", forEventId: "evt-1"))
        let instruction = videoInstruction()
        XCTAssertTrue(store.setInstruction(instruction, forEventId: "evt-1"))

        // `track` re-saves the existing row, so it must preserve both
        // fields too (design §4.5).
        XCTAssertTrue(store.track(eventId: "evt-1"))
        XCTAssertEqual(store.extras(forEventId: "evt-1")?.instruction, instruction)

        // The gherkin's "setPhotoFilename nil is written": clearing the
        // photo must leave the instruction exactly as it was. The shipped
        // wholesale rebuild would have erased it here (P-4, R-11).
        XCTAssertTrue(store.setPhotoFilename(nil, forEventId: "evt-1"))
        XCTAssertEqual(store.extras(forEventId: "evt-1")?.instruction, instruction,
                       "clearing the photo must not rebuild the row around one field")
        XCTAssertNil(store.extras(forEventId: "evt-1")?.photoFilename)

        // A new photo is the same in-place mutation, not a rebuild.
        XCTAssertTrue(store.setPhotoFilename("a2.jpg", forEventId: "evt-1"))
        XCTAssertEqual(store.extras(forEventId: "evt-1")?.instruction, instruction)
        XCTAssertEqual(store.extras(forEventId: "evt-1")?.photoFilename, "a2.jpg")
        XCTAssertEqual(store.count, 1, "a photo change must not duplicate the row")
    }

    func testSetInstructionPreservesPhoto() {
        XCTAssertTrue(store.setPhotoFilename("b.jpg", forEventId: "evt-2"))

        // Replace a text instruction with a new video one: the second
        // write must leave the photo from the first path intact.
        XCTAssertTrue(store.setInstruction(
            Instruction(kind: InstructionKind.text.rawValue,
                        text: "Take the blue pill"),
            forEventId: "evt-2"))
        let video = videoInstruction(filename: "lunch.mov", caption: "After lunch")
        XCTAssertTrue(store.setInstruction(video, forEventId: "evt-2"))

        XCTAssertEqual(store.extras(forEventId: "evt-2")?.photoFilename, "b.jpg",
                       "an instruction write must never rebuild the row around one field")
        XCTAssertEqual(store.extras(forEventId: "evt-2")?.instruction, video)
        XCTAssertEqual(store.count, 1)
    }

    func testLegacyExtrasDecodesWithNilInstruction() {
        // F-2: exactly what a pre-instruction build wrote — photo only.
        storage.write(key: storageKey,
                      value: ["evt-old": ["photoFilename": "a.jpg"]]
                          as [String: [String: String]])

        XCTAssertEqual(store.eventIds, ["evt-old"])
        XCTAssertEqual(store.extras(forEventId: "evt-old")?.photoFilename, "a.jpg")
        XCTAssertNil(store.extras(forEventId: "evt-old")?.instruction)

        // F-7: a malformed nested instruction costs the instruction, not
        // the row (design §4.6), which is exactly what `try?` buys.
        storage.write(key: storageKey,
                      value: ["evt-oops": ["instruction": "oops"]]
                          as [String: [String: String]])
        XCTAssertEqual(store.eventIds, ["evt-oops"])
        XCTAssertNil(store.extras(forEventId: "evt-oops")?.instruction)

        // F-10: an explicit null is an absent instruction, not a failure.
        storage.write(key: storageKey,
                      value: ["evt-null": ["instruction": nil]]
                          as [String: [String: String?]])
        XCTAssertEqual(store.eventIds, ["evt-null"])
        XCTAssertNil(store.extras(forEventId: "evt-null")?.instruction)
    }

    func testExtrasRoundTripWithBothFields() {
        let instruction = videoInstruction(filename: "round.mov",
                                           caption: "Before the walk")
        XCTAssertTrue(store.setPhotoFilename("round.jpg", forEventId: "evt-round"))
        XCTAssertTrue(store.setInstruction(instruction, forEventId: "evt-round"))

        // A second store over the same storage IS a relaunch: both fields
        // travel in the one encrypted payload.
        let reopened = EventExtrasStore(storage: storage)
        XCTAssertEqual(reopened.extras(forEventId: "evt-round")?.photoFilename,
                       "round.jpg")
        XCTAssertEqual(reopened.extras(forEventId: "evt-round")?.instruction,
                       instruction)
        XCTAssertEqual(reopened.count, 1)
    }

    // MARK: - Strict snapshot (IF-27)

    func testSnapshotReturnsEmptyWhenReadableEmpty() {
        // The key exists and decodes to `{}`: readable, with no rows.
        storage.write(key: storageKey, value: [String: EventExtras]())

        guard let snapshot = store.snapshot() else {
            return XCTFail("a readable empty index is an empty dictionary, not nil")
        }
        XCTAssertTrue(snapshot.isEmpty)
        // The legacy accessor still collapses to empty, unchanged.
        XCTAssertTrue(store.isEmpty)
    }

    func testSnapshotReturnsNilOnReadFailure() {
        // No key at all: the encrypted store reports a missing key as a
        // read failure, so the sweep must read "unknown", never "empty".
        XCTAssertNil(store.snapshot(),
                     "an absent key is a read failure — unknown, not an empty live set")

        // A payload this build cannot decode gets the same answer.
        storage.write(key: storageKey, value: "not an index at all")
        XCTAssertNil(store.snapshot())
        XCTAssertTrue(store.isEmpty,
                      "the legacy accessor keeps its empty-on-failure convenience")
    }

    // MARK: - Bool write seam (OI-1)

    func testSetInstructionReturnsFalseForMissingRow() {
        XCTAssertTrue(store.track(eventId: "evt-1"))
        let writesBefore = storage.writeCallCount

        XCTAssertFalse(store.setInstruction(videoInstruction(),
                                            forEventId: "evt-missing"),
                       "no row means the event is not ours; the store cannot upsert")

        XCTAssertEqual(storage.writeCallCount, writesBefore,
                       "a missing row must write nothing")
        XCTAssertNil(store.extras(forEventId: "evt-missing"),
                     "no row may be created for a missing event")
        XCTAssertEqual(store.eventIds, ["evt-1"],
                       "an unrelated row must be untouched")
    }

    func testSetInstructionReturnsTrueOnSuccess() {
        XCTAssertTrue(store.track(eventId: "evt-2"))
        let instruction = videoInstruction()

        XCTAssertTrue(store.setInstruction(instruction, forEventId: "evt-2"),
                      "the Bool seam reports a landed write")
        XCTAssertEqual(store.extras(forEventId: "evt-2")?.instruction, instruction)

        // Clearing is also a successful write on an existing row.
        XCTAssertTrue(store.setInstruction(nil, forEventId: "evt-2"))
        XCTAssertNil(store.extras(forEventId: "evt-2")?.instruction)
        XCTAssertEqual(store.count, 1)
    }

    // MARK: - Media ownership

    func testNoInstructionMediaIsDeletedByTheStore() {
        let deleteWatcher = DeleteWatchingEncryptedLocalStorage()
        let watchedStore = EventExtrasStore(storage: deleteWatcher)

        XCTAssertTrue(watchedStore.track(eventId: "evt-media"))
        XCTAssertTrue(watchedStore.setPhotoFilename("keep.jpg", forEventId: "evt-media"))
        XCTAssertTrue(watchedStore.setInstruction(videoInstruction(filename: "keep.mov"),
                                                  forEventId: "evt-media"))
        XCTAssertTrue(watchedStore.setInstruction(nil, forEventId: "evt-media"))

        // The mutation path really ran, so the empty delete log is not
        // vacuous: four writes landed, zero deletes occurred.
        XCTAssertEqual(deleteWatcher.writeCount, 4)
        XCTAssertTrue(deleteWatcher.deletedKeys.isEmpty,
                      "the index owner deletes no key here, and media bytes belong elsewhere")
        XCTAssertEqual(watchedStore.extras(forEventId: "evt-media")?.photoFilename,
                       "keep.jpg",
                       "an instruction change must not drop the photo row")

        // The store has no media path at all: deleting the photo or the
        // video needs the photo/video stores or the filesystem, and the
        // source must reach neither (design §2.12 item 6, T-014).
        let sourceURL = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/Services/Storage/EventExtrasStore.swift")
        let code = FeatureSourceScan.codeText(of: sourceURL)
        for forbidden in ["FileManager", "removeItem", "ContactPhotoStore",
                          "InstructionVideoStore", "EventPhotos"] {
            XCTAssertFalse(code.contains(forbidden),
                           "EventExtrasStore must not delete media; found \(forbidden)")
        }
    }
}

/// The stock encrypted-storage behaviour plus a delete/write witness.
/// The extras store owns the index row; the photo and video stores own
/// the bytes, so an instruction mutation has no business calling `delete`
/// or touching the filesystem at all. `MockEncryptedLocalStorage` is
/// `final`, so this composes one instead of subclassing it.
private final class DeleteWatchingEncryptedLocalStorage: EncryptedLocalStorage {
    private let base = MockEncryptedLocalStorage()

    private(set) var deletedKeys: [String] = []
    private(set) var writeCount = 0

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        writeCount += 1
        return base.write(key: key, value: value)
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        base.read(key: key, type: type)
    }

    func delete(key: String) -> Result<Void, StorageError> {
        deletedKeys.append(key)
        return base.delete(key: key)
    }
}
