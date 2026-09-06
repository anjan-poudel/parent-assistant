import XCTest
@testable import ElderlyAssistant

/// Persistence + pagination for the locally cached conversation history
/// (local-cache-chat task, 2026-09-06): round-trip through
/// `EncryptedLocalStorage` under one key, the 200-entry cap, corrupt-
/// data tolerance, and the paging contract the "Last conversation"
/// sheet's Show-more button relies on (newest-20 window, older pages,
/// exhaustion).
final class ChatHistoryStoreTests: XCTestCase {

    /// Fixture exchange `i` — "e0", "e1", … with strictly increasing
    /// timestamps so ordering assertions read by text. Roles alternate so
    /// the user/assistant split round-trips too.
    private func exchange(_ i: Int) -> ChatHistoryStore.Exchange {
        ChatHistoryStore.Exchange(
            role: i % 2 == 0 ? .user : .assistant,
            text: "e\(i)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(i))
        )
    }

    private func append(_ store: ChatHistoryStore, count: Int) {
        for i in 0..<count {
            store.append(exchange(i))
        }
    }

    // MARK: - Persistence round-trip

    /// A second store over the SAME storage (a fresh launch) must see
    /// everything the first one appended — text, role, timestamp, and
    /// the persisted ids pagination slices on.
    func testPersistenceRoundTripAcrossStoreInstances() {
        let storage = StubEncryptedStorage()
        let first = ChatHistoryStore(storage: storage)
        append(first, count: 3)
        XCTAssertEqual(first.all.map(\.text), ["e0", "e1", "e2"])

        let relaunch = ChatHistoryStore(storage: storage)
        relaunch.load()
        XCTAssertEqual(relaunch.all, first.all)
        XCTAssertEqual(relaunch.recent(), first.all)
        // The ids survived the JSON round-trip, so id-based pagination
        // still finds boundaries after a relaunch.
        XCTAssertEqual(relaunch.older(than: relaunch.all[2].id).count, 2)
    }

    // MARK: - 200-entry cap (drop oldest)

    func testCapTrimsOldestBeyond200() {
        let storage = StubEncryptedStorage()
        let store = ChatHistoryStore(storage: storage)
        append(store, count: 205)

        XCTAssertEqual(store.all.count, ChatHistoryStore.cap)
        // e0…e4 dropped; the newest 200 survive in order.
        XCTAssertEqual(store.all.first?.text, "e5")
        XCTAssertEqual(store.all.last?.text, "e204")

        // The persisted file is trimmed too — a relaunch never sees the
        // dropped entries resurface.
        let relaunch = ChatHistoryStore(storage: storage)
        relaunch.load()
        XCTAssertEqual(relaunch.all, store.all)
    }

    /// Defensive: even a payload that somehow exceeds the cap on disk
    /// loads as the NEWEST 200 (same direction the append trim drops
    /// from), never a crash.
    func testLoadTrimsOversizedPayloadKeepingNewest() {
        let storage = RawDataStorage()
        storage.raw[ChatHistoryStore.storageKey] = try! JSONEncoder()
            .encode((0..<205).map(exchange))

        let store = ChatHistoryStore(storage: storage)
        store.load()
        XCTAssertEqual(store.all.count, ChatHistoryStore.cap)
        XCTAssertEqual(store.all.first?.text, "e5")
        XCTAssertEqual(store.all.last?.text, "e204")
    }

    // MARK: - Corrupt / missing data tolerance

    /// Missing key on first launch → empty history, and the first append
    /// still persists cleanly.
    func testMissingDataLoadsAsEmpty() {
        let store = ChatHistoryStore(storage: StubEncryptedStorage())
        store.load()
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertTrue(store.recent().isEmpty)
        XCTAssertEqual(store.older(than: UUID()).count, 0)

        store.append(exchange(0))
        XCTAssertEqual(store.all.map(\.text), ["e0"])
    }

    /// Garbage bytes under the storage key must read as an empty history
    /// (never a crash), and the store must be able to write over the
    /// corruption on the next append.
    func testCorruptDataLoadsAsEmptyAndRecovers() {
        let storage = RawDataStorage()
        storage.raw[ChatHistoryStore.storageKey] = Data("not-json-at-all".utf8)

        let store = ChatHistoryStore(storage: storage)
        store.load()
        XCTAssertTrue(store.all.isEmpty)

        store.append(exchange(0))
        let relaunch = ChatHistoryStore(storage: storage)
        relaunch.load()
        XCTAssertEqual(relaunch.all.map(\.text), ["e0"])
    }

    // MARK: - Pagination slicing

    /// The in-memory window (`conversationHistory` on the coordinator) is
    /// always the LAST 20 — even after 25 turns only e5…e24 are visible,
    /// exactly like the old ring buffer.
    func testRecentWindowKeepsOnlyLast20() {
        let store = ChatHistoryStore(storage: StubEncryptedStorage())
        append(store, count: 25)

        let window = store.recent()
        XCTAssertEqual(window.count, 20)
        XCTAssertEqual(window.first?.text, "e5")
        XCTAssertEqual(window.last?.text, "e24")
    }

    /// Show-more page 1: strictly older than the window's oldest row,
    /// returned oldest → newest in batches of 20.
    func testOlderPageLoadsNext20BeforeWindow() {
        let store = ChatHistoryStore(storage: StubEncryptedStorage())
        append(store, count: 55)
        let window = store.recent()
        XCTAssertEqual(window.first?.text, "e35")  // e35…e54 visible

        let page = store.older(than: window.first!.id)
        XCTAssertEqual(page.count, ChatHistoryStore.pageSize)
        XCTAssertEqual(page.first?.text, "e15")
        XCTAssertEqual(page.last?.text, "e34")
    }

    /// A partial final page returns what remains (fewer than 20), and
    /// paging past the oldest entry reports exhaustion with empty pages.
    func testOlderPagingExhaustsAtOldestEntry() {
        let store = ChatHistoryStore(storage: StubEncryptedStorage())
        append(store, count: 55)

        // Window e35…e54 → page 1 e15…e34 → page 2 e0…e14 (partial).
        let page1 = store.older(than: store.recent().first!.id)
        let page2 = store.older(than: page1.first!.id)
        XCTAssertEqual(page2.map(\.text), (0...14).map { "e\($0)" })

        // Exhausted: nothing older than the oldest entry, and the store
        // says so without a fetch.
        XCTAssertTrue(store.older(than: page2.first!.id).isEmpty)
        XCTAssertEqual(store.countOlder(than: page2.first!.id), 0)
    }

    /// When the stored count is an exact multiple of the page size, page
    /// 1 is a full 20 and page 2 is the empty exhaustion page.
    func testExactMultipleOfPageSizeStillExhausts() {
        let store = ChatHistoryStore(storage: StubEncryptedStorage())
        append(store, count: 40)

        let window = store.recent()  // e20…e39
        let page = store.older(than: window.first!.id)
        XCTAssertEqual(page.count, 20)
        XCTAssertEqual(page.first?.text, "e0")
        XCTAssertEqual(page.last?.text, "e19")
        XCTAssertTrue(store.older(than: page.first!.id).isEmpty)
    }

    /// A boundary id that is not in the store (unknown, or trimmed past
    /// the cap) must read as exhausted — empty page, zero count, no
    /// crash.
    func testUnknownBoundaryReadsAsExhausted() {
        let store = ChatHistoryStore(storage: StubEncryptedStorage())
        append(store, count: 5)
        XCTAssertTrue(store.older(than: UUID()).isEmpty)
        XCTAssertEqual(store.countOlder(than: UUID()), 0)
    }

    /// Custom page sizes slice the same way the 20-row default does
    /// (used by tests and kept honest by construction).
    func testOlderPageHonorsCustomLimit() {
        let store = ChatHistoryStore(storage: StubEncryptedStorage())
        append(store, count: 30)
        let window = store.recent()
        let page = store.older(than: window.first!.id, limit: 7)
        XCTAssertEqual(page.map(\.text), ["e3", "e4", "e5", "e6", "e7", "e8", "e9"])
    }
}

/// Storage double that lets a test plant RAW bytes under a key
/// (`StubEncryptedStorage` only accepts `Encodable` values) — needed to
/// prove the store tolerates corrupt payloads.
private final class RawDataStorage: EncryptedLocalStorage {
    var raw: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        do {
            raw[key] = try encoder.encode(value)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard let data = raw[key] else { return .failure(.encryptedReadFailed) }
        do {
            return .success(try decoder.decode(T.self, from: data))
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        raw.removeValue(forKey: key)
        return .success(())
    }
}
