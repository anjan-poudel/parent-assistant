import Foundation

/// Outcome of resolving a spoken contact reference against family contacts.
enum ContactMatch: Equatable {
    /// Nothing plausible — caller speaks "contact not found".
    case none
    /// Exactly one plausible contact (score ≥ accept threshold, no rival).
    case one(FamilyContact)
    /// Two or more contacts are too close to call — caller disambiguates
    /// by speech rather than guessing (spec 2026-09-05 §6.1: guessing a
    /// PERSON is the worst resolution error).
    case ambiguous([FamilyContact])
}

/// Resolves the `contact` slot (a name OR a relationship, in either script)
/// against family contacts. Deterministic — no LLM anywhere near the
/// decision of WHO gets called (spec §6: "LLM proposes, code disposes").
///
/// Replaces `AppCoordinator.matchContact`'s bare substring check, which
/// had no scoring, no ambiguity concept, and matched relationships only by
/// luck ("छोरा" worked only if the contact's relationship field literally
/// contained it).
///
/// Scoring (normalized both sides via `NepaliTextNormalizer`):
///  - exact normalized name match            1.0
///  - relationship-word match                0.9 (छोरा/son/didi… → relationship field)
///  - one side contains the other            0.8 ("सुनिता" ↔ "सुनिता आचार्य")
///  - token overlap ≥ half of the query      0.6
/// Accept threshold 0.6. A rival within 0.15 of the top score → ambiguous.
final class ContactResolver {

    /// Relationship vocabulary → normalized relationship-field words.
    /// Both scripts map onto the same English anchor words so a contact
    /// stored as relationship "छोरा" matches a query of "son" and vice
    /// versa — matching runs on the ANCHORS, not the raw strings.
    ///
    /// Shared with `UnifiedContactSearch` (2026-09-06): the phone
    /// search's relationship tier anchors family matches on this same
    /// table, so one relationship vocabulary drives both surfaces
    /// instead of two copies that could drift apart.
    static let relationshipAnchors: [String: String] = [
        // Nepali
        "छोरा": "son", "छोरी": "daughter",
        "आमा": "mother", "बुबा": "father", "बाबु": "son",
        "हजुरआमा": "grandmother", "हजुरबुबा": "grandfather",
        "नाति": "grandson", "नातिनी": "granddaughter",
        "दिदी": "sister", "बहिनी": "sister",
        "दाइ": "brother", "दाई": "brother", "भाइ": "brother",
        "श्रीमान": "husband", "श्रीमती": "wife",
        "सासु": "mother-in-law", "ससुरा": "father-in-law",
        // English
        "son": "son", "daughter": "daughter",
        "mother": "mother", "mom": "mother", "mum": "mother", "aama": "mother",
        "father": "father", "dad": "father", "baba": "father", "buwa": "father",
        "grandmother": "grandmother", "grandfather": "grandfather",
        "grandson": "grandson", "granddaughter": "granddaughter",
        "sister": "sister", "didi": "sister", "brother": "brother", "dai": "brother",
        "husband": "husband", "wife": "wife"
    ]

    private static let acceptThreshold = 0.6
    private static let ambiguityMargin = 0.15

    private let contactsProvider: () -> [FamilyContact]

    init(contactsProvider: @escaping () -> [FamilyContact]) {
        self.contactsProvider = contactsProvider
    }

    func resolve(_ query: String?) -> ContactMatch {
        guard let query else { return .none }
        let normalized = NepaliTextNormalizer.normalize(query)
        guard !normalized.isEmpty else { return .none }
        let stripped = NepaliTextNormalizer.strippingHonorifics(normalized)
        let variants = stripped == normalized ? [normalized] : [normalized, stripped]

        let scored: [(contact: FamilyContact, score: Double)] = contactsProvider().compactMap { contact in
            let best = variants.map { score($0, against: contact) }.max() ?? 0
            return best >= Self.acceptThreshold ? (contact, best) : nil
        }
        guard let top = scored.max(by: { $0.score < $1.score }) else { return .none }

        let rivals = scored.filter { $0.contact.id != top.contact.id
            && top.score - $0.score < Self.ambiguityMargin }
        if !rivals.isEmpty {
            return .ambiguous(([top.contact] + rivals.map(\.contact)))
        }
        return .one(top.contact)
    }

    // MARK: - Scoring

    private func score(_ normalizedQuery: String, against contact: FamilyContact) -> Double {
        let name = NepaliTextNormalizer.normalize(contact.name)
        let relationship = NepaliTextNormalizer.normalize(contact.relationship)

        if !name.isEmpty && normalizedQuery == name { return 1.0 }

        // Relationship match: query anchors AND the contact's stored
        // relationship anchors must share a word. Raw containment is not
        // enough — "बहिनी" and "दिदी" are both "sister" but share no
        // substring.
        if let queryAnchor = Self.relationshipAnchor(in: normalizedQuery),
           let contactAnchor = Self.relationshipAnchor(in: relationship),
           queryAnchor == contactAnchor {
            return 0.9
        }

        if !name.isEmpty, name.contains(normalizedQuery) || normalizedQuery.contains(name) {
            return 0.8
        }

        // Token overlap — "सुनिता आचार्य" vs "आचार्य" style partials.
        let queryTokens = Set(normalizedQuery.split(separator: " "))
        let nameTokens = Set(name.split(separator: " "))
        if !queryTokens.isEmpty {
            let overlap = queryTokens.intersection(nameTokens).count
            if overlap > 0, Double(overlap) >= Double(queryTokens.count) / 2.0 {
                return 0.6
            }
        }
        return 0
    }

    /// The first relationship anchor word found in `normalizedText` —
    /// checked token-wise AND as containment for compounds like
    /// "मेरो छोरालाई" (my son, with the dative suffix attached).
    /// Internal so `UnifiedContactSearch` can tier family matches on
    /// the same anchors.
    static func relationshipAnchor(in normalizedText: String) -> String? {
        let tokens = normalizedText.split(separator: " ").map(String.init)
        for token in tokens {
            if let anchor = Self.relationshipAnchors[token] { return anchor }
        }
        for (word, anchor) in Self.relationshipAnchors
        where normalizedText.contains(word) {
            return anchor
        }
        return nil
    }

    // MARK: - Near-miss proposal

    /// Scalar edit budget for the near-miss band: a normalized form two
    /// scalar edits or fewer from a contact's name (a matra variant
    /// "सुनीता"/"सुनिता" is ONE edit; "स्यानु"/"सानु" — the virama-y
    /// romanization artefact — is TWO). Deliberately small: anything
    /// larger stops being a "mangled spelling" and becomes a guess.
    private static let nearMissEditBudget = 2
    /// A query longer than this carries no name signal worth proposing
    /// against (STT noise around trigger words).
    private static let nearMissMaxQueryScalars = 40

    /// A single near-miss family contact for a query that `resolve`
    /// REJECTED — the coordinator calls this only on `.none`, so the
    /// accept bands always win. Same no-guess discipline as `resolve`:
    /// a proposal requires EXACTLY ONE contact within the budget (two
    /// rivals in the band is the same ambiguity `resolve` refuses to
    /// call, and the caller then stays on its honest not-found line).
    /// No proposal for a query with no signal at all — empty after
    /// normalization, or so long it cannot be a name.
    func nearMiss(_ query: String?) -> FamilyContact? {
        guard let query else { return nil }
        let normalized = NepaliTextNormalizer.normalize(query)
        let scalarCount = normalized.unicodeScalars.count
        guard !normalized.isEmpty,
              scalarCount <= Self.nearMissMaxQueryScalars else { return nil }
        let stripped = NepaliTextNormalizer.strippingHonorifics(normalized)
        let variants = stripped == normalized ? [normalized] : [normalized, stripped]

        var withinBudget: [FamilyContact] = []
        for contact in contactsProvider() {
            let name = NepaliTextNormalizer.normalize(contact.name)
            guard !name.isEmpty else { continue }
            let best = variants
                .map { Self.editDistance($0, name) }
                .min() ?? Int.max
            if best <= Self.nearMissEditBudget { withinBudget.append(contact) }
        }
        return withinBudget.count == 1 ? withinBudget[0] : nil
    }

    /// Levenshtein distance over Unicode scalars with an early exit
    /// once the near-miss budget is exceeded — the budget is tiny, so
    /// most comparisons bail out in one row.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let s1 = Array(a.unicodeScalars)
        let s2 = Array(b.unicodeScalars)
        if s1.isEmpty { return s2.count }
        if s2.isEmpty { return s1.count }
        if abs(s1.count - s2.count) > nearMissEditBudget { return nearMissEditBudget + 1 }

        var previous = Array(0...s2.count)
        var current = [Int](repeating: 0, count: s2.count + 1)
        for i in 1...s1.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...s2.count {
                let cost = s1[i - 1] == s2[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1,
                                 min(current[j - 1] + 1, previous[j - 1] + cost))
                rowMin = min(rowMin, current[j])
            }
            if rowMin > nearMissEditBudget { return nearMissEditBudget + 1 }
            swap(&previous, &current)
        }
        return previous[s2.count]
    }
}
