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
    func testDayPatternDosesFollowOnlyTheNonZeroSlots() {
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

    // MARK: - Frequency-based schedules [MED-OCR-FREQ] (2026-10-15)

    /// The owner's own device report: "one tablet twice a day" captured
    /// NOTHING — no day pattern, no time word, and the count table only
    /// reads a DIGIT. The phrase means after lunch and after dinner, and
    /// that is what it now captures: the two conventional hours (13:00,
    /// 19:00 — the pinned hour table converts them to afternoon and
    /// evening) plus the after-food context frequency rows carry.
    func testTwiceADayPhrasesCaptureAfternoonAndEveningAfterFood() {
        for line in ["one tablet twice a day", "1 tablet twice a day",
                     "two times a day", "2 times daily", "BD", "b.i.d",
                     "Take 1 tablet twice daily"] {
            let candidate = MedicationLabelParser.candidate(fromLines: [line])

            XCTAssertEqual(hours(candidate), [13, 19], "from \"\(line)\"")
            XCTAssertEqual(minutes(candidate), [0, 0], "from \"\(line)\"")
            XCTAssertEqual(candidate.frequency, .daily, "from \"\(line)\"")
            XCTAssertEqual(candidate.mealRelation, .afterMeal, "from \"\(line)\"")
        }
    }

    /// Three-times-a-day forms are the whole day, still after food.
    func testThreeTimesADayPhrasesCaptureMorningThroughEveningAfterFood() {
        for line in ["three times a day", "3 times daily", "TDS", "t.i.d", "T.D.S"] {
            let candidate = MedicationLabelParser.candidate(fromLines: ["Paracetamol", line])

            XCTAssertEqual(hours(candidate), [8, 13, 19], "from \"\(line)\"")
            XCTAssertEqual(candidate.frequency, .daily, "from \"\(line)\"")
            XCTAssertEqual(candidate.mealRelation, .afterMeal, "from \"\(line)\"")
        }
    }

    /// OCR splits lines wherever it likes: a phrase broken across two
    /// recognition lines still reads (the whitespace-collapsed match).
    func testFrequencyPhraseBrokenAcrossLinesStillReads() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["Paracetamol", "1 tablet twice a", "day"])

        XCTAssertEqual(hours(candidate), [13, 19])
        XCTAssertEqual(candidate.mealRelation, .afterMeal)
    }

    /// The once-a-day family states a frequency and NO time of day — the
    /// parser refuses to guess morning, and the family picks the row.
    func testOnceDailyPhrasesYieldNoTimesAndNoMealGuess() {
        for line in ["once daily", "once a day", "1 time daily", "OD", "o.d."] {
            let candidate = MedicationLabelParser.candidate(fromLines: ["Amlodipine", line])

            XCTAssertEqual(candidate.scheduleTimes, [], "from \"\(line)\"")
            XCTAssertEqual(candidate.frequency, .daily, "from \"\(line)\"")
            XCTAssertNil(candidate.mealRelation, "from \"\(line)\"")
        }
    }

    /// "1 time a day" is the digit twin of "once a day" and follows the
    /// same rule: no times. This pins the removed count-1 guess — the old
    /// count table turned it into 08:00 morning, exactly the inference
    /// the owner's rule forbids ("Do NOT guess morning").
    func testDigitOnceADayDoesNotGuessMorning() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["Paracetamol", "1 time a day"])

        XCTAssertEqual(candidate.scheduleTimes, [], "no morning guess")
        XCTAssertEqual(candidate.frequency, .daily)
        XCTAssertNil(candidate.mealRelation)
    }

    /// Stated times outrank a frequency phrase — the "mixed signals" rule:
    /// the first shape that matches decides the TIMES, and no frequency
    /// table context is recorded as such beside them. The relation the
    /// rows carry is the blanket after-food default (2026-10-15, the
    /// owner's rule), not an inference from the frequency phrase — the
    /// rows are label-derived either way, so the default applies.
    func testStatedTimesOutrankAConflictingFrequency() {
        let words = MedicationLabelParser.candidate(
            fromLines: ["Amlodipine", "morning and twice a day"])
        XCTAssertEqual(hours(words), [8], "the stated time word decides")
        XCTAssertEqual(words.frequency, .daily)
        XCTAssertEqual(words.mealRelation, .afterMeal)

        let pattern = MedicationLabelParser.candidate(
            fromLines: ["Amlodipine", "1-0-1", "twice a day"])
        XCTAssertEqual(hours(pattern), [8, 20], "the explicit day pattern decides")
        XCTAssertEqual(pattern.mealRelation, .afterMeal)

        let counted = MedicationLabelParser.candidate(
            fromLines: ["Amlodipine", "2 times a day", "three times daily"])
        XCTAssertEqual(hours(counted), [8, 20], "the digit count table decides")
        XCTAssertEqual(counted.mealRelation, .afterMeal,
                       "the digit count rows default after food like every shape")
    }

    // MARK: - The after-food default (2026-10-15, the owner's rule)

    /// A label that states times but says nothing about meals still gets
    /// the household's after-food default on its rows — the rule covers
    /// EVERY scanned schedule shape, not just the frequency table.
    func testTimeWordRowsDefaultAfterFood() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["Amlodipine", "morning and evening"])

        XCTAssertEqual(hours(candidate), [8, 19])
        XCTAssertEqual(candidate.frequency, .daily)
        XCTAssertEqual(candidate.mealRelation, .afterMeal, "unstated defaults after food")
    }

    /// The day-pattern shape states times and no meal context — the
    /// default reaches it too.
    func testDayPatternRowsDefaultAfterFood() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["Amlodipine", "1-0-1"])

        XCTAssertEqual(hours(candidate), [8, 20])
        XCTAssertEqual(candidate.mealRelation, .afterMeal)
    }

    /// The digit count table states hours and no meal context — the
    /// default reaches it too. This supersedes the earlier pin that digit
    /// rows recorded no relation (2026-10-15, the owner's rule: every
    /// label-derived row defaults after food unless the label says more).
    func testDigitCountRowsDefaultAfterFood() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["Paracetamol", "2 times a day"])

        XCTAssertEqual(hours(candidate), [8, 20])
        XCTAssertEqual(candidate.mealRelation, .afterMeal)
    }

    /// A relation the label STATES always wins over the default — the
    /// owner's own example ("before breakfast"), and the Nepali before
    /// phrase.
    func testBeforeFoodOnTheLabelIsKept() {
        let pattern = MedicationLabelParser.candidate(
            fromLines: ["Amlodipine", "1-0-1", "before breakfast"])
        XCTAssertEqual(hours(pattern), [8, 20])
        XCTAssertEqual(pattern.mealRelation, .beforeMeal)

        let words = MedicationLabelParser.candidate(
            fromLines: ["एमोक्सिसिलिन", "बिहान र बेलुका", "खानु अघि"])
        XCTAssertEqual(hours(words), [8, 19])
        XCTAssertEqual(words.mealRelation, .beforeMeal)
    }

    /// A label naming BOTH contexts ("before breakfast, after dinner") is
    /// a split schedule no single relation holds: the read states none —
    /// and none is defaulted over an explicit mention.
    func testMixedMealMentionsStateNothing() {
        let candidate = MedicationLabelParser.candidate(
            fromLines: ["Amlodipine", "morning", "before food", "after dinner"])

        XCTAssertEqual(hours(candidate), [8], "the stated time still decides the rows")
        XCTAssertNil(candidate.mealRelation, "mixed mentions state nothing — no default either")
    }

    /// Unknown frequency phrasing gets NO schedule — the refuse-to-guess
    /// invariant. "twice a week" is a weekly cadence the table does not
    /// state and "4 times daily" a real prescription it does not carry,
    /// and neither is repaired into one.
    func testUnknownFrequencyPhrasesAreRefused() {
        for line in ["twice a week", "thrice a day", "as needed",
                     "every other day", "4 times daily"] {
            let candidate = MedicationLabelParser.candidate(fromLines: ["Medicine", line])

            XCTAssertEqual(candidate.scheduleTimes, [], "from \"\(line)\"")
            XCTAssertNil(candidate.mealRelation, "from \"\(line)\"")
        }

        // …and the frequency field stays what the text actually says: a
        // line carrying no daily/weekly token records nil.
        for line in ["twice a week", "thrice a day", "as needed",
                     "every other day"] {
            XCTAssertNil(MedicationLabelParser.candidate(
                fromLines: ["Medicine", line]).frequency, "from \"\(line)\"")
        }
    }

    /// The abbreviations fire only as standalone tokens: "od" inside
    /// "food" or "blood", "bd" inside a word — none may become a
    /// frequency. This is the lookarounds' whole job.
    func testAbbreviationsFireOnlyAsStandaloneTokens() {
        for line in ["Take after food", "Product of Nepal", "Blood pressure"] {
            let candidate = MedicationLabelParser.candidate(fromLines: ["Medicine", line])

            XCTAssertEqual(candidate.scheduleTimes, [], "from \"\(line)\"")
            XCTAssertNil(candidate.mealRelation, "from \"\(line)\"")
        }
    }

    /// The Nepali frequency WORDS ("दिनमा दुई पटक") — the digit forms
    /// ("दिनमा २ पटक") stay on the shipped count table, unchanged.
    func testReadsNepaliFrequencyWords() {
        let twice = MedicationLabelParser.candidate(
            fromLines: ["प्यारासिटामोल", "दिनमा दुई पटक"])
        XCTAssertEqual(hours(twice), [13, 19])
        XCTAssertEqual(twice.frequency, .daily)
        XCTAssertEqual(twice.mealRelation, .afterMeal)

        let thrice = MedicationLabelParser.candidate(
            fromLines: ["प्यारासिटामोल", "दिनमा तीन पटक"])
        XCTAssertEqual(hours(thrice), [8, 13, 19])
        XCTAssertEqual(thrice.mealRelation, .afterMeal)

        let once = MedicationLabelParser.candidate(
            fromLines: ["प्यारासिटामोल", "दिनमा एक पटक"])
        XCTAssertEqual(once.scheduleTimes, [])
        XCTAssertEqual(once.frequency, .daily)
        XCTAssertNil(once.mealRelation)
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
