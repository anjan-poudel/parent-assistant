import XCTest
@testable import ElderlyAssistant

/// Template persistence (Services/Voice/VoiceBiometricStore.swift):
/// round-trip across store instances, the enrolled/absent/corrupt
/// distinction, the profile-before-marker write invariant, schema-version
/// refusal, and idempotent clear. Uses the in-memory double of
/// `EncryptedLocalStorage`; the production backing (KeychainEncryptedStorage,
/// WhenUnlockedThisDeviceOnly, no iCloud sync) is the seam this suite
/// proves the store behaves correctly against.
final class VoiceBiometricStoreTests: XCTestCase {

    private func profile(embedderID: String = "mfcc.stats.v1",
                         schemaVersion: Int = VoiceBiometricStore.currentSchemaVersion) -> EnrolledVoiceProfile {
        EnrolledVoiceProfile(
            schemaVersion: schemaVersion,
            embedderID: embedderID,
            embedding: [0.1, -0.2, 0.3, 0.4, 0.5, 0.6, 0.7, -0.8, 0.9, -0.15,
                        0.25, -0.35, 0.45, -0.55, 0.65, -0.75, 0.85, -0.95],
            createdAt: Date(timeIntervalSince1970: 1_752_000_000),
            utteranceCount: 3,
            perUtteranceSpeechSeconds: [2.1, 2.4, 2.2])
    }

    // MARK: - Round-trip

    func testRoundTripAcrossStoreInstances() {
        let storage = VoiceBiometricInMemoryStorage()
        let original = profile()

        let writer = VoiceBiometricStore(storage: storage)
        guard case .success = writer.save(original) else {
            return XCTFail("save must succeed")
        }

        // A fresh store over the SAME storage = a relaunch.
        let relaunch = VoiceBiometricStore(storage: storage)
        switch relaunch.load() {
        case .success(.some(let loaded)):
            XCTAssertEqual(loaded, original,
                           "template bytes must survive the encrypted round-trip intact")
        default:
            XCTFail("expected the saved profile back after a relaunch")
        }
    }

    func testLoadReturnsNilWhenNeverEnrolled() {
        let store = VoiceBiometricStore(storage: VoiceBiometricInMemoryStorage())
        switch store.load() {
        case .success(.none):
            break // expected: never enrolled
        default:
            XCTFail("fresh storage must read as 'not enrolled', not as an error")
        }
    }

    // MARK: - Write invariant: profile before marker

    func testSaveWritesProfileBeforeMarker() {
        let storage = VoiceBiometricInMemoryStorage()
        let store = VoiceBiometricStore(storage: storage)
        _ = store.save(profile())
        XCTAssertEqual(storage.writtenKeys,
                       [VoiceBiometricStore.profileKey, VoiceBiometricStore.markerKey],
                       "a marker must never exist without its profile (corruption-detection invariant)")
    }

    // MARK: - Corruption / tampering

    func testCorruptProfileWithMarkerIsAnErrorNotSilence() {
        let storage = VoiceBiometricInMemoryStorage()
        storage.plantRaw(key: VoiceBiometricStore.profileKey, data: Data("not json at all".utf8))
        // Marker as the REAL store writes it (JSON-encoded true).
        var marker: Data!
        XCTAssertNoThrow(marker = try JSONEncoder().encode(true))
        storage.plantRaw(key: VoiceBiometricStore.markerKey, data: marker)

        let store = VoiceBiometricStore(storage: storage)
        switch store.load() {
        case .failure(.encryptedReadFailed):
            break // expected: loud failure, not a silent "fresh device"
        default:
            XCTFail("a marker without a readable profile must surface as unreadable")
        }
    }

    func testMarkerWithoutProfileIsAnError() {
        let storage = VoiceBiometricInMemoryStorage()
        _ = storage.write(key: VoiceBiometricStore.markerKey, value: true)
        let store = VoiceBiometricStore(storage: storage)
        guard case .failure = store.load() else {
            return XCTFail("marker-only state must be reported as unreadable")
        }
    }

    func testFutureSchemaVersionIsRefusedOnLoad() {
        // A future schema payload is planted RAW (save already refuses it):
        // load must refuse too — we never score a template we cannot parse
        // the meaning of (forward-compat safety).
        let storage = VoiceBiometricInMemoryStorage()
        let store = VoiceBiometricStore(storage: storage)
        guard case .failure = store.save(profile(schemaVersion: VoiceBiometricStore.currentSchemaVersion + 1)) else {
            return XCTFail("save must refuse a future schema version")
        }
        let future = profile(schemaVersion: VoiceBiometricStore.currentSchemaVersion + 1)
        // Planted directly (try! on JSONEncoder of a value type is safe):
        // deliberately NOT wrapped in XCTAssertNoThrow({ ... }) — a
        // parenthesised closure passed to an @autoclosure parameter is
        // never invoked, which would silently skip the planting.
        let data = try! JSONEncoder().encode(future)
        storage.plantRaw(key: VoiceBiometricStore.profileKey, data: data)
        storage.plantRaw(key: VoiceBiometricStore.markerKey, data: try! JSONEncoder().encode(true))
        guard case .failure = store.load() else {
            return XCTFail("a template from a future schema must never be scored")
        }
    }

    func testSaveRefusesInvalidProfiles() {
        let storage = VoiceBiometricInMemoryStorage()
        let store = VoiceBiometricStore(storage: storage)
        guard case .failure = store.save(profile(schemaVersion: 999)) else {
            return XCTFail("save must refuse a wrong schema version")
        }
        guard case .failure = store.save(profile(embedderID: "")) else {
            return XCTFail("save must refuse an empty embedder identity")
        }

        let invalid = EnrolledVoiceProfile(
            schemaVersion: VoiceBiometricStore.currentSchemaVersion,
            embedderID: "mfcc.stats.v1", embedding: [],
            createdAt: Date(), utteranceCount: 3,
            perUtteranceSpeechSeconds: [1.0, 1.0, 1.0])
        guard case .failure = store.save(invalid) else {
            return XCTFail("save must refuse an empty embedding")
        }
        XCTAssertTrue(storage.writtenKeys.isEmpty,
                      "nothing invalid may reach the encrypted storage")
    }

    func testLoadRejectsSanityBrokenProfile() {
        // A payload that DECODES but violates invariants (zero utterances)
        // is as untrustworthy as corrupt bytes.
        let storage = VoiceBiometricInMemoryStorage()
        let store = VoiceBiometricStore(storage: storage)
        let broken = EnrolledVoiceProfile(
            schemaVersion: VoiceBiometricStore.currentSchemaVersion,
            embedderID: "mfcc.stats.v1", embedding: [1, 0, 0],
            createdAt: Date(), utteranceCount: 0,
            perUtteranceSpeechSeconds: [])
        _ = store.save(broken) // save refuses it — plant directly instead
        let data = try! JSONEncoder().encode(broken)
        storage.plantRaw(key: VoiceBiometricStore.profileKey, data: data)
        storage.plantRaw(key: VoiceBiometricStore.markerKey, data: try! JSONEncoder().encode(true))
        guard case .failure = store.load() else {
            return XCTFail("a profile with utteranceCount 0 must be refused on load")
        }
    }

    // MARK: - Clear

    func testClearRemovesTemplateAndMarker() {
        let storage = VoiceBiometricInMemoryStorage()
        let store = VoiceBiometricStore(storage: storage)
        _ = store.save(profile())
        guard case .success = store.clear() else {
            return XCTFail("clear must succeed")
        }
        guard case .success(.none) = store.load() else {
            return XCTFail("after clear, the store must read as not enrolled")
        }
    }

    func testClearIsIdempotent() {
        let store = VoiceBiometricStore(storage: VoiceBiometricInMemoryStorage())
        guard case .success = store.clear() else {
            return XCTFail("first clear must succeed")
        }
        guard case .success = store.clear() else {
            return XCTFail("'Remove voice login' must be safe to press twice (doc §10)")
        }
    }

    // MARK: - Storage failure propagation

    func testSavePropagatesStorageFailure() {
        let storage = VoiceBiometricInMemoryStorage()
        storage.failWrites = true
        let store = VoiceBiometricStore(storage: storage)
        guard case .failure = store.save(profile()) else {
            return XCTFail("storage failure must propagate")
        }
    }

    func testPersistedProfileIsIdentifiedByCurrentSchema() {
        XCTAssertEqual(VoiceBiometricStore.currentSchemaVersion, 1,
                       "bump this constant only with a migration story (doc §10)")
    }
}
