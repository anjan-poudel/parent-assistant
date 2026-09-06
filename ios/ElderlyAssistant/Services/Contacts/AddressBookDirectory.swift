import Contacts
import Foundation

// MARK: - System-contacts search (Phone leaf, 2026-09-06)
//
// The phone screen's "sweep every sweepable contact" search. On iOS the
// SYSTEM address book is the sweep: the Contacts app already aggregates
// the user's own entries AND people synced in by third-party apps
// (WhatsApp, Messenger, etc.) as unlinked CNContact records — there is
// no per-app SDK to query, and no need for one. The Contacts framework
// reads all of them through one `CNContactStore`.
//
// Layering: this file keeps the platform glue (`AddressBookDirectory`,
// `ContactsAccess`) separate from pure logic (`AddressBookEntry`,
// `ContactNumberKey`, `SystemContactSearch`) so matching, ranking and
// mapping are unit-testable without CNContact (which is not
// constructible in tests). The glue is deliberately thin.

/// Digits-only key for a phone number, shared by search matching,
/// duplicate collapsing and the `CallRecencyStore` key.
///
/// ASCII digits only, on purpose: `tel:` URLs only ever dial ASCII
/// digits, so two spellings that differ only in formatting ("+977-9841…"
/// vs "(977) 9841…") compare equal — but Devanagari numerals (०-९) do
/// NOT, because dialing a Devanagari-numeral URL fails. A number typed
/// with such digits never became a dialable number, so it must not match
/// one that did.
enum ContactNumberKey {
    static func normalized(_ raw: String) -> String {
        raw.filter { $0.isASCII && $0.isNumber }
    }
}

/// One dialable row from the system address book, after the CNContact →
/// plain-data mapping. One entry per PERSON (first dialable number wins —
/// see `make`); unlinked duplicates of the same number collapse during
/// fetch (see `AddressBookDirectory.allEntries`).
///
/// `Identifiable` by `normalized`: rows are deduped on the same key, so
/// the id is stable and unique within a result list.
struct AddressBookEntry: Equatable, Identifiable {
    /// Display name: "given family", or the organization for company
    /// contacts, or the raw number when the record has no name at all
    /// (Contacts.app shows the number in that case too).
    let name: String
    /// The number's label ("mobile", "home", …) — Apple-localized by the
    /// system, not the app language (CNLabeledValue has no locale
    /// parameter; the label is a caption, the dialable text is the
    /// number itself).
    let label: String
    /// The raw number exactly as the system stores it — what we dial.
    let phone: String
    /// `ContactNumberKey.normalized(phone)` — matching + dedupe key.
    let normalized: String

    var id: String { normalized }

    /// One-line caption under the name, e.g. "mobile · +977 9841…".
    var caption: String {
        [label, phone].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Pure seam for the CNContact → entry mapping: composes the display
    /// name from the contact's parts and takes the FIRST number that
    /// normalizes to dialable digits (CNContact stores numbers in user
    /// order; mobile-first is the common shape). Returns nil for a
    /// contact with no dialable number — such a person can't be called,
    /// so they never appear as a search row.
    ///
    /// A contact whose every number is unusable is skipped entirely
    /// rather than shown with a dead button: the phone leaf's honesty
    /// rule is "never a silent dead tap" (same bar as
    /// `AppCoordinator.announceNoUsableNumber`), and a row we KNOW can't
    /// dial should not exist to be tapped.
    static func make(givenName: String,
                     familyName: String,
                     organizationName: String,
                     numbers: [(label: String, phone: String)]) -> AddressBookEntry? {
        guard let number = numbers.first(where: {
            !ContactNumberKey.normalized($0.phone).isEmpty
        }) else { return nil }

        var name = [givenName, familyName]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: " ")
        if name.isEmpty { name = organizationName }
        if name.isEmpty { name = number.phone }

        return AddressBookEntry(name: name,
                                label: number.label,
                                phone: number.phone,
                                normalized: ContactNumberKey.normalized(number.phone))
    }
}

/// App-facing authorization state. `.restricted` (parental controls etc.)
/// is surfaced as `.denied`: for both, the only forward path is the
/// system Settings screen, so the UI copy is the same.
enum ContactsAccess: Equatable {
    case notDetermined
    case allowed
    case denied
}

/// Search + ranking over address-book rows.
///
/// Ordering contract ("most recently used first"): entries whose number
/// was called from this app (see `CallRecencyStore`) sort by that date,
/// newest first; everything else — and ties — fall back to a
/// locale-aware alphabetical order. This is suggestion, not filtering:
/// every match stays reachable, a recent call just floats to the top.
enum SystemContactSearch {

    /// What one search shows: the ranked rows to render, and whether
    /// more matches were cut off by `limit` (the caller shows the
    /// "keep typing" hint instead of silently hiding people — an
    /// elderly user who searches "a" must never wonder where the rest
    /// went).
    struct Outcome: Equatable {
        let entries: [AddressBookEntry]
        let moreAvailable: Bool
    }

    static let defaultLimit = 15

    static func search(query: String,
                       in entries: [AddressBookEntry],
                       recency: [String: Date] = [:],
                       limit: Int = defaultLimit) -> Outcome {
        let matched = matches(query: query, in: entries)
        let ranked = rank(matched, by: recency)
        return Outcome(entries: Array(ranked.prefix(limit)),
                       moreAvailable: matched.count > limit)
    }

    /// Case- and diacritic-insensitive substring match on the display
    /// name ("sita" hits "Sita Sharma"; "सीता" hits "सीता शर्मा" —
    /// Devanagari has no case to fold). A query containing digits also
    /// matches numbers CONTAINING that digit run — but only the row's
    /// own dialable number, never a number the row can't dial, so a
    /// digit search can never surface a person and then call a
    /// different line of theirs (the row dials exactly the matched
    /// number).
    static func matches(query: String, in entries: [AddressBookEntry]) -> [AddressBookEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let digits = ContactNumberKey.normalized(needle)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return entries.filter { entry in
            if entry.name.range(of: needle, options: options) != nil { return true }
            return !digits.isEmpty && entry.normalized.contains(digits)
        }
    }

    static func rank(_ entries: [AddressBookEntry],
                     by recency: [String: Date]) -> [AddressBookEntry] {
        entries.sorted { lhs, rhs in
            let lhsDate = recency[lhs.normalized]
            let rhsDate = recency[rhs.normalized]
            switch (lhsDate, rhsDate) {
            case let (a?, b?) where a != b:
                return a > b
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }
}

/// Thin `CNContactStore` wrapper. All three surfaces are platform glue
/// (CNContactStore is not constructible or fakeable in unit tests), so
/// they stay one-liners over the tested pure seams above.
final class AddressBookDirectory {

    private static let fetchKeys: [CNKeyDescriptor] = [
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactOrganizationNameKey,
        CNContactPhoneNumbersKey,
    ] as [CNKeyDescriptor]

    private let store: CNContactStore

    init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    static func access() -> ContactsAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .allowed
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Point-of-use permission request (constitution: permissions are
    /// requested when the feature needs them, with plain-language
    /// explanation shown first — the CallView access card does that).
    /// Completion-handler form wrapped rather than the async overlay so
    /// the call compiles against any SDK that ships the Contacts
    /// framework.
    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Every contact with at least one dialable number, deduped by
    /// normalized number and sorted by name. The fetch itself is the
    /// "sweep": one enumerate pass covers the phone's own contacts AND
    /// every app-synced record (WhatsApp, Messenger, …).
    ///
    /// Dedupe: unlinked apps (typically WhatsApp) can hold a second
    /// record for someone already in the phone book — same number, so
    /// the same person — and two rows for one number would let a search
    /// show the same dialable person twice. The record with a real name
    /// wins over a number-as-name placeholder; otherwise the first
    /// record encountered (fetch is in user-default display order)
    /// stays.
    func allEntries() throws -> [AddressBookEntry] {
        let request = CNContactFetchRequest(keysToFetch: Self.fetchKeys)
        request.sortOrder = .userDefault

        var byNumber: [String: AddressBookEntry] = [:]
        try store.enumerateContacts(with: request) { contact, _ in
            let numbers: [(label: String, phone: String)] = contact.phoneNumbers.map { labeled in
                let label = labeled.label.flatMap {
                    CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0)
                } ?? ""
                return (label, labeled.value.stringValue)
            }
            guard let entry = AddressBookEntry.make(givenName: contact.givenName,
                                                    familyName: contact.familyName,
                                                    organizationName: contact.organizationName,
                                                    numbers: numbers) else { return }
            let existing = byNumber[entry.normalized]
            let entryHasRealName = entry.name != entry.phone
            if existing == nil {
                byNumber[entry.normalized] = entry
            } else if entryHasRealName && existing?.name == existing?.phone {
                // The placeholder must not shadow the named record.
                byNumber[entry.normalized] = entry
            }
        }
        return byNumber.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
