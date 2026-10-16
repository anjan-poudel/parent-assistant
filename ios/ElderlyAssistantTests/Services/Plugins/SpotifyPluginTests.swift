import XCTest
import SwiftUI
@testable import ElderlyAssistant

/// [SPOTIFY] (2026-10-07) T-118 — the interpreter-side Spotify plugin
/// (C-SP-05 / design-l2 §12, §27; FR-SP-006): intent contribution (one
/// action + the C-1-trimmed query-entity fragment under the YouTube
/// fragment's measured size model), locale applicability, and the `handle`
/// behavior over fake session/store/transport/opener seams — no-query,
/// unlinked, revoked, not-found, network-failure, premium remote play, the
/// free/unknown deep-link hand-off (L2-D14) and the app-absent terminal.
///
/// Every handle test asserts the exact event pair list (component
/// `plugin_spotify`, `metadata: [:]` on every event) and, where content
/// exists, sweeps the emitted events for the query, the title and the
/// token (NFR-SP-002 / M-1 — no query or title text in any event).
///
/// All doubles are file-private copies of the `CommandRouterMusicTests`
/// harness (that suite's doubles are private there); the shared
/// `SpotifyInMemoryStorage` and `RecordingObservabilityBus` fixtures are
/// reused as-is.
@MainActor
final class SpotifyPluginTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")

    // MARK: - Pinned fixture values

    private static let trackID = "4uLU6hMCjMI75M1A2tKUQC"
    private static let trackTitle = "Namo Namah"
    private static let storedAccessToken = "stored-access-token-1"

    private static let trackJSON = Data(
        #"{"tracks":{"items":[{"id":"4uLU6hMCjMI75M1A2tKUQC","name":"Namo Namah"}]}}"#.utf8)
    private static let emptyTracksJSON = Data(#"{"tracks":{"items":[]}}"#.utf8)
    private static let invalidGrantJSON = Data(
        #"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#.utf8)
    private static let restrictedForbiddenJSON = Data(
        #"{"error":{"status":403,"reason":"PLAYER_COMMAND_FAILED","message":"Restricted device"}}"#.utf8)

    // MARK: - World builder

    /// One plugin over one fake world with every seam scriptable: the
    /// credential store (linked record or none), the account session, the
    /// scripted transport, the probing link opener and the recording bus.
    /// (Nested types do not inherit the enclosing global actor — the
    /// annotation is explicit, the `CommandRouterMusicTests.MusicWorld`
    /// precedent.)
    @MainActor
    private final class PluginWorld {
        let store: SpotifyCredentialStore
        let session: SpotifyAccountSession
        let transport: PluginStubTransport
        let opener: PluginLinkOpener
        let bus: RecordingObservabilityBus
        let plugin: SpotifyPlugin

        init(store: SpotifyCredentialStore, session: SpotifyAccountSession,
             transport: PluginStubTransport, opener: PluginLinkOpener,
             bus: RecordingObservabilityBus, plugin: SpotifyPlugin) {
            self.store = store
            self.session = session
            self.transport = transport
            self.opener = opener
            self.bus = bus
            self.plugin = plugin
        }

        var pluginEvents: [ObservabilityEvent] {
            bus.events.filter { $0.component == "plugin_spotify" }
        }

        var pluginEventPairs: [String] {
            pluginEvents.map { "\($0.eventType)|\($0.outcome)" }
        }
    }

    private func makeWorld(linked: Bool = true,
                           product: String? = "premium",
                           expiry: Date? = nil,
                           searchReply: PluginStubTransport.Reply? = nil,
                           playReply: PluginStubTransport.Reply? = nil,
                           tokenReply: PluginStubTransport.Reply? = nil,
                           openerProbes: [Bool] = [true]) -> PluginWorld {
        let transport = PluginStubTransport()
        if let searchReply { transport.spotifySearchReply = searchReply }
        if let playReply { transport.spotifyPlayReply = playReply }
        if let tokenReply { transport.tokenReply = tokenReply }

        let store = SpotifyCredentialStore(storage: SpotifyInMemoryStorage())
        if linked {
            store.save(SpotifySessionRecord(accessToken: Self.storedAccessToken,
                                            refreshToken: "stored-refresh-token-1",
                                            expiry: expiry ?? Date(timeIntervalSinceNow: 3600),
                                            product: product,
                                            scope: "user-read-private user-modify-playback-state",
                                            linkedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        }
        let bus = RecordingObservabilityBus()
        let session = SpotifyAccountSession(store: store,
                                            flow: PluginUnusedAuthSession(),
                                            transport: transport,
                                            clientID: "client-test-1",
                                            refreshAttemptLimit: 1,
                                            capabilityStalenessSeconds: 3600,
                                            linkFlowTimeoutSeconds: 300,
                                            expirySkewSeconds: 60,
                                            observabilityBus: bus)
        let opener = PluginLinkOpener(probeResults: openerProbes)
        let plugin = SpotifyPlugin(accountSession: session,
                                   credentialStore: store,
                                   transport: transport,
                                   linkOpener: opener)
        return PluginWorld(store: store, session: session, transport: transport,
                           opener: opener, bus: bus, plugin: plugin)
    }

    private func makeContext(bus: RecordingObservabilityBus,
                             locale: Locale? = nil) -> PluginExecutionContext {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let client = GeminiClient(configStore: store,
                                  observabilityBus: MockObservabilityBus(),
                                  transport: FakeGeminiTransport())
        return PluginExecutionContext(locale: locale ?? ne,
                                      geminiClient: client,
                                      observabilityBus: bus)
    }

    private func command(query: String?) -> PluginCommand {
        PluginCommand(actionName: "spotify.play",
                      transcript: "",
                      entities: query.map { ["query": $0] } ?? [:],
                      confidence: 0.9)
    }

    /// The exact event-pair pin plus the cross-cutting event contract:
    /// component `plugin_spotify`, empty metadata, nil error code and none
    /// of the forbidden content strings in any event field (NFR-SP-002).
    private func assertPluginEvents(_ world: PluginWorld,
                                    _ expectedPairs: [String],
                                    forbidden: [String] = [],
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        XCTAssertEqual(world.pluginEventPairs, expectedPairs, file: file, line: line)
        for event in world.pluginEvents {
            XCTAssertEqual(event.component, "plugin_spotify", file: file, line: line)
            XCTAssertTrue(event.metadata.isEmpty,
                          "metadata must be empty on every plugin event",
                          file: file, line: line)
            XCTAssertNil(event.errorCode, file: file, line: line)
            let fields = [event.component, event.eventType, event.outcome]
            for text in forbidden where !text.isEmpty {
                XCTAssertFalse(fields.contains { $0.contains(text) },
                               "event field leaked content: \(text)",
                               file: file, line: line)
            }
        }
    }

    // MARK: - Applicability and intent contribution

    func testApplicableToBothLocales() {
        let world = makeWorld()
        XCTAssertTrue(world.plugin.isApplicable(locale: Locale(identifier: "en")))
        XCTAssertTrue(world.plugin.isApplicable(locale: Locale(identifier: "ne-NP")))
    }

    func testIntentContributionDeclaresExactlyOneActionAndAQueryFragment() {
        let world = makeWorld()
        XCTAssertEqual(world.plugin.pluginID, "spotify")
        XCTAssertEqual(world.plugin.displayNameKey, "plugin.spotify.name")
        XCTAssertEqual(world.plugin.intentContribution.actionNames, ["spotify.play"])
        XCTAssertTrue(world.plugin.intentContribution.promptFragment.contains("spotify.play"))
        XCTAssertTrue(world.plugin.intentContribution.promptFragment.contains("query"))
    }

    // MARK: - C-1: the fragment stays at or under the YouTube size model

    func testPromptFragmentStaysAtOrUnderTheYouTubeBudget() {
        let youtubeFragment = YouTubePlugin(
            configStore: YouTubeConfigStore(storage: GeminiInMemoryStorage()))
            .intentContribution.promptFragment
        let fragment = makeWorld().plugin.intentContribution.promptFragment

        // The size model itself, pinned: the YouTube fragment measures 341
        // UTF-16 code units — the "341 characters" the design budget and
        // the acceptance criterion name — which Swift's grapheme-based
        // `count` reports as 326 clusters (Devanagari aksharas fuse their
        // combining marks). Pinning both measures means neither a reword
        // of the model nor a re-encoding of either literal can drift
        // silently.
        XCTAssertEqual(youtubeFragment.utf16.count, 341,
                       "the YouTube fragment's 341-character model length")
        XCTAssertEqual(youtubeFragment.count, 326,
                       "the same literal in Swift extended grapheme clusters")

        // The C-1 guard, asserted in both measures.
        XCTAssertLessThanOrEqual(fragment.count, youtubeFragment.count)
        XCTAssertLessThanOrEqual(fragment.utf16.count, youtubeFragment.utf16.count)

        // The tokens the fragment must keep (C-1).
        XCTAssertTrue(fragment.contains("spotify.play"))
        XCTAssertTrue(fragment.contains("query"))

        // The L2-D15 sentence routing general/bare music requests to the
        // `music` intent, verbatim (whitespace-normalised so a re-wrap
        // cannot hide its removal).
        let normalized = fragment.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        XCTAssertTrue(normalized.contains(
            "General music or bhajan requests without the word Spotify are NOT this capability — use the \"music\" intent for those."),
            "the L2-D15 routing sentence must survive the trim")
    }

    // MARK: - No query

    func testHandleWithNoQueryEntityFailsHonestly() async {
        let world = makeWorld()
        let result = await world.plugin.handle(command(query: nil),
                                               context: makeContext(bus: world.bus))
        XCTAssertEqual(result, .failed(spokenApology: L10n.str("spotify.unavailable", locale: ne)))
        XCTAssertTrue(world.transport.capturedRequests.isEmpty,
                      "no entity means no request of any kind")
        assertPluginEvents(world, ["spotify_plugin_no_query|failure"])
    }

    func testHandleTreatsABlankQueryEntityAsNoQuery() async {
        let world = makeWorld()
        let result = await world.plugin.handle(command(query: "   \n "),
                                               context: makeContext(bus: world.bus))
        XCTAssertEqual(result, .failed(spokenApology: L10n.str("spotify.unavailable", locale: ne)))
        XCTAssertTrue(world.transport.capturedRequests.isEmpty)
        assertPluginEvents(world, ["spotify_plugin_no_query|failure"])
    }

    func testHandleTrimsTheQueryBeforeItReachesTheTool() async {
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              playReply: .body(Data(), 204))
        let result = await world.plugin.handle(command(query: "  bhajan  "),
                                               context: makeContext(bus: world.bus))
        XCTAssertEqual(result, .spoken(L10n.fmt("spotify.playing", locale: ne, Self.trackTitle)))
        // The single search request carries the TRIMMED query (the exact
        // URL the shared tool builds for "bhajan").
        let searches = world.transport.requests(path: "/v1/search")
        XCTAssertEqual(searches.count, 1)
        XCTAssertEqual(searches.first?.url, SpotifyTool.apiSearchURL(query: "bhajan", market: nil))
    }

    // MARK: - Unlinked and revoked

    func testUnlinkedHandleFailsWithTheNotLinkedLineAndMakesNoRequest() async {
        let world = makeWorld(linked: false)
        let result = await world.plugin.handle(command(query: "bhajan"),
                                               context: makeContext(bus: world.bus))
        XCTAssertEqual(result, .failed(spokenApology: L10n.str("spotify.notLinked", locale: ne)))
        XCTAssertTrue(world.transport.capturedRequests.isEmpty,
                      "an unlinked account never reaches the provider")
        assertPluginEvents(world, ["spotify_plugin_not_linked|failure"])
    }

    func testRevokedRefreshTakesTheNotLinkedTreatment() async {
        // A linked record whose stored token already expired: the session
        // runs its single refresh and the provider answers `invalid_grant`
        // — the session wipes and reports `.revoked`; the plugin must take
        // the unlinked treatment, never search with a rejected grant.
        let world = makeWorld(expiry: Date(timeIntervalSinceNow: -60),
                              tokenReply: .body(Self.invalidGrantJSON, 400))
        let result = await world.plugin.handle(command(query: "bhajan"),
                                               context: makeContext(bus: world.bus))
        XCTAssertEqual(result, .failed(spokenApology: L10n.str("spotify.notLinked", locale: ne)))
        XCTAssertFalse(world.session.isLinked)
        XCTAssertNil(world.store.record, "the revocation wipe owns the store")
        XCTAssertTrue(world.transport.requests(path: "/v1/search").isEmpty,
                      "no search may follow a definitively revoked grant")
        assertPluginEvents(world, ["spotify_plugin_not_linked|failure"])
        XCTAssertTrue(world.bus.events.contains {
            $0.component == "spotify" && $0.eventType == "spotify_unlink" && $0.outcome == "revoked"
        }, "the session's own wipe event is the one that reports the revocation")
    }

    func testRefreshTransportFailureFailsUnavailableAndKeepsTheRecord() async {
        let world = makeWorld(expiry: Date(timeIntervalSinceNow: -60),
                              tokenReply: .failure(PluginFixtureBoom()))
        let result = await world.plugin.handle(command(query: "bhajan"),
                                               context: makeContext(bus: world.bus))
        XCTAssertEqual(result, .failed(spokenApology: L10n.str("spotify.unavailable", locale: ne)))
        XCTAssertNotNil(world.store.record, "a transport failure never wipes (matrix row 11)")
        assertPluginEvents(world, ["spotify_plugin_failed|failure"])
    }

    // MARK: - Premium remote play

    func testLinkedPremiumRemotePlaySpeaksTheTrackTitle() async {
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              playReply: .body(Data(), 204))
        let result = await world.plugin.handle(command(query: "bhajan"),
                                               context: makeContext(bus: world.bus))
        XCTAssertEqual(result, .spoken(L10n.fmt("spotify.playing", locale: ne, Self.trackTitle)))
        XCTAssertEqual(world.transport.requests(path: "/v1/search").count, 1)
        XCTAssertEqual(world.transport.requests(path: "/v1/me/player/play").count, 1)
        XCTAssertTrue(world.transport.requests(host: "accounts.spotify.com").isEmpty,
                      "a fresh stored token must not trigger a refresh")
        XCTAssertTrue(world.opener.canOpenChecks.isEmpty,
                      "a successful remote play never probes the deep link")

        // The stored token travels in the Authorization header only —
        // never in a URL component (NFR-SP-002).
        let search = world.transport.requests(path: "/v1/search").first
        XCTAssertEqual(search?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer \(Self.storedAccessToken)")
        XCTAssertFalse(search?.url?.absoluteString.contains(Self.storedAccessToken) ?? true)

        assertPluginEvents(world, ["spotify_plugin_played|success"],
                           forbidden: ["bhajan", Self.trackTitle, Self.storedAccessToken])
    }

    // MARK: - Free tier and unknown product (L2-D14): direct deep link

    func testFreeTierHandsOffToTheDeepLinkWithoutARemoteAttempt() async {
        let world = makeWorld(product: "free",
                              searchReply: .body(Self.trackJSON, 200))
        let result = await world.plugin.handle(command(query: "bhajan"),
                                               context: makeContext(bus: world.bus))
        XCTAssertEqual(result, .spoken(L10n.str("spotify.openApp", locale: ne)))
        XCTAssertEqual(world.transport.requests(path: "/v1/me/player/play").count, 0,
                       "free tier never attempts a remote play")
        let uri = SpotifyTool.trackURI(id: Self.trackID)
        XCTAssertEqual(world.opener.canOpenChecks.count, 1)
        XCTAssertEqual(world.opener.canOpenChecks.first, uri)
        XCTAssertEqual(world.opener.opened.count, 1)
        XCTAssertEqual(world.opener.opened.first, uri)
        assertPluginEvents(world, ["spotify_plugin_play_opened|opened_app"],
                           forbidden: ["bhajan", Self.trackTitle, Self.storedAccessToken])
    }

    func testUnknownProductIsTreatedAsFreeTier() async {
        let world = makeWorld(product: nil,
                              searchReply: .body(Self.trackJSON, 200))
        let result = await world.plugin.handle(command(query: "bhajan"),
                                               context: makeContext(bus: world.bus))
        XCTAssertEqual(result, .spoken(L10n.str("spotify.openApp", locale: ne)))
        XCTAssertEqual(world.transport.requests(path: "/v1/me/player/play").count, 0,
                       ".unknown is never remote-capable (L2-D14)")
        XCTAssertEqual(world.opener.opened.first, SpotifyTool.trackURI(id: Self.trackID))
        assertPluginEvents(world, ["spotify_plugin_play_opened|opened_app"])
    }

    // MARK: - Play failure falls back to the deep link, single-shot

    func testPlayFailureFallsBackToTheDeepLinkInASingleShot() async {
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              playReply: .body(Self.restrictedForbiddenJSON, 403))
        let result = await world.plugin.handle(command(query: "bhajan"),
                                               context: makeContext(bus: world.bus))
        XCTAssertEqual(result, .spoken(L10n.str("spotify.openApp", locale: ne)))
        XCTAssertEqual(world.transport.requests(path: "/v1/me/player/play").count, 1,
                       "exactly one play attempt — no retry")
        XCTAssertTrue(world.transport.requests(host: "accounts.spotify.com").isEmpty,
                      "the plugin is not the ladder: no forced refresh here")
        XCTAssertEqual(world.opener.opened.first, SpotifyTool.trackURI(id: Self.trackID))
        assertPluginEvents(world, ["spotify_plugin_play_opened|opened_app"])
    }

    // MARK: - App absent

    func testAppAbsentDeepLinkFailsWithTheAppMissingLine() async {
        let world = makeWorld(product: "free",
                              searchReply: .body(Self.trackJSON, 200),
                              openerProbes: [false])
        let result = await world.plugin.handle(command(query: "bhajan"),
                                               context: makeContext(bus: world.bus))
        XCTAssertEqual(result, .failed(spokenApology: L10n.str("spotify.appMissing", locale: ne)))
        XCTAssertEqual(world.opener.canOpenChecks.first, SpotifyTool.trackURI(id: Self.trackID))
        XCTAssertTrue(world.opener.opened.isEmpty, "a failed probe opens nothing")
        assertPluginEvents(world, ["spotify_plugin_app_missing|failure"])
    }

    // MARK: - Search failures

    func testSearchNoResultsFailsNotFound() async {
        let world = makeWorld(searchReply: .body(Self.emptyTracksJSON, 200))
        let result = await world.plugin.handle(command(query: "zzz"),
                                               context: makeContext(bus: world.bus))
        XCTAssertEqual(result, .failed(spokenApology: L10n.str("spotify.notFound", locale: ne)))
        XCTAssertTrue(world.opener.canOpenChecks.isEmpty,
                      "nothing was found, so nothing can be opened")
        assertPluginEvents(world, ["spotify_plugin_no_results|failure"])
    }

    func testSearchNetworkFailureFailsUnavailable() async {
        let world = makeWorld(searchReply: .failure(PluginFixtureBoom()))
        let result = await world.plugin.handle(command(query: "bhajan"),
                                               context: makeContext(bus: world.bus))
        XCTAssertEqual(result, .failed(spokenApology: L10n.str("spotify.unavailable", locale: ne)))
        assertPluginEvents(world, ["spotify_plugin_failed|failure"],
                           forbidden: ["bhajan"])
    }

    func testSearchNon200FailsUnavailable() async {
        let world = makeWorld(searchReply: .body(Data(), 500))
        let result = await world.plugin.handle(command(query: "bhajan"),
                                               context: makeContext(bus: world.bus))
        XCTAssertEqual(result, .failed(spokenApology: L10n.str("spotify.unavailable", locale: ne)))
        assertPluginEvents(world, ["spotify_plugin_failed|failure"])
    }

    // MARK: - Presentation

    func testPresentationViewIsNil() {
        let world = makeWorld()
        XCTAssertNil(world.plugin.presentationView(for: .spoken("anything")))
        XCTAssertNil(world.plugin.presentationView(
            for: .failed(spokenApology: L10n.str("spotify.unavailable", locale: ne))))
    }

    // MARK: - Event hygiene sweep

    func testNoEmittedEventEverCarriesQueryTitleOrTokenContent() async {
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              playReply: .body(Data(), 204))
        _ = await world.plugin.handle(command(query: "Namo bhajan"),
                                      context: makeContext(bus: world.bus))
        let forbidden = ["Namo bhajan", Self.trackTitle, Self.storedAccessToken,
                         "Bearer", "api.spotify.com"]
        for event in world.bus.events {
            let fields = [event.component, event.eventType, event.outcome]
                + Array(event.metadata.keys) + Array(event.metadata.values)
            for text in forbidden {
                XCTAssertFalse(fields.contains { $0.contains(text) },
                               "no event may carry \(text) (NFR-SP-002)")
            }
        }
        XCTAssertTrue(world.pluginEvents.allSatisfy { $0.metadata.isEmpty })
    }
}

// MARK: - Doubles (file-private mirrors of the CommandRouterMusicTests harness)

private struct PluginFixtureBoom: Error {}

/// Scripted multi-host `LocalToolTransport`: routes by host + path so one
/// double serves the plugin's Spotify search/play and the session's token
/// endpoint.
private final class PluginStubTransport: LocalToolTransport {
    enum Reply {
        case body(Data, Int)
        case failure(Error)
        case nonHTTP(Data)
    }

    var spotifySearchReply: Reply = .body(Data(), 500)
    var spotifyPlayReply: Reply = .body(Data(), 500)
    var spotifyProfileReply: Reply = .body(Data(#"{"product":"premium","id":"caregiver"}"#.utf8), 200)
    var tokenReply: Reply = .body(Data(), 500)

    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    var capturedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func requests(path: String? = nil, host: String? = nil) -> [URLRequest] {
        capturedRequests.filter { request in
            (path == nil || request.url?.path == path)
                && (host == nil || request.url?.host == host)
        }
    }

    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        _requests.append(request)
        lock.unlock()

        let host = request.url?.host ?? ""
        let path = request.url?.path ?? ""
        let reply: Reply
        switch (host, path) {
        case ("api.spotify.com", "/v1/search"):
            reply = spotifySearchReply
        case ("api.spotify.com", "/v1/me/player/play"):
            reply = spotifyPlayReply
        case ("api.spotify.com", "/v1/me"):
            reply = spotifyProfileReply
        case ("accounts.spotify.com", _):
            reply = tokenReply
        default:
            reply = .body(Data(), 500)
        }

        switch reply {
        case .failure(let error):
            throw error
        case .nonHTTP(let data):
            let response = URLResponse(url: request.url ?? URL(string: "https://api.spotify.com")!,
                                       mimeType: nil,
                                       expectedContentLength: 0,
                                       textEncodingName: nil)
            return (data, response)
        case .body(let data, let statusCode):
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://api.spotify.com")!,
                                           statusCode: statusCode,
                                           httpVersion: nil,
                                           headerFields: nil)!
            return (data, response)
        }
    }
}

private final class PluginLinkOpener: CallLinkOpening {
    /// Probe results in call order; the last value repeats.
    private let probeResults: [Bool]
    private(set) var canOpenChecks: [URL] = []
    private(set) var opened: [URL] = []

    init(probeResults: [Bool] = [true]) {
        self.probeResults = probeResults.isEmpty ? [true] : probeResults
    }

    func canOpenURL(_ url: URL) -> Bool {
        canOpenChecks.append(url)
        return probeResults[min(canOpenChecks.count - 1, probeResults.count - 1)]
    }

    func open(_ url: URL) {
        opened.append(url)
    }
}

/// The session fixture's presentation seam — never exercised here (no
/// `link()` runs in this suite).
@MainActor
private final class PluginUnusedAuthSession: SpotifyAuthSession {
    func authorize(url: URL, callbackURLScheme: String) async throws -> URL {
        throw SpotifyAuthError.userCancelled
    }
}
