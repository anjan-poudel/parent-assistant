import XCTest
@testable import ElderlyAssistant

/// The snapshot the medication photo surfaces present
/// (medication-visual-aids task, 2026-09-16).
///
/// One type feeds three callers — the fired-dose screen (a delivered
/// reminder), the Meds leaf's dose row and the Reminders leaf's dose row —
/// so this is where "what the elder is shown" is pinned: the name and dose
/// line the entry had when the screen was OPENED, never whatever the entry
/// says later. A dose is safety-critical: silently swapping the text under
/// an elder mid-confirmation is the bug this value type exists to prevent.
final class MedicationVisualAidPresentationTests: XCTestCase {

    private func makeEntry(aids: [VisualAid] = [],
                           name: String = "Amlodipine",
                           dose: String = "One tablet") -> MedicationEntry {
        MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: name,
            doseDescription: dose,
            scheduleTimes: [DateComponents(hour: 8, minute: 0)],
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: false,
            confirmationDescription: nil,
            visualAids: aids
        )
    }

    func testSnapshotCarriesTheEntrysNameDoseAndPhotos() {
        let aids = [VisualAid(filename: "box.jpg", caption: "the blue box"),
                    VisualAid(filename: "pack.jpg")]
        let entry = makeEntry(aids: aids)

        let presentation = MedicationVisualAidsPresentation(entry: entry)

        XCTAssertEqual(presentation.entryId, entry.id)
        XCTAssertEqual(presentation.medicationName, "Amlodipine")
        XCTAssertEqual(presentation.doseDescription, "One tablet")
        XCTAssertEqual(presentation.aids, aids)
    }

    /// `fullScreenCover(item:)` keys on this, and the same medication entry
    /// fires again tomorrow (twice a day for a twice-daily dose) — the
    /// identity is the ENTRY, so a re-fire of the same dose presents again
    /// rather than being swallowed as "already showing".
    func testIdentityIsTheMedicationEntryId() {
        let entry = makeEntry(aids: [VisualAid(filename: "box.jpg")])

        XCTAssertEqual(MedicationVisualAidsPresentation(entry: entry).id, entry.id)
    }

    /// The snapshot is taken at present time, so a later edit to the same
    /// entry cannot change what a screen already on display is showing.
    /// (The name and dose line are immutable on the entry — a schedule edit
    /// builds a new one — so the photos are the part that can move while a
    /// dose screen is up.)
    func testSnapshotDoesNotFollowLaterEditsToTheEntry() {
        var entry = makeEntry(aids: [VisualAid(filename: "box.jpg")])
        let presentation = MedicationVisualAidsPresentation(entry: entry)

        entry.visualAids = []

        XCTAssertEqual(presentation.medicationName, "Amlodipine")
        XCTAssertEqual(presentation.doseDescription, "One tablet")
        XCTAssertEqual(presentation.aids.count, 1,
                       "the dose screen keeps the photo it opened with")
    }

    func testSnapshotsOfTheSameEntryAreEqual() {
        let entry = makeEntry(aids: [VisualAid(filename: "box.jpg")])

        XCTAssertEqual(MedicationVisualAidsPresentation(entry: entry),
                       MedicationVisualAidsPresentation(entry: entry))
    }

    // MARK: - The dose screen's strings

    /// The dose screen's prompt is the one NEW string this feature adds —
    /// it must resolve in both app languages rather than render its raw key
    /// in front of an elder (the same check `VisualAidDisplayStateTests`
    /// makes for the page indicator).
    func testDoseScreenStringsResolveInBothLanguages() {
        for key in ["meds.firePrompt", "meds.iTookIt"] {
            for identifier in ["en", "ne"] {
                let value = L10n.str(key, locale: Locale(identifier: identifier))
                XCTAssertNotEqual(value, key, "\(key) must resolve for \(identifier)")
                XCTAssertFalse(value.isEmpty, "\(key) is empty for \(identifier)")
            }
        }
    }
}
