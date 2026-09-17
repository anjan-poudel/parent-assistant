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

    private func hours(_ draft: MedicationEditorDraft) -> [Int] {
        draft.times.map { calendar.dateComponents([.hour], from: $0).hour ?? -1 }
    }

    // MARK: - The fresh form

    /// One time row, nothing typed, nothing saveable — the shape the editor
    /// has always opened with.
    func testFreshDraftHasOneTimeAndCannotBeSaved() {
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
    func testScanFillsFieldsHoldingOnlyWhitespace() {
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
    func testScanReplacesTheFormTimesWithTheLabel() {
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
}
