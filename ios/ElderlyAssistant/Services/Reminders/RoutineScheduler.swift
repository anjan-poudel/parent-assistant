import Foundation

/// The routine/event write seam's failures (design L2 §3.3, §5.6, §6.2).
///
/// Every case means "nothing changed": the previous instruction and every
/// file the index still names are intact. The seam returns
/// `Result<Void, InstructionWriteError>` and never a `Bool` (OI-1, P-11), so
/// a caller cannot mistake a refusal for a save.
///
/// Declared here, beside its routine owner (implementation pin P-4), because
/// the routine write transaction is the only producer; the event service
/// (C13) consumes the same type.
enum InstructionWriteError: Error, Equatable {
    /// No routine (or extras) entry has this id. Checked before anything is
    /// written, deleted or re-armed.
    case ownerNotFound
    /// A media payload that names neither pending bytes nor a stored
    /// filename: there is nothing the instruction could point at.
    case unresolvedPayload
    /// The store refused the new bytes. The previous instruction and its
    /// media are untouched.
    case mediaWriteFailed(InstructionStorageError)
    /// The entry/index refused the new payload. Any bytes committed for this
    /// attempt are rolled back; the previous instruction remains readable.
    case persistenceFailed
}

/// The slice of `InstructionVideoStore` the routine write transaction needs
/// (design L2 §5.6, §7.2).
///
/// `InstructionVideoStore` is a concrete `final class` by design (§3.5), so
/// this protocol exists only to make the ordered transaction testable with a
/// spy. There is no second implementation and no second store: the class
/// conforms below, unchanged.
protocol RoutineInstructionVideoStoring: AnyObject {
    func commit(_ staged: StagedInstructionVideo,
                for owner: InstructionOwner) -> Result<String, InstructionStorageError>
    func discard(_ staged: StagedInstructionVideo) -> Result<Void, InstructionStorageError>
    func delete(_ filename: String,
                for owner: InstructionOwner) -> Result<Void, InstructionStorageError>
    func deleteAll(for owner: InstructionOwner) -> Result<Void, InstructionStorageError>
    func availability(filename: String,
                      owner: InstructionOwner) -> InstructionPlaybackAvailability
}

/// The production store is the only conformer (design C02).
extension InstructionVideoStore: RoutineInstructionVideoStoring {}

/// Schedules and fires routine (non-medication) reminders — v2 pivot
/// Phase 1 (docs/superpowers/specs/2026-09-03-v2-gemini-pivot-design.md
/// §4.1/§9). Mirrors `MedicationScheduler`'s proven shape — entries in
/// encrypted storage, occurrences persisted BEFORE platform alarms arm,
/// restore-once + re-arm on every launch — minus everything
/// safety-critical: no acknowledgement window, no escalation engine, no
/// re-fire, no family notification. A missed walk reminder is noise,
/// not an emergency; it expires silently instead of firing late.
final class RoutineScheduler {

    /// Active locale for user-facing strings produced by this service
    /// (notification bodies, spoken summaries). Injected by
    /// `AppCoordinator` from `activeLocale`.
    var locale: Locale = Locale(identifier: "en")

    private let store: RoutineStore
    private let alarmScheduler: RoutineAlarmScheduling
    private let observabilityBus: ObservabilityBus
    /// Caregiver alert seam (caregiver event-notifications task,
    /// 2026-09-13). Unlike the medication path — where the scheduler
    /// already notified for missed doses — routines had no family
    /// notification at all; this is the wiring for the
    /// designed-but-never-called `markDelivered` hook.
    private let familyNotifier: FamilyNotifierProtocol
    /// Per-event-type preferences, read at FIRE time (see
    /// `CaregiverNotifySettings`).
    private let caregiverNotifySettings: CaregiverNotifySettings
    /// Photo store for the entries' visual aids (photo-visual-aids task,
    /// 2026-09-16). Optional with a nil default so every existing test
    /// harness constructs a scheduler unchanged and an entry without
    /// photos — the overwhelming majority — never touches the disk.
    /// `AppCoordinator` passes the app's shared instance, which is what
    /// makes fired notifications carry the picture and deleted entries
    /// drop their photos.
    private let visualAidStore: VisualAidStore?
    /// Instruction video bytes for this owner (C11 write seam, T-013).
    /// Optional with a nil default so every existing harness constructs the
    /// scheduler unchanged; `AppCoordinator` passes the app's one shared
    /// video store. Nil means "no video bytes can be written or deleted" —
    /// text and image instructions still save.
    private let instructionVideoStore: RoutineInstructionVideoStoring?
    /// Injectable clock — tests pin "now" so window/weekday behavior is
    /// deterministic. Production passes `Date.init`.
    private let now: () -> Date

    private var occurrences: [UUID: RoutineOccurrence] = [:]
    private var didRestore = false

    /// Invoked at the end of every schedule-mutating operation
    /// (`addEntry` / `setEnabled` / `removeEntry`) — the single seam
    /// through which the calendar mirror re-syncs (`AppCoordinator`
    /// wires it to `calendarSync.syncNow`) and any other side channel
    /// reacts. Deliberately NOT fired by `scheduleAll()` itself: launch
    /// and BGTask re-queues must not re-mirror per occurrence.
    var onScheduleChanged: (() -> Void)?

    init(
        store: RoutineStore,
        alarmScheduler: RoutineAlarmScheduling,
        observabilityBus: ObservabilityBus,
        familyNotifier: FamilyNotifierProtocol,
        caregiverNotifySettings: CaregiverNotifySettings,
        visualAidStore: VisualAidStore? = nil,
        instructionVideoStore: RoutineInstructionVideoStoring? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.alarmScheduler = alarmScheduler
        self.observabilityBus = observabilityBus
        self.familyNotifier = familyNotifier
        self.caregiverNotifySettings = caregiverNotifySettings
        self.visualAidStore = visualAidStore
        self.instructionVideoStore = instructionVideoStore
        self.now = now
    }

    // MARK: - Entries (read-through to the store)

    func entries() -> [RoutineEntry] {
        store.loadEntries()
    }

    /// IF-23 / M-4. The strict read the orphan sweep builds its live set
    /// from: it delegates to `RoutineStore.loadEntriesIfReadable()` (IF-33),
    /// so `nil` means "the store could not be read" and is preserved as
    /// such. It is never `loadEntries()` plus a flag, and a read failure is
    /// never collapsed to an empty list — that would make every instruction
    /// file on disk look unreferenced. The legacy `entries()` above keeps
    /// its `[]`-on-failure contract for its existing callers.
    func entriesIfReadable() -> [RoutineEntry]? {
        store.loadEntriesIfReadable()
    }

    func entry(for id: UUID) -> RoutineEntry? {
        entries().first { $0.id == id }
    }

    // MARK: - Mutations (UI toggles, voice-created entries)

    /// Persists a new entry and re-arms. Used by the voice `routine.set`
    /// path and any future editor.
    @discardableResult
    func addEntry(_ entry: RoutineEntry) -> Bool {
        guard store.add(entry) else {
            emit("entry_persistence_failed", metadata: [:])
            return false
        }
        emit("entry_added", metadata: ["entry_id_hash": idHash(entry.id),
                                       "category": entry.category.rawValue])
        scheduleAll()
        onScheduleChanged?()
        return true
    }

    func setEnabled(_ entryId: UUID, enabled: Bool) {
        guard var entry = entry(for: entryId) else { return }
        entry.isEnabled = enabled
        guard store.update(entry) else {
            emit("entry_persistence_failed", metadata: [:])
            return
        }
        emit(enabled ? "entry_enabled" : "entry_disabled",
             metadata: ["entry_id_hash": idHash(entryId)])
        scheduleAll()
        onScheduleChanged?()
    }

    func removeEntry(id: UUID) {
        entry(deleting: id)
    }

    /// Removes an entry through the shipping deletion path and tears down
    /// its instruction media (design C11, §2.11 rule 4, §5.6 D).
    ///
    /// The photos and a routine instruction IMAGE share the visual-aid
    /// directory, so the existing `deleteAll` covers both; a routine
    /// instruction VIDEO lives in its own owner directory and is purged
    /// separately. A media delete failure is reported as a typed event and
    /// then left to the orphan sweep — it can never fail the entry deletion
    /// or resurrect the entry.
    func entry(deleting entryId: UUID) {
        guard store.remove(id: entryId) else { return }
        // The photos go WITH the reminder (photo-visual-aids task): a
        // picture of a medicine box must not outlive the reminder it was
        // attached to, and nothing else can find these files afterwards.
        visualAidStore?.deleteAll(for: entryId)
        tearDownInstructionVideoMedia(entryId: entryId)
        emit("entry_removed", metadata: ["entry_id_hash": idHash(entryId)])
        scheduleAll()
        onScheduleChanged?()
    }

    /// Replaces an entry's visual aids (the photo editor's save path).
    /// Persists and re-arms through `persistAndReschedule`, so an edit to
    /// the photos behaves exactly like an edit to the times: durable
    /// immediately, notifications refreshed, calendar mirror re-synced.
    ///
    /// The FILES are the caller's business (`VisualAidStore.save` on add,
    /// `delete` on remove) — this mutator owns only the model payload, the
    /// same separation `RoutineStore` keeps.
    @discardableResult
    func setVisualAids(_ aids: [VisualAid], entryId: UUID) -> Bool {
        guard var entry = entry(for: entryId) else { return false }
        entry.visualAids = aids
        return persistAndReschedule(entry, eventType: "entry_visual_aids_updated",
                                    metadata: ["entry_id_hash": idHash(entryId),
                                               "count": String(aids.count)])
    }

    // MARK: - Instruction write seam (IF-22, design §5.6)

    /// IF-22 / OI-1. The routine owner's ordered write transaction.
    ///
    /// Ordering rule (§5.6): bytes become durable before the index names
    /// them, and the index moves before old bytes are deleted. A missing
    /// owner is `.ownerNotFound` before anything is touched. A failure after
    /// the media write but before persistence deletes the newly committed
    /// file (or keeps it when the unchanged index already names it); a
    /// failure after persistence leaves the new file live and the previous
    /// file a best-effort delete.
    ///
    /// On a successful, real change the entry is persisted once, the window
    /// is regenerated once (`regenerateWindow` refreshes `hadInstruction`
    /// from the new index) and `entry_instruction_updated` is emitted once.
    /// A write producing exactly the stored instruction is a successful
    /// no-op: no persist, no re-arm, no event.
    @discardableResult
    func setInstruction(_ commit: InstructionCommit,
                        entryId: UUID) -> Result<Void, InstructionWriteError> {
        guard var entry = entry(for: entryId) else { return .failure(.ownerNotFound) }
        let previous = entry.instruction

        switch commit.write {
        case .remove:
            // Removing nothing is not a change: no persist, no event, no
            // media delete. The reminder keeps its current instruction.
            guard previous != nil else { return .success(()) }
            entry.instruction = nil
            guard persistInstructionEntry(entry) else {
                return .failure(.persistenceFailed)
            }
            if let previous {
                deleteInstructionMedia(previous, entryId: entryId)
            }
            notifyInstructionChanged(entryId: entryId,
                                     kind: previous?.kind ?? "")
            return .success(())

        case .set(let payload):
            let prepared: Instruction
            var committedVideoFilename: String?
            var committedImage: VisualAid?
            switch payload.kind {
            case .text:
                prepared = payload.instruction
            case .image, .video:
                switch resolveMedia(payload: payload,
                                    pendingMedia: commit.pendingMedia,
                                    entryId: entryId) {
                case .failure(let error):
                    return .failure(error)
                case .success(let media):
                    prepared = media.instruction
                    committedVideoFilename = media.videoFilename
                    committedImage = media.imageAid
                }
            }

            guard prepared != previous else { return .success(()) }

            entry.instruction = prepared
            guard persistInstructionEntry(entry) else {
                rollBackCommittedMedia(videoFilename: committedVideoFilename,
                                       image: committedImage,
                                       previous: previous,
                                       entryId: entryId)
                return .failure(.persistenceFailed)
            }

            if let previous {
                deleteInstructionMedia(previous, entryId: entryId,
                                       replacingWith: prepared)
            }
            notifyInstructionChanged(entryId: entryId, kind: prepared.kind)
            return .success(())
        }
    }

    /// What `resolveMedia` hands back: the instruction the index should
    /// store, plus the bytes just committed (nil when nothing new was
    /// written) so a failed persist can roll them back.
    private struct ResolvedInstructionMedia {
        let instruction: Instruction
        let videoFilename: String?
        let imageAid: VisualAid?
    }

    /// The media half of a `.set` (§5.6 A1/A3, §5.8).
    ///
    /// Pending bytes are committed before the index can name them; a
    /// committed filename is returned for rollback and for the
    /// "index already names it" adoption check. With no pending bytes the
    /// payload must already carry a filename, or the write is
    /// `.unresolvedPayload`.
    private func resolveMedia(payload: InstructionPayload,
                              pendingMedia: InstructionPendingMedia?,
                              entryId: UUID) -> Result<ResolvedInstructionMedia,
                                                       InstructionWriteError> {
        if let pendingMedia, media(pendingMedia, matches: payload.kind) {
            switch pendingMedia {
            case .image(let image):
                guard let visualAidStore else {
                    return .failure(.mediaWriteFailed(.stagingFailed))
                }
                guard let aid = visualAidStore.save(image, for: entryId,
                                                    caption: payload.caption) else {
                    // §5.8: a nil image save is the store's staging refusal.
                    return .failure(.mediaWriteFailed(.stagingFailed))
                }
                let instruction = InstructionPayload(kind: .image,
                                                     caption: payload.caption,
                                                     filename: aid.filename).instruction
                return .success(ResolvedInstructionMedia(instruction: instruction,
                                                         videoFilename: nil,
                                                         imageAid: aid))
            case .video(let video):
                guard let instructionVideoStore else {
                    return .failure(.mediaWriteFailed(.stagingFailed))
                }
                switch instructionVideoStore.commit(video.staged,
                                                   for: .routine(entryId)) {
                case .success(let filename):
                    let instruction = InstructionPayload(kind: .video,
                                                         caption: payload.caption,
                                                         filename: filename).instruction
                    return .success(ResolvedInstructionMedia(instruction: instruction,
                                                             videoFilename: filename,
                                                             imageAid: nil))
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
            // The index already names the bytes (the unchanged-media path):
            // nothing new to commit.
            return .success(ResolvedInstructionMedia(instruction: payload.instruction,
                                                     videoFilename: nil,
                                                     imageAid: nil))
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

    /// Never leaves bytes the index does not name after a failed persist
    /// (§5.6 A2). If the unchanged index already names the committed file (a
    /// retried commit reused the name), the file is adopted and kept.
    private func rollBackCommittedMedia(videoFilename: String?,
                                        image: VisualAid?,
                                        previous: Instruction?,
                                        entryId: UUID) {
        if let videoFilename, previous?.filename != videoFilename {
            deleteVideoMedia(filename: videoFilename, entryId: entryId,
                             reportSuccess: false)
        }
        if let image, previous?.filename != image.filename {
            // Image deletes have no error channel in the shipping store
            // (N-1): the sweep is the backstop.
            visualAidStore?.delete(image, for: entryId)
        }
    }

    /// Deletes a previous instruction's now-unreferenced media (§5.6 step
    /// 3). Only video deletes have an error channel and therefore an event
    /// (N-1); an image delete keeps the shipping best-effort `Void` shape.
    /// `replacingWith` is the new instruction: when both name the same file
    /// the file is still referenced and must not be deleted.
    private func deleteInstructionMedia(_ instruction: Instruction,
                                        entryId: UUID,
                                        replacingWith replacement: Instruction? = nil) {
        guard let filename = instruction.filename, !filename.isEmpty else { return }
        if let replacementFilename = replacement?.filename,
           replacementFilename == filename {
            return
        }
        switch instruction.knownKind {
        case .some(.video):
            deleteVideoMedia(filename: filename, entryId: entryId,
                             reportSuccess: true)
        case .some(.image):
            visualAidStore?.delete(VisualAid(filename: filename), for: entryId)
        case .some(.text):
            break
        case .none:
            // Unknown raw kind: the holding store is not knowable from the
            // model, so attempt both. Neither attempt claims a success
            // event for a kind the instruction does not have.
            visualAidStore?.delete(VisualAid(filename: filename), for: entryId)
            deleteVideoMedia(filename: filename, entryId: entryId,
                             reportSuccess: false)
        }
    }

    /// One video-file delete with its `instruction_media_delete` event
    /// (§6.4). `reportSuccess` is false for internal rollbacks, which must
    /// clean up without claiming the person's media was deleted.
    private func deleteVideoMedia(filename: String,
                                  entryId: UUID,
                                  reportSuccess: Bool) {
        guard let instructionVideoStore else { return }
        let owner = InstructionOwner.routine(entryId)
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
            instructionEvents.mediaDelete(outcome: existed ? .deleted : .absent,
                                          count: existed ? 1 : 0,
                                          error: nil)
        case .failure(let error):
            instructionEvents.mediaDelete(outcome: .failed, count: 0,
                                          error: error)
        }
    }

    /// Entry teardown's video half (§2.11 rule 4). Always attempted for the
    /// owner directory; a failure is reported and left to the sweep.
    private func tearDownInstructionVideoMedia(entryId: UUID) {
        guard let instructionVideoStore else { return }
        if case .failure(let error) =
            instructionVideoStore.deleteAll(for: .routine(entryId)) {
            instructionEvents.mediaDelete(outcome: .failed, count: 0,
                                          error: error)
        }
    }

    /// The single index write of the transaction. Emits the routine's
    /// existing persistence-failure event on refusal; `setInstruction`
    /// turns `false` into `.persistenceFailed`.
    private func persistInstructionEntry(_ entry: RoutineEntry) -> Bool {
        guard store.update(entry) else {
            emit("entry_persistence_failed", metadata: [:])
            return false
        }
        return true
    }

    /// `entry_instruction_updated`, exactly once per real change (design
    /// §6.4): outcome `saved`, metadata `entry_id_hash`, `kind` and
    /// `count = 1`. Never text, caption, filename, path or title.
    ///
    /// Emitted through the scheduler's shared post-persist path
    /// (`completeMutation`, the same tail `persistAndReschedule` runs) but
    /// after the old-media delete §5.6 step 3 requires between the index
    /// write and step 4. Written as a direct `emit` call so the release
    /// log-safety gate grades this registered event's payload by name.
    private func notifyInstructionChanged(entryId: UUID, kind: String) {
        emit("entry_instruction_updated",
             metadata: ["entry_id_hash": idHash(entryId),
                        "kind": InstructionKind.reportable(kind),
                        "count": "1"],
             outcome: "saved")
        completeMutation()
    }

    /// The typed media-event emitter this seam shares with the rest of the
    /// feature (§6.4). A value type over the injected bus; no state.
    private var instructionEvents: InstructionObservability {
        InstructionObservability(bus: observabilityBus)
    }

    // MARK: - Native-edit application (calendar-driven task, 2026-09-07)

    /// Mutators the coordinator applies `CalendarSyncService`
    /// mutations through (family edits made in the native Calendar on
    /// the two-way Sahayak mirror). Every lookup is keyed by
    /// TIME-OF-DAY, never by list index: reconciliation plans against
    /// an entry snapshot, then mutations apply sequentially — earlier
    /// ones may have compacted `scheduleTimes`, so an index would go
    /// stale while an hour:minute survives. Like every other mutator
    /// here they persist, re-arm and fire `onScheduleChanged` (the
    /// mirror re-syncs; the planners then see equal shapes and stop).

    /// Retimes one slot of an entry. No-op (returns false) when the
    /// entry or the from-time no longer exists.
    @discardableResult
    func retimeSlot(entryId: UUID, fromHour: Int, fromMinute: Int,
                    toHour: Int, toMinute: Int) -> Bool {
        guard var entry = entry(for: entryId),
              let index = slotIndex(in: entry, hour: fromHour, minute: fromMinute)
        else { return false }
        entry.scheduleTimes[index] = DateComponents(hour: toHour, minute: toMinute)
        return persistAndReschedule(entry, eventType: "entry_retimed",
                                    metadata: ["entry_id_hash": idHash(entryId)])
    }

    /// Drops one slot of an entry (its native mirror event was
    /// deleted). Refuses to empty the list — an entry whose last slot
    /// goes is DISABLED instead (the planner emits `disableEntry` for
    /// that shape; an enabled entry with zero times could never fire
    /// anything but would keep mirroring confusion).
    @discardableResult
    func dropSlot(entryId: UUID, hour: Int, minute: Int) -> Bool {
        guard var entry = entry(for: entryId),
              let index = slotIndex(in: entry, hour: hour, minute: minute)
        else { return false }
        entry.scheduleTimes.remove(at: index)
        guard !entry.scheduleTimes.isEmpty else { return false }
        return persistAndReschedule(entry, eventType: "slot_dropped",
                                    metadata: ["entry_id_hash": idHash(entryId)])
    }

    /// Converts an entry's recurrence (a native daily↔weekly edit).
    /// `.daily` clears weekdays; `.weekly` stores the record's list
    /// (empty weekdays under `.weekly` means every day — but the
    /// planner only emits `.weekly` with days).
    @discardableResult
    func updateRecurrence(entryId: UUID, frequency: RoutineFrequency,
                          weekdays: [Int]) -> Bool {
        guard var entry = entry(for: entryId) else { return false }
        entry.frequency = frequency
        entry.weekdays = frequency == .daily ? [] : weekdays.sorted()
        return persistAndReschedule(entry, eventType: "entry_recurrence_updated",
                                    metadata: ["entry_id_hash": idHash(entryId)])
    }

    /// First slot whose hour/minute match — the compaction-safe lookup
    /// every native-edit mutator keys on.
    private func slotIndex(in entry: RoutineEntry, hour: Int, minute: Int) -> Int? {
        entry.scheduleTimes.firstIndex { time in
            time.hour == hour && time.minute == minute
        }
    }

    private func persistAndReschedule(_ entry: RoutineEntry,
                                      eventType: String,
                                      metadata: [String: String]) -> Bool {
        guard store.update(entry) else {
            emit("entry_persistence_failed", metadata: [:])
            return false
        }
        completePersistedMutation(eventType: eventType, metadata: metadata)
        return true
    }

    /// The post-persist half of every mutation: one observation, then the
    /// shared completion. Called only after the index write succeeded, so a
    /// failed mutation never announces itself as done.
    private func completePersistedMutation(eventType: String,
                                           metadata: [String: String],
                                           outcome: String = "success") {
        emit(eventType, metadata: metadata, outcome: outcome)
        completeMutation()
    }

    /// One re-arm and one side-channel notification — the tail every
    /// successful mutation (and `setInstruction`) shares.
    private func completeMutation() {
        scheduleAll()
        onScheduleChanged?()
    }

    // MARK: - Schedule All (launch + BGTask wake, mirrors MedicationScheduler)

    /// Restores persisted occurrences once per process, then regenerates
    /// the scheduling window (today + tomorrow) from the current entries:
    /// kept occurrences preserve identity (their OS alarms replace
    /// in-place), new occurrences arm, dropped ones cancel. This is the
    /// FR-025 re-queue: relaunching the app always leaves every pending
    /// routine reminder for the window armed.
    func scheduleAll() {
        restoreState()
        regenerateWindow()
    }

    /// Today's occurrences (any state), sorted — the Reminders leaf and
    /// the voice query both render this.
    func todaysOccurrences() -> [RoutineOccurrence] {
        restoreState()
        let calendar = Calendar.current
        return occurrences.values
            .filter { calendar.isDate($0.scheduledAt, inSameDayAs: now()) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    /// Marks an occurrence delivered (notification observed firing) and
    /// fires the caregiver alert for it.
    ///
    /// Called from `CaregiverEventFireHandler.willPresent` — the
    /// notification delegate finally exists (caregiver
    /// event-notifications task, 2026-09-13), which is the "when that
    /// delegate lands" moment this hook was written for.
    ///
    /// The `state == .pending` guard is what makes the alert
    /// once-per-event: a foreground + background delivery pair for the
    /// same occurrence (or a re-presented notification) notifies exactly
    /// once, because the second call is already `.delivered`.
    func markDelivered(occurrenceId: UUID) {
        restoreState()
        guard var occurrence = occurrences[occurrenceId],
              occurrence.state == .pending else { return }
        occurrence.state = .delivered
        occurrences[occurrenceId] = occurrence
        persistOccurrences()
        emit("reminder_delivered", metadata: ["entry_id_hash": idHash(occurrence.entryId)])
        notifyCaregivers(of: occurrence)
    }

    /// Caregiver alert for a delivered routine occurrence (caregiver
    /// event-notifications task, 2026-09-13).
    ///
    /// The alert's title is the entry's DISPLAY title — the exact string
    /// the notification body and the mirrored calendar event carry
    /// (`entry.displayTitle(locale:)`), so the caregiver sees the same
    /// words the elder did. It stays in memory; the bus records only the
    /// hashed occurrence id and the kind.
    private func notifyCaregivers(of occurrence: RoutineOccurrence) {
        guard caregiverNotifySettings.isEnabled(for: .routineReminder) else {
            emit("caregiver_event_skipped",
                 metadata: ["kind": EventNotifyKind.routineReminder.rawValue])
            return
        }
        let context = FamilyAlertContext(
            kind: .routineReminder,
            eventIdHash: idHash(occurrence.id),
            eventTitle: entry(for: occurrence.entryId)?.displayTitle(locale: locale) ?? "",
            fireAt: occurrence.scheduledAt
        )
        emit("caregiver_event_fired",
             metadata: ["kind": EventNotifyKind.routineReminder.rawValue,
                        "event_id_hash": context.eventIdHash])
        Task { [familyNotifier] in
            _ = await familyNotifier.notifyAll(
                alertType: .eventReminder,
                at: Date(),
                context: context
            )
        }
    }

    // MARK: - Private: window regeneration

    private func regenerateWindow() {
        let calendar = Calendar.current
        let currentTime = now()
        let startOfToday = calendar.startOfDay(for: currentTime)
        guard let endOfWindow = calendar.date(byAdding: .day, value: 2, to: startOfToday) else {
            return
        }

        // Desired fire times for the window, keyed by (entry, minute-
        // precise time) so existing occurrences keep their identity.
        let allEntries = entries()
        let entriesById = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.id, $0) })
        var desired: [String: (entry: RoutineEntry, at: Date)] = [:]
        for entry in allEntries where entry.isEnabled {
            for dayOffset in 0..<2 {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday),
                      entry.fires(on: day, calendar: calendar) else { continue }
                for time in entry.scheduleTimes {
                    guard let fireAt = combine(day: day, time: time, calendar: calendar),
                          fireAt < endOfWindow else { continue }
                    desired[dedupeKey(entryId: entry.id, at: fireAt)] = (entry, fireAt)
                }
            }
        }

        // Reconcile: keep matching occurrences (identity + state), create
        // the rest. Anything tracked but no longer desired (entry removed,
        // disabled, or window rolled past) is cancelled and dropped.
        var next: [UUID: RoutineOccurrence] = [:]
        var staleIds: [UUID] = []
        for occurrence in occurrences.values {
            let key = dedupeKey(entryId: occurrence.entryId, at: occurrence.scheduledAt)
            if desired[key] != nil {
                next[occurrence.id] = occurrence
            } else {
                staleIds.append(occurrence.id)
            }
        }
        for (_, candidate) in desired {
            let key = dedupeKey(entryId: candidate.entry.id, at: candidate.at)
            let alreadyTracked = occurrences.values.contains {
                dedupeKey(entryId: $0.entryId, at: $0.scheduledAt) == key
            }
            if !alreadyTracked {
                let occurrence = RoutineOccurrence(
                    id: UUID(), entryId: candidate.entry.id,
                    scheduledAt: candidate.at, state: .pending
                )
                next[occurrence.id] = occurrence
            }
        }
        occurrences = next
        if !staleIds.isEmpty {
            alarmScheduler.cancelRoutineReminders(occurrenceIds: staleIds)
        }

        // Persistence BEFORE alarms — the medication path's ordering rule
        // (a crash between the two must leave durable state, never an
        // armed alarm for a forgotten occurrence). On write failure we do
        // NOT arm: mirrors `createPendingReminders`' early return.
        guard persistOccurrences() else { return }

        // Arm future pendings; expire past-due pendings without firing
        // (see RoutineOccurrence.State.expired for the rationale).
        // Iterate a snapshot: the loop mutates `occurrences`, which is a
        // simultaneous-access violation if done mid-enumeration.
        var expiredIds: [UUID] = []
        let pendingSnapshot = occurrences.values.filter { $0.state == .pending }
        for occurrence in pendingSnapshot {
            guard let entry = entriesById[occurrence.entryId] else { continue }
            if occurrence.scheduledAt > currentTime {
                alarmScheduler.scheduleRoutineReminder(
                    occurrenceId: occurrence.id,
                    entryId: entry.id,
                    title: entry.displayTitle(locale: locale),
                    visualAidURL: visualAidURL(for: entry),
                    hadInstruction: entry.instruction?.isPresent == true,
                    at: occurrence.scheduledAt
                )
            } else {
                occurrences[occurrence.id]?.state = .expired
                expiredIds.append(occurrence.id)
                emit("occurrence_expired_unfired",
                     metadata: ["entry_id_hash": idHash(occurrence.entryId)])
            }
        }
        if !expiredIds.isEmpty {
            persistOccurrences()
        }
    }

    /// The file to attach to this entry's fired notification: its FIRST
    /// visual aid, or nil when the entry has none, the store is not wired,
    /// or the file has gone missing. One image per notification is the
    /// platform's limit (a `UNNotificationAttachment` is singular), and
    /// "the first photo the caregiver added" is the one that matters — the
    /// full set is what the in-app screen pages through.
    private func visualAidURL(for entry: RoutineEntry) -> URL? {
        guard let visualAidStore, let aid = entry.visualAids.first else { return nil }
        return visualAidStore.existingFileURL(aid, for: entry.id)
    }

    private func combine(day: Date, time: DateComponents, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        return calendar.date(from: components)
    }

    private func dedupeKey(entryId: UUID, at date: Date) -> String {
        "\(entryId.uuidString)|\(Int(date.timeIntervalSince1970))"
    }

    // MARK: - Private: state

    private func restoreState() {
        // Once per process — a second restore would clobber in-memory
        // mutations not yet persisted (MedicationScheduler's didRestore rule).
        guard !didRestore else { return }
        didRestore = true
        occurrences = Dictionary(
            uniqueKeysWithValues: store.loadOccurrences().map { ($0.id, $0) }
        )
    }

    @discardableResult
    private func persistOccurrences() -> Bool {
        guard store.saveOccurrences(Array(occurrences.values)) else {
            emit("occurrence_persistence_failed", metadata: [:])
            return false
        }
        return true
    }

    // MARK: - Observability

    private func idHash(_ id: UUID) -> String {
        IdHashing.shortHash(of: id)
    }

    private func emit(_ eventType: String, metadata: [String: String],
                      outcome: String = "success") {
        observabilityBus.emit(ObservabilityEvent(
            component: "routine_scheduler",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: metadata
        ))
    }
}
