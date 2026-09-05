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
/// handle, not by phone number. Optional — Codable's synthesized decoding
/// reads a missing key as nil, so payloads written before the field
/// existed load unchanged (the store is unversioned; an optional field IS
/// its migration pattern).
struct FamilyContact: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var phone: String
    var relationship: String
    var messengerHandle: String?

    init(id: UUID = UUID(), name: String, phone: String, relationship: String,
         messengerHandle: String? = nil) {
        self.id = id
        self.name = name
        self.phone = phone
        self.relationship = relationship
        self.messengerHandle = messengerHandle
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
