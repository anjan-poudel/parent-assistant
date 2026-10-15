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
//
// [MED-SLOT] (2026-10-15) The slot model rides the same split (design-l2 C8,
// IF-22). The draft gains the row model the family edits — clock rows
// (`.times`, the shipped form) or slot rows (`.slots`: a slot per row, plus
// the quantity and the before/after-meal relation the entry carries) — and
// the three shipped scan rules extend to it UNCHANGED: text pre-fills blank
// fields only, the label's stated schedule replaces the rows, and a read
// that found nothing changes nothing. Nothing here persists, resolves a
// clock time, or infers a slot, a meal relation or a quantity: the draft
// carries what the family stated, the slot clock (C1) resolves times at
// arming/save, and the save gate (C12) binds nothing until the family saves.

// MARK: - The slot model's vocabulary for the form

/// Which row model the form is editing (design-l2 C8): the shipped clock
/// rows, or the slot-model rows.
///
/// Per DRAFT, not per store: switching the model is a visible,
/// family-confirmed act in the form — a legacy entry opens in `.times` and
/// stays there unless the family chooses the slot controls (the
/// edit-existing rule: exact preselection, never a silent conversion).
enum ScheduleMode: Equatable {
    /// One `DatePicker` row per dose — the shipped editor's form, and the
    /// model every pre-slot entry and payload speaks.
    case times
    /// One slot row per dose: morning / afternoon / evening, with the
    /// meal relation and the quantity. The family states no clock time;
    /// the household mapping resolves the slot to an hour/minute at save
    /// and at arming (D2: an entry's `scheduleTimes` on a slot entry is a
    /// resolved-time mirror, never an arming input).
    case slots
}

/// One row of a save request (design-l2 IF-21): a dose stated either as an
/// exact clock time (a legacy row, or a family that stayed on the shipped
/// model) or as a slot.
///
/// Declared here because the draft is its first producer — `storedRows`
/// below is consumed by the W3 save plumbing (`MedicationSaveRequest`,
/// C12/IF-21) and by the editor surface's request-building (C8 view half).
/// The mixed-shape rule (all `.time` OR all `.slot`) belongs to the request
/// (C12), not to this value.
enum MedicationDoseRow: Equatable {
    case time(DateComponents)
    case slot(MedicationSlot)
}

/// The draft's quantity step: an amount plus a unit, in the
/// `MedicationPurposeDraft` chip-or-free-text shape (design-l2 C8; OD-2:
/// the seven built-in units ship as chips, and the family's own words —
/// "half tablet", a local unit name — are the free-text half).
///
/// The contract, one sentence — chips pre-fill the field, free text
/// overrides, and nothing is stored until both halves are stated: the
/// stored quantity is the chip's raw value while the field still reads as
/// its label, the typed words as soon as they differ, and nil when the
/// amount or the unit is missing. Nothing is defaulted (no invented "1",
/// no invented "tablet"), because a quantity the family never stated must
/// never reach a dose line.
struct MedicationQuantityDraft: Equatable {
    /// The amount the family stated — a positive whole number, the
    /// `MedicationQuantity` contract (T-001). nil = not stated; a zero or
    /// negative value is not a dose quantity and is never repaired into
    /// one (the editor's control keeps the family inside the range, and
    /// `storedValue` re-checks rather than clamps).
    var amount: Int?
    /// The unit chip the family tapped, while the field still reads as it.
    private(set) var unit: MedicationDoseUnit?
    /// What the unit field shows — the chip's label after a tap, the
    /// family's own words once they type.
    private(set) var text: String
    /// The exact label the selected chip wrote into the field, so "free
    /// text overrides" is decided by comparison and not by ordering — the
    /// purpose draft's comparison seam, applied to units.
    private var unitLabel: String?

    init() {
        amount = nil
        unit = nil
        text = ""
        unitLabel = nil
    }

    /// A unit chip was tapped: it becomes the selection and pre-fills the
    /// field with the chip's label, resolved through the T-012 catalog key
    /// `meds.unit.<id>` — the same key family the dose line renders
    /// through, never literal copy here.
    mutating func select(_ unit: MedicationDoseUnit, locale: Locale) {
        let label = L10n.str("meds.unit." + unit.rawValue, locale: locale)
        self.unit = unit
        unitLabel = label
        text = label
    }

    /// The unit field was edited. Any divergence from what the chip
    /// pre-filled — including clearing the field — ends the chip's claim
    /// on the value: what the family typed is what they meant.
    mutating func editText(_ newValue: String) {
        text = newValue
        if newValue != unitLabel { unit = nil }
    }

    /// What the save path stores: the chip's raw value, the family's own
    /// words, or nil. The both-or-nothing rule: an amount with no unit, or
    /// a unit with no amount, is a quantity the family has not stated —
    /// storing half of it would compose a dose line nobody wrote (rule 1
    /// of C2 composes "<amount> <unit>" only from a complete quantity).
    var storedValue: MedicationQuantity? {
        guard let amount, amount > 0 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let unit, let unitLabel, trimmed == unitLabel {
            return MedicationQuantity(amount: amount, unit: unit.rawValue)
        }
        return MedicationQuantity(amount: amount, unit: trimmed)
    }
}

/// Everything the "Scan label" flow can pre-fill, plus the purpose step,
/// plus the slot model's rows and dose context [MED-SLOT].
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
    /// The dose rows' clock values, as the `DatePicker` rows bind them —
    /// the ROW CARRIER for both models (row i of the form). Never empty: an
    /// entry with no dose time is not a schedule, so the last row cannot be
    /// removed.
    ///
    /// [MED-SLOT] In `.slots` mode these dates are a carrier only: the
    /// family stated no clock time, the values are never shown as a
    /// schedule and never saved as one (the save path resolves each row's
    /// slot through the household mapping — T-017; arming resolves fresh —
    /// D2). `storedTimes` below keeps its shipped `[.hour, .minute]` shape
    /// for the `.times` model.
    var times: [Date]
    /// The purpose step (chips + free text), unchanged from [MED-PURPOSE].
    var purpose: MedicationPurposeDraft
    /// Which row model the form is editing [MED-SLOT].
    var scheduleMode: ScheduleMode
    /// Row i's slot, parallel to `times` (one form, rows = doses): nil =
    /// the family has not assigned this row yet. Only `.slots` mode reads
    /// it; in `.times` mode the assignments are inert (and are reset when a
    /// scan replaces the rows — they belonged to the rows it replaced).
    var slotRows: [MedicationSlot?]
    /// The quantity step [MED-SLOT] (amount + unit, the chip-or-free-text
    /// shape).
    var quantity: MedicationQuantityDraft
    /// The before/after-meal relation, or nil when the family stated none.
    /// Context only (design-l1 §4.2): it is rendered in copy and on the
    /// dose screen, and it never moves the resolved time or adds a firing.
    var mealRelation: MealRelation?

    /// The calendar every `Date`/`DateComponents` conversion below uses.
    /// Injected so a test's pre-fill assertions are exact rather than
    /// dependent on the machine's time zone.
    private let calendar: Calendar
    /// The day the label's times are placed on — the editor's own "today"
    /// when the form opened. Only the HOUR and MINUTE ever reach the entry;
    /// the date is the picker's carrier.
    private let referenceDate: Date

    /// The shipped clock model by default: this initializer keeps every
    /// pre-slot call site and test on exactly the behavior it had. The
    /// new-entry FORM's `.slots` default (design-l2 C8) is the view's
    /// choice — it assigns the mode after constructing the draft — so the
    /// value type never silently changes what a caller already got.
    init(now: Date = Date(), calendar: Calendar = .current) {
        self.name = ""
        self.strength = ""
        self.times = [now]
        self.purpose = MedicationPurposeDraft()
        self.scheduleMode = .times
        self.slotRows = [nil]
        self.quantity = MedicationQuantityDraft()
        self.mealRelation = nil
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
    ///    [MED-SLOT] In `.slots` mode the same rule reaches the slot rows:
    ///    the read converts through `ScannedSchedule.slots(from:)` (T-005,
    ///    the pinned hour table m-3 — consumed, never re-derived here) and
    ///    the converted slots replace the rows in first-occurrence order. A
    ///    read whose times convert to NO slot is a read that stated no
    ///    schedule this form can use: it changes nothing, exactly like a
    ///    read with no times at all.
    ///  - **A read that found nothing changes nothing.** An empty candidate
    ///    leaves the form exactly as it was and the photo is still attached;
    ///    the scanner has already said out loud that it could not read it.
    ///  - **Nothing is inferred.** A scan never fills the quantity, never
    ///    picks a meal relation and never touches the purpose step: those
    ///    are the family's statements, and the label does not print them.
    mutating func applyScan(_ candidate: MedicationLabelCandidate) {
        if let scannedName = candidate.name, isBlank(name) {
            name = scannedName
        }
        if let scannedStrength = candidate.strength, isBlank(strength) {
            strength = scannedStrength
        }
        switch scheduleMode {
        case .times:
            applyTimeScan(candidate)
        case .slots:
            applySlotScan(candidate)
        }
    }

    /// The shipped schedule rule, for the clock model: the label's times
    /// replace the form's, in the order the parser produced them (already
    /// clock-ordered). The rows are replaced only when the label actually
    /// resolved to some: `times` never empty is this type's invariant (the
    /// save path needs one dose time), and a candidate the calendar could
    /// not place at all is a candidate that stated no schedule.
    ///
    /// The replaced rows leave no slot assignments behind: an assignment
    /// names a ROW, and these rows no longer exist.
    private mutating func applyTimeScan(_ candidate: MedicationLabelCandidate) {
        guard !candidate.scheduleTimes.isEmpty else { return }
        let scannedTimes = candidate.scheduleTimes.compactMap(date(from:))
        guard !scannedTimes.isEmpty else { return }
        times = scannedTimes
        slotRows = Array(repeating: nil, count: times.count)
    }

    /// The same rule, for the slot model: the converted slots replace the
    /// row assignments, and the carrier rows are rebuilt to match —
    /// parallel by construction, never a mismatched pair of arrays.
    ///
    /// The carrier dates are the draft's own reference day: a slot row
    /// carries no clock the family stated, so no scanned hour is smuggled
    /// into a picker it will never show. An empty conversion (no times, an
    /// unmapped hour, a time the table refuses) changes nothing at all.
    private mutating func applySlotScan(_ candidate: MedicationLabelCandidate) {
        let scannedSlots = ScannedSchedule.slots(from: candidate.scheduleTimes)
        guard !scannedSlots.isEmpty else { return }
        slotRows = scannedSlots.map(Optional.some)
        times = scannedSlots.map { _ in referenceDate }
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

    // MARK: - Slot preselection (the edit-existing flow)

    /// Pre-selects slots for rows the family has not assigned, by EXACT
    /// equality with the household mapping: a row whose hour:minute equals
    /// the mapped time for a slot, to the minute, selects that slot
    /// (morning / afternoon / evening order decides the first match).
    ///
    /// The rules that keep this honest:
    ///
    ///  - **Preselection, never conversion.** It fills the chips; the mode
    ///    is untouched (a legacy entry stays in `.times` until the family
    ///    chooses the slot controls) and nothing is stored — the save gate
    ///    is still the family's.
    ///  - **Exact equality only.** 08:15 does not "become" morning because
    ///    08:00 is nearest: a fuzzy match is a guess about a dose time,
    ///    and the design forbids it. Equality is measured against the
    ///    mapping the family has now: `resolve(slot:)` is the ONLY source
    ///    of the mapped time, and a slot the mapping cannot resolve
    ///    (fail-closed `.indeterminate`) matches nothing.
    ///  - **Nothing is clobbered.** A row the family has assigned keeps its
    ///    slot; only nil rows are filled. An unassigned row that matches
    ///    nothing stays nil, and the request gate (`canSaveRequest`) keeps
    ///    the save closed until the family assigns it or removes the row.
    mutating func applySlotPreselection(mapping: MedicationSlotClock) {
        for index in times.indices where slotRows.indices.contains(index) {
            guard slotRows[index] == nil else { continue }
            let components = calendar.dateComponents([.hour, .minute], from: times[index])
            guard let hour = components.hour, let minute = components.minute else { continue }
            for slot in MedicationSlot.allCases {
                guard case .success(let mapped) = mapping.resolve(slot: slot) else { continue }
                if mapped.hour == hour && mapped.minute == minute {
                    slotRows[index] = slot
                    break
                }
            }
        }
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

    // MARK: - Dose rows

    /// Adds a row. [MED-OCR] Not only for scans: a medicine taken twice a
    /// day is two rows, and the editor could only ever express one before
    /// this. [MED-SLOT] The appender serves both models — the new-entry
    /// form's "add another dose" control calls it too — so an added row is
    /// unassigned in slot mode (nil until the family picks a slot; slot
    /// ordering follows the scan conversion and manual rows append).
    mutating func addTime() {
        let last = times.last ?? referenceDate
        times.append(last.addingTimeInterval(3600))
        slotRows.append(nil)
    }

    /// Removes one row. The LAST row is never removed — the save path needs
    /// at least one dose row, and an empty row list would be a form that
    /// cannot be saved without the family knowing why. The row's slot
    /// assignment goes with it.
    mutating func removeTime(at index: Int) {
        guard times.count > 1, times.indices.contains(index) else { return }
        times.remove(at: index)
        if slotRows.indices.contains(index) {
            slotRows.remove(at: index)
        }
    }

    // MARK: - What gets stored

    /// The name as the entry stores it (trimmed; the save gate is `canSave`).
    var storedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The strength, or nil when the family left it blank (house rule: blank
    /// text is never stored).
    var storedStrength: String? { Self.normalizedOptional(strength) }

    /// The purpose, resolved by the chips/free-text rule.
    var storedPurpose: String? { purpose.storedValue }

    /// The quantity, resolved by the both-or-nothing rule (nil unless the
    /// family stated an amount and a unit).
    var storedQuantity: MedicationQuantity? { quantity.storedValue }

    /// The dose times as the model's hour/minute components.
    ///
    /// `[.hour, .minute]` deliberately, in this order: `MedicationEntry`'s
    /// schedule is a LOCAL TIME, and a component set that carried a day
    /// would make two entries for the same clock time compare unequal (the
    /// duplicate check in `AppCoordinator.addMedication`).
    var storedTimes: [DateComponents] {
        times.map { calendar.dateComponents([.hour, .minute], from: $0) }
    }

    /// The save request's rows (IF-21) [MED-SLOT], in row order:
    ///
    ///  - `.times` mode: every row as its hour/minute components — the
    ///    shipped shape, so a clock-mode save is byte-for-byte what it was.
    ///  - `.slots` mode: every ASSIGNED row as its slot. An unassigned row
    ///    contributes nothing (there is no "unassigned" dose row to save),
    ///    and `canSaveRequest` below is false while one remains — so a
    ///    request is only ever built from fully assigned rows.
    var storedRows: [MedicationDoseRow] {
        switch scheduleMode {
        case .times:
            return storedTimes.map(MedicationDoseRow.time)
        case .slots:
            return slotRows.compactMap { $0.map(MedicationDoseRow.slot) }
        }
    }

    /// Whether the form can be saved: a name and nothing else (the same gate
    /// the editor has always applied). The slot model does not touch it and
    /// no row state relaxes it — a nameless draft with perfect rows is still
    /// unsaveable.
    var canSave: Bool { !storedName.isEmpty }

    /// Whether a SAVE REQUEST could be built from this draft right now
    /// (IF-22): the name gate above, plus the row shape — `.slots` mode
    /// needs at least one row and every row assigned, `.times` mode's rows
    /// are shaped by construction. This is a readiness READOUT for the
    /// request-building caller (C12), not a second save rule: it gates
    /// nothing by itself, and `canSave` is unchanged beside it.
    var canSaveRequest: Bool {
        guard canSave else { return false }
        switch scheduleMode {
        case .times:
            return !storedRows.isEmpty
        case .slots:
            return !slotRows.isEmpty && slotRows.allSatisfy { $0 != nil }
        }
    }

    private func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
