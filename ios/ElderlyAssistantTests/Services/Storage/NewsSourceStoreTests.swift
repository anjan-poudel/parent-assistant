import XCTest
@testable import ElderlyAssistant

/// [NEWS-READER] (2026-09-08) `NewsSourceStore` unit tests:
///  - load round-trip (a configured list survives a store rebuild),
///  - CRUD: add / remove / save / clear with write-through semantics,
///  - the REPLACE rule: configured sources ARE the news; defaults apply
///    only while the configured list is empty,
///  - persist-first contract: a failed Keychain write changes nothing
///    in memory (the Settings editor can honestly report the failure),
///  - the curated defaults: 6 sources, mixed en + ne, all parseable
///    URLs, unique names.
final class NewsSourceStoreTests: XCTestCase {

    /// In-memory EncryptedLocalStorage double — same shape as the fakes
    /// in MorningBriefingTests (the real Keychain impl is exercised by
    /// the main-checkout integration build).
    private final class InMemoryStorage: EncryptedLocalStorage {
        var store: [String: Data] = [:]
        var failWrites = false

        private let encoder = JSONEncoder()
        private let decoder = JSONDecoder()

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard !failWrites else { return .failure(.encryptedWriteFailed) }
            store[key] = (try? encoder.encode(value)) ?? Data()
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            guard let data = store[key], let value = try? decoder.decode(type, from: data) else {
                return .failure(.encryptedReadFailed)
            }
            return .success(value)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            guard !failWrites else { return .failure(.encryptedWriteFailed) }
            store.removeValue(forKey: key)
            return .success(())
        }
    }

    private func source(_ name: String, url: String = "https://example.com/feed") -> NewsSource {
        NewsSource(name: name, urlString: url, languageCode: "en")
    }

    // MARK: - Load

    func testInitWithEmptyStorageHasNoConfiguredSources() {
        let store = NewsSourceStore(storage: InMemoryStorage())
        XCTAssertEqual(store.configuredSources, [])
        XCTAssertTrue(store.list().isEmpty)
    }

    func testConfiguredSourcesSurviveAStoreRebuild() {
        let storage = InMemoryStorage()
        let first = NewsSourceStore(storage: storage)
        let saved = [source("Family Blog", url: "https://family.example/rss")]
        XCTAssertTrue(first.save(saved))

        let rebuilt = NewsSourceStore(storage: storage)
        XCTAssertEqual(rebuilt.configuredSources, saved,
                       "a relaunch must restore the configured list")
    }

    // MARK: - REPLACE rule

    func testDefaultsApplyOnlyWhenNothingIsConfigured() {
        let store = NewsSourceStore(storage: InMemoryStorage())
        XCTAssertEqual(store.effectiveSources, NewsSourceStore.defaults,
                       "no configuration → the curated defaults")
    }

    func testConfiguredSourcesReplaceDefaultsEntirely() {
        let store = NewsSourceStore(storage: InMemoryStorage())
        let configured = [source("Family Blog", url: "https://family.example/rss")]
        _ = store.add(configured[0])
        XCTAssertEqual(store.effectiveSources, configured,
                       "one configured source replaces ALL defaults — never a merge")
    }

    func testClearingConfiguredSourcesFallsBackToDefaults() {
        let store = NewsSourceStore(storage: InMemoryStorage())
        _ = store.add(source("Family Blog", url: "https://family.example/rss"))
        XCTAssertTrue(store.clear())
        XCTAssertEqual(store.configuredSources, [])
        XCTAssertEqual(store.effectiveSources, NewsSourceStore.defaults)
    }

    // MARK: - CRUD

    func testAddAppendsAndPersists() {
        let store = NewsSourceStore(storage: InMemoryStorage())
        let a = source("A")
        let b = source("B")
        XCTAssertTrue(store.add(a))
        XCTAssertTrue(store.add(b))
        XCTAssertEqual(store.list(), [a, b], "order is the family's save order")
    }

    func testRemoveDeletesById() {
        let store = NewsSourceStore(storage: InMemoryStorage())
        let a = source("A")
        let b = source("B")
        _ = store.add(a)
        _ = store.add(b)
        XCTAssertTrue(store.remove(id: a.id))
        XCTAssertEqual(store.list(), [b])
    }

    func testRemoveUnknownIDFailsWithoutChangingTheList() {
        let store = NewsSourceStore(storage: InMemoryStorage())
        let a = source("A")
        _ = store.add(a)
        XCTAssertFalse(store.remove(id: UUID()))
        XCTAssertEqual(store.list(), [a])
    }

    func testSaveReplacesTheWholeList() {
        let store = NewsSourceStore(storage: InMemoryStorage())
        _ = store.add(source("Old"))
        let replacement = [source("New 1"), source("New 2")]
        XCTAssertTrue(store.save(replacement))
        XCTAssertEqual(store.list(), replacement)
    }

    // MARK: - Persist-first contract

    func testFailedWriteLeavesMemoryUnchanged() {
        let storage = InMemoryStorage()
        let store = NewsSourceStore(storage: storage)
        storage.failWrites = true
        XCTAssertFalse(store.add(source("Doomed")),
                       "a failed Keychain write must report failure")
        XCTAssertEqual(store.configuredSources, [],
                       "memory must not claim a source that is not on disk")
        storage.failWrites = false
        XCTAssertTrue(store.add(source("After recovery")))
        XCTAssertEqual(store.list().map(\.name), ["After recovery"])
    }

    func testFailedClearLeavesMemoryUnchanged() {
        let storage = InMemoryStorage()
        let store = NewsSourceStore(storage: storage)
        _ = store.add(source("Kept"))
        storage.failWrites = true
        XCTAssertFalse(store.clear())
        XCTAssertEqual(store.configuredSources.map(\.name), ["Kept"])
    }

    // MARK: - Curated defaults

    func testDefaultsAreSixMixedLanguageSourcesWithValidURLs() {
        let defaults = NewsSourceStore.defaults
        XCTAssertEqual(defaults.count, 6)
        XCTAssertEqual(defaults.filter { $0.languageCode == "en" }.count, 3)
        XCTAssertEqual(defaults.filter { $0.languageCode == "ne" }.count, 3)
        for source in defaults {
            XCTAssertTrue(source.isValid, "\(source.name) must carry a parseable URL")
        }
        XCTAssertEqual(Set(defaults.map(\.name)).count, defaults.count, "unique names")
        XCTAssertEqual(Set(defaults.map(\.urlString)).count, defaults.count, "unique URLs")
    }
}
