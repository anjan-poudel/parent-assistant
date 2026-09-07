import XCTest
@testable import ElderlyAssistant

/// [INTENT-TOOLS] (2026-09-07) Deterministic calculator contract:
///  - fires ONLY on provable spoken arithmetic (symbols OR word forms),
///  - parses Devanagari AND Arabic digits with full precedence,
///  - never fires on anything that is not arithmetic (injection
///    rejection, veto vocabulary, single numbers, spelled numbers),
///  - division by zero is an honest `.divisionByZero` decision,
///  - replies echo the operation with localized words and Devanagari
///    digits under Nepali.
final class CalculatorToolTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")
    private let en = Locale(identifier: "en")

    // MARK: - Helpers

    private func result(of utterance: String) -> Double? {
        guard case .computed(let calculation)? = CalculatorTool.decide(utterance) else {
            return nil
        }
        return calculation.result
    }

    private func assertResult(_ utterance: String, _ expected: Double,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let value = result(of: utterance) else {
            XCTFail("no computed decision for \"\(utterance)\"", file: file, line: line)
            return
        }
        XCTAssertEqual(value, expected, accuracy: 1e-9,
                       "for \"\(utterance)\"", file: file, line: line)
    }

    private func assertNoFire(_ utterance: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(CalculatorTool.decide(utterance),
                     "must NOT fire for \"\(utterance)\"", file: file, line: line)
    }

    // MARK: - Devanagari + Arabic digits, plain questions

    func testDevanagariAdditionQuestionFires() {
        assertResult("५ जोड ३ कति हुन्छ?", 8)
        assertResult("कति हुन्छ ५ जोड ३?", 8)
    }

    func testArabicAndMixedDigitUtterances() {
        assertResult("5 plus 3", 8)
        assertResult("५+3", 8)          // glued Devanagari + symbol
        assertResult("५ + ३", 8)
        assertResult("७ - २", 5)
        assertResult("९८७ × २", 1974)
        assertResult("१० ÷ 2", 5)
        assertResult("5 x 3", 15)        // x between digits = times
    }

    func testDecimalsParseAndFormat() {
        assertResult("5.5 + 4.5", 10)
        assertResult("1.5 गुणा 2", 3)
        assertResult("10 / 4", 2.5)
    }

    // MARK: - Precedence, parentheses, powers

    func testOperatorPrecedence() {
        assertResult("2 + 3 * 4", 14)
        assertResult("2 * 3 + 4", 10)
        assertResult("10 - 2 * 3", 4)
        assertResult("10 / 2 + 3", 8)
        assertResult("2 * 3 ^ 2", 18)          // ^ binds tighter than *
        assertResult("2 + 3 - 1 + 4", 8)       // left-assoc chain
    }

    func testParenthesesOverridePrecedence() {
        assertResult("(2 + 3) * 4", 20)
        assertResult("2 + (3 * 4)", 14)
        assertResult("(2 + 3) गुणा 4", 20)     // spoken form, kept grouped
    }

    func testPowerIsRightAssociative() {
        assertResult("2^10", 1024)
        assertResult("2^3^2", 512)             // 2^(3^2), NOT (2^3)^2
    }

    func testUnaryMinus() {
        assertResult("-5 + 8", 3)
        assertResult("-2^2", -4)               // -(2^2), convention
        assertResult("10 - -3", 13)
    }

    func testModuloByWord() {
        assertResult("17 मोडुलो 5", 2)
        assertResult("17 modulo 5", 2)
    }

    // MARK: - Spoken word forms (Nepali + English)

    func testInfixWordOperators() {
        assertResult("५ जोड ७", 12)
        assertResult("५ घटाउ २", 3)
        assertResult("५ गुणा ७", 35)
        assertResult("५ भाग २", 2.5)
        assertResult("५ जोड ३ जोड ७", 15)     // verb chains collapse
    }

    func testDirectionalForms() {
        assertResult("१० लाई २ ले भाग गर", 5)
        assertResult("१० लाई २ ले भाग गर्नुहोस्", 5)
        assertResult("५ लाई ३ ले गुणा गर", 15)
        assertResult("५ मा ३ जोड", 8)
        assertResult("१० बाट ३ घटाउ", 7)
    }

    func testVerbFirstAndVerbLastWithConjunction() {
        assertResult("जोड ५ र ७", 12)
        assertResult("गुणा गर्नुहोस् ५ र ७", 35)
        assertResult("add 5 and 7", 12)
        assertResult("५ र ३ जोड्नुहोस्", 8)
        assertResult("१० र ४ घटाउनुहोस्", 6)
    }

    func testEnglishDirectedForms() {
        assertResult("divide 10 by 2", 5)
        assertResult("multiply 5 by 2", 10)
        assertResult("subtract 3 from 10", 7)
        assertResult("5 divided by 2", 2.5)
    }

    func testPercentConstructions() {
        assertResult("१०० को ५० प्रतिशत", 50)
        assertResult("10 percent of 200", 20)
    }

    func testPowerWordForms() {
        assertResult("२ को घात ३", 8)
        assertResult("2 to the power of 10", 1024)
    }

    // MARK: - Division by zero — honest decision, never a number

    func testDivisionByZeroIsAnHonestError() {
        XCTAssertEqual(CalculatorTool.decide("५ लाई ० ले भाग गर"), .divisionByZero)
        XCTAssertEqual(CalculatorTool.decide("10 / 0"), .divisionByZero)
        XCTAssertEqual(CalculatorTool.decide("10 भाग 0"), .divisionByZero)
        XCTAssertEqual(CalculatorTool.decide("5 + 3 / 0"), .divisionByZero,
                       "a division by zero ANYWHERE in a symbol chain is honest")
    }

    func testModuloByZeroIsAnHonestError() {
        XCTAssertEqual(CalculatorTool.decide("10 मोडुलो 0"), .divisionByZero)
    }

    func testDivisionByZeroErrorReplyIsLocalized() {
        XCTAssertEqual(L10n.str("calculator.error.divByZero", locale: ne),
                       "शून्यले भाग गर्न सकिँदैन।")
        XCTAssertEqual(L10n.str("calculator.error.divByZero", locale: en),
                       "You can't divide by zero.")
    }

    // MARK: - Injection rejection — anything not provably math never fires

    func testInjectionAttemptsNeverFire() {
        assertNoFire("5 plus 3 drop table")
        assertNoFire("५ जोड ३; rm -rf /")
        assertNoFire("5 + 3 सेना")
        assertNoFire("5 and 3 and payload()")
    }

    func testVetoVocabularyNeverFires() {
        // Call-ish vocabulary (mirrors CommandRouter.sensitiveCallPhrases).
        assertNoFire("फोन ५ जोड ३")
        assertNoFire("छोरालाई फोन गर ५ जोड ३")
        assertNoFire("call 5 plus 3")
        // Medication/reminder markers (mirrors TopicPreAnswer).
        assertNoFire("औषधि ५ जोड ३")
        assertNoFire("दवाई २ थान जोड १")
        assertNoFire("remind me 5 plus 3")
        // Clock talk — a time is not arithmetic.
        assertNoFire("बिहान ८ बजे")
        assertNoFire("कति बजे भयो ५ जोड ३")
        assertNoFire("५ मिनेट जोड ३")
    }

    func testNonArithmeticUtterancesNeverFire() {
        assertNoFire("कति हुन्छ?")
        assertNoFire("हिसाब गर")                 // trigger words alone — no numbers
        assertNoFire("९८४१")                     // a phone number, no operator
        assertNoFire("मेरो नम्बर ९८४१२३४५६७ हो")
        assertNoFire("५ जोड तीन")                 // spelled-out number word
        assertNoFire("५ जोड ३ रुपैयाँ")           // currency after the fact
        assertNoFire("(5+3")                      // unbalanced parens
        assertNoFire("5+")                        // dangling operator
        assertNoFire("भाग २ र ३")                 // "part 2 and 3" — not division
        assertNoFire("एपिसोड २ र ३")
        assertNoFire("20 साल ८ महिना ५ जोड")       // date-ish words kill it
        assertNoFire("घटाउ ५")                    // single operand
        assertNoFire("5 ! 3")                     // unknown operator
    }

    func testFullyWrappedBareNumberNeverFires() {
        assertNoFire("(5)")                       // digits but no operator
    }

    // MARK: - Spoken replies — echo + localization

    func testReplyEchoesOperationWithLocalizedWords() {
        guard case .computed(let calc)? = CalculatorTool.decide("५ जोड ३ कति हुन्छ?") else {
            return XCTFail("expected a computation")
        }
        XCTAssertEqual(CalculatorTool.reply(for: calc, locale: ne),
                       "५ जोड ३ बराबर ८ हुन्छ।")
        XCTAssertEqual(CalculatorTool.reply(for: calc, locale: en),
                       "5 plus 3 equals 8.")
    }

    func testReplyUsesAnswerOnlyFormWhenEchoWouldLie() {
        // "(2+3)*4" must never be read back as "2 जोड 3 गुणा 4" (=14).
        guard case .computed(let calc)? = CalculatorTool.decide("(2 + 3) * 4") else {
            return XCTFail("expected a computation")
        }
        XCTAssertEqual(CalculatorTool.reply(for: calc, locale: ne),
                       "जवाफ २० हुन्छ।")
        XCTAssertEqual(CalculatorTool.reply(for: calc, locale: en),
                       "The answer is 20.")
        // Powers and modulo likewise get the answer-only form.
        guard case .computed(let power)? = CalculatorTool.decide("2^10") else {
            return XCTFail("expected a computation")
        }
        XCTAssertEqual(CalculatorTool.reply(for: power, locale: ne),
                       "जवाफ १०२४ हुन्छ।")
    }

    func testReplyRendersDigitsInLocaleScript() {
        guard case .computed(let calc)? = CalculatorTool.decide("५ जोड ३") else {
            return XCTFail("expected a computation")
        }
        let nepali = CalculatorTool.reply(for: calc, locale: ne)
        // Exact-string + scalar assertions ONLY — deliberately not
        // `nepali.contains("5")`: on the iOS 18 runtime, Foundation's
        // string search (range(of:)/contains(String), default options)
        // matched the ASCII "5" INSIDE this pure-Devanagari string even
        // though no ASCII digit scalar exists in it (the same NSString
        // finds nothing with options [.literal]; == is exact). Diagnosed
        // 2026-09-07 while chasing a phantom failure — an NSString-backed
        // String from String(format:) exposes it; literals and == do not.
        XCTAssertEqual(nepali, "५ जोड ३ बराबर ८ हुन्छ।")
        XCTAssertFalse(nepali.unicodeScalars.contains { (0x30...0x39).contains($0.value) },
                       "Nepali reply must contain no ASCII digit scalars — got: \(nepali)")
        let english = CalculatorTool.reply(for: calc, locale: en)
        XCTAssertEqual(english, "5 plus 3 equals 8.")
        XCTAssertTrue(english.unicodeScalars.contains { (0x30...0x39).contains($0.value) },
                      "English reply must contain ASCII digits — got: \(english)")
    }

    func testDecimalReplyIsTrimmedForSpeech() {
        guard case .computed(let calc)? = CalculatorTool.decide("5.5 + 4.5") else {
            return XCTFail("expected a computation")
        }
        XCTAssertEqual(CalculatorTool.reply(for: calc, locale: en),
                       "5.5 plus 4.5 equals 10.")
    }

    func testMixedChainComputesAndGetsAnswerOnlySpeech() {
        // "५ जोड ३ घटाउ २" = 6. The phrase rewrites must group left to
        // right without changing the value, but the result keeps the
        // conservative answer-only form: the inner group is wrapped in
        // parentheses during rewriting, and once parentheses exist the
        // spoken word stream could not prove the grouping, so the echo
        // is disabled by design.
        guard case .computed(let calc)? = CalculatorTool.decide("५ जोड ३ घटाउ २ कति?") else {
            return XCTFail("expected a computation")
        }
        XCTAssertEqual(CalculatorTool.reply(for: calc, locale: ne),
                       "जवाफ ६ हुन्छ।")
    }
}
