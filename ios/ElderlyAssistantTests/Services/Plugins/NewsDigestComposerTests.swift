import XCTest
@testable import ElderlyAssistant

/// [NEWS-READER] (2026-09-08) `NewsDigestComposer` unit tests:
///  - TTS sanitization: HTML entities (named + numeric + hex), embedded
///    tags, URLs, whitespace runs; nothing speakable → nil; the
///    single-pass rule ("&amp;quot;" must NOT become a quote),
///  - en + ne digest templates (source line, sentence stop "। ", counts),
///  - the honest outcome rules: all-failed → one `news.allFailed` line,
///    all-empty → one `news.allEmpty` line, mixed → per-source lines
///    with the honest per-source empty/failed lines,
///  - headline cap (top 3 per source), feed-order determinism,
///  - zero sources → the honest all-failed line (never silence).
///
/// English expectations pin the catalog values verbatim; Nepali
/// expectations pin the composed structure (stop, argument placement).
final class NewsDigestComposerTests: XCTestCase {

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    private func source(_ name: String = "BBC World",
                        url: String = "https://example.com/rss") -> NewsSource {
        NewsSource(name: name, urlString: url, languageCode: "en")
    }

    private func ok(_ titles: [String], source: NewsSource? = nil) -> NewsDigestComposer.SourceResult {
        NewsDigestComposer.SourceResult(source: source ?? self.source(),
                                        outcome: .ok(titles))
    }

    // MARK: - TTS sanitization

    func testDecodesNamedEntities() {
        XCTAssertEqual(NewsDigestComposer.sanitizedTitle("Fire &amp; rescue"),
                       "Fire & rescue")
        // Decode-then-strip order: the decoded <b> is tag-shaped and is
        // stripped, so no angle brackets ever reach TTS.
        XCTAssertEqual(NewsDigestComposer.sanitizedTitle("A &lt;b&gt;old headline"),
                       "A old headline")
    }

    func testDecodesNumericAndHexEntities() {
        // &#039; is the straight apostrophe (U+0027), not the curly one.
        XCTAssertEqual(NewsDigestComposer.sanitizedTitle("Nepal&#039;s first portal"),
                       "Nepal's first portal")
        XCTAssertEqual(NewsDigestComposer.sanitizedTitle("Smile &#x1F600; today"),
                       "Smile 😀 today")
    }

    func testDecodeIsSinglePass() {
        // A feed that double-encodes ("&amp;quot;") must decode to the
        // literal text "&quot;", never to a quote — a second pass would
        // have invented content the feed did not carry.
        XCTAssertEqual(NewsDigestComposer.sanitizedTitle("Say &amp;quot;hello&amp;quot;"),
                       "Say &quot;hello&quot;")
    }

    func testDecodedTextIsNotDecodedAgain() {
        // XMLParser already resolved this in a normal text node — the
        // composer's pass must leave it untouched.
        XCTAssertEqual(NewsDigestComposer.sanitizedTitle("Nepal’s first portal"),
                       "Nepal’s first portal")
        XCTAssertEqual(NewsDigestComposer.sanitizedTitle("AT&T wireless"),
                       "AT&T wireless")
    }

    func testUnknownNamedEntityDegradesToInnerText() {
        XCTAssertEqual(NewsDigestComposer.sanitizedTitle("Price &bogus; drop"),
                       "Price bogus drop")
    }

    func testStripsEmbeddedTagsAndURLs() {
        XCTAssertEqual(NewsDigestComposer.sanitizedTitle("Big <b>win</b> for the team"),
                       "Big win for the team")
        XCTAssertEqual(NewsDigestComposer.sanitizedTitle("Read more at https://example.com/news today"),
                       "Read more at today")
        XCTAssertEqual(NewsDigestComposer.sanitizedTitle("Visit www.example.com now"),
                       "Visit now")
    }

    func testTrailingColonIsStripped() {
        // A trailing colon is a list/continuation artifact ("Read more:
        // <url>") — once the URL is stripped it dangles and reads aloud
        // like a prompt for text that never comes.
        XCTAssertEqual(NewsDigestComposer.sanitizedTitle("Read more: https://example.com/x"),
                       "Read more")
        XCTAssertEqual(NewsDigestComposer.sanitizedTitle("Live blog:"),
                       "Live blog")
        XCTAssertNil(NewsDigestComposer.sanitizedTitle(":"))
    }

    func testCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(NewsDigestComposer.sanitizedTitle("  Rain   and\n\nmore rain\t today  "),
                       "Rain and more rain today")
    }

    func testNothingSpeakableReturnsNil() {
        XCTAssertNil(NewsDigestComposer.sanitizedTitle("   "))
        XCTAssertNil(NewsDigestComposer.sanitizedTitle("https://example.com"))
        XCTAssertNil(NewsDigestComposer.sanitizedTitle("<b></b>"))
    }

    func testNepaliScriptSurvivesSanitization() {
        XCTAssertEqual(NewsDigestComposer.sanitizedTitle("काठमाडौंमा वर्षा&nbsp;सुरु"),
                       "काठमाडौंमा वर्षा सुरु")
    }

    // MARK: - Digest templates (en)

    func testEnglishDigestLines() {
        let results = [
            ok(["First headline", "Second headline"]),
            ok(["Solo headline"])
        ]
        XCTAssertEqual(NewsDigestComposer.lines(for: results, locale: en), [
            "From BBC World: First headline. Second headline.",
            "From BBC World: Solo headline."
        ])
    }

    func testEnglishDigestTextJoinsLinesWithNewlines() {
        let results = [ok(["First headline"]), ok(["Second headline"])]
        XCTAssertEqual(NewsDigestComposer.digestText(for: results, locale: en),
                       "From BBC World: First headline.\nFrom BBC World: Second headline.")
    }

    // MARK: - Digest templates (ne)

    func testNepaliDigestUsesDevanagariSentenceStop() {
        let results = [ok(["पहिलो शीर्षक", "दोस्रो शीर्षक"])]
        let lines = NewsDigestComposer.lines(for: results, locale: ne)
        XCTAssertEqual(lines, [
            L10n.fmt("news.sourceLine", locale: ne, "BBC World") + " पहिलो शीर्षक। दोस्रो शीर्षक।"
        ])
        XCTAssertTrue(lines[0].contains("। "), "Nepali headlines join with the Devanagari stop")
    }

    func testNepaliSourceLineTemplate() {
        let results = [ok(["एउटा शीर्षक"])]
        let lines = NewsDigestComposer.lines(for: results, locale: ne)
        XCTAssertTrue(lines[0].hasPrefix("BBC World बाट:"))
    }

    // MARK: - Headline cap

    func testCapsHeadlinesAtThreePerSource() {
        let results = [ok(["H1", "H2", "H3", "H4", "H5"])]
        let lines = NewsDigestComposer.lines(for: results, locale: en)
        XCTAssertEqual(lines, ["From BBC World: H1. H2. H3."])
    }

    func testRenderSeamDefensivelyReSanitizesRawTitles() {
        // The render seam is the last gate before the speaker: even RAW
        // (entity-carrying) titles render speakable text (idempotent —
        // production titles arrive already sanitized).
        let raw = ok(["Fire &amp; rescue drill", "Read: https://example.com/x"])
        XCTAssertEqual(NewsDigestComposer.lines(for: [raw], locale: en),
                       ["From BBC World: Fire & rescue drill. Read."])
    }

    func testSourceWhoseTitlesAllSanitizeToNothingRendersHonestEmptyLine() {
        let nothingSpeakable = ok(["https://example.com", "&nbsp;"])
        XCTAssertEqual(NewsDigestComposer.lines(for: [nothingSpeakable], locale: en),
                       [L10n.fmt("news.sourceEmpty", locale: en, "BBC World")],
                       "never a bare 'From X:' line")
    }

    // MARK: - Honest outcome rules

    func testAllSourcesFailedProducesSingleAllFailedLine() {
        let results = [
            NewsDigestComposer.SourceResult(source: source("BBC World"), outcome: .failed),
            NewsDigestComposer.SourceResult(source: source("NPR News"), outcome: .failed)
        ]
        XCTAssertEqual(NewsDigestComposer.lines(for: results, locale: en),
                       [L10n.str("news.allFailed", locale: en)])
    }

    func testAllSourcesEmptyProducesSingleAllEmptyLine() {
        let results = [
            NewsDigestComposer.SourceResult(source: source("BBC World"), outcome: .empty),
            NewsDigestComposer.SourceResult(source: source("NPR News"), outcome: .empty)
        ]
        XCTAssertEqual(NewsDigestComposer.lines(for: results, locale: en),
                       [L10n.str("news.allEmpty", locale: en)])
    }

    func testMixedFailAndEmptyWithoutItemsUsesHonestPerSourceLines() {
        // No source has items but only SOME failed — per-source honest
        // lines, never the all-failed claim (one source did respond: it
        // just had nothing).
        let results = [
            NewsDigestComposer.SourceResult(source: source("BBC World"), outcome: .failed),
            NewsDigestComposer.SourceResult(source: source("NPR News"), outcome: .empty)
        ]
        XCTAssertEqual(NewsDigestComposer.lines(for: results, locale: en), [
            L10n.fmt("news.sourceFailed", locale: en, "BBC World"),
            L10n.fmt("news.sourceEmpty", locale: en, "NPR News")
        ])
    }

    func testMixedOkEmptyAndFailedLines() {
        let results = [
            ok(["H1"]),
            NewsDigestComposer.SourceResult(source: source("NPR News"), outcome: .empty),
            NewsDigestComposer.SourceResult(source: source("Setopati"), outcome: .failed)
        ]
        XCTAssertEqual(NewsDigestComposer.lines(for: results, locale: en), [
            "From BBC World: H1.",
            L10n.fmt("news.sourceEmpty", locale: en, "NPR News"),
            L10n.fmt("news.sourceFailed", locale: en, "Setopati")
        ])
    }

    func testEmptyResultsStillSpeakTheHonestAllFailedLine() {
        // Zero sources must never be silence (constitution: no silent
        // stubs) — the honest "couldn't fetch" line stands in.
        XCTAssertEqual(NewsDigestComposer.lines(for: [], locale: en),
                       [L10n.str("news.allFailed", locale: en)])
    }

    func testNepaliAllFailedLine() {
        let results = [NewsDigestComposer.SourceResult(source: source(), outcome: .failed)]
        XCTAssertEqual(NewsDigestComposer.lines(for: results, locale: ne),
                       [L10n.str("news.allFailed", locale: ne)])
    }

    // MARK: - Sentence stop

    func testSentenceStop() {
        XCTAssertEqual(NewsDigestComposer.sentenceStop(for: en), ". ")
        XCTAssertEqual(NewsDigestComposer.sentenceStop(for: ne), "। ")
    }
}
