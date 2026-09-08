import Foundation

/// [YOUTUBE] (2026-09-08) YouTube search/play tool for the voice YouTube
/// feature: deep-link construction (native `youtube://` scheme + https
/// fallbacks), the YouTube Data API v3 top-result lookup (optional API
/// key), and the app-present/absent open decisions over the
/// `CallLinkOpening` seam.
///
/// Honesty contract:
///  - With an API key configured the top search result is a REAL Data
///    API v3 hit — its video ID opens the native app (`youtube://watch`)
///    and its title is spoken once. Never a fabricated title.
///  - Any failure (timeout, network error, non-200, quota/rate-limit
///    403, empty/malformed payload) surfaces as the router's honest
///    localized fallback lines — never a guess.
///  - The app-absent decision is the honest one the call flow uses:
///    `canOpenURL` on the `youtube://` scheme (declared in
///    LSApplicationQueriesSchemes), falling back to the equivalent
///    https URL via Safari. Openers never claim a video "played" — the
///    confirmation says what actually opened.
///
/// Privacy: the Data API request carries the spoken query + the API key
/// (Google's own API — the same disclosure family as the web-search
/// tool's `searchSettings.privacy` line); no user identity. Observability
/// events carry no query text; the encrypted debug log carries the query
/// only (the title-bearing confirmation is SPOKEN ONLY and never logged —
/// see `CommandRouter.fireYouTubePlay`).
///
/// Design: a caseless enum of pure statics (house tool pattern, like
/// `WeatherTool`/`SearchTool`) with the `LocalToolTransport` network seam
/// and `CallLinkOpening` open seam — URL shape, JSON parsing, and
/// open decisions are the testable seams; no real network in tests.
enum YouTubeTool {

    /// The top video the Data API resolved for a query.
    struct TopVideoResult: Equatable {
        let videoID: String
        let title: String
    }

    /// Why `fetchTopResult` failed. The router maps every case to an
    /// honest fallback line — the distinction exists for tests,
    /// observability and the not-found vs unavailable speech, not for
    /// any fabricated fallback.
    enum FetchError: Error, Equatable {
        /// The server answered, but not with 200 OK (quota/rate-limit
        /// 403, 4xx/5xx).
        case invalidResponse(statusCode: Int)
        /// The payload decoded but held no usable video (empty result
        /// set, channel-only result, blank title).
        case noResults
        /// The payload did not decode into a search response at all.
        case malformedResponse
    }

    /// Timeout for the Data API round-trip — the same 8 s budget as the
    /// weather/search tools (long enough for a mobile link, short enough
    /// to not feel hung).
    static let fetchTimeoutSeconds: TimeInterval = 8

    // MARK: - URLs

    /// `youtube://www.youtube.com/results?search_query=<q>` — opens the
    /// NATIVE app's search screen. Built via URLComponents so the query
    /// (incl. Nepali text, `&`, spaces) percent-encodes correctly.
    static func appSearchURL(query: String) -> URL {
        var components = URLComponents()
        components.scheme = "youtube"
        components.host = "www.youtube.com"
        components.path = "/results"
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return components.url!
    }

    /// `https://www.youtube.com/results?search_query=<q>` — the
    /// app-absent fallback (Safari).
    static func webSearchURL(query: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/results"
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return components.url!
    }

    /// `youtube://watch?v=<id>` — opens the video in the native app
    /// (playback begins in-app; `autoplay=1` is not honored by the
    /// native app, so this IS the closest autoplay — platform facts
    /// 2026-09).
    static func appWatchURL(videoID: String) -> URL {
        var components = URLComponents()
        components.scheme = "youtube"
        components.host = "watch"
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return components.url!
    }

    /// `https://www.youtube.com/watch?v=<id>` — the app-absent fallback
    /// (Safari).
    static func webWatchURL(videoID: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/watch"
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return components.url!
    }

    /// YouTube Data API v3 `search.list` endpoint for ONE top video.
    /// Pure URL construction — the unit tests assert the exact
    /// query-item set (`part=snippet`, `type=video`, `maxResults=1`,
    /// `q`, `key` — nothing else). `apiKey` comes from
    /// `YouTubeConfigStore` at call time (Keychain-backed), never from
    /// code or logs.
    static func apiSearchURL(query: String, apiKey: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.path = "/youtube/v3/search"
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "maxResults", value: "1"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "key", value: apiKey)
        ]
        return components.url!
    }

    // MARK: - Parsing

    /// Wire format of the Data API search response. Everything optional:
    /// an empty result set omits `items` entirely, and a channel-ish hit
    /// can carry an id without a `videoId`.
    private struct SearchPayload: Decodable {
        struct Item: Decodable {
            struct ID: Decodable {
                let kind: String?
                let videoId: String?
            }
            struct Snippet: Decodable {
                let title: String?
            }
            let id: ID?
            let snippet: Snippet?
        }
        let items: [Item]?
    }

    /// Decodes the FIRST video hit into a usable result. Returns nil on
    /// ANY malformation (non-JSON, wrong shape), for an empty result
    /// set, and when the top hit has no `videoId` or a blank title —
    /// a title-less or ID-less hit is not a playable answer.
    static func parseSearchJSON(data: Data) -> TopVideoResult? {
        guard let payload = try? JSONDecoder().decode(SearchPayload.self, from: data) else {
            return nil
        }
        guard let top = payload.items?.first,
              let videoID = top.id?.videoId?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !videoID.isEmpty else {
            return nil
        }
        let title = collapsed(top.snippet?.title ?? "")
        guard !title.isEmpty else { return nil }
        return TopVideoResult(videoID: videoID, title: title)
    }

    /// Collapses whitespace/newline runs to single spaces — API titles
    /// carry stray newlines/HTML-ish spacing that would garble TTS.
    private static func collapsed(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    // MARK: - Fetch

    /// Fetches and parses the top video for `query` via `transport`
    /// (URLSession in production, a stub in tests). Throws `FetchError`
    /// on non-200 / empty / undecodable payloads; transport-level errors
    /// (timeout, no network) propagate as-is — the caller catches
    /// everything.
    static func fetchTopResult(query: String,
                               apiKey: String,
                               transport: LocalToolTransport = URLSession.shared) async throws -> TopVideoResult {
        var request = URLRequest(url: apiSearchURL(query: query, apiKey: apiKey))
        request.timeoutInterval = fetchTimeoutSeconds
        let (data, response) = try await transport.fetchData(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.invalidResponse(statusCode: http.statusCode)
        }
        guard (try? JSONDecoder().decode(SearchPayload.self, from: data)) != nil else {
            throw FetchError.malformedResponse
        }
        // A decoded-but-unplayable response (empty items, channel hit,
        // blank title) is the not-found outcome; the router speaks the
        // honest `youtube.notFound` line for it.
        guard let result = parseSearchJSON(data: data) else {
            throw FetchError.noResults
        }
        return result
    }

    // MARK: - Open decisions

    /// Which surface actually opened.
    enum OpenOutcome: Equatable {
        /// The native app accepted the `youtube://` link.
        case openedApp
        /// The app is absent (canOpenURL failed) — the https URL was
        /// opened via Safari instead.
        case openedWeb
    }

    /// Opens the YouTube SEARCH screen: the native `youtube://` link
    /// when the app is present, the https search URL otherwise. The
    /// canOpenURL probe is the honest installed-check (the scheme is in
    /// LSApplicationQueriesSchemes).
    static func openSearch(query: String, opener: CallLinkOpening) -> OpenOutcome {
        let appURL = appSearchURL(query: query)
        if opener.canOpenURL(appURL) {
            opener.open(appURL)
            return .openedApp
        }
        opener.open(webSearchURL(query: query))
        return .openedWeb
    }

    /// Opens the WATCH screen for a resolved video: native
    /// `youtube://watch` when present, https watch URL otherwise. The
    /// caller's spoken line stays "playing <title> on YouTube" — the
    /// open decision is observable but never reworded into a lie about
    /// autoplay.
    static func openWatch(videoID: String, opener: CallLinkOpening) -> OpenOutcome {
        let appURL = appWatchURL(videoID: videoID)
        if opener.canOpenURL(appURL) {
            opener.open(appURL)
            return .openedApp
        }
        opener.open(webWatchURL(videoID: videoID))
        return .openedWeb
    }
}

/// [YOUTUBE] (2026-09-08) Holds the YouTube Data API v3 key — a
/// deliberate mirror of `SearchConfigStore`: `EncryptedLocalStorage`
/// (Keychain, Data Protection Complete), never `UserDefaults`, never
/// hardcoded. Entered by a family member in Settings (the elderly
/// primary user is never asked to handle API keys).
///
/// The key is OPTIONAL, unlike the search tool's credential pair: a
/// single API key is the only credential the Data API needs, and
/// WITHOUT one the voice command still works — it opens the YouTube
/// search deeplink (the accepted search-only MVP).
final class YouTubeConfigStore: ObservableObject {
    private static let apiKeyStorageKey = "youtube.apiKey"

    private let storage: EncryptedLocalStorage

    @Published private(set) var apiKey: String?

    var isConfigured: Bool { apiKey != nil }

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
        self.apiKey = Self.load(key: Self.apiKeyStorageKey, storage: storage)
    }

    /// Save (whitespace-trimmed) or clear the API key. Saving empty
    /// text clears the key.
    func saveAPIKey(_ newKey: String) {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            _ = storage.delete(key: Self.apiKeyStorageKey)
            apiKey = nil
            return
        }
        _ = storage.write(key: Self.apiKeyStorageKey, value: trimmed)
        apiKey = trimmed
    }

    /// Removes the key (the Settings "remove" action) — the Data API
    /// lookup stops firing until reconfigured (the search deeplink path
    /// keeps working).
    func clear() {
        _ = storage.delete(key: Self.apiKeyStorageKey)
        apiKey = nil
    }

    private static func load(key: String, storage: EncryptedLocalStorage) -> String? {
        guard case .success(let value) = storage.read(key: key, type: String.self),
              !value.isEmpty else { return nil }
        return value
    }
}
