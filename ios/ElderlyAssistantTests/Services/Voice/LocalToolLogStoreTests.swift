import XCTest
@testable import ElderlyAssistant

/// `LocalToolLogStore` unit tests (tool-debug-log, 2026-09-07): the
/// encrypted single-key array store behind Settings → Tool requests.
/// `GeminiInMemoryStorage` doubles the Keychain-backed
/// `EncryptedLocalStorage` (the real channel needs a device context —
/// the same double the FamilyContactStore/ChatHistoryStore tests use),
/// which makes the corrupt-payload case scriptable: junk bytes under the
/// exact storage key must read back as an EMPTY log, never a crash.
final class LocalToolLogStoreTests: XCTestCase {

    private func makeEntry(kind: LocalToolLogEntry.Kind = .weather,
                           query: String = "मौसम कस्तो छ?",
                           response: String = "It's 24°C and clear.",
                           outcome: String = "ok",
                           statusCode: Int? = nil,
                           durationMs: Int? = nil) -> LocalToolLogEntry {
        LocalToolLogEntry(kind: kind, query: query, response: response,
                          outcome: outcome, statusCode: statusCode,
                          durationMs: durationMs)
    }

    func testRecordRoundTripsEveryField() {
        let store = LocalToolLogStore(storage: GeminiInMemoryStorage())
        let entry = makeEntry(kind: .search, query: "what is the capital of France",
                              response: "France is a country…", outcome: "ok",
                              statusCode: 200, durationMs: 812)

        store.record(entry)

        XCTAssertEqual(store.entries(), [entry],
                       "the recorded entry must round-trip field-for-field, id and timestamp included")
    }

    func testRecordPersistsAcrossStoreInstancesOverTheSameStorage() {
        let storage = GeminiInMemoryStorage()
        let entry = makeEntry(query: "भोलि काठमाडौंमा पानी पर्छ?", outcome: "fallback")
        LocalToolLogStore(storage: storage).record(entry)

        let reloaded = LocalToolLogStore(storage: storage)
        XCTAssertEqual(reloaded.entries(), [entry],
                       "a fresh store over the same storage must read the persisted entry")
    }

    func testEntriesAreNewestFirst() {
        let store = LocalToolLogStore(storage: GeminiInMemoryStorage())
        store.record(makeEntry(query: "oldest"))
        store.record(makeEntry(query: "middle"))
        store.record(makeEntry(query: "newest"))

        XCTAssertEqual(store.entries().map(\.query), ["newest", "middle", "oldest"])
    }

    func testCapPrunesTheOldestEntriesAt200() {
        let store = LocalToolLogStore(storage: GeminiInMemoryStorage())
        for index in 0..<205 {
            store.record(makeEntry(query: "q-\(index)"))
        }

        let entries = store.entries()
        XCTAssertEqual(entries.count, LocalToolLogStore.maxEntries,
                       "the store must never hold more than the 200-entry cap")
        XCTAssertEqual(entries.first?.query, "q-204",
                       "the NEWEST entry survives the prune")
        XCTAssertEqual(entries.last?.query, "q-5",
                       "exactly the five oldest entries (q-0…q-4) are dropped")
    }

    func testCorruptPayloadLoadsEmptyAndRecoversOnTheNextRecord() {
        let storage = GeminiInMemoryStorage()
        // Plant junk under the exact storage key the store reads — the
        // decode must fail into an EMPTY log, not a crash.
        _ = storage.write(key: LocalToolLogStore.storageKey, value: "not-an-entry-array")

        let store = LocalToolLogStore(storage: storage)
        XCTAssertEqual(store.entries(), [],
                       "a corrupt payload must read as an empty log")

        let entry = makeEntry(query: "what is the capital of France", outcome: "ok")
        store.record(entry)
        XCTAssertEqual(store.entries(), [entry],
                       "the next record must overwrite the corrupt payload and recover")
    }

    func testExportJSONWritesAValidJSONArrayWhenEntriesExist() throws {
        let store = LocalToolLogStore(storage: GeminiInMemoryStorage())
        store.record(makeEntry(kind: .weather, query: "भोलिको मौसम कस्तो छ?", outcome: "fail"))
        store.record(makeEntry(kind: .search, query: "what is the capital of France",
                               outcome: "cap", statusCode: nil))

        let url = try XCTUnwrap(store.exportJSON())
        let data = try Data(contentsOf: url)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        XCTAssertEqual(parsed.count, 2, "every logged entry must be exported")
        XCTAssertEqual(parsed[0]["query"] as? String, "भोलिको मौसम कस्तो छ?",
                       "export order is oldest → newest (the store's internal order)")
        XCTAssertEqual(parsed[0]["outcome"] as? String, "fail")
        XCTAssertEqual(parsed[1]["outcome"] as? String, "cap")
        XCTAssertEqual(parsed[1]["kind"] as? String, "search")
        XCTAssertNotNil(parsed[0]["timestamp"], "timestamps must be present in the export")
    }

    func testExportJSONIsNilWhenNothingIsLogged() {
        let store = LocalToolLogStore(storage: GeminiInMemoryStorage())
        XCTAssertNil(store.exportJSON())
    }
}
