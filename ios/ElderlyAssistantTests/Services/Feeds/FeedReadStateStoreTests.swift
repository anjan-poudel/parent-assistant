import XCTest
@testable import ElderlyAssistant

/// Feed read-state store tests (feeds readaloud task, 2026-09-19) — the
/// persisted half of "mark as read when read aloud": encrypted storage,
/// idempotent writes, the bounded-id trim, and the honest empty default
/// (an absent or unreadable payload means "nothing read", never
/// "everything read").
final class FeedReadStateStoreTests: XCTestCase {

    // MARK: - Defaults

    func testAbsentPayloadReadsAsEmpty() {
        let store = FeedReadStateStore(storage: InMemoryStorage())
        XCTAssertEqual(store.load(), .empty)
        XCTAssertTrue(store.load().readIDs.isEmpty)
    }

    func testUnreadablePayloadReadsAsEmpty() {
        // A corrupt/undecodable payload must degrade to "nothing read" —
        // the honest failure mode (the elder sees an unread badge again),
        // never a crash and never "everything is read".
        XCTAssertEqual(FeedReadStateStore(storage: FailingReadStorage()).load(),
                       .empty)
    }

    // MARK: - Mark / persist

    func testMarkReadPersistsAcrossInstances() {
        let storage = InMemoryStorage()
        FeedReadStateStore(storage: storage).markRead(id: "item-1")
        let reloaded = FeedReadStateStore(storage: storage)
        XCTAssertEqual(reloaded.load().readIDs, ["item-1"])
    }

    func testMarkReadReturnsTheNewState() {
        let store = FeedReadStateStore(storage: InMemoryStorage())
        let state = store.markRead(id: "item-1")
        XCTAssertEqual(state.readIDs, ["item-1"])
        XCTAssertEqual(store.load().readIDs, ["item-1"])
    }

    func testMarkReadIsIdempotentAndKeepsOrder() {
        let store = FeedReadStateStore(storage: InMemoryStorage())
        store.markRead(id: "a")
        store.markRead(id: "b")
        store.markRead(id: "a")
        XCTAssertEqual(store.load().readIDs, ["a", "b"],
                       "re-marking an id must not duplicate or reorder it")
    }

    func testMarkUnreadRemovesOnlyThatID() {
        let store = FeedReadStateStore(storage: InMemoryStorage())
        store.markRead(id: "a")
        store.markRead(id: "b")
        XCTAssertEqual(store.markUnread(id: "a").readIDs, ["b"])
        XCTAssertEqual(store.load().readIDs, ["b"])
    }

    func testMarkUnreadOnUnknownIDIsANoOp() {
        let store = FeedReadStateStore(storage: InMemoryStorage())
        store.markRead(id: "a")
        XCTAssertEqual(store.markUnread(id: "zzz").readIDs, ["a"])
    }

    func testEmptyIDIsNeverTracked() {
        // An empty id would be a bucket every id-less item falls into —
        // the badge would claim "read" for items never heard.
        let store = FeedReadStateStore(storage: InMemoryStorage())
        XCTAssertTrue(store.markRead(id: "").readIDs.isEmpty)
        XCTAssertTrue(store.load().readIDs.isEmpty)
    }

    // MARK: - Bounds

    func testTrimKeepsTheMostRecentIDs() {
        let storage = InMemoryStorage()
        let store = FeedReadStateStore(storage: storage)
        let overflow = FeedReadStateStore.maxTrackedIDs + 1
        for index in 0..<overflow {
            store.markRead(id: "item-\(index)")
        }
        let state = store.load()
        XCTAssertEqual(state.readIDs.count, FeedReadStateStore.maxTrackedIDs,
                       "the store must stay bounded")
        XCTAssertFalse(state.readIDs.contains("item-0"),
                       "the OLDEST id is the one dropped")
        XCTAssertTrue(state.readIDs.contains("item-\(overflow - 1)"),
                      "the newest id survives the trim")
        XCTAssertEqual(state.readIDs.last, "item-\(overflow - 1)")
    }

    // MARK: - Write failure

    func testFailedWriteStillReturnsTheRequestedState() {
        // The badge must be honest for THIS launch even when the write
        // fails (the `FeedSettingsStore` policy: a failed persist is not
        // a failed action) — the caller publishes what it asked for.
        let store = FeedReadStateStore(storage: FailingWriteStorage())
        XCTAssertEqual(store.markRead(id: "item-1").readIDs, ["item-1"])
    }

    // MARK: - Storage key

    func testStorageKeyIsVersionedAndNamespaced() {
        // The payload format is the array ORDER (trim order), so a future
        // incompatible change must be able to move to a new key.
        XCTAssertEqual(FeedReadStateStore.storageKey, "feeds.read.v1")
    }
}

// MARK: - Test storage doubles

/// In-memory `EncryptedLocalStorage` (Keychain-backed in production).
private final class InMemoryStorage: EncryptedLocalStorage {
    private var values: [String: Data] = [:]

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        do {
            values[key] = try JSONEncoder().encode(value)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard let data = values[key] else { return .failure(.encryptedReadFailed) }
        do {
            return .success(try JSONDecoder().decode(T.self, from: data))
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        values.removeValue(forKey: key)
        return .success(())
    }
}

private final class FailingWriteStorage: EncryptedLocalStorage {
    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        .failure(.encryptedWriteFailed)
    }
    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        .failure(.encryptedReadFailed)
    }
    func delete(key: String) -> Result<Void, StorageError> {
        .failure(.encryptedWriteFailed)
    }
}

private final class FailingReadStorage: EncryptedLocalStorage {
    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        .success(())
    }
    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        .failure(.encryptedReadFailed)
    }
    func delete(key: String) -> Result<Void, StorageError> {
        .success(())
    }
}
