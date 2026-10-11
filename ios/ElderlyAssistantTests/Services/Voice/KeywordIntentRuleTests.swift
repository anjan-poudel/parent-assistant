import XCTest
@testable import ElderlyAssistant

/// [INTENT-KEYWORDS] (2026-09-11) Pure table tests for the relaxed
/// keyword co-occurrence rules: each relaxed rule fires when its
/// REQUIRED keyword groups all co-occur in noisy surrounding text, and
/// never fires when a required keyword is absent. Ordering pins: news
/// precedes YouTube, mirroring the strict ladder's stage order.
final class KeywordIntentRuleTests: XCTestCase {

    // MARK: - News rule fires on co-occurrence with noisy text

    func testNewsVerbVariantFiresOnNoisySurroundingTextDataDriven() {
        let utterances = [
            "हजुर, आजको समाचार सुनाइदिनुस् न",
            "कृपया समाचार पढ्नुहोस् है",
            "खबर सुनाउनुस् न त",
            "मलाई अहिलेको खबर सुनाइदिनु न",
            "tell me news from Nepal please",
            "can you read the news to me",
            "play the news for me",
            "i would like to hear the news",
            "listen to the news"
        ]
        for utterance in utterances {
            XCTAssertEqual(KeywordIntentRule.match(transcript: utterance)?.domain, .news,
                           "\(utterance) must resolve to the news rule — keyword co-occurrence, not form")
        }
    }

    func testBareNewsNounFiresWithGreetingPrefix() {
        XCTAssertEqual(KeywordIntentRule.match(transcript: "नमस्ते, समाचार")?.domain, .news)
        XCTAssertEqual(KeywordIntentRule.match(transcript: "good morning, news")?.domain, .news)
        XCTAssertEqual(KeywordIntentRule.match(transcript: "hello खबर")?.domain, .news)
    }

    func testNewsMatchCarriesTheMatchedKeys() {
        let match = KeywordIntentRule.match(transcript: "आजको समाचार सुनाइदिनुस् न")
        XCTAssertEqual(match, KeywordIntentRule.Match(domain: .news,
                                                      matchedKeys: ["समाचार", "सुनाइदिनुस्"]))
    }

    // MARK: - YouTube rule fires on co-occurrence with noisy text

    func testYoutubeRuleFiresOnNoisySurroundingTextDataDriven() {
        // The device transcript the directive names — resolved from the
        // keyword set alone (युट्युब ∧ चलाइदिनुस्), the surrounding
        // noise irrelevant.
        let utterances = [
            "हाम्लाई युट्युबमा नेपाली न्युज चलाइदिनुस् न है त",
            "search songs on youtube",
            "can you search youtube for old songs",
            "please play some bhajan on youtube for me",
            "युट्युबमा गीत खोजिदिनुस् न"
        ]
        for utterance in utterances {
            XCTAssertEqual(KeywordIntentRule.match(transcript: utterance)?.domain, .youtube,
                           "\(utterance) must resolve to the YouTube rule — keyword co-occurrence, not form")
        }
    }

    func testYoutubeMatchCarriesTheMatchedKeys() {
        let match = KeywordIntentRule.match(transcript: "हाम्लाई युट्युबमा नेपाली न्युज चलाइदिनुस् न है त")
        XCTAssertEqual(match, KeywordIntentRule.Match(domain: .youtube,
                                                      matchedKeys: ["युट्युब", "चलाइदिनुस्"]))
    }

    // MARK: - Ordering: news before YouTube (strict ladder mirror)

    func testBothKeywordSetsResolvePerRuleOrdering() {
        // "play the news on youtube" — the news rule is ordered first,
        // mirroring the strict ladder (news stage precedes the YouTube
        // stage): the digest wins.
        XCTAssertEqual(KeywordIntentRule.match(transcript: "play the news on youtube")?.domain, .news)

        // Nepali "play the news on YouTube" — चलाइदिनुस् is a YOUTUBE
        // verb, not a news verb, so the news rule declines and YouTube
        // claims it.
        XCTAssertEqual(KeywordIntentRule.match(transcript: "समाचार युट्युबमा चलाइदिनुस्")?.domain, .youtube)

        // News word + news verb co-occurring with a YouTube word still
        // resolves news (the rule order, not the utterance shape).
        XCTAssertEqual(KeywordIntentRule.match(transcript: "समाचार युट्युबमा सुनाऊ")?.domain, .news)
    }

    // MARK: - Required keyword absent → never fires

    func testYoutubeRuleNeverFiresWithoutTheYoutubeWordDataDriven() {
        // [SPOTIFY] (2026-10-06) Deliberate supersession: "play some
        // music" and "गीत चलाऊ" moved to the music-domain fixtures
        // below — they are bare music REQUESTS now (FR-SP-013), so the
        // whole table resolves them to `.music`. They never fired the
        // YouTube rule, which is what this list pins, and they still
        // don't. The remaining fixtures keep the no-YouTube-word
        // discipline intact.
        for utterance in ["play", "अलार्म बजाऊ", "search songs"] {
            XCTAssertNil(KeywordIntentRule.match(transcript: utterance),
                         "\(utterance) has a verb but no YouTube word — the required set must stay intact")
        }
    }

    func testYoutubeRuleNeverFiresWithoutAPlayOrSearchVerbDataDriven() {
        for utterance in ["youtube", "युट्युब", "i watched youtube yesterday",
                          "what is youtube", "youtube is nice"] {
            XCTAssertNil(KeywordIntentRule.match(transcript: utterance),
                         "\(utterance) has the YouTube word but no play/search verb — narration must not fire the stage")
        }
    }

    func testNewsRuleNeverFiresWithoutAVerbOrGreetingDataDriven() {
        for utterance in ["news", "समाचार", "खबर", "news please",
                          "news from my son about school", "के छ खबर?"] {
            XCTAssertNil(KeywordIntentRule.match(transcript: utterance),
                         "\(utterance) is a mention, not a request — a verb or greeting co-occurrence is required")
        }
    }

    func testNewsRuleNeverFiresOnTheBareNounWithoutGreeting() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "समाचार"))
        XCTAssertNil(KeywordIntentRule.match(transcript: "the news"))
        XCTAssertNil(KeywordIntentRule.match(transcript: "आजको खबर"))
    }

    func testNewspaperNeverFiresTheNewsRule() {
        // Whole-token discipline: "news" must not eat "newspaper".
        XCTAssertNil(KeywordIntentRule.match(transcript: "read the newspaper"))
    }

    // MARK: - App-launch rules ([APP-LAUNCHER] 2026-09-16)

    func testAppLaunchRulesFireDataDriven() {
        // The launcher fast path: [app word ∧ open verb], Nepali and
        // English, in noisy surrounding text — every entry resolves to
        // its CATALOG id, the id the `launcher.open` entity carries.
        let utterances: [(String, String)] = [
            ("क्यामेरा खोल", "camera"),
            ("हजुर, क्यामेरा खोल्नुहोस् न", "camera"),
            ("camera khol", "camera"),
            ("open the camera please", "camera"),
            ("फोटो खोल", "photos"),
            ("फोटो खोल्नुहोस्", "photos"),
            ("photos khol", "photos"),
            ("open my photos", "photos"),
            ("सेटिङ खोल", "settings"),
            ("settings kholnu hos", "settings"),
            ("open settings", "settings"),
            ("मौसम खोल", "weather"),
            ("weather khol", "weather"),
            ("mausam kholnus", "weather"),
            ("open the weather app", "weather"),
            ("ह्वाट्सएप खोल", "whatsapp"),
            ("whatsapp kholnu hos", "whatsapp"),
            ("open whatsapp", "whatsapp"),
            ("व्हाट्सएप खोल्नुहोस्", "whatsapp"),
            ("युट्युब खोल", "youtube"),
            ("open youtube", "youtube"),
            ("फेसबुक खोल", "facebook"),
            ("facebook khol", "facebook"),
            ("open facebook", "facebook")
        ]
        for (utterance, appID) in utterances {
            XCTAssertEqual(KeywordIntentRule.match(transcript: utterance)?.appID, appID,
                           "\(utterance) must launch \(appID) — app word ∧ open verb, whole words only")
        }
    }

    func testCameraCapturePhrasesResolveToTheCamera() {
        // "फोटो खिच्न" asks to SHOOT — iOS serves that in-process (the
        // camera entry), never by opening the Photos app.
        for utterance in ["फोटो खिच्न", "फोटो खिच", "फोटो खिच्नुहोस्",
                          "photo khicna", "take a photo", "a photo खिच्नुस्"] {
            XCTAssertEqual(KeywordIntentRule.match(transcript: utterance)?.appID, "camera",
                           "\(utterance) is a capture request — the camera entry, not Photos")
        }
    }

    func testAppLaunchMatchCarriesTheMatchedKeysAndCatalogID() {
        XCTAssertEqual(KeywordIntentRule.match(transcript: "क्यामेरा खोल"),
                       KeywordIntentRule.Match(domain: .appLaunch,
                                               matchedKeys: ["क्यामेरा", "खोल"],
                                               appID: "camera"))
        // News/YouTube matches carry no app id — the field means "the
        // rule that fired names this catalog app".
        XCTAssertNil(KeywordIntentRule.match(transcript: "आजको समाचार सुनाइदिनुस् न")?.appID)
    }

    func testEveryLauncherCatalogAliasFiresWithAnOpenVerb() {
        // The launcher rules read the catalog's own `aliases` — the same
        // words the plugin's prompt exposes. Every alias of every
        // launchable catalog app must fire, so the fast path can never
        // be narrower than the vocabulary the elder is told about.
        //
        // The list is the KEYWORD-COVERED set; the entries outside it
        // (phone, maps, messenger, gmail, zoom, the Settings panes, …)
        // are reachable through the model path only — see
        // docs/voice-launcher-phrases.md §4.
        for appID in ["camera", "photos", "settings", "weather",
                      "whatsapp", "youtube", "facebook",
                      "magnifier", "health", "instagram", "calendar"] {
            guard let app = AppLauncher.app(for: appID) else {
                XCTFail("catalog entry missing for \(appID)")
                continue
            }
            XCTAssertFalse(app.aliases.isEmpty, "\(appID) carries no spoken alias")
            for alias in app.aliases {
                XCTAssertEqual(KeywordIntentRule.match(transcript: "\(alias) खोल")?.appID, appID,
                               "\"\(alias) खोल\" must launch \(appID)")
                XCTAssertEqual(KeywordIntentRule.match(transcript: "open \(alias)")?.appID, appID,
                               "\"open \(alias)\" must launch \(appID) too")
            }
        }
    }

    /// [F8] The four apps the on-device stack could not reach. Its grammar
    /// cannot emit the plugin action, so without a deterministic rule
    /// "म्याग्निफायर खोल" was answered by nothing at all on the device the
    /// app ships on. The fix is table-only — no encoder, no grammar and no
    /// prompt change.
    func testAppLaunchRulesCoverTheOnDeviceGapApps() {
        let utterances: [(String, String)] = [
            ("magnifier खोल", "magnifier"),
            ("म्याग्निफायर खोल", "magnifier"),
            ("हजुर, म्याग्निफायर खोल्नुहोस् न", "magnifier"),
            ("open the magnifier", "magnifier"),
            ("health खोल", "health"),
            ("स्वास्थ्य खोल्नुहोस्", "health"),
            ("open my health app", "health"),
            ("instagram खोल", "instagram"),
            ("इन्स्टाग्राम खोल", "instagram"),
            ("open instagram please", "instagram"),
            ("calendar खोल", "calendar"),
            ("पात्रो खोल", "calendar"),
            ("open the calendar", "calendar")
        ]
        for (utterance, appID) in utterances {
            XCTAssertEqual(KeywordIntentRule.match(transcript: utterance)?.appID, appID,
                           "\(utterance) must launch \(appID) on EVERY stack — the " +
                           "on-device grammar cannot reach the plugin path")
        }
    }

    /// [F12] The spellings that used to live only in the keyword table.
    /// The catalog owns them now, so the model path resolves the same
    /// words; these pins keep the fast path firing on them.
    func testTheFormerKeywordOnlySpellingsStillFire() {
        for (utterance, spelling, appID) in [("mausam खोल", "mausam", "weather"),
                                             ("mausam kholnus", "mausam", "weather"),
                                             ("व्हाट्सएप खोल्नुहोस्", "व्हाट्सएप", "whatsapp"),
                                             ("वाट्सएप खोल", "वाट्सएप", "whatsapp")] {
            XCTAssertEqual(KeywordIntentRule.match(transcript: utterance)?.appID, appID,
                           "\(utterance) must keep launching \(appID)")
            XCTAssertTrue(AppLauncher.app(for: appID)!.aliases.contains(spelling),
                          "\(spelling) must be a CATALOG alias, not keyword-only — the " +
                          "model path reads the catalog and would reject it")
        }
    }

    func testBareAppWordsNeverFireTheLauncherDataDriven() {
        // No open (or capture) verb → not a launch request. A bare app
        // name belongs to the interpreter, and a bare weather word
        // belongs to the topic table ("मौसम कस्तो छ?" must stay a
        // QUESTION, never a launch).
        for utterance in ["camera", "क्यामेरा", "photos", "फोटो", "photo",
                          "settings", "सेटिङ", "weather", "मौसम", "mausam",
                          "whatsapp", "ह्वाट्सएप", "youtube", "युट्युब",
                          "facebook", "फेसबुक",
                          "magnifier", "म्याग्निफायर", "health", "स्वास्थ्य",
                          "instagram", "इन्स्टाग्राम", "calendar", "पात्रो",
                          "आजको मौसम कस्तो छ?", "is it raining today"] {
            XCTAssertNil(KeywordIntentRule.match(transcript: utterance),
                         "\(utterance) has no launcher verb — the required set must stay intact")
        }
    }

    func testAppWordsMatchWholeLexemesOnly() {
        // The pinned Devanagari Character-cluster regression: a fused or
        // longer word must never resolve through a shorter app word.
        for utterance in ["photoshop खोल", "क्यामेरामा खोल", "youtubers khol",
                          "फोटोहरू खोल"] {
            XCTAssertNil(KeywordIntentRule.match(transcript: utterance),
                         "\(utterance) is not the bare app word — whole-lexeme matching only")
        }
    }

    func testAppLaunchRulesRunLast() {
        // An utterance carrying both a video request and an app word
        // resolves as the strict ladder would: the play request wins
        // (the launcher rules are ordered after news + YouTube).
        XCTAssertEqual(KeywordIntentRule.match(transcript: "युट्युब खोल र गीत चलाऊ")?.domain,
                       .youtube)
        XCTAssertEqual(KeywordIntentRule.match(transcript: "समाचार खोल, समाचार सुनाऊ")?.domain,
                       .news)
    }

    // MARK: - The music domain ([SPOTIFY] 2026-10-06, C-SP-07 / FR-SP-013)

    /// The golden corpus' verb-bearing music rows: a marker ∧ a
    /// play/listen/sing verb co-occurring in any order, any surrounding
    /// grammar — every one classifies as the music domain with no model
    /// call. This is the zero-prompt-token path (constraint 3).
    func testMusicRuleFiresOnTheGoldenVerbBearingUtterancesDataDriven() {
        for utterance in [
            "भजन बजाउनुस्",
            "गीत चलाऊ",
            "रामायणको भजन लगाइदेऊ",
            "गाना बजाऊ",
            "कुनै भजन सुनाऊ",
            "शिवको भजन बजाऊ",
            "नयाँ गीत सुनाउनुस्",
            "play a song",
            "पुरानो हिन्दी गीत बजाऊ",
            "भजन गाउनुस्",
            "संगीत बजाऊ",
            "लोक गीत सुनाऊ",
            "कृष्ण भजन बजाऊ",
            "गीत सुनाउनुस्"
        ] {
            XCTAssertEqual(KeywordIntentRule.match(transcript: utterance)?.domain, .music,
                           "\(utterance) must resolve to the music rule — marker ∧ verb, no model")
        }
    }

    /// The marker and verb fixture tables, crossed: every marker form
    /// pairs with every verb form, in both scripts. Co-occurrence is
    /// the whole gate — no adjacency, no full-form requirement.
    func testMusicRuleFiresAcrossTheMarkerAndVerbTablesDataDriven() {
        let markers = ["भजन", "गीत", "गाना", "संगीत", "सङ्गीत", "music", "song", "bhajan"]
        let verbs = ["बजाऊ", "चलाऊ", "सुनाऊ", "लगाऊ", "गाऊ", "play", "listen", "sing"]
        for marker in markers {
            for verb in verbs {
                XCTAssertEqual(KeywordIntentRule.match(transcript: "\(marker) \(verb)")?.domain,
                               .music,
                               "\(marker) \(verb) must classify as music")
            }
        }
    }

    func testMusicRuleFiresOnNoisySurroundingTextDataDriven() {
        for utterance in [
            "हजुर, आज मलाई पुरानो भजन बजाइदिनुहोस् न है",
            "please play some bhajan for me",
            "can you listen to some music with me",
            "मलाई संगीत सुनाइदिनु न त",
            "sing a song please"
        ] {
            XCTAssertEqual(KeywordIntentRule.match(transcript: utterance)?.domain, .music,
                           "\(utterance) must resolve to the music rule — keyword co-occurrence, not form")
        }
    }

    /// The matched keys are the FIRST matching alternative of each
    /// required group — fixed rule vocabulary for the
    /// `intent_keyword_match` event, never user text.
    func testMusicMatchCarriesTheMatchedKeys() {
        XCTAssertEqual(KeywordIntentRule.match(transcript: "भजन बजाऊ"),
                       KeywordIntentRule.Match(domain: .music,
                                               matchedKeys: ["भजन", "बजाऊ"]))
        XCTAssertEqual(KeywordIntentRule.match(transcript: "play a song")?.matchedKeys,
                       ["song", "play"])
        // The music match carries no app/festival/medication ids — the
        // fields mean "the rule that fired resolved this catalog id".
        let match = KeywordIntentRule.match(transcript: "गीत चलाऊ")
        XCTAssertNil(match?.appID)
        XCTAssertNil(match?.festivalID)
        XCTAssertNil(match?.medicationName)
    }

    // MARK: - Music rule: excluded forms (design §14)

    /// The deliberate conservative choice (design §14): a noun-only
    /// musical phrase does not fire the deterministic stage. "देवीको
    /// भजन" is the golden corpus row that pins the interpreter's
    /// existing `music` intent — the rule must not double-claim it.
    func testMusicRuleNeverFiresOnTheNounOnlyGoldenPhrase() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "देवीको भजन"))
    }

    func testMusicRuleNeverFiresOnBareMusicNounsDataDriven() {
        for utterance in ["गीत", "भजन", "गाना", "संगीत", "सङ्गीत",
                          "music", "song", "bhajan",
                          "मलाई गीत मन पर्छ", "songs are nice", "i like music"] {
            XCTAssertNil(KeywordIntentRule.match(transcript: utterance),
                         "\(utterance) is a mention, not a request — a verb co-occurrence is required")
        }
    }

    /// The narration guard (design L2-D9): the past forms are excluded
    /// from `musicVerbFamily`, exactly as `searched` is excluded from
    /// the YouTube family, so a narration never fires the stage.
    func testMusicRuleNeverFiresOnNarrationDataDriven() {
        for utterance in ["i played a song for her",
                          "i listened to music yesterday",
                          "she sang a bhajan",
                          "the song was sung by him",
                          "मैले हिजो गीत सुनेँ",
                          "हिजो भजन बज्यो"] {
            XCTAssertNil(KeywordIntentRule.match(transcript: utterance),
                         "\(utterance) narrates — the music stage must not fire on it")
        }
    }

    /// The homonyms and non-music verb uses: alarms use the same
    /// बजाऊ/लगाऊ verbs as music, and marker-stem contact names can
    /// collide. Note (W1 review F-1): under the pinned grapheme-cluster
    /// semantics a contact named गीता does NOT carry the substring गीत
    /// (the fused forms गीतहरू / गीतमाया / भजनको do) — these fixtures
    /// pass on the missing music verb, and the fused-marker over-block
    /// class is pinned with T-113's veto fixtures.
    func testExcludedFormsNeverFireTheMusicRule() {
        for utterance in ["गीतालाई फोन गर", "call geeta", "गीता पढ",
                          "अलार्म बजाऊ", "टाइमर लगाऊ", "घण्टी बजाऊ",
                          "बिहानको अलार्म बजाउनुहोस्",
                          "अलार्म चलाऊ", "फोन लगाऊ",
                          // Fused-marker class (W1 review F-1): here the
                          // marker stem SURVIVES the grapheme clusters
                          // ("गीत" ⊂ "गीतमाया", "भजन" ⊂ "भजनलाई"), so
                          // the marker group matches — but the utterance
                          // carries no music verb, so the music rule
                          // still stays nil. The veto-side over-block
                          // for this same class is pinned in T-113's
                          // VoiceContactSearchRouteTests (F-6 trade-off).
                          "भजनलाई फोन गर", "गीतमाया"] {
            XCTAssertNil(KeywordIntentRule.match(transcript: utterance),
                         "\(utterance) is not a music request — the required marker set must stay intact")
        }
    }

    /// The pinned Devanagari grapheme-cluster semantics (2026-09-07):
    /// the markers are substring alternatives, so a fused postposition
    /// still matches ("भजनको" ⊃ "भजन") — and the Latin markers keep
    /// whole-token discipline ("songwriter" must never fire "song").
    func testMusicGraphemeClusterMatchingIsPreserved() {
        XCTAssertEqual(KeywordIntentRule.match(transcript: "भजनको सुनाऊ")?.domain, .music)
        XCTAssertEqual(KeywordIntentRule.match(transcript: "गीतहरू सुनाऊ")?.domain, .music)
        XCTAssertNil(KeywordIntentRule.match(transcript: "play songs"),
                     "'songs' is outside the reviewed marker vocabulary — the plural stays out")
        XCTAssertNil(KeywordIntentRule.match(transcript: "i am a songwriter"),
                     "whole-token Latin discipline: 'songwriter' must not fire 'song'")
    }

    // MARK: - Music rule ordering (strict ladder mirror)

    func testMusicRuleRunsAfterYoutubeAndBeforeAppLaunch() {
        // A YouTube-marked utterance keeps resolving as the strict
        // ladder would: the YouTube rule precedes music.
        XCTAssertEqual(KeywordIntentRule.match(transcript: "युट्युब खोल र गीत चलाऊ")?.domain,
                       .youtube)
        // A music request wins over a co-occurring launch word — the
        // music rule is ordered before every appLaunch rule.
        XCTAssertEqual(KeywordIntentRule.match(transcript: "गीत चलाऊ, क्यामेरा खोल")?.domain,
                       .music)
        // News still precedes both.
        XCTAssertEqual(KeywordIntentRule.match(transcript: "समाचार सुनाऊ, गीत पनि सुनाऊ")?.domain,
                       .news)
    }

    // MARK: - YouTube precedence under the music rule (FR-SP-005, ADR-SP-06)

    /// The shipped explicit-YouTube fixtures classify exactly as before
    /// and are never re-classified to music.
    func testYoutubeMarkedUtterancesStillMatchTheYoutubeDomainDataDriven() {
        let utterances: [(String, [String])] = [
            ("हाम्लाई युट्युबमा नेपाली न्युज चलाइदिनुस् न है त", ["युट्युब", "चलाइदिनुस्"]),
            ("search songs on youtube", ["youtube", "search"]),
            ("can you search youtube for old songs", ["youtube", "search"]),
            ("please play some bhajan on youtube for me", ["youtube", "play"]),
            // The matched verb key is the FULL enumerated form — the
            // pinned grapheme-cluster behaviour of 2026-09-07 means
            // "खोजिदिनुस्" does NOT contain a bare "खोज" substring, so
            // the first matching alternative is the form itself.
            ("युट्युबमा गीत खोजिदिनुस् न", ["युट्युब", "खोजिदिनुस्"])
        ]
        for (utterance, keys) in utterances {
            let match = KeywordIntentRule.match(transcript: utterance)
            XCTAssertEqual(match?.domain, .youtube,
                           "\(utterance) must stay a YouTube utterance")
            XCTAssertNotEqual(match?.domain, .music,
                              "\(utterance) must NEVER be re-classified to music (FR-SP-005)")
            XCTAssertEqual(match?.matchedKeys, keys)
        }
    }

    /// The ADR-SP-06 structural exclusion: an utterance carrying a
    /// YouTube marker is disqualified from the music rule even when the
    /// youtube rule itself declines it (these verbs are listen/sing
    /// verbs, not YouTube play/search verbs) — it falls through to the
    /// interpreter, never to music.
    func testYoutubeMarkedUtterancesAreNeverReclassifiedAsMusic() {
        for utterance in ["युट्युबमा गीत सुनाऊ", "युट्युबमा भजन सुनाऊ",
                          "युट्युबमा गीत गाऊ", "youtube song singing",
                          "on youtube music listen"] {
            XCTAssertNil(KeywordIntentRule.match(transcript: utterance),
                         "\(utterance) carries a YouTube marker — never the music domain")
        }
    }

    // MARK: - Music query extraction (design §14 fixtures, pinned)

    func testMusicQueryExtractsTheSongDataDriven() {
        let fixtures: [(String, String)] = [
            ("भजन बजाऊ", "भजन"),
            ("पुरानो हिन्दी गीत बजाऊ", "पुरानो हिन्दी"),
            ("देवीको भजन", "देवीको"),
            ("युट्युबमा गीत चलाऊ", "गीत"),
            ("play a song", "song"),
            ("स्पोटिफाइमा गीत चलाऊ", "गीत"),
            ("गीत चलाऊ", "गीत"),
            ("भजन बजाउनुस्", "भजन"),
            ("रामायणको भजन लगाइदेऊ", "रामायणको"),
            ("नयाँ गीत सुनाउनुस्", "नयाँ")
        ]
        for (utterance, query) in fixtures {
            XCTAssertEqual(KeywordIntentRule.musicQuery(from: utterance), query,
                           "\(utterance) must extract \"\(query)\"")
        }
    }

    /// The provider and YouTube marker morphemes are query noise: no
    /// music search may search for "spotify" or "youtube", and a fused
    /// Devanagari token is dropped whole.
    func testMusicQueryDropsProviderAndYoutubeMarkers() {
        XCTAssertEqual(KeywordIntentRule.musicQuery(from: "spotify गीत बजाऊ"), "गीत")
        XCTAssertEqual(KeywordIntentRule.musicQuery(from: "गीत चलाऊ युट्युबमा"), "गीत")
        XCTAssertEqual(KeywordIntentRule.musicQuery(from: "स्पोटिफाइमा भजन सुनाऊ"), "भजन")
    }

    /// Romanized Nepali particles and play verbs are query noise exactly
    /// like their Devanagari twins: device evidence 2026-10-11 — the
    /// v6-q6 on-device STT transcribed "युट्युबमा नेपाली गीत लगाऊ" as
    /// "maa nepali geet la" and मा/लगाऊ leaked into the search box in
    /// Latin script. Whole-token only: "ma" must not eat "mama".
    func testMusicQueryDropsRomanizedNepaliTokens() {
        XCTAssertEqual(KeywordIntentRule.musicQuery(from: "maa nepali geet la"), "nepali geet")
        XCTAssertEqual(KeywordIntentRule.musicQuery(from: "youtube maa nepali geet lagauda"),
                       "nepali geet")
        XCTAssertEqual(KeywordIntentRule.musicQuery(from: "mero geet lagau"), "geet")
        XCTAssertEqual(KeywordIntentRule.musicQuery(from: "mama"), "mama",
                       "whole-token drops: a real query token containing \"ma\" survives")
    }

    /// L2-D10: the extractor never leaves an empty query — when every
    /// token is scaffolding, the first music-marker token is searched;
    /// when there is none, the raw transcript's tokens stand in.
    /// Returns nil only when the input canonicalizes to nothing.
    func testMusicQueryFallbacksAndCap() {
        XCTAssertEqual(KeywordIntentRule.musicQuery(from: "चलाऊ"), "चलाऊ",
                       "no marker token → the raw transcript's tokens stand in (L2-D10 step 3)")

        let long = Array(repeating: "रामायण", count: 60).joined(separator: " ")
        XCTAssertEqual(KeywordIntentRule.musicQuery(from: long)?.count,
                       KeywordIntentRule.maxMusicQueryLength)
        XCTAssertEqual(KeywordIntentRule.musicQuery(from: long, maxLength: 12)?.count, 12)

        XCTAssertNil(KeywordIntentRule.musicQuery(from: ""))
        XCTAssertNil(KeywordIntentRule.musicQuery(from: "   "))
        XCTAssertNil(KeywordIntentRule.musicQuery(from: "। ॥"))
    }

    // MARK: - mentionsMusic: the contact-search veto predicate (C-SP-08)

    /// The veto fires on the SHARED marker family — the same
    /// alternatives the rule is gated by — and canonicalizes
    /// internally, so it is order-independent relative to the route's
    /// own canonicalization.
    func testMentionsMusicIsTrueOnTheMusicVocabularyDataDriven() {
        for text in ["गीत चलाऊ", "भजन बजाऊ", "play a song", "संगीत सुनाऊ",
                     "सङ्गीत बजाऊ", "युट्युबमा गीत खोज", "भजनको",
                     "गीतहरू बजाउनुहोस्", "  Bhajan   Bajau "] {
            XCTAssertTrue(KeywordIntentRule.mentionsMusic(text),
                          "\(text) carries a music marker — the veto must fire")
        }
    }

    /// The non-over-block proof (design §15): a contact request without
    /// a music marker is untouched by the veto, and the Latin markers
    /// keep whole-token discipline ("songs" is not "song").
    func testMentionsMusicIsFalseWithoutAMarkerDataDriven() {
        for text in ["आरवलाई फोन गर", "call ram", "मेरो छोरालाई फोन लगाऊ",
                     "अलार्म बजाऊ", "समाचार सुनाऊ", "youtube खोज",
                     "play songs", "search videos"] {
            XCTAssertFalse(KeywordIntentRule.mentionsMusic(text),
                           "\(text) carries no music marker — the veto must not fire")
        }
    }

    // MARK: - Safety pins: relaxed rules never claim safety vocabulary

    func testRelaxedRulesNeverClaimSafetyCriticalPhrasesDataDriven() {
        // Emergency, medication, alarm/timer, and call vocabulary carry
        // none of the required keyword sets — and the router's ladder
        // runs every safety stage before this table is ever consulted.
        for utterance in [
            "मद्दत गर्नुहोस्", "help me", "i fell",
            "मैले औषधि खाएँ", "i took my medication",
            "बिहान ६ बजे उठाउनुहोस्", "पाँच मिनेटको टाइमर लगाऊ",
            "अलार्म बन्द गर", "टाइमर रोक",
            "छोरालाई फोन गर", "call my daughter"
        ] {
            XCTAssertNil(KeywordIntentRule.match(transcript: utterance),
                         "\(utterance) must never be claimed by a relaxed rule")
        }
    }

    // MARK: - The medication photo query ([MED-PHOTO] 2026-09-17)

    /// The vocabulary the router hands the rule: an entry's name plus the
    /// words its purpose covers, exactly as `MedicationVoiceVocabulary`
    /// produces them for the live schedule. Passed IN — the rule holds no
    /// medicine of its own — so these tests are the whole of its drug
    /// knowledge.
    private let bloodPressureEntry = ["amlodipine", "रक्तचाप", "blood pressure", "pressure"]
    private let nepaliNamedEntry = ["डाइलोक्सिन"]

    /// A medicine the elder actually has, asked about by NAME: the query
    /// lexeme and the name co-occur, in either language and in noisy
    /// surrounding text.
    func testMedicationPhotoFiresOnAMedicationNameDataDriven() {
        let utterances = [
            "amlodipine कस्तो छ?",
            "हेर, amlodipine कस्तो छ त",
            "what does amlodipine look like",
            "amlodipine looks like what?",
            "kun ho amlodipine",
            "मेरो डाइलोक्सिन कस्तो देखिन्छ?"
        ]
        for utterance in utterances {
            let names = utterance.contains("डाइलोक्सिन") ? nepaliNamedEntry : bloodPressureEntry
            XCTAssertEqual(KeywordIntentRule.match(transcript: utterance,
                                                   medicationNames: names)?.domain,
                           .medicationPhoto,
                           "\(utterance) must resolve to the photo query")
        }
    }

    /// ...and by what it is FOR: a purpose word is a key like any other, so
    /// "रक्तचापको औषधि" (the blood-pressure medicine) asks about the entry
    /// filed under blood pressure without ever naming it.
    func testMedicationPhotoFiresOnAPurposeWordDataDriven() {
        for utterance in [
            "रक्तचापको औषधि कस्तो छ?",
            "blood pressure medicine looks like what?",
            "pressure kun ho",
            "मलाई रक्तचापको औषधि कस्तो देखिन्छ थाहा छैन"
        ] {
            XCTAssertEqual(KeywordIntentRule.match(transcript: utterance,
                                                   medicationNames: bloodPressureEntry)?.domain,
                           .medicationPhoto,
                           "\(utterance) names the medicine by its purpose — a purpose key is a key")
        }
    }

    /// The matched rule carries the query lexeme in `matchedKeys` and the
    /// medication key in `medicationName` — that is the string the router
    /// resolves back to the entry (or entries) carrying it, so its identity
    /// with the vocabulary is load-bearing. The medication key deliberately
    /// stays OUT of `matchedKeys`: that field feeds the
    /// `intent_keyword_match` event, which carries fixed rule vocabulary
    /// only, and a medication name is the household's health data.
    func testMedicationPhotoMatchCarriesTheQueryKeyAndTheMedicationKey() {
        let match = KeywordIntentRule.match(transcript: "रक्तचापको औषधि कस्तो छ?",
                                            medicationNames: bloodPressureEntry)

        XCTAssertEqual(match, KeywordIntentRule.Match(domain: .medicationPhoto,
                                                      matchedKeys: ["कस्तो छ"],
                                                      medicationName: "रक्तचाप"))
        XCTAssertEqual(match?.matchedKeys, ["कस्तो छ"],
                       "no schedule-derived key may ride the fixed-vocabulary event field")
    }

    /// Devanagari postpositions fuse onto the stem ("रक्तचापको" ⊃
    /// "रक्तचाप") — the phrase mode of the 2026-09-07 grapheme rule, which
    /// is why a chip need only ship the bare stem.
    func testDevanagariPurposeKeysMatchWithFusedPostpositions() {
        XCTAssertEqual(KeywordIntentRule.match(transcript: "रक्तचापको औषधि कस्तो छ",
                                               medicationNames: bloodPressureEntry)?
                        .medicationName,
                       "रक्तचाप")
        XCTAssertEqual(KeywordIntentRule.match(transcript: "सास फेर्नको औषधि कुन हो",
                                               medicationNames: ["सास फेर्न", "सास"])?
                        .medicationName,
                       "सास फेर्न")
    }

    /// Whole-token discipline for the single Latin words: the same rule
    /// that keeps "news" out of "newspaper" keeps "pain" out of "paint" and
    /// "sleep" out of "sleepy" — a wrong photo is worse than no photo.
    func testSingleLatinPurposeWordsMatchWholeTokensOnly() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "the paint looks like this",
                                             medicationNames: ["pain"]))
        XCTAssertNil(KeywordIntentRule.match(transcript: "i am sleepy, kun ho?",
                                             medicationNames: ["sleep"]))
        XCTAssertEqual(KeywordIntentRule.match(transcript: "pain kun ho",
                                               medicationNames: ["pain"])?.domain,
                       .medicationPhoto)
    }

    /// Multi-word keys match as phrases, because a two-word key can never
    /// equal one whitespace token.
    func testMultiWordVocabularyKeysMatchAsPhrases() {
        XCTAssertEqual(KeywordIntentRule.match(transcript: "my blood pressure tablet कस्तो छ",
                                               medicationNames: ["blood pressure"])?.domain,
                       .medicationPhoto)
        XCTAssertNil(KeywordIntentRule.match(transcript: "my blood test result कस्तो छ",
                                             medicationNames: ["blood pressure"]),
                     "the phrase is the key, not its first word")
    }

    /// BOTH halves are required. A question with no medication in it never
    /// fires — the rule must not guess which medicine was meant.
    func testMedicationPhotoNeverFiresWithoutAMedicationWord() {
        for utterance in ["कस्तो छ?", "यो औषधि कस्तो छ?",
                          "what does it look like", "kun ho", "कुन हो"] {
            XCTAssertNil(KeywordIntentRule.match(transcript: utterance,
                                                 medicationNames: bloodPressureEntry),
                         "\(utterance) asks about no medicine in particular — never a guess")
        }
    }

    /// ...and naming a medicine is not a question. Without a query lexeme
    /// the utterance resolves to nothing, exactly as it did before this
    /// rule existed.
    func testMedicationPhotoNeverFiresOnAMedicationWithoutAQuery() {
        for utterance in ["amlodipine", "रक्तचापको औषधि",
                          "मैले amlodipine खाएँ", "रक्तचापको औषधि खानु पर्छ",
                          "amlodipine is in the blue box"] {
            XCTAssertNil(KeywordIntentRule.match(transcript: utterance,
                                                 medicationNames: bloodPressureEntry),
                         "\(utterance) mentions a medicine but asks nothing — no photo")
        }
    }

    /// The empty vocabulary is what every pre-existing caller gets: with no
    /// medications the rule goes quiet for every utterance shape, including
    /// the ones that would otherwise fire.
    func testEmptyVocabularyNeverFiresTheRule() {
        for utterance in ["कस्तो छ?", "amlodipine कस्तो छ", "blood pressure kun ho",
                          "what does amlodipine look like"] {
            XCTAssertNil(KeywordIntentRule.match(transcript: utterance),
                         "no medications → no vocabulary → the rule can never match: \(utterance)")
        }
    }

    /// Ordering: the medication rule is evaluated LAST, after the whole
    /// static table. An utterance that also satisfies an earlier rule
    /// resolves to that earlier rule, mirroring the ladder.
    func testMedicationPhotoRunsLast() {
        XCTAssertEqual(KeywordIntentRule.match(transcript: "समाचार सुनाऊ, amlodipine कस्तो छ",
                                               medicationNames: bloodPressureEntry)?.domain,
                       .news)
        XCTAssertEqual(KeywordIntentRule.match(transcript: "युट्युबमा गीत चलाऊ, amlodipine कस्तो छ",
                                               medicationNames: bloodPressureEntry)?.domain,
                       .youtube)
    }

    // MARK: - [MTC] Extractor provenance and the wrapper (T-130, FR-MTC-002)

    /// Gherkin — "A marker-only request is flagged degenerate with no
    /// query". The music verb plus the generic bhajan marker survives
    /// only as the never-empty marker fallback: the provenance is
    /// `.markerFallback` and the outcome is degenerate. The fallback
    /// query itself stays the bare marker byte-for-byte — FR-MTC-002
    /// names exactly this case ("भजन बजाऊ" → query "भजन", the
    /// degenerate marker fallback the probe trigger reads).
    func testMarkerOnlyRequestIsFlaggedDegenerateWithNoContentQuery() {
        for (utterance, marker) in [("भजन बजाऊ", "भजन"),
                                    ("गीत चलाऊ", "गीत"),
                                    ("गाना बजाऊ", "गाना"),
                                    ("भजन गाउनुस्", "भजन"),
                                    ("play a song", "song")] {
            let outcome = KeywordIntentRule.musicQueryOutcome(from: utterance)
            XCTAssertEqual(outcome.provenance, .markerFallback,
                           "\(utterance): only the marker survives the drop sets")
            XCTAssertNotEqual(outcome.provenance, .content,
                              "\(utterance) carries no content query")
            XCTAssertTrue(outcome.isDegenerate,
                          "\(utterance) must probe — the bare marker is not a query")
            XCTAssertEqual(outcome.query, marker,
                           "\(utterance): the fallback queries the marker token itself (byte-parity)")
        }
    }

    /// Gherkin — "A specific request keeps the content provenance": the
    /// occasion/artist phrase before the music verb survives the drop
    /// sets, so the provenance is `.content`, the degenerate flag is
    /// clear and the query is the specific phrase.
    func testSpecificRequestKeepsTheContentProvenance() {
        let outcome = KeywordIntentRule.musicQueryOutcome(from: "दशैं दुर्गा भजन बजाऊ")
        XCTAssertEqual(outcome.provenance, .content)
        XCTAssertFalse(outcome.isDegenerate)
        XCTAssertEqual(outcome.query, "दशैं दुर्गा")

        let english = KeywordIntentRule.musicQueryOutcome(from: "play the old hindi song")
        XCTAssertEqual(english.provenance, .content)
        XCTAssertFalse(english.isDegenerate)
        XCTAssertEqual(english.query, "old hindi")
    }

    /// Gherkin — "A canonical empty result falls back to the transcript
    /// without a query". The transcript fallback's two shapes: an
    /// utterance whose every token is scaffolding and carries no marker
    /// reports the raw tokens as the stand-in query (the shipped L2-D10
    /// step 3 — "चलाऊ" → "चलाऊ", degenerate); an input that
    /// canonicalizes to nothing is the one shape that reports the
    /// transcript fallback with NO query at all.
    func testCanonicalEmptyResultFallsBackToTheTranscriptWithoutAQuery() {
        let framingOnly = KeywordIntentRule.musicQueryOutcome(from: "चलाऊ")
        XCTAssertEqual(framingOnly.provenance, .transcriptFallback)
        XCTAssertTrue(framingOnly.isDegenerate)
        XCTAssertEqual(framingOnly.query, "चलाऊ",
                       "no marker — the raw transcript's tokens stand in (L2-D10 step 3)")

        for empty in ["", "   ", "। ॥"] {
            let outcome = KeywordIntentRule.musicQueryOutcome(from: empty)
            XCTAssertEqual(outcome.provenance, .transcriptFallback,
                           "\"\(empty)\" canonicalizes empty")
            XCTAssertNil(outcome.query)
            XCTAssertTrue(outcome.isDegenerate,
                          "an absent query is degenerate by definition")
        }
    }

    /// Gherkin — "The compatibility wrapper is byte-identical". The full
    /// existing fixture corpus — the shipped extraction fixtures, the
    /// provider drops, the fallbacks, the cap and the empty inputs —
    /// returns exactly what it returned before the provenance landed:
    /// `musicQuery` is a thin wrapper over `musicQueryOutcome(...).query`.
    /// The historical literals are asserted beside the parity, so a
    /// wrapper cannot satisfy the test by drifting consistently.
    func testMusicQueryWrapperMatchesOutcome() {
        let fixtures = [
            "भजन बजाऊ", "पुरानो हिन्दी गीत बजाऊ", "देवीको भजन",
            "युट्युबमा गीत चलाऊ", "play a song", "स्पोटिफाइमा गीत चलाऊ",
            "गीत चलाऊ", "भजन बजाउनुस्", "रामायणको भजन लगाइदेऊ", "नयाँ गीत सुनाउनुस्",
            "spotify गीत बजाऊ", "गीत चलाऊ युट्युबमा", "स्पोटिफाइमा भजन सुनाऊ",
            "चलाऊ", "कृपया बजाऊ", "अलार्म बजाऊ",
            "  भजन   बजाऊ  ",
            "", "   ", "। ॥"
        ]
        let shippedValues: [String: String?] = [
            "भजन बजाऊ": "भजन",
            "पुरानो हिन्दी गीत बजाऊ": "पुरानो हिन्दी",
            "देवीको भजन": "देवीको",
            "युट्युबमा गीत चलाऊ": "गीत",
            "play a song": "song",
            "स्पोटिफाइमा गीत चलाऊ": "गीत",
            "गीत चलाऊ": "गीत",
            "भजन बजाउनुस्": "भजन",
            "रामायणको भजन लगाइदेऊ": "रामायणको",
            "नयाँ गीत सुनाउनुस्": "नयाँ",
            "spotify गीत बजाऊ": "गीत",
            "गीत चलाऊ युट्युबमा": "गीत",
            "स्पोटिफाइमा भजन सुनाऊ": "भजन",
            "चलाऊ": "चलाऊ",
            "कृपया बजाऊ": "कृपया बजाऊ",
            "  भजन   बजाऊ  ": "भजन",
            "": nil, "   ": nil, "। ॥": nil
        ]
        for fixture in fixtures {
            XCTAssertEqual(KeywordIntentRule.musicQuery(from: fixture),
                           KeywordIntentRule.musicQueryOutcome(from: fixture).query,
                           "\(fixture): the wrapper is the outcome's query, byte-identical")
            if let shipped = shippedValues[fixture] {
                XCTAssertEqual(KeywordIntentRule.musicQuery(from: fixture), shipped,
                               "\(fixture): the shipped value is unchanged")
            }
        }

        // The cap leg: the wrapper forwards `maxLength` unchanged.
        let long = Array(repeating: "रामायण", count: 60).joined(separator: " ")
        XCTAssertEqual(KeywordIntentRule.musicQuery(from: long, maxLength: 12),
                       KeywordIntentRule.musicQueryOutcome(from: long, maxLength: 12).query)
        XCTAssertEqual(KeywordIntentRule.musicQuery(from: long, maxLength: 12)?.count, 12)
        XCTAssertEqual(KeywordIntentRule.musicQuery(from: long)?.count,
                       KeywordIntentRule.maxMusicQueryLength)
    }

    // MARK: - [MTC] Near-match readings (T-130, design-l2 §13b)

    /// Gherkin — "Near-match readings are bounded and deduplicated": at
    /// most one entry per domain, only the four framable domains
    /// {news, youtube, music, appLaunch} participate, and the
    /// medication family is never returned.
    func testNearMatchReadingsAreBoundedAndDeduplicated() {
        // Several families partially match in one utterance: YouTube's
        // word without a YouTube verb, and the camera's word without an
        // open verb. Table order: youtube precedes appLaunch.
        XCTAssertEqual(KeywordIntentRule.nearMatches(transcript: "युट्युब क्यामेरा"), [
            KeywordIntentRule.NearMatch(domain: .youtube,
                                        matchedKeys: ["युट्युब"], appID: nil),
            KeywordIntentRule.NearMatch(domain: .appLaunch,
                                        matchedKeys: ["क्यामेरा"], appID: "camera")
        ])

        // Two app-launch rules could partially match ("क्यामेरा" and
        // "फोटो"); the domain still reports ONE entry — the first
        // partial variant in table order wins.
        XCTAssertEqual(KeywordIntentRule.nearMatches(transcript: "क्यामेरा फोटो"), [
            KeywordIntentRule.NearMatch(domain: .appLaunch,
                                        matchedKeys: ["क्यामेरा"], appID: "camera")
        ])

        // A news word and a music marker pair up: one entry each.
        XCTAssertEqual(KeywordIntentRule.nearMatches(transcript: "समाचार गीत"), [
            KeywordIntentRule.NearMatch(domain: .news, matchedKeys: ["समाचार"], appID: nil),
            KeywordIntentRule.NearMatch(domain: .music, matchedKeys: ["गीत"], appID: nil)
        ])

        // The bound and the domain restriction hold over the corpus.
        let framable: Set<KeywordIntentRule.Domain> = [.news, .youtube, .music, .appLaunch]
        for utterance in ["युट्युब क्यामेरा", "समाचार गीत", "भजन", "क्यामेरा फोटो",
                          "कहिले", "शिवरात्रि", "रक्तचापको औषधि कस्तो छ"] {
            let matches = KeywordIntentRule.nearMatches(transcript: utterance)
            XCTAssertEqual(Set(matches.map(\.domain)).count, matches.count,
                           "\(utterance): one entry per domain")
            XCTAssertLessThanOrEqual(matches.count, 4, "\(utterance): four domains, four entries")
            for match in matches {
                XCTAssertTrue(framable.contains(match.domain),
                              "\(utterance): \(match.domain) is not a framable domain")
            }
        }

        // Medication-family rules are never returned: `nearMatches`
        // takes no medication vocabulary at all, so no probe can ever
        // be framed around a medication command.
        XCTAssertTrue(KeywordIntentRule.nearMatches(
            transcript: "रक्तचापको औषधि कस्तो छ").isEmpty)
        XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: "").isEmpty)
        XCTAssertTrue(KeywordIntentRule.nearMatches(transcript: "   ").isEmpty)
    }

    // MARK: - [MTC] Scaffold and marker accessors (T-130, design-l2 §13c)

    /// Gherkin — "Scaffold and marker accessors split framing words from
    /// content": the marker tokens are excluded from scaffold content
    /// (they are kept in the free-text fallback and dropped only through
    /// the marker-dropped variant), and the existing drop-word behaviour
    /// is unchanged — both accessors read the same tables the extractor
    /// has always read.
    func testScaffoldAndMarkerAccessorsSplitFramingWordsFromContent() {
        // Scaffold = a drop token that is NOT a marker.
        for scaffold in ["बजाऊ", "चलाऊ", "सुनाऊ", "गाऊ", "play", "listen",
                         "कृपया", "हजुर", "मा", "युट्युबमा", "स्पोटिफाइमा"] {
            XCTAssertTrue(KeywordIntentRule.isMusicScaffoldToken(scaffold),
                          "\(scaffold) is framing, not content")
        }
        for marker in ["भजन", "भजनको", "गीत", "गीतहरू", "गाना", "संगीत", "सङ्गीत",
                       "music", "song", "bhajan"] {
            XCTAssertTrue(KeywordIntentRule.isMusicMarkerToken(marker),
                          "\(marker) is a marker token")
            XCTAssertFalse(KeywordIntentRule.isMusicScaffoldToken(marker),
                           "\(marker) is a MARKER — markers are never scaffold")
        }
        for content in ["रामायण", "देवीको", "दुर्गा", "songs", "songwriter", "गीता"] {
            XCTAssertFalse(KeywordIntentRule.isMusicScaffoldToken(content),
                           "\(content) is content — neither a drop nor a marker")
            XCTAssertFalse(KeywordIntentRule.isMusicMarkerToken(content),
                           "\(content) is outside the marker family")
        }

        // V3's shape from the predicates alone: "दुर्गा भजन बजाऊ" —
        // the scaffold strip keeps the marker (content + marker), and
        // the marker-dropped variant is exactly the catalog alias
        // "दुर्गा" the repetition capture matches.
        let tokens = "दुर्गा भजन बजाऊ".split(separator: " ").map(String.init)
        let scaffoldStripped = tokens.filter { !KeywordIntentRule.isMusicScaffoldToken($0) }
        XCTAssertEqual(scaffoldStripped, ["दुर्गा", "भजन"])
        XCTAssertEqual(scaffoldStripped.filter { !KeywordIntentRule.isMusicMarkerToken($0) },
                       ["दुर्गा"])

        // V4/V6's shape: no scaffold token is present, so the strip is
        // the identity and the markers stay in the value
        // ("दशैं दुर्गा भजन" survives whole).
        let freeText = "दशैं दुर्गा भजन".split(separator: " ").map(String.init)
        XCTAssertEqual(freeText.filter { !KeywordIntentRule.isMusicScaffoldToken($0) }, freeText)
    }
}
