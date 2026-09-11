import Foundation

/// [INTENT-KEYWORDS] (2026-09-11) Relaxed keyword co-occurrence rules.
///
/// The deterministic ladder's strict stages validate whole FORM — full
/// phrase containment, enumerated verb families, marker adjacency — a
/// rigid gate that drops real commands when the speaker or the STT
/// rephrases ("हजुर, आजको समाचार सुनाइदिनुस् न" is obviously a news
/// request but fails the full-phrase "समाचार सुनाऊ" gate). This table
/// resolves intent from keyword CO-OCCURRENCE instead: a domain fires
/// when every one of its REQUIRED keyword groups is present anywhere in
/// the utterance, whatever the surrounding grammar.
///
/// Deliberately tiny and SAFE — only domains whose whole effect is
/// "read a public news digest / open a video search" may relax here.
/// The groups below are REQUIRED sets (every group must match), so a
/// bare "play" never fires without the YouTube word and a bare
/// "समाचार" never fires without a request verb or a greeting.
///
/// NEVER relaxed here: emergency, medication acknowledgment, the
/// confirmation flows, alarms/timers (they own their numbers), and
/// anything touching safety/health/money. Those stages run BEFORE this
/// table is consulted in the router ladder, keep their strict forms,
/// and are untouchable — the table only ever sees utterances every
/// strict deterministic stage has already declined.
///
/// Rule order mirrors the strict ladder (the news stage precedes the
/// YouTube stage), so an utterance carrying BOTH keyword sets resolves
/// exactly as the strict ordering would: the news digest wins over a
/// YouTube play. "समाचार युट्युबमा चलाइदिनुस्" (play the news on
/// YouTube) still resolves to YouTube — चलाइदिनुस् is a YouTube verb,
/// not a news verb.
enum KeywordIntentRule {

    /// Safe domains the relaxed rules may claim.
    enum Domain: String {
        case news
        case youtube
    }

    /// A fired rule: which domain resolved, and the FIRST matching
    /// alternative of each required group — the honest "matched keys"
    /// payload for the `intent_keyword_match` observability event
    /// (fixed rule vocabulary only, never user text).
    struct Match: Equatable {
        let domain: Domain
        let matchedKeys: [String]
    }

    // MARK: - Matching

    /// Returns the highest-ordered rule whose required keyword groups
    /// ALL co-occur in the transcript, or nil when no relaxed rule
    /// fires. Canonicalization mirrors the router's phrase stages
    /// (lowercase + interior-whitespace collapse).
    static func match(transcript raw: String) -> Match? {
        let text = canonical(raw)
        guard !text.isEmpty else { return nil }
        for rule in rules {
            for variant in rule.variants {
                var matched: [String] = []
                var complete = true
                for group in variant {
                    guard let key = firstMatchingKey(in: group, text: text) else {
                        complete = false
                        break
                    }
                    matched.append(key)
                }
                if complete {
                    return Match(domain: rule.domain, matchedKeys: matched)
                }
            }
        }
        return nil
    }

    // MARK: - Rule table

    /// A keyword alternative and its match mode:
    ///  - `.token` — whole-token equality (whitespace/punctuation
    ///    split). The ONLY safe mode for short Latin words: containment
    ///    would turn "news" into "newspaper", "play" into "playlist".
    ///  - `.phrase` — substring containment. Used for Devanagari
    ///    morphemes whose postpositions fuse onto the stem
    ///    ("युट्युबमा" ⊃ "युट्युब") and for verb families the virama
    ///    merges ("सुनाइदिनुस्" does NOT token-equal "सुनाऊ" —
    ///    grapheme-cluster rule of 2026-09-07).
    private enum Alternative {
        case token(String)
        case phrase(String)

        func matches(_ text: String) -> Bool {
            switch self {
            case .token(let word):
                return tokens(in: text).contains(word)
            case .phrase(let phrase):
                return text.contains(phrase)
            }
        }

        var key: String {
            switch self {
            case .token(let word): return word
            case .phrase(let phrase): return phrase
            }
        }
    }

    /// One required group: ANY alternative may match. All groups of a
    /// variant must match for the variant to fire.
    private typealias Group = [Alternative]

    /// One way a domain can fire: all its groups co-occur.
    private typealias Variant = [Group]

    private struct Rule {
        let domain: Domain
        let variants: [Variant]
    }

    /// Rules in evaluation order — mirrors the strict ladder's stage
    /// order (news before YouTube).
    private static let rules: [Rule] = [
        Rule(domain: .news, variants: [
            // Request-verb variant: news word ∧ news verb, anywhere.
            [newsKeywords, newsVerbFamily],
            // Bare-noun variant: news word ∧ greeting prefix ("नमस्ते,
            // समाचार") — the same greeting vocabulary the topic table
            // keeps.
            [newsKeywords, greetingGroup]
        ]),
        Rule(domain: .youtube, variants: [
            // YouTube word ∧ play/search verb, anywhere in the sentence
            // (no adjacency, no full-form requirement).
            [youtubeKeywords, youtubeVerbFamily]
        ])
    ]

    // MARK: - Keyword groups

    /// News topic words. "news" stays whole-token ("newspaper" is not a
    /// request); the Devanagari/romanized words are substring-matched
    /// because postpositions fuse onto them ("समाचारमा" ⊃ "समाचार").
    private static let newsKeywords: Group = [
        .token("news"),
        .phrase("समाचार"), .phrase("खबर"),
        .phrase("samachar"), .phrase("khabar")
    ]

    /// The small safe news-request verb set (directive: read / play /
    /// सुनाऊ / पढ + families). English verbs are whole-token; Nepali
    /// verbs are the full grapheme enumeration (the virama fuses:
    /// "सुनाइदिनुस्" does not contain the bare "सुनाऊ", so every form
    /// ships).
    private static let newsVerbFamily: Group = [
        .token("read"), .token("reads"), .token("reading"),
        .token("play"), .token("plays"), .token("playing"), .token("played"),
        .token("tell"), .token("tells"), .token("telling"),
        .token("hear"), .token("hears"), .token("hearing"),
        .token("listen"), .token("listens"), .token("listening"),
        .phrase("सुनाऊ"), .phrase("सुनाऊँ"), .phrase("सुनाउ"),
        .phrase("सुनाउनुहोस्"), .phrase("सुनाउनुस्"),
        .phrase("सुनाइदिनुहोस्"), .phrase("सुनाइदिनुस्"), .phrase("सुनाइदिनु"),
        .phrase("सुनाइदेऊ"), .phrase("सुनाइदेऊँ"), .phrase("सुनाइदेउ"),
        .phrase("पढ"), .phrase("पढ्नुहोस्"), .phrase("पढ्नुस्"),
        .phrase("पढिदिनुहोस्"), .phrase("पढिदिनुस्"), .phrase("पढिदिनु"),
        .phrase("पढिदेऊ"), .phrase("पढिदेऊँ"), .phrase("पढिदेउ")
    ]

    /// Greeting vocabulary for the bare-noun news variant — the same
    /// token/phrase vocabulary `TopicPreAnswer` keeps for greetings.
    private static let greetingGroup: Group = [
        .token("hi"), .token("hello"), .token("namaste"),
        .token("नमस्ते"), .token("नमस्कार"), .token("सुप्रभात"),
        .phrase("good morning"), .phrase("good afternoon"), .phrase("good evening")
    ]

    /// The YouTube word. Devanagari substring (postpositions fuse),
    /// English whole-token.
    private static let youtubeKeywords: Group = [
        .phrase("युट्युब"), .token("youtube")
    ]

    /// Play/search verb families — the SAME enumerations the strict
    /// `YouTubeRoute` gate keeps, PLUS the English search verbs as
    /// plain tokens: the strict gate only accepts the adjacent
    /// "search youtube" phrase shape, while the relaxed rule accepts
    /// any search verb anywhere ("search songs on youtube").
    private static let youtubeVerbFamily: Group = [
        // English play family (whole-token — containment would eat
        // "playlist").
        .token("play"), .token("plays"), .token("playing"), .token("played"),
        // English search family (whole-token; "searched" stays out so
        // narration "i searched youtube" never fires the stage).
        .token("search"), .token("searches"), .token("searching"),
        // Nepali play families (full grapheme enumeration — substring).
        .phrase("चलाऊ"), .phrase("चलाऊँ"), .phrase("चलाउ"), .phrase("चलाउनुहोस्"), .phrase("चलाउनुस्"),
        .phrase("चलाइदिनुहोस्"), .phrase("चलाइदिनुस्"), .phrase("चलाइदिनु"),
        .phrase("चलाइदेऊ"), .phrase("चलाइदेऊँ"), .phrase("चलाइदेउ"),
        .phrase("बजाऊ"), .phrase("बजाऊँ"), .phrase("बजाउ"), .phrase("बजाउनुहोस्"), .phrase("बजाउनुस्"),
        .phrase("बजाइदिनुहोस्"), .phrase("बजाइदिनुस्"), .phrase("बजाइदिनु"),
        .phrase("बजाइदेऊ"), .phrase("बजाइदेऊँ"), .phrase("बजाइदेउ"),
        .phrase("लगाऊ"), .phrase("लगाऊँ"), .phrase("लगाउ"), .phrase("लगाउँ"),
        .phrase("लगाउनुहोस्"), .phrase("लगाउनुस्"),
        .phrase("लगाइदिनुहोस्"), .phrase("लगाइदिनुस्"), .phrase("लगाइदिनु"),
        .phrase("लगाइदेऊ"), .phrase("लगाइदेऊँ"), .phrase("लगाइदेउ"),
        // Nepali search family.
        .phrase("खोज"), .phrase("खोज्नुहोस्"), .phrase("खोज्नुस्"), .phrase("खोज्नुभयो"),
        .phrase("खोज्ने"), .phrase("खोज्न"), .phrase("खोजेर"), .phrase("खोजे"),
        .phrase("खोजिदिनुहोस्"), .phrase("खोजिदिनुस्"), .phrase("खोजिदिनु"),
        .phrase("खोजिदेउ"), .phrase("खोजिदेऊ"), .phrase("खोजिदेऊँ")
    ]

    // MARK: - Helpers

    private static func firstMatchingKey(in group: Group, text: String) -> String? {
        for alternative in group where alternative.matches(text) {
            return alternative.key
        }
        return nil
    }

    /// Lowercase + interior-whitespace collapse — the same
    /// canonicalization the router applies before its phrase stages
    /// ([NEWS-READER][NOISE-FILTER] 2026-09-08), so this table sees
    /// exactly what the strict stages saw.
    private static func canonical(_ raw: String) -> String {
        raw.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Whole-token split — same semantics as
    /// `CommandRouter.containsToken` (whitespace/punctuation split,
    /// exact equality), mirrored so this table never depends on router
    /// internals.
    private static func tokens(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { !$0.isEmpty }
    }
}
