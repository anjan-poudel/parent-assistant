import XCTest
@testable import ElderlyAssistant

/// Store tests for the saved-places list (directions task, 2026-09-07):
/// encryption-backed persistence, the 20-place cap, and — the part the
/// navigation feature depends on — the default-home bookkeeping:
///  - HARD invariant (every read/write): at most one default, and only a
///    `.home` place can carry the flag.
///  - SOFT invariant (mutation paths): while a `.home` place exists,
///    exactly one is the default — first-home auto-promotion, explicit
///    toggle wins, removal/recategorization promotes the next home.
final class SavedPlaceStoreTests: XCTestCase {

    private func home(name: String, defaultHome: Bool = false) -> SavedPlace {
        SavedPlace(name: name, address: "काठमाडौं", category: .home,
                   isDefaultHome: defaultHome)
    }

    private func important(name: String) -> SavedPlace {
        SavedPlace(name: name, address: "बूढानीलकण्ठ", category: .important)
    }

    // MARK: - Persistence

    func testAddLoadRoundTrip() {
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        XCTAssertTrue(store.add(home(name: "मेरो घर")))
        XCTAssertTrue(store.add(important(name: "अस्पताल")))

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first?.name, "मेरो घर")
        XCTAssertEqual(loaded.first?.address, "काठमाडौं")
        XCTAssertEqual(loaded.first?.category, .home)
        XCTAssertEqual(loaded.last?.category, .important)
    }

    func testEmptyWhenNothingStored() {
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertNil(store.defaultHome)
    }

    func testMaxPlacesEnforcedAtTwenty() {
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        for i in 0..<21 {
            let added = store.add(SavedPlace(name: "ठाउँ \(i)", address: "ठेगाना",
                                             category: .important))
            if i < 20 {
                XCTAssertTrue(added, "place \(i) should have been accepted")
            } else {
                XCTAssertFalse(added, "21st place must be rejected")
            }
        }
        XCTAssertEqual(store.load().count, 20)
    }

    func testRemoveDeletesOnlyTarget() {
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        let a = home(name: "घर")
        let b = important(name: "बजार")
        store.add(a)
        store.add(b)

        XCTAssertTrue(store.remove(id: a.id))
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, b.id)
    }

    func testUpdateReplacesFields() {
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        let a = important(name: "बजार")
        store.add(a)

        var edited = a
        edited.name = "नयाँ बजार"
        edited.address = "ठमेल"
        XCTAssertTrue(store.update(edited))
        XCTAssertEqual(store.load().first?.name, "नयाँ बजार")
        XCTAssertEqual(store.load().first?.address, "ठमेल")
    }

    func testUpdateOfUnknownIdFails() {
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        XCTAssertFalse(store.update(home(name: "कहिल्यै थपिएन")))
    }

    // MARK: - Default home: soft invariant (mutation paths)

    func testFirstHomeAutoPromotesToDefault() {
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        store.add(important(name: "अस्पताल"))     // .important first
        let firstHome = home(name: "काठमाडौंको घर")
        store.add(firstHome)

        XCTAssertEqual(store.defaultHome?.id, firstHome.id,
                       "the first .home ever added becomes the default, so take-me-home works out of the box")
    }

    func testExplicitlyToggledNewHomeDemotesPreviousDefault() {
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        let firstHome = home(name: "काठमाडौंको घर")
        store.add(firstHome)
        let gumbaHome = home(name: "गाउँको घर", defaultHome: true)
        store.add(gumbaHome)

        XCTAssertEqual(store.defaultHome?.id, gumbaHome.id,
                       "the user's explicit toggle wins over the older default")
    }

    func testSecondPlainHomeDoesNotStealDefault() {
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        let firstHome = home(name: "पहिलो घर")
        store.add(firstHome)
        let secondHome = home(name: "दोस्रो घर")
        store.add(secondHome)

        XCTAssertEqual(store.defaultHome?.id, firstHome.id)
    }

    func testRemovingDefaultPromotesNextHome() {
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        let defaultHome = home(name: "मुख्य घर")
        let otherHome = home(name: "अर्को घर")
        store.add(defaultHome)
        store.add(otherHome)

        XCTAssertTrue(store.remove(id: defaultHome.id))
        XCTAssertEqual(store.defaultHome?.id, otherHome.id,
                       "removing the default must auto-promote the remaining home")
    }

    func testRemovingLastHomeLeavesNoDefault() {
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        store.add(home(name: "एक्लो घर"))

        XCTAssertTrue(store.remove(id: store.defaultHome!.id))
        XCTAssertNil(store.defaultHome,
                     "no .home places left — take-me-home then speaks the honest noHome line")
    }

    func testSetDefaultHomeSwitchesFlagBetweenHomes() {
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        let firstHome = home(name: "पहिलो घर")
        let secondHome = home(name: "दोस्रो घर")
        store.add(firstHome)
        store.add(secondHome)

        XCTAssertTrue(store.setDefaultHome(id: secondHome.id))
        XCTAssertEqual(store.defaultHome?.id, secondHome.id)
        XCTAssertEqual(store.load().first { $0.id == firstHome.id }?.isDefaultHome, false,
                       "exactly one home carries the flag")
    }

    func testSetDefaultHomeRejectsImportantPlace() {
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        let market = important(name: "बजार")
        store.add(market)
        store.add(home(name: "घर"))

        XCTAssertFalse(store.setDefaultHome(id: market.id),
                       "an .important place can never be the default home")
        XCTAssertEqual(store.defaultHome?.name, "घर")
    }

    func testRecategorizingDefaultHomePromotesNextHome() {
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        let firstHome = home(name: "पहिलो घर")
        let secondHome = home(name: "दोस्रो घर")
        store.add(firstHome)
        store.add(secondHome)

        // Editing the default into an .important place — a home is gone.
        var demoted = firstHome
        demoted.category = .important
        XCTAssertTrue(store.update(demoted))
        XCTAssertEqual(store.defaultHome?.id, secondHome.id)
        XCTAssertEqual(store.defaultHome?.category, .home)
    }

    // MARK: - Default home: hard invariant (any read/write)

    func testHandBuiltListWithTwoDefaultsSelfHealsOnSave() {
        // Two `.home` places both claiming the flag — only the first may
        // keep it, whatever a buggy caller wrote.
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        let a = home(name: "घर क", defaultHome: true)
        let b = home(name: "घर ख", defaultHome: true)
        XCTAssertTrue(store.save([a, b]))

        let loaded = store.load()
        XCTAssertEqual(loaded.filter(\.isDefaultHome).count, 1)
        XCTAssertEqual(loaded.first { $0.isDefaultHome }?.id, a.id)
    }

    func testHandBuiltImportantPlaceWithDefaultFlagSelfHeals() {
        let store = SavedPlaceStore(storage: InMemoryEncryptedStorage())
        let smuggled = SavedPlace(id: UUID(), name: "अस्पताल", address: "ठेगाना",
                                  category: .important, isDefaultHome: true)
        XCTAssertTrue(store.save([smuggled]))

        XCTAssertEqual(store.load().first?.isDefaultHome, false,
                       "the model boundary itself refuses the flag on a non-home")
        XCTAssertNil(store.defaultHome)
    }

    // MARK: - Legacy payloads

    func testLegacyPayloadWithoutAddressFieldDecodes() {
        // A payload written before `address` existed (the field joined in
        // the same task that added the store's siblings) decodes with an
        // empty address — an optional field IS the unversioned store's
        // migration; the navigation candidate filter then excludes it.
        let storage = InMemoryEncryptedStorage()
        let legacy = LegacySavedPlace(id: UUID(), name: "पुरानो ठाउँ")
        guard case .success = storage.write(key: "places.saved", value: [legacy]) else {
            return XCTFail("legacy payload write failed")
        }

        let store = SavedPlaceStore(storage: storage)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "पुरानो ठाउँ")
        XCTAssertEqual(loaded.first?.address, "")
        XCTAssertEqual(loaded.first?.category, .important,
                       "unknown/missing category raw value decodes to the safe default")
        XCTAssertEqual(loaded.first?.isDefaultHome, false)
    }
}

/// The pre-optional-fields place shape — no `address`, `category`, or
/// `isDefaultHome`. Exists to write old-shape payloads into storage for
/// the backward-decode test; its JSON is byte-compatible with what an
/// older build stored.
private struct LegacySavedPlace: Codable {
    let id: UUID
    var name: String
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
