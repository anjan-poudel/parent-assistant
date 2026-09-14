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
///    (top first), nothing clearing the bar → `.unknownPlace`. Under all
///    of those sits the transliteration tier (0.7, WAY/WAY-request task
///    2026-09-14): "सिड्नी" reaches a saved place stored as "Sydney
///    house".
///  - WAY/DIRECTIONS requests ("बाटो लगाउँ", "बाटो देखाऊ", "बाटो बताऊ",
///    रास्ता/रस्ता) are their own family: they fire standalone, the bare
///    form with no destination is not directions, and a home word makes
///    them the bare-home case.
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

    // MARK: - WAY/DIRECTIONS requests (2026-09-14)

    /// The reported on-device failure, verbatim: the elder asked
    /// "सिड्नी घरको बाटो लगाउँ" about a saved place stored in LATIN
    /// ("Sydney house" — the name as it was typed when it was saved) and
    /// the turn fell through to the model, which misclassified and
    /// truncated it. The way family sends it to navigation and the
    /// transliteration tier finds the candidate.
    func testLatinNamedSavedPlaceResolvesFromDevanagariWayRequest() {
        let sydney = UUID()
        let decision = DirectionsRoute.decide(
            transcript: "सिड्नी घरको बाटो लगाउँ",
            candidates: [place(id: sydney, name: "Sydney house")])
        XCTAssertEqual(decision, .navigate(.place(sydney)))
    }

    func testWayRequestFormsResolveNamedPlace() {
        // Every way phrasing, the way a speaker actually varies them.
        let hospital = UUID()
        let destination = place(id: hospital, name: "अस्पताल")
        for transcript in ["बाटो देखाउनुहोस् अस्पताल",
                           "अस्पतालको बाटो बताऊ",
                           "अस्पताल बाटो लगाइदिनुहोस्",
                           "अस्पताल बाटो देखाऊ",
                           "अस्पताल सम्मको रास्ता बताउनुहोस्",
                           "अस्पताल बाटोलगाउँ",
                           "bato dekhau अस्पताल"] {
            XCTAssertEqual(DirectionsRoute.decide(transcript: transcript,
                                                  candidates: [destination]),
                           .navigate(.place(hospital)), transcript)
        }
    }

    func testRomanizedWayRequestResolvesEnglishNamedPlace() {
        let hospital = UUID()
        XCTAssertEqual(DirectionsRoute.decide(transcript: "hospital rasta dekhau",
                                              candidates: [place(id: hospital,
                                                                 name: "Hospital")]),
                       .navigate(.place(hospital)))
    }

    func testWayRequestWithHomeWordResolvesDefaultHome() {
        // "give me the way home" — the way noun is the destination the
        // walker means, and घर is what makes it the bare-home case.
        XCTAssertEqual(DirectionsRoute.decide(transcript: "घरको बाटो लगाउँ",
                                              candidates: []),
                       .navigate(.defaultHome))
    }

    func testBareWayRequestWithNoDestinationIsNotDirections() {
        // The way noun alone names no place and no home: a request for
        // directions is not a drive to a default home (the same gate the
        // bare TAKE/DROP verbs pass through).
        for transcript in ["बाटो लगाउँ", "बाटो देखाउनुहोस्", "रास्ता बताऊ",
                           "bato lagau"] {
            XCTAssertEqual(DirectionsRoute.decide(transcript: transcript,
                                                  candidates: []),
                           .notDirections, transcript)
        }
    }

    func testBareWayVerbsAreNotMarkersOnTheirOwn() {
        // The ver forms only mark a request WITH the way noun: "भात
        // लगाउ" (serve rice) and "फोटो देखाऊ" (show the photo) are
        // everyday verb use, never a drive.
        for transcript in ["लगाउ", "भात लगाउ", "फोटो देखाऊ", "फोटो देखाउनुहोस्"] {
            XCTAssertEqual(DirectionsRoute.decide(transcript: transcript,
                                                  candidates: []),
                           .notDirections, transcript)
        }
    }

    func testWayRequestVetoesStillWin() {
        // The vetoes run before the shape check, way noun or not.
        XCTAssertEqual(DirectionsRoute.decide(transcript: "फोन लगाउ",
                                              candidates: []),
                       .notDirections)
        XCTAssertEqual(DirectionsRoute.decide(transcript: "दवाई बाटो लगाउ",
                                              candidates: []),
                       .notDirections)
        XCTAssertEqual(DirectionsRoute.decide(transcript: "औषधि बाटो देखाऊ",
                                              candidates: []),
                       .notDirections)
    }

    // MARK: - Transliteration tier

    func testTransliterationTierMatchesLatinCandidateNames() {
        // Devanagari query ↔ Latin name is the bridge; "सुनिता" ↔
        // "Sunita" is the same bridge with nothing to fuzz.
        let aspatal = UUID()
        XCTAssertEqual(DirectionsRoute.decide(transcript: "अस्पताल बाटो लगाउँ",
                                              candidates: [place(id: aspatal,
                                                                 name: "Aspatal")]),
                       .navigate(.place(aspatal)))

        let sunita = UUID()
        XCTAssertEqual(DirectionsRoute.decide(transcript: "सुनिता घरको बाटो देखाऊ",
                                              candidates: [place(id: sunita,
                                                                 name: "Sunita")]),
                       .navigate(.place(sunita)))
    }

    func testTransliterationTierMatchesDevanagariCandidateFromLatinQuery() {
        let sydney = UUID()
        XCTAssertEqual(DirectionsRoute.decide(transcript: "sidney bato dekhau",
                                              candidates: [place(id: sydney,
                                                                 name: "सिड्नी")]),
                       .navigate(.place(sydney)))
    }

    func testLiteralMatchOutranksTransliterationTier() {
        // Both candidates are reachable from "अस्पताल" — the literal one
        // must win, and win alone (no ambiguity: 1.0 clears 0.7 by more
        // than the margin).
        let literal = UUID()
        XCTAssertEqual(DirectionsRoute.decide(
            transcript: "अस्पताल लैजाऊ",
            candidates: [place(id: literal, name: "अस्पताल"),
                         place(name: "Aspatal")]),
                       .navigate(.place(literal)))
    }

    func testShortNamesAreNotFuzzedAcrossScripts() {
        // "राम" and "राज" are one edit apart in Latin form and are
        // different people: tokens under five characters must match
        // exactly, so this stays unknown rather than driving to राज.
        XCTAssertEqual(DirectionsRoute.decide(transcript: "राम लैजाऊ",
                                              candidates: [place(name: "राज")]),
                       .unknownPlace)
        XCTAssertEqual(DirectionsRoute.decide(transcript: "सिड्नी लैजाऊ",
                                              candidates: [place(name: "सीता")]),
                       .unknownPlace)
    }

    func testTwoTransliterationMatchesAskTopCandidateFirst() {
        // The transliteration score is one score like any other, so the
        // ambiguity margin applies to it too — the coordinator asks.
        let decision = DirectionsRoute.decide(transcript: "सिड्नी बाटो लगाउँ",
                                              candidates: [place(name: "Sydney"),
                                                           place(name: "Sidney")])
        guard case .ambiguous = decision else {
            return XCTFail("two transliteration matches must ask, got \(decision)")
        }
    }
}
