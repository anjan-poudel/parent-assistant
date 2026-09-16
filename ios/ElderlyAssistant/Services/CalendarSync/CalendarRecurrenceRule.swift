import Foundation

// MARK: - RFC 5545 recurrence rendering (calendar & family sharing, 2026-09-16)

/// Renders the app's recurrence shapes into the RRULE strings Google
/// Calendar expects. Pure and total: every app shape maps to exactly
/// one rule, and there is no "unsupported" branch to get wrong — the
/// app only has two shapes (`EventRecurrence`).
///
/// Weekday numbering is the app's throughout: 1 = Sunday … 7 =
/// Saturday, matching `EKWeekday` and `CalendarSyncService`. RFC 5545
/// wants two-letter codes, so the mapping lives here and only here.
enum CalendarRecurrenceRule {

    /// Single letters per RFC 5545 §3.3.10, indexed by the app's
    /// weekday number (Sunday first).
    static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    /// `["RRULE:FREQ=DAILY"]` or `["RRULE:FREQ=WEEKLY;BYDAY=SU,TH"]` —
    /// the array shape Google's `recurrence` field takes, ready to drop
    /// into a request body.
    static func googleRecurrence(_ recurrence: EventRecurrence) -> [String] {
        [rrule(recurrence)]
    }

    /// The bare rule string, `RRULE:` prefix included.
    static func rrule(_ recurrence: EventRecurrence) -> String {
        switch recurrence {
        case .daily:
            return "RRULE:FREQ=DAILY"
        case .weekly(let weekdays):
            // Sorted and de-duplicated: an entry whose weekdays list
            // arrives out of order (or with a duplicate) must not
            // produce a different rule for the same schedule — the
            // round-trip through Google would otherwise look like a
            // change on every sync and re-write the twin forever.
            let days = Set(weekdays)
                .filter { $0 >= 1 && $0 <= 7 }
                .sorted()
                .map { weekdayCodes[$0 - 1] }
            // An empty (or entirely out-of-range) day list means "every
            // day" in the app's model — the same rule
            // `CalendarSyncService.recurrence(for:)` applies, kept here
            // so a hand-built draft cannot produce a rule that never
            // fires. FREQ=WEEKLY with no BYDAY means weekly-on-the-DTSTART
            // day in RFC 5545, which is NOT what an empty list means.
            guard !days.isEmpty else { return "RRULE:FREQ=DAILY" }
            return "RRULE:FREQ=WEEKLY;BYDAY=\(days.joined(separator: ","))"
        }
    }
}
