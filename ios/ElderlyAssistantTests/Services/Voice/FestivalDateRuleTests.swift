import XCTest
@testable import ElderlyAssistant

/// [FESTIVAL-DATE] (2026-09-17) The deterministic festival-date keyword
/// rule: a when-word plus a festival NAME from the catalog resolves to
/// `.festivalDate` with the catalog id — immune to encoder availability
/// and model calibration.
final class FestivalDateRuleTests: XCTestCase {

    func testDashainQuestionResolvesTheUmbrellaEntry() {
        guard let match = KeywordIntentRule.match(transcript: "दशैँ कहिले हो") else {
            return XCTFail("expected a festivalDate match")
        }
        XCTAssertEqual(match.domain, .festivalDate)
        XCTAssertEqual(match.festivalID, "dashain")
    }

    func testEnglishFormResolves() {
        let match = KeywordIntentRule.match(transcript: "when is dashain")
        XCTAssertEqual(match?.domain, .festivalDate)
        XCTAssertEqual(match?.festivalID, "dashain")
    }

    func testTiharUmbrellaResolves() {
        let match = KeywordIntentRule.match(transcript: "तिहार कहिले हो")
        XCTAssertEqual(match?.festivalID, "tihar")
    }

    func testFusedPostpositionStillMatches() {
        // Devanagari postpositions fuse onto the name ("दशैँमा") — the
        // phrase alternative must contain-match exactly as the app
        // words do.
        let match = KeywordIntentRule.match(transcript: "दशैँमा कुन दिन हो")
        XCTAssertEqual(match?.festivalID, "dashain")
    }

    func testFestivalNameWithoutWhenWordDoesNotFire() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "दशैँमा के खाने"))
    }

    func testWhenWordWithoutFestivalDoesNotFire() {
        XCTAssertNil(KeywordIntentRule.match(transcript: "बुबा कहिले आउनुहुन्छ"))
    }

    func testEarlierRulesStillWin() {
        // An utterance naming an app AND asking about a festival still
        // resolves through the app-launch rule (earlier in the table).
        let match = KeywordIntentRule.match(transcript: "युट्युब खोल दशैँ कहिले हो")
        XCTAssertEqual(match?.domain, .appLaunch)
    }

    func testAppLaunchUnchanged() {
        let match = KeywordIntentRule.match(transcript: "क्यामेरा खोल")
        XCTAssertEqual(match?.domain, .appLaunch)
        XCTAssertEqual(match?.appID, "camera")
    }
}
