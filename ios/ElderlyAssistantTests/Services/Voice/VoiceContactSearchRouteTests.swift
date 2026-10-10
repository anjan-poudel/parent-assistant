import XCTest
@testable import ElderlyAssistant

/// Pure decision/extraction tests for the deterministic contact-search
/// pre-route (voice-contact-search, 2026-09-07). Everything here is
/// string-in/string-out — no audio, no coordinator, no interpreter.
final class VoiceContactSearchRouteTests: XCTestCase {

    // MARK: - Devanagari (primary flow)

    func testDevanagariPossessiveSearchExtractsName() {
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "मैयाको फोन नम्बर खोज"),
                       .openPhone("मैया"))
    }

    func testDevanagariNoSpaceFusedSpelling() {
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "मैयाको फोननम्बर खोज"),
                       .openPhone("मैया"))
    }

    func testDevanagariSearchVerbVariantsAllMatch() {
        // Grapheme rule (2026-09-07): the virama/matra fuses into the
        // ज, so खोज्नुहोस् / खोजेर / खोजिदिनुहोस् do NOT contain the
        // bare "खोज" — each verb form is enumerated in the marker and
        // drop tables. These utterances pin that enumeration.
        for utterance in ["मैयाको फोन नम्बर खोज्नुहोस्",
                          "कृपया मैयाको नम्बर खोजिदिनुहोस्",
                          "मैयाको फोन नम्बर खोजेर दिनुहोस्"] {
            XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: utterance),
                           .openPhone("मैया"), utterance)
        }
    }

    func testKinshipAddressAfterNameIsDroppedFromQuery() {
        // "मैया दिदी" — दिदी is address, not identity; the query keeps
        // the name so it matches the stored contact.
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "मैया दिदीको फोन नम्बर खोज"),
                       .openPhone("मैया"))
    }

    func testLoneKinshipQueryIsKept() {
        // A lone kinship word stays — UnifiedContactSearch's relationship
        // tier resolves "दिदी" on its own.
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "दिदीको फोन नम्बर खोज"),
                       .openPhone("दिदी"))
    }

    func testGiveMeTheNumberIsASearch() {
        // "फोन नम्बर दिनुहोस्" carries the फोन नम्बर marker — showing
        // the number means running the search.
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "मैयाको फोन नम्बर दिनुहोस्"),
                       .openPhone("मैया"))
    }

    func testGreetingPrefixIsStripped() {
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "नमस्ते, मैयाको फोन नम्बर खोज"),
                       .openPhone("मैया"))
    }

    func testDevanagariDigitQuerySurvivesNormalization() {
        // Devanagari digits fold to ASCII through NepaliTextNormalizer.
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "९८४१ नम्बर खोज"),
                       .openPhone("9841"))
    }

    func testSearchShapedUtteranceWithoutNameOpensUnprefilled() {
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "फोन नम्बर खोज"),
                       .openPhone(nil))
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "नम्बर खोज"),
                       .openPhone(nil))
    }

    // MARK: - Romanized / English

    func testRomanizedSearchExtractsName() {
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "maiya ko phone khoja"),
                       .openPhone("maiya"))
    }

    func testPossessiveApostropheIsStripped() {
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "look up maiya's number"),
                       .openPhone("maiya"))
    }

    func testEnglishSearchPhrases() {
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "contact search ram"),
                       .openPhone("ram"))
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "find ram phone number"),
                       .openPhone("ram"))
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "ram ko number khoja"),
                       .openPhone("ram"))
    }

    func testMixedKinshipEnglishQuery() {
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "find maiya sister's number"),
                       .openPhone("maiya"))
    }

    func testCaseInsensitiveRouting() {
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "MAIYA KO PHONE KHOJA"),
                       .openPhone("maiya"))
    }

    // MARK: - Direct-call veto (call utterances are NEVER a search)

    func testPhoneNumberDialPhraseIsVetoed() {
        // Golden-corpus CALL intent — the marker "फोन नम्बर" is inside it
        // but the veto runs first.
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "फोन नम्बर लगाऊ"),
                       .notSearch)
    }

    func testCallVerbPhrasesAreVetoed() {
        for utterance in ["छोरालाई फोन गर",
                          "मैयालाई फोन गर्नुहोस्",
                          "मैयालाई फोन लगाऊ",
                          "मैयालाई कल गर",
                          "मैयासँग भिडियो कल गर"] {
            XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: utterance),
                           .notSearch, utterance)
        }
    }

    func testEnglishCallPhrasesAreVetoed() {
        for utterance in ["call maiya", "please call maiya", "video call maiya",
                          "dial maiya's number", "make a phone call to maiya"] {
            XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: utterance),
                           .notSearch, utterance)
        }
    }

    // MARK: - Non-search phone talk never opens the screen

    func testEverydayPhoneTalkIsNotASearch() {
        // Bare Devanagari फोन/नम्बर are deliberately NOT markers: phone
        // talk ("my phone died", "first number…") must not open search.
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "मेरो फोन चार्ज भएन"),
                       .notSearch)
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "पहिलो नम्बर सम्झनुहोस्"),
                       .notSearch)
    }

    func testUnrelatedUtteranceIsNotASearch() {
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "आज मौसम कस्तो छ"),
                       .notSearch)
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "मैले औषधि खाएँ"),
                       .notSearch)
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: ""), .notSearch)
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "   "), .notSearch)
    }

    // MARK: - YouTube veto ([YOUTUBE] 2026-09-08)

    /// YouTube-marked utterances belong to the YouTube stage (which runs
    /// LATER in the ladder) — the bare "search"/"खोज" markers must never
    /// swallow them into a Phone-screen search.
    func testYouTubeShapedUtterancesAreNotContactSearches() {
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "search youtube for ram"),
                       .notSearch)
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "युट्युबमा गीत खोज"),
                       .notSearch)
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "युट्युबमा रामायण खोजिदिनुहोस्"),
                       .notSearch)
    }

    /// The veto must stay narrow: a genuine contact search that merely
    /// mentions a search verb still routes.
    func testNonYouTubeSearchStillRoutes() {
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "search for ram's number"),
                       .openPhone("ram"))
    }

    // MARK: - Music veto ([SPOTIFY] 2026-10-06 — design L2 §15, C-SP-08)

    /// Music-marked utterances belong to the music stage (which runs
    /// LATER in the ladder) — the bare "search"/"खोज" markers must
    /// never swallow them into a Phone-screen search. Pins Gherkin
    /// scenario "A music utterance is vetoed before contact search":
    /// the veto predicate fires, contact search does not, and the
    /// utterance proceeds toward the music path (the music rule claims
    /// it downstream).
    func testMusicShapedUtterancesAreNotContactSearches() {
        for utterance in ["गीत चलाऊ", "भजन बजाऊ", "play a song", "संगीत सुनाऊ"] {
            XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: utterance),
                           .notSearch, utterance)
            XCTAssertTrue(KeywordIntentRule.mentionsMusic(utterance),
                          "\(utterance) carries a music marker — the veto predicate must fire")
            XCTAssertEqual(KeywordIntentRule.match(transcript: utterance)?.domain, .music,
                           "\(utterance) proceeds toward the music path")
        }
    }

    /// The exact Gherkin shape: a SEARCH-marked utterance that also
    /// carries a music marker. The insertion is load-bearing here — the
    /// "खोज" / "फोन नम्बर" markers hit and a query survives extraction
    /// (pre-T-113 these opened the Phone screen prefilled), while the
    /// music veto leaves the utterance for the music path.
    func testSearchMarkerUtteranceWithMusicMarkerIsVetoed() {
        let utterance = "भजन खोज र सुनाऊ"
        XCTAssertTrue(KeywordIntentRule.mentionsMusic(utterance))
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: utterance),
                       .notSearch,
                       "the music veto must stop the search the खोज marker started")
        XCTAssertEqual(VoiceContactSearchRoute.extractQuery(from: utterance),
                       "भजन सुनाऊ",
                       "baseline artifact: this WAS the Phone-screen prefill before the veto")
        XCTAssertEqual(KeywordIntentRule.match(transcript: utterance)?.domain, .music,
                       "the utterance proceeds toward the music path")
    }

    /// F-6 residual (accepted trade-off; design §15, W1 review F-1): a
    /// contact whose name literally contains a FULL music marker is no
    /// longer reachable through a search-marker utterance carrying that
    /// name. "गीतमाया" contains "गीत" and "भजनलाई" contains "भजन" —
    /// the marker survives the grapheme clusters — so the veto fires
    /// and the search cannot run; the extractions below are what those
    /// utterances returned before the veto. Near-misses stay protected
    /// by the cluster semantics: "गीता" and "गीतांजलि" do NOT contain
    /// "गीत" (the final त carries the vowel sign), so their searches
    /// route exactly as before.
    func testFusedMarkerNamesAreTheKnownF6OverBlock() {
        // Known over-block — the F-6 trade-off this fixture documents.
        for (utterance, wouldHaveBeen) in [("गीतमायाको फोन नम्बर खोज", "गीतमाया"),
                                           ("भजनलाई फोन नम्बर खोज", "भजन")] {
            XCTAssertTrue(KeywordIntentRule.mentionsMusic(utterance),
                          "\(utterance) carries the fused marker — the veto fires")
            XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: utterance),
                           .notSearch, utterance)
            XCTAssertEqual(VoiceContactSearchRoute.extractQuery(from: utterance), wouldHaveBeen,
                           "pre-T-113 this extraction WAS the search query — F-6 accepts losing it")
        }
        // Near-miss protection (the reason the F-6 trade-off is narrow).
        for (utterance, name) in [("गीतालाई फोन नम्बर खोज", "गीता"),
                                  ("गीतांजलिलाई फोन नम्बर खोज", "गीतांजलि")] {
            XCTAssertFalse(KeywordIntentRule.mentionsMusic(utterance),
                           "\(utterance) must not match a music marker")
            XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: utterance),
                           .openPhone(name), utterance)
        }
    }

    /// Non-over-block proof (design §15): a contact request without a
    /// music marker matches no marker, so the veto stays quiet and
    /// every baseline decision holds. These are call-shaped, and the
    /// direct-call veto precedes the music veto — the outcome is
    /// identical with and without the insertion.
    func testMusicVetoDoesNotOverBlockContactRequests() {
        for utterance in ["आरवलाई फोन गर", "call ram", "मेरो छोरालाई फोन लगाऊ"] {
            XCTAssertFalse(KeywordIntentRule.mentionsMusic(utterance),
                           "\(utterance) carries no music marker — the veto must stay quiet")
            XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: utterance),
                           .notSearch, utterance)
        }
    }

    /// Position pin (design L2 §15): "युट्युबमा गीत खोज" matches BOTH
    /// vetoes. The reviewed contract places the music veto immediately
    /// after the YouTube veto; either ordering decides identically for
    /// double-matching utterances, because both paths return
    /// `.notSearch`. The YouTube fixtures keep behaving exactly as at
    /// baseline with the music veto in place.
    func testYoutubeVetoStillHoldsWithTheMusicVeto() {
        XCTAssertTrue(KeywordIntentRule.mentionsMusic("युट्युबमा गीत खोज"),
                      "the music veto would catch it too — the position cannot change the outcome")
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "युट्युबमा गीत खोज"),
                       .notSearch)
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "search youtube for ram"),
                       .notSearch)
        XCTAssertEqual(VoiceContactSearchRoute.decide(transcript: "युट्युबमा रामायण खोजिदिनुहोस्"),
                       .notSearch)
    }
}
