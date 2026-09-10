import XCTest
@testable import ElderlyAssistant

/// [YOUTUBE] (2026-09-08) Pure decision tests for the deterministic
/// YouTube marker stage — the utterance table (en + ne), the query
/// extraction (non-marker remainder), and the vetoes that keep
/// non-YouTube talk on the existing ladder.
final class YouTubeRouteTests: XCTestCase {

    // MARK: - English utterances

    func testPlayOnYouTubeExtractsQuery() {
        XCTAssertEqual(YouTubeRoute.decide(transcript: "play bhajan on youtube"),
                       .play("bhajan"))
        XCTAssertEqual(YouTubeRoute.decide(transcript: "play ramayan in youtube"),
                       .play("ramayan"))
        XCTAssertEqual(YouTubeRoute.decide(transcript: "PLAY old songs ON YOUTUBE"),
                       .play("old songs"),
                       "matching must be case-insensitive (STT transcripts vary)")
    }

    func testLeadingYouTubeExtractsQuery() {
        XCTAssertEqual(YouTubeRoute.decide(transcript: "youtube news"), .play("news"))
        XCTAssertEqual(YouTubeRoute.decide(transcript: "youtube bhajan gana"), .play("bhajan gana"))
    }

    func testSearchYoutubePhrasingsExtractQuery() {
        XCTAssertEqual(YouTubeRoute.decide(transcript: "search youtube for old songs"),
                       .play("old songs"))
        XCTAssertEqual(YouTubeRoute.decide(transcript: "search on youtube for bhajan"),
                       .play("bhajan"))
        XCTAssertEqual(YouTubeRoute.decide(transcript: "search in youtube ramayan"),
                       .play("ramayan"))
    }

    func testGreetingPrefixedRequestIsACommandNotSmallTalk() {
        XCTAssertEqual(YouTubeRoute.decide(transcript: "नमस्ते, play bhajan on youtube"),
                       .play("bhajan"))
        XCTAssertEqual(YouTubeRoute.decide(transcript: "hello youtube bhajan"),
                       .notYouTube,
                       "a leading English greeting is not part of the marker gate — the play/search verb or leading youtube is required")
    }

    // MARK: - Nepali utterances

    func testNepaliPlayUtterancesExtractQuery() {
        XCTAssertEqual(YouTubeRoute.decide(transcript: "युट्युबमा गीत चलाऊ"),
                       .play("गीत"))
        XCTAssertEqual(YouTubeRoute.decide(transcript: "युट्युबमा भजन चलाइदिनुहोस्"),
                       .play("भजन"))
        XCTAssertEqual(YouTubeRoute.decide(transcript: "युट्युबमा भजन बजाऊ"),
                       .play("भजन"))
        XCTAssertEqual(YouTubeRoute.decide(transcript: "युट्युबमा गीत बजाइदिनुहोस्"),
                       .play("गीत"))
    }

    func testNepaliSearchUtterancesExtractQuery() {
        XCTAssertEqual(YouTubeRoute.decide(transcript: "युट्युबमा रामायण खोज"),
                       .play("रामायण"))
        XCTAssertEqual(YouTubeRoute.decide(transcript: "युट्युबमा पुराना गीत खोजिदिनुहोस्"),
                       .play("पुराना गीत"))
    }

    func testNepaliLagauFamilyExtractsQueryDataDriven() {
        // [YT-LAGAU] (2026-09-11) Device evidence: the user's natural verb
        // for "play a video" is लगाऊ (Whisper nasalizes it to लगाउँ) —
        // every लगाऊ-family form must route as .play with a clean query.
        let lagauForms = [
            "लगाऊ", "लगाउ", "लगाउँ", "लगाउनुहोस्", "लगाउनुस्",
            "लगाइदिनुहोस्", "लगाइदिनुस्", "लगाइदिनु", "लगाइदेऊ", "लगाइदेउ"
        ]
        for form in lagauForms {
            let phrase = "युट्युबमा नेपाली न्युज \(form)"
            XCTAssertEqual(YouTubeRoute.decide(transcript: phrase),
                           .play("नेपाली न्युज"),
                           "लगाऊ-family form must extract the query for: \(phrase)")
        }
    }

    func testDeviceTranscriptNepaliNewsLagauExtractsQuery() {
        // The EXACT device transcript that motivated the family: nasalized
        // लगाउँ after a two-word query.
        XCTAssertEqual(YouTubeRoute.decide(transcript: "युट्युबमा नेपाली न्युज लगाउँ"),
                       .play("नेपाली न्युज"))
    }

    // MARK: - Vetoes (never hijack the ladder)

    func testBarePlayWithoutYouTubeWordNeverFires() {
        XCTAssertEqual(YouTubeRoute.decide(transcript: "play some music"), .notYouTube)
        XCTAssertEqual(YouTubeRoute.decide(transcript: "play"), .notYouTube)
        XCTAssertEqual(YouTubeRoute.decide(transcript: "play the radio"), .notYouTube)
    }

    func testNarrationAboutYouTubeNeverFires() {
        // A YouTube word without a play/search verb (and not leading) is
        // narration or a question about the site, not a command.
        XCTAssertEqual(YouTubeRoute.decide(transcript: "i watched youtube yesterday"),
                       .notYouTube)
        XCTAssertEqual(YouTubeRoute.decide(transcript: "what is youtube"), .notYouTube)
    }

    func testLagauWithoutYouTubeWordNeverFires() {
        // [YT-LAGAU] Safety: the लगाऊ-family marker must not widen the
        // gate — a YouTube word is still required, so alarm/timer business
        // (which uses the same verb) stays on its own stage.
        XCTAssertEqual(YouTubeRoute.decide(transcript: "अलार्म लगाऊ"), .notYouTube)
        XCTAssertEqual(YouTubeRoute.decide(transcript: "पाँच मिनेटको टाइमर लगाउँ"), .notYouTube)
    }

    func testYouTubeWordAloneWithNoQueryFallsThrough() {
        XCTAssertEqual(YouTubeRoute.decide(transcript: "youtube"), .notYouTube)
        XCTAssertEqual(YouTubeRoute.decide(transcript: "search youtube"), .notYouTube)
        XCTAssertEqual(YouTubeRoute.decide(transcript: "play on youtube"), .notYouTube,
                       "a play marker with no survivable query is not a playable request")
    }

    // MARK: - Query hygiene

    func testQueryCapAndWhitespaceCollapse() {
        let long = String(repeating: "x ", count: 200)
        guard case .play(let query) = YouTubeRoute.decide(transcript: "play \(long)on youtube") else {
            return XCTFail("a long query must still match the marker")
        }
        XCTAssertLessThanOrEqual(query.count, 100)
    }
}
