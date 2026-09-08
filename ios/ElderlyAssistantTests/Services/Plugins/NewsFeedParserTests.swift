import XCTest
@testable import ElderlyAssistant

/// [NEWS-READER] (2026-09-08) `NewsFeedParser` unit tests:
///  - RSS 2.0 item/title extraction (plain text + CDATA),
///  - Atom entry/title extraction (default-namespace atom),
///  - channel/feed-level titles are NEVER captured,
///  - well-formed-but-empty feeds → `.empty`; broken XML → `.malformed`
///    (a parse failure is a FAILURE, never "nothing new"),
///  - whitespace-only titles are dropped,
///  - raw-title contract: the parser does NOT decode HTML entities in
///    CDATA (the digest composer owns decoding — pinned split).
final class NewsFeedParserTests: XCTestCase {

    private func data(_ xml: String) -> Data { Data(xml.utf8) }

    // MARK: - RSS 2.0

    func testExtractsItemTitlesFromRSS() {
        let feed = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel>
          <title>BBC News</title>
          <item><title>First headline</title></item>
          <item><title>Second headline</title></item>
        </channel></rss>
        """
        XCTAssertEqual(NewsFeedParser.parse(data(feed)),
                       .ok([NewsHeadline(title: "First headline"),
                            NewsHeadline(title: "Second headline")]))
    }

    func testChannelTitleIsNeverCaptured() {
        let feed = """
        <rss version="2.0"><channel>
          <title>BBC News</title>
          <item><title>A real headline</title></item>
        </channel></rss>
        """
        XCTAssertEqual(NewsFeedParser.parse(data(feed)),
                       .ok([NewsHeadline(title: "A real headline")]))
    }

    func testExtractsCDATATitles() {
        // BBC's real feed shape: titles wrapped in CDATA.
        let feed = """
        <rss version="2.0"><channel><item>
          <title><![CDATA[Police say the fire started &amp; spread quickly]]></title>
        </item></channel></rss>
        """
        XCTAssertEqual(NewsFeedParser.parse(data(feed)),
                       .ok([NewsHeadline(title: "Police say the fire started &amp; spread quickly")]),
                       "CDATA titles arrive RAW — entity decoding is the digest composer's job")
    }

    func testNumericEntityInNormalTextNodeArrivesDecoded() {
        // In normal text nodes XMLParser resolves character references
        // per the XML spec (Ratopati's &#039; shape). The composer's
        // decode pass is a no-op on this text — pinned so the two
        // stages can never double-decode.
        let feed = """
        <rss version="2.0"><channel><item>
          <title>Nepal&#039;s first 24-hour portal</title>
        </item></channel></rss>
        """
        XCTAssertEqual(NewsFeedParser.parse(data(feed)),
                       .ok([NewsHeadline(title: "Nepal's first 24-hour portal")]))
    }

    func testWhitespaceOnlyTitleIsDropped() {
        let feed = """
        <rss version="2.0"><channel>
          <item><title>   </title></item>
          <item><title>Kept headline</title></item>
        </channel></rss>
        """
        XCTAssertEqual(NewsFeedParser.parse(data(feed)),
                       .ok([NewsHeadline(title: "Kept headline")]))
    }

    // MARK: - Atom

    func testExtractsEntryTitlesFromAtom() {
        let feed = """
        <?xml version="1.0"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>The Guardian</title>
          <entry>
            <title>Atom headline one</title>
          </entry>
          <entry>
            <title>Atom headline two</title>
          </entry>
        </feed>
        """
        XCTAssertEqual(NewsFeedParser.parse(data(feed)),
                       .ok([NewsHeadline(title: "Atom headline one"),
                            NewsHeadline(title: "Atom headline two")]),
                       "XMLParser reports local element names (no namespace processing), so default-ns Atom parses like plain XML")
    }

    func testAtomFeedTitleIsNeverCaptured() {
        let feed = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>The Guardian</title>
        </feed>
        """
        XCTAssertEqual(NewsFeedParser.parse(data(feed)), .empty)
    }

    // MARK: - Empty / malformed

    func testWellFormedFeedWithoutItemsIsEmpty() {
        let feed = """
        <rss version="2.0"><channel><title>Nothing today</title></channel></rss>
        """
        XCTAssertEqual(NewsFeedParser.parse(data(feed)), .empty)
    }

    func testMalformedXMLIsMalformedNeverEmpty() {
        XCTAssertEqual(NewsFeedParser.parse(data("<rss><channel><item><title>unclosed")),
                       .malformed)
    }

    func testNonXMLPayloadIsMalformed() {
        // A feed URL serving an HTML error page (plain text) must read as
        // a per-source FAILURE, never as "nothing new".
        XCTAssertEqual(NewsFeedParser.parse(data("Not a feed: 404 page not found")),
                       .malformed)
    }

    func testEmptyDataIsMalformed() {
        XCTAssertEqual(NewsFeedParser.parse(Data()), .malformed)
    }
}
