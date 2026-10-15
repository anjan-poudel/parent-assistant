import CoreGraphics
import Foundation
import UIKit
import Vision

// [MED-OCR] (2026-09-18) Reading a medicine label with the camera.
//
// The family points the phone at the box, the app reads what the label says,
// and the editor is PRE-FILLED with it. Three properties are structural here,
// not conventions:
//
//  - **On device, only.** Recognition is Vision's, locally: there is no
//    network client, no API key and no URL anywhere in this file
//    (constitution: no cloud AI on user content). The only thing that ever
//    leaves this file is the RECOGNIZED TEXT of a medicine label, and the
//    only thing a caller can do with it is fill a form field the family
//    reviews before saving.
//  - **Advisory, never authoritative.** The parser's output is a
//    `MedicationLabelCandidate` — a SUGGESTION the editor drops into its
//    fields. Nothing here writes to a store, and no caller may save what a
//    candidate says without the family seeing it first: an OCR misread of
//    "1-0-1" as "1-0-7" must cost a correction, never a dose.
//  - **The parsing is image-independent.** `MedicationLabelParser` takes
//    LINES, not pixels, so the whole matrix — fused name + strength,
//    Devanagari time words, garbage, empty — is a unit test on a string
//    array. Only the recognizer below touches Vision.

// MARK: - The candidate

/// What one label said, in the editor's vocabulary.
///
/// Every field is optional on purpose: a label read upside-down yields a
/// name and nothing else, a label read perfectly still has no purpose on it,
/// and the editor must be able to pre-fill exactly what was found. Absent
/// means "the label did not say", never "empty".
///
/// `scheduleTimes` are hour/minute `DateComponents` — the same shape
/// `MedicationEntry.scheduleTimes` and the editor's `DatePicker` rows use —
/// and `frequency` is the parser's best guess (`MedicationFrequency`), nil
/// when the label said nothing about how often.
struct MedicationLabelCandidate: Equatable {
    /// The medicine's name, as printed, with the strength and the dose form
    /// stripped off ("Amoxicillin 500 mg Tablet" → "Amoxicillin").
    var name: String?
    /// The printed strength, normalized to one space ("500mg" → "500 mg").
    var strength: String?
    /// Dose times the label implies — see `MedicationLabelParser` for the
    /// two shapes that produce them (time words, and the `1-0-1` day
    /// pattern). Defaults, not facts: the editor shows them as editable
    /// pickers before anything is saved.
    var scheduleTimes: [DateComponents]
    /// The parser's frequency guess, or nil when the label did not say.
    var frequency: MedicationFrequency?
    /// The meal context the label's schedule carries [MED-OCR-FREQ]. The
    /// label's own statement wins ("before breakfast", "खानु अघि"), and a
    /// label that states none carries the after-food default on every
    /// row-producing shape (2026-10-15, the owner's rule — "one tablet
    /// twice a day" is an after-food schedule, and so is every other
    /// label-derived row the family did not say otherwise about). nil
    /// when the read produced no rows, or when the label states both
    /// before and after food — a split schedule no single value holds.
    var mealRelation: MealRelation?

    init(name: String? = nil,
         strength: String? = nil,
         scheduleTimes: [DateComponents] = [],
         frequency: MedicationFrequency? = nil,
         mealRelation: MealRelation? = nil) {
        self.name = name
        self.strength = strength
        self.scheduleTimes = scheduleTimes
        self.frequency = frequency
        self.mealRelation = mealRelation
    }

    /// Nothing was read. The scanner still reports the photo — see
    /// `MedicationLabelScanResult` — so "no candidate" is a real, handled
    /// outcome and not a failure.
    static let empty = MedicationLabelCandidate()

    var isEmpty: Bool {
        name == nil && strength == nil && scheduleTimes.isEmpty
            && frequency == nil && mealRelation == nil
    }
}

// MARK: - The parser (pure, image-independent)

/// Turns recognized label lines into a candidate. Pure functions over
/// strings: no Vision, no image, no state — which is what makes the whole
/// matrix a unit test.
///
/// Conservative by design. Every rule below refuses to guess when the text
/// does not clearly say something, because the failure mode of an
/// over-eager parser is a WRONG DOSE TIME pre-filled into a form a hurried
/// family member then saves. A missed field costs one typed word; a wrong
/// schedule costs a dose.
enum MedicationLabelParser {

    /// The candidate for a label's recognized lines, in Vision's order.
    ///
    /// First plausible line is the name (the top of a medicine box is its
    /// name), the first strength-looking token anywhere is the strength, and
    /// the schedule comes from the whole text — a label's directions often
    /// sit under the name in their own line, and a name line can carry the
    /// strength ("Amoxicillin 500 mg").
    static func candidate(fromLines lines: [String]) -> MedicationLabelCandidate {
        let normalized = lines.map(normalizedDigits)
        let schedule = schedule(in: normalized)
        return MedicationLabelCandidate(
            name: name(fromLines: normalized),
            strength: strength(inLines: normalized),
            scheduleTimes: schedule.times,
            frequency: schedule.frequency,
            mealRelation: schedule.mealRelation
        )
    }

    /// Convenience for callers holding one blob (a test, or a future
    /// paste-the-label path): the text is split on newlines first.
    static func candidate(fromText text: String) -> MedicationLabelCandidate {
        candidate(fromLines: text.components(separatedBy: .newlines))
    }

    // MARK: Name

    /// The first line that can plausibly BE a name: it must carry real
    /// letters, must not be a directions/warning/storage line, and must still
    /// have letters left — and not begin with a numeral — once its strength,
    /// its schedule tokens and its trailing dose form are removed.
    ///
    /// The first-plausible rule is what makes a box with a brand name on
    /// top and a generic name under it resolve to the brand line — the word
    /// the family says out loud, and the word the voice photo query will
    /// match on.
    static func name(fromLines lines: [String]) -> String? {
        for line in lines {
            let trimmed = trimmed(line)
            guard !trimmed.isEmpty, !isNoiseLine(trimmed) else { continue }
            var text = removingStrength(from: trimmed)
            text = removingScheduleTokens(from: text)
            text = trimmingFormWords(text)
            text = trimmingSeparators(text)
            // A candidate that still STARTS with a digit is a dose line, not a
            // name ("1 tablet twice a day" — no direction word in it, and the
            // trailing "day" keeps the form strip from firing). Medicine names
            // do not begin with a numeral; directions very often do. The cost
            // of being wrong here is one typed word.
            guard hasEnoughLetters(text), !startsWithDigit(text) else { continue }
            return text
        }
        return nil
    }

    // MARK: Strength

    /// The first `<number> <unit>` token in the text, normalized to a single
    /// space between number and unit. nil when no unit the table knows
    /// appears next to a number — "500" alone is a batch number far more
    /// often than a strength, and a strength-less label is a label that said
    /// nothing about strength.
    static func strength(inLines lines: [String]) -> String? {
        for line in lines {
            if let match = strengthMatch(in: line) { return match }
        }
        return nil
    }

    // MARK: Schedule

    /// What the label says about WHEN, from the shapes a label actually
    /// carries, tried in order of specificity:
    ///
    ///  - **A day pattern** — `1-0-1`, `1.0.1`, `1 0 1`, in ASCII or
    ///    Devanagari digits: one digit per slot (morning, midday, night),
    ///    nonzero slots become dose times on the slot hours below. An
    ///    explicit pattern is the most specific thing a label can say, so
    ///    when one is present it decides the times on its own.
    ///  - **Time words** — बिहान / सकाळ / दिउँसो / बेलुका / राति and their
    ///    English counterparts, matched as substrings because Devanagari
    ///    postpositions fuse onto the stem ("बिहानको औषधि" ⊃ "बिहान", the
    ///    same convention `MedicationPurpose.voiceKeys` relies on).
    ///  - **A digit count** — `<n> times a day` / `दिनमा <n> पटक`, n default
    ///    times from the count table below.
    ///  - **A frequency phrase** — [MED-OCR-FREQ] "twice a day", "BD",
    ///    "दिनमा दुई पटक": the frequency table below turns HOW OFTEN into
    ///    the conventional slot hours its meaning implies ("twice a day" =
    ///    after lunch and after dinner).
    ///
    /// The order IS the precedence rule: the first shape that matches
    /// decides. A label that states actual times (a pattern, a time word)
    /// never gets an extra frequency inference — "mixed signals" resolve
    /// to the stated time and record nothing else.
    ///
    /// Every row-producing shape also states a `mealRelation` (2026-10-15,
    /// the owner's after-food-default rule): a relation the label states
    /// explicitly ("before breakfast", "खानु अघि") wins, and a label that
    /// states none defaults to after food — the household convention for
    /// every label-derived row, not just the frequency table's. A label
    /// that mentions BOTH ("before breakfast, after dinner") states none:
    /// a split schedule no single value holds, and none is defaulted over
    /// an explicit mention. Shapes that produce no rows state none either —
    /// there are no label-derived rows to carry a context.
    ///
    /// Failing all of these, a bare daily/weekly token yields a frequency
    /// with no times — the once-a-day family (which includes digits:
    /// "1 time a day") states no time of day, and none is guessed. A label
    /// saying none of these yields no times — an empty schedule is the
    /// honest answer, and the editor keeps the time the family already had.
    static func schedule(in lines: [String]) -> (times: [DateComponents],
                                                 frequency: MedicationFrequency?,
                                                 mealRelation: MealRelation?) {
        let text = normalizedDigits(lines.joined(separator: "\n")).lowercased()
        // The phrase tables below match against a whitespace-collapsed
        // copy, so a phrase OCR split across two lines ("twice a\nday") or
        // double-spaced still reads. The frequency and meal-relation
        // matchers use it — every shipped matcher reads `text`, exactly
        // as before.
        let phraseText = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        let weekly = weeklyTokens.contains { text.contains($0) }
        // The day pattern first: an explicit 1-0-1 outranks a stray "morning"
        // in a warning line, and outranks the count table below.
        if let pattern = dayPatternTimes(in: text) {
            return (pattern, weekly ? .weekly : .daily, rowMealRelation(in: phraseText))
        }
        let words = timeWordTimes(in: text)
        if !words.isEmpty {
            return (words, weekly ? .weekly : .daily, rowMealRelation(in: phraseText))
        }
        if let counted = countedDoseTimes(in: text) {
            return (counted, weekly ? .weekly : .daily, rowMealRelation(in: phraseText))
        }
        if let frequencyTimes = frequencyRowTimes(in: phraseText) {
            return (frequencyTimes, weekly ? .weekly : .daily, rowMealRelation(in: phraseText))
        }
        if weekly { return ([], .weekly, nil) }
        if isOnceDaily(in: phraseText) { return ([], .daily, nil) }
        if dailyTokens.contains(where: { text.contains($0) }) { return ([], .daily, nil) }
        return ([], nil, nil)
    }

    // MARK: - Schedule tables and matchers

    /// The hours each time word means, as dose-time defaults. Nepali first:
    /// these labels are read in the household's own language.
    ///
    /// The hours are deliberately *conventional* (बिहान is the morning dose,
    /// not sunrise): every one of them lands in an editable `DatePicker`, and
    /// a plausible default is worth more to the family than a literal one.
    static let timeWordHours: [(words: [String], hour: Int, minute: Int)] = [
        (["सकाळ", "बिहान", "morning"], 8, 0),
        (["दिउँसो", "afternoon"], 13, 0),
        (["noon"], 12, 0),
        (["बेलुका", "evening"], 19, 0),
        (["राति", "night"], 21, 0)
    ]

    /// The slot hours a `1-0-1` day pattern maps to: morning, midday, night.
    /// Slot 0/1/2 in order; a zero slot is a skipped dose.
    static let slotHours: [(hour: Int, minute: Int)] = [
        (8, 0), (13, 0), (20, 0)
    ]

    /// How many default times a `<n> times a day` DIGIT count means, and
    /// which hours. Off-table counts (0, or 5+) yield nothing rather than
    /// a guess: "5 times a day" is a real prescription and a real thing to
    /// get wrong.
    ///
    /// Count 1 is deliberately absent (2026-10-15, the owner's frequency
    /// report): "1 time a day" is the digit twin of "once a day", and the
    /// once-a-day shape states no time of day. The old count-1 row guessed
    /// 08:00 morning — exactly the inference the owner's rule forbids
    /// ("Do NOT guess morning"). The count now falls through to the
    /// once-daily phrases below, which yield the frequency and no times.
    static let countedDoseHours: [Int: [(hour: Int, minute: Int)]] = [
        2: [(8, 0), (20, 0)],
        3: [(8, 0), (13, 0), (20, 0)],
        4: [(8, 0), (13, 0), (19, 0), (21, 0)]
    ]

    /// Words that make the frequency a daily one even with no times to show.
    private static let dailyTokens = ["daily", "every day", "once a day",
                                      "दैनिक", "दिनको", "हरेक दिन"]

    /// Words that make it weekly. Checked first: "1 tablet weekly" carries no
    /// daily token, but a label that mentions both is a weekly one ("weekly,
    /// not every day").
    private static let weeklyTokens = ["weekly", "once a week", "per week",
                                       "every week", "हप्ता", "साताको"]

    // MARK: - The frequency table [MED-OCR-FREQ] (2026-10-15)

    /// Frequency phrases → the hours their meaning implies: the "one
    /// tablet twice a day" fix. The owner scanned exactly that label on
    /// device and the schedule stayed empty — no day pattern, no time
    /// word, and the count table only reads a DIGIT, so nothing matched
    /// the words or the abbreviations.
    ///
    /// The hours are the conventional times of day these phrases name in
    /// the household ("twice a day" = after lunch and after dinner, the
    /// owner's own reading), expressed in the same convention hours the
    /// rest of this file emits, so the pinned hour table converts them to
    /// slots with no second mapping:
    ///
    ///  - twice a day → 13:00, 19:00 → afternoon, evening
    ///  - three times a day → 8:00, 13:00, 19:00 → morning, afternoon,
    ///    evening
    ///
    /// Every row matched here is a FREQUENCY-derived row, and a
    /// frequency-derived row is an after-food row ("take twice a day" =
    /// with meals) — consistent with the after-food default its caller
    /// states beside the times it returns (`rowMealRelation(in:)`; the
    /// table's rows are an unstated-relation shape like every other).
    ///
    /// Conservative on purpose: the phrase lists are the families a label
    /// actually states this way, and nothing else is inferred ("twice a
    /// week", "thrice a day", "as needed" match nothing and get no
    /// schedule at all — a wrong schedule costs a dose).
    static let frequencyRowHours: [(phrases: [String], hours: [(hour: Int, minute: Int)])] = [
        (["twice a day", "twice daily", "two times a day", "two times daily",
          "2 times daily",
          "दिनमा दुई पटक"],
         [(13, 0), (19, 0)]),
        (["three times a day", "three times daily", "3 times daily",
          "दिनमा तीन पटक"],
         [(8, 0), (13, 0), (19, 0)])
    ]

    /// The abbreviation row of the frequency table: "BD" / "b.i.d" and
    /// "TDS" / "t.i.d", as STANDALONE tokens — dots between the letters
    /// optional, non-alphanumerics required on both sides.
    ///
    /// (The meal-relation matchers live below this table; they read the
    /// same whitespace-collapsed phrase text.)
    ///
    /// Deliberately regexes and not phrase-list substrings: two- and
    /// three-letter ASCII abbreviations matched as substrings would fire
    /// inside ordinary words ("od" in "food", "bd" in "abdomen"), and a
    /// frequency invented out of a warning line becomes schedule rows
    /// nobody stated. The lookarounds are the whole guard, and they are
    /// why the two-letter forms can be trusted at all.
    private static let twiceDailyPattern = try? NSRegularExpression(
        pattern: "(?<![a-z0-9])(?:b\\.?i\\.?d\\.?|b\\.?d\\.?)(?![a-z0-9])")
    private static let thriceDailyPattern = try? NSRegularExpression(
        pattern: "(?<![a-z0-9])(?:t\\.?d\\.?s\\.?|t\\.?i\\.?d\\.?)(?![a-z0-9])")
    private static let onceDailyPattern = try? NSRegularExpression(
        pattern: "(?<![a-z0-9])o\\.?d\\.?(?![a-z0-9])")

    /// The once-a-day forms: one dose whose TIME OF DAY the label does
    /// not state — and this parser does not guess one. "Once daily" is
    /// the phrase that used to guess 08:00 morning through the count
    /// table's count-1 row; under the owner's rule it now yields the
    /// frequency and no times, and the family picks the time of day for
    /// a single daily dose. The editor shows one blank row; nothing is
    /// assigned for them.
    private static let onceDailyPhrases = ["once daily", "once a day",
                                           "1 time daily", "1 time a day",
                                           "दिनमा एक पटक"]

    // MARK: - The meal-relation rule (2026-10-15, the owner's default)

    /// The meal context a row-producing read carries [MED-OCR-FREQ]: the
    /// relation the label STATES wins, and a label that states none
    /// defaults to after food — the household convention for every
    /// label-derived row, whatever shape produced it. A label that
    /// mentions BOTH ("before breakfast, after dinner") is a split
    /// schedule no single column can hold: the read states none, and none
    /// is defaulted over an explicit mention — the family picks.
    ///
    /// Only row-producing shapes call this; a read with no rows carries
    /// no relation at all. The lists below match on the whitespace-
    /// collapsed phrase text, so an OCR line split still reads.
    static func rowMealRelation(in phraseText: String) -> MealRelation? {
        let before = beforeMealPhrases.contains { phraseText.contains($0) }
        let after = afterMealPhrases.contains { phraseText.contains($0) }
        if before && !after { return .beforeMeal }
        if before && after { return nil }
        return .afterMeal
    }

    /// The words that name a before-food context, ne + en. The meal names
    /// are here because "before breakfast" states exactly the relation
    /// "before food" states — a label that names the meal is if anything
    /// more specific, not less.
    static let beforeMealPhrases = ["before meal", "before food", "before eating",
                                    "before breakfast", "before lunch", "before dinner",
                                    "खानु अघि", "खाना अघि", "खाने अघि", "भोजन अघि"]

    /// The after-food twins. An unstated read lands on the same after-food
    /// default, so these exist to keep an explicit after-food statement
    /// from reading as "no statement" — and to catch the mixed case above.
    static let afterMealPhrases = ["after meal", "after food", "after eating",
                                   "after breakfast", "after lunch", "after dinner",
                                   "खानु पछि", "खाना पछि", "खाने पछि", "भोजन पछि",
                                   "खाना खाएपछि"]

    /// The `d` `sep` `d` `sep` `d` day pattern, ASCII digits only (the input
    /// is digit-normalized before this runs). The lookarounds keep it from
    /// firing inside a longer number or a date: "12-05-2026" has no
    /// single-digit triple, so it matches nothing.
    ///
    /// The separator is one to three of `-`, `.`, `/`, space or tab. SPACE
    /// and TAB are in the class because OCR of a Nepali box often renders
    /// "१-०-१" as "1 0 1", and the doc contract above promises that shape.
    /// Newlines are deliberately NOT: "1\n2\n3" is three lines of a table,
    /// not a day pattern. Adjacent digits are still refused by the
    /// lookarounds, which is what keeps dates out — every separator in
    /// "12-05-2026" has a digit on at least one side of it, so no start
    /// position yields a single-digit triple.
    private static let dayPattern = try? NSRegularExpression(
        pattern: "(?<![0-9])([0-9])[ \\t.\\-/]{1,3}([0-9])[ \\t.\\-/]{1,3}([0-9])(?![0-9])")

    /// The `<n> times a day` shape, English and Nepali ("दिनमा २ पटक").
    private static let countPattern = try? NSRegularExpression(
        pattern: "([0-9])\\s*(?:times?|x)\\s*(?:a|per)\\s*day|दिनमा\\s*([0-9])\\s*पटक")

    /// One digit per slot; a nonzero slot becomes a dose time. A pattern of
    /// all zeros is not a schedule and is ignored (a "0-0-0" on a label is a
    /// strike-through, a tick-box or noise).
    private static func dayPatternTimes(in text: String) -> [DateComponents]? {
        guard let dayPattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in dayPattern.matches(in: text, range: range) {
            var doses: [DateComponents] = []
            let slots = Swift.min(3, Swift.min(match.numberOfRanges - 1, slotHours.count))
            for slot in 0..<Swift.max(0, slots) {
                guard let slotRange = Range(match.range(at: slot + 1), in: text),
                      let count = Int(text[slotRange]), count > 0 else { continue }
                doses.append(DateComponents(hour: slotHours[slot].hour,
                                            minute: slotHours[slot].minute))
            }
            if !doses.isEmpty { return sorted(doses) }
        }
        return nil
    }

    /// Every distinct hour a time word names, deduplicated and sorted —
    /// "morning and night" gives two times, "बिहान बेलुका" the same two.
    private static func timeWordTimes(in text: String) -> [DateComponents] {
        var doses: [DateComponents] = []
        for entry in timeWordHours where entry.words.contains(where: { text.contains($0) }) {
            doses.append(DateComponents(hour: entry.hour, minute: entry.minute))
        }
        return sorted(doses)
    }

    /// The count table's times for an `<n> times a day` line, or nil.
    private static func countedDoseTimes(in text: String) -> [DateComponents]? {
        guard let countPattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in countPattern.matches(in: text, range: range) {
            let group = (1...2).lazy.compactMap { index -> Int? in
                guard let matchRange = Range(match.range(at: index), in: text) else { return nil }
                return Int(text[matchRange])
            }.first
            guard let count = group, let hours = countedDoseHours[count] else { continue }
            return sorted(hours.map { DateComponents(hour: $0.hour, minute: $0.minute) })
        }
        return nil
    }

    /// The frequency table's times for the phrases in `text` (the
    /// whitespace-collapsed copy — see `schedule(in:)`), or nil.
    ///
    /// Row order decides when a text somehow carries phrases from two
    /// rows: the twice-daily row is tested first, then the thrice-daily
    /// row, each by its phrase list and then its abbreviation. An
    /// off-table phrase matches nothing here — the caller's fall-through
    /// then records no schedule, which is the honest answer.
    private static func frequencyRowTimes(in text: String) -> [DateComponents]? {
        let abbreviations = [twiceDailyPattern, thriceDailyPattern]
        for (row, abbreviation) in zip(frequencyRowHours, abbreviations) {
            let phraseHit = row.phrases.contains { text.contains($0) }
            let abbreviationHit: Bool
            if let abbreviation {
                abbreviationHit = abbreviation.firstMatch(
                    in: text, range: NSRange(text.startIndex..., in: text)) != nil
            } else {
                abbreviationHit = false
            }
            guard phraseHit || abbreviationHit else { continue }
            return sorted(row.hours.map { DateComponents(hour: $0.hour, minute: $0.minute) })
        }
        return nil
    }

    /// Whether the text states a once-a-day frequency — by phrase
    /// ("once a day") or by the standalone "OD" abbreviation.
    private static func isOnceDaily(in text: String) -> Bool {
        if onceDailyPhrases.contains(where: { text.contains($0) }) { return true }
        guard let onceDailyPattern else { return false }
        return onceDailyPattern.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Dose times in clock order, one entry per hour:minute. The editor's
    /// rows and the entry's `scheduleTimes` both read better in order, and
    /// the order must not depend on which token Vision happened to find
    /// first.
    private static func sorted(_ times: [DateComponents]) -> [DateComponents] {
        var seen = Set<String>()
        return times
            .sorted { ($0.hour ?? 0, $0.minute ?? 0) < ($1.hour ?? 0, $1.minute ?? 0) }
            .filter { time in
                let key = "\(time.hour ?? 0):\(time.minute ?? 0)"
                return seen.insert(key).inserted
            }
    }

    // MARK: - Strength matcher

    /// `500 mg`, `5ml`, `0.5 MG`, `५०० एमजी` — a number and a unit the table
    /// knows, with no letter/digit immediately after the unit (so "500mgx"
    /// and a batch code like "500mg2" are not strengths).
    private static let strengthPattern = try? NSRegularExpression(
        pattern: "(?<![A-Za-z0-9])([0-9]+(?:[.,][0-9]+)?)\\s*"
            + "(mg|milligrams?|mcg|micrograms?|µg|ug|gm|grams?|kg|ml|millilitres?|milliliters?"
            + "|iu|units?|%|एमजी|मिग्रा|ग्राम|मिलि)(?![A-Za-z0-9])",
        options: [.caseInsensitive])

    /// The first strength token in `line`, normalized to one space between
    /// number and unit, unit lowercased when it is ASCII. nil when the line
    /// carries none.
    static func strengthMatch(in line: String) -> String? {
        guard let strengthPattern else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = strengthPattern.firstMatch(in: line, range: range),
              let numberRange = Range(match.range(at: 1), in: line),
              let unitRange = Range(match.range(at: 2), in: line) else { return nil }
        let number = String(line[numberRange])
        let unit = String(line[unitRange])
        // ASCII units are case-normalized ("MG" → "mg"); Devanagari units are
        // left exactly as printed.
        let normalizedUnit = unit.allSatisfy(\.isASCII) ? unit.lowercased() : unit
        return "\(number) \(normalizedUnit)"
    }

    /// `line` with its first strength token removed ("Amoxicillin 500 mg" →
    /// "Amoxicillin").
    private static func removingStrength(from line: String) -> String {
        guard let strengthPattern else { return line }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = strengthPattern.firstMatch(in: line, range: range),
              let matchRange = Range(match.range, in: line) else { return line }
        return line.replacingCharacters(in: matchRange, with: " ")
    }

    // MARK: - Name plumbing

    /// The words that mark a line as NOT a name: directions, warnings and
    /// storage notes. A line containing any of them is skipped whole — a
    /// partially-parsed "Take 1 tablet in the morning" is a worse name than
    /// no name at all.
    ///
    /// Dose FORM words are deliberately NOT in this list even though most of
    /// them (tablet, capsule, syrup, …) can appear on a directions line:
    /// they are handled by `trimmingFormWords` instead, which strips them off
    /// the END of the line. Rejecting the line outright — the rule before
    /// [MED-OCR]'s review — made "Amlodipine Tablet 5 mg" unreadable, and
    /// that is one of the commonest ways a box prints its name. The
    /// directions lines are still kept out, by the direction words here and
    /// by the digit guard in `name(fromLines:)`.
    private static let noiseWords = [
        "take", "swallow", "directions", "dosage", "dose", "each", "every",
        "times", "before", "after", "food", "meal", "water", "doctor",
        "pharmacy", "store", "keep", "warning", "exp", "batch", "lot",
        "mfg", "manufactured", "ndc", "rx",
        "खानु", "खाने", "खुराक", "मात्रा", "प्रयोग", "दिनमा", "पटक",
        "चिकित्सक", "डाक्टर", "अघि", "पछि", "खाना", "पानी", "चेतावनी",
        "सावधान", "भण्डारण", "म्याद", "लट", "निर्माता", "औषधालय"
    ]

    /// Dose forms stripped off the END of a name line ("Amoxicillin Tablet"
    /// → "Amoxicillin"). Only trailing ones: a form word inside a name is
    /// part of the name ("Capsule Plus"), and a line that is ONLY a form word
    /// strips to nothing and is then rejected by the caller's letter count.
    private static let formWords = ["tablet", "tablets", "capsule", "capsules",
                                    "syrup", "suspension", "injection", "ointment",
                                    "drops",
                                    "ट्याब्लेट", "क्याप्सुल", "सिरप"]

    private static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if noiseWords.contains(where: { lowered.contains($0) }) { return true }
        // A line with no letters at all (pure digits, punctuation, a box
        // rule) is never a name.
        return !hasEnoughLetters(line)
    }

    /// True when the text begins with a numeral — the shape of a dose line
    /// ("1 tablet twice a day") rather than of a medicine's name.
    private static func startsWithDigit(_ text: String) -> Bool {
        text.first?.isNumber ?? false
    }

    /// True when the text holds at least three letters (Latin or Devanagari)
    /// — the shortest real medicine name is around that, and a two-letter
    /// fragment is a crop artifact, a strength suffix ("XR" alone) or noise.
    private static func hasEnoughLetters(_ text: String) -> Bool {
        text.filter { $0.isLetter }.count >= 3
    }

    /// `text` with its day pattern, its time words and its count phrases
    /// removed — the remainder of a name line once the schedule is off it.
    private static func removingScheduleTokens(from text: String) -> String {
        var result = text
        for regex in [dayPattern, countPattern].compactMap({ $0 }) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: " ")
        }
        for entry in timeWordHours {
            for word in entry.words {
                result = result.replacingOccurrences(of: word, with: " ",
                                                     options: [.caseInsensitive])
            }
        }
        return result
    }

    /// Drops any trailing dose-form word, repeatedly ("Amoxicillin Tablet
    /// Tablets" → "Amoxicillin"). Stripping is unconditional — a line that is
    /// ONLY a form word ("Tablet") becomes empty and is rejected by the
    /// caller's letter-count guard, which is the same verdict by one route
    /// instead of two.
    private static func trimmingFormWords(_ text: String) -> String {
        var result = trimmed(text)
        while let word = formWords.first(where: { result.lowercased().hasSuffix($0) }) {
            result = trimmed(String(result.dropLast(word.count)))
        }
        return result
    }

    /// Trims the punctuation a box puts around a name ("• Amoxicillin -").
    private static func trimmingSeparators(_ text: String) -> String {
        var result = trimmed(text)
        let separators = CharacterSet(charactersIn: " -–—•*:|,;()[]{}<>/\\")
        while let first = result.unicodeScalars.first, separators.contains(first) {
            result = String(result.dropFirst())
        }
        while let last = result.unicodeScalars.last, separators.contains(last) {
            result = String(result.dropLast())
        }
        return trimmed(result)
    }

    // MARK: - Digits and whitespace

    /// Devanagari digits (०–९) normalized to ASCII. Everything downstream —
    /// the day pattern, the count table, the strength numbers — then has one
    /// numeral system to read, which is what lets a Nepali label's "१-०-१"
    /// parse at all.
    static func normalizedDigits(_ text: String) -> String {
        String(text.map { character in
            guard let scalar = character.unicodeScalars.first,
                  character.unicodeScalars.count == 1,
                  scalar.value >= 0x0966, scalar.value <= 0x096F else { return character }
            return Character(String(scalar.value - 0x0966))
        })
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The recognizer (everything Vision-shaped)

/// What can go wrong between a photo and its lines.
enum MedicationLabelOCRError: Error, Equatable {
    /// The image carried no bitmap to recognize — a `UIImage` that is not
    /// backed by pixels (the camera never returns one; a test or a future
    /// path can).
    case noUsableImage
    /// Vision refused the request. Nothing was read; the photo is still
    /// attached by the caller.
    case recognitionFailed
}

/// The injectable recognition seam: everything Vision-shaped, in this
/// feature's own vocabulary. Production is
/// `VisionMedicationLabelRecognizer`; a test supplies lines and needs no
/// camera, no device and no rendered label.
protocol MedicationLabelRecognizing: AnyObject {
    /// One on-device recognition pass over `image`. Returns the recognized
    /// lines in Vision's own order (which is why the caller's "first
    /// plausible line is the name" rule sees the box's top line first);
    /// throws when there was nothing to recognize or Vision refused.
    func recognizeLines(in image: UIImage) throws -> [String]
}

/// The shipped recognizer: `VNRecognizeTextRequest`, on device, one pass.
///
/// Deliberately the same configuration `LiveTextDetector` ships
/// (`recognitionLevel = .accurate`, automatic language detection on iOS 16+)
/// rather than a second, differently-tuned Vision path: a medicine label is
/// dense small print in mixed scripts — the case the accurate level and
/// language detection exist for.
final class VisionMedicationLabelRecognizer: MedicationLabelRecognizing {

    private let request = VNRecognizeTextRequest()

    init() {
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(iOS 16.0, *) {
            request.automaticallyDetectsLanguage = true
        }
    }

    func recognizeLines(in image: UIImage) throws -> [String] {
        guard let cgImage = image.cgImage else {
            throw MedicationLabelOCRError.noUsableImage
        }
        // The captured photo's own orientation, handed to Vision: a label
        // photographed in landscape must not be recognized sideways.
        // `UIImage.Orientation` and `CGImagePropertyOrientation` share the
        // EXIF orientation numbering, so the raw value bridges directly; a
        // value the enum does not know (not produced by UIImage) falls back
        // to upright rather than a force-unwrap.
        let orientation = CGImagePropertyOrientation(
            rawValue: UInt32(image.imageOrientation.rawValue)) ?? .up
        let handler = VNImageRequestHandler(cgImage: cgImage,
                                            orientation: orientation,
                                            options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw MedicationLabelOCRError.recognitionFailed
        }
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }
}
