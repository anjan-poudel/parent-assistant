import Foundation

/// [NO-GIBBERISH] (2026-09-07) Deterministic, pre-written answers for the
/// most common Q&A topics — weather, time, date, greetings — matched by
/// `CommandRouter` BEFORE any model is consulted, so a question like
/// "भोलिको मौसम कस्तो छ?" ALWAYS gets a sensible, honest reply and can
/// never produce (or fall back from) unconstrained-model gibberish.
///
/// Design rules:
///  - The answers are HONEST: weather has no live-data source on-device
///    yet, so the weather answer says exactly that — it never fabricates
///    a forecast. Time/date answers read the real clock/calendar
///    (Nepali: Bikram Sambat date + weekday via `BikramSambat`,
///    Devanagari numerals; English: full Gregorian date).
///  - Matching is conservative and ordered (weather → time → date →
///    greeting), so a compound "नमस्ते, भोलिको मौसम कस्तो छ?" resolves to
///    the weather answer, and a greeting never shadows a real question.
///  - Phrase matching uses the substring convention and word matching the
///    whole-token convention of `CommandRouter.containsPhrase` /
///    `containsToken` (identical semantics; private there, mirrored
///    here — keep in sync).
///  - Safety-critical utterances NEVER reach this table: the router runs
///    its emergency/med-ack safety net and its confirmation flow BEFORE
///    consulting it, and the router additionally skips the table when a
///    sensitive-call phrase is present (a call-ish utterance with a
///    topic word inside must stay blocked/interpreter-routed). Inside the
///    table, medication/reminder markers veto the time/date/greeting
///    topics so "औषधि कति बजे खाने?" and "set a reminder at 8" reach the
///    interpreter instead of a small-talk answer.
enum TopicPreAnswer {

    enum Topic: String, CaseIterable {
        case weather
        case time
        case date
        case greeting
    }

    /// Match order — see design rules.
    private static let topicsInMatchOrder: [Topic] = [.weather, .time, .date, .greeting]

    /// Returns the pre-answer topic an utterance maps to, or nil when the
    /// utterance is not one of the deterministic topics (route it to the
    /// interpreter as before).
    static func match(transcript raw: String) -> Topic? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for topic in topicsInMatchOrder where topicMatches(topic, in: text) {
            return topic
        }
        return nil
    }

    /// The pre-written, localized reply for a matched topic. `now`/
    /// `timeZone` are injectable so the time/date answers are
    /// deterministic under test.
    static func reply(for topic: Topic,
                      locale: Locale,
                      now: Date = Date(),
                      timeZone: TimeZone = .current) -> String {
        switch topic {
        case .weather:
            return L10n.str("topic.weather.unavailable", locale: locale)
        case .greeting:
            return L10n.str("topic.greeting", locale: locale)
        case .time:
            return timeReply(now: now, timeZone: timeZone, locale: locale)
        case .date:
            return dateReply(now: now, timeZone: timeZone, locale: locale)
        }
    }

    // MARK: - Matching tables

    // Weather — Nepali topic words are distinctive enough for whole-token
    // matching ("मौसम" as a token excludes "मौसमी" seasonal-fruit talk);
    // multi-word weather phrases use substring matching. English single
    // words match as whole tokens ("raining", "forecast"…).
    private static let weatherTokens = [
        "मौसम", "weather", "forecast", "temperature",
        "rain", "rains", "raining", "rainy", "sunny", "cloudy"
    ]
    private static let weatherPhrases = [
        "पानी पर्छ", "पानी पर्ने", "पानी पर्", "पानी पर्यो", "पानी परेको",
        "घाम लाग्ने", "घाम लाग्यो", "घाम छ", "बादल लागेको", "हिउँ पर्ने",
        "will it rain", "does it rain", "is it raining", "weather like"
    ]

    // Time. "बजे"/"बज्यो" only match inside the phrases below — a bare
    // "बजे" is a reminder-phrase word ("बिहान ८ बजे रिमाइन्डर"), which is
    // exactly what the medication/reminder veto below protects.
    private static let timeTokens = ["time", "समय"]
    private static let timePhrases = [
        "कति बजे", "कति बज्यो", "बजेको छ", "बजिसकेको", "कति समय",
        "समय कति", "समय के", "अहिलेको समय",
        "what time", "the time", "time is it", "time now", "current time"
    ]

    // Date. Whole-word "date"/"दिन" are deliberately NOT matched — "दिन"
    // appears in countless compounds (जन्मदिन, दिनभरि…) and bare "date"
    // in schedule talk; only clearly date-asking phrases qualify.
    private static let datePhrases = [
        "कति गते", "कुन तारिख", "कुन दिन", "आज के दिन", "आज कुन दिन",
        "कुन साल", "कति साल", "के साल",
        "what date", "what's the date", "whats the date",
        "today's date", "todays date", "what day", "which day",
        "date today"
    ]

    private static let greetingTokens = [
        "hi", "hello", "namaste", "नमस्ते", "नमस्कार", "सुप्रभात"
    ]
    private static let greetingPhrases = [
        "good morning", "good afternoon", "good evening"
    ]

    /// Medication/reminder markers (substring) — any present utterance is
    /// a domain question about doses or scheduled times ("औषधि कति बजे
    /// खाने?", "औषधि कति गते सकिन्छ?", "remind me at 8", "when is my next
    /// dose?"), which must reach the interpreter, never the small-talk
    /// table. Mirrors the router's med vocabulary spelling variants.
    private static let medicationOrReminderMarkers = [
        "औषधि", "औषधी", "दवाई", "दबाइ", "दवाइ",
        "medicine", "medication", "pill", "dose",
        "reminder", "remind", "alarm",
        "रिमाइन्डर", "रिमाइन्ड", "अलार्म"
    ]

    private static func topicMatches(_ topic: Topic, in text: String) -> Bool {
        if topic != .weather && mentionsMedicationOrReminder(text) {
            return false
        }
        switch topic {
        case .weather:
            return weatherTokens.contains { token($0, in: text) }
                || weatherPhrases.contains { text.contains($0) }
        case .time:
            return timeTokens.contains { token($0, in: text) }
                || timePhrases.contains { text.contains($0) }
        case .date:
            return datePhrases.contains { text.contains($0) }
        case .greeting:
            return greetingTokens.contains { token($0, in: text) }
                || greetingPhrases.contains { text.contains($0) }
        }
    }

    private static func mentionsMedicationOrReminder(_ text: String) -> Bool {
        medicationOrReminderMarkers.contains { text.contains($0) }
    }

    /// Whole-token match — same semantics as
    /// `CommandRouter.containsToken` (split on whitespace + punctuation,
    /// exact equality), kept private here and mirrored so the table can
    /// never depend on router internals.
    private static func token(_ token: String, in text: String) -> Bool {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .contains { $0 == token }
    }

    // MARK: - Replies

    /// Day-period of `hour` (0–23) for the spoken time.
    private static func periodKey(hour: Int) -> String {
        switch hour {
        case 5..<12: return "topic.time.period.morning"
        case 12..<16: return "topic.time.period.afternoon"
        case 16..<20: return "topic.time.period.evening"
        default: return "topic.time.period.night"   // 20:00–4:59
        }
    }

    private static func timeReply(now: Date, timeZone: TimeZone, locale: Locale) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: now)
        let hour = c.hour ?? 0
        let minute = c.minute ?? 0
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let period = L10n.str(periodKey(hour: hour), locale: locale)
        let isNepali = locale.language.languageCode?.identifier == "ne"

        let hourText = isNepali ? devanagari(String(hour12)) : String(hour12)
        let minuteText = isNepali
            ? devanagari(String(format: "%02d", minute))
            : String(format: "%02d", minute)
        if minute == 0 {
            // ne: "अहिले बिहान ९ बजेको छ।"  en: "It's 9 in the morning."
            return L10n.fmt("topic.time.nowOnHour", locale: locale, hourText, period)
        }
        // ne: "अहिले बिहान ९ बजेर ३० मिनेट भयो।"
        // en: "It's 9:30 in the morning."
        return L10n.fmt("topic.time.nowWithMinutes", locale: locale,
                        hourText, minuteText, period)
    }

    private static func dateReply(now: Date, timeZone: TimeZone, locale: Locale) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        if locale.language.languageCode?.identifier == "ne" {
            // "आज बुधबार, असोज २२, २०८३ हो।" — BS date + Nepali weekday.
            let weekdayIndex = cal.component(.weekday, from: now)   // 1 == Sunday
            let weekday = BikramSambat.weekdayNamesNepali[weekdayIndex - 1]
            let bsText = BikramSambat.bsDate(from: now, calendar: cal)
                .map(BikramSambat.nepaliString) ?? ""
            return L10n.fmt("topic.date.now", locale: locale, weekday, bsText)
        }
        // English: full Gregorian date in the user's locale.
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return L10n.fmt("topic.date.now", locale: locale, formatter.string(from: now))
    }

    /// Western ASCII digits → Devanagari numerals ("09" → "०९").
    private static func devanagari(_ value: String) -> String {
        let digits = Array("०१२३४५६७८९")
        return String(value.map { digits[Int(String($0))!] })
    }
}
