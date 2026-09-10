import XCTest
@testable import ElderlyAssistant

final class GeminiConfigStoreTests: XCTestCase {

    func testStartsUnconfiguredWhenNothingStored() {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        XCTAssertFalse(store.isConfigured)
        XCTAssertNil(store.apiKey)
    }

    func testInitPerformsNoStorageReads() {
        // [BOOT-M1M2] Constant-time init: constructing the store must not
        // touch storage — the persisted values land via the deferred load.
        let storage = GeminiCountingStorage()
        let store = GeminiConfigStore(storage: storage)
        XCTAssertEqual(storage.readCount, 0)
        XCTAssertNil(store.apiKey)
    }

    func testSaveTrimsWhitespaceAndMarksConfigured() {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("  my-test-key  ")
        XCTAssertTrue(store.isConfigured)
        XCTAssertEqual(store.apiKey, "my-test-key")
    }

    func testSavingBlankStringClearsInsteadOfStoringEmpty() {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("real-key")
        store.save("   ")
        XCTAssertFalse(store.isConfigured)
        XCTAssertNil(store.apiKey)
    }

    func testClearRemovesTheKey() {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("real-key")
        store.clear()
        XCTAssertFalse(store.isConfigured)
    }

    func testDefaultsToFlashLiteModel() {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        XCTAssertEqual(store.model, GeminiConfigStore.defaultModel)
    }

    func testSaveModelPersistsAndUpdates() {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.saveModel("gemini-2.5-pro")
        XCTAssertEqual(store.model, "gemini-2.5-pro")
    }

    func testSaveModelIgnoresBlankInput() {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.saveModel("gemini-2.5-flash")
        store.saveModel("   ")
        XCTAssertEqual(store.model, "gemini-2.5-flash", "blank input should not overwrite a real selection")
    }

    func testModelPersistsAcrossInstances() {
        let storage = GeminiInMemoryStorage()
        GeminiConfigStore(storage: storage).saveModel("gemini-flash-latest")
        let reloaded = GeminiConfigStore(storage: storage)
        // [BOOT-M1M2] init must not read storage — the persisted model
        // lands via the deferred load.
        XCTAssertEqual(reloaded.model, GeminiConfigStore.defaultModel)

        let loaded = expectation(description: "deferred model load")
        reloaded.loadPersistedValues(on: DispatchQueue(label: "test.gemini.load")) {
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 1)
        XCTAssertEqual(reloaded.model, "gemini-flash-latest")
    }

    func testPersistsAcrossInstancesOverTheSameStorage() {
        let storage = GeminiInMemoryStorage()
        GeminiConfigStore(storage: storage).save("persisted-key")
        let reloaded = GeminiConfigStore(storage: storage)
        XCTAssertNil(reloaded.apiKey, "init must not read storage (constant-time init)")

        let loaded = expectation(description: "deferred key load")
        reloaded.loadPersistedValues(on: DispatchQueue(label: "test.gemini.load")) {
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 1)
        XCTAssertEqual(reloaded.apiKey, "persisted-key")
    }

    // MARK: - Deferred-load write protection ([BOOT-M1M2])

    func testDeferredLoadNeverClobbersAnEarlierKeySave() {
        let storage = GeminiInMemoryStorage()
        GeminiConfigStore(storage: storage).save("old-key") // what a load would read
        let store = GeminiConfigStore(storage: storage)
        store.save("user-key") // explicit user write, before the load lands

        let loaded = expectation(description: "deferred key load")
        store.loadPersistedValues(on: DispatchQueue(label: "test.gemini.load")) {
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 1)
        XCTAssertEqual(store.apiKey, "user-key",
                       "the user's explicit save must win over a deferred restore")
    }

    func testDeferredLoadNeverClobbersAnEarlierModelSave() {
        let storage = GeminiInMemoryStorage()
        GeminiConfigStore(storage: storage).saveModel("gemini-2.5-pro")
        let store = GeminiConfigStore(storage: storage)
        store.saveModel("gemini-2.5-flash")

        let loaded = expectation(description: "deferred model load")
        store.loadPersistedValues(on: DispatchQueue(label: "test.gemini.load")) {
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 1)
        XCTAssertEqual(store.model, "gemini-2.5-flash",
                       "the user's explicit save must win over a deferred restore")
    }

    func testDeferredLoadRunsOnce() {
        let storage = GeminiInMemoryStorage()
        GeminiConfigStore(storage: storage).save("persisted-key")
        let store = GeminiConfigStore(storage: storage)

        let first = expectation(description: "first load")
        store.loadPersistedValues(on: DispatchQueue(label: "test.gemini.load")) {
            first.fulfill()
        }
        wait(for: [first], timeout: 1)
        XCTAssertEqual(store.apiKey, "persisted-key")

        // A second kick is a no-op — the guard must never re-read.
        let readsBefore = storage.readCount
        store.loadPersistedValues(on: DispatchQueue(label: "test.gemini.load"))
        XCTAssertEqual(storage.readCount, readsBefore,
                       "a second load must not touch storage")
    }
}

/// In-memory `EncryptedLocalStorage` — mirrors the double used by
/// `FamilyContactStoreTests`; the real implementation is Keychain-backed
/// and untestable without a device context.
final class GeminiInMemoryStorage: EncryptedLocalStorage {
    private var values: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private(set) var readCount = 0

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        do {
            values[key] = try encoder.encode(value)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        readCount += 1
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

/// Counting-only `EncryptedLocalStorage` — the [BOOT-M1M2] init-IO guard:
/// asserts constructing a `GeminiConfigStore` performs zero reads.
private final class GeminiCountingStorage: EncryptedLocalStorage {
    private(set) var readCount = 0

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        .success(())
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        readCount += 1
        return .failure(.encryptedReadFailed)
    }

    func delete(key: String) -> Result<Void, StorageError> {
        .success(())
    }
}
