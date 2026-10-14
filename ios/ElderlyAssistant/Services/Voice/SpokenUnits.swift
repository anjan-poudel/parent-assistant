import Foundation

/// Shared SPOKEN-unit formatting for reply text (weather-wording task,
/// 2026-10-14; extended by the spoken-response mechanical-phrasing audit,
/// [AUDIT-SPOKEN] 2026-10-14).
///
/// The reported bug: the assistant said "15c" — the spoken weather reply
/// carried the raw token "15°C" and a synthesizer reads it
/// letter-by-letter. Same doctrine as `SpokenTime`: the spoken form of a
/// number/unit is produced by deterministic code, never by a prompt's
/// promise. The deterministic catalog templates are fixed at the source
/// (no `°` survives in a weather template any more) and THIS helper is
/// the same guarantee for MODEL-GENERATED replies, applied from
/// `SpokenReplyPolisher.polish` before any text reaches the speaker.
///
/// Output conventions (pinned by unit tests):
///  - English: "15 degrees Celsius" / "60 degrees Fahrenheit". A bare
///    "°" becomes "15 degrees" — the scale is not in the token, so it is
///    never invented.
///  - Nepali: Devanagari numerals (the house convention of
///    `BikramSambat.devanagariDigits`, `TopicPreAnswer`,
///    `CalculatorTool`) plus "डिग्री सेल्सियस": "१५ डिग्री सेल्सियस".
///  - Once the scale is already established earlier in the text —
///    spelled by this pass or written out in the source — later
///    mentions keep the short form: "…15 degrees Celsius… and 10
///    degrees tonight" / "…१५ डिग्री सेल्सियस… अनि राति १० डिग्री"।
///  - A hyphen/en-dash range followed by the spoken degree word is a
///    RANGE: "14-22°C" → "14 to 22 degrees Celsius" / "१४ देखि २२
///    डिग्री सेल्सियस" (the `देखि` range word the weather templates
///    already use). A dash not followed by the degree word ("pages
///    14–22") is left untouched.
///
/// Recognized forms: "15c", "15C", "15°C", "15 °C", "15 ° c", "15.5c",
/// "-5°C", "15ºF", "15 degrees C", "15 deg C", "१५°C". Conservative by
/// construction: a C/F letter only counts as a unit when it is a
/// standalone token (never followed by another letter or digit), so
/// "15cm", "15fps" and "degenerate" are never rewritten.
///
/// [AUDIT-SPOKEN] (2026-10-14) The audit added two more unit families to
/// this file — `normalizeDoseUnits` (medication strength: "500 mg" was
/// synthesized as "five hundred em gee") and `normalizeMeasureUnits`
/// (feeds/news: kg/km/cm/mm/g, "500/kg", "km/h"). Both are applied by
/// `SpokenTextNormalizer` at the speaker boundary, so they reach every
/// spoken path; `SpokenReplyPolisher` keeps calling the temperature pass
/// for model text. The broader symbol/media/time/host stages of the
/// audit live in `SpokenTextNormalizer`.
///
/// Known limits (deliberate): a decimal comma ("15,5°C") passes through
/// (ambiguous with list commas); "2 C batteries" (a battery size) reads
/// as a temperature — accepted, since the reply vocabulary is
/// weather/health/chat where the C is Celsius; slashed dose ratios
/// ("5mg/ml") expand the strength only — the "/ml" tail still reads as a
/// slash (rare on caregiver labels, fixable later).
///
/// Pure and total: any input produces a String. Idempotent: the output
/// of a pass is never rewritten by the same pass again.
enum SpokenUnits {

    /// The full normalization: spelled short forms first ("deg C"), then
    /// the °/letter tokens, then dash ranges (which need the expanded
    /// degree word to recognize "14-22°C" as a range).
    static func normalizeTemperatures(in text: String, locale: Locale) -> String {
        let isNepali = locale.language.languageCode?.identifier == "ne"
        var value = expandSpelledUnits(in: text, isNepali: isNepali)
        value = expandTemperatureSymbols(in: value, isNepali: isNepali)
        value = expandDashRanges(in: value, isNepali: isNepali)
        return value
    }

    // MARK: - Patterns

    /// A temperature token: optional minus, a number (ASCII or
    /// Devanagari digits, optional decimal part), then the unit suffix —
    /// "°"/"º" with an optional C/F letter, or a standalone C/F letter.
    /// The lookarounds keep the number intact inside larger tokens
    /// ("version15c" is not a temperature) and the letter must not
    /// continue into a word ("15cm", "15fps" stay as-is).
    ///
    /// Capture groups: 1 = minus sign, 2 = digits, 3 = the letter after
    /// "°" (only when one is present), 4 = a BARE "°" (a temperature of
    /// unknown scale — its own branch, so the whitespace after it is not
    /// swallowed when no letter follows), 5 = the attached standalone
    /// letter.
    private static let temperaturePattern = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}])(-|−)?([0-9०-९]+(?:\\.[0-9०-९]+)?)\\s*(?:[°º]\\s*([cCfF])|([°º])(?![\\p{L}\\p{N}])|([cCfF])(?![\\p{L}\\p{N}]))")

    /// The spelled short form — "deg C", "deg. F", "degree C",
    /// "degrees C". The lead-in must be a whole word ("degenerate" is
    /// never touched) and the letter must end the word ("degrees
    /// Celsius" — C followed by "e" — is already the spoken form and
    /// stays byte-identical).
    private static let spelledUnitPattern = try? NSRegularExpression(
        pattern: "(?<![\\p{L}])(?:degrees?|deg)\\.?\\s*([cCfF])(?![\\p{L}\\p{N}])",
        options: [.caseInsensitive])

    /// A dash between two numbers directly followed by the spoken degree
    /// word: the shape "14–22 degrees Celsius" (which the symbol pass
    /// produces from "14–22°C"). The degree word is required, so
    /// "pages 14–22" never changes; already-spoken "to" ranges never
    /// match (idempotent).
    private static let dashRangePattern = try? NSRegularExpression(
        pattern: "([0-9०-९]+(?:\\.[0-9०-९]+)?)\\s*[-–—]\\s*([0-9०-९]+(?:\\.[0-9०-९]+)?)\\s+(degrees|डिग्री)",
        options: [.caseInsensitive])

    // MARK: - Passes

    /// "15 deg C" → "15 degrees Celsius" (the letter always expands to
    /// the full scale name — the spelled form already carries "degrees").
    private static func expandSpelledUnits(in text: String, isNepali: Bool) -> String {
        guard let pattern = spelledUnitPattern else { return text }
        return replacingMatches(of: pattern, in: text) { match, ns in
            let letter = ns.substring(with: match.range(at: 1)).uppercased()
            let celsius = letter == "C"
            if isNepali {
                return celsius ? "डिग्री सेल्सियस" : "डिग्री फारेनहाइट"
            }
            return celsius ? "degrees Celsius" : "degrees Fahrenheit"
        }
    }

    /// "It's 15°C." → "It's 15 degrees Celsius." / "१५°C" → "१५ डिग्री
    /// सेल्सियस". The scale word repeats only on first use — see the
    /// established-scale rule in the type doc.
    private static func expandTemperatureSymbols(in text: String, isNepali: Bool) -> String {
        guard let pattern = temperaturePattern else { return text }
        // What the listener has already heard of the scale, from this
        // pass's own earlier replacements (the original text before each
        // match is checked separately below).
        var celsiusEstablished = false
        var fahrenheitEstablished = false

        return replacingMatches(of: pattern, in: text) { match, ns in
            let prefixEnd = match.range.location
            let prefix = prefixEnd > 0
                ? ns.substring(with: NSRange(location: 0, length: prefixEnd)).lowercased()
                : ""
            let celsiusHeard = celsiusEstablished
                || prefix.contains("celsius")
                || prefix.contains("सेल्सियस")
            let fahrenheitHeard = fahrenheitEstablished
                || prefix.contains("fahrenheit")
                || prefix.contains("फारेनहाइट")

            let minus = match.range(at: 1).location != NSNotFound
                ? ns.substring(with: match.range(at: 1)) : ""
            let rawNumber = ns.substring(with: match.range(at: 2))
            let afterDegree = match.range(at: 3).location != NSNotFound
                ? ns.substring(with: match.range(at: 3)) : nil
            let attached = match.range(at: 5).location != NSNotFound
                ? ns.substring(with: match.range(at: 5)) : nil
            let number = isNepali ? toDevanagari(rawNumber) : rawNumber

            let unit: String
            switch (afterDegree ?? attached)?.uppercased() {
            case "C":
                unit = isNepali
                    ? (celsiusHeard ? "डिग्री" : "डिग्री सेल्सियस")
                    : (celsiusHeard ? "degrees" : "degrees Celsius")
                celsiusEstablished = true
            case "F":
                unit = isNepali
                    ? (fahrenheitHeard ? "डिग्री" : "डिग्री फारेनहाइट")
                    : (fahrenheitHeard ? "degrees" : "degrees Fahrenheit")
                fahrenheitEstablished = true
            default:
                // Bare "°" — the scale is not in the token, never invented.
                unit = isNepali ? "डिग्री" : "degrees"
            }
            return "\(minus)\(number) \(unit)"
        }
    }

    /// "14-22 degrees Celsius" → "14 to 22 degrees Celsius" ("१४ देखि
    /// २२ डिग्री" under Nepali) — a synthesizer may read the raw dash as
    /// a minus or swallow it.
    private static func expandDashRanges(in text: String, isNepali: Bool) -> String {
        guard let pattern = dashRangePattern else { return text }
        return replacingMatches(of: pattern, in: text) { match, ns in
            let low = ns.substring(with: match.range(at: 1))
            let high = ns.substring(with: match.range(at: 2))
            let unit = ns.substring(with: match.range(at: 3))
            let connector = isNepali ? "देखि" : "to"
            return "\(low) \(connector) \(high) \(unit)"
        }
    }

    // MARK: - Doses and measures ([AUDIT-SPOKEN] items 1 and 8)

    /// Medication-strength units spoken as words ([AUDIT-SPOKEN]
    /// 2026-10-14, audit item 1 — the HIGH finding). The class: a
    /// caregiver-typed "500 mg" synthesized as "five hundred em gee" and
    /// "1/2 tablet" as "one slash two". Highest-frequency mechanical
    /// text in the app: the daily briefing, every dose alert (via the
    /// notification reader) and the confirmation challenge all speak
    /// caregiver text.
    ///
    /// This is a SPEECH transform only. The card keeps the caregiver's
    /// own characters — the speaker gets this one.
    ///
    /// Forms: "500 mg"/"500mg"/"mgs", "mcg"/"µg"/"ug", "ml"/"mls", "IU"
    /// and the fraction "1/2"/"½" ("half"). A value of exactly 1 takes
    /// the singular unit ("1 milligram"); everything else is plural.
    /// Nepali output uses Devanagari numerals and the standard Nepali
    /// unit words ("५०० मिलीग्राम").
    static func normalizeDoseUnits(in text: String, locale: Locale) -> String {
        let isNepali = locale.language.languageCode?.identifier == "ne"
        var value = expandHalves(in: text, isNepali: isNepali)
        value = expandDoseUnitTokens(in: value, isNepali: isNepali)
        return value
    }

    /// General measure units spoken as words ([AUDIT-SPOKEN] 2026-10-14,
    /// audit item 8): feeds, news and search snippets carry "5 kg",
    /// "10km", "100 mm" and per-unit slashes ("500/kg", "km/h") that a
    /// synthesizer reads as letters. kg/km/cm/mm are case-insensitive
    /// (no collision); a standalone lower-case "g" counts as grams ONLY
    /// when it directly follows the number ("500 g", "500g") — "5G" is
    /// a network, never grams.
    static func normalizeMeasureUnits(in text: String, locale: Locale) -> String {
        let isNepali = locale.language.languageCode?.identifier == "ne"
        var value = expandPerUnitSlashes(in: text, isNepali: isNepali)
        value = expandMeasureUnitTokens(in: value, isNepali: isNepali)
        value = expandGrams(in: value, isNepali: isNepali)
        return value
    }

    /// The number token shared by every unit pattern — ASCII or
    /// Devanagari digits with an optional decimal part.
    private static let numberToken = "[0-9०-९]+(?:\\.[0-9०-९]+)?"

    /// "1/2" / "½" → "half" / "आधा" (the caregiver dose verb). The
    /// lookarounds keep decimal fractions ("1/2.5") and glued tokens
    /// ("x1/2") untouched. Devanagari digits accepted ("१/२").
    private static let halfSlashPattern = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}/])(?:1|१)\\s*/\\s*(?:2|२)(?![\\p{L}\\p{N}/])(?!\\.[0-9])")

    /// The "½" glyph, as a standalone token only ("1½" keeps its own
    /// shape — never guessed).
    private static let halfGlyphPattern = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}])½")

    /// The medication-strength tokens. "IU" lowercases to "iu"; the
    /// mixed-case "µg" survives lowercasing as-is.
    private static let doseUnitPattern = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}])(" + numberToken + ")\\s*(mgs|mg|mcg|µg|ug|mls|ml|iu)\\b",
        options: [.caseInsensitive])

    /// "500/kg" → "500 per kilogram", "60 km/h" → "60 kilometres per
    /// hour". Runs BEFORE the bare measure tokens so the slash unit is
    /// consumed as one phrase ("Rs. 500/kg" never leaves a naked "/kg").
    private static let perUnitSlashPattern = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}/])(" + numberToken + ")\\s*/\\s*(kg|g|ml|l|km)\\b",
        options: [.caseInsensitive])

    private static let speedSlashPattern = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}/])(" + numberToken + ")\\s*(?:km|kms)\\s*/\\s*h(?:r|our)?s?\\b",
        options: [.caseInsensitive])

    /// The ALREADY-EXPANDED dose-ratio tail ("5 milligrams/ml") — the
    /// dose pass runs first, so the "/ml" is matched in its spoken form.
    private static let doseRatioSlashPattern = try? NSRegularExpression(
        pattern: "(milligrams?|micrograms?|international units?)\\s*/\\s*(ml|millilitres?)\\b",
        options: [.caseInsensitive])

    /// Big measure tokens — longer alternatives first ("kgs" before
    /// "kg"), case-insensitive.
    private static let measureUnitPattern = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}])(" + numberToken + ")\\s*(kgs|kg|kms|km|cms|cm|mm)\\b",
        options: [.caseInsensitive])

    /// Lower-case "g" grams — case-SENSITIVE on purpose ("5G" is a
    /// network). A BARE integer must be ≥ 2 digits ("5g" alone is as
    /// likely a network generation as a mass); an explicit decimal
    /// ("1.5 g") is unambiguous and always counts. The audit's real
    /// cases are "500 g"/"500g".
    private static let gramsPattern = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}])([0-9०-९]{2,}(?:\\.[0-9०-९]+)?|[0-9०-९]+\\.[0-9०-९]+)\\s*(g)(?![\\p{L}\\p{N}])")

    /// "1/2 tablet" → "half tablet" / "१/२ …" → "आधा …" / "½ cup" →
    /// "half cup".
    private static func expandHalves(in text: String, isNepali: Bool) -> String {
        let word = isNepali ? "आधा" : "half"
        var value = text
        for pattern in [halfSlashPattern, halfGlyphPattern].compactMap({ $0 }) {
            value = pattern.stringByReplacingMatches(
                in: value,
                range: NSRange(location: 0, length: (value as NSString).length),
                withTemplate: word)
        }
        return value
    }

    /// The dose tokens themselves, with the singular/plural decision.
    private static func expandDoseUnitTokens(in text: String, isNepali: Bool) -> String {
        guard let pattern = doseUnitPattern else { return text }
        return replacingMatches(of: pattern, in: text) { match, ns in
            let raw = ns.substring(with: match.range(at: 1))
            let token = ns.substring(with: match.range(at: 2)).lowercased()
            let number = isNepali ? toDevanagari(raw) : raw
            let singular = raw == "1" || raw == "१"
            let unit: String
            switch token {
            case "mg", "mgs":
                unit = isNepali ? "मिलीग्राम" : (singular ? "milligram" : "milligrams")
            case "mcg", "µg", "ug":
                unit = isNepali ? "माइक्रोग्राम" : (singular ? "microgram" : "micrograms")
            case "ml", "mls":
                unit = isNepali ? "मिलीलिटर" : (singular ? "millilitre" : "millilitres")
            default:   // "iu"
                unit = isNepali ? "अन्तर्राष्ट्रिय युनिट"
                                : (singular ? "international unit" : "international units")
            }
            return "\(number) \(unit)"
        }
    }

    /// The per-unit slash forms, before the bare tokens: speed first
    /// ("60 km/h" must not leave a naked "km"), then the mass/volume
    /// slashes, then the already-expanded dose ratios.
    private static func expandPerUnitSlashes(in text: String, isNepali: Bool) -> String {
        var value = text
        if let pattern = speedSlashPattern {
            let unit = isNepali ? "किलोमिटर प्रति घण्टा" : "kilometres per hour"
            value = replacingMatches(of: pattern, in: value) { match, ns in
                let raw = ns.substring(with: match.range(at: 1))
                let number = isNepali ? toDevanagari(raw) : raw
                return "\(number) \(unit)"
            }
        }
        if let pattern = perUnitSlashPattern {
            let connector = isNepali ? "प्रति" : "per"
            value = replacingMatches(of: pattern, in: value) { match, ns in
                let raw = ns.substring(with: match.range(at: 1))
                let number = isNepali ? toDevanagari(raw) : raw
                let token = ns.substring(with: match.range(at: 2)).lowercased()
                let unit = isNepali ? Self.perUnitNepali[token] ?? token
                                    : Self.perUnitEnglish[token] ?? token
                return "\(number) \(connector) \(unit)"
            }
        }
        if let pattern = doseRatioSlashPattern {
            let unit = isNepali ? "प्रति मिलीलिटर" : "per millilitre"
            value = pattern.stringByReplacingMatches(
                in: value,
                range: NSRange(location: 0, length: (value as NSString).length),
                withTemplate: "$1 " + unit)
        }
        return value
    }

    private static let perUnitEnglish = ["kg": "kilogram", "g": "gram",
                                          "ml": "millilitre", "l": "litre",
                                          "km": "kilometre"]
    private static let perUnitNepali = ["kg": "किलोग्राम", "g": "ग्राम",
                                         "ml": "मिलीलिटर", "l": "लिटर",
                                         "km": "किलोमिटर"]

    /// The bare big-measure tokens with the singular/plural decision.
    private static func expandMeasureUnitTokens(in text: String, isNepali: Bool) -> String {
        guard let pattern = measureUnitPattern else { return text }
        return replacingMatches(of: pattern, in: text) { match, ns in
            let raw = ns.substring(with: match.range(at: 1))
            let token = ns.substring(with: match.range(at: 2)).lowercased()
            let number = isNepali ? toDevanagari(raw) : raw
            let singular = raw == "1" || raw == "१"
            let unit: String
            switch token {
            case "kg", "kgs":
                unit = isNepali ? "किलोग्राम" : (singular ? "kilogram" : "kilograms")
            case "km", "kms":
                unit = isNepali ? "किलोमिटर" : (singular ? "kilometre" : "kilometres")
            case "cm", "cms":
                unit = isNepali ? "सेन्टिमिटर" : (singular ? "centimetre" : "centimetres")
            default:   // "mm"
                unit = isNepali ? "मिलिमिटर" : (singular ? "millimetre" : "millimetres")
            }
            return "\(number) \(unit)"
        }
    }

    /// "500 g" / "500g" / "500.5 g" → "500 grams" (lower-case g only —
    /// "5G" is a network and the ≥2-digit rule keeps it that way).
    private static func expandGrams(in text: String, isNepali: Bool) -> String {
        guard let pattern = gramsPattern else { return text }
        return replacingMatches(of: pattern, in: text) { match, ns in
            let raw = ns.substring(with: match.range(at: 1))
            let number = isNepali ? toDevanagari(raw) : raw
            let singular = raw == "1" || raw == "१"
            let unit = isNepali ? "ग्राम" : (singular ? "gram" : "grams")
            return "\(number) \(unit)"
        }
    }

    // MARK: - Shared assembly

    /// Assembles `text` with every `pattern` match replaced by
    /// `replacement`'s output — left to right, so a replacement can
    /// depend on what precedes it. NSRange offsets are UTF-16, so the
    /// slicing math happens on the NSString view (same discipline as
    /// `SearchTool`'s sentence splitter). Internal since [AUDIT-SPOKEN]:
    /// `SpokenTextNormalizer` reuses it for its own passes.
    static func replacingMatches(of pattern: NSRegularExpression,
                                 in text: String,
                                 replacement: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: cursor,
                                              length: match.range.location - cursor))
            out += replacement(match, ns)
            cursor = match.range.upperBound
        }
        out += ns.substring(from: cursor)
        return out
    }

    // MARK: - Digits

    /// The shared Devanagari digit table — the same convention as
    /// `BikramSambat.devanagariDigits` (kept here at string level so a
    /// decimal part converts too; a sign character passes through).
    /// Internal since [AUDIT-SPOKEN]: `SpokenTextNormalizer` converts
    /// captured numbers (ranges, money, percentages) with it.
    private static let devanagariDigitTable = ["०", "१", "२", "३", "४", "५", "६", "७", "८", "९"]

    static func toDevanagari(_ text: String) -> String {
        String(text.map { character -> Character in
            guard let ascii = character.asciiValue, ascii >= 48, ascii <= 57 else {
                return character
            }
            return Character(devanagariDigitTable[Int(ascii - 48)])
        })
    }
}
