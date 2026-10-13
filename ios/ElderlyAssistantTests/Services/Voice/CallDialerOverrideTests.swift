import XCTest
@testable import ElderlyAssistant

/// [PER-CONTACT-OVERRIDE] (2026-10-14) — the contact-level dialer
/// override and its exclusion rule. The owner's rule, verbatim: "if
/// override is secondary, then fallback will be primary, not the
/// same." Every case below pins that the override is attempted exactly
/// once and its fallback is never a repeat of itself.
final class CallDialerOverrideTests: XCTestCase {

    // MARK: - The chain's override order

    func testOverrideEqualsSecondaryFallsBackToThePrimary() {
        let order = CallChannelChain.attemptOrderForOverride(override: .messenger,
                                                             primary: .whatsApp,
                                                             secondary: .messenger)
        XCTAssertEqual(order, [.messenger, .whatsApp, .phone],
                       "the secondary override falls back to the PRIMARY, "
                       + "never a repeat of itself")
        XCTAssertEqual(Set(order).count, order.count, "every channel appears once")
    }

    func testOverrideEqualsPrimaryFallsBackToTheSecondary() {
        let order = CallChannelChain.attemptOrderForOverride(override: .whatsApp,
                                                             primary: .whatsApp,
                                                             secondary: .messenger)
        XCTAssertEqual(order, [.whatsApp, .messenger, .phone])
    }

    func testDistinctOverrideKeepsTheStandardFallback() {
        let order = CallChannelChain.attemptOrderForOverride(override: .faceTime,
                                                             primary: .whatsApp,
                                                             secondary: .messenger)
        XCTAssertEqual(order, [.faceTime, .messenger, .phone])
    }

    func testOverrideWhenPrimaryAndSecondaryAreEqualNeverRepeats() {
        let order = CallChannelChain.attemptOrderForOverride(override: .messenger,
                                                             primary: .messenger,
                                                             secondary: .messenger)
        XCTAssertEqual(order, [.messenger, .phone])
        XCTAssertEqual(Set(order).count, order.count)
    }

    func testPhoneOverrideNeverAppendsAPhoneAgain() {
        let order = CallChannelChain.attemptOrderForOverride(override: .phone,
                                                             primary: .whatsApp,
                                                             secondary: .messenger)
        XCTAssertEqual(order, [.phone, .messenger])
        XCTAssertEqual(Set(order).count, order.count)
    }

    // MARK: - The seam routes the override order

    func testSeamFallsBackToThePrimaryWhenTheSecondaryOverrideIsInfeasible() {
        // Override = messenger, no handle on file → infeasible; the
        // global secondary is ALSO messenger (the override) — the seam
        // must fall to the PRIMARY (whatsApp), with the skipped channel
        // in provenance.
        let route = AppCoordinator.resolvedCallChannelWithOverride(
            override: .messenger,
            defaultApp: .whatsApp,
            secondaryApp: .messenger,
            messengerHandleAvailable: false,
            whatsAppInstalled: true)
        XCTAssertEqual(route.channel, .whatsApp,
                       "the fallback is the primary, not the override again")
        XCTAssertEqual(route.fellBackFrom, [.messenger],
                       "the skipped override is the provenance")
    }

    func testSeamRoutesTheFeasibleOverrideFirst() {
        let route = AppCoordinator.resolvedCallChannelWithOverride(
            override: .whatsApp,
            defaultApp: .phone,
            secondaryApp: .messenger,
            messengerHandleAvailable: true,
            whatsAppInstalled: true)
        XCTAssertEqual(route.channel, .whatsApp)
        XCTAssertTrue(route.fellBackFrom.isEmpty)
    }

    func testHopCandidatesInTheOverrideOrderPointAtThePrimaryNext() {
        // The override routed; the hop's next attempt must be the
        // primary — the suffix of [messenger, whatsApp, phone].
        let order = CallChannelChain.attemptOrderForOverride(override: .messenger,
                                                             primary: .whatsApp,
                                                             secondary: .messenger)
        let hops = CallChannelChain.hopCandidates(in: order, routed: .messenger)
        XCTAssertEqual(hops, [.whatsApp, .phone],
                       "the hop after the override goes to the primary")
    }

    // MARK: - The model round-trips the override

    func testDialerOverrideRoundTripsThroughCodable() throws {
        let contact = FamilyContact(name: "सुनिता", phone: "9812345678",
                                    relationship: "छोरी",
                                    dialerOverride: .whatsApp)
        let data = try JSONEncoder().encode(contact)
        let decoded = try JSONDecoder().decode(FamilyContact.self, from: data)
        XCTAssertEqual(decoded.dialerOverride, .whatsApp)
    }

    func testLegacyPayloadWithoutTheOverrideKeyDecodesToNil() throws {
        let contact = FamilyContact(name: "सुनिता", phone: "9812345678",
                                    relationship: "छोरी")
        let data = try JSONEncoder().encode(contact)
        var dict = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "dialerOverride")
        let legacy = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(FamilyContact.self, from: legacy)
        XCTAssertNil(decoded.dialerOverride,
                     "a pre-field payload follows the globals, never an override")
    }
}
