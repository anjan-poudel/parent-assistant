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
/// `nicknames` (family-contacts-unify T-145, 2026-10-12 — REPLACES the
/// single `nickname` from the family-wizard task, 2026-09-07): the
/// informal names/variations the family calls the person. Stored
/// explicitly and verbatim — "sanu" and "सानु" are distinct entries, no
/// transliteration (feature constitution, Open Decision 2). An empty
/// array is the "no nicknames" value; the custom decoder reads a
/// missing key as `[]` and migrates the legacy single `nickname` key
/// losslessly (design-l2 §3.4).
///
/// `address` (directions task, 2026-09-07): the contact's home address,
/// so voice navigation can drive to a relative ("मैयाको घर लैजाऊ").
/// Free-form text — whatever the user typed in the family editor; the
/// navigation pipeline forward-geocodes it at request time. Optional,
/// same unversioned-store migration rule: a payload written before the
/// field existed loads address-less instead of failing the read.
///
/// `isEmergencyContact` (family-emergency task, 2026-09-07): marks the
/// person the Emergency affordance dials FIRST (see
/// `AppCoordinator.preferredEmergencyContact`). Unlike the optional
/// fields above it is a NON-optional Bool defaulted false — "not
/// flagged" is a real value that must survive — so its migration is a
/// decoder default, not nil: the custom decoder reads a missing key as
/// false, and a pre-flag payload simply falls back to the old behavior
/// (first contact wins).
///
/// `email` (calendar & family sharing task, 2026-09-16): the address a
/// Google Calendar invitation is sent to. Optional at the MODEL level
/// with the usual missing-key-reads-nil migration, even though the
/// EDITOR makes it mandatory for emergency contacts — contacts saved
/// before the field existed (including the synthetic fallback contact
/// `AppCoordinator` builds when the list is empty) must keep loading.
/// Invite logic simply skips a contact with no address (see
/// `CalendarShareMapper`).
struct FamilyContact: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var phone: String
    var relationship: String
    var messengerHandle: String?
    /// ContactPhotoStore filename of the contact's thumbnail, nil when
    /// no photo is on file.
    var photoFilename: String?
    /// The informal names the family uses, in the order entered; empty
    /// when none is set. Entries are stored as entered (trimmed, never
    /// transliterated) — see `FamilyContact.normalizedNicknames`.
    var nicknames: [String]
    /// Free-form home address for voice navigation, nil when the user
    /// never set one (the contact then cannot be a navigation target).
    var address: String?

    /// Google account address this contact's calendar invitations are
    /// sent to (calendar & family sharing task, 2026-09-16). Mandatory
    /// in the EDITOR while `isEmergencyContact` is on; nil in the model
    /// for every contact saved before the field existed — those simply
    /// receive no invite until an address is added.
    var email: String?

    /// Whether the Emergency affordance dials this contact before any
    /// other (family-emergency task, 2026-09-07). False when unset —
    /// see `AppCoordinator.preferredEmergencyContact` for the rule.
    var isEmergencyContact: Bool

    /// App the video button opens for this contact. Default `.faceTime`
    /// (the global default) — the only app that truly starts a video
    /// call from a deep link.
    var preferredVideoApp: CallApp
    /// App the audio call button opens for this contact. Default
    /// `.phone` (GSM `tel:`) — works for every contact, no app
    /// assumptions.
    var preferredCallApp: CallApp

    /// The system address-book record this family contact IS (the same
    /// person on both surfaces), with the fingerprint needed to prove
    /// it is still the same person. Local-only — never transmitted.
    /// Optional with the usual migration rule: a payload written before
    /// the link existed loads unlinked, and a corrupt/empty payload
    /// degrades to nil rather than losing the contact (FR-FCU-002
    /// scenario 3, design-l2 §3.4).
    var systemContact: SystemContactLink?

    init(id: UUID = UUID(), name: String, phone: String, relationship: String,
         messengerHandle: String? = nil,
         preferredVideoApp: CallApp = .faceTime, preferredCallApp: CallApp = .phone,
         photoFilename: String? = nil, nicknames: [String] = [],
         address: String? = nil, email: String? = nil,
         isEmergencyContact: Bool = false, systemContact: SystemContactLink? = nil) {
        self.id = id
        self.name = name
        self.phone = phone
        self.relationship = relationship
        self.messengerHandle = messengerHandle
        self.preferredVideoApp = preferredVideoApp
        self.preferredCallApp = preferredCallApp
        self.photoFilename = photoFilename
        self.nicknames = nicknames
        self.address = address
        self.email = email
        self.isEmergencyContact = isEmergencyContact
        self.systemContact = systemContact
    }

    /// Custom decode: contacts persisted BEFORE the preference fields
    /// existed (and any hand-edited/corrupt value) must load with the
    /// global defaults, not fail the whole store read. The store has no
    /// schema-versioning pattern — plain Codable — so defaulting lives
    /// here on the model.
    ///
    /// Encoder contract (design-l2 §3.3): the synthesized `Encodable` is
    /// kept deliberately — a hand-written encoder risks silent field
    /// loss. Nil optionals are omitted; `nicknames`/`systemContact`
    /// encode as stored. No legacy `nickname` key is ever written (a
    /// downgraded build simply reads no nickname — accepted).
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
        // Nicknames — L1 §5.2 order, lossless (design-l2 §3.4):
        //   1. the multi-nickname key present WINS — even an empty
        //      array ("the user removed every nickname" is real data);
        //   2. else the legacy single `nickname` key (read through its
        //      OWN container, never `CodingKeys` — the synthesized
        //      encoder must not be able to emit a legacy key);
        //   3. else no nicknames. A pre-field payload loads here.
        if let list = (try? container.decodeIfPresent([String].self, forKey: .nicknames)) ?? nil {
            nicknames = FamilyContact.normalizedNicknames(list)
        } else if let legacy = try? decoder.container(keyedBy: LegacyNicknameKeys.self),
                  let single = (try? legacy.decodeIfPresent(String.self, forKey: .nickname)) ?? nil,
                  !single.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nicknames = FamilyContact.normalizedNicknames([single])
        } else {
            nicknames = []
        }
        // The link (design-l2 §3.4): a corrupt, truncated or empty
        // payload decodes to NO link — the contact is retained intact,
        // never dropped for a bad fingerprint (FR-FCU-002 scenario 3).
        let decodedLink = (try? container.decodeIfPresent(SystemContactLink.self, forKey: .systemContact)) ?? nil
        if let link = decodedLink, !link.identifier.isEmpty, !link.numberKey.isEmpty {
            systemContact = link
        } else {
            systemContact = nil
        }
        // Same rule for the address (directions task, 2026-09-07): a
        // payload written before the field existed loads address-less.
        address = (try? container.decodeIfPresent(String.self, forKey: .address)) ?? nil
        // And for the email (calendar & family sharing task, 2026-09-16):
        // a payload written before the field existed loads email-less
        // rather than failing the whole read.
        email = (try? container.decodeIfPresent(String.self, forKey: .email)) ?? nil
        // The emergency flag (family-emergency task, 2026-09-07) is the
        // one non-optional field: a missing key is not "nil value" but
        // "not flagged" — false, the same answer a pre-flag payload
        // would have given by construction.
        isEmergencyContact = (try? container.decodeIfPresent(Bool.self, forKey: .isEmergencyContact)) ?? false
    }

    /// The faithful nickname projection: each entry trimmed, whitespace-
    /// only entries dropped, order and duplicates preserved (design-l2
    /// §3.2). Deliberately NOT lossy beyond that — migration of the
    /// legacy single `nickname` must never rewrite the value, so no
    /// transliteration, no case folding, no length cap lives here.
    ///
    /// F5 decision (recorded, T-145): the 64-char bound is enforced at
    /// the EDITOR/submission seam (`cappedNickname`, used by the wizard
    /// save path) while this projection stays faithful; the worst-case
    /// long-string performance assertion lives in T-151, not here.
    ///
    /// Applied at the decoder (defensive for hand-edited/corrupt
    /// payloads), at the editor/submission seam (`cappedNickname`) AND —
    /// since T-156 landed the widened `nicknames: [String]` signature —
    /// at the coordinator's add/update save path, the one point every
    /// caller passes through, so no raw or whitespace-only entry can
    /// reach the store whatever the caller hands over.
    static func normalizedNicknames(_ raw: [String]) -> [String] {
        raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
           .filter { !$0.isEmpty }
    }

    /// The editor/submission seam's length bound (security advisory F5):
    /// a typed nickname is trimmed, blank becomes nil, and an over-long
    /// value is capped at 64 CHARACTERS — a whole-grapheme prefix, so a
    /// Devanagari cluster is never split. The stored entries stay exactly
    /// what the family member entered within that bound.
    static let maxNicknameLength = 64

    static func cappedNickname(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNicknameLength))
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

/// The legacy-only key of the pre-migration payload shape (design-l2
/// §3.4): read through its own container so `FamilyContact.CodingKeys`
/// (and therefore the synthesized `Encodable`) contains ONLY stored
/// properties and can never re-emit the old key.
private enum LegacyNicknameKeys: String, CodingKey {
    case nickname
}

/// A pointer to one record in the system address book, with the
/// fingerprint needed to prove it is still the same person. Local-only;
/// never transmitted. Defined next to `FamilyContact` because it is part
/// of the persisted payload shape the decoder above reads.
struct SystemContactLink: Codable, Equatable {
    /// `CNContact.identifier` at link time.
    var identifier: String
    /// `ContactNumberKey.normalized` of the FIRST dialable number of the
    /// picked entry at link time — the fingerprint that lets a stale
    /// identifier (re-sync, iCloud merge) be told apart from a live one.
    var numberKey: String
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
