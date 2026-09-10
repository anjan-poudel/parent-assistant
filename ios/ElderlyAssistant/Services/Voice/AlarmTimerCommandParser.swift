import Foundation

/// [ALARMS-TIMERS] (2026-09-07) Deterministic, marker-gated parsers for
/// the voice alarm + timer commands, used by the `CommandRouter` stage
/// that runs BEFORE any model is consulted:
///
///  - "set an alarm for 6 am" / "wake me up at 7:30" / "alarm at 8 pm"
///  - "बिहान ६ बजे अलार्म लगाऊ" / "अलार्म ८ बजे" / "बिहान ६ बजे उठाउनुहोस्"
///  - "set a timer for 5 minutes" / "timer 10 minutes" / "1 hour timer"
///  - "टाइमर ५ मिनेट" / "५ मिनेटको टाइमर लगाऊ" / "१ घण्टाको टाइमर"
///  - "turn off the alarm" / "cancel my alarm" / "snooze for 15 minutes"
///  - "अलार्म बन्द गर" / "अलार्म स्नुज गर्नुहोस्" / "स्नुज गर"
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
///    "कति बजेको अलार्म?"), negations, third-person wake requests
///    ("wake my grandson", "छोरालाई उठाउनुहोस्" — that is not THIS
///    device's alarm), and countdown phrasings ("alarm in 5 minutes" — a
///    countdown is a TIMER: since 2026-09-10 the router's `parseTimer`
///    claims alarm-worded countdowns outright, and this veto remains the
///    safety net for countdowns the timer parse cannot own, e.g.
///    out-of-range durations or wake-worded countdowns). Anything
///    vetoed returns nil and the utterance falls through the router
///    ladder unchanged.
///  - Cancellations are NOT blanket-vetoed any more (2026-09-08): the
///    sanctioned shapes parse — `parseAlarmOff` ("turn off the alarm",
///    "cancel my alarm", "अलार्म बन्द गर"), `parseAlarmSnooze`
///    ("snooze", "snooze for 15 minutes", "स्नुज गर") and, since
///    2026-09-11 ([HOME-TIMER-CHIP]), `parseTimerCancel` ("cancel the
///    timer", "stop the timer", "टाइमर बन्द गर", "टाइमर रोक") — and the
///    router checks them right after `parseAlarm` (the set parses win
///    first; `parseAlarm`'s own cancel veto already returns nil for every
///    OFF shape, so the order is safe). Shapes OUTSIDE the sanctioned set
///    still return nil and fall through: time-qualified cancellations
///    ("cancel the 6 am alarm" — the off branch must not guess which
///    alarm), duration- or clock-qualified TIMER cancellations ("cancel
///    the 5 minute timer" — the timer-cancel branch must not guess which
///    one) and timer-worded snoozes ("snooze the timer" — timer business,
///    not an alarm re-wake).
///  - Deterministic: `parseAlarm` takes an injectable `now`/`calendar`;
///    `parseTimer` is pure. Time-of-day phrases resolve to the NEXT future
///    occurrence (a 6 am spoken at 10 am rings tomorrow 6 am).
///  - Honest about its limits: timer durations are bounded to 1…86400 s;
///    out-of-bounds or garbage returns nil (the interpreter sees the
///    utterance, as today). Compound durations ("1 hour 30 minutes",
///    "टाइमर १ घण्टा ३० मिनेट") parse into ONE duration; two SEPARATE
///    commands ("5 minutes, then one for 3 minutes") return nil — never
///    silently merged into one timer.
///  - NUMBER WORDS (2026-09-10): "पाँच मिनेट" / "five minutes" and their
///    spelling variants parse exactly like digit forms. The per-locale
///    `NumberWordNormalizer` (word tables in `Resources/NumberWords/
///    <code>.json` — language data, not code) rewrites amount-like
///    number words to digits UPSTREAM of this grammar, so units, amounts,
///    compounds and snooze minutes all work untouched; word-digit mixes
///    and compounds compose ("एक घण्टा तीस मिनेट" → "1 घण्टा 30 मिनेट"
///    → 5400 s). The rewrite is guarded — a word counts only when a
///    unit/clock word follows, so the copula "छ" ("अलार्म छ?") and
///    "एक" inside "एकछिन" never become numbers, and multi-word English
///    numbers ("forty five") are never partially rewritten.
///  - NATURAL-SPEECH SURFACE (2026-09-10): informal transliterations
///    (टाइमअर/टाइमेर for टाइमर; मिने for मिनेट — a real-device whisper
///    transcript rendered "मिनेट" as "मिनेको", and the unit's
///    substring match covers the को/का/मा suffixes; लगाउ/लागू/लागु/
///    लगाइदेऊ/लगाउँ for लगाऊ) are marker/unit/label vocabulary, and
///    trailing emphasis particles (त/है/नि/ल — "लगाऊ त") are dropped
///    as tokens or peeled off glued tokens when the remainder is a
///    word this parser knows (`strippedOfEmphasisParticles`) —
///    token-boundary-safe.
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

    /// Snooze delay when the utterance names none — "snooze" means
    /// "wake me again in 10 minutes".
    static let defaultSnoozeMinutes = 10

    /// Maximum snooze delay the parser accepts, in minutes (one hour) —
    /// mirrored by `AlarmTimersService.maxSnoozeMinutes`. Beyond an hour
    /// a "snooze" is really a timer or a schedule change.
    static let maxSnoozeMinutes = 60

    // MARK: - Public parsers

    /// Parses an alarm command into its next-occurrence `Date` (injected
    /// `now`/`calendar` make resolution deterministic under test) plus an
    /// optional spoken label ("…for yoga" → "yoga"; most utterances have
    /// none). Returns nil for anything that is not a clear, actionable
    /// alarm command.
    static func parseAlarm(_ text: String,
                           now: Date = Date(),
                           calendar: Calendar = .current,
                           locale: Locale = AppLanguage.persisted().locale)
        -> (time: Date, label: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = NepaliTimeParser.normalise(trimmed)
        guard !normalized.isEmpty else { return nil }
        // [NUMBER-WORDS] spoken number words → digits, upstream of the
        // grammar below (clock times included: "सात बजे" → "7 बजे").
        let cleaned = strippedOfEmphasisParticles(
            NumberWordNormalizer.normalise(normalized, locale: locale))

        let hasAlarmMarker = alarmMarkers.contains { containsToken($0, in: cleaned) }
        let hasWakeMarker = wakeMarkers.contains { cleaned.contains($0) }
        guard hasAlarmMarker || hasWakeMarker else { return nil }

        // Vetoes — questions, cancellations, negations …
        guard !vetoedAsQuestionOrCancellation(cleaned) else { return nil }
        // … third-party wake requests (wake-marker commands only; an
        // "alarm"-word command is always this device's own alarm) …
        if hasWakeMarker && mentionsAnotherPerson(cleaned) { return nil }
        // … and countdown phrasings — "in N minutes/hours" is a TIMER
        // (the router's timer parse claims alarm-worded countdowns
        // first); this veto is the safety net that keeps one from ever
        // silently becoming a time-of-day alarm.
        if countdownSeconds(in: cleaned) != nil { return nil }

        guard let parsed = NepaliTimeParser.parse(cleaned),
              let hour = adjustedHour(from: parsed, text: cleaned)
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

        // Labels strip the DIGIT-carrying text (see `labelForAlarm`) so a
        // spoken word form drops like its digit form would.
        return (time, labelForAlarm(from: cleaned))
    }

    /// Parses a timer command into whole seconds + optional label.
    /// Durations: a single amount+unit ("5 minutes", "१ घण्टा", "90 min")
    /// or a compound chain ("1 hour 30 minutes" → 5400 s; "टाइमर १ घण्टा
    /// ३० मिनेट"), bounded 1…`maxTimerSeconds`. Nil for anything else.
    /// The marker gate also claims alarm-worded COUNTDOWNS ("पांच मिनुटको
    /// अलार्म लगाऊ", "set an alarm in 5 minutes") as timers — doctrine
    /// extension 2026-09-10; see the gate below.
    static func parseTimer(_ text: String,
                           locale: Locale = AppLanguage.persisted().locale)
        -> (durationSeconds: Int, label: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = NepaliTimeParser.normalise(trimmed)
        guard !normalized.isEmpty else { return nil }
        // [NUMBER-WORDS] spoken number words → digits, upstream of the
        // duration grammar ("टाइमर पाँच मिनेट" → "टाइमर 5 मिनेट").
        let cleaned = strippedOfEmphasisParticles(
            NumberWordNormalizer.normalise(normalized, locale: locale))
        // Marker gate — a timer word, OR an alarm-worded countdown
        // (doctrine extension, 2026-09-10): an alarm marker plus an
        // explicit duration unit+amount ("पांच मिनुटको अलार्म लगाऊ",
        // "set an alarm in 5 minutes") is unambiguous "ring me in N"
        // intent and routes as a TIMER. A bare clock phrase carries no
        // duration unit, so "५ बजेको अलार्म" stays a clock alarm.
        let hasTimerMarker = timerMarkers.contains(where: { containsToken($0, in: cleaned) })
        let hasAlarmMarker = alarmMarkers.contains(where: { containsToken($0, in: cleaned) })
        guard hasTimerMarker || hasAlarmMarker else { return nil }
        // Snooze-worded durations are snooze business ("snooze the alarm
        // for 15 minutes") — the new alarm-worded path must never steal
        // them; timer-worded utterances keep their historical claim.
        if !hasTimerMarker, snoozeMarkers.contains(where: { cleaned.contains($0) }) {
            return nil
        }
        guard !vetoedAsQuestionOrCancellation(cleaned) else { return nil }
        guard let durationSeconds = countdownSeconds(in: cleaned) else { return nil }
        guard (1...maxTimerSeconds).contains(durationSeconds) else { return nil }
        return (durationSeconds, labelForTimer(from: cleaned))
    }

    /// True when the utterance is a sanctioned alarm-OFF command: an
    /// alarm marker PLUS a turn-off phrasing — "turn off the alarm",
    /// "turn the alarm off", "cancel my alarm", "switch off the alarm",
    /// "अलार्म बन्द गर", "अलार्म बन्द गर्नुहोस्". Questions, negations
    /// and time-qualified cancellations ("cancel the 6 am alarm") are NOT
    /// off commands (they fall through — `parseAlarm` still cancel-vetoes
    /// the time-carrying shapes). The router checks this right AFTER
    /// `parseAlarm` — safe because `parseAlarm`'s cancel veto already
    /// returns nil for every OFF shape, so a sanctioned cancellation is a
    /// command, never a vetoed fall-through.
    static func parseAlarmOff(_ text: String,
                              locale: Locale = AppLanguage.persisted().locale) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = NepaliTimeParser.normalise(trimmed)
        guard !normalized.isEmpty else { return false }
        // [NUMBER-WORDS] word times count as times here too: "सात बजेको
        // अलार्म बन्द गर" is a time-qualified cancellation and must not
        // blank-off any alarm.
        let cleaned = strippedOfEmphasisParticles(
            NumberWordNormalizer.normalise(normalized, locale: locale))
        guard alarmMarkers.contains(where: { containsToken($0, in: cleaned) }) else {
            return false
        }
        guard !vetoedAsQuestionOrNegation(cleaned) else { return false }
        // A time-qualified cancellation names a specific alarm — with
        // several alarms the off branch must not guess which one; it
        // falls through unchanged instead.
        if NepaliTimeParser.parse(cleaned) != nil { return false }
        return hasOffVerbPhrasing(cleaned)
    }

    /// Parses a snooze command into its delay in minutes. "snooze" /
    /// "snooze the alarm" / "स्नुज गर" (no duration spoken) → the fixed
    /// default (10). A spoken duration must be a clean single minute
    /// amount ("snooze for 15 minutes", "स्नुज १५ मिनेट") within
    /// 1…`maxSnoozeMinutes`. Everything else returns nil — hour/second
    /// durations, out-of-range amounts, multi-duration chains,
    /// timer-worded snoozes ("snooze the timer" — timer business, not
    /// an alarm re-wake), and clock-shaped snoozes ("snooze until
    /// 6:15": a re-wake at a named time is not a "ring again in N
    /// minutes" command and must never silently ring at the default).
    /// Questions and negations are vetoed. Nil for anything that is not
    /// snooze business.
    static func parseAlarmSnooze(_ text: String,
                                 locale: Locale = AppLanguage.persisted().locale) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = NepaliTimeParser.normalise(trimmed)
        guard !normalized.isEmpty else { return nil }
        // [NUMBER-WORDS] spoken minute amounts parse like digits
        // ("स्नुज पन्ध्र मिनेट" → "स्नुज 15 मिनेट" → 15).
        let cleaned = strippedOfEmphasisParticles(
            NumberWordNormalizer.normalise(normalized, locale: locale))
        guard snoozeMarkers.contains(where: { cleaned.contains($0) }) else { return nil }
        guard !vetoedAsQuestionOrNegation(cleaned) else { return nil }
        // A timer-worded snooze ("snooze the timer") is TIMER business —
        // there is no timer-snooze command yet; fall through rather than
        // snooze an alarm the user did not mean.
        if timerMarkers.contains(where: { containsToken($0, in: cleaned) }),
           !alarmMarkers.contains(where: { containsToken($0, in: cleaned) }) {
            return nil
        }
        let units = timerUnits(in: cleaned)
        if !units.isEmpty {
            guard units.count == 1,
                  units[0].seconds == 60,
                  let amount = amountImmediatelyBefore(units[0].range, in: cleaned),
                  (1...Self.maxSnoozeMinutes).contains(amount)
            else { return nil }
            return amount
        }
        // No duration words. A clock-shaped snooze ("snooze until 6:15")
        // is not a relative re-wake command — fall through rather than
        // ring at the default the user did not ask for.
        if NepaliTimeParser.parse(cleaned) != nil { return nil }
        // Plain "snooze" — the fixed default.
        return Self.defaultSnoozeMinutes
    }

    /// [HOME-TIMER-CHIP] (2026-09-11) True when the utterance is a
    /// sanctioned timer-CANCEL command: a timer marker PLUS a stop
    /// phrasing — "cancel the timer", "stop the timer", "टाइमर बन्द गर",
    /// "टाइमर रोक", "टाइमर रद्द गर", "टाइमर बन्द". The cancel branch
    /// always means the NEAREST running timer, so qualified shapes must
    /// NOT parse: a duration ("cancel the 5 minute timer") or a clock
    /// phrase ("stop the 6 o'clock timer") names a specific timer and
    /// falls through unchanged, exactly like `parseAlarmOff`'s
    /// time-qualified rule. Questions and negations are vetoed. English
    /// "cancel"/"stop" and the bare Nepali stop verbs are whole-token;
    /// the imperative/honorific Nepali phrases match as substrings.
    static func parseTimerCancel(_ text: String,
                                 locale: Locale = AppLanguage.persisted().locale) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = NepaliTimeParser.normalise(trimmed)
        guard !normalized.isEmpty else { return false }
        // [NUMBER-WORDS] word amounts count as amounts here too: "पाँच
        // मिनेटको टाइमर रद्द गर" is a duration-qualified cancellation
        // and must not blank-cancel the nearest timer.
        let cleaned = strippedOfEmphasisParticles(
            NumberWordNormalizer.normalise(normalized, locale: locale))
        guard timerMarkers.contains(where: { containsToken($0, in: cleaned) }) else {
            return false
        }
        guard !vetoedAsQuestionOrNegation(cleaned) else { return false }
        // A duration-qualified cancellation names a specific timer — with
        // several timers the cancel branch must not guess which one; it
        // falls through unchanged instead.
        if countdownSeconds(in: cleaned) != nil { return false }
        // Same rule for clock-shaped qualifications ("cancel the 6
        // o'clock timer").
        if NepaliTimeParser.parse(cleaned) != nil { return false }
        return hasTimerStopPhrasing(cleaned)
    }

    /// Sanctioned timer-STOP verb phrasings. English "cancel"/"stop" and
    /// the bare Nepali stop verbs (बन्द/रोक/रद्द — "टाइमर बन्द",
    /// "टाइमर रोक") are whole-token: a token like "बन्दोबस्त" can never
    /// trip them. The enumerated Nepali imperative/honorific गर/
    /// गर्नुहोस्/रोक्नुहोस् forms match as substrings (the
    /// grapheme-cluster hazard `parseAlarmOff` documents).
    private static func hasTimerStopPhrasing(_ text: String) -> Bool {
        if containsToken("cancel", in: text) { return true }
        if containsToken("stop", in: text) { return true }
        if containsToken("बन्द", in: text) { return true }
        if containsToken("रोक", in: text) { return true }
        if containsToken("रद्द", in: text) { return true }
        if nepaliTimerStopPhrases.contains(where: { text.contains($0) }) { return true }
        return false
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

    /// Whole-token timer markers. The टाइमअर/टाइमेर spellings are
    /// attested informal transliterations of the loanword — ASR renders
    /// them freely in natural speech ([NUMBER-WORDS] follow-up 2).
    private static let timerMarkers = [
        "timer", "timers", "टाइमर", "टाइमरहरू", "टाइमअर", "टाइमेर"
    ]

    /// Snooze markers — the word that makes an utterance snooze business
    /// at all (bare "snooze" is a sanctioned command, so the marker IS the
    /// word, no alarm noun required). Substring: STT inflections of the
    /// loanword ("snoozed", "snoozing") vary, and the word is long enough
    /// that substring matching cannot ride inside unrelated text the way
    /// "off" can.
    private static let snoozeMarkers = ["snooze", "स्नुज"]

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

    // MARK: - Countdown grammar (timers) — shared with the alarm veto and
    //                            the snooze minute spec

    /// The ONE duration the utterance names, in whole seconds: a chain of
    /// one or more amount + unit pairs ("5 minutes", "1 hour 30 minutes",
    /// "टाइमर १ घण्टा 30 मिनेट"). Every unit must carry its own amount
    /// immediately before it (whitespace apart). Two SEPARATE durations —
    /// "5 minutes, then one for 3 minutes" — return nil: the text between
    /// the pairs must not carry a second-command connector, so a
    /// two-command utterance is never silently merged into one timer. nil
    /// for garbage.
    private static func countdownSeconds(in normalized: String) -> Int? {
        let units = timerUnits(in: normalized)
        guard !units.isEmpty else { return nil }
        var total = 0
        for unit in units {
            guard let amount = amountImmediatelyBefore(unit.range, in: normalized) else {
                return nil
            }
            total += amount * unit.seconds
        }
        if units.count > 1 {
            let middle = String(normalized[units[0].range.upperBound
                ..< units[units.count - 1].range.lowerBound])
            if durationConnectors.contains(where: { middle.contains($0) }) { return nil }
        }
        return total
    }

    /// Words that mark a SECOND command between two duration pairs — a
    /// veto inside `countdownSeconds`, never part of one duration.
    private static let durationConnectors = ["then", "another", "अनि", "अर्को", "पछि"]

    /// Unit words in order of appearance, each with its own text range —
    /// candidates are tried longest-first so overlapping singular/plural
    /// forms ("hour" inside "hours") cannot double-count, and a match
    /// consumes its own text (a repeated unit word therefore yields one
    /// entry per occurrence, each with its own range).
    private static func timerUnits(in text: String)
        -> [(word: String, seconds: Int, range: Range<String.Index>)] {
        var found: [(word: String, seconds: Int, range: Range<String.Index>)] = []
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
            found.append((match.word, match.seconds, match.range))
            searchStart = match.range.upperBound
        }
        return found
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

    /// Question words — whole-token ("कति" vs "कतिबेर" is one token
    /// either way — both are questions). Applied by every parser.
    private static let questionTokens = [
        "when", "why", "did", "does", "should", "how", "which",
        "कति", "कहिले", "किन", "कुन", "के", "कता", "कसरी", "कसले"
    ]
    private static let questionPhrases = ["what time", "is my", "are my"]

    /// Cancellation shapes vetoing the SET parsers only (2026-09-08 — the
    /// OFF/SNOOZE parsers use their OWN sanctioned verbs below; these
    /// lists stay so a time-qualified cancellation like "cancel the 6 am
    /// alarm" can never SET an alarm). Cancellation phrases ("बन्द गर",
    /// "turn off") are substring; ne bare "बन्द" is token-only so label
    /// text inside other words cannot trip it.
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

    /// The set parsers' veto — question / negation / cancellation shapes.
    private static func vetoedAsQuestionOrCancellation(_ text: String) -> Bool {
        if vetoedAsQuestionOrNegation(text) { return true }
        if cancelTokens.contains(where: { containsToken($0, in: text) }) { return true }
        if cancelPhrases.contains(where: { text.contains($0) }) { return true }
        return false
    }

    /// Question / negation shapes only — the veto the OFF and SNOOZE
    /// parsers run: for them cancellation phrasing is the COMMAND itself,
    /// never a veto.
    private static func vetoedAsQuestionOrNegation(_ text: String) -> Bool {
        if questionTokens.contains(where: { containsToken($0, in: text) }) { return true }
        if questionPhrases.contains(where: { text.contains($0) }) { return true }
        // Negations without a dedicated token ("do not", "don't").
        if text.contains("don't") || text.contains("dont") || text.contains("do not") {
            return true
        }
        return false
    }

    /// Sanctioned OFF verb phrasings — checked only after an alarm marker
    /// and the question/negation/time vetoes passed (see
    /// `parseAlarmOff`). English "turn"/"switch"/"cancel" are whole-token:
    /// "turn the alarm off" (turn … off apart) and "turn off the alarm"
    /// both count, and "the alarm went off" (no verb token) never does.
    /// Nepali forms are enumerated per inflection because Swift matches
    /// substrings on EXTENDED GRAPHEME CLUSTERS: "गर्नुहोस्" clusters as
    /// ग + र्नु + हो + स्, so "बन्द गर्नुहोस्" does NOT contain "बन्द
    /// गर" (the same hazard the directions route documents for
    /// "खोज्नुहोस्"). Each imperative/honorific form is therefore a
    /// phrase of its own.
    private static let nepaliOffPhrases = [
        "बन्द गर", "बन्द गर्नुहोस्", "बन्द गर्नुस्", "बन्द गरिदिनुहोस्", "बन्द गरिदेउ",
        "रद्द गर", "रद्द गर्नुहोस्", "रद्द गर्नुस्"
    ]

    /// [HOME-TIMER-CHIP] (2026-09-11) Sanctioned timer-STOP phrases —
    /// the OFF phrases plus the timer-specific रोक (stop) forms. The
    /// BARE verbs (बन्द/रोक/रद्द — "टाइमर बन्द", "टाइमर रोक") are
    /// deliberately NOT here: `hasTimerStopPhrasing` matches them
    /// whole-token only, so they cannot ride inside other words the way
    /// the enumerated गर/गर्नुहोस् phrases safely can.
    private static let nepaliTimerStopPhrases = [
        "बन्द गर", "बन्द गर्नुहोस्", "बन्द गर्नुस्", "बन्द गरिदिनुहोस्", "बन्द गरिदेउ",
        "रद्द गर", "रद्द गर्नुहोस्", "रद्द गर्नुस्",
        "रोक्नुहोस्", "रोकिदिनुहोस्", "रोकिदेउ"
    ]

    private static func hasOffVerbPhrasing(_ text: String) -> Bool {
        if containsToken("cancel", in: text) { return true }
        if containsToken("turn", in: text) && containsToken("off", in: text) { return true }
        if containsToken("switch", in: text) && containsToken("off", in: text) { return true }
        if nepaliOffPhrases.contains(where: { text.contains($0) }) { return true }
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
                         containsDrops: ["बजे", "मिनेट", "मिनुट", "मिनिट", "मिने", "घण्टा", "सेकेण्ड"])
    }

    private static func labelForTimer(from raw: String) -> String? {
        labelByStripping(raw,
                         markerTokens: timerMarkers + alarmMarkers + wakeMarkerTokensForLabel,
                         containsDrops: ["बजे", "मिनेट", "मिनुट", "मिनिट", "मिने", "घण्टा", "सेकेण्ड"])
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
        // [NUMBER-WORDS] informal imperative spellings of "लगाऊ" — ASR
        // renders the command verb freely in natural speech (लगाउँ is
        // the nasalized form a real-device whisper transcript emitted).
        "लगाउ", "लागू", "लागु", "लगाइदेऊ", "लगाउँ",
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

    // MARK: - Natural-speech emphasis particles

    /// Trailing emphasis particles of natural Nepali speech ("लगाऊ त",
    /// "लगाऊ है", "लगाऊ नि", "लगाऊ ल"):
    ///  - a STANDALONE particle token (punctuation-clad or not) is
    ///    dropped — pure noise for the grammar, junk for labels;
    ///  - a particle GLUED to the end of a token ("टाइमरत", "लगाऊत") is
    ///    stripped only when the remainder is a word this parser knows
    ///    (a marker, a command verb, or any label-stop token) —
    ///    token-boundary-safe, so a legitimate word-final "त" ("सात" =
    ///    7, "रात" = night) can never be eaten.
    ///
    /// Whitespace-token only: interior punctuation is preserved verbatim
    /// ("6:30" stays "6:30" for the colon-minute grammar, "don't" stays
    /// "don't" for the negation veto).
    private static func strippedOfEmphasisParticles(_ text: String) -> String {
        let particles = ["है", "त", "नि", "ल"]
        var kept: [String] = []
        let rawTokens = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        for rawToken in rawTokens {
            let core = rawToken.trimmingCharacters(in: .punctuationCharacters)
            if particles.contains(core) { continue }
            var stripped = rawToken
            for particle in particles {
                guard core.count > particle.count, core.hasSuffix(particle) else { continue }
                let remainder = String(core.dropLast(particle.count))
                guard particleStripVocabulary.contains(remainder) else { continue }
                stripped = remainder
                break
            }
            kept.append(stripped)
        }
        return kept.joined(separator: " ")
    }

    /// The remainder vocabulary the glued-particle strip checks against —
    /// markers plus the label-stop words (which include the लगाऊ verb
    /// spellings). Only words the parser itself consumes may have a
    /// particle peeled off.
    private static let particleStripVocabulary: Set<String> = {
        var vocabulary = Set(labelStopTokens)
        vocabulary.formUnion(alarmMarkers)
        vocabulary.formUnion(timerMarkers)
        vocabulary.formUnion(wakeMarkers)
        vocabulary.formUnion(snoozeMarkers)
        return vocabulary
    }()

    // MARK: - Unit vocabulary

    /// Timer unit words, longest-first so a found unit consumes its own
    /// text before a shorter overlapping candidate ("hours" before "hour",
    /// "minutes" before "minute") can double-count.
    private static let timerUnitsByLengthDesc: [(word: String, seconds: Int)] = [
        ("minutes", 60), ("minute", 60), ("hours", 3600), ("hour", 3600),
        ("seconds", 1), ("second", 1), ("mins", 60), ("secs", 1), ("sec", 1),
        ("min", 60), ("घण्टा", 3600), ("घन्टा", 3600), ("मिनेट", 60),
        // [NUMBER-WORDS] transliteration spellings of "minute" — "मिनुट"
        // is the user-reported form ("पांच मिनुटको अलार्म लगाऊ"); without
        // it the countdown veto never fires and "५ मिनुटको अलार्म" would
        // silently parse as a 5 O'CLOCK alarm.
        ("मिनुट", 60), ("मिनिट", 60),
        // [NUMBER-WORDS] "मिने" — a real-device whisper transcript
        // rendered "मिनेट" as "मिनेको" ("पाँच मिनेको टाइमर लगाउँ"); the
        // substring match covers the को/का/मा suffixes. Listed after the
        // longer spellings so "मिनेट" wins first and never double-counts.
        ("मिने", 60),
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
