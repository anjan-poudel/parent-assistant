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
///    hazard — plan). The WAY/DIRECTIONS family ("बाटो लगाउँ", "बाटो
///    देखाऊ", "बाटो बताऊ", the रास्ता synonyms — 2026-09-14) covers the
///    request shape the transport verbs missed: asking FOR the way
///    instead of asking to be taken somewhere ("सिड्नी घरको बाटो लगाउँ"
///    fell through to the model before this). It fires standalone like
///    TAKE/DROP and passes through the same bare-verb gate: nothing
///    surviving extraction and no home word → not directions.
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
///    the query 0.6; accept 0.6, ambiguity margin 0.15. Under every
///    literal tier sits the transliteration tier (0.7 — see `score`):
///    a Devanagari query matched against a Latin candidate name
///    ("सिड्नी" ↔ "Sydney house" — the 2026-09-14 failure), and the same
///    variance inside one script ("सिड्नी" ↔ "सिडनी"). A top score with
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

    /// WAY/DIRECTIONS-request forms — "बाटो लगाउँ" (give me the way),
    /// "बाटो देखाऊ" (show me the way), "बाटो बताऊ" (tell me the way) and
    /// the रास्ता/रस्ता synonyms (2026-09-14: the reported "सिड्नी घरको
    /// बाटो लगाउँ" had no marker at all and fell through to the model).
    ///
    /// Every entry is the WHOLE collocation (way noun + request verb),
    /// enumerated in full like the tables above (grapheme rule): "बाटो
    /// लगाउ" is a grapheme-safe prefix of "बाटो लगाउनुहोस्" (उ is an
    /// independent vowel, it does not fuse into the नु), but the longer
    /// forms stay listed — same defensive style as the जाऊ/जाउ pairs.
    /// Bare "लगाउ"/"देखाऊ"/"बताऊ" are deliberately NOT markers: they are
    /// everyday verbs ("फोन लगाउ" = dial, "भात लगाउ" = serve rice), so
    /// the way NOUN is what anchors this family — a destination is never
    /// the way-word itself. Fused noun+verb spellings ("बाटोलगाउ") are
    /// listed too (STT drops the space), mirroring the contact route's
    /// fused entries.
    private static let wayRequestPhrases = [
        // बाटो + लगाउनु (give/apply — "give me the way")
        "बाटो लगाउँ", "बाटो लगाउ", "बाटो लगाऊ", "बाटो लगाउनुहोस्", "बाटो लगाउनुस्",
        "बाटो लगाइदिनुहोस्", "बाटो लगाइदिनुस्", "बाटो लगाइदिनु", "बाटो लगाइदेउ",
        "बाटोलगाउ", "बाटोलगाउँ", "बाटोलगाइदिनुहोस्",
        // बाटो + देखाउनु (show)
        "बाटो देखाऊ", "बाटो देखाउ", "बाटो देखाउनुहोस्", "बाटो देखाउनुस्",
        "बाटो देखाइदिनुहोस्", "बाटोदेखाउ",
        // बाटो + बताउनु (tell)
        "बाटो बताऊ", "बाटो बताउ", "बाटो बताउनुहोस्", "बाटो बताउनुस्", "बाटोबताउ",
        // रास्ता synonym (आ spelling) — same three verbs
        "रास्ता लगाउँ", "रास्ता लगाउ", "रास्ता लगाऊ", "रास्ता लगाउनुहोस्",
        "रास्ता लगाइदिनुहोस्", "रास्ता देखाऊ", "रास्ता देखाउ", "रास्ता देखाउनुहोस्",
        "रास्ता बताऊ", "रास्ता बताउ", "रास्ता बताउनुहोस्", "रास्तालगाउ",
        // रस्ता (अ spelling — STT wavers between आ and अ)
        "रस्ता लगाउ", "रस्ता देखाऊ", "रस्ता देखाउ", "रस्ता बताऊ",
        "रस्ता लगाउनुहोस्", "रस्ता देखाउनुहोस्", "रस्तालगाउ"
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

    /// Romanized-Nepali way requests ("bato lagau", "rasta dekhau") —
    /// same discipline as the Devanagari family: the way NOUN and a
    /// request VERB must both appear as whole tokens, so bare "lagau"
    /// ("phone lagau" = dial the phone) never fires on its own. Both the
    /// bato/rasta noun spellings STT produces are listed.
    private static let romanizedWayNouns = [
        "bato", "bata", "baato", "rasta", "rastaa", "raasta"
    ]
    private static let romanizedWayVerbs = [
        "lagau", "lagaa", "lagauu", "lagaun", "laganus", "lagaidinu",
        "dekhau", "dekhaau", "dekhaun", "dekhauu",
        "batau", "bataau", "bataun", "batauu"
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
        // WAY/DIRECTIONS family — fires standalone like TAKE/DROP. There
        // is no bare-verb hazard to gate here (the noun is part of every
        // phrase), and the no-destination rule lives in `decide`, so
        // "बाटो लगाउँ" alone still is not directions.
        if wayRequestPhrases.contains(where: { text.contains($0) }) { return true }
        if englishNavPhrases.contains(where: { text.contains($0) }) { return true }
        if romanizedVerbTokens.contains(where: { token($0, in: text) }) { return true }
        // Romanized way requests — noun AND verb, both as whole tokens.
        if romanizedWayNouns.contains(where: { token($0, in: text) }),
           romanizedWayVerbs.contains(where: { token($0, in: text) }) {
            return true
        }
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

    /// WAY-family drops: the way nouns themselves (a token that STARTS
    /// with one of these is never a destination name — "बाटो", "बाटोको",
    /// and the fused "बाटोलगाउँ" are all requests, not places) and the
    /// request verbs left standing after the noun is cut ("सिड्नी घरको
    /// बाटो लगाउँ" → "सिड्नी"). Whole-token, so real names survive.
    private static let wayNounTokens = ["बाटो", "रास्ता", "रस्ता"]
    private static let wayVerbDropTokens = [
        "लगाउँ", "लगाउ", "लगाऊ", "लगाउनुहोस्", "लगाउनुस्",
        "देखाऊ", "देखाउ", "देखाउनुहोस्", "देखाउनुस्", "देखाइदिनुहोस्",
        "बताऊ", "बताउ", "बताउनुहोस्", "बताउनुस्"
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
            // Exact verb/home-word match, any fused घर form (घरमा,
            // घरै…) — a token that starts with the word for "home" is
            // never a destination name — or a way noun / fused way
            // request (बाटो, बाटोको, बाटोलगाउँ) for the same reason.
            return verbDropTokens.contains(token)
                || wayVerbDropTokens.contains(token)
                || token.hasPrefix("घर")
                || wayNounTokens.contains { token.hasPrefix($0) }
        }
        return englishVerbDropTokens.contains(token)
            || romanizedVerbTokens.contains(token)
            || verbDropTokens.contains(token)
            || romanizedWayNouns.contains(token)
            || romanizedWayVerbs.contains(token)
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
    /// `ContactResolver.score` ladder (normalized both sides), plus the
    /// transliteration tier this route adds for cross-script names:
    ///  1.0 exact name, 0.9 shared relationship anchor, 0.8 containment,
    ///  0.7 transliteration (see `transliterationMatch`), 0.6 token
    ///  overlap ≥ half the query, else 0.
    /// The transliteration tier sits UNDER every literal tier on purpose:
    /// it is lossy (script folding plus an edit-distance fuzz), so a
    /// candidate that literally carries the query must always outrank one
    /// that merely sounds like it. 0.7 is above `acceptThreshold`, so a
    /// clean cross-script name ("सिड्नी" ↔ "Sydney house") resolves
    /// instead of falling into `.unknownPlace` — and since it is one
    /// score like any other, it takes part in the same ambiguity margin
    /// (a 0.7 name beside a 0.8 containment still asks).
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

        // Transliteration tier — last, so it can never outrank a literal
        // hit on another candidate, and below containment's 0.8.
        if transliterationMatch(normalizedQuery, name: name) { return 0.7 }
        return 0
    }

    // MARK: - Transliteration tier

    /// Whether EVERY token of the query finds a token in the candidate
    /// name that is the same word heard through another script or another
    /// STT run — the cross-script bridge ("सिड्नी" ↔ "Sydney house", the
    /// 2026-09-14 failure: a Latin-stored saved place the Devanagari
    /// utterance could never reach through normalization) and the
    /// spelling-variance bridge inside one script ("सिड्नी" ↔ "सिडनी").
    /// Whole-query coverage on purpose: a partial hit is not a name, so
    /// an unmatched token means no tier match at all.
    ///
    /// The repo's contact search deliberately refuses transliteration
    /// (`UnifiedContactSearch` / `NepaliTextNormalizer`: lossy folding
    /// would merge different people), and that rule stands for SEARCH.
    /// Here the stakes are a yes/no question the coordinator already
    /// asks, so the tier is fenced the repo's way: it ranks under every
    /// literal tier, and short tokens may not fuzz at all (below).
    private static func transliterationMatch(_ normalizedQuery: String,
                                             name: String) -> Bool {
        let queryTokens = latinForm(normalizedQuery).split(separator: " ").map(String.init)
        let nameTokens = Set(latinForm(name).split(separator: " ").map(String.init))
        guard !queryTokens.isEmpty, !nameTokens.isEmpty else { return false }
        return queryTokens.allSatisfy { queryToken in
            nameTokens.contains { withinEditTolerance(queryToken, $0) }
        }
    }

    /// Two Latin tokens are "the same word" when they are equal, or —
    /// only for tokens of five characters and up — within three edits
    /// AND at least half their characters in order. "sidni" ↔ "sydney"
    /// is exactly at that bound (3 edits, 0.50 similarity): the 'y'/'e'
    /// the Devanagari spelling has no letters for. Short tokens must be
    /// EQUAL: "rama" ↔ "raja" (राम/राज) is a single edit and they are
    /// different people — one edit on a four-letter name is a different
    /// name far more often than it is a spelling wobble, so the tier
    /// refuses to guess there at all.
    private static func withinEditTolerance(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard min(lhs.count, rhs.count) >= 5 else { return false }
        let distance = editDistance(lhs, rhs)
        guard distance <= 3 else { return false }
        let similarity = 1 - Double(distance) / Double(max(lhs.count, rhs.count))
        return similarity >= 0.5
    }

    /// Plain Levenshtein distance over characters. The tokens are names,
    /// so the O(n·m) table is the honest, obviously-correct form (no
    /// early-exit cleverness to get wrong).
    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for (i, lhsCharacter) in left.enumerated() {
            current[0] = i + 1
            for (j, rhsCharacter) in right.enumerated() {
                let substitution = previous[j] + (lhsCharacter == rhsCharacter ? 0 : 1)
                current[j + 1] = min(previous[j + 1] + 1,
                                     current[j] + 1,
                                     substitution)
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }

    /// Devanagari → Latin tables for the tier above, in the spelling
    /// NEPALI SPEAKERS THEMSELVES TYPE (not ISO 15919): long and short
    /// vowels collapse onto one letter (ई/ी → i, ऊ/ू → u, आ/ा → a)
    /// because STT wavers between the two lengths in the same word and
    /// the tier only has to survive an edit-distance comparison. Nukta
    /// variants degrade to the base consonant's sound ("ज़" → j). Lossy
    /// by construction — which is exactly why it ranks lowest.
    private static let devanagariConsonants: [Unicode.Scalar: String] = [
        "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n",
        "च": "ch", "छ": "chh", "ज": "j", "झ": "jh", "ञ": "n",
        "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n",
        "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n",
        "प": "p", "फ": "ph", "ब": "b", "भ": "bh", "म": "m",
        "य": "y", "र": "r", "ल": "l", "व": "v",
        "श": "sh", "ष": "sh", "स": "s", "ह": "h"
    ]
    private static let devanagariIndependentVowels: [Unicode.Scalar: String] = [
        "अ": "a", "आ": "a", "इ": "i", "ई": "i", "उ": "u", "ऊ": "u",
        "ऋ": "ri", "ए": "e", "ऐ": "ai", "ओ": "o", "औ": "au"
    ]
    private static let devanagariMatras: [Unicode.Scalar: String] = [
        "ा": "a", "ि": "i", "ी": "i", "ु": "u", "ू": "u",
        "ृ": "ri", "े": "e", "ै": "ai", "ो": "o", "ौ": "au"
    ]
    private static let devanagariVirama: Unicode.Scalar = "्"
    private static let devanagariNukta: Unicode.Scalar = "़"
    private static let devanagariAnusvara: Unicode.Scalar = "ं"
    private static let devanagariChandrabindu: Unicode.Scalar = "ँ"
    private static let devanagariVisarga: Unicode.Scalar = "ः"

    /// The Latin spelling of `text`: Devanagari transliterated, ASCII
    /// passed through, everything else a word break. Scalar-wise, not
    /// character-wise, so the virama/matra fusions the file doc describes
    /// are decoded rather than mangled. Used ONLY by the transliteration
    /// tier — never for storage, matching or display.
    private static func latinForm(_ text: String) -> String {
        var out = ""
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if let consonant = devanagariConsonants[scalar] {
                out += consonant
                let next = index + 1
                if next < scalars.count, scalars[next] == devanagariVirama {
                    index = next + 1              // conjunct: no inherent vowel
                    continue
                }
                if next < scalars.count, let matra = devanagariMatras[scalars[next]] {
                    out += matra
                    index = next + 1
                    continue
                }
                out += "a"                        // inherent vowel
                index = next
                continue
            }
            if let vowel = devanagariIndependentVowels[scalar] {
                out += vowel
                index += 1
                continue
            }
            if scalar == devanagariAnusvara || scalar == devanagariChandrabindu {
                out += "n"                        // nasalisation, not a letter
                index += 1
                continue
            }
            if scalar == devanagariVisarga {
                out += "h"
                index += 1
                continue
            }
            if scalar == devanagariVirama || scalar == devanagariNukta {
                index += 1                        // stray marks carry no sound
                continue
            }
            if scalar.value < 0x80,
               scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                out.unicodeScalars.append(scalar) // Latin/ASCII stays as written
            } else {
                out += " "
            }
            index += 1
        }
        return out.lowercased()
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
