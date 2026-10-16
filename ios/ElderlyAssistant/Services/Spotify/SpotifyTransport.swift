import Foundation

// MARK: - Spotify Web API transport plumbing (T-106, C-SP-01 §24)
//
// Transport-level concerns for the search + remote-play client half of
// `SpotifyTool` (design-l2 C-SP-01 §24, "Request hardening"): the endpoint
// vocabulary, request construction (method, bounded timeout, credential in
// the Authorization header only) and the classification of provider
// statuses and bodies into the closed `SpotifyTool.FetchError` /
// `SpotifyTool.PlayError` vocabularies. The tool itself owns no URLRequest
// details, so the request shape is a testable seam on its own.
//
// Privacy (NFR-SP-002): a provider body is inspected in memory exactly
// once — the play 403 `error.reason` probe below — and is never stored,
// logged, echoed in an error or returned to a caller. Every error this
// file produces carries a numeric status code or a closed case name, never
// query text, track text, token material or provider content.
//
// Log discipline: this file has no logging surface at all — no print, no
// event, no tool-log write. The release log-safety gate owns the sweep
// (design §33); nothing here has a legal way to reach a log sink.
//
// Egress (NFR-SP-003): the two request builders are this component's only
// network surfaces, and both target `https://api.spotify.com` — the one
// host the client half of the tool may contact. The other feature host,
// `accounts.spotify.com`, belongs to the auth components (T-109) and is
// never referenced here.
enum SpotifyTransport {

    // MARK: - Endpoint vocabulary

    /// The one Web API host this component is allowed to talk to
    /// (NFR-SP-003).
    static let apiHost = "api.spotify.com"

    /// `GET .../v1/search` for the top track (L2-D2: track-only).
    static let searchPath = "/v1/search"

    /// `PUT .../v1/me/player/play` — the one remote-play endpoint.
    static let playPath = "/v1/me/player/play"

    /// The credential scheme for the two API requests. The header value is
    /// assembled per request (`scheme + " " + token`) so the source carries
    /// no credential-shaped literal; the token itself never becomes a URL
    /// component, a log line or an error value.
    static let authorizationScheme = "Bearer"

    /// The provider's own reason code for "this account cannot start
    /// remote playback" inside a play 403 body (FR-SP-011: the free-tier
    /// degradation row is exactly a 403 with this reason). The body is read
    /// in memory only — never stored, echoed or logged (design §24).
    static let premiumRequiredReason = "PREMIUM_REQUIRED"

    // MARK: - Request construction

    /// One bounded GET for the top track. `timeoutSeconds` is the caller's
    /// injected budget (`SpotifyTool.defaultFetchTimeoutSeconds` unless a
    /// call site overrides it — §32); the credential is header-only
    /// (design §24: "no token is ever a URL component").
    static func searchRequest(url: URL,
                              accessToken: String,
                              timeoutSeconds: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        request.setValue(authorizationScheme + " " + accessToken,
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// One bounded PUT carrying the verified track URI in the JSON body
    /// (`{"uris":["<uri>"]}` — design §24). No retry is built anywhere:
    /// the caller's fallback (the deep link) replaces a second attempt
    /// (FR-SP-011 / matrix row 2).
    static func playRequest(url: URL,
                            uri: URL,
                            accessToken: String,
                            timeoutSeconds: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = timeoutSeconds
        request.setValue(authorizationScheme + " " + accessToken,
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = playBody(uri: uri)
        return request
    }

    /// `{"uris":["<absoluteString>"]}` — the exact play body of design
    /// §24. The encode is total for this shape (a `[String]`-only
    /// Codable), so it cannot fail; the value is never logged.
    private static func playBody(uri: URL) -> Data {
        try! JSONEncoder().encode(PlayBody(uris: [uri.absoluteString]))
    }

    private struct PlayBody: Encodable {
        let uris: [String]
    }

    // MARK: - Error classification

    /// Maps a transport-level search failure to the closed vocabulary:
    /// a URL-stack timeout is `.timedOut`, everything else (offline,
    /// connection loss, DNS) is `.transportUnavailable` — both matrix
    /// row 7 (search failure → honest unavailable/fallback treatment).
    static func mapSearchTransportError(_ error: Error) -> SpotifyTool.FetchError {
        isTimeout(error) ? .timedOut : .transportUnavailable
    }

    /// Same mapping for the play attempt (matrix row 2: the deep-link
    /// branch replaces the failed remote attempt).
    static func mapPlayTransportError(_ error: Error) -> SpotifyTool.PlayError {
        isTimeout(error) ? .timedOut : .transportUnavailable
    }

    /// Classifies a play status code: `nil` means 2xx (success); 401 is
    /// returned to the caller for the single-refresh dance (design §12
    /// state machine B — the tool itself never refreshes); 403 is split by
    /// the provider's own reason; 404 is the no-active-device case;
    /// everything else is the remaining-status bucket (design §24).
    static func playError(statusCode: Int, data: Data) -> SpotifyTool.PlayError? {
        switch statusCode {
        case 200...299:
            return nil
        case 401:
            return .unauthorized
        case 403:
            return classifyForbidden(data: data)
        case 404:
            return .noActiveDevice
        default:
            return .invalidResponse(statusCode: statusCode)
        }
    }

    /// The 403 split, from the provider's `error.reason` field only.
    /// Anything that is not the exact premium reason — another reason, a
    /// different shape, an unparseable or empty body — classifies as
    /// `.restricted`. The body never leaves this function (NFR-SP-002).
    static func classifyForbidden(data: Data) -> SpotifyTool.PlayError {
        guard let payload = try? JSONDecoder().decode(PlayErrorPayload.self, from: data),
              payload.error?.reason == premiumRequiredReason else {
            return .restricted
        }
        return .premiumRequired
    }

    /// Wire shape of a Spotify error body, reduced to the one field the
    /// classification reads: `{"error":{"status":403,"reason":"…"}}`.
    private struct PlayErrorPayload: Decodable {
        struct ProviderError: Decodable {
            let reason: String?
        }
        let error: ProviderError?
    }

    /// A URL-stack timeout, whether thrown as `URLError` (URLSession) or
    /// as the equivalent `NSError` bridge (a stub may throw either).
    private static func isTimeout(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }
}
