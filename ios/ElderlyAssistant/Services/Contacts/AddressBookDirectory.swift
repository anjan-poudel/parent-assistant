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
///
/// `messengerHandle` (2026-09-06): the Messenger handle derived from the
/// record's stored Facebook linkage (see `derivedMessengerHandle`) — nil
/// for a record that carries none, and the honest basis for the row's
/// Messenger pill in the unified search.
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
    /// The Messenger handle this record's Facebook linkage carries
    /// (derived at `make` time, pre-normalized by
    /// `CallLinks.messengerHandle`) — nil when the record has no
    /// linkage. Never derived from the phone: a bare number is not a
    /// Messenger identity.
    let messengerHandle: String?

    /// Memberwise stand-in with a nil-handle default — same pattern as
    /// `FamilyContact`'s defaulted `messengerHandle`: a row with no
    /// linkage (the common case) reads naturally instead of spelling
    /// `messengerHandle: nil` at every construction site.
    init(name: String, label: String, phone: String, normalized: String,
         messengerHandle: String? = nil) {
        self.name = name
        self.label = label
        self.phone = phone
        self.normalized = normalized
        self.messengerHandle = messengerHandle
    }

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
    ///
    /// `instantMessageAddresses` and `socialProfiles` are the record's
    /// Facebook/Messenger linkage fields, pre-mapped to plain tuples by
    /// `AddressBookDirectory.allEntries` (this function stays
    /// CNContact-free). The Messenger handle is derived from THEM via
    /// `derivedMessengerHandle`, never from the phone — a bare number
    /// is not a Messenger identity. A handle never changes the row's
    /// existence: no dialable number still means no row, handle or not.
    static func make(givenName: String,
                     familyName: String,
                     organizationName: String,
                     numbers: [(label: String, phone: String)],
                     instantMessageAddresses: [(service: String, username: String)] = [],
                     socialProfiles: [(service: String, urlString: String)] = []) -> AddressBookEntry? {
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
                                normalized: ContactNumberKey.normalized(number.phone),
                                messengerHandle: derivedMessengerHandle(
                                    instantMessageAddresses: instantMessageAddresses,
                                    socialProfiles: socialProfiles))
    }

    /// The Messenger handle this contact's stored Facebook linkage
    /// actually carries — the honest basis for the row's Messenger pill
    /// (`UnifiedContactSearch.Result.messengerAvailable`). Messenger
    /// addresses people by handle, and only two kinds of address-book
    /// data ever contain one:
    ///
    ///  1. A Facebook-family instant-message address — service
    ///     "Facebook" (the framework's `CNInstantMessageServiceFacebook`)
    ///     or any service naming Messenger, case-insensitive — whose
    ///     username is the person's Facebook username or numeric
    ///     user-id. (2026-09-06: Contacts.h predefines "Facebook";
    ///     "Messenger"-named services come from sync tools, which may
    ///     write any free-form service string.)
    ///  2. A "Facebook" social profile (`CNSocialProfileServiceFacebook`)
    ///     whose URL points at a facebook.com profile page — the shape
    ///     Facebook's contact sync wrote into the book. The page's last
    ///     path segment is the person's username ("…/sita.sharma" →
    ///     "sita.sharma"); a trailing ".php" segment is a reserved page
    ///     handler ("profile.php", "friends.php", …), never a person, so
    ///     then the numeric user-id — which such pages carry in their
    ///     `id=` query — is read instead. A URL naming no person
    ///     (empty path, non-facebook host) contributes nothing.
    ///
    /// Every candidate runs through `CallLinks.messengerHandle`, so
    /// anything outside Messenger's username alphabet ("सीता", a display
    /// name with spaces, a phone number's "+") can never become a
    /// handle: nil means no usable handle is present, and the pill's
    /// claim stays "a link can be built from what this row has", never
    /// "this person is on Messenger". A phone number alone never
    /// contributes — a bare number is not a Messenger identity.
    ///
    /// Field-class precedence: an instant-message handle beats a
    /// social-profile URL — the IM username is linkage a sync wrote
    /// directly as a handle, the URL path is second-hand — and the
    /// first usable entry in contact order wins WITHIN each class: an
    /// unusable entry (empty username, malformed URL) is skipped, not
    /// fatal, so a real handle behind a junk field is not lost.
    static func derivedMessengerHandle(instantMessageAddresses: [(service: String, username: String)],
                                       socialProfiles: [(service: String, urlString: String)]) -> String? {
        for address in instantMessageAddresses {
            guard Self.isFacebookFamilyService(address.service) else { continue }
            let handle = CallLinks.messengerHandle(address.username)
            if !handle.isEmpty { return handle }
        }
        for profile in socialProfiles {
            guard Self.isFacebookService(profile.service),
                  let url = URL(string: profile.urlString),
                  Self.isFacebookProfileHost(url.host) else { continue }
            if let handle = Self.facebookHandle(in: url) { return handle }
        }
        return nil
    }

    /// Is an instant-message service string Facebook or Messenger? The
    /// framework defines `CNInstantMessageServiceFacebook` = "Facebook";
    /// sync tools that add Messenger as a free-form service (the
    /// initializer takes any string) write names like "Messenger" or
    /// "Facebook Messenger" — so: equal to "facebook" (any case) or
    /// containing "messenger".
    private static func isFacebookFamilyService(_ service: String) -> Bool {
        let s = service.lowercased()
        return s == "facebook" || s.contains("messenger")
    }

    /// Is a social-profile service string Facebook's? (Social profiles
    /// have no free-form Messenger service — `CNSocialProfileServiceFacebook`
    /// is the only Facebook-shaped one, so exact match only.)
    private static func isFacebookService(_ service: String) -> Bool {
        service.lowercased() == "facebook"
    }

    /// Does a URL host name facebook.com (with any subdomain)?
    /// "www.facebook.com" and "m.facebook.com" yes; "notfacebook.com"
    /// no — the ".facebook.com" suffix check needs the separating dot.
    private static func isFacebookProfileHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == "facebook.com" || host.hasSuffix(".facebook.com")
    }

    /// The handle one facebook.com profile URL names, or nil when it
    /// names no person. Last non-empty path segment = the username;
    /// when that segment is a reserved ".php" page handler, the person's
    /// numeric user-id (a legitimate `fb-messenger://user-thread/` form)
    /// is read from the page's `id=` query instead — and only when the
    /// id is pure ASCII digits, which Facebook's ids always are: an
    /// id that isn't digits is not a real profile id, so no handle.
    private static func facebookHandle(in url: URL) -> String? {
        guard let segment = url.pathComponents.last(where: { $0 != "/" }),
              !segment.isEmpty else { return nil }
        if segment.lowercased().hasSuffix(".php") {
            guard let id = facebookProfileID(in: url) else { return nil }
            let handle = CallLinks.messengerHandle(id)
            return handle.isEmpty ? nil : handle
        }
        let handle = CallLinks.messengerHandle(segment)
        return handle.isEmpty ? nil : handle
    }

    /// The digits-only `id=` query parameter of a facebook.com
    /// profile-by-ID page ("…/profile.php?id=1000123456789").
    private static func facebookProfileID(in url: URL) -> String? {
        guard let queryItems = URLComponents(url: url,
                                             resolvingAgainstBaseURL: false)?.queryItems,
              let id = queryItems.first(where: { $0.name == "id" })?.value,
              !id.isEmpty,
              id.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return id
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

    /// Keys fetched for every contact. The IM-address and social-profile
    /// linkage keys (2026-09-06) are fetched so Messenger-synced
    /// records — which carry the person's Facebook/Messenger handle in
    /// those fields, never in a phone-adjacent one — can earn the row's
    /// Messenger pill in the unified search (see
    /// `AddressBookEntry.derivedMessengerHandle`). One pass serves both
    /// the plain dial search and the badged unified one, so they are
    /// fetched unconditionally.
    private static let fetchKeys: [CNKeyDescriptor] = [
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactOrganizationNameKey,
        CNContactPhoneNumbersKey,
        CNContactInstantMessageAddressesKey,
        CNContactSocialProfilesKey,
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
    /// every app-synced record (WhatsApp, Messenger, …). A record whose
    /// Facebook/Messenger linkage yields a handle (see
    /// `AddressBookEntry.derivedMessengerHandle`) carries it on the
    /// row, so the unified search can badge the row honestly.
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
            // The Facebook/Messenger linkage fields, mapped to plain
            // tuples (CNInstantMessageAddress/CNSocialProfile live on
            // CNContact and cannot appear in the pure `make`).
            let instantMessages: [(service: String, username: String)] =
                contact.instantMessageAddresses.map {
                    (service: $0.value.service, username: $0.value.username)
                }
            let socialProfiles: [(service: String, urlString: String)] =
                contact.socialProfiles.map {
                    (service: $0.value.service, urlString: $0.value.urlString)
                }
            guard let entry = AddressBookEntry.make(givenName: contact.givenName,
                                                    familyName: contact.familyName,
                                                    organizationName: contact.organizationName,
                                                    numbers: numbers,
                                                    instantMessageAddresses: instantMessages,
                                                    socialProfiles: socialProfiles) else { return }
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
