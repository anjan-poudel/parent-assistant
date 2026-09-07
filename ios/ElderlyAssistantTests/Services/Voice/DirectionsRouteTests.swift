import XCTest
@testable import ElderlyAssistant

/// Pure decision tests for the deterministic directions route (directions
/// task, 2026-09-07): what a transcript means for navigation, independent
/// of the router wiring (covered by `CommandRouterDirectionsTests`) and of
/// the coordinator (which owns execution + speech).
///
/// The design rules under test:
///  - TAKE/DROP verbs ("लैजाऊ"…) fire on their own; the GO family
///    ("जानुहोस्"…) fires ONLY with a home word; bare "जान" never fires.
///  - The bare home ("घर लैजाऊ", "take me home") resolves to
///    `.defaultHome` with NO candidate list — the coordinator owns what
///    home is.
///  - Vetoes run first: call talk, phone-number search talk, medication
///    markers, and third-person transport ("छोरालाई स्कुल लैजाऊ") never
///    launch navigation.
///  - Scoring mirrors `ContactResolver` (1.0 exact / 0.9 relationship
///    anchor / 0.8 containment / 0.6 token overlap; accept 0.6, ambiguity
///    margin 0.15) — top with a rival inside the margin → `.ambiguous`
///    (top first), nothing clearing the bar → `.unknownPlace`.
final class DirectionsRouteTests: XCTestCase {

    private func place(id: UUID = UUID(), name: String) -> DirectionsCandidate {
        DirectionsCandidate(id: id, source: .savedPlace, name: name,
                            address: "काठमाडौं", relationship: nil)
    }

    private func relative(id: UUID = UUID(), name: String, relationship: String)
        -> DirectionsCandidate {
        DirectionsCandidate(id: id, source: .familyContact, name: name,
                            address: "बूढानीलकण्ठ", relationship: relationship)
    }

    // MARK: - Bare home → .defaultHome

    func testTakeMeHomeDevanagariResolvesDefaultHome() {
        XCTAssertEqual(DirectionsRoute.decide(transcript: "मलाई घर लैजाऊ",
                                              candidates: []),
                       .navigate(.defaultHome))
    }

    func testTakeMeHomeEnglishResolvesDefaultHome() {
        XCTAssertEqual(DirectionsRoute.decide(transcript: "take me home",
                                              candidates: []),
                       .navigate(.defaultHome))
    }

    func testGoHomeVerbWithHomeWordResolvesDefaultHome() {
        // The GO family fires only with a home word present.
        XCTAssertEqual(DirectionsRoute.decide(transcript: "घर जानुहोस्",
                                              candidates: []),
                       .navigate(.defaultHome))
    }

    func testRomanizedGharLaijaResolvesDefaultHome() {
        XCTAssertEqual(DirectionsRoute.decide(transcript: "ghar laija",
                                              candidates: []),
                       .navigate(.defaultHome))
    }

    // MARK: - Named destinations

    func testSavedPlaceNameResolvesItsTarget() {
        let hospital = UUID()
        let decision = DirectionsRoute.decide(
            transcript: "मलाई अस्पताल लैजाऊ",
            candidates: [place(id: hospital, name: "अस्पताल")])
        XCTAssertEqual(decision, .navigate(.place(hospital)))
    }

    func testFusedDirectionalSuffixStillResolvesName() {
        // "अस्पतालसम्म" fuses the directional suffix onto the name —
        // stripped, not kept.
        let hospital = UUID()
        let decision = DirectionsRoute.decide(
            transcript: "अस्पतालसम्म लैजाइदिनुहोस्",
            candidates: [place(id: hospital, name: "अस्पताल")])
        XCTAssertEqual(decision, .navigate(.place(hospital)))
    }

    func testPossessiveHomeJunctionResolvesContact() {
        // "मैयाकोघर" (fused, no space) cuts back to the name.
        let maiya = UUID()
        let decision = DirectionsRoute.decide(
            transcript: "मैयाकोघर लैजाऊ",
            candidates: [relative(id: maiya, name: "मैया", relationship: "दिदी")])
        XCTAssertEqual(decision, .navigate(.familyContact(maiya)))
    }

    func testRelationshipAnchorResolvesContactHome() {
        // "छोरीको घर लैजाऊ" — the relationship tier, not the name.
        let sita = UUID()
        let decision = DirectionsRoute.decide(
            transcript: "छोरीको घर लैजाऊ",
            candidates: [relative(id: sita, name: "सीता", relationship: "छोरी")])
        XCTAssertEqual(decision, .navigate(.familyContact(sita)))
    }

    func testEnglishNamedPlaceResolvesByContainment() {
        let hospital = UUID()
        let decision = DirectionsRoute.decide(
            transcript: "take me to the hospital",
            candidates: [place(id: hospital, name: "Hospital")])
        XCTAssertEqual(decision, .navigate(.place(hospital)))
    }

    func testAddresslessCandidateNeverWins() {
        // Defensive filter: a candidate whose address text is blank can
        // never be routed to (nothing would geocode) — even on an exact
        // name match.
        let id = UUID()
        let candidate = DirectionsCandidate(id: id, source: .savedPlace,
                                            name: "अस्पताल", address: "  ",
                                            relationship: nil)
        XCTAssertEqual(DirectionsRoute.decide(transcript: "अस्पताल लैजाऊ",
                                              candidates: [candidate]),
                       .unknownPlace)
    }

    // MARK: - Ambiguity

    func testTwoExactMatchesAskTopCandidateFirst() {
        let first = UUID()
        let second = UUID()
        let decision = DirectionsRoute.decide(
            transcript: "मैयाको घर लैजाऊ",
            candidates: [
                relative(id: first, name: "मैया", relationship: "दिदी"),
                relative(id: second, name: "मैया", relationship: "बहिनी")
            ])
        guard case .ambiguous(let targets) = decision else {
            return XCTFail("two 1.0-scoring names must be ambiguous, got \(decision)")
        }
        XCTAssertEqual(targets.map(\.id), [first, second],
                       "top candidate first — the coordinator asks about it first")
    }

    // MARK: - Unknown

    func testUnmatchedNameIsUnknownPlace() {
        XCTAssertEqual(DirectionsRoute.decide(transcript: "गाउँ लैजाऊ",
                                              candidates: []),
                       .unknownPlace)
    }

    // MARK: - Vetoes (never navigation)

    func testCallTalkNeverRoutes() {
        XCTAssertEqual(DirectionsRoute.decide(transcript: "फोन लैजाऊ",
                                              candidates: []),
                       .notDirections)
        XCTAssertEqual(DirectionsRoute.decide(transcript: "छोरालाई फोन गरिदेउ",
                                              candidates: []),
                       .notDirections)
    }

    func testPhoneNumberSearchNeverRoutes() {
        XCTAssertEqual(DirectionsRoute.decide(transcript: "घरको फोन नम्बर खोज",
                                              candidates: []),
                       .notDirections)
    }

    func testMedicationTalkNeverRoutes() {
        // "दवाई लैजाऊ" is dose talk (take the medicine), not a drive.
        XCTAssertEqual(DirectionsRoute.decide(transcript: "दवाई लैजाऊ",
                                              candidates: []),
                       .notDirections)
        XCTAssertEqual(DirectionsRoute.decide(transcript: "औषधि लैजानुहोस्",
                                              candidates: []),
                       .notDirections)
    }

    func testThirdPersonTransportNeverRoutes() {
        // "छोरालाई स्कुल लैजाऊ" = take my son to school — an errand for
        // the interpreter, never self-navigation.
        XCTAssertEqual(DirectionsRoute.decide(transcript: "छोरालाई स्कुल लैजाऊ",
                                              candidates: []),
                       .notDirections)
    }

    // MARK: - Not navigation shaped

    func testGoingToMarketStatementIsNotDirections() {
        // "म बजार जान्छु" — narration about going, not a request.
        XCTAssertEqual(DirectionsRoute.decide(transcript: "म बजार जान्छु",
                                              candidates: []),
                       .notDirections)
    }

    func testMusicRequestIsNotDirections() {
        // "गीत बजाऊ" carries no TAKE verb and no home word for the GO
        // gate — a music request, never a drive.
        XCTAssertEqual(DirectionsRoute.decide(transcript: "गीत बजाऊ",
                                              candidates: []),
                       .notDirections)
    }

    func testBeingAtHomeIsNotDirections() {
        XCTAssertEqual(DirectionsRoute.decide(transcript: "म घर छु",
                                              candidates: []),
                       .notDirections)
    }

    func testBareTransportVerbWithNoDestinationIsNotDirections() {
        // "लैजाऊ" alone — no home word, no name: nothing to resolve.
        XCTAssertEqual(DirectionsRoute.decide(transcript: "लैजाऊ",
                                              candidates: []),
                       .notDirections)
    }
}
