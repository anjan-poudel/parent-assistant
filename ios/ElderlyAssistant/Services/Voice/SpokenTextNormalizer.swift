import Foundation

/// [AUDIT-SPOKEN] (2026-10-14) The ONE speech-text normalization pass —
/// the shared seam the spoken-response mechanical-phrasing audit asked
/// for (finding HIGH-3).
///
/// Every string that reaches a synthesizer passes through `normalize`
/// exactly once per delivery, called from the only two concrete speaker
/// implementations (`SystemSpeechSpeaker.speak`, `PiperVoiceSpeaker
/// .speak`). Doing it at the speaker boundary — rather than at every
/// producer — is what makes the guarantee total: deterministic catalog
/// templates, model replies (which additionally pass
/// `SpokenReplyPolisher`), plugin/guide text, compose acknowledgements,
/// LiveTranslate speech, feed read-aloud, notification bodies, nav
/// steps and wake acknowledgements ALL funnel through the same two
/// entry points (verified at the [AUDIT-SPOKEN] change), so a new
/// producer CANNOT bypass normalization — there is no other door to the
/// engine.
///
/// Producers keep their own exact text: this returns a NEW string and
/// the caller keeps the raw one for the card/display. The Piper path
/// applies this AFTER `resolveVoiceSpec`, deliberately: the voice
/// audition keys on the exact out-loud-sample text and must see it
/// unchanged.
///
/// Pipeline (order is load-bearing, each stage pinned by unit tests):
///   1. collapse whitespace runs (stable shape for the regexes below)
///   2. drop decorative glyphs (™ ® ©)
///   3. strip media-title noise — "(Official Video)", "(Lyrics)",
///      " - Remastered 2011", "feat." → "featuring" (MEDIUM-5)
///   4. `SpokenUnits.normalizeDoseUnits` — "500 mg" → "500 milligrams"
///      (HIGH-1; briefing, dose alerts, confirmation challenge)
///   5. `SpokenUnits.normalizeMeasureUnits` — "5 kg", "500/kg", "km/h"
///      (MEDIUM-6 feed units)
///   6. `SpokenUnits.normalizeTemperatures` — the weather fix
///   7. numeric ranges — "14 – 22" / "2019–2021" → "14 to 22" /
///      "१४ देखि २२"; date-shaped hyphen forms ("2026-10-14",
///      "COVID-19", "555-1234") are never touched because only a
///      SPACED hyphen or a tight EN/EM dash counts
///   8. clock times with a colon + am/pm → `SpokenTime` (LOW-11: model
///      text saying "8:00 AM" comes out as the pinned spoken form)
///   9. web addresses → the site label ("www.bbc.com" → "bbc",
///      MEDIUM-4 search answers)
///  10. street suffixes — "Main St" → "Main Street" (nav steps; a
///      title form like "St. Louis"/"Dr. Smith" is protected by
///      lookarounds)
///  11. symbols and money — "%" → "percent/प्रतिशत", "₹500"/"Rs. 500" →
///      "500 rupees/५०० रुपैयाँ" (number first), "$/£/€" → words,
///      "&" → "and/र" (MEDIUM-6 feed ₹/%; the news entity map and
///      plugin bypass flows are automatically covered by the seam)
///  12. quotes and parens are DROPPED, content kept (LOW-13 calendar
///      quote marks, LOW-14 call parens) — punctuation a synthesizer
///      would read as "open paren"
///  13. prose dashes — first "… . — …" loses the dash, then any " — "
///      between words reads as a comma pause (LOW-12 em-dash
///      separators, briefing " — " joins)
///  14. final collapse + trim
///
/// Locale: English and Nepali, driven by the speaking locale; Nepali
/// gets Devanagari digits (the house convention) and Nepali unit words.
/// An unknown locale behaves as English (the app has exactly two).
///
/// Idempotence is a hard requirement — the seam may run after
/// `SpokenReplyPolisher` already normalized (model replies) and text can
/// be re-spoken (replay, notification re-read). Every stage is a fixed
/// point on its own output; `SpokenTextNormalizerTests` pins this for
/// the composite pass on a corpus of already-spoken lines.
///
/// Known limits (deliberate, matching the audit's WONTFIX discipline):
/// English clock times keep the pinned `SpokenTime` "1:30 pm" form (an
/// already-spoken convention AVSpeech reads correctly); "8:00" without
/// am/pm is not a match (could be a duration); two-digit years
/// ("'26") are untouched; a bare lower-case "g" after a single digit
/// ("5g") stays as written — as likely a network generation as a mass.
enum SpokenTextNormalizer {

    /// The full pass — see the type doc for the stage list and the
    /// order rationale. Pure and total: any input produces a String.
    static func normalize(_ text: String, locale: Locale) -> String {
        guard !text.isEmpty else { return text }
        let isNepali = locale.language.languageCode?.identifier == "ne"

        var value = collapseWhitespace(text)
        value = dropDecorativeSymbols(value)
        value = stripMediaTitleNoise(value)
        value = SpokenUnits.normalizeDoseUnits(in: value, locale: locale)
        value = SpokenUnits.normalizeMeasureUnits(in: value, locale: locale)
        value = SpokenUnits.normalizeTemperatures(in: value, locale: locale)
        value = expandNumericRanges(value, isNepali: isNepali)
        value = normalizeClockTimes(value, locale: locale)
        value = speakableWebAddresses(value)
        value = expandStreetSuffixes(value)
        value = normalizeSymbolsAndMoney(value, locale: locale, isNepali: isNepali)
        value = dropQuoteAndParenCharacters(value)
        value = normalizeProseDashes(value)
        return collapseWhitespace(value)
    }

    // MARK: - 1 / 14 — whitespace

    private static let whitespaceRunPattern = try? NSRegularExpression(
        pattern: "[ \t]{2,}")

    /// Runs of spaces/tabs read as odd pauses; newlines are kept (they
    /// are the synthesizer's own pause signal).
    private static func collapseWhitespace(_ text: String) -> String {
        var value = text
        if let pattern = whitespaceRunPattern {
            value = pattern.stringByReplacingMatches(
                in: value,
                range: NSRange(location: 0, length: (value as NSString).length),
                withTemplate: " ")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 2 — decorative glyphs

    private static let decorativeSymbolPattern = try? NSRegularExpression(
        pattern: "[™®©]")

    /// Trademark/copyright marks are decoration on a screen and noise in
    /// a voice line ("tm" read aloud).
    private static func dropDecorativeSymbols(_ text: String) -> String {
        guard let pattern = decorativeSymbolPattern else { return text }
        return pattern.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: "")
    }

    // MARK: - 3 — media-title noise (MEDIUM-5)

    /// "(Official Video)", "(Official Music Video)", "(Official Lyric
    /// Video)", "(Official Audio)", "(Music Video)", "(Lyric Video)",
    /// "(Lyrics)", "(Audio)", "(Video)", "(Visualizer)", with an
    /// optional quality tag. The structure — a closed set of prefix
    /// words, then a known base noun, then the bracket — is deliberate
    /// so an organic parenthetical like "(video call)" or "(audio
    /// interview)", where more words follow, is NOT stripped.
    private static let mediaNoiseParentheticalPattern = try? NSRegularExpression(
        pattern: "[ ]*[\\[(](?:(?:official|music|lyric|hd|4k)[ \t]+)*(?:video|audio|lyric[s]?|visualizer)(?:[ \t]+(?:hd|4k|1080p))?[\\])]",
        options: [.caseInsensitive])

    /// "(Remastered)", "(Remastered 2011)", "(Deluxe)", "(Deluxe
    /// Edition)", "(Anniversary Edition)".
    private static let remasterParentheticalPattern = try? NSRegularExpression(
        pattern: "[ ]*[\\[(](?:remaster(?:ed)?(?:[ \t]+\\d{4})?|deluxe(?:[ \t]+edition)?|anniversary[ \t]+edition)[\\])]",
        options: [.caseInsensitive])

    /// The Spotify/YouTube tail form: " - Single", " - EP",
    /// " - Remastered 2011", " - Deluxe Edition". The leading whitespace
    /// is consumed so the join stays clean.
    private static let releaseSuffixPattern = try? NSRegularExpression(
        pattern: "[ \t]+[-–—][ \t]+(?:single|ep|remaster(?:ed)?(?:[ \t]+\\d{4})?|deluxe(?:[ \t]+edition)?)\\b",
        options: [.caseInsensitive])

    /// "feat." / "feat" (the artist credit verb) — always expands, the
    /// abbreviation is never read right ("feat" as in "feet"/"feature").
    private static let featPattern = try? NSRegularExpression(
        pattern: "\\bfeat\\.?[ \t]+",
        options: [.caseInsensitive])

    private static func stripMediaTitleNoise(_ text: String) -> String {
        var value = text
        for pattern in [mediaNoiseParentheticalPattern,
                        remasterParentheticalPattern,
                        releaseSuffixPattern] {
            guard let pattern else { continue }
            value = pattern.stringByReplacingMatches(
                in: value,
                range: NSRange(location: 0, length: (value as NSString).length),
                withTemplate: "")
        }
        if let pattern = featPattern {
            value = pattern.stringByReplacingMatches(
                in: value,
                range: NSRange(location: 0, length: (value as NSString).length),
                withTemplate: "featuring ")
        }
        return value
    }

    // MARK: - 7 — numeric ranges

    /// A SPACED hyphen or en/em dash between two number tokens: "14 - 22",
    /// "2019 – 2021", "10 — 15 minutes". The lookarounds keep adjacent
    /// forms alone; a trailing period is allowed through (sentence end —
    /// "See pages 14–22." keeps its period).
    private static let spacedRangePattern = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}.,])([0-9०-९]+(?:\\.[0-9०-९]+)?)[ \t]+[-–—][ \t]+([0-9०-९]+(?:\\.[0-9०-९]+)?)(?![\\p{L}\\p{N},])")

    /// A TIGHT en/em dash between two number tokens: "2019–2021",
    /// "14–22". Deliberately excludes the ASCII hyphen — that is where
    /// "2026-10-14", "COVID-19" and "555-1234" live, and none of them
    /// is a spoken range.
    private static let tightRangePattern = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}.,])([0-9०-९]+(?:\\.[0-9०-९]+)?)[–—]([0-9०-९]+(?:\\.[0-9०-९]+)?)(?![\\p{L}\\p{N},])")

    /// "14 – 22" / "2019–2021" → "14 to 22" / "2019 to 2021" ("१४ देखि
    /// २२" under Nepali — the `देखि` range word the weather templates
    /// already use).
    private static func expandNumericRanges(_ text: String, isNepali: Bool) -> String {
        var value = text
        for pattern in [spacedRangePattern, tightRangePattern] {
            guard let pattern else { continue }
            let connector = isNepali ? "देखि" : "to"
            value = SpokenUnits.replacingMatches(of: pattern, in: value) { match, ns in
                let low = ns.substring(with: match.range(at: 1))
                let high = ns.substring(with: match.range(at: 2))
                if isNepali {
                    return "\(SpokenUnits.toDevanagari(low)) \(connector) \(SpokenUnits.toDevanagari(high))"
                }
                return "\(low) \(connector) \(high)"
            }
        }
        return value
    }

    // MARK: - 8 — clock times (LOW-11)

    /// "8:00 am" / "8:30 PM" / "8:00 a.m." — colon forms carrying an
    /// am/pm marker (the marker is what disambiguates from durations).
    /// Two branches on purpose: the dotted spelling "a.m." owns its
    /// trailing dot (the "period" is abbreviation punctuation), the
    /// plain spelling "am" never consumes a following dot (that one is
    /// the sentence's — "…at 8:00 am." keeps it). The lookarounds keep
    /// seconds ("12:30:45") and version-like tokens alone.
    private static let clockTimePattern = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}:.])([0-9०-९]{1,2}):([0-9०-९]{2})[ \t]*(?:([ap])\\.m\\.?|([ap])m)(?![\\p{L}\\p{N}])",
        options: [.caseInsensitive])

    /// Re-emits model clock strings through the pinned `SpokenTime`
    /// convention: "8:00 am" → "8 am", "8:30 pm" → "8:30 pm", "१:३०
    /// दिउँसो"? — the Nepali output follows the house "दिउँसो १ बजेर ३०
    /// मिनेट" convention. An hour outside 0–12 is out of scope and
    /// passes through untouched (24-hour "20:30" has no marker anyway).
    private static func normalizeClockTimes(_ text: String, locale: Locale) -> String {
        guard let pattern = clockTimePattern else { return text }
        return SpokenUnits.replacingMatches(of: pattern, in: text) { match, ns in
            let hourText = ns.substring(with: match.range(at: 1))
            let minuteText = ns.substring(with: match.range(at: 2))
            let markerRange = match.range(at: 3).location != NSNotFound
                ? match.range(at: 3) : match.range(at: 4)
            let marker = ns.substring(with: markerRange).lowercased()
            guard let hour = intValue(of: hourText),
                  let minute = intValue(of: minuteText),
                  (0...12).contains(hour),
                  (0...59).contains(minute) else {
                return ns.substring(with: match.range)
            }
            var hour24 = hour % 12          // "12 am" → 0
            if marker == "p" { hour24 += 12 } // "12 pm" → 12
            return SpokenTime.string(hour: hour24, minute: minute, locale: locale)
        }
    }

    /// Parses a run of ASCII or Devanagari digits. Nil on anything else
    /// (the caller then leaves the match untouched).
    private static func intValue(of raw: String) -> Int? {
        var ascii = ""
        for character in raw {
            if let asciiValue = character.asciiValue, asciiValue >= 48, asciiValue <= 57 {
                ascii.append(Character(UnicodeScalar(asciiValue)))
            } else if let digit = devanagariDigitIndex(of: character) {
                // UnicodeScalar(UInt8) is non-failable (0-255 are all valid
                // scalars) — no force-unwrap here (compile error otherwise).
                ascii.append(Character(UnicodeScalar(48 + UInt8(digit))))
            } else {
                return nil
            }
        }
        return Int(ascii)
    }

    private static let devanagariDigits = Array("०१२३४५६७८९")

    private static func devanagariDigitIndex(of character: Character) -> Int? {
        devanagariDigits.firstIndex(of: character)
    }

    // MARK: - 9 — web addresses (MEDIUM-4)

    /// A dotted hostname ending in a known TLD. The lookbehind keeps
    /// e-mail addresses ("x@site.com") and paths alone.
    private static let webAddressPattern = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}@/])(?:[a-z0-9][a-z0-9-]*\\.)+(?:com|org|net|edu|gov|io|co|uk|us|ca|au|in|np|info|biz|app|dev|me|tv|news)\\b",
        options: [.caseInsensitive])

    /// Subdomain noise never worth speaking; stripped only when at
    /// least two labels remain, so "news.com" still says "news".
    private static let leadingSubdomains: Set<String> = ["www", "m", "mobile", "amp", "web", "news"]

    /// "www.bbc.com" → "bbc", "m.thehindu.com" → "thehindu",
    /// "news.bbc.co.uk" → "bbc". A synthesizer reading "w w w dot b b c
    /// dot com" was the MEDIUM-4 finding; the site's NAME is what a
    /// person says.
    private static func speakableWebAddresses(_ text: String) -> String {
        guard let pattern = webAddressPattern else { return text }
        return SpokenUnits.replacingMatches(of: pattern, in: text) { match, ns in
            let host = ns.substring(with: match.range)
            var labels = host.split(separator: ".").map(String.init)
            while labels.count > 2,
                  leadingSubdomains.contains(labels[0].lowercased()) {
                labels.removeFirst()
            }
            return labels.first ?? host
        }
    }

    // MARK: - 10 — street suffixes

    /// "Main St" → "Main Street". Requires a word character + space
    /// directly before the token, which keeps sentence-initial and
    /// title forms ("St. Louis", "St. Patrick's") untouched — and the
    /// lookahead additionally protects the title pattern when the
    /// abbreviation sits mid-sentence ("on St. Louis Ave").
    private static let streetSuffixPattern = try? NSRegularExpression(
        pattern: "(?<=\\p{L}[ \t])(st|ave|rd|blvd|hwy|ln|ct|pl|ter)\\b(?!\\.[ \t]+\\p{Lu})",
        options: [.caseInsensitive])

    /// Deliberately NO "dr" — "see Dr. Patel" is a hundred times more
    /// likely in this app than "Elm Dr", and "Dr" → "Drive" before a
    /// name would be embarrassing. "Drive" spelled out passes through.
    private static let streetSuffixWords = ["st": "Street", "ave": "Avenue",
                                            "rd": "Road", "blvd": "Boulevard",
                                            "hwy": "Highway", "ln": "Lane",
                                            "ct": "Court", "pl": "Place",
                                            "ter": "Terrace"]

    private static func expandStreetSuffixes(_ text: String) -> String {
        guard let pattern = streetSuffixPattern else { return text }
        return SpokenUnits.replacingMatches(of: pattern, in: text) { match, ns in
            let token = ns.substring(with: match.range(at: 1))
            guard let expansion = streetSuffixWords[token.lowercased()] else {
                return token
            }
            // "Main ST" shouts; "main st" doesn't — mirror the token's
            // own capitalization.
            let firstIsUpper = token.first?.isUppercase ?? false
            return firstIsUpper ? expansion : expansion.lowercased()
        }
    }

    // MARK: - 11 — symbols and money

    private static let ampersandPattern = try? NSRegularExpression(
        pattern: "(?<=[\\p{L}\\p{N}])[ \t]*&[ \t]*(?=[\\p{L}\\p{N}])")

    private static let percentPattern = try? NSRegularExpression(
        pattern: "([0-9०-९]+(?:\\.[0-9०-९]+)?)[ \t]*%")

    /// Percent ranges, both spellings: "50%-60%" and the half-slurred
    /// "10-15%" (only the trailing % — one marker is enough to read the
    /// hyphen as a range word). Run BEFORE the plain percent pass so
    /// the first "50%" is not consumed alone.
    private static let percentRangePattern = try? NSRegularExpression(
        pattern: "([0-9०-९]+(?:\\.[0-9०-९]+)?)[ \t]*%?[ \t]*[-–—][ \t]*([0-9०-९]+(?:\\.[0-9०-९]+)?)[ \t]*%")

    /// The money patterns share one shape — number, an OPTIONAL scale
    /// word, then the currency name. The scale group exists because the
    /// number-first reorder must not split "… billion": "$40 billion" →
    /// "40 billion dollars", never "40 dollars billion".
    private static let moneyScaleWords = "billion|million|thousand|lakh|crore|trillion"
    private static let moneyTail = "([0-9०-९]+(?:,[0-9०-९]{3})*(?:\\.[0-9०-९]+)?)(?:[ \t]+(" + moneyScaleWords + ")\\b)?"

    private static let rupeeSymbolPattern = try? NSRegularExpression(
        pattern: "₹[ \t]*" + moneyTail,
        options: [.caseInsensitive])

    /// "Rs. 500" / "Rs 500" / "रु. ५००" — the Nepali abbreviation too.
    private static let rupeeAbbreviationPattern = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}])(?:Rs\\.?|रु\\.?)[ \t]*" + moneyTail,
        options: [.caseInsensitive])

    private static let dollarPattern = try? NSRegularExpression(
        pattern: "\\$[ \t]*" + moneyTail,
        options: [.caseInsensitive])

    private static let poundPattern = try? NSRegularExpression(
        pattern: "£[ \t]*" + moneyTail,
        options: [.caseInsensitive])

    private static let euroPattern = try? NSRegularExpression(
        pattern: "€[ \t]*" + moneyTail,
        options: [.caseInsensitive])

    /// The scale word as Nepali ("billion" → "बिलियन", "crore" →
    /// "करोड" — the words Nepali news actually uses).
    private static let neScaleWords = ["billion": "बिलियन", "million": "मिलियन",
                                       "thousand": "हजार", "lakh": "लाख",
                                       "crore": "करोड", "trillion": "ट्रिलियन"]

    /// "%", "₹500", "Rs. 500", "$5", "£5", "€5" and a bare "&" — the
    /// symbols a screen shows and a voice should never pronounce as
    /// themselves (MEDIUM-6). Money is reordered NUMBER FIRST ("500
    /// rupees" / "५०० रुपैयाँ") — the natural spoken English/Nepali
    /// order.
    private static func normalizeSymbolsAndMoney(_ text: String,
                                                 locale: Locale,
                                                 isNepali: Bool) -> String {
        var value = text

        if let pattern = ampersandPattern, let bare = try? NSRegularExpression(pattern: "&") {
            let word = isNepali ? "र" : "and"
            value = SpokenUnits.replacingMatches(of: pattern, in: value) { _, _ in
                " \(word) "
            }
            value = bare.stringByReplacingMatches(
                in: value,
                range: NSRange(location: 0, length: (value as NSString).length),
                withTemplate: " \(word) ")
        }

        if let pattern = percentRangePattern {
            let word = isNepali ? "प्रतिशत" : "percent"
            let connector = isNepali ? "देखि" : "to"
            value = SpokenUnits.replacingMatches(of: pattern, in: value) { match, ns in
                let low = ns.substring(with: match.range(at: 1))
                let high = ns.substring(with: match.range(at: 2))
                if isNepali {
                    return "\(SpokenUnits.toDevanagari(low)) \(connector) \(SpokenUnits.toDevanagari(high)) \(word)"
                }
                return "\(low) \(connector) \(high) \(word)"
            }
        }
        if let pattern = percentPattern {
            let word = isNepali ? "प्रतिशत" : "percent"
            value = SpokenUnits.replacingMatches(of: pattern, in: value) { match, ns in
                let raw = ns.substring(with: match.range(at: 1))
                let number = isNepali ? SpokenUnits.toDevanagari(raw) : raw
                return "\(number) \(word)"
            }
            value = value.replacingOccurrences(of: "%",
                                               with: isNepali ? " प्रतिशत" : " percent")
        }

        let moneyForms: [(NSRegularExpression?, String, String)] = [
            (rupeeSymbolPattern, "rupees", "रुपैयाँ"),
            (rupeeAbbreviationPattern, "rupees", "रुपैयाँ"),
            (dollarPattern, "dollars", "डलर"),
            (poundPattern, "pounds", "पाउन्ड"),
            (euroPattern, "euros", "युरो")
        ]
        for (pattern, englishWord, nepaliWord) in moneyForms {
            guard let pattern else { continue }
            let word = isNepali ? nepaliWord : englishWord
            value = SpokenUnits.replacingMatches(of: pattern, in: value) { match, ns in
                let raw = ns.substring(with: match.range(at: 1))
                let number = isNepali ? SpokenUnits.toDevanagari(raw) : raw
                if match.range(at: 2).location != NSNotFound {
                    let rawScale = ns.substring(with: match.range(at: 2))
                    let scale = isNepali
                        ? (neScaleWords[rawScale.lowercased()] ?? rawScale) : rawScale
                    return "\(number) \(scale) \(word)"
                }
                return "\(number) \(word)"
            }
        }

        // Any currency glyph that survived a pattern (e.g. "US$" with
        // no number behind it) still must not be read as a character.
        value = value.replacingOccurrences(of: "₹",
                                           with: isNepali ? " रुपैयाँ" : " rupees")
        value = value.replacingOccurrences(of: "$",
                                           with: isNepali ? " डलर" : " dollars")
        value = value.replacingOccurrences(of: "£",
                                           with: isNepali ? " पाउन्ड" : " pounds")
        value = value.replacingOccurrences(of: "€",
                                           with: isNepali ? " युरो" : " euros")
        return value
    }

    // MARK: - 12 — quotes and parens (LOW-13, LOW-14)

    /// Straight and typographic quotes and parentheses are punctuation,
    /// not content: "“Amlodipine”" and "(morning dose)" must read as the
    /// words alone — a synthesizer says "open paren"/"quote" otherwise.
    /// The characters are removed, everything between them stays.
    private static let removableCharacters: Set<Character> =
        ["\"", "\u{201C}", "\u{201D}", "\u{00AB}", "\u{00BB}", "(", ")"]

    private static func dropQuoteAndParenCharacters(_ text: String) -> String {
        String(text.filter { !removableCharacters.contains($0) })
    }

    // MARK: - 13 — prose dashes (LOW-12)

    /// A dash opening a sentence after terminal punctuation is the
    /// calendar/feed quote shape ("काठमाडौं। — bbc"): the dash is a
    /// separator mark, the pause already lives in the period.
    private static let sentenceDashPattern = try? NSRegularExpression(
        pattern: "([.!?।])[ \t]+[-–—][ \t]+")

    /// Any remaining spaced dash between words is an aside/pause:
    /// "Sorry — I couldn't" → "Sorry, I couldn't". A comma is the
    /// spoken pause — a synthesizer may read the dash as "minus" or
    /// swallow it silently.
    private static let proseDashPattern = try? NSRegularExpression(
        pattern: "[ \t]+[-–—][ \t]+")

    private static func normalizeProseDashes(_ text: String) -> String {
        var value = text
        if let pattern = sentenceDashPattern {
            value = pattern.stringByReplacingMatches(
                in: value,
                range: NSRange(location: 0, length: (value as NSString).length),
                withTemplate: "$1 ")
        }
        if let pattern = proseDashPattern {
            value = pattern.stringByReplacingMatches(
                in: value,
                range: NSRange(location: 0, length: (value as NSString).length),
                withTemplate: ", ")
        }
        return value
    }
}
