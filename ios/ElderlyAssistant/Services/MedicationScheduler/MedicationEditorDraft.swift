import Foundation

// [MED-OCR] (2026-09-18) The medication editor's draft, as a value.
//
// The view owns `@State` for the form; this type owns the RULES for moving a
// scan's result into it, because those rules are the part with a failure
// mode: a pre-fill that overwrote what a family member had already typed, or
// that dropped a schedule the label stated, is a form that quietly lies about
// what the household entered. Same split as `MedicationPurposeDraft`: the
// view moves values in and reads the result out, and the rule is tested
// without a view.

/// Everything the "Scan label" flow can pre-fill, plus the purpose step.
///
/// `strength` is the printed dose strength ("500 mg") and is stored in the
/// entry's existing `doseDescription` — the field the fired-dose screen and
/// the morning briefing already render as the dose line. An entry added
/// before this feature keeps its own dose text; nothing is migrated.
struct MedicationEditorDraft: Equatable {

    /// The medicine's name, as typed or as read.
    var name: String
    /// The printed strength. Blank means "not stated" — the entry stores nil.
    var strength: String
    /// Dose times, as the `DatePicker` rows bind them. Never empty: an entry
    /// with no dose time is not a schedule, so the last row cannot be
    /// removed.
    var times: [Date]
    /// The purpose step (chips + free text), unchanged from [MED-PURPOSE].
    var purpose: MedicationPurposeDraft

    /// The calendar every `Date`/`DateComponents` conversion below uses.
    /// Injected so a test's pre-fill assertions are exact rather than
    /// dependent on the machine's time zone.
    private let calendar: Calendar
    /// The day the label's times are placed on — the editor's own "today"
    /// when the form opened. Only the HOUR and MINUTE ever reach the entry;
    /// the date is the picker's carrier.
    private let referenceDate: Date

    init(now: Date = Date(), calendar: Calendar = .current) {
        self.name = ""
        self.strength = ""
        self.times = [now]
        self.purpose = MedicationPurposeDraft()
        self.calendar = calendar
        self.referenceDate = now
    }

    // MARK: - Scanning

    /// Drops a scan's candidate into the form.
    ///
    /// The rules, in one place because they are the feature's contract:
    ///
    ///  - **Text is never taken from the family.** A name or strength is
    ///    filled only while the field is still BLANK. Scanning a box after
    ///    typing "Amox" must not replace what they typed with what the OCR
    ///    thought it saw — the machine is the assistant here, not the author.
    ///  - **The label's schedule wins.** Times the label states replace the
    ///    form's, including a time the family had set: they just asked the
    ///    label to fill this form, the times are visible as pickers, and a
    ///    half-updated schedule (name from the box, times from before) is
    ///    the one outcome nobody can reason about. A label that states no
    ///    schedule changes nothing.
    ///  - **A read that found nothing changes nothing.** An empty candidate
    ///    leaves the form exactly as it was and the photo is still attached;
    ///    the scanner has already said out loud that it could not read it.
    mutating func applyScan(_ candidate: MedicationLabelCandidate) {
        if let scannedName = candidate.name, isBlank(name) {
            name = scannedName
        }
        if let scannedStrength = candidate.strength, isBlank(strength) {
            strength = scannedStrength
        }
        guard !candidate.scheduleTimes.isEmpty else { return }
        let scannedTimes = candidate.scheduleTimes.compactMap(date(from:))
        // The rows are replaced only when the label actually resolved to
        // some: `times` never empty is this type's invariant (the save path
        // needs one dose time), and a candidate the calendar could not place
        // at all is a candidate that stated no schedule.
        guard !scannedTimes.isEmpty else { return }
        times = scannedTimes
    }

    /// The parsed times as `Date`s on the draft's own day, in the order the
    /// parser produced them (already clock-ordered). A component the
    /// calendar cannot resolve is dropped rather than defaulted to midnight —
    /// a dose at 00:00 that nobody asked for is worse than one fewer row.
    private func date(from components: DateComponents) -> Date? {
        guard let hour = components.hour, let minute = components.minute else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0,
                             of: referenceDate)
    }

    // MARK: - The lookup's landing spot

    /// The text a purpose lookup returned, put where the family's own words
    /// go: the free-text field, which by `MedicationPurposeDraft`'s rule
    /// releases any chip the field's text came from. The lookup is a
    /// SUGGESTION, so it lands in the editable half of the step and never
    /// silently becomes a chip selection.
    mutating func applyPurposeLookup(_ text: String) {
        purpose.editText(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Time rows

    /// Adds a picker row. [MED-OCR] Not only for scans: a medicine taken
    /// twice a day is two times, and the editor could only ever express one
    /// before this.
    mutating func addTime() {
        let last = times.last ?? referenceDate
        times.append(last.addingTimeInterval(3600))
    }

    /// Removes one row. The LAST row is never removed — the save path needs
    /// at least one dose time, and an empty picker list would be a form that
    /// cannot be saved without the family knowing why.
    mutating func removeTime(at index: Int) {
        guard times.count > 1, times.indices.contains(index) else { return }
        times.remove(at: index)
    }

    // MARK: - What gets stored

    /// The name as the entry stores it (trimmed; the save gate is `canSave`).
    var storedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The strength, or nil when the family left it blank (house rule: blank
    /// text is never stored).
    var storedStrength: String? { Self.normalizedOptional(strength) }

    /// The purpose, resolved by the chips/free-text rule.
    var storedPurpose: String? { purpose.storedValue }

    /// The dose times as the model's hour/minute components.
    ///
    /// `[.hour, .minute]` deliberately, in this order: `MedicationEntry`'s
    /// schedule is a LOCAL TIME, and a component set that carried a day
    /// would make two entries for the same clock time compare unequal (the
    /// duplicate check in `AppCoordinator.addMedication`).
    var storedTimes: [DateComponents] {
        times.map { calendar.dateComponents([.hour, .minute], from: $0) }
    }

    /// Whether the form can be saved: a name and nothing else (the same gate
    /// the editor has always applied).
    var canSave: Bool { !storedName.isEmpty }

    private func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
