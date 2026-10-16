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
    /// `EKEvent.location` — the free-form address a rich event carries
    /// (rich-events task, 2026-09-17). Read back so the share layer can
    /// tell "the family changed the address in the Calendar app" from
    /// "the address is unchanged" (see `CalendarShareService`'s
    /// free-form reconcile) and so an address the family added natively
    /// still reaches the Google twin. nil for events with no address —
    /// the overwhelming majority.
    ///
    /// A `var` with a default rather than a `let`: it is an ADDITION to
    /// a record that several fakes and call sites construct positionally,
    /// and a defaulted trailing member keeps every one of them compiling
    /// unchanged.
    var location: String? = nil

    /// How long the event's block runs, in minutes (rich-events task,
    /// 2026-09-17) — `endDate - startDate`, clamped to at least one
    /// minute. The mirror planners ignore it (a mirror is always the
    /// house 30 minutes); it exists for the SHARE layer, where the
    /// duration the elder set in the Events form is part of the event
    /// the family reads, and dropping it would silently shorten every
    /// shared appointment to half an hour.
    ///
    /// Defaulted like `location` above, and for the same reason: the
    /// fakes that model a record without an end time still compile and
    /// still describe the house default.
    var durationMinutes: Int = 30
}

/// Recurrence shapes the app's mirrors can take — the RoutineEntry
/// model's daily/weekly pair, in EventKit terms. Weekday numbering is
/// the app's: 1 = Sunday … 7 = Saturday (matches `EKWeekday`).
///
/// `Codable` (calendar & family sharing, 2026-09-16): the persistent
/// share queue stores a draft's recurrence verbatim, so an operation
/// enqueued before a relaunch still knows it was a series when it is
/// flushed. Synthesized conformance — the associated value round-trips
/// as `{"weekly":{"weekdays":[…]}}` / `{"daily":{}}`.
enum EventRecurrence: Equatable, Codable {
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
    /// A plain address string written to `EKEvent.location` (rich-events
    /// task, 2026-09-17). Deliberately a STRING, not a coordinate: the
    /// native Calendar app renders it in the event's location row, and
    /// the Google twin inherits it verbatim. Forward-geocoding happens
    /// only at navigation time, never here — a stored coordinate would
    /// go stale the moment the family corrects the address.
    ///
    /// nil (and blank, normalized to nil by the callers that take it
    /// from a text field) means "no address".
    let location: String?

    init(title: String, notes: String?, startDate: Date,
         durationMinutes: Int = 30, recurrence: EventRecurrence?,
         location: String? = nil) {
        self.title = title
        self.notes = notes
        self.startDate = startDate
        self.durationMinutes = durationMinutes
        self.recurrence = recurrence
        self.location = location
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

    /// One event by identifier, or nil when it no longer exists.
    ///
    /// The free-form share reconcile's read (rich-events task,
    /// 2026-09-17): it walks the side-index's native event ids and needs
    /// each one's CURRENT title / start / location to decide whether the
    /// family's edit in the Calendar app has to reach the Google twin.
    /// A window fetch would do that too, but only for events inside the
    /// window — an event the family moved a year out would silently stop
    /// being reconciled, which is exactly the edit that matters most.
    ///
    /// NO default implementation on purpose. A protocol extension that
    /// answered nil would make every fake report "gone", and the caller
    /// reads "gone" as "tombstone the twin" — a default here would be a
    /// mass-delete waiting to happen. Conformers state their answer.
    func fetchEvent(identifier: String) -> CalendarEventRecord?

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

    /// Removes EVERY event whose notes carry `fragment` as their first
    /// line — all calendars, so the legacy one-way rebuild's default-
    /// calendar mirrors go as surely as the two-way Sahayak ones — and
    /// returns the count removed. One commit for the whole batch.
    ///
    /// The ownership test is `CalendarSyncService.notesCarryMirrorTag`,
    /// not a substring search: the tag is the notes' FIRST LINE in both
    /// mirror forms, and a family event that merely mentions the string
    /// in prose is not ours to delete.
    ///
    /// ONE REMOVAL PER EVENT, never per occurrence. The mirrors are
    /// recurring daily series and a date-predicate fetch expands a
    /// series into one entry per occurrence, all sharing the series'
    /// identifier; removing those one at a time with `span: .thisEvent`
    /// cancels occurrences and leaves the series itself standing, so the
    /// next rebuild stacks a second series on top of the first — the
    /// duplicate pile. Implementations collapse occurrences by
    /// identifier and remove the event itself, recurring series
    /// included.
    func removeEvents(matchingNotesFragment fragment: String) -> Int

    /// Whether an event with this identifier is still in the store — the
    /// stale-twin sweep's only question (`CalendarShareService`), which
    /// asks it before deleting a twin from the family's calendar.
    ///
    /// A gateway that cannot answer says ALIVE: see the extension below.
    func eventExists(identifier: String) -> Bool
}

extension EventKitCalendarGateway {
    /// Fail-SAFE default: `true` ("I cannot tell you it is gone").
    ///
    /// The only thing a "gone" verdict can trigger is a DELETE on the
    /// family's shared calendar — irreversible, and visible to everyone
    /// the elder shares with. A wrong "gone" therefore costs an event the
    /// family is relying on; a wrong "alive" costs one stale twin until
    /// the next sweep. So the answer that cannot do harm is the default,
    /// and every conformer that genuinely owns an event store (the
    /// EventKit one, and the fakes that model it) overrides it.
    ///
    /// The sweep additionally refuses to run without FULL calendar access
    /// — write-only access cannot read events at all, so every lookup
    /// would answer nil and the sweep would delete everything it knows
    /// about.
    func eventExists(identifier: String) -> Bool { true }
}

// MARK: - Production gateway

/// The real EventKit-backed gateway. Deliberately tiny and side-effect-
/// only so `CalendarSyncService` logic is fully testable against a
/// fake — same split as `EKCalendarScanner`/`NativeCalendarScanning`.
final class EKCalendarGateway: EventKitCalendarGateway {

    static let sahayakCalendarTitle = "Sahayak"

    private let store = EKEventStore()

    /// A real answer, unlike the protocol's fail-safe default: the store
    /// either holds the identifier or it does not. `event(withIdentifier:)`
    /// also returns the recurring-event MASTER for an occurrence's id,
    /// which is what the sweep wants — a series the elder deleted in the
    /// Calendar app takes its master with it.
    func eventExists(identifier: String) -> Bool {
        store.event(withIdentifier: identifier) != nil
    }

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
        return store.events(matching: predicate).map(Self.record(from:))
    }

    func fetchEvent(identifier: String) -> CalendarEventRecord? {
        guard let event = store.event(withIdentifier: identifier) else { return nil }
        return Self.record(from: event)
    }

    /// `EKEvent` → plain record, in ONE place so the window fetch and the
    /// by-identifier read can never describe the same event differently —
    /// the reconcile compares the two readings' fields against each
    /// other, and a field mapped in one and forgotten in the other would
    /// read as a family edit on every pass.
    private static func record(from event: EKEvent) -> CalendarEventRecord {
        CalendarEventRecord(
            eventIdentifier: event.eventIdentifier,
            calendarIdentifier: event.calendar.calendarIdentifier,
            title: event.title ?? "",
            notes: event.notes,
            startDate: event.startDate,
            isAllDay: event.isAllDay,
            isCanceled: event.status == .canceled,
            recurrence: recurrence(from: event.recurrenceRules?.first),
            location: Self.normalizedLocation(event.location),
            durationMinutes: Self.durationMinutes(from: event)
        )
    }

    /// An event's block length in whole minutes, floored at 1.
    ///
    /// A zero or negative span is not hypothetical: EventKit returns a
    /// zero-length block for an event whose end was never set, and a
    /// duration of 0 would make a shared twin an instant the family
    /// cannot see on their calendar at all. One minute is the smallest
    /// honest answer.
    static func durationMinutes(from event: EKEvent) -> Int {
        guard let end = event.endDate, let start = event.startDate else { return 30 }
        return max(1, Int(end.timeIntervalSince(start) / 60))
    }

    /// `EKEvent.location` normalized to "a non-blank address or nil".
    /// EventKit happily stores an empty string (and a whitespace-only
    /// one), and the share layer's "does this event have an address?"
    /// question has to answer the same way whether the field was never
    /// filled or was emptied by the family.
    static func normalizedLocation(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
            // `.futureEvents`, for the same reason the tag wipe uses it:
            // the app's mirrored routines (and a family's own weekly or
            // daily entry) are recurring SERIES, and `.thisEvent` on a
            // series cancels a single occurrence — the event the caller
            // asked to delete keeps appearing, and for a mirror the next
            // rebuild adds a second series on top of it. For a
            // non-recurring event the span is ignored, so a one-off is
            // still removed whole.
            try store.remove(event, span: .futureEvents, commit: true)
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
        // `calendars: nil` is every calendar on purpose: the one-way
        // mirror writes into the DEFAULT calendar and the two-way one
        // into Sahayak, and the wipe must not leave either behind.
        let ours = store.events(matching: predicate).filter {
            CalendarSyncService.notesCarryMirrorTag($0.notes, tag: fragment)
        }
        var removed = 0
        // Occurrences of one recurring event share the series'
        // identifier (EventKit documents this), so this collapses the
        // fetch's per-occurrence expansion back to one entry per EVENT —
        // and it also drops the stale occurrence objects of a series
        // already removed a moment ago, which is precisely the set that
        // used to throw and get swallowed.
        var seen = Set<String>()
        for event in ours {
            guard seen.insert(event.eventIdentifier).inserted else { continue }
            do {
                // `.futureEvents`, NEVER `.thisEvent`: this event is a
                // recurring daily series, and `.thisEvent` cancels one
                // occurrence and leaves the series (and every later
                // occurrence) in the family's calendar, where the next
                // rebuild adds another one on top of it. `.futureEvents`
                // removes the event itself — for a non-recurring event
                // the span is ignored, so both shapes are removed whole.
                try store.remove(event, span: .futureEvents, commit: false)
                removed += 1
            } catch {
                // Best-effort removal — a single stuck event must not
                // abort the rebuild.
            }
        }
        if removed > 0 { try? store.commit() }
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
        // Written verbatim as plain text: the native Calendar app shows
        // it in the event's location row, and the Google twin inherits
        // it. A draft with no address CLEARS the field, so a family
        // edit that removed an address is not silently put back by the
        // next mirror pass.
        event.location = draft.location
        event.startDate = draft.startDate
        event.endDate = draft.startDate
            .addingTimeInterval(TimeInterval(draft.durationMinutes) * 60)
        let rules = Self.recurrenceRules(for: draft.recurrence)
        // nil rather than [] for "does not repeat": EventKit's own
        // property is optional and every reader in this codebase (the
        // gateway's `recurrence(from:)` included) treats a present-but-
        // empty rule list as ambiguous. Clearing the field outright is
        // the one answer that cannot be misread.
        event.recurrenceRules = rules.isEmpty ? nil : rules
        event.alarms = nil
    }

    /// The EventKit rules a draft's recurrence means. A pure, static
    /// mapping (rich-events task, 2026-09-17) so the one place the app's
    /// none/daily/weekly vocabulary becomes an `EKRecurrenceRule` is
    /// unit-testable (`FreeFormEventFormTests`) without an event store —
    /// the free-form Events form's weekly choice and the mirror planners
    /// both land here, and they must produce the same rule for the same
    /// input.
    ///
    /// nil means "does not repeat" and answers an empty array, which
    /// CLEARS any rule an event already carried (a family edit that took
    /// a series back to a one-off), exactly as the previous inline switch
    /// did.
    static func recurrenceRules(for recurrence: EventRecurrence?) -> [EKRecurrenceRule] {
        guard let recurrence else { return [] }
        switch recurrence {
        case .daily:
            return [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]
        case .weekly(let weekdays):
            // A weekly rule always lists at least one day here (the
            // planner only emits `.weekly` with days); weekNumber must be
            // 0 for weekly rules.
            let days = weekdays
                .compactMap { EKWeekday(rawValue: $0) }
                .map { EKRecurrenceDayOfWeek(dayOfTheWeek: $0, weekNumber: 0) }
            return [EKRecurrenceRule(recurrenceWith: .weekly, interval: 1,
                                     daysOfTheWeek: days, daysOfTheMonth: nil,
                                     monthsOfTheYear: nil, weeksOfTheYear: nil,
                                     daysOfTheYear: nil, setPositions: nil, end: nil)]
        }
    }
}
