import XCTest
@testable import ElderlyAssistant

/// The medication editor's pre-fill rules ([MED-OCR], 2026-09-18).
///
/// The view holds the form; this type holds the RULES, and they are the part
/// with a failure mode that reaches a dose:
///
///  - **text is never taken from the family** — a scan fills the name and the
///    strength only while those fields are still blank, because an OCR misread
///    replacing what a caregiver typed is the machine overriding the author;
///  - **the label's schedule wins** — a label that states times replaces the
///    form's, since a half-updated schedule (name from the box, times from
///    before) is the one outcome nobody can reason about, while a label that
///    states nothing changes nothing;
///  - **the stored shape is the model's** — hour/minute components only (the
///    duplicate check compares them), blank text is nil, and a chip is stored
///    as its id while a lookup's words are stored verbatim.
///
/// [MED-SLOT] (2026-10-15) The slot model rides the same rules and the suite
/// proves it: a scan in `.slots` mode replaces the SLOT rows under exactly
/// the shipped schedule rule (first-occurrence order through T-005's
/// conversion, an unmapped read changing nothing), text still fills blank
/// fields only, the save gate is still a name, and preselection from a
/// legacy entry is exact equality — never a fuzzy match. No shipped test
/// above changed: the extensions below are additive.
final class MedicationEditorDraftTests: XCTestCase {

    private let english = Locale(identifier: "en")

    /// A fixed calendar and clock: every `Date`/`DateComponents` assertion
    /// below is exact rather than dependent on the machine's time zone.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private lazy var referenceDate: Date = calendar.date(
        from: DateComponents(year: 2026, month: 9, day: 18, hour: 7, minute: 30))!

    private func makeDraft() -> MedicationEditorDraft {
        MedicationEditorDraft(now: referenceDate, calendar: calendar)
    }

    /// The same draft, in the slot model's form (the view's default for the
    /// new-entry form; the value type's default stays `.times`).
    private func makeSlotDraft() -> MedicationEditorDraft {
        var draft = makeDraft()
        draft.scheduleMode = .slots
        return draft
    }

    /// A picker date on the draft's reference day, so every schedule
    /// assertion is exact.
    private func date(hour: Int, minute: Int) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0,
                      of: referenceDate)!
    }

    private func hours(_ draft: MedicationEditorDraft) -> [Int] {
        draft.times.map { calendar.dateComponents([.hour], from: $0).hour ?? -1 }
    }

    // MARK: - The fresh form

    /// One time row, nothing typed, nothing saveable — the shape the editor
    /// has always opened with.
    func testFreshDraftHasOneTimeCannotBeSaved() {
        let draft = makeDraft()

        XCTAssertEqual(draft.name, "")
        XCTAssertEqual(draft.strength, "")
        XCTAssertEqual(draft.times.count, 1)
        XCTAssertEqual(hours(draft), [7])
        XCTAssertNil(draft.storedPurpose)
        XCTAssertFalse(draft.canSave)
    }

    /// The save gate is a name, trimmed: whitespace is not a name.
    func testCanSaveNeedsARealName() {
        var draft = makeDraft()

        draft.name = "   "
        XCTAssertFalse(draft.canSave)

        draft.name = "  Amlodipine  "
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.storedName, "Amlodipine")
    }

    // MARK: - Scanning: text is never taken from the family

    /// A blank form takes everything the label offered.
    func testScanFillsBlankNameAndStrength() {
        var draft = makeDraft()

        draft.applyScan(MedicationLabelCandidate(name: "Amoxicillin", strength: "500 mg"))

        XCTAssertEqual(draft.name, "Amoxicillin")
        XCTAssertEqual(draft.strength, "500 mg")
        XCTAssertEqual(draft.storedStrength, "500 mg")
    }

    /// What the family typed is theirs: a scan never overwrites a non-blank
    /// field, however plausible the OCR's reading looks.
    func testScanNeverOverwritesTypedText() {
        var draft = makeDraft()
        draft.name = "Amo"
        draft.strength = "250 mg"

        draft.applyScan(MedicationLabelCandidate(name: "Amoxicillin", strength: "500 mg"))

        XCTAssertEqual(draft.name, "Amo")
        XCTAssertEqual(draft.strength, "250 mg")
    }

    /// A field holding only spaces counts as blank — the family touched it and
    /// typed nothing.
    func testScanFillsFieldsHoldingOnlyWhitespaceRuns() {
        var draft = makeDraft()
        draft.name = "   "

        draft.applyScan(MedicationLabelCandidate(name: "Amoxicillin"))

        XCTAssertEqual(draft.name, "Amoxicillin")
    }

    /// A candidate that read nothing changes NOTHING — the photo is still
    /// attached by the caller, and the scanner has already said out loud that
    /// it could not read the label.
    func testEmptyCandidateChangesNothing() {
        var draft = makeDraft()
        draft.name = "Amlodipine"
        let before = draft

        draft.applyScan(.empty)

        XCTAssertEqual(draft, before)
    }

    // MARK: - Scanning: the label's schedule

    /// The label's times replace the form's — including a time the family had
    /// set, because they just asked the label to fill this form and the rows
    /// are visible pickers.
    func testScanReplacesTheFormTimesWithLabelValues() {
        var draft = makeDraft()

        draft.applyScan(MedicationLabelCandidate(
            name: "Amoxicillin",
            strength: "500 mg",
            scheduleTimes: [DateComponents(hour: 8, minute: 0),
                            DateComponents(hour: 20, minute: 0)],
            frequency: .daily))

        XCTAssertEqual(draft.times.count, 2)
        XCTAssertEqual(hours(draft), [8, 20])
        XCTAssertEqual(draft.storedTimes,
                       [DateComponents(hour: 8, minute: 0),
                        DateComponents(hour: 20, minute: 0)])
    }

    /// A label that states no schedule keeps the family's time: the form is
    /// never left with no dose time at all.
    func testScanWithoutATimesChangesNothingAboutTheSchedule() {
        var draft = makeDraft()

        draft.applyScan(MedicationLabelCandidate(name: "Amlodipine", frequency: .daily))

        XCTAssertEqual(hours(draft), [7])
        XCTAssertEqual(draft.name, "Amlodipine")
        XCTAssertEqual(draft.storedTimes.count, 1)
    }

    /// The stored components carry hour and minute ONLY. A component set with
    /// a day in it would make two entries for the same clock time compare
    /// unequal in the duplicate check.
    func testStoredTimesCarryOnlyHourAndMinute() {
        var draft = makeDraft()

        draft.applyScan(MedicationLabelCandidate(
            scheduleTimes: [DateComponents(hour: 13, minute: 15)]))

        XCTAssertEqual(draft.storedTimes,
                       [DateComponents(hour: 13, minute: 15)])
        XCTAssertNil(draft.storedTimes.first?.day)
        XCTAssertNil(draft.storedTimes.first?.second)
    }

    /// A component the calendar cannot resolve (no hour/minute — the parser
    /// never produces one, but the type accepts it) is dropped rather than
    /// defaulted to midnight, and a candidate that resolved to NOTHING
    /// changes nothing: `times` never empty is this type's invariant, because
    /// an empty row list is a form that cannot be saved.
    func testUnresolvableComponentsAreDroppedAndNeverEmptyTheRows() {
        var draft = makeDraft()
        draft.applyScan(MedicationLabelCandidate(
            scheduleTimes: [DateComponents(hour: 19, minute: 0)]))
        XCTAssertEqual(hours(draft), [19])

        draft.applyScan(MedicationLabelCandidate(scheduleTimes: [DateComponents()]))

        XCTAssertEqual(hours(draft), [19], "the unresolvable candidate changed nothing")
        XCTAssertEqual(draft.times.count, 1)

        draft.applyScan(MedicationLabelCandidate(
            scheduleTimes: [DateComponents(), DateComponents(hour: 13, minute: 0)]))

        XCTAssertEqual(hours(draft), [13], "the resolvable row survived, the other was dropped")
    }

    // MARK: - Time rows

    /// A second row is one hour after the last — the shape of a twice-daily
    /// medicine, added by hand or by a label.
    func testAddTimeAppendsAnHourAfterTheLast() {
        var draft = makeDraft()

        draft.addTime()

        XCTAssertEqual(draft.times.count, 2)
        XCTAssertEqual(hours(draft), [7, 8])
    }

    /// The last row is never removed: the save path needs at least one dose
    /// time, and an empty picker list is a form that cannot be saved without
    /// the family knowing why.
    func testRemoveTimeKeepsTheLastRow() {
        var draft = makeDraft()
        draft.addTime()

        draft.removeTime(at: 0)
        XCTAssertEqual(draft.times.count, 1)

        draft.removeTime(at: 0)
        XCTAssertEqual(draft.times.count, 1, "the last row cannot be removed")
        XCTAssertEqual(draft.storedTimes.count, 1)
    }

    /// An out-of-range index is ignored, not a crash.
    func testRemoveTimeIgnoresAnUnknownIndex() {
        var draft = makeDraft()
        draft.addTime()

        draft.removeTime(at: 9)
        draft.removeTime(at: -1)

        XCTAssertEqual(draft.times.count, 2)
    }

    // MARK: - Strength and purpose storage

    /// Blank strength is nil (house rule: blank text is never stored), and
    /// what is stored is trimmed.
    func testStoredStrengthIsNilWhenBlank() {
        var draft = makeDraft()
        XCTAssertNil(draft.storedStrength)

        draft.strength = "   "
        XCTAssertNil(draft.storedStrength)

        draft.strength = "  500 mg  "
        XCTAssertEqual(draft.storedStrength, "500 mg")
    }

    /// A chip is stored as its ID, and the lookup's words — being free text —
    /// release the chip and are stored verbatim, trimmed.
    func testPurposeLookupLandsInTheFreeTextFieldAndReleasesTheChip() {
        var draft = makeDraft()
        draft.purpose.select(.bloodPressure, locale: english)
        XCTAssertEqual(draft.storedPurpose, MedicationPurpose.bloodPressure.rawValue)

        draft.applyPurposeLookup("  Used to treat high blood pressure.  ")

        XCTAssertEqual(draft.storedPurpose, "Used to treat high blood pressure.")
        XCTAssertNil(draft.purpose.chip, "a lookup's words are the family's to edit, not a chip")
        XCTAssertEqual(draft.purpose.text, "Used to treat high blood pressure.")
    }

    /// A lookup that returned only whitespace leaves no purpose at all —
    /// never an empty string in the model.
    func testBlankLookupTextLeavesNoPurpose() {
        var draft = makeDraft()

        draft.applyPurposeLookup("   \n ")

        XCTAssertNil(draft.storedPurpose)
    }

    // MARK: - The slot model [MED-SLOT]: the shipped rules, not relaxed

    /// **The unchanged-rules pair, text half.** The slot model changes which
    /// rows a scan replaces and nothing about the text rules: a name the
    /// family typed survives the scan, a blank field still fills, and a
    /// field holding only spaces still counts as blank.
    func testScanFillsBlankFieldsOnly() {
        var draft = makeSlotDraft()
        draft.name = "Amo"

        draft.applyScan(MedicationLabelCandidate(
            name: "Amoxicillin",
            strength: "500 mg",
            scheduleTimes: [DateComponents(hour: 8, minute: 0)]))

        XCTAssertEqual(draft.name, "Amo", "a scan never overwrites what the family typed")
        XCTAssertEqual(draft.strength, "500 mg", "a blank field still fills")
        XCTAssertEqual(draft.slotRows, [.morning], "the label's schedule still replaces the rows")

        draft.name = "   "
        draft.applyScan(MedicationLabelCandidate(name: "Amoxicillin"))

        XCTAssertEqual(draft.name, "Amoxicillin", "whitespace is blank in the slot model too")
    }

    /// The shipped "the label's schedule wins" rule, applied to slot rows: a
    /// scan in `.slots` mode replaces the family's current assignments with
    /// the converted read, in FIRST-OCCURRENCE order, and the carrier rows
    /// stay parallel to the assignments (one form, rows = doses).
    func testScanReplacesSlotRowsShippedRule() {
        var draft = makeSlotDraft()
        draft.slotRows = [.afternoon]
        draft.mealRelation = .beforeMeal

        draft.applyScan(MedicationLabelCandidate(
            scheduleTimes: [DateComponents(hour: 8, minute: 0),
                            DateComponents(hour: 20, minute: 0)]))

        XCTAssertEqual(draft.slotRows, [.morning, .evening],
                       "the label's schedule wins over the form's assignment")
        XCTAssertEqual(draft.mealRelation, .beforeMeal,
                       "the meal relation was not inferred — the family's statement stands")
        XCTAssertNil(draft.storedQuantity, "a scan states no quantity")
        XCTAssertEqual(draft.times.count, draft.slotRows.count,
                       "the row carrier stays parallel to the slot rows")

        // First occurrence, not clock order: the conversion keeps the order
        // it saw, and so do the rows.
        var reversed = makeSlotDraft()
        reversed.applyScan(MedicationLabelCandidate(
            scheduleTimes: [DateComponents(hour: 20, minute: 0),
                            DateComponents(hour: 8, minute: 0)]))

        XCTAssertEqual(reversed.slotRows, [.evening, .morning])
    }

    /// An empty read changes NOTHING in the slot model either — no field, no
    /// row, no assignment — and a read that found a name but stated no
    /// schedule still only fills blank text.
    func testEmptyReadChangesNothing() {
        var draft = makeSlotDraft()
        draft.name = "Amlodipine"
        draft.strength = "5 mg"
        draft.quantity.amount = 1
        draft.quantity.select(.tablet, locale: english)
        draft.mealRelation = .beforeMeal
        draft.applyScan(MedicationLabelCandidate(scheduleTimes: [DateComponents(hour: 8, minute: 0)]))
        let before = draft

        draft.applyScan(.empty)

        XCTAssertEqual(draft, before)

        var named = before
        named.name = ""
        named.applyScan(MedicationLabelCandidate(name: "Amlodipine"))

        XCTAssertEqual(named.name, "Amlodipine", "the text rule still applies")
        XCTAssertEqual(named.slotRows, before.slotRows, "a name-only read states no schedule")
        XCTAssertEqual(named.times, before.times)
        XCTAssertEqual(named.mealRelation, .beforeMeal, "a scan never picks a meal relation")
        XCTAssertEqual(named.storedQuantity,
                       MedicationQuantity(amount: 1, unit: MedicationDoseUnit.tablet.rawValue),
                       "a scan never fills a quantity")
    }

    /// An unmapped read — times the pinned hour table (m-3) converts to no
    /// slot — leaves the rows exactly as they were: not cleared, not
    /// fitted, not "nearest". The table is a lookup, never a guess.
    func testUnmappedReadLeavesRowsUnchanged() {
        var draft = makeSlotDraft()
        draft.applyScan(MedicationLabelCandidate(
            scheduleTimes: [DateComponents(hour: 8, minute: 0),
                            DateComponents(hour: 19, minute: 0)]))
        XCTAssertEqual(draft.slotRows, [.morning, .evening])
        let before = draft

        draft.applyScan(MedicationLabelCandidate(
            scheduleTimes: [DateComponents(hour: 10, minute: 0)]))
        XCTAssertEqual(draft, before, "an unmapped read changes nothing — rows, carrier and all")

        // 10:30 is nearer morning 08:00 than afternoon 13:00, and still
        // nothing: no nearest-slot inference anywhere on this path.
        draft.applyScan(MedicationLabelCandidate(
            scheduleTimes: [DateComponents(hour: 10, minute: 30)]))
        XCTAssertEqual(draft, before)

        // A named unmapped read follows the text rule only.
        var named = before
        named.name = ""
        named.applyScan(MedicationLabelCandidate(
            name: "Amlodipine",
            scheduleTimes: [DateComponents(hour: 10, minute: 0)]))

        XCTAssertEqual(named.name, "Amlodipine")
        XCTAssertEqual(named.slotRows, before.slotRows)
        XCTAssertEqual(named.times, before.times)
    }

    /// Preselection is EXACT equality against the household mapping — hour
    /// AND minute — and only for rows the family has not assigned. A legacy
    /// entry is preselected while it is still in clock mode; nothing fuzzy,
    /// nothing clobbered, no silent conversion.
    func testSlotPreselectionIsExactEquality() {
        var draft = makeDraft()
        draft.name = "Amlodipine"
        draft.times = [date(hour: 8, minute: 0),      // == morning's mapped time
                       date(hour: 13, minute: 0),     // == afternoon's mapped time
                       date(hour: 20, minute: 0)]     // evening maps 19:00 — nearest, not equal
        draft.slotRows = [nil, nil, nil]

        draft.applySlotPreselection(mapping: .default)

        XCTAssertEqual(draft.scheduleMode, .times, "preselection never converts the model")
        XCTAssertEqual(draft.slotRows, [.morning, .afternoon, nil],
                       "exact matches preselect; a near miss stays unassigned")
        XCTAssertTrue(draft.canSaveRequest,
                      "clock mode stays saveable exactly as stored — nothing forces the conversion")

        // Only when the family CHOOSES the slot model does the unmatched row
        // gate the request, until it is assigned or removed.
        draft.scheduleMode = .slots
        XCTAssertFalse(draft.canSaveRequest)

        // The family's OWN mapping is what equality is measured against.
        var custom = makeDraft()
        custom.times = [date(hour: 7, minute: 30), date(hour: 12, minute: 45)]
        custom.slotRows = [nil, nil]
        let familyMapping = MedicationSlotClock(
            morning: TimeOfDay(hour: 7, minute: 30),
            afternoon: TimeOfDay(hour: 12, minute: 45),
            evening: TimeOfDay(hour: 21, minute: 10))

        custom.applySlotPreselection(mapping: familyMapping)

        XCTAssertEqual(custom.slotRows, [.morning, .afternoon])

        var nearMiss = makeDraft()
        nearMiss.times = [date(hour: 8, minute: 0)]
        nearMiss.slotRows = [nil]

        nearMiss.applySlotPreselection(mapping: familyMapping)

        XCTAssertEqual(nearMiss.slotRows, [nil], "08:00 is not 07:30 and not 12:45")

        // A corrupt mapping slot resolves .indeterminate and matches nothing
        // — fail-closed, never repaired into a plausible time.
        var corrupt = makeDraft()
        corrupt.times = [date(hour: 8, minute: 0)]
        corrupt.slotRows = [nil]
        let broken = MedicationSlotClock(
            morning: .unset,
            afternoon: TimeOfDay(hour: 13, minute: 0),
            evening: TimeOfDay(hour: 19, minute: 0))

        corrupt.applySlotPreselection(mapping: broken)

        XCTAssertEqual(corrupt.slotRows, [nil])

        // Preselection never clobbers a row the family assigned.
        var assigned = makeDraft()
        assigned.times = [date(hour: 8, minute: 0)]
        assigned.slotRows = [.evening]

        assigned.applySlotPreselection(mapping: .default)

        XCTAssertEqual(assigned.slotRows, [.evening])
    }

    /// `storedRows` is the save request's rows (IF-21), in row order: clock
    /// rows as their hour/minute-only components, slot rows as their slots.
    /// A manually added row appends and contributes no stored row until the
    /// family assigns it.
    func testStoredRowsShapeMatchesSaveRequest() {
        var clock = makeDraft()
        clock.applyScan(MedicationLabelCandidate(
            scheduleTimes: [DateComponents(hour: 13, minute: 15),
                            DateComponents(hour: 19, minute: 0)]))

        XCTAssertEqual(clock.storedRows,
                       [.time(DateComponents(hour: 13, minute: 15)),
                        .time(DateComponents(hour: 19, minute: 0))],
                       "clock rows carry hour/minute only — the stored shape")
        XCTAssertEqual(clock.storedRows.count, clock.times.count)

        var slot = makeSlotDraft()
        slot.name = "Amlodipine"
        slot.applyScan(MedicationLabelCandidate(
            scheduleTimes: [DateComponents(hour: 8, minute: 0),
                            DateComponents(hour: 20, minute: 0)]))

        XCTAssertEqual(slot.storedRows, [.slot(.morning), .slot(.evening)])

        slot.addTime()
        XCTAssertEqual(slot.storedRows, [.slot(.morning), .slot(.evening)],
                       "an unassigned row contributes no stored row")
        XCTAssertFalse(slot.canSaveRequest, "a name is not enough while a row is unassigned")

        slot.slotRows[2] = .afternoon
        XCTAssertEqual(slot.storedRows,
                       [.slot(.morning), .slot(.evening), .slot(.afternoon)],
                       "manually added rows append in row order")
        XCTAssertTrue(slot.canSaveRequest)
    }

    /// **The unchanged-rules pair, gate half.** The shipped save gate stands:
    /// a name, nothing else. Slot rows — assigned or not — neither make a
    /// nameless draft saveable nor block a named one; the request-readiness
    /// readout (`canSaveRequest`, IF-22) sits beside the gate and never
    /// replaces it.
    func testCanSaveStillNameOnly() {
        var draft = makeSlotDraft()
        draft.addTime()
        draft.slotRows = [.morning, nil]

        XCTAssertFalse(draft.canSave, "rows do not make a nameless draft saveable")
        XCTAssertFalse(draft.canSaveRequest)

        draft.name = "   "
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(draft.canSaveRequest)

        draft.name = "  Amlodipine  "
        XCTAssertTrue(draft.canSave, "the shipped gate: a name, trimmed")
        XCTAssertFalse(draft.canSaveRequest, "an unassigned slot row still gates the request")

        draft.slotRows = [.morning, .evening]
        XCTAssertTrue(draft.canSaveRequest)

        // Clock mode: every row is shaped by construction, so the request
        // gate is the name gate and nothing more.
        var clockMode = makeDraft()
        XCTAssertFalse(clockMode.canSaveRequest)
        clockMode.name = "Amlodipine"
        XCTAssertTrue(clockMode.canSaveRequest)
    }

    // MARK: - Frequency scans [MED-OCR-FREQ] (2026-10-15)

    /// The owner's device case, through the real parser: "one tablet twice
    /// a day" fills the slot form with exactly the rows the owner expected
    /// — afternoon and evening, after food — and nothing else changes.
    func testFrequencyScanFillsTwoSlotRowsAfterFood() {
        var draft = makeSlotDraft()
        draft.name = "Metformin"

        draft.applyScan(MedicationLabelParser.candidate(fromText: "1 tablet twice a day"))

        XCTAssertEqual(draft.slotRows, [.afternoon, .evening])
        XCTAssertEqual(draft.mealRelation, .afterMeal)
        XCTAssertEqual(draft.times.count, 2, "the row carrier stays parallel")
        XCTAssertEqual(hours(draft), [7, 7],
                       "carriers are the draft's own day — no scanned clock smuggled in")
        XCTAssertEqual(draft.storedRows, [.slot(.afternoon), .slot(.evening)])
        XCTAssertNil(draft.storedQuantity, "a scan still states no quantity")
        XCTAssertTrue(draft.canSaveRequest)
    }

    /// The family's stated relation is theirs: a frequency read replaces
    /// the ROWS (the label's schedule, the shipped rule) and fills only a
    /// BLANK relation.
    func testFrequencyScanNeverRewritesTheStatedRelation() {
        var draft = makeSlotDraft()
        draft.slotRows = [.morning]
        draft.mealRelation = .beforeMeal

        draft.applyScan(MedicationLabelParser.candidate(fromText: "1 tablet twice a day"))

        XCTAssertEqual(draft.slotRows, [.afternoon, .evening],
                       "the label's rows still replace the form's")
        XCTAssertEqual(draft.mealRelation, .beforeMeal,
                       "the family's statement stands")
    }

    /// A row-producing read now picks the after-food default when the
    /// label states no relational context (2026-10-15, the owner's rule):
    /// a day pattern names no meal, and unstated means after food on
    /// every label-derived row — not just the frequency table's.
    func testPatternScanDefaultsAfterFood() {
        var draft = makeSlotDraft()

        draft.applyScan(MedicationLabelParser.candidate(fromText: "1-0-1"))

        XCTAssertEqual(draft.slotRows, [.morning, .evening])
        XCTAssertEqual(draft.mealRelation, .afterMeal, "unstated defaults after food")
    }

    /// The owner's time-word case through the real parser: "morning and
    /// evening" with no meal mention fills the slot rows AND the
    /// after-food default the rows carry.
    func testTimeWordScanDefaultsAfterFood() {
        var draft = makeSlotDraft()

        draft.applyScan(MedicationLabelParser.candidate(fromText: "morning and evening"))

        XCTAssertEqual(draft.slotRows, [.morning, .evening])
        XCTAssertEqual(draft.mealRelation, .afterMeal)
    }

    /// A label that states "before food" fills the blank relation with
    /// its own statement — the default never overwrites an explicit
    /// mention.
    func testBeforeFoodScanFillsBeforeMeal() {
        var draft = makeSlotDraft()

        draft.applyScan(MedicationLabelParser.candidate(fromText: "morning before food"))

        XCTAssertEqual(draft.slotRows, [.morning])
        XCTAssertEqual(draft.mealRelation, .beforeMeal)
    }

    /// "Once daily" states a frequency and no time of day: nothing is
    /// filled, cleared or assigned — on the fresh form, one blank row for
    /// the family to pick, and the request gate waits for their choice.
    func testOnceDailyScanLeavesTheRowToFamily() {
        var draft = makeSlotDraft()
        draft.name = "Amlodipine"
        let before = draft

        draft.applyScan(MedicationLabelParser.candidate(fromText: "1 tablet once daily"))

        XCTAssertEqual(draft, before, "no times is no schedule — nothing changes")
        XCTAssertEqual(draft.slotRows, [nil], "one blank row: the family picks")
        XCTAssertTrue(draft.canSave)
        XCTAssertFalse(draft.canSaveRequest, "the request gate stays closed until they pick")
    }

    /// The clock model fills the same way: the frequency table's hours land
    /// in the pickers, the blank relation fills beside them, and a relation
    /// the family stated still stands.
    func testFrequencyScanInClockModeFillsTimesAndBlankRelationOnly() {
        var draft = makeDraft()
        draft.mealRelation = .beforeMeal

        draft.applyScan(MedicationLabelParser.candidate(fromText: "1 tablet twice a day"))

        XCTAssertEqual(hours(draft), [13, 19])
        XCTAssertEqual(draft.storedTimes, [DateComponents(hour: 13, minute: 0),
                                           DateComponents(hour: 19, minute: 0)])
        XCTAssertEqual(draft.mealRelation, .beforeMeal, "the family's statement stands")

        var fresh = makeDraft()
        fresh.applyScan(MedicationLabelParser.candidate(fromText: "1 tablet twice a day"))

        XCTAssertEqual(hours(fresh), [13, 19])
        XCTAssertEqual(fresh.mealRelation, .afterMeal, "a blank relation takes the label's")
    }
}
