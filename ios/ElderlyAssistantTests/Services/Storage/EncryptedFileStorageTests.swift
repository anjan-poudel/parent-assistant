import XCTest
@testable import ElderlyAssistant

/// Unit tests for the encrypted file store ([BOOT-REVIEW P1-6],
/// 2026-09-10): the Data Protection class Complete, backup-excluded,
/// atomically written half of the storage split. Runs against a throwaway
/// directory (`rootDirectory:`) so nothing touches the real container and
/// no keychain is involved.
final class EncryptedFileStorageTests: XCTestCase {

    private var root: URL!
    private var storage: EncryptedFileStorage!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedFileStorageTests-\(UUID().uuidString)",
                                    isDirectory: true)
        storage = EncryptedFileStorage(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        storage = nil
        try super.tearDownWithError()
    }

    /// The store's own files (hidden entries like `.DS_Store` are not the
    /// store's business).
    private func storedFileNames() -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return all.filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: - Round trip

    func testWriteThenReadRoundTrips() {
        guard case .success = storage.write(key: "family.contacts",
                                            value: ["Maya", "Bishal"]) else {
            return XCTFail("write failed")
        }
        guard case .success(let value) = storage.read(key: "family.contacts",
                                                     type: [String].self) else {
            return XCTFail("read failed")
        }
        XCTAssertEqual(value, ["Maya", "Bishal"])
    }

    func testReadOfAnAbsentKeyFails() {
        guard case .failure = storage.read(key: "family.contacts",
                                          type: [String].self) else {
            return XCTFail("an absent key must read back as a failure")
        }
    }

    func testWriteOverwritesAtomically() {
        _ = storage.write(key: "routine.entries", value: ["morning"])
        _ = storage.write(key: "routine.entries", value: ["evening"])
        guard case .success(let value) = storage.read(key: "routine.entries",
                                                     type: [String].self) else {
            return XCTFail("read failed")
        }
        XCTAssertEqual(value, ["evening"])

        // The store holds exactly one file for the key — the atomic write
        // must not leave a temp/partial sibling behind.
        XCTAssertEqual(storedFileNames().count, 1)
    }

    func testDeleteRemovesTheValueAndToleratesAMissingKey() {
        _ = storage.write(key: "places.saved", value: ["Home"])
        guard case .success = storage.delete(key: "places.saved") else {
            return XCTFail("delete failed")
        }
        if case .success = storage.read(key: "places.saved", type: [String].self) {
            XCTFail("deleted value came back")
        }
        // Deleting again (or deleting a key that never existed) is fine.
        guard case .success = storage.delete(key: "places.saved") else {
            return XCTFail("deleting a missing key must not fail")
        }
        guard case .success = storage.delete(key: "never.written") else {
            return XCTFail("deleting a missing key must not fail")
        }
    }

    func testRawPayloadIsStoredVerbatim() {
        let bytes = Data("[ \"Maya\" ]".utf8)
        guard case .success = storage.writeRawData(bytes, key: "chat.history") else {
            return XCTFail("raw write failed")
        }
        XCTAssertEqual(storage.readRawData(key: "chat.history"), bytes,
                       "the raw payload is the migration's contract — it must "
                       + "not be re-encoded on the way in or out")
        guard case .success(let value) = storage.read(key: "chat.history",
                                                     type: [String].self) else {
            return XCTFail("decoding the raw payload failed")
        }
        XCTAssertEqual(value, ["Maya"])
    }

    // MARK: - Keys are not paths

    func testArbitraryKeyTextBecomesAHashFileName() {
        // The Nepali calendar plugin builds a key from the user's question.
        let key = "plugin.nepali_calendar.answer.आजको मिति? / today"
        _ = storage.write(key: key, value: "जवाफ")

        let files = storedFileNames()
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(files[0].contains("/"), "a key must never be a path")
        XCTAssertFalse(files[0].contains("आजको"))
        XCTAssertEqual(files[0], EncryptedFileStorage.fileName(for: key))
        XCTAssertTrue(files[0].hasSuffix(".json"))

        guard case .success(let value) = storage.read(key: key, type: String.self) else {
            return XCTFail("read failed")
        }
        XCTAssertEqual(value, "जवाफ")
    }

    func testTwoKeysThatDifferOnlyByCaseAreDistinct() {
        _ = storage.write(key: "feeds.config.v1", value: ["a"])
        _ = storage.write(key: "feeds.config.V1", value: ["b"])
        guard case .success(let lower) = storage.read(key: "feeds.config.v1",
                                                     type: [String].self),
              case .success(let upper) = storage.read(key: "feeds.config.V1",
                                                      type: [String].self) else {
            return XCTFail("read failed")
        }
        XCTAssertEqual(lower, ["a"])
        XCTAssertEqual(upper, ["b"])
    }

    func testAFileWhoseStoredKeyDiffersIsTreatedAsAbsent() throws {
        // Simulates a collided/renamed/foreign file: same hash file name,
        // different key inside the envelope.
        _ = storage.write(key: "family.contacts", value: ["Maya"])
        let file = root.appendingPathComponent(
            EncryptedFileStorage.fileName(for: "family.contacts"))
        let foreign = EncryptedFileStorage.Envelope(
            key: "some.other.key",
            payload: try JSONEncoder().encode(["Intruder"]))
        try JSONEncoder().encode(foreign).write(to: file)

        if case .success = storage.read(key: "family.contacts", type: [String].self) {
            XCTFail("a payload written under another key must not be served")
        }
    }

    // MARK: - Snapshot

    func testSnapshotPayloadsReturnsOnlyTheRequestedPresentKeys() {
        _ = storage.write(key: "family.contacts", value: ["Maya"])
        _ = storage.write(key: "places.saved", value: ["Home"])

        let snapshot = storage.snapshotPayloads(
            keys: ["family.contacts", "chat.history", "places.saved"])
        XCTAssertEqual(Set(snapshot.keys), ["family.contacts", "places.saved"])
        XCTAssertEqual(Set(storage.snapshotPayloads(keys: ["family.contacts"]).keys),
                       ["family.contacts"])
        XCTAssertTrue(storage.snapshotPayloads(keys: ["chat.history"]).isEmpty)
    }

    // MARK: - Protection

    func testStoreIsExcludedFromBackups() throws {
        _ = storage.write(key: "family.contacts", value: ["Maya"])
        let file = root.appendingPathComponent(
            EncryptedFileStorage.fileName(for: "family.contacts"))
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true,
                       "device-bound data must not travel in a backup, "
                       + "matching the Keychain's …ThisDeviceOnly")
    }

    // MARK: - Path stability

    func testASecondInstanceOverTheSameDirectorySeesTheSameValues() {
        _ = storage.write(key: "app.activity.log", value: ["opened"])
        let reopened = EncryptedFileStorage(rootDirectory: root)
        guard case .success(let value) = reopened.read(key: "app.activity.log",
                                                      type: [String].self) else {
            return XCTFail("a reopened store lost its data")
        }
        XCTAssertEqual(value, ["opened"])
    }

    func testUnresolvableRootMeansNothingIsWritten() {
        // A store that cannot resolve its directory must FAIL CLOSED —
        // writes fail (so a migration keeps the Keychain copy) instead of
        // quietly landing somewhere that does not survive a relaunch.
        let broken = EncryptedFileStorage(
            rootDirectory: URL(fileURLWithPath: "/dev/null/not-a-directory"))
        guard case .failure = broken.write(key: "family.contacts", value: ["Maya"]) else {
            return XCTFail("a write into an unusable directory must fail")
        }
        if case .success = broken.read(key: "family.contacts", type: [String].self) {
            XCTFail("nothing was stored — the read must fail")
        }
        XCTAssertNil(broken.readRawData(key: "family.contacts"))
    }
}
