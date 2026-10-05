import XCTest
@testable import ElderlyAssistant

/// The coordinator's profile seams (profile-interview, T-092, C01):
/// `saveProfile` as the only writer, `currentProfileSnapshot` as the
/// cached read, and the personalization seam composed in `init()`.
///
/// The wizard runs BEFORE `start()`, so these tests deliberately never
/// call `start()` — the whole point of the seam split is that the store,
/// the guard and the read surface exist the moment `init` returns (only
/// the ack service, which needs the speaker, is built in `start()`).
final class ProfileCoordinatorSeamTests: XCTestCase {

    // MARK: - Doubles

    /// In-memory stand-in for the encrypted channel: raw read/write plus
    /// a write-failure injection. The store's decode path reads raw data,
    /// so `write` encodes exactly like the real typed channel would.
    private final class InMemoryProfilePayloadStorage: ProfilePayloadStorage {
        var payloads: [String: Data] = [:]
        var failWrites = false
        private let encoder = JSONEncoder()

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard !failWrites, let data = try? encoder.encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            payloads[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            .failure(.encryptedReadFailed)   // this fake is raw-read only
        }

        func delete(key: String) -> Result<Void, StorageError> {
            payloads[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? { payloads[key] }

        func hasPayload(key: String) -> Bool? { payloads[key] != nil }
    }

    // MARK: - Helpers

    private func completeRecord(name: String = "Maya Gurung",
                                addressAs: String = "Mum") -> UserProfile {
        UserProfile(name: name,
                    addressAs: addressAs,
                    dateOfBirth: DateComponents(year: 1943, month: 7, day: 21),
                    emergencyDoctor: "Dr. Sharma",
                    localHospital: "Teaching Hospital")
    }

    // MARK: - Scenario: The coordinator is the only writer

    func testSaveProfileRoundTripsThroughTheSnapshot() {
        let storage = InMemoryProfilePayloadStorage()
        let coordinator = AppCoordinator(profileStorage: storage)

        let saved = coordinator.saveProfile(
            name: "Maya Gurung",
            addressAs: "Mum",
            dateOfBirth: DateComponents(year: 1943, month: 7, day: 21),
            emergencyDoctor: "Dr. Sharma",
            localHospital: "Teaching Hospital",
            photoFilename: nil)
        if case .failure(let error) = saved {
            return XCTFail("expected success, got \(error)")
        }

        guard case .loaded(let profile) = coordinator.currentProfileSnapshot() else {
            return XCTFail("the snapshot must reflect the saved record")
        }
        XCTAssertEqual(profile, completeRecord())

        // The write went through the coordinator's own store — no wizard
        // or Settings code path touches the payload channel directly
        // (single writer by contract; the contract is documented on
        // `AppCoordinator.saveProfile`).
        XCTAssertNotNil(storage.payloads[UserProfileStore.storageKey],
                        "the record reached the injected encrypted channel")
    }

    func testSaveProfileRoundTripsTheSelfieFilename() {
        let storage = InMemoryProfilePayloadStorage()
        let coordinator = AppCoordinator(profileStorage: storage)

        let saved = coordinator.saveProfile(
            name: "Maya Gurung",
            addressAs: "Mum",
            dateOfBirth: nil,
            emergencyDoctor: nil,
            localHospital: nil,
            photoFilename: "selfie-1.jpg")
        if case .failure(let error) = saved {
            return XCTFail("expected success, got \(error)")
        }

        guard case .loaded(let profile) = coordinator.currentProfileSnapshot() else {
            return XCTFail("the snapshot must reflect the saved record")
        }
        XCTAssertEqual(profile.photoFilename, "selfie-1.jpg",
                       "the About-you selfie's file name travels the single "
                       + "writer path and reads back")
    }

    // MARK: - Scenario: The personalization seam exists before start()

    func testSeamExistsBeforeStartAndFeedsTheGuardedTermIntoContext() throws {
        let storage = InMemoryProfilePayloadStorage()
        storage.payloads[UserProfileStore.storageKey] =
            try JSONEncoder().encode(completeRecord())
        let coordinator = AppCoordinator(profileStorage: storage)

        // init() has returned; start() has NOT been called.
        let seam = coordinator.profilePersonalization
        XCTAssertNotNil(seam, "the seam must exist before start()")
        XCTAssertEqual(seam?.addressAsForPrompt, "Mum")
        XCTAssertEqual(seam?.addressAsVerbatim, "Mum")

        let context = InterpreterContext(
            pendingMedications: [],
            userLanguageHint: "ne",
            addressAs: seam?.addressAsForPrompt)
        XCTAssertEqual(context.addressAs, "Mum",
                       "the interpreters consume the guarded accessor "
                       + "through InterpreterContext")
    }

    // MARK: - Scenario: A nil seam is consumed nil-safe

    func testNilSeamIsConsumedNilSafe() {
        let storage = InMemoryProfilePayloadStorage()
        let coordinator = AppCoordinator(profileStorage: storage,
                                         wireProfilePersonalization: false)
        XCTAssertNil(coordinator.profilePersonalization)

        let context = InterpreterContext(
            pendingMedications: [],
            userLanguageHint: "ne",
            addressAs: coordinator.profilePersonalization?.addressAsForPrompt)
        XCTAssertNil(context.addressAs,
                     "no seam, no term — the nil path resolves to nil and "
                     + "nothing crashes or blocks")

        let prompt = IntentPrompt.build(transcript: "test transcript",
                                        context: context)
        XCTAssertFalse(prompt.contains("Address them as"),
                       "the no-term clause is used")
    }

    // MARK: - Scenario: A failed save surfaces explicitly and changes nothing

    func testAFailedWriteSurfacesExplicitlyAndChangesNothing() throws {
        let storage = InMemoryProfilePayloadStorage()
        let stored = completeRecord()
        storage.payloads[UserProfileStore.storageKey] =
            try JSONEncoder().encode(stored)
        let coordinator = AppCoordinator(profileStorage: storage)

        // Prime the cache from disk — the record as stored.
        guard case .loaded(let before) = coordinator.currentProfileSnapshot() else {
            return XCTFail("precondition: the stored record must load")
        }
        XCTAssertEqual(before, stored)

        storage.failWrites = true
        let result = coordinator.saveProfile(
            name: "Someone Else",
            addressAs: "Dad",
            dateOfBirth: nil,
            emergencyDoctor: nil,
            localHospital: nil,
            photoFilename: nil)
        guard case .failure(let error) = result else {
            return XCTFail("a failed write must surface explicitly (E3)")
        }
        XCTAssertEqual(error, .writeFailed)

        // Nothing changed: the cached snapshot still reflects the record
        // as stored — the caller can show an inline message with nothing
        // claimed.
        guard case .loaded(let after) = coordinator.currentProfileSnapshot() else {
            return XCTFail("the snapshot must still hold the stored record")
        }
        XCTAssertEqual(after, stored)
        XCTAssertEqual(after.addressAs, "Mum")
    }
}
