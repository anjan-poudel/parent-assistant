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

    // MARK: - Full article (feeds readaloud task, 2026-09-19)

    func testBlockTagsBecomeSpacesSoParagraphsDoNotGlueTogether() {
        // `stripHTMLTags` removes a tag WITHOUT leaving a boundary, which
        // would turn "<p>one</p><p>two</p>" into "onetwo". Block-level
        // markup becomes a SPACE — whitespace only, never invented
        // punctuation.
        XCTAssertEqual(
            FeedSpeechSanitizer.articleBody("<p>one</p><p>two</p>"),
            "one two")
        XCTAssertEqual(
            FeedSpeechSanitizer.articleBody("first<br>second"),
            "first second")
        XCTAssertEqual(
            FeedSpeechSanitizer.articleBody("<ul><li>a</li><li>b</li></ul>"),
            "a b")
    }

    func testInlineTagsAreRemovedWithoutABoundary() {
        XCTAssertEqual(
            FeedSpeechSanitizer.articleBody("Full <b>bold</b> text"),
            "Full bold text")
    }

    func testArticleBodyStripsMarkupAndURLs() {
        let body = "<p>Read <a href=\"https://x.example.com/a\">this</a> now.</p>"
        let spoken = FeedSpeechSanitizer.articleBody(body)
        XCTAssertEqual(spoken, "Read this now.")
        XCTAssertFalse(spoken.contains("<"))
        XCTAssertFalse(spoken.contains("https://"))
    }

    func testArticleBodyLeavesDevanagariIntact() {
        let body = "<p>काठमाडौँ मा आज</p><p>मौसम राम्रो छ।</p>"
        XCTAssertEqual(FeedSpeechSanitizer.articleBody(body),
                       "काठमाडौँ मा आज मौसम राम्रो छ।")
    }

    func testArticleSpeechTextUsesTheBodyNotTheSummary() {
        let text = FeedSpeechSanitizer.articleSpeechText(
            title: "Headline", summary: "Short blurb",
            fullText: "<p>The whole story body.</p>")
        XCTAssertEqual(text, "Headline. The whole story body.")
        XCTAssertFalse(text.contains("Short blurb"),
                       "the full-article path must not read the summary")
    }

    func testArticleSpeechTextFallsBackToTheSummaryWhenNoDistinctBody() {
        // No body stored: the option reads what the source published —
        // never silence, never a fabricated article.
        XCTAssertEqual(
            FeedSpeechSanitizer.articleSpeechText(title: "Headline",
                                                  summary: "Short blurb",
                                                  fullText: ""),
            "Headline. Short blurb")
        // Body identical to the summary: the same fallback (there is
        // nothing MORE to read).
        XCTAssertEqual(
            FeedSpeechSanitizer.articleSpeechText(title: "Headline",
                                                  summary: "Short blurb",
                                                  fullText: "<p>Short blurb</p>"),
            "Headline. Short blurb")
    }

    func testArticleSpeechTextIsCappedAtTheArticleLimit() {
        let longBody = String(repeating: "<p>word</p>", count: 1000)
        let text = FeedSpeechSanitizer.articleSpeechText(title: "T",
                                                         summary: "",
                                                         fullText: longBody)
        XCTAssertEqual(text.count, FeedSpeechSanitizer.maxArticleSpeechLength)
        XCTAssertGreaterThan(FeedSpeechSanitizer.maxArticleSpeechLength,
                             FeedSpeechSanitizer.maxSpeechLength,
                             "the article cap is the longer, deliberate one")
    }

    func testArticleCapIsCharacterSafeForDevanagari() {
        let longBody = String(repeating: "काठमाडौँ ", count: 2000)
        let text = FeedSpeechSanitizer.articleSpeechText(title: "",
                                                         summary: "",
                                                         fullText: longBody)
        XCTAssertEqual(text.count, FeedSpeechSanitizer.maxArticleSpeechLength)
        let expected = String(
            FeedSpeechSanitizer.articleBody(longBody)
                .prefix(FeedSpeechSanitizer.maxArticleSpeechLength))
        XCTAssertEqual(text, expected,
                       "the cap must equal the grapheme-cluster-safe prefix")
    }

    // MARK: - hasFullArticle

    func testHasFullArticleIsFalseWithoutADistinctBody() {
        XCTAssertFalse(FeedSpeechSanitizer.hasFullArticle(summary: "S", fullText: ""))
        XCTAssertFalse(FeedSpeechSanitizer.hasFullArticle(summary: "S",
                                                          fullText: "   "))
        XCTAssertFalse(FeedSpeechSanitizer.hasFullArticle(summary: "Same text",
                                                          fullText: "<p>Same text</p>"),
                       "a body the summary already says is nothing MORE to read")
    }

    func testHasFullArticleIsTrueForARealBody() {
        XCTAssertTrue(FeedSpeechSanitizer.hasFullArticle(
            summary: "Short blurb", fullText: "<p>A much longer body.</p>"))
    }
}
