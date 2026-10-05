import Foundation

// MARK: - Encrypted user profile record (profile-interview, T-090)
//
// One encrypted single-record store for the interview fields (plus the
// optional About-you selfie), on the
// existing encrypted-file channel (`user.profile` → Application Support /
// `EncryptedStore/`, sha256 file name, `{key, payload}` envelope, atomic +
// complete file protection, excluded from backup — the placement policy
// routes it there because the key is not in `keychainResidentKeys`).
//
// Design contract (design-l2 §5.1), verbatim semantics:
//
//  - `name` / `addressAs` are non-optional: a payload MISSING either key
//    fails to decode and is UNREADABLE — never defaulted. An empty string
//    is legal and means "not recorded yet" (Skip path, partial fill,
//    Settings clear; FR-PI-011).
//  - absent vs unreadable is discriminated through the `hasPayload` probe
//    (tri-state — `nil` = unknowable is NEVER read as absent; NFR-PI-010,
//    FR-PI-015).
//  - the first load of an unusable payload returns `.unreadable` and then
//    discards the payload best-effort, EXACTLY once; the cache then holds
//    what the store now contains (no re-read loop — R7).
//  - writes are main-thread-only by contract (asserted) and atomic; on
//    failure the previously stored record stays in effect and the cache is
//    not touched (E3).
//  - first-load events are content-free (`outcome` / `error_code` only,
//    empty metadata) and fire once per disk observation, never per cache
//    hit (§7.3, NFR-PI-002).

/// The single profile record. Unversioned; every future addition is an
/// optional key read as nil when absent (the FamilyContact convention).
/// `name` / `addressAs` are non-optional Strings: a payload MISSING those
/// keys is unreadable — never defaulted. An empty string is legal and
/// means "not recorded yet" (skip path, partial fill, Settings clear).
///
/// `photoFilename` (about-you selfie, 2026-10-06): the name of the
/// person's stored selfie under Application Support/ContactPhotos (see
/// `ContactPhotoStore`) — just a file NAME, never a path, exactly like
/// `FamilyContact.photoFilename`. Optional with the same migration: the
/// custom decoder reads a missing key as nil, so a payload written
/// before the selfie existed loads photo-less instead of failing.
struct UserProfile: Codable, Equatable {
    var name: String
    var addressAs: String
    var dateOfBirth: DateComponents?   // year/month/day only; never spoken, never prompted
    var emergencyDoctor: String?
    var localHospital: String?
    /// ContactPhotoStore filename of the person's selfie, nil when none
    /// is on file (the photo is optional — the capture step can be
    /// skipped like every other field).
    var photoFilename: String?

    init(name: String,
         addressAs: String,
         dateOfBirth: DateComponents?,
         emergencyDoctor: String?,
         localHospital: String?,
         photoFilename: String? = nil) {
        self.name = name
        self.addressAs = addressAs
        self.dateOfBirth = dateOfBirth
        self.emergencyDoctor = emergencyDoctor
        self.localHospital = localHospital
        self.photoFilename = photoFilename
    }

    /// Custom decode (the FamilyContact migration pattern): a payload
    /// written BEFORE the selfie field existed must load with a nil
    /// filename, not fail the whole store read. The mandatory keys keep
    /// the store's contract — a payload missing `name` or `addressAs`
    /// still throws, so it stays unreadable, never defaulted.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        addressAs = try container.decode(String.self, forKey: .addressAs)
        dateOfBirth = try container.decodeIfPresent(DateComponents.self, forKey: .dateOfBirth)
        emergencyDoctor = try container.decodeIfPresent(String.self, forKey: .emergencyDoctor)
        localHospital = try container.decodeIfPresent(String.self, forKey: .localHospital)
        // A missing key AND a malformed value both read as "no photo".
        photoFilename = (try? container.decodeIfPresent(String.self, forKey: .photoFilename)) ?? nil
    }
}

enum ProfileLoadResult {
    case absent                        // fresh install / never written / discarded
    case loaded(UserProfile)
    case unreadable(ProfileStoreError) // present but not usable
}

enum ProfileStoreError: Error, Equatable {
    case readFailed     // the store could not answer "is there a payload?"
    case decodeFailed   // payload present, but not a valid UserProfile
    case writeFailed    // the atomic write failed
}

/// The raw seam the store needs from the encrypted storage chain.
/// Deliberately NOT `RawEncryptedStorage`: it adds the presence probe
/// that distinguishes absent from unreadable, and inherits the typed
/// write/delete surface from the existing protocol.
protocol ProfilePayloadStorage: EncryptedLocalStorage {
    /// The stored payload verbatim, or nil when the key is absent AND
    /// when a file exists but does not yield a payload.
    func readRawData(key: String) -> Data?
    /// true  = a payload exists for `key` (even if unreadable),
    /// false = no payload,
    /// nil   = unknowable (store location unresolvable, or the file
    ///         channel does not expose the probe). Never read as absent.
    func hasPayload(key: String) -> Bool?
}

protocol UserProfileStoring: AnyObject {
    /// Never throws; a failure is an explicit case. Callable from any
    /// queue; the result is cached after the first disk read.
    func load() -> ProfileLoadResult
    /// Main-thread writer (UI-initiated through the coordinator). Atomic;
    /// on failure the previously stored record stays in effect and the
    /// cache is not touched.
    func save(_ profile: UserProfile) -> Result<Void, ProfileStoreError>
}

final class UserProfileStore: UserProfileStoring {

    /// Constant, not tunable (L1 §11). Placement rides the existing
    /// policy: not in `keychainResidentKeys` → encrypted-file channel.
    static let storageKey = "user.profile"

    private let storage: ProfilePayloadStorage
    private let observabilityBus: ObservabilityBus?
    private let decoder = JSONDecoder()

    /// Guards the cache AND the disk access: readers never see a partial
    /// record, and the first read primes every later one (§6).
    private let lock = NSLock()
    private var cachedResult: ProfileLoadResult?

    init(storage: ProfilePayloadStorage, observabilityBus: ObservabilityBus?) {
        self.storage = storage
        self.observabilityBus = observabilityBus
    }

    // MARK: - Reading

    func load() -> ProfileLoadResult {
        lock.lock()
        defer { lock.unlock() }
        if let cachedResult { return cachedResult }
        let observation = observeDisk()
        cachedResult = observation.cached
        return observation.result
    }

    /// One disk observation: probe → raw read → decode, with the design's
    /// exhaustive mapping. `result` is what THIS load reports (a corrupt
    /// payload reports `.unreadable(.decodeFailed)` even when the discard
    /// then succeeds); `cached` is what the next load reports.
    private func observeDisk() -> (result: ProfileLoadResult, cached: ProfileLoadResult) {
        switch storage.hasPayload(key: Self.storageKey) {
        case .none:
            // Unknowable is a failure, never "absent" — and nothing is
            // deleted (the store may hold a perfectly good record).
            emit(eventType: "profile_store_unreadable",
                 outcome: "failure", errorCode: "read_failed")
            return (.unreadable(.readFailed), .unreadable(.readFailed))

        case .some(false):
            emit(eventType: "profile_store_absent", outcome: "success")
            return (.absent, .absent)

        case .some(true):
            if let data = storage.readRawData(key: Self.storageKey),
               let profile = try? decoder.decode(UserProfile.self, from: data) {
                emit(eventType: "profile_store_loaded", outcome: "success")
                return (.loaded(profile), .loaded(profile))
            }
            // Present but not usable: report decode_failed, then discard
            // best-effort exactly once. A failed delete caches the
            // unreadable verdict so no per-read delete loop forms.
            emit(eventType: "profile_store_unreadable",
                 outcome: "failure", errorCode: "decode_failed")
            let discarded: Bool
            if case .success = storage.delete(key: Self.storageKey) {
                discarded = true
            } else {
                discarded = false
            }
            return (.unreadable(.decodeFailed),
                    discarded ? .absent : .unreadable(.decodeFailed))
        }
    }

    // MARK: - Writing

    func save(_ profile: UserProfile) -> Result<Void, ProfileStoreError> {
        // Main-thread-only by contract (UI-initiated through the
        // coordinator). The file I/O still happens behind the lock so a
        // concurrent reader never observes a partial swap.
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        defer { lock.unlock() }
        switch storage.write(key: Self.storageKey, value: profile) {
        case .success:
            cachedResult = .loaded(profile)
            emit(eventType: "profile_store_saved", outcome: "success")
            return .success(())
        case .failure:
            // The previously stored record (file and cache) stays in
            // effect; nothing is claimed (E3).
            return .failure(.writeFailed)
        }
    }

    // MARK: - Events

    private func emit(eventType: String, outcome: String, errorCode: String? = nil) {
        observabilityBus?.emit(ObservabilityEvent(
            component: "profile",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: [:]
        ))
    }
}
