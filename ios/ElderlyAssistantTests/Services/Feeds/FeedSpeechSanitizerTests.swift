import XCTest
@testable import ElderlyAssistant

/// Speech sanitizer tests (feed-agent task, 2026-09-08) — the TTS-friendly
/// text contract: no URLs, no HTML, collapsed whitespace, Devanagari
/// untouched, and the hard length cap (Character-safe).
final class FeedSpeechSanitizerTests: XCTestCase {

    // MARK: - Composition

    func testComposesTitleThenSummary() {
        let text = FeedSpeechSanitizer.speechText(title: "Headline",
                                                  summary: "The full story")
        XCTAssertEqual(text, "Headline. The full story")
    }

    func testTitleOnlyWhenSummaryEmpty() {
        XCTAssertEqual(FeedSpeechSanitizer.speechText(title: "Headline", summary: ""),
                       "Headline")
    }

    func testSummaryOnlyWhenTitleEmpty() {
        XCTAssertEqual(FeedSpeechSanitizer.speechText(title: "", summary: "Body"),
                       "Body")
    }

    func testEmptyWhenBothEmpty() {
        XCTAssertEqual(FeedSpeechSanitizer.speechText(title: "  ", summary: ""), "")
    }

    // MARK: - HTML stripping

    func testStripsHTMLTags() {
        let stripped = FeedSpeechSanitizer.stripHTMLTags(
            "Read <b>this</b> <a href=\"https://x.example.com\">link</a> now")
        XCTAssertEqual(stripped, "Read this link now")
    }

    func testTagLikeGuardLeavesProseComparisons() {
        // "2 < 3" has no ">" and "a > b" has no "<" — honest prose must
        // survive the tag stripper.
        XCTAssertEqual(FeedSpeechSanitizer.stripHTMLTags("2 < 3 and a > b"),
                       "2 < 3 and a > b")
    }

    func testUnclosedTagIsLeftAlone() {
        XCTAssertEqual(FeedSpeechSanitizer.stripHTMLTags("Cost < 5 dollars"),
                       "Cost < 5 dollars")
    }

    // MARK: - URL stripping

    func testStripsURLTokens() {
        let stripped = FeedSpeechSanitizer.stripURLTokens(
            "See https://example.com/a and www.example.org for more")
        XCTAssertEqual(stripped, "See and for more")
    }

    func testHTTPSAndWWWVariantsStripped() {
        XCTAssertEqual(FeedSpeechSanitizer.stripURLTokens("http://a.example.com x"),
                       "x")
        XCTAssertEqual(FeedSpeechSanitizer.stripURLTokens("HTTPS://A.EXAMPLE.COM x"),
                       "x")
        XCTAssertEqual(FeedSpeechSanitizer.stripURLTokens("WWW.Example.com x"),
                       "x")
    }

    // MARK: - Whitespace

    func testCollapsesWhitespaceAndNewlines() {
        XCTAssertEqual(FeedSpeechSanitizer.collapseWhitespace(
            "Line one\nLine two\t tabbed   spaces"),
            "Line one Line two tabbed spaces")
    }

    // MARK: - Devanagari safety

    func testDevanagariPassesThroughUnchanged() {
        let nepali = "नेपालका समाचार स्वास्थ्य"
        let text = FeedSpeechSanitizer.speechText(title: nepali, summary: "विवरण")
        XCTAssertEqual(text, "नेपालका समाचार स्वास्थ्य. विवरण")
    }

    func testNepaliWithInlineEnglishSurvives() {
        let text = FeedSpeechSanitizer.stripped("काठमाडौँ updates आज")
        XCTAssertEqual(text, "काठमाडौँ updates आज")
    }

    // MARK: - Length cap

    func testLongCompositionIsCappedAtMaxSpeechLength() {
        let longTitle = String(repeating: "word ", count: 200)
        let text = FeedSpeechSanitizer.speechText(title: longTitle, summary: "end")
        XCTAssertEqual(text.count, FeedSpeechSanitizer.maxSpeechLength)
    }

    func testCapIsCharacterSafeForDevanagari() {
        // The cap must be the Character-safe prefix — a future
        // reimplementation using scalar/UTF-16 arithmetic could cut a
        // cluster mid-way, leaving a dangling matra (the exact bug class
        // the Devanagari substring lesson warns about). A complete
        // cluster legitimately CONTAINS mark scalars ("ौँ" = ौ + ँ),
        // so the pin is prefix equality, not a mark-range scan.
        let longNepali = String(repeating: "काठमाडौँ ", count: 200)
        let text = FeedSpeechSanitizer.speechText(title: longNepali, summary: "")
        XCTAssertEqual(text.count, FeedSpeechSanitizer.maxSpeechLength)
        XCTAssertEqual(text, String(longNepali.prefix(FeedSpeechSanitizer.maxSpeechLength)),
                       "the cap must equal the grapheme-cluster-safe prefix")
    }

    func testShortCompositionIsUncapped() {
        let text = FeedSpeechSanitizer.speechText(title: "Short", summary: "summary")
        XCTAssertLessThan(text.count, FeedSpeechSanitizer.maxSpeechLength)
    }
}
