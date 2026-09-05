import Foundation

/// A family/emergency contact configured on-device (spec §4.4.2).
///
/// Stored encrypted via `EncryptedLocalStorage` (Keychain, Data Protection
/// Complete — constitution §Security). The phone number is the payload the
/// future broker relay will notify; `deviceToken` in the APNs notifier stays
/// unprovisioned until that channel exists (review C6).
///
/// `preferredVideoApp`/`preferredCallApp` (contact-call-buttons task,
/// 2026-09-06) are the per-contact default apps the Call leaf's video/
/// audio buttons open. The model carries them NOW so personalization
/// ships later as UI only — the edit-defaults screen (deferred by the
/// user) plugs in by writing these two fields through
/// `FamilyContactStore.save`; nothing else needs to change.
struct FamilyContact: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var phone: String
    var relationship: String
    /// App the video button opens for this contact. Default `.faceTime`
    /// (the global default) — the only app that truly starts a video
    /// call from a deep link.
    var preferredVideoApp: CallApp
    /// App the audio call button opens for this contact. Default
    /// `.phone` (GSM `tel:`) — works for every contact, no app
    /// assumptions.
    var preferredCallApp: CallApp

    init(id: UUID = UUID(), name: String, phone: String, relationship: String,
         preferredVideoApp: CallApp = .faceTime, preferredCallApp: CallApp = .phone) {
        self.id = id
        self.name = name
        self.phone = phone
        self.relationship = relationship
        self.preferredVideoApp = preferredVideoApp
        self.preferredCallApp = preferredCallApp
    }

    /// Custom decode: contacts persisted BEFORE the preference fields
    /// existed (and any hand-edited/corrupt value) must load with the
    /// global defaults, not fail the whole store read. The store has no
    /// schema-versioning pattern — plain Codable — so defaulting lives
    /// here on the model.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        phone = try container.decode(String.self, forKey: .phone)
        relationship = try container.decode(String.self, forKey: .relationship)
        // `decode` throws on a missing key AND on an unknown raw value —
        // `try?` turns both into the default.
        preferredVideoApp = (try? container.decode(CallApp.self, forKey: .preferredVideoApp)) ?? .faceTime
        preferredCallApp = (try? container.decode(CallApp.self, forKey: .preferredCallApp)) ?? .phone
    }

    /// The app a VIDEO button resolves to (task: contact preference →
    /// global default). A stored preference that can't do video (`.phone`)
    /// can't have come from the future picker — treat it as unset and
    /// fall back to the global default rather than open the wrong surface.
    var resolvedVideoApp: CallApp {
        preferredVideoApp.supportsVideo ? preferredVideoApp : .faceTime
    }

    /// The app an AUDIO button resolves to. `.faceTime` is video-only in
    /// the button vocabulary, so it falls back to the GSM default.
    var resolvedAudioApp: CallApp {
        preferredCallApp.supportsAudio ? preferredCallApp : .phone
    }
}

/// Persists the 1–3 family contacts. The Settings section and the
/// onboarding step 3 both write through this store; `AppCoordinator` feeds
/// the resulting list into the family notifier.
final class FamilyContactStore {

    static let maxContacts = 3
    private static let storageKey = "family.contacts"

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    func load() -> [FamilyContact] {
        guard case .success(let contacts) = storage.read(
            key: Self.storageKey, type: [FamilyContact].self
        ) else { return [] }
        return contacts
    }

    @discardableResult
    func save(_ contacts: [FamilyContact]) -> Bool {
        switch storage.write(key: Self.storageKey, value: contacts) {
        case .success: return true
        case .failure: return false
        }
    }

    @discardableResult
    func add(_ contact: FamilyContact) -> Bool {
        var contacts = load()
        guard contacts.count < Self.maxContacts else { return false }
        contacts.append(contact)
        return save(contacts)
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        var contacts = load()
        contacts.removeAll { $0.id == id }
        return save(contacts)
    }
}
