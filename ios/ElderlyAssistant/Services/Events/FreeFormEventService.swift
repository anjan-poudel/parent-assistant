import Foundation
import UIKit

// MARK: - Free-form events (rich-events task, 2026-09-17; design §2)

/// How often a free-form event repeats — the three choices the Events
/// form offers (design §1.2). Monthly, yearly and custom rules are out
/// of scope, and the form states that by simply not offering them.
enum FreeFormEventRecurrence: String, CaseIterable, Identifiable {
    case none
    case daily
    case weekly

    var id: String { rawValue }

    /// The picker label's catalog key — one per case, so a new choice
    /// cannot ship untranslated.
    var titleKey: String { "events.recurrence.\(rawValue)" }

    /// The gateway draft's recurrence for this choice.
    ///
    /// Weekly means "the same weekday as the event's start date": the
    /// form has ONE date field and no weekday picker (deliberately —
    /// seven weekday toggles is a caregiver screen, not an elder one),
    /// so the day the event falls on IS the day it repeats on.
    func eventRecurrence(startDate: Date, calendar: Calendar = .current) -> EventRecurrence? {
        switch self {
        case .none: return nil
        case .daily: return .daily
        case .weekly:
            return .weekly(weekdays: [calendar.component(.weekday, from: startDate)])
        }
    }

    /// The inverse read, for the edit form: what the picker should show
    /// for an event that already exists. Any weekly rule — one day or
    /// five — reads as `.weekly`; WHICH days it repeats on is preserved
    /// separately (see `FreeFormEventForm.resolvedRecurrence`), so
    /// opening the form on a family-edited series and saving cannot
    /// quietly drop days this form never showed.
    static func from(_ recurrence: EventRecurrence?) -> FreeFormEventRecurrence {
        switch recurrence {
        case nil: return .none
        case .daily: return .daily
        case .weekly: return .weekly
        }
    }
}

/// One free-form event as the UI reads it: the native event's own fields
/// plus the app-side photo the side index holds.
///
/// `id` IS the native `eventIdentifier` — the event is native by
/// construction (design §1 decision 4), so there is no second identity to
/// keep in step, and a family edit in the Calendar app is an edit to the
/// one event the app reads back.
struct FreeFormEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let durationMinutes: Int
    /// The event's rule in app terms, nil when it does not repeat.
    let recurrence: EventRecurrence?
    let notes: String?
    /// The address the elder typed, read back from `EKEvent.location` —
    /// so a family correction made in the Calendar app is what the
    /// Navigate button geocodes.
    let address: String?
    /// The app-side photo's file name, nil when the event has none.
    /// Native calendars cannot hold event photos (design §7), so this
    /// only ever shows inside this app.
    let photoFilename: String?

    /// A series has no single "when" for the list to print, so the UI
    /// says "repeats" instead of a date.
    var isRecurring: Bool { recurrence != nil }

    var recurrenceChoice: FreeFormEventRecurrence {
        FreeFormEventRecurrence.from(recurrence)
    }

    /// Whether the Navigate affordance belongs on this event at all.
    var hasAddress: Bool {
        guard let address else { return false }
        return !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The Events form's draft, and the ONE place its value rules live —
/// validation, the default duration, address/notes normalization and the
/// recurrence translation are all pure and unit-tested
/// (`FreeFormEventFormTests`), so the screen only binds fields.
///
/// A struct with defaults rather than an init per call site: the add form
/// starts from `FreeFormEventForm(startDate:)`, the edit form from
/// `init(event:)`, and both then differ only by what the elder types.
struct FreeFormEventForm: Equatable {

    /// House default (design §2: "duration (default 30 min — the house
    /// default)"). Also what `EKCalendarGateway` answers for an event
    /// with no measurable end.
    static let defaultDurationMinutes = 30

    /// The durations the form offers, in minutes. Four choices, each a
    /// single tap on a ≥44pt capsule — a duration wheel would be a
    /// precision task this app does not hand an elder.
    static let durationChoices = [15, 30, 60, 120]

    var title: String = ""
    var startDate: Date
    var durationMinutes: Int = defaultDurationMinutes
    var recurrence: FreeFormEventRecurrence = .none
    var notes: String = ""
    var address: String = ""

    /// The photo the elder picked in THIS sitting. nil means "nothing new
    /// was picked" — it does not mean "no photo", because an edit form
    /// opened on an event that already has one leaves this nil.
    var pickedPhoto: UIImage?
    /// The elder tapped Remove on an existing photo. Distinct from
    /// `pickedPhoto == nil` for exactly the reason above.
    var removedPhoto = false

    /// The rule the event carried when the form opened. Kept so a weekly
    /// event's day list survives an edit (see `resolvedRecurrence`).
    var originalRecurrence: EventRecurrence?

    init(startDate: Date = FreeFormEventForm.defaultStartDate()) {
        self.startDate = startDate
    }

    /// An hour from now, truncated to the minute — the same "no time
    /// chosen yet" default the appointment form starts from.
    ///
    /// Truncation rebuilds the date from its components rather than
    /// calling `calendar.date(bySetting: .second, value: 0, of:)`: that
    /// API searches FORWARD for the next matching instant, so 10:30:47
    /// would round UP to 10:31 — a default a minute later than it says
    /// it is, and one that would land on the next hour's :00 whenever
    /// the seconds happened to be zero already.
    static func defaultStartDate(now: Date = Date(),
                                 calendar: Calendar = .current) -> Date {
        let proposed = calendar.date(byAdding: .hour, value: 1, to: now) ?? now
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute],
                                            from: proposed)
        return calendar.date(from: parts) ?? proposed
    }

    /// The form loaded from an existing event — the edit path.
    init(event: FreeFormEvent) {
        self.title = event.title
        self.startDate = event.startDate
        self.durationMinutes = event.durationMinutes
        self.recurrence = event.recurrenceChoice
        self.notes = event.notes ?? ""
        self.address = event.address ?? ""
        self.originalRecurrence = event.recurrence
    }

    // MARK: - Value rules (pure)

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The only required field (design §2). Everything else has an honest
    /// default, so a title alone is a saveable event.
    var isValid: Bool { !trimmedTitle.isEmpty }

    /// Blank notes are nil, not "" — the same reading the gateway gives
    /// an emptied field, so the two can never disagree.
    var normalizedNotes: String? {
        Self.normalized(notes)
    }

    /// Blank address is nil, and a whitespace-only one is nil too: the
    /// native Calendar row and the Google twin both have to answer "does
    /// this event have an address?" the same way.
    var normalizedAddress: String? {
        Self.normalized(address)
    }

    /// At least one minute — a zero-length block is not a thing anyone
    /// can be reminded of, and EventKit would store it as an instant.
    var normalizedDurationMinutes: Int { max(1, durationMinutes) }

    /// The rule this form's state implies.
    ///
    /// `weekly` keeps the day list the event already had, when it had
    /// one: this form has no weekday picker, so the days are not the
    /// form's to change — they belong to whoever set them (possibly in
    /// the Calendar app). Only a weekly rule built FRESH here — from
    /// none, from daily, or from a date the elder just picked on a
    /// non-weekly event — takes the start date's weekday.
    var resolvedRecurrence: EventRecurrence? {
        switch recurrence {
        case .none:
            return nil
        case .daily:
            return .daily
        case .weekly:
            if case .weekly(let weekdays) = originalRecurrence, !weekdays.isEmpty {
                return .weekly(weekdays: weekdays)
            }
            return .weekly(weekdays: [Calendar.current.component(.weekday, from: startDate)])
        }
    }

    /// The value the gateway writes.
    func draft() -> CalendarEventDraft {
        CalendarEventDraft(title: trimmedTitle,
                           notes: normalizedNotes,
                           startDate: startDate,
                           durationMinutes: normalizedDurationMinutes,
                           recurrence: resolvedRecurrence,
                           location: normalizedAddress)
    }

    /// "15 min" / "1 hour" — one formatter for the capsule labels and the
    /// list captions, so the same duration never reads two ways.
    static func durationLabel(minutes: Int, locale: Locale) -> String {
        if minutes >= 60, minutes % 60 == 0 {
            return L10n.fmt("events.duration.hours", locale: locale, minutes / 60)
        }
        return L10n.fmt("events.duration.minutes", locale: locale, minutes)
    }

    private static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Service

/// Free-form events are NATIVE EventKit events in the default calendar
/// (design §1 decision 4): the app owns no event store of its own, and
/// everything EventKit can hold — title, time, duration, recurrence,
/// notes, address — lives there, so the native Calendar app, the app's
/// import, the caregiver alert and the Google bridge all see the same
/// event, and a family edit is simply an edit.
///
/// The ONE thing EventKit cannot hold is a photo, so that alone lives in
/// an encrypted side index (`EventExtrasStore`) plus a file store
/// (`ContactPhotoStore` rooted at EventPhotos — the photo-aids store
/// pattern). The design says so plainly: photos show in this app only,
/// never in the native Calendar app or Google Calendar, because those
/// platforms have no event-photo API.
///
/// Membership in the side index is what makes an event "one of ours" for
/// the list, and the reconcile that prunes it — an event the elder (or
/// the family) deleted natively is dropped from the index and its photo
/// file with it, so the index can never grow a tail of dead ids.
final class FreeFormEventService {

    private let gateway: EventKitCalendarGateway
    private let extras: EventExtrasStore
    private let photoStore: ContactPhotoStore
    private let observability: ObservabilityBus?

    /// `gateway` and `photoStore` default to the production ones — the
    /// composition root constructs this with only the encrypted store it
    /// owns, and tests pass fakes. The photo store gets a directory of
    /// its own (`EventPhotos`) so an event photo can never be read — or
    /// deleted — as a contact's.
    init(gateway: EventKitCalendarGateway = EKCalendarGateway(),
         extras: EventExtrasStore,
         photoStore: ContactPhotoStore? = nil,
         observability: ObservabilityBus? = nil) {
        self.gateway = gateway
        self.extras = extras
        self.photoStore = photoStore ?? ContactPhotoStore(directoryName: "EventPhotos")
        self.observability = observability
    }

    // MARK: - Reading

    /// The app's own events that are still ahead, soonest first.
    ///
    /// Ordering is by start date ascending — the question this list
    /// answers is "what is coming up?", and the next thing to happen
    /// belongs at the top. (Design §2's "newest first" is about the list
    /// leading with what is imminent; EventKit exposes no creation date
    /// to sort by, and an upcoming list sorted by one would put a
    /// long-scheduled appointment above tomorrow's doctor visit.)
    ///
    /// "Ahead" is honest about recurrence: a series recurs forever (the
    /// form creates none-ending rules), so it stays listed even though
    /// the master event's own start date is in the past. A one-off whose
    /// start has passed drops out. This is also where the index heals —
    /// an id that no longer resolves is removed, and its photo file with
    /// it.
    func upcoming(now: Date = Date()) -> [FreeFormEvent] {
        var events: [FreeFormEvent] = []
        for eventId in extras.eventIds {
            guard let record = gateway.fetchEvent(identifier: eventId),
                  !record.isCanceled else {
                // Gone (or canceled, which reads as deleted everywhere
                // else in this codebase). Drop the index row and the
                // photo bytes together — the index/bytes split means the
                // caller of `remove` owns the file.
                if let dropped = extras.remove(eventId: eventId) {
                    photoStore.delete(named: dropped.photoFilename)
                    emit("event_vanished")
                }
                continue
            }
            let event = Self.event(from: record,
                                   photoFilename: extras.extras(forEventId: eventId)?
                                       .photoFilename)
            guard event.isRecurring || event.startDate >= now else { continue }
            events.append(event)
        }
        return events.sorted { $0.startDate < $1.startDate }
    }

    /// One event by native identifier, or nil when it is gone.
    func event(withId eventId: String) -> FreeFormEvent? {
        guard let record = gateway.fetchEvent(identifier: eventId),
              !record.isCanceled else { return nil }
        return Self.event(from: record,
                          photoFilename: extras.extras(forEventId: eventId)?.photoFilename)
    }

    /// The event's photo, or nil when it has none (or the file is
    /// unreadable — a missing photo is never an error, same rule as the
    /// contact photo store).
    func photo(for event: FreeFormEvent) -> UIImage? {
        photoStore.load(named: event.photoFilename)
    }

    /// The photo for an id, without loading the event first.
    func photo(forEventId eventId: String) -> UIImage? {
        photoStore.load(named: extras.extras(forEventId: eventId)?.photoFilename)
    }

    /// The store the list and detail screens read photos through — the
    /// SAME instance this service writes them with, so a photo saved a
    /// moment ago is readable now.
    var photos: ContactPhotoStore { photoStore }

    // MARK: - Writing

    /// Creates (eventId nil) or updates the event, and answers its native
    /// identifier — nil when nothing was saved, in which case the form
    /// stays on screen with its draft intact.
    ///
    /// Create writes to the DEFAULT calendar (the gateway's nil
    /// calendar), which is where an elder's own appointments belong and
    /// what the design asks for. `alarms` stay nil: the app's own
    /// scheduler is the fire signal (house rule), and a native alarm
    /// would double-notify.
    ///
    /// Photo handling is transactional in the only direction that cannot
    /// lose data: the new image is written BEFORE it is indexed, and the
    /// image it replaces is deleted only after the index points at the
    /// new one. A failed write therefore leaves the previous photo in
    /// place rather than destroying it for a file that never landed.
    @discardableResult
    func save(_ form: FreeFormEventForm, editing eventId: String? = nil) -> String? {
        guard form.isValid else { return nil }
        let draft = form.draft()

        let resolvedId: String
        if let eventId {
            guard gateway.updateEvent(identifier: eventId, with: draft) else {
                emit("event_save", outcome: "update_failed")
                return nil
            }
            resolvedId = eventId
        } else {
            guard let created = gateway.createEvent(draft, in: nil) else {
                emit("event_save", outcome: "create_failed")
                return nil
            }
            resolvedId = created
            // Indexed only once the event truly exists: an id that never
            // landed would be a row the list can never resolve.
            _ = extras.track(eventId: created)
        }

        if let image = form.pickedPhoto {
            _ = setPhoto(image, forEventId: resolvedId)
        } else if form.removedPhoto {
            _ = setPhoto(nil, forEventId: resolvedId)
        }
        emit("event_save", outcome: eventId == nil ? "created" : "updated")
        return resolvedId
    }

    /// Writes `image` as the event's photo (nil clears it — the file is
    /// deleted, the index row's field cleared). False when the image
    /// could not be written; the previous photo then stays exactly as it
    /// was.
    @discardableResult
    func setPhoto(_ image: UIImage?, forEventId eventId: String) -> Bool {
        let previous = extras.extras(forEventId: eventId)?.photoFilename
        guard let image else {
            guard extras.setPhotoFilename(nil, forEventId: eventId) else { return false }
            photoStore.delete(named: previous)
            return true
        }
        guard let filename = photoStore.save(image) else { return false }
        guard extras.setPhotoFilename(filename, forEventId: eventId) else {
            // The index refused the new name — drop the bytes it would
            // have pointed at rather than leave an orphan file.
            photoStore.delete(named: filename)
            return false
        }
        if previous != filename {
            photoStore.delete(named: previous)
        }
        return true
    }

    /// Deletes the event: native event, index row, and photo file.
    ///
    /// The native removal comes first. A failure there (the event no
    /// longer exists, or EventKit refused) is not a reason to strand the
    /// index row: the event is not in the calendar either way, so the row
    /// and the photo go regardless — that is exactly what "the event is
    /// gone" means to the list.
    @discardableResult
    func delete(eventId: String) -> Bool {
        let removed = gateway.removeEvent(identifier: eventId)
        if let dropped = extras.remove(eventId: eventId) {
            photoStore.delete(named: dropped.photoFilename)
        }
        emit("event_delete", outcome: removed ? "removed" : "already_gone")
        return removed
    }

    /// The ids the app itself owns — what the Google bridge's free-form
    /// reconcile walks (design §3: "edits/deletes via a foreground
    /// reconcile of side-index-tracked events"). The side index is the
    /// only honest source: it holds exactly the events this app created,
    /// never an imported invitation whose twin belongs to its organizer.
    var trackedEventIds: Set<String> { extras.eventIds }

    // MARK: - Helpers

    static func event(from record: CalendarEventRecord,
                      photoFilename: String?) -> FreeFormEvent {
        FreeFormEvent(id: record.eventIdentifier,
                      title: record.title,
                      startDate: record.startDate,
                      durationMinutes: record.durationMinutes,
                      recurrence: record.recurrence,
                      notes: record.notes,
                      address: record.location,
                      photoFilename: photoFilename)
    }

    private func emit(_ eventType: String, outcome: String = "success") {
        guard let observability else { return }
        observability.emit(ObservabilityEvent(
            component: "free_form_events", eventType: eventType, durationMs: nil,
            outcome: outcome, errorCode: nil, metadata: [:]))
    }
}
