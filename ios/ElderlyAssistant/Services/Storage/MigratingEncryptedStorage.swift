import Foundation

// MARK: - Keychain → encrypted-file migration (startup review P1-6, 2026-09-10)
//
// One `EncryptedLocalStorage` in front of two: the Keychain (small
// secrets, see `StoragePlacementPolicy`) and the encrypted file store
// (everything structured). The coordinator hands this to every store, so
// the placement decision stays in one auditable place and no store has to
// know which channel it is on.
//
// The migration is TRANSACTIONAL and one-way per key, and it never drops
// the only copy of anything:
//
//   read a key that is not in the file store yet
//     → Keychain has it?
//         → copy the payload VERBATIM into the file store (atomic write)
//         → read it back and compare byte-for-byte
//             → equal:  the file is authoritative → remove the Keychain item
//             → differ: remove the bad file copy, KEEP the Keychain item
//         → return the value the Keychain held (never a re-encoded one)
//
// Failure modes and what they leave behind:
//
//   - file store unavailable (no Application Support) → nothing is
//     copied, nothing is deleted: every read still comes from the
//     Keychain, exactly as before this change,
//   - write to the file store fails → the write falls back to the
//     Keychain, so durability is never worse than the Keychain-only
//     behavior this replaces,
//   - Keychain delete fails after a verified file write → both copies
//     hold the SAME bytes and reads prefer the file; harmless,
//   - delete: the Keychain copy goes FIRST, then the file. The reverse
//     order would let a surviving Keychain item resurrect a deleted
//     value on the next read.
//
// The migration is idempotent and safe to run from several queues at
// once: two readers of the same key write the same bytes and the second
// `SecItemDelete` is a no-op.

/// `EncryptedLocalStorage` that routes each key to the Keychain or the
/// encrypted file store and migrates the structured keys across on first
/// read.
final class MigratingEncryptedStorage: EncryptedLocalStorage {

    private let keychain: any EncryptedLocalStorage & RawEncryptedStorage
    private let files: any MigratableFileStorage

    /// Guards `snapshot` only (see `withReadSnapshot`).
    private let lock = NSLock()
    private var snapshot: [String: Data] = [:]
    private var snapshotDepth = 0
    private let decoder = JSONDecoder()

    init(keychain: any EncryptedLocalStorage & RawEncryptedStorage
            = KeychainEncryptedStorage(),
         files: any MigratableFileStorage = EncryptedFileStorage()) {
        self.keychain = keychain
        self.files = files
    }

    // MARK: - EncryptedLocalStorage

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        guard StoragePlacementPolicy.migratesToFile(key) else {
            return keychain.write(key: key, value: value)
        }
        switch files.write(key: key, value: value) {
        case .success:
            // A read snapshot must never outlive the write that supersedes
            // it (a store that seeds-then-reads inside one batch would
            // otherwise see its own pre-write value).
            invalidateSnapshotEntry(for: key)
            // The file is authoritative now. A surviving legacy item would
            // only be a stale shadow for a later fallback read — drop it,
            // best-effort (the file already has the newer value).
            if keychain.readRawData(key: key) != nil {
                _ = keychain.delete(key: key)
            }
            return .success(())
        case .failure:
            // Files unwritable (disk full, protection churn): keep the
            // pre-migration durability rather than lose the write.
            return keychain.write(key: key, value: value)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard StoragePlacementPolicy.migratesToFile(key) else {
            return keychain.read(key: key, type: type)
        }
        // Inside a read snapshot the payload is already in memory — one
        // store opening serves the whole boot batch.
        if let payload = snapshotPayload(for: key) {
            do {
                return .success(try decoder.decode(type, from: payload))
            } catch {
                return .failure(.encryptedReadFailed)
            }
        }
        if case .success(let value) = files.read(key: key, type: type) {
            return .success(value)
        }
        // Not in the file store yet — the legacy read, and the migration.
        guard case .success(let value) = keychain.read(key: key, type: type) else {
            return .failure(.encryptedReadFailed)
        }
        migrateToFileIfPossible(key: key)
        return .success(value)
    }

    func delete(key: String) -> Result<Void, StorageError> {
        guard StoragePlacementPolicy.migratesToFile(key) else {
            return keychain.delete(key: key)
        }
        // Legacy copy first (see the header): a delete must not be undone
        // by a Keychain item that outlives the file.
        let legacy = keychain.delete(key: key)
        guard case .success = legacy else { return legacy }
        invalidateSnapshotEntry(for: key)
        return files.delete(key: key)
    }

    // MARK: - Read snapshot ([BOOT-REVIEW P1-6])

    /// Runs `body` with `keys`' payloads loaded in one pass over the file
    /// store (`EncryptedFileStorage.snapshotPayloads`), so the boot
    /// restore's per-store reads do not each open the store again. Only
    /// the file-backed keys are snapshot; Keychain-resident keys keep
    /// going through the Keychain (they are a handful of small reads by
    /// design).
    ///
    /// Nesting is counted, and the snapshot is installed for the
    /// duration of `body` only.
    func withReadSnapshot<T>(keys: [String], _ body: () -> T) -> T {
        installSnapshot(files.snapshotPayloads(
            keys: keys.filter(StoragePlacementPolicy.migratesToFile)))
        defer { removeSnapshot() }
        return body()
    }

    private func installSnapshot(_ payloads: [String: Data]) {
        lock.lock()
        snapshotDepth += 1
        if snapshotDepth == 1 { snapshot = payloads }
        lock.unlock()
    }

    private func removeSnapshot() {
        lock.lock()
        snapshotDepth = max(0, snapshotDepth - 1)
        if snapshotDepth == 0 { snapshot = [:] }
        lock.unlock()
    }

    private func snapshotPayload(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return snapshotDepth > 0 ? snapshot[key] : nil
    }

    /// Drops one key from an installed snapshot — a write or a delete
    /// during the snapshot's lifetime must not be masked by the payload it
    /// replaced.
    private func invalidateSnapshotEntry(for key: String) {
        lock.lock()
        if snapshotDepth > 0 { snapshot[key] = nil }
        lock.unlock()
    }

    // MARK: - Migration

    /// Copies `key` from the Keychain into the file store, verbatim, and
    /// removes the Keychain copy only after the copy on disk has been read
    /// back and compared byte-for-byte. Every failure path leaves the
    /// Keychain item in place.
    private func migrateToFileIfPossible(key: String) {
        guard let raw = keychain.readRawData(key: key) else { return }
        guard case .success = files.writeRawData(raw, key: key) else { return }
        guard files.readRawData(key: key) == raw else {
            // A copy that does not read back as the same bytes must never
            // shadow the Keychain value: remove it and keep the original.
            _ = files.delete(key: key)
            return
        }
        _ = keychain.delete(key: key)
    }
}
