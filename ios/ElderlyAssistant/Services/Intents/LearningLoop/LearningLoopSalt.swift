import CryptoKit
import Foundation
import Security

/// L-4 — the per-install salt (T-053 §3.4; T-054 §3.4).
///
/// 32 random bytes, minted ONCE on the OFF → ON transition and destroyed
/// on opt-out — the salt has no other creation path and no other
/// destruction path (T-054 §3.4: rotation is event-driven only; a
/// scheduled rotation would break the cross-revision dedup the miner
/// depends on while buying nothing salt destruction does not already
/// give).
///
/// **Placement.** The key `learningLoop.salt` MUST be a member of
/// `StoragePlacementPolicy.keychainResidentKeys`, because the policy's
/// default for an unknown key is `.encryptedFile` — an unlisted key would
/// silently put the salt on the encrypted-file channel, where
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
/// `kSecAttrSynchronizable = false` do not apply. `LearningLoopStoreTests`
/// pins the membership.
///
/// **Escrow is forbidden** (T-054 §3.4): never uploaded, never synced,
/// never in an iCloud or encrypted-iTunes backup, never in a project
/// artifact or a log. The Keychain class is what delivers that, and the
/// value never leaves this type except as a digest.
///
/// **Availability failure is fail-closed** (T-054 §3.4): an unreadable
/// salt means no handle is written and no content entry is written. The
/// loop never degrades to an unsalted or no-op-keyed digest — a lost salt
/// makes every previously egressed digest permanently unlinkable to the
/// device, and that is a stated property, not an accident.
final class LearningLoopSalt {

    static let storageKey = "learningLoop.salt"

    /// T-053 §3.4: a 256-bit key generated on-device at opt-in time.
    static let byteCount = 32
    /// T-054 §3.4: 16 hex characters (64 bits).
    static let digestHexLength = 16

    private let storage: EncryptedLocalStorage
    private let lock = NSLock()
    /// Cached after a SUCCESSFUL read only. A failed read is retried: a
    /// Keychain that is unreadable before the first unlock becomes
    /// readable afterwards, and caching the failure would leave the
    /// process capturing nothing for its whole lifetime.
    private var cached: Data?

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    // MARK: - Lifecycle

    /// Mints the salt only if none exists — the OFF → ON transition's
    /// first step. Returns false when the salt cannot be minted, in which
    /// case the caller must NOT write the consent record: consent without
    /// a salt would be a consent the app cannot honour.
    @discardableResult
    func mintIfAbsent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let existing = readLocked() {
            cached = existing
            return true
        }
        var bytes = Data(count: Self.byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, Self.byteCount, base)
        }
        guard status == errSecSuccess else { return false }
        guard case .success = storage.write(key: Self.storageKey, value: bytes) else {
            return false
        }
        cached = bytes
        return true
    }

    /// The salt, or nil when it is unavailable. The capture seam's
    /// fail-closed input.
    func current() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let value = readLocked() else { return nil }
        cached = value
        return value
    }

    /// Destroys the salt — the opt-out's LAST step (T-054 §5.1, S3 → S4).
    /// A keychain delete, not a write of a zeroed value: "destroyed" has
    /// to mean the bytes are gone, or the copy's guarantee (*"it can no
    /// longer be linked to anything you say from now on"*) is a hope.
    func destroy() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        _ = storage.delete(key: Self.storageKey)
    }

    // MARK: - Digests

    /// `HMAC-SHA256(salt, value)` truncated to 16 lowercase hex.
    ///
    /// A KEYED MAC, not a bare `SHA256(salt ‖ value)` (T-053 §3.4): a
    /// bare salted hash is weakened the moment the salt is read, a keyed
    /// MAC keeps the key out of the egressed digest's structure. The
    /// caller supplies the already-normalized value — the handle uses
    /// `NepaliTextNormalizer.normalize`, the same normalization the cache,
    /// the contact resolver and the training-side dataset builder use, so
    /// "same utterance" means the same thing everywhere.
    static func digest(_ value: String, salt: Data) -> String {
        let key = SymmetricKey(data: salt)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(digestHexLength))
    }

    // MARK: - Storage helper

    /// Caller holds `lock`. A missing, unreadable or malformed item reads
    /// as absent — the fail-closed direction.
    private func readLocked() -> Data? {
        guard case .success(let value) = storage.read(key: Self.storageKey, type: Data.self) else {
            return nil
        }
        guard value.count == Self.byteCount else { return nil }
        return value
    }
}
