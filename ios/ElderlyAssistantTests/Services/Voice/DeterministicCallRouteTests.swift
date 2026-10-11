import XCTest
@testable import ElderlyAssistant

/// [DETERMINISTIC-CALL] (2026-10-11) Unit pins for the deterministic call
/// fallback's extraction: direct-call shape detection, name extraction
/// across both scripts and suffixes, call/app vocabulary dropping, and
/// the cases that must NOT extract (indefinite pronouns, non-call
/// utterances, containment traps).
final class DeterministicCallRouteTests: XCTestCase {

    // MARK: - Extraction

    func testDevanagariCallExtractsDativeStrippedName() {
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "छोरालाई फोन गर"),
                       .call(query: "छोरा"))
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "मैयालाई फोन गर्नुहोस्"),
                       .call(query: "मैया"))
    }

    func testLatinCallExtractsName() {
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "call maiya"),
                       .call(query: "maiya"))
    }

    func testRomanizedNepaliCallPhraseExtractsName() {
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "maiya lai phone gara"),
                       .call(query: "maiya"))
    }

    func testCallVerbsAndAppWordsAreDropped() {
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "video call maiya"),
                       .call(query: "maiya"))
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "ह्वाट्सएपमा फोन गर मैयालाई"),
                       .call(query: "मैया"))
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "भिडियो कल गर बाबालाई"),
                       .call(query: "बाबा"))
    }

    /// Every WhatsApp spelling in the router's vocabulary is a drop —
    /// "व्हाट्सएपमा कल गर" (golden-corpus spelling) must not leak the app
    /// word into the name query.
    func testAllWhatsAppSpellingsAreDropped() {
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "व्हाट्सएपमा कल गर"),
                       .callNoName)
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "ह्वाट्सएपमा फोन गर मैयालाई"),
                       .call(query: "मैया"))
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "वाट्सएपमा कल गर मैयालाई"),
                       .call(query: "मैया"))
    }

    /// The लगाऊ-family call verbs ("फोन लगाऊ", "नम्बर लगाऊ" — golden
    /// corpus) are dropped whole, so a nameless request stays nameless
    /// instead of resolving the verb as a contact.
    func testLagauFamilyVerbsAreDropped() {
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "फोन लगाऊ"),
                       .callNoName)
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "फोन नम्बर लगाऊ"),
                       .callNoName)
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "फोन लगाइदिनु"),
                       .callNoName)
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "मैयालाई फोन लगाइदेऊ"),
                       .call(query: "मैया"))
    }

    /// Golden-corpus call shapes resolve to the corpus contact.
    func testGoldenCorpusCallShapesExtract() {
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "छोरीलाई फोन गरिदेऊ"),
                       .call(query: "छोरी"))
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "भाइलाई कल गर"),
                       .call(query: "भाइ"))
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "नातिलाई फोन गर"),
                       .call(query: "नाति"))
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "call my son"),
                       .call(query: "son"))
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "मेरो परिवारलाई कल गर"),
                       .call(query: "परिवार"))
    }

    func testPossessiveAndPoliteDropsStillExtract() {
        // "मेरो" is a drop word in the shared extractor; the dative
        // "छोरालाई" still yields the name.
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "मेरो छोरालाई फोन गर"),
                       .call(query: "छोरा"))
    }

    func testKinshipWordAfterNameIsAddressNotIdentity() {
        // Same convention as the contact-search extractor: "मैया दिदी"
        // resolves "मैया" (a lone kinship word would stay, but here it
        // trails a real name).
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "मैया दिदीलाई फोन गर"),
                       .call(query: "मैया"))
    }

    // MARK: - No-name / negative cases

    func testBareCallPhraseIsNameUnclear() {
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "फोन गर"),
                       .callNoName)
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "call someone"),
                       .callNoName)
    }

    func testIndefinitePronounIsNameUnclear() {
        // "कसै" (someone) is a pronoun, not a contact — a call to "कसै"
        // must ask WHO, never run contact resolution on "कसै".
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "कसैलाई फोन गर"),
                       .callNoName)
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "कोहीलाई फोन गर"),
                       .callNoName)
    }

    func testNonCallUtterancesAreNotDirectCall() {
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "मेरो फोन कहाँ छ"),
                       .notDirectCall)
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "भोलिको मौसम कस्तो छ"),
                       .notDirectCall)
    }

    func testCallTokenContainmentNeverEatsAName() {
        // "कल" is dropped whole-token only — the name कल्याणी must
        // survive ("कल" ⊂ "कल्याणी").
        XCTAssertEqual(DeterministicCallRoute.decide(transcript: "कल्याणीलाई फोन गर"),
                       .call(query: "कल्याणी"))
    }
}
