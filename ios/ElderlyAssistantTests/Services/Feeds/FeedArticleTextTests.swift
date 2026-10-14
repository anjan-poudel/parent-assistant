import XCTest
@testable import ElderlyAssistant

/// Reader display-text tests (news-feed-images task, 2026-10-14) — the
/// paragraph assembly behind the tap-through article reader.
///
/// The reader keeps the speech path's editing rules (markup and URL
/// tokens removed, nothing invented, grapheme-safe) and differs only in
/// LAYOUT: each block-level boundary becomes its own paragraph, which is
/// the structure the eye reads. These pins make the two claims the
/// reader makes checkable: block tags split, inline tags do not, and a
/// summary-only item shows exactly the published words.
final class FeedArticleTextTests: XCTestCase {

    // MARK: - paragraphs(fromBody:)

    func testBlockTagsBecomeParagraphBreaks() {
        XCTAssertEqual(
            FeedArticleText.paragraphs(fromBody: "<p>one</p><p>two</p>"),
            ["one", "two"])
    }

    func testLineBreakTagSplitsAParagraph() {
        XCTAssertEqual(
            FeedArticleText.paragraphs(fromBody: "first<br>second"),
            ["first", "second"])
    }

    func testListItemsBecomeTheirOwnParagraphs() {
        XCTAssertEqual(
            FeedArticleText.paragraphs(fromBody: "<ul><li>a</li><li>b</li></ul>"),
            ["a", "b"])
    }

    func testInlineTagsAreRemovedWithoutSplitting() {
        XCTAssertEqual(
            FeedArticleText.paragraphs(fromBody: "Full <b>bold</b> text"),
            ["Full bold text"])
    }

    func testPrettyPrintedSourceWhitespaceIsLayoutNotStructure() {
        // Raw newlines in the feed XML are pretty-printing — HTML
        // collapses them — so only block tags may split paragraphs, and
        // the prose they separated stays on one line.
        XCTAssertEqual(
            FeedArticleText.paragraphs(fromBody: "<p>one\n  line</p>\n<p>two</p>"),
            ["one line", "two"])
    }

    func testURLTokensAreDropped() {
        let body = "<p>Read <a href=\"https://x.example.com/a\">this</a> now.</p>"
        let paragraphs = FeedArticleText.paragraphs(fromBody: body)
        XCTAssertEqual(paragraphs, ["Read this now."])
        XCTAssertFalse(paragraphs.joined().contains("https://"))
    }

    func testBlankBlocksNeverProduceEmptyParagraphs() {
        XCTAssertEqual(
            FeedArticleText.paragraphs(fromBody: "<p></p><p>  </p><p>x</p>"),
            ["x"])
        XCTAssertEqual(FeedArticleText.paragraphs(fromBody: "   "), [])
        XCTAssertEqual(FeedArticleText.paragraphs(fromBody: ""), [])
    }

    func testDevanagariParagraphsSurviveIntact() {
        XCTAssertEqual(
            FeedArticleText.paragraphs(
                fromBody: "<p>काठमाडौँ मा आज</p><p>मौसम राम्रो छ।</p>"),
            ["काठमाडौँ मा आज", "मौसम राम्रो छ।"])
    }

    // MARK: - bodyParagraphs(summary:fullText:)

    func testRealBodyBecomesParagraphs() {
        XCTAssertEqual(
            FeedArticleText.bodyParagraphs(summary: "Short blurb",
                                           fullText: "<p>One.</p><p>Two.</p>"),
            ["One.", "Two."],
            "a distinct body is what the reader lays out")
    }

    func testSummaryOnlyItemShowsTheSummaryAsOneParagraph() {
        // No distinct body: the reader shows the published summary — the
        // same words the full-article reading falls back to, so the
        // screen and the voice agree.
        XCTAssertEqual(
            FeedArticleText.bodyParagraphs(summary: "Short blurb", fullText: ""),
            ["Short blurb"])
        XCTAssertEqual(
            FeedArticleText.bodyParagraphs(summary: "Short blurb",
                                           fullText: "<p>Short blurb</p>"),
            ["Short blurb"],
            "a body the summary already says is nothing MORE to show")
    }

    func testSummaryFallbackIsSanitized() {
        XCTAssertEqual(
            FeedArticleText.bodyParagraphs(
                summary: "Blurb <b>bold</b> https://x.example.com",
                fullText: ""),
            ["Blurb bold"],
            "the fallback takes the same editing rules as a body")
    }

    func testDevanagariSummaryFallbackSurvives() {
        XCTAssertEqual(
            FeedArticleText.bodyParagraphs(summary: "सारांश पाठ", fullText: ""),
            ["सारांश पाठ"])
    }

    func testEmptyItemProducesNoParagraphs() {
        XCTAssertEqual(FeedArticleText.bodyParagraphs(summary: "  ", fullText: ""), [])
        XCTAssertEqual(FeedArticleText.bodyParagraphs(summary: "", fullText: ""), [])
    }
}
