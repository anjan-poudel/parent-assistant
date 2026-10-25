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

    /// The event's one instruction, read from the side index (FR-RIE-001;
    /// design L2 §2.13, §4.8). `nil` when the event has none OR when its
    /// row does not carry one — the two read the same here, and the detail
    /// renders `.none` rather than the routine fired screen's `.removed`
    /// (§5.9). Populated by `event(withId:)` and `upcoming` from the SAME
    /// extras row that carries the photo; there is no second store.
    var instruction: Instruction? = nil

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

    /// The event's one instruction draft (design L2 §4.8). The add form
    /// starts `.loaded(instruction: nil)` — nothing to write, and
    /// `resolvedCommit` stays nil until the elder authors something — and
    /// `init(event:)` seeds it from the event the detail read, so an
    /// untouched edit writes no instruction work at all. The form owns no
    /// write decision beyond this value: `save` reads `resolvedCommit`.
    var instructionDraft: InstructionDraft = .loaded(instruction: nil)

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
    ///
    /// The instruction draft is seeded from the event's stored
    /// instruction (§4.8), so an edit that does not touch the instruction
    /// has `resolvedCommit == nil` and writes nothing. The photo is
    /// deliberately NOT seeded into `pickedPhoto`: an existing file is
    /// not "just picked", and only an explicit pick or Remove may change
    /// it.
    init(event: FreeFormEvent) {
        self.title = event.title
        self.startDate = event.startDate
        self.durationMinutes = event.durationMinutes
        self.recurrence = event.recurrenceChoice
        self.notes = event.notes ?? ""
        self.address = event.address ?? ""
        self.originalRecurrence = event.recurrence
        self.instructionDraft = .loaded(instruction: event.instruction)
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

/// IF-25. What the Events form's save actually achieved (design L2 §3.6,
/// §4.8).
///
/// `nil` from `save` means the EVENT did not save; this value only exists
/// when it did. `instructionSaved == false` is the honest partial result:
/// the event (and its photo) are exactly as they would have been, and the
/// instruction write either failed or never happened — the form reports
/// one plain line and keeps the event editable.
///
/// Two fields, no error payload: the instruction failure is already
/// mapped to copy by `InstructionMessageKey.forWrite` at the surface, and
/// no error type belongs in a value the view compares.
struct FreeFormEventSaveOutcome: Equatable {
    let eventId: String
    let instructionSaved: Bool
}

// MARK: - Service

/// Free-form events are NATIVE EventKit events in the default calendar
/// (design §1 decision 4): the app owns no event store of its own, and
/// everything EventKit can hold — title, time, duration, recurrence,
/// notes, address — lives there, so the native Calendar app, the app's
/// import, the caregiver alert and the Google bridge all see the same
/// event, and a family edit is simply an edit.
///
/// The TWO things EventKit cannot hold are a photo and an instruction, so
/// those alone live in an encrypted side index (`EventExtrasStore`) plus a
/// file store: the photo in `ContactPhotoStore` rooted at EventPhotos (the
/// photo-aids store pattern), the instruction's video bytes in
/// `InstructionVideoStore` under the event owner root (`ev-<sha256>`, never
/// the routine root — design L2 §5.6, §5.8). The design says so plainly:
/// photos show in this app only, never in the native Calendar app or
/// Google Calendar, because those platforms have no event-photo API.
///
/// Membership in the side index is what makes an event "one of ours" for
/// the list, and the reconcile that prunes it — an event the elder (or
/// the family) deleted natively is dropped from the index, its photo file
/// and its instruction video directory with it, so the index can never
/// grow a tail of dead ids.
final class FreeFormEventService {

    private let gateway: EventKitCalendarGateway
    private let extras: EventExtrasStore
    private let photoStore: ContactPhotoStore
    /// The event owner's video bytes (C13 write seam, T-015). Typed to the
    /// shared store slice so a test can spy the transaction's order; the
    /// concrete `InstructionVideoStore` is the production default. The
    /// protocol is the SAME one C11 uses (`RoutineInstructionVideoStoring`)
    /// — one slice, one conformance, no duplicate declaration — and the
    /// store it names is rooted per owner, so the routine and event roots
    /// can never collide.
    private let instructionVideoStore: RoutineInstructionVideoStoring
    private let observability: ObservabilityBus?

    /// `gateway` and `photoStore` default to the production ones — the
    /// composition root constructs this with only the encrypted store it
    /// owns, and tests pass fakes. The photo store gets a directory of
    /// its own (`EventPhotos`) so an event photo can never be read — or
    /// deleted — as a contact's. The video store defaults to a production
    /// `InstructionVideoStore` (path resolution only, no IO at init) so
    /// an event instruction works without extra wiring; the coordinator
    /// may inject its shared instance.
    init(gateway: EventKitCalendarGateway = EKCalendarGateway(),
         extras: EventExtrasStore,
         photoStore: ContactPhotoStore? = nil,
         instructionVideoStore: RoutineInstructionVideoStoring? = nil,
         observability: ObservabilityBus? = nil) {
        self.gateway = gateway
        self.extras = extras
        self.photoStore = photoStore ?? ContactPhotoStore(directoryName: "EventPhotos")
        self.instructionVideoStore = instructionVideoStore ?? InstructionVideoStore()
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
    /// an id that no longer resolves is removed, its photo file with it,
    /// and its instruction video directory too (design L2 §2.13.4). The
    /// media teardown is best-effort: a failed index removal leaves the
    /// row AND the media in place, which is today's retry behaviour.
    func upcoming(now: Date = Date()) -> [FreeFormEvent] {
        var events: [FreeFormEvent] = []
        for eventId in extras.eventIds {
            guard let record = gateway.fetchEvent(identifier: eventId),
                  !record.isCanceled else {
                // Gone (or canceled, which reads as deleted everywhere
                // else in this codebase). Drop the index row and the
                // media bytes together — the index/bytes split means the
                // caller of `remove` owns the files.
                if let dropped = extras.remove(eventId: eventId) {
                    photoStore.delete(named: dropped.photoFilename)
                    tearDownInstructionVideoMedia(eventId: eventId)
                    emit("event_vanished")
                }
                continue
            }
            let row = extras.extras(forEventId: eventId)
            let event = Self.event(from: record,
                                   photoFilename: row?.photoFilename,
                                   instruction: row?.instruction)
            guard event.isRecurring || event.startDate >= now else { continue }
            events.append(event)
        }
        return events.sorted { $0.startDate < $1.startDate }
    }

    /// One event by native identifier, or nil when it is gone.
    ///
    /// The composite carries the instruction from the SAME extras row that
    /// carries the photo (design L2 §2.13.1). A nil row and a row without
    /// an instruction both read as `instruction == nil`; the coordinator's
    /// existing `freeFormEvent(id:)` wrapper is a call to this method, so
    /// there is no second read path (§5.9).
    func event(withId eventId: String) -> FreeFormEvent? {
        guard let record = gateway.fetchEvent(identifier: eventId),
              !record.isCanceled else { return nil }
        let row = extras.extras(forEventId: eventId)
        return Self.event(from: record,
                          photoFilename: row?.photoFilename,
                          instruction: row?.instruction)
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

    /// Creates (eventId nil) or updates the event, and answers what was
    /// saved — nil only when the EVENT itself was not, in which case the
    /// form stays on screen with its draft intact.
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
    ///
    /// IF-25 (design L2 §2.13.3, §4.8, §5.6): the instruction is written
    /// SECOND, through `setInstruction`, and only after the event's
    /// `resolvedId` exists — so a refused create leaves no instruction
    /// bytes at all, and a failed instruction write leaves the event
    /// saved and editable with an honest `instructionSaved == false`.
    /// A partial outcome is never nil; nil would make the form lie about
    /// what happened. No draft (or an untouched one) has no resolved
    /// commit and does no instruction work.
    @discardableResult
    func save(_ form: FreeFormEventForm,
              editing eventId: String? = nil) -> FreeFormEventSaveOutcome? {
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

        // §5.6: step 1 of the instruction transaction runs only after the
        // event's resolvedId exists. `.remove` from an untouched draft
        // cannot happen — `resolvedCommit` is nil without a change.
        guard let commit = form.instructionDraft.resolvedCommit else {
            return FreeFormEventSaveOutcome(eventId: resolvedId,
                                            instructionSaved: true)
        }
        switch setInstruction(commit, forEventId: resolvedId) {
        case .success:
            return FreeFormEventSaveOutcome(eventId: resolvedId,
                                            instructionSaved: true)
        case .failure:
            // The event and its photo are as today; the instruction did
            // not change and no committed media was left behind
            // (§4.8 row 4). Never collapse this into nil.
            return FreeFormEventSaveOutcome(eventId: resolvedId,
                                            instructionSaved: false)
        }
    }

    // MARK: - The instruction write seam (IF-24, design §5.6)

    /// IF-24. The event owner's ordered write transaction — the same rule
    /// as C11: **bytes are durable before the index names them; the index
    /// moves before old bytes are deleted.**
    ///
    /// A missing extras row is `.ownerNotFound` before anything is
    /// touched (no bytes written, no bytes deleted, no event emitted).
    /// Pending image bytes go through the existing event photo store
    /// (§5.8 — a nil save is `.mediaWriteFailed(.stagingFailed)`); pending
    /// video bytes go through `InstructionVideoStore.commit(for:
    /// .event(eventId))`, never the routine root. A failed persist deletes
    /// the bytes committed for this attempt; a failed media delete after a
    /// durable index is reported and never fails the write (§5.6 A3/D).
    /// A write producing exactly the stored instruction is a successful
    /// no-op: no persist, no delete, no event.
    @discardableResult
    func setInstruction(_ commit: InstructionCommit,
                        forEventId eventId: String) -> Result<Void, InstructionWriteError> {
        // Resolve the owner FIRST (design §5.6): "no row here" means the
        // event is no longer ours, and no byte may be touched.
        guard let row = extras.extras(forEventId: eventId) else {
            return .failure(.ownerNotFound)
        }
        let previous = row.instruction

        switch commit.write {
        case .remove:
            // Removing nothing is not a change: no persist, no event, no
            // media delete. The event keeps its current instruction.
            guard previous != nil else { return .success(()) }
            // §5.6 D: persist first. On failure the bytes and the index
            // are untouched.
            guard extras.setInstruction(nil, forEventId: eventId) else {
                return .failure(.persistenceFailed)
            }
            if let previous {
                deleteInstructionMedia(previous, eventId: eventId)
                notifyInstructionChanged(kind: previous.kind)
            }
            return .success(())

        case .set(let payload):
            let prepared: Instruction
            var committedVideoFilename: String?
            var committedImageFilename: String?
            switch payload.kind {
            case .text:
                prepared = payload.instruction
            case .image, .video:
                switch resolveMedia(payload: payload,
                                    pendingMedia: commit.pendingMedia,
                                    eventId: eventId) {
                case .failure(let error):
                    return .failure(error)
                case .success(let media):
                    prepared = media.instruction
                    committedVideoFilename = media.videoFilename
                    committedImageFilename = media.imageFilename
                }
            }

            guard prepared != previous else { return .success(()) }

            // §5.6 A2/B/C: one index write, after the bytes (if any).
            guard extras.setInstruction(prepared, forEventId: eventId) else {
                rollBackCommittedMedia(videoFilename: committedVideoFilename,
                                       imageFilename: committedImageFilename,
                                       previous: previous,
                                       eventId: eventId)
                return .failure(.persistenceFailed)
            }

            // §5.6 A3/C: only now may the previous bytes go. A failure is
            // observed and left to the sweep — the instruction is already
            // correct, so it never fails this write.
            if let previous {
                deleteInstructionMedia(previous,
                                       eventId: eventId,
                                       replacingWith: prepared)
            }
            notifyInstructionChanged(kind: prepared.kind)
            return .success(())
        }
    }

    /// What `resolveMedia` hands back: the instruction the extras row
    /// should store, plus the bytes just committed (nil when nothing new
    /// was written) so a failed persist can roll them back.
    private struct ResolvedInstructionMedia {
        let instruction: Instruction
        let videoFilename: String?
        let imageFilename: String?
    }

    /// The media half of a `.set` (§5.6 A1, §5.8).
    ///
    /// Pending bytes are committed BEFORE the extras row can name them; a
    /// committed filename is returned for rollback and for the
    /// "index already names it" adoption check. With no pending bytes the
    /// payload must already carry a filename, or the write is
    /// `.unresolvedPayload`.
    private func resolveMedia(payload: InstructionPayload,
                              pendingMedia: InstructionPendingMedia?,
                              eventId: String) -> Result<ResolvedInstructionMedia,
                                                       InstructionWriteError> {
        if let pendingMedia, media(pendingMedia, matches: payload.kind) {
            switch pendingMedia {
            case .image(let image):
                // §5.8: events map the existing photo store's nil save to
                // the same staging refusal the routine path uses.
                guard let filename = photoStore.save(image) else {
                    return .failure(.mediaWriteFailed(.stagingFailed))
                }
                let instruction = InstructionPayload(kind: .image,
                                                     caption: payload.caption,
                                                     filename: filename).instruction
                return .success(ResolvedInstructionMedia(instruction: instruction,
                                                         videoFilename: nil,
                                                         imageFilename: filename))
            case .video(let video):
                switch instructionVideoStore.commit(video.staged,
                                                    for: .event(eventId)) {
                case .success(let filename):
                    let instruction = InstructionPayload(kind: .video,
                                                         caption: payload.caption,
                                                         filename: filename).instruction
                    return .success(ResolvedInstructionMedia(instruction: instruction,
                                                             videoFilename: filename,
                                                             imageFilename: nil))
                case .failure(let error):
                    // The draft bytes are useless now; the orphan sweep
                    // collects them if this best-effort discard also fails
                    // (§5.6 A1).
                    _ = instructionVideoStore.discard(video.staged)
                    return .failure(.mediaWriteFailed(error))
                }
            }
        }

        if let filename = payload.filename, !filename.isEmpty {
            // The extras row already names the bytes (the unchanged-media
            // path): nothing new to commit.
            return .success(ResolvedInstructionMedia(instruction: payload.instruction,
                                                     videoFilename: nil,
                                                     imageFilename: nil))
        }
        return .failure(.unresolvedPayload)
    }

    private func media(_ media: InstructionPendingMedia,
                       matches kind: InstructionKind) -> Bool {
        switch media {
        case .image:
            return kind == .image
        case .video:
            return kind == .video
        }
    }

    /// Never leaves bytes the extras row does not name after a failed
    /// persist (§5.6 A2). If the unchanged row already names the committed
    /// file (a retried commit reused the name), the file is adopted and
    /// kept.
    private func rollBackCommittedMedia(videoFilename: String?,
                                        imageFilename: String?,
                                        previous: Instruction?,
                                        eventId: String) {
        if let videoFilename, previous?.filename != videoFilename {
            deleteVideoMedia(filename: videoFilename, eventId: eventId,
                             reportSuccess: false)
        }
        if let imageFilename, previous?.filename != imageFilename {
            // Image deletes have no error channel in the shipping store
            // (N-1): best-effort, and the sweep is the backstop.
            photoStore.delete(named: imageFilename)
        }
    }

    /// Deletes a previous instruction's now-unreferenced media (§5.6 step
    /// 3). Only video deletes have an error channel and therefore an
    /// event (N-1, §5.8); an image delete keeps the shipping best-effort
    /// `Void` shape. `replacingWith` is the new instruction: when both
    /// name the same file the file is still referenced and must not be
    /// deleted.
    private func deleteInstructionMedia(_ instruction: Instruction,
                                        eventId: String,
                                        replacingWith replacement: Instruction? = nil) {
        guard let filename = instruction.filename, !filename.isEmpty else { return }
        if let replacementFilename = replacement?.filename,
           replacementFilename == filename {
            return
        }
        switch instruction.knownKind {
        case .some(.video):
            deleteVideoMedia(filename: filename, eventId: eventId,
                             reportSuccess: true)
        case .some(.image):
            photoStore.delete(named: filename)
        case .some(.text):
            break
        case .none:
            // Unknown raw kind: the holding store is not knowable from the
            // model, so attempt both. Neither attempt claims a success
            // event for a kind the instruction does not have.
            photoStore.delete(named: filename)
            deleteVideoMedia(filename: filename, eventId: eventId,
                             reportSuccess: false)
        }
    }

    /// One video-file delete with its `instruction_media_delete` event
    /// (§6.4). `reportSuccess` is false for internal rollbacks, which must
    /// clean up without claiming the person's media was deleted.
    private func deleteVideoMedia(filename: String,
                                  eventId: String,
                                  reportSuccess: Bool) {
        let owner = InstructionOwner.event(eventId)
        let existed: Bool
        switch instructionVideoStore.availability(filename: filename,
                                                  owner: owner) {
        case .available, .rejectedFilename, .unreadableFile:
            existed = true
        case .missingFile:
            existed = false
        }
        switch instructionVideoStore.delete(filename, for: owner) {
        case .success:
            guard reportSuccess else { return }
            instructionEvents?.mediaDelete(outcome: existed ? .deleted : .absent,
                                           count: existed ? 1 : 0,
                                           error: nil)
        case .failure(let error):
            instructionEvents?.mediaDelete(outcome: .failed, count: 0,
                                           error: error)
        }
    }

    /// The event teardown's video half (design §2.13.4). Always attempted
    /// for the owner directory; a failure is reported and left to the
    /// sweep. A media-delete failure can never fail-or-block the event
    /// deletion.
    private func tearDownInstructionVideoMedia(eventId: String) {
        if case .failure(let error) =
            instructionVideoStore.deleteAll(for: .event(eventId)) {
            instructionEvents?.mediaDelete(outcome: .failed, count: 0,
                                           error: error)
        }
    }

    /// `event_instruction_updated`, exactly once per real change (design
    /// §6.4): component `free_form_events`, outcome `saved`, metadata
    /// `kind` and `count = 1`. Never an event id, title, text, caption,
    /// filename or URL — an event id would misname the routine
    /// `entry_id_hash` field, and the rest is household content.
    private func notifyInstructionChanged(kind: String) {
        emit("event_instruction_updated", outcome: "saved",
             metadata: ["kind": InstructionKind.reportable(kind),
                        "count": "1"])
    }

    /// The typed media-event emitter this service shares with the rest of
    /// the feature (§6.4). A value type over the injected bus; nil when no
    /// bus was injected, in which case only the write itself is silent.
    private var instructionEvents: InstructionObservability? {
        observability.map { InstructionObservability(bus: $0) }
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

    /// Deletes the event: native event, index row, photo file and the
    /// event owner's whole instruction-video directory (design §2.13.4).
    ///
    /// The native removal comes first. A failure there (the event no
    /// longer exists, or EventKit refused) is not a reason to strand the
    /// index row: the event is not in the calendar either way, so the row
    /// and the media go regardless — that is exactly what "the event is
    /// gone" means to the list.
    ///
    /// The video teardown is best-effort by contract: a media-delete
    /// failure is reported as an `instruction_media_delete` event and left
    /// to the orphan sweep. It never changes the returned Bool (which
    /// reports the NATIVE removal) and never blocks the row removal.
    @discardableResult
    func delete(eventId: String) -> Bool {
        let removed = gateway.removeEvent(identifier: eventId)
        if let dropped = extras.remove(eventId: eventId) {
            photoStore.delete(named: dropped.photoFilename)
        }
        tearDownInstructionVideoMedia(eventId: eventId)
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
                      photoFilename: String?,
                      instruction: Instruction? = nil) -> FreeFormEvent {
        FreeFormEvent(id: record.eventIdentifier,
                      title: record.title,
                      startDate: record.startDate,
                      durationMinutes: record.durationMinutes,
                      recurrence: record.recurrence,
                      notes: record.notes,
                      address: record.location,
                      photoFilename: photoFilename,
                      instruction: instruction)
    }

    private func emit(_ eventType: String,
                      outcome: String = "success",
                      metadata: [String: String] = [:]) {
        guard let observability else { return }
        observability.emit(ObservabilityEvent(
            component: "free_form_events", eventType: eventType, durationMs: nil,
            outcome: outcome, errorCode: nil, metadata: metadata))
    }
}
