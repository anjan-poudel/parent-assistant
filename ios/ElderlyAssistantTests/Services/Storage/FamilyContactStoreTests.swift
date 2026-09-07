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

    func testNicknameRoundTrips() {
        // (family-wizard task, 2026-09-07) The optional nickname is a
        // stored part of the record like the handle before it — and a
        // contact saved without one reads back as nil.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "राम", phone: "9812345678",
                                    relationship: "छोरा",
                                    nickname: "बुवा")
        XCTAssertTrue(store.add(contact))

        XCTAssertEqual(store.load().first?.nickname, "बुवा")

        let plain = FamilyContact(name: "सीता", phone: "9812345678", relationship: "छोरी")
        XCTAssertTrue(store.add(plain))
        XCTAssertNil(store.load().last?.nickname,
                     "a contact created without a nickname stores none")
    }

    func testAddressRoundTrips() {
        // (directions task, 2026-09-07) The free-form home address makes
        // a relative a voice-navigation target ("मैयाको घर लैजाऊ"); nil
        // when the user never set one.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "मैया", phone: "9812345678",
                                    relationship: "दिदी",
                                    address: "बूढानीलकण्ठ, काठमाडौं ९")
        XCTAssertTrue(store.add(contact))

        let loaded = store.load()
        XCTAssertEqual(loaded.first?.address, "बूढानीलकण्ठ, काठमाडौं ९")
    }

    func testContactWithoutAddressLoadsNil() {
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "राम", phone: "9812345678",
                                    relationship: "छोरा")
        XCTAssertTrue(store.add(contact))

        XCTAssertNil(store.load().first?.address,
                     "no address typed means nil — the navigation candidate list excludes the contact")
    }

    func testLegacyPayloadWithoutOptionalFieldsDecodesAsNil() {
        // Payloads written before the optional fields existed (the
        // unversioned store's only "migration" is each field being
        // optional) must still load — written here through a legacy-shaped
        // struct that provably lacks all four optional fields:
        // `messengerHandle` (added 2026-09-06), `photoFilename` (added
        // 2026-09-07 by the family-and-friends task), `nickname` (added
        // 2026-09-07 by the family-wizard task) and `address` (added
        // 2026-09-07 by the directions task).
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
        XCTAssertNil(loaded.first?.nickname,
                     "a pre-nickname-field payload decodes nickname-less, not a failure")
        XCTAssertNil(loaded.first?.address,
                     "a pre-address payload decodes address-less, not a failure")
    }

    // MARK: - Emergency flag (family-emergency task, 2026-09-07)

    func testIsEmergencyContactRoundTrips() {
        // The wizard's "Emergency contact" toggle writes the flag on the
        // record; the store must hand it back so an edit shows the
        // toggle pre-set and `AppCoordinator.emergencyContact` can
        // prefer the flagged person.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "बहिनी", phone: "9812345678",
                                    relationship: "बहिनी",
                                    isEmergencyContact: true)
        XCTAssertTrue(store.add(contact))

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertTrue(loaded.first?.isEmergencyContact ?? false,
                      "the flagged contact must read back flagged")
    }

    func testEmergencyFlagDefaultsToFalse() {
        // A contact created without the flag — every pre-toggle call
        // site, onboarding included — stores false, never a surprise.
        let store = FamilyContactStore(storage: InMemoryEncryptedStorage())
        let contact = FamilyContact(name: "राम", phone: "9812345678", relationship: "छोरा")
        XCTAssertFalse(contact.isEmergencyContact)
        XCTAssertTrue(store.add(contact))
        XCTAssertFalse(store.load().first?.isEmergencyContact ?? true)
    }

    func testLegacyPayloadWithoutEmergencyFlagDecodesFalse() {
        // The flag is the one NON-optional field added since the
        // optional era — its migration is a decoder default, not nil:
        // a payload written before the flag existed (same four-field
        // shape as `LegacyFamilyContact`) must load as false, not fail
        // the whole store read — the pre-flag behavior (first contact
        // wins) is exactly what `AppCoordinator.emergencyContact`
        // keeps as its fallback.
        let storage = InMemoryEncryptedStorage()
        let legacy = LegacyFamilyContact(id: UUID(), name: "राम",
                                         phone: "9812345678", relationship: "छोरा")
        guard case .success = storage.write(key: "family.contacts", value: [legacy]) else {
            return XCTFail("legacy payload write failed")
        }

        let store = FamilyContactStore(storage: storage)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertFalse(loaded.first?.isEmergencyContact ?? true,
                       "a pre-flag payload decodes as not-emergency, not a failure")
    }

    // MARK: - Emergency-preference rule — AppCoordinator.preferredEmergencyContact

    func testPreferredEmergencyPrefersFlaggedContact() {
        // The wizard's flagged person is whom the Emergency button
        // dials first, even when an unflagged relative sits earlier in
        // the list.
        let son = FamilyContact(name: "छोरा", phone: "9812345678", relationship: "छोरा")
        let daughter = FamilyContact(name: "छोरी", phone: "9812000000",
                                     relationship: "छोरी", isEmergencyContact: true)
        XCTAssertEqual(AppCoordinator.preferredEmergencyContact([son, daughter])?.id,
                       daughter.id)
    }

    func testPreferredEmergencyFirstFlagWinsAmongSeveral() {
        // The toggle caption promises "dials this person first" — with
        // several flagged contacts the FIRST flag is the number, list
        // order is the tiebreak.
        let first = FamilyContact(name: "आमा", phone: "1", relationship: "आमा",
                                  isEmergencyContact: true)
        let middle = FamilyContact(name: "छोरा", phone: "2", relationship: "छोरा")
        let last = FamilyContact(name: "छोरी", phone: "3", relationship: "छोरी",
                                 isEmergencyContact: true)
        XCTAssertEqual(AppCoordinator.preferredEmergencyContact([first, middle, last])?.id,
                       first.id)
    }

    func testPreferredEmergencyFallsBackToFirstWhenNoneFlagged() {
        // No flagged contact (every record written before the flag
        // existed, or none toggled) keeps the pre-flag behavior: the
        // first configured contact is the emergency number.
        let ram = FamilyContact(name: "राम", phone: "9812345678", relationship: "छोरा")
        let sita = FamilyContact(name: "सीता", phone: "9812345678", relationship: "छोरी")
        XCTAssertEqual(AppCoordinator.preferredEmergencyContact([ram, sita])?.id, ram.id)
    }

    func testPreferredEmergencyEmptyListIsNil() {
        // No configured contacts — the view surfaces that honestly
        // (the emergency button's no-contact alert) instead of
        // resolving to somebody who is not there.
        XCTAssertNil(AppCoordinator.preferredEmergencyContact([]))
    }
}

/// The pre-optional-fields contact shape — no `messengerHandle` (added
/// 2026-09-06), no `photoFilename` (added 2026-09-07), no `nickname`
/// (added 2026-09-07 by the family-wizard task) and no `address` (added
/// 2026-09-07 by the directions task). It also lacks the
/// `isEmergencyContact` flag (added 2026-09-07 by the family-emergency
/// task), which — unlike the optionals — decodes as false rather than
/// nil. Exists to write old-shape payloads into storage for the
/// backward-decode test; its JSON is byte-compatible with what the old
/// app version stored.
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
