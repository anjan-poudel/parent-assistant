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
}
