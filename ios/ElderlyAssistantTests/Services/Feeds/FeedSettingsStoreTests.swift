import XCTest
@testable import ElderlyAssistant

/// Feed settings store tests (feed-agent task, 2026-09-08) — curated
/// default seeding, source/topic CRUD, caps, validation, and the
/// never-re-seed-over-user-choices rule.
final class FeedSettingsStoreTests: XCTestCase {

    // MARK: - Seeding

    func testFirstLoadSeedsCuratedDefaults() {
        let store = FeedSettingsStore(storage: InMemoryStorage())
        let config = store.load()
        XCTAssertEqual(config.sources, FeedSettingsStore.curatedDefaults)
        XCTAssertTrue(config.topics.isEmpty)
    }

    func testSeedPersistsAcrossInstances() {
        let storage = InMemoryStorage()
        FeedSettingsStore(storage: storage).load()
        let reloaded = FeedSettingsStore(storage: storage).load()
        XCTAssertEqual(reloaded.sources, FeedSettingsStore.curatedDefaults)
    }

    func testUserRemovingAllDefaultsIsNeverReseeded() {
        let storage = InMemoryStorage()
        let store = FeedSettingsStore(storage: storage)
        for source in store.load().sources {
            XCTAssertTrue(store.removeSource(id: source.id))
        }
        // Re-read through a FRESH instance: the user's empty config must
        // survive — seeding happens once ever, not on every read.
        let reloaded = FeedSettingsStore(storage: storage).load()
        XCTAssertTrue(reloaded.sources.isEmpty)
    }

    func testCuratedDefaultsCoverEveryFeedKind() {
        // One default per kind is the point of the curated set (mixed
        // feed out of the box): at least one image source and one audio
        // source exist among the defaults.
        let defaults = FeedSettingsStore.curatedDefaults
        XCTAssertFalse(defaults.isEmpty)
        XCTAssertTrue(defaults.contains { $0.name == "NASA Image of the Day" })
        XCTAssertTrue(defaults.contains { $0.name == "NPR News" })
        // All default URLs are valid feed URLs (the store's own gate).
        XCTAssertTrue(defaults.allSatisfy {
            FeedSettingsStore.isValidFeedURL($0.urlString)
        })
    }

    // MARK: - Source CRUD

    func testAddSourceAppearsInLoad() {
        let store = emptyStore()
        XCTAssertTrue(store.addSource(name: "My Blog",
                                      urlString: "https://blog.example.com/rss.xml"))
        XCTAssertTrue(store.load().sources.contains {
            $0.name == "My Blog" && $0.urlString == "https://blog.example.com/rss.xml"
                && !$0.isCuratedDefault
        })
    }

    func testRemoveSourceById() {
        let store = FeedSettingsStore(storage: InMemoryStorage())
        let defaults = store.load().sources
        XCTAssertTrue(store.removeSource(id: defaults[0].id))
        XCTAssertFalse(store.load().sources.contains { $0.id == defaults[0].id })
    }

    func testDuplicateURLIsRejected() {
        let store = emptyStore()
        XCTAssertTrue(store.addSource(name: "A", urlString: "https://a.example.com/rss"))
        XCTAssertFalse(store.addSource(name: "B", urlString: "https://a.example.com/rss"))
        XCTAssertEqual(store.load().sources.filter {
            $0.urlString == "https://a.example.com/rss"
        }.count, 1)
    }

    func testEmptyNameOrURLIsRejected() {
        let store = emptyStore()
        XCTAssertFalse(store.addSource(name: "", urlString: "https://a.example.com/rss"))
        XCTAssertFalse(store.addSource(name: "A", urlString: "   "))
    }

    func testSourceCapRejectsBeyondMax() {
        let store = emptyStore()
        for index in 0..<FeedSettingsStore.maxSources {
            XCTAssertTrue(store.addSource(name: "S\(index)",
                                          urlString: "https://s\(index).example.com/rss"))
        }
        XCTAssertFalse(store.addSource(name: "Over",
                                       urlString: "https://over.example.com/rss"))
        XCTAssertEqual(store.load().sources.count, FeedSettingsStore.maxSources)
    }

    // MARK: - URL validation

    func testValidFeedURLsPass() {
        XCTAssertTrue(FeedSettingsStore.isValidFeedURL("https://example.com/feed.xml"))
        XCTAssertTrue(FeedSettingsStore.isValidFeedURL("http://example.com/feed"))
    }

    func testInvalidFeedURLsFail() {
        XCTAssertFalse(FeedSettingsStore.isValidFeedURL("not a url"))
        XCTAssertFalse(FeedSettingsStore.isValidFeedURL("ftp://example.com/feed"))
        XCTAssertFalse(FeedSettingsStore.isValidFeedURL("https://"))
        XCTAssertFalse(FeedSettingsStore.isValidFeedURL(""))
    }

    // MARK: - Topic CRUD

    func testAddAndRemoveTopic() {
        let store = emptyStore()
        XCTAssertTrue(store.addTopic("health"))
        XCTAssertTrue(store.addTopic("स्वास्थ्य"))
        XCTAssertEqual(store.load().topics, ["health", "स्वास्थ्य"])
        XCTAssertTrue(store.removeTopic("health"))
        XCTAssertEqual(store.load().topics, ["स्वास्थ्य"])
    }

    func testDuplicateTopicRejectedCaseInsensitively() {
        let store = emptyStore()
        XCTAssertTrue(store.addTopic("Health"))
        XCTAssertFalse(store.addTopic("health"))
        XCTAssertFalse(store.addTopic("HEALTH"))
        XCTAssertEqual(store.load().topics.count, 1)
    }

    func testEmptyTopicRejected() {
        let store = emptyStore()
        XCTAssertFalse(store.addTopic("   "))
        XCTAssertTrue(store.load().topics.isEmpty)
    }

    func testTopicCapRejectsBeyondMax() {
        let store = emptyStore()
        for index in 0..<FeedSettingsStore.maxTopics {
            XCTAssertTrue(store.addTopic("topic\(index)"))
        }
        XCTAssertFalse(store.addTopic("over"))
        XCTAssertEqual(store.load().topics.count, FeedSettingsStore.maxTopics)
    }

    // MARK: - Storage failure behavior

    func testFailingStorageNeverClaimsSuccess() {
        let store = FeedSettingsStore(storage: FailingStorage())
        // Seeding write fails — load still returns the defaults (the
        // in-memory seed is the honest fallback) but every mutation
        // reports false.
        XCTAssertEqual(store.load().sources, FeedSettingsStore.curatedDefaults)
        XCTAssertFalse(store.addSource(name: "A", urlString: "https://a.example.com/rss"))
        XCTAssertFalse(store.addTopic("health"))
    }

    // MARK: - Helpers

    /// A store with the curated defaults removed (controlled fixtures).
    private func emptyStore() -> FeedSettingsStore {
        let store = FeedSettingsStore(storage: InMemoryStorage())
        for source in store.load().sources {
            _ = store.removeSource(id: source.id)
        }
        return store
    }

    func testNameSuggesterDerivesFromHost() {
        XCTAssertEqual(FeedSourceNameSuggester.name(from: "https://feeds.bbci.co.uk/news/rss.xml"),
                       "Bbci.co.uk")
        XCTAssertEqual(FeedSourceNameSuggester.name(from: "https://www.nasa.gov/feeds/iotd-feed/"),
                       "Nasa.gov")
        XCTAssertEqual(FeedSourceNameSuggester.name(from: "not a url"), "")
    }
}

// MARK: - Test storage doubles

/// In-memory `EncryptedLocalStorage` (Keychain-backed in production).
private final class InMemoryStorage: EncryptedLocalStorage {
    private var values: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        do {
            values[key] = try encoder.encode(value)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard let data = values[key] else { return .failure(.encryptedReadFailed) }
        do {
            return .success(try decoder.decode(T.self, from: data))
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        values.removeValue(forKey: key)
        return .success(())
    }
}

private final class FailingStorage: EncryptedLocalStorage {
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
