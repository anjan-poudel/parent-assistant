import Foundation

/// Per-contact Messenger handles for ADDRESS-BOOK people, keyed by the
/// contact's normalized phone number (the same `ContactNumberKey`
/// normalization the search and recency stores share).
///
/// WHY this exists (2026-09-07): Messenger supports NO phone-number
/// thread deep link — `m.me/<username>` is Meta's only official form and
/// `fb-messenger://user-thread/…` is keyed to Facebook ids. A tap that
/// only has a phone number can never reliably open the person's thread,
/// so a one-time username-capture prompt asked for the person's handle
/// and stored it here, and the pill opened the real thread from then
/// on. The capture prompt is GONE (messenger-gate, 2026-09-07 — the
/// pill shows only for rows with a handle), but the handles recorded
/// before the revert still live here, and the Phone leaf resolves them
/// so a saved handle keeps its pill and its thread. Writes resumed with
/// the Phone-tab redesign (2026-09-07): the row's add-handle sheet
/// stores through `AppCoordinator.storeMessengerHandle`.
///
/// Stored encrypted (`EncryptedLocalStorage`, Keychain — constitution
/// §Security): usernames are personal linkage data, not a UI preference.
final class MessengerHandleStore {

    static let storageKey = "messenger.handles.byNormalizedPhone"

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    /// The stored handle for a normalized phone, nil when none exists.
    /// Missing or corrupt storage reads as nil — a broken payload never
    /// crashes the row, and the next write recovers (house pattern).
    func handle(forNormalizedPhone normalized: String) -> String? {
        guard !normalized.isEmpty else { return nil }
        return load()[normalized]
    }

    /// Stores (or overwrites) the handle for a normalized phone.
    /// Blank handles are stored as-is — the caller decides what counts
    /// as usable via `CallLinks.messengerHandle`.
    @discardableResult
    func set(handle: String, forNormalizedPhone normalized: String) -> Bool {
        guard !normalized.isEmpty else { return false }
        var map = load()
        map[normalized] = handle
        switch storage.write(key: Self.storageKey, value: map) {
        case .success: return true
        case .failure: return false
        }
    }

    private func load() -> [String: String] {
        guard case .success(let map) = storage.read(key: Self.storageKey,
                                                    type: [String: String].self) else { return [:] }
        return map
    }
}
