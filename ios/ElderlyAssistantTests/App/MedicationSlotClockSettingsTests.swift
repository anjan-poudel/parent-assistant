import XCTest
@testable import ElderlyAssistant

/// T-020 — the "Medicine times" settings surface and its one-shot note
/// (design-l2 IF-9/IF-10, review m-1/m-5; FR-MSR-002, NFR-MSR-004/005).
///
/// What this suite pins, and why each half is worth a named test:
///
///  - **IF-9's order — validate, persist, re-arm.** A mapping with an
///    indeterminate slot is refused BEFORE anything is written; a store
///    write that fails is reported honestly; and after a real save the
///    family's edit reaches the ARMED state (reminders resolve at the
///    new time, the mirror follows, the stale reminder is replaced) —
///    with the report's four facts traveling back into the result's line
///    keys and nothing claimed beside them (m-1).
///  - **The reset.** "Back to the usual times" restores the DOCUMENTED
///    defaults (OD-1: morning 08:00, afternoon 13:00, evening 19:00),
///    seed and save in one tap, and the seed-to-save circle
///    round-trips.
///  - **The m-5 one-shot note.** A refused slot retime surfaces it; the
///    dismissal persists through the SETTINGS seam and survives a
///    relaunch; presentation stays transient.
///  - **Composition wiring.** Both scheduler hooks are assigned beside
///    `onScheduleChanged`, the calendar hook routes through the T-015
///    write on main and consults NO caregiver notification toggle
///    (T-016's flag), and the retime hook is DRIVEN end to end.
///  - **The card's words.** Every clock the card shows is `SpokenTime`;
///    not one string interpolation exists on the card region; the read
///    seam is the coordinator's ONE accessor and the view composes no
///    store of its own (the T-018 deviation-3 follow-up); every consumed
///    catalog key resolves in both shipped languages; the 44pt /
///    typography floors hold by token counts.
///
/// Recipe (the `MedicationSavePlumbingTests` convention): the real
/// coordinator over the real scheduler, the household-mapping store over
/// an in-memory channel via the T-017 constructor seam — which the
/// T-020 composition passes through to the scheduler, so the save gate
/// and the re-arm read the ONE record — the scheduler's schedule seeded
/// and restored in `defer`, and the m-5 dismissal key backed up and
/// restored around every test.
final class MedicationSlotClockSettingsTests: XCTestCase {

    // MARK: - Named tests (T-020)

    /// IF-9's two refusal points, both BEFORE any effect: an
    /// indeterminate mapping fails validation first, and a failing store
    /// write is reported honestly — in both cases nothing is persisted,
    /// the stored mapping is unchanged, and no re-arm runs (proved by a
    /// deliberately stale mirror the pass would have rewritten).
    @MainActor
    func testSaveValidatesBeforePersist() throws {
        let seeded = MedicationSlotClock(morning: TimeOfDay(hour: 6, minute: 45),
                                         afternoon: TimeOfDay(hour: 12, minute: 30),
                                         evening: TimeOfDay(hour: 21, minute: 5))
        let clockStorage = SlotClockSettingsTestStorage()
        install(seeded, into: clockStorage)
        // The mirror (08:00) is deliberately STALE against the stored
        // mapping (06:45): a re-arm would rewrite it, so its survival is
        // how this test sees that no re-arm ran.
        let stale = slotEntry(slot: .morning, mirrorHour: 8, mirrorMinute: 0)
        let (coordinator, scheduler, restore) = try XCTUnwrap(
            makeSeededCoordinator(clockStorage: clockStorage, entries: [stale]))
        defer { restore() }

        // Refusal point 1: validation (IF-2) — hour 24 is indeterminate.
        let invalid = MedicationSlotClock(morning: TimeOfDay(hour: 24, minute: 0),
                                          afternoon: seeded.afternoon,
                                          evening: seeded.evening)
        let invalidResult = coordinator.saveMedicationSlotClock(invalid)

        XCTAssertFalse(invalidResult.persisted,
                       "an indeterminate mapping must be refused before any write (IF-9/IF-2)")
        XCTAssertEqual(invalidResult.invalidSlot, .morning,
                       "the offending slot rides the result")
        XCTAssertEqual(invalidResult.rearmedCount, 0)
        XCTAssertEqual(invalidResult.keptLiveCount, 0)
        XCTAssertTrue(invalidResult.unresolvedSlots.isEmpty)
        XCTAssertFalse(invalidResult.persistenceFailed)
        XCTAssertEqual(invalidResult.lineKeys, [SlotClockSaveResult.saveFailedLineKey],
                       "a refused save says exactly one thing — the failure line")
        XCTAssertEqual(coordinator.currentMedicationSlotClock(), seeded,
                       "nothing was persisted — the stored mapping is unchanged")

        // Refusal point 2: the store write itself fails (IF-4). The
        // mapping is valid, so validation passes; the failure is the
        // store's, and it must be just as honest.
        let valid = MedicationSlotClock(morning: TimeOfDay(hour: 7, minute: 30),
                                        afternoon: seeded.afternoon,
                                        evening: seeded.evening)
        clockStorage.failWrites = true
        let failedResult = coordinator.saveMedicationSlotClock(valid)
        clockStorage.failWrites = false

        XCTAssertFalse(failedResult.persisted, "a failed store write persists nothing (IF-9/IF-4)")
        XCTAssertNil(failedResult.invalidSlot, "validation itself passed — the store refused")
        XCTAssertTrue(failedResult.persistenceFailed, "the failure is carried, never swallowed")
        XCTAssertEqual(failedResult.rearmedCount, 0, "nothing may arm against a mapping that was not stored")
        XCTAssertEqual(failedResult.lineKeys, [SlotClockSaveResult.saveFailedLineKey])
        XCTAssertEqual(coordinator.currentMedicationSlotClock(), seeded,
                       "the stored mapping survives the failed write unchanged")

        // No re-arm ran on either refusal: the stale mirror is untouched,
        // and the schedule gained nothing.
        let after = try XCTUnwrap(scheduler.medicationEntry(for: stale.id))
        XCTAssertEqual(after.scheduleTimes.first?.hour, 8,
                       "a stale mirror would have been rewritten to 06:45 had the pass run")
        XCTAssertEqual(after.scheduleTimes.first?.minute, 0)
        XCTAssertEqual(scheduler.medicationEntries().count, 1)
    }

    /// The save's happy path end to end (acceptance: morning set to
    /// 07:30): the mapping persists, the re-arm runs against the mapping
    /// JUST stored, the entry's reminders resolve at 07:30, the stale
    /// reminder is replaced (never edited in place), the resolved-time
    /// mirror follows, and the result's lines follow the report exactly
    /// (the clean commit line alone, m-1 — with all four report shapes
    /// pinned through the pure mapper).
    @MainActor
    func testSaveTriggersRearmAndSurfacesReport() throws {
        let clockStorage = SlotClockSettingsTestStorage()
        install(.default, into: clockStorage)
        let morning = slotEntry(name: "Amlodipine", slot: .morning,
                                mirrorHour: 8, mirrorMinute: 0)
        let (coordinator, scheduler, restore) = try XCTUnwrap(
            makeSeededCoordinator(clockStorage: clockStorage, entries: [morning]))
        defer { restore() }

        let initial = try XCTUnwrap(
            scheduler.pendingReminders.first { $0.medicationEntryId == morning.id },
            "the morning dose must be armed under the default mapping")
        XCTAssertEqual(Calendar.current.component(.hour, from: initial.scheduledAt), 8)

        let retimed = MedicationSlotClock(morning: TimeOfDay(hour: 7, minute: 30),
                                          afternoon: MedicationSlotClock.defaultAfternoonTime,
                                          evening: MedicationSlotClock.defaultEveningTime)
        let result = coordinator.saveMedicationSlotClock(retimed)

        XCTAssertTrue(result.persisted, "a valid mapping persists (IF-9 step 2)")
        XCTAssertNil(result.invalidSlot)
        XCTAssertGreaterThanOrEqual(result.rearmedCount, 1,
                                    "the stale reminder was replaced through the standard path (IF-12)")
        XCTAssertEqual(result.keptLiveCount, 0, "no finalize is in flight — the honest zero")
        XCTAssertTrue(result.unresolvedSlots.isEmpty)
        XCTAssertFalse(result.persistenceFailed)
        XCTAssertEqual(result.lineKeys, [SlotClockSaveResult.savedLineKey],
                       "a clean commit says exactly one thing")

        // The mapping is stored through the ONE seam…
        XCTAssertEqual(coordinator.currentMedicationSlotClock(), retimed)
        // …the entry RESOLVES at 07:30 (the acceptance: the family's edit
        // reaches the armed state, twice identical — FR-MSR-002)…
        let updated = try XCTUnwrap(scheduler.medicationEntry(for: morning.id))
        guard case .success(let resolution) = scheduler.resolvedScheduleTimes(for: updated),
              case .success(let second) = scheduler.resolvedScheduleTimes(for: updated) else {
            return XCTFail("a slot entry under a valid mapping must resolve")
        }
        XCTAssertEqual(resolution.first?.hour, 7)
        XCTAssertEqual(resolution.first?.minute, 30)
        XCTAssertEqual(resolution, second, "resolution is deterministic")
        // …the mirror follows (D2)…
        XCTAssertEqual(updated.scheduleTimes.first?.hour, 7)
        XCTAssertEqual(updated.scheduleTimes.first?.minute, 30)
        // …and the reminder was REPLACED at the new time.
        let rearmed = try XCTUnwrap(
            scheduler.pendingReminders.first { $0.medicationEntryId == morning.id })
        XCTAssertNotEqual(rearmed.id, initial.id, "the stale reminder is replaced, never edited in place")
        XCTAssertEqual(Calendar.current.component(.hour, from: rearmed.scheduledAt), 7)
        XCTAssertEqual(Calendar.current.component(.minute, from: rearmed.scheduledAt), 30)

        // IF-9's order, pinned in the shipped code: validate, then
        // persist, then re-arm — never any other order.
        let if9 = collapsed(coordinatorRegion("func saveMedicationSlotClock(",
                                              to: "func surfaceMedicationRetimeNote"))
        assertAppearsInOrder(["MedicationSlotClock.validate(clock)",
                              "slotClockStore.save(clock)",
                              "rearmForSlotClockChange()"],
                             in: if9)

        // The pure mapper: all four report shapes, failure first (m-1).
        XCTAssertEqual(
            SlotClockSaveResult.lineKeys(for: SlotClockRearmReport(
                rearmedCount: 1, keptLiveCount: 0,
                unresolvedSlots: [], persistenceFailed: false)),
            [SlotClockSaveResult.savedLineKey])
        XCTAssertEqual(
            SlotClockSaveResult.lineKeys(for: SlotClockRearmReport(
                rearmedCount: 0, keptLiveCount: 0,
                unresolvedSlots: [], persistenceFailed: true)),
            [SlotClockSaveResult.saveFailedLineKey])
        XCTAssertEqual(
            SlotClockSaveResult.lineKeys(for: SlotClockRearmReport(
                rearmedCount: 0, keptLiveCount: 0,
                unresolvedSlots: [.evening], persistenceFailed: false)),
            [SlotClockSaveResult.unresolvedLineKey])
        XCTAssertEqual(
            SlotClockSaveResult.lineKeys(for: SlotClockRearmReport(
                rearmedCount: 0, keptLiveCount: 0,
                unresolvedSlots: [.evening], persistenceFailed: true)),
            [SlotClockSaveResult.saveFailedLineKey, SlotClockSaveResult.unresolvedLineKey],
            "a failed write leads the lines — the unresolved fact follows it")
    }

    /// "Back to the usual times" means the DOCUMENTED defaults (OD-1) —
    /// the constants, the seed-to-save circle the button makes, and the
    /// save that lands them — plus the source pins that keep the button
    /// label, the reset member and the mapping read seam from drifting.
    @MainActor
    func testResetToDefaultsRestoresDocumentedTimes() throws {
        // The documented defaults, as values.
        XCTAssertEqual(MedicationSlotClock.defaultMorningTime, TimeOfDay(hour: 8, minute: 0),
                       "morning 08:00 (OD-1)")
        XCTAssertEqual(MedicationSlotClock.defaultAfternoonTime, TimeOfDay(hour: 13, minute: 0),
                       "afternoon 13:00 (OD-1)")
        XCTAssertEqual(MedicationSlotClock.defaultEveningTime, TimeOfDay(hour: 19, minute: 0),
                       "evening 19:00 (OD-1)")

        // The reset's seed-to-save circle: a picker seed built from
        // `.default` reads back as `.default` — the button cannot drift
        // from the defaults — and any determinate mapping round-trips.
        let calendar = Calendar.current
        XCTAssertEqual(
            MedicationScheduleSettingsView.MedicineTimesDraft
                .loaded(from: .default, now: Date(), calendar: calendar)
                .clock(calendar: calendar),
            .default)
        let moved = MedicationSlotClock(morning: TimeOfDay(hour: 6, minute: 45),
                                        afternoon: TimeOfDay(hour: 12, minute: 30),
                                        evening: TimeOfDay(hour: 21, minute: 5))
        XCTAssertEqual(
            MedicationScheduleSettingsView.MedicineTimesDraft
                .loaded(from: moved, now: Date(), calendar: calendar)
                .clock(calendar: calendar),
            moved, "the seed and readback round-trip any determinate mapping")

        // The reset's save half, behaviorally: the store starts at a
        // non-default mapping, and the reset's save lands the defaults.
        let clockStorage = SlotClockSettingsTestStorage()
        install(moved, into: clockStorage)
        let (coordinator, _, restore) = try XCTUnwrap(
            makeSeededCoordinator(clockStorage: clockStorage, entries: []))
        defer { restore() }
        XCTAssertEqual(coordinator.currentMedicationSlotClock(), moved)

        let result = coordinator.saveMedicationSlotClock(.default)
        XCTAssertTrue(result.persisted, "the reset saves like any other mapping (IF-9)")
        XCTAssertEqual(result.lineKeys, [SlotClockSaveResult.savedLineKey])
        XCTAssertEqual(coordinator.currentMedicationSlotClock(), .default,
                       "after the reset the stored mapping IS the documented default")

        // Source pins: the button says the reset key, its action calls
        // the reset member, and that member seeds from `.default` and
        // saves in the same tap.
        let view = settingsViewSource()
        let button = collapsed(region("private var medicineTimesResetButton",
                                      to: "private var medicineTimesSaveButton", in: view))
        XCTAssertTrue(button.contains("\"settings.meds.times.reset\""),
                      "the reset control carries the shipped reset key")
        let reset = collapsed(region("private func resetMedicineTimes()",
                                     to: "static func medicineTimesLabelKey", in: view))
        XCTAssertTrue(reset.contains("MedicineTimesDraft.loaded(from: MedicationSlotClock.default"),
                      "the reset seeds the DOCUMENTED defaults — one tap reaches the named state")
        XCTAssertTrue(reset.contains("saveMedicineTimes()"),
                      "and saves them in the same tap — never a two-step edit")

        // The view reads the mapping through the coordinator's ONE
        // accessor (the T-018 deviation-3 follow-up): the model switch
        // and the card can never hold a divergent clock, and no store is
        // composed anywhere in this file.
        let mapping = collapsed(region("private func householdMapping()",
                                       to: "private var slotDoseRows", in: view))
        XCTAssertTrue(mapping.contains("coordinator.currentMedicationSlotClock()"),
                      "the model switch reads through the coordinator's accessor")
        XCTAssertFalse(mapping.contains("MedicationSlotClockStore(storage:"),
                       "the view composes no second store for the switch")
        XCTAssertFalse(view.contains("MedicationSlotClockStore(storage:"),
                       "no store is composed anywhere in the Settings leaf — the seam is the coordinator's")
    }

    /// The m-5 one-shot note's state machine: silent until a refusal
    /// surfaces it, dismissed into the SETTINGS seam, never resurrected,
    /// and the dismissal survives a fresh coordinator (the next launch).
    @MainActor
    func testRetimeNoteAppearsOnceAndDismissalPersists() throws {
        let clockStorage = SlotClockSettingsTestStorage()
        let (coordinator, _, restore) = try XCTUnwrap(
            makeSeededCoordinator(clockStorage: clockStorage, entries: []))
        defer { restore() }

        XCTAssertFalse(coordinator.medicationRetimeNotePresented,
                       "the note starts silent — nothing has been refused")
        XCTAssertFalse(coordinator.medicationRetimeNoteDismissed,
                       "fresh install: nothing dismissed")

        coordinator.surfaceMedicationRetimeNote()
        XCTAssertTrue(coordinator.medicationRetimeNotePresented,
                      "a refusal surfaces the note")

        coordinator.dismissMedicationRetimeNote()
        XCTAssertFalse(coordinator.medicationRetimeNotePresented, "dismissal takes it down")
        XCTAssertTrue(coordinator.medicationRetimeNoteDismissed)
        XCTAssertTrue(SettingsPersistence.shared.bool(forKey: Self.retimeNoteKey),
                      "the dismissal persists through the SETTINGS seam")

        // One-shot: surfacing again after dismissal is a no-op.
        coordinator.surfaceMedicationRetimeNote()
        XCTAssertFalse(coordinator.medicationRetimeNotePresented,
                       "a dismissed note never returns, .v1 for good (IF-10)")

        // A fresh coordinator (the next launch) reads the dismissal back
        // and stays silent for the new session.
        let next = try XCTUnwrap(
            makeSeededCoordinator(clockStorage: clockStorage, entries: []))
        defer { next.restore() }
        XCTAssertTrue(next.coordinator.medicationRetimeNoteDismissed,
                      "the dismissal survives a relaunch — read back in init")
        XCTAssertFalse(next.coordinator.medicationRetimeNotePresented,
                       "presentation is transient — a launch never resurrects the note")
        next.coordinator.surfaceMedicationRetimeNote()
        XCTAssertFalse(next.coordinator.medicationRetimeNotePresented)
    }

    /// The refusal hook, DRIVEN end to end: a slot entry's retime is
    /// refused by the scheduler, the composition's hook surfaces the
    /// note through the main hop, a successful legacy retime never does,
    /// and once dismissed a later refusal stays silent.
    @MainActor
    func testRetimeHookWiresToTheNote() throws {
        let clockStorage = SlotClockSettingsTestStorage()
        let slotted = slotEntry(name: "Amlodipine", slot: .morning,
                                mirrorHour: 8, mirrorMinute: 0)
        let legacy = legacyEntry(name: "Metformin", hour: 10, minute: 0)
        let (coordinator, scheduler, restore) = try XCTUnwrap(
            makeSeededCoordinator(clockStorage: clockStorage, entries: [slotted, legacy]))
        defer { restore() }

        // A LEGACY retime succeeds: nothing was refused, no note.
        XCTAssertTrue(scheduler.setScheduleTimes([timeComponents(hour: 11, minute: 0)],
                                                 entryId: legacy.id),
                      "a legacy entry's retime is the shipped behaviour, first-class")
        drainMainQueue()
        XCTAssertFalse(coordinator.medicationRetimeNotePresented,
                       "a successful retime never surfaces the note")

        // A SLOT retime is refused — the time comes from the mapping —
        // and the hook brings the note up.
        XCTAssertFalse(scheduler.setScheduleTimes([timeComponents(hour: 9, minute: 0)],
                                                  entryId: slotted.id),
                       "a slot entry's clock is the household mapping (IF-10)")
        XCTAssertFalse(coordinator.medicationRetimeNotePresented,
                       "the hop is asynchronous — nothing surfaces on the calling thread")
        drainMainQueue()
        XCTAssertTrue(coordinator.medicationRetimeNotePresented,
                      "the refusal hook surfaces the note (IF-10, m-5)")
        XCTAssertEqual(scheduler.medicationEntry(for: slotted.id)?.scheduleTimes.first?.hour, 8,
                       "the refusal changed nothing — the stored time is untouched")
        XCTAssertEqual(scheduler.medicationEntry(for: slotted.id)?.scheduleTimes.first?.minute, 0)

        // Dismissing persists…
        coordinator.dismissMedicationRetimeNote()
        XCTAssertTrue(SettingsPersistence.shared.bool(forKey: Self.retimeNoteKey))

        // …and a later refusal never brings the note back.
        XCTAssertFalse(scheduler.setScheduleTimes([timeComponents(hour: 9, minute: 30)],
                                                  entryId: slotted.id))
        drainMainQueue()
        XCTAssertFalse(coordinator.medicationRetimeNotePresented,
                       "dismissed once is dismissed for good (IF-10)")
    }

    /// Both composition hooks are assigned at composition, the calendar
    /// hook routes through the T-015 write on main and consults NO
    /// caregiver notification toggle (T-016's flag: the at-risk alert
    /// types were never about the notify preference), and the wired
    /// closure survives a real call.
    @MainActor
    func testSignificantEventHookIsAssignedAtComposition() throws {
        let clockStorage = SlotClockSettingsTestStorage()
        let entry = legacyEntry(name: "Metformin", hour: 10, minute: 0)
        let (_, scheduler, restore) = try XCTUnwrap(
            makeSeededCoordinator(clockStorage: clockStorage, entries: [entry]))
        defer { restore() }

        XCTAssertNotNil(scheduler.onSignificantEvent,
                        "the calendar write path is assigned at composition (T-015/T-020)")
        XCTAssertNotNil(scheduler.onSlotEntryRetimeRefused,
                        "the note hook is assigned beside it")

        // The wiring's own text: the hook's body is the sharer's one-off
        // write, the main hop runs first, and NOTHING consults the
        // caregiver notification toggle.
        let wiring = collapsed(coordinatorRegion("medicationScheduler.onSignificantEvent = {",
                                                 to: "externalCalendarCancellable"))
        XCTAssertTrue(wiring.contains("calendarShareService.writeSignificantEvent(event, entry: entry)"),
                      "the T-015 write path is the hook's body")
        XCTAssertTrue(wiring.contains("DispatchQueue.main.async"),
                      "the lazy service is kept on main by the hop")
        XCTAssertFalse(wiring.contains("caregiverNotify"),
                       "the at-risk alert types are NOT gated on the caregiver preference (T-016)")

        // Drive the wired closure: consent is not accepted in the test
        // defaults, so the sharer's own gate makes this an honest no-op
        // — the claim is that a real call flows through the composition
        // (and the main hop) without trapping.
        let event = SignificantMedicationEvent(kind: .missedMedication,
                                               entryId: entry.id,
                                               occurredAt: Date())
        scheduler.onSignificantEvent?(event, entry)
        drainMainQueue()
    }

    /// The card's WORDS are honest (NFR-MSR-004/005): every clock it
    /// shows comes from `SpokenTime.string(hour:minute:locale:)`, not one
    /// string interpolation exists on the card, no display formatter
    /// renders a clock, every font and height goes through the design
    /// tokens, and every key the card can show is a shipped catalog key
    /// resolving in both languages.
    func testSpokenTimesUseSpokenTimeFormatter() {
        let view = settingsViewSource()
        let card = collapsed(region("private var medicineTimesSection",
                                    to: "struct MedicineTimesDraft", in: view))

        XCTAssertTrue(card.contains("SpokenTime.string(hour: time.hour, minute: time.minute,"),
                      "the row's words come from SpokenTime and nothing else (NFR-MSR-004)")
        XCTAssertFalse(card.contains("\\("),
                       "not one interpolation on the card — no raw digit can enter the family's words")
        XCTAssertFalse(card.contains("Date.FormatStyle"),
                       "no display formatter renders a clock on this card")
        XCTAssertFalse(card.contains("DateFormatter"))
        XCTAssertFalse(card.contains(".formatted("))

        // NFR-MSR-005 by token counts: every font through the appearance
        // tokens, every minHeight through the design tokens.
        XCTAssertEqual(count(of: ".font(", in: card),
                       count(of: ".font(.system(size: appearance.typography.", in: card),
                       "every font on this card goes through the appearance tokens")
        XCTAssertEqual(count(of: ".frame(minHeight:", in: card),
                       count(of: ".frame(minHeight: DesignTokens.", in: card),
                       "every height floor on this card goes through the design tokens")
        XCTAssertTrue(card.contains("DesignTokens.minTapTargetSize"),
                      "the 44pt floor is stated (NFR-MSR-005)")
        XCTAssertTrue(card.contains("DesignTokens.chipHeight"))

        // The card reads through the coordinator's ONE accessor.
        XCTAssertTrue(card.contains("coordinator.currentMedicationSlotClock()"),
                      "the card's values come from the stored record, never a local guess")

        // The row-label family and its catalog keys, both directions.
        XCTAssertEqual(MedicationScheduleSettingsView.medicineTimesLabelKey(for: .morning),
                       "settings.meds.times.morning")
        XCTAssertEqual(MedicationScheduleSettingsView.medicineTimesLabelKey(for: .afternoon),
                       "settings.meds.times.afternoon")
        XCTAssertEqual(MedicationScheduleSettingsView.medicineTimesLabelKey(for: .evening),
                       "settings.meds.times.evening")
        for slot in MedicationSlot.allCases {
            XCTAssertTrue(Self.cardKeys.contains(
                MedicationScheduleSettingsView.medicineTimesLabelKey(for: slot)),
                "every row label the card derives is on the reviewed key list")
        }
        let labelRegion = collapsed(region("static func medicineTimesLabelKey",
                                           to: "struct MedicineTimesDraft", in: view))
        XCTAssertTrue(labelRegion.contains("\"settings.meds.times.\" + slot.rawValue"),
                      "the derivation is the reviewed family, verbatim")

        // Every consumed key resolves in BOTH shipped languages, to
        // non-empty, non-identical copy (the L10nCatalogCoverageTests
        // discipline, through the same `L10n.str` seam non-View code
        // uses).
        let english = Locale(identifier: "en-US")
        let nepali = Locale(identifier: "ne-NP")
        for key in Self.cardKeys {
            let en = L10n.str(key, locale: english)
            let ne = L10n.str(key, locale: nepali)
            XCTAssertNotEqual(en, key, "\(key) does not resolve in en")
            XCTAssertNotEqual(ne, key, "\(key) does not resolve in ne")
            XCTAssertFalse(en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(ne.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertNotEqual(en, ne, "\(key) ships the English copy untranslated")
        }

        // The formatter's own conventions — the exact words the card
        // shows for the documented defaults and a retime.
        XCTAssertEqual(SpokenTime.string(hour: 8, minute: 0, locale: english), "8 am")
        XCTAssertEqual(SpokenTime.string(hour: 7, minute: 30, locale: english), "7:30 am")
        XCTAssertEqual(SpokenTime.string(hour: 19, minute: 0, locale: english), "7 pm")
    }

    // MARK: - The reviewed key list

    /// Every catalog key the "Medicine times" card can put on screen —
    /// the section inventory plus the shared save label and the clean
    /// commit line. Reviewed here so a key added to the card without a
    /// catalog entry fails in this suite.
    private static let cardKeys: [String] = [
        "settings.meds.times.title",
        "settings.meds.times.morning",
        "settings.meds.times.afternoon",
        "settings.meds.times.evening",
        "settings.meds.times.reset",
        "settings.meds.times.saveFailed",
        "settings.meds.times.unresolved",
        "settings.meds.times.retimeNote",
        "settings.meds.times.retimeNote.dismiss",
        "settings.meds.save",
        SlotClockSaveResult.savedLineKey,
    ]

    // MARK: - Fixtures and helpers

    /// A slot entry (T-003's model): the dose lives in `slot` and
    /// `scheduleTimes` carries the resolved-time MIRROR, passed here as a
    /// deliberately explicit value so a test can watch it move (or not).
    private func slotEntry(name: String = "Amlodipine", slot: MedicationSlot,
                           mirrorHour: Int, mirrorMinute: Int) -> MedicationEntry {
        MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: name,
            doseDescription: "One tablet",
            scheduleTimes: [timeComponents(hour: mirrorHour, minute: mirrorMinute)],
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: false,
            confirmationDescription: nil,
            quantity: MedicationQuantity(amount: 1,
                                         unit: MedicationDoseUnit.tablet.rawValue),
            slot: slot,
            mealRelation: .beforeMeal)
    }

    /// A legacy-shape entry — a raw clock time, no slot.
    private func legacyEntry(name: String, hour: Int, minute: Int) -> MedicationEntry {
        MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: name,
            doseDescription: "",
            scheduleTimes: [timeComponents(hour: hour, minute: minute)],
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: false,
            confirmationDescription: nil)
    }

    private func timeComponents(hour: Int, minute: Int) -> DateComponents {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return components
    }

    /// Persists a mapping the way the settings save action does —
    /// through the store, so the arming path reads exactly what a
    /// household would have saved.
    private func install(_ clock: MedicationSlotClock,
                         into storage: SlotClockSettingsTestStorage) {
        switch MedicationSlotClockStore(storage: storage).save(clock) {
        case .success:
            break
        case .failure:
            XCTFail("a valid mapping must persist")
        }
    }

    /// The real coordinator over the real scheduler (the T-017 recipe),
    /// with the household-mapping store injected over an in-memory
    /// channel (which the T-020 composition also hands to the scheduler)
    /// and the evidence store rooted at a scratch directory. `entries`
    /// seeds the schedule; the RETURNED `restore` closure must be
    /// deferred by the TEST method (a defer inside this helper would
    /// fire before the test body runs).
    @MainActor
    private func makeSeededCoordinator(clockStorage: SlotClockSettingsTestStorage,
                                       entries: [MedicationEntry])
        -> (coordinator: AppCoordinator, scheduler: MedicationScheduler,
            restore: () -> Void)? {
        let coordinator = AppCoordinator(
            profileStorage: InMemoryProfilePayloadStorage(),
            slotClockStore: MedicationSlotClockStore(storage: clockStorage),
            medicationEvidenceStore: MedicationEvidenceStore(rootDirectory: evidenceRoot))
        guard let scheduler = stored("medicationScheduler", of: coordinator,
                                     as: MedicationScheduler.self) else { return nil }
        let previous = scheduler.medicationEntries()
        scheduler.loadSchedule(entries: entries)
        return (coordinator, scheduler, { scheduler.loadSchedule(entries: previous) })
    }

    /// One stored property of `subject`, by label. The `as? T` cast
    /// unwraps one level of Optional (the house `stored` helper, the
    /// `MedicationAckClarificationTests` convention). A missing label or
    /// a mismatched type is an explicit failure, never a silent nil.
    private func stored<T>(_ label: String, of subject: Any, as type: T.Type = T.self,
                           file: StaticString = #filePath, line: UInt = #line) -> T? {
        guard let child = Mirror(reflecting: subject).children.first(where: { $0.label == label }) else {
            XCTFail("no stored property '\(label)' on \(Swift.type(of: subject))",
                    file: file, line: line)
            return nil
        }
        guard let value = child.value as? T else {
            XCTFail("stored property '\(label)' is not a \(T.self) — holds \(Swift.type(of: child.value))",
                    file: file, line: line)
            return nil
        }
        return value
    }

    /// Waits out the composition's main hop (the
    /// `DialogueCoordinatorWiringTests` idiom): an expectation fulfilled
    /// from the main queue runs only after every earlier main-queue
    /// block — including the hooks' — has run.
    private func drainMainQueue() {
        let done = expectation(description: "main drain")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    // MARK: - Source helpers (the `CallConfirmationWordingTests` pattern)

    private func coordinatorSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift"))
    }

    private func settingsViewSource() -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/SettingsView.swift"))
    }

    private func coordinatorRegion(_ start: String, to end: String) -> String {
        region(start, to: end, in: coordinatorSource())
    }

    /// The text between two code markers (comment-stripped, so the
    /// markers and pins are code, never prose).
    private func region(_ start: String, to end: String, in text: String) -> String {
        guard let startRange = text.range(of: start) else {
            XCTFail("source has no `\(start)`")
            return ""
        }
        guard let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
            XCTFail("no `\(end)` after `\(start)`")
            return ""
        }
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    /// Whitespace-collapsed form: exact token sequences survive while
    /// indentation and line breaks do not.
    private func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func assertAppearsInOrder(_ markers: [String], in text: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        var searchFrom = text.startIndex
        for marker in markers {
            guard let found = text.range(of: marker, range: searchFrom..<text.endIndex) else {
                XCTFail("`\(marker)` missing — or out of order — in the pinned region",
                        file: file, line: line)
                return
            }
            searchFrom = found.upperBound
        }
    }

    private func count(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - Test doubles
    // (private to this suite, the house pattern its sibling suites ship)

    /// In-memory `EncryptedLocalStorage` for the household-mapping store:
    /// JSON encode/decode like the shipped file store, plus a write-fail
    /// switch so the store-failure half of IF-9 can be staged.
    private final class SlotClockSettingsTestStorage: EncryptedLocalStorage {
        private var records: [String: Data] = [:]
        var failWrites = false

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard !failWrites, let data = try? JSONEncoder().encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            records[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            guard let data = records[key] else { return .failure(.encryptedReadFailed) }
            guard let value = try? JSONDecoder().decode(type, from: data) else {
                return .failure(.encryptedReadFailed)
            }
            return .success(value)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            records.removeValue(forKey: key)
            return .success(())
        }
    }

    /// In-memory stand-in for the coordinator's profile payload channel
    /// (the house helper: the seams under test are the real scheduler,
    /// the real save path and the real settings card logic; only the
    /// profile store's channel is faked).
    private final class InMemoryProfilePayloadStorage: ProfilePayloadStorage {
        var payloads: [String: Data] = [:]
        private let encoder = JSONEncoder()

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard let data = try? encoder.encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            payloads[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            .failure(.encryptedReadFailed)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            payloads[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? { payloads[key] }
        func hasPayload(key: String) -> Bool? { payloads[key] != nil }
    }

    // MARK: - Language + note-key seeding (the T-013 recipe)

    private static let languageKey = "appLanguage"
    private static let retimeNoteKey = "medicationRetimeNoteDismissed.v1"
    private var languageBackup: Any?
    private var retimeNoteBackup: Any?
    private var evidenceRoot: URL!

    override func setUp() {
        super.setUp()
        // Seed BEFORE any coordinator exists: the init restores through
        // the real `AppLanguage.persisted()` seam, so the composed copy
        // resolves the English catalog deterministically.
        languageBackup = UserDefaults.standard.object(forKey: Self.languageKey)
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: Self.languageKey)
        // The m-5 dismissal is process-global state (the SETTINGS
        // passthrough writes it to standard defaults); every test starts
        // from "never dismissed" and hands the previous value back.
        retimeNoteBackup = UserDefaults.standard.object(forKey: Self.retimeNoteKey)
        UserDefaults.standard.removeObject(forKey: Self.retimeNoteKey)
        evidenceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MedicationSlotClockSettings-" + UUID().uuidString,
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: evidenceRoot,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let evidenceRoot {
            try? FileManager.default.removeItem(at: evidenceRoot)
        }
        if let languageBackup {
            UserDefaults.standard.set(languageBackup, forKey: Self.languageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.languageKey)
        }
        if let retimeNoteBackup {
            UserDefaults.standard.set(retimeNoteBackup, forKey: Self.retimeNoteKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.retimeNoteKey)
        }
        super.tearDown()
    }
}
