import Foundation
import CryptoKit

// MARK: - Mapping-change re-arm report (IF-12, m-1)

/// The honest per-entry effects of one `rearmForSlotClockChange()` pass
/// (IF-12, review-l1 m-1). The medicine-times save action (T-020) renders
/// one settings line per field; nothing here is UI and nothing here is
/// consumed by the scheduler itself.
///
/// PII-free by construction: two counts, the closed slot vocabulary and
/// one Bool — no medication name, no dose, no clock value (NFR-MSR-002).
/// The counts are REMINDERS, not entries: an entry may hold more than one
/// pending reminder, and each is kept or replaced on its own merits.
struct SlotClockRearmReport: Equatable {
    /// Un-fired reminders replaced through the standard creation path and
    /// armed on this pass. Zero when the persistence the arming depends
    /// on failed — nothing was armed on the replaced set.
    var rearmedCount: Int

    /// Reminders deliberately left in place instead of replaced: every
    /// reminder of an entry kept by the finalize-in-flight guard, plus
    /// every fired reminder of an entry that WAS re-armed (live
    /// escalation never moves).
    var keptLiveCount: Int

    /// Slots whose resolution failed under the new mapping, ordered
    /// morning → afternoon → evening and deduplicated. Those entries
    /// armed nothing; the stored mapping was not repaired or guessed.
    var unresolvedSlots: [MedicationSlot]

    /// A write this pass depended on failed — the rewritten mirrors or
    /// the replacement reminder set — so nothing was armed on the
    /// replaced set. The report never lets that vanish silently (m-1).
    var persistenceFailed: Bool
}

// MARK: - MedicationScheduler Implementation (L2 §5.4)

final class MedicationScheduler: MedicationSchedulerProtocol {

    private let storage: EncryptedLocalStorage
    private let alarmScheduler: PlatformAlarmScheduler
    private let observabilityBus: ObservabilityBus
    private let doubleDoseDetector: DoubleDoseDetector
    private let familyNotifier: FamilyNotifierProtocol
    /// Per-event-type caregiver notification preferences (caregiver
    /// event-notifications task, 2026-09-13). Read at FIRE time — the
    /// reminder itself carries no "notify" flag, so flipping the toggle
    /// changes every subsequent fire and nothing that already fired.
    private let caregiverNotifySettings: CaregiverNotifySettings
    /// Photo store for the entries' visual aids (medication-visual-aids
    /// task, 2026-09-16). Optional with a nil default so every existing
    /// test harness constructs a scheduler unchanged, and so a medicine
    /// with no photos — the overwhelming majority — never touches the
    /// disk on the arming path. `AppCoordinator` passes the app's shared
    /// MEDICATION store (the prefixed one), which is what puts the right
    /// box photo in the right dose's banner.
    private let visualAidStore: VisualAidStore?

    /// On-device photo evidence store (T-007; FR-MSR-013). Optional with
    /// a nil default so every construction site written before the capture
    /// plumbing keeps compiling unchanged — W6/T-021 is the unit that
    /// passes the app's shared store. With a nil store the hold still
    /// registers and finalizes identically (the id contract is
    /// store-independent), but file deletions are SKIPPED: this seam
    /// never touches a store it was not given, and the composition
    /// obligation (pass the store) is explicit at the construction site.
    private let evidenceStore: MedicationEvidenceStore?

    /// The in-memory evidence hold (IF-15, C7.6; T-019): at most one held
    /// capture per entry. The coordinator mints the log id at capture
    /// time (T-021), the store names the file by it, and
    /// `finalizeAcknowledgement` writes the record under that SAME id —
    /// so the `<logId>.jpg` scheme stays true everywhere, including
    /// pending captures (R-1(a)).
    ///
    /// In-memory only, and that is the design: process death loses the
    /// hold and with it any claim — the photo was never attached to a
    /// record, so the honest loss is no loss. Deregistration paths: attach
    /// at finalize, discard on deny/re-enter, replace on re-capture,
    /// clear-at-registration when no un-finalized reminder exists (R-3),
    /// process death.
    private var pendingEvidenceHold: [UUID: PendingEvidenceHold] = [:]

    /// One held capture: the id the record will be written under and the
    /// bare file name the store minted for it (`<logId>.jpg`).
    private struct PendingEvidenceHold {
        let logId: UUID
        let fileName: String
    }

    /// The household slot → clock mapping this scheduler resolves slot
    /// entries through at arming time (C1, IF-11 / FR-MSR-002). A thin,
    /// stateless façade over the encrypted store: every resolution call
    /// reads the persisted record, so a mapping edit is picked up by the
    /// next arming pass and nothing is cached that could drift.
    ///
    /// Defaulted to a store composed over the SAME storage seam the
    /// scheduler already reads and writes — the record it reads is the one
    /// the household mapping is persisted under (`medication.slot_clock`),
    /// and an absent record loads as the household defaults (morning
    /// 08:00, afternoon 13:00, evening 19:00) per the store's own contract.
    /// That default is what keeps every existing construction site
    /// reading the real mapping rather than guessing one; the shared
    /// instance can still be passed explicitly where composition wants it.
    private let slotClockStore: MedicationSlotClockStore

    /// The response window every `ConfirmationChallenge` this scheduler
    /// constructs receives (review-l2 R-2). The initializer default is
    /// the one named home (`ConfirmationChallenge
    /// .defaultChallengeTimeoutSeconds`), and the value is passed
    /// EXPLICITLY at both construction sites — the first-call-issues
    /// challenge and `startConfirmationChallenge` — so no call site
    /// carries a literal and an injected shorter window is honored
    /// end-to-end (challenge deadline, timeout path, re-escalation).
    /// `AckClarificationConfig` (the walk's window) composes from the
    /// same home, so the two windows can never desynchronize (D4).
    private let challengeTimeoutSeconds: TimeInterval

    private var entries: [UUID: MedicationEntry] = [:]
    /// Escalation engines are keyed by REMINDER id, not medication entry id.
    /// A twice-daily entry produces two concurrent reminders; keying by entry
    /// id makes the second overwrite the first, corrupting the morning dose's
    /// escalation math (review finding C4).
    private var engines: [UUID: EscalationEngine] = [:]
    private var adherenceLog: [MedicationAdherenceLog] = []
    private var pendingRemindersList: [UUID: ScheduledReminder] = [:]
    private var confirmationChallenges: [UUID: ConfirmationChallenge] = [:]
    private var didRestore = false

    /// Active locale for user-facing text produced by this service (the
    /// confirmation-challenge prompts). Injected by `AppCoordinator` from
    /// `activeLocale`; the English default matches the legacy hardcoded
    /// strings.
    var locale: Locale = Locale(identifier: "en")

    /// Fired after the schedule changes, with the new entry list
    /// (calendar & family sharing, 2026-09-16).
    ///
    /// Every write path already funnels through `loadSchedule` — the
    /// Settings editor, the voice `set_reminder` path and the app's own
    /// restore — so one seam here observes all of them without any of
    /// them having to remember to tell the share layer. The list is
    /// passed rather than left for the observer to re-read so the
    /// observer sees exactly the version that was stored.
    ///
    /// Deliberately a plain closure and not a delegate/protocol: the
    /// only consumer is `CalendarShareService`, failures there must
    /// never affect the scheduler's own behavior, and a closure the
    /// coordinator assigns once is the smallest thing that works.
    var onScheduleChanged: (([MedicationEntry]) -> Void)?

    /// Significant-event hook (IF-20, C7.4; T-016): invoked
    /// synchronously at the three at-risk trigger sites — a missed dose,
    /// a blocked double dose and the first re-fire decision — with the
    /// event value and the entry it is about.
    ///
    /// Same shape and nullability rule as `onScheduleChanged` above
    /// (the design's own precedent): a plain closure set once at
    /// composition (T-020), main thread by the scheduler's contract,
    /// and an unset hook degrades to no calendar write while every
    /// local behaviour stays untouched. The notifier call and this hook
    /// are independent channels — neither gates the other — and
    /// `intakeRecorded` deliberately never reaches this hook: a
    /// recorded intake is not an at-risk event and writes no calendar
    /// entry.
    var onSignificantEvent: ((SignificantMedicationEvent, MedicationEntry?) -> Void)?

    /// Retime-refusal hook (IF-20, C7.5; T-016, m-5): fires on a
    /// REFUSED slot-entry retime (`setScheduleTimes`) for the one-shot
    /// settings note the family sees (wired at composition in T-020).
    /// The refusal is never silent: the named PII-free observability
    /// event is the operator record, this hook is the family-facing
    /// surface, and the note names no medication — the entry id is all
    /// the consumer needs. Unset = no note, local truth untouched.
    var onSlotEntryRetimeRefused: ((UUID) -> Void)?

    private let storageKeyReminders = "medication.pending_reminders"
    private let storageKeyAdherenceLog = "medication.adherence_log"
    private let storageKeyEntries = "medication.entries"

    var pendingReminders: [ScheduledReminder] {
        Array(pendingRemindersList.values).filter { $0.state != .completed }
    }

    /// Configured medication entries — used by the Settings medication
    /// schedule editor and the voice `set_reminder` path to read/append
    /// entries through the same storage the scheduler persists to.
    func medicationEntries() -> [MedicationEntry] {
        Array(entries.values).sorted { $0.medicationName < $1.medicationName }
    }

    /// One entry by id, or nil when it does not exist (deleted since the
    /// alarm was armed, or never loaded). Read by the Settings photo
    /// editor and by `MedicationVisualAidFireHandler` at FIRE time
    /// (medication-visual-aids task, 2026-09-16).
    func medicationEntry(for id: UUID) -> MedicationEntry? {
        entries[id]
    }

    /// The photo to attach to this entry's armed notifications: its FIRST
    /// visual aid, or nil when the entry has none, no store is wired, or
    /// the file has gone missing. One image per notification is the
    /// platform's limit (a `UNNotificationAttachment` is singular), and
    /// "the first photo the family added" is the one that matters — the
    /// full set is what the in-app dose screen pages through.
    ///
    /// The `entry.visualAids.first` guard comes first on purpose: a
    /// medicine with no photos must not touch the disk at all on the
    /// arming path.
    private func visualAidURL(for entry: MedicationEntry) -> URL? {
        guard let visualAidStore, let aid = entry.visualAids.first else { return nil }
        return visualAidStore.existingFileURL(aid, for: entry.id)
    }

    /// Replaces one entry's visual aids (the photo editor's save path,
    /// medication-visual-aids task 2026-09-16) — the medication analogue
    /// of `RoutineScheduler.setVisualAids`.
    ///
    /// Deliberately NOT `loadSchedule`: that rebuilds every pending
    /// reminder and drops the escalation engines, which is exactly right
    /// for an EDIT to the schedule and exactly wrong for attaching a photo.
    /// A photo must never reschedule a dose, reset an escalation window or
    /// disturb an acknowledgement in flight — so this persists the entry
    /// payload and touches nothing else. The armed notifications keep their
    /// existing trigger; the photo reaches the elder through the dose
    /// screen at fire time, which reads the entry.
    ///
    /// The FILES are the caller's business (`VisualAidStore.save` on add,
    /// `delete` on remove) — this mutator owns only the model payload.
    @discardableResult
    func setVisualAids(_ aids: [VisualAid], entryId: UUID) -> Bool {
        guard var entry = entries[entryId] else { return false }
        entry.visualAids = aids
        entries[entryId] = entry
        // The same payload shape `loadSchedule` writes (sorted by name),
        // so a photo edit and a schedule edit leave identical bytes.
        guard case .success = storage.write(key: storageKeyEntries,
                                            value: medicationEntries()) else {
            emit("entry_persistence_failed",
                 metadata: ["entry_id_hash": idHash(entryId)])
            return false
        }
        emit("entry_visual_aids_updated",
             metadata: ["entry_id_hash": idHash(entryId),
                        "count": String(aids.count)])
        return true
    }

    /// Replaces one entry's dose times — the family retimed or deleted
    /// its mirror events in the Calendar app (calendar-driven
    /// reconciliation, rich-events task 2026-09-17).
    ///
    /// Goes through `loadSchedule` DELIBERATELY, unlike
    /// `setVisualAids`: an edit to WHEN a dose fires must clear the old
    /// pending reminders and arm new ones, or the elder keeps being
    /// prompted at the time the family just moved. `loadSchedule` does
    /// exactly that — it drops every pending reminder and its escalation
    /// engine, re-creates them from the new times, and re-arms the
    /// platform alarms.
    ///
    /// The cost is that an in-flight acknowledgement is lost with the
    /// old schedule, and that is the right trade: the times under it
    /// changed. The alternative — keeping a reminder for a time that no
    /// longer exists — would fire a dose the family removed.
    ///
    /// A SLOT entry is refused outright (m-5, FR-MSR-018): its clock
    /// time comes from the household mapping, so a calendar-driven
    /// retime has nothing local to move — the refusal is the
    /// NON-interpretation (L1 §11), and the authority stays the
    /// settings editor. The refusal applies NOTHING and SURFACES itself,
    /// twice: the named PII-free `medication_retime_refused` event
    /// (metadata `entry_id_hash` and `slot` ONLY — never a name, a dose
    /// or a clock value, NFR-MSR-002) and the one-shot settings-note
    /// hook (IF-20, wired in T-020). No write, no re-arm, no observer
    /// call — a refusal never mutates state.
    ///
    /// Returns false when the entry is unknown (deleted in Settings
    /// since the plan was made), when the entry is a slot entry (the
    /// refusal above), or when the write fails.
    @discardableResult
    func setScheduleTimes(_ times: [DateComponents], entryId: UUID) -> Bool {
        guard let entry = entries[entryId] else { return false }
        if let slot = entry.slot {
            emit("medication_retime_refused",
                 metadata: ["entry_id_hash": idHash(entryId),
                            "slot": slot.rawValue],
                 outcome: "info")
            onSlotEntryRetimeRefused?(entryId)
            return false
        }
        var next = medicationEntries()
        guard let index = next.firstIndex(where: { $0.id == entryId }) else { return false }
        next[index] = entry.withScheduleTimes(times)
        loadSchedule(entries: next)
        return true
    }

    init(
        storage: EncryptedLocalStorage,
        alarmScheduler: PlatformAlarmScheduler,
        observabilityBus: ObservabilityBus,
        familyNotifier: FamilyNotifierProtocol,
        caregiverNotifySettings: CaregiverNotifySettings,
        visualAidStore: VisualAidStore? = nil,
        evidenceStore: MedicationEvidenceStore? = nil,
        slotClockStore: MedicationSlotClockStore? = nil,
        challengeTimeoutSeconds: TimeInterval = ConfirmationChallenge.defaultChallengeTimeoutSeconds
    ) {
        self.storage = storage
        self.alarmScheduler = alarmScheduler
        self.observabilityBus = observabilityBus
        self.familyNotifier = familyNotifier
        self.caregiverNotifySettings = caregiverNotifySettings
        self.visualAidStore = visualAidStore
        self.evidenceStore = evidenceStore
        // The mapping store is stateless over the storage seam, so
        // composing one here is equivalent to being handed the shared
        // instance — and it is what makes a house that has never opened
        // the slot settings read the ONE mapping record instead of a
        // second, divergent clock. No IO happens in init: the store reads
        // only when resolution asks (arming time).
        self.slotClockStore = slotClockStore ?? MedicationSlotClockStore(storage: storage)
        self.challengeTimeoutSeconds = challengeTimeoutSeconds
        self.doubleDoseDetector = DoubleDoseDetector()
    }

    // MARK: - Load Schedule

    func loadSchedule(entries newEntries: [MedicationEntry]) {
        entries.removeAll()
        engines.removeAll()
        pendingRemindersList.removeAll()

        for entry in newEntries {
            entries[entry.id] = entry
        }

        _ = storage.write(key: storageKeyEntries, value: newEntries)

        emit("schedule_loaded", metadata: ["entry_count": "\(newEntries.count)"])

        createPendingReminders(for: newEntries, now: Date())

        // Last, and after the local work is fully committed: an observer
        // must never see a half-applied schedule, and the local
        // reminders are the part the elder depends on — they are armed
        // before anything is offered to the share layer.
        onScheduleChanged?(newEntries)
    }

    // MARK: - Schedule All

    func scheduleAll() {
        restoreState()
        rearmAllPendingReminders()
    }

    // MARK: - Arming resolution feed (IF-11)

    /// The times this entry is armed at, resolved freshly at schedule /
    /// arming time (IF-11, FR-MSR-002).
    ///
    /// - A legacy entry (no slot) resolves to its stored times, VERBATIM:
    ///   the shipped behaviour stays first-class, and no mapping, clock or
    ///   guess is consulted for it.
    /// - A slot entry resolves through the household mapping (C1) — never
    ///   through its own stored `scheduleTimes`, which for a slot entry is
    ///   only the resolved-time MIRROR (D2). That mirror is not read here
    ///   and not written here: the save gate and the mapping-change re-arm
    ///   pass are its only writers.
    ///
    /// The mapping is read through the injected store on EVERY call, so a
    /// mapping edit reaches the next arming pass with nothing cached in
    /// between. Resolution happens at arming time only — never at fire
    /// time — so the firing path keeps its shipped shape.
    ///
    /// The one failure is `SlotClockError.indeterminate(slot:)`: a stored
    /// mapping value with no determinate hour/minute. It is returned
    /// as-is (fail-closed); the arming consumer arms NOTHING for that
    /// entry and surfaces the slot. No time is guessed, clamped or
    /// defaulted on any path.
    func resolvedScheduleTimes(for entry: MedicationEntry) -> Result<[DateComponents], SlotClockError> {
        guard let slot = entry.slot else {
            return .success(entry.scheduleTimes)
        }

        switch slotClockStore.load().resolve(slot: slot) {
        case .success(let time):
            return .success([time.dateComponents])
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - Guarded re-arm on mapping change (IF-12, m-1)

    /// Re-arms every slot entry against the household mapping as the
    /// store reads NOW — the walk the medicine-times save action runs
    /// after it has validated and persisted a new mapping (IF-9/T-020;
    /// this pass only ever runs behind that order and never validates or
    /// writes the mapping record itself).
    ///
    /// Per step, and why the order is the order:
    ///
    /// 1. Every SLOT entry is re-resolved through the arming feed
    ///    (IF-11). Legacy entries are not this pass's business: no
    ///    mapping ever produced their times, so nothing about them moves.
    /// 2. An entry with a finalize in flight — an ACTIVE confirmation
    ///    challenge — is kept WHOLE: no reminder replaced, no mirror
    ///    rewritten, no counter beyond the honest `keptLiveCount`.
    ///    Re-arming an entry under an acknowledgement sequence in
    ///    progress is the one thing this pass must never do (the HIGH
    ///    risk of IF-12).
    /// 3. A slot that cannot resolve under the new mapping arms NOTHING
    ///    for that entry (fail-closed, the arming feed's own rule): its
    ///    un-fired reminders are dropped and the slot is named — ordered,
    ///    deduplicated — in `unresolvedSlots`, with the PII-free
    ///    `medication_slot_unresolved` event (the slot and nothing else).
    /// 4. Fired reminders are NEVER moved: a live escalation keeps its
    ///    persisted time and its engine.
    /// 5. An un-fired reminder that no longer matches the new resolution
    ///    is replaced through the STANDARD creation path
    ///    (`createPendingReminders`) — there is no parallel arming code —
    ///    which persists the replacement set before it arms it
    ///    (FR-MSR-022). The entries' resolved-time mirrors (D2) are
    ///    rewritten and persisted BEFORE any alarm is touched.
    /// 6. A second pass under unchanged inputs replaces nothing — the
    ///    equality check finds every armed time and every mirror already
    ///    matching — and reports the clean no-op without a single write
    ///    or alarm call.
    ///
    /// One shipped-path side effect is worth knowing (and is not the
    /// guard failing): `createPendingReminders` re-asserts every pending
    /// alarm in the list, exactly as `loadSchedule` does today. A kept
    /// entry's alarm is therefore re-added at its OWN time — idempotent
    /// by reminder id, never moved, and its persisted state, engine and
    /// challenge all untouched.
    ///
    /// Failure honesty (m-1): `persistenceFailed` is set by either write
    /// this pass depends on, and a failed write arms nothing on the
    /// replaced set. `onScheduleChanged` fires last and only for a
    /// committed mirror rewrite — the same contract `loadSchedule` keeps,
    /// so the share layer sees exactly the version that was stored.
    @discardableResult
    func rearmForSlotClockChange() -> SlotClockRearmReport {
        var report = SlotClockRearmReport(rearmedCount: 0,
                                          keptLiveCount: 0,
                                          unresolvedSlots: [],
                                          persistenceFailed: false)
        let now = Date()

        // A stable order (name, then id): the same state always walks in
        // the same order, so the report is deterministic.
        let slotEntries = entries.values
            .filter { $0.slot != nil }
            .sorted {
                if $0.medicationName != $1.medicationName {
                    return $0.medicationName < $1.medicationName
                }
                return $0.id.uuidString < $1.id.uuidString
            }

        var rearmEntries: [MedicationEntry] = []
        var rewrittenById: [UUID: MedicationEntry] = [:]
        var replacedReminderIds: [UUID] = []
        var droppedReminderIds: [UUID] = []
        var unresolvedSeen: Set<MedicationSlot> = []

        // ---- Decide. No write, no alarm, no challenge touched yet. ----
        for entry in slotEntries {
            let reminders = pendingRemindersList.values
                .filter { $0.medicationEntryId == entry.id }

            // Guard (a): a finalize in flight keeps the entry whole.
            if hasActiveConfirmationChallenge(for: entry.id) {
                report.keptLiveCount += reminders.filter(isLiveReminder).count
                continue
            }

            switch resolvedScheduleTimes(for: entry) {
            case .failure(.indeterminate(let slot)):
                unresolvedSeen.insert(slot)
                emit("medication_slot_unresolved",
                     metadata: ["slot": slot.rawValue],
                     outcome: "unresolved")
                droppedReminderIds.append(contentsOf: reminders
                    .filter(isUnfiredReminder)
                    .map(\.id))

            case .success(let times):
                let unfired = reminders.filter(isUnfiredReminder)
                let staleUnfired = unfired.contains { !clockMatches($0.scheduledAt, times) }
                let staleMirror = !mirrorMatches(entry.scheduleTimes, times)
                // Idempotence: anything that already matches the new
                // resolution is left alone, so a second pass under the
                // same mapping replaces nothing at all.
                guard staleMirror || staleUnfired else { continue }
                let rewritten = entry.withScheduleTimes(times)
                if staleMirror { rewrittenById[entry.id] = rewritten }
                rearmEntries.append(rewritten)
                replacedReminderIds.append(contentsOf: unfired.map(\.id))
                report.keptLiveCount += reminders.filter {
                    isLiveReminder($0) && !isUnfiredReminder($0)
                }.count
            }
        }

        report.unresolvedSlots = MedicationSlot.allCases.filter { unresolvedSeen.contains($0) }

        // Nothing to replace and nothing to drop: the honest no-op, with
        // no write and no alarm call behind it.
        guard !rearmEntries.isEmpty || !droppedReminderIds.isEmpty else { return report }

        // ---- The resolved-time mirrors, persisted BEFORE any alarm (D2) ----
        if !rewrittenById.isEmpty {
            let payload = entries.values
                .map { rewrittenById[$0.id] ?? $0 }
                .sorted { $0.medicationName < $1.medicationName }
            guard case .success = storage.write(key: storageKeyEntries, value: payload) else {
                // Nothing armed on the replaced set, and the in-memory
                // entries keep the version that is actually stored.
                emit("entry_persistence_failed", metadata: [:])
                report.persistenceFailed = true
                return report
            }
            for (entryId, rewritten) in rewrittenById {
                entries[entryId] = rewritten
            }
        }

        // ---- Replace / drop the un-fired reminders, then persist, then arm ----
        for reminderId in replacedReminderIds + droppedReminderIds {
            pendingRemindersList.removeValue(forKey: reminderId)
            engines.removeValue(forKey: reminderId)
        }

        let statePersisted: Bool
        if !rearmEntries.isEmpty {
            let createdCount = createPendingReminders(for: rearmEntries, now: now)
            statePersisted = createdCount != nil
            report.rearmedCount = createdCount ?? 0
        } else {
            // Drop-only pass (every affected slot was unresolved): the
            // removal still has to be durable before any alarm is touched.
            statePersisted = persistReminders()
        }
        if !statePersisted {
            // The write that failed already reported itself
            // (`reminder_persistence_failed`); the report carries it too.
            report.persistenceFailed = true
        }

        // ---- Platform alarms last, and only over durable state ----
        if statePersisted {
            for reminderId in replacedReminderIds + droppedReminderIds {
                alarmScheduler.cancelReminder(reminderId: reminderId)
            }
        }

        // ---- The share layer last of all: the committed entry payload ----
        if !rewrittenById.isEmpty {
            onScheduleChanged?(medicationEntries())
        }

        return report
    }

    // MARK: - Acknowledge (Baseline FR-026 to FR-029)

    func acknowledge(entryId: UUID, at acknowledgedAt: Date) -> Result<Void, SafetyError> {
        guard let entry = entries[entryId] else {
            return .failure(.reminderPersistenceFailed)
        }

        guard let reminderId = activeReminderId(for: entryId),
              let engine = engines[reminderId] else {
            return .failure(.reminderPersistenceFailed)
        }

        let escalationResult = engine.acknowledge(at: acknowledgedAt)

        switch escalationResult.action {
        case .markAcknowledged:
            return finalizeAcknowledgement(
                entry: entry,
                entryId: entryId,
                at: acknowledgedAt,
                refireCount: engine.currentRefireCount
            )

        case .escalateToFamilyNotifier:
            recordMissedDose(entryId: entryId, entry: entry)
            return .success(())

        case .noAction, .fireReminder, .waitForAcknowledgement, .markMissed:
            return .success(())
        }
    }

    func acknowledgeWithConfirmation(
        entryId: UUID,
        at acknowledgedAt: Date,
        confirmationResponse: ConfirmationResponse
    ) -> Result<Void, SafetyError> {
        guard let entry = entries[entryId] else {
            return .failure(.reminderPersistenceFailed)
        }

        // If no challenge was issued yet for this entry, issue one now so the
        // caller-facing flow is: call once with a response → prompt appears →
        // call again with the answer. Silently accepting the first response
        // would defeat the dementia FR-D01 confirmation guarantee.
        let challenge = confirmationChallenges[entryId] ?? {
            let new = ConfirmationChallenge(challengeTimeoutSeconds: challengeTimeoutSeconds,
                                            locale: locale)
            confirmationChallenges[entryId] = new
            _ = new.start(
                medicationName: entry.medicationName,
                confirmationDescription: entry.confirmationDescription
            )
            emit("confirmation_challenged", metadata: ["entry_id_hash": idHash(entryId)])
            return new
        }()

        let confirmationAction = challenge.userResponds(with: confirmationResponse)

        switch confirmationAction {
        case .recordTaken:
            confirmationChallenges.removeValue(forKey: entryId)
            return checkDoubleDoseAndRecord(entry: entry, entryId: entryId, at: acknowledgedAt)

        case .reEnterEscalation:
            confirmationChallenges.removeValue(forKey: entryId)
            emit("confirmation_denied", metadata: ["entry_id_hash": idHash(entryId)])
            // The chain did not confirm (a "no" or a lapsed window), so the
            // held capture can never be claimed (IF-15, safety delta (c);
            // T-019): the hold is cleared and the stored file deleted — the
            // deny writes no record, and the evidence must not outlive it
            // as an orphan. PII-free classification only.
            discardPendingEvidence(for: entryId, outcome: "denied")
            return reEnterEscalation(entryId: entryId, entry: entry)

        case .noAction:
            return .success(())

        case .issueChallenge:
            return .success(())
        }
    }

    // MARK: - Trigger Reminder (called by platform alarm)

    func triggerReminder(for reminderId: UUID) {
        guard var reminder = pendingRemindersList[reminderId] else {
            return
        }

        guard let entry = entries[reminder.medicationEntryId] else {
            return
        }

        let engine: EscalationEngine
        if let existing = engines[reminderId] {
            engine = existing
        } else {
            engine = makeEngine(for: entry, from: reminder)
            engines[reminderId] = engine
            _ = engine.start()
        }

        // FIRST-fire gate, read BEFORE `lastFiredAt` below overwrites it
        // (caregiver event-notifications task, 2026-09-13). A re-fire is
        // the SAME event firing again — the alarm nagging an
        // unacknowledged dose — so the caregiver wants the event, not one
        // push per refire. `lastFiredAt` is the only "has this fired
        // before" bit the reminder carries, and it is already persisted
        // for the escalation engine's own reasons: no new per-event flag.
        let isFirstFire = reminder.lastFiredAt == nil

        let escalationResult = engine.reminderDelivered(at: Date())
        reminder.state = engine.toReminderState()
        reminder.lastFiredAt = Date()
        pendingRemindersList[reminderId] = reminder

        // Persist updated state
        persistReminders()

        emit("reminder_fired", metadata: [
            "entry_id_hash": idHash(entry.id),
            "refire_count": "\(engine.currentRefireCount)"
        ])

        if isFirstFire {
            notifyCaregiversOfFirstFire(entry: entry, reminder: reminder)
        }

        // Schedule ack-window expiry check
        if case .waitForAcknowledgement(let deadline) = escalationResult.action {
            alarmScheduler.scheduleAckDeadlineCheck(
                reminderId: reminderId,
                entryId: entry.id,
                deadline: deadline
            )
        }
    }

    /// Caregiver alert for the first delivery of a medication reminder
    /// (caregiver event-notifications task, 2026-09-13).
    ///
    /// The event id is the REMINDER id, not the medication entry id: a
    /// twice-daily entry produces two concurrent reminders, and "the
    /// morning dose" vs "the evening dose" has to be two distinct events
    /// for the caregiver reading the alert stream. The medication NAME is
    /// the alert's title (the elder's own words for it — the same string
    /// the confirmation challenge and the notification body use) and it
    /// stays in memory; the bus records only the hashed id and the kind.
    private func notifyCaregiversOfFirstFire(entry: MedicationEntry,
                                             reminder: ScheduledReminder) {
        guard caregiverNotifySettings.isEnabled(for: .medicationReminder) else {
            emit("caregiver_event_skipped",
                 metadata: ["kind": EventNotifyKind.medicationReminder.rawValue])
            return
        }
        let context = FamilyAlertContext(
            kind: .medicationReminder,
            eventIdHash: idHash(reminder.id),
            eventTitle: entry.medicationName,
            fireAt: reminder.scheduledAt
        )
        emit("caregiver_event_fired",
             metadata: ["kind": EventNotifyKind.medicationReminder.rawValue,
                        "event_id_hash": context.eventIdHash])
        Task { [familyNotifier] in
            _ = await familyNotifier.notifyAll(
                alertType: .eventReminder,
                at: Date(),
                context: context
            )
        }
    }

    // MARK: - Ack Deadline Expired (called by platform alarm)

    func handleAckDeadlineExpired(for reminderId: UUID) {
        guard let reminder = pendingRemindersList[reminderId] else {
            return
        }

        guard let entry = entries[reminder.medicationEntryId] else {
            return
        }

        guard let engine = engines[reminderId] else {
            return
        }

        let result = engine.ackWindowExpired(at: Date())

        switch result.action {
        case .fireReminder(let refireCount):
            emit("refire", metadata: [
                "entry_id_hash": idHash(entry.id),
                "refire_count": "\(refireCount)"
            ])

            var updated = reminder
            updated.refireCount = refireCount
            updated.state = engine.toReminderState()
            pendingRemindersList[reminderId] = updated
            persistReminders()

            if let nextFireAt = result.nextFireAt {
                alarmScheduler.scheduleReminder(
                    reminderId: reminderId,
                    entryId: entry.id,
                    medicationName: entry.medicationName,
                    visualAidURL: visualAidURL(for: entry),
                    at: nextFireAt
                )
            }

            // The reminder's FIRST re-fire decision (D10, FR-MSR-015):
            // the ack window elapsed and the escalation begins.
            // `refireCount == 1` is the engine's own count crossing 0→1
            // — state-derived, exactly once per reminder, and with no
            // stored per-event flag (the count IS the flag; `recover`
            // rebuilds it from the persisted reminder, so a relaunch
            // never replays the transition). Both channels are
            // UNCONDITIONAL: the first-fire opt-in gate governs the
            // delivery-day `eventReminder` alert (`triggerReminder`) and
            // is not touched here.
            if refireCount == 1 {
                notifySignificantEvent(.escalationStarted, entry: entry,
                                       at: Date(), fireAt: reminder.scheduledAt)
                raiseSignificantEvent(.escalationStarted, entry: entry,
                                      occurredAt: reminder.scheduledAt)
            }

        case .escalateToFamilyNotifier:
            recordMissedDose(entryId: entry.id, entry: entry)

        case .noAction, .markAcknowledged, .waitForAcknowledgement, .markMissed:
            break
        }
    }

    // MARK: - Start Confirmation Challenge (called after initial ack)

    /// Issues (or re-issues) the confirmation challenge for `entryId`.
    /// The returned prompt should be spoken to the user; the response then
    /// arrives via `acknowledgeWithConfirmation(entryId:at:confirmationResponse:)`,
    /// which reads the per-entry `ConfirmationChallenge` state left here.
    func startConfirmationChallenge(for entryId: UUID) -> String? {
        guard let entry = entries[entryId] else { return nil }

        let challenge = confirmationChallenges[entryId] ?? {
            let new = ConfirmationChallenge(challengeTimeoutSeconds: challengeTimeoutSeconds,
                                            locale: locale)
            confirmationChallenges[entryId] = new
            return new
        }()

        let action = challenge.start(
            medicationName: entry.medicationName,
            confirmationDescription: entry.confirmationDescription
        )

        if case .issueChallenge(let prompt) = action {
            emit("confirmation_challenged", metadata: ["entry_id_hash": idHash(entryId)])
            return prompt
        }
        return nil
    }

    // MARK: - Evidence hold (IF-15; T-019, C7.6)

    /// Registers the held capture for `entryId` (IF-15): the coordinator
    /// minted `logId` at capture time (T-021) and the store named the file
    /// by it, so the finalize that writes the record uses that SAME id —
    /// the `<logId>.jpg` scheme stays true everywhere (R-1(a)).
    ///
    /// R-3 FIRST, before anything is registered: a capture whose store
    /// completed after the chain finalized has no un-finalized reminder to
    /// attach to — the stored file is deleted and no hold is registered.
    /// The record stays honestly evidence-free; nothing is ever claimed.
    ///
    /// A re-capture REPLACES: the prior hold's file is deleted (no orphan)
    /// and the new capture takes the entry's one hold slot — unless the
    /// new capture IS that same file (the same log id re-held), which the
    /// caller just re-stored and which must not be deleted.
    ///
    /// Returns `true` when a hold is registered for the entry and `false`
    /// when the late-hold rule cleared the capture at registration — the
    /// honest outcome W6/T-021 observes. With a nil evidence store the
    /// hold still registers; only the file deletions are skipped (the
    /// composition obligation is stated at `init`).
    ///
    /// The PII-free `medication_evidence_discarded` event classifies every
    /// discard (`late_hold` here, `replaced` for a superseded capture) —
    /// the entry-id hash and nothing else (NFR-MSR-002).
    @discardableResult
    func holdPendingEvidence(logId: UUID, fileName: String, for entryId: UUID) -> Bool {
        guard activeReminderId(for: entryId) != nil else {
            deleteEvidenceFile(fileName, entryId: entryId)
            emit("medication_evidence_discarded",
                 metadata: ["entry_id_hash": idHash(entryId)],
                 outcome: "late_hold")
            return false
        }

        if let prior = pendingEvidenceHold[entryId], prior.fileName != fileName {
            deleteEvidenceFile(prior.fileName, entryId: entryId)
            emit("medication_evidence_discarded",
                 metadata: ["entry_id_hash": idHash(entryId)],
                 outcome: "replaced")
        }

        pendingEvidenceHold[entryId] = PendingEvidenceHold(logId: logId, fileName: fileName)
        return true
    }

    /// The record-surface attach (IF-15): sets `evidencePhotoFileName` on
    /// an EXISTING adherence log and persists it. This seam NEVER creates
    /// a record — an unknown `logId` returns the shipped failure without
    /// writing anything and without creating a log, so by construction a
    /// photo alone can never record a dose (safety delta (c)).
    ///
    /// A failed persist is never a claim: the just-stored file is deleted
    /// (no orphan) and the in-memory record is reverted to the version the
    /// store holds — to the previous name when that file still exists, or
    /// to evidence-free when the deleted file WAS that name. The shipped
    /// `.reminderPersistenceFailed` is returned on either failure arm.
    ///
    /// (`fileName` alone cannot resolve the file's entry directory, so the
    /// unknown-log arm deletes nothing — it cannot prove which stored file
    /// would be the orphan, and guessing is not this seam's business.)
    @discardableResult
    func attachEvidence(fileName: String, toLog logId: UUID) -> Result<Void, SafetyError> {
        guard let index = adherenceLog.firstIndex(where: { $0.id == logId }) else {
            return .failure(.reminderPersistenceFailed)
        }

        let previousName = adherenceLog[index].evidencePhotoFileName
        adherenceLog[index].evidencePhotoFileName = fileName

        if case .failure = storage.write(key: storageKeyAdherenceLog, value: adherenceLog) {
            deleteEvidenceFile(fileName, entryId: adherenceLog[index].medicationEntryId)
            adherenceLog[index].evidencePhotoFileName = previousName == fileName ? nil : previousName
            emit("medication_evidence_discarded",
                 metadata: ["entry_id_hash": idHash(adherenceLog[index].medicationEntryId)],
                 outcome: "attach_failed")
            return .failure(.reminderPersistenceFailed)
        }

        emit("medication_evidence_attached",
             metadata: ["entry_id_hash": idHash(adherenceLog[index].medicationEntryId)])
        return .success(())
    }

    // MARK: - Private

    private func finalizeAcknowledgement(
        entry: MedicationEntry,
        entryId: UUID,
        at acknowledgedAt: Date,
        refireCount: Int
    ) -> Result<Void, SafetyError> {
        let reminderId = activeReminderId(for: entryId)
        let scheduledAt = reminderId.flatMap { engines[$0]?.scheduledTime } ?? Date()
        // R-1(a): a held capture becomes the record's evidence under ONE
        // identity — the log this finalize writes carries the held log id
        // (the id the coordinator minted at capture time and the store
        // named the file by) and the held bare file name. Without a hold
        // this is exactly the shipped mint and an evidence-free record.
        let held = pendingEvidenceHold[entryId]
        let logEntry = MedicationAdherenceLog(
            id: held?.logId ?? UUID(),
            medicationEntryId: entryId,
            scheduledAt: scheduledAt,
            acknowledgedAt: acknowledgedAt,
            refireCount: refireCount,
            status: .acknowledged,
            familyAlerted: false,
            photoVerification: entry.photoVerificationEnabled ? .pending : .notRequired,
            confirmationPassed: true,
            confirmationDeniedAt: nil,
            evidencePhotoFileName: held?.fileName
        )

        let logIndex = adherenceLog.count
        adherenceLog.append(logEntry)

        // Persist adherence log
        if case .failure = storage.write(key: storageKeyAdherenceLog, value: adherenceLog) {
            // The record never landed, so the held file can never be
            // claimed: it is deleted (no orphan), the hold is cleared, and
            // the un-persisted in-memory record is stripped of the name —
            // a later successful write must not persist a claim to a file
            // that no longer exists. `intakeRecorded` does not fire (it
            // follows the write; T-016).
            if held != nil {
                discardPendingEvidence(for: entryId, outcome: "persistence_failed")
                adherenceLog[logIndex].evidencePhotoFileName = nil
            }
            return .failure(.reminderPersistenceFailed)
        }

        // The record claimed its evidence: the hold is cleared WITHOUT
        // deleting the file — it now belongs to the stored log.
        if held != nil {
            pendingEvidenceHold.removeValue(forKey: entryId)
            emit("medication_evidence_attached",
                 metadata: ["entry_id_hash": idHash(entryId)])
        }

        // The intakeRecorded significant event (T-016, L1 §9.1) — the
        // caregiver's record that the dose was actually taken. It fires
        // AFTER the write above, never instead of it: the failure arm
        // has already returned, so a dose is never announced as
        // recorded when the record did not land. Before the runtime
        // cleanup on purpose — the alert is about the record, not about
        // the reminder teardown — and unconditional (the first-fire
        // opt-in gate is the `eventReminder` path alone). Deliberately
        // NO `onSignificantEvent` call here: a recorded intake is not an
        // at-risk event and writes no calendar entry.
        notifySignificantEvent(.intakeRecorded, entry: entry,
                               at: acknowledgedAt, fireAt: scheduledAt)

        // Clean up pending reminder + its engine
        if let reminderId = reminderId {
            pendingRemindersList.removeValue(forKey: reminderId)
            alarmScheduler.cancelReminder(reminderId: reminderId)
            if let engine = engines.removeValue(forKey: reminderId) {
                _ = engine.markCompleted()
            }
        }

        persistReminders()

        emit("acknowledged", metadata: [
            "entry_id_hash": idHash(entryId),
            "refire_count": "\(refireCount)"
        ])

        return .success(())
    }

    private func checkDoubleDoseAndRecord(
        entry: MedicationEntry,
        entryId: UUID,
        at acknowledgedAt: Date
    ) -> Result<Void, SafetyError> {
        let doseCheck = doubleDoseDetector.check(
            medicationEntryId: entryId,
            windowHours: entry.doubleDoseWindowHours,
            adherenceLog: adherenceLog,
            now: acknowledgedAt
        )

        if doseCheck.isDuplicate {
            // Block double dose (FR-D03)
            let blockedLog = MedicationAdherenceLog(
                id: UUID(),
                medicationEntryId: entryId,
                scheduledAt: Date(),
                acknowledgedAt: acknowledgedAt,
                refireCount: 0,
                status: .doubleDoseAttempt,
                familyAlerted: false,
                photoVerification: .notRequired,
                confirmationPassed: false,
                confirmationDeniedAt: nil
            )
            adherenceLog.append(blockedLog)
            _ = storage.write(key: storageKeyAdherenceLog, value: adherenceLog)

            emit("double_dose_blocked", metadata: ["entry_id_hash": idHash(entryId)])

            // Alert caregiver asynchronously, with the context this
            // significant event now carries (T-016): the entry-id hash
            // is the correlation handle the payload is allowed to hold,
            // and the title stays in memory. `acknowledgedAt` is the
            // event instant — the attempt — which is also what the
            // blocked record above stamps as its own `scheduledAt`.
            notifySignificantEvent(.possibleDoubleDose, entry: entry,
                                   at: acknowledgedAt, fireAt: acknowledgedAt)
            raiseSignificantEvent(.possibleDoubleDose, entry: entry,
                                  occurredAt: acknowledgedAt)

            return .success(())  // Not a persistence failure -- dose intentionally blocked
        }

        // No duplicate -- record the dose. Per-entry challenge state was
        // already cleared by acknowledgeWithConfirmation before we got here.
        return finalizeAcknowledgement(
            entry: entry,
            entryId: entryId,
            at: acknowledgedAt,
            refireCount: activeReminderId(for: entryId).flatMap { engines[$0]?.currentRefireCount } ?? 0
        )
    }

    private func recordMissedDose(entryId: UUID, entry: MedicationEntry) {
        let reminderId = activeReminderId(for: entryId)
        let scheduledAt = reminderId.flatMap { engines[$0]?.scheduledTime } ?? Date()
        let logEntry = MedicationAdherenceLog(
            id: UUID(),
            medicationEntryId: entryId,
            scheduledAt: scheduledAt,
            acknowledgedAt: nil,
            refireCount: entry.maxRefireCount,
            status: .missed,
            familyAlerted: true,
            photoVerification: .notRequired,
            confirmationPassed: false,
            confirmationDeniedAt: nil
        )

        adherenceLog.append(logEntry)
        _ = storage.write(key: storageKeyAdherenceLog, value: adherenceLog)

        // Remove pending reminder + its engine
        if let reminderId = reminderId {
            pendingRemindersList.removeValue(forKey: reminderId)
            engines.removeValue(forKey: reminderId)
            alarmScheduler.cancelReminder(reminderId: reminderId)
        }
        persistReminders()

        emit("missed", metadata: ["entry_id_hash": idHash(entryId)])
        emit("family_alerted", metadata: ["entry_id_hash": idHash(entryId)])

        // Fire the caregiver channels asynchronously (T-016): the push
        // now carries the significant event's context, and the calendar
        // hook gets the same event as a value. Independent channels —
        // neither gates the other — and both unconditional. The context
        // and the event anchor share the missed dose's scheduledAt: the
        // occurrence the miss is about, already stamped into the record
        // above.
        notifySignificantEvent(.missedMedication, entry: entry,
                               at: Date(), fireAt: scheduledAt)
        raiseSignificantEvent(.missedMedication, entry: entry,
                              occurredAt: scheduledAt)
    }

    private func reEnterEscalation(entryId: UUID, entry: MedicationEntry) -> Result<Void, SafetyError> {
        guard let reminderId = activeReminderId(for: entryId),
              let engine = engines[reminderId] else {
            return .failure(.reminderPersistenceFailed)
        }

        // Find the next re-fire time
        let nextTime = engine.nextRefireTime(after: Date())

        if Date() < engine.escalationDeadline {
            alarmScheduler.scheduleReminder(
                reminderId: reminderId,
                entryId: entryId,
                medicationName: entry.medicationName,
                visualAidURL: visualAidURL(for: entry),
                at: nextTime
            )
        }

        return .success(())
    }

    /// Clears the entry's hold and deletes its stored file — idempotent
    /// (no hold = no-op: nothing happened, nothing is emitted). Fail-soft
    /// toward truth: a store `.removeFailed` is swallowed (the file
    /// survives; the hold does not) and a nil store skips the deletion
    /// while the claim is still cleared. Every discard is classified by
    /// the PII-free `medication_evidence_discarded` event.
    private func discardPendingEvidence(for entryId: UUID, outcome: String) {
        guard let hold = pendingEvidenceHold.removeValue(forKey: entryId) else { return }
        deleteEvidenceFile(hold.fileName, entryId: entryId)
        emit("medication_evidence_discarded",
             metadata: ["entry_id_hash": idHash(entryId)],
             outcome: outcome)
    }

    /// Deletes one stored evidence file, fail-soft: an absent store, an
    /// absent file and a `.removeFailed` all leave the caller's flow
    /// untouched — the honest truth is that the file may survive, and
    /// nothing here may turn that into a crash or a blocked
    /// acknowledgement.
    private func deleteEvidenceFile(_ fileName: String, entryId: UUID) {
        guard let evidenceStore else { return }
        _ = evidenceStore.delete(fileName: fileName, entryId: entryId)
    }

    private func restoreState() {
        // Only hydrate from disk once per process. `scheduleAll()` is called on
        // every BGTask wake; a second restore would clobber in-memory mutations
        // (e.g. an acknowledgement received but not yet persisted).
        guard !didRestore else { return }
        didRestore = true

        if let storedReminders: [String: ScheduledReminder] = try? storage.read(
            key: storageKeyReminders,
            type: [String: ScheduledReminder].self
        ).get() {
            var restored: [UUID: ScheduledReminder] = [:]
            for (key, reminder) in storedReminders {
                if let uuid = UUID(uuidString: key) {
                    restored[uuid] = reminder
                }
            }
            pendingRemindersList = restored
        }

        if let storedLog: [MedicationAdherenceLog] = try? storage.read(
            key: storageKeyAdherenceLog,
            type: [MedicationAdherenceLog].self
        ).get() {
            adherenceLog = storedLog
        }

        if let storedEntries: [MedicationEntry] = try? storage.read(
            key: storageKeyEntries,
            type: [MedicationEntry].self
        ).get() {
            entries = Dictionary(uniqueKeysWithValues: storedEntries.map { ($0.id, $0) })
        }
    }

    private func rearmAllPendingReminders() {
        let now = Date()

        for (reminderId, reminder) in pendingRemindersList {
            guard reminder.state != .acknowledged,
                  reminder.state != .missed,
                  reminder.state != .completed else {
                continue
            }

            guard let entry = entries[reminder.medicationEntryId] else {
                continue
            }

            // Never-fire reminders (state == .pending) are future doses.
            // They must be re-armed for their scheduled time, NOT fired now
            // — otherwise every app relaunch prompts early medication.
            if reminder.state == .pending {
                if reminder.scheduledAt > now {
                    alarmScheduler.scheduleReminder(
                        reminderId: reminderId,
                        entryId: entry.id,
                        medicationName: entry.medicationName,
                        visualAidURL: visualAidURL(for: entry),
                        at: reminder.scheduledAt
                    )
                } else {
                    // Scheduled time passed while the app was dead and the
                    // platform alarm never delivered (or was lost). Start the
                    // escalation cycle now so the dose is not silently skipped.
                    triggerReminder(for: reminderId)
                }
                continue
            }

            let engine = makeEngine(for: entry, from: reminder)
            engines[reminderId] = engine

            let recoveryResult = engine.recover(from: reminder, at: now)

            switch recoveryResult.action {
            case .fireReminder:
                // Fired before the kill; delivery not confirmed. Re-fire now
                // if still within the escalation window (FR-029).
                if now < engine.escalationDeadline {
                    triggerReminder(for: reminderId)
                } else {
                    recordMissedDose(entryId: entry.id, entry: entry)
                }

            case .escalateToFamilyNotifier:
                if now >= engine.escalationDeadline {
                    recordMissedDose(entryId: entry.id, entry: entry)
                }

            case .noAction, .markAcknowledged, .waitForAcknowledgement, .markMissed:
                break
            }
        }
    }

    /// The scheduler's EXISTING challenge-active predicate, reused by the
    /// re-arm guard — no new per-entry flag is minted: a finalize is in
    /// flight for `entryId` exactly while the shipped
    /// `ConfirmationChallenge` for it sits in `.awaitingResponse` with
    /// its window still open.
    ///
    /// The deadline is part of the predicate on purpose. A challenge past
    /// its deadline is a LAPSED window, not a live finalize: the machine's
    /// own `userResponds` treats any later answer as timed out (re-entering
    /// escalation over the untouched fired reminder), and the coordinator
    /// has already cleared its pended question on the same window (R-2's
    /// single source). Treating a lapsed challenge as active would lock
    /// that dose out of every future mapping change — a mapping edit the
    /// family will never see take effect.
    private func hasActiveConfirmationChallenge(for entryId: UUID) -> Bool {
        guard let challenge = confirmationChallenges[entryId],
              case .awaitingResponse(let deadline) = challenge.state else {
            return false
        }
        return Date() <= deadline
    }

    /// Whether the reminder is a FUTURE dose the standard creation path
    /// owns: never delivered (`.pending`) and never fired
    /// (`lastFiredAt` unset). Only these may be replaced by a re-arm pass.
    private func isUnfiredReminder(_ reminder: ScheduledReminder) -> Bool {
        reminder.state == .pending && reminder.lastFiredAt == nil
    }

    /// Whether the reminder still has work to do — a future dose or a
    /// live escalation. Every other state is history: the pass neither
    /// replaces it nor counts it as kept.
    private func isLiveReminder(_ reminder: ScheduledReminder) -> Bool {
        reminder.state == .pending || reminder.state == .fired
    }

    /// Whether `date`'s wall-clock hour and minute equal one of the
    /// resolved times. This is the equality the idempotence rule reads:
    /// the reminder's armed instant was built from the same hour/minute
    /// (`nextOccurrence`), so a matching pair means "this dose already
    /// resolves to the current mapping".
    private func clockMatches(_ date: Date, _ resolvedTimes: [DateComponents]) -> Bool {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return resolvedTimes.contains { $0.hour == hour && $0.minute == minute }
    }

    /// Whether a stored mirror already equals the fresh resolution —
    /// compared as clock values, the only components either side carries
    /// (D2: the mirror is written as the resolved hour/minute).
    private func mirrorMatches(_ stored: [DateComponents],
                               _ resolvedTimes: [DateComponents]) -> Bool {
        stored.count == resolvedTimes.count
            && zip(stored, resolvedTimes).allSatisfy {
                $0.hour == $1.hour && $0.minute == $1.minute
            }
    }

    /// Creates (and persists, then arms) one pending reminder per resolved
    /// time of each given entry, through the ONE arming path every writer
    /// shares. Returns the number of reminders it created AND armed, or
    /// nil when the persistence the arming depends on failed (in which
    /// case nothing was armed). Callers that only want the side effect
    /// ignore the result (`loadSchedule`); the re-arm pass reads it so its
    /// report can be honest.
    @discardableResult
    private func createPendingReminders(for entries: [MedicationEntry], now: Date) -> Int? {
        let calendar = Calendar.current
        var createdCount = 0

        for entry in entries {
            // The arming times come from the resolution feed (IF-11): a
            // slot entry is resolved against the household mapping NOW,
            // and a legacy entry keeps its stored times verbatim.
            let scheduleTimes: [DateComponents]
            switch resolvedScheduleTimes(for: entry) {
            case .success(let resolved):
                scheduleTimes = resolved
            case .failure(.indeterminate(let slot)):
                // Fail-closed: this entry arms nothing and no time is
                // guessed for it. The slot is the ONLY thing surfaced —
                // no medication name, no quantity, no clock value
                // (NFR-MSR-002). Other entries in the pass are unaffected:
                // one unresolvable slot must never take the whole
                // household's schedule down with it.
                emit("medication_slot_unresolved",
                     metadata: ["slot": slot.rawValue],
                     outcome: "unresolved")
                continue
            }

            for scheduleTime in scheduleTimes {
                guard let scheduledAt = nextOccurrence(of: scheduleTime, after: now, calendar: calendar) else {
                    continue
                }

                let reminder = ScheduledReminder(
                    id: UUID(),
                    medicationEntryId: entry.id,
                    scheduledAt: scheduledAt,
                    refireCount: 0,
                    escalationDeadline: scheduledAt.addingTimeInterval(TimeInterval(entry.escalationWindowMinutes * 60)),
                    state: .pending,
                    lastFiredAt: nil,
                    acknowledgedAt: nil
                )
                pendingRemindersList[reminder.id] = reminder
                // Engines are keyed per-reminder (C4) — a twice-daily entry
                // gets two independent escalation engines.
                engines[reminder.id] = makeEngine(for: entry, from: reminder)
                createdCount += 1
            }
        }

        // Persist BEFORE arming — the order is the invariant, not an
        // implementation detail: the elder's reminder state (with its
        // resolved exact time) is on disk before the platform alarm
        // exists, so an interruption between the two can only ever re-arm
        // a dose, never lose one. A failed write arms nothing.
        guard persistReminders() else { return nil }

        for reminder in pendingRemindersList.values {
            guard let entry = self.entries[reminder.medicationEntryId] else { continue }
            alarmScheduler.scheduleReminder(
                reminderId: reminder.id,
                entryId: entry.id,
                medicationName: entry.medicationName,
                visualAidURL: visualAidURL(for: entry),
                at: reminder.scheduledAt
            )
        }

        return createdCount
    }

    private func nextOccurrence(of time: DateComponents, after now: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second ?? 0

        guard let today = calendar.date(from: components) else { return nil }
        if today > now {
            return today
        }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }

    private func makeEngine(for entry: MedicationEntry, from reminder: ScheduledReminder) -> EscalationEngine {
        EscalationEngine(
            scheduledTime: reminder.scheduledAt,
            ackWindowMinutes: entry.ackWindowMinutes,
            maxRefireCount: entry.maxRefireCount,
            escalationWindowMinutes: entry.escalationWindowMinutes
        )
    }

    /// The reminder currently tracking `entryId`'s dose. An entry with
    /// multiple daily times may have several pending reminders; the active
    /// one is the earliest-scheduled. Engine lookups must go through this
    /// rather than assuming `engines[entryId]` exists (C4).
    private func activeReminderId(for entryId: UUID) -> UUID? {
        pendingRemindersList
            .filter { $0.value.medicationEntryId == entryId }
            .sorted { $0.value.scheduledAt < $1.value.scheduledAt }
            .first?.key
    }

    @discardableResult
    private func persistReminders() -> Bool {
        let dict = pendingRemindersList.reduce(into: [String: ScheduledReminder]()) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
        switch storage.write(key: storageKeyReminders, value: dict) {
        case .success:
            return true
        case .failure:
            emit("reminder_persistence_failed", metadata: [:])
            return false
        }
    }

    // MARK: - Significant events (T-016, C7.3–C7.4)

    /// The notifier half of a significant event (FR-MSR-015): one
    /// context-carrying `notifyAll`, asynchronous exactly like the
    /// shipped medication alerts, UNCONDITIONAL (the four significant
    /// types are not toggle-gated — the first-fire opt-in governs the
    /// `eventReminder` path alone).
    ///
    /// The context is the honesty seam T-011 built: `entry_id_hash` is
    /// the only medication reference the payload is allowed to carry,
    /// and the title (`eventTitle`) lives in memory only — never
    /// serialized, never logged. `fireAt` is the dose occurrence the
    /// event is about, which is not always the instant the alert is
    /// sent (an event observed late still says WHEN it happened).
    private func notifySignificantEvent(_ alertType: FamilyAlertType,
                                        entry: MedicationEntry,
                                        at timestamp: Date,
                                        fireAt: Date) {
        let context = FamilyAlertContext(
            kind: .medicationReminder,
            eventIdHash: idHash(entry.id),
            eventTitle: entry.medicationName,
            fireAt: fireAt
        )
        Task { [familyNotifier] in
            let _ = await familyNotifier.notifyAll(
                alertType: alertType,
                at: timestamp,
                context: context
            )
        }
    }

    /// The calendar half of an at-risk significant event (IF-20, C7.4):
    /// exposes the event as a plain value and invokes the hook
    /// synchronously, main thread by the scheduler's contract. The hook
    /// is the ONLY consumer (the write itself lives in
    /// `CalendarShareService`, wired at composition in T-020) and an
    /// unset hook is a no-op while local truth stays untouched. Called
    /// at the three at-risk sites and nowhere else — `intakeRecorded`
    /// writes no calendar entry, so it never reaches here.
    private func raiseSignificantEvent(_ kind: SignificantMedicationEvent.Kind,
                                       entry: MedicationEntry,
                                       occurredAt: Date) {
        onSignificantEvent?(
            SignificantMedicationEvent(kind: kind,
                                       entryId: entry.id,
                                       occurredAt: occurredAt),
            entry
        )
    }

    // MARK: - Observability

    private func idHash(_ id: UUID) -> String {
        IdHashing.shortHash(of: id)
    }

    /// The events below are classification only — `entry_id_hash` and
    /// categorical fields, never a medication name, a dose, a clock value
    /// or any other content (NFR-MSR-002). `outcome` is defaulted so every
    /// shipped emission keeps its exact payload and only the paths that
    /// have something else to say (an unresolved slot) deviate.
    private func emit(_ eventType: String, metadata: [String: String],
                      outcome: String = "success") {
        observabilityBus.emit(ObservabilityEvent(
            component: "medication_scheduler",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: metadata
        ))
    }
}
