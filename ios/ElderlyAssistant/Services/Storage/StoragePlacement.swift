import Foundation

// MARK: - Where a key is stored (startup review P1-6, 2026-09-10)
//
// The review's rule: the Keychain is for SMALL SECRETS AND KEYS ONLY;
// larger structured data (contacts, appointments, histories, reminder
// state, feed config, cached presentation data) moves to encrypted files
// under Application Support. This type is that rule, in one place, as a
// pure function — so the split is auditable and testable rather than
// scattered across twenty-five store constructors.
//
// The decision is made per KEY, which is what lets every existing store
// keep taking the single shared `EncryptedLocalStorage` the coordinator
// hands it: a store never chooses its own channel, and a later store
// automatically lands on the right side of the line.

/// Which channel a key lives in.
enum StoragePlacement: Equatable {
    /// The iOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
    case keychain
    /// A file under `Application Support/EncryptedStore/`, Data
    /// Protection class Complete, excluded from backups.
    case encryptedFile
}

/// The pure placement policy.
///
/// `keychainResidentKeys` is deliberately an explicit, short, REVIEWED
/// list, and everything else defaults to the encrypted file store: the
/// review's migration target is the large structured payloads, and the
/// listed exceptions are the small secrets that must keep the Keychain's
/// per-item protection (Secure-Enclave-derived class key, device-bound,
/// never written to disk). A new key added later therefore has to be
/// consciously placed in the Keychain to end up there —
/// `StoragePlacementTests` pins both directions, including the API keys
/// by name.
enum StoragePlacementPolicy {

    /// Small secrets and scalars that stay in the Keychain. Named
    /// constants would be nicer than string literals, but the keys are
    /// `private static let`s inside their owning stores (deliberately so)
    /// — the strings here are pinned by tests in both directions, so a
    /// typo cannot silently move a secret to disk.
    static let keychainResidentKeys: Set<String> = [
        // Family-entered provider credentials (Settings → Gemini AI /
        // Search / YouTube). Never in UserDefaults, never in a file.
        "gemini.apiKey",
        "search.apiKey",
        "search.engineId",
        "youtube.apiKey",
        // The chosen Gemini model name: a small scalar kept beside the key
        // it is used with, so one store is not split across two channels.
        "gemini.model",
    ]

    static func placement(for key: String) -> StoragePlacement {
        keychainResidentKeys.contains(key) ? .keychain : .encryptedFile
    }

    /// True when the key moves to the encrypted file store — the migration
    /// set. Readable as prose at the call sites.
    static func migratesToFile(_ key: String) -> Bool {
        placement(for: key) == .encryptedFile
    }
}
