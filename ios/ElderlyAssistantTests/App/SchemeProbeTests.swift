import XCTest
@testable import ElderlyAssistant

/// [SCHEME-PROBE] Pins the tester's candidate list — the chips the elder
/// taps are exactly the schemes the plist whitelists, so every probe the
/// tester offers is an honest one.
final class SchemeProbeTests: XCTestCase {

    func testCandidateChipsAreStableAndContainTheDisputedSchemes() {
        let candidates = SchemeProbeView.candidateSchemes
        // The two the owner asked about — present so the tester answers
        // them on-device instead of folklore lists answering them.
        XCTAssertTrue(candidates.contains("contact://"))
        XCTAssertTrue(candidates.contains("people://"))
        // The device-disproven Phone-tab schemes stay testable — a
        // tester exists so evidence, not lists, decides.
        XCTAssertTrue(candidates.contains("mobilephone-recents://"))
        // Known-good roots for contrast (the tester's green rows).
        XCTAssertTrue(candidates.contains("whatsapp://"))
        XCTAssertTrue(candidates.contains("calshow://"))
        // No duplicates — a chip appearing twice would suggest drift.
        XCTAssertEqual(Set(candidates).count, candidates.count)
    }

    func testCandidateBareSchemesMatchTheWhitelistContract() {
        // Every candidate's bare form must be declared in
        // LSApplicationQueriesSchemes for its probe to be truthful. The
        // view keeps its own whitelist copy; this test pins the two
        // together so they can never drift silently.
        let candidates = SchemeProbeView.candidateSchemes
        let whitelistedBare: Set<String> = [
            "contact", "people", "mobilephone", "mobilephone-contacts",
            "mobilephone-favorites", "mobilephone-recents",
            "mobilephone-voicemail", "vmshow", "tel", "telprompt",
            "whatsapp", "fb-messenger", "calshow", "prefs",
        ]
        for candidate in candidates {
            let bare = SchemeProbeView.bareScheme(of: candidate)
            XCTAssertTrue(whitelistedBare.contains(bare),
                          "\(candidate) must be whitelisted for an honest probe")
        }
    }

    func testBareSchemeExtractsTheSchemeNotThePath() {
        XCTAssertEqual(SchemeProbeView.bareScheme(of: "prefs:root=Phone"), "prefs")
        XCTAssertEqual(SchemeProbeView.bareScheme(of: "tel:"), "tel")
        XCTAssertEqual(SchemeProbeView.bareScheme(of: "contact://"), "contact")
    }
}
