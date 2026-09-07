import XCTest
@testable import ElderlyAssistant

final class FamilyContactStoreTests: XCTestCase {

    func testAddLoadRoundTrip() {
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "राम", phone: "9812345678", relationship: "छोरा")
        XCTAssertTrue(store.add(contact))

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "राम")
        XCTAssertEqual(loaded.first?.phone, "9812345678")
    }

    func testMaxContactsEnforcedAtTwelve() {
        // (family-and-friends task, 2026-09-07) The cap was raised from
        // 3 to 12 — "Family and friends" is now the primary curated list,
        // not just the emergency trio. The onboarding flow keeps its own
        // 1–3 collection regardless; this cap bounds the Settings editor.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        for i in 0..<13 {
            let added = store.add(FamilyContact(name: "सम्पर्क \(i)",
                                                phone: "98\(i)",
                                                relationship: "परिवार"))
            if i < 12 {
                XCTAssertTrue(added, "contact \(i) should have been accepted")
            } else {
                XCTAssertFalse(added, "13th contact must be rejected")
            }
        }
        XCTAssertEqual(store.load().count, 12)
    }

    func testRemoveDeletesOnlyTarget() {
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let a = FamilyContact(name: "अ", phone: "1", relationship: "छोरा")
        let b = FamilyContact(name: "ब", phone: "2", relationship: "छोरी")
        store.add(a)
        store.add(b)

        XCTAssertTrue(store.remove(id: a.id))
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, b.id)
    }

    func testEmptyWhenNothingStored() {
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        XCTAssertTrue(store.load().isEmpty)
    }

    func testMessengerHandleRoundTrips() {
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "सीता", phone: "9812345678",
                                    relationship: "छोरी",
                                    messengerHandle: "sita.sharma77")
        XCTAssertTrue(store.add(contact))

        let loaded = store.load()
        XCTAssertEqual(loaded.first?.messengerHandle, "sita.sharma77")
    }

    func testPhotoFilenameRoundTrips() {
        // (family-and-friends task, 2026-09-07) The contact stores only
        // the ContactPhotoStore file NAME — never a path — and a contact
        // without a photo simply has nil.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "गीता", phone: "9812345678",
                                    relationship: "छोरी",
                                    photoFilename: "1E9A8B7C-2D3E-4F5A-6B7C-8D9E0F1A2B3C.jpg")
        XCTAssertTrue(store.add(contact))

        let loaded = store.load()
        XCTAssertEqual(loaded.first?.photoFilename,
                       "1E9A8B7C-2D3E-4F5A-6B7C-8D9E0F1A2B3C.jpg")
    }

    func testLegacyPayloadWithoutOptionalFieldsDecodesAsNil() {
        // Payloads written before the optional fields existed (the
        // unversioned store's only "migration" is each field being
        // optional) must still load — written here through a legacy-shaped
        // struct that provably lacks both `messengerHandle` AND
        // `photoFilename` (the family-and-friends task, 2026-09-07, added
        // the photo name after the handle).
        let storage = InMemoryEncryptedStorage()
        let legacy = LegacyFamilyContact(id: UUID(), name: "राम",
                                         phone: "9812345678", relationship: "छोरा")
        guard case .success = storage.write(key: "family.contacts", value: [legacy]) else {
            return XCTFail("legacy payload write failed")
        }

        let store = FamilyContactStore(storage: storage)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "राम")
        XCTAssertNil(loaded.first?.messengerHandle,
                     "a pre-field payload decodes with a nil handle, not a failure")
        XCTAssertNil(loaded.first?.photoFilename,
                     "a pre-photo-field payload decodes photo-less, not a failure")
    }
}

/// The pre-optional-fields contact shape — no `messengerHandle` (added
/// 2026-09-06) and no `photoFilename` (added 2026-09-07). Exists to
/// write old-shape payloads into storage for the backward-decode test;
/// its JSON is byte-compatible with what the old app version stored.
private struct LegacyFamilyContact: Codable {
    let id: UUID
    var name: String
    var phone: String
    var relationship: String
}

/// In-memory `EncryptedLocalStorage` for tests — the real implementation
/// is Keychain-backed and untestable without a device context.
private final class InMemoryEncryptedStorage: EncryptedLocalStorage {
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
