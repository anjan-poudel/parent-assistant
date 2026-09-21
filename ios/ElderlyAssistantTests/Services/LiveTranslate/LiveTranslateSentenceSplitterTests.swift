import XCTest
@testable import ElderlyAssistant

/// [FOCUS-CAPTURE] The sentence splitter: one recognized block, cut into the
/// pieces the tiers were measured on.
///
/// Two claims are worth a suite of their own, and both are the reason the type
/// exists rather than a `components(separatedBy:)` call at the call site:
///
///  1. **A Nepali sentence boundary is the danda, and nothing else in the
///     feature speaks it.** Foundation's sentence tokenizer is the first
///     answer; on the OSes where its model does not terminate on `।` it hands
///     back the whole paragraph as one sentence, and the deterministic fallback
///     is what a crop of Nepali prose actually needs. `NepaliTextNormalizer`
///     cannot be it — that type strips the danda deliberately, and this suite
///     pins that too, so a later "let us just reuse the normalizer" change
///     fails here rather than silently joining every sentence in a paragraph
///     back together.
///  2. **The fallback is a fallback.** A string the tokenizer already split, or
///     a short string with one danda in it, is not re-examined: the splitter
///     never second-guesses an answer that was already a list.
///
/// The rejoining assertions are deliberate. Whether a given OS splits a Nepali
/// paragraph with Foundation's model or with the fallback is not something this
/// suite may depend on — but *either* way the pieces must carry exactly the
/// characters the recogniser read, with nothing invented and nothing dropped.
/// That property is what makes a split piece and the whole string the same
/// evidence, and it is asserted against both functions so a change to either
/// branch cannot quietly lose a character.
final class LiveTranslateSentenceSplitterTests: XCTestCase {

    // MARK: - Fixtures

    /// The longest natural sentence this feature reads off a sign, well inside
    /// the threshold — the shape the device tier is proven on.
    private let shortEnglish = "Light"

    /// Two English sentences in one block: the tokenizer's own case, and the
    /// one the fallback must not touch.
    private let twoEnglishSentences = "Shut the gate. The dog is loose."

    /// A Nepali paragraph of four sentences, each ended with a danda. This is
    /// the crop the fallback exists for: a prescription's directions, read off
    /// a label.
    private let nepaliParagraph = "बिहान खानु अघि एक चक्की खानुहोस्। "
        + "राति सुत्नु अघि एक चक्की खानुहोस्। "
        + "दिनमा दुई लिटर पानी पिउनुहोस्। "
        + "नुन कम खानुहोस्।"

    /// One Devanagari sentence with **no terminator at all** — the string the
    /// tokenizer calls one sentence and the fallback can say nothing more about.
    private var singleNepaliSentenceOverThreshold: String {
        // Deliberately over `fallbackThresholdCharacters` and deliberately free
        // of any terminator, so both stages agree there is one sentence here.
        // (Graphemes, not scalars: "यो औषधि" is five Characters — `यो`, the
        // space, `औ`, `ष` and `धि` — so the repeat count is set for the unit
        // `String.count` actually measures.)
        String(repeating: "यो औषधि", count: 18) + "खानुहोस्"
    }

    /// Every non-whitespace character of `text`, in order — what a split must
    /// carry exactly, whatever it split on.
    private func characters(of text: String) -> [Character] {
        text.filter { !$0.isWhitespace }
    }

    private func XCTAssertPiecesCarryTheWholeString(_ pieces: [String],
                                                    _ text: String,
                                                    file: StaticString = #filePath,
                                                    line: UInt = #line) {
        XCTAssertEqual(pieces.reduce(into: [Character]()) { $0 += characters(of: $1) },
                       characters(of: text),
                       "the pieces must carry exactly the characters the recogniser read",
                       file: file, line: line)
    }

    // MARK: - The empty and short cases

    func testAnEmptyCropAsksTheTiersNothing() {
        XCTAssertEqual(LiveTranslateSentenceSplitter.sentences(in: ""), [])
        XCTAssertEqual(LiveTranslateSentenceSplitter.sentences(in: "   \n\t  "), [])
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "  "), [])
    }

    func testASingleShortStringComesBackWholeAndTrimmed() {
        XCTAssertEqual(LiveTranslateSentenceSplitter.sentences(in: "  \(shortEnglish) \n"),
                       [shortEnglish])
    }

    func testOneShortNepaliSentenceIsNotSplitEvenThoughItCarriesADanda() {
        // A one-sentence crop is a one-sentence crop: the danda is a terminator,
        // not an instruction to invent a second piece.
        XCTAssertEqual(LiveTranslateSentenceSplitter.sentences(in: "बत्ती।"), ["बत्ती।"])
    }

    func testASingleSentenceWithNoTerminatorOverTheThresholdStaysOneSentence() {
        let text = singleNepaliSentenceOverThreshold
        XCTAssertGreaterThan(text.count, LiveTranslateSentenceSplitter.fallbackThresholdCharacters)

        let pieces = LiveTranslateSentenceSplitter.sentences(in: text)

        // The fallback found nothing, and an honest long sentence is the answer
        // — never an empty list. "There is text here" is not "there is nothing
        // to translate".
        XCTAssertEqual(pieces, [text])
    }

    // MARK: - The two stages, separately

    func testTheTokenizerSplitsEnglishIntoSentencesAndKeepsTheMarks() {
        let pieces = LiveTranslateSentenceSplitter.tokenizedSentences(in: twoEnglishSentences)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue(pieces[0].hasSuffix("."), "the terminator stays on the piece it ended")
        XCTAssertTrue(pieces[1].hasSuffix("."))
        XCTAssertPiecesCarryTheWholeString(pieces, twoEnglishSentences)
    }

    func testTheDeterministicFallbackBreaksAfterEveryTerminator() {
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "क ख। ग घ।"),
                       ["क ख।", "ग घ।"])
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "One. Two! Three?"),
                       ["One.", "Two!", "Three?"])
        // The double danda, the paragraph mark: a terminator like the single one.
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "क ख॥ ग घ"),
                       ["क ख॥", "ग घ"])
    }

    func testTheFallbackKeepsATrailingSentenceWithNoTerminator() {
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "One. Two"),
                       ["One.", "Two"])
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "One."),
                       ["One."])
    }

    func testTheFallbackInventsNothingBetweenTwoTerminators() {
        // An empty piece is an id the tiers would be asked to translate, so two
        // terminators in a row produce one piece, not one and a blank.
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "One. . Two."),
                       ["One.", ".", "Two."])
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: ". . ."),
                       [".", ".", "."])
    }

    func testEveryFallbackPieceCarriesOnlyWhitespaceOut() {
        let text = "  One.   Two.  "
        let pieces = LiveTranslateSentenceSplitter.deterministicSentences(in: text)
        XCTAssertEqual(pieces, ["One.", "Two."])
        for piece in pieces {
            XCTAssertEqual(piece, piece.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - The two stages, together

    func testANepaliParagraphIsSplitRatherThanHandedOverWhole() {
        let pieces = LiveTranslateSentenceSplitter.sentences(in: nepaliParagraph)

        XCTAssertGreaterThan(pieces.count, 1,
                             "a four-sentence paragraph must never reach a tier as one string")
        XCTAssertPiecesCarryTheWholeString(pieces, nepaliParagraph)
    }

    func testEveryPieceOfALongNepaliParagraphEndsWithItsTerminator() {
        // The crop this suite is about: four dandas, four pieces, and each one
        // carries the mark that ended it. Asserted over the *pieces the
        // fallback produces* so the assertion holds whichever stage ran: a
        // tokenizer sentence that already carried its mark is unchanged.
        let pieces = LiveTranslateSentenceSplitter.deterministicSentences(in: nepaliParagraph)

        XCTAssertEqual(pieces.count, 4)
        for piece in pieces {
            XCTAssertTrue(piece.hasSuffix("।"), "\(piece) lost its terminator")
        }
        XCTAssertPiecesCarryTheWholeString(pieces, nepaliParagraph)
    }

    func testAMixedScriptParagraphSplitsOnBothScriptsMarks() {
        let text = "Take one tablet. बिहान खानु अघि। राति एक चक्की। Call the clinic."
        let pieces = LiveTranslateSentenceSplitter.sentences(in: text)

        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertPiecesCarryTheWholeString(pieces, text)
    }

    func testTheThresholdIsTheCallersAndMovesTheAmbiguousCase() {
        // A short string with one danda, under a lowered threshold: the
        // fallback is allowed to look at it, and still finds one sentence.
        let text = "बत्ती।"
        XCTAssertEqual(LiveTranslateSentenceSplitter.sentences(in: text, minimumFallbackLength: 0),
                       LiveTranslateSentenceSplitter.deterministicSentences(in: text))
        // The default leaves it alone entirely.
        XCTAssertEqual(LiveTranslateSentenceSplitter.sentences(in: text), [text])
    }

    func testTheDefaultThresholdSitsBetweenTheRoutersProvenLengthAndTheSanitisersBound() {
        // The threshold's own doc names both bounds; the numbers are pinned
        // here so a later edit to either has to come past this test.
        XCTAssertEqual(LiveTranslateSentenceSplitter.fallbackThresholdCharacters, 80)
        XCTAssertGreaterThan(LiveTranslateSentenceSplitter.fallbackThresholdCharacters,
                             TranslationReliabilityRouter.maxProvenCharacters)
        XCTAssertLessThan(LiveTranslateSentenceSplitter.fallbackThresholdCharacters,
                          LiveTranslateConfig.default.sceneTextMaxLength)
    }

    func testTheTerminatorsAreTheTwoDandasAndTheThreeLatinMarks() {
        XCTAssertEqual(LiveTranslateSentenceSplitter.terminators,
                       ["।", "॥", ".", "!", "?"])
    }

    // MARK: - The period's other jobs (review finding 9)

    func testAPeriodBetweenDigitsIsDecimalAndNeverABoundary() {
        // The crop this matters on: a prescription's times and doses. Breaking
        // here handed the tiers "8." and "30" — two strings, two ids, two cache
        // keys, and a number cut in half.
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "8.30 बजे खानु। अब"),
                       ["8.30 बजे खानु।", "अब"])
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "1.5 mg twice. Now"),
                       ["1.5 mg twice.", "Now"])
        // A leading dot is the same shape: nothing on the near side, a digit on
        // the far one.
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: ".5 mg. Then"),
                       [".5 mg.", "Then"])
    }

    func testATrailingPeriodAfterANumberStillEndsASentence() {
        // The other half of the rule: a period that follows a number is a
        // decimal only when a *digit* is across it. A rule that refused every
        // digit-adjacent period would join these two sentences, and joining is
        // the failure the fallback exists to fix.
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "It was 2024. Then we left."),
                       ["It was 2024.", "Then we left."])
    }

    func testAnAbbreviationsOwnPeriodIsNotABoundary() {
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "Dr. Sharma arrived. He sat"),
                       ["Dr. Sharma arrived.", "He sat"])
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "Rs. 250 for the visit. Pay at the desk"),
                       ["Rs. 250 for the visit.", "Pay at the desk"])
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "Take it etc. after food. Then rest"),
                       ["Take it etc. after food.", "Then rest"])
    }

    func testADotInsideATokenIsNotABoundary() {
        // A closed-up initial: a letter immediately on both sides of the dot is
        // one token, not a sentence end.
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "J.Sharma arrived. He sat"),
                       ["J.Sharma arrived.", "He sat"])
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "Take it e.g. after food. Then rest"),
                       ["Take it e.g. after food.", "Then rest"])
        // A multi-dot acronym's *inner* dots are in-word by the same rule; the
        // dot that closes it follows a letter and stands before a space, which
        // is the shape of a sentence end. The rules do not know the acronym —
        // and reading every such dot as in-word would join two real sentences
        // ("…in the U.S.A. Then we left."), which is the worse failure. Pinned
        // so the limit is a decision rather than a surprise.
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "The U.S.A. office is shut. Go tomorrow"),
                       ["The U.S.A.", "office is shut.", "Go tomorrow"])
    }

    func testAnInitialDoesNotSplitAName() {
        // A single letter before the dot is read as an initial. On the forms
        // this path reads that is far more common than a one-letter word ending
        // a sentence — and a name cut in half is the worse failure of the two.
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "J. Sharma arrived. He sat"),
                       ["J. Sharma arrived.", "He sat"])
    }

    func testARepeatedDotIsOneTerminator() {
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "Wait.. then go. Done"),
                       ["Wait.. then go.", "Done"])
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "Hmm... not now. Later"),
                       ["Hmm... not now.", "Later"])
    }

    func testTheDandaAndTheExclamationMarksAreAlwaysBoundaries() {
        // The period is the only mark whose job is ambiguous: nothing else in
        // the terminator set is used for anything but ending a sentence, so
        // nothing else may be second-guessed.
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "8.30 बजे। अब"),
                       ["8.30 बजे।", "अब"])
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: "No. 5 गेट! अब?"),
                       ["No.", "5 गेट!", "अब?"])
    }

    func testNeitherStageHandsATierTheHalvesOfATimeOrAName() {
        let text = "Dr. Sharma को घर 8.30 बजे जानुहोस्। फेरि आउनुहोस्।"
        // The fallback is the stage whose rules changed, so it is asserted
        // exactly; the two-stage entry is asserted on the property that must
        // hold whichever stage ran.
        XCTAssertEqual(LiveTranslateSentenceSplitter.deterministicSentences(in: text),
                       ["Dr. Sharma को घर 8.30 बजे जानुहोस्।", "फेरि आउनुहोस्।"])

        let pieces = LiveTranslateSentenceSplitter.sentences(in: text, minimumFallbackLength: 0)
        XCTAssertFalse(pieces.contains("8."), "a time is not two strings")
        XCTAssertFalse(pieces.contains("30"))
        XCTAssertFalse(pieces.contains { $0.hasSuffix("Dr.") }, "a name is not a sentence")
        XCTAssertPiecesCarryTheWholeString(pieces, text)
    }

    func testTheAbbreviationListIsTheCloseableOneTheDocNames() {
        // The list is short on purpose — every entry is a token that is never a
        // sentence's last word on its own, because suppressing a real break
        // joins two sentences. Pinned so growing it (or a later "just suppress
        // every dot" change) has to come past this test.
        XCTAssertEqual(LiveTranslateSentenceSplitter.abbreviations,
                       ["dr", "mr", "mrs", "ms", "prof", "sr", "jr", "vs", "etc", "eg", "ie",
                        "rs", "approx", "fig", "dept", "govt", "ltd", "pvt"])
        XCTAssertFalse(LiveTranslateSentenceSplitter.abbreviations.contains("no"),
                       "a token that can end a sentence does not belong here")
    }

    // MARK: - Why this is not the normalizer

    func testTheNormalizerStripsTheDandaThisSplitterSplitsOn() {
        // The regression this type exists for: the shipped Nepali normalizer
        // removes `।` (it exists to make two spellings compare equal), so a
        // splitter built on it would find no boundary anywhere in a Nepali
        // paragraph. Pinned as a fact about the normalizer, not as a defect in
        // it — the two types answer different questions.
        let normalized = NepaliTextNormalizer.normalize(nepaliParagraph)
        XCTAssertFalse(normalized.contains("।"),
                       "NepaliTextNormalizer no longer strips the danda — the splitter's "
                       + "reason for not using it needs re-reading")
        XCTAssertTrue(nepaliParagraph.contains("।"))
    }

    func testTheSplitterAppliesNoNormalizationOfItsOwn() {
        // What the caller sends is what the recogniser read: no case folding, no
        // punctuation removal. The cache key is derived separately, from the
        // piece, by `LiveTranslateTextNormalization`.
        let text = "Take One Tablet."
        XCTAssertEqual(LiveTranslateSentenceSplitter.sentences(in: text), [text])
        XCTAssertNotEqual(LiveTranslateSentenceSplitter.sentences(in: text),
                          [LiveTranslateTextNormalization.normalized(text)])
    }
}
