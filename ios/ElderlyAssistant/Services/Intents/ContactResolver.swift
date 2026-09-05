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
    private static let relationshipAnchors: [String: String] = [
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
        if let queryAnchor = anchor(in: normalizedQuery),
           let contactAnchor = anchor(in: relationship),
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
    private func anchor(in normalizedText: String) -> String? {
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
}
