import Foundation

// MARK: - Scanned schedule → slot pre-fill (FR-MSR-005 / FR-MSR-006, C9)
//
// The parser (`MedicationLabelParser.schedule(in:)`) answers "WHEN does the
// label say", in the convention hours its dose-time shapes emit. The slot
// model asks a different question — which time of day — so this small,
// pure helper sits BESIDE the parser (design-l2 C9, IF-23) and converts
// one into the other through the pinned hour table (m-3). The parser file
// itself is untouched by this feature.
//
// Pre-fill only: the candidates below are what the editor shows before the
// family saves, and the human save gate (FR-MSR-006) stands between them
// and anything the household's schedule binds.

/// The slot candidates a scanned label read implies (IF-23).
///
/// Pure and deterministic: no I/O, no stored state, no clock — the same
/// read always converts to the same candidates. No household re-timing
/// record is ever consulted here; a slot's exact clock time is resolved
/// later, at arming and display, never at this conversion.
enum ScannedSchedule {

    /// The pinned hour → slot table (m-3), keyed on the hour the parser
    /// emits. The parser's emitted-hour union is covered in full:
    ///
    /// - 8:00 → `.morning`
    /// - 12:00, 13:00 → `.afternoon`
    /// - 19:00, 20:00, 21:00 → `.evening`
    ///
    /// Every other hour fills nothing — no nearest slot, no inference, no
    /// guess. A convention time carries minute 0 and a slot carries no
    /// clock of its own, so the hour alone names the time of day.
    private static let hourTable: [Int: MedicationSlot] = [
        8: .morning,
        12: .afternoon,
        13: .afternoon,
        19: .evening,
        20: .evening,
        21: .evening
    ]

    /// Converts a parsed label read's dose times into slot candidates
    /// (IF-23). Order is the input's first-occurrence order, deduplicated
    /// per slot: a count-4 read (8:00, 13:00, 19:00, 21:00) converts to
    /// `[.morning, .afternoon, .evening]`.
    ///
    /// Fail-closed: an hour outside the table, or a time with no hour at
    /// all, contributes nothing. An unmapped read converts to the empty
    /// list — nothing to propose is the honest answer, and nothing here
    /// records a dose, a time or a store write.
    static func slots(from scheduleTimes: [DateComponents]) -> [MedicationSlot] {
        var slots: [MedicationSlot] = []
        for time in scheduleTimes {
            guard let hour = time.hour, let slot = hourTable[hour] else { continue }
            guard !slots.contains(slot) else { continue }
            slots.append(slot)
        }
        return slots
    }
}
