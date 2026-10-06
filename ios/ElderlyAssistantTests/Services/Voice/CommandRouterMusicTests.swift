import XCTest
import SwiftUI
@testable import ElderlyAssistant

/// [SPOTIFY] (2026-10-07) T-116 — wiring of the router's music path
/// (C-SP-06 / design-l2 §13, §21, §28). One test per §13 matrix row
/// (names encode the row), plus the §22 cross-cutting pins: never-stub
/// on every branch, exactly one spoken outcome line per turn, the
/// keyless-YouTube leg never pre-opened (L2-R1), `.unknown` ≡ free
/// deep-link-only (L2-D14), no metadata on any event, no query/title/id
/// on any tool-log entry (per-entry walk — F-5(b)), the provider egress
/// allowlist, and the two-keyed-legs concurrency pin.
///
/// ## Supersession block (constraint 5, §22)
///
/// Pinned item | Old expectation (pre-feature) | New expectation
/// `case .music:` dispatch | emits `command_music_stub`; speaks
///   `router.musicStub` | routes to `fireMusicRequest`; speaks exactly
///   one real outcome line; the stub event name is unreachable on every
///   music branch (`testStubIsUnreachableOnEveryMusicBranch`,
///   `testNoMusicBranchSpeaksTheStubForInterpretedMusic`)
/// `router.musicStub` catalog key | reachable, spoken | retained in the
///   catalog, no reachable call site (ADR-SP-11; catalog pinned by
///   `SpotifyLocalizationTests`)
/// Golden music block (15 utterances) | parse to `intent: "music"` |
///   unchanged; verb-bearing entries additionally reach the
///   deterministic stage
/// YouTube-marked request | YouTube stage | YouTube stage (unchanged;
///   `testYoutubeMarkedUtteranceNeverReachesTheMusicPath`)
///
/// All doubles are file-private copies of the `CommandRouterYouTubeTests`
/// harness (that suite's own doubles are private there; the T-114 golden
/// captures in it are untouched by this suite).
final class CommandRouterMusicTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")

    // MARK: - Pinned fixture values

    private static let trackID = "4uLU6hMCjMI75M1A2tKUQC"
    private static let trackTitle = "Namo Namah"
    private static let storedAccessToken = "stored-access-token-1"
    private static let refreshedAccessToken = "refreshed-access-1"

    private static let trackJSON = Data(
        #"{"tracks":{"items":[{"id":"4uLU6hMCjMI75M1A2tKUQC","name":"Namo Namah"}]}}"#.utf8)
    private static let emptyTracksJSON = Data(#"{"tracks":{"items":[]}}"#.utf8)
    private static let youtubeTopJSON = Data(
        #"{"items": [{"id": {"kind": "youtube#video", "videoId": "abc123"},"snippet": {"title": "Bhajan Ganga"}}]}"#.utf8)
    private static let invalidGrantJSON = Data(
        #"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#.utf8)
    private static let restrictedForbiddenJSON = Data(
        #"{"error":{"status":403,"reason":"PLAYER_COMMAND_FAILED","message":"Restricted device"}}"#.utf8)
    private static let tokenBodyJSON = Data(
        #"{"access_token":"refreshed-access-1","token_type":"Bearer","expires_in":3600,"scope":"user-read-private user-modify-playback-state"}"#.utf8)

    /// The ladder's deterministic intake accepts this on every turn below
    /// (marker भजन ∧ verb बजाऊ); the extractor resolves the query to the
    /// content word. The hard commitment is asserted, not assumed, in
    /// `testRow8UnlinkedFallsBackToYouTube`.
    private let musicTranscript = "भजन बजाऊ"
    private let extractedQuery = "भजन"

    // MARK: - World builder

    private enum YouTubeMode {
        case none
        case keyless
        case keyed
    }

    /// One router over one fake world with every music seam scriptable.
    @MainActor
    private final class MusicWorld {
        let coordinator: MusicMockCoordinator
        let bus: MockObservabilityBus
        let speaker: MusicMockSpeaker
        let transport: MusicStubTransport
        let logStore: LocalToolLogStore
        let session: SpotifyAccountSession?
        let store: SpotifyCredentialStore?
        let spotifyOpener: MusicLinkOpener?
        let youtubeOpener: MusicLinkOpener?
        let router: CommandRouter

        init(coordinator: MusicMockCoordinator, bus: MockObservabilityBus,
             speaker: MusicMockSpeaker, transport: MusicStubTransport,
             logStore: LocalToolLogStore, session: SpotifyAccountSession?,
             store: SpotifyCredentialStore?, spotifyOpener: MusicLinkOpener?,
             youtubeOpener: MusicLinkOpener?, router: CommandRouter) {
            self.coordinator = coordinator
            self.bus = bus
            self.speaker = speaker
            self.transport = transport
            self.logStore = logStore
            self.session = session
            self.store = store
            self.spotifyOpener = spotifyOpener
            self.youtubeOpener = youtubeOpener
            self.router = router
        }

        var spotifyEntries: [LocalToolLogEntry] { logStore.entries().filter { $0.kind == .spotify } }
        var youtubeEntries: [LocalToolLogEntry] { logStore.entries().filter { $0.kind == .youtube } }
        var spotifyEventPairs: [String] {
            bus.emittedEvents.filter { $0.component == "spotify" }
                .map { "\($0.eventType)|\($0.outcome)" }
        }
        func hasSpotifyEvent(_ eventType: String, _ outcome: String) -> Bool {
            spotifyEventPairs.contains("\(eventType)|\(outcome)")
        }
    }

    @MainActor
    private func makeWorld(searchReply: MusicStubTransport.Reply? = nil,
                           playReply: MusicStubTransport.Reply? = nil,
                           tokenReply: MusicStubTransport.Reply? = nil,
                           youtubeReply: MusicStubTransport.Reply? = nil,
                           product: String? = "premium",
                           expiry: Date? = nil,
                           sessionPresent: Bool = true,
                           recordPresent: Bool = true,
                           spotifyTransportPresent: Bool = true,
                           youtubeMode: YouTubeMode = .none,
                           spotifyProbes: [Bool]? = nil,
                           interpreter: CommandInterpreter = NullCommandInterpreter())
        -> MusicWorld {
        let coordinator = MusicMockCoordinator()
        let bus = MockObservabilityBus()
        let speaker = MusicMockSpeaker()
        let transport = MusicStubTransport()
        if let searchReply { transport.spotifySearchReply = searchReply }
        if let playReply { transport.spotifyPlayReply = playReply }
        if let tokenReply { transport.tokenReply = tokenReply }
        if let youtubeReply { transport.youtubeReply = youtubeReply }
        let logStore = LocalToolLogStore(storage: GeminiInMemoryStorage())

        var session: SpotifyAccountSession?
        var store: SpotifyCredentialStore?
        if sessionPresent {
            let built = makeSession(product: product, expiry: expiry, record: recordPresent,
                                    transport: transport, bus: bus)
            session = built.session
            store = built.store
        }

        let spotifyOpener = spotifyProbes.map { MusicLinkOpener(probeResults: $0) }
        var youtubeConfigStore: YouTubeConfigStore?
        var youtubeTransport: LocalToolTransport?
        var youtubeOpener: MusicLinkOpener?
        switch youtubeMode {
        case .none:
            break
        case .keyless:
            youtubeOpener = MusicLinkOpener()
        case .keyed:
            youtubeConfigStore = makeConfigStore(apiKey: "k123")
            youtubeTransport = transport
            youtubeOpener = MusicLinkOpener()
        }

        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: speaker,
                                   interpreter: interpreter,
                                   localToolLogStore: logStore,
                                   youtubeConfigStore: youtubeConfigStore,
                                   youtubeTransport: youtubeTransport,
                                   youtubeLinkOpener: youtubeOpener,
                                   spotifyAccountSession: session,
                                   spotifyTransport: spotifyTransportPresent ? transport : nil,
                                   spotifyLinkOpener: spotifyOpener)
        return MusicWorld(coordinator: coordinator, bus: bus, speaker: speaker,
                          transport: transport, logStore: logStore,
                          session: session, store: store,
                          spotifyOpener: spotifyOpener, youtubeOpener: youtubeOpener,
                          router: router)
    }

    @MainActor
    private func makeSession(product: String?,
                             expiry: Date?,
                             record: Bool,
                             transport: LocalToolTransport,
                             bus: ObservabilityBus)
        -> (session: SpotifyAccountSession, store: SpotifyCredentialStore) {
        let storage = SpotifyInMemoryStorage()
        let store = SpotifyCredentialStore(storage: storage)
        if record {
            store.save(SpotifySessionRecord(accessToken: Self.storedAccessToken,
                                            refreshToken: "stored-refresh-token-1",
                                            expiry: expiry ?? Date(timeIntervalSinceNow: 3600),
                                            product: product,
                                            scope: "user-read-private user-modify-playback-state",
                                            linkedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        }
        let session = SpotifyAccountSession(store: store,
                                            flow: UnusedSpotifyAuthSession(),
                                            transport: transport,
                                            clientID: "client-test-1",
                                            refreshAttemptLimit: 1,
                                            capabilityStalenessSeconds: 3600,
                                            linkFlowTimeoutSeconds: 300,
                                            expirySkewSeconds: 60,
                                            observabilityBus: bus)
        return (session, store)
    }

    private func makeConfigStore(apiKey: String? = nil) -> YouTubeConfigStore {
        let store = YouTubeConfigStore(storage: GeminiInMemoryStorage())
        if let apiKey { store.saveAPIKey(apiKey) }
        return store
    }

    private func waitForDelivery(_ seconds: TimeInterval = 0.6) {
        let exp = expectation(description: "music async delivery")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)
    }

    /// The pre-acks the turn legitimately speaks (the music entry's own
    /// ack, plus the interpret stage's and the verbatim YouTube leg's
    /// where those stages run): the matrix guarantee is exactly one
    /// SPOKEN OUTCOME line — this filters the acks out to assert it.
    private func outcomeLines(from spoken: [String]) -> [String] {
        let acks = (1...3).map { L10n.str("voiceAck.moment\($0)", locale: ne) }
        return spoken.filter { !acks.contains($0) }
    }

    private func assertNoStubEmission(_ world: MusicWorld, _ label: String) {
        XCTAssertFalse(world.bus.emittedEvents.contains { $0.eventType == "command_music_stub" },
                       "\(label): the stub event must have no reachable emission")
        let stubLine = L10n.str("router.musicStub", locale: ne)
        XCTAssertFalse(world.coordinator.assistantSpoken.contains(stubLine),
                       "\(label): the stub line must never be spoken")
        XCTAssertFalse(world.coordinator.genericReplies.contains(stubLine),
                       "\(label): the stub line must never be carded")
    }

    // MARK: - Matrix row 1: Premium-capable, usable, remote play ok

    @MainActor
    func testRow1PremiumRemotePlaySucceeds() {
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              playReply: .body(Data(), 204),
                              youtubeMode: .keyed)
        // The intake is the ladder's deterministic stage (FR-SP-015):
        // zero interpreter, and the extractor resolves the query.
        XCTAssertEqual(KeywordIntentRule.musicQuery(from: musicTranscript), extractedQuery)

        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        let playing = L10n.fmt("spotify.playing", locale: ne, Self.trackTitle)
        XCTAssertEqual(world.coordinator.assistantSpoken,
                       [L10n.str("voiceAck.moment1", locale: ne), playing])
        XCTAssertFalse(world.coordinator.genericReplies.contains(playing),
                       "the track confirmation is SPOKEN ONLY — never carded (NFR-SP-002)")

        // Row 1's pair, in order; and the keyed YouTube leg really ran
        // (search both legs, §13 row 1) without disturbing the outcome.
        XCTAssertEqual(world.spotifyEventPairs, ["spotify_search|usable", "spotify_play|ok"])
        let hosts = Set(world.transport.capturedRequests.compactMap { $0.url?.host })
        XCTAssertEqual(hosts, ["api.spotify.com", "www.googleapis.com"])
        XCTAssertEqual(world.transport.requests(host: "api.spotify.com", path: "/v1/search").count, 1)
        XCTAssertEqual(world.transport.requests(host: "www.googleapis.com").count, 1)
        XCTAssertEqual(world.transport.requests(host: "api.spotify.com", path: "/v1/me/player/play").count, 1)

        XCTAssertEqual(world.spotifyEntries.count, 1)
        let entry = world.spotifyEntries.first
        XCTAssertEqual(entry?.outcome, "ok")
        XCTAssertEqual(entry?.query, "")
        XCTAssertEqual(entry?.response, "")
        XCTAssertEqual(entry?.statusCode, 204)
        assertNoStubEmission(world, "row 1")
    }

    // MARK: - Matrix row 2: Premium-capable, play fails → deep link

    @MainActor
    func testRow2PlayFailureFallsToTheDeepLinkWithTheFailureStatus() {
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              playReply: .body(Self.restrictedForbiddenJSON, 403),
                              spotifyProbes: [true])
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertEqual(world.coordinator.assistantSpoken.last,
                       L10n.str("spotify.openApp", locale: ne))
        XCTAssertFalse(world.coordinator.genericReplies.contains(L10n.str("spotify.openApp", locale: ne)),
                       "the hand-off line is SPOKEN ONLY — never carded (the youtube.openingSearch precedent, NFR-SP-002)")
        XCTAssertEqual(world.spotifyOpener?.opened.count, 1)
        XCTAssertEqual(world.spotifyOpener?.opened.first,
                       SpotifyTool.trackURI(id: Self.trackID))
        XCTAssertEqual(world.spotifyEventPairs,
                       ["spotify_search|usable", "spotify_play|restricted", "spotify_deeplink|opened"])

        // Row 2's entry: fail, EMPTY response (the app took over), and the
        // play failure's status.
        XCTAssertEqual(world.spotifyEntries.count, 1)
        XCTAssertEqual(world.spotifyEntries.first?.outcome, "fail")
        XCTAssertEqual(world.spotifyEntries.first?.response, "")
        XCTAssertEqual(world.spotifyEntries.first?.query, "")
        XCTAssertEqual(world.spotifyEntries.first?.statusCode, 403)
        assertNoStubEmission(world, "row 2")
    }

    @MainActor
    func testRow2PlayNetworkFailureOpensTheDeepLinkWithNilStatus() {
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              playReply: .failure(MusicFixtureBoom()),
                              spotifyProbes: [true])
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertEqual(world.spotifyEventPairs,
                       ["spotify_search|usable", "spotify_play|network_failed", "spotify_deeplink|opened"])
        XCTAssertEqual(world.spotifyOpener?.opened.first,
                       SpotifyTool.trackURI(id: Self.trackID))
        XCTAssertEqual(world.spotifyEntries.first?.outcome, "fail")
        XCTAssertNil(world.spotifyEntries.first?.statusCode)
    }

    // MARK: - Matrix row 3: free tier, usable → deep link, no remote attempt

    @MainActor
    func testRow3FreeTierOpensTheTrackDeepLinkWithoutARemoteAttempt() {
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              product: "free",
                              spotifyProbes: [true, true])
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertEqual(world.coordinator.assistantSpoken.last, L10n.str("spotify.openApp", locale: ne))
        XCTAssertEqual(world.spotifyOpener?.opened.count, 1)
        XCTAssertEqual(world.spotifyOpener?.opened.first,
                       SpotifyTool.trackURI(id: Self.trackID))
        XCTAssertEqual(world.spotifyOpener?.canOpenChecks.count, 2,
                       "probed at selection AND at the open attempt")
        XCTAssertEqual(world.spotifyEventPairs,
                       ["spotify_search|usable", "spotify_deeplink|opened"])
        XCTAssertTrue(world.transport.requests(host: "api.spotify.com", path: "/v1/me/player/play").isEmpty,
                      "a free-tier turn NEVER attempts remote play")

        XCTAssertEqual(world.spotifyEntries.count, 1)
        XCTAssertEqual(world.spotifyEntries.first?.outcome, "ok")
        XCTAssertEqual(world.spotifyEntries.first?.response, "")
        XCTAssertNil(world.spotifyEntries.first?.statusCode)
        assertNoStubEmission(world, "row 3")
    }

    // MARK: - Matrix row 4: not capable → YouTube if serveable, else honest line

    @MainActor
    func testRow4AppAbsentWithYouTubeServeableFallsBackToYouTube() {
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              product: "free",
                              youtubeMode: .keyless,
                              spotifyProbes: [false])
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertEqual(world.spotifyOpener?.canOpenChecks.count, 1,
                       "the selection probe only — a not-capable selection never attempts the link")
        XCTAssertEqual(world.youtubeOpener?.opened, [YouTubeTool.appSearchURL(query: extractedQuery)])
        XCTAssertEqual(world.coordinator.assistantSpoken.last,
                       L10n.fmt("youtube.openingSearch", locale: ne, extractedQuery))
        XCTAssertTrue(world.hasSpotifyEvent("spotify_fallback", "youtube"))
        XCTAssertFalse(world.hasSpotifyEvent("spotify_deeplink", "not_opened"),
                       "no deeplink was attempted, so no deeplink event exists")

        // The turn's own fail entry (a Spotify attempt happened) with the
        // successful search's 200; the YouTube leg writes its own entry.
        XCTAssertEqual(world.spotifyEntries.count, 1)
        XCTAssertEqual(world.spotifyEntries.first?.outcome, "fail")
        XCTAssertEqual(world.spotifyEntries.first?.response, "")
        XCTAssertEqual(world.spotifyEntries.first?.statusCode, 200)
        XCTAssertEqual(world.youtubeEntries.count, 1)
        assertNoStubEmission(world, "row 4")
    }

    @MainActor
    func testRow4AppAbsentWithoutYouTubeSpeaksAppMissing() {
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              product: "free",
                              spotifyProbes: [false])
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        let appMissing = L10n.str("spotify.appMissing", locale: ne)
        XCTAssertEqual(world.coordinator.assistantSpoken.last, appMissing)
        XCTAssertTrue(world.coordinator.genericReplies.contains(appMissing))
        XCTAssertEqual(world.spotifyEventPairs,
                       ["spotify_search|usable", "spotify_fallback|app_missing"])
        XCTAssertEqual(world.spotifyEntries.count, 1)
        XCTAssertEqual(world.spotifyEntries.first?.outcome, "fail")
        XCTAssertEqual(world.spotifyEntries.first?.response, appMissing)
    }

    // MARK: - Matrix row 5: deep-link open attempted and fails → terminal

    @MainActor
    func testRow5DeepLinkNotOpenedSpeaksAppMissingWithNoChaining() {
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              product: "free",
                              youtubeMode: .keyless,
                              spotifyProbes: [true, false])
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        let appMissing = L10n.str("spotify.appMissing", locale: ne)
        XCTAssertEqual(world.coordinator.assistantSpoken.last, appMissing)
        XCTAssertTrue(world.coordinator.genericReplies.contains(appMissing))
        XCTAssertEqual(world.spotifyEventPairs,
                       ["spotify_search|usable", "spotify_deeplink|not_opened"])
        XCTAssertTrue(world.youtubeOpener?.opened.isEmpty ?? false,
                      "row 5 is terminal — no chaining into the YouTube fallback")
        XCTAssertTrue(world.youtubeOpener?.canOpenChecks.isEmpty ?? false)
        XCTAssertNil(world.spotifyOpener?.opened.first,
                     "a failed probe opens nothing")

        XCTAssertEqual(world.spotifyEntries.count, 1)
        XCTAssertEqual(world.spotifyEntries.first?.outcome, "fail")
        XCTAssertEqual(world.spotifyEntries.first?.response, appMissing)
        assertNoStubEmission(world, "row 5")
    }

    // MARK: - Matrix row 6: search empty → YouTube / not found

    @MainActor
    func testRow6EmptySearchWithYouTubeServeableFallsBackToYouTube() {
        let world = makeWorld(searchReply: .body(Self.emptyTracksJSON, 200),
                              youtubeMode: .keyless)
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertEqual(world.youtubeOpener?.opened, [YouTubeTool.appSearchURL(query: extractedQuery)])
        XCTAssertTrue(world.hasSpotifyEvent("spotify_search", "empty"))
        XCTAssertTrue(world.hasSpotifyEvent("spotify_fallback", "youtube"))
        XCTAssertEqual(world.spotifyEntries.first?.outcome, "fail")
        XCTAssertEqual(world.spotifyEntries.first?.response, "")
        XCTAssertEqual(world.spotifyEntries.first?.statusCode, 200)
    }

    @MainActor
    func testRow6EmptySearchWithoutYouTubeSpeaksNotFound() {
        let world = makeWorld(searchReply: .body(Self.emptyTracksJSON, 200))
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        let notFound = L10n.str("spotify.notFound", locale: ne)
        XCTAssertEqual(world.coordinator.assistantSpoken.last, notFound)
        XCTAssertTrue(world.coordinator.genericReplies.contains(notFound))
        XCTAssertEqual(world.spotifyEventPairs,
                       ["spotify_search|empty", "spotify_fallback|not_found"])
        XCTAssertEqual(world.spotifyEntries.first?.outcome, "fail")
        XCTAssertEqual(world.spotifyEntries.first?.response, notFound)
        XCTAssertEqual(world.spotifyEntries.first?.statusCode, 200)
    }

    // MARK: - Matrix row 7: search failure → YouTube / unavailable

    @MainActor
    func testRow7SearchFailureWithYouTubeServeableFallsBackToYouTube() {
        let world = makeWorld(searchReply: .body(Data(), 500),
                              youtubeMode: .keyless)
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertEqual(world.youtubeOpener?.opened, [YouTubeTool.appSearchURL(query: extractedQuery)])
        XCTAssertTrue(world.hasSpotifyEvent("spotify_search", "failed"))
        XCTAssertTrue(world.hasSpotifyEvent("spotify_fallback", "youtube"))
        XCTAssertEqual(world.spotifyEntries.first?.outcome, "fail")
        XCTAssertEqual(world.spotifyEntries.first?.statusCode, 500)
        assertNoStubEmission(world, "row 7")
    }

    @MainActor
    func testRow7SearchFailureWithoutYouTubeSpeaksUnavailable() {
        let world = makeWorld(searchReply: .body(Data(), 500))
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        let unavailable = L10n.str("spotify.unavailable", locale: ne)
        XCTAssertEqual(world.coordinator.assistantSpoken.last, unavailable)
        XCTAssertTrue(world.coordinator.genericReplies.contains(unavailable))
        XCTAssertEqual(world.spotifyEventPairs,
                       ["spotify_search|failed", "spotify_fallback|unavailable"])
        XCTAssertEqual(world.spotifyEntries.first?.outcome, "fail")
        XCTAssertEqual(world.spotifyEntries.first?.response, unavailable)
        XCTAssertEqual(world.spotifyEntries.first?.statusCode, 500)
    }

    @MainActor
    func testLinkedSessionWithoutTransportTakesTheRow7Shape() {
        // §28's "linked+transport missing → the row-7 branch" (see the
        // task notes for the §10B askability tension).
        let world = makeWorld(spotifyTransportPresent: false, youtubeMode: .keyless)
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertEqual(world.youtubeOpener?.opened, [YouTubeTool.appSearchURL(query: extractedQuery)])
        XCTAssertTrue(world.transport.requests(host: "api.spotify.com").isEmpty,
                      "without the transport seam no Spotify request can exist")
        XCTAssertFalse(world.spotifyEventPairs.contains("spotify_search|usable"))
        XCTAssertTrue(world.hasSpotifyEvent("spotify_fallback", "youtube"))
        XCTAssertEqual(world.spotifyEntries.count, 1)
        XCTAssertEqual(world.spotifyEntries.first?.outcome, "fail")
        XCTAssertNil(world.spotifyEntries.first?.statusCode)
        assertNoStubEmission(world, "linked/no-transport")
    }

    // MARK: - Matrix row 8: unlinked → YouTube / search hand-off / honest line

    @MainActor
    func testRow8UnlinkedFallsBackToYouTube() {
        let world = makeWorld(sessionPresent: false, youtubeMode: .keyless)
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertEqual(world.youtubeOpener?.opened, [YouTubeTool.appSearchURL(query: extractedQuery)])
        XCTAssertEqual(world.coordinator.assistantSpoken.last,
                       L10n.fmt("youtube.openingSearch", locale: ne, extractedQuery))
        XCTAssertEqual(world.spotifyEventPairs, ["spotify_fallback|youtube"])
        XCTAssertTrue(world.spotifyEntries.isEmpty,
                      "no Spotify attempt happened — only the YouTube leg's own entry exists")
        XCTAssertEqual(world.youtubeEntries.count, 1)
        XCTAssertEqual(world.youtubeEntries.first?.query, "",
                       "[T-114][M-1] the fallback logs query-free")
        assertNoStubEmission(world, "row 8")
    }

    @MainActor
    func testRow8UnlinkedWithoutYouTubeHandsOffTheSearch() {
        let world = makeWorld(sessionPresent: false, spotifyProbes: [true])
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertEqual(world.spotifyOpener?.opened.first,
                       SpotifyTool.searchURI(query: extractedQuery))
        XCTAssertEqual(world.coordinator.assistantSpoken.last,
                       L10n.str("spotify.openSearch", locale: ne))
        XCTAssertFalse(world.coordinator.genericReplies.contains(L10n.str("spotify.openSearch", locale: ne)),
                       "the hand-off confirmation is spoken-only (the youtube.openingSearch precedent)")
        XCTAssertEqual(world.spotifyEventPairs, ["spotify_deeplink|opened"])
        XCTAssertEqual(world.spotifyEntries.count, 1)
        XCTAssertEqual(world.spotifyEntries.first?.outcome, "ok")
        XCTAssertEqual(world.spotifyEntries.first?.response, "")
        XCTAssertNil(world.spotifyEntries.first?.statusCode)
        assertNoStubEmission(world, "row 8 hand-off")
    }

    @MainActor
    func testRow8SearchHandoffNotOpenedSpeaksNotLinked() {
        let world = makeWorld(sessionPresent: false, spotifyProbes: [false])
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        let notLinked = L10n.str("spotify.notLinked", locale: ne)
        XCTAssertEqual(world.coordinator.assistantSpoken.last, notLinked)
        XCTAssertTrue(world.coordinator.genericReplies.contains(notLinked))
        XCTAssertEqual(world.spotifyEventPairs, ["spotify_deeplink|not_opened"])
        XCTAssertEqual(world.spotifyEntries.count, 1)
        XCTAssertEqual(world.spotifyEntries.first?.outcome, "fail")
        XCTAssertEqual(world.spotifyEntries.first?.response, notLinked)
    }

    // MARK: - Matrix row 9: unlinked + dormant seams → honest not-linked

    @MainActor
    func testNeitherProviderAskableSpeaksNotLinked() {
        let world = makeWorld(sessionPresent: false)
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        let notLinked = L10n.str("spotify.notLinked", locale: ne)
        XCTAssertEqual(world.coordinator.assistantSpoken,
                       [L10n.str("voiceAck.moment1", locale: ne), notLinked])
        XCTAssertTrue(world.coordinator.genericReplies.contains(notLinked))
        XCTAssertEqual(world.spotifyEventPairs, ["spotify_fallback|not_linked"])
        XCTAssertTrue(world.logStore.entries().isEmpty,
                      "row 9's tool-log column is none — no attempt happened")
        assertNoStubEmission(world, "row 9")
    }

    // MARK: - Matrix row 10: invalid_grant wipe → unlinked treatment

    @MainActor
    func testRow10InvalidGrantOnRefreshWipesAndTakesTheUnlinkedTreatment() {
        let world = makeWorld(tokenReply: .body(Self.invalidGrantJSON, 400),
                              expiry: Date(timeIntervalSinceNow: -60),
                              youtubeMode: .keyless)
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertFalse(world.session?.isLinked ?? true,
                       "the provider's rejection wiped the record")
        XCTAssertNil(world.store?.record)
        XCTAssertTrue(world.hasSpotifyEvent("spotify_unlink", "revoked"))
        XCTAssertTrue(world.hasSpotifyEvent("spotify_fallback", "youtube"))
        XCTAssertFalse(world.spotifyEventPairs.contains("spotify_search|usable"),
                       "no search runs after the wipe")
        XCTAssertTrue(world.spotifyEntries.isEmpty, "row 10's tool-log column is none")
        XCTAssertEqual(world.youtubeOpener?.opened, [YouTubeTool.appSearchURL(query: extractedQuery)])
        XCTAssertTrue(world.transport.requests(host: "api.spotify.com").isEmpty)
        assertNoStubEmission(world, "row 10")
    }

    @MainActor
    func testSecondUnauthorizedWipesAndTakesTheUnlinkedTreatment() {
        // §10B: 401 → one forced re-acquisition → retry once → a second
        // 401 wipes through the session (`markRevoked` — §26 names this
        // "the router's second-401 path") and the turn is unlinked.
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              playReply: .body(Data(), 401),
                              youtubeMode: .keyless)
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertFalse(world.session?.isLinked ?? true)
        XCTAssertNil(world.store?.record)
        XCTAssertEqual(world.transport.requests(host: "api.spotify.com", path: "/v1/me/player/play").count, 2,
                       "exactly one retry after the first 401")
        XCTAssertEqual(world.bus.emittedEvents.filter {
            $0.component == "spotify" && $0.eventType == "spotify_play" && $0.outcome == "unauthorized"
        }.count, 2)
        XCTAssertTrue(world.hasSpotifyEvent("spotify_unlink", "revoked"))
        XCTAssertTrue(world.hasSpotifyEvent("spotify_fallback", "youtube"))
        XCTAssertTrue(world.spotifyEntries.isEmpty,
                      "the unlinked treatment brings no .spotify entry (row 10's shape)")
        XCTAssertEqual(world.youtubeOpener?.opened, [YouTubeTool.appSearchURL(query: extractedQuery)])
        assertNoStubEmission(world, "second 401")
    }

    // MARK: - Matrix row 11: refresh failure → row 7 shape, record kept

    @MainActor
    func testRow11RefreshTransportFailureKeepsTheRecordAndTakesTheRow7Shape() {
        let world = makeWorld(tokenReply: .failure(MusicFixtureBoom()),
                              expiry: Date(timeIntervalSinceNow: -60),
                              youtubeMode: .keyless)
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertNotNil(world.store?.record, "a transport failure never wipes (row 11)")
        XCTAssertTrue(world.session?.isLinked ?? false)
        XCTAssertTrue(world.transport.requests(host: "api.spotify.com").isEmpty,
                      "no search runs when the token could not be obtained")
        XCTAssertTrue(world.hasSpotifyEvent("spotify_fallback", "youtube"))
        XCTAssertFalse(world.spotifyEventPairs.contains(where: { $0.hasPrefix("spotify_search") }),
                       "spotify_search fires only when a search actually ran")
        XCTAssertEqual(world.spotifyEntries.count, 1)
        XCTAssertEqual(world.spotifyEntries.first?.outcome, "fail")
        XCTAssertNil(world.spotifyEntries.first?.statusCode)
        XCTAssertEqual(world.youtubeOpener?.opened, [YouTubeTool.appSearchURL(query: extractedQuery)])
        assertNoStubEmission(world, "row 11")
    }

    // MARK: - Matrix row 12: link-time failure residue → unlinked treatment

    @MainActor
    func testRow12LinkFailedSessionBehavesAsUnlinked() {
        // The residual state of a link-time verification/scope failure is
        // "stored nothing" (T-110's state machine A pins the failure and
        // its `spotify_link` failed event); routing-wise it is the
        // unlinked treatment.
        let world = makeWorld(product: nil,
                              sessionPresent: true, recordPresent: false,
                              youtubeMode: .keyless)
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertFalse(world.session?.isLinked ?? true)
        XCTAssertEqual(world.youtubeOpener?.opened, [YouTubeTool.appSearchURL(query: extractedQuery)])
        XCTAssertTrue(world.hasSpotifyEvent("spotify_fallback", "youtube"))
        XCTAssertTrue(world.spotifyEntries.isEmpty)
        assertNoStubEmission(world, "row 12")
    }

    // MARK: - §22 pins

    @MainActor
    func testBareMusicRequestNeverSpeaksTheStub() {
        // The ladder's deterministic intake, fully dormant: the honest
        // unlinked line, never the pre-feature stub, and no stub event.
        let world = makeWorld(sessionPresent: false)
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        assertNoStubEmission(world, "bare music request")
        XCTAssertEqual(world.coordinator.assistantSpoken.last,
                       L10n.str("spotify.notLinked", locale: ne))
    }

    @MainActor
    func testNoMusicBranchSpeaksTheStubForInterpretedMusic() {
        // The §22-named pin: a scripted interpreter resolves a music
        // action with a query. The stub dies at the dispatch arm — the
        // model's query travels into the real path instead.
        let scripted = StubCommandInterpreter(result: InterpretedCommand(
            action: .music,
            entryId: nil,
            contact: nil,
            time: nil,
            medication: nil,
            message: "गाउने मान्छे",
            callType: nil,
            requestedApp: nil,
            topic: nil,
            confidence: 0.95,
            reply: "ठीक छ"))
        // A transcript the deterministic ladder does not claim (no music
        // marker; the bare listen verb alone never fires the rule) —
        // proven fall-through material in CommandRouterSafetyNetTests.
        let world = makeWorld(youtubeMode: .keyless, interpreter: scripted)
        world.router.route(transcript: "केही राम्रो कुरा बताउनुस्")
        waitForDelivery()

        XCTAssertEqual(scripted.callCount, 1, "the interpreter resolved this turn")
        assertNoStubEmission(world, "interpreted music")
        XCTAssertEqual(world.youtubeOpener?.opened,
                       [YouTubeTool.appSearchURL(query: "गाउने मान्छे")],
                       "the model's query — not the transcript — reached the music path")
        XCTAssertEqual(world.coordinator.assistantSpoken.last,
                       L10n.fmt("youtube.openingSearch", locale: ne, "गाउने मान्छे"))
    }

    @MainActor
    func testYoutubeMarkedUtteranceNeverReachesTheMusicPath() {
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              playReply: .body(Data(), 204),
                              youtubeMode: .keyless,
                              spotifyProbes: [true])
        world.router.route(transcript: "युट्युबमा गीत चलाऊ")
        waitForDelivery()

        XCTAssertEqual(world.youtubeOpener?.opened,
                       [YouTubeTool.appSearchURL(query: "गीत")],
                       "the YouTube stage claims YouTube-marked utterances, byte-identically")
        XCTAssertTrue(world.bus.emittedEvents.allSatisfy { $0.component != "spotify" },
                      "not one Spotify event fires on a YouTube-marked turn")
        XCTAssertTrue(world.spotifyEntries.isEmpty)
        XCTAssertTrue(world.spotifyOpener?.canOpenChecks.isEmpty ?? false)
        XCTAssertTrue(world.transport.requests(host: "api.spotify.com").isEmpty)
    }

    @MainActor
    func testBothKeyedProvidersAreSearchedConcurrently() {
        let gate = MusicArrivalGate()
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              playReply: .body(Data(), 204),
                              youtubeMode: .keyed)
        world.transport.arrivalGate = gate

        world.router.route(transcript: musicTranscript)
        waitForDelivery(1.5)

        // Read the actor without blocking the main thread.
        let exp = expectation(description: "gate read")
        var overlap = false
        Task {
            overlap = await gate.overlapObserved
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertTrue(overlap,
                      "the two keyed legs must be in flight together (sequential legs park the gate to timeout)")
        XCTAssertEqual(world.transport.requests(host: "api.spotify.com", path: "/v1/search").count, 1)
        XCTAssertEqual(world.transport.requests(host: "www.googleapis.com").count, 1)
        XCTAssertEqual(world.coordinator.assistantSpoken.last,
                       L10n.fmt("spotify.playing", locale: ne, Self.trackTitle))
    }

    @MainActor
    func testKeylessYouTubeIsNotOpenedWhenSpotifyWins() {
        // L2-R1: the keyless YouTube leg is askable but is NOT
        // pre-opened — its "search" is its outcome, and Spotify won.
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              playReply: .body(Data(), 204),
                              youtubeMode: .keyless)
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertEqual(world.coordinator.assistantSpoken.last,
                       L10n.fmt("spotify.playing", locale: ne, Self.trackTitle))
        XCTAssertTrue(world.youtubeOpener?.opened.isEmpty ?? false,
                      "the keyless leg must not be pre-opened when Spotify wins")
        XCTAssertTrue(world.youtubeOpener?.canOpenChecks.isEmpty ?? false)
        XCTAssertTrue(world.transport.requests(host: "www.googleapis.com").isEmpty,
                      "no keyed YouTube fetch exists on the keyless path")
    }

    @MainActor
    func testUnknownProductUsesTheDeepLink() {
        // L2-D14: `.unknown` ≡ free — deep-link only, never a remote
        // play attempt.
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              product: nil,
                              spotifyProbes: [true, true])
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertEqual(world.spotifyOpener?.opened.first,
                       SpotifyTool.trackURI(id: Self.trackID))
        XCTAssertTrue(world.transport.requests(host: "api.spotify.com", path: "/v1/me/player/play").isEmpty)
        XCTAssertFalse(world.spotifyEventPairs.contains("spotify_play|ok"))
        XCTAssertEqual(world.coordinator.assistantSpoken.last, L10n.str("spotify.openApp", locale: ne))
    }

    @MainActor
    func testExpiredRecordRefreshesOnceAndSearchesWithTheNewToken() {
        // State machine B integration (§10): the router obtains the token
        // through `validAccessToken()` — an expired record refreshes
        // exactly once and the search carries the refreshed credential.
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              playReply: .body(Data(), 204),
                              tokenReply: .body(Self.tokenBodyJSON, 200),
                              expiry: Date(timeIntervalSinceNow: -60))
        world.router.route(transcript: musicTranscript)
        waitForDelivery()

        XCTAssertEqual(world.transport.requests(host: "accounts.spotify.com").count, 1)
        let search = world.transport.requests(host: "api.spotify.com", path: "/v1/search").first
        XCTAssertEqual(search?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer \(Self.refreshedAccessToken)")
        XCTAssertEqual(world.coordinator.assistantSpoken.last,
                       L10n.fmt("spotify.playing", locale: ne, Self.trackTitle))
    }

    @MainActor
    func testMusicTurnEndsInExactlyOneSpokenOutcomeLine() {
        // Data-driven over the row shapes: every music turn speaks
        // EXACTLY ONE outcome line (the acks the design mandates are
        // filtered; everything else would be a second outcome).
        struct Case {
            let label: String
            let expected: String
            let build: () -> MusicWorld
        }
        let cases: [Case] = [
            Case(label: "row 1 remote ok",
                 expected: L10n.fmt("spotify.playing", locale: ne, Self.trackTitle),
                 build: { self.makeWorld(searchReply: .body(Self.trackJSON, 200),
                                         playReply: .body(Data(), 204)) }),
            Case(label: "row 3 deep link",
                 expected: L10n.str("spotify.openApp", locale: ne),
                 build: { self.makeWorld(searchReply: .body(Self.trackJSON, 200),
                                         product: "free", spotifyProbes: [true, true]) }),
            Case(label: "row 6 not found",
                 expected: L10n.str("spotify.notFound", locale: ne),
                 build: { self.makeWorld(searchReply: .body(Self.emptyTracksJSON, 200)) }),
            Case(label: "row 7 unavailable",
                 expected: L10n.str("spotify.unavailable", locale: ne),
                 build: { self.makeWorld(searchReply: .body(Data(), 500)) }),
            Case(label: "row 8 youtube fallback",
                 expected: L10n.fmt("youtube.openingSearch", locale: ne, self.extractedQuery),
                 build: { self.makeWorld(sessionPresent: false, youtubeMode: .keyless) }),
            Case(label: "row 9 not linked",
                 expected: L10n.str("spotify.notLinked", locale: ne),
                 build: { self.makeWorld(sessionPresent: false) })
        ]
        for testCase in cases {
            let world = testCase.build()
            world.router.route(transcript: musicTranscript)
            waitForDelivery()
            XCTAssertEqual(outcomeLines(from: world.coordinator.assistantSpoken),
                           [testCase.expected],
                           "\(testCase.label): exactly one spoken outcome line")
        }
    }

    @MainActor
    func testStubIsUnreachableOnEveryMusicBranch() {
        struct Branch {
            let label: String
            let build: () -> MusicWorld
        }
        let branches: [Branch] = [
            Branch(label: "row 1", build: { self.makeWorld(searchReply: .body(Self.trackJSON, 200), playReply: .body(Data(), 204)) }),
            Branch(label: "row 2", build: { self.makeWorld(searchReply: .body(Self.trackJSON, 200), playReply: .body(Data(), 401), spotifyProbes: [true]) }),
            Branch(label: "row 3", build: { self.makeWorld(searchReply: .body(Self.trackJSON, 200), product: "free", spotifyProbes: [true, true]) }),
            Branch(label: "row 4", build: { self.makeWorld(searchReply: .body(Self.trackJSON, 200), product: "free", spotifyProbes: [false]) }),
            Branch(label: "row 5", build: { self.makeWorld(searchReply: .body(Self.trackJSON, 200), product: "free", spotifyProbes: [true, false]) }),
            Branch(label: "row 6", build: { self.makeWorld(searchReply: .body(Self.emptyTracksJSON, 200)) }),
            Branch(label: "row 7", build: { self.makeWorld(searchReply: .body(Data(), 500)) }),
            Branch(label: "row 8 youtube", build: { self.makeWorld(sessionPresent: false, youtubeMode: .keyless) }),
            Branch(label: "row 8 hand-off", build: { self.makeWorld(sessionPresent: false, spotifyProbes: [true]) }),
            Branch(label: "row 9", build: { self.makeWorld(sessionPresent: false) }),
            Branch(label: "row 10", build: { self.makeWorld(tokenReply: .body(Self.invalidGrantJSON, 400), expiry: Date(timeIntervalSinceNow: -60)) }),
            Branch(label: "row 11", build: { self.makeWorld(tokenReply: .failure(MusicFixtureBoom()), expiry: Date(timeIntervalSinceNow: -60)) }),
            Branch(label: "row 12", build: { self.makeWorld(product: nil, recordPresent: false) })
        ]
        for branch in branches {
            let world = branch.build()
            world.router.route(transcript: musicTranscript)
            waitForDelivery()
            assertNoStubEmission(world, branch.label)
        }
    }

    @MainActor
    func testToolLogEntriesCarryNoQueryOrTitle() {
        // F-5(b): the PER-ENTRY walk — EVERY tool-log entry of a music
        // turn, not only the terminal one, is swept for the query, the
        // track title, the track id and the token.
        let title = Self.trackTitle
        let trackID = Self.trackID
        let query = extractedQuery

        func sweep(_ world: MusicWorld, _ label: String) {
            for entry in world.logStore.entries() {
                // [W3-review M2] The M-1 contract is per-entry and
                // POSITIVE: every music-turn entry logs an EMPTY query —
                // not merely one free of the known query text.
                XCTAssertTrue(entry.query.isEmpty,
                              "\(label): \(entry.kind.rawValue) entry must log an EMPTY query")
                XCTAssertFalse(entry.query.contains(query),
                               "\(label): query leak in \(entry.kind.rawValue) entry (query field)")
                XCTAssertFalse(entry.response.contains(query),
                               "\(label): query leak in \(entry.kind.rawValue) entry (response field)")
                XCTAssertFalse(entry.response.contains(title),
                               "\(label): title leak in \(entry.kind.rawValue) entry")
                XCTAssertFalse(entry.query.contains(title),
                               "\(label): title leak in \(entry.kind.rawValue) entry (query field)")
                XCTAssertFalse(entry.response.contains(trackID),
                               "\(label): track id leak in \(entry.kind.rawValue) entry")
                XCTAssertFalse(entry.query.contains(Self.storedAccessToken),
                               "\(label): token leak in \(entry.kind.rawValue) entry (query field)")
                XCTAssertFalse(entry.response.contains(Self.storedAccessToken),
                               "\(label): token leak in \(entry.kind.rawValue) entry (response field)")
                XCTAssertFalse(entry.response.contains(Self.refreshedAccessToken),
                               "\(label): refreshed token leak in \(entry.kind.rawValue) entry")
                XCTAssertFalse(entry.query.contains(trackID),
                               "\(label): track id leak in \(entry.kind.rawValue) entry (query field)")
            }
        }

        let remote = makeWorld(searchReply: .body(Self.trackJSON, 200),
                               playReply: .body(Data(), 204))
        remote.router.route(transcript: musicTranscript)
        waitForDelivery()
        sweep(remote, "row 1")

        let deepLink = makeWorld(searchReply: .body(Self.trackJSON, 200),
                                 product: "free", spotifyProbes: [true, true])
        deepLink.router.route(transcript: musicTranscript)
        waitForDelivery()
        sweep(deepLink, "row 3")

        let fallback = makeWorld(sessionPresent: false, youtubeMode: .keyless)
        fallback.router.route(transcript: musicTranscript)
        waitForDelivery()
        sweep(fallback, "row 8")
        // The query-free projection's own pin: the YouTube leg's entry
        // logs an EMPTY query on music turns.
        XCTAssertEqual(fallback.youtubeEntries.first?.query, "")
    }

    @MainActor
    func testObservabilityEventsCarryNoMetadata() {
        let closedVocabulary: [String: Set<String>] = [
            "spotify_search": ["usable", "empty", "failed"],
            "spotify_play": ["ok", "premium_required", "restricted", "no_active_device",
                             "unauthorized", "network_failed"],
            "spotify_deeplink": ["opened", "not_opened"],
            "spotify_fallback": ["youtube", "not_linked", "not_found", "unavailable", "app_missing"],
            "spotify_link": ["success", "not_configured", "no_presenter", "cancelled", "failed"],
            "spotify_unlink": ["success", "revoked", "failed"]
        ]

        let worlds = [
            makeWorld(searchReply: .body(Self.trackJSON, 200), playReply: .body(Data(), 204)),
            makeWorld(searchReply: .body(Self.trackJSON, 200), product: "free", spotifyProbes: [true, true]),
            makeWorld(sessionPresent: false, youtubeMode: .keyless)
        ]
        for world in worlds {
            world.router.route(transcript: musicTranscript)
            waitForDelivery()
            for event in world.bus.emittedEvents {
                // Scoped to the two provider components T-116 owns. The
                // pre-existing `command_router`/`intent_keyword_match`
                // event deliberately carries fixed-vocabulary metadata
                // (domain, matched_keys) — out of scope here, and asserted
                // by its own suite.
                if event.component == "spotify" || event.component == "youtube" {
                    XCTAssertTrue(event.metadata.isEmpty,
                                  "\(event.eventType)|\(event.outcome): every provider event carries metadata [:]")
                }
                if event.component == "spotify" {
                    guard let allowed = closedVocabulary[event.eventType] else {
                        XCTFail("spotify event outside the closed vocabulary: \(event.eventType)")
                        continue
                    }
                    XCTAssertTrue(allowed.contains(event.outcome),
                                  "\(event.eventType): closed outcome set violated by \(event.outcome)")
                }
            }
        }
    }

    @MainActor
    func testNoEgressBeyondTheProviderAllowlist() {
        let allowedHosts: Set<String> = ["api.spotify.com", "accounts.spotify.com", "www.googleapis.com"]
        let worlds = [
            makeWorld(searchReply: .body(Self.trackJSON, 200), playReply: .body(Data(), 204),
                      youtubeMode: .keyed),
            makeWorld(searchReply: .body(Self.trackJSON, 200), product: "free", spotifyProbes: [true, true]),
            makeWorld(sessionPresent: false, youtubeMode: .keyless),
            makeWorld(tokenReply: .failure(MusicFixtureBoom()), expiry: Date(timeIntervalSinceNow: -60))
        ]
        for world in worlds {
            world.router.route(transcript: musicTranscript)
            waitForDelivery()
            for request in world.transport.capturedRequests {
                let host = request.url?.host ?? "-"
                XCTAssertTrue(allowedHosts.contains(host), "egress escaped the allowlist: \(host)")
                let urlText = request.url?.absoluteString ?? ""
                XCTAssertFalse(urlText.contains(Self.storedAccessToken),
                               "the token must never travel in a URL")
                XCTAssertFalse(urlText.contains("Bearer"),
                               "credentials are header-only")
            }
            for url in world.spotifyOpener?.opened ?? [] {
                XCTAssertEqual(url.scheme, "spotify",
                               "the music path opens only spotify: deep links")
            }
        }
    }

    @MainActor
    func testOneProviderUnavailableDoesNotBlockTheOther() {
        // YouTube broken, Spotify serviceable: Spotify serves.
        let spotifyWins = makeWorld(searchReply: .body(Self.trackJSON, 200),
                                    playReply: .body(Data(), 204),
                                    youtubeReply: .failure(MusicFixtureBoom()),
                                    youtubeMode: .keyed)
        spotifyWins.router.route(transcript: musicTranscript)
        waitForDelivery()
        XCTAssertEqual(spotifyWins.coordinator.assistantSpoken.last,
                       L10n.fmt("spotify.playing", locale: ne, Self.trackTitle),
                       "a failing YouTube pre-fetch never blocks the Spotify outcome")

        // Spotify broken, YouTube serviceable: YouTube serves.
        let youtubeWins = makeWorld(searchReply: .failure(MusicFixtureBoom()),
                                    youtubeMode: .keyless)
        youtubeWins.router.route(transcript: musicTranscript)
        waitForDelivery()
        XCTAssertEqual(youtubeWins.youtubeOpener?.opened,
                       [YouTubeTool.appSearchURL(query: extractedQuery)],
                       "a failing Spotify search never blocks the YouTube fallback")
    }

    // MARK: - §32 budgets (music.outcomeBudgetSeconds / music.negativeBudgetSeconds)

    @MainActor
    func testOutcomeLandsWithinTheOutcomeBudgetWhenAProviderAnswers() {
        // §32 row `music.outcomeBudgetSeconds` = 10.0 — assertion: when at
        // least one provider answers, the outcome line lands within
        // budget. In this stub world the measurement is a TRIPWIRE against
        // a change that introduces a real wait on the music path (the
        // overlap itself is structurally pinned by
        // `testBothKeyedProvidersAreSearchedConcurrently`; the wall-clock
        // property at real-network latency is DV-1/DV-4's). [W3-review M1]
        let world = makeWorld(searchReply: .body(Self.trackJSON, 200),
                              playReply: .body(Data(), 204),
                              youtubeMode: .keyed)
        let started = Date()
        world.router.route(transcript: musicTranscript)
        waitForDelivery()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(world.coordinator.assistantSpoken.last,
                       L10n.fmt("spotify.playing", locale: ne, Self.trackTitle))
        XCTAssertLessThan(elapsed, 10.0,
                          "the outcome must land within music.outcomeBudgetSeconds "
                          + "(one provider answered)")
    }

    @MainActor
    func testNoMusicPathWaitsBeyondTheNegativeBudget() {
        // §32 row `music.negativeBudgetSeconds` = 16.0 — assertion: no path
        // waits longer than two sequential provider budgets (2 × the 8.0 s
        // `spotify.fetchTimeoutSeconds`) before speaking. Run the deepest
        // no-answer path: unlinked, dormant session, no opener (row 9) —
        // its outcome line must still land inside the negative budget.
        // [W3-review M1]
        let world = makeWorld(sessionPresent: false)
        let started = Date()
        world.router.route(transcript: musicTranscript)
        waitForDelivery()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(world.coordinator.assistantSpoken.last,
                       L10n.str("spotify.notLinked", locale: ne))
        XCTAssertLessThan(elapsed, 16.0,
                          "no music path may wait beyond two sequential provider budgets")
    }
}

// MARK: - Doubles (file-private mirrors of the CommandRouterYouTubeTests harness)

private struct MusicFixtureBoom: Error {}

private final class MusicMockCoordinator: VoiceCommandCoordinating {
    var recordedTranscripts: [String] = []
    var isAwaitingConfirmation = false
    var brainReadiness = BrainReadiness.available
    var isAwaitingCallConfirmation = false
    var activeLocale: Locale { Locale(identifier: "ne-NP") }

    var assistantSpoken: [String] = []
    var genericReplies: [String] = []
    var contactSearchRequests: [String?] = []
    var pendingRephraseCommand: InterpretedCommand? { nil }

    func recordTranscript(_ text: String) { recordedTranscripts.append(text) }
    func oldestPendingReminderEntryId() -> UUID? { nil }
    func handleMedicationAcknowledgement(entryId: UUID) {}
    func startVoiceAckConfirmation(for entryId: UUID) -> String? { nil }
    func handleConfirmationResponse(_ response: ConfirmationResponse) {}
    func noteSpeakingStarted() {}
    func noteSpeakingEnded() {}
    func noteAssistantSpoke(_ text: String) { assistantSpoken.append(text) }
    func noteGenericReply(_ text: String) { genericReplies.append(text) }
    func addVoiceReminder(title: String, time: DateComponents) {}
    func requestCallConfirmation(contactQuery: String?, callType: String?, requestedApp: String?,
                                 sourceTranscript: String?, sourceCommand: InterpretedCommand?) -> String? { nil }
    func startRephraseConfirmation(_ command: InterpretedCommand, sourceTranscript: String?) {}
    func takePendingRephraseCommand() -> (command: InterpretedCommand, sourceTranscript: String?)? { nil }
    func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }
    func composeMessage(toContactNamed name: String?, body: String,
                        requestedApp: String?) -> MessageComposeOutcome { .contactNotFound }
    func presentPluginView(_ view: AnyView) {}
    func requestContactSearch(query: String?) { contactSearchRequests.append(query) }
}

private final class MusicMockSpeaker: Speaker {
    private(set) var utterances: [(text: String, locale: Locale)] = []

    func speak(_ text: String, locale: Locale) async {
        utterances.append((text, locale))
    }

    func cancel() {}
}

/// Scripted multi-host `LocalToolTransport`: routes by host + path so one
/// double serves the router's Spotify search/play, the YouTube pre-fetch
/// and the session's token endpoint. Request capture is lock-guarded —
/// the music turn's two provider legs fetch concurrently.
private final class MusicStubTransport: LocalToolTransport {
    enum Reply {
        case body(Data, Int)
        case failure(Error)
        case nonHTTP(Data)
    }

    var spotifySearchReply: Reply = .body(Data(), 500)
    var spotifyPlayReply: Reply = .body(Data(), 500)
    var spotifyProfileReply: Reply = .body(Data(#"{"product":"premium","id":"caregiver"}"#.utf8), 200)
    var tokenReply: Reply = .body(Data(), 500)
    var youtubeReply: Reply = .body(Data(#"{"items": []}"#.utf8), 200)
    /// When set, the two provider search legs park on the gate until both
    /// have arrived (the §13 row-1 concurrency proof).
    var arrivalGate: MusicArrivalGate?

    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    var capturedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func requests(host: String, path: String? = nil) -> [URLRequest] {
        capturedRequests.filter { request in
            request.url?.host == host && (path == nil || request.url?.path == path)
        }
    }

    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        _requests.append(request)
        lock.unlock()

        let host = request.url?.host ?? ""
        let path = request.url?.path ?? ""
        if let arrivalGate,
           (host == "api.spotify.com" && path == "/v1/search") || host == "www.googleapis.com" {
            await arrivalGate.arrive()
        }

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
        case ("www.googleapis.com", _):
            reply = youtubeReply
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

/// The concurrency gate: the first provider leg parks; if the second leg
/// arrives while it is still parked, the two legs were genuinely in
/// flight together (`overlapObserved`). A sequential implementation lets
/// the parked leg release on the timeout and the later arrival cannot
/// set the flag — an honest failure signal, never a hang.
private actor MusicArrivalGate {
    private(set) var overlapObserved = false
    private var arrivals = 0
    private var parked: CheckedContinuation<Void, Never>?

    func arrive() async {
        arrivals += 1
        if arrivals >= 2 {
            if let parked {
                overlapObserved = true
                self.parked = nil
                parked.resume()
            }
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parked = continuation
            Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.releaseAfterTimeout()
            }
        }
    }

    private func releaseAfterTimeout() {
        if let parked {
            self.parked = nil
            parked.resume()
        }
    }
}

private final class MusicLinkOpener: CallLinkOpening {
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

/// The session fixture's presentation seam — never exercised on the
/// music path (no link() runs in this suite).
@MainActor
private final class UnusedSpotifyAuthSession: SpotifyAuthSession {
    func authorize(url: URL, callbackURLScheme: String) async throws -> URL {
        throw SpotifyAuthError.userCancelled
    }
}
