import XCTest
@testable import ElderlyAssistant

/// The family contact save-gate, as a pure function — the editor's
/// `canSave` reads `FamilyContactValidation.issue(email:isEmergencyContact:)`,
/// so these rule tests need no View, no store and no storage.
///
/// The one rule is deliberately asymmetric:
///
///  - an ORDINARY contact may save with any address, including none —
///    an address-less relative simply receives no calendar invitation;
///  - an EMERGENCY contact must have a well-formed one, because the
///    invite policy makes emergency contacts attendees of every shared
///    event, so a blank field there is a silent hole in the safety net.
final class FamilyContactValidationTests: XCTestCase {

    // MARK: - The emergency rule

    func testEmergencyContactWithABlankAddressCannotBeSaved() {
        // Blank is a distinct issue from invalid on purpose: the hint
        // asks for "an email", and asking for an email from someone who
        // already typed one is the kind of lie that makes an elder
        // distrust the whole screen.
        for blank in ["", " ", "   ", "\n", "\t\t", " \n "] {
            XCTAssertEqual(
                FamilyContactValidation.issue(email: blank, isEmergencyContact: true),
                FamilyContactValidation.Issue.emailRequired,
                "\"\(blank)\" is a blank field, not a wrong address")
        }
    }

    func testEmergencyContactWithSomethingThatIsNotAnAddressCannotBeSaved() {
        // Only the shape that would silently fail to deliver is
        // rejected — one `@`, a dotted domain, no whitespace. The
        // validator is NOT an RFC 5322 implementation and must not grow
        // into one; it gates a Save button.
        for malformed in ["nope", "a@b", "a b@c.com", "a@@b.com",
                          "@b.com", "a@.com", "a@b.", "a@b..com"] {
            XCTAssertEqual(
                FamilyContactValidation.issue(email: malformed,
                                              isEmergencyContact: true),
                FamilyContactValidation.Issue.emailInvalid,
                "\"\(malformed)\" is typed-but-not-an-address — the hint must say so specifically")
        }
    }

    func testEmergencyContactWithAWellFormedAddressSaves() {
        for good in ["a@b.com", "maa@example.com", "first.last+tag@sub.example.co.uk",
                     "a@b.c.d", "  maa@example.com  ", "MAA@EXAMPLE.COM"] {
            XCTAssertNil(
                FamilyContactValidation.issue(email: good, isEmergencyContact: true),
                "\"\(good)\" is deliverable-as-far-as-the-shape-goes — Save stays live")
        }
    }

    // MARK: - The ordinary-contact exemption

    func testOrdinaryContactIsNeverBlockedByTheAddressField() {
        // The asymmetry is the whole design: a relative without an
        // address is normal (the family has not asked them yet), so the
        // editor never refuses to save one — the invite policy just
        // skips them.
        for email in ["", "   ", "nope", "a@b", "a b@c.com", "a@@b.com"] {
            XCTAssertNil(
                FamilyContactValidation.issue(email: email, isEmergencyContact: false),
                "\"\(email)\" must not block an ordinary contact from being saved")
        }
    }

    // MARK: - Normalization

    func testNormalizedEmailTrimsAndTurnsBlankIntoNil() {
        // Blank means UNSET, the same rule the nickname and address
        // fields follow: an empty field must never persist an empty
        // string that invite logic would then have to special-case.
        XCTAssertNil(FamilyContactValidation.normalizedEmail(""))
        XCTAssertNil(FamilyContactValidation.normalizedEmail("   "))
        XCTAssertNil(FamilyContactValidation.normalizedEmail("\n\t"))

        XCTAssertEqual(FamilyContactValidation.normalizedEmail("  maa@example.com  "),
                       "maa@example.com")
        XCTAssertEqual(FamilyContactValidation.normalizedEmail("maa@example.com"),
                       "maa@example.com",
                       "an address that needs no trimming comes back unchanged")
    }
}
