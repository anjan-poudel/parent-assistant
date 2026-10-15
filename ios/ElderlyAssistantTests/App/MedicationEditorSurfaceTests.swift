import Foundation
import XCTest
@testable import ElderlyAssistant

/// T-018 — the medication editor's slot-model surface (design-l2 C8 view
/// half; FR-MSR-001/004/005/006, FR-MSR-021, NFR-MSR-005; decisions D1/D2,
/// rule m-3).
///
/// The split this suite tests through, and why each half is worth a named
/// test:
///
///  - **The form's decisions are pure seams.** A view body cannot be
///    instantiated in a unit test, so the drawing is pinned at the SOURCE
///    (the presentation-suite idiom: `FeatureSourceScan.codeText` plus
///    struct/region slicing), while every decision the form makes — the
///    draft the add form opens with, the prefill an existing entry loads
///    by, the request Save builds (IF-21), the view's pending-row gate and
///    both explicit model switches — is a static, testable function on
///    `MedicationScheduleSettingsView`.
///  - **A slot save runs end to end.** The request built from a slot draft
///    is handed to the REAL coordinator over the REAL scheduler (the T-017
///    recipe, seams injected), so the resolved-time mirror, the composed
///    dose line and the persisted shape are exercised, not mocked.
///  - **Edit-existing never converts silently.** A legacy entry opens on
///    the clock model exactly as stored; preselection is exact-equality
///    against the household mapping the family has NOW (no nearest slot,
///    no clobbering); the model changes only through the family's tap.
///  - **An empty scan read changes nothing** — the shipped scan rule,
///    reached through the slot arm.
///  - **The elderly-fit floor** (NFR-MSR-005, FR-MSR-021) on every control
///    this unit adds: the 44pt tap token or the scaled typography tokens
///    (>= 18pt by construction), pinned per control because the rendering
///    itself cannot run here. Device-level accessibility is the DV
///    checklist's, not this unit's.
final class MedicationEditorSurfaceTests: XCTestCase {

    // MARK: - The add form (C8)

    /// The new-entry form opens on the slot model, "Add another dose"
    /// appends one row per dose, and the request Save builds carries the
    /// slot rows untouched — the view states no clock time (IF-21). End to
    /// end: the request lands through the real save gate, and the
    /// persisted entries carry the slot, the structured quantity, the
    /// meal relation and C2's composed line. Source pins cover the
    /// three-slot picker, the time-of-day-only arm and the elderly-fit
    /// floor.
    @MainActor
    func testSaveRequestBuiltFromSlotRows() throws {
        var draft = MedicationScheduleSettingsView.newDraft(now: referenceDate, calendar: calendar)
        XCTAssertEqual(draft.scheduleMode, .slots,
                       "the new-entry form opens on the slot model (C8)")
        XCTAssertEqual(draft.slotRows, [nil],
                       "…with exactly one row, unassigned until the family picks")
        XCTAssertEqual(MedicationScheduleSettingsView.pendingRowFailureKey(for: draft),
                       "settings.meds.slotRequired",
                       "an unassigned row holds the save closed at the view")

        draft.name = "Amlodipine"
        draft.strength = "500 mg"
        draft.quantity.amount = 2
        draft.quantity.select(.tablet, locale: english)
        draft.mealRelation = .afterMeal
        draft.slotRows[0] = .morning
        draft.addTime()
        XCTAssertEqual(draft.slotRows.count, 2, "one tap, one more dose row (D1)")
        draft.slotRows[1] = .evening

        XCTAssertTrue(draft.canSaveRequest,
                      "a named draft with every row assigned can build a request")
        XCTAssertNil(MedicationScheduleSettingsView.pendingRowFailureKey(for: draft))

        let request = MedicationScheduleSettingsView.saveRequest(from: draft, photo: nil)
        XCTAssertEqual(request.name, "Amlodipine")
        XCTAssertEqual(request.strength, "500 mg")
        XCTAssertNil(request.purpose)
        XCTAssertEqual(request.quantity, MedicationQuantity(amount: 2, unit: "tablet"),
                       "the structured quantity is the chip's raw value")
        XCTAssertEqual(request.mealRelation, .afterMeal)
        XCTAssertEqual(request.rows, [.slot(.morning), .slot(.evening)],
                       "one row per dose, each stated as a slot — never a clock time from this surface")
        XCTAssertNil(request.photo)

        let (coordinator, scheduler, restore) = try XCTUnwrap(makeSeededCoordinator(entries: []))
        defer { restore() }
        XCTAssertNil(coordinator.addMedication(request), "the slot-model save lands")
        let saved = scheduler.medicationEntries()
        XCTAssertEqual(saved.count, 2, "N dose rows create N entries (D1)")
        let morning = try XCTUnwrap(saved.first { $0.slot == .morning })
        XCTAssertEqual(morning.doseDescription, "2 tablet, 500 mg",
                       "the line is C2's composition of the quantity and the family's strength")
        XCTAssertEqual(morning.quantity, MedicationQuantity(amount: 2, unit: "tablet"))
        XCTAssertEqual(morning.mealRelation, .afterMeal,
                       "the stated meal context rides the entry — context only, never a second firing")
        XCTAssertEqual(morning.scheduleTimes,
                       [MedicationSlotClock.defaultMorningTime.dateComponents],
                       "the mirror is resolved by the coordinator (D2), not by the view")

        // The drawing the unit test cannot render. The slot arm asks for a
        // time of day and nothing else; the elderly-fit floor holds on
        // every control this unit adds.
        let controls = controlsRegion()
        XCTAssertTrue(controls.contains("MedicationSlot.allCases"),
                      "the slot picker renders the whole slot vocabulary")
        XCTAssertFalse(controls.contains("DatePicker"),
                       "the slot arm never asks the family for a clock time (C8)")
        XCTAssertTrue(controls.contains("draft.addTime()"),
                      "'Add another dose' appends a draft row, one per dose")
        XCTAssertTrue(controls.contains("\"settings.meds.keepTimes\""),
                      "the explicit way back to the clock model is offered — no silent conversion either way")
        XCTAssertTrue(controls.contains("\"settings.meds.useSlotModel\""),
                      "…and the explicit way in is the same chooser")
        XCTAssertTrue(controls.contains("\"meds.addDose\""),
                      "the appender renders the shipped catalog line")
        XCTAssertTrue(controls.contains("\"meds.quantity.amount\"")
                      && controls.contains("\"meds.quantity.customUnit\""),
                      "the quantity step renders the shipped amount and unit fields")
        for builder in ["private func modeChip", "private func slotChip",
                        "private var addDoseButton", "private func amountButton",
                        "private func unitChip", "private func mealChip"] {
            let control = member(builder)
            XCTAssertTrue(control.contains("DesignTokens.minTapTargetSize"),
                          "\(builder) keeps the 44pt tap floor (NFR-MSR-005)")
        }
        for line in controls.split(separator: "\n") where line.contains(".font(") {
            XCTAssertTrue(line.contains("appearance.typography."),
                          "type drawn outside the scaled tokens would break the 18pt floor: \(line)")
        }

        // The T-012 key mappings, live through L10n: the picker, the unit
        // chips and the row's context line name the same catalog keys.
        for slot in MedicationSlot.allCases {
            let key = MedicationScheduleSettingsView.slotKey(for: slot)
            let en = L10n.str(key, locale: english)
            let ne = L10n.str(key, locale: nepali)
            XCTAssertFalse(en.isEmpty, "\(key) must resolve (T-012)")
            XCTAssertNotEqual(en, ne, "\(key) must be translated in both languages")
        }
        XCTAssertEqual(MedicationScheduleSettingsView.slotKey(for: .morning), "meds.slot.morning")
        XCTAssertEqual(MedicationScheduleSettingsView.mealKey(for: .beforeMeal), "meds.meal.before")
        XCTAssertEqual(MedicationScheduleSettingsView.mealKey(for: .afterMeal), "meds.meal.after")
        XCTAssertEqual(MedicationScheduleSettingsView.unitLabel(for: .tablet, locale: english),
                       "tablet", "the one unit-label source is the catalog key family")
    }

    // MARK: - Edit existing: the clock-model entry (C8)

    /// A legacy entry opens on the CLOCK model, exactly as stored. The slot
    /// model appears only when the family chooses it, and its preselection
    /// is exact equality against the mapping the family has now: 08:00
    /// matches 08:00, 08:15 matches nothing (no nearest slot), and a row
    /// the family already assigned is never clobbered.
    @MainActor
    func testLegacyEntryPreselectsClockModelExactly() throws {
        let entry = legacyEntry(name: "Amlodipine",
                                times: [DateComponents(hour: 8, minute: 0),
                                        DateComponents(hour: 8, minute: 15)])
        let draft = MedicationScheduleSettingsView.draft(from: entry, locale: english,
                                                         now: referenceDate, calendar: calendar)
        XCTAssertEqual(draft.scheduleMode, .times,
                       "a legacy entry opens on the clock model — nothing converts on the way in")
        XCTAssertEqual(draft.storedTimes,
                       [DateComponents(hour: 8, minute: 0), DateComponents(hour: 8, minute: 15)],
                       "the stored times are placed exactly as stored, hour and minute")
        XCTAssertEqual(draft.slotRows, [nil, nil],
                       "no slot is assigned before the family chooses the model")

        var switched = draft
        MedicationScheduleSettingsView.switchToSlots(&switched, mapping: .default)
        XCTAssertEqual(switched.scheduleMode, .slots)
        XCTAssertEqual(switched.slotRows, [.morning, nil],
                       "exact equality only: 08:00 matches, 08:15 is no one's 'morning'")
        XCTAssertFalse(switched.canSaveRequest,
                       "the unmatched row keeps the request gate closed")
        XCTAssertEqual(MedicationScheduleSettingsView.pendingRowFailureKey(for: switched),
                       "settings.meds.slotRequired",
                       "…and the view says so through the shipped error key")

        // Nothing is clobbered: the family's own assignment survives a
        // second switch — preselection fills unassigned rows only.
        switched.slotRows[0] = .evening
        MedicationScheduleSettingsView.switchToSlots(&switched, mapping: .default)
        XCTAssertEqual(switched.slotRows, [.evening, nil],
                       "preselection never overwrites a slot the family picked")

        // Equality is measured against the mapping the family has NOW: a
        // mapping whose morning is 08:15 matches the 08:15 row instead.
        var moved = draft
        let movedMapping = MedicationSlotClock(morning: TimeOfDay(hour: 8, minute: 15),
                                               afternoon: TimeOfDay(hour: 13, minute: 0),
                                               evening: TimeOfDay(hour: 19, minute: 0))
        MedicationScheduleSettingsView.switchToSlots(&moved, mapping: movedMapping)
        XCTAssertEqual(moved.slotRows, [nil, .morning],
                       "the match follows the household mapping, not a shipped default")

        // Source pin: the prefill itself never preselects — preselection
        // exists only through the explicit family switch.
        let prefill = member("static func draft(from")
        XCTAssertFalse(prefill.contains("applySlotPreselection"),
                       "entering the form never converts a clock time into a slot (C8)")
        XCTAssertTrue(prefill.contains("draft.scheduleMode = .times"),
                      "the legacy arm is the clock model")
        XCTAssertTrue(prefill.contains("draft.scheduleMode = .slots"),
                      "…and a slot entry reopens on the slot model")
    }

    // MARK: - One row model per save

    /// One row model per save, and only ever by the family's explicit
    /// choice: without a switch a legacy entry saves as its exact times;
    /// after the switch it saves as slots (and the coordinator resolves
    /// the mirror); switching back states times again. A switch alone
    /// persists nothing.
    @MainActor
    func testModeSwitchOneWayPerSave() throws {
        let entry = legacyEntry(name: "Metformin",
                                times: [DateComponents(hour: 8, minute: 0)])
        let (coordinator, scheduler, restore) = try XCTUnwrap(makeSeededCoordinator(entries: [entry]))
        defer { restore() }

        var draft = MedicationScheduleSettingsView.draft(from: entry, locale: english,
                                                         now: referenceDate, calendar: calendar)
        var request = MedicationScheduleSettingsView.saveRequest(from: draft, photo: nil)
        XCTAssertEqual(request.rows, [.time(DateComponents(hour: 8, minute: 0))],
                       "an unswitched legacy entry saves as its exact time — it gains no slot")
        XCTAssertEqual(scheduler.medicationEntries().map(\.id), [entry.id],
                       "building a request writes nothing")
        XCTAssertNil(try XCTUnwrap(scheduler.medicationEntries().first).slot,
                     "…and the stored entry is still a legacy one")

        // The explicit family choice, and only it, changes the model.
        MedicationScheduleSettingsView.switchToSlots(&draft, mapping: .default)
        XCTAssertEqual(draft.scheduleMode, .slots)
        XCTAssertEqual(scheduler.medicationEntries().map(\.id), [entry.id],
                       "the switch itself persists nothing — the save gate is still the family's")
        request = MedicationScheduleSettingsView.saveRequest(from: draft, photo: nil)
        XCTAssertEqual(request.rows, [.slot(.morning)],
                       "after the explicit switch the one save states slots, never times")

        XCTAssertNil(coordinator.updateMedication(id: entry.id, request),
                     "the switched save lands through the shipped update path")
        let updated = try XCTUnwrap(scheduler.medicationEntries().first)
        XCTAssertEqual(updated.id, entry.id, "an edit keeps the id — no second entry")
        XCTAssertEqual(updated.slot, .morning)
        XCTAssertEqual(updated.scheduleTimes,
                       [MedicationSlotClock.defaultMorningTime.dateComponents],
                       "the mirror is the mapping's resolved time (D2) — the view passed no clock")

        // The reverse explicit choice states times again — and the picker
        // is placed at the time the slot actually fires at, so the visible
        // conversion never moves a dose.
        MedicationScheduleSettingsView.switchToTimes(&draft, mapping: .default,
                                                     now: referenceDate, calendar: calendar)
        XCTAssertEqual(draft.scheduleMode, .times)
        XCTAssertEqual(draft.storedTimes, [DateComponents(hour: 8, minute: 0)])
        XCTAssertEqual(MedicationScheduleSettingsView.saveRequest(from: draft, photo: nil).rows,
                       [.time(DateComponents(hour: 8, minute: 0))],
                       "…and the save states times again — one row model per save, both directions")

        // Source pin: the view's own gate (unassigned rows) runs before
        // IF-21, so a save that would drop a row never reaches the
        // coordinator; and the view itself never writes.
        let saveBody = collapsed(member("private func save()"))
        let pending = try XCTUnwrap(saveBody.range(of: "pendingRowFailureKey"))
        let write = try XCTUnwrap(saveBody.range(of: "addMedication"))
        XCTAssertLessThan(pending.lowerBound, write.lowerBound,
                          "the pending-row gate runs before the save paths")
    }

    // MARK: - Edit existing: the slot entry (C8, D1, D2)

    /// A slot entry reopens on the slot model with its slot on the one form
    /// row (D1), its quantity and food context back in the step, and the
    /// resolved-time mirror NEVER shown as a clock the family stated (D2).
    /// Re-saving round-trips the dose line without composing the quantity
    /// twice; a line whose halves cannot be aligned exactly keeps the
    /// family's words verbatim and degrades to the legacy shape — never a
    /// rewrite, never a duplicate.
    @MainActor
    func testSlotEntryReopensInSlotMode() throws {
        let quantity = MedicationQuantity(amount: 1, unit: MedicationDoseUnit.tablet.rawValue)
        let entry = medicationEntry(name: "Metformin",
                                    doseDescription: "1 tablet, after dinner",
                                    times: [MedicationSlotClock.defaultEveningTime.dateComponents],
                                    quantity: quantity, slot: .evening, mealRelation: .afterMeal)
        let draft = MedicationScheduleSettingsView.draft(from: entry, locale: english,
                                                         now: referenceDate, calendar: calendar)
        XCTAssertEqual(draft.scheduleMode, .slots, "a slot entry reopens on the slot model")
        XCTAssertEqual(draft.slotRows, [.evening], "…with its slot on the form's one row (D1)")
        XCTAssertEqual(draft.times.count, 1)
        XCTAssertNotEqual(draft.storedTimes, [DateComponents(hour: 19, minute: 0)],
                          "the resolved-time mirror is never placed where the form shows a clock (D2)")
        XCTAssertEqual(draft.quantity.amount, 1)
        XCTAssertEqual(draft.storedQuantity, quantity,
                       "the structured quantity is refilled — never parsed back out of the line")
        XCTAssertEqual(draft.strength, "after dinner",
                       "the line's text half comes back; the quantity half must not be duplicated")
        XCTAssertEqual(draft.mealRelation, .afterMeal)
        XCTAssertTrue(draft.canSaveRequest)

        let request = MedicationScheduleSettingsView.saveRequest(from: draft, photo: nil)
        XCTAssertEqual(request.rows, [.slot(.evening)])
        XCTAssertEqual(request.quantity, quantity)
        XCTAssertEqual(request.strength, "after dinner")

        let (coordinator, scheduler, restore) = try XCTUnwrap(makeSeededCoordinator(entries: [entry]))
        defer { restore() }
        XCTAssertNil(coordinator.updateMedication(id: entry.id, request),
                     "re-saving the reopened entry lands (self excluded from the duplicate rule)")
        let saved = try XCTUnwrap(scheduler.medicationEntries().first)
        XCTAssertEqual(scheduler.medicationEntries().count, 1, "an edit edits in place")
        XCTAssertEqual(saved.id, entry.id)
        XCTAssertEqual(saved.doseDescription, "1 tablet, after dinner",
                       "the dose line round-trips exactly — the quantity is never composed twice")
        XCTAssertEqual(saved.quantity, quantity)
        XCTAssertEqual(saved.slot, .evening)
        XCTAssertEqual(saved.mealRelation, .afterMeal)

        // A line that is not exactly the C2 composition of the stored
        // quantity and a text half (composed in the other language, then
        // edited after a language switch) stays the family's free text,
        // verbatim: rule 3 re-saves the identical line, and no quantity is
        // invented from the family's prose.
        let foreign = medicationEntry(
            name: "Amlodipine", doseDescription: "one pill",
            times: [MedicationSlotClock.defaultMorningTime.dateComponents],
            quantity: MedicationQuantity(amount: 1, unit: "tablet"),
            slot: .morning, mealRelation: nil)
        let foreignDraft = MedicationScheduleSettingsView.draft(from: foreign, locale: english,
                                                                now: referenceDate, calendar: calendar)
        XCTAssertEqual(foreignDraft.strength, "one pill")
        XCTAssertNil(foreignDraft.storedQuantity,
                     "the quantity step stays empty rather than duplicating the line's own words")
        XCTAssertEqual(foreignDraft.storedRows, [.slot(.morning)])
        let foreignRequest = MedicationScheduleSettingsView.saveRequest(from: foreignDraft, photo: nil)
        XCTAssertNil(foreignRequest.quantity)
        XCTAssertEqual(foreignRequest.strength, "one pill")
        XCTAssertNil(coordinator.addMedication(foreignRequest))
        let foreignSaved = try XCTUnwrap(
            scheduler.medicationEntries().first { $0.id != entry.id })
        XCTAssertEqual(foreignSaved.doseDescription, "one pill",
                       "rule 3: no quantity keeps the family's dose text, verbatim")

        // Source pin: the row draws the slot context through the shipped
        // catalog keys — the same keys the picker uses — and the row, not
        // a new control, is the edit-existing door.
        let context = member("private func slotContextText")
        XCTAssertTrue(context.contains("Self.slotKey(for: slot)"))
        XCTAssertTrue(context.contains("Self.mealKey(for: meal)"))
        let row = collapsed(region("private func medRow", to: "private var addForm"))
        XCTAssertTrue(row.contains("slotContextText(entry)"),
                      "a slot entry's row states its time of day")
        XCTAssertTrue(row.contains("timesText(entry.scheduleTimes)"),
                      "a legacy entry's row keeps its stored clock times, exactly as shipped")
        XCTAssertTrue(row.contains("beginEditing(entry)"),
                      "the row is the edit-existing door")
    }

    // MARK: - Empty scan read

    /// The shipped scan rule on the slot model: a read that found nothing
    /// changes nothing — no field, no row, no slot, no quantity — and the
    /// view hands the read to the draft (where those rules live) while the
    /// photo is attached either way.
    @MainActor
    func testEmptyScanLeavesValuesUnchanged() throws {
        var slotDraft = MedicationScheduleSettingsView.newDraft(now: referenceDate, calendar: calendar)
        slotDraft.name = "Amoxicillin"
        slotDraft.strength = "250 mg"
        slotDraft.quantity.amount = 2
        slotDraft.quantity.select(.capsule, locale: english)
        slotDraft.mealRelation = .beforeMeal
        slotDraft.slotRows[0] = .morning
        slotDraft.addTime()
        slotDraft.slotRows[1] = .evening
        let slotBefore = slotDraft

        slotDraft.applyScan(.empty)
        XCTAssertEqual(slotDraft, slotBefore,
                       "an empty read leaves the slot-model form exactly as it was")

        // A candidate carrying only a frequency guess is the same
        // non-event: the draft has no frequency step, and nothing else in
        // it may be touched.
        slotDraft.applyScan(MedicationLabelCandidate(frequency: .daily))
        XCTAssertEqual(slotDraft, slotBefore,
                       "a read with nothing to fill fills nothing")

        // The clock model rides the same rule, pre-filled from an entry…
        let entry = legacyEntry(name: "Amlodipine",
                                times: [DateComponents(hour: 8, minute: 0)])
        var timeDraft = MedicationScheduleSettingsView.draft(from: entry, locale: english,
                                                              now: referenceDate, calendar: calendar)
        let timeBefore = timeDraft
        timeDraft.applyScan(.empty)
        XCTAssertEqual(timeDraft, timeBefore,
                       "the rule is the model's, not the arm's")

        // …and the view wires the scan to the draft and the photo apart:
        // values are the draft's, the photo is the view's, and only Save
        // reaches the store.
        let (_, scheduler, restore) = try XCTUnwrap(makeSeededCoordinator(entries: [entry]))
        defer { restore() }
        XCTAssertEqual(scheduler.medicationEntries().map(\.id), [entry.id],
                       "a scan saves nothing — only Save does")
        let scan = member("private func scanLabel")
        XCTAssertTrue(scan.contains("scanPhoto = image"),
                      "the photo is attached whether or not anything was read")
        XCTAssertTrue(scan.contains("draft.applyScan(candidate)"),
                      "the view hands the read to the draft — the fill rules live there")
    }

    // MARK: - The name gate

    /// The shipped name gate is the one that speaks when everything else is
    /// ready (blank text is not a name, and a refused save persists
    /// nothing); the view's own gate — unassigned slot rows — is the only
    /// thing checked before IF-21.
    @MainActor
    func testSaveRejectedWithoutName() throws {
        let (coordinator, scheduler, restore) = try XCTUnwrap(makeSeededCoordinator(entries: []))
        defer { restore() }

        var draft = MedicationScheduleSettingsView.newDraft(now: referenceDate, calendar: calendar)
        draft.slotRows[0] = .morning
        XCTAssertNil(MedicationScheduleSettingsView.pendingRowFailureKey(for: draft),
                     "a fully assigned row set needs nothing from the view gate")
        XCTAssertFalse(draft.canSave, "a nameless draft cannot be saved")

        let request = MedicationScheduleSettingsView.saveRequest(from: draft, photo: nil)
        XCTAssertEqual(coordinator.addMedication(request), "settings.meds.nameRequired",
                       "the shipped name gate is the one that speaks — nothing else is wrong with this save")
        XCTAssertTrue(scheduler.medicationEntries().isEmpty, "a refused save persists nothing")

        draft.name = "   "
        XCTAssertEqual(coordinator.addMedication(
                        MedicationScheduleSettingsView.saveRequest(from: draft, photo: nil)),
                       "settings.meds.nameRequired",
                       "blank text is not a name (trimmed)")

        var unassigned = MedicationScheduleSettingsView.newDraft(now: referenceDate, calendar: calendar)
        unassigned.name = "Amlodipine"
        XCTAssertEqual(MedicationScheduleSettingsView.pendingRowFailureKey(for: unassigned),
                       "settings.meds.slotRequired",
                       "an unassigned row is caught at the view — a request with fewer rows than the form shows is never built")

        // Source pin: that ordering, the one write path per flow, and the
        // reset a landed save performs.
        let saveBody = collapsed(member("private func save()"))
        XCTAssertTrue(saveBody.contains("pendingRowFailureKey"),
                      "the view's gate is checked in save()")
        XCTAssertTrue(saveBody.contains("coordinator.addMedication(request)"),
                      "the add flow goes through IF-21")
        XCTAssertTrue(saveBody.contains("coordinator.updateMedication(id: entryId, request)"),
                      "the edit flow goes through IF-21 — the same request shape")
        XCTAssertTrue(saveBody.contains("resetToAddForm()"),
                      "a landed save returns the form to a fresh add shape")
    }

    // MARK: - Fixtures

    /// The calendar every prefill assertion runs under: fixed UTC, so the
    /// stored-times comparisons are exact on any machine (the T-009
    /// fixture).
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The day the form's pickers carry. A minute that matches no slot's
    /// default, so a mirror accidentally placed in the carrier would fail
    /// the D2 assertions loudly.
    private var referenceDate: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 15,
                                           hour: 14, minute: 23))!
    }

    private var english: Locale { AppLanguage.english.locale }
    private var nepali: Locale { AppLanguage.nepali.locale }

    /// A pre-slot entry — the shape every household's stored payload has —
    /// with the slot-model fields overridable for the slot-entry fixtures.
    private func legacyEntry(name: String, times: [DateComponents]) -> MedicationEntry {
        medicationEntry(name: name, doseDescription: "", times: times)
    }

    private func medicationEntry(
        name: String,
        doseDescription: String,
        times: [DateComponents],
        purpose: String? = nil,
        quantity: MedicationQuantity? = nil,
        slot: MedicationSlot? = nil,
        mealRelation: MealRelation? = nil,
        photoVerificationEnabled: Bool = false
    ) -> MedicationEntry {
        MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: name,
            doseDescription: doseDescription,
            scheduleTimes: times,
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: photoVerificationEnabled,
            confirmationDescription: nil,
            purpose: purpose,
            quantity: quantity,
            slot: slot,
            mealRelation: mealRelation)
    }

    /// The real coordinator over the real scheduler (the T-017 recipe),
    /// with its constructor seams injected: an in-memory household-mapping
    /// channel and an evidence store rooted at a scratch directory.
    /// `entries` seeds the schedule; the RETURNED `restore` closure must be
    /// deferred by the TEST method (a defer inside this helper would fire
    /// before the test body runs).
    @MainActor
    private func makeSeededCoordinator(entries: [MedicationEntry])
        -> (coordinator: AppCoordinator, scheduler: MedicationScheduler,
            restore: () -> Void)? {
        let coordinator = AppCoordinator(
            profileStorage: InMemoryProfilePayloadStorage(),
            slotClockStore: MedicationSlotClockStore(storage: MedicationSurfaceTestStorage()),
            medicationEvidenceStore: MedicationEvidenceStore(rootDirectory: evidenceRoot))
        guard let scheduler = stored("medicationScheduler", of: coordinator,
                                     as: MedicationScheduler.self) else { return nil }
        let previous = scheduler.medicationEntries()
        scheduler.loadSchedule(entries: entries)
        return (coordinator, scheduler, { scheduler.loadSchedule(entries: previous) })
    }

    /// One stored property of `subject`, by label. The `as? T` cast unwraps
    /// one level of Optional (the house `stored` helper, the
    /// `MedicationAckClarificationTests` convention). A missing label or a
    /// mismatched type is an explicit failure, never a silent nil.
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

    // MARK: - Source slicing (the presentation-suite idiom)

    /// The medication leaf's own source, comment-stripped and sliced at
    /// its column-0 boundaries — a key rendered by a neighbouring leaf in
    /// the same (very long) file cannot pass for this one's.
    private func structSource() -> String {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/SettingsView.swift")
        let text = FeatureSourceScan.codeText(of: url)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("struct MedicationScheduleSettingsView")
        }) else {
            XCTFail("SettingsView.swift has no top-level struct MedicationScheduleSettingsView")
            return ""
        }
        let end = lines[(start + 1)...].firstIndex { line in
            ["struct ", "enum ", "extension ", "final class ", "class "]
                .contains { line.hasPrefix($0) }
        } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    /// The text between two code markers (comment-stripped, so the markers
    /// and pins are code, never prose — the house `region` convention).
    private func region(_ start: String, to end: String) -> String {
        let text = structSource()
        guard let startRange = text.range(of: start) else {
            XCTFail("the medication leaf has no `\(start)`")
            return ""
        }
        guard let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
            XCTFail("no `\(end)` after `\(start)`")
            return ""
        }
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    /// One member's source: from its declaration marker to the next
    /// column-4 declaration (the members of this struct all start with
    /// `private` / `static` / `@ViewBuilder`), whichever comes first.
    private func member(_ start: String) -> String {
        let text = structSource()
        guard let startRange = text.range(of: start) else {
            XCTFail("the medication leaf has no `\(start)`")
            return ""
        }
        let tail = text[startRange.lowerBound...]
        var end = tail.endIndex
        for marker in ["\n    private ", "\n    static ", "\n    @ViewBuilder"] {
            if let found = tail.range(of: marker,
                                      range: tail.index(after: tail.startIndex)..<tail.endIndex),
               found.lowerBound < end {
                end = found.lowerBound
            }
        }
        return String(tail[..<end])
    }

    /// The new slot-model controls (this unit's draft, quantity, meal and
    /// picker builders), between the first builder and the first pure
    /// seam — the region the elderly-fit pins hold over.
    private func controlsRegion() -> String {
        region("private var scheduleStep", to: "static func newDraft")
    }

    /// Whitespace-collapsed form: exact token sequences survive while
    /// indentation and line breaks do not through this reshaper.
    private func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    // MARK: - Test doubles
    // (private to this suite, the house pattern its sibling suites ship)

    /// In-memory `EncryptedLocalStorage` for the household-mapping store:
    /// JSON encode/decode like the shipped file store. Every test here
    /// runs on the mapping's defaults (an absent record), which is exactly
    /// what this channel returns until a test seeds one.
    private final class MedicationSurfaceTestStorage: EncryptedLocalStorage {
        private var store: [String: Data] = [:]

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard let data = try? JSONEncoder().encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            store[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            guard let data = store[key] else { return .failure(.encryptedReadFailed) }
            guard let value = try? JSONDecoder().decode(type, from: data) else {
                return .failure(.encryptedReadFailed)
            }
            return .success(value)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            store.removeValue(forKey: key)
            return .success(())
        }
    }

    /// In-memory stand-in for the coordinator's profile payload channel
    /// (the `MedicationAckClarificationTests` helper: the seam is the real
    /// scheduler and the real save path; only the profile store's channel
    /// is faked).
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

    // MARK: - Language seeding (the T-013 recipe)

    private static let languageKey = "appLanguage"
    private var languageBackup: Any?
    private var evidenceRoot: URL!

    override func setUp() {
        super.setUp()
        // Seed BEFORE any coordinator exists: the init restores through
        // the real `AppLanguage.persisted()` seam, so the composed dose
        // line resolves the English catalog deterministically.
        languageBackup = UserDefaults.standard.object(forKey: Self.languageKey)
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: Self.languageKey)
        evidenceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MedicationEditorSurface-" + UUID().uuidString,
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
        super.tearDown()
    }
}
