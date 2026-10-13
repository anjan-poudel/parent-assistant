import XCTest
@testable import ElderlyAssistant

// [REPLY-POLISH] The deterministic spoken-reply polisher: string-level
// pins for every stage — cleanup only, never a grammar rewrite.

final class SpokenReplyPolisherTests: XCTestCase {

    func testCollapsesWhitespaceRuns() {
        XCTAssertEqual(SpokenReplyPolisher.collapseWhitespace("  हजुर   भोलि  छ। "),
                       "हजुर भोलि छ।")
    }

    func testCollapsesRepeatedTerminalPunctuation() {
        XCTAssertEqual(SpokenReplyPolisher.collapseRepeatedTerminalPunctuation("ठीक छ।।"),
                       "ठीक छ।")
        XCTAssertEqual(SpokenReplyPolisher.collapseRepeatedTerminalPunctuation("कस्तो छ??"),
                       "कस्तो छ?")
        XCTAssertEqual(SpokenReplyPolisher.collapseRepeatedTerminalPunctuation("हुन्छ!!"),
                       "हुन्छ!")
        XCTAssertEqual(SpokenReplyPolisher.collapseRepeatedTerminalPunctuation("भयो।!"),
                       "भयो!")
        // Mid-word period runs collapse too — model text never carries a
        // meaningful "..", and one dot is the honest form.
        XCTAssertEqual(SpokenReplyPolisher.collapseRepeatedTerminalPunctuation("ठीक..छ।"),
                       "ठीक.छ।")
    }

    func testStripsEnumerationArtifactsPerSentence() {
        XCTAssertEqual(SpokenReplyPolisher.stripEnumerationArtifacts("१. हजुर ठीक छ।"),
                       "हजुर ठीक छ।")
        XCTAssertEqual(SpokenReplyPolisher.stripEnumerationArtifacts("2) भोलि आउनुहोस्।"),
                       "भोलि आउनुहोस्।")
        XCTAssertEqual(SpokenReplyPolisher.stripEnumerationArtifacts("- अर्को कुरा।"),
                       "अर्को कुरा।")
        // A real ordinal inside prose survives: it is not at the head.
        XCTAssertEqual(SpokenReplyPolisher.stripEnumerationArtifacts("म २ वर्षको छु।"),
                       "म २ वर्षको छु।")
    }

    func testDedupesAdjacentRepeatedWords() {
        XCTAssertEqual(SpokenReplyPolisher.dedupeAdjacentWords("हजुर हजुर ठीक छ"),
                       "हजुर ठीक छ")
        // Non-adjacent repeats survive — "भोलि ... भोलि" is content.
        XCTAssertEqual(SpokenReplyPolisher.dedupeAdjacentWords("भोलि आउँछु भोलि"),
                       "भोलि आउँछु भोलि")
    }

    func testBriefProfileKeepsTwoSentences() {
        XCTAssertEqual(SpokenReplyPolisher.enforceBrevity(
                            "पहिलो। दोस्रो। तेस्रो।", profile: .brief),
                       "पहिलो। दोस्रो।")
        XCTAssertEqual(SpokenReplyPolisher.enforceBrevity(
                            "एक। दुई। तीन", profile: .brief),
                       "एक। दुई।")
    }

    func testStandardProfileKeepsFourSentences() {
        // Substantive answers get room: four sentences survive, the
        // fifth is cut.
        XCTAssertEqual(SpokenReplyPolisher.enforceBrevity(
                            "एक। दुई। तीन। चार। पाँच।"),
                       "एक। दुई। तीन। चार।")
    }

    func testStandardCapsTheLastSentenceAtFortyFiveWords() {
        let long = (1...60).map { "शब्द\($0)" }.joined(separator: " ")
        let polished = SpokenReplyPolisher.enforceBrevity(long)
        let words = polished.split(separator: " ").count
        XCTAssertEqual(words, 45)
        XCTAssertTrue(polished.hasSuffix("शब्द45"))
    }

    func testThePipelinePolishesEndToEnd() {
        let raw = "  हजुर हजुर।। १. ठीक छ भन्नुहोस्!!  2) भोलि आउनुहोस्। तेस्रो वाक्य।"
        // Dedupe collapses "हजुर हजुर।" keeping the mark; the standard
        // profile keeps four sentences.
        XCTAssertEqual(SpokenReplyPolisher.polish(raw),
                       "हजुर। ठीक छ भन्नुहोस्! भोलि आउनुहोस्। तेस्रो वाक्य।")
    }

    func testAnEmptyResultIsEmpty() {
        XCTAssertEqual(SpokenReplyPolisher.polish("   "), "")
        XCTAssertEqual(SpokenReplyPolisher.polish(""), "")
    }
}
