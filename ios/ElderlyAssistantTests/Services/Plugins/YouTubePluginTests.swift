import XCTest
@testable import ElderlyAssistant

/// [YOUTUBE] (2026-09-08) The interpreter-side YouTube plugin: intent
/// contribution (one action + a query-entity fragment), locale
/// applicability, and the `handle` behavior over fake config/transport/
/// opener seams — keyless search deeplink, keyed top-result watch link,
/// and the honest `.failed` lines.
final class YouTubePluginTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")

    private func makePlugin(apiKey: String? = nil,
                            transport: LocalToolTransport? = nil,
                            opener: CallLinkOpening? = nil)
        -> (YouTubePlugin, YouTubeConfigStore) {
        let store = YouTubeConfigStore(storage: GeminiInMemoryStorage())
        if let apiKey { store.saveAPIKey(apiKey) }
        let plugin = YouTubePlugin(configStore: store,
                                   transport: transport ?? StubYouTubeTransport(data: Data(), statusCode: 200),
                                   linkOpener: opener ?? FakeLinkOpener(canOpen: true))
        return (plugin, store)
    }

    private func makeContext(locale: Locale = Locale(identifier: "ne-NP"),
                             bus: MockObservabilityBus? = nil) -> (PluginExecutionContext, MockObservabilityBus) {
        let bus = bus ?? MockObservabilityBus()
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let client = GeminiClient(configStore: store, observabilityBus: MockObservabilityBus(),
                                  transport: FakeGeminiTransport())
        return (PluginExecutionContext(locale: locale, geminiClient: client, observabilityBus: bus), bus)
    }

    private var topResultJSON: Data {
        Data(#"{"items": [{"id": {"kind": "youtube#video", "videoId": "abc123"},"#.utf8)
            + Data(#" "snippet": {"title": "Bhajan Ganga"}}]}"#.utf8)
    }

    func testApplicableToBothLocales() {
        let (plugin, _) = makePlugin()
        XCTAssertTrue(plugin.isApplicable(locale: Locale(identifier: "en")))
        XCTAssertTrue(plugin.isApplicable(locale: Locale(identifier: "ne-NP")))
    }

    func testIntentContributionDeclaresOneActionAndAQueryFragment() {
        let (plugin, _) = makePlugin()
        XCTAssertEqual(plugin.intentContribution.actionNames, ["youtube.play"])
        XCTAssertTrue(plugin.intentContribution.promptFragment.contains("youtube.play"))
        XCTAssertTrue(plugin.intentContribution.promptFragment.contains("query"))
    }

    func testHandleWithNoQueryEntityFailsHonestly() async {
        let (plugin, _) = makePlugin()
        let (context, bus) = makeContext()
        let result = await plugin.handle(
            PluginCommand(actionName: "youtube.play", transcript: "", entities: [:], confidence: 0.9),
            context: context)
        XCTAssertEqual(result, .failed(spokenApology: L10n.str("youtube.unavailable", locale: ne)))
        XCTAssertTrue(bus.emittedEvents.contains { $0.component == "plugin_youtube" })
    }

    func testKeylessHandleOpensSearchDeeplink() async {
        let opener = FakeLinkOpener(canOpen: true)
        let (plugin, _) = makePlugin(opener: opener)
        let (context, bus) = makeContext()
        let result = await plugin.handle(
            PluginCommand(actionName: "youtube.play", transcript: "",
                          entities: ["query": "भजन"], confidence: 0.9),
            context: context)
        XCTAssertEqual(result, .spoken(L10n.fmt("youtube.openingSearch", locale: ne, "भजन")))
        XCTAssertEqual(opener.opened, [YouTubeTool.appSearchURL(query: "भजन")])
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "plugin_youtube" && $0.eventType == "youtube_plugin_search_opened"
        })
    }

    func testKeylessHandleAppAbsentOpensWebSearchURL() async {
        let opener = FakeLinkOpener(canOpen: false)
        let (plugin, _) = makePlugin(opener: opener)
        let (context, _) = makeContext()
        _ = await plugin.handle(
            PluginCommand(actionName: "youtube.play", transcript: "",
                          entities: ["query": "news"], confidence: 0.9),
            context: context)
        XCTAssertEqual(opener.opened, [YouTubeTool.webSearchURL(query: "news")])
    }

    func testKeyedHandleOpensWatchLinkWithSpokenTitle() async {
        let opener = FakeLinkOpener(canOpen: true)
        let transport = StubYouTubeTransport(data: topResultJSON, statusCode: 200)
        let (plugin, _) = makePlugin(apiKey: "k123", transport: transport, opener: opener)
        let (context, bus) = makeContext()
        let result = await plugin.handle(
            PluginCommand(actionName: "youtube.play", transcript: "",
                          entities: ["query": "bhajan"], confidence: 0.9),
            context: context)
        XCTAssertEqual(result, .spoken(L10n.fmt("youtube.playing", locale: ne, "Bhajan Ganga")))
        XCTAssertEqual(opener.opened, [YouTubeTool.appWatchURL(videoID: "abc123")])
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "plugin_youtube" && $0.eventType == "youtube_plugin_played"
        })
        XCTAssertTrue(bus.emittedEvents.allSatisfy { $0.metadata.isEmpty },
                      "no query or title may reach the bus")
    }

    func testKeyedHandleNoResultsFailsHonestly() async {
        let transport = StubYouTubeTransport(data: Data(#"{"items": []}"#.utf8), statusCode: 200)
        let (plugin, _) = makePlugin(apiKey: "k123", transport: transport)
        let (context, _) = makeContext()
        let result = await plugin.handle(
            PluginCommand(actionName: "youtube.play", transcript: "",
                          entities: ["query": "zzz"], confidence: 0.9),
            context: context)
        XCTAssertEqual(result, .failed(spokenApology: L10n.str("youtube.notFound", locale: ne)))
    }

    func testKeyedHandleNetworkFailureFailsHonestly() async {
        struct Boom: Error {}
        let transport = StubYouTubeTransport(data: Data(), statusCode: 200, error: Boom())
        let (plugin, _) = makePlugin(apiKey: "k123", transport: transport)
        let (context, _) = makeContext()
        let result = await plugin.handle(
            PluginCommand(actionName: "youtube.play", transcript: "",
                          entities: ["query": "bhajan"], confidence: 0.9),
            context: context)
        XCTAssertEqual(result, .failed(spokenApology: L10n.str("youtube.unavailable", locale: ne)))
    }
}

// MARK: - Doubles

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
