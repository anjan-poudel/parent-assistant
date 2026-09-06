import XCTest
@testable import ElderlyAssistant

/// [NO-GIBBERISH] (2026-09-07) Unit tests for the pure `ReplySanityGate`.
///
/// Invariant: the assistant must NEVER speak garbage. Every rejection
/// class must be caught here (they are what `CommandRouter` turns into an
/// honest fallback + a `llama_response_rejected_sanity` event), and —
/// equally important — real Nepali and English sentences, including
/// matra-heavy Devanagari and legitimate punctuation, must PASS: a false
/// rejection is a poor experience, and combining marks must never be
/// mistaken for non-language content.
final class ReplySanityGateTests: XCTestCase {

    // MARK: - Empty

    func testEmptyAndWhitespaceOnlyAreRejected() {
        XCTAssertEqual(ReplySanityGate.rejectionReason(""), .empty)
        XCTAssertEqual(ReplySanityGate.rejectionReason("   "), .empty)
        XCTAssertEqual(ReplySanityGate.rejectionReason("\n\t  "), .empty)
    }

    // MARK: - Placeholder "answers"

    func testPlaceholderAnswersAreRejected() {
        XCTAssertEqual(ReplySanityGate.rejectionReason("null"), .jsonRemnant)
        XCTAssertEqual(ReplySanityGate.rejectionReason("NULL"), .jsonRemnant)
        XCTAssertEqual(ReplySanityGate.rejectionReason("nil"), .jsonRemnant)
        XCTAssertEqual(ReplySanityGate.rejectionReason("none"), .jsonRemnant)
        XCTAssertEqual(ReplySanityGate.rejectionReason("  None  "), .jsonRemnant)
    }

    func testRealNegationWordsAreNotPlaceholders() {
        // "no one"/"होइन" are language, not a JSON null in disguise.
        XCTAssertNil(ReplySanityGate.rejectionReason("no one"))
        XCTAssertNil(ReplySanityGate.rejectionReason("होइन"))
    }

    // MARK: - Control characters

    func testControlCharactersAreRejected() {
        XCTAssertEqual(ReplySanityGate.rejectionReason("hi\u{07}there"), .controlCharacters)
        XCTAssertEqual(ReplySanityGate.rejectionReason("line1\nline2"), .controlCharacters)
        XCTAssertEqual(ReplySanityGate.rejectionReason("a\u{00}b"), .controlCharacters)
        XCTAssertEqual(ReplySanityGate.rejectionReason("यो\u{9F}त्यो"), .controlCharacters)
    }

    // MARK: - Structural remnants (JSON leaking into speech)

    func testStraightQuotesBracesBracketsBackslashAreRejected() {
        XCTAssertEqual(ReplySanityGate.rejectionReason("he said \"hi\" to me"), .jsonRemnant)
        XCTAssertEqual(ReplySanityGate.rejectionReason("{\"intent\":\"query\"}"), .jsonRemnant)
        XCTAssertEqual(ReplySanityGate.rejectionReason("साथी {ठीक} छ"), .jsonRemnant)
        XCTAssertEqual(ReplySanityGate.rejectionReason("answer [x] found"), .jsonRemnant)
        XCTAssertEqual(ReplySanityGate.rejectionReason("back\\slash"), .jsonRemnant)
        XCTAssertEqual(ReplySanityGate.rejectionReason("दाहिने \u{005C} पट्टि"), .jsonRemnant)
    }

    func testApostrophesAndCurlyQuotesAreAllowed() {
        // Real language punctuation — never reject it.
        XCTAssertNil(ReplySanityGate.rejectionReason("it's a sunny day"))
        XCTAssertNil(ReplySanityGate.rejectionReason("उनले भने “हुन्छ” र हिँडे।"))
        XCTAssertNil(ReplySanityGate.rejectionReason("‘एकैछिन्’ भन्दै बस्थे।"))
    }

    // MARK: - Repetition

    func testTokenRepeatedMoreThanThreeTimesIsRejected() {
        XCTAssertEqual(ReplySanityGate.rejectionReason("हुन्छ हुन्छ हुन्छ हुन्छ"), .repetition)
        XCTAssertEqual(ReplySanityGate.rejectionReason("हुन्छ हुन्छ हुन्छ हुन्छ छ"), .repetition)
        XCTAssertEqual(ReplySanityGate.rejectionReason("yes yes yes yes"), .repetition)
        XCTAssertEqual(ReplySanityGate.rejectionReason("भोलि भोलि भोलि भोलि कस्तो छ"), .repetition)
    }

    func testTokenUpToThreeTimesPasses() {
        XCTAssertNil(ReplySanityGate.rejectionReason("हुन्छ हुन्छ हुन्छ"))
        XCTAssertNil(ReplySanityGate.rejectionReason("ठीक छ ठीक छ ठीक छ"))
    }

    func testConsecutiveRunLongerThanEightScalarsIsRejected() {
        XCTAssertEqual(ReplySanityGate.rejectionReason("aaaaaaaaaa"), .repetition)
        XCTAssertEqual(ReplySanityGate.rejectionReason("कककककककककक"), .repetition)
        XCTAssertEqual(ReplySanityGate.rejectionReason("होइन होइन होइन होइन होइन होइन"), .repetition)
        XCTAssertEqual(ReplySanityGate.rejectionReason("---------------------"), .repetition)
    }

    func testUnspacedSyllableLoopsAreRejected() {
        // Decoder loops often repeat a syllable/word with NO separators —
        // invisible to the token rule (one token) and to the run rule
        // (Devanagari loops alternate consonant/matra scalars). The
        // whole-string periodic check must catch them.
        XCTAssertEqual(ReplySanityGate.rejectionReason("हाहाहाहाहा"), .repetition)
        XCTAssertEqual(ReplySanityGate.rejectionReason("होइनहोइनहोइनहोइन"), .repetition)
        XCTAssertEqual(ReplySanityGate.rejectionReason("लललललललललल"), .repetition)
        XCTAssertEqual(ReplySanityGate.rejectionReason("abcabcabcabc"), .repetition)
    }

    func testSpacedReduplicationIsNotALoop() {
        // Legit Nepali reduplication ("बिस्तारै बिस्तारै" — slowly
        // slowly) repeats a word exactly TWICE with a space; it must not
        // trip the repetition rules.
        XCTAssertNil(ReplySanityGate.rejectionReason("बिस्तारै बिस्तारै हिँड्नुस्"))
        XCTAssertNil(ReplySanityGate.rejectionReason("दिनभरि दिनभरि काम भयो"))
        XCTAssertNil(ReplySanityGate.rejectionReason("घरघर गएर सोध्नुस्"))
    }

    // MARK: - Non-language soup

    func testDigitAndSymbolSoupIsRejected() {
        XCTAssertEqual(ReplySanityGate.rejectionReason("123456"), .nonLanguage)
        XCTAssertEqual(ReplySanityGate.rejectionReason("९:३०"), .nonLanguage)
        XCTAssertEqual(ReplySanityGate.rejectionReason("3.14 π 2.71"), .nonLanguage)
        XCTAssertEqual(ReplySanityGate.rejectionReason("!!! ??? ..."), .nonLanguage)
        XCTAssertEqual(ReplySanityGate.rejectionReason("😀😀😀😀😀"), .nonLanguage)
        XCTAssertEqual(ReplySanityGate.rejectionReason("12.5% 4.5% 6"), .nonLanguage)
    }

    func testDigitsInsideRealSentencesPass() {
        // Numbers inside language are fine — the strict majority is
        // letter-ish. This is what lets a pre-answer like "अहिले बिहान ९
        // बजेको छ।" through (and what the deterministic TopicPreAnswer
        // table is for, so the MODEL never needs bare-number replies).
        XCTAssertNil(ReplySanityGate.rejectionReason("अहिले बिहान ९ बजेको छ।"))
        XCTAssertNil(ReplySanityGate.rejectionReason("The appointment is at 3 pm tomorrow."))
        XCTAssertNil(ReplySanityGate.rejectionReason("म ८५ वर्षको भएँ।"))
    }

    // MARK: - Real language passes

    func testRealNepaliSentencesPass() {
        XCTAssertNil(ReplySanityGate.rejectionReason("हुन्छ"))
        XCTAssertNil(ReplySanityGate.rejectionReason("आज काठमाडौंमा मौसम बदली छ।"))
        XCTAssertNil(ReplySanityGate.rejectionReason("तपाईंका लागि केही राम्रा कुरा छन्।"))
        XCTAssertNil(ReplySanityGate.rejectionReason("मैले खाना खाएँ, अब आराम गर्छु।"))
        XCTAssertNil(ReplySanityGate.rejectionReason("ठीक छ — अब हिँड्ने बेला भयो।"))
    }

    func testRealEnglishSentencesPass() {
        XCTAssertNil(ReplySanityGate.rejectionReason("Tomorrow it will be sunny in Kathmandu."))
        XCTAssertNil(ReplySanityGate.rejectionReason("Your next dose is at 8 in the morning."))
        XCTAssertNil(ReplySanityGate.rejectionReason("Sure, I can help you with that."))
    }

    func testDevanagariCombiningMarksAreNeverTreatedAsNonLanguage() {
        // Matra-heavy line — combining marks (virama/matras) must count
        // toward the letter-ish majority, not against it.
        XCTAssertNil(ReplySanityGate.rejectionReason("कृष्णप्रसाद कोइरालाले भने"))
        XCTAssertNil(ReplySanityGate.rejectionReason("होइन, मलाई त्यो मन पर्दैन।"))
    }
}
