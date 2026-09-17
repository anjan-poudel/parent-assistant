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
        for utterance in ["play some music", "play", "गीत चलाऊ", "अलार्म बजाऊ", "search songs"] {
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
}
