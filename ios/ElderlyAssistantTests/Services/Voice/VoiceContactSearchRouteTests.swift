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
}
