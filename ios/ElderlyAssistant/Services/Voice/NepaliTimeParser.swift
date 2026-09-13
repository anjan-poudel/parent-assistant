import Foundation

/// Resolves fuzzy Nepali time expressions into `DateComponents`
/// (spec §5.2 — `set_reminder` entity extraction).
///
/// Handles:
///  - "बिहान ८ बजे" (morning 8), "दिउँसो २ बजे" (afternoon 2),
///    "बेलुका ७ बजे" (evening 7), "राति ९ बजे" (night 9)
///  - "साढे ८" (half past eight → 8:30)
///  - "8:30" / "8॥30" clock strings
///  - period words alone: "बिहान" → 8:00, "दिउँसो" → 12:00,
///    "साँझ"/"बेलुका" → 17:00, "राति" → 20:00
///  - "अब" → the current time
///  - ASCII and Devanagari digits ("८" = "8"), 12- and 24-hour clock,
///    am/pm suffixes
///
/// Pure and deterministic — no locale/calendar state beyond the current
/// date for "अब". Returns nil when nothing time-like is found.
enum NepaliTimeParser {

    private static let devanagariDigits: [Character: Character] = [
        "०": "0", "१": "1", "२": "2", "३": "3", "४": "4",
        "५": "5", "६": "6", "७": "7", "८": "8", "९": "9"
    ]

    /// Period words with the hour range they imply.
    private static let periods: [(word: String, startHour: Int, fallbackHour: Int)] = [
        ("बिहान", 4, 8),     // morning
        ("दिउँसो", 12, 12),  // afternoon
        ("साँझ", 16, 17),    // early evening
        ("बेलुका", 16, 17),  // evening
        ("राति", 20, 20)     // night
    ]

    static func parse(_ raw: String) -> DateComponents? {
        let text = normalise(raw)
        guard !text.isEmpty else { return nil }

        // "अब" → now.
        if text.contains("अब") || text.contains("now") {
            let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
            return DateComponents(hour: now.hour, minute: now.minute)
        }

        // "N घण्टा पछि" / "in N hours" — an absolute timestamp, returned
        // with full date components (spec 2026-09-05 §6.3 extension).
        if let hours = relativeHours(in: text) {
            let target = Calendar.current.date(byAdding: .hour, value: hours, to: Date())
                ?? Date()
            return Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                   from: target)
        }

        // Relative days (आज/भोलि/पर्सि, today/tomorrow) and weekday names
        // (आइतबार…शनिबार, sunday…saturday) attach a DATE to the time of
        // day parsed below — checked here, applied at the end.
        let dayOffset = relativeDayOffset(inNormalised: text)
        let weekday = weekdayIndex(in: text)

        let period = periods.first { text.contains($0.word) }
        let isPM = text.contains("pm") || text.contains("बेलुका") || text.contains("साँझ")
            || text.contains("राति")

        // Extract the first number (hour).
        guard var hour = firstInteger(in: text) else {
            // No digits — period word alone → its representative time.
            if let period {
                return DateComponents(hour: period.fallbackHour, minute: 0)
            }
            return nil
        }

        // Minutes: "साढे N" (half past) or "N:MM" / "N॥MM".
        var minute = 0
        if text.contains("साढे") {
            minute = 30
        } else if let colonIndex = text.firstIndex(of: ":") {
            let afterColon = String(text[text.index(after: colonIndex)...])
            minute = firstInteger(in: afterColon) ?? 0
        }

        // 12-hour adjustment via pm or period words.
        if hour >= 1 && hour <= 12 {
            if isPM && hour < 12 {
                hour += 12
            }
            if let period, hour >= 1 && hour < period.startHour && hour <= 12 {
                hour += 12
            }
        }
        // Clamp to a valid day.
        hour = min(max(hour, 0), 23)
        minute = min(max(minute, 0), 59)

        // A relative day or weekday name upgrades the bare time-of-day
        // into a full date-time (spec §6.3); otherwise the historical
        // hour/minute-only shape is preserved for existing callers.
        if dayOffset != nil || weekday != nil {
            return attachDate(hour: hour, minute: minute,
                              dayOffset: dayOffset, weekday: weekday)
        }
        return DateComponents(hour: hour, minute: minute)
    }

    // MARK: - Spec §6.3 extensions (relative days, weekdays, hours-later)

    /// "N घण्टा पछि" / "N hours later" / "in N hours" → N, else nil.
    private static func relativeHours(in text: String) -> Int? {
        guard text.contains("पछि") || text.contains("hours") || text.contains("hour") else {
            return nil
        }
        guard text.contains("घण्टा") || text.contains("hour") else { return nil }
        return firstInteger(in: text)
    }

    /// आज → 0, भोलि → 1, पर्सि → 2 (+ English). Nil when no relative-day
    /// word is present — callers then leave the date components unset.
    ///
    /// [TOMORROW-WEATHER] (2026-09-13) Internal, and the single day table
    /// for the whole app: a question that carries a DAY but no clock time
    /// ("भोलि मौसम कस्तो हुन्छ") is no business of `parse` — which
    /// extracts time-of-day and returns nil for it — so before this seam
    /// existed the day was dropped before the weather query and a भोलि
    /// question was answered with today's reading. The weather path
    /// resolves the asked day HERE (raw transcript in, offset out) and
    /// threads it into the forecast request.
    static func relativeDayOffset(in raw: String) -> Int? {
        relativeDayOffset(inNormalised: normalise(raw))
    }

    /// The calendar DAY a relative-day phrase names, resolved against
    /// `now` (start of that day) — आज = today, भोलि = tomorrow, पर्सि =
    /// the day after tomorrow. Nil when the utterance names no relative
    /// day. The date-level view of `relativeDayOffset`, on an injected
    /// clock/calendar so it is deterministic under test.
    static func resolveRelativeDay(in raw: String,
                                   now: Date = Date(),
                                   calendar: Calendar = .current) -> Date? {
        guard let offset = relativeDayOffset(in: raw) else { return nil }
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: offset, to: start)
    }

    /// `relativeDayOffset(in:)` on text that has already been through
    /// `normalise` (the `parse` path) — avoids a second normalisation.
    private static func relativeDayOffset(inNormalised text: String) -> Int? {
        if text.contains("पर्सि") || text.contains("day after tomorrow") { return 2 }
        if text.contains("भोलि") || text.contains("tomorrow") { return 1 }
        if text.contains("आज") || text.contains("today") { return 0 }
        return nil
    }

    /// Nepali and English weekday names → 0=Sunday … 6=Saturday.
    private static let weekdays: [(word: String, index: Int)] = [
        ("आइतबार", 0), ("सोमबार", 1), ("मंगलबार", 2), ("बुधबार", 3),
        ("बिहीबार", 4), ("शुक्रबार", 5), ("शनिबार", 6),
        ("sunday", 0), ("monday", 1), ("tuesday", 2), ("wednesday", 3),
        ("thursday", 4), ("friday", 5), ("saturday", 6)
    ]

    private static func weekdayIndex(in text: String) -> Int? {
        weekdays.first { text.contains($0.word) }?.index
    }

    /// Attaches a real date to a parsed time-of-day: dayOffset days from
    /// today at that time, or the next occurrence of the weekday at that
    /// time (Calendar handles "later today vs next week" via nextDate).
    private static func attachDate(hour: Int, minute: Int,
                                   dayOffset: Int?, weekday: Int?) -> DateComponents? {
        let calendar = Calendar.current
        var target: Date?
        if let dayOffset {
            let startOfDay = calendar.startOfDay(for: Date())
            target = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay)
            target = target.flatMap { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: $0) }
        } else if let weekday {
            // Calendar.weekday is 1=Sunday…7=Saturday; our index is 0-based.
            target = calendar.nextDate(after: Date(),
                                       matching: DateComponents(hour: hour, minute: minute,
                                                                weekday: weekday + 1),
                                       matchingPolicy: .nextTime)
        }
        guard let target else { return DateComponents(hour: hour, minute: minute) }
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday],
                                       from: target)
    }

    // MARK: - Helpers

    /// Lowercases, trims, maps Devanagari digits to ASCII, and unifies the
    /// danda time separator ("८॥३०") with ":".
    static func normalise(_ raw: String) -> String {
        var text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        text = String(text.map { devanagariDigits[$0] ?? $0 })
        text = text.replacingOccurrences(of: "॥", with: ":")
        return text
    }

    /// First run of digits in the string as an Int (stops at the first
    /// non-digit after at least one digit). "8:30" → 8; "साढे ८" (normalised
    /// "साढे 8") → 8.
    private static func firstInteger(in text: String) -> Int? {
        var buffer = ""
        for character in text {
            if character.isNumber {
                buffer.append(character)
                if buffer.count >= 2 { break }
            } else if !buffer.isEmpty {
                break
            }
        }
        guard !buffer.isEmpty else { return nil }
        return Int(buffer)
    }
}
