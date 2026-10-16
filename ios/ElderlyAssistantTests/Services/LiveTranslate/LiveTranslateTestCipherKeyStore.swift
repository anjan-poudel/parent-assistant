import Foundation
@testable import ElderlyAssistant

/// The key store the cipher tests drive — an in-memory
/// `LiveTranslateCipherKeyStoring`.
///
/// It exists so no suite's outcome depends on the simulator's Keychain
/// state (which survives between runs and between suites), and so the three
/// fail-able decisions the cipher makes about a key are reachable: the store
/// cannot be read, it will not accept a write, and it hands back something
/// that is not a usable key. A double that could only round-trip bytes would
/// leave the key-loss path — the one that must never crash — untested.
///
/// The real Keychain implementation gets its own integration test
/// (`LiveTranslateCipherStorageTests.testTheKeychainKeyStoreStoresOneDeviceBoundKey`)
/// against a throwaway service, so this double is never the only evidence
/// that the production key store works.
final class LiveTranslateTestCipherKeyStore: LiveTranslateCipherKeyStoring {

    /// What the store holds. `nil` is "nothing stored" — a fresh install, or
    /// a key that was lost.
    private(set) var bytes: Data?
    private(set) var addCount = 0
    private(set) var replaceCount = 0
    private(set) var readCount = 0

    /// When true every write is refused, as a Keychain that is unavailable
    /// (locked, or an entitlement the process does not have) would be.
    var failsWrites = false

    init(bytes: Data? = nil) {
        self.bytes = bytes
    }

    /// The key is gone: a device restore, a deleted item, or a different key
    /// written by something else. The next resolution must regenerate.
    func loseKey() { bytes = nil }

    func readKeyBytes() -> Data? {
        readCount += 1
        return bytes
    }

    func addKeyBytesIfAbsent(_ newBytes: Data) -> Data? {
        addCount += 1
        guard !failsWrites else { return nil }
        // First key wins: an existing key is never clobbered, which is the
        // property that keeps existing payloads readable.
        if let bytes { return bytes }
        bytes = newBytes
        return newBytes
    }

    func replaceKeyBytes(_ newBytes: Data) -> Bool {
        replaceCount += 1
        guard !failsWrites else { return false }
        bytes = newBytes
        return true
    }
}
