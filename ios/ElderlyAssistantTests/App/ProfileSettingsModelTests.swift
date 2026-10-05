import XCTest
@testable import ElderlyAssistant

/// The Settings editor's model (profile-interview, T-103 / C08): prefill
/// from the store's cached snapshot, save through the coordinator's
/// single writer with the shared draft semantics, success/failure
/// mapping, and the one deliberate difference from the wizard — clearing
/// name / address-as is ALLOWED here (FR-PI-011: clearing returns to the
/// un-personalized path).
final class ProfileSettingsModelTests: XCTestCase {

    // MARK: - Double

    /// In-memory stand-in for the encrypted channel (same shape as the
    /// coordinator seam tests' double): raw read/write plus a
    /// write-failure injection.
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
            .failure(.encryptedReadFailed)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            payloads[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? { payloads[key] }
        func hasPayload(key: String) -> Bool? { payloads[key] != nil }
    }

    private func completeRecord() -> UserProfile {
        UserProfile(name: "Maya Gurung",
                    addressAs: "Mum",
                    dateOfBirth: DateComponents(year: 1943, month: 7, day: 21),
                    emergencyDoctor: "Dr. Sharma",
                    localHospital: "Teaching Hospital")
    }

    // MARK: - Prefill

    @MainActor
    func testLoadPrefillsEveryFieldFromTheSnapshot() throws {
        let storage = InMemoryProfilePayloadStorage()
        storage.payloads[UserProfileStore.storageKey] =
            try JSONEncoder().encode(completeRecord())
        let coordinator = AppCoordinator(profileStorage: storage)
        let model = ProfileSettingsModel(coordinator: coordinator)

        model.load()

        XCTAssertEqual(model.name, "Maya Gurung")
        XCTAssertEqual(model.addressAs, "Mum")
        XCTAssertTrue(model.hasDateOfBirth)
        XCTAssertEqual(model.dateOfBirth,
                       Calendar.current.date(from: DateComponents(year: 1943,
                                                                  month: 7,
                                                                  day: 21)))
        XCTAssertEqual(model.emergencyDoctor, "Dr. Sharma")
        XCTAssertEqual(model.localHospital, "Teaching Hospital")
        XCTAssertEqual(model.saveState, .idle)
    }

    @MainActor
    func testLoadOnAnEmptyStoreYieldsEmptyFieldsAndToggleOff() {
        let storage = InMemoryProfilePayloadStorage()
        let coordinator = AppCoordinator(profileStorage: storage)
        let model = ProfileSettingsModel(coordinator: coordinator)

        model.load()

        XCTAssertEqual(model.name, "")
        XCTAssertEqual(model.addressAs, "")
        XCTAssertFalse(model.hasDateOfBirth)
        XCTAssertNil(model.dateOfBirth)
        XCTAssertEqual(model.emergencyDoctor, "")
        XCTAssertEqual(model.localHospital, "")
        XCTAssertNil(model.photoFilename, "no record, no selfie")
    }

    // MARK: - Save

    @MainActor
    func testSaveWritesTheMergedRecordAndReportsSaved() {
        let storage = InMemoryProfilePayloadStorage()
        let coordinator = AppCoordinator(profileStorage: storage)
        let model = ProfileSettingsModel(coordinator: coordinator)
        model.load()

        model.name = "  Maya Gurung "
        model.addressAs = " Mum "
        model.hasDateOfBirth = true
        model.dateOfBirth = Calendar.current.date(
            from: DateComponents(year: 1943, month: 7, day: 21))
        model.emergencyDoctor = " Dr. Sharma "
        model.localHospital = "Teaching Hospital"

        model.save()

        XCTAssertEqual(model.saveState, .saved)
        guard case .loaded(let stored) = coordinator.currentProfileSnapshot() else {
            return XCTFail("the save must land in the store")
        }
        XCTAssertEqual(stored.name, "Maya Gurung", "name is trimmed on save")
        XCTAssertEqual(stored.addressAs, "Mum", "address-as is trimmed on save")
        XCTAssertEqual(stored.dateOfBirth,
                       DateComponents(year: 1943, month: 7, day: 21),
                       "DOB stores year/month/day components only")
        XCTAssertEqual(stored.emergencyDoctor, "Dr. Sharma")
        XCTAssertEqual(stored.localHospital, "Teaching Hospital")
    }

    @MainActor
    func testClearingIsAllowedAndReturnsToTheUnpersonalizedPath() throws {
        let storage = InMemoryProfilePayloadStorage()
        storage.payloads[UserProfileStore.storageKey] =
            try JSONEncoder().encode(completeRecord())
        let coordinator = AppCoordinator(profileStorage: storage)
        let model = ProfileSettingsModel(coordinator: coordinator)
        model.load()

        // Clear the two personalization fields and switch the DOB off.
        // The date is left HELD (as the loaded wheel state does): the
        // toggle-off in front of a prefilled date clears the record, and
        // the editor allows this (the wizard's Next gate does not).
        model.name = ""
        model.addressAs = ""
        model.hasDateOfBirth = false

        model.save()

        XCTAssertEqual(model.saveState, .saved)
        guard case .loaded(let stored) = coordinator.currentProfileSnapshot() else {
            return XCTFail("clearing is a legal write, not a deletion")
        }
        XCTAssertEqual(stored.name, "")
        XCTAssertEqual(stored.addressAs, "")
        XCTAssertNil(stored.dateOfBirth)
        XCTAssertEqual(stored.emergencyDoctor, "Dr. Sharma",
                       "fields the user did not clear are preserved")
        XCTAssertEqual(stored.localHospital, "Teaching Hospital")
    }

    // MARK: - Selfie (2026-10-06)

    @MainActor
    func testLoadShowsTheStoredSelfieAndSavePreservesIt() throws {
        let storage = InMemoryProfilePayloadStorage()
        var record = completeRecord()
        record.photoFilename = "selfie-1.jpg"
        storage.payloads[UserProfileStore.storageKey] =
            try JSONEncoder().encode(record)
        let coordinator = AppCoordinator(profileStorage: storage)
        let model = ProfileSettingsModel(coordinator: coordinator)

        model.load()
        XCTAssertEqual(model.photoFilename, "selfie-1.jpg",
                       "the editor shows the stored selfie's file name")

        // This editor has NO photo UI: an ordinary save of the text
        // fields must carry the selfie through untouched — never erase
        // it by omission.
        model.name = "Maya G."
        model.save()

        XCTAssertEqual(model.saveState, .saved)
        guard case .loaded(let stored) = coordinator.currentProfileSnapshot() else {
            return XCTFail("the save must land in the store")
        }
        XCTAssertEqual(stored.name, "Maya G.")
        XCTAssertEqual(stored.photoFilename, "selfie-1.jpg",
                       "a text-only save preserves the stored selfie")
    }

    // MARK: - Failure

    @MainActor
    func testSaveFailureReportsFailedAndChangesNothing() throws {
        let storage = InMemoryProfilePayloadStorage()
        let stored = completeRecord()
        storage.payloads[UserProfileStore.storageKey] =
            try JSONEncoder().encode(stored)
        let coordinator = AppCoordinator(profileStorage: storage)
        let model = ProfileSettingsModel(coordinator: coordinator)
        model.load()

        storage.failWrites = true
        model.name = "Someone Else"
        model.save()

        XCTAssertEqual(model.saveState, .failed)
        guard case .loaded(let after) = coordinator.currentProfileSnapshot() else {
            return XCTFail("the previous record must remain in effect")
        }
        XCTAssertEqual(after, stored)
    }

    // MARK: - Saved-state lifecycle

    @MainActor
    func testReloadResetsAStaleSavedState() {
        let storage = InMemoryProfilePayloadStorage()
        let coordinator = AppCoordinator(profileStorage: storage)
        let model = ProfileSettingsModel(coordinator: coordinator)

        model.load()
        model.name = "Maya"
        model.addressAs = "Mum"
        model.save()
        XCTAssertEqual(model.saveState, .saved)

        // Leaving and returning to the screen re-runs load(); the old
        // "Saved" confirmation must not survive the visit.
        model.load()
        XCTAssertEqual(model.saveState, .idle)
    }
}
