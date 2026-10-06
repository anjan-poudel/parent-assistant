import Foundation

// MARK: - SpotifyTool: search + remote-play client half (T-106, C-SP-01 §24)
//
// The Spotify Web API client half of the voice music tool (design-l2
// C-SP-01 §24; FR-SP-002/007/012, NFR-SP-001/003), mirroring `YouTubeTool`'s
// house pattern: a caseless enum of pure statics — no state, no UI, no
// logging, no retries.
//
//  - Search: one GET against `https://api.spotify.com/v1/search` with
//    `type=track`, `limit=1`, parsed into the validated top match.
//  - Play: one PUT against `https://api.spotify.com/v1/me/player/play`
//    carrying the verified `spotify:track:` URI in the JSON body, mapped to
//    a typed outcome.
//
// Every failure maps to a `FetchError` / `PlayError` case tied to the
// router's matrix rows (§13): `noResults` is row 6; every other search
// failure is row 7; every play failure is row 2 (deep-link fallback) except
// `unauthorized`, which drives the caller's single forced refresh (rows
// 10/12's unlinked treatment). The tool itself decides nothing about
// speaking, fallback or retry — and nothing here ever retries.
//
// Token seam (design §12 state machine B): the access token is an injected
// `String` parameter. Acquisition, the 60 s expiry skew and the single
// refresh belong to the session component (T-109/T-110, landing in
// parallel); this unit never reads a store, Keychain or OAuth endpoint, so
// it compiles and tests without the auth components and no second token
// path exists inside the tool.
//
// Privacy (NFR-SP-002): the token travels in the Authorization header only
// — never a URL component, a log line, an event or an error value. Provider
// bodies are classified in memory and discarded (`SpotifyTransport`); the
// parsed title is spoken-only in this feature and never logged.
//
// Egress (NFR-SP-003): every request built here goes to `api.spotify.com`
// and nowhere else (`SpotifyTransport` owns the two builders).
//
// Log discipline (design §33): this file contains no console write, ever.
enum SpotifyTool {

    // MARK: - Results

    /// The top track a search resolved for a query — exactly the fields
    /// design §24 exposes: the validated identifier and the provider's
    /// track name. Anything else in the payload (album, duration, preview
    /// URLs, artist lists) is ignored, never carried further.
    struct TrackResult: Equatable {
        /// Validated: base62, exactly 22 characters (the real Spotify
        /// track-id shape — NFR-SP-008: never trusted as delivered).
        let id: String
        /// The track name as returned, whitespace-collapsed for speech.
        /// Spoken-only: never composed into a URI, never logged
        /// (NFR-SP-002).
        let title: String
    }

    // MARK: - Errors

    /// Why a search failed. The router turns `noResults` into the honest
    /// not-found treatment (matrix row 6) and every other case into the
    /// unavailable treatment with the YouTube fallback where it can serve
    /// (row 7); the distinction is for honest speech, tests and
    /// observability — never for a fabricated fallback.
    enum FetchError: Error, Equatable {
        /// The provider answered non-2xx (incl. 401 on search — row 7
        /// treatment).
        case invalidResponse(statusCode: Int)
        /// 2xx but zero usable tracks.
        case noResults
        /// An unparseable payload, or a hit with no usable title.
        case malformedResponse
        /// An id that is absent or fails the 22-char base62 validation.
        case unusableResult
        /// The transport timed out at the request's configured budget
        /// (NFR-SP-001: the 8 s default, injected per call site).
        case timedOut
        /// Any other URL-stack failure (offline, connection loss, DNS).
        case transportUnavailable
    }

    /// Why a single remote-play attempt failed. `unauthorized` returns to
    /// the caller for the one forced refresh; every other case sends the
    /// caller to the deep-link branch (FR-SP-011) — never to a second
    /// play attempt.
    enum PlayError: Error, Equatable {
        /// Defensive: the URI's scheme is not `spotify`.
        case invalidURI
        /// 401, already at the caller's post-refresh attempt.
        case unauthorized
        /// 403 whose body carries the provider's exact premium-required
        /// reason (the honest free-tier signal).
        case premiumRequired
        /// Any other 403 (another reason, another shape, unparseable).
        case restricted
        /// 404 — no active device for the household account.
        case noActiveDevice
        /// Any other non-2xx status.
        case invalidResponse(statusCode: Int)
        /// The transport timed out at the request's configured budget.
        case timedOut
        /// Any other URL-stack failure.
        case transportUnavailable
    }

    // MARK: - Configuration (§32)

    /// Provider round-trip budget: the same 8 s as the weather/search/
    /// YouTube tools (NFR-SP-001). This is the default only — every call
    /// site passes `timeoutSeconds` explicitly or accepts this named
    /// default; no bare literal appears at any call site.
    static let defaultFetchTimeoutSeconds: TimeInterval = 8.0

    /// Spotify track identifiers are exactly 22 base62 characters.
    static let maxIdentifierLength = 22

    /// Mirrors `KeywordIntentRule.maxMusicQueryLength` (§32): empty or
    /// longer queries are never sent to the provider.
    static let maxSearchQueryLength = 100

    // MARK: - Search URL

    private static let searchQueryItemName = "q"
    private static let searchTypeItemName = "type"
    private static let searchTypeTrackValue = "track"
    private static let searchLimitItemName = "limit"
    private static let searchLimitValue = "1"
    private static let marketItemName = "market"

    /// `https://api.spotify.com/v1/search` for exactly ONE track:
    /// `q=<trimmed query>`, `type=track`, `limit=1` and nothing else —
    /// `market` is appended only when a non-empty market is given
    /// (L2-D2: search is track-only). Returns nil for an empty (after
    /// trimming) or over-cap query: nothing is constructed and no request
    /// can happen.
    static func apiSearchURL(query: String, market: String?) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxSearchQueryLength else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = SpotifyTransport.apiHost
        components.path = SpotifyTransport.searchPath
        var items = [
            URLQueryItem(name: searchQueryItemName, value: trimmed),
            URLQueryItem(name: searchTypeItemName, value: searchTypeTrackValue),
            URLQueryItem(name: searchLimitItemName, value: searchLimitValue)
        ]
        if let market, !market.isEmpty {
            items.append(URLQueryItem(name: marketItemName, value: market))
        }
        components.queryItems = items
        return components.url
    }

    /// `https://api.spotify.com/v1/me/player/play` — the one remote-play
    /// endpoint (design §24; NFR-SP-003: `api.spotify.com` only).
    static func apiPlayURL() -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = SpotifyTransport.apiHost
        components.path = SpotifyTransport.playPath
        return components.url!
    }

    // MARK: - Fetch

    /// Searches for the single best track match and returns it parsed and
    /// validated. Exactly ONE request is issued on every path — success,
    /// non-2xx, malformed payload or timeout; there is no retry anywhere
    /// (matrix rows 6/7). Throws `FetchError`; the caller maps the case to
    /// speech and the fallback.
    static func fetchTopTrack(query: String,
                              accessToken: String,
                              transport: LocalToolTransport,
                              timeoutSeconds: TimeInterval = SpotifyTool.defaultFetchTimeoutSeconds) async throws -> TrackResult {
        guard let url = apiSearchURL(query: query, market: nil) else {
            // Defensive: the extractor guarantees a non-empty, ≤100-char
            // query, so this is unreachable from the router. An empty or
            // over-cap query resolves to zero usable tracks — the honest
            // not-found classification (row 6), never a fabricated request.
            throw FetchError.noResults
        }
        let request = SpotifyTransport.searchRequest(url: url,
                                                     accessToken: accessToken,
                                                     timeoutSeconds: timeoutSeconds)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.fetchData(for: request)
        } catch {
            throw SpotifyTransport.mapSearchTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            // A non-HTTP answer is a transport anomaly, not a provider
            // verdict (row 7 treatment).
            throw FetchError.transportUnavailable
        }
        guard (200...299).contains(http.statusCode) else {
            throw FetchError.invalidResponse(statusCode: http.statusCode)
        }
        return try parseSearchJSON(data)
    }

    /// One single-shot remote-play attempt for a validated
    /// `spotify:track:` URI. A 401 returns as `.unauthorized` for the
    /// caller's one forced refresh; a 403/404/network failure returns as
    /// its typed case so the caller can fall back to the deep link
    /// immediately — with no second play attempt from this tool.
    static func playTrack(uri: URL,
                          accessToken: String,
                          transport: LocalToolTransport,
                          timeoutSeconds: TimeInterval = SpotifyTool.defaultFetchTimeoutSeconds) async throws {
        guard uri.scheme == "spotify" else {
            // Defensive (design §24): a URI produced by the tool's own
            // validated construction always carries this scheme; anything
            // else is rejected before a request exists.
            throw PlayError.invalidURI
        }
        let request = SpotifyTransport.playRequest(url: apiPlayURL(),
                                                   uri: uri,
                                                   accessToken: accessToken,
                                                   timeoutSeconds: timeoutSeconds)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.fetchData(for: request)
        } catch {
            throw SpotifyTransport.mapPlayTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PlayError.transportUnavailable
        }
        if let failure = SpotifyTransport.playError(statusCode: http.statusCode, data: data) {
            throw failure
        }
    }

    // MARK: - Parsing

    /// Wire shape of the search response, reduced to the fields this tool
    /// uses: `tracks.items[0]`'s id and name. `tracks` is required — a
    /// payload without the search envelope is malformed, not empty.
    private struct SearchPayload: Decodable {
        struct Tracks: Decodable {
            struct Item: Decodable {
                let id: String?
                let name: String?
            }
            let items: [Item]?
        }
        let tracks: Tracks
    }

    /// Decodes the first hit into a validated result. Throws the closed
    /// `FetchError`:
    ///  - `.malformedResponse`: not the search envelope, or a blank title
    ///    (an untitleable hit is not something to speak);
    ///  - `.noResults`: the envelope parsed but holds no tracks;
    ///  - `.unusableResult`: the id is absent or fails the 22-char base62
    ///    validation (NFR-SP-008 — an id is never trusted as delivered).
    static func parseSearchJSON(_ data: Data) throws -> TrackResult {
        guard let payload = try? JSONDecoder().decode(SearchPayload.self, from: data) else {
            throw FetchError.malformedResponse
        }
        guard let item = payload.tracks.items?.first else {
            throw FetchError.noResults
        }
        let title = collapsed(item.name ?? "")
        guard !title.isEmpty else {
            throw FetchError.malformedResponse
        }
        let id = (item.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSpotifyIdentifier(id) else {
            throw FetchError.unusableResult
        }
        return TrackResult(id: id, title: title)
    }

    /// `^[A-Za-z0-9]{22}$`: length exactly 22 and every scalar in
    /// [A-Za-z0-9]. Everything else — punctuation, scheme text, whitespace,
    /// control characters, non-base62 Unicode, any other length — is
    /// rejected (NFR-SP-008). This is the single identifier gate the
    /// deep-link half (T-107) shares.
    static func isSpotifyIdentifier(_ id: String) -> Bool {
        guard id.count == maxIdentifierLength else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            base62Scalars.contains(scalar)
        }
    }

    private static let base62Scalars = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    /// Collapses whitespace/newline runs to single spaces — provider
    /// titles carry stray newlines/HTML-ish spacing that would garble TTS
    /// (the `YouTubeTool.collapsed` precedent).
    private static func collapsed(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }
}
