import Foundation

/// The enrolled speaker template and its enrollment metadata. This is
/// biometric data (research doc §2.3: GDPR Art. 9 special-category): it
/// is stored ONLY through `VoiceBiometricStore` (Keychain,
/// `WhenUnlockedThisDeviceOnly`, no iCloud sync — see
/// KeychainEncryptedStorage, which is that exact pattern), is never
/// written to disk anywhere else, and is never logged. The payload is
/// small by design: a 192-d ECAPA template is 768 B (doc §8); the
/// interim MFCC template is 72-d.
struct EnrolledVoiceProfile: Codable, Equatable, Sendable {
    /// Store schema version; a payload from a newer schema is refused on
    /// load (forward-compat safety: we never score a template we cannot
    /// parse the meaning of).
    let schemaVersion: Int
    /// The embedder that produced the template; scoring requires the same
    /// identity — embedder/model changes force re-enrollment instead of
    /// silently mixing incompatible scores (doc §10).
    let embedderID: String
    /// The centroid embedding (L2-normalised), enrolled over N utterances.
    let embedding: [Float]
    let createdAt: Date
    /// Number of utterances averaged into the centroid (doc §4.3: 3–5).
    let utteranceCount: Int
    /// Per-utterance net-speech seconds at enrollment time — kept so the
    /// Settings/status surface can show enrollment quality honestly, not
    /// for scoring.
    let perUtteranceSpeechSeconds: [Float]
}

/// Persistence for `EnrolledVoiceProfile` via the shared
/// `EncryptedLocalStorage` seam (protocol defined in
/// Services/MedicationScheduler/DependencyProtocols.swift; production
/// backing is `KeychainEncryptedStorage` — Data Protection Complete,
/// this-device-only, per constitution §Security). The store itself has no
/// logging of any kind: template bytes and scores never leave the
/// process (doc §10).
///
/// Enrolled/absent/corrupt are distinguished exactly, without extending
/// the storage protocol: the profile is written under `profileKey` and a
/// one-byte marker under `markerKey`, always profile-first so a marker
/// can never point at nothing. A marker without a readable profile means
/// the template is corrupted/unreadable — surfaced as an error so the
/// status seam reports "needs re-enrollment" instead of silently
/// pretending the device is fresh (the doc's honesty contract, §3.2).
final class VoiceBiometricStore {

    static let currentSchemaVersion = 1
    static let profileKey = "voice.biometric.profile.v1"
    static let markerKey = "voice.biometric.enrolled"

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    /// Production backing: Keychain under a dedicated service namespace,
    /// so no other feature's storage key can collide with (or a careless
    /// other-feature `delete` sweep across) the biometric template.
    static func makeKeychainBacked() -> VoiceBiometricStore {
        VoiceBiometricStore(storage: KeychainEncryptedStorage(
            service: "com.elderlyassistant.voicebiometric"))
    }

    /// Persists a template. Profile-first ordering is the invariant that
    /// makes load()'s corruption detection exact (see the type header).
    func save(_ profile: EnrolledVoiceProfile) -> Result<Void, StorageError> {
        guard profile.schemaVersion == Self.currentSchemaVersion,
              !profile.embedding.isEmpty,
              !profile.embedderID.isEmpty,
              profile.utteranceCount > 0 else {
            return .failure(.encryptedWriteFailed)
        }
        switch storage.write(key: Self.profileKey, value: profile) {
        case .failure(let error):
            return .failure(error)
        case .success:
            return storage.write(key: Self.markerKey, value: true)
        }
    }

    /// Loads the enrolled template.
    ///  - `.success(.some(profile))` — enrolled, payload sane;
    ///  - `.success(nil)` — never enrolled (no marker);
    ///  - `.failure(.encryptedReadFailed)` — marker present but the
    ///    payload is missing, corrupt, or from a future schema: the
    ///    template is unrecoverable by design (Keychain, this-device-only)
    ///    and re-enrollment is the only recovery path (doc §7.1).
    func load() -> Result<EnrolledVoiceProfile?, StorageError> {
        switch storage.read(key: Self.profileKey, type: EnrolledVoiceProfile.self) {
        case .success(let profile):
            guard profile.schemaVersion == Self.currentSchemaVersion,
                  !profile.embedding.isEmpty,
                  !profile.embedderID.isEmpty,
                  profile.utteranceCount > 0 else {
                return .failure(.encryptedReadFailed)
            }
            return .success(profile)
        case .failure:
            switch storage.read(key: Self.markerKey, type: Bool.self) {
            case .success:
                return .failure(.encryptedReadFailed)
            case .failure:
                return .success(nil)
            }
        }
    }

    /// Deletes template and marker together; deleting when nothing is
    /// enrolled is a success (idempotent — the "Remove voice login"
    /// action must be safe to press twice).
    func clear() -> Result<Void, StorageError> {
        let profileDelete = storage.delete(key: Self.profileKey)
        let markerDelete = storage.delete(key: Self.markerKey)
        switch (profileDelete, markerDelete) {
        case (.success, .success):
            return .success(())
        default:
            return .failure(.encryptedWriteFailed)
        }
    }
}
