import XCTest
@testable import ElderlyAssistant

/// Per-contact Messenger handle capture (deep-link fix, 2026-09-07):
/// Messenger has no phone-number thread link, so the row's pill stores
/// the person's username once and opens the real thread from then on.
final class MessengerHandleStoreTests: XCTestCase {

    func testRoundTripsHandleAcrossInstances() {
        let storage = StubEncryptedStorage()
        let writer = MessengerHandleStore(storage: storage)
        XCTAssertTrue(writer.set(handle: "sita.sharma", forNormalizedPhone: "9841000001"))
        // A second instance over the same storage sees the write —
        // exactly the app's restart shape.
        let reader = MessengerHandleStore(storage: storage)
        XCTAssertEqual(reader.handle(forNormalizedPhone: "9841000001"), "sita.sharma")
    }

    func testMissingPhoneReturnsNil() {
        let storage = StubEncryptedStorage()
        let store = MessengerHandleStore(storage: storage)
        XCTAssertNil(store.handle(forNormalizedPhone: "9841000001"))
        XCTAssertNil(store.handle(forNormalizedPhone: ""))
    }

    func testOverwriteReplacesHandle() {
        let storage = StubEncryptedStorage()
        let store = MessengerHandleStore(storage: storage)
        store.set(handle: "sita.sharma", forNormalizedPhone: "9841000001")
        store.set(handle: "sita123", forNormalizedPhone: "9841000001")
        XCTAssertEqual(store.handle(forNormalizedPhone: "9841000001"), "sita123")
    }

    func testEmptyNormalizedPhoneNeverStored() {
        let storage = StubEncryptedStorage()
        let store = MessengerHandleStore(storage: storage)
        XCTAssertFalse(store.set(handle: "anything", forNormalizedPhone: ""))
        XCTAssertNil(store.handle(forNormalizedPhone: ""))
    }

    func testDistinctPhonesKeepDistinctHandles() {
        let storage = StubEncryptedStorage()
        let store = MessengerHandleStore(storage: storage)
        store.set(handle: "sita.sharma", forNormalizedPhone: "9841000001")
        store.set(handle: "hari.thapa", forNormalizedPhone: "9841000002")
        XCTAssertEqual(store.handle(forNormalizedPhone: "9841000001"), "sita.sharma")
        XCTAssertEqual(store.handle(forNormalizedPhone: "9841000002"), "hari.thapa")
    }
}
