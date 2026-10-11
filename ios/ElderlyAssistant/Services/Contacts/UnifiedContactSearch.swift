import Foundation

// MARK: - Unified contact search (Phone leaf, 2026-09-06)
//
// One search over BOTH "people I might call" surfaces: the configured
// family contacts (relationship-labelled, always reachable through this
// app's own buttons — the curated list grew to twelve with the
// family-and-friends task, 2026-09-07; the count is `FamilyContactStore
// .maxContacts`, no number is hard-coded here) and the system address
// book (see `SystemContactSearch` — the platform sweep; Contacts.app
// already aggregates the user's own entries AND app-synced records).
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

        /// Whether a Messenger chat surface can be opened for this row
        /// (2026-09-07, user direction — phone-based badging reverted).
        /// The pill means "a handle exists for a real thread link",
        /// never "this person is on Messenger" and never "this row has
        /// a phone": Messenger has no phone-number thread link
        /// (`m.me/<username>` is Meta's only official form), so the
        /// phone-based chat attempt is GONE for book rows — a bare
        /// number is not a Messenger identity and earns no pill.
        ///
        /// Family rows keep the existing handle-normalization gate: the
        /// configured handle must be usable in Messenger's username
        /// alphabet (see `CallLinks.messengerHandle` — "सीता" is NOT a
        /// usable handle, and no handle means no link).
        ///
        /// Book rows: the handle derived at fetch time from the record's
        /// Facebook/Messenger linkage (`AddressBookEntry.messengerHandle`
        /// — pre-normalized, nil when the record carries none). A handle
        /// the app captured earlier for a book row lives in
        /// `MessengerHandleStore` (keyed by normalized phone); the UI
        /// layer resolves that on top of this pure search (see
        /// CallView's messenger pill resolution).
        var messengerAvailable: Bool {
            switch self {
            case .family(let contact):
                return !CallLinks.messengerHandle(contact.messengerHandle ?? "").isEmpty
            case .addressBook(let entry):
                return entry.messengerHandle != nil
            }
        }
    }

    /// What one search shows: the ranked union rows to render, whether
    /// more matches were cut off by `limit`, and — for rows synthesized
    /// by the link merge (Pass 3) — the phone-book name the person is
    /// ALSO stored under. Same honesty contract as
    /// `SystemContactSearch.Outcome`: the caller shows the "keep typing"
    /// hint instead of silently hiding people — an elderly user who
    /// searches "a" must never wonder where the rest went.
    struct Outcome: Equatable {
        let entries: [Result]
        let moreAvailable: Bool

        /// Keyed by FAMILY result id ("family-<uuid>", see `Result.id`) →
        /// the linked phone-book record's display name — the honest
        /// explanation for why a name the user never typed into the
        /// family record surfaces this row (design-l1 §7.2: the row
        /// renders "Also in your phone book as …"). Only SYNTHESIZED
        /// rows appear here: a row the family contact matched itself
        /// needs no explanation, and dropping its linked book twin adds
        /// no caption. Empty for every unlinked search — the default
        /// keeps existing constructions compiling and is the parity
        /// anchor.
        let linkedBookNames: [String: String]

        init(entries: [Result], moreAvailable: Bool,
             linkedBookNames: [String: String] = [:]) {
            self.entries = entries
            self.moreAvailable = moreAvailable
            self.linkedBookNames = linkedBookNames
        }
    }

    static let defaultLimit = 15

    /// Why a family contact matched, best first. `.exactName` beats
    /// `.relationship` beats `.nickname` beats `.containment`: an exact
    /// name says "this person" louder than a relationship word does, a
    /// stored nickname/variation is the person's OWN name (stronger
    /// than a raw substring of a field, and it bridges what raw
    /// containment would miss), and a raw substring or digit hit is the
    /// weakest signal. A contact matching at several tiers keeps the
    /// best one.
    ///
    /// `.nickname` was INSERTED at raw value 2 (family-contacts-unify
    /// T-152, design-l1 §8.1) and `.containment` renumbered to 3: the
    /// tier is transient — computed per search and never persisted — so
    /// the renumbering is safe, and raw-value order stays the quality
    /// order `<` compares.
    enum FamilyMatchTier: Int, Comparable {
        case exactName = 0
        case relationship = 1
        /// Any stored nickname: exact (one O(1) map hit on the index) or
        /// Character-safe substring of a precomputed normalized
        /// nickname. Both land here — "exact > substring" is check
        /// ORDER only, with no ranking consequence by construction
        /// (design-l2 §1.6).
        case nickname = 2
        case containment = 3

        /// Raw-value order (0/1/2/3) IS the quality order — best first —
        /// so `<` compares the raw values directly.
        static func < (lhs: FamilyMatchTier, rhs: FamilyMatchTier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// One search over both sources, in the five passes design-l1 §7.1
    /// pins. Family matches always lead — they are the people the app
    /// is CONFIGURED to call and chat with by its own buttons, and the
    /// address book is the long tail — then the book rows follow in
    /// `SystemContactSearch`'s own order.
    ///
    /// Passes:
    ///  1. family matches (name / relationship / nickname /
    ///     containment tiers — see `familyMatches`);
    ///  2. book matches (`SystemContactSearch.matches`, unchanged);
    ///  3. link merge — a matched book row whose RECORD is a verified
    ///     link of a family contact is the same person twice: dropped,
    ///     replaced by a synthesized family row when the family contact
    ///     itself did not match;
    ///  4. the number dedupe below, over the rows left after pass 3
    ///     (byte-for-byte today's rule, unchanged);
    ///  5. the truncation recount over the POST-pass union.
    ///
    /// Dedupe drops a book row only when the SAME PERSON already
    /// matched as a family contact (identical dialable number) or when
    /// an explicit VERIFIED link proves the two records are one person
    /// (pass 3) — and only when the family side is reachable: an
    /// unmatched family twin must not hide the book twin, the book
    /// record may carry a fresher, app-synced name, and the person
    /// stays findable by whatever they matched.
    ///
    /// `index` is REQUIRED (no convenience overload that could drift,
    /// design-l2 §1.6): the caller publishes one index per roster
    /// snapshot, so the nickname/name tiers read the same precomputed
    /// strings and normalization runs once per build, not per contact
    /// per keystroke (NFR-FCU-001).
    ///
    /// `verifiedLinks` defaults to `.empty` — the unlinked anchor: with
    /// no verified link, every new branch below is inert and the
    /// outcome is today's byte-for-byte (FR-FCU-003, the parity pin).
    /// A snapshot is a value; a stale one simply fails its lookups.
    ///
    /// The rows' reachability badges (see `Result`) are honest by
    /// design: availability is not platform presence — iOS cannot say
    /// who actually uses WhatsApp or Messenger — so a badge-off row is
    /// not unreachable, and a badge-on row never claims the app is
    /// installed. `moreAvailable` counts the whole matched union after
    /// dedupe, not just the rows shown.
    static func search(query: String,
                       family: [FamilyContact],
                       index: FamilyContactIndex,
                       in entries: [AddressBookEntry],
                       verifiedLinks: VerifiedLinksSnapshot = .empty,
                       recency: [String: Date] = [:],
                       limit: Int = defaultLimit) -> Outcome {
        // Pass 1 — family matches, nickname tiers included.
        let matchedFamily = familyMatches(query: query, in: family, index: index)
        // Pass 2 — book matches, unchanged.
        let bookMatches = addressBookMatches(query: query, in: entries)
        // Pass 3 — link merge: drop the linked twin, or synthesize the
        // family row in its place. `.empty` snapshot → both lists back
        // untouched (the early-out IS the parity guarantee).
        let merged = linkMerge(matchedFamily: matchedFamily, bookMatches: bookMatches,
                               family: family, index: index, verifiedLinks: verifiedLinks)
        // Pass 4 — today's number rule, over the REMAINING book rows.
        let remainingBook = dedupe(matchedFamily: matchedFamily.map { $0.contact },
                                   in: merged.bookRows)
        // Pass 5 — recount before the limit slice.
        let ranked = rank(family: matchedFamily + merged.synthesized,
                          book: remainingBook, recency: recency)
        return Outcome(entries: Array(ranked.prefix(limit)),
                       moreAvailable: matchedFamily.count + merged.synthesized.count
                           + remainingBook.count > limit,
                       linkedBookNames: merged.linkedBookNames)
    }

    /// The family half of the union — Pass 1. Matching runs on the
    /// TRIMMED query (empty or whitespace-only → no matches at all).
    /// Name and nickname tiers read the caller's `index` (the roster's
    /// precomputed normalized strings, see `FamilyContactIndex`); each
    /// contact keeps its BEST tier:
    ///
    ///  - `.exactName` — the indexed normalized name equals the
    ///    normalized query. `NepaliTextNormalizer` folds case, NFC
    ///    forms and Devanagari digits, but deliberately does NOT
    ///    transliterate — "sita" and "सीता" stay different names, same
    ///    rule as the book search.
    ///  - `.relationship` — the query AND the stored relationship both
    ///    anchor on `ContactResolver.relationshipAnchors` and land on
    ///    the same anchor word. This is the cross-script bridge
    ///    ("daughter" ↔ "छोरी") and the synonym bridge ("बहिनी" ↔
    ///    "दिदी" — same "sister" anchor, no shared substring), which
    ///    raw containment would miss.
    ///  - `.nickname` — the normalized query is one of the contact's
    ///    stored nickname spellings, exact (the O(1) index map) or a
    ///    Character-safe substring of a precomputed normalized one
    ///    (`range(of:options:)`, the SAME call and options the
    ///    containment tier uses — the Devanagari grapheme behaviour is
    ///    reused and pinned, never "fixed", NFR-FCU-007). A
    ///    punctuation-only query that normalizes to the empty string is
    ///    no query at all here, mirroring the index's own decision
    ///    never to key the empty string.
    ///  - `.containment` — the query is a case- and diacritic-
    ///    insensitive substring of the RAW name or relationship (same
    ///    options as `SystemContactSearch.matches`), or a non-empty
    ///    digit run of the query is contained in the contact's
    ///    normalized number.
    ///
    /// An index that does not know this contact (a caller error — the
    /// shipped call sites build the index from the same roster they
    /// search) contributes no name/nickname tiers; containment still
    /// applies, so a person is never rendered un-findable.
    static func familyMatches(query: String,
                              in family: [FamilyContact],
                              index: FamilyContactIndex) -> [(contact: FamilyContact, tier: FamilyMatchTier)] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let normalizedQuery = NepaliTextNormalizer.normalize(needle)
        let queryDigits = ContactNumberKey.normalized(needle)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        // One map hit per call, not per contact: the exact-nickname
        // holders, resolved once.
        let exactNicknameHolders = Set(index.exactNicknameHolders(normalizedQuery))

        return family.compactMap { contact in
            // Checking tiers best-first and returning the first hit IS
            // best-tier selection: exactName (checked first) is better
            // than relationship (checked second) is better than
            // nickname (third) is better than containment (last).
            let entry = index.entry(for: contact.id)
            if entry?.normalizedName == normalizedQuery {
                return (contact: contact, tier: .exactName)
            }
            if let queryAnchor = ContactResolver.relationshipAnchor(in: normalizedQuery),
               let contactAnchor = ContactResolver.relationshipAnchor(
                   in: NepaliTextNormalizer.normalize(contact.relationship)),
               queryAnchor == contactAnchor {
                return (contact: contact, tier: .relationship)
            }
            // Exact first (the map), then the Character-safe substring
            // over the precomputed normalized spellings — same
            // direction as the name tier (the stored value contains the
            // query). Both are one tier: check order has no ranking
            // consequence by construction.
            if exactNicknameHolders.contains(contact.id)
                || (!normalizedQuery.isEmpty
                    && (entry?.normalizedNicknames.contains {
                        $0.range(of: normalizedQuery, options: options) != nil
                    } ?? false)) {
                return (contact: contact, tier: .nickname)
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

    /// Pass 3 — the link merge (design-l1 §7.1, FR-FCU-003). For each
    /// matched book row whose RECORD carries a verified family link:
    ///
    ///  - the family contact MATCHED in pass 1 → the book row is the
    ///    same person twice: DROP it (the family row is the person);
    ///  - the family contact did NOT match (the query hit only the
    ///    book-side name or number spelling) → SYNTHESIZE its family
    ///    row at tier `.containment` and DROP the book row, recording
    ///    the book's display name in `linkedBookNames` so the row can
    ///    explain the name the user never typed — suppressed when the
    ///    two names already normalize equal (nothing to explain).
    ///
    /// Guarded, never guessed:
    ///  - a row with an EMPTY identifier is not a live record and can
    ///    never be a link target (T-148a) — it is kept;
    ///  - a link whose family contact is not in this roster (deleted
    ///    between the snapshot publish and this search) is kept too:
    ///    a row is never dropped without a replacement row carrying the
    ///    person — no phantom drop;
    ///  - a second matched row of the SAME record (one record, two
    ///    numbers) synthesizes once — one row per person;
    ///  - an `.empty` snapshot short-circuits: every new branch here is
    ///    gated on a verified link, so unlinked pairs take the exact
    ///    lists they always took (FR-FCU-003 "unlinked pairs keep
    ///    today's behavior EXACTLY").
    ///
    /// Only the VERIFIED snapshot is consulted: a stored `systemContact`
    /// claim that did not verify is stale and merges nothing (FR-FCU-006).
    private static func linkMerge(matchedFamily: [(contact: FamilyContact, tier: FamilyMatchTier)],
                                 bookMatches: [AddressBookEntry],
                                 family: [FamilyContact],
                                 index: FamilyContactIndex,
                                 verifiedLinks: VerifiedLinksSnapshot)
        -> (synthesized: [(contact: FamilyContact, tier: FamilyMatchTier)],
            bookRows: [AddressBookEntry],
            linkedBookNames: [String: String]) {
        guard !verifiedLinks.links.isEmpty else {
            return ([], bookMatches, [:])
        }

        let matchedIDs = Set(matchedFamily.map { $0.contact.id })
        var synthesizedIDs: Set<UUID> = []
        var synthesized: [(contact: FamilyContact, tier: FamilyMatchTier)] = []
        var linkedBookNames: [String: String] = [:]
        var remaining: [AddressBookEntry] = []
        remaining.reserveCapacity(bookMatches.count)

        for row in bookMatches {
            guard !row.identifier.isEmpty,
                  let familyID = verifiedLinks.familyID(forIdentifier: row.identifier),
                  let contact = family.first(where: { $0.id == familyID }) else {
                remaining.append(row)
                continue
            }
            // Matched in pass 1, or already synthesized for a sibling
            // row of the same record: either way this row is the
            // duplicate, and dropping it always leaves one row for the
            // person.
            if matchedIDs.contains(familyID) || synthesizedIDs.contains(familyID) {
                continue
            }
            synthesizedIDs.insert(familyID)
            synthesized.append((contact: contact, tier: .containment))
            // The caption key is the RESULT id, built through `Result`
            // itself so the map can never drift from the row's id.
            let rowID = Result.family(contact).id
            if NepaliTextNormalizer.normalize(row.name) != index.entry(for: familyID)?.normalizedName {
                linkedBookNames[rowID] = row.name
            }
        }
        return (synthesized, remaining, linkedBookNames)
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
