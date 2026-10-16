import XCTest
@testable import ElderlyAssistant

/// The `ProfilePayloadStorage.hasPayload` probe on the file store
/// (profile-interview, T-090, design §5.1). The probe exists to
/// distinguish "no payload" from "a payload that cannot be read": the
/// profile store must never read a file that is present-but-unreadable as
/// absent — that would silently re-interview a user whose record is
/// merely damaged. Runs against a throwaway directory root, plus a
/// deliberately broken FileManager for the unresolvable-root case.
final class EncryptedFileStorageProbeTests: XCTestCase {

    /// Overrides the Application Support resolution so
    /// `defaultRootDirectory` fails: the production route to a store with
    /// `rootDirectory == nil`. (Verified honored on the Darwin
    /// Foundation build; if a future platform ignores the override the
    /// nil case is still covered by the `hasPayload` contract below.)
    private final class FailingFileManager: FileManager {
        override func url(for directory: FileManager.SearchPathDirectory,
                          in domain: FileManager.SearchPathDomainMask,
                          appropriateFor url: URL?,
                          create shouldCreate: Bool) throws -> URL {
            throw NSError(domain: "EncryptedFileStorageProbeTests", code: 1)
        }
    }

    private var root: URL!
    private var storage: EncryptedFileStorage!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedFileStorageProbeTests-\(UUID().uuidString)",
                                    isDirectory: true)
        storage = EncryptedFileStorage(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        storage = nil
        try super.tearDownWithError()
    }

    private let key = "user.profile"

    func testProbeIsFalseForAnAbsentKey() {
        XCTAssertEqual(storage.hasPayload(key: key), false)
    }

    func testProbeIsTrueForAWrittenKey() {
        _ = storage.write(key: key, value: UserProfile(name: "Maya", addressAs: "Mum",
                                                       dateOfBirth: nil,
                                                       emergencyDoctor: nil,
                                                       localHospital: nil))
        XCTAssertEqual(storage.hasPayload(key: key), true)
        XCTAssertNotNil(storage.readRawData(key: key))
    }

    func testProbeIsTrueForACorruptEnvelopeFile() throws {
        // A file exists at the key's hash path but does not decode as the
        // envelope: present-but-unreadable. The probe must say true; the
        // raw read must say nil — the store maps that pair to
        // .unreadable, never .absent.
        let file = root.appendingPathComponent(EncryptedFileStorage.fileName(for: key))
        try Data("{ truncated".utf8).write(to: file)

        XCTAssertEqual(storage.hasPayload(key: key), true)
        XCTAssertNil(storage.readRawData(key: key))
        _ = storage.delete(key: key)
        XCTAssertEqual(storage.hasPayload(key: key), false,
                       "after the store discards the corrupt file the key "
                       + "reads as absent")
    }

    func testProbeIsTrueForAFileWrittenUnderADifferentKey() throws {
        // A collided/renamed/foreign file at the hash path: present for
        // the probe, not served by the raw read (the envelope key check),
        // and therefore unreadable — not absent — to the store.
        let file = root.appendingPathComponent(EncryptedFileStorage.fileName(for: key))
        let foreign = EncryptedFileStorage.Envelope(
            key: "some.other.key", payload: Data("value".utf8))
        try JSONEncoder().encode(foreign).write(to: file)

        XCTAssertEqual(storage.hasPayload(key: key), true)
        XCTAssertNil(storage.readRawData(key: key))
    }

    func testProbeIsNilWhenTheStoreRootIsUnresolvable() {
        // Application Support unavailable: the store location cannot be
        // resolved, so presence is UNKNOWABLE. nil — never false.
        let rootless = EncryptedFileStorage(fileManager: FailingFileManager())
        XCTAssertNil(rootless.hasPayload(key: key),
                     "an unresolvable root must never probe as absent")
        XCTAssertNil(rootless.readRawData(key: key))
        // And the fail-closed write path still holds.
        if case .success = rootless.write(key: key,
                                          value: UserProfile(name: "Maya",
                                                             addressAs: "Mum",
                                                             dateOfBirth: nil,
                                                             emergencyDoctor: nil,
                                                             localHospital: nil)) {
            XCTFail("a store without a root must fail its writes")
        }
    }
}
