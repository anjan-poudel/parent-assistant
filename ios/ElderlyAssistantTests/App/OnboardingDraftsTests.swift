import XCTest
@testable import ElderlyAssistant

/// T-097: the pure merge helpers the wizard steps and the Settings editor
/// share. Both callers merge through these values and save with the
/// coordinator's single writer, so the semantics pinned here are the
/// feature's only normalization rules (trim; empty→nil for GP/hospital;
/// DOB as year/month/day components with no calendar or timezone).
final class OnboardingDraftsTests: XCTestCase {

    private func profile(name: String = "Maya",
                         addressAs: String = "Mum",
                         year: Int? = 1955,
                         emergencyDoctor: String? = "Dr. Rai",
                         localHospital: String? = "Patan Hospital") -> UserProfile {
        UserProfile(
            name: name,
            addressAs: addressAs,
            dateOfBirth: year.map { DateComponents(year: $0, month: 6, day: 2) },
            emergencyDoctor: emergencyDoctor,
            localHospital: localHospital
        )
    }

    // MARK: - The mandatory-fields predicate (FR-PI-002 / FR-PI-016)

    func testTheNextGateAndTheRoutingPredicateAreOneRule() {
        XCTAssertTrue(AboutYouDraft.mandatoryFieldsRecorded(
            name: " Maya ", addressAs: "Mum"))
        XCTAssertTrue(AboutYouDraft.mandatoryFieldsRecorded(in: profile()))
        XCTAssertFalse(AboutYouDraft.mandatoryFieldsRecorded(
            name: "   ", addressAs: "Mum"),
            "whitespace is not a name")
        XCTAssertFalse(AboutYouDraft.mandatoryFieldsRecorded(
            name: "Maya", addressAs: "\n\t"),
            "whitespace is not an address-as term")
        XCTAssertFalse(AboutYouDraft.mandatoryFieldsRecorded(
            name: "", addressAs: ""))
    }

    func testIsCompleteMirrorsTheStaticPredicate() {
        var draft = AboutYouDraft()
        XCTAssertFalse(draft.isComplete)
        draft.name = " Maya "
        XCTAssertFalse(draft.isComplete, "both fields are required")
        draft.addressAs = " Mum "
        XCTAssertTrue(draft.isComplete,
                      "trimmed non-empty in both fields is complete")
        draft.name = "   "
        XCTAssertFalse(draft.isComplete)
    }

    // MARK: - About-you merge

    func testMergeTrimsAndPreservesTheFieldsTheStepDoesNotEdit() {
        let base = profile()
        let draft = AboutYouDraft(name: "  Maya  ", addressAs: "  Amma ")
        let merged = draft.merged(into: base)
        XCTAssertEqual(merged.name, "Maya")
        XCTAssertEqual(merged.addressAs, "Amma")
        XCTAssertEqual(merged.emergencyDoctor, "Dr. Rai",
                       "GP is preserved across an About-you save")
        XCTAssertEqual(merged.localHospital, "Patan Hospital")
        XCTAssertEqual(merged.dateOfBirth, base.dateOfBirth,
                       "DOB follows the draft only; here it preserves the base")
    }

    func testDateOfBirthIsComponentOnlyAndFollowsTheToggle() {
        // Toggle OFF: the recorded value is nil, even with a base date.
        var off = AboutYouDraft(name: "Maya", addressAs: "Mum")
        off.dateOfBirth = Date()
        off.hasDateOfBirth = false
        let mergedOff = off.merged(into: self.profile())
        XCTAssertNil(mergedOff.dateOfBirth,
                     "a disabled toggle records no date")

        // Toggle ON: year/month/day only — no calendar, no timezone, no
        // time-of-day fields.
        var on = AboutYouDraft(name: "Maya", addressAs: "Mum")
        var components = DateComponents()
        components.year = 1955
        components.month = 6
        components.day = 2
        components.hour = 11
        components.minute = 30
        on.dateOfBirth = Calendar.current.date(from: components)
        on.hasDateOfBirth = true
        XCTAssertNotNil(on.dateOfBirth)
        let mergedOn = on.merged(into: self.profile(year: nil))
        let stored = mergedOn.dateOfBirth
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.year, 1955)
        XCTAssertEqual(stored?.month, 6)
        XCTAssertEqual(stored?.day, 2)
        XCTAssertNil(stored?.calendar, "no calendar is attached")
        XCTAssertNil(stored?.timeZone, "no timezone is attached")
        XCTAssertNil(stored?.hour)
        XCTAssertNil(stored?.minute)
    }

    // MARK: - OB-2 merge base

    func testMergeBaseIsEmptyForAbsentAndUnreadableAndVerbatimForLoaded() {
        let stored = profile()
        XCTAssertEqual(ProfileLoadResult.loaded(stored).mergeBase, stored,
                       "a loaded result merges onto its own record verbatim")

        for result: ProfileLoadResult in [.absent,
                                          .unreadable(.readFailed),
                                          .unreadable(.decodeFailed)] {
            let base = result.mergeBase
            XCTAssertEqual(base.name, "")
            XCTAssertEqual(base.addressAs, "")
            XCTAssertNil(base.dateOfBirth)
            XCTAssertNil(base.emergencyDoctor)
            XCTAssertNil(base.localHospital)
        }
    }

    func testAbsentBaseSaveRepairsTheRecord() {
        // OB-2: the ordinary Next-and-save is the repair path — merging an
        // empty base still writes the complete draft record.
        let merged = AboutYouDraft(name: "Maya", addressAs: "Mum")
            .merged(into: ProfileLoadResult.unreadable(.decodeFailed).mergeBase)
        XCTAssertEqual(merged.name, "Maya")
        XCTAssertEqual(merged.addressAs, "Mum")
    }

    // MARK: - Emergency contacts merge

    func testGpAndHospitalTrimEmptyToNilAndPreserveTheRest() {
        let base = profile()
        let merged = EmergencyContactsDraft(emergencyDoctor: "  Dr. Rai  ",
                                            localHospital: "  ",
                                            nextOfKinID: UUID())
            .merged(into: base)
        XCTAssertEqual(merged.emergencyDoctor, "Dr. Rai")
        XCTAssertNil(merged.localHospital, "blank clears to nil")
        XCTAssertEqual(merged.name, base.name)
        XCTAssertEqual(merged.addressAs, base.addressAs)
        XCTAssertEqual(merged.dateOfBirth, base.dateOfBirth)
    }

    func testClearingBothFieldsIsLegal() {
        let merged = EmergencyContactsDraft()
            .merged(into: profile())
        XCTAssertNil(merged.emergencyDoctor)
        XCTAssertNil(merged.localHospital)
    }

    // MARK: - Bounds

    func testEntryBoundsDefaultsMatchTheDesign() {
        let bounds = ProfileEntryBounds.default
        XCTAssertEqual(bounds.addressAsMaxGraphemes, 24)
        XCTAssertEqual(bounds.nameMaxGraphemes, 60)
    }
}
