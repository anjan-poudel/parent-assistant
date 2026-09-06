import Foundation

// MARK: - Unified contact search (Phone leaf, 2026-09-06)
//
// One search over BOTH "people I might call" surfaces: the configured
// family contacts (up to three, relationship-labelled, always reachable
// through this app's own buttons) and the system address book (see
// `SystemContactSearch` — the platform sweep; Contacts.app already
// aggregates the user's own entries AND app-synced records).
//
// Layering mirrors AddressBookDirectory: the pure union logic — tiered
// family matching, family-first ranking, matched-only dedupe, row
// mapping — lives here and is unit-testable without CNContact; platform
// glue stays in `AddressBookDirectory`. Matching semantics are shared
// deliberately: family name matching uses the same substring options
// and digit rule as `SystemContactSearch`, and family RELATIONSHIP
// matching anchors on `ContactResolver`'s relationship table, so a
// contact stored as "छोरी" surfaces for a query of "daughter" exactly
// as the voice resolver would resolve it.
enum UnifiedContactSearch {

    /// One row of the unified result list: a configured family contact
    /// (`.family`) or a system address-book entry (`.addressBook`). The
    /// UI renders both uniformly through the computed properties —
    /// name, caption, dialable phone — plus the reachability badges.
    ///
    /// The `.whatsAppAvailable`/`.messengerAvailable` badges are
    /// AVAILABILITY, never PRESENCE: iOS cannot enumerate which people
    /// have WhatsApp or Messenger installed, and a Messenger link
    /// cannot even be built from a bare phone number. A badge therefore
    /// only claims "a link to the app in question can be built from
    /// what this row has, IF the app is installed" — the honest maximum
    /// iOS lets the app know. For book rows "what this row has"
    /// (2026-09-06) includes the Facebook/Messenger linkage the system
    /// stores with app-synced records (see
    /// `AddressBookEntry.derivedMessengerHandle`): a record that
    /// carries a real handle earns the Messenger pill, while a bare
    /// number alone never does. A row with every badge off is still a
    /// row: its dial button reaches the person by number.
    enum Result: Equatable, Identifiable {
        case family(FamilyContact)
        case addressBook(AddressBookEntry)

        /// Stable identity across both sources: family rows key on
        /// their UUID, prefixed so a UUID string can never collide with
        /// a number key; book rows key on their normalized number, the
        /// same key the address-book fetch dedupes on.
        var id: String {
            switch self {
            case .family(let contact): return "family-\(contact.id.uuidString)"
            case .addressBook(let entry): return entry.normalized
            }
        }

        /// Display name: the configured name or the book row's name.
        var name: String {
            switch self {
            case .family(let contact): return contact.name
            case .addressBook(let entry): return entry.name
            }
        }

        /// One-line caption under the name: the relationship for family
        /// contacts ("छोरी"), the number label + number for book rows.
        var caption: String {
            switch self {
            case .family(let contact): return contact.relationship
            case .addressBook(let entry): return entry.caption
            }
        }

        /// Raw phone as dialed. Both sources always carry a phone
        /// string — a family contact may have typed a non-dialable one
        /// (see `whatsAppAvailable`), a book row is dialable by
        /// construction (`AddressBookEntry.make`).
        var phone: String {
            switch self {
            case .family(let contact): return contact.phone
            case .addressBook(let entry): return entry.phone
            }
        }

        /// The Messenger handle the row's thread link is built from.
        /// Family rows: the stored handle exactly as configured
        /// ("@hari.thapa" stays "@hari.thapa"; link building
        /// normalizes). Book rows: the handle derived at fetch time
        /// from the record's Facebook linkage
        /// (`AddressBookEntry.derivedMessengerHandle`) — already
        /// normalized, or nil when the record carries no linkage.
        var messengerHandle: String? {
            switch self {
            case .family(let contact): return contact.messengerHandle
            case .addressBook(let entry): return entry.messengerHandle
            }
        }

        /// Whether a WhatsApp chat link can be built for this row's
        /// phone (any ASCII digits to route on). Availability, not
        /// presence — see the enum doc.
        var whatsAppAvailable: Bool {
            !ContactNumberKey.normalized(phone).isEmpty
        }

        /// Whether a Messenger thread link can be built for this row.
        /// Family rows: the stored handle must normalize to Messenger's
        /// username alphabet (see `CallLinks.messengerHandle` — "सीता"
        /// is NOT a usable handle, and no handle means no link). Book
        /// rows: true exactly when the record's Facebook linkage
        /// yielded a handle — `AddressBookEntry.derivedMessengerHandle`
        /// already ran every candidate through the same normalizer, so a
        /// non-nil derived handle IS a buildable link, and a plain row
        /// (number only, no linkage) stays badge-off: a bare number
        /// cannot form a Messenger handle, even when an app-synced copy
        /// of the person exists on the device.
        var messengerAvailable: Bool {
            switch self {
            case .family(let contact):
                return !CallLinks.messengerHandle(contact.messengerHandle ?? "").isEmpty
            case .addressBook(let entry):
                return entry.messengerHandle != nil
            }
        }
    }

    /// What one search shows: the ranked union rows to render, and
    /// whether more matches were cut off by `limit`. Same honesty
    /// contract as `SystemContactSearch.Outcome`: the caller shows the
    /// "keep typing" hint instead of silently hiding people — an
    /// elderly user who searches "a" must never wonder where the rest
    /// went.
    struct Outcome: Equatable {
        let entries: [Result]
        let moreAvailable: Bool
    }

    static let defaultLimit = 15

    /// Why a family contact matched, best first. `.exactName` beats
    /// `.relationship` beats `.containment`: an exact name says "this
    /// person" louder than a relationship word does, and both are
    /// stronger signals than a raw substring or digit hit. A contact
    /// matching at several tiers keeps the best one.
    enum FamilyMatchTier: Int, Comparable {
        case exactName
        case relationship
        case containment

        /// Raw-value order (0/1/2) IS the quality order — best first —
        /// so `<` compares the raw values directly.
        static func < (lhs: FamilyMatchTier, rhs: FamilyMatchTier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// One search over both sources. Family matches always lead — they
    /// are the people the app is CONFIGURED to call and chat with by
    /// its own buttons, and the address book is the long tail — then
    /// the book rows follow in `SystemContactSearch`'s own order.
    ///
    /// Dedupe drops a book row only when the SAME PERSON already
    /// matched as a family contact (identical dialable number), and
    /// only when the FAMILY row matched: an unmatched family twin must
    /// not hide the book twin — the book record may carry a fresher,
    /// app-synced name, and the person stays findable by whatever they
    /// matched.
    ///
    /// The rows' reachability badges (see `Result`) are honest by
    /// design: availability is not platform presence — iOS cannot say
    /// who actually uses WhatsApp or Messenger — so a badge-off row is
    /// not unreachable, and a badge-on row never claims the app is
    /// installed. `moreAvailable` counts the whole matched union after
    /// dedupe, not just the rows shown.
    static func search(query: String,
                       family: [FamilyContact],
                       in entries: [AddressBookEntry],
                       recency: [String: Date] = [:],
                       limit: Int = defaultLimit) -> Outcome {
        let matchedFamily = familyMatches(query: query, in: family)
        let bookMatches = dedupe(matchedFamily: matchedFamily.map { $0.contact },
                                 in: addressBookMatches(query: query, in: entries))
        let ranked = rank(family: matchedFamily, book: bookMatches, recency: recency)
        return Outcome(entries: Array(ranked.prefix(limit)),
                       moreAvailable: matchedFamily.count + bookMatches.count > limit)
    }

    /// The family half of the union. Matching runs on the TRIMMED query
    /// (empty or whitespace-only → no matches at all). Each contact
    /// keeps its BEST tier:
    ///
    ///  - `.exactName` — normalized name equals the normalized query.
    ///    `NepaliTextNormalizer` folds case, NFC forms and Devanagari
    ///    digits, but deliberately does NOT transliterate — "sita" and
    ///    "सीता" stay different names, same rule as the book search.
    ///  - `.relationship` — the query AND the stored relationship both
    ///    anchor on `ContactResolver.relationshipAnchors` and land on
    ///    the same anchor word. This is the cross-script bridge
    ///    ("daughter" ↔ "छोरी") and the synonym bridge ("बहिनी" ↔
    ///    "दिदी" — same "sister" anchor, no shared substring), which
    ///    raw containment would miss.
    ///  - `.containment` — the query is a case- and diacritic-
    ///    insensitive substring of the RAW name or relationship (same
    ///    options as `SystemContactSearch.matches`), or a non-empty
    ///    digit run of the query is contained in the contact's
    ///    normalized number.
    static func familyMatches(query: String,
                              in family: [FamilyContact]) -> [(contact: FamilyContact, tier: FamilyMatchTier)] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let normalizedQuery = NepaliTextNormalizer.normalize(needle)
        let queryDigits = ContactNumberKey.normalized(needle)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        return family.compactMap { contact in
            // Checking tiers best-first and returning the first hit IS
            // best-tier selection: exactName (checked first) is better
            // than relationship (checked second) is better than
            // containment (checked last).
            if NepaliTextNormalizer.normalize(contact.name) == normalizedQuery {
                return (contact: contact, tier: .exactName)
            }
            if let queryAnchor = ContactResolver.relationshipAnchor(in: normalizedQuery),
               let contactAnchor = ContactResolver.relationshipAnchor(
                   in: NepaliTextNormalizer.normalize(contact.relationship)),
               queryAnchor == contactAnchor {
                return (contact: contact, tier: .relationship)
            }
            if contact.name.range(of: needle, options: options) != nil
                || contact.relationship.range(of: needle, options: options) != nil {
                return (contact: contact, tier: .containment)
            }
            if !queryDigits.isEmpty,
               ContactNumberKey.normalized(contact.phone).contains(queryDigits) {
                return (contact: contact, tier: .containment)
            }
            return nil
        }
    }

    /// The address-book half of the union — byte-identical delegation
    /// to `SystemContactSearch.matches`, so this surface can never
    /// disagree with the system-contacts one about what matches.
    static func addressBookMatches(query: String,
                                   in entries: [AddressBookEntry]) -> [AddressBookEntry] {
        SystemContactSearch.matches(query: query, in: entries)
    }

    /// Drops book rows whose normalized number equals a MATCHED family
    /// contact's number — the same person under two records (family
    /// config plus the inevitable app-synced book copy), who must not
    /// appear twice in one list.
    ///
    /// Scoped to MATCHED family contacts on purpose: a family twin that
    /// did not match must not hide the book twin. If the query did not
    /// match the family record, the book record (possibly fresher,
    /// possibly under the name the person actually uses) stays — the
    /// person remains findable through exactly what matched.
    static func dedupe(matchedFamily: [FamilyContact],
                       in bookMatches: [AddressBookEntry]) -> [AddressBookEntry] {
        let matchedNumbers = Set(matchedFamily.map { ContactNumberKey.normalized($0.phone) })
        guard !matchedNumbers.isEmpty else { return bookMatches }
        return bookMatches.filter { !matchedNumbers.contains($0.normalized) }
    }

    /// Ranks a matched set into the unified order: every family match
    /// first — tier best-first, then most-recently-called first with
    /// the same nil-handling as `SystemContactSearch.rank` (called
    /// beats never-called; a date tie falls to name), then name via
    /// `localizedStandardCompare` — and the book rows after, in
    /// `SystemContactSearch.rank`'s own unchanged order.
    static func rank(family: [(contact: FamilyContact, tier: FamilyMatchTier)],
                     book: [AddressBookEntry],
                     recency: [String: Date]) -> [Result] {
        let rankedFamily = family.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            let lhsDate = recency[ContactNumberKey.normalized(lhs.contact.phone)]
            let rhsDate = recency[ContactNumberKey.normalized(rhs.contact.phone)]
            switch (lhsDate, rhsDate) {
            case let (a?, b?) where a != b:
                return a > b
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.contact.name.localizedStandardCompare(rhs.contact.name) == .orderedAscending
            }
        }.map { Result.family($0.contact) }

        let rankedBook = SystemContactSearch.rank(book, by: recency)
            .map { Result.addressBook($0) }
        return rankedFamily + rankedBook
    }
}
