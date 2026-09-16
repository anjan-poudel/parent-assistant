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
}
