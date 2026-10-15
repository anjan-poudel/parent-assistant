import Foundation

// MARK: - Medication acknowledgement resolution (C3, IF-6)
//
// [MED-ACK] The pure half of "the elder acknowledges intake in natural
// voice": where the shipped path selected `oldestPendingReminderEntryId()`
// — silently, by firing/pending order — this resolver decides WHICH
// pending reminder the elder just said they took, by what they said
// (FR-MSR-007), and refuses to guess when what they said does not
// identify exactly one (FR-MSR-008).
//
// THE CONTAINER CONTRACT: never record the wrong medication. Every
// `AckResolution` that can lead to a recording carries an `entryId` that
// is a member of the candidate set handed in; anything unresolved or
// ambiguous leaves as `.ambiguous` / `.unmatched` / `.nothingPending`
// and is settled — if at all — by the clarification walk (C4) and the
// shipped challenge sequence (FR-MSR-009), never here.
//
// PURITY (NFR-MSR-001): a total function of (utterance, candidate set).
// No clock reads (the candidates carry their times), no randomness, no
// I/O, no coordinator access, no LLM symbols, no network types. The
// resolver does not fire, record, speak or persist anything — it returns
// a value, and its caller (T-014) decides what that value means.
//
// ADMISSION IS UPSTREAM. The refusal-first denial guard and the shipped
// acknowledgement gate (`CommandRouter.isExplicitMedicationAcknowledgement`,
// design-l1 §7.1 steps 2–3) run before this function; a denial is never
// resolved here. Acknowledgement recognition is deliberately NOT
// duplicated in this file — the shipped `medicationAckPhrases` /
// `medicationAckTokens` lists remain the ONE acknowledgement vocabulary
// (design-l2 C3: "the resolver itself needs none"), and no second list
// is minted here. This file adds only the closed slot/meal word tables
// (design-l2 C3) that the shipped vocabulary does not carry.
//
// DEVANAGARI PIN (NFR-MSR-007): matching is Swift Character-cluster
// substring containment — the shipped convention — and stays that way. A
// key spelled one vowel sign short is a different cluster and does NOT
// match; that behaviour is regression-pinned by this suite and must not
// be "fixed" here.

// MARK: - Candidate (IF-7)

/// One pending reminder, as the resolver sees it (design-l1 §7.2).
///
/// Built by the coordinator's read seam (`medicationAckCandidates()`,
/// T-013) from the live schedule — one value per pending reminder. The
/// resolver never reads the schedule itself; this struct IS its world,
/// and the fixed `scheduledAt` / canonical-name / id order it produces
/// for walk outputs is derived from these fields alone.
struct MedicationAckCandidate: Equatable {
    /// The reminder's entry — the only thing a resolution may ever name.
    let entryId: UUID

    /// The reminder's resolved time; the fixed ordering's first key.
    let scheduledAt: Date

    /// `lastFiredAt != nil` — the reminder has rung. A simple
    /// acknowledgement with no further information refers to what rang
    /// (the accepted fired-preference, review-l1 n-1).
    let fired: Bool

    /// The dose's slot; nil for legacy-shape entries, which never match a
    /// slot word — no inference over their raw clock times.
    let slot: MedicationSlot?

    /// `MedicationVoiceVocabulary.voiceKeys(for: entry)` — canonical keys
    /// (name first, then purpose keys). These, and only these, are what
    /// the elder can name this candidate by.
    let voiceKeys: [String]

    /// The canonical medication name — the fixed ordering's tiebreak and
    /// the sanctioned copy's "did you mean X" noun. Not a matching key of
    /// its own: matching reads `voiceKeys`.
    let medicationName: String
}

// MARK: - Resolution (IF-6)

/// The four honest outcomes of one utterance (design-l1 §7.2, frozen).
///
/// Every `.resolved` entryId is a member of the candidate set passed to
/// `resolve(utterance:candidates:)` — there is no fifth "best guess" case,
/// by construction.
enum AckResolution: Equatable {
    /// What was said identifies exactly one pending reminder. The shipped
    /// safety sequence (FR-MSR-009) continues for this entry — nothing is
    /// recorded by this value; recording happens only after the challenge.
    case resolved(entryId: UUID)

    /// What was said does not identify exactly one reminder, and the
    /// honest candidates to walk are these, in the fixed order
    /// (`scheduledAt`, canonical name, id). Also carried when a named slot
    /// conflicts with every name-match (one of the two statements is
    /// wrong): the walk then has a single entry, and the sanctioned single
    /// form ("did you mean X?") is what settles it.
    case ambiguous(ordered: [UUID])

    /// Something was said that matches no pending entry (a slot the
    /// schedule does not cover). Carries the FULL ordered pending set so
    /// the caller can run the sanctioned fallback question over it.
    case unmatched(orderedPending: [UUID])

    /// Nothing is pending at all — a value, not an error (design-l2
    /// IF-7: the empty case is expressed by this case).
    case nothingPending
}

// MARK: - The closed vocabulary (design-l2 C3)

/// The resolver's closed vocabulary: the slot words and the meal words in
/// both shipped languages, matched as Character-cluster substrings of the
/// canonical utterance (the shipped convention; NFR-MSR-007).
///
/// The slot families MIRROR the scanner's word families
/// (`MedicationLabelParser.timeWordHours`): the house has ONE vocabulary,
/// not two inventions. The scanner maps a word to an hour; the resolver
/// maps the same word to the slot that hour belongs to under the pinned
/// hour table (m-3) — and a test pins the mirror relationship, so the two
/// tables cannot drift apart silently.
///
/// Meal words are RECOGNISED ONLY: the meal relation is context, never a
/// filter, never a discriminator, never a selection (OD-1 — meal is not a
/// clock; the named medication and slot are the strong signals).
enum MedicationAckVocabulary {

    /// `MedicationSlot` → the words that name it, ne + en (design-l2 C3).
    static let slotWords: [MedicationSlot: [String]] = [
        .morning: ["morning", "बिहान", "सकाळ"],
        .afternoon: ["afternoon", "midday", "noon", "दिउँसो"],
        .evening: ["evening", "night", "बेलुका", "राति"]
    ]

    /// `MealRelation` → the words that name it, ne + en (design-l2 C3).
    static let mealWords: [MealRelation: [String]] = [
        .beforeMeal: ["before meal", "before food", "before eating", "खानु अघि", "खाना अघि"],
        .afterMeal: ["after meal", "after food", "after eating", "खानु पछि", "खाना खाएपछि"]
    ]

    /// Character-cluster substring containment: does this key occur in the
    /// canonical utterance?
    ///
    /// The key is canonicalised on the way in (idempotent — the candidate
    /// keys arrive canonical per IF-7), and an EMPTY key matches nothing:
    /// `String.contains("")` is trivially true, and a candidate with an
    /// empty key must never claim every utterance. Matching is the shipped
    /// Swift `String.contains` on `Character` boundaries — the pinned
    /// Devanagari behaviour, reused as-is and never "corrected".
    static func containsKey(_ key: String, inCanonical text: String) -> Bool {
        let canonicalKey = MedicationVoiceVocabulary.canonical(key)
        guard !canonicalKey.isEmpty else { return false }
        return text.contains(canonicalKey)
    }

    /// The slots the canonical utterance names — zero, one, or (for an
    /// utterance that names several, "morning and evening") more than one.
    /// A set, built in `MedicationSlot.allCases` order: deterministic for
    /// any input.
    static func namedSlots(inCanonical text: String) -> Set<MedicationSlot> {
        var named: Set<MedicationSlot> = []
        for slot in MedicationSlot.allCases {
            guard let words = slotWords[slot] else { continue }
            if words.contains(where: { containsKey($0, inCanonical: text) }) {
                named.insert(slot)
            }
        }
        return named
    }

    /// The meal relation the canonical utterance carries, when it carries
    /// exactly one — nil when it carries none, and nil when it carries
    /// both ("before and after food" states no single relation). Context
    /// only: no caller of the resolver may branch on this value; the
    /// suite pins that resolution is identical with and without the meal
    /// words in an utterance.
    static func mealRelation(inCanonical text: String) -> MealRelation? {
        guard let beforeWords = mealWords[.beforeMeal],
              let afterWords = mealWords[.afterMeal] else { return nil }
        let before = beforeWords.contains(where: { containsKey($0, inCanonical: text) })
        let after = afterWords.contains(where: { containsKey($0, inCanonical: text) })
        if before && !after { return .beforeMeal }
        if after && !before { return .afterMeal }
        return nil
    }
}

// MARK: - The resolver (IF-6)

/// The pure acknowledgement resolver: one utterance + the pending
/// candidate set in, one honest `AckResolution` out (design-l1 §7.2's
/// algorithm, deterministic and conservative).
///
/// Resolution is NAME-FIRST, THEN SLOT, THEN the simple acknowledgement —
/// by what the elder said, never by firing order, pending order, recency
/// or the order of the array it was handed. The candidate order handed in
/// is the coordinator's canonical sort (T-013); this resolver never reads
/// it — it may only ever mention order in what it RETURNS, and it returns
/// the fixed order (`scheduledAt`, canonical name, id) for every walk
/// output.
enum MedicationAckResolver {

    /// Resolve one acknowledged utterance against the pending reminders.
    ///
    /// Precondition (upstream, not checked here): the utterance has passed
    /// the shipped denial guard and acknowledgement gate — a denial is
    /// never resolved, and an utterance that never reached the gate is
    /// never resolved either.
    ///
    /// - Empty candidate set ⇒ `.nothingPending`, whatever was said.
    /// - Name match(es) ⇒ narrowed by a named slot when one was said
    ///   (a slot that conflicts with every name-match is not trusted over
    ///   the name: the utterance is ambiguous and the walk asks).
    /// - No name, slot said ⇒ the pending entries in those slots; none
    ///   there ⇒ `.unmatched` (never a fall-through to another slot).
    /// - Neither ⇒ the simple acknowledgement resolves to what rang, or —
    ///   when nothing has rung — to the pending set itself, which is how
    ///   the single-pending case keeps working without a name.
    static func resolve(utterance: String,
                        candidates: [MedicationAckCandidate]) -> AckResolution {
        guard !candidates.isEmpty else { return .nothingPending }

        let text = MedicationVoiceVocabulary.canonical(utterance)
        let pending = fixedOrder(candidates)
        let slots = MedicationAckVocabulary.namedSlots(inCanonical: text)

        // 1. Name first — the elder said which medication.
        let named = pending.filter { candidate in
            candidate.voiceKeys.contains { key in
                MedicationAckVocabulary.containsKey(key, inCanonical: text)
            }
        }
        if !named.isEmpty {
            guard !slots.isEmpty else { return resolution(of: named) }
            let carrying = named.filter { candidate in
                guard let slot = candidate.slot else { return false }
                return slots.contains(slot)
            }
            guard !carrying.isEmpty else {
                // Conflict: the elder named a medication and a time that do
                // not go together, so one of the two statements is wrong.
                // Neither half is trusted over the other — the walk asks
                // (with the sanctioned form over the name-match set, a
                // single form when that set holds one entry).
                return .ambiguous(ordered: named.map(\.entryId))
            }
            return resolution(of: carrying)
        }

        // 2. Then slot — no name matched, but the elder said when.
        //    Legacy entries (slot nil) never match a slot word.
        if !slots.isEmpty {
            let inSlot = pending.filter { candidate in
                guard let slot = candidate.slot else { return false }
                return slots.contains(slot)
            }
            guard !inSlot.isEmpty else {
                return .unmatched(orderedPending: pending.map(\.entryId))
            }
            return resolution(of: inSlot)
        }

        // 3. Then a simple acknowledgement. "Taken" with no name and no
        //    slot refers to what rang (n-1); with nothing rung, to the
        //    pending set itself — the shipped single-pending behaviour,
        //    byte-identical when exactly one reminder is pending.
        let fired = pending.filter(\.fired)
        return resolution(of: fired.isEmpty ? pending : fired)
    }

    // MARK: - Internals

    /// One match resolves; several become the ordered walk candidates. A
    /// zero-length match set cannot occur (every call site filters to a
    /// non-empty set) and is answered honestly rather than by a guess.
    private static func resolution(of matched: [MedicationAckCandidate]) -> AckResolution {
        switch matched.count {
        case 0: return .nothingPending
        case 1: return .resolved(entryId: matched[0].entryId)
        default: return .ambiguous(ordered: matched.map(\.entryId))
        }
    }

    /// The fixed ordering every walk output uses, derived from candidate
    /// facts alone (never from the order handed in): `scheduledAt`, then
    /// the canonical medication name, then the entry id — all three
    /// fields compared, so the order of equal-time, equal-name candidates
    /// is still total and stable across calls.
    private static func fixedOrder(_ candidates: [MedicationAckCandidate]) -> [MedicationAckCandidate] {
        candidates.sorted { left, right in
            if left.scheduledAt != right.scheduledAt {
                return left.scheduledAt < right.scheduledAt
            }
            let leftName = MedicationVoiceVocabulary.canonical(left.medicationName)
            let rightName = MedicationVoiceVocabulary.canonical(right.medicationName)
            if leftName != rightName {
                return leftName < rightName
            }
            return left.entryId.uuidString < right.entryId.uuidString
        }
    }
}
