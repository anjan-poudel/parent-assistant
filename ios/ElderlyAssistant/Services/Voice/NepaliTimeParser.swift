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

        return DateComponents(hour: hour, minute: minute)
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
