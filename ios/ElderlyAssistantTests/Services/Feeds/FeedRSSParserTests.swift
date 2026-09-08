import XCTest
@testable import ElderlyAssistant

/// Feed parser tests (feed-agent task, 2026-09-08) — RSS/Atom enclosures
/// → kinds, dates, CDATA, entities, id fallbacks, caps, and the
/// thumbnail-does-not-flip-the-kind rule.
final class FeedRSSParserTests: XCTestCase {

    private func parse(_ xml: String, sourceName: String = "Test Source",
                       maxItems: Int = 20) -> [FeedItem] {
        FeedRSSParser.parse(data: Data(xml.utf8), sourceName: sourceName,
                            maxItems: maxItems)
    }

    /// A minimal RSS item with the given extra child elements (title and
    /// link always present so the item is never skipped for being empty).
    private func rssItem(children: String) -> String {
        """
        <?xml version="1.0"?>
        <rss version="2.0"><channel><title>Channel</title>
        <item><title>Story title</title><link>https://example.com/item</link>
        \(children)</item></channel></rss>
        """
    }

    // MARK: - Enclosures → kinds

    func testAudioEnclosureProducesAudioItem() {
        let items = parse(rssItem(children:
            #"<enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="1000"/>"#))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .audio)
        XCTAssertEqual(items[0].mediaURL, "https://example.com/a.mp3")
        XCTAssertNil(items[0].imageURL)
    }

    func testVideoEnclosureProducesVideoItem() {
        let items = parse(rssItem(children:
            #"<enclosure url="https://example.com/v.mp4" type="video/mp4"/>"#))
        XCTAssertEqual(items[0].kind, .video)
        XCTAssertEqual(items[0].mediaURL, "https://example.com/v.mp4")
    }

    func testImageEnclosureProducesImageItem() {
        let items = parse(rssItem(children:
            #"<enclosure url="https://example.com/p.jpg" type="image/jpeg"/>"#))
        XCTAssertEqual(items[0].kind, .image)
        XCTAssertNil(items[0].mediaURL)
        XCTAssertEqual(items[0].imageURL, "https://example.com/p.jpg")
    }

    func testAudioWinsOverImageEnclosure() {
        let items = parse(rssItem(children: """
            <enclosure url="https://example.com/p.jpg" type="image/jpeg"/>
            <enclosure url="https://example.com/a.mp3" type="audio/mpeg"/>
            """))
        XCTAssertEqual(items[0].kind, .audio)
        XCTAssertEqual(items[0].mediaURL, "https://example.com/a.mp3")
        XCTAssertEqual(items[0].imageURL, "https://example.com/p.jpg",
                       "the image URL survives as the thumbnail")
    }

    func testUnknownMimeTypeFallsBackToText() {
        let items = parse(rssItem(children:
            #"<enclosure url="https://example.com/doc.pdf" type="application/pdf"/>"#))
        XCTAssertEqual(items[0].kind, .text)
        XCTAssertNil(items[0].mediaURL)
        XCTAssertNil(items[0].imageURL)
    }

    func testNoEnclosureIsText() {
        let items = parse(rssItem(children: "<description>Plain story</description>"))
        XCTAssertEqual(items[0].kind, .text)
        XCTAssertNil(items[0].mediaURL)
        XCTAssertNil(items[0].imageURL)
    }

    func testThumbnailDoesNotFlipTextStoryToImage() {
        // The BBC shape: every story carries a media:thumbnail — it must
        // remain a TEXT item (with the thumbnail as its imageURL), so the
        // read-aloud action survives.
        let items = parse(rssItem(children: """
            <description>News story body</description>
            <media:thumbnail url="https://example.com/t.jpg"/>
            """))
        XCTAssertEqual(items[0].kind, .text)
        XCTAssertEqual(items[0].imageURL, "https://example.com/t.jpg")
        XCTAssertNil(items[0].mediaURL)
    }

    func testMediaContentWithMediumFallbackType() {
        // media:content without a type but with medium="video".
        let items = parse(rssItem(children:
            #"<media:content url="https://example.com/v.mp4" medium="video"/>"#))
        XCTAssertEqual(items[0].kind, .video)
        XCTAssertEqual(items[0].mediaURL, "https://example.com/v.mp4")
    }

    // MARK: - Dates

    func testRSSPubDateRFC822Parses() {
        let items = parse(rssItem(children: "<pubDate>Tue, 08 Sep 2026 08:00:00 +0000</pubDate>"))
        let expected = ISO8601DateFormatter().date(from: "2026-09-08T08:00:00Z")
        XCTAssertEqual(items[0].publishedAt, expected)
    }

    func testRSSPubDateWithoutWeekdayParsesLoose() {
        let items = parse(rssItem(children: "<pubDate>08 Sep 2026 08:00:00 +0000</pubDate>"))
        let expected = ISO8601DateFormatter().date(from: "2026-09-08T08:00:00Z")
        XCTAssertEqual(items[0].publishedAt, expected)
    }

    func testMissingPubDateIsNil() {
        let items = parse(rssItem(children: ""))
        XCTAssertNil(items[0].publishedAt)
    }

    // MARK: - CDATA and entities

    func testEntitiesOutsideCDATAAreDecoded() {
        let items = parse(rssItem(children: "<description>Tom &amp; Jerry &lt;3</description>"))
        XCTAssertEqual(items[0].summary, "Tom & Jerry <3")
    }

    func testCDATAContentArrivesRaw() {
        // CDATA content is not entity-decoded — it arrives verbatim and
        // residual markup is the SANITIZER's job (display/speech).
        let items = parse(rssItem(children: "<description><![CDATA[<b>bold</b> & news]]></description>"))
        XCTAssertEqual(items[0].summary, "<b>bold</b> & news")
    }

    func testContentEncodedUsedWhenDescriptionAbsent() {
        let items = parse(rssItem(children: "<content:encoded>Full body text</content:encoded>"))
        XCTAssertEqual(items[0].summary, "Full body text")
    }

    func testDescriptionPreferredOverContentEncoded() {
        let items = parse(rssItem(children: """
            <description>Short summary</description>
            <content:encoded>Much longer full body</content:encoded>
            """))
        XCTAssertEqual(items[0].summary, "Short summary")
    }

    // MARK: - Atom

    func testAtomEntryParsesLinkSummaryAndEnclosure() {
        let atom = """
        <?xml version="1.0"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Example</title>
          <entry>
            <title>Atom story</title>
            <link rel="alternate" href="https://example.com/a"/>
            <link rel="enclosure" href="https://example.com/a.mp3" type="audio/mpeg"/>
            <id>tag:example.com,2026:a</id>
            <published>2026-09-08T08:00:00Z</published>
            <summary>Atom summary</summary>
          </entry>
        </feed>
        """
        let items = parse(atom)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Atom story")
        XCTAssertEqual(items[0].summary, "Atom summary")
        XCTAssertEqual(items[0].linkURL, "https://example.com/a")
        XCTAssertEqual(items[0].kind, .audio)
        XCTAssertEqual(items[0].mediaURL, "https://example.com/a.mp3")
        XCTAssertEqual(items[0].id, "tag:example.com,2026:a|Test Source")
        XCTAssertEqual(items[0].publishedAt,
                       ISO8601DateFormatter().date(from: "2026-09-08T08:00:00Z"))
    }

    func testAtomEntryWithoutEnclosureIsText() {
        let atom = """
        <?xml version="1.0"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <title>Plain atom</title>
            <link rel="alternate" href="https://example.com/b"/>
            <id>tag:example.com,2026:b</id>
          </entry>
        </feed>
        """
        let items = parse(atom)
        XCTAssertEqual(items[0].kind, .text)
        XCTAssertEqual(items[0].linkURL, "https://example.com/b")
    }

    // MARK: - Id fallbacks

    func testGuidIsPreferredId() {
        let items = parse(rssItem(children: "<guid>guid-123</guid>"))
        XCTAssertEqual(items[0].id, "guid-123|Test Source")
    }

    func testLinkIsFallbackId() {
        let items = parse(rssItem(children: ""))
        XCTAssertEqual(items[0].id, "https://example.com/item|Test Source")
    }

    func testTitleIsLastResortId() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel><title>Channel</title>
        <item><title>Only a title</title></item></channel></rss>
        """
        let items = parse(xml)
        XCTAssertEqual(items[0].id, "Only a title|Test Source")
    }

    // MARK: - Robustness and caps

    func testMalformedXMLYieldsNoItems() {
        let items = parse("<rss><channel><item><title>Broken")
        XCTAssertEqual(items.count, 0)
    }

    func testEmptyTitleAndSummaryItemIsSkipped() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel><title>C</title>
        <item><link>https://example.com/empty</link></item>
        <item><title>Real</title></item></channel></rss>
        """
        let items = parse(xml)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Real")
    }

    func testMaxItemsCapsTheParse() {
        var xml = "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>C</title>"
        for index in 0..<5 {
            xml += "<item><title>Story \(index)</title></item>"
        }
        xml += "</channel></rss>"
        let items = parse(xml, maxItems: 3)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.title), ["Story 0", "Story 1", "Story 2"])
    }

    func testTitleSurvivesAsFallbackWhenSummaryEmpty() {
        let items = parse(rssItem(children: ""))
        XCTAssertEqual(items[0].title, "Story title")
        XCTAssertTrue(items[0].summary.isEmpty)
    }

    func testSourceNameIsStampedOnItems() {
        let items = parse(rssItem(children: ""), sourceName: "BBC World")
        XCTAssertEqual(items[0].sourceName, "BBC World")
    }
}
