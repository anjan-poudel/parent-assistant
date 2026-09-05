import Foundation

// MARK: - Routine Entry (v2 pivot §4.1 — generalised reminders, Phase 1)

/// The nine reminder categories from the v2 brief, unified on one model
/// (docs/superpowers/specs/2026-09-03-v2-gemini-pivot-design.md §4.1).
///
/// `.medication` exists so a routine entry can REPRESENT a medication
/// reminder uniformly — but actual medication entries always live in
/// `MedicationScheduler` (safety-critical; untouched by this system), and
/// no medication entry is ever seeded here.
enum RoutineCategory: String, Codable, CaseIterable {
    case medication
    case exercise
    case meal
    case walk
    case gym
    case bedtime
    case reading
    case callRelative
    case custom

    /// Catalog key for the localized display name (en + ne entries in
    /// Localizable.xcstrings).
    var displayNameKey: String { "routine.category.\(rawValue)" }

    /// SF Symbol for list rows (iOS 16 deployment target).
    var systemImage: String {
        switch self {
        case .medication: return "pills.fill"
        case .exercise: return "figure.mixed.cardio"
        case .meal: return "fork.knife"
        case .walk: return "figure.walk"
        case .gym: return "dumbbell.fill"
        case .bedtime: return "bed.double.fill"
        case .reading: return "book.fill"
        case .callRelative: return "phone.fill"
        case .custom: return "clock.fill"
        }
    }
}

/// How often a routine entry repeats. `daily` covers the brief's
/// "times-per-day" shapes — an entry with two `scheduleTimes` IS
/// exercise ×2/day; there is no separate times-per-day frequency.
enum RoutineFrequency: String, Codable {
    case daily
    case weekly
}

/// One recurring routine reminder (walk at 17:30, exercise at 07:00 and
/// 16:00, call a relative on Sundays). Not safety-critical: no
/// acknowledgement window, no escalation, no re-fire — those stay
/// exclusive to `MedicationScheduler`.
struct RoutineEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var category: RoutineCategory
    /// Voice-created/custom entries carry their title verbatim (as the
    /// user said it). Seeded category entries leave this nil so the
    /// display name localizes via the category's catalog key and follows
    /// the app language.
    var titleOverride: String?
    /// Fire times as hour/minute components; N entries = N times per day
    /// (exercise ×2/day = two components).
    var scheduleTimes: [DateComponents]
    var frequency: RoutineFrequency
    /// `Calendar` weekday numbers (1 = Sunday … 7 = Saturday); only
    /// consulted when `frequency == .weekly`. Empty under `.weekly` is
    /// treated as every day rather than never.
    var weekdays: [Int]
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        category: RoutineCategory,
        titleOverride: String? = nil,
        scheduleTimes: [DateComponents],
        frequency: RoutineFrequency = .daily,
        weekdays: [Int] = [],
        isEnabled: Bool
    ) {
        self.id = id
        self.category = category
        self.titleOverride = titleOverride
        self.scheduleTimes = scheduleTimes
        self.frequency = frequency
        self.weekdays = weekdays
        self.isEnabled = isEnabled
    }

    /// What the user sees/hears: the verbatim override when present,
    /// else the localized category name.
    func displayTitle(locale: Locale) -> String {
        if let titleOverride, !titleOverride.isEmpty { return titleOverride }
        return L10n.str(category.displayNameKey, locale: locale)
    }

    /// True when this entry fires on `date` (daily: always; weekly: the
    /// date's weekday is in `weekdays`, with empty treated as daily).
    func fires(on date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        switch frequency {
        case .daily:
            return true
        case .weekly:
            guard !weekdays.isEmpty else { return true }
            return weekdays.contains(calendar.component(.weekday, from: date))
        }
    }
}

// MARK: - Routine Occurrence (runtime, persisted before OS alarm)

/// A concrete firing of a `RoutineEntry` on a specific date/time —
/// the routine analogue of `ScheduledReminder`, minus the escalation
/// machinery (no ack window, no refire count, no missed-escalation).
/// Persisted BEFORE the platform alarm is armed, same ordering rule as
/// the medication path.
struct RoutineOccurrence: Codable, Identifiable, Equatable {
    let id: UUID
    let entryId: UUID
    let scheduledAt: Date
    var state: State

    enum State: String, Codable {
        case pending
        case delivered
        /// Fire time passed without delivery (e.g. generated for a time
        /// already past at scheduling time). Never re-fired: a walk
        /// reminder arriving hours late is noise, not safety — the
        /// opposite tradeoff from medication, where a late dose MUST
        /// still fire (FR-029).
        case expired
    }
}
