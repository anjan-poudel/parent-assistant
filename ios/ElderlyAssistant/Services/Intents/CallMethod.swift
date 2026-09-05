import Foundation

/// Real, one-tap-completable outbound methods (2026-09-05 "intent is
/// king" routing, extended by the intent-engine spec §6.2).
///
/// FaceTime deep links genuinely place the call; WhatsApp has no public
/// call-initiation API on iOS at all — `.whatsappChat` only opens the
/// conversation, the user still taps the call icon themselves inside
/// WhatsApp. Messenger and Viber have no integration point whatsoever
/// (confirmed in docs/messaging-calling-platform-research.md, out of
/// scope) — requesting either falls back to FaceTime, disclosed out loud,
/// never silently.
///
/// `.phone` (plain `tel:`) is NEW in v2: the universal default at the end
/// of the MethodResolver chain — it works for every contact regardless of
/// which apps are installed, which FaceTime cannot promise (the contact
/// needs an Apple device). The pre-v2 behavior of defaulting a bare "फोन
/// गर" to FaceTime audio assumed Apple-on-both-ends; `tel:` assumes
/// nothing.
///
/// Moved out of `AppCoordinator` (2026-09-05) so `MethodResolver`, the
/// method-preference/history stores, and `CallOverrideParser` can all
/// share the type; `Codable` for the stores.
enum CallMethod: String, Codable, Equatable {
    case phone
    case facetimeVideo
    case facetimeAudio
    case whatsappChat
}

/// Per-contact, family-set preferred calling method (spec §6.2 chain
/// step 2). Written from Settings by family — "Maiya prefers FaceTime
/// audio" — so the assistant's DEFAULT for that contact matches the
/// household's reality without the elder ever naming an app.
final class CallMethodPreferenceStore {

    private static let storageKey = "call.methodPreferences"

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    func preference(for contactId: UUID) -> CallMethod? {
        loadAll()[contactId.uuidString]
    }

    @discardableResult
    func setPreference(_ method: CallMethod?, for contactId: UUID) -> Bool {
        var all = loadAll()
        all[contactId.uuidString] = method
        return writeAll(all)
    }

    @discardableResult
    func removeAll(for contactId: UUID) -> Bool {
        setPreference(nil, for: contactId)
    }

    private func loadAll() -> [String: CallMethod] {
        guard case .success(let map) = storage.read(
            key: Self.storageKey, type: [String: CallMethod].self
        ) else { return [:] }
        return map
    }

    private func writeAll(_ map: [String: CallMethod]) -> Bool {
        switch storage.write(key: Self.storageKey, value: map) {
        case .success: return true
        case .failure: return false
        }
    }
}

/// Per-contact record of the method the user actually CONFIRMED last time
/// (spec §6.2 chain step 3). Written by the call executor on each
/// confirmed call — confirmation already happens on every call, so
/// learning the household's real habits is one line, deterministic, and
/// dementia-friendly (the app behaves CONSISTENTLY — same person, same
/// method — which matters more than behaving cleverly).
struct ConfirmedMethodRecord: Codable, Equatable {
    let method: CallMethod
    let confirmedAt: Date
    let count: Int
}

final class ConfirmedMethodHistoryStore {

    private static let storageKey = "call.confirmedMethodHistory"

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    func lastConfirmed(for contactId: UUID) -> ConfirmedMethodRecord? {
        loadAll()[contactId.uuidString]
    }

    @discardableResult
    func record(_ method: CallMethod, for contactId: UUID, at date: Date = Date()) -> Bool {
        var all = loadAll()
        let prior = all[contactId.uuidString]
        all[contactId.uuidString] = ConfirmedMethodRecord(
            method: method,
            confirmedAt: date,
            count: (prior?.count ?? 0) + 1
        )
        return writeAll(all)
    }

    @discardableResult
    func removeAll(for contactId: UUID) -> Bool {
        var all = loadAll()
        all.removeValue(forKey: contactId.uuidString)
        return writeAll(all)
    }

    private func loadAll() -> [String: ConfirmedMethodRecord] {
        guard case .success(let map) = storage.read(
            key: Self.storageKey, type: [String: ConfirmedMethodRecord].self
        ) else { return [:] }
        return map
    }

    private func writeAll(_ map: [String: ConfirmedMethodRecord]) -> Bool {
        switch storage.write(key: Self.storageKey, value: map) {
        case .success: return true
        case .failure: return false
        }
    }
}
