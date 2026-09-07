import XCTest
@testable import ElderlyAssistant

/// Per-contact calling-channel preferences for ADDRESS-BOOK rows — the
/// row channel chooser's persistence (Phone-tab redesign, 2026-09-07).
/// Exercises the plain [String: String] payload shape, including the
/// store's two corruption contracts: an undecodable payload reads as
/// nil-and-recoverable, and a decodable payload holding an unknown
/// channel raw value drops that entry on read (never a crash).
final class ChannelPreferenceStoreTests: XCTestCase {

    func testRoundtripsPreferenceAcrossInstances() {
        let storage = RawDataStorage()
        let writer = ChannelPreferenceStore(storage: storage)
        XCTAssertTrue(writer.set(.whatsApp, forNormalizedPhone: "9841000001"))
        // A second instance over the same storage sees the write —
        // exactly the app's restart shape.
        let reader = ChannelPreferenceStore(storage: storage)
        XCTAssertEqual(reader.preference(forNormalizedPhone: "9841000001"), .whatsApp)
    }

    func testMissingPhoneReturnsNil() {
        let storage = RawDataStorage()
        let store = ChannelPreferenceStore(storage: storage)
        XCTAssertNil(store.preference(forNormalizedPhone: "9841000001"))
        XCTAssertNil(store.preference(forNormalizedPhone: ""))
    }

    func testOverwriteReplacesPreference() {
        let storage = RawDataStorage()
        let store = ChannelPreferenceStore(storage: storage)
        store.set(.faceTime, forNormalizedPhone: "9841000001")
        store.set(.phone, forNormalizedPhone: "9841000001")
        XCTAssertEqual(store.preference(forNormalizedPhone: "9841000001"), .phone)
    }

    func testEmptyNormalizedPhoneNeverStored() {
        let storage = RawDataStorage()
        let store = ChannelPreferenceStore(storage: storage)
        XCTAssertFalse(store.set(.phone, forNormalizedPhone: ""))
        XCTAssertNil(store.preference(forNormalizedPhone: ""))
    }

    func testDistinctPhonesKeepDistinctPreferences() {
        let storage = RawDataStorage()
        let store = ChannelPreferenceStore(storage: storage)
        store.set(.messenger, forNormalizedPhone: "9841000001")
        store.set(.whatsApp, forNormalizedPhone: "9841000002")
        XCTAssertEqual(store.preference(forNormalizedPhone: "9841000001"), .messenger)
        XCTAssertEqual(store.preference(forNormalizedPhone: "9841000002"), .whatsApp)
    }

    func testRemoveDeletesEntryAcrossInstances() {
        let storage = RawDataStorage()
        let store = ChannelPreferenceStore(storage: storage)
        store.set(.faceTime, forNormalizedPhone: "9841000001")
        XCTAssertTrue(store.remove(forNormalizedPhone: "9841000001"))
        XCTAssertNil(store.preference(forNormalizedPhone: "9841000001"))
        // Removal persisted — a relaunched instance still sees it gone.
        XCTAssertNil(ChannelPreferenceStore(storage: storage)
            .preference(forNormalizedPhone: "9841000001"))
    }

    func testRemoveOfPhoneWithNoEntryIsNoOpSuccess() {
        let storage = RawDataStorage()
        let store = ChannelPreferenceStore(storage: storage)
        XCTAssertTrue(store.remove(forNormalizedPhone: "9841000001"))
        XCTAssertFalse(store.remove(forNormalizedPhone: ""))
    }

    /// A payload whose raw value names no `CallApp` case (an app removed
    /// from the enum, or a hand-edited payload) must read as nil for
    /// that phone — never a crash, and never a stale channel — while
    /// the well-formed entries beside it keep reading.
    func testUnknownRawValuesAreDroppedOnRead() throws {
        let storage = RawDataStorage()
        let payload = try JSONEncoder().encode([
            "9841000001": "telegram",  // names no CallApp case
            "9841000002": CallApp.whatsApp.rawValue
        ])
        storage.raw[ChannelPreferenceStore.storageKey] = payload

        let store = ChannelPreferenceStore(storage: storage)
        XCTAssertNil(store.preference(forNormalizedPhone: "9841000001"))
        XCTAssertEqual(store.preference(forNormalizedPhone: "9841000002"), .whatsApp)
    }

    /// Garbage bytes under the storage key must read as nil (never a
    /// crash), and the store must be able to write over the corruption
    /// on the next pick.
    func testCorruptPayloadReadsNilAndRecovers() {
        let storage = RawDataStorage()
        storage.raw[ChannelPreferenceStore.storageKey] = Data("not-json-at-all".utf8)

        let store = ChannelPreferenceStore(storage: storage)
        XCTAssertNil(store.preference(forNormalizedPhone: "9841000001"))

        XCTAssertTrue(store.set(.faceTime, forNormalizedPhone: "9841000001"))
        let relaunch = ChannelPreferenceStore(storage: storage)
        XCTAssertEqual(relaunch.preference(forNormalizedPhone: "9841000001"), .faceTime)
    }
}

/// Storage double that lets a test plant RAW bytes under a key
/// (`StubEncryptedStorage` only accepts `Encodable` values) — needed to
/// prove the store tolerates corrupt payloads. Mirrors the private
/// double in AppActivityLogTests / ChatHistoryStoreTests.
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
