import XCTest
@testable import ElderlyAssistant

/// Unit tests for the encrypted profile record (profile-interview, T-090),
/// over an in-memory `ProfilePayloadStorage` fake — no file system, no
/// Keychain. The probe/read/decode matrix of `specs/design-l2.md` §5.1 is
/// covered exhaustively: every row of the load-state mapping table has a
/// test here, plus the write-failure path and the event discipline
/// (content-free, once per disk observation, never per cache hit).
final class UserProfileStoreTests: XCTestCase {

    // MARK: - Doubles

    /// In-memory stand-in for the encrypted store, with the failure
    /// injections the load/write paths must survive: an unknowable probe
    /// (unresolvable store location), failed writes and failed deletes.
    private final class FakeProfileStorage: ProfilePayloadStorage {
        var payloads: [String: Data] = [:]
        /// When true the presence probe reports "unknowable".
        var probeReturnsNil = false
        var failWrites = false
        var failDeletes = false
        private(set) var probeCalls: [String] = []
        private(set) var rawReadCalls: [String] = []
        private(set) var deleteCalls: [String] = []
        private(set) var typedWriteCount = 0
        private let encoder = JSONEncoder()
        private let decoder = JSONDecoder()

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard !failWrites else { return .failure(.encryptedWriteFailed) }
            guard let data = try? encoder.encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            payloads[key] = data
            typedWriteCount += 1
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            guard let data = payloads[key],
                  let value = try? decoder.decode(type, from: data) else {
                return .failure(.encryptedReadFailed)
            }
            return .success(value)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            deleteCalls.append(key)
            guard !failDeletes else { return .failure(.encryptedWriteFailed) }
            payloads[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? {
            rawReadCalls.append(key)
            return payloads[key]
        }

        func hasPayload(key: String) -> Bool? {
            probeCalls.append(key)
            if probeReturnsNil { return nil }
            return payloads[key] != nil
        }
    }

    private final class RecordingBus: ObservabilityBus {
        private(set) var events: [ObservabilityEvent] = []

        func emit(_ event: ObservabilityEvent) {
            events.append(event)
        }

        func events(ofType eventType: String) -> [ObservabilityEvent] {
            events.filter { $0.eventType == eventType }
        }
    }

    private var storage: FakeProfileStorage!
    private var bus: RecordingBus!
    private var store: UserProfileStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = FakeProfileStorage()
        bus = RecordingBus()
        store = UserProfileStore(storage: storage, observabilityBus: bus)
    }

    override func tearDownWithError() throws {
        store = nil
        bus = nil
        storage = nil
        try super.tearDownWithError()
    }

    private func storedJSON() -> String? {
        storage.payloads[UserProfileStore.storageKey]
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// `Result<Void, _>` is not Equatable; assert the success case by
    /// pattern match.
    private func assertSaveSucceeds(_ result: Result<Void, ProfileStoreError>,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        if case .failure(let error) = result {
            XCTFail("save failed: \(error)", file: file, line: line)
        }
    }

    // MARK: - Round trip (Scenario: Round-trip of a complete record)

    func testRoundTripOfACompleteRecord() {
        let profile = UserProfile(
            name: "Maya Gurung",
            addressAs: "Mum",
            dateOfBirth: DateComponents(year: 1943, month: 7, day: 21),
            emergencyDoctor: "Dr. Sharma",
            localHospital: "Teaching Hospital"
        )
        assertSaveSucceeds(store.save(profile))

        // The successful save swaps the cache (§5.1, FR-PI-012), so the
        // same instance's next load is a cache hit: no disk observation,
        // no per-cache-hit event.
        guard case .loaded(let cached) = store.load() else {
            return XCTFail("a complete record must load")
        }
        XCTAssertEqual(cached, profile)
        XCTAssertTrue(storage.probeCalls.isEmpty,
                      "the post-save load is served from the cache")

        // The disk round trip proper: a fresh store over the same storage
        // observes disk, decodes, and reports the first-load event.
        let reopened = UserProfileStore(storage: storage,
                                        observabilityBus: bus)
        guard case .loaded(let loaded) = reopened.load() else {
            return XCTFail("the saved record must decode from disk")
        }
        XCTAssertEqual(loaded, profile)

        // Date of birth is carried as year/month/day components only.
        XCTAssertEqual(loaded.dateOfBirth?.year, 1943)
        XCTAssertEqual(loaded.dateOfBirth?.month, 7)
        XCTAssertEqual(loaded.dateOfBirth?.day, 21)
        XCTAssertNil(loaded.dateOfBirth?.hour)
        XCTAssertNil(loaded.dateOfBirth?.minute)
        XCTAssertNil(loaded.dateOfBirth?.second)

        // The write went through the typed channel under the pinned key;
        // the saved and first-disk-load events fire exactly once each.
        XCTAssertEqual(storage.typedWriteCount, 1)
        XCTAssertNotNil(storedJSON(), "the payload must land under user.profile")
        XCTAssertEqual(bus.events(ofType: "profile_store_saved").count, 1)
        XCTAssertEqual(bus.events(ofType: "profile_store_loaded").count, 1)
    }

    // MARK: - Absent vs unreadable (Scenario: Absent and unreadable are distinct)

    func testNothingStoredLoadsAsAbsentExactlyOnce() {
        guard case .absent = store.load() else {
            return XCTFail("nothing stored must load as .absent")
        }
        guard case .absent = store.load() else {
            return XCTFail("the cached result must stay .absent")
        }
        XCTAssertEqual(storage.probeCalls.count, 1,
                       "the second load must be served from the cache — "
                       + "one disk observation, never a re-read loop")
        XCTAssertEqual(bus.events(ofType: "profile_store_absent").count, 1,
                       "events fire once per disk observation, never per "
                       + "cache hit")
    }

    func testCorruptPayloadIsUnreadableThenDiscardedExactlyOnce() {
        storage.payloads[UserProfileStore.storageKey] = Data("{ not json".utf8)

        guard case .unreadable(.decodeFailed) = store.load() else {
            return XCTFail("a corrupt payload must load as .unreadable(.decodeFailed)")
        }
        XCTAssertEqual(storage.deleteCalls, [UserProfileStore.storageKey],
                       "the corrupt payload is discarded best-effort, once")
        XCTAssertNil(storage.payloads[UserProfileStore.storageKey])

        // The next load reports what the store now holds — no re-read loop.
        guard case .absent = store.load() else {
            return XCTFail("after the discard the store must read as .absent")
        }
        XCTAssertEqual(storage.probeCalls.count, 1,
                       "the discard must not trigger another disk observation")
        XCTAssertEqual(bus.events(ofType: "profile_store_unreadable").count, 1)
        guard case .absent = store.load() else {
            return XCTFail("the cached verdict must stay stable")
        }
    }

    func testPartialRecordIsUnreadableNotPartiallyApplied() {
        // Valid JSON, valid shape for the optional keys, but the mandatory
        // addressAs key is missing: the whole record is unreadable —
        // never defaulted, never partially applied.
        storage.payloads[UserProfileStore.storageKey] =
            Data(#"{"name":"Maya"}"#.utf8)

        guard case .unreadable(.decodeFailed) = store.load() else {
            return XCTFail("a payload missing addressAs must be unreadable")
        }
        XCTAssertEqual(storage.deleteCalls.count, 1)
        let unreadable = bus.events(ofType: "profile_store_unreadable")
        XCTAssertEqual(unreadable.count, 1)
        XCTAssertEqual(unreadable.first?.errorCode, "decode_failed")
    }

    func testUnreadableRawReadIsTreatedAsDecodeFailed() {
        // Probe true but the raw read yields nil (a file that exists but
        // does not decode as this key's envelope). Same route as a decode
        // throw: unreadable, discard, cache what remains.
        storage.payloads[UserProfileStore.storageKey] = Data("present".utf8)
        // Make readRawData answer nil while the probe still says present.
        let opaque = OpaqueStorage(base: storage)
        let opaqueStore = UserProfileStore(storage: opaque, observabilityBus: bus)

        guard case .unreadable(.decodeFailed) = opaqueStore.load() else {
            return XCTFail("probe-true + raw-nil must be .unreadable(.decodeFailed)")
        }
        XCTAssertEqual(storage.deleteCalls.count, 1)
        guard case .absent = opaqueStore.load() else {
            return XCTFail("after the discard the store reads .absent")
        }
    }

    /// Wraps the fake so the raw read reports nil while the probe still
    /// reports presence — the Unreadable(no raw payload) mapping row.
    private final class OpaqueStorage: ProfilePayloadStorage {
        private let base: FakeProfileStorage
        init(base: FakeProfileStorage) { self.base = base }
        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            base.write(key: key, value: value)
        }
        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            base.read(key: key, type: type)
        }
        func delete(key: String) -> Result<Void, StorageError> {
            base.delete(key: key)
        }
        func readRawData(key: String) -> Data? { nil }
        func hasPayload(key: String) -> Bool? {
            base.hasPayload(key: key)
        }
    }

    func testFailedDeleteCachesUnreadableWithoutALoop() {
        storage.payloads[UserProfileStore.storageKey] = Data("corrupt".utf8)
        storage.failDeletes = true

        guard case .unreadable(.decodeFailed) = store.load() else {
            return XCTFail("first load must report decodeFailed")
        }
        guard case .unreadable(.decodeFailed) = store.load() else {
            return XCTFail("a failed discard caches the unreadable verdict")
        }
        XCTAssertEqual(storage.deleteCalls.count, 1,
                       "exactly one discard attempt — no per-read delete loop")
        XCTAssertEqual(storage.probeCalls.count, 1)
    }

    // MARK: - Unknowable probe (Scenario: An unknowable probe is never absent)

    func testUnknowableProbeIsReadFailedAndNothingIsDeleted() {
        storage.probeReturnsNil = true
        storage.payloads[UserProfileStore.storageKey] = Data("untouched".utf8)

        guard case .unreadable(.readFailed) = store.load() else {
            return XCTFail("a nil probe must be .unreadable(.readFailed) — "
                           + "never read as absent")
        }
        XCTAssertTrue(storage.deleteCalls.isEmpty,
                      "nothing may be deleted when presence is unknowable")
        XCTAssertEqual(storage.rawReadCalls.count, 0,
                       "no raw read is attempted on an unknowable store")

        guard case .unreadable(.readFailed) = store.load() else {
            return XCTFail("the verdict is cached")
        }
        XCTAssertEqual(storage.probeCalls.count, 1)
        let unreadable = bus.events(ofType: "profile_store_unreadable")
        XCTAssertEqual(unreadable.count, 1)
        XCTAssertEqual(unreadable.first?.errorCode, "read_failed")
    }

    // MARK: - Failed write (Scenario: A failed write leaves the record in effect)

    func testFailedWriteLeavesTheStoredRecordInEffect() {
        let original = UserProfile(name: "Maya", addressAs: "Mum",
                                   dateOfBirth: nil,
                                   emergencyDoctor: nil, localHospital: nil)
        assertSaveSucceeds(store.save(original))

        storage.failWrites = true
        let replacement = UserProfile(name: "Other", addressAs: "Dad",
                                      dateOfBirth: nil,
                                      emergencyDoctor: nil, localHospital: nil)
        guard case .failure(.writeFailed) = store.save(replacement) else {
            return XCTFail("a failed write must report .writeFailed")
        }

        guard case .loaded(let loaded) = store.load() else {
            return XCTFail("the stored record must still load")
        }
        XCTAssertEqual(loaded, original,
                       "a failed write must leave the previously stored "
                       + "record in effect")
        XCTAssertEqual(bus.events(ofType: "profile_store_saved").count, 1,
                       "a failed save emits no success event")
        XCTAssertEqual(storage.typedWriteCount, 1)
    }

    // MARK: - Empty / partial records (Scenario: Empty-string records are legal)

    func testEmptyStringNameAndAddressAsAreLegal() {
        let blank = UserProfile(name: "", addressAs: "",
                                dateOfBirth: nil,
                                emergencyDoctor: nil, localHospital: nil)
        assertSaveSucceeds(store.save(blank))

        guard case .loaded(let loaded) = store.load() else {
            return XCTFail("empty strings mean Not recorded yet — legal, "
                           + "not unreadable")
        }
        XCTAssertEqual(loaded.name, "")
        XCTAssertEqual(loaded.addressAs, "")
        XCTAssertNil(loaded.dateOfBirth)
        XCTAssertNil(loaded.emergencyDoctor)
        XCTAssertNil(loaded.localHospital)
    }

    func testMissingOptionalKeysDecodeAsNil() {
        // The forward-compatibility contract: every future addition is an
        // optional key read as nil when absent (never defaulted).
        storage.payloads[UserProfileStore.storageKey] =
            Data(#"{"name":"Maya","addressAs":"Mum"}"#.utf8)

        guard case .loaded(let loaded) = store.load() else {
            return XCTFail("a record without the optional keys must load")
        }
        XCTAssertEqual(loaded.name, "Maya")
        XCTAssertEqual(loaded.addressAs, "Mum")
        XCTAssertNil(loaded.dateOfBirth)
        XCTAssertNil(loaded.emergencyDoctor)
        XCTAssertNil(loaded.localHospital)
        XCTAssertNil(loaded.photoFilename)
    }

    func testPreSelfiePayloadLoadsPhotoLess() {
        // The selfie's migration (2026-10-06): a payload written before
        // the field existed — every pre-selfie key present, no
        // `photoFilename` — must load with a nil filename through the
        // custom decoder, not fail the read. The mandatory-keys contract
        // is unchanged alongside it (the partial-record test above still
        // pins it).
        storage.payloads[UserProfileStore.storageKey] = Data(
            #"{"name":"Maya","addressAs":"Mum","dateOfBirth":{"year":1943,"month":7,"day":21},"emergencyDoctor":"Dr. Sharma","localHospital":"Teaching Hospital"}"#.utf8)

        guard case .loaded(let loaded) = store.load() else {
            return XCTFail("a pre-selfie payload must load, not fail the read")
        }
        XCTAssertEqual(loaded.name, "Maya")
        XCTAssertEqual(loaded.emergencyDoctor, "Dr. Sharma")
        XCTAssertNil(loaded.photoFilename,
                     "the missing key reads as nil — the unversioned-store rule")
    }

    func testSelfieFilenameRoundTripsThroughTheStore() {
        var profile = UserProfile(name: "Maya", addressAs: "Mum",
                                  dateOfBirth: nil,
                                  emergencyDoctor: nil, localHospital: nil)
        profile.photoFilename = "selfie-1.jpg"
        assertSaveSucceeds(store.save(profile))

        let reopened = UserProfileStore(storage: storage, observabilityBus: bus)
        guard case .loaded(let loaded) = reopened.load() else {
            return XCTFail("the saved record must decode from disk")
        }
        XCTAssertEqual(loaded.photoFilename, "selfie-1.jpg",
                       "the selfie file name survives the disk round trip")
        XCTAssertEqual(loaded, profile)
    }

    // MARK: - Events (content-free, allow-listed keys only)

    func testEventsCarryNoMetadataAndOnlyAllowListedFields() {
        _ = store.load()  // disk observation: absent
        assertSaveSucceeds(store.save(UserProfile(name: "Maya", addressAs: "Mum",
                                                  dateOfBirth: nil,
                                                  emergencyDoctor: nil,
                                                  localHospital: nil)))
        _ = store.load()  // cache hit: no event

        XCTAssertFalse(bus.events.isEmpty)
        for event in bus.events {
            XCTAssertEqual(event.component, "profile")
            XCTAssertTrue(event.metadata.isEmpty,
                          "profile events are content-free (NFR-PI-002)")
            XCTAssertTrue(["success", "failure"].contains(event.outcome))
            XCTAssertNil(event.durationMs)
            XCTAssertTrue(
                ["profile_store_loaded", "profile_store_absent",
                 "profile_store_unreadable", "profile_store_saved"]
                    .contains(event.eventType))
        }
        XCTAssertEqual(bus.events.map(\.eventType),
                       ["profile_store_absent", "profile_store_saved"],
                       "one event per disk observation, never per cache hit")
    }

    // MARK: - Concurrency

    func testLoadIsSafeFromSeveralQueuesAndCachesOnce() {
        storage.payloads[UserProfileStore.storageKey] =
            Data(#"{"name":"Maya","addressAs":"Mum"}"#.utf8)

        var results: [ProfileLoadResult] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let result = store.load()
            lock.lock()
            results.append(result)
            lock.unlock()
        }
        XCTAssertEqual(results.count, 8)
        for result in results {
            guard case .loaded(let profile) = result else {
                return XCTFail("every concurrent load must see the record")
            }
            XCTAssertEqual(profile.name, "Maya")
        }
        XCTAssertEqual(storage.probeCalls.count, 1,
                       "the lock must collapse the first reads into one "
                       + "disk observation")
    }

    // Save is main-thread-only by contract, enforced by
    // `dispatchPrecondition(condition: .onQueue(.main))` in
    // `UserProfileStore.save`. It is deliberately NOT exercised off-main
    // here: the precondition traps the whole test process in a debug
    // build, so an in-process test would crash the bundle instead of
    // asserting. The contract is carried by the precondition itself and
    // observed in the release evidence (T-105).
}
