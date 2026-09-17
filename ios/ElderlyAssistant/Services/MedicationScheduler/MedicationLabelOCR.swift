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

    init(name: String? = nil,
         strength: String? = nil,
         scheduleTimes: [DateComponents] = [],
         frequency: MedicationFrequency? = nil) {
        self.name = name
        self.strength = strength
        self.scheduleTimes = scheduleTimes
        self.frequency = frequency
    }

    /// Nothing was read. The scanner still reports the photo — see
    /// `MedicationLabelScanResult` — so "no candidate" is a real, handled
    /// outcome and not a failure.
    static let empty = MedicationLabelCandidate()

    var isEmpty: Bool {
        name == nil && strength == nil && scheduleTimes.isEmpty && frequency == nil
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
            frequency: schedule.frequency
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

    /// What the label says about WHEN, from the two shapes a label actually
    /// carries:
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
    ///
    /// Failing both, a `<n> times a day` count becomes n default times. A
    /// label saying none of these yields no times — an empty schedule is the
    /// honest answer, and the editor keeps the time the family already had.
    static func schedule(in lines: [String]) -> (times: [DateComponents], frequency: MedicationFrequency?) {
        let text = normalizedDigits(lines.joined(separator: "\n")).lowercased()

        let weekly = weeklyTokens.contains { text.contains($0) }
        // The day pattern first: an explicit 1-0-1 outranks a stray "morning"
        // in a warning line, and outranks the count table below.
        if let pattern = dayPatternTimes(in: text) {
            return (pattern, weekly ? .weekly : .daily)
        }
        let words = timeWordTimes(in: text)
        if !words.isEmpty {
            return (words, weekly ? .weekly : .daily)
        }
        if let counted = countedDoseTimes(in: text) {
            return (counted, weekly ? .weekly : .daily)
        }
        if weekly { return ([], .weekly) }
        if dailyTokens.contains(where: { text.contains($0) }) { return ([], .daily) }
        return ([], nil)
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

    /// How many default times a "twice a day" count means, and which hours.
    /// Off-table counts (0, or 5+) yield nothing rather than a guess: "5
    /// times a day" is a real prescription and a real thing to get wrong.
    static let countedDoseHours: [Int: [(hour: Int, minute: Int)]] = [
        1: [(8, 0)],
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
