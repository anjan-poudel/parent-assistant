import Foundation

/// Deterministic keyword route for VOICE-DRIVEN contact search
/// (voice-contact-search task, 2026-09-07): an utterance like
/// "मैयाको फोन नम्बर खोज", "maiya ko phone khoja" or "contact search
/// ram" opens the Phone screen (`CallView`) with the extracted name
/// already searching — zero-touch hands-free, mirroring the
/// `TopicPreAnswer` pattern (deterministic, runs BEFORE any model, no
/// IntentPrompt token growth — the prompt budget is pinned by
/// `IntentPromptTests`).
///
/// Design rules:
///  - Runs as its own `CommandRouter` stage AFTER the safety net and
///    the confirmation flow (emergency / med-ack / yes-no utterances
///    win exactly as before) and BEFORE the topic table, so a
///    greeting-prefixed search ("नमस्ते, मैयाको फोन नम्बर खोज") is a
///    search, never a small-talk reply — the same ordering convention
///    `TopicPreAnswer` documents for its own table.
///  - A direct-CALL veto runs FIRST: any utterance that reads as
///    "call/phone X" ("फोन नम्बर लगाऊ" — a `call` intent in the golden
///    corpus — "छोरालाई फोन गर") must keep the interpreter/block path.
///    The phone-word markers below would otherwise shadow it.
///  - Matching uses the router's substring convention for phrases and
///    whole-token convention for single words (mirrored private
///    helpers here — identical semantics to `CommandRouter`'s
///    `containsPhrase`/`containsToken`; keep in sync).
///  - Devanagari verbs are enumerated explicitly, exactly like the
///    router's own keyword tables. Swift substring matching works on
///    EXTENDED GRAPHEME CLUSTERS, which is stricter than a
///    letter-by-letter reader expects (finding of 2026-09-07): a
///    virama U+094D or vowel matra fuses into the preceding
///    consonant's cluster, so the bare stem occurs only where its
///    final consonant stands bare — standalone or word-final.
///    "खोज्नुहोस्" does NOT contain "खोज" (its ज carries a virama),
///    nor does "खोजेर" (जे) or "खोजिदिनुहोस्" (जि) — every
///    search-verb form is listed out in full below, in the marker
///    table AND the extraction drop table, the same convention the
///    router already uses for the "गर" family.
///  - Extraction strips trigger/drop words and the Devanagari
///    possessive/dative suffixes; the REMAINDER is the search query
///    ("मैयाको फोन नम्बर खोज" → "मैया"). A trailing kinship/anchor
///    word after a real name ("मैया दिदी") is dropped so the query
///    matches the name; a lone kinship query ("दिदी") is kept, and
///    `UnifiedContactSearch` resolves it through the relationship tier.
///    When nothing useful survives ("फोन नम्बर खोज"), the command
///    still opens the Phone screen — unprefilled.
///  - Safety nets never reach this type's markers in the router, but
///    the decision function itself stays conservative: no emergency,
///    no medication/reminder vocabulary anywhere in this table.
enum VoiceContactSearchRoute {

    enum Decision: Equatable {
        /// Not a contact-search utterance — route as before.
        case notSearch
        /// Open the Phone screen; `query` nil when the utterance was
        /// search-shaped but no query survived extraction.
        case openPhone(String?)
    }

    /// Upper bound on the extracted query — a name/number is short;
    /// anything longer is STT noise around the trigger words.
    private static let maxQueryLength = 60

    /// Decides what a transcript means for contact search. Mirrors the
    /// `TopicPreAnswer.match` entry-point style: lowercase + trim, then
    /// ordered checks, pure and unit-testable.
    static func decide(transcript raw: String) -> Decision {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .notSearch }

        // Veto first: a direct call request must never be swallowed by
        // the phone-word markers ("फोन नम्बर लगाऊ" is a CALL intent —
        // GoldenCorpus; "फोन नम्बर" alone would match its marker).
        if isDirectCallUtterance(text) { return .notSearch }

        // [YOUTUBE] (2026-09-08) YouTube-marked utterances belong to the
        // YouTube stage, which runs LATER in the ladder — "search
        // youtube for ram" and "युट्युबमा गीत खोज" are YouTube
        // searches, never contact searches. Without this veto the bare
        // "search"/"खोज" markers below would swallow them (opening the
        // Phone screen for "youtube ram") before the YouTube stage ever
        // ran.
        if isYouTubeUtterance(text) { return .notSearch }

        guard isSearchMarkerHit(text) else { return .notSearch }
        return .openPhone(extractQuery(from: text))
    }

    /// True when the utterance names YouTube — whole-token "youtube"
    /// (Latin) or Devanagari substring "युट्युब" (the locative
    /// "युट्युबमा" contains the bare stem).
    private static func isYouTubeUtterance(_ text: String) -> Bool {
        token("youtube", in: text) || text.contains("युट्युब")
    }

    // MARK: - Direct-call veto

    /// Call-shaped utterances checked BEFORE the search markers —
    /// enumerated Devanagari verb phrases (abugida containment rules,
    /// see file doc) + whole-word Latin. An utterance with any of these
    /// is a "call X" request and stays on the interpreter/block path.
    private static let directCallPhrases = [
        // फोन + verb (devanagari)
        "फोन गर", "फोनगर", "फोन गर्नुहोस्", "फोन गर्नुस्",
        "फोन गर्नुभयो", "फोन गर्ने", "फोन गरेर", "फोन गरिदेउ", "फोन गरिदिनु",
        "फोन लगाऊ", "फोन लगाउ", "फोन लगाउनुहोस्", "फोन लगाउनुस्",
        "फोन लगाइदेऊ", "फोन लगाइदेउ", "फोन लगाइदिनु",
        // नम्बर + verb — "फोन नम्बर लगाऊ" (golden corpus: call)
        "नम्बर लगाऊ", "नम्बर लगाउ", "नम्बर लगाइदेउ",
        "नंबर लगाऊ", "नंबर लगाउ",
        // कल + verb
        "कल गर", "कल गर्नुहोस्", "कल गर्नुस्", "कल गर्ने", "कल गरिदेउ",
        "कल लगाऊ", "कल लगाउ",
        // Video-call / app surfaces
        "भिडियो कल", "भिडियोकल", "भिडियो गर",
        // Romanized Nepali verb phrases (spaced STT output)
        "phone gar", "phone gara", "phone garna", "phone lagau", "phone lagaa",
        "call gar", "call gara", "video call", "phone call"
    ]
    private static let directCallTokens = ["call", "calls", "calling", "dial"]

    private static func isDirectCallUtterance(_ text: String) -> Bool {
        directCallPhrases.contains { text.contains($0) }
            || directCallTokens.contains { token($0, in: text) }
    }

    // MARK: - Search markers

    /// Marker = the utterance must clearly be asking for a contact /
    /// number search. Devanagari phrase markers are substrings; bare
    /// "खोज" fires only where the search verb ends the phrase — in a
    /// fused verb the virama/matra eats the bare ज (grapheme rule, file
    /// doc), so EVERY verb form gets its own entry below. A bare
    /// Devanagari "फोन"/"नम्बर" is deliberately NOT a marker —
    /// "मेरो फोन चार्ज…", "पहिलो नम्बर…" (everyday phone talk) must not
    /// open the search screen.
    private static let markerPhrases = [
        // Devanagari — explicit search phrasing
        "फोन नम्बर खोज", "फोन नंबर खोज", "फोन नं खोज",
        "फोन नम्बर", "फोननम्बर", "फोन नंबर",
        "फोन खोज", "फोनखोज",
        "नम्बर खोज", "नम्बरखोज", "नंबर खोज", "नंबरखोज", "नं खोज",
        "खोज",
        // Devanagari खोज verb forms — enumerated in full: Swift contains
        // works on grapheme clusters, and the virama/matra fuses into
        // the ज, so none of खोज्नुहोस् / खोजेर / खोजिदिनुहोस् actually
        // contains the bare "खोज" above (2026-09-07).
        "खोज्नुहोस्", "खोज्नुस्", "खोज्नुभयो", "खोज्ने", "खोज्न",
        "खोजेर", "खोजे",
        "खोजिदिनुहोस्", "खोजिदिनुस्", "खोजिदिनु", "खोजिदेउ", "खोजिदेऊ",
        // English / romanized — multi-word
        "phone number", "look up", "contact search", "find the number"
    ]
    /// Whole-word markers (Latin / romanized Nepali only — Devanagari
    /// bare words are too ambiguous, see above).
    private static let markerTokens = [
        "search", "searches", "searching", "searched",
        "find", "finds", "found", "looking",
        "contact", "contacts",
        "phone", "phones", "number", "numbers",
        "khoja", "khoj", "khojdinu"
    ]

    private static func isSearchMarkerHit(_ text: String) -> Bool {
        markerPhrases.contains { text.contains($0) }
            || markerTokens.contains { token($0, in: text) }
    }

    // MARK: - Query extraction

    /// Words that never belong in a search query. Devanagari verb
    /// families (गर-, खोज-) and question words are whole-token ONLY:
    /// containment would eat real names ("गर" ⊂ "गरिमा"), and the
    /// virama/matra fuses into the stem's final consonant, so fused
    /// verb forms do not even contain their bare stem (grapheme rule,
    /// file doc). फोन/नम्बर-containing tokens are dropped wholesale —
    /// they are the trigger morphemes, no real name contains them, and
    /// their cluster runs survive suffixes like -हरू, so containment is
    /// safe there.
    private static let devanagariExactDrops = [
        // verbs / politeness
        "गर्नुहोस्", "गर्नुस्", "गर्नुभयो", "गर्ने", "गर्न", "गर",
        "गरेर", "गरिदिनुहोस्", "गरिदेउ", "गरिदेऊ", "गरिदिनु",
        // खोज-family — same enumeration rule as गर-family above: the
        // virama/matra fuses into the ज, so a containment entry cannot
        // catch the fused forms (and the bare "खोज" entry in the old
        // containment list never matched them either — 2026-09-07).
        "खोज्नुहोस्", "खोज्नुस्", "खोज्नुभयो", "खोज्ने", "खोज्न",
        "खोजेर", "खोजे", "खोज", "खोजिदिनुहोस्", "खोजिदिनुस्",
        "खोजिदिनु", "खोजिदेउ", "खोजिदेऊ",
        "दिनुहोस्", "दिनुस्", "दिनु", "देउ", "देऊ", "नं",
        "कृपया", "हजुर", "मलाई", "मेरो", "मेरा", "मेरी",
        // small talk / question words (whole-token only)
        "नमस्ते", "नमस्कार", "सुप्रभात", "कति", "के", "हो", "छ", "छैन",
        "को", "की", "का", "लाई", "ले", "एउटा", "केही", "केहि", "अनि",
        "र", "यो", "त्यो"
    ]
    /// Romanized-Nepali / English drop words (whole-token).
    private static let latinExactDrops = [
        "a", "an", "the", "for", "of", "to", "in", "on", "at", "by",
        "from", "with", "and", "or", "me", "my", "mine", "i", "we",
        "our", "ours", "you", "your", "yours", "he", "him", "his",
        "she", "her", "hers", "it", "its", "they", "them", "their",
        "us", "do", "does", "did", "doing", "is", "are", "was", "were",
        "be", "been", "am", "can", "could", "will", "would", "shall",
        "should", "may", "might", "must", "want", "wanna", "need",
        "please", "ok", "okay", "up", "show", "shows", "look", "looks",
        "looking", "looked", "lookup", "list", "lists",
        "find", "finds", "found", "search", "searches", "searching",
        "searched", "contact", "contacts", "phone", "phones",
        "number", "numbers", "khoja", "khoj", "ko", "ka", "ke", "ki",
        "lai", "le", "gara", "garna", "garnu", "garnus", "gar",
        "kripaya", "namaste", "namaskar", "hello", "hi", "hey",
        "yo", "tyo", "please", "what", "who", "whose", "which", "when",
        "where", "why", "how"
    ]
    private static let devanagariContainmentDrops = ["फोन", "नम्बर", "नंबर"]
    /// Whole-token-only (khoja-family romanized); a Latin "find"-family
    /// containment would eat names ("findlay").
    private static let latinContainmentDrops = ["khoj"]

    /// Possessive / dative suffixes stripped from Devanagari tokens
    /// ("मैयाको" → "मैया") and the Latin "'s" possessive.
    private static let devanagariSuffixes = ["को", "की", "का", "लाई", "ले"]

    static func extractQuery(from raw: String) -> String? {
        var kept: [String] = []
        for piece in raw.components(separatedBy: .whitespacesAndNewlines) {
            var token = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            // Latin "'s" possessive BEFORE punctuation trimming —
            // otherwise the apostrophe is stripped as punctuation and
            // the "s" is left behind ("maiya's" → "maiyas").
            if token.hasSuffix("'s") || token.hasSuffix("’s") {
                token = String(token.dropLast(2))
            }
            for suffix in devanagariSuffixes
            where token.hasSuffix(suffix) && token.count > suffix.count + 1 {
                token = String(token.dropLast(suffix.count))
                break
            }
            token = token.trimmingCharacters(
                in: CharacterSet.punctuationCharacters.union(CharacterSet(charactersIn: "।॥"))
            )
            guard !token.isEmpty else { continue }
            if isDropToken(token) { continue }
            kept.append(token)
        }
        var query = NepaliTextNormalizer.normalize(kept.joined(separator: " "))
        // A trailing kinship/anchor word after a real name is address,
        // not identity: "मैया दिदी" searches "मैया". A LONE kinship
        // query stays — the relationship tier resolves "दिदी".
        let tokens = query.split(separator: " ").map(String.init)
        if tokens.count > 1,
           let last = tokens.last,
           ContactResolver.relationshipAnchors[last] != nil {
            query = NepaliTextNormalizer.normalize(tokens.dropLast().joined(separator: " "))
        }
        query = String(query.prefix(maxQueryLength))
        return query.isEmpty ? nil : query
    }

    private static func isDropToken(_ token: String) -> Bool {
        let devanagari = token.unicodeScalars.contains { $0.value >= 0x0900 && $0.value <= 0x097F }
        if devanagari {
            return devanagariExactDrops.contains(token)
                || devanagariContainmentDrops.contains { token.contains($0) }
        }
        return latinExactDrops.contains(token)
            || latinContainmentDrops.contains { token.contains($0) }
    }

    /// Whole-token match — identical semantics to
    /// `CommandRouter.containsToken` (split on whitespace + punctuation,
    /// exact equality), mirrored here so this type can never depend on
    /// router internals.
    private static func token(_ token: String, in text: String) -> Bool {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .contains { $0 == token }
    }
}
