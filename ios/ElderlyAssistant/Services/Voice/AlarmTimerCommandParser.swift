import Foundation

/// [ALARMS-TIMERS] (2026-09-07) Deterministic, marker-gated parsers for
/// the voice alarm + timer commands, used by the `CommandRouter` stage
/// that runs BEFORE any model is consulted:
///
///  - "set an alarm for 6 am" / "wake me up at 7:30" / "alarm at 8 pm"
///  - "बिहान ६ बजे अलार्म लगाऊ" / "अलार्म ८ बजे" / "बिहान ६ बजे उठाउनुहोस्"
///  - "set a timer for 5 minutes" / "timer 10 minutes"
///  - "टाइमर ५ मिनेट" / "५ मिनेटको टाइमर लगाऊ"
///
/// Design rules:
///  - MARKER-GATED: nothing parses without an alarm/wake/timer marker, so
///    topic utterances, calculator expressions and small talk can never
///    false-positive. Whole-token matching (same semantics as
///    `TopicPreAnswer.token`) keeps short English words safe; the Nepali
///    honorific wake markers ("उठाउनुहोस्", "उठाइदिनुहोस्", …) match as
///    substrings. Bare "उठाउनु" (informal, subjectless) is deliberately
///    NOT a wake marker — the reminder corpus's "बिहान ६ बजे उठाउनु" keeps
///    routing to set_reminder exactly as before.
///  - VETOED before time extraction: questions ("when is my alarm?",
///    "कति बजेको अलार्म?"), cancellations ("cancel the timer", "बन्द
///    गर"), negations, third-person wake requests ("wake my grandson",
///    "छोरालाई उठाउनुहोस्" — that is not THIS device's alarm), and
///    countdown phrasings ("alarm in 5 minutes" — a countdown is a TIMER,
///    and timer commands win the parse order; the router checks
///    `parseTimer` first). Anything vetoed returns nil and the utterance
///    falls through the router ladder unchanged.
///  - Deterministic: `parseAlarm` takes an injectable `now`/`calendar`;
///    `parseTimer` is pure. Time-of-day phrases resolve to the NEXT future
///    occurrence (a 6 am spoken at 10 am rings tomorrow 6 am).
///  - Honest about its limits: compound durations ("1 hour 30 minutes")
///    return nil rather than silently keep only the first unit; timer
///    durations are bounded to 1…86400 s; out-of-bounds or garbage
///    returns nil (the interpreter sees the utterance, as today).
///
/// The alarm time engine reuses `NepaliTimeParser` (the reminder
/// set_reminder extractor): Devanagari + ASCII digits, ne period words
/// (बिहान/दिउँसो/साँझ/बेलुका/राति), साढे, colon/danda clocks, am/pm,
/// relative days (आज/भोलि/पर्सि, today/tomorrow) and weekday names.
/// English 12-hour periods NOT understood by that parser (afternoon,
/// evening, night, 12 am) are post-adjusted here.
enum AlarmTimerCommandParser {

    /// Maximum timer duration the parser accepts (24 h — matches
    /// `AlarmTimersService.maxTimerDurationSeconds`).
    static let maxTimerSeconds = 86_400

    // MARK: - Public parsers

    /// Parses an alarm command into its next-occurrence `Date` (injected
    /// `now`/`calendar` make resolution deterministic under test) plus an
    /// optional spoken label ("…for yoga" → "yoga"; most utterances have
    /// none). Returns nil for anything that is not a clear, actionable
    /// alarm command.
    static func parseAlarm(_ text: String,
                           now: Date = Date(),
                           calendar: Calendar = .current) -> (time: Date, label: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = NepaliTimeParser.normalise(trimmed)
        guard !normalized.isEmpty else { return nil }

        let hasAlarmMarker = alarmMarkers.contains { containsToken($0, in: normalized) }
        let hasWakeMarker = wakeMarkers.contains { normalized.contains($0) }
        guard hasAlarmMarker || hasWakeMarker else { return nil }

        // Vetoes — questions, cancellations, negations …
        guard !vetoedAsQuestionOrCancellation(normalized) else { return nil }
        // … third-party wake requests (wake-marker commands only; an
        // "alarm"-word command is always this device's own alarm) …
        if hasWakeMarker && mentionsAnotherPerson(normalized) { return nil }
        // … and countdown phrasings — "in N minutes/hours" is a TIMER
        // (which the router parses first); never silently an alarm.
        if countdownSpec(in: normalized) != nil { return nil }

        guard let parsed = NepaliTimeParser.parse(normalized),
              let hour = adjustedHour(from: parsed, text: normalized)
        else { return nil }
        let minute = min(max(parsed.minute ?? 0, 0), 59)

        // A full date (relative day / weekday / hours-later shape) pins the
        // exact day; anything already past rolls forward one day. A bare
        // time-of-day resolves to its NEXT occurrence after `now`.
        var date: Date?
        if parsed.year != nil, parsed.month != nil, parsed.day != nil {
            var base = DateComponents()
            base.year = parsed.year
            base.month = parsed.month
            base.day = parsed.day
            base.hour = hour
            base.minute = minute
            if let resolved = calendar.date(from: base) {
                date = resolved <= now
                    ? calendar.date(byAdding: .day, value: 1, to: resolved)
                    : resolved
            }
        } else {
            date = calendar.nextDate(after: now,
                                     matching: DateComponents(hour: hour, minute: minute),
                                     matchingPolicy: .nextTime)
        }
        guard let time = date else { return nil }

        return (time, labelForAlarm(from: trimmed))
    }

    /// Parses a timer command into whole seconds + optional label. Only
    /// single-unit durations parse (see class doc). Nil for anything else.
    static func parseTimer(_ text: String) -> (durationSeconds: Int, label: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = NepaliTimeParser.normalise(trimmed)
        guard !normalized.isEmpty else { return nil }
        guard timerMarkers.contains(where: { containsToken($0, in: normalized) }) else {
            return nil
        }
        guard !vetoedAsQuestionOrCancellation(normalized) else { return nil }
        guard let spec = countdownSpec(in: normalized) else { return nil }
        let durationSeconds = spec.amount * spec.unitSeconds
        guard (1...maxTimerSeconds).contains(durationSeconds) else { return nil }
        return (durationSeconds, labelForTimer(from: trimmed))
    }

    /// Spoken duration for confirmations: "5 minutes" / "1 hour 30
    /// minutes" / "५ मिनेट" (Devanagari digits). Built by hand — the
    /// `DateComponentsFormatter` has no `locale`, so it would render in
    /// the SYSTEM language, not the app language; this stays faithful to
    /// the user's chosen app language and is deterministic for tests.
    /// Whole units only, largest first, all nonzero units included:
    /// 3665 s → "1 hour 1 minute 5 seconds".
    static func durationText(seconds: Int, locale: Locale) -> String {
        let total = max(seconds, 0)
        let isNepali = locale.language.languageCode?.identifier == "ne"
        var text = ""
        func appendPart(_ value: Int, neWord: String, enSingular: String, enPlural: String) {
            guard value > 0 else { return }
            let word = isNepali ? neWord : (value == 1 ? enSingular : enPlural)
            let valueText = isNepali ? devanagari(String(value)) : String(value)
            text += text.isEmpty ? "\(valueText) \(word)" : " \(valueText) \(word)"
        }
        appendPart(total / 3600, neWord: "घण्टा", enSingular: "hour", enPlural: "hours")
        appendPart((total % 3600) / 60, neWord: "मिनेट", enSingular: "minute", enPlural: "minutes")
        appendPart(total % 60, neWord: "सेकेण्ड", enSingular: "second", enPlural: "seconds")
        return text
    }

    // MARK: - Markers

    /// Whole-token alarm markers.
    private static let alarmMarkers = ["alarm", "alarms", "अलार्म", "अलार्महरू"]

    /// Whole-token timer markers.
    private static let timerMarkers = ["timer", "timers", "टाइमर", "टाइमरहरू"]

    /// Wake-UP markers — the imperative wake-me forms that mean "ring me
    /// at this time". English: whole-token ("wake", "wakeup", "get"+"up").
    /// Nepali: substring honorific do-for-me forms only — the reminders
    /// corpus owns bare "उठाउनु" (subjectless "to wake") and it must keep
    /// routing to set_reminder, so it is NOT a marker here.
    private static let wakeMarkers = [
        "wake", "wakeup", "उठाउनुहोस्", "उठाइदिनुहोस्", "उठाइदेउ",
        "उठाउनुस्", "उठाइदिनुस्"
    ]

    // MARK: - Time resolution

    /// 12-hour fixes the NepaliTimeParser does not know about. The parser
    /// already handles "pm" and the Nepali period words; applied only to
    /// purely-English period phrasings:
    ///  - "12 am" / "12 at night" / "12 in the morning" → 0
    ///  - "6 in the evening" / "8 at night" / "10 tonight" → +12 h
    private static func adjustedHour(from components: DateComponents,
                                     text: String) -> Int? {
        guard var hour = components.hour else { return nil }
        hour = min(max(hour, 0), 23)

        let hasNepaliPeriod = nePeriodWords.contains { text.contains($0) }
        let hasExplicitAmPm = explicitPeriod("pm", in: text) || explicitPeriod("am", in: text)
        if hasExplicitAmPm {
            // The parser already applied pm (+12 for hours 1…11); only the
            // "12 am" → midnight fix is missing here.
            if explicitPeriod("am", in: text) && hour == 12 { return 0 }
            return hour
        }
        guard !hasNepaliPeriod else { return hour }

        // "12 am" is unreachable here (explicit am returns above), so
        // these are the word-only midnight phrasings.
        if hour == 12,
           ["morning", "midnight", "night", "tonight"].contains(where: { text.contains($0) }) {
            return 0
        }
        if (1...11).contains(hour),
           ["afternoon", "evening", "night", "tonight"].contains(where: { text.contains($0) }) {
            return hour + 12
        }
        return hour
    }

    /// "am"/"pm" directly attached to a digit ("6am") OR standing alone as
    /// a token. Scans every occurrence so the "am" inside "alarm" can
    /// never count.
    private static func explicitPeriod(_ period: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: period, range: searchStart..<text.endIndex) {
            let before = range.lowerBound > text.startIndex
                ? text[text.index(before: range.lowerBound)]
                : nil
            // Preceded by a letter → glued to a word ("alarm"): not a period.
            if let before, before.isLetter {
                searchStart = range.upperBound
                continue
            }
            return true
        }
        return false
    }

    // MARK: - Countdown grammar (timers) — shared with the alarm veto

    /// One number + ONE unit word describing a duration ("5 minutes",
    /// "२ घण्टा", "90 min"). Multiple DISTINCT unit words ("1 hour 30
    /// minutes") return nil — the single-unit-only contract. The number
    /// must sit immediately before the unit (whitespace apart). nil for
    /// garbage.
    private static func countdownSpec(in normalized: String) -> (amount: Int, unitSeconds: Int)? {
        let units = timerUnitWords(in: normalized)
        guard units.count == 1, let unit = units.first else { return nil }
        guard let range = unitRange(of: unit.word, in: normalized) else { return nil }
        guard let amount = amountImmediatelyBefore(range, in: normalized) else { return nil }
        return (amount, unit.seconds)
    }

    /// Unit words in order of appearance — candidates are tried
    /// longest-first so overlapping singular/plural forms ("hour" inside
    /// "hours") cannot double-count, and a match consumes its own text.
    private static func timerUnitWords(in text: String) -> [(word: String, seconds: Int)] {
        var found: [(word: String, seconds: Int)] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex {
            var earliest: (word: String, seconds: Int, range: Range<String.Index>)?
            for candidate in timerUnitsByLengthDesc {
                guard let range = text.range(of: candidate.word,
                                             range: searchStart..<text.endIndex) else { continue }
                if earliest == nil || range.lowerBound < earliest!.range.lowerBound {
                    earliest = (candidate.word, candidate.seconds, range)
                }
            }
            guard let match = earliest else { break }
            found.append((match.word, match.seconds))
            searchStart = match.range.upperBound
        }
        return found
    }

    private static func unitRange(of word: String, in text: String) -> Range<String.Index>? {
        text.range(of: word)
    }

    /// The integer whose run ends immediately before `range` (whitespace
    /// apart): "set a timer for 25 minutes" → 25, "timer 5minutes" → 5.
    /// Anything else directly before the run (letters, punctuation) → nil.
    private static func amountImmediatelyBefore(_ range: Range<String.Index>,
                                                in text: String) -> Int? {
        guard range.lowerBound > text.startIndex else { return nil }
        var digits = ""
        var index = text.index(before: range.lowerBound)
        while true {
            let character = text[index]
            if character.isNumber {
                digits.insert(character, at: digits.startIndex)
            } else if !(character.isWhitespace && digits.isEmpty) {
                break   // a non-digit adjacent to the run, or a gap after it
            }
            if index == text.startIndex { break }
            index = text.index(before: index)
        }
        return digits.isEmpty ? nil : Int(digits)
    }

    // MARK: - Vetoes

    private static let nePeriodWords = ["बिहान", "दिउँसो", "साँझ", "बेलुका", "राति"]

    /// Question / cancellation / negation shapes. Question words are
    /// whole-token ("कति" vs "कतिबेर" is one token either way — both are
    /// questions); cancellation phrases ("बन्द गर", "turn off") are
    /// substring; ne bare "बन्द" is token-only so label text inside other
    /// words cannot trip it.
    private static let questionTokens = [
        "when", "why", "did", "does", "should", "how", "which",
        "कति", "कहिले", "किन", "कुन", "के", "कता", "कसरी", "कसले"
    ]
    private static let questionPhrases = ["what time", "is my", "are my"]
    private static let cancelTokens = [
        "cancel", "remove", "delete", "stop", "off",
        "हटाऊ", "हटाउनुहोस्", "मेट", "मेट्नुहोस्", "रद्द", "बन्द", "नलगाऊ", "नबजाऊ"
    ]
    private static let cancelPhrases = [
        "turn off", "switch off", "बन्द गर", "नगर्नुहोस्", "नगर", "पर्दैन"
    ]

    /// Family/other-person nouns — a wake command about ANY of them is
    /// not "ring me", it is about a third person's phone; leave it to the
    /// interpreter. Substring (Devanagari nouns are commonly suffixed:
    /// छोरालाई, बुबाको…).
    private static let otherPersonWords = [
        "him", "her", "his", "grandson", "granddaughter", "grandchild",
        "daughter", "son", "mom", "dad", "mother", "father", "parents",
        "baby", "kids", "children", "wife", "husband", "brother", "sister",
        "uncle", "aunt",
        "छोरा", "छोरी", "नाति", "नातिनी", "बुबा", "आमा", "दिदी", "दाइ",
        "भाइ", "बहिनी", "बाजे", "बज्यै", "सासू", "ससुरा", "ज्वाइँ", "बुहारी",
        "श्रीमान", "श्रीमती", "पत्नी", "पति"
    ]

    private static func vetoedAsQuestionOrCancellation(_ text: String) -> Bool {
        if questionTokens.contains(where: { containsToken($0, in: text) }) { return true }
        if cancelTokens.contains(where: { containsToken($0, in: text) }) { return true }
        if questionPhrases.contains(where: { text.contains($0) }) { return true }
        if cancelPhrases.contains(where: { text.contains($0) }) { return true }
        // Negations without a dedicated token ("do not", "don't").
        if text.contains("don't") || text.contains("dont") || text.contains("do not") {
            return true
        }
        return false
    }

    private static func mentionsAnotherPerson(_ text: String) -> Bool {
        otherPersonWords.contains { text.contains($0) }
    }

    // MARK: - Labels

    /// Label from the utterance with every grammar token removed: markers,
    /// fillers, clock/period/date words, numbers, unit words. "set an
    /// alarm for 6:30 am for yoga" → "yoga"; "बिहान ६ बजे अलार्म" → nil
    /// (nothing of substance remains). Heuristic by design — the label
    /// only decorates the Settings row; it is never spoken back verbatim.
    private static func labelForAlarm(from raw: String) -> String? {
        labelByStripping(raw,
                         markerTokens: alarmMarkers + timerMarkers + wakeMarkerTokensForLabel,
                         containsDrops: ["बजे", "मिनेट", "घण्टा", "सेकेण्ड"])
    }

    private static func labelForTimer(from raw: String) -> String? {
        labelByStripping(raw,
                         markerTokens: timerMarkers + alarmMarkers + wakeMarkerTokensForLabel,
                         containsDrops: ["बजे", "मिनेट", "घण्टा", "सेकेण्ड"])
    }

    /// For labels, "wake up"-type phrases reduce to their tokens
    /// ("wake","up"…); the remaining English pieces are handled by the
    /// shared filler list below.
    private static let wakeMarkerTokensForLabel = ["wake", "wakeup", "उठाउनुहोस्", "उठाइदिनुहोस्"]

    /// Word-level noise: fillers + periods + relative-day/date words.
    private static let labelStopTokens = [
        // English fillers
        "set", "start", "create", "put", "a", "an", "the", "for", "at",
        "in", "on", "to", "me", "my", "please", "up", "of", "and", "s",
        "o", "clock", "later", "after", "then",
        // English periods + relative days + weekdays
        "am", "pm", "morning", "afternoon", "evening", "night", "tonight",
        "noon", "midnight", "today", "tomorrow",
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        // English unit words (the Nepali ones ride `containsDrops`)
        "minutes", "minute", "hours", "hour", "seconds", "second",
        "mins", "secs", "min", "sec",
        // Nepali fillers + particles
        "मलाई", "को", "का", "की", "लागि", "पछि", "गर", "गर्नुहोस्", "गर्न",
        "गरिदिनुहोस्", "लगाऊ", "लगाउनुहोस्", "लगाइदिनुहोस्", "बजाऊ",
        "बजाउनुहोस्", "राख", "राख्नुहोस्", "सेट", "अब",
        // Nepali periods + relative days + weekdays
        "बिहान", "दिउँसो", "साँझ", "बेलुका", "राति", "साढे", "आज", "भोलि", "पर्सि",
        "आइतबार", "सोमबार", "मंगलबार", "बुधबार", "बिहीबार", "शुक्रबार", "शनिबार"
    ]

    private static func labelByStripping(_ raw: String,
                                         markerTokens: [String],
                                         containsDrops: [String]) -> String? {
        let lower = raw.lowercased()
        var kept: [String] = []
        for token in tokens(in: lower) {
            if markerTokens.contains(token) { continue }
            if labelStopTokens.contains(token) { continue }
            if containsDrops.contains(where: { token.contains($0) }) { continue }
            if token.contains(where: { $0.isNumber }) { continue }
            if token.allSatisfy({ !$0.isLetter && !$0.isNumber }) { continue }
            kept.append(token)
        }
        let label = kept.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        return String(label.prefix(80))
    }

    private static func tokens(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters))
    }

    /// Whole-token match — same semantics as `TopicPreAnswer.token` and
    /// `CommandRouter.containsToken` (split on whitespace + punctuation,
    /// exact equality).
    private static func containsToken(_ token: String, in text: String) -> Bool {
        tokens(in: text).contains { $0 == token }
    }

    // MARK: - Unit vocabulary

    /// Timer unit words, longest-first so a found unit consumes its own
    /// text before a shorter overlapping candidate ("hours" before "hour",
    /// "minutes" before "minute") can double-count.
    private static let timerUnitsByLengthDesc: [(word: String, seconds: Int)] = [
        ("minutes", 60), ("minute", 60), ("hours", 3600), ("hour", 3600),
        ("seconds", 1), ("second", 1), ("mins", 60), ("secs", 1), ("sec", 1),
        ("min", 60), ("घण्टा", 3600), ("घन्टा", 3600), ("मिनेट", 60),
        ("सेकेण्ड", 1), ("सेकेन्ड", 1)
    ]

    // MARK: - Duration text

    /// Western ASCII digits → Devanagari numerals ("15" → "१५").
    private static func devanagari(_ value: String) -> String {
        let digits = Array("०१२३४५६७८९")
        return String(value.map { character in
            guard let ascii = character.wholeNumberValue, (0...9).contains(ascii) else {
                return character
            }
            return digits[ascii]
        })
    }
}
