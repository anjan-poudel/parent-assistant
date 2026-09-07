import Foundation

/// One place the voice navigation pipeline can drive to — the merged,
/// pre-filtered view the coordinator hands `DirectionsRoute` (directions
/// task, 2026-09-07). The coordinator builds these from saved places and
/// family contacts that HAVE an address; address-less candidates never
/// reach the decider (and the decider re-filters defensively anyway).
struct DirectionsCandidate: Equatable {
    enum Source: Equatable {
        case savedPlace
        case familyContact
    }

    /// The backing store's id — maps back to the coordinator's
    /// `SavedPlace` / `FamilyContact` for execution.
    let id: UUID
    let source: Source
    /// Display/match name — the saved place's name or the contact's name.
    let name: String
    /// Free-form address text (non-empty for every candidate).
    let address: String
    /// The contact's relationship ("छोरा", "son"…) — nil for places.
    /// Feeds the relationship-anchor scoring tier.
    let relationship: String?

    var target: DirectionsRoute.PlaceTarget {
        switch source {
        case .savedPlace: return .place(id)
        case .familyContact: return .familyContact(id)
        }
    }
}

/// Deterministic keyword route for VOICE-DRIVEN NAVIGATION (directions
/// task, 2026-09-07): an utterance like "मलाई घर लैजाऊ" (take me home),
/// "मैयाको घर लैजाऊ" (take me to Maiya's home) or "take me to the
/// hospital" resolves against the user's saved places + relatives'
/// addresses and starts navigation. Mirrors the `VoiceContactSearchRoute`
/// pattern: deterministic, runs BEFORE any model, no IntentPrompt token
/// growth (the prompt budget is pinned by `IntentPromptTests`).
///
/// Design rules:
///  - Runs as its own `CommandRouter` stage AFTER the safety net, the
///    confirmation flow AND the contact-search stage, and BEFORE the
///    topic table — a navigation request must never be answered as
///    small talk or eaten by a search marker.
///  - Markers are the TRANSPORT verbs, not the destinations. The
///    TAKE/DROP families ("लैजाऊ", "पुर्याउनुहोस्"…) fire on their own
///    ("अस्पताल लैजाऊ" = take me to the hospital); the GO family
///    ("जाऊँ", "जाऊ", "जानुहोस्", "जाने") fires ONLY when a home word
///    is also present ("घर जानुहोस्"). That gate keeps music and orders
///    out: "गीत बजाऊ" (play a song) contains जाऊ but no घर, so it never
///    reaches navigation. Bare "जान" is excluded entirely (जानकारी
///    hazard — plan).
///  - Devanagari verb forms are enumerated explicitly, exactly like the
///    router's keyword tables: Swift substring matching works on EXTENDED
///    GRAPHEME CLUSTERS, so a virama or matra fuses into the preceding
///    consonant ("खोज्नुहोस्" does not contain "खोज" — 2026-09-07
///    finding). Both जाऊ and जाउ spellings are listed (STT wavers).
///  - Vetoes run FIRST: call talk ("फोन लैजाऊ" = carry the phone),
///    phone-number search talk, and medication/reminder markers
///    ("दवाई लैजाऊ" = take the medicine) never launch navigation.
///  - Extraction reuses `VoiceContactSearchRoute.extractQuery`, then
///    post-cleans: drops transport-verb/home-word tokens, cuts fused
///    possessive-home junctions ("मैयाकोघर" → "मैया") and fused
///    directional suffixes (मा/तिर/सम्म — with guards so real names
///    like रमा survive). An empty remainder means the destination was
///    the BARE HOME ("घर लैजाऊ", "take me home") → `.defaultHome`; a
///    non-empty remainder is a NAME and goes through candidate scoring.
///    (A bare transport verb with no destination at all — "लैजाऊ"
///    alone — is not directions.)
///  - Scoring mirrors `ContactResolver`: exact normalized name 1.0 /
///    relationship-anchor 0.9 / containment 0.8 / token overlap ≥ half
///    the query 0.6; accept 0.6, ambiguity margin 0.15. A top score with
///    a rival inside the margin → `.ambiguous` (the coordinator asks
///    yes/no, never guessing a PLACE — the same rule that protects
///    persons). No candidate clears the bar → `.unknownPlace` (the
///    router speaks the honest "place not found" line).
enum DirectionsRoute {

    enum PlaceTarget: Equatable {
        /// The user's default home — "मलाई घर लैजाऊ" / "take me home".
        /// Resolution happens in the coordinator: no default home on
        /// file → honest `directions.noHome` fallback.
        case defaultHome
        /// A saved place, by id.
        case place(UUID)
        /// A family contact with an address, by id.
        case familyContact(UUID)
    }

    enum Decision: Equatable {
        /// Not a navigation request — route as before.
        case notDirections
        /// Drive to this target.
        case navigate(PlaceTarget)
        /// Directions-shaped but nothing matched — speak the honest
        /// "I couldn't find that place" line.
        case unknownPlace
        /// Two or more candidates too close to call — top first; the
        /// coordinator asks yes/no down the list instead of guessing.
        case ambiguous([DirectionsCandidate])
    }

    /// Upper bound on the destination query — a name is short; anything
    /// longer is STT noise around the trigger words (mirrors the search
    /// route's bound).
    private static let maxQueryLength = 60

    // MARK: - Decision

    /// Decides what a transcript means for navigation. `candidates` is
    /// the coordinator's merged list (saved places + family contacts
    /// WITH addresses). Pure and unit-testable.
    static func decide(transcript raw: String,
                       candidates: [DirectionsCandidate]) -> Decision {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .notDirections }

        // Veto first — call / phone-search / medication talk that
        // happens to carry a transport verb stays on its own path
        // ("फोन लैजाऊ" is about carrying a phone; "दवाई लैजाऊ" about
        // taking medicine — neither is a drive).
        if isVetoed(text) { return .notDirections }

        guard isNavigationShaped(text) else { return .notDirections }

        // Destination extraction: what survives is a NAME to match;
        // nothing surviving means the destination was the bare home.
        guard let query = extractDestination(from: text), !query.isEmpty else {
            return containsHomeWord(text) ? .navigate(.defaultHome) : .notDirections
        }
        return resolve(query: query, candidates: candidates)
    }

    // MARK: - Vetoes

    /// Medication/reminder vocabulary (mirrors `TopicPreAnswer`'s veto —
    /// same markers, same reason: "दवाई लैजाऊ" carries a transport verb
    /// but is dose talk, not navigation).
    private static let medicationMarkers = [
        "औषधि", "औषधी", "दवाई", "दबाइ", "दवाइ",
        "medicine", "medication", "pill", "dose",
        "reminder", "remind", "alarm",
        "रिमाइन्डर", "रिमाइन्ड", "अलार्म"
    ]

    /// Call-shaped phrases + whole-word call/phone tokens (mirrors
    /// `VoiceContactSearchRoute`'s veto; token matching keeps place
    /// names out of it — "कलंकी लैजाऊ" must not read as call talk).
    private static let callPhrases = [
        "फोन गर", "फोन गर्नुहोस्", "फोन गर्नुस्", "फोन गरिदेउ", "फोन गरिदिनु",
        "फोन लगाऊ", "फोन लगाउ", "फोन लगाउनुहोस्", "फोन लगाइदेउ", "फोन लगाइदिनु",
        "नम्बर लगाऊ", "नम्बर लगाउ", "नम्बर लगाइदेउ", "नंबर लगाऊ", "नंबर लगाउ",
        "कल गर", "कल गर्नुहोस्", "कल गर्नुस्", "कल गरिदेउ", "कल लगाऊ", "कल लगाउ",
        "भिडियो कल", "भिडियोकल", "भिडियो गर",
        "phone gar", "phone gara", "phone garna", "phone lagau", "phone lagaa",
        "call gar", "call gara", "video call", "phone call"
    ]
    private static let callTokens = [
        "call", "calls", "calling", "dial", "phone",
        "फोन", "नम्बर", "नंबर"
    ]

    /// Phone-search vocabulary — a number/contact search request is never
    /// navigation ("घरको फोन नम्बर खोज" asks for a number to call).
    private static let searchMarkers = [
        "खोज", "खोज्नुहोस्", "खोज्नुस्", "खोज्ने", "खोजेर", "खोजिदिनुहोस्",
        "search", "searches", "searching", "searched", "khoja", "khoj"
    ]

    /// Third-person dative tokens ("छोरालाई", "मैयालाई") — a लाई-marked
    /// noun that is NOT the speaker means PERSON TRANSPORT, not
    /// self-navigation: "छोरालाई स्कुल लैजाऊ" = take my son to school
    /// (an errand, interpreter business) vs "मलाई घर लैजाऊ" = take ME
    /// home (navigation). Only the speaker's own dative (मलाई/मलाइ) is
    /// navigation-shaped; anyone else's marks a carried person.
    private static func carriesThirdPersonDative(_ text: String) -> Bool {
        for token in tokens(in: text) where token.unicodeScalars.contains(where: { $0.value >= 0x0900 && $0.value <= 0x097F }) {
            if (token.hasSuffix("लाई") || token.hasSuffix("लाइ")),
               token != "मलाई", token != "मलाइ" {
                return true
            }
        }
        return false
    }

    private static func isVetoed(_ text: String) -> Bool {
        if medicationMarkers.contains(where: { text.contains($0) }) { return true }
        if callPhrases.contains(where: { text.contains($0) })
            || callTokens.contains(where: { token($0, in: text) }) { return true }
        if searchMarkers.contains(where: { text.contains($0) }) { return true }
        if carriesThirdPersonDative(text) { return true }
        return false
    }

    // MARK: - Shape markers

    /// Home words: the Devanagari घर token (or a fused घर form like
    /// घरमा — any token that starts with घर), the "को घर" / "कोघर"
    /// possessive junctions, and romanized ghar/home. A token that starts
    /// with घर is safe: navigation destinations are names, and no query
    /// worth driving to begins with the word for "home".
    private static func containsHomeWord(_ text: String) -> Bool {
        if text.contains("को घर") || text.contains("कोघर")
            || text.contains("काघर") || text.contains("कीघर") {
            return true
        }
        let tokens = tokens(in: text)
        return tokens.contains { token in
            token.hasPrefix("घर") || token == "ghar" || token == "ghara" || token == "home"
        }
    }

    /// TAKE/DROP transport verbs — Devanagari substring markers that fire
    /// on their own ("अस्पताल लैजाऊ" = take me to the hospital). Every
    /// form is enumerated in full (grapheme rule, file doc); both the ऊ
    /// and उ spellings of the jaau ending appear (STT wavers between
    /// जाऊ and जाउ).
    private static let takeDropVerbForms = [
        // लैजानु (to take [someone]) family
        "लैजाऊ", "लैजाउ", "लैजानुहोस्", "लैजानुस्", "लैजाने",
        "लैजाइदिनुहोस्", "लैजाइदिनुस्", "लैजाइदिनु", "लैजाइदेउ", "लैजाइदेऊ",
        // पुर्याउनु (to drop [someone] off) family
        "पुर्याउनुहोस्", "पुर्याउनुस्", "पुर्याउने",
        "पुर्याइदिनुहोस्", "पुर्याइदिनुस्", "पुर्याइदिनु", "पुर्याइदेउ", "पुर्याइदेऊ",
        // लगिदिनु (to take [someone] back/drop home) family
        "लगिदिनुहोस्", "लगिदिनुस्", "लगिदिनु", "लगिदेउ", "लगिदेऊ"
    ]

    /// GO-family forms — "जाऊँ"/"जाऊ"/"जाउ"/"जानुहोस्"/"जानुस्"/"जाने".
    /// These fire ONLY when a home word is also present ("घर जानुहोस्",
    /// "घर जाने"); standalone they are narration or other business
    /// ("गीत बजाऊ" is a music request — जाऊ without घर). Bare "जान" is
    /// excluded everywhere (जानकारी hazard, plan).
    private static let goVerbForms = [
        "जाऊँ", "जाऊ", "जाउ", "जानुहोस्", "जानुस्", "जाने"
    ]

    /// Romanized-Nepali transport verbs — whole-token (Latin-script STT
    /// renders Nepali requests as "ghar laija", "ghar jaau"). Home words
    /// are deliberately NOT here: the GO family needs its Devanagari gate
    /// logic to also work in Latin ("म घर छु" as "ma ghar chu" must not
    /// fire), so ghar only fires combined with one of these verb tokens
    /// or an English marker phrase.
    private static let romanizedVerbTokens = [
        "laija", "laijau", "laijaa", "laijanu", "laijanus", "laijane",
        "laijaideu", "laijaideuu", "lija", "lijau", "lijaideu",
        "purya", "puryau", "puryaunu", "puryaidinu", "puryaideu",
        "jaau", "jaaun", "jaan", "janu", "janus", "jane"
    ]

    /// English navigation phrases (substring). Deliberately narrow: bare
    /// "go to" is NOT a marker ("go to sleep" is not a drive) — only
    /// clearly transport-shaped phrasing qualifies.
    private static let englishNavPhrases = [
        "take me home", "take me to", "take me", "bring me home",
        "navigate home", "navigate to", "go home", "get me home",
        "drive me home", "drive me to", "drive home",
        "directions to", "route to", "drop me at"
    ]

    private static func isNavigationShaped(_ text: String) -> Bool {
        if takeDropVerbForms.contains(where: { text.contains($0) }) { return true }
        if englishNavPhrases.contains(where: { text.contains($0) }) { return true }
        if romanizedVerbTokens.contains(where: { token($0, in: text) }) { return true }
        // GO family — only with a home word present.
        if containsHomeWord(text),
           goVerbForms.contains(where: { text.contains($0) }) {
            return true
        }
        return false
    }

    // MARK: - Destination extraction

    /// Whole-token drops: every transport-verb form (marker tables
    /// mirrored) plus the home/direction words. English transport words
    /// have their own table below (whole-token only — containment would
    /// eat real names, e.g. "route" ⊂ "router").
    private static let verbDropTokens = takeDropVerbForms + goVerbForms + [
        "घर", "ghar", "ghara", "home", "house", "तिर", "सम्म"
    ]

    private static let englishVerbDropTokens = [
        "take", "takes", "took", "taken", "taking",
        "bring", "brings", "brought",
        "navigate", "navigation", "navigating",
        "directions", "route", "drive", "drives", "driving",
        "drop", "go", "going"
    ]

    /// Fused directional suffixes stripped from the END of a Devanagari
    /// token ("अस्पतालतिर" → "अस्पताल", "बजारसम्म" → "बजार"). The मा
    /// guard (stem must be ≥ 5 characters) keeps real names out of the
    /// knife: रमा/कमला are names, not "रम् + मा".
    private static let directionalSuffixes = ["तिर", "सम्म", "मा"]

    /// Fused possessive-home junctions cut from the MIDDLE of a
    /// Devanagari token ("मैयाकोघर" → "मैया") — only when followed by
    /// घर, so real place names ("महाकोट") survive.
    private static let possessiveHomeJunctions = ["कोघर", "काघर", "कीघर"]

    /// Extracts the destination NAME from a navigation utterance.
    ///
    /// Reuses `VoiceContactSearchRoute.extractQuery` (possessive/dative
    /// suffix stripping, drop tables), then post-cleans what survived:
    /// transport-verb and home-word tokens are dropped, fused
    /// possessive-home junctions are cut, fused directional suffixes are
    /// stripped. Returns nil when nothing survives — the caller maps
    /// that to the bare-home case.
    static func extractDestination(from raw: String) -> String? {
        let base = VoiceContactSearchRoute.extractQuery(from: raw) ?? ""
        let tokens = base.split(separator: " ").map(String.init)
        var kept: [String] = []
        for var token in tokens {
            let devanagari = token.unicodeScalars.contains { $0.value >= 0x0900 && $0.value <= 0x097F }
            if devanagari {
                // Cut fused possessive-home junctions from the middle.
                if let junction = possessiveHomeJunctions.first(where: { token.contains($0) }),
                   let range = token.range(of: junction) {
                    token = String(token[..<range.lowerBound])
                }
                // Strip fused directional suffixes from the end.
                for suffix in directionalSuffixes
                where token.hasSuffix(suffix) && token.count > suffix.count + 4 {
                    token = String(token.dropLast(suffix.count))
                    break
                }
            }
            if isDropToken(token, devanagari: devanagari) { continue }
            if !token.isEmpty { kept.append(token) }
        }
        var query = NepaliTextNormalizer.normalize(kept.joined(separator: " "))
        query = String(query.prefix(maxQueryLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
    }

    private static func isDropToken(_ token: String, devanagari: Bool) -> Bool {
        if token.isEmpty { return true }
        if devanagari {
            // Exact verb/home-word match, or any fused घर form (घरमा,
            // घरै…) — a token that starts with the word for "home" is
            // never a destination name.
            return verbDropTokens.contains(token) || token.hasPrefix("घर")
        }
        return englishVerbDropTokens.contains(token)
            || romanizedVerbTokens.contains(token)
            || verbDropTokens.contains(token)
    }

    // MARK: - Candidate resolution

    /// Resolves a destination NAME against the candidates. Mirrors
    /// `ContactResolver` exactly: same tiers, same thresholds.
    private static func resolve(query rawQuery: String,
                                candidates: [DirectionsCandidate]) -> Decision {
        let normalized = NepaliTextNormalizer.normalize(rawQuery)
        guard !normalized.isEmpty else { return .notDirections }
        let stripped = NepaliTextNormalizer.strippingHonorifics(normalized)
        let variants = stripped == normalized ? [normalized] : [normalized, stripped]

        // Address-less candidates are excluded defensively — the
        // coordinator filters, but a place with no drivable address must
        // never win a route (its address text is what gets geocoded).
        let scored: [(candidate: DirectionsCandidate, score: Double)] = candidates.compactMap { candidate in
            guard !candidate.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let best = variants.map { score($0, against: candidate) }.max() ?? 0
            return best >= acceptThreshold ? (candidate, best) : nil
        }
        guard let top = scored.max(by: { $0.score < $1.score }) else { return .unknownPlace }

        let rivals = scored.filter {
            $0.candidate.id != top.candidate.id
                && top.score - $0.score < ambiguityMargin
        }
        if !rivals.isEmpty {
            // Top first — the coordinator asks about it first.
            let ordered = ([top] + rivals).sorted { $0.score > $1.score }
            return .ambiguous(ordered.map(\.candidate))
        }
        return .navigate(top.candidate.target)
    }

    private static let acceptThreshold = 0.6
    private static let ambiguityMargin = 0.15

    /// Scores one candidate against the normalized query — the exact
    /// `ContactResolver.score` ladder (normalized both sides):
    ///  1.0 exact name, 0.9 shared relationship anchor, 0.8 containment,
    ///  0.6 token overlap ≥ half the query, else 0.
    private static func score(_ normalizedQuery: String,
                              against candidate: DirectionsCandidate) -> Double {
        let name = NepaliTextNormalizer.normalize(candidate.name)
        let relationship = candidate.relationship.map(NepaliTextNormalizer.normalize) ?? ""

        if !name.isEmpty && normalizedQuery == name { return 1.0 }

        // Relationship anchor match — "छोरा"/"son"/"didi" resolve to the
        // contact whose stored relationship shares the anchor.
        if let queryAnchor = relationshipAnchor(in: normalizedQuery),
           let contactAnchor = relationshipAnchor(in: relationship),
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
    /// shared vocabulary with `ContactResolver`/`UnifiedContactSearch`
    /// (one table drives every surface).
    private static func relationshipAnchor(in normalizedText: String) -> String? {
        let tokens = normalizedText.split(separator: " ").map(String.init)
        for token in tokens {
            if let anchor = ContactResolver.relationshipAnchors[token] { return anchor }
        }
        for (word, anchor) in ContactResolver.relationshipAnchors
        where normalizedText.contains(word) {
            return anchor
        }
        return nil
    }

    // MARK: - Token helper

    /// Whole-token match — same semantics as
    /// `CommandRouter.containsToken` (split on whitespace + punctuation,
    /// exact equality), mirrored here so this type can never depend on
    /// router internals.
    private static func token(_ token: String, in text: String) -> Bool {
        tokens(in: text).contains(token)
    }

    private static func tokens(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { !$0.isEmpty }
    }
}
