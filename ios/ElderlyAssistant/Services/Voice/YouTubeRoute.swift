import Foundation

/// Deterministic keyword route for VOICE-DRIVEN YOUTUBE (youtube-plugin
/// task, 2026-09-08): an utterance like "play bhajan on youtube",
/// "youtube news", "search youtube for old songs", "युट्युबमा गीत
/// चलाऊ" or "युट्युबमा रामायण खोज" extracts the query and lets the
/// router's YouTube stage search + play the top result (with a Data API
/// key) or open the YouTube search deeplink (without one — the accepted
/// search-only MVP). Same deterministic pattern as
/// `VoiceContactSearchRoute`: no model, no IntentPrompt tokens (the
/// prompt budget is pinned by `IntentPromptTests`).
///
/// Design rules:
///  - Runs as its own `CommandRouter` stage AFTER the safety net +
///    confirmation flow + contact search + directions + alarms/timers
///    (emergency / med-ack / yes-no / phone-search / navigation /
///    alarm-timer utterances win exactly as before) and BEFORE the
///    topic table, so a greeting-prefixed request ("नमस्ते, युट्युबमा
///    भजन चलाऊ") is a command, never small talk.
///  - Marker-gated like `AlarmTimerCommandParser`: a bare "play" with
///    no YouTube word never fires ("play some music" falls through to
///    the interpreter/topic ladder exactly as before). The YouTube word
///    plus a play/search verb — or a leading "youtube <X>" — is the
///    gate, so narration ("i watched youtube yesterday") and questions
///    about YouTube itself ("what is youtube") stay off this stage.
///  - The query is the non-marker remainder ("युट्युबमा गीत चलाऊ" →
///    "गीत"; "search youtube for old songs" → "old songs"). When
///    nothing survives extraction the utterance is NOT YouTube business
///    and falls through.
///  - Devanagari verbs are enumerated explicitly, exactly like the
///    router's own keyword tables (grapheme-cluster rule of
///    2026-09-07: a virama or matra fuses into the stem's final
///    consonant, so "चलाउनुहोस्" does NOT contain "चलाऊ" — every verb
///    form gets its own entry below).
///  - Ordering note: `VoiceContactSearchRoute` (which runs EARLIER in
///    the ladder) carries a matching YouTube veto — "search youtube for
///    ram" and "युट्युबमा गीत खोज" must reach THIS stage, never open
///    the Phone screen.
enum YouTubeRoute {

    enum Decision: Equatable {
        /// Not a YouTube request — route as before.
        case notYouTube
        /// Search/play this on YouTube. The extracted non-marker query.
        case play(String)
    }

    /// Upper bound on the extracted query — a video search is a phrase
    /// ("भजन गीत रामायण"), longer than a contact name but still short;
    /// anything longer is STT noise around the trigger words.
    private static let maxQueryLength = 100

    /// Decides what a transcript means for YouTube. Mirrors the
    /// `VoiceContactSearchRoute.decide` entry-point style: lowercase +
    /// trim, then ordered checks, pure and unit-testable.
    static func decide(transcript raw: String) -> Decision {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .notYouTube }

        guard isYouTubeMarked(text) else { return .notYouTube }
        guard let query = extractQuery(from: text) else { return .notYouTube }
        return .play(query)
    }

    // MARK: - Marker gate

    /// English play-family verbs (whole-token — a containment match
    /// would eat "playlist", "players").
    private static let englishPlayTokens = ["play", "plays", "playing", "played"]

    /// English search phrasings (substring).
    private static let englishSearchPhrases = [
        "search youtube", "search on youtube", "search in youtube"
    ]

    /// Nepali play-family verbs (substring on the lowercased text; the
    /// grapheme rule, file doc, forces full enumeration — चलाऊ and
    /// चलाउनुहोस् share no fused stem). बजाऊ-family included: "गीत
    /// बजाऊ" is the natural Nepali phrasing for playing music.
    private static let nepaliPlayMarkers = [
        "चलाऊ", "चलाउ", "चलाउनुहोस्", "चलाउनुस्",
        "चलाइदिनुहोस्", "चलाइदिनुस्", "चलाइदिनु", "चलाइदेऊ", "चलाइदेउ",
        "बजाऊ", "बजाउ", "बजाउनुहोस्", "बजाउनुस्",
        "बजाइदिनुहोस्", "बजाइदिनुस्", "बजाइदिनु", "बजाइदेऊ", "बजाइदेउ"
    ]

    /// Nepali search-family verbs — the same full enumeration the
    /// contact-search route keeps (खोज्नुहोस् does NOT contain bare
    /// खोज; the virama fuses into the ज).
    private static let nepaliSearchMarkers = [
        "खोज", "खोज्नुहोस्", "खोज्नुस्", "खोज्नुभयो", "खोज्ने", "खोज्न",
        "खोजेर", "खोजे",
        "खोजिदिनुहोस्", "खोजिदिनुस्", "खोजिदिनु", "खोजिदेउ", "खोजिदेऊ"
    ]

    /// True when the utterance is clearly a YouTube request. The YouTube
    /// word alone is NOT enough (narration/questions about the site must
    /// not fire the stage): English needs a play verb, a "search
    /// youtube"-shape phrase, or a LEADING "youtube <X>"; Nepali needs a
    /// play/search verb next to युट्युब.
    private static func isYouTubeMarked(_ text: String) -> Bool {
        let hasEnglish = token("youtube", in: text)
        let hasNepali = text.contains("युट्युब")
        guard hasEnglish || hasNepali else { return false }

        if hasEnglish {
            if let first = firstToken(in: text), first == "youtube" { return true }
            if englishPlayTokens.contains(where: { token($0, in: text) }) { return true }
            if englishSearchPhrases.contains(where: { text.contains($0) }) { return true }
        }
        if hasNepali {
            if nepaliPlayMarkers.contains(where: { text.contains($0) }) { return true }
            if nepaliSearchMarkers.contains(where: { text.contains($0) }) { return true }
        }
        return false
    }

    // MARK: - Query extraction

    /// Words that never belong in a YouTube query — trigger morphemes,
    /// prepositions and pronouns. Whole-token only (a containment "for"
    /// would eat "foreigner"; a containment "play" would eat "playlist").
    private static let latinDrops = [
        "play", "plays", "playing", "played",
        "youtube", "on", "in", "for", "the", "a", "an", "to", "of",
        "and", "or", "please", "me", "my", "some", "that", "this",
        "from", "with", "search", "searches", "searching", "searched"
    ]

    /// Devanagari trigger/particle words — the verb families and polite
    /// fillers, whole-token only (containment would eat real queries;
    /// "गर" ⊂ "गरिमा").
    private static let devanagariDrops = [
        // play verbs
        "चलाऊ", "चलाउ", "चलाउनुहोस्", "चलाउनुस्",
        "चलाइदिनुहोस्", "चलाइदिनुस्", "चलाइदिनु", "चलाइदेऊ", "चलाइदेउ",
        "बजाऊ", "बजाउ", "बजाउनुहोस्", "बजाउनुस्",
        "बजाइदिनुहोस्", "बजाइदिनुस्", "बजाइदिनु", "बजाइदेऊ", "बजाइदेउ",
        // search verbs
        "खोज", "खोज्नुहोस्", "खोज्नुस्", "खोज्नुभयो", "खोज्ने", "खोज्न",
        "खोजेर", "खोजे",
        "खोजिदिनुहोस्", "खोजिदिनुस्", "खोजिदिनु", "खोजिदेउ", "खोजिदेऊ",
        // particles / politeness
        "मा", "मलाई", "लाई", "कृपया", "हजुर", "नमस्ते", "नमस्कार",
        "सुप्रभात", "एउटा", "एउटै", "केही", "केहि", "अनि", "र"
    ]

    /// Devanagari tokens CONTAINING the YouTube word are dropped
    /// wholesale ("युट्युबमा", "युट्युबको" — the trigger morpheme; no
    /// real query contains it).
    private static let devanagariContainmentDrops = ["युट्युब"]

    static func extractQuery(from raw: String) -> String? {
        var kept: [String] = []
        for piece in raw.components(separatedBy: .whitespacesAndNewlines) {
            let token = piece.trimmingCharacters(
                in: CharacterSet.punctuationCharacters.union(CharacterSet(charactersIn: "।॥"))
            )
            guard !token.isEmpty else { continue }
            if isDropToken(token) { continue }
            kept.append(token)
        }
        var query = NepaliTextNormalizer.normalize(kept.joined(separator: " "))
        query = String(query.prefix(maxQueryLength))
        return query.isEmpty ? nil : query
    }

    private static func isDropToken(_ token: String) -> Bool {
        let devanagari = token.unicodeScalars.contains { $0.value >= 0x0900 && $0.value <= 0x097F }
        if devanagari {
            return devanagariDrops.contains(token)
                || devanagariContainmentDrops.contains { token.contains($0) }
        }
        return latinDrops.contains(token)
    }

    /// Whole-token match — identical semantics to
    /// `CommandRouter.containsToken` (split on whitespace + punctuation,
    /// exact equality), mirrored here so this type can never depend on
    /// router internals.
    private static func token(_ token: String, in text: String) -> Bool {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .contains { $0 == token }
    }

    private static func firstToken(in text: String) -> String? {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .first { !$0.isEmpty }
    }
}
