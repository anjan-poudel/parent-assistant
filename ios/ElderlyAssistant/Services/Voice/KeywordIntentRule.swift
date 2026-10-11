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
/// "read a public news digest / open a video search / open a named app
/// the elder asked for" may relax here. The groups below are REQUIRED
/// sets (every group must match), so a bare "play" never fires without
/// the YouTube word, a bare "समाचार" never fires without a request verb
/// or a greeting, and a bare app name never fires without an open verb
/// (or, for the camera, a capture verb).
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
///
/// [APP-LAUNCHER] (2026-09-16) The launcher rules run LAST — after news
/// and YouTube — for the same reason: "युट्युब खोल र गीत चलाऊ" (open
/// YouTube and play a song) is the PLAY request. Each launcher rule
/// carries the catalog id its match resolved to (`Match.appID`), which
/// is exactly the `app` entity the `launcher.open` plugin resolves, and
/// its required groups are [app word ∧ open verb]. So "क्यामेरा खोल" /
/// "open WhatsApp" fire the deterministic fast path while a bare app
/// word — and every weather QUESTION ("मौसम कस्तो छ?", which the topic
/// table owns) — falls through exactly as before. Camera capture is the
/// second camera variant: "फोटो खिच्न" shoots a photo, it does not open
/// the Photos app. The router hands a match to the coordinator's
/// launch seam, which is the SAME seam the plugin calls — the keyword
/// layer composes no plugin command of its own.
///
/// [MED-PHOTO] (2026-09-17) The medication photo query ("रक्तचापको औषधि
/// कस्तो छ?" / "what does my blood pressure medicine look like?") is the
/// one rule whose keyword group is NOT in the static table: it is built at
/// match time from the live medication schedule (names + purposes), so a
/// medicine the household does not have can never be asked about. It is
/// evaluated last of all — after the festival rule and every launcher
/// rule — and the router resolves the key it matched back through the same
/// live schedule.
///
/// [SPOTIFY] (2026-10-06) The music domain gives the same relaxed
/// shape to bare music requests: [musicMarkers ∧ musicVerbFamily],
/// ordered after news and YouTube and BEFORE every launcher rule, and
/// structurally EXCLUDING the YouTube marker family (ADR-SP-06), so an
/// explicit YouTube utterance can never be reclassified as music
/// (FR-SP-005) even where the YouTube rule itself declines.
/// `musicQuery(from:)` extracts the song query for the router's music
/// path and `mentionsMusic(_:)` is the contact-search veto's predicate
/// (C-SP-08) — both pure statics, no model, no prompt tokens
/// (constraint 3).
enum KeywordIntentRule {

    /// Safe domains the relaxed rules may claim.
    enum Domain: String {
        case news
        case youtube
        /// [SPOTIFY] (2026-10-06) A bare music request ("भजन बजाऊ",
        /// "गीत चलाऊ", "play a song") — the zero-prompt-token path into
        /// the music route (FR-SP-013, C-SP-07). The rule structurally
        /// excludes the YouTube marker family (ADR-SP-06), so an
        /// explicit YouTube utterance can never be claimed here; the
        /// router turns a `.music` match into the real music path
        /// (`fireMusicRequest`), never the old stub.
        case music
        /// [APP-LAUNCHER] (2026-09-16) A spoken app-launch request
        /// ("क्यामेरा खोल", "open WhatsApp", "फोटो खिच्न"). The matched
        /// rule carries the catalog id in `Match.appID`.
        case appLaunch
        /// [FESTIVAL-DATE] (2026-09-17) A festival date question
        /// ("दशैँ कहिले हो", "when is Dashain") — answered
        /// deterministically from the festival catalog, so the answer
        /// never depends on encoder availability, band policy or model
        /// calibration. The matched rule carries the catalog id in
        /// `Match.festivalID`.
        case festivalDate
        /// [MED-PHOTO] (2026-09-17) "What does my blood pressure medicine
        /// look like?" — a photo IDENTIFICATION question about a medicine
        /// the household actually has. The rule's vocabulary is built at
        /// match time from the live medication schedule (names + the
        /// purposes they were filed under), so it can only ever claim a
        /// medication the elder can actually be shown. The matched rule
        /// carries the vocabulary key that resolved the entry in
        /// `Match.medicationName`.
        case medicationPhoto
    }

    /// A fired rule: which domain resolved, and the FIRST matching
    /// alternative of each required group — the honest "matched keys"
    /// payload for the `intent_keyword_match` observability event
    /// (fixed rule vocabulary only, never user text).
    ///
    /// That "fixed vocabulary only" rule is why `.medicationPhoto`'s
    /// medication key rides `medicationName` and NOT `matchedKeys`: the
    /// vocabulary is the live schedule, so a matched key can be a
    /// medication name or a purpose word — health data about the
    /// household, and the exact thing every medication event in this app
    /// refuses to log. The event keeps the rule's own query lexeme, which
    /// is fixed vocabulary and safe.
    struct Match: Equatable {
        let domain: Domain
        let matchedKeys: [String]
        /// [APP-LAUNCHER] (2026-09-16) The catalog id an `.appLaunch`
        /// match resolved to ("camera", "whatsapp", …) — the id the
        /// catalog and the `launcher.open` entity are both keyed by.
        /// nil for every other domain (and only for that reason).
        let appID: String?
        /// [FESTIVAL-DATE] (2026-09-17) The festival catalog id a
        /// `.festivalDate` match resolved to ("dashain", "tihar", …).
        /// nil for every other domain.
        let festivalID: String?
        /// [MED-PHOTO] (2026-09-17) The medication vocabulary key a
        /// `.medicationPhoto` match resolved to — an entry's NAME or one of
        /// its purpose words, in the canonical form the live schedule's
        /// `MedicationVoiceVocabulary` produced. The router resolves that
        /// key back to the entry (or entries) it names; the rule itself
        /// never holds a table of medicines. nil for every other domain.
        let medicationName: String?

        init(domain: Domain, matchedKeys: [String],
             appID: String? = nil, festivalID: String? = nil,
             medicationName: String? = nil) {
            self.domain = domain
            self.matchedKeys = matchedKeys
            self.appID = appID
            self.festivalID = festivalID
            self.medicationName = medicationName
        }
    }

    // MARK: - Matching

    /// Returns the highest-ordered rule whose required keyword groups
    /// ALL co-occur in the transcript, or nil when no relaxed rule
    /// fires. Canonicalization mirrors the router's phrase stages
    /// (lowercase + interior-whitespace collapse).
    ///
    /// `medicationNames` is the DYNAMIC half of the table
    /// ([MED-PHOTO], 2026-09-17): the live medication vocabulary — each
    /// entry's name plus the words its purpose covers, as produced by
    /// `MedicationVoiceVocabulary.voiceKeys(for:)`. It is passed IN, never
    /// held: a fixed drug table would let the app claim a medicine the
    /// household does not have. The default `[]` is what every pre-existing
    /// caller and the other rules' tests get — with no entries the
    /// medication group is empty, an empty group can never satisfy a
    /// variant, and the medication rule simply never fires.
    static func match(transcript raw: String,
                      medicationNames: [String] = []) -> Match? {
        let text = canonical(raw)
        guard !text.isEmpty else { return nil }
        for rule in rules {
            // [SPOTIFY] (2026-10-06) Rule-level exclusion, evaluated
            // BEFORE any variant (ADR-SP-06): an excluded group's
            // presence disqualifies the whole rule, so the music rule
            // can never act on an utterance carrying a YouTube marker.
            // The YouTube rule itself is ordered first and usually
            // claims such utterances; this check is the structural
            // belt-and-braces for the ones it declines.
            if rule.excluded.contains(where: { firstMatchingKey(in: $0, text: text) != nil }) {
                continue
            }
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
                    // [FESTIVAL-DATE] The festival id comes from WHICH
                    // festival name matched (the group's own key), not
                    // from the rule — one rule covers the whole catalog.
                    let festivalID = rule.domain == .festivalDate
                        ? Self.festivalID(forNameKey: matched.last ?? "")
                        : nil
                    return Match(domain: rule.domain, matchedKeys: matched,
                                 appID: rule.appID, festivalID: festivalID)
                }
            }
        }
        // [MED-PHOTO] The one rule whose groups cannot live in the static
        // table above: its medication group is built from the live schedule
        // at match time. Evaluated LAST, after every static rule, which is
        // exactly where the approved design puts it.
        return matchMedicationPhotoQuery(text: text, medicationNames: medicationNames)
    }

    /// [MED-PHOTO] (2026-09-17) The medication photo query: a query lexeme
    /// ("कस्तो देखिन्छ", "what does … look like") AND a medication
    /// vocabulary key co-occurring anywhere in the utterance.
    ///
    /// Both groups are REQUIRED, and that conjunction is the whole safety
    /// story: naming a medicine alone ("रक्तचापको औषधि") is not a question,
    /// and asking "how does it look" with no medicine in the sentence
    /// resolves to nothing — never to a guess at which medicine was meant.
    private static func matchMedicationPhotoQuery(text: String,
                                                  medicationNames: [String]) -> Match? {
        let vocabulary = medicationVocabularyGroup(medicationNames)
        // No medications (or none of them produced a usable key): the group
        // is empty and an empty group can never satisfy a variant — the
        // rule goes quiet rather than guessing a medicine.
        guard !vocabulary.isEmpty else { return nil }
        guard let queryKey = firstMatchingKey(in: medicationQueryWords, text: text),
              let medicationKey = firstMatchingKey(in: vocabulary, text: text) else {
            return nil
        }
        // `matchedKeys` carries the QUERY lexeme only — the medication key
        // is schedule data (a name or the family's words) and the
        // `intent_keyword_match` event is fixed-vocabulary-only, so the key
        // travels the dedicated `medicationName` field instead.
        return Match(domain: .medicationPhoto,
                     matchedKeys: [queryKey],
                     medicationName: medicationKey)
    }

    /// [MED-PHOTO] The medication group, built from the live vocabulary
    /// passed in. Canonicalized and deduplicated on the way in — the
    /// coordinator's keys and this group's keys must be the same strings,
    /// because the router resolves the matched key back against the
    /// schedule it came from.
    private static func medicationVocabularyGroup(_ names: [String]) -> Group {
        var seen = Set<String>()
        var group: Group = []
        for raw in names {
            let key = canonical(raw)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            group.append(alternative(forVocabularyKey: key))
        }
        return group
    }

    /// A vocabulary key's match mode, by the same rules the rest of this
    /// table follows: WHOLE-TOKEN for a single Latin word (containment
    /// would turn "pressure" into "pressured" and "pain" into "paint"), and
    /// PHRASE containment for Devanagari — where postpositions fuse onto
    /// the stem ("रक्तचापको औषधि" ⊃ "रक्तचाप", the grapheme rule of
    /// 2026-09-07) — and for any multi-word key ("blood pressure" can never
    /// token-equal one token).
    private static func alternative(forVocabularyKey key: String) -> Alternative {
        if key.contains(" ") || containsDevanagari(key) {
            return .phrase(key)
        }
        return .token(key)
    }

    /// Devanagari block (U+0900–U+097F) — enough to answer "does this key
    /// fuse postpositions onto its stem?", which is the only question the
    /// match-mode split asks.
    private static func containsDevanagari(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
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
    ///
    /// [SPOTIFY] Internal (not private) only so the shared
    /// `musicMarkers` family can be exposed to the contact-search veto
    /// (C-SP-08) and the test seams (design-l2 §29). Matching semantics
    /// are unchanged.
    enum Alternative {
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
    ///
    /// [SPOTIFY] Internal (not private) for the same reason as
    /// `Alternative` — the shared `musicMarkers` family is part of the
    /// C-SP-08 seam.
    typealias Group = [Alternative]

    /// One way a domain can fire: all its groups co-occur.
    private typealias Variant = [Group]

    private struct Rule {
        let domain: Domain
        let variants: [Variant]
        /// [APP-LAUNCHER] (2026-09-16) The catalog id an `.appLaunch`
        /// rule launches; nil for every other domain. The rule owns it
        /// (not the caller) so a match can never carry an id that the
        /// fired rule did not name.
        let appID: String?
        /// [SPOTIFY] (2026-10-06) Rule-level exclusion (ADR-SP-06): a
        /// variant of this rule never fires when ANY of these groups
        /// matches the transcript. The music rule excludes the YouTube
        /// marker family with it, so explicit-YouTube wording wins
        /// before any music classification can act — even where the
        /// YouTube rule itself declines (FR-SP-005). Every pre-existing
        /// rule keeps the empty default and is untouched.
        let excluded: [Group]

        init(domain: Domain, appID: String? = nil, excluded: [Group] = [],
             variants: [Variant]) {
            self.domain = domain
            self.appID = appID
            self.excluded = excluded
            self.variants = variants
        }
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
        ]),
        // [SPOTIFY] (2026-10-06) The music domain — a bare music request
        // ("भजन बजाऊ", "गीत चलाऊ", "play a song") without a YouTube
        // word, exactly the youtube rule's relaxed co-occurrence shape
        // ([musicMarkers, musicVerbFamily]). `excluded` is the
        // ADR-SP-06 structural guarantee: the moment a YouTube marker
        // appears the rule cannot act at all, even where the youtube
        // rule itself declines — "युट्युबमा गीत सुनाऊ" (सुनाऊ is a
        // listen verb, not a YouTube play/search verb) stays a YouTube
        // utterance and falls to the interpreter, never to music
        // (FR-SP-005). Ordered BEFORE every appLaunch rule so a play
        // request still wins over a launch word — "युट्युब खोल र गीत
        // चलाऊ" resolves exactly as the strict ladder would.
        Rule(domain: .music, excluded: [youtubeKeywords], variants: [
            [musicMarkers, musicVerbFamily]
        ]),
        // [APP-LAUNCHER] (2026-09-16) The launcher's fast path — ordered
        // LAST, so an utterance carrying both an app word and a video
        // request ("युट्युब खोल र गीत चलाऊ") resolves as the strict
        // ladder would: the play request wins. Every variant is [app
        // word ∧ open verb]; the camera adds the capture variant
        // ("फोटो खिच्न" shoots a photo, it does not open Photos).
        Rule(domain: .appLaunch, appID: "camera", variants: [
            [cameraWords, openVerbFamily],
            [photoWords, captureVerbFamily]
        ]),
        Rule(domain: .appLaunch, appID: "photos", variants: [
            [photoWords, openVerbFamily]
        ]),
        Rule(domain: .appLaunch, appID: "settings", variants: [
            [settingsWords, openVerbFamily]
        ]),
        Rule(domain: .appLaunch, appID: "weather", variants: [
            [weatherWords, openVerbFamily]
        ]),
        Rule(domain: .appLaunch, appID: "whatsapp", variants: [
            [whatsappWords, openVerbFamily]
        ]),
        Rule(domain: .appLaunch, appID: "youtube", variants: [
            [youtubeAppWords, openVerbFamily]
        ]),
        Rule(domain: .appLaunch, appID: "facebook", variants: [
            [facebookWords, openVerbFamily]
        ]),
        // [APP-LAUNCHER F8] Appended AFTER every existing rule, so the
        // added coverage cannot reorder what already fired: an utterance
        // naming two apps still resolves through the earlier rule.
        Rule(domain: .appLaunch, appID: "magnifier", variants: [
            [magnifierWords, openVerbFamily]
        ]),
        Rule(domain: .appLaunch, appID: "health", variants: [
            [healthWords, openVerbFamily]
        ]),
        Rule(domain: .appLaunch, appID: "instagram", variants: [
            [instagramWords, openVerbFamily]
        ]),
        Rule(domain: .appLaunch, appID: "calendar", variants: [
            [calendarWords, openVerbFamily]
        ]),
        // [FESTIVAL-DATE] (2026-09-17) Ordered after EVERY rule, so a
        // festival question can never shadow an existing claim — and the
        // when-word ∧ festival-name conjunction keeps false fires to
        // near zero ("दशैँमा के खाने?" names a festival with no when
        // word, so it falls through to the interpreter as before).
        Rule(domain: .festivalDate, variants: [
            [whenQuestionWords, festivalNamesGroup]
        ])
        // [MED-PHOTO] (2026-09-17) The medication photo query is NOT here:
        // its second group is the live medication schedule, so it is built
        // and evaluated in `match(transcript:medicationNames:)` after this
        // whole table — i.e. ordered last, after the festival rule too.
    ]

    /// Festival name keys resolved back to catalog ids — the name
    /// string is the group key (canonicalized), the id is what the
    /// router's answer path looks up.
    private static func festivalID(forNameKey key: String) -> String? {
        NepaliFestivalCatalog.all.first {
            canonical($0.nameNepali) == key || canonical($0.nameEnglish) == key
        }?.id
    }

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

    // MARK: - Music groups ([SPOTIFY] 2026-10-06)

    /// The music marker family — the SHARED vocabulary of the music
    /// rule, the contact-search veto (`mentionsMusic`) and the query
    /// extractor's marker fallback. Internal so the C-SP-08 veto reads
    /// the same alternatives the rule is gated by; the veto can never
    /// be wider or narrower than this family.
    ///
    /// Devanagari markers are substring-matched because postpositions
    /// fuse onto the stem ("गीतहरू" ⊃ "गीत", "भजनको" ⊃ "भजन" — the
    /// grapheme-cluster rule of 2026-09-07); the Latin markers are
    /// whole tokens, exactly like the YouTube word: "song" must not
    /// eat "songwriter" any more than "news" may eat "newspaper". The
    /// plural "songs" is deliberately NOT a marker (outside the
    /// reviewed vocabulary) — such an utterance still reaches the
    /// music path through the interpreter's existing `music` intent,
    /// which is why the rule can afford to stay narrow.
    static let musicMarkers: Group = [
        .phrase("भजन"), .phrase("गीत"), .phrase("गाना"),
        .phrase("संगीत"), .phrase("सङ्गीत"),
        .token("music"), .token("song"), .token("bhajan")
    ]

    /// The music verb family — play/listen/sing. English verbs are
    /// whole tokens; the narration guard (design L2-D9) deliberately
    /// ships the progressive forms and EXCLUDES the past forms
    /// `played`, `listened`, `sang`, `sung`, exactly as
    /// `youtubeVerbFamily` excludes `searched` so a narration never
    /// fires the stage. The Nepali families are the full grapheme
    /// enumerations the shipped families keep (the virama/matra rule:
    /// "चलाउनुहोस्" does not contain "चलाऊ", so every form ships
    /// explicitly): the play families verbatim from
    /// `youtubeVerbFamily`, the listen family verbatim from
    /// `newsVerbFamily`'s सुनाऊ block, and the sing family new.
    ///
    /// The खोज search family is deliberately NOT here — "गीत खोज" is a
    /// search phrase the interpreter owns (design §14), and adding it
    /// would widen the deterministic stage past the reviewed shape.
    private static let musicVerbFamily: Group = [
        // English play family (whole-token — containment would eat
        // "playlist"; `played` is the excluded narration form).
        .token("play"), .token("plays"), .token("playing"),
        // English listen family (`listened` excluded — narration).
        .token("listen"), .token("listens"), .token("listening"),
        // English sing family (`sang`/`sung` excluded — narration).
        .token("sing"), .token("sings"), .token("singing"),
        // Nepali play families (identical to youtubeVerbFamily).
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
        // Nepali listen family (identical to newsVerbFamily's block).
        .phrase("सुनाऊ"), .phrase("सुनाऊँ"), .phrase("सुनाउ"),
        .phrase("सुनाउनुहोस्"), .phrase("सुनाउनुस्"),
        .phrase("सुनाइदिनुहोस्"), .phrase("सुनाइदिनुस्"), .phrase("सुनाइदिनु"),
        .phrase("सुनाइदेऊ"), .phrase("सुनाइदेऊँ"), .phrase("सुनाइदेउ"),
        // Nepali sing family (new — the music domain's own verbs).
        .phrase("गाऊ"), .phrase("गाऊँ"), .phrase("गाउ"), .phrase("गाउनुहोस्"), .phrase("गाउनुस्"),
        .phrase("गाइदिनुहोस्"), .phrase("गाइदिनुस्"), .phrase("गाइदिनु"),
        .phrase("गाइदेऊ"), .phrase("गाइदेऊँ"), .phrase("गाइदेउ")
    ]

    // MARK: - App-launch groups ([APP-LAUNCHER] 2026-09-16)

    /// The words an elder says for a catalog app: the catalog's own
    /// spoken `aliases` and NOTHING ELSE — the same vocabulary the
    /// `launcher.open` plugin's prompt exposes, so the fast path and the
    /// model path hear one set of words.
    ///
    /// [APP-LAUNCHER F12] That "and nothing else" is the fix: the
    /// keyword table used to add private `extra:` spellings (romanized
    /// `mausam`, the व्हाट्सएप / वाट्सएप WhatsApp forms), so the fast path
    /// fired on words the interpreter then rejected — the elder said
    /// "व्हाट्सएप खोल", the on-device path launched it, and the same
    /// utterance through the model path answered "I don't know an app
    /// called व्हाट्सएप". Every spelling now lives in the catalog
    /// (`AppLauncher.App.aliases`), which is the single vocabulary both
    /// paths read.
    ///
    /// `.token` throughout: an app word matches WHOLE or not at all
    /// (never a substring — the Devanagari Character-cluster
    /// regression), which is also why the catalog's aliases are
    /// single-token words. A catalog id that no longer resolves yields
    /// an EMPTY group, and an empty group can never satisfy a variant:
    /// the rule goes quiet rather than guessing an app.
    private static func appWords(_ appID: String) -> Group {
        (AppLauncher.app(for: appID)?.aliases ?? []).map { .token($0) }
    }

    private static let cameraWords = appWords("camera")
    private static let photoWords = appWords("photos")
    private static let settingsWords = appWords("settings")
    /// The weather rule still requires an open verb — a bare "मौसम",
    /// "mausam" or "weather" stays the topic table's weather QUESTION.
    private static let weatherWords = appWords("weather")
    private static let whatsappWords = appWords("whatsapp")
    /// [APP-LAUNCHER F8] The entries the ON-DEVICE stack could not reach.
    /// Its grammar has no "plugin" action, so the model/plugin path
    /// (`launcher.open` via the interpreter) does not exist there and
    /// these four apps were voice-unreachable on the device that ships
    /// with the app — reachable only in a cloud session. A deterministic
    /// rule is the whole fix: no encoder, no grammar and no prompt change,
    /// and the on-device ladder runs this table like any other stage.
    /// Their words are catalog aliases like every other rule's.
    private static let magnifierWords = appWords("magnifier")
    private static let healthWords = appWords("health")
    private static let instagramWords = appWords("instagram")
    private static let calendarWords = appWords("calendar")

    /// [FESTIVAL-DATE] (2026-09-17) The "when" question family — whole
    /// tokens for the single words, phrase-containment for the
    /// Devanagari/romanized two-word forms (whitespace collapse is the
    /// canonicalizer's only transform, so "कुन दिन" survives it).
    /// Deliberately NOT a substring family for the bare words: "when"
    /// must not fire on "whenever" any more than "open" on "opened".
    private static let whenQuestionWords: Group = [
        .token("when"), .token("कहिले"), .token("kahile"),
        .phrase("कुन दिन"), .phrase("kun din"),
        .phrase("कुन गते"), .phrase("kun gate"),
    ]

    /// [FESTIVAL-DATE] (2026-09-17) Every festival name in the catalog,
    /// both languages, phrase-matched — Devanagari postpositions fuse
    /// onto names ("दशैँमा" ⊃ "दशैँ"), and phrase containment covers
    /// the fusion exactly as it covers the app words'. A name alone
    /// fires nothing; the when-family is the other required group.
    private static let festivalNamesGroup: Group = NepaliFestivalCatalog.all
        .flatMap { festival in
            [festival.nameNepali, festival.nameEnglish]
                .filter { !$0.isEmpty }
                .map { Alternative.phrase(canonical($0)) }
        }
    /// [MED-PHOTO] (2026-09-17) The "what does it look like?" family — the
    /// identification question the photo query answers. Phrase-matched
    /// throughout: every form here is longer than one token, and
    /// "कस्तो छ" must not fire on a bare "कस्तो" (which belongs to the
    /// topic table's questions) any more than "looks like" may fire on
    /// "look".
    ///
    /// "what does" is the English half of "what does it look like" and is
    /// deliberately no weaker than that: the medication group is the other
    /// required half, so "what does my blood pressure medicine do?" is
    /// still a question about a medicine the household HAS — the worst case
    /// is showing a photo the elder did not ask for, never claiming a
    /// medicine that does not exist.
    private static let medicationQueryWords: Group = [
        .phrase("कस्तो देखिन्छ"), .phrase("कस्तो छ"),
        .phrase("कुन हो"), .phrase("kun ho"),
        .phrase("looks like"), .phrase("what does")
    ]

    /// The YouTube APP word — deliberately separate from
    /// `youtubeKeywords` above: that group is substring-matched for the
    /// postposition-fused "युट्युबमा" of a PLAY request, while a launch
    /// must match the bare word only ("युट्युब खोल").
    private static let youtubeAppWords = appWords("youtube")
    private static let facebookWords = appWords("facebook")

    /// The open/launch verb every app-launch rule requires. English
    /// whole-token ("open" must not eat "opened"); Nepali and romanized
    /// Nepali forms enumerated in FULL and token-matched — खोल्नुहोस्
    /// does not token-equal खोल (the virama rule of 2026-09-07), so
    /// every form ships rather than one stem being substring-matched.
    private static let openVerbFamily: Group = [
        .token("open"), .token("opens"), .token("opening"),
        .token("launch"), .token("launches"), .token("launching"),
        .token("start"), .token("starts"), .token("starting"),
        // Romanized Nepali (kholnu — "to open").
        .token("khol"), .token("khola"), .token("kholnu"), .token("kholnus"),
        .token("kholnuhos"), .token("kholidinu"), .token("kholidinus"),
        // Devanagari.
        .token("खोल"), .token("खोल्नु"), .token("खोल्नुहोस्"), .token("खोल्नुस्"),
        .token("खोल्न"), .token("खोल्ने"),
        .token("खोलिदिनुहोस्"), .token("खोलिदिनुस्"), .token("खोलिदिनु"),
        .token("खोलिदेऊ"), .token("खोलिदेऊँ"), .token("खोलिदेउ"),
        .token("खोल्दिनुहोस्"), .token("खोल्दिनुस्"), .token("खोल्दिनु")
    ]

    /// The CAMERA capture verbs ("फोटो खिच्न" / "photo khicna" / "take a
    /// photo"): a photo word plus one of these asks to SHOOT, which iOS
    /// serves only through the launcher's in-process camera — never the
    /// Photos app. Same full-enumeration, whole-token discipline as the
    /// open family.
    private static let captureVerbFamily: Group = [
        .token("take"), .token("snap"), .token("capture"),
        .token("khic"), .token("khich"), .token("khicna"), .token("khichna"),
        .token("khicnu"), .token("khichnu"),
        .token("खिच"), .token("खिच्न"), .token("खिच्नु"), .token("खिच्नुहोस्"),
        .token("खिच्नुस्"), .token("खिच्ने")
    ]

    // MARK: - Music query extraction ([SPOTIFY] 2026-10-06)

    /// Upper bound on the extracted music query — mirrors
    /// `YouTubeRoute.maxQueryLength`: a song search is a phrase, not a
    /// sentence, and anything longer is STT noise around the trigger
    /// words. Exposed for the router and the extractor's own cap tests.
    static let maxMusicQueryLength = 100

    /// True when the text carries any music marker — the predicate the
    /// contact-search route vetoes on (C-SP-08). Canonicalizes
    /// internally, so the call is order-independent relative to the
    /// route's own canonicalization, and reuses the rule's own
    /// `musicMarkers` alternatives, so the veto and the rule can never
    /// disagree about what "a music utterance" is.
    static func mentionsMusic(_ raw: String) -> Bool {
        let text = canonical(raw)
        guard !text.isEmpty else { return false }
        return musicMarkers.contains { $0.matches(text) }
    }

    /// [MTC] (2026-10-10) The music query extractor's outcome with its
    /// PROVENANCE — which of the never-empty fallback steps produced the
    /// query, and whether that makes the request degenerate
    /// (design-l2 §13; FR-MTC-002). The degenerate trigger reads
    /// `isDegenerate`; the wrapper `musicQuery(from:)` reads `query`
    /// alone and keeps every shipped return value byte-identical.
    ///
    /// Closed vocabulary, pure value data: no egress, no file reads, no
    /// console writes — NFR-MTC-012 by construction.
    struct MusicQueryExtraction: Equatable {
        /// Which arm of the extractor produced the query.
        enum Provenance: Equatable {
            /// Tokens survived the drop sets — the utterance named its
            /// own query ("रामायणको भजन लगाइदेऊ" → "रामायणको"). The
            /// only non-degenerate provenance.
            case content
            /// Every token was scaffolding; the never-empty fallback
            /// searched the FIRST music-marker token ("भजन बजाऊ" →
            /// "भजन"). The query is the bare marker, not a request the
            /// elder voiced — degenerate.
            case markerFallback
            /// Every token was scaffolding AND no marker token was
            /// present: the raw transcript's tokens stand in the query
            /// ("चलाऊ" → "चलाऊ"; design L2-D10 step 3). A
            /// canonical-empty input reports this provenance with
            /// `query == nil` (FR-MTC-002's "canonicalizes to
            /// nothing"). Degenerate either way.
            case transcriptFallback
        }

        /// The extracted query; nil only when the input canonicalizes
        /// to nothing.
        let query: String?
        let provenance: Provenance

        /// The degenerate-query trigger (design-l2 §23, FR-MTC-002):
        /// only a content-derived query is a real search phrase. A
        /// marker fallback, a transcript fallback and the
        /// canonical-empty case must probe instead of searching the
        /// literal result blindly.
        var isDegenerate: Bool { provenance != .content || query == nil }
    }

    /// Extracts the song query from a music request — the marker/verb
    /// scaffolding removed, the remainder normalized — and reports
    /// WHICH step produced it. Mirrors `YouTubeRoute.extractQuery`'s
    /// mechanics exactly (per-token punctuation + danda trim,
    /// whole-token Latin/Devanagari drop sets, Devanagari containment
    /// drops, `NepaliTextNormalizer`), with the music vocabulary added
    /// to the drop sets, plus the never-empty fallback of design
    /// L2-D10:
    ///
    ///   1. the tokens surviving the drop sets, joined ⇒ `.content`;
    ///   2. else the FIRST music-marker token ("भजन बजाऊ" → "भजन")
    ///      ⇒ `.markerFallback`;
    ///   3. else the raw transcript's tokens ⇒ `.transcriptFallback`.
    ///
    /// A canonical-empty input is step 3 with no tokens at all:
    /// `.transcriptFallback` and `query == nil`. The canonicalization
    /// happens first (lowercase + whitespace collapse), so a direct
    /// call with a raw transcript behaves like one with the router's
    /// pre-canonicalized text.
    static func musicQueryOutcome(from raw: String,
                                  maxLength: Int = KeywordIntentRule.maxMusicQueryLength)
        -> MusicQueryExtraction {
        let text = canonical(raw)
        var tokens: [String] = []
        for piece in text.components(separatedBy: .whitespacesAndNewlines) {
            let token = piece.trimmingCharacters(
                in: CharacterSet.punctuationCharacters.union(CharacterSet(charactersIn: "।॥")))
            guard !token.isEmpty else { continue }
            tokens.append(token)
        }
        guard !tokens.isEmpty else {
            return MusicQueryExtraction(query: nil, provenance: .transcriptFallback)
        }

        var kept = tokens.filter { !isMusicDropToken($0) }
        let provenance: MusicQueryExtraction.Provenance
        if !kept.isEmpty {
            provenance = .content
        } else {
            // [SPOTIFY] L2-D10 — a query of marker + verb only ("भजन
            // बजाऊ") must never extract empty: search the marker word,
            // never the verb phrase, and only when there is no marker
            // at all fall back to the raw transcript's tokens.
            if let marker = tokens.first(where: { isMusicMarkerToken($0) }) {
                kept = [marker]
                provenance = .markerFallback
            } else {
                kept = tokens
                provenance = .transcriptFallback
            }
        }
        var query = NepaliTextNormalizer.normalize(kept.joined(separator: " "))
        query = String(query.prefix(maxLength))
        return MusicQueryExtraction(query: query.isEmpty ? nil : query,
                                    provenance: provenance)
    }

    /// Thin wrapper — `musicQueryOutcome(from:maxLength:).query`. Every
    /// return value (and every shipped test of it) is byte-identical to
    /// the extractor's historical behaviour; new callers that need the
    /// provenance read `musicQueryOutcome` instead.
    static func musicQuery(from raw: String,
                           maxLength: Int = KeywordIntentRule.maxMusicQueryLength) -> String? {
        musicQueryOutcome(from: raw, maxLength: maxLength).query
    }

    /// The music extractor's drop sets: the YouTubeRoute sets, verbatim,
    /// plus the music vocabulary (markers and the listen/sing/play verb
    /// forms). Whole-token only on both scripts — a containment "for"
    /// would eat "foreigner", and a containment Devanagari marker would
    /// eat a contact name ("गीता"), which is exactly the grapheme-cluster
    /// discipline the shipped extractor keeps.
    private static let musicLatinDrops: [String] = [
        // The YouTubeRoute latinDrops set, verbatim.
        "play", "plays", "playing", "played",
        "youtube", "on", "in", "for", "the", "a", "an", "to", "of",
        "and", "or", "please", "me", "my", "some", "that", "this",
        "from", "with", "search", "searches", "searching", "searched",
        // romanized Nepali particles and play-family verbs — device
        // evidence 2026-10-11: the v6-q6 on-device STT sometimes
        // transcribes ROMANIZED Nepali, and "maa nepali geet la"
        // (meant as "युट्युबमा नेपाली गीत लगाऊ") leaked मा and लगाऊ
        // into the search query. Whole-token only: "ma" must not eat
        // "mama".
        "ma", "maa", "la", "lagau", "lagaau", "lagauu", "lagaunu",
        "lagaunus", "lagauda", "lagaudai", "lagai", "lagayera",
        "bajau", "bajaaun", "bajaunu", "bajauda", "bajaai", "bajaunus",
        "chalaau", "chalau", "chalaunu", "chalauda", "chalaai",
        "kripa", "kripaya", "hajur", "euta", "eutai", "ani", "ra",
        "mero", "hamro", "malai", "malaai",
        // Music markers, the provider name, and the listen/sing verbs.
        "music", "song", "bhajan", "spotify",
        "listen", "listens", "listening",
        "sing", "sings", "singing"
    ]

    /// The music extractor's Devanagari whole-token drops: the
    /// YouTubeRoute set, verbatim, plus the music markers and the
    /// listen/sing verb families. The खोज search family stays in the
    /// set (it is sentence scaffolding in a music request too: "गीत
    /// खोज" extracts the marker, not the verb).
    private static let musicDevanagariDrops: [String] = [
        // play verbs (the YouTube set, verbatim)
        "चलाऊ", "चलाऊँ", "चलाउ", "चलाउनुहोस्", "चलाउनुस्",
        "चलाइदिनुहोस्", "चलाइदिनुस्", "चलाइदिनु", "चलाइदेऊ", "चलाइदेऊँ", "चलाइदेउ",
        "बजाऊ", "बजाऊँ", "बजाउ", "बजाउनुहोस्", "बजाउनुस्",
        "बजाइदिनुहोस्", "बजाइदिनुस्", "बजाइदिनु", "बजाइदेऊ", "बजाइदेऊँ", "बजाइदेउ",
        "लगाऊ", "लगाऊँ", "लगाउ", "लगाउँ", "लगाउनुहोस्", "लगाउनुस्",
        "लगाइदिनुहोस्", "लगाइदिनुस्", "लगाइदिनु", "लगाइदेऊ", "लगाइदेऊँ", "लगाइदेउ",
        // participial / progressive play forms (device evidence
        // 2026-10-10: "युट्युबमा नेपाली गीत लगाउँदा" — the -दा/-दै
        // endings are natural phrasings and must not survive into the
        // search query)
        "लगाउँदा", "लगाउँदै", "बजाउँदा", "बजाउँदै", "चलाउँदा", "चलाउँदै",
        // search verbs
        "खोज", "खोज्नुहोस्", "खोज्नुस्", "खोज्नुभयो", "खोज्ने", "खोज्न",
        "खोजेर", "खोजे",
        "खोजिदिनुहोस्", "खोजिदिनुस्", "खोजिदिनु", "खोजिदेउ", "खोजिदेऊ", "खोजिदेऊँ",
        // particles / politeness
        "मा", "मलाई", "लाई", "कृपया", "हजुर", "नमस्ते", "नमस्कार",
        "सुप्रभात", "एउटा", "एउटै", "केही", "केहि", "अनि", "र",
        // music markers
        "भजन", "गीत", "गाना", "संगीत", "सङ्गीत",
        // listen family
        "सुनाऊ", "सुनाऊँ", "सुनाउ", "सुनाउनुहोस्", "सुनाउनुस्",
        "सुनाइदिनुहोस्", "सुनाइदिनुस्", "सुनाइदिनु", "सुनाइदेऊ", "सुनाइदेऊँ", "सुनाइदेउ",
        // sing family
        "गाऊ", "गाऊँ", "गाउ", "गाउनुहोस्", "गाउनुस्",
        "गाइदिनुहोस्", "गाइदिनुस्", "गाइदिनु", "गाइदेऊ", "गाइदेऊँ", "गाइदेउ"
    ]

    /// Devanagari tokens CONTAINING one of these are dropped wholesale —
    /// the trigger morphemes, extended by the provider marker
    /// ("स्पोटिफाइमा" must not search the provider name). No real query
    /// contains them.
    private static let musicDevanagariContainmentDrops = ["युट्युब", "स्पोटिफाइ"]

    private static func isMusicDropToken(_ token: String) -> Bool {
        let devanagari = token.unicodeScalars.contains { $0.value >= 0x0900 && $0.value <= 0x097F }
        if devanagari {
            return musicDevanagariDrops.contains(token)
                || musicDevanagariContainmentDrops.contains { token.contains($0) }
        }
        return musicLatinDrops.contains(token)
    }

    /// True when the token is itself a music marker — the L2-D10
    /// fallback's search key and, since [MTC] (2026-10-10), the answer
    /// path's marker-dropped-variant predicate (design-l2 §22 S6). Uses
    /// the same `musicMarkers` alternatives the rule matches by
    /// (Devanagari substring, Latin whole-token), so neither consumer
    /// can ever pick or drop a token the rule would not have recognised.
    static func isMusicMarkerToken(_ token: String) -> Bool {
        musicMarkers.contains { $0.matches(token) }
    }

    /// [MTC] (2026-10-10) True when the token is a NON-marker drop token
    /// — the music verb family, the particles and the filter words —
    /// the answer path's scaffold-strip predicate (design-l2 §13c/§22
    /// S3). Markers deliberately return false: they are kept in the
    /// free-text fallback and dropped only through the
    /// marker-dropped variant, which reads `isMusicMarkerToken`. Both
    /// accessors read the SAME tables the extractor reads — the drop
    /// sets stay single-sourced (NFR-MTC-012).
    static func isMusicScaffoldToken(_ token: String) -> Bool {
        isMusicDropToken(token) && !isMusicMarkerToken(token)
    }

    // MARK: - Near-match reporting ([MTC] 2026-10-10)

    /// [MTC] (2026-10-10) A domain whose relaxed rule PARTIALLY
    /// co-occurred — the bounded near-match reading the did-you-mean
    /// builder turns into candidates (design-l2 §10/§13b). Fixed
    /// vocabulary only: `matchedKeys` are the rule's own alternatives,
    /// never user text, so the value is safe to render as a candidate
    /// label and to observe.
    struct NearMatch: Equatable {
        let domain: Domain
        /// The variant's leading groups that co-occurred, in declared
        /// order, as their first matching key — the rule's own
        /// vocabulary. The FIRST key is the candidate's primary label
        /// word (the one the elder actually said).
        let matchedKeys: [String]
        /// [APP-LAUNCHER] The catalog id an `.appLaunch` near-match
        /// resolved to — the same field discipline as `Match.appID`:
        /// nil for every other domain, and only for that reason.
        let appID: String?
    }

    /// The four domains a candidate probe may be framed around
    /// (design-l2 §6/§10). `.medicationPhoto` is excluded BY
    /// CONSTRUCTION — no probe may ever be framed around a medication
    /// command — and `.festivalDate` is not a candidate domain.
    private static let nearMatchDomains: Set<Domain> = [.news, .youtube, .music, .appLaunch]

    /// [MTC] (2026-10-10) The bounded near-match reading: for each rule
    /// in table order, a variant counts when at least one — but not all
    /// — of its declared groups co-occurs in the transcript. The reading
    /// mirrors `match`'s traversal: the variant's groups are read in
    /// their declared order (specific word first, action verb last) and
    /// the match stops at the first absent group, so `matchedKeys` is
    /// the co-occurred prefix, never a bare verb on its own — a lone
    /// "बजाऊ" partially matches nothing, exactly as it fires nothing.
    ///
    /// One entry per domain (the first partial variant in table order
    /// wins), restricted to the four framable domains. The rule-level
    /// `excluded` groups apply exactly as they apply in `match`
    /// (ADR-SP-06: a YouTube marker disqualifies the music rule even
    /// for a near-match). Pure; no dynamic vocabulary is consulted, so
    /// the medication rule can never appear here.
    static func nearMatches(transcript raw: String) -> [NearMatch] {
        let text = canonical(raw)
        guard !text.isEmpty else { return [] }
        var matches: [NearMatch] = []
        var claimed: Set<Domain> = []
        for rule in rules {
            guard nearMatchDomains.contains(rule.domain),
                  !claimed.contains(rule.domain) else { continue }
            if rule.excluded.contains(where: { firstMatchingKey(in: $0, text: text) != nil }) {
                continue
            }
            for variant in rule.variants {
                var matched: [String] = []
                for group in variant {
                    guard let key = firstMatchingKey(in: group, text: text) else { break }
                    matched.append(key)
                }
                if !matched.isEmpty && matched.count < variant.count {
                    matches.append(NearMatch(domain: rule.domain,
                                             matchedKeys: matched,
                                             appID: rule.appID))
                    claimed.insert(rule.domain)
                    break
                }
            }
        }
        return matches
    }

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
