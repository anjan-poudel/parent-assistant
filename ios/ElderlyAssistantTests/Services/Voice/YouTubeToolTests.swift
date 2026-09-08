import XCTest
@testable import ElderlyAssistant

/// [YOUTUBE] (2026-09-08) URL construction (native scheme + https +
/// Data API, percent-encoding), Data API response parsing (top result,
/// empty, malformed), fetch error mapping, the app-present/absent open
/// decisions over a fake `CallLinkOpening`, and the `YouTubeConfigStore`
/// credential lifecycle.
final class YouTubeToolTests: XCTestCase {

    // MARK: - URL construction

    func testAppSearchURLShape() {
        let url = YouTubeTool.appSearchURL(query: "new song")
        XCTAssertEqual(url.absoluteString,
                       "youtube://www.youtube.com/results?search_query=new%20song")
        XCTAssertEqual(url.scheme, "youtube")
        XCTAssertEqual(url.host, "www.youtube.com")
        XCTAssertEqual(url.path, "/results")
    }

    func testWebSearchURLShape() {
        let url = YouTubeTool.webSearchURL(query: "new song")
        XCTAssertEqual(url.absoluteString,
                       "https://www.youtube.com/results?search_query=new%20song")
        XCTAssertEqual(url.scheme, "https")
    }

    func testSearchURLsPercentEncodeNepaliAndReservedCharacters() {
        let app = YouTubeTool.appSearchURL(query: "गीत & फूल")
        let web = YouTubeTool.webSearchURL(query: "गीत & फूल")
        XCTAssertEqual(app.absoluteString,
                       "youtube://www.youtube.com/results?search_query=%E0%A4%97%E0%A5%80%E0%A4%A4%20%26%20%E0%A4%AB%E0%A5%82%E0%A4%B2")
        XCTAssertEqual(web.absoluteString,
                       "https://www.youtube.com/results?search_query=%E0%A4%97%E0%A5%80%E0%A4%A4%20%26%20%E0%A4%AB%E0%A5%82%E0%A4%B2")
        // The encoded value round-trips to the original query.
        let decoded = URLComponents(url: app, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "search_query" }?.value
        XCTAssertEqual(decoded, "गीत & फूल")
    }

    func testWatchURLShapes() {
        XCTAssertEqual(YouTubeTool.appWatchURL(videoID: "dQw4w9WgXcQ").absoluteString,
                       "youtube://watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeTool.webWatchURL(videoID: "dQw4w9WgXcQ").absoluteString,
                       "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    func testAPISearchURLShape() {
        let url = YouTubeTool.apiSearchURL(query: "bhajan", apiKey: "test-key")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.host, "www.googleapis.com")
        XCTAssertEqual(url.path, "/youtube/v3/search")
        XCTAssertEqual(items.first { $0.name == "part" }?.value, "snippet")
        XCTAssertEqual(items.first { $0.name == "type" }?.value, "video")
        XCTAssertEqual(items.first { $0.name == "maxResults" }?.value, "1")
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "bhajan")
        XCTAssertEqual(items.first { $0.name == "key" }?.value, "test-key")
    }

    // MARK: - Parsing

    private var topResultJSON: Data {
        Data(#"{"items": [{"id": {"kind": "youtube#video", "videoId": "abc123"},"#.utf8)
            + Data(#" "snippet": {"title": "Bhajan Ganga"}}]}"#.utf8)
    }

    func testParseExtractsTopVideoIDAndTitle() {
        let result = YouTubeTool.parseSearchJSON(data: topResultJSON)
        XCTAssertEqual(result, YouTubeTool.TopVideoResult(videoID: "abc123", title: "Bhajan Ganga"))
    }

    func testParseCollapsesTitleWhitespace() {
        let data = Data(#"{"items": [{"id": {"videoId": "abc"},"#.utf8)
            + Data(#" "snippet": {"title": "Bhajan\n  Ganga\tMix"}}]}"#.utf8)
        XCTAssertEqual(YouTubeTool.parseSearchJSON(data: data)?.title, "Bhajan Ganga Mix")
    }

    func testParseEmptyItemsReturnsNil() {
        XCTAssertNil(YouTubeTool.parseSearchJSON(data: Data(#"{"items": []}"#.utf8)))
        XCTAssertNil(YouTubeTool.parseSearchJSON(data: Data(#"{}"#.utf8)),
                     "a payload with no items key (empty result set) is no result")
    }

    func testParseHitWithoutVideoIDReturnsNil() {
        let data = Data(#"{"items": [{"id": {"kind": "youtube#channel","#.utf8)
            + Data(#" "channelId": "UC123"}, "snippet": {"title": "A Channel"}}]}"#.utf8)
        XCTAssertNil(YouTubeTool.parseSearchJSON(data: data),
                     "a channel hit has no videoId and is not playable")
    }

    func testParseBlankTitleReturnsNil() {
        let data = Data(#"{"items": [{"id": {"videoId": "abc"},"#.utf8)
            + Data(#" "snippet": {"title": "   "}}]}"#.utf8)
        XCTAssertNil(YouTubeTool.parseSearchJSON(data: data))
    }

    func testParseNonJSONReturnsNil() {
        XCTAssertNil(YouTubeTool.parseSearchJSON(data: Data("not json".utf8)))
    }

    // MARK: - Fetch error mapping

    func testFetchTopResultReturnsParsedHit() async throws {
        let transport = StubYouTubeTransport(data: topResultJSON, statusCode: 200)
        let result = try await YouTubeTool.fetchTopResult(query: "bhajan", apiKey: "k",
                                                          transport: transport)
        XCTAssertEqual(result.videoID, "abc123")
        XCTAssertEqual(transport.capturedRequests.first?.timeoutInterval,
                       YouTubeTool.fetchTimeoutSeconds,
                       "the request must carry the tool's bounded timeout")
    }

    func testFetchNon200ThrowsInvalidResponse() async {
        let transport = StubYouTubeTransport(data: Data(), statusCode: 403)
        do {
            _ = try await YouTubeTool.fetchTopResult(query: "bhajan", apiKey: "k",
                                                     transport: transport)
            XCTFail("a quota/rate-limit 403 must throw, never fabricate a result")
        } catch let error as YouTubeTool.FetchError {
            XCTAssertEqual(error, .invalidResponse(statusCode: 403))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testFetchEmptyResultSetThrowsNoResults() async {
        let transport = StubYouTubeTransport(data: Data(#"{"items": []}"#.utf8), statusCode: 200)
        do {
            _ = try await YouTubeTool.fetchTopResult(query: "zzz", apiKey: "k",
                                                     transport: transport)
            XCTFail("an empty result set must throw")
        } catch let error as YouTubeTool.FetchError {
            XCTAssertEqual(error, .noResults)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testFetchUndecodablePayloadThrowsMalformedResponse() async {
        let transport = StubYouTubeTransport(data: Data("garbage".utf8), statusCode: 200)
        do {
            _ = try await YouTubeTool.fetchTopResult(query: "x", apiKey: "k",
                                                     transport: transport)
            XCTFail("an undecodable payload must throw")
        } catch let error as YouTubeTool.FetchError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testFetchTransportErrorPropagates() async {
        struct Boom: Error {}
        let transport = StubYouTubeTransport(data: Data(), statusCode: 200, error: Boom())
        do {
            _ = try await YouTubeTool.fetchTopResult(query: "x", apiKey: "k",
                                                     transport: transport)
            XCTFail("a transport error must propagate to the caller")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    // MARK: - Open decisions

    func testOpenSearchAppPresentUsesNativeScheme() {
        let opener = FakeLinkOpener(canOpen: true)
        XCTAssertEqual(YouTubeTool.openSearch(query: "bhajan", opener: opener), .openedApp)
        XCTAssertEqual(opener.opened, [YouTubeTool.appSearchURL(query: "bhajan")])
        XCTAssertEqual(opener.canOpenChecks, [YouTubeTool.appSearchURL(query: "bhajan")])
    }

    func testOpenSearchAppAbsentFallsBackToWeb() {
        let opener = FakeLinkOpener(canOpen: false)
        XCTAssertEqual(YouTubeTool.openSearch(query: "bhajan", opener: opener), .openedWeb)
        XCTAssertEqual(opener.opened, [YouTubeTool.webSearchURL(query: "bhajan")])
    }

    func testOpenWatchAppPresentUsesNativeScheme() {
        let opener = FakeLinkOpener(canOpen: true)
        XCTAssertEqual(YouTubeTool.openWatch(videoID: "abc123", opener: opener), .openedApp)
        XCTAssertEqual(opener.opened, [YouTubeTool.appWatchURL(videoID: "abc123")])
    }

    func testOpenWatchAppAbsentFallsBackToWeb() {
        let opener = FakeLinkOpener(canOpen: false)
        XCTAssertEqual(YouTubeTool.openWatch(videoID: "abc123", opener: opener), .openedWeb)
        XCTAssertEqual(opener.opened, [YouTubeTool.webWatchURL(videoID: "abc123")])
    }

    // MARK: - Config store

    func testConfigStoreIsUnconfiguredByDefault() {
        let store = YouTubeConfigStore(storage: GeminiInMemoryStorage())
        XCTAssertNil(store.apiKey)
        XCTAssertFalse(store.isConfigured)
    }

    func testConfigStorePersistsAndReloadsTheKey() {
        let storage = GeminiInMemoryStorage()
        let store = YouTubeConfigStore(storage: storage)
        store.saveAPIKey("  key-123  ")
        XCTAssertEqual(store.apiKey, "key-123", "the key must be whitespace-trimmed")
        XCTAssertTrue(store.isConfigured)
        XCTAssertEqual(YouTubeConfigStore(storage: storage).apiKey, "key-123")
    }

    func testConfigStoreClearRemovesTheKey() {
        let storage = GeminiInMemoryStorage()
        let store = YouTubeConfigStore(storage: storage)
        store.saveAPIKey("key-123")
        store.clear()
        XCTAssertNil(store.apiKey)
        XCTAssertFalse(store.isConfigured)
        XCTAssertNil(YouTubeConfigStore(storage: storage).apiKey)
    }

    func testConfigStoreEmptySaveClearsOnlyTheKey() {
        let storage = GeminiInMemoryStorage()
        let store = YouTubeConfigStore(storage: storage)
        store.saveAPIKey("key-123")
        store.saveAPIKey("   ")
        XCTAssertNil(store.apiKey)
    }
}

// MARK: - Doubles

/// Scripted `LocalToolTransport` for the Data API round-trip.
private final class StubYouTubeTransport: LocalToolTransport {
    private(set) var capturedRequests: [URLRequest] = []
    private let data: Data
    private let statusCode: Int
    private let error: Error?

    init(data: Data, statusCode: Int, error: Error? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.error = error
    }

    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequests.append(request)
        if let error { throw error }
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://stub.local")!,
                                       statusCode: statusCode,
                                       httpVersion: nil,
                                       headerFields: nil)!
        return (data, response)
    }
}

/// Scripted `CallLinkOpening` — records every probe and open so tests
/// assert the exact URLs and the app-present/absent branches.
private final class FakeLinkOpener: CallLinkOpening {
    let canOpen: Bool
    private(set) var canOpenChecks: [URL] = []
    private(set) var opened: [URL] = []

    init(canOpen: Bool) {
        self.canOpen = canOpen
    }

    func canOpenURL(_ url: URL) -> Bool {
        canOpenChecks.append(url)
        return canOpen
    }

    func open(_ url: URL) {
        opened.append(url)
    }
}
