import Foundation

// MARK: - Spotify credential store (T-108, C-SP-02)
//
// The one encrypted record a linked Spotify account leaves on the device
// (ADR-SP-08 / design-l2 §9 and §25). Exactly six fields under exactly
// one storage key — a single Codable value, so the write is atomic and
// the unlink wipe is one delete (FR-SP-010). There is no second
// persistence path: never UserDefaults, never a plist, never a plain
// file, never the repository (FR-SP-009, NFR-SP-007).
//
// The key is classified `keychain` by `StoragePlacementPolicy` — the
// same reviewed small-secrets channel as the Gemini/Search/YouTube keys
// — so whatever `EncryptedLocalStorage` the coordinator hands in (today
// `MigratingEncryptedStorage`), the record lands in the Keychain-backed
// store with Data Protection class Complete.
//
// Log discipline (NFR-SP-002): this store writes no log line and emits
// no event; failures surface to the caller as the `StorageError`
// classification only, and that enum carries no associated values, so no
// token, expiry or scope text has a path out of here except the returned
// record itself.

/// The single `spotify.session` record: everything a linked account keeps
/// on the device. Field-for-field ADR-SP-08 — no additions, so a record
/// round-trips unchanged and the one-key write stays atomic.
struct SpotifySessionRecord: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
    /// "premium" | "free" | nil — the product the token endpoint returned
    /// at link time.
    var product: String?
    /// The granted scope string, kept for verification (L2-D13 derives the
    /// verification age from `expiry`; no extra timestamp field).
    var scope: String?
    var linkedAt: Date
}

/// Owns the one encrypted record (C-SP-02). `@MainActor`-confined like
/// the rest of the Spotify-path mutable state (design-l2 §concurrency).
///
/// Read semantics: the record is loaded in `init`; a missing or corrupt
/// item reads as not configured (`record == nil`, `isLinked == false`)
/// with no plaintext fallback — the honest degradation (NFR-SP-007).
///
/// Write semantics: `save`/`clear` return the typed `StorageError` from
/// the encrypted-write machinery — never a silent success. A failed
/// write leaves the previous record in place (or nil) and a failed clear
/// leaves the record visible, so the linked status flips only on a
/// confirmed wipe (FR-SP-010).
@MainActor
final class SpotifyCredentialStore: ObservableObject {

    /// The single key. Pinned by `SpotifyCredentialStoreTests` (constant ↔
    /// literal) and by the exact-set assertion in `StoragePlacementTests`
    /// (literal), so renaming or moving the key is a deliberate two-file
    /// edit.
    static let storageKey = "spotify.session"

    private let storage: EncryptedLocalStorage

    /// The loaded record — the single source of truth for `isLinked`, the
    /// account session and the Settings surface. `private(set)`: every
    /// mutation goes through `save`/`clear`, so the in-memory value can
    /// never drift from the store.
    @Published private(set) var record: SpotifySessionRecord?

    /// Derived, never stored separately — no split-brain "linked flag"
    /// beside a missing record.
    var isLinked: Bool { record != nil }

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
        self.record = Self.load(from: storage)
    }

    /// Saves the record under the single key. On failure the in-memory
    /// record is untouched and the error is returned — never swallowed.
    /// `init` performed no write, so a corrupt payload on disk is simply
    /// overwritten here on the first successful save.
    @discardableResult
    func save(_ record: SpotifySessionRecord) -> Result<Void, StorageError> {
        switch storage.write(key: Self.storageKey, value: record) {
        case .success:
            self.record = record
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Wipes the single key. The status flips to not linked only after the
    /// delete is confirmed; a failed wipe is surfaced and the record stays
    /// visible (FR-SP-010: on this path the local wipe is the guarantee).
    @discardableResult
    func clear() -> Result<Void, StorageError> {
        switch storage.delete(key: Self.storageKey) {
        case .success:
            self.record = nil
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Missing or corrupt reads as nil — not configured, no fallback, no
    /// destructive repair (a later save overwrites the key).
    private static func load(from storage: EncryptedLocalStorage) -> SpotifySessionRecord? {
        guard case .success(let record) = storage.read(key: storageKey,
                                                       type: SpotifySessionRecord.self) else {
            return nil
        }
        return record
    }
}
