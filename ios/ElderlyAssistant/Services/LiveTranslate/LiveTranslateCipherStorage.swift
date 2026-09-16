import Foundation
import CryptoKit
import Security

// MARK: - T-032 — the at-rest cipher for the live-translation payloads
//
// [SECURITY REVIEW, 2026-09-17] What `EncryptedFileStorage` calls
// "encrypted" is Data Protection class Complete: the file cannot be read
// while the device is LOCKED, and that is the whole of the claim. On an
// unlocked device — or through a container inspection, which is exactly what
// AM-10's "cache-at-rest inspection of the app container" performs — the
// payload is plain JSON. The cache holds recognized and translated scene
// text; the consent record holds the elder's consent decision. Both are
// user content and both get a real cipher here.
//
// This type is a DECORATOR over the storage seam (`EncryptedLocalStorage` +
// `RawEncryptedStorage`) at this feature's layer — not a change inside
// `EncryptedFileStorage`, which contacts, appointments, chat history,
// medications, the Gemini config, the cost governor and feeds all share.
// Only the two live-translation consumers are wrapped, so no other feature's
// on-disk format changes and no other feature's data needs a migration.
//
// What it guarantees, and why each one is structural rather than a promise:
//
//  - **AES-GCM (CryptoKit) with a 256-bit key in the Keychain**
//    (`KeychainLiveTranslateCipherKeyStore`,
//    `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronised). The
//    key never sits beside the ciphertext: an inspection of the container
//    finds the payload and not the key.
//  - **A versioned envelope**: `magic | version | nonce | ciphertext | tag`.
//    A payload whose magic or version this code does not recognise is never
//    guessed at, never served, and is discarded — the format is detectable,
//    so a future change fails closed instead of mis-decoding.
//  - **The storage key is authenticated, not merely used as a file name.**
//    The key string is the AES-GCM additional authenticated data, so a
//    consent ciphertext copied into the cache's slot (or the reverse) fails
//    authentication rather than being served under the wrong name.
//  - **Key loss costs translations, never integrity and never a launch.**
//    A missing or unusable key is regenerated; nothing here throws, traps or
//    surfaces a crypto error. The payload the lost key protected simply
//    reads as absent (and is discarded), which every consumer already
//    handles as "empty cache" / "nothing recorded".
//  - **A payload that fails authentication is treated as absent and
//    removed**, never served and never crashed on. The bytes are
//    unrecoverable by construction, so leaving them would only make every
//    later read fail.
//
// Threading: one `NSLock` guards key resolution only. The consumers each
// guard their own state, and this type never calls back into them, so the
// decorator's lock can never be held across a consumer's lock.

/// AES-GCM at-rest protection for the two payloads the live-translation
/// feature persists (the translation cache and the consent record).
final class LiveTranslateCipherStorage: EncryptedLocalStorage, RawEncryptedStorage {

    // MARK: - Envelope

    /// What the cipher writes, byte for byte:
    ///
    ///     offset 0   magic     4 bytes  "LTCE" (Live Translate Cipher Envelope)
    ///     offset 4   version   1 byte
    ///     offset 5   nonce    12 bytes  AES-GCM nonce
    ///     offset 17  payload   n bytes   ciphertext
    ///     offset 17+n tag     16 bytes  AES-GCM authentication tag
    ///
    /// The nonce/ciphertext/tag triple is exactly `AES.GCM.SealedBox.combined`
    /// — the form CryptoKit produces and parses back — so the layout cannot
    /// drift from the crypto primitive it describes.
    enum Envelope {
        /// ASCII `LTCE`.
        static let magic: [UInt8] = [0x4C, 0x54, 0x43, 0x45]
        /// The only version this code writes or reads. Bumped by any layout
        /// change; an unknown value is treated as "not a payload I can read".
        static let currentVersion: UInt8 = 1
        static let headerByteCount = magic.count + 1
        static let nonceByteCount = 12
        static let tagByteCount = 16
        /// Header + nonce + tag: the shortest byte string that is even
        /// shaped like an envelope, checked before any parser sees it.
        static let minimumByteCount = headerByteCount + nonceByteCount + tagByteCount
    }

    /// The AES-256 key size. One value, read by both the reader and the
    /// "is the stored key usable" check, so they cannot disagree.
    static let keyByteCount = 32

    // MARK: - Dependencies

    private let wrapped: EncryptedLocalStorage
    private let keyStore: LiveTranslateCipherKeyStoring
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - State

    private let lock = NSLock()
    /// Resolved once per process — a Keychain round-trip per read would be
    /// paid on the translation hot path for no benefit.
    private var cachedKey: SymmetricKey?

    init(wrapping wrapped: EncryptedLocalStorage,
         keyStore: LiveTranslateCipherKeyStoring = KeychainLiveTranslateCipherKeyStore()) {
        self.wrapped = wrapped
        self.keyStore = keyStore
    }

    // MARK: - EncryptedLocalStorage

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        guard let plaintext = try? encoder.encode(value) else {
            return .failure(.encryptedWriteFailed)
        }
        guard let sealed = seal(plaintext, key: key) else {
            return .failure(.encryptedWriteFailed)
        }
        return writeStoredBytes(sealed, key: key)
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard let stored = readStoredBytes(key: key) else {
            // Nothing at this key. The convention every consumer in the app
            // relies on: a failed read reads as an empty cache.
            return .failure(.encryptedReadFailed)
        }
        guard let plaintext = open(stored, key: key) else {
            // Present, and not authenticatable: this is the "treated as
            // absent" rule, and the discard is what makes it stick — the
            // bytes can never be read by anyone, including us.
            discard(key: key)
            return .failure(.encryptedReadFailed)
        }
        guard let value = try? decoder.decode(T.self, from: plaintext) else {
            // Authentic, but not the shape the caller asked for (a payload
            // from a future schema, or a damaged one). Unusable: discard, do
            // not serve.
            discard(key: key)
            return .failure(.encryptedReadFailed)
        }
        return .success(value)
    }

    func delete(key: String) -> Result<Void, StorageError> {
        wrapped.delete(key: key)
    }

    // MARK: - RawEncryptedStorage

    /// The bytes this store holds for `key`: the sealed envelope, verbatim.
    ///
    /// Deliberately the ciphertext and not the plaintext. The raw channel's
    /// job is to answer "is something stored here?" (the consumers' healing
    /// paths ask exactly that), and an accessor that decrypted would be a
    /// second, unauthenticated way to reach scene text.
    func readRawData(key: String) -> Data? {
        readStoredBytes(key: key)
    }

    /// Stores `data` verbatim as this key's payload. The caller must supply a
    /// sealed envelope: this store never serves bytes it cannot authenticate,
    /// so unsealed bytes written here would be discarded on the first read.
    /// The type's own `write(_:key:)` is the only writer the app uses.
    func writeRawData(_ data: Data, key: String) -> Result<Void, StorageError> {
        writeStoredBytes(data, key: key)
    }

    // MARK: - The cipher

    /// Seals `plaintext` under `key`'s storage key. Returns nil only if the
    /// crypto primitive itself refuses, which is reported as a write failure
    /// — never a crash and never a plaintext fallback.
    private func seal(_ plaintext: Data, key: String) -> Data? {
        guard let box = try? AES.GCM.seal(plaintext,
                                         using: cryptoKey(),
                                         authenticating: associatedData(for: key)),
              let combined = box.combined else { return nil }
        var envelope = Data(Envelope.magic)
        envelope.append(Envelope.currentVersion)
        envelope.append(combined)
        return envelope
    }

    /// Opens a stored envelope, or nil when it is not one this code can
    /// authenticate: wrong magic, unknown version, truncated, different key,
    /// moved between storage keys, or edited. Every one of those is the same
    /// answer — "not a payload" — because none of them is recoverable.
    private func open(_ stored: Data, key: String) -> Data? {
        guard stored.count >= Envelope.minimumByteCount else { return nil }
        let header = [UInt8](stored.prefix(Envelope.headerByteCount))
        guard Array(header.prefix(Envelope.magic.count)) == Envelope.magic,
              header[Envelope.magic.count] == Envelope.currentVersion else { return nil }
        guard let box = try? AES.GCM.SealedBox(combined: stored.dropFirst(Envelope.headerByteCount)) else {
            return nil
        }
        return try? AES.GCM.open(box, using: cryptoKey(), authenticating: associatedData(for: key))
    }

    /// The storage key is authenticated data, not just a name: a payload that
    /// belongs to another key in the same store fails authentication here.
    private func associatedData(for key: String) -> Data {
        Data(key.utf8)
    }

    /// Removes a payload that can never be read again. Best-effort by design:
    /// a store that will not delete is still never served from.
    private func discard(key: String) {
        _ = wrapped.delete(key: key)
    }

    // MARK: - Bytes on the channel

    /// The wrapped store's verbatim channel when it has one (the shipped
    /// `EncryptedFileStorage` does), otherwise its `Data` channel, which
    /// round-trips the same bytes losslessly through its own envelope.
    private func readStoredBytes(key: String) -> Data? {
        if let raw = wrapped as? RawEncryptedStorage {
            return raw.readRawData(key: key)
        }
        guard case .success(let bytes) = wrapped.read(key: key, type: Data.self) else {
            return nil
        }
        return bytes
    }

    private func writeStoredBytes(_ sealed: Data, key: String) -> Result<Void, StorageError> {
        if let raw = wrapped as? RawEncryptedStorage {
            return raw.writeRawData(sealed, key: key)
        }
        return wrapped.write(key: key, value: sealed)
    }

    // MARK: - The key

    /// The process's key, resolved once. Never returns nil and never throws:
    /// the Keychain being unavailable downgrades the store to a session key,
    /// which is a translation cost, not a failure.
    private func cryptoKey() -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        let key = resolveKey()
        cachedKey = key
        return key
    }

    private func resolveKey() -> SymmetricKey {
        if let stored = keyStore.readKeyBytes() {
            if stored.count == Self.keyByteCount {
                return SymmetricKey(data: stored)
            }
            // Stored, but not a key this code can use (truncated, or written
            // by something that is not this type). Regenerating in memory
            // alone would produce a new unusable key on every launch, so the
            // unusable value is replaced. Whether the replacement lands or
            // not, this session has a working key.
            let replacement = SymmetricKey(size: .bits256)
            _ = keyStore.replaceKeyBytes(replacement.rawBytes)
            return replacement
        }

        let generated = SymmetricKey(size: .bits256)
        if let effective = keyStore.addKeyBytesIfAbsent(generated.rawBytes),
           effective.count == Self.keyByteCount {
            // The first key ever written is the one that protects whatever is
            // already on disk, so a lost race converges on it rather than
            // replacing it.
            return SymmetricKey(data: effective)
        }
        // The Keychain would not store the key: this session still encrypts
        // and decrypts with the in-memory key. A later launch resolves a
        // different key, the payload fails authentication, and it is
        // discarded as absent — losing translations, never integrity.
        return generated
    }
}

// MARK: - Key storage

/// Where the at-rest key lives. Production is the Keychain; tests inject an
/// in-memory double so no suite depends on the simulator's Keychain state.
///
/// Three methods rather than one `key` property because the decisions differ:
/// reading can fail, **adding must never clobber an existing key** (that
/// would orphan every payload it protects), and replacing is allowed only for
/// a stored value this type has already read and found unusable.
protocol LiveTranslateCipherKeyStoring {
    /// The stored key bytes, or nil when nothing is stored (and nil when the
    /// store cannot be read — both are "no usable key", which is the
    /// fail-closed reading).
    func readKeyBytes() -> Data?

    /// Stores `bytes` **only when no key is stored**, and returns the key
    /// that is stored afterwards — the existing one when this call lost a
    /// race — or nil when the store would not take it.
    func addKeyBytesIfAbsent(_ bytes: Data) -> Data?

    /// Replaces a stored value that cannot be a usable key. Only ever called
    /// with the outcome of `readKeyBytes()` in hand, so it can never clobber
    /// a key that is protecting live payloads.
    func replaceKeyBytes(_ bytes: Data) -> Bool
}

/// The production key store: one 256-bit AES-GCM key in the Keychain.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is the same class the
/// app's other Keychain secrets use, and it is the right one here: the
/// ciphertext it protects is a Data Protection Complete file, so a key that
/// outlived the lock state would protect nothing. `kSecAttrSynchronizable:
/// false` keeps the key off iCloud Keychain — the payloads are already
/// excluded from backup, and a key that travelled to another device would be
/// a key that travels.
///
/// (AES keys cannot live in the Secure Enclave — it holds P-256 keys only —
/// so the Keychain item is the strongest home available for a symmetric key
/// on iOS.)
final class KeychainLiveTranslateCipherKeyStore: LiveTranslateCipherKeyStoring {

    /// Namespaced away from the app's other Keychain items: this key belongs
    /// to one feature and nothing else should be able to collide with it.
    static let defaultService = "com.elderlyassistant.livetranslate.cipher"
    static let defaultAccount = "plugin.live_translate.at_rest_key.v1"

    private let service: String
    private let account: String

    init(service: String = KeychainLiveTranslateCipherKeyStore.defaultService,
         account: String = KeychainLiveTranslateCipherKeyStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    func readKeyBytes() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    func addKeyBytesIfAbsent(_ bytes: Data) -> Data? {
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = bytes
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        switch SecItemAdd(addQuery as CFDictionary, nil) {
        case errSecSuccess:
            return bytes
        case errSecDuplicateItem:
            // Another thread (or a previous launch) stored the key first.
            // Its key is the one the existing payloads were sealed with.
            return readKeyBytes()
        default:
            return nil
        }
    }

    func replaceKeyBytes(_ bytes: Data) -> Bool {
        let status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: bytes] as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return addKeyBytesIfAbsent(bytes) != nil }
        return false
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Bind to this device; do not sync via iCloud Keychain.
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }
}

// MARK: - Key bytes

private extension SymmetricKey {
    /// The key's own bytes. The only places they exist are the Keychain and
    /// this process's memory.
    var rawBytes: Data {
        withUnsafeBytes { Data($0) }
    }
}
