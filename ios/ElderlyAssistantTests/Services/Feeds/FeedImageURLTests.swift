import XCTest
@testable import ElderlyAssistant

/// Image URL selection tests (news-feed-images task, 2026-10-14) — the
/// one gate every feed image surface loads through.
///
/// `FeedItem.imageURL` is stored verbatim by the parser (which never
/// fabricates), so the display side owns the "is this a URL this app
/// will fetch?" decision. All three surfaces — the text card's
/// thumbnail, the image card and the reader — resolve through
/// `displayURL`, so none can load what the others refuse: an http(s)
/// URL with a real host loads, everything else renders the honest
/// placeholder instead of a request.
final class FeedImageURLTests: XCTestCase {

    func testAcceptsHTTPSAndHTTP() {
        XCTAssertEqual(FeedImageURL.displayURL("https://example.com/a.jpg")?.absoluteString,
                       "https://example.com/a.jpg")
        XCTAssertEqual(FeedImageURL.displayURL("http://example.com/a.jpg")?.absoluteString,
                       "http://example.com/a.jpg")
    }

    func testSchemeMatchIsCaseInsensitive() {
        XCTAssertNotNil(FeedImageURL.displayURL("HTTPS://example.com/a.jpg"))
        XCTAssertNotNil(FeedImageURL.displayURL("Http://example.com/a.jpg"))
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertNotNil(FeedImageURL.displayURL("  https://example.com/a.jpg\n"))
    }

    func testPreservesQueryAndFragment() {
        let url = FeedImageURL.displayURL("https://example.com/a.jpg?w=640&h=360#top")
        XCTAssertEqual(url?.query, "w=640&h=360")
        XCTAssertEqual(url?.fragment, "top")
    }

    func testRejectsAbsentOrEmptyReferences() {
        XCTAssertNil(FeedImageURL.displayURL(nil))
        XCTAssertNil(FeedImageURL.displayURL(""))
        XCTAssertNil(FeedImageURL.displayURL("   \n "))
    }

    func testRejectsNonWebSchemes() {
        XCTAssertNil(FeedImageURL.displayURL("file:///tmp/a.jpg"))
        XCTAssertNil(FeedImageURL.displayURL("javascript:alert(1)"))
        XCTAssertNil(FeedImageURL.displayURL("ftp://example.com/a.jpg"))
        XCTAssertNil(FeedImageURL.displayURL("data:image/png;base64,AAAA"))
    }

    func testRejectsRelativeAndHostlessReferences() {
        XCTAssertNil(FeedImageURL.displayURL("/photos/a.jpg"))
        XCTAssertNil(FeedImageURL.displayURL("photos/a.jpg"))
        XCTAssertNil(FeedImageURL.displayURL("https://"),
                     "a scheme with no host is not fetchable")
    }

    func testRejectsUnparseableStrings() {
        XCTAssertNil(FeedImageURL.displayURL("not a url"))
    }
}
