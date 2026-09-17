import XCTest
@testable import ElderlyAssistant

/// The medicine-label parser ([MED-OCR], 2026-09-18).
///
/// This is the half of the feature that can be wrong in a way that reaches a
/// DOSE: a pre-filled name the family does not notice is one typed word, but a
/// pre-filled schedule they do not notice is a missed or doubled tablet. So
/// the matrix below is deliberately two-sided —
///
///  - the shapes a real label carries MUST parse (name above the strength,
///    name fused with strength and dose form, `1-0-1`, Devanagari digits,
///    Nepali and English time words, "twice a day", weekly), and
///  - the shapes that merely LOOK like one must not: a batch code, an expiry
///    date, an all-zero day pattern, a count off the table, a line of
///    directions.
///
/// Everything here runs on string arrays — no image, no camera, no Vision.
final class MedicationLabelOCRTests: XCTestCase {

    private func hours(_ candidate: MedicationLabelCandidate) -> [Int] {
        candidate.scheduleTimes.map { $0.hour ?? -1 }
    }

    private func minutes(_ candidate: MedicationLabelCandidate) -> [Int] {
        candidate.scheduleTimes.map { $0.minute ?? -1 }
    }

    // MARK: - The shapes a label carries

    /// The ordinary box: brand on top, strength under it, directions in their
    /// own line. All three fields must come out of one pass.
    func testReadsNameStrengthAndDayPatternFromASeparatedLabel() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["Amoxicillin", "500 mg", "1-0-1"])

        XCTAssertEqual(candidate.name, "Amoxicillin")
        XCTAssertEqual(candidate.strength, "500 mg")
        XCTAssertEqual(candidate.scheduleTimes,
                       [DateComponents(hour: 8, minute: 0),
                        DateComponents(hour: 20, minute: 0)])
        XCTAssertEqual(candidate.frequency, .daily)
    }

    /// The name line carries its own strength and dose form —
    /// "Amlodipine Tablet 5 mg" is one line on most boxes, and the name the
    /// family says aloud is "Amlodipine".
    func testStripsStrengthAndTrailingDoseFormOffTheNameLine() {
        for line in ["Amlodipine Tablet 5 mg", "Amlodipine 5mg", "• Amlodipine - 5 MG"] {
            let candidate = MedicationLabelParser.candidate(
                fromLines: [line, "Take one tablet in the morning"])

            XCTAssertEqual(candidate.name, "Amlodipine", "from \"\(line)\"")
            XCTAssertEqual(candidate.strength, "5 mg", "from \"\(line)\"")
        }
    }

    /// The commonest box in this market: the generic name line carries the
    /// dose form (and the pharmacopoeia marker) beside the strength. The line
    /// must still yield a name — refusing it because it says "Tablets" is a
    /// scan that read the strength and left the name blank.
    func testNameLineCarryingADoseFormStillYieldsAName() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["Amoxicillin Tablets IP 500 mg", "1-0-1"])

        XCTAssertEqual(candidate.strength, "500 mg")
        XCTAssertTrue(candidate.name?.contains("Amoxicillin") == true,
                      "got \(String(describing: candidate.name))")
    }

    /// The first PLAUSIBLE line is the name: a directions line above the name
    /// is skipped whole rather than half-parsed into a name.
    func testSkipsDirectionsLinesAndTakesTheFirstRealNameLine() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["Take 1 tablet by mouth", "Metformin", "500 mg", "daily"])

        XCTAssertEqual(candidate.name, "Metformin")
        XCTAssertEqual(candidate.strength, "500 mg")
        XCTAssertEqual(candidate.scheduleTimes, [], "no time words: daily is a frequency only")
        XCTAssertEqual(candidate.frequency, .daily)
    }

    /// Nepali label: Devanagari digits normalize to ASCII before anything
    /// reads them, so the strength AND the day pattern both parse.
    func testReadsDevanagariDigitsInStrengthAndDayPattern() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["एमोक्सिसिलिन ५०० एमजी", "१-०-१"])

        XCTAssertEqual(candidate.name, "एमोक्सिसिलिन")
        XCTAssertEqual(candidate.strength, "500 एमजी")
        XCTAssertEqual(hours(candidate), [8, 20])
    }

    /// The Nepali time words, including one fused with a postposition
    /// ("बिहानको औषधि" ⊃ "बिहान") — the same substring convention
    /// `MedicationPurpose.voiceKeys` relies on.
    func testReadsNepaliTimeWordsIncludingFusedPostpositions() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["मेटफर्मिन", "बिहानको औषधि", "बेलुका खानु"])

        XCTAssertEqual(candidate.name, "मेटफर्मिन")
        XCTAssertEqual(hours(candidate), [8, 19])
        XCTAssertEqual(candidate.frequency, .daily)
    }

    /// English time words, two of them, in clock order regardless of the
    /// order they appear in.
    func testReadsEnglishTimeWordsSortedAndDeduplicated() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["Amlodipine", "night and morning"])

        XCTAssertEqual(hours(candidate), [8, 21])
        XCTAssertEqual(minutes(candidate), [0, 0])
    }

    /// "3 times a day" is three doses at the conventional hours — the count
    /// table, not a guess at the family's day.
    func testReadsCountedDailyDoses() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["Paracetamol", "500 mg", "2 times a day"])

        XCTAssertEqual(hours(candidate), [8, 20])
        XCTAssertEqual(candidate.frequency, .daily)
    }

    /// The Nepali count shape ("दिनमा २ पटक") is the same table.
    func testReadsNepaliCountedDoses() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["प्यारासिटामोल", "दिनमा २ पटक"])

        XCTAssertEqual(hours(candidate), [8, 20])
    }

    /// The day pattern decides on its own, and a nonzero slot is the only
    /// thing that becomes a dose: "1-0-1" is two tablets, not three.
    func testDayPatternDosesFollowTheNonZeroSlots() {
        XCTAssertEqual(hours(MedicationLabelParser.candidate(fromLines: ["1-1-1"])), [8, 13, 20])
        XCTAssertEqual(hours(MedicationLabelParser.candidate(fromLines: ["0-0-1"])), [20])
        XCTAssertEqual(hours(MedicationLabelParser.candidate(fromLines: ["1 0 1"])), [8, 20])
        XCTAssertEqual(hours(MedicationLabelParser.candidate(fromLines: ["1.0.1"])), [8, 20])
    }

    /// A day pattern on the NAME line comes off the name (the toggle toggle
    /// and the name share a line on small boxes).
    func testDayPatternOnTheNameLineIsStrippedFromTheName() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["Amlodipine 1-0-1", "5 mg"])

        XCTAssertEqual(candidate.name, "Amlodipine")
        XCTAssertEqual(candidate.strength, "5 mg")
        XCTAssertEqual(hours(candidate), [8, 20])
    }

    /// Weekly is a frequency the label can state with no times to show.
    func testWeeklyLabelYieldsAWeeklyFrequencyAndNoTimes() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["Alendronate", "70 mg", "Take one tablet once a week"])

        XCTAssertEqual(candidate.name, "Alendronate")
        XCTAssertEqual(candidate.strength, "70 mg")
        XCTAssertEqual(candidate.scheduleTimes, [])
        XCTAssertEqual(candidate.frequency, .weekly)
    }

    /// A label that says "daily" and nothing about WHEN is a daily frequency
    /// with no times — the editor keeps the time the family already had.
    func testDailyTokenAloneYieldsAFrequencyWithNoTimes() {
        let candidate = MedicationLabelParser.candidate(fromLines: ["Vitamin D", "daily"])

        XCTAssertEqual(candidate.scheduleTimes, [])
        XCTAssertEqual(candidate.frequency, .daily)
    }

    // MARK: - The shapes that only look like one

    /// A bare number next to a batch code is not a strength: "500" alone, and
    /// a unit glued to more digits, are refused.
    func testBareNumbersAndSuffixedUnitsAreNotStrengths() {
        XCTAssertNil(MedicationLabelParser.strengthMatch(in: "Batch 500"))
        XCTAssertNil(MedicationLabelParser.strengthMatch(in: "Batch 500mg2"))
        XCTAssertNil(MedicationLabelParser.strengthMatch(in: "NDC 1234567890"))
        XCTAssertEqual(MedicationLabelParser.strengthMatch(in: "NDC 12345 500 mg"), "500 mg")
    }

    /// An expiry date is not a schedule. The day pattern needs single digits;
    /// the lookarounds keep it out of every date a box prints.
    func testExpiryAndBatchDatesDoNotBecomeSchedules() {
        for line in ["Exp 12-05-2026", "Mfg 2026/05/12", "Batch 11.02.2026"] {
            let candidate = MedicationLabelParser.candidate(fromLines: [line])

            XCTAssertEqual(candidate.scheduleTimes, [], "from \"\(line)\"")
            XCTAssertNil(candidate.name, "from \"\(line)\"")
        }
    }

    /// An all-zero day pattern is a tick-box or a strike-through, not three
    /// skipped doses.
    func testAllZeroDayPatternIsIgnored() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["Amlodipine", "0-0-0"])

        XCTAssertEqual(candidate.scheduleTimes, [])
        XCTAssertNil(candidate.frequency)
    }

    /// "5 times a day" is a real prescription and a real thing to get wrong:
    /// the count table refuses off-table counts rather than inventing hours.
    func testOffTableCountsAreRefused() {
        for line in ["5 times a day", "0 times a day"] {
            let candidate = MedicationLabelParser.candidate(fromLines: ["Medicine", line])

            XCTAssertEqual(candidate.scheduleTimes, [], "from \"\(line)\"")
            XCTAssertNil(candidate.frequency, "from \"\(line)\"")
        }
    }

    /// A line that is only a dose form is not a name — it strips to nothing,
    /// and the letter-count guard rejects it.
    func testDoseFormAloneIsNotAName() {
        XCTAssertNil(MedicationLabelParser.name(fromLines: ["Tablet"]))
        XCTAssertNil(MedicationLabelParser.name(fromLines: ["Tablets 500 mg"]))
        XCTAssertNil(MedicationLabelParser.name(fromLines: ["500 mg tablet"]))
        XCTAssertNil(MedicationLabelParser.name(fromLines: ["१ ट्याब्लेट"]))
    }

    /// A dose line with no direction word in it ("1 tablet twice a day") is
    /// still not a name: it begins with a numeral, which no medicine name
    /// does and almost every directions line does.
    func testDoseLineBeginningWithANumeralIsNotAName() {
        XCTAssertNil(MedicationLabelParser.name(fromLines: ["1 tablet twice a day"]))
        XCTAssertNil(MedicationLabelParser.name(fromLines: ["1 tablet daily"]))
        XCTAssertNil(MedicationLabelParser.name(fromLines: ["30 tablets"]))
    }

    /// Garbage in, empty candidate out — never a name made of punctuation or
    /// digits, and never an exception.
    func testGarbageLinesYieldAnEmptyCandidate() {
        for lines in [["!! ?? ..", "12345", "///"],
                      ["- - -", "0", "*"],
                      ["   ", "\n"]] {
            let candidate = MedicationLabelParser.candidate(fromLines: lines)

            XCTAssertTrue(candidate.isEmpty, "from \(lines)")
            XCTAssertEqual(candidate, .empty)
        }
    }

    /// No lines at all is the same empty answer.
    func testNoLinesYieldAnEmptyCandidate() {
        XCTAssertEqual(MedicationLabelParser.candidate(fromLines: []), .empty)
        XCTAssertEqual(MedicationLabelParser.candidate(fromText: ""), .empty)
    }

    /// The single-blob convenience splits on newlines first, so a test (or a
    /// future paste path) gets the same candidate as the line array.
    func testBlobConvenienceMatchesTheLineParser() {
        let text = "Amoxicillin\n500 mg\n1-0-1"
        let expected = MedicationLabelParser.candidate(fromLines: ["Amoxicillin", "500 mg", "1-0-1"])

        XCTAssertEqual(MedicationLabelParser.candidate(fromText: text), expected)
    }

    /// The digit normalizer is the one place Devanagari numerals are
    /// translated; everything downstream depends on it.
    func testNormalizedDigitsTranslatesDevanagariAndLeavesTheRest() {
        XCTAssertEqual(MedicationLabelParser.normalizedDigits("१२३४५६७८९०"), "1234567890")
        XCTAssertEqual(MedicationLabelParser.normalizedDigits("Amlodipine 5 mg"), "Amlodipine 5 mg")
        XCTAssertEqual(MedicationLabelParser.normalizedDigits("बिहान"), "बिहान")
    }
}
