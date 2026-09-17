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
                           dose: String = "One tablet",
                           purpose: String? = nil) -> MedicationEntry {
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
            purpose: purpose,
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

        let presentation = MedicationVisualAidsPresentation(entry: entry)

        XCTAssertTrue(presentation.id.hasPrefix(entry.id.uuidString),
                      "the identity is still the entry — a re-fire presents again")
        XCTAssertEqual(presentation, MedicationVisualAidsPresentation(entry: entry),
                       "and two snapshots of the same entry are the same presentation")
    }

    /// ...but the identity carries the MODE too ([MED-PHOTO], 2026-09-17):
    /// a voice "what does it look like?" for a medicine whose DOSE screen is
    /// already up is a different presentation — one carries the dose prompt
    /// and "I took it", the other must not. Keyed by entry alone, the cover
    /// would swallow the swap and leave the acknowledge button on screen at
    /// a moment when nothing is due.
    func testIdentityDistinguishesTheDoseScreenFromTheIdentifyScreen() {
        let entry = makeEntry(aids: [VisualAid(filename: "box.jpg")])

        let dose = MedicationVisualAidsPresentation(entry: entry, mode: .dose)
        let identify = MedicationVisualAidsPresentation(entry: entry, mode: .identify)

        XCTAssertNotEqual(dose.id, identify.id)
        XCTAssertEqual(dose.id, MedicationVisualAidsPresentation(entry: entry).id,
                       "dose is the default mode — every pre-existing caller is unchanged")
        XCTAssertEqual(dose, MedicationVisualAidsPresentation(entry: entry, mode: .dose))
    }

    /// A single composition for the photo's caption, shared by the fired
    /// dose and the voice query, so the elder is told the same thing about
    /// the same medicine however the screen appeared.
    func testTheCaptionCarriesThePurposeWhenThereIsOne() {
        let english = Locale(identifier: "en")
        let nepali = Locale(identifier: "ne")

        XCTAssertEqual(
            MedicationVisualAidsPresentation.caption(medicationName: "अम्लोडिपिन",
                                                     purpose: "bloodPressure",
                                                     locale: nepali),
            "रक्तचापको औषधि — अम्लोडिपिन",
            "the approved caption shape: <purpose label> — <name>")
        XCTAssertEqual(
            MedicationVisualAidsPresentation.caption(medicationName: "Amlodipine",
                                                     purpose: "bloodPressure",
                                                     locale: english),
            "Blood pressure medicine — Amlodipine")
        XCTAssertEqual(
            MedicationVisualAidsPresentation.caption(medicationName: "Amlodipine",
                                                     purpose: "for the heart valve",
                                                     locale: english),
            "for the heart valve medicine — Amlodipine",
            "free text renders verbatim, exactly as it does in the settings row")
    }

    /// A household that files no purposes sees exactly the caption it saw
    /// before this feature: the bare name.
    func testTheCaptionIsTheBareNameWithoutAPurpose() {
        for purpose in [nil, "", "   "] as [String?] {
            XCTAssertEqual(
                MedicationVisualAidsPresentation.caption(medicationName: "Amlodipine",
                                                         purpose: purpose,
                                                         locale: Locale(identifier: "en")),
                "Amlodipine")
        }
    }

    /// The snapshot carries the purpose at present time — it is part of what
    /// the elder is being shown, so it rides the same snapshot as the name
    /// and the dose line.
    func testSnapshotCarriesThePurpose() {
        let entry = makeEntry(aids: [VisualAid(filename: "box.jpg")],
                              purpose: "bloodPressure")

        let presentation = MedicationVisualAidsPresentation(entry: entry)

        XCTAssertEqual(presentation.purpose, "bloodPressure")
        XCTAssertEqual(presentation.caption(locale: Locale(identifier: "ne")),
                       "रक्तचापको औषधि — Amlodipine")
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

    /// The purpose feature's strings — the editor's step, the ten chips, the
    /// caption and the two spoken lines — must resolve in both app languages
    /// too: an unresolved key here is a button that reads
    /// "meds.purpose.heart", or an elder being read a raw key out loud.
    func testPurposeStringsResolveInBothLanguages() {
        let keys = ["meds.purpose.label", "meds.purpose.freeTextPlaceholder",
                    "meds.purposeCaption", "meds.photoMissing", "meds.photoMultiple"]
            + MedicationPurpose.allCases.map(\.labelKey)

        for key in keys {
            for identifier in ["en", "ne"] {
                let value = L10n.str(key, locale: Locale(identifier: identifier))
                XCTAssertNotEqual(value, key, "\(key) must resolve for \(identifier)")
                XCTAssertFalse(value.isEmpty, "\(key) is empty for \(identifier)")
            }
        }
    }

    /// The spoken lines take arguments — a placeholder that lost its
    /// argument, or an argument with no placeholder, is a sentence read
    /// aloud with a hole in it.
    func testPurposePlaceholdersFormatInBothLanguages() {
        for identifier in ["en", "ne"] {
            let locale = Locale(identifier: identifier)
            let caption = L10n.fmt("meds.purposeCaption", locale: locale, "X")
            XCTAssertTrue(caption.contains("X"), "meds.purposeCaption must place its argument: \(caption)")
            XCTAssertFalse(caption.contains("%"), "no placeholder may survive formatting")

            let multiple = L10n.fmt("meds.photoMultiple", locale: locale, "A, B")
            XCTAssertTrue(multiple.contains("A, B"), "meds.photoMultiple must place its argument")
            XCTAssertFalse(multiple.contains("%"), "no placeholder may survive formatting")
        }
    }
}
