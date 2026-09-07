import Foundation

/// A family/emergency contact configured on-device (spec §4.4.2).
///
/// Stored encrypted via `EncryptedLocalStorage` (Keychain, Data Protection
/// Complete — constitution §Security). The phone number is the payload the
/// future broker relay will notify; `deviceToken` in the APNs notifier stays
/// unprovisioned until that channel exists (review C6).
///
/// `messengerHandle` (2026-09-06): the contact's Messenger username or
/// numeric user-id, needed because Messenger deep links address people by
/// handle, not by phone number. Optional — the custom decoder reads a
/// missing key as nil (the store is unversioned; an optional field IS its
/// migration pattern).
///
/// `preferredVideoApp`/`preferredCallApp` (contact-call-buttons task,
/// 2026-09-06) are the per-contact default apps the Call leaf's video/
/// audio buttons open. The model carries them NOW so personalization
/// ships later as UI only — the edit-defaults screen (deferred by the
/// user) plugs in by writing these two fields through
/// `FamilyContactStore.save`; nothing else needs to change.
///
/// `photoFilename` (family-and-friends task, 2026-09-07): the name of
/// the contact's stored thumbnail under Application Support/
/// ContactPhotos (see `ContactPhotoStore`) — just a file NAME, never a
/// path. The model stores only the reference; the pixels are best-effort
/// visuals that may legitimately be missing (nothing picked yet, file
/// deleted or corrupt), so it is optional and the custom decoder reads a
/// missing key as nil — the unversioned store's one migration pattern
/// (an optional field IS its migration).
///
/// `nickname` (family-wizard task, 2026-09-07): the informal name the
/// family calls the person — the wizard's optional final step. Same
/// optional-field contract as the handle and the photo: the custom
/// decoder reads a missing key as nil.
struct FamilyContact: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var phone: String
    var relationship: String
    var messengerHandle: String?
    /// ContactPhotoStore filename of the contact's thumbnail, nil when
    /// no photo is on file.
    var photoFilename: String?
    /// The informal name the family uses, nil when none is set.
    var nickname: String?

    /// App the video button opens for this contact. Default `.faceTime`
    /// (the global default) — the only app that truly starts a video
    /// call from a deep link.
    var preferredVideoApp: CallApp
    /// App the audio call button opens for this contact. Default
    /// `.phone` (GSM `tel:`) — works for every contact, no app
    /// assumptions.
    var preferredCallApp: CallApp

    init(id: UUID = UUID(), name: String, phone: String, relationship: String,
         messengerHandle: String? = nil,
         preferredVideoApp: CallApp = .faceTime, preferredCallApp: CallApp = .phone,
         photoFilename: String? = nil, nickname: String? = nil) {
        self.id = id
        self.name = name
        self.phone = phone
        self.relationship = relationship
        self.messengerHandle = messengerHandle
        self.preferredVideoApp = preferredVideoApp
        self.preferredCallApp = preferredCallApp
        self.photoFilename = photoFilename
        self.nickname = nickname
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
        messengerHandle = (try? container.decodeIfPresent(String.self, forKey: .messengerHandle)) ?? nil
        // `decode` throws on a missing key AND on an unknown raw value —
        // `try?` turns both into the default.
        preferredVideoApp = (try? container.decode(CallApp.self, forKey: .preferredVideoApp)) ?? .faceTime
        preferredCallApp = (try? container.decode(CallApp.self, forKey: .preferredCallApp)) ?? .phone
        // Same missing-key rule for the photo: a payload written before
        // the field existed loads photo-less instead of failing the read.
        photoFilename = (try? container.decodeIfPresent(String.self, forKey: .photoFilename)) ?? nil
        // And for the nickname: a pre-field payload loads without one.
        nickname = (try? container.decodeIfPresent(String.self, forKey: .nickname)) ?? nil
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

/// Persists the curated "Family and friends" list (family-and-friends
/// task, 2026-09-07 — raised the cap from 3 to 12; the feature is now
/// the primary curated contact list, not just the emergency trio). The
/// Settings section and the onboarding family step (which still collects
/// a contact or two of its own) both write through this store;
/// `AppCoordinator` feeds the resulting list into the family notifier.
final class FamilyContactStore {

    /// How many curated contacts the store accepts. The onboarding flow
    /// keeps collecting its own 1–3 regardless of this cap; the cap only
    /// bounds what the Settings editor adds.
    static let maxContacts = 12
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
