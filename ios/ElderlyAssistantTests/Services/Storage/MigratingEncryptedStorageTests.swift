import XCTest
@testable import ElderlyAssistant

/// Guards the transactional Keychain → encrypted-file migration
/// ([BOOT-REVIEW P1-6], 2026-09-10). The rule under test is the safety
/// one, stated in the review:
///
///   "read existing Keychain payload → write+verify new encrypted store →
///    remove legacy item only on verified success"
///
/// so every failure path below must leave the Keychain copy — the only
/// copy — exactly where it was, and no path may delete it before the new
/// copy is proven readable.
final class MigratingEncryptedStorageTests: XCTestCase {

    // MARK: - Doubles

    /// Byte-level in-memory stand-in for the Keychain, with injectable
    /// delete failure (a locked-keychain / missing-entitlement case).
    private final class FakeKeychain: EncryptedLocalStorage, RawEncryptedStorage {
        var raw: [String: Data] = [:]
        var failDeletes = false
        private(set) var deleteCount = 0
        private(set) var readCount = 0
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
            readCount += 1
            guard let data = raw[key], let value = try? decoder.decode(type, from: data) else {
                return .failure(.encryptedReadFailed)
            }
            return .success(value)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            deleteCount += 1
            guard !failDeletes else { return .failure(.encryptedWriteFailed) }
            raw[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? { raw[key] }

        func writeRawData(_ data: Data, key: String) -> Result<Void, StorageError> {
            raw[key] = data
            return .success(())
        }
    }

    /// In-memory stand-in for the file store, with the two failure
    /// injections the migration must survive: writes that fail (store
    /// unavailable) and a read-back that does not return what was written
    /// (a copy that cannot be trusted).
    private final class FakeFileStore: MigratableFileStorage {
        var raw: [String: Data] = [:]
        var failWrites = false
        /// When true, `readRawData` never returns the stored bytes — the
        /// "written but not verifiable" case.
        var breakReadBack = false
        private(set) var readCount = 0
        private(set) var snapshotCount = 0
        private let encoder = JSONEncoder()
        private let decoder = JSONDecoder()

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard !failWrites else { return .failure(.encryptedWriteFailed) }
            do {
                raw[key] = try encoder.encode(value)
                return .success(())
            } catch {
                return .failure(.encryptedWriteFailed)
            }
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            readCount += 1
            guard let data = raw[key], let value = try? decoder.decode(type, from: data) else {
                return .failure(.encryptedReadFailed)
            }
            return .success(value)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            raw[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? {
            breakReadBack ? nil : raw[key]
        }

        func writeRawData(_ data: Data, key: String) -> Result<Void, StorageError> {
            guard !failWrites else { return .failure(.encryptedWriteFailed) }
            raw[key] = data
            return .success(())
        }

        func snapshotPayloads(keys: [String]) -> [String: Data] {
            snapshotCount += 1
            return keys.reduce(into: [:]) { result, key in
                result[key] = raw[key]
            }
        }
    }

    private func makeStorage(keychain: FakeKeychain = FakeKeychain(),
                             files: FakeFileStore = FakeFileStore())
        -> (MigratingEncryptedStorage, FakeKeychain, FakeFileStore) {
        (MigratingEncryptedStorage(keychain: keychain, files: files),
         keychain, files)
    }

    private let structuredKey = "family.contacts"
    private let secretKey = "gemini.apiKey"

    // MARK: - Migration

    func testLegacyValueIsReadAndMigratedOnFirstRead() {
        let (storage, keychain, files) = makeStorage()
        _ = keychain.write(key: structuredKey, value: ["Maya"])

        guard case .success(let value) = storage.read(key: structuredKey,
                                                     type: [String].self) else {
            return XCTFail("legacy read failed")
        }
        XCTAssertEqual(value, ["Maya"])
        XCTAssertNotNil(files.raw[structuredKey], "the file copy was not written")
        XCTAssertNil(keychain.raw[structuredKey],
                     "the Keychain copy must be removed only after the file "
                     + "copy verified")
    }

    func testMigrationCopiesThePayloadVerbatim() {
        let (storage, keychain, files) = makeStorage()
        // Valid JSON for the requested type, but NOT in the byte shape a
        // re-encode would produce (spaces, and JSONEncoder would emit
        // ["Maya"] compact). A migration that decoded and re-encoded would
        // fail this assertion.
        let legacyBytes = Data("[ \"Maya\" ]".utf8)
        keychain.raw[structuredKey] = legacyBytes

        guard case .success = storage.read(key: structuredKey,
                                           type: [String].self) else {
            return XCTFail("legacy read failed")
        }
        XCTAssertEqual(files.raw[structuredKey], legacyBytes,
                       "the migrated payload must be the bytes the Keychain "
                       + "held, not a re-encoding of the decoded value")
    }

    func testSecondReadIsServedFromTheFileStore() {
        let (storage, keychain, files) = makeStorage()
        _ = keychain.write(key: structuredKey, value: ["Maya"])
        _ = storage.read(key: structuredKey, type: [String].self)

        let keychainReadsAfterMigration = keychain.readCount
        guard case .success(let value) = storage.read(key: structuredKey,
                                                     type: [String].self) else {
            return XCTFail("post-migration read failed")
        }
        XCTAssertEqual(value, ["Maya"])
        XCTAssertEqual(keychain.readCount, keychainReadsAfterMigration,
                       "a migrated key must not be read from the Keychain again")
        XCTAssertNotNil(files.raw[structuredKey])
    }

    func testFileCopyWinsWhenBothCopiesExist() {
        let (storage, keychain, files) = makeStorage()
        _ = keychain.write(key: structuredKey, value: ["stale"])
        _ = files.write(key: structuredKey, value: ["current"])

        guard case .success(let value) = storage.read(key: structuredKey,
                                                     type: [String].self) else {
            return XCTFail("read failed")
        }
        XCTAssertEqual(value, ["current"],
                       "the file copy is authoritative — a surviving legacy "
                       + "item must not shadow it")
    }

    // MARK: - Failure paths keep the only copy

    func testUnverifiableFileCopyIsDroppedAndTheKeychainCopyKept() {
        let (storage, keychain, files) = makeStorage()
        _ = keychain.write(key: structuredKey, value: ["Maya"])
        files.breakReadBack = true

        guard case .success(let value) = storage.read(key: structuredKey,
                                                     type: [String].self) else {
            return XCTFail("the legacy value must still be returned")
        }
        XCTAssertEqual(value, ["Maya"])
        XCTAssertNil(files.raw[structuredKey],
                     "a copy that does not read back must not be left to "
                     + "shadow the Keychain value")
        XCTAssertNotNil(keychain.raw[structuredKey],
                        "the Keychain copy is the only trustworthy one — it "
                        + "must survive a failed verification")
    }

    func testUnavailableFileStoreLeavesTheKeychainUntouched() {
        let (storage, keychain, files) = makeStorage()
        _ = keychain.write(key: structuredKey, value: ["Maya"])
        files.failWrites = true

        for _ in 0..<3 {
            guard case .success(let value) = storage.read(key: structuredKey,
                                                         type: [String].self) else {
                return XCTFail("reads must keep working without the file store")
            }
            XCTAssertEqual(value, ["Maya"])
        }
        XCTAssertNotNil(keychain.raw[structuredKey])
    }

    func testWriteFallsBackToTheKeychainWhenTheFileStoreFails() {
        let (storage, keychain, files) = makeStorage()
        files.failWrites = true

        guard case .success = storage.write(key: structuredKey, value: ["Maya"]) else {
            return XCTFail("a write must not be lost when the file store is "
                           + "unavailable — durability must not regress")
        }
        XCTAssertNotNil(keychain.raw[structuredKey])
        guard case .success(let value) = storage.read(key: structuredKey,
                                                     type: [String].self) else {
            return XCTFail("read-back failed")
        }
        XCTAssertEqual(value, ["Maya"])
    }

    func testWriteAfterMigrationDropsASurvivingLegacyCopy() {
        let (storage, keychain, files) = makeStorage()
        // A legacy copy that outlived its migration (delete failed once).
        _ = keychain.write(key: structuredKey, value: ["old"])

        _ = storage.write(key: structuredKey, value: ["new"])
        XCTAssertNil(keychain.raw[structuredKey],
                     "the file holds the current value — a stale Keychain "
                     + "item could only resurrect on a fallback read")
        guard case .success(let value) = storage.read(key: structuredKey,
                                                     type: [String].self) else {
            return XCTFail("read-back failed")
        }
        XCTAssertEqual(value, ["new"])
    }

    // MARK: - Delete

    func testDeleteRemovesBothCopies() {
        let (storage, keychain, files) = makeStorage()
        _ = keychain.write(key: structuredKey, value: ["Maya"])
        _ = storage.read(key: structuredKey, type: [String].self)

        guard case .success = storage.delete(key: structuredKey) else {
            return XCTFail("delete failed")
        }
        XCTAssertNil(keychain.raw[structuredKey])
        XCTAssertNil(files.raw[structuredKey])
        // Deleted means deleted: no copy may resurrect it.
        if case .success = storage.read(key: structuredKey, type: [String].self) {
            XCTFail("a deleted key must read back as absent")
        }
    }

    func testFailedKeychainDeleteLeavesTheFileUntouched() {
        let (storage, keychain, files) = makeStorage()
        _ = files.write(key: structuredKey, value: ["Maya"])
        keychain.failDeletes = true

        guard case .failure = storage.delete(key: structuredKey) else {
            return XCTFail("a failed legacy delete must be reported")
        }
        XCTAssertNotNil(files.raw[structuredKey],
                        "the delete did not complete — the value must still "
                        + "be there, not half-removed")
        XCTAssertEqual(keychain.deleteCount, 1)
    }

    // MARK: - Secrets never touch the file store

    func testSecretKeysStayInTheKeychainAndOffTheFileStore() {
        let (storage, keychain, files) = makeStorage()

        guard case .success = storage.write(key: secretKey, value: "AIza-secret") else {
            return XCTFail("secret write failed")
        }
        guard case .success(let value) = storage.read(key: secretKey,
                                                     type: String.self) else {
            return XCTFail("secret read failed")
        }
        XCTAssertEqual(value, "AIza-secret")
        XCTAssertNotNil(keychain.raw[secretKey])
        XCTAssertNil(files.raw[secretKey], "a secret must never be written to disk")
        XCTAssertEqual(files.readCount, 0)

        guard case .success = storage.delete(key: secretKey) else {
            return XCTFail("secret delete failed")
        }
        XCTAssertNil(keychain.raw[secretKey])
    }

    // MARK: - Read snapshot

    func testSnapshotServesReadsWithOneStoreOpening() {
        let (storage, _, files) = makeStorage()
        _ = files.write(key: structuredKey, value: ["Maya"])
        _ = files.write(key: "places.saved", value: ["Home"])

        var fileReadsInside = -1
        storage.withReadSnapshot(keys: [structuredKey, "places.saved", secretKey]) {
            guard case .success(let contacts) = storage.read(key: structuredKey,
                                                            type: [String].self),
                  case .success(let places) = storage.read(key: "places.saved",
                                                           type: [String].self) else {
                return XCTFail("snapshot read failed")
            }
            XCTAssertEqual(contacts, ["Maya"])
            XCTAssertEqual(places, ["Home"])
            fileReadsInside = files.readCount
        }
        XCTAssertEqual(files.snapshotCount, 1,
                       "the batch must open the store once")
        XCTAssertEqual(fileReadsInside, 0,
                       "a snapshotted read must not touch the file store again")
    }

    func testSnapshotDoesNotServeKeysOutsideIt() {
        let (storage, _, files) = makeStorage()
        _ = files.write(key: "chat.history", value: ["Maya"])

        storage.withReadSnapshot(keys: [structuredKey]) {
            guard case .success = storage.read(key: "chat.history",
                                               type: [String].self) else {
                return XCTFail("a key outside the snapshot must still read")
            }
        }
        XCTAssertEqual(files.readCount, 1)
    }

    func testWriteDuringASnapshotInvalidatesTheCachedPayload() {
        let (storage, _, files) = makeStorage()
        _ = files.write(key: structuredKey, value: ["old"])

        storage.withReadSnapshot(keys: [structuredKey]) {
            _ = storage.write(key: structuredKey, value: ["new"])
            guard case .success(let value) = storage.read(key: structuredKey,
                                                         type: [String].self) else {
                return XCTFail("read failed")
            }
            XCTAssertEqual(value, ["new"],
                           "a write must not be masked by the snapshot it "
                           + "superseded")
        }
    }

    func testSnapshotUnwindsAfterTheBatch() {
        let (storage, _, files) = makeStorage()
        _ = files.write(key: structuredKey, value: ["Maya"])

        storage.withReadSnapshot(keys: [structuredKey]) { }
        let before = files.readCount
        _ = storage.read(key: structuredKey, type: [String].self)
        XCTAssertEqual(files.readCount, before + 1,
                       "the snapshot must not outlive its batch")
    }
}
