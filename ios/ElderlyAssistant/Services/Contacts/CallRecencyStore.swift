import Foundation

/// Recently-called phone numbers — the phone leaf's search-ranking index
/// ("most recently used first", system-contacts search task 2026-09-06).
///
/// Every place the app ACTUALLY places a call records the dialed number
/// here (voice flow, family-contact tiles, system-contact search rows —
/// see `AppCoordinator.contactNumberUsed`); a row whose number was
/// called from this app floats to the top of search results.
///
/// Keyed by `ContactNumberKey.normalized` (ASCII digits) so the same
/// number written differently ("+977-9841…" vs "(977) 9841…") is one
/// key. Two spellings that differ in COUNTRY CODE stay distinct — that
/// would need carrier/region knowledge (national vs international
/// equivalence) this store deliberately does not pretend to have.
///
/// Stored through `EncryptedLocalStorage` — the same channel and trust
/// as `RepetitionGuard`'s recent-action records. Called numbers are the
/// user's personal activity; a plaintext UserDefaults plist in
/// Library/Preferences would not carry the Data Protection posture the
/// constitution's Privacy section asks of personal data.
final class CallRecencyStore {

    /// One entry per number, newest write wins; cap mirrors
    /// `RepetitionGuard.maxRecords` so the keychain payload stays small
    /// and the list can't grow without bound.
    static let maxNumbers = 100
    private static let storageKey = "call.recency.byNormalizedNumber"

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    /// Records that a call to `phone` was placed now (or `date`).
    /// Numbers that normalize to nothing dialable are ignored — nothing
    /// that couldn't be called should rank as called.
    func record(phone: String, at date: Date = Date()) {
        let key = ContactNumberKey.normalized(phone)
        guard !key.isEmpty else { return }
        var all = load()
        all[key] = date
        if all.count > Self.maxNumbers {
            let newestFirst = all.sorted { $0.value > $1.value }
            // `prefix` keeps the dictionary element's labels, which the
            // initializer rejects under Swift 6 — re-map to unlabeled pairs.
            all = Dictionary(uniqueKeysWithValues:
                newestFirst.prefix(Self.maxNumbers).map { ($0.key, $0.value) })
        }
        save(all)
    }

    func lastCalled(phone: String) -> Date? {
        load()[ContactNumberKey.normalized(phone)]
    }

    /// The whole index (normalized number → last call date), for one
    /// load + in-memory ranking per search session.
    func recentCalls() -> [String: Date] {
        load()
    }

    private func load() -> [String: Date] {
        guard case .success(let map) = storage.read(
            key: Self.storageKey, type: [String: Date].self
        ) else { return [:] }
        return map
    }

    private func save(_ map: [String: Date]) {
        _ = storage.write(key: Self.storageKey, value: map)
    }
}
