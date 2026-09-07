import Foundation

// MARK: - Briefing source protocols (mirror the REAL read APIs)

/// Today's routine occurrences + entry lookup — mirrors
/// `RoutineScheduler.todaysOccurrences()` / `RoutineScheduler.entry(for:)`
/// (Services/Reminders/RoutineScheduler.swift).
protocol BriefingRoutineSource: AnyObject {
    func todaysOccurrences() -> [RoutineOccurrence]
    func entry(for id: UUID) -> RoutineEntry?
}

/// Pending medication reminders + the full entry list — mirrors
/// `MedicationScheduler.pendingReminders` / `.medicationEntries()`
/// (Services/MedicationScheduler/MedicationScheduler.swift).
protocol BriefingMedicationSource: AnyObject {
    var pendingReminders: [ScheduledReminder] { get }
    func medicationEntries() -> [MedicationEntry]
}

/// Today's events as ready-to-speak lines — mirrors
/// `ExternalCalendarService.todaysSpokenLines(locale:)`
/// (Services/ExternalCalendar/ExternalCalendarService.swift), which
/// already filters to still-relevant items (all-day events stay, past
/// timed events drop).
protocol BriefingCalendarSource: AnyObject {
    func todaysSpokenLines(locale: Locale) -> [String]
}

/// One localized line describing today's weather, or nil when this engine
/// stack has no live weather source. v1 wires nothing here — both current
/// stacks (on-device and Gemini) resolve weather through the deterministic
/// pre-answer table whose honest answer is "unavailable"
/// (`TopicPreAnswer.reply(for: .weather)`); a future live-weather stack
/// conforms in its own file. nil NEVER means "no weather today" — it means
/// "not available in this mode" and renders `briefing.weather.unavailable`.
protocol BriefingWeatherSource: AnyObject {
    func todaySummary(locale: Locale) -> String?
}

// MARK: - Real-service conformances (each member exists verbatim today)

extension RoutineScheduler: BriefingRoutineSource {}
extension MedicationScheduler: BriefingMedicationSource {}
extension ExternalCalendarService: BriefingCalendarSource {}

/// Voice-OS shell v1 — proactive morning briefing source plugin
/// (docs/superpowers/specs/2026-09-07-voice-os-shell-v1-design.md §4.4,
/// §5, §6; implementation plan §Pinned contracts).
///
/// Triggers:
///  (a) first app activation inside the configurable wake window
///      (default 05:00–10:00) — `shouldFireOnActivation` → `fire()`,
///  (b) spoken command ("read me my briefing") routed through the
///      pre-answer layer → `fire()` directly.
///
/// Composition is DETERMINISTIC and HONEST (constitution: no fabricated
/// data): greeting → date (Bikram Sambat for the Nepali locale, Gregorian
/// otherwise) → today's routines → today's medications → today's calendar
/// events → weather. Every source reports available / empty / unavailable
/// explicitly:
///  - available with items → `briefing.<source>` line with the items;
///  - empty (a queryable on-device source with nothing today) → an honest
///    `briefing.empty.<source>` line — or a single `briefing.nothing`
///    line when ALL schedule sources are empty;
///  - unavailable (weather on a stack with no live source) → the honest
///    `briefing.weather.unavailable` line. Never fabricated.
///
/// Localization: all text goes through `L10n` with the pinned
/// `briefing.*` catalog keys (Agent D adds the en+ne values to
/// Localizable.xcstrings). The active composition locale is the mutable
/// `locale` property — injected by `AppCoordinator` from `activeLocale`,
/// the same pattern as `RoutineScheduler.locale` / `MedicationScheduler.locale`.
///
/// Observability: PII-free events only (`component: "morning_briefing"`).
/// Announcement text (medication names, event titles, routine titles) is
/// user-facing speech and a card — it NEVER appears in log metadata,
/// event names, or transcript-adjacent fields.
///
/// Safety: medication announcements themselves stay scheduler/`.safety`
/// lane (design §4.2 hard rule). This source only *summarises the day's
/// schedule* in the `.briefing` lane and never re-alerts for missed doses.
final class MorningBriefing: SpeechSource {

    // MARK: - SpeechSource

    static let sourceIDValue = "morning_briefing"

    var sourceID: String { Self.sourceIDValue }

    var defaultPriority: AnnouncementPriority { .briefing }

    /// The briefing is a push source: its pinned `fire()` composes and
    /// enqueues directly. `nextAnnouncement()` is therefore always nil —
    /// returning the last composition here would double-speak it once the
    /// registry consumer also enqueues (spec §5: one enqueue per trigger).
    func nextAnnouncement() async -> Announcement? { nil }

    /// Both supported app languages compose a briefing (spec §7: both
    /// languages verified for every spoken template). Not geogated.
    func isApplicable(locale: Locale) -> Bool {
        guard let language = locale.language.languageCode?.identifier else { return false }
        return language == "en" || language == "ne"
    }

    // MARK: - Wake window (local setting for v1; caregiver-configurable later)

    /// Wake-window start hour (inclusive), 24-hour clock. Default 05:00.
    var wakeWindowStart: Int = 5
    /// Wake-window end hour (exclusive), 24-hour clock. Default 10:00.
    var wakeWindowEnd: Int = 10

    // MARK: - State

    /// Active composition locale. Injected by `AppCoordinator` from
    /// `activeLocale` (same pattern as RoutineScheduler/MedicationScheduler/
    /// ExternalCalendarService `.locale`).
    var locale: Locale = Locale(identifier: "en")

    private let queue: SpeakQueueProtocol
    private let observabilityBus: ObservabilityBus
    private let routineSource: BriefingRoutineSource
    private let medicationSource: BriefingMedicationSource
    private let calendarSource: BriefingCalendarSource
    private let weatherSource: BriefingWeatherSource?

    /// Injectable clock — tests pin "now" so day boundaries, the date
    /// line and the once-per-day rule are deterministic. Production
    /// passes `Date.init` (same convention as `RoutineScheduler`).
    private let now: () -> Date

    /// Calendar whose day boundaries mark "today" for the once-per-day
    /// rule and the schedule-day filter. Production runs on `.current`
    /// (identical to the calendar `AppCoordinator` passes to
    /// `shouldFireOnActivation`); injectable for tests.
    private let calendar: Calendar

    /// Start-of-day instants that already fired a briefing — at most one
    /// entry per calendar day, in-memory (a relaunch is a fresh process,
    /// so "once per wake window per calendar day" applies per process,
    /// matching the design's first-activation trigger).
    private var firedDayStarts: Set<Date> = []

    // MARK: - Init

    init(
        queue: SpeakQueueProtocol,
        observability: ObservabilityBus,
        routineSource: BriefingRoutineSource,
        medicationSource: BriefingMedicationSource,
        calendarSource: BriefingCalendarSource,
        weatherSource: BriefingWeatherSource? = nil,
        locale: Locale = Locale(identifier: "en"),
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.queue = queue
        self.observabilityBus = observability
        self.routineSource = routineSource
        self.medicationSource = medicationSource
        self.calendarSource = calendarSource
        self.weatherSource = weatherSource
        self.locale = locale
        self.now = now
        self.calendar = calendar
    }

    // MARK: - Trigger

    /// True only when `now` falls inside the wake window
    /// ([wakeWindowStart, wakeWindowEnd) hours of `calendar`) AND no
    /// briefing has fired for that calendar day yet. Pure predicate —
    /// `fire()` performs the composition and marks the day.
    func shouldFireOnActivation(now instant: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: instant)
        guard hour >= wakeWindowStart, hour < wakeWindowEnd else { return false }
        return !firedDayStarts.contains(calendar.startOfDay(for: instant))
    }

    /// Composes the briefing deterministically and enqueues ONE
    /// `.briefing` Announcement. Idempotent per calendar day: a second
    /// call the same day is a no-op that emits a PII-free
    /// `briefing_fire_skipped` event (the spoken-command trigger shares
    /// this once-per-day budget with the activation trigger).
    ///
    /// Not gated on the wake window itself — the spoken command must work
    /// any time of day (design §4.4 trigger b).
    func fire() async {
        let instant = now()
        let dayStart = calendar.startOfDay(for: instant)
        guard !firedDayStarts.contains(dayStart) else {
            emit("briefing_fire_skipped",
                 metadata: ["state": "already_fired_today"])
            return
        }

        let text = composeLines(locale: locale, now: instant).joined(separator: "\n")
        let announcement = Announcement(
            id: UUID(),
            text: text,
            priority: .briefing,
            sourceID: sourceID,
            card: AnnouncementCard(
                title: L10n.str("briefing.greeting", locale: locale),
                body: text,
                symbolName: "sunrise.fill"
            )
        )
        queue.enqueue(announcement)
        firedDayStarts.insert(dayStart)
        emit("briefing_fired", metadata: [:])
    }

    // MARK: - Composition

    /// The briefing's spoken lines, in pinned order:
    /// greeting → date → routines → medications → calendar events → weather.
    /// Deterministic for identical inputs: sources are queried in a fixed
    /// order and every list is sorted by schedule time before rendering.
    func composeLines(locale: Locale, now: Date) -> [String] {
        var lines: [String] = []
        lines.append(L10n.str("briefing.greeting", locale: locale))
        lines.append(L10n.fmt("briefing.date", locale: locale,
                              Self.dateArg(for: now, locale: locale, calendar: calendar)))

        let routines = routineLines(now: now, locale: locale)
        let medications = medicationLines(now: now, locale: locale)
        let events = calendarSource.todaysSpokenLines(locale: locale)

        if routines.isEmpty && medications.isEmpty && events.isEmpty {
            // Nothing scheduled at all — one honest line instead of three
            // redundant empties (a medication name, event title or
            // routine title never appears here; this text is static).
            lines.append(L10n.str("briefing.nothing", locale: locale))
        } else {
            lines.append(routines.isEmpty
                ? L10n.str("briefing.empty.routines", locale: locale)
                : L10n.fmt("briefing.routines", locale: locale, Self.joinItems(routines)))
            lines.append(medications.isEmpty
                ? L10n.str("briefing.empty.medications", locale: locale)
                : L10n.fmt("briefing.medications", locale: locale, Self.joinItems(medications)))
            lines.append(events.isEmpty
                ? L10n.str("briefing.empty.calendar", locale: locale)
                : L10n.fmt("briefing.calendar", locale: locale, Self.joinItems(events)))
        }

        if let summary = weatherSource?.todaySummary(locale: locale) {
            lines.append(L10n.fmt("briefing.weather", locale: locale, summary))
        } else {
            lines.append(L10n.str("briefing.weather.unavailable", locale: locale))
        }
        return lines
    }

    /// Today's pending routine occurrences as "Title — time" lines.
    /// Pending only: occurrences already delivered or expired are past
    /// items, not part of the morning look-ahead.
    private func routineLines(now: Date, locale: Locale) -> [String] {
        routineSource.todaysOccurrences()
            .filter { $0.state == .pending && calendar.isDate($0.scheduledAt, inSameDayAs: now) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .compactMap { occurrence -> String? in
                guard let entry = routineSource.entry(for: occurrence.entryId) else { return nil }
                return "\(entry.displayTitle(locale: locale)) — \(timeText(occurrence.scheduledAt, locale: locale))"
            }
    }

    /// Today's pending medication reminders as "Name — dose — time"
    /// lines. Pending only: the morning briefing is a look-ahead, and
    /// missed-dose escalation is the scheduler's safety lane, never this
    /// source (design §4.2 hard rule). Dose omitted when the entry has
    /// none — never invented.
    private func medicationLines(now: Date, locale: Locale) -> [String] {
        let entriesByID = Dictionary(
            uniqueKeysWithValues: medicationSource.medicationEntries().map { ($0.id, $0) }
        )
        return medicationSource.pendingReminders
            .filter { $0.state == .pending && calendar.isDate($0.scheduledAt, inSameDayAs: now) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .compactMap { reminder -> String? in
                guard let entry = entriesByID[reminder.medicationEntryId],
                      !entry.medicationName.isEmpty else { return nil }
                let parts = [entry.medicationName,
                             entry.doseDescription.trimmingCharacters(in: .whitespaces),
                             timeText(reminder.scheduledAt, locale: locale)]
                    .filter { !$0.isEmpty }
                return parts.joined(separator: " — ")
            }
    }

    private func timeText(_ date: Date, locale: Locale) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    // MARK: - Date line

    /// The argument for `briefing.date` ("Today is %@").
    /// Nepali: Bikram Sambat date + Nepali weekday from the existing
    /// calendar services ("आइतबार, भदौ २१, २०८३"); Gregorian fallback
    /// when the BS table does not cover the date (honest — never blank).
    /// English (and any non-Nepali locale): the full Gregorian date.
    static func dateArg(for date: Date, locale: Locale, calendar: Calendar = .current) -> String {
        if locale.language.languageCode?.identifier == "ne" {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            let weekdayIndex = gregorian.component(.weekday, from: date)  // 1 == Sunday
            let weekday = BikramSambat.weekdayNamesNepali[weekdayIndex - 1]
            if let bs = BikramSambat.bsDate(from: date, calendar: gregorian) {
                return "\(weekday), \(BikramSambat.nepaliString(bs))"
            }
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// List items joined for a section's %@ argument.
    private static func joinItems(_ items: [String]) -> String {
        items.joined(separator: ", ")
    }

    // MARK: - Observability (PII-free)

    private func emit(_ eventType: String, metadata: [String: String]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "morning_briefing",
            eventType: eventType,
            durationMs: nil,
            outcome: "success",
            errorCode: nil,
            metadata: metadata
        ))
    }
}
