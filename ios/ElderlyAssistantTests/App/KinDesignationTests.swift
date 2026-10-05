import XCTest
@testable import ElderlyAssistant

/// T-100's one-tap next-of-kin designation (profile-interview; added in
/// rework pass 1 on the review's recommendation): a tap must plan the
/// SINGULAR flag write — the tapped contact flagged true, every other
/// currently-flagged contact cleared — and every planned write must
/// carry the contact's current field values verbatim, so the flag write
/// can never clear a field edited elsewhere.
///
/// `EmergencyContactsStep.designate` executes exactly this plan through
/// `AppCoordinator.updateFamilyContact` (one call per entry, passing the
/// entry's contact values and its flag), so the plan is the decision
/// logic the T-100 DoD names; these tests pin it.
final class KinDesignationTests: XCTestCase {

    // MARK: - Synthetic fixtures (no real contact data)

    private func contact(_ name: String,
                         flagged: Bool = false,
                         nickname: String? = nil,
                         address: String? = nil,
                         email: String? = nil,
                         phone: String = "9800000000") -> FamilyContact {
        FamilyContact(name: name,
                      phone: phone,
                      relationship: "family",
                      messengerHandle: "same-handle",
                      nickname: nickname,
                      address: address,
                      email: email,
                      isEmergencyContact: flagged)
    }

    // Scenario: a tap on an unflagged contact clears the flagged others
    // and sets the tapped one — the singular designation.
    func testATapPlansTheSingularDesignation() {
        let first = contact("A", flagged: true)
        let second = contact("B", flagged: true)
        let third = contact("C")            // neither tapped nor flagged
        let tapped = contact("D")

        let plan = KinDesignation.plan(contacts: [first, second, third, tapped],
                                       tapped: tapped)

        XCTAssertEqual(plan.map(\.contact.id), [first.id, second.id, tapped.id],
                       "flagged others clear first, then the tap sets; the "
                       + "unflagged other is not written at all")
        XCTAssertEqual(plan.map(\.isEmergencyContact), [false, false, true],
                       "exactly one flag set and every other flag cleared — "
                       + "the singular designation the T-100 DoD names")
    }

    // Scenario: tapping the already-flagged contact stays singular (its
    // own set only — there is nothing else to clear).
    func testTappingTheAlreadyFlaggedContactPlansOnlyItsOwnSet() {
        let flagged = contact("A", flagged: true)
        let other = contact("B")

        let plan = KinDesignation.plan(contacts: [flagged, other],
                                       tapped: flagged)

        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.contact.id, flagged.id)
        XCTAssertEqual(plan.first?.isEmergencyContact, true)
        XCTAssertFalse(plan.contains { $0.contact.id == other.id },
                       "an unflagged contact is never written by a tap")
    }

    // Scenario: current values preserved — each planned entry carries the
    // source contact exactly (the flag being the only delta), including
    // the optional fields the Settings editor owns.
    func testEveryPlannedEntryCarriesTheContactsCurrentValuesVerbatim() {
        let flagged = contact("Bimala", flagged: true,
                              nickname: "Bim", address: "Lalitpur",
                              email: "b@example.com")
        let tapped = contact("Sita",
                             nickname: "Sit", address: "Kathmandu",
                             email: "s@example.com")

        let plan = KinDesignation.plan(contacts: [flagged, tapped],
                                       tapped: tapped)

        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].contact, flagged,
                       "the clearing entry carries the stored contact verbatim")
        XCTAssertEqual(plan[1].contact, tapped,
                       "the setting entry carries the stored contact verbatim")
        XCTAssertEqual(plan[1].contact.nickname, "Sit")
        XCTAssertEqual(plan[1].contact.address, "Kathmandu")
        XCTAssertEqual(plan[1].contact.email, "s@example.com")
        XCTAssertEqual(plan[1].contact.messengerHandle, "same-handle")
    }

    // Scenario: the tapped entry is the value handed to the tap (an
    // edited snapshot of the same id), and that id is never planned as
    // both a clear and a set.
    func testTheTappedContactIsPlannedOnceWithTheHandedValue() {
        let other = contact("B", flagged: true)
        var tappedEdit = contact("A", flagged: true, nickname: "old")
        tappedEdit.nickname = "new"

        let plan = KinDesignation.plan(contacts: [other, tappedEdit],
                                       tapped: tappedEdit)

        XCTAssertEqual(plan.map(\.contact.id), [other.id, tappedEdit.id],
                       "one entry per id — the tap's own id is excluded "
                       + "from the clears")
        XCTAssertEqual(plan.map(\.isEmergencyContact), [false, true])
        XCTAssertEqual(plan[1].contact.nickname, "new",
                       "the tap writes the value it was handed")
    }
}
