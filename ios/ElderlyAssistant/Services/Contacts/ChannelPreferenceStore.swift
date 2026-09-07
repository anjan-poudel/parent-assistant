import Foundation

/// Per-contact calling-channel preference for ADDRESS-BOOK people,
/// keyed by normalized phone (2026-09-07 Phone-tab redesign): the row's
/// channel chooser persists the user's pick here; a missing entry falls
/// back to the global default (AppCoordinator.defaultCallApp).
///
/// The payload is plain [String: String] — normalized phone → CallApp
/// rawValue — deliberately NOT a Codable wrapper type: a wrapper would
/// add a schema-versioning story for zero benefit, while a dictionary
/// reads as "drop the unknown entries" for free. Unknown raw values (an
/// app removed from `CallApp`, or a hand-edited payload) read as nil —
/// the row falls back to the global default rather than crash or wedge.
///
/// Stored through `EncryptedLocalStorage`, the same channel and trust as
/// `MessengerHandleStore` / `CallRecencyStore`: a calling-channel pick is
/// personal linkage data (who the user actually calls, and how), not a
/// UI preference.
final class ChannelPreferenceStore {

    static let storageKey = "contact.channel.preferences"

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    /// The stored channel for a normalized phone, nil when none exists.
    /// A missing entry, a corrupt payload, or a stored raw value naming
    /// no `CallApp` case all read as nil — the caller falls back to the
    /// global default (never a crash, never a stale channel).
    func preference(forNormalizedPhone normalized: String) -> CallApp? {
        guard !normalized.isEmpty else { return nil }
        guard let raw = load()[normalized],
              let app = CallApp(rawValue: raw) else { return nil }
        return app
    }

    /// Stores (or overwrites) the channel for a normalized phone.
    /// Returns whether the encrypted write landed.
    @discardableResult
    func set(_ app: CallApp, forNormalizedPhone normalized: String) -> Bool {
        guard !normalized.isEmpty else { return false }
        var map = load()
        map[normalized] = app.rawValue
        switch storage.write(key: Self.storageKey, value: map) {
        case .success: return true
        case .failure: return false
        }
    }

    /// Removes the stored channel for a normalized phone — the row
    /// reverts to the global default. Removing a phone that has no entry
    /// is a successful no-op (true), mirroring the keychain storage's
    /// delete semantics.
    @discardableResult
    func remove(forNormalizedPhone normalized: String) -> Bool {
        guard !normalized.isEmpty else { return false }
        var map = load()
        guard map.removeValue(forKey: normalized) != nil else { return true }
        switch storage.write(key: Self.storageKey, value: map) {
        case .success: return true
        case .failure: return false
        }
    }

    /// Whole map read. Missing or corrupt storage reads as empty — a
    /// broken payload never crashes a read, and the next write recovers
    /// (house pattern, same as `MessengerHandleStore`).
    private func load() -> [String: String] {
        guard case .success(let map) = storage.read(key: Self.storageKey,
                                                    type: [String: String].self) else { return [:] }
        return map
    }
}
