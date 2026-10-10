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

    // MARK: - [SPOTIFY] (2026-10-06, C-SP-14) — kind round-trip + §21 contract

    func testSpotifyKindRoundTripsAcrossStoreInstances() {
        // The encrypted payload round-trips the raw string "spotify"; a
        // rawValue the enum cannot decode fails the WHOLE array decode
        // (loadLocked reads as empty), so this pins the storage contract,
        // not just the in-memory enum case.
        let storage = GeminiInMemoryStorage()
        let servedRemote = LocalToolLogEntry(kind: .spotify, query: "",
                                             response: "", outcome: "ok",
                                             statusCode: 204, durationMs: 431)
        let terminalHonest = LocalToolLogEntry(
            kind: .spotify, query: "",
            response: "Spotify is not available right now.", outcome: "fail")

        LocalToolLogStore(storage: storage).record(servedRemote)
        LocalToolLogStore(storage: storage).record(terminalHonest)

        let reloaded = LocalToolLogStore(storage: storage)
        XCTAssertEqual(reloaded.entries(), [terminalHonest, servedRemote],
                       "both §21 row shapes must survive the encrypted round trip")
        XCTAssertEqual(reloaded.entries().map(\.kind.rawValue),
                       ["spotify", "spotify"],
                       "the persisted kind string is 'spotify' — the stable storage/export contract")
    }

    func testSpotifyRowsRespectTheLogContract() throws {
        // Contract §21 / ADR-SP-15: query is "" in EVERY spotify row;
        // response is "" except the terminal honest line (the static
        // spoken fallback); the served remote path records 204, the
        // deep-link path nil. No query text, track title, track id,
        // token or provider body exists anywhere on the row — the shape
        // has no field that could carry one (NFR-SP-002).
        let store = LocalToolLogStore(storage: GeminiInMemoryStorage())
        let servedRemote = makeEntry(kind: .spotify, query: "", response: "",
                                     outcome: "ok", statusCode: 204)
        let servedDeepLink = makeEntry(kind: .spotify, query: "", response: "",
                                       outcome: "ok", statusCode: nil)
        let failedFallback = makeEntry(kind: .spotify, query: "", response: "",
                                       outcome: "fail", statusCode: 403)
        let terminalHonest = makeEntry(
            kind: .spotify, query: "",
            response: "Spotify is not available right now.", outcome: "fail")
        for entry in [servedRemote, servedDeepLink, failedFallback, terminalHonest] {
            store.record(entry)
        }

        // Newest first: the honest line was recorded last.
        XCTAssertEqual(store.entries(),
                       [terminalHonest, failedFallback, servedDeepLink, servedRemote],
                       "every §21 row shape must round-trip field-for-field")
        let rows = store.entries()
        XCTAssertTrue(rows.allSatisfy { $0.query.isEmpty },
                      "a spotify row must never carry query text (NFR-SP-002)")
        XCTAssertEqual(rows.filter { !$0.response.isEmpty }, [terminalHonest],
                       "only the terminal honest line carries a response")
        XCTAssertTrue(rows.allSatisfy { ["ok", "fail"].contains($0.outcome) },
                      "spotify rows use the ok/fail classifications of the §21 table")

        // The export must not grow a field that could carry provider
        // content, and must keep the query empty on every row.
        let url = try XCTUnwrap(store.exportJSON())
        let data = try Data(contentsOf: url)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let allowedKeys: Set<String> = ["id", "timestamp", "kind", "query",
                                        "response", "outcome", "statusCode", "durationMs"]
        XCTAssertEqual(parsed.count, 4, "every spotify row must be exported")
        for row in parsed {
            let unexpected = Set(row.keys).subtracting(allowedKeys)
            XCTAssertTrue(unexpected.isEmpty,
                          "unexpected exported fields \(unexpected.sorted()) — the row shape " +
                          "must not grow a field that could carry a token or provider body")
            XCTAssertEqual(row["kind"] as? String, "spotify")
            XCTAssertEqual(row["query"] as? String, "",
                           "the exported spotify row must keep query empty")
        }
        let exportedHonest = parsed.first { ($0["response"] as? String)?.isEmpty == false }
        XCTAssertEqual(exportedHonest?["response"] as? String,
                       terminalHonest.response,
                       "the one non-empty response is the terminal honest line, verbatim")
    }
}
