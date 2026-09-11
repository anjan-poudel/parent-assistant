import Foundation

/// Shared SPEECH-bound time formatting (spoken-time task, 2026-09-08).
///
/// Every voice line that embeds a wall-clock time formats it through this
/// helper so the TTS engine never receives a clock string it reads as
/// digits — the reported bug: the Nepali locale's `Date.FormatStyle
/// .shortened` yields "13:00"-style text ("१३:००"), and the TTS reads
/// "thirteen hundred" instead of "1 pm" / "दिउँसो १ बजे".
///
/// Output conventions (pinned by unit tests):
///  - English: 12-hour with a lowercase, space-separated am/pm
///    ("1 pm", "5 pm", "1:30 pm"). Minutes are omitted at the top of the
///    hour — ":00" is exactly the kind of token a TTS reads aloud.
///  - Nepali: day-period word + Devanagari digits + बजे, following the
///    house spoken convention already used by `TopicPreAnswer`
///    ("बिहान ८ बजे", "बेलुका ५ बजेर ३० मिनेट"). Period windows match
///    `TopicPreAnswer.periodKey` exactly (see below). Devanagari digits,
///    never ASCII, never a colon.
///
/// UI DISPLAY formatting normally stays out — screens keep
/// `Date.FormatStyle` / `DateFormatter`, which are locale-correct for
/// reading. ONE deliberate display exception (updates-alarms task,
/// 2026-09-10): the Updates leaf's alarm rows render this spoken form
/// so the screen shows exactly the words the assistant speaks when the
/// alarm rings — a senior reads what they hear. Everything else on
/// screen keeps `Date.FormatStyle` / `DateFormatter`.
enum SpokenTime {

    /// Formats `date`'s hour/minute in `locale`'s spoken convention,
    /// using `calendar` only to read the clock (defaults to `.current`,
    /// the same implicit zone `Date.FormatStyle` used at the old call
    /// sites). Hours outside 0–23 are not expected (all call sites pass
    /// Calendar-derived components).
    static func string(from date: Date, locale: Locale,
                       calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return string(hour: components.hour ?? 0,
                      minute: components.minute ?? 0,
                      locale: locale)
    }

    /// Formats an hour/minute pair (24-hour clock) in `locale`'s spoken
    /// convention. `CommandRouter`/`RoutinePlugin` resolve alarm and
    /// reminder times from spoken DateComponents, so the pair (not a
    /// Date) is the lowest common input shape.
    static func string(hour: Int, minute: Int, locale: Locale) -> String {
        if locale.language.languageCode?.identifier == "ne" {
            return nepali(hour: hour, minute: minute, locale: locale)
        }
        return english(hour: hour, minute: minute)
    }

    // MARK: - English — "1 pm", "1:30 pm"

    private static func english(hour: Int, minute: Int) -> String {
        let hour12 = twelveHour(hour)
        let meridian = hour < 12 ? "am" : "pm"
        guard minute != 0 else { return "\(hour12) \(meridian)" }
        return String(format: "%d:%02d %@", hour12, minute, meridian)
    }

    // MARK: - Nepali — "बिहान ८ बजे" / "बिहान ८ बजेर ३० मिनेट"

    private static func nepali(hour: Int, minute: Int, locale: Locale) -> String {
        let hour12 = twelveHour(hour)
        let period = L10n.str(periodKey(hour: hour), locale: locale)
        let hourDigits = BikramSambat.devanagariDigits(hour12)
        guard minute != 0 else {
            return "\(period) \(hourDigits) बजे"
        }
        return "\(period) \(hourDigits) बजेर \(BikramSambat.devanagariDigits(minute)) मिनेट"
    }

    /// 24-hour hour → the 12-hour dial reading ("13" → "1", "0" → "12",
    /// "12" → "12").
    private static func twelveHour(_ hour: Int) -> Int {
        let dial = hour % 12
        return dial == 0 ? 12 : dial
    }

    /// Day-period of `hour` (0–23) for SPOKEN times — the single source
    /// of truth for the speech period table. `TopicPreAnswer.timeReply`
    /// resolves the same catalog keys through this function so the "what
    /// time is it" answer and every scheduled-time line can never drift
    /// apart. Windows (and the topic.time.period.* catalog values) are
    /// TopicPreAnswer's, unchanged:
    ///   5..<12 → morning (बिहान), 12..<16 → afternoon (दिउँसो),
    ///   16..<20 → evening (बेलुका), else night (राति).
    static func periodKey(hour: Int) -> String {
        switch hour {
        case 5..<12: return "topic.time.period.morning"
        case 12..<16: return "topic.time.period.afternoon"
        case 16..<20: return "topic.time.period.evening"
        default: return "topic.time.period.night"   // 20:00–4:59
        }
    }
}
