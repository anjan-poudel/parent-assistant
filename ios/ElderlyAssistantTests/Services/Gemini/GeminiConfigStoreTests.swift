import XCTest
@testable import ElderlyAssistant

final class GeminiConfigStoreTests: XCTestCase {

    func testStartsUnconfiguredWhenNothingStored() {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        XCTAssertFalse(store.isConfigured)
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
        XCTAssertEqual(GeminiConfigStore(storage: storage).model, "gemini-flash-latest")
    }

    func testPersistsAcrossInstancesOverTheSameStorage() {
        let storage = GeminiInMemoryStorage()
        GeminiConfigStore(storage: storage).save("persisted-key")
        let reloaded = GeminiConfigStore(storage: storage)
        XCTAssertEqual(reloaded.apiKey, "persisted-key")
    }
}

/// In-memory `EncryptedLocalStorage` — mirrors the double used by
/// `FamilyContactStoreTests`; the real implementation is Keychain-backed
/// and untestable without a device context.
final class GeminiInMemoryStorage: EncryptedLocalStorage {
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
