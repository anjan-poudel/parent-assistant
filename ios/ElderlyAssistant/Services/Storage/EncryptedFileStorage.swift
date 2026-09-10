import Foundation
import CryptoKit

// MARK: - Encrypted file store (startup review P1-6, 2026-09-10)
//
// The Keychain is for SMALL SECRETS. Everything structured — contacts,
// appointments, histories, reminder state, feed config, cached
// presentation data — belongs in encrypted FILES under Application
// Support with Data Protection class Complete, because a Keychain item
// per payload is slow to write, awkward to size, and pays
// `SecItemCopyMatching` on every read (the boot restore read a dozen of
// them before the first frame was even committed).
//
// This store is the file half. Protection matches what the constitution
// §Security requires and what `KeychainEncryptedStorage` already used
// (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`):
//
//  - `.completeFileProtection` on every write — unreadable while the
//    device is locked, exactly like the Keychain item it replaces,
//  - `isExcludedFromBackup` — never migrated to a new device via
//    iCloud/iTunes, matching `…ThisDeviceOnly`,
//  - atomic writes (temp file + rename), so a crash mid-write leaves the
//    previous value intact rather than a truncated one.
//
// A key is hashed (SHA-256, hex) for its file name: store keys are
// arbitrary strings — the Nepali calendar plugin builds one from the
// user's own question text, which can contain "/" — so a raw key must
// never reach the file system as a path component. The original key is
// kept INSIDE the file (`Envelope.key`), which also lets a read detect a
// mismatched/collided file instead of handing back someone else's value.
//
// Byte-verbatim access (`RawEncryptedStorage`) is the migration seam: the
// Keychain → file migration copies the stored bytes through unchanged, so
// the value that lands on disk is bit-for-bit what the Keychain held.

/// Verbatim byte access to an encrypted store. Byte-level on purpose —
/// never decode/re-encode — so a migrated payload is identical to the
/// original even when the type is only `Decodable`, or when the encoding
/// would not round-trip (dictionary ordering, float formatting, dates).
protocol RawEncryptedStorage {
    /// The stored payload verbatim, or nil when the key is absent.
    func readRawData(key: String) -> Data?
    /// Stores `data` verbatim as the key's payload.
    func writeRawData(_ data: Data, key: String) -> Result<Void, StorageError>
}

/// The file-store surface the Keychain → file migration drives. A
/// protocol (rather than the concrete store) so the migration's failure
/// paths — an unavailable store, a write that does not read back — are
/// reachable in tests without a real file system or a crash-inducing
/// sandbox trick.
protocol MigratableFileStorage: EncryptedLocalStorage, RawEncryptedStorage {
    /// Payloads for `keys`, read in ONE pass over the store.
    func snapshotPayloads(keys: [String]) -> [String: Data]
}

/// JSON-file-backed `EncryptedLocalStorage` under
/// `Application Support/EncryptedStore/`.
final class EncryptedFileStorage: MigratableFileStorage {

    /// What actually lands on disk: the original key plus the payload as
    /// encoded by the CALLER's type (`EncryptedLocalStorage.write`) or
    /// copied through verbatim (`writeRawData`).
    struct Envelope: Codable {
        let key: String
        let payload: Data
    }

    static let directoryName = "EncryptedStore"

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// nil when Application Support could not be resolved: read/write then
    /// fail (so a migration keeps the Keychain copy and a write falls back
    /// to the Keychain) instead of silently storing data somewhere that
    /// does not survive the next launch. `ContactPhotoStore` falls back to
    /// the temporary directory because thumbnails are best-effort visuals;
    /// this store holds the user's data and must fail closed.
    private let rootDirectory: URL?

    init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            self.rootDirectory = Self.defaultRootDirectory(fileManager: fileManager)
        }
        ensureDirectory()
    }

    /// Production location. `create: true` so the Application Support
    /// container exists on a first launch.
    static func defaultRootDirectory(fileManager: FileManager = .default) -> URL? {
        guard let base = try? fileManager.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask,
                                              appropriateFor: nil,
                                              create: true) else { return nil }
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    // MARK: - EncryptedLocalStorage

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        do {
            return writeRawData(try encoder.encode(value), key: key)
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard let payload = readRawData(key: key) else {
            return .failure(.encryptedReadFailed)
        }
        do {
            return .success(try decoder.decode(type, from: payload))
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        // No store directory = nothing was ever stored here.
        guard let url = url(for: key) else { return .success(()) }
        guard fileManager.fileExists(atPath: url.path) else { return .success(()) }
        do {
            try fileManager.removeItem(at: url)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    // MARK: - RawEncryptedStorage

    func readRawData(key: String) -> Data? {
        guard let url = url(for: key),
              let data = try? Data(contentsOf: url),
              let envelope = try? decoder.decode(Envelope.self, from: data),
              // A file whose payload was written under a different key is
              // not this key's value (hash collision, renamed file, or a
              // stale copy) — report it as absent instead of serving it.
              envelope.key == key else { return nil }
        return envelope.payload
    }

    func writeRawData(_ data: Data, key: String) -> Result<Void, StorageError> {
        guard let url = url(for: key) else { return .failure(.encryptedWriteFailed) }
        do {
            ensureDirectory()
            let envelope = Envelope(key: key, payload: data)
            try encoder.encode(envelope).write(
                to: url, options: [.atomic, .completeFileProtection])
            excludeFromBackup(url)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    // MARK: - Read snapshot ([BOOT-REVIEW P1-6])

    /// Reads several keys in ONE pass over the store: the directory is
    /// enumerated once and each requested key costs a single file read —
    /// the boot restore's "one transactional open/read" instead of one
    /// directory resolution + read per store. Keys that are absent are
    /// simply missing from the result.
    func snapshotPayloads(keys: [String]) -> [String: Data] {
        guard let rootDirectory else { return [:] }
        let filesByName = (try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]))?
            .reduce(into: [String: URL]()) { $0[$1.lastPathComponent] = $1 } ?? [:]

        var result: [String: Data] = [:]
        for key in keys {
            guard let url = filesByName[Self.fileName(for: key)],
                  let data = try? Data(contentsOf: url),
                  let envelope = try? decoder.decode(Envelope.self, from: data),
                  envelope.key == key else { continue }
            result[key] = envelope.payload
        }
        return result
    }

    // MARK: - Paths

    /// SHA-256 of the key, hex — a store key is arbitrary text (one of
    /// them is built from the user's own question), so it can never be
    /// used as a path component directly.
    static func fileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func url(for key: String) -> URL? {
        rootDirectory?.appendingPathComponent(Self.fileName(for: key),
                                              isDirectory: false)
    }

    private func ensureDirectory() {
        guard let rootDirectory else { return }
        try? fileManager.createDirectory(at: rootDirectory,
                                         withIntermediateDirectories: true)
        excludeFromBackup(rootDirectory)
    }

    private func excludeFromBackup(_ url: URL) {
        var mutable = url
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        try? mutable.setResourceValues(resource)
    }
}
