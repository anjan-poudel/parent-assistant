import XCTest
@testable import ElderlyAssistant

/// Guards the Spotify credential store (T-108, C-SP-02 / FR-SP-009,
/// FR-SP-010, NFR-SP-007): the single `spotify.session` record round-trips
/// through the encrypted seam, failures are typed and never swallow the
/// previous record, and the unlink wipe leaves no credential material
/// anywhere in the seam.
///
/// The seam double is the `GeminiInMemoryStorage` precedent plus two
/// things this feature owes the security evidence: write/read/delete
/// failure injection, and a raw-payload sweep so "zero credential
/// material after wipe" (security evidence obligation 2) is asserted
/// against every byte the seam holds, not just the expected key.
final class SpotifyCredentialStoreTests: XCTestCase {

    // MARK: - Fixture

    private let accessToken = "sp-access-fixture-001"
    private let refreshToken = "sp-refresh-fixture-002"
    private let scopeText = "user-read-private user-read-email streaming"

    private func makeRecord(
        accessToken: String? = nil,
        refreshToken: String? = nil,
        expiry: Date = Date(timeIntervalSince1970: 1_800_000_000),
        product: String? = "premium",
        scope: String? = nil,
        linkedAt: Date = Date(timeIntervalSince1970: 1_799_000_000)
    ) -> SpotifySessionRecord {
        SpotifySessionRecord(
            accessToken: accessToken ?? self.accessToken,
            refreshToken: refreshToken ?? self.refreshToken,
            expiry: expiry,
            product: product,
            scope: scope ?? scopeText,
            linkedAt: linkedAt)
    }

    // MARK: - Gherkin 1: a session record round-trips field by field

    @MainActor
    func testRecordRoundTripsThroughTheEncryptedStoreFieldByField() {
        let storage = SpotifyInMemoryStorage()
        let store = SpotifyCredentialStore(storage: storage)
        XCTAssertNil(store.record, "an empty seam reads as not configured")
        XCTAssertFalse(store.isLinked)

        let saved = makeRecord()
        guard case .success = store.save(saved) else {
            return XCTFail("save of a well-formed record must succeed")
        }
        XCTAssertEqual(store.record, saved)
        XCTAssertTrue(store.isLinked)

        // Relaunch: a fresh store over the same seam reads every field
        // back — the encrypted store is the only read path (NFR-SP-007
        // scenario 2), asserted field by field because the six-field
        // record is the contract.
        let reloaded = SpotifyCredentialStore(storage: storage)
        XCTAssertEqual(reloaded.record?.accessToken, saved.accessToken)
        XCTAssertEqual(reloaded.record?.refreshToken, saved.refreshToken)
        XCTAssertEqual(reloaded.record?.expiry, saved.expiry)
        XCTAssertEqual(reloaded.record?.product, saved.product)
        XCTAssertEqual(reloaded.record?.scope, saved.scope)
        XCTAssertEqual(reloaded.record?.linkedAt, saved.linkedAt)
        XCTAssertEqual(reloaded.record, saved)
        XCTAssertTrue(reloaded.isLinked)
    }

    @MainActor
    func testStorageKeyIsPinnedToTheSingleSpotifyKey() {
        // Constant ↔ literal, both sides: the store's key must be exactly
        // the one `StoragePlacementTests` places in the Keychain (that
        // file pins its own literal), so a rename on either side fails a
        // test instead of silently moving a token to the file store.
        XCTAssertEqual(SpotifyCredentialStore.storageKey, "spotify.session")
        XCTAssertEqual(StoragePlacementPolicy.placement(for: SpotifyCredentialStore.storageKey),
                       .keychain)
        XCTAssertFalse(StoragePlacementPolicy.migratesToFile(SpotifyCredentialStore.storageKey))
    }

    @MainActor
    func testTheStoreTouchesExactlyOneKeyAndKeepsNoSecondPersistencePath() {
        let storage = SpotifyInMemoryStorage()
        let store = SpotifyCredentialStore(storage: storage)

        guard case .success = store.save(makeRecord()) else {
            return XCTFail("first save must succeed")
        }
        // A token refresh rewrites the same single record.
        guard case .success = store.save(makeRecord(accessToken: "sp-access-rotated-003")) else {
            return XCTFail("rotated save must succeed")
        }
        guard case .success = store.clear() else {
            return XCTFail("clear must succeed")
        }

        XCTAssertEqual(storage.writtenKeys,
                       [SpotifyCredentialStore.storageKey, SpotifyCredentialStore.storageKey],
                       "the store may only ever write the one declared key")
        XCTAssertTrue(storage.rawPayloads.isEmpty,
                      "after the wipe the seam holds no payload at all")
    }

    // MARK: - Gherkin 2: a failed write is typed and leaves the previous
    // record untouched

    @MainActor
    func testFailedWriteSurfacesTheTypedErrorAndKeepsThePreviousRecord() {
        let storage = SpotifyInMemoryStorage()
        let store = SpotifyCredentialStore(storage: storage)
        let previous = makeRecord()
        guard case .success = store.save(previous) else {
            return XCTFail("seeding save must succeed")
        }

        storage.failWrites = true
        let replacement = makeRecord(accessToken: "sp-access-replacement-004")
        guard case .failure(let error) = store.save(replacement) else {
            return XCTFail("a failed write must not return success")
        }
        switch error {
        case .encryptedWriteFailed:
            break
        case .encryptedReadFailed:
            XCTFail("a write failure is encryptedWriteFailed, not \(error)")
        }

        // In memory and on disk: the previous record, unchanged.
        XCTAssertEqual(store.record, previous)
        XCTAssertTrue(store.isLinked)
        XCTAssertEqual(SpotifyCredentialStore(storage: storage).record, previous)
        XCTAssertEqual(storage.keysCarryingMaterial("sp-access-replacement-004"), [],
                       "the failed write must not leak any replacement material")
    }

    @MainActor
    func testFailedClearSurfacesAndTheRecordStaysVisible() {
        let storage = SpotifyInMemoryStorage()
        let store = SpotifyCredentialStore(storage: storage)
        let saved = makeRecord()
        guard case .success = store.save(saved) else {
            return XCTFail("seeding save must succeed")
        }

        storage.failDeletes = true
        guard case .failure(let error) = store.clear() else {
            return XCTFail("a failed wipe must not report success")
        }
        switch error {
        case .encryptedWriteFailed:
            break
        case .encryptedReadFailed:
            XCTFail("a delete failure is encryptedWriteFailed, not \(error)")
        }

        // The status flips only on a confirmed wipe: the record is still
        // there, in memory and on disk (FR-SP-010).
        XCTAssertEqual(store.record, saved)
        XCTAssertTrue(store.isLinked)
        XCTAssertEqual(SpotifyCredentialStore(storage: storage).record, saved)
    }

    // MARK: - Degradation: absent or corrupt reads as not configured

    @MainActor
    func testAbsentSeamReadsAsNotConfigured() {
        let store = SpotifyCredentialStore(storage: SpotifyInMemoryStorage())
        XCTAssertNil(store.record)
        XCTAssertFalse(store.isLinked)
    }

    @MainActor
    func testCorruptStoredPayloadReadsAsNotConfiguredWithNoPlaintextFallback() {
        let storage = SpotifyInMemoryStorage()
        storage.seedRawPayload(Data("{ not a session record".utf8),
                               forKey: SpotifyCredentialStore.storageKey)

        let store = SpotifyCredentialStore(storage: storage)
        XCTAssertNil(store.record, "corrupt bytes must not be guessed at")
        XCTAssertFalse(store.isLinked)

        // A later successful save overwrites the corrupt payload — init
        // performed no destructive repair of its own.
        guard case .success = store.save(makeRecord()) else {
            return XCTFail("overwriting a corrupt payload must succeed")
        }
        XCTAssertEqual(SpotifyCredentialStore(storage: storage).record, makeRecord())
    }

    @MainActor
    func testUnreadableSeamDegradesToNotConfigured() {
        let storage = SpotifyInMemoryStorage()
        guard case .success = SpotifyCredentialStore(storage: storage).save(makeRecord()) else {
            return XCTFail("seeding save must succeed")
        }
        storage.failReads = true
        // NFR-SP-007 scenario 3: an unavailable secure store reads as not
        // configured — never a crash, never a plaintext fallback.
        let store = SpotifyCredentialStore(storage: storage)
        XCTAssertNil(store.record)
        XCTAssertFalse(store.isLinked)
    }

    // MARK: - Gherkin 3 + obligation 2: wipe leaves no residue

    @MainActor
    func testWipeLeavesNothingLoadable() {
        let storage = SpotifyInMemoryStorage()
        let store = SpotifyCredentialStore(storage: storage)
        guard case .success = store.save(makeRecord()) else {
            return XCTFail("seeding save must succeed")
        }

        guard case .success = store.clear() else {
            return XCTFail("clear must succeed")
        }
        XCTAssertNil(store.record)
        XCTAssertFalse(store.isLinked)
        XCTAssertTrue(storage.rawPayloads.isEmpty)
        // And a relaunch-time reader over the wiped seam agrees.
        XCTAssertNil(SpotifyCredentialStore(storage: storage).record)
        XCTAssertFalse(SpotifyCredentialStore(storage: storage).isLinked)
    }

    @MainActor
    func testPostWipeSweepFindsNoCredentialMaterialInAnyChannel() {
        let storage = SpotifyInMemoryStorage()
        // A neighbouring encrypted payload — the wipe must be a targeted
        // single-key delete, not a scorched-earth clear of the seam.
        _ = storage.write(key: "family.contacts", value: Data("[]".utf8))

        let store = SpotifyCredentialStore(storage: storage)
        guard case .success = store.save(makeRecord()) else {
            return XCTFail("seeding save must succeed")
        }

        // While linked, every piece of credential material lives under
        // exactly the one declared key — swept across EVERY key in the
        // seam, not just the expected one.
        for material in [accessToken, refreshToken, "user-read-private", "premium"] {
            XCTAssertEqual(storage.keysCarryingMaterial(material),
                           [SpotifyCredentialStore.storageKey],
                           "'\(material)' must live only under the declared key")
        }

        guard case .success = store.clear() else {
            return XCTFail("clear must succeed")
        }

        // Security evidence obligation 2: after the wipe, a sweep of every
        // key the encrypted seam holds finds zero credential material.
        for material in [accessToken, refreshToken, "user-read-private",
                         "user-read-email", "premium", "sp-access", "sp-refresh"] {
            XCTAssertEqual(storage.keysCarryingMaterial(material), [],
                           "no key may carry '\(material)' after the wipe")
        }
        XCTAssertEqual(storage.rawPayloads.keys.sorted(), ["family.contacts"],
                       "the wipe removes the Spotify record and nothing else")
    }

    // MARK: - NFR-SP-002: failures carry a classification, no content

    @MainActor
    func testFailureSurfacingCarriesNoCredentialContent() {
        let storage = SpotifyInMemoryStorage()
        let store = SpotifyCredentialStore(storage: storage)
        storage.failWrites = true

        guard case .failure(let error) = store.save(makeRecord()) else {
            return XCTFail("the injected failure must surface")
        }
        // The only outward failure channel is the fieldless StorageError
        // enum: its rendered form is the classification, and no token,
        // refresh value or scope can ride along with it.
        let rendered = String(describing: error)
        XCTAssertEqual(rendered, "encryptedWriteFailed")
        XCTAssertFalse(rendered.contains(accessToken))
        XCTAssertFalse(rendered.contains(refreshToken))
        XCTAssertFalse(rendered.contains("user-read-private"))
    }
}

/// In-memory `EncryptedLocalStorage` — the `GeminiInMemoryStorage`
/// precedent plus the failure injectors and the raw-payload sweep the
/// credential tests need. `rawPayloads` is every byte the seam holds, so
/// the wipe test can sweep for residue rather than trust the store's own
/// account of what it deleted.
final class SpotifyInMemoryStorage: EncryptedLocalStorage {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private(set) var rawPayloads: [String: Data] = [:]
    private(set) var writtenKeys: [String] = []
    var failWrites = false
    var failReads = false
    var failDeletes = false

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        guard !failWrites, let data = try? encoder.encode(value) else {
            return .failure(.encryptedWriteFailed)
        }
        rawPayloads[key] = data
        writtenKeys.append(key)
        return .success(())
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard !failReads, let data = rawPayloads[key] else {
            return .failure(.encryptedReadFailed)
        }
        do {
            return .success(try decoder.decode(T.self, from: data))
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        guard !failDeletes else { return .failure(.encryptedWriteFailed) }
        rawPayloads.removeValue(forKey: key)
        return .success(())
    }

    /// Seeds bytes that no store wrote (the corrupt-payload fixture).
    func seedRawPayload(_ data: Data, forKey key: String) {
        rawPayloads[key] = data
    }

    /// The placement sweep: which held keys' payload bytes contain the
    /// needle. The real Keychain encrypts at rest; the double models the
    /// seam's held bytes, so a hit means "material is present at exactly
    /// this key", and an empty result is "no residue anywhere".
    func keysCarryingMaterial(_ needle: String) -> [String] {
        rawPayloads.compactMap { key, data in
            String(data: data, encoding: .utf8)?.contains(needle) == true ? key : nil
        }.sorted()
    }
}
