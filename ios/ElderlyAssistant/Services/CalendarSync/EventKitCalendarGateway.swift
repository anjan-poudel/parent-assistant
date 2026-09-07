import Foundation
import EventKit

// MARK: - Calendar access truth (calendar-driven task, 2026-09-07)

/// What the OS currently allows for CALENDAR EVENTS, expressed in
/// mirroring terms. iOS 17 split event access into full/write-only;
/// earlier iOS has no write-only concept (`.authorized` IS full
/// access). Mirroring works with `.writeOnly` (add + edit own events),
/// but TWO-WAY mirroring — which must read events back to reconcile —
/// strictly needs `.fullAccess`; `CalendarSyncService` states that
/// honestly instead of half-running.
enum CalendarAccess: Equatable {
    case fullAccess
    case writeOnly
    case denied
    case restricted
    case notDetermined
}

/// A native calendar event as a plain value. The gateway maps
/// EKEvent ↔ record so no EventKit object ever crosses into the
/// service layer (same split as `EKCalendarScanner`/`ScannedEvent`).
struct CalendarEventRecord: Equatable {
    let eventIdentifier: String
    /// Owning calendar — the service uses it to recognise the app's
    /// own two-way "Sahayak" calendar and never touches others'.
    let calendarIdentifier: String?
    let title: String
    let notes: String?
    let startDate: Date
    let isAllDay: Bool
    /// `EKEvent.status == .canceled` — a canceled mirror event behaves
    /// as deleted for planning purposes.
    let isCanceled: Bool
    /// The event's recurrence in app terms; nil when it carries none
    /// or a shape the app cannot express (monthly, yearly…).
    let recurrence: EventRecurrence?
}

/// Recurrence shapes the app's mirrors can take — the RoutineEntry
/// model's daily/weekly pair, in EventKit terms. Weekday numbering is
/// the app's: 1 = Sunday … 7 = Saturday (matches `EKWeekday`).
enum EventRecurrence: Equatable {
    case daily
    case weekly(weekdays: [Int])
}

/// A value the service hands the gateway to create or update a native
/// event. The service composes title/notes/start (next matching
/// occurrence) and the gateway saves verbatim.
struct CalendarEventDraft: Equatable {
    let title: String
    let notes: String?
    let startDate: Date
    var durationMinutes: Int = 30
    let recurrence: EventRecurrence?

    init(title: String, notes: String?, startDate: Date,
         durationMinutes: Int = 30, recurrence: EventRecurrence?) {
        self.title = title
        self.notes = notes
        self.startDate = startDate
        self.durationMinutes = durationMinutes
        self.recurrence = recurrence
    }
}

// MARK: - Gateway seam

/// The EventKit surface `CalendarSyncService` mirrors through. The
/// production `EKCalendarGateway` is a thin, side-effect-only shell
/// (fetch + save + delete, struct-mapped at the boundary); every
/// decision — which slots to create/update/remove, which native edits
/// to apply back — lives in the service's pure planners and is
/// unit-tested against a fake gateway with zero OS permission
/// involvement (the `ExternalItemOpening` seam style).
protocol EventKitCalendarGateway: AnyObject {
    /// Current permission truth for calendar events (no prompting).
    var eventsAccess: CalendarAccess { get }

    /// Point-of-use full-access request. iOS 17 uses
    /// `requestFullAccessToEvents`; older iOS `requestAccess(to: .event)`
    /// (whose grant IS full access). Returns whether the store is
    /// usable for whatever the caller needs next.
    func requestFullAccess() async -> Bool

    /// Finds-or-creates the app's dedicated two-way calendar ("Sahayak",
    /// created on the default source) and returns its identifier.
    /// `knownIdentifier` (the link store's memory) short-circuits the
    /// title search; a calendar deleted natively under that id is
    /// re-found by title or re-created. Returns nil only when no
    /// writable source exists.
    func ensureSahayakCalendar(knownIdentifier: String?) -> String?

    /// Every event with an occurrence in [start, end], all calendars.
    func fetchEvents(from start: Date, to end: Date) -> [CalendarEventRecord]

    /// Creates the event — in the given calendar when an identifier is
    /// provided (the Sahayak calendar), else the store's default
    /// calendar (the legacy one-way mirror's home). Returns the new
    /// event's identifier, or nil on failure.
    func createEvent(_ draft: CalendarEventDraft,
                     in calendarIdentifier: String?) -> String?

    /// Overwrites an existing event in place (title, notes, start,
    /// duration, recurrence — calendar untouched). False when the
    /// event no longer exists or the save failed.
    func updateEvent(identifier: String, with draft: CalendarEventDraft) -> Bool

    /// Removes an event by identifier. False when it is gone or the
    /// removal failed (both fine — the caller's goal is reached).
    func removeEvent(identifier: String) -> Bool

    /// Removes every event whose notes contain `fragment` (all
    /// calendars) and returns the count removed — the legacy rebuild's
    /// wipe-by-tag. One commit for the whole batch.
    func removeEvents(matchingNotesFragment fragment: String) -> Int
}

// MARK: - Production gateway

/// The real EventKit-backed gateway. Deliberately tiny and side-effect-
/// only so `CalendarSyncService` logic is fully testable against a
/// fake — same split as `EKCalendarScanner`/`NativeCalendarScanning`.
final class EKCalendarGateway: EventKitCalendarGateway {

    static let sahayakCalendarTitle = "Sahayak"

    private let store = EKEventStore()

    var eventsAccess: CalendarAccess {
        let status = EKEventStore.authorizationStatus(for: .event)
        // Matching the iOS 17 cases as switch PATTERNS is legal on any
        // deployment target — the enum type carries them at compile
        // time; at runtime a pre-17 OS simply never yields them.
        switch status {
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        case .authorized:
            // Pre-iOS-17 grant — the old enum name for what is full
            // access (no write-only split existed); never returned on
            // iOS 17+.
            return .fullAccess
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func requestFullAccess() async -> Bool {
        do {
            if #available(iOS 17.0, *) {
                return try await store.requestFullAccessToEvents()
            } else {
                return try await store.requestAccess(to: .event)
            }
        } catch {
            return false
        }
    }

    func ensureSahayakCalendar(knownIdentifier: String?) -> String? {
        // Fast path: the id the link store remembers still exists.
        if let knownIdentifier,
           let existing = store.calendar(withIdentifier: knownIdentifier) {
            return existing.calendarIdentifier
        }
        // Re-find by title (the calendar was deleted + recreated
        // natively, or this is a fresh install with one already there
        // from a previous app version). Matching by exact title is
        // intentional — a family calendar of the same name would be
        // indistinguishable from ours anyway.
        if let titled = store.calendars(for: .event)
            .first(where: { $0.title == Self.sahayakCalendarTitle }) {
            return titled.calendarIdentifier
        }
        // Create once, on the default calendar's source (the least
        // surprising home — calendars need a source and the default
        // one always exists on a configured device).
        guard let source = store.defaultCalendarForNewEvents?.source else { return nil }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.sahayakCalendarTitle
        calendar.source = source
        do {
            try store.saveCalendar(calendar, commit: true)
            return calendar.calendarIdentifier
        } catch {
            return nil
        }
    }

    func fetchEvents(from start: Date, to end: Date) -> [CalendarEventRecord] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEventRecord(
                eventIdentifier: event.eventIdentifier,
                calendarIdentifier: event.calendar.calendarIdentifier,
                title: event.title ?? "",
                notes: event.notes,
                startDate: event.startDate,
                isAllDay: event.isAllDay,
                isCanceled: event.status == .canceled,
                recurrence: Self.recurrence(from: event.recurrenceRules?.first)
            )
        }
    }

    func createEvent(_ draft: CalendarEventDraft,
                     in calendarIdentifier: String?) -> String? {
        let event = EKEvent(eventStore: store)
        apply(draft, to: event)
        if let calendarIdentifier {
            guard let calendar = store.calendar(withIdentifier: calendarIdentifier) else {
                return nil
            }
            event.calendar = calendar
        } else {
            event.calendar = store.defaultCalendarForNewEvents
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        } catch {
            return nil
        }
    }

    func updateEvent(identifier: String, with draft: CalendarEventDraft) -> Bool {
        guard let event = store.event(withIdentifier: identifier) else { return false }
        apply(draft, to: event)
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return true
        } catch {
            return false
        }
    }

    func removeEvent(identifier: String) -> Bool {
        guard let event = store.event(withIdentifier: identifier) else { return false }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
            return true
        } catch {
            return false
        }
    }

    func removeEvents(matchingNotesFragment fragment: String) -> Int {
        // A year back and a year ahead — mirrored routines are
        // recurring daily, so they recur across the whole window.
        let start = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        let end = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let ours = store.events(matching: predicate).filter {
            $0.notes?.contains(fragment) == true
        }
        var removed = 0
        for event in ours {
            do {
                try store.remove(event, span: .thisEvent, commit: false)
                removed += 1
            } catch {
                // Best-effort removal — a single stuck event must not
                // abort the rebuild.
            }
        }
        if !ours.isEmpty { try? store.commit() }
        return removed
    }

    /// The first recurrence rule in app terms; nil for no rule or an
    /// unsupported frequency (monthly/yearly — planners leave those
    /// events alone: the family re-shaped them natively on purpose).
    /// A weekly rule with no day list is treated as daily (EventKit's
    /// convention when `daysOfTheWeek` is nil).
    static func recurrence(from rule: EKRecurrenceRule?) -> EventRecurrence? {
        guard let rule else { return nil }
        switch rule.frequency {
        case .daily:
            return .daily
        case .weekly:
            let weekdays = rule.daysOfTheWeek?
                .map { $0.dayOfTheWeek.rawValue }
                .sorted() ?? []
            guard !weekdays.isEmpty else { return .daily }
            return .weekly(weekdays: weekdays)
        default:
            return nil
        }
    }

    /// Copies a draft onto an EKEvent. Mirror events never carry
    /// alarms — the app's own scheduler already fires (a native alarm
    /// would double-notify), same rule as the legacy writer.
    private func apply(_ draft: CalendarEventDraft, to event: EKEvent) {
        event.title = draft.title
        event.notes = draft.notes
        event.startDate = draft.startDate
        event.endDate = draft.startDate
            .addingTimeInterval(TimeInterval(draft.durationMinutes) * 60)
        if let recurrence = draft.recurrence {
            switch recurrence {
            case .daily:
                event.recurrenceRules = [
                    EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
                ]
            case .weekly(let weekdays):
                // A weekly rule always lists at least one day here
                // (the planner only emits `.weekly` with days);
                // weekNumber must be 0 for weekly rules.
                let days = weekdays
                    .compactMap { EKWeekday(rawValue: $0) }
                    .map { EKRecurrenceDayOfWeek(dayOfTheWeek: $0, weekNumber: 0) }
                event.recurrenceRules = [
                    EKRecurrenceRule(recurrenceWith: .weekly, interval: 1,
                                     daysOfTheWeek: days, daysOfTheMonth: nil,
                                     monthsOfTheYear: nil, weeksOfTheYear: nil,
                                     daysOfTheYear: nil, setPositions: nil, end: nil)
                ]
            }
        } else {
            event.recurrenceRules = nil
        }
        event.alarms = nil
    }
}
