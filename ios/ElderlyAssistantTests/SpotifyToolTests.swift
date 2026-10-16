import XCTest
@testable import ElderlyAssistant

/// [SPOTIFY] (2026-10-06) `SpotifyTool` search + remote-play client half
/// (T-106; design-l2 C-SP-01 §24 / §22): request shape (track-only,
/// bounded timeout, header-only credential), payload parsing, the closed
/// `FetchError` / `PlayError` mappings, single-shot discipline (no path
/// retries), the timeout budget, and the absence of query text, provider
/// bodies and token material from every failure value. All network rides
/// the stub transport; no test touches the real network.
final class SpotifyToolTests: XCTestCase {

    /// A synthetic 22-character base62 track id (the real Spotify shape).
    private let trackID = "01AbCdEfGhIjKlMnOpQrSt"
    private let trackTitle = "Bhajan Ganga"

    /// Test-side stand-in for the session's `validAccessToken()` (design §12
    /// state machine B). Production's seam is `fetchTopTrack`'s
    /// `accessToken: String` parameter — acquisition belongs to the auth
    /// components (T-109/T-110, landing in parallel) — so a closure that
    /// returns a valid token is exactly the Gherkin's "token source that
    /// returns a valid access token".
    private let tokenSource = StubTokenSource("test-access-token")

    private var token: String { tokenSource.accessToken() }

    private var spotifyTrackURL: URL {
        URL(string: "spotify:track:" + trackID)!
    }

    /// A canonical 2xx search payload. The `artists` element is payload
    /// this unit deliberately does not carry past parsing: design §24's
    /// `TrackResult` exposes the validated id and the provider's name.
    private var topTrackJSON: Data {
        Data("""
        {"tracks":{"items":[{"id":"\(trackID)","name":"\(trackTitle)","artists":[{"name":"Ganga Band"}]}]}}
        """.utf8)
    }

    // MARK: - URL construction

    func testApiSearchURLIsTrackOnlyAndPercentEncoded() throws {
        let url = try XCTUnwrap(SpotifyTool.apiSearchURL(query: "भजन & फूल", market: nil))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "api.spotify.com")
        XCTAssertEqual(url.path, "/v1/search")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["q", "type", "limit"],
                       "exactly one search request carries exactly q/type/limit")
        XCTAssertEqual(items.first { $0.name == "type" }?.value, "track",
                       "search is track-only (L2-D2)")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "1",
                       "one best match only")
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "भजन & फूल",
                       "the spoken query round-trips through percent-encoding")
        XCTAssertNil(items.first { $0.name == "market" })
        XCTAssertTrue(url.absoluteString.contains("%20"), "spaces are encoded")
        XCTAssertTrue(url.absoluteString.contains("%26"), "reserved delimiters are encoded")
        XCTAssertFalse(url.absoluteString.contains("test-access-token"),
                       "no credential ever becomes a URL component")
    }

    func testApiSearchURLAddsMarketOnlyWhenGiven() throws {
        let withMarket = try XCTUnwrap(SpotifyTool.apiSearchURL(query: "bhajan", market: "NP"))
        let items = URLComponents(url: withMarket, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "market" }?.value, "NP")

        let withoutMarket = try XCTUnwrap(SpotifyTool.apiSearchURL(query: "bhajan", market: nil))
        let bare = URLComponents(url: withoutMarket, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(bare.first { $0.name == "market" })
    }

    func testApiSearchURLTrimsAndRejectsEmptyOrOverCapQueries() throws {
        let trimmed = try XCTUnwrap(SpotifyTool.apiSearchURL(query: "  bhajan\n", market: nil))
        let items = URLComponents(url: trimmed, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "bhajan")

        XCTAssertNil(SpotifyTool.apiSearchURL(query: "", market: nil))
        XCTAssertNil(SpotifyTool.apiSearchURL(query: "   \n", market: nil))

        let atCap = String(repeating: "a", count: SpotifyTool.maxSearchQueryLength)
        XCTAssertNotNil(SpotifyTool.apiSearchURL(query: atCap, market: nil))
        let overCap = atCap + "a"
        XCTAssertNil(SpotifyTool.apiSearchURL(query: overCap, market: nil),
                     "an over-cap query is never sent to the provider")
    }

    func testApiPlayURLIsThePlayerPlayEndpoint() {
        XCTAssertEqual(SpotifyTool.apiPlayURL().absoluteString,
                       "https://api.spotify.com/v1/me/player/play")
    }

    func testDefaultTimeoutBudgetIsTheSharedEightSeconds() {
        XCTAssertEqual(SpotifyTool.defaultFetchTimeoutSeconds, 8.0,
                       "NFR-SP-001: the default provider budget is 8 s")
    }

    // MARK: - Parsing

    func testParseSearchJSONExtractsTheTopTrack() throws {
        let result = try SpotifyTool.parseSearchJSON(topTrackJSON)
        XCTAssertEqual(result, SpotifyTool.TrackResult(id: trackID, title: trackTitle))
        XCTAssertEqual(result.id.count, 22, "the id is the 22-character base62 shape")
    }

    func testParseSearchJSONCollapsesTitleWhitespace() throws {
        let data = Data("""
        {"tracks":{"items":[{"id":"\(trackID)","name":"Bhajan\\n  Ganga\\tMix"}]}}
        """.utf8)
        XCTAssertEqual(try SpotifyTool.parseSearchJSON(data).title, "Bhajan Ganga Mix")
    }

    func testParseSearchJSONEmptyResultSetIsNoResults() {
        for json in [#"{"tracks":{"items":[]}}"#, #"{"tracks":{}}"#] {
            XCTAssertThrowsError(try SpotifyTool.parseSearchJSON(Data(json.utf8))) { error in
                XCTAssertEqual(error as? SpotifyTool.FetchError, .noResults)
            }
        }
    }

    func testParseSearchJSONMalformedPayloadIsMalformedResponse() {
        let cases: [Data] = [
            Data("not json".utf8),
            Data("{}".utf8),
            Data("""
            {"tracks":{"items":[{"id":"\(trackID)","name":"   "}]}}
            """.utf8)
        ]
        for data in cases {
            XCTAssertThrowsError(try SpotifyTool.parseSearchJSON(data)) { error in
                XCTAssertEqual(error as? SpotifyTool.FetchError, .malformedResponse)
            }
        }
    }

    func testParseSearchJSONUnusableIdentifierIsUnusableResult() {
        let twentyThreeCharID = trackID + "X"
        let cases = [
            #"{"tracks":{"items":[{"name":"no id at all"}]}}"#,
            #"{"tracks":{"items":[{"id":null,"name":"null id"}]}}"#,
            "{\"tracks\":{\"items\":[{\"id\":\"\(twentyThreeCharID)\",\"name\":\"too long\"}]}}",
            #"{"tracks":{"items":[{"id":"01AbCdEfGhIjKlMnOpQrS-","name":"punctuation"}]}}"#
        ]
        for json in cases {
            XCTAssertThrowsError(try SpotifyTool.parseSearchJSON(Data(json.utf8))) { error in
                XCTAssertEqual(error as? SpotifyTool.FetchError, .unusableResult)
            }
        }
    }

    func testIsSpotifyIdentifierAcceptsOnlyExactly22Base62Characters() {
        XCTAssertTrue(SpotifyTool.isSpotifyIdentifier("01AbCdEfGhIjKlMnOpQrSt"))
        XCTAssertTrue(SpotifyTool.isSpotifyIdentifier("ABCDEFGHIJKLMNOPQRSTUV"))
        XCTAssertTrue(SpotifyTool.isSpotifyIdentifier("abcdefghijklmnopqrstuv"))
        XCTAssertTrue(SpotifyTool.isSpotifyIdentifier("0123456789012345678901"))

        let rejected = [
            "",
            "01AbCdEfGhIjKlMnOpQrS",          // 21
            "01AbCdEfGhIjKlMnOpQrStX",        // 23
            "01AbCdEfGhIjKlMnOpQrS-",         // punctuation
            "01AbCdEfGhIjKlMnOpQrS/",
            "01AbCdEfGhIjKlMnOpQrS:",
            "01AbCdEfGhIjKlMnOpQrS ",
            "01AbCdEfGhIjKlMnOpQrS%",
            "01AbCdEfGhIjKlMnOpQrSé",         // non-base62 Unicode
            String(repeating: "a", count: 100)
        ]
        for id in rejected {
            XCTAssertFalse(SpotifyTool.isSpotifyIdentifier(id), "must reject: \(id)")
        }
    }

    // MARK: - Search requests (Gherkin 1 and 2)

    /// Gherkin: "A spoken query returns the single best track match" —
    /// exactly one request with type=track and limit=1, and the returned
    /// track exposes its 22-character base62 id and name.
    func testSearchIssuesExactlyOneTrackRequestWithHeaderOnlyCredential() async throws {
        let transport = StubSpotifyTransport(data: topTrackJSON, statusCode: 200)
        let result = try await SpotifyTool.fetchTopTrack(query: "भजन बजाऊ",
                                                         accessToken: tokenSource.accessToken(),
                                                         transport: transport)

        XCTAssertEqual(result, SpotifyTool.TrackResult(id: trackID, title: trackTitle))
        XCTAssertEqual(transport.capturedRequests.count, 1,
                       "one search request per call — never a fan-out or a retry")

        let request = try XCTUnwrap(transport.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "api.spotify.com")
        XCTAssertEqual(request.url?.path, "/v1/search")
        let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "type" }?.value, "track")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       SpotifyTransport.authorizationScheme + " " + token,
                       "the credential travels in the Authorization header only")
        XCTAssertFalse(try XCTUnwrap(request.url).absoluteString.contains(token),
                       "the token never appears in the request URL")
        XCTAssertEqual(request.timeoutInterval, SpotifyTool.defaultFetchTimeoutSeconds,
                       "the request carries the tool's bounded budget")
    }

    func testSearchPublishesTheInjectedTimeoutBudget() async throws {
        let transport = StubSpotifyTransport(data: topTrackJSON, statusCode: 200)
        let injected = 3.5
        _ = try await SpotifyTool.fetchTopTrack(query: "bhajan",
                                                accessToken: token,
                                                transport: transport,
                                                timeoutSeconds: injected)
        XCTAssertEqual(transport.capturedRequests.first?.timeoutInterval, injected,
                       "NFR-SP-001: the timeout is the injected value, not a literal")
    }

    /// Gherkin: "Search failure is typed, single-shot and content-free in
    /// logs" — a non-200 is a typed matrix-row-7 failure, no retry is
    /// attempted, and neither the query text nor the raw provider body
    /// appears in the failure value (the only thing that could reach a log
    /// or an event from this unit).
    func testSearchNon200IsTypedSingleShotAndContentFree() async {
        let queryMarker = "bhajan-query-marker"
        let bodyMarker = "provider-body-marker"
        let transport = StubSpotifyTransport(
            data: Data("{\"error\":{\"status\":403,\"message\":\"\(bodyMarker)\"}}".utf8),
            statusCode: 403)

        let failure = await searchError(query: queryMarker, transport: transport)

        XCTAssertEqual(failure, SpotifyTool.FetchError.invalidResponse(statusCode: 403))
        XCTAssertEqual(transport.capturedRequests.count, 1,
                       "a failed search is single-shot — no retry is attempted")
        let rendered = String(describing: failure)
        XCTAssertFalse(rendered.contains(queryMarker), "no query text in the failure")
        XCTAssertFalse(rendered.contains(bodyMarker), "no raw provider body in the failure")
        XCTAssertFalse(rendered.contains(token), "no token material in the failure")
    }

    func testSearch401UsesTheRow7InvalidResponseCase() async {
        let transport = StubSpotifyTransport(data: Data(), statusCode: 401)
        let failure = await searchError(transport: transport)
        XCTAssertEqual(failure, SpotifyTool.FetchError.invalidResponse(statusCode: 401),
                       "401 on search is a row-7 search failure, not a refresh dance")
        XCTAssertEqual(transport.capturedRequests.count, 1)
    }

    func testSearchEmptyPayloadIsNotFoundAndMalformedIsMalformed() async {
        let empty = StubSpotifyTransport(data: Data(#"{"tracks":{"items":[]}}"#.utf8), statusCode: 200)
        let emptyFailure = await searchError(transport: empty)
        XCTAssertEqual(emptyFailure, SpotifyTool.FetchError.noResults)
        XCTAssertEqual(empty.capturedRequests.count, 1)

        let malformed = StubSpotifyTransport(data: Data("garbage".utf8), statusCode: 200)
        let malformedFailure = await searchError(transport: malformed)
        XCTAssertEqual(malformedFailure, SpotifyTool.FetchError.malformedResponse)
        XCTAssertEqual(malformed.capturedRequests.count, 1)

        let unusable = StubSpotifyTransport(
            data: Data("{\"tracks\":{\"items\":[{\"id\":\"too-short\",\"name\":\"x\"}]}}".utf8),
            statusCode: 200)
        let unusableFailure = await searchError(transport: unusable)
        XCTAssertEqual(unusableFailure, SpotifyTool.FetchError.unusableResult,
                       "an id that fails validation is never carried further")
        XCTAssertEqual(unusable.capturedRequests.count, 1)
    }

    func testSearchTransportErrorMappingDistinguishesTimeoutFromUnavailable() async {
        let timedOut = StubSpotifyTransport(error: URLError(.timedOut))
        let timedOutFailure = await searchError(transport: timedOut)
        XCTAssertEqual(timedOutFailure, SpotifyTool.FetchError.timedOut)

        let bridged = StubSpotifyTransport(
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        let bridgedFailure = await searchError(transport: bridged)
        XCTAssertEqual(bridgedFailure, SpotifyTool.FetchError.timedOut,
                       "the NSError bridge of a timeout classifies the same")

        let offline = StubSpotifyTransport(error: URLError(.notConnectedToInternet))
        let offlineFailure = await searchError(transport: offline)
        XCTAssertEqual(offlineFailure, SpotifyTool.FetchError.transportUnavailable)

        struct Boom: Error {}
        let foreign = StubSpotifyTransport(error: Boom())
        let foreignFailure = await searchError(transport: foreign)
        XCTAssertEqual(foreignFailure, SpotifyTool.FetchError.transportUnavailable)
    }

    func testSearchEmptyOrOverCapQueryFailsAsNoResultsWithoutAnyRequest() async {
        let transport = StubSpotifyTransport(data: topTrackJSON, statusCode: 200)
        let emptyFailure = await searchError(query: "   \n", transport: transport)
        XCTAssertEqual(emptyFailure, SpotifyTool.FetchError.noResults,
                       "an empty query resolves to zero usable tracks — never a fabricated request")

        let overCap = String(repeating: "a", count: SpotifyTool.maxSearchQueryLength + 1)
        let overCapFailure = await searchError(query: overCap, transport: transport)
        XCTAssertEqual(overCapFailure, SpotifyTool.FetchError.noResults)
        XCTAssertEqual(transport.capturedRequests.count, 0,
                       "no request is constructed for an empty or over-cap query")
    }

    func testNonHTTPResponseIsATransportAnomaly() async {
        let searchFailure = await searchError(transport: NonHTTPResponseTransport())
        XCTAssertEqual(searchFailure, SpotifyTool.FetchError.transportUnavailable)

        let playFailure = await playError(transport: NonHTTPResponseTransport())
        XCTAssertEqual(playFailure, SpotifyTool.PlayError.transportUnavailable)
    }

    /// Gherkin: "A hung provider is bounded by the configured timeout" —
    /// the provider delays beyond `defaultFetchTimeoutSeconds`, so the
    /// request ends in the timeout classification at the request's
    /// published budget, with one request only, and the turn does not
    /// actually wait out the provider's delay.
    ///
    /// The stub models URLSession's own timeout enforcement: it "waits"
    /// `simulatedDelay` (a few real milliseconds) and, when that delay
    /// overruns the request's published `timeoutInterval`, throws the
    /// `URLError(.timedOut)` the real stack produces at its deadline.
    func testHungProviderEndsInTheTimeoutClassificationWithinTheBound() async {
        let transport = DelayedProviderTransport(
            simulatedDelay: SpotifyTool.defaultFetchTimeoutSeconds + 0.5)
        let started = Date()
        let failure = await searchError(transport: transport)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(failure, SpotifyTool.FetchError.timedOut)
        XCTAssertEqual(transport.capturedRequests.count, 1, "the timeout is terminal — no retry")
        XCTAssertEqual(transport.capturedRequests.first?.timeoutInterval,
                       SpotifyTool.defaultFetchTimeoutSeconds,
                       "the request carries the budget URLSession enforces")
        XCTAssertLessThan(elapsed, 1.0,
                          "the calling turn is bounded by the budget, not the provider's delay")
    }

    func testEveryRequestStaysOnTheApiHost() async throws {
        let searchTransport = StubSpotifyTransport(data: topTrackJSON, statusCode: 200)
        _ = try await SpotifyTool.fetchTopTrack(query: "bhajan", accessToken: token,
                                                transport: searchTransport)
        let playTransport = StubSpotifyTransport(data: Data(), statusCode: 204)
        try await SpotifyTool.playTrack(uri: spotifyTrackURL, accessToken: token,
                                        transport: playTransport)

        let requests = searchTransport.capturedRequests + playTransport.capturedRequests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "api.spotify.com",
                           "egress from this unit is api.spotify.com only (NFR-SP-003)")
        }
    }

    // MARK: - Play requests (Gherkin 3)

    func testPlayIssuesExactlyOnePutWithTheTrackUriBodyAndHeader() async throws {
        let transport = StubSpotifyTransport(data: Data(), statusCode: 204)
        try await SpotifyTool.playTrack(uri: spotifyTrackURL, accessToken: token,
                                        transport: transport)

        XCTAssertEqual(transport.capturedRequests.count, 1, "one play attempt, single-shot")
        let request = try XCTUnwrap(transport.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url, SpotifyTool.apiPlayURL())
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       SpotifyTransport.authorizationScheme + " " + token)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, SpotifyTool.defaultFetchTimeoutSeconds)
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(String(data: body, encoding: .utf8),
                       "{\"uris\":[\"spotify:track:\(trackID)\"]}",
                       "the one play body carries the verified track URI")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: [String]],
                       ["uris": ["spotify:track:\(trackID)"]])
        XCTAssertFalse(request.url?.absoluteString.contains(token) ?? true,
                       "the token never appears in the request URL")
    }

    /// Gherkin: "Remote play failure is typed and never retried" — a 403
    /// maps to the premium-required classification and the caller can fall
    /// back to the deep link without a second play attempt.
    func testPlay403PremiumRequiredIsTypedAndNeverRetried() async {
        let transport = StubSpotifyTransport(
            data: Data("""
            {"error":{"status":403,"reason":"PREMIUM_REQUIRED","message":"premium only"}}
            """.utf8),
            statusCode: 403)
        let failure = await playError(transport: transport)
        XCTAssertEqual(failure, SpotifyTool.PlayError.premiumRequired)
        XCTAssertEqual(transport.capturedRequests.count, 1,
                       "one attempt only — the deep-link fallback replaces a second play attempt")
    }

    func testPlay403OtherReasonsAreRestricted() async {
        let bodies = [
            Data("{\"error\":{\"status\":403,\"reason\":\"INVALID_DEVICE\"}}".utf8),
            Data("{\"error\":{\"status\":403,\"message\":\"no reason field\"}}".utf8),
            Data("not json".utf8),
            Data()
        ]
        for body in bodies {
            let transport = StubSpotifyTransport(data: body, statusCode: 403)
            let failure = await playError(transport: transport)
            XCTAssertEqual(failure, SpotifyTool.PlayError.restricted)
            XCTAssertEqual(transport.capturedRequests.count, 1)
        }
    }

    func testPlay401IsUnauthorizedForTheCallersRefreshSeam() async {
        let transport = StubSpotifyTransport(data: Data(), statusCode: 401)
        let failure = await playError(transport: transport)
        XCTAssertEqual(failure, SpotifyTool.PlayError.unauthorized)
        XCTAssertEqual(transport.capturedRequests.count, 1,
                       "the tool itself never retries; the caller owns the single refresh")
    }

    func testPlay404IsNoActiveDevice() async {
        let transport = StubSpotifyTransport(
            data: Data("{\"error\":{\"status\":404,\"reason\":\"NO_ACTIVE_DEVICE\"}}".utf8),
            statusCode: 404)
        let failure = await playError(transport: transport)
        XCTAssertEqual(failure, SpotifyTool.PlayError.noActiveDevice)
    }

    func testPlayOtherNon2xxIsInvalidResponse() async {
        let transport = StubSpotifyTransport(data: Data(), statusCode: 500)
        let failure = await playError(transport: transport)
        XCTAssertEqual(failure, SpotifyTool.PlayError.invalidResponse(statusCode: 500))
    }

    func testPlayTransportErrorMappingDistinguishesTimeoutFromUnavailable() async {
        let timedOut = StubSpotifyTransport(error: URLError(.timedOut))
        let timedOutFailure = await playError(transport: timedOut)
        XCTAssertEqual(timedOutFailure, SpotifyTool.PlayError.timedOut)

        let bridged = StubSpotifyTransport(
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        let bridgedFailure = await playError(transport: bridged)
        XCTAssertEqual(bridgedFailure, SpotifyTool.PlayError.timedOut)

        let offline = StubSpotifyTransport(error: URLError(.networkConnectionLost))
        let offlineFailure = await playError(transport: offline)
        XCTAssertEqual(offlineFailure, SpotifyTool.PlayError.transportUnavailable)
    }

    func testPlayRejectsNonSpotifyURIWithoutAnyRequest() async {
        let transport = StubSpotifyTransport(data: Data(), statusCode: 204)
        let failure = await playError(uri: URL(string: "https://evil.example/x")!,
                                      transport: transport)
        XCTAssertEqual(failure, SpotifyTool.PlayError.invalidURI)
        XCTAssertEqual(transport.capturedRequests.count, 0,
                       "a rejected URI never produces a request")
    }

    func testPlayFailureCarriesNoProviderBodyOrToken() async {
        let bodyMarker = "provider-body-marker"
        let transport = StubSpotifyTransport(
            data: Data("""
            {"error":{"status":403,"reason":"PREMIUM_REQUIRED","message":"\(bodyMarker)"}}
            """.utf8),
            statusCode: 403)
        let failure = await playError(transport: transport)
        XCTAssertEqual(failure, SpotifyTool.PlayError.premiumRequired)
        let rendered = String(describing: failure)
        XCTAssertFalse(rendered.contains(bodyMarker), "no raw provider body in the failure")
        XCTAssertFalse(rendered.contains(token), "no token material in the failure")
        XCTAssertEqual(transport.capturedRequests.count, 1)
    }

    // MARK: - Deep links (T-107; Gherkin: validated id opens / app absent)

    /// Gherkin: "A validated track id opens the Spotify app" — the link is
    /// the exact `spotify:track:` shape for the validated id, carries no
    /// title and no query text (the title is spoken-only), and every scalar
    /// in it is base62 or the scheme's colon.
    func testTrackURIUsesTheExactSpotifyTrackShapeAndCarriesNoTitleOrQueryText() throws {
        let uri = try XCTUnwrap(SpotifyTool.trackURI(id: trackID))
        XCTAssertEqual(uri.absoluteString, "spotify:track:" + trackID)
        XCTAssertEqual(uri.scheme, "spotify")
        XCTAssertFalse(uri.absoluteString.contains(trackTitle),
                       "a title is never composed into a URI (NFR-SP-008)")
        XCTAssertFalse(uri.absoluteString.contains("search"),
                       "a track link is not a search link")
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:")
        XCTAssertTrue(uri.absoluteString.unicodeScalars.allSatisfy { allowed.contains($0) },
                      "a validated id cannot introduce any scalar outside base62")
    }

    /// Representative grammar rejections; the exhaustive hostile corpus —
    /// one named rejection assertion per fixture — lives in
    /// `SpotifyDeepLinkTests` / `SpotifyHostileCorpus`.
    func testTrackURIRejectsRepresentativeNonGrammarIdentifiers() {
        let rejected = [
            "",
            "01AbCdEfGhIjKlMnOpQrS",
            "01AbCdEfGhIjKlMnOpQrStX",
            "spotify:track:01AbCdEfGhIjKlMnOpQrSt",
            "01AbCdEfGhIjKlMnOpQrS/",
        ]
        for id in rejected {
            XCTAssertNil(SpotifyTool.trackURI(id: id), "must not build a URI from '\(id)'")
        }
    }

    /// Gherkin: "A validated track id opens the Spotify app" — the probe
    /// (canOpenURL true in this scenario) runs first and determines the
    /// outcome; the open call carries exactly the validated URL.
    func testValidatedTrackIDOpensThroughTheProbeWithTheProbeResultAsTheOutcome() throws {
        let uri = try XCTUnwrap(SpotifyTool.trackURI(id: trackID))
        let opener = RecordingSpotifyLinkOpener(grantsOpen: true)
        XCTAssertEqual(SpotifyTool.open(uri, opener: opener), SpotifyTool.OpenOutcome.opened)
        XCTAssertEqual(opener.events, [.canOpenURL(uri), .open(uri)],
                       "the probe runs first, exactly once, then the accepted URL opens")
    }

    /// Gherkin: "Spotify app absent degrades honestly" — a probe that
    /// reports no installed app is the typed not-opened outcome the caller
    /// turns into the honest app-absent line; no open call is issued, so
    /// there is no silent no-op to mistake for success.
    func testProbeReportingTheAppAbsentIsNotOpenedWithNoOpenCall() throws {
        let uri = try XCTUnwrap(SpotifyTool.searchURI(query: "भजन"))
        let opener = RecordingSpotifyLinkOpener(grantsOpen: false)
        XCTAssertEqual(SpotifyTool.open(uri, opener: opener), SpotifyTool.OpenOutcome.notOpened)
        XCTAssertEqual(opener.events, [.canOpenURL(uri)],
                       "a failed probe never reaches the open call")
        XCTAssertTrue(opener.openedURLs.isEmpty)
    }

    /// The DoD pin, over both probe answers: `.opened` appears if and only
    /// if the probe granted, the probe is consulted exactly once, and the
    /// outcome has no other input (V-4) — no path treats probe failure as
    /// success.
    func testOpenOutcomeHasNoPathThatTreatsProbeFailureAsSuccess() throws {
        let uri = try XCTUnwrap(SpotifyTool.trackURI(id: trackID))
        for grants in [true, false] {
            let opener = RecordingSpotifyLinkOpener(grantsOpen: grants)
            let outcome = SpotifyTool.open(uri, opener: opener)
            XCTAssertEqual(outcome, grants ? .opened : .notOpened)
            XCTAssertEqual(opener.probedURLs, [uri],
                           "the probe is the single, once-only input to the pin (V-4)")
            XCTAssertEqual(opener.openedURLs, grants ? [uri] : [],
                           "the open call happens iff the probe granted")
        }
    }

    /// The search hand-off link follows the same grammar and encoding rules
    /// (design §24, matrix row 8).
    func testSearchURIUsesTheSpotifySearchShapeAndPercentEncodesTheQuery() throws {
        let uri = try XCTUnwrap(SpotifyTool.searchURI(query: "भजन & फूल"))
        XCTAssertEqual(uri.scheme, "spotify")
        XCTAssertTrue(uri.absoluteString.hasPrefix("spotify:search:"),
                      "the hand-off keeps the spotify:search: shape")
        let encoded = String(uri.absoluteString.dropFirst("spotify:search:".count))
        XCTAssertFalse(encoded.contains("&"), "no unencoded query delimiter survives")
        XCTAssertFalse(encoded.contains("="))
        XCTAssertTrue(encoded.contains("%26"), "the reserved delimiter is percent-encoded")
        XCTAssertTrue(encoded.contains("%20"), "the space is percent-encoded")
        XCTAssertEqual(encoded.removingPercentEncoding, "भजन & फूल",
                       "the query round-trips; only the encoding changed")
    }

    func testSearchURIEncodesEveryDelimiterInTheGrammarSet() throws {
        let cases: [(query: String, body: String)] = [
            ("a+b", "a%2Bb"),   // '+' first: form decoders read a raw '+' as space
            ("a&b", "a%26b"),
            ("a=b", "a%3Db"),
            ("a?b", "a%3Fb"),
            ("a/b", "a%2Fb"),
            ("a%b", "a%25b"),
            ("a#b", "a%23b"),
        ]
        for (query, expectedBody) in cases {
            let uri = try XCTUnwrap(SpotifyTool.searchURI(query: query))
            XCTAssertEqual(String(uri.absoluteString.dropFirst("spotify:search:".count)),
                           expectedBody, "\(query)")
        }
    }

    func testSearchURIRejectsEmptyTrimmedAndOverCapQueries() throws {
        XCTAssertNil(SpotifyTool.searchURI(query: ""))
        XCTAssertNil(SpotifyTool.searchURI(query: " \n\t "))
        let atCap = String(repeating: "ग", count: SpotifyTool.maxSearchQueryLength)
        XCTAssertNotNil(SpotifyTool.searchURI(query: atCap),
                        "the cap counts Characters, not bytes or scalars")
        XCTAssertNil(SpotifyTool.searchURI(query: atCap + "ग"))
        let trimmed = try XCTUnwrap(SpotifyTool.searchURI(query: "  भजन  "))
        XCTAssertEqual(String(trimmed.absoluteString.dropFirst("spotify:search:".count))
                        .removingPercentEncoding,
                       "भजन",
                       "the hand-off trims the same way the API search does")
    }

    /// NFR-SP-008's scheme allowlist, over accepted inputs including hostile
    /// query text: every construction stays `spotify:` and only `spotify:`
    /// URLs are ever offered to the opener seam.
    func testEveryDeepLinkConstructionStaysInsideTheSpotifyScheme() throws {
        var constructed: [URL] = []
        for id in [trackID, "ABCDEFGHIJKLMNOPQRSTUV"] {
            constructed.append(try XCTUnwrap(SpotifyTool.trackURI(id: id)))
        }
        for query in ["भजन", "https://evil.example/x", "javascript:alert(1)", "..%2F..%2Fetc"] {
            constructed.append(try XCTUnwrap(SpotifyTool.searchURI(query: query)))
        }

        let opener = RecordingSpotifyLinkOpener(grantsOpen: true)
        for uri in constructed {
            XCTAssertEqual(uri.scheme, "spotify",
                           "\(uri) escapes the construction allowlist (NFR-SP-008)")
            _ = SpotifyTool.open(uri, opener: opener)
        }
        XCTAssertEqual(opener.probedURLs.count, constructed.count)
        XCTAssertEqual(Set(opener.probedURLs.map(\.scheme)), ["spotify"],
                       "only allowlisted schemes ever reach the opener seam")
        XCTAssertEqual(Set(opener.openedURLs.map(\.scheme)), ["spotify"])
    }

    // MARK: - Helpers

    /// Runs a search and returns the typed `FetchError` it threw — failing
    /// the test on success or on a foreign error type, so each assertion
    /// stays a one-line equality on the closed vocabulary.
    private func searchError(query: String = "bhajan",
                             transport: LocalToolTransport,
                             timeoutSeconds: TimeInterval = SpotifyTool.defaultFetchTimeoutSeconds,
                             file: StaticString = #filePath,
                             line: UInt = #line) async -> SpotifyTool.FetchError? {
        do {
            _ = try await SpotifyTool.fetchTopTrack(query: query,
                                                    accessToken: token,
                                                    transport: transport,
                                                    timeoutSeconds: timeoutSeconds)
            XCTFail("the search must fail", file: file, line: line)
            return nil
        } catch let error as SpotifyTool.FetchError {
            return error
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
            return nil
        }
    }

    /// Runs a play attempt and returns the typed `PlayError` it threw.
    private func playError(uri: URL? = nil,
                           transport: LocalToolTransport,
                           timeoutSeconds: TimeInterval = SpotifyTool.defaultFetchTimeoutSeconds,
                           file: StaticString = #filePath,
                           line: UInt = #line) async -> SpotifyTool.PlayError? {
        do {
            try await SpotifyTool.playTrack(uri: uri ?? spotifyTrackURL,
                                            accessToken: token,
                                            transport: transport,
                                            timeoutSeconds: timeoutSeconds)
            XCTFail("the play attempt must fail", file: file, line: line)
            return nil
        } catch let error as SpotifyTool.PlayError {
            return error
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
            return nil
        }
    }
}

// MARK: - Doubles

/// The Gherkin's "token source that returns a valid access token" — a
/// closure stand-in for the session's `validAccessToken()` until T-109/T-110
/// land. Nothing in production consumes a closure: the tool takes the
/// resolved token string (design §24), so this double cannot drift into a
/// second token path.
private struct StubTokenSource {
    private let source: () -> String

    init(_ token: String = "test-access-token") {
        self.source = { token }
    }

    func accessToken() -> String { source() }
}

/// Scripted `LocalToolTransport`: records every request and answers with
/// the scripted payload/status, or throws the scripted transport error.
private final class StubSpotifyTransport: LocalToolTransport {
    private(set) var capturedRequests: [URLRequest] = []
    private let data: Data
    private let statusCode: Int
    private let error: Error?

    init(data: Data = Data(), statusCode: Int = 200, error: Error? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.error = error
    }

    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequests.append(request)
        if let error { throw error }
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://api.spotify.com")!,
                                       statusCode: statusCode,
                                       httpVersion: nil,
                                       headerFields: nil)!
        return (data, response)
    }
}

/// Returns a bare `URLResponse` (not an `HTTPURLResponse`) — the anomalous
/// transport answer the tool must classify without reading a status.
private final class NonHTTPResponseTransport: LocalToolTransport {
    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = URLResponse(url: request.url ?? URL(string: "https://api.spotify.com")!,
                                   mimeType: nil,
                                   expectedContentLength: 0,
                                   textEncodingName: nil)
        return (Data(), response)
    }
}

/// Models URLSession's timeout enforcement at the seam: the provider "takes"
/// `simulatedDelay` seconds (a few real milliseconds here — a test never
/// waits out the 8 s budget) and, when that overruns the request's own
/// `timeoutInterval`, throws the `URLError(.timedOut)` the real stack
/// produces at its deadline. A provider within budget answers normally.
private final class DelayedProviderTransport: LocalToolTransport {
    private(set) var capturedRequests: [URLRequest] = []
    private let simulatedDelay: TimeInterval
    private let data: Data
    private let statusCode: Int

    init(simulatedDelay: TimeInterval, data: Data = Data(), statusCode: Int = 200) {
        self.simulatedDelay = simulatedDelay
        self.data = data
        self.statusCode = statusCode
    }

    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequests.append(request)
        try await Task.sleep(nanoseconds: 5_000_000)
        guard simulatedDelay <= request.timeoutInterval else {
            throw URLError(.timedOut)
        }
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://api.spotify.com")!,
                                       statusCode: statusCode,
                                       httpVersion: nil,
                                       headerFields: nil)!
        return (data, response)
    }
}
