import Foundation

/// Derived, value-type index over the family roster — the search
/// foundation the nickname tiers are built on (design-l1 §5.4,
/// design-l2 §1.2; FR-FCU-012, NFR-FCU-001).
///
/// Shape and lifecycle:
///  - Built wholesale from a `[FamilyContact]` snapshot — never
///    persisted, never mutated in place. The coordinator republishes
///    it on every roster mutation (T-156); because a rebuild derives
///    ONLY from the roster it was handed, an index can never disagree
///    with that snapshot, and a rebuild can never produce a torn read:
///    callers swap a whole new value, the old one is left untouched.
///  - Pure value, no shared mutable state, safe on any thread
///    (design-l2 §4.1). All storage is immutable after `init`.
///
/// Matching discipline (NFR-FCU-007):
///  - Every name/nickname is normalized ONCE at build time through the
///    shared `NepaliTextNormalizer` — no new grapheme or transliteration
///    logic lives here ("सानु" and "sanu" stay different people, the
///    deliberate OD-2 no-transliteration rule).
///  - Exact nickname matching is one dictionary hit
///    (`exactNicknameHolders`); the substring/containment tiers run
///    downstream (T-152) over the PREcomputed strings in `Entry` with
///    the house `range(of:options:)` call, so the Devanagari
///    grapheme-cluster behaviour is pinned, not reinvented.
///  - An empty index (or a roster that never used nicknames)
///    reproduces today's name-only behaviour exactly — the
///    compatibility anchor for unlinked pairs.
///
/// Failure paths:
///  - Two contacts may claim the same nickname: `idsByNickname` is
///    multi-valued, so both ids survive in roster order (no silent
///    overwrite) and the ambiguity is representable for T-152/T-153.
///  - No logging at all in this type — there is no PII surface to
///    sanitise (constitution §Privacy).
struct FamilyContactIndex: Equatable {

    /// One roster record, as the index sees it. `rawNicknames` keeps
    /// the stored spellings (order preserved, duplicates preserved) so
    /// containment matching stays byte-parity with the family list;
    /// `normalizedNicknames` is positionally aligned with it (index i
    /// in one list corresponds to index i in the other).
    struct Entry: Equatable {
        let id: UUID
        /// `NepaliTextNormalizer.normalize(name)` — the `.exactName`
        /// tier's comparison surface (T-152).
        let normalizedName: String
        /// Per-entry normalized spellings, order preserved.
        let normalizedNicknames: [String]
        /// The stored spellings, order preserved (containment parity).
        let rawNicknames: [String]
    }

    /// Roster order preserved, one entry per contact.
    private(set) var entries: [Entry]

    /// Normalized exact nickname key → the ids that hold it, in roster
    /// order. Multi-valued by design: duplicates are real data (two
    /// relatives can share "बुवा"), never an overwrite. An id appears
    /// at most once per key even when the contact lists the same
    /// spelling twice. Keys that normalize to the empty string are not
    /// indexed — an empty key would make an empty query match people,
    /// and today's search treats an empty query as "no query".
    private(set) var idsByNickname: [String: [UUID]]

    /// Private O(1) backing for `entry(for:)` — the per-contact hot
    /// path the voice resolver walks (design-l2 §6.1); kept out of the
    /// published surface because it is exactly derivable from
    /// `entries`.
    private let entriesByID: [UUID: Entry]

    /// Builds the whole index in one pass: one `normalize` per name
    /// and per nickname (≤ 108 calls at the 12 × 8 production maximum,
    /// measured sub-millisecond — NFR-FCU-001's ≤ 20 ms build ceiling
    /// is asserted, including the 256-char worst case, by
    /// `FamilyContactIndexTests`).
    init(family: [FamilyContact]) {
        var builtEntries: [Entry] = []
        builtEntries.reserveCapacity(family.count)
        var builtByID: [UUID: Entry] = [:]
        builtByID.reserveCapacity(family.count)
        var builtMap: [String: [UUID]] = [:]

        for contact in family {
            // The projection is applied here too (it is idempotent for
            // stored data — the decoder and the editor already trimmed):
            // a directly-constructed model must not be able to smuggle
            // an untrimmed spelling into a key that containment can
            // never match.
            let rawNicknames = FamilyContact.normalizedNicknames(contact.nicknames)
            let entry = Entry(
                id: contact.id,
                normalizedName: NepaliTextNormalizer.normalize(contact.name),
                normalizedNicknames: rawNicknames.map { NepaliTextNormalizer.normalize($0) },
                rawNicknames: rawNicknames
            )
            builtEntries.append(entry)
            builtByID[entry.id] = entry

            for key in entry.normalizedNicknames where !key.isEmpty {
                var holders = builtMap[key] ?? []
                // Roster order, no duplicates per contact: appending
                // only on first sight keeps the array a set-like list
                // of DISTINCT holders in roster order.
                if !holders.contains(entry.id) {
                    holders.append(entry.id)
                }
                builtMap[key] = holders
            }
        }

        entries = builtEntries
        idsByNickname = builtMap
        entriesByID = builtByID
    }

    /// The empty index — `== FamilyContactIndex(family: [])`, the
    /// parity anchor: no nickname keys, no entries, every lookup empty.
    static let empty = FamilyContactIndex(family: [])

    /// The normalized nicknames of one contact, in stored order ([] for
    /// an unknown id). The voice resolver's near-miss walk reads this
    /// (T-153); returning the precomputed strings keeps the per-call
    /// cost to a dictionary hit.
    func nicknameEntries(for id: UUID) -> [String] {
        entry(for: id)?.normalizedNicknames ?? []
    }

    /// Who holds this EXACT nickname — one `idsByNickname` hit, no
    /// scan. `_ normalizedQuery` is the caller's contract, and the
    /// reason it is one: the search layer normalizes the query ONCE
    /// per keystroke/utterance (design-l2 §6.1) and exact matching is
    /// deliberately stricter than fuzzy matching (OD-2). Returns the
    /// ids in roster order; [] when nobody holds it.
    func exactNicknameHolders(_ normalizedQuery: String) -> [UUID] {
        idsByNickname[normalizedQuery] ?? []
    }

    /// One roster entry by contact id — the resolver's hot-path lookup
    /// (design-l2 §1.2); nil for an unknown id.
    func entry(for id: UUID) -> Entry? {
        entriesByID[id]
    }
}
