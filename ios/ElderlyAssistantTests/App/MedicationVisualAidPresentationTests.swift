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

    // MARK: - Evidence capture surfaces ([MED-EVIDENCE], T-021)

    /// The photo-as-evidence affordance belongs to the FIRED dose and to
    /// nothing else, and everything about it is pinned here: the pure seam
    /// decides it, the dose screen's own source renders it under that seam
    /// as an elderly-fit control, and its copy — the button, the one
    /// outcome mapping shared with the spoken line, every key the surfaces
    /// render — resolves in both app languages rather than putting a raw
    /// key in front of an elder.
    func testAffordancePresentOnFiredDoseScreen() {
        XCTAssertTrue(MedicationVisualAidsPresentation.showsEvidenceAffordance(mode: .dose),
                      "a fired dose invites the photo of it")
        XCTAssertFalse(MedicationVisualAidsPresentation.showsEvidenceAffordance(mode: .identify),
                       "an identify screen must not grow a capture path — a photo there "
                       + "would be evidence for a dose that is not happening")

        let screen = viewSource(named: "MedicationDoseFireScreen")
        XCTAssertTrue(screen.contains("meds.evidence.capture"),
                      "the dose screen carries the capture affordance")
        XCTAssertTrue(screen.contains("showsEvidenceAffordance(mode: mode)"),
                      "…rendered under the pinned seam, never an ad-hoc mode check")
        XCTAssertTrue(screen.contains("onCaptureEvidence"),
                      "…routed through the capture closure the host binds")

        // The control itself: the elderly-fit tap floor and a type token,
        // never a literal point size.
        let button = region(screen, from: "Label(\"meds.evidence.capture\"",
                            to: "if let evidenceNoticeKey")
        XCTAssertTrue(button.contains("frame(minHeight: DesignTokens.minTapTargetSize)"),
                      "the capture control clears the elderly-fit tap floor")
        XCTAssertTrue(button.contains(".appSurface(role: .control"),
                      "…and draws as a control, the house surface role")
        let fontLines = button.split(separator: "\n").map(String.init)
            .filter { $0.contains(".font(") }
        XCTAssertFalse(fontLines.isEmpty, "the capture label carries a font")
        for line in fontLines {
            XCTAssertTrue(line.contains("appearance.typography."),
                          "a new control's type comes from the appearance tokens: \(line)")
        }

        // The ONE outcome mapping — the drawn caption and the spoken line
        // share it — pinned case by case: nil shows nothing; a deferred
        // capture says "not yet delivered"; a failed or declined capture is
        // the honest "could not be saved" (in the declined case the photo
        // really is gone).
        XCTAssertNil(MedicationVisualAidsPresentation.evidenceOutcomeKey(for: nil))
        XCTAssertEqual(MedicationVisualAidsPresentation.evidenceOutcomeKey(
                           for: .held(entryId: UUID())),
                       "meds.evidence.notYetDelivered")
        XCTAssertEqual(MedicationVisualAidsPresentation.evidenceOutcomeKey(
                           for: .attached(logId: UUID())),
                       "meds.evidence.attached")
        XCTAssertEqual(MedicationVisualAidsPresentation.evidenceOutcomeKey(
                           for: .declinedNoContext),
                       "meds.evidence.failed")
        XCTAssertEqual(MedicationVisualAidsPresentation.evidenceOutcomeKey(
                           for: .failed(.compressionFailed)),
                       "meds.evidence.failed")

        // Every key the capture surfaces render resolves in both app
        // languages.
        let keys = ["meds.evidence.capture", "meds.evidence.attached",
                    "meds.evidence.failed", "meds.evidence.notYetDelivered",
                    "meds.evidence.spoken", "meds.takenToday.title", "meds.taken"]
        for key in keys {
            for identifier in ["en", "ne"] {
                let value = L10n.str(key, locale: Locale(identifier: identifier))
                XCTAssertNotEqual(value, key, "\(key) must resolve for \(identifier)")
                XCTAssertFalse(value.isEmpty, "\(key) is empty for \(identifier)")
            }
        }
    }

    /// D11: the announce that opens a capture NAMES the medicine it is for —
    /// the BOUND presentation's own name, composed through the one catalog
    /// line, spoken BEFORE the camera opens. The overlay may only pass what
    /// is on screen, and the flow may only speak the shared composition.
    func testAnnounceNamesTheBoundMedication() {
        for identifier in ["en", "ne"] {
            let locale = Locale(identifier: identifier)
            let line = MedicationVisualAidsPresentation.evidenceAnnounceLine(
                medicationName: "Amlodipine", locale: locale)
            XCTAssertNotEqual(line, "meds.evidence.spoken",
                              "the announce is composed, never the raw key")
            XCTAssertTrue(line.contains("Amlodipine"),
                          "the announce names the bound medicine (\(identifier)): \(line)")
            XCTAssertFalse(line.contains("%"), "no placeholder may survive formatting")

            let devanagari = MedicationVisualAidsPresentation.evidenceAnnounceLine(
                medicationName: "अम्लोडिपिन", locale: locale)
            XCTAssertTrue(devanagari.contains("अम्लोडिपिन"))
            XCTAssertFalse(devanagari.contains("Amlodipine"),
                           "the line names exactly the medicine it was composed with")
        }

        // The overlay binds the SAME presentation that is on screen: the
        // name the announce speaks and the entry the hold binds are read
        // off `fired`, never re-resolved.
        let overlay = viewSource(named: "MedicationVisualAidOverlay")
        XCTAssertTrue(overlay.contains("medicationName: fired.medicationName"),
                      "the announce takes the displayed medicine's own name")
        XCTAssertTrue(overlay.contains("context: .pendingDose(entryId: fired.entryId)"),
                      "…and the hold binds the displayed entry's own id")

        // …and the flow speaks the ONE shared composition, before the
        // camera opens (the announce is the elder's context for the photo).
        let flow = coordinatorRegion("func captureMedicationEvidence(",
                                     to: "func takenDosesToday()")
        XCTAssertTrue(flow.contains("MedicationVisualAidsPresentation.evidenceAnnounceLine("),
                      "the announce is the one shared composition")
        XCTAssertTrue(flow.contains("speak(text:"),
                      "…spoken, not merely composed")
        guard let announce = flow.range(of: "evidenceAnnounceLine("),
              let present = flow.range(of: "presentCamera") else {
            return XCTFail("the capture flow must both announce and present")
        }
        XCTAssertLessThan(announce.lowerBound, present.lowerBound,
                          "D11: the medicine is named BEFORE the camera opens")
    }

    // MARK: - Source slicing (the editor-suite idiom)

    /// The text of one top-level declaration in
    /// `MedicationVisualAidViews.swift`, comment-stripped and sliced at
    /// column-0 boundaries: a key rendered by a neighbouring view in the
    /// same file cannot pass for this one's.
    private func viewSource(named name: String) -> String {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/MedicationVisualAidViews.swift")
        let text = FeatureSourceScan.codeText(of: url)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("struct \(name)")
        }) else {
            XCTFail("MedicationVisualAidViews.swift has no top-level struct \(name)")
            return ""
        }
        let end = lines[(start + 1)...].firstIndex { line in
            ["struct ", "enum ", "extension ", "final class ", "class "]
                .contains { line.hasPrefix($0) }
        } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    /// A region of the coordinator's own source (comment-stripped), between
    /// two code markers — for the flow arrangements that must hold in the
    /// code, not just in the pieces.
    private func coordinatorRegion(_ start: String, to end: String) -> String {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift")
        let text = FeatureSourceScan.codeText(of: url)
        guard let startRange = text.range(of: start) else {
            XCTFail("AppCoordinator.swift has no `\(start)`")
            return ""
        }
        guard let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
            XCTFail("no `\(end)` after `\(start)`")
            return ""
        }
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    /// The text between two code markers within an already-sliced source, or
    /// an explicit failure — the house `region` convention.
    private func region(_ text: String, from start: String, to end: String,
                        file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let startRange = text.range(of: start) else {
            XCTFail("no `\(start)` in the sliced source", file: file, line: line)
            return ""
        }
        guard let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
            XCTFail("no `\(end)` after `\(start)`", file: file, line: line)
            return ""
        }
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }
}
