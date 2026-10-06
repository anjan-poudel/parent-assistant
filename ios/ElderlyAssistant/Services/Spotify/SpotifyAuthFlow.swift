import Foundation
import CryptoKit

// MARK: - C-SP-04: the PKCE authorization-code flow (public client, no secret)

/// The Spotify account-linking flow's pure half (design-l2 §26): PKCE
/// generation, authorize-URL construction, exact-match callback validation,
/// token-exchange and refresh request bodies, and token-response parsing.
///
/// ADR-SP-01 — no client secret exists anywhere. This is an
/// authorization-code + PKCE (S256) PUBLIC client: there is no secret field
/// in the bundle, in the exchange, in the refresh or in this file's
/// vocabulary at all, so no build artifact and no log line can leak one. The
/// only per-attempt secret is the PKCE verifier, which lives for the duration
/// of one link attempt, travels in the exchange body and is then discarded.
///
/// Egress (NFR-SP-003): `accounts.spotify.com` is the only host this type can
/// reach — the authorize page and the token endpoint are both on it. The other
/// allowlisted host, `api.spotify.com`, belongs to the tool (C-SP-01), not to
/// this file.
///
/// Logging (NFR-SP-002): there is no logger, no console write and no event
/// emitter in this file — not even an injected bus. Nothing here CAN record a
/// verifier, an authorization code, a state nonce, a token or a provider body,
/// because there is nowhere to put one. Tokens built by the tool travel in the
/// request's authorization header, never in a URL.
///
/// Configuration parameters (§32) are named constants here so that no call
/// site repeats a bare literal: the link-flow timeout (300 s), the refresh
/// bound (1) and the expiry skew (60 s) are injected into
/// `SpotifyAccountSession`'s initializer from these defaults.
enum SpotifyAuthFlow {

    // MARK: - Endpoints (egress allowlist)

    /// `https://accounts.spotify.com/authorize` — the caregiver-facing consent
    /// page, opened in the system web-auth sheet (T-111's seam).
    static let authorizeEndpoint = URL(string: "https://accounts.spotify.com/authorize")!

    /// `https://accounts.spotify.com/api/token` — the code exchange and the
    /// single bounded refresh. Same host as the authorize page: the feature's
    /// second and final outbound host (NFR-SP-003).
    static let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!

    // MARK: - The redirect (one constant, three consumers)

    /// The app scheme in the registered redirect. Shared by three consumers
    /// that must never disagree (design-l2 §11, risk 1): the `Info.plist`
    /// `CFBundleURLTypes` declaration (T-111), the Spotify Dashboard
    /// registration (an owner action, OD-S2 / V-2) and the exact-match
    /// validator below. If the Dashboard refuses the scheme, the change is
    /// this constant plus the plist entry, and the validator and its tests
    /// move with them.
    static let callbackScheme = "sahayak-spotify"

    /// The registered callback host. `sahayak-spotify://callback` — any other
    /// host is refused before a single query value is read.
    static let callbackHost = "callback"

    /// The registered redirect URI, spelled exactly as it must be registered
    /// and compared.
    static let redirectURI = "sahayak-spotify://callback"

    // MARK: - Scopes (M-3: the pinned least-privilege set)

    /// The scope set requested at sign-in — and the set the Dashboard
    /// registration must carry.
    ///
    /// This is the M-3 TRIMMED set. The first design draft asked for
    /// `user-read-playback-state` as well, and the security design review's
    /// M-3 (must-fix, least privilege) found it has NO call site anywhere in
    /// this design: no device management, no playback-state read, and play
    /// success is judged from the play request's 2xx. The two remaining scopes
    /// are exactly the ones with call sites — `user-read-private` verifies the
    /// account and its product via `GET /v1/me`, and
    /// `user-modify-playback-state` starts playback.
    ///
    /// `SpotifyAuthFlowTests.testAuthorizeURLRequestsExactlyThePinnedLeastPrivilegeScopeSet`
    /// is the tripwire: it pins this list as the exact equality between what
    /// the authorize URL requests and what the Dashboard must be registered
    /// with. A later task that genuinely introduces a playback-state read must
    /// add the scope here AND re-open the registration (a scope change
    /// re-opens security review by the plan's own criterion) — the failing
    /// test is how that becomes deliberate instead of silent.
    static let scopes = [
        "user-read-private",
        "user-modify-playback-state",
    ]

    // MARK: - Injected parameters (§32)

    /// `spotify.linkFlowTimeoutSeconds` — how long one link attempt may stay
    /// open before it is cancelled and reported as `.userCancelled` (L2-D7).
    /// The session takes this as an injected parameter; the constant lives here
    /// so no call site spells `300`.
    static let defaultLinkFlowTimeoutSeconds: TimeInterval = 300

    /// `spotify.maxRefreshAttemptsPerRequest` — the refresh bound. ONE refresh
    /// per request, counted; the session never loops (ADR-SP-13, §10).
    static let maxRefreshAttemptsPerRequest = 1

    /// The expiry skew: a token is treated as usable only while
    /// `now < expiry - skew`, so a request never sets out with a token that
    /// dies in flight (§10). The session takes this as an injected parameter.
    static let defaultExpirySkewSeconds: TimeInterval = 60

    // MARK: - The OAuth error registry (V-3)

    /// The authorization-endpoint error registry (RFC 6749 §4.1.2.1) — the
    /// ONLY vocabulary admitted into `.providerError(code:)`.
    ///
    /// Verification item V-3: a provider `error=` value outside this set is
    /// provider text this client does not understand, and it maps to
    /// `.malformedResponse` rather than being carried through verbatim. A
    /// typo'd, hostile or future provider value can therefore never reach a
    /// log line, an observability field or a UI string — and the set is fixed
    /// at compile time, so the mapping is testable rather than hopeful.
    ///
    /// `access_denied` IS a member, and is additionally mapped to
    /// `.userCancelled` before this branch runs: a denial is the caregiver's
    /// decision, not a provider failure, and it gets its own outcome in the UI
    /// copy (§26).
    static let oauthErrorRegistry: Set<String> = [
        "invalid_request",
        "unauthorized_client",
        "access_denied",
        "unsupported_response_type",
        "invalid_scope",
        "server_error",
        "temporarily_unavailable",
    ]

    // MARK: - PKCE (RFC 7636)

    /// A fresh verifier/challenge pair for ONE link attempt.
    ///
    /// The verifier is 43 characters of base64url — 32 random bytes, unpadded —
    /// inside RFC 7636's 43...128 bound with 256 bits of entropy. The challenge
    /// is `BASE64URL(SHA256(ASCII(verifier)))`, the `S256` method the authorize
    /// request declares. Freshness is the point: a NEW pair is minted per
    /// attempt, so a callback from an earlier attempt can never be completed
    /// with a later exchange.
    static func makePKCE() -> (verifier: String, challenge: String) {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let verifier = base64URL(Data(bytes))
        return (verifier, codeChallenge(for: verifier))
    }

    /// The S256 challenge for a verifier: `base64url(SHA256(verifier))`,
    /// unpadded (RFC 7636 §4.2). Pure, deterministic and exposed so the pair's
    /// relation is verified against the RFC's own test vector rather than only
    /// against itself.
    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// base64url without padding: the RFC 7636 alphabet for both the verifier
    /// and the challenge (`+` to `-`, `/` to `_`, `=` dropped).
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Authorize URL

    /// The consent page URL carrying the PKCE material and the pinned scope
    /// set. `nil` means the request cannot be built honestly (an absent client
    /// id — the dormant state — or absent PKCE/state material); the caller
    /// reports that as `.notConfigured`/`.malformedResponse` rather than
    /// presenting a sheet that cannot work.
    ///
    /// The scopes go on THIS request (design-l2 §11): the calendar-share
    /// lesson was that scopes requested only on the consent screen come back
    /// missing and every later call answers 401.
    static func authorizeURL(clientID: String, state: String, challenge: String) -> URL? {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !state.isEmpty, !challenge.isEmpty else { return nil }
        guard var components = URLComponents(url: authorizeEndpoint,
                                             resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url
    }

    // MARK: - Callback validation (exact match, zero exceptions)

    /// Validates one callback delivery against the nonce minted for the
    /// attempt and returns the authorization code on `.success`.
    ///
    /// The exact match is checked FIRST, before a single query value is read
    /// (design-l2 §11): scheme, host, an EMPTY path and no authority tricks
    /// (userinfo, port, fragment) must all hold, or the answer is
    /// `.redirectMismatch` and the callback's contents are never consulted —
    /// so a hijacked app-scheme delivery cannot contribute a code or a state.
    /// The scheme comparison is case-sensitive; a delivery that differs only
    /// in case is a different scheme, not a match.
    ///
    /// The state nonce is checked for EVERY delivery, a provider error
    /// redirect included: an unsolicited callback is not evidence of anything,
    /// not even of a denial. Only then is the error vocabulary consulted, and
    /// only then the code. A callback with neither is a
    /// `.malformedResponse` — the redirect matched, so nothing else in the
    /// vocabulary would be honest.
    ///
    /// This function is pure: it writes nothing and has no state to write to.
    /// The session is the only writer, and it writes only after `.success`
    /// (FR-SP-008: a denied or cancelled authorization leaves no partial
    /// state).
    static func parseCallback(_ url: URL,
                              expectedState: String) -> Result<String, SpotifyAuthError> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.redirectMismatch)
        }
        // Exact-match gate: refuse before parsing anything.
        guard components.scheme == callbackScheme,
              components.host == callbackHost,
              components.path.isEmpty,
              (components.user ?? "").isEmpty,
              (components.password ?? "").isEmpty,
              components.port == nil,
              components.fragment == nil else {
            return .failure(.redirectMismatch)
        }

        let queryItems = components.queryItems ?? []

        // The nonce is validated for every delivery — including one that
        // claims a denial: a URL that did not come from this attempt is not
        // evidence of the caregiver's decision.
        guard !expectedState.isEmpty,
              let state = queryItems.first(where: { $0.name == "state" })?.value,
              state == expectedState else {
            return .failure(.stateMismatch)
        }

        if let providerError = queryItems.first(where: { $0.name == "error" })?.value {
            if providerError == "access_denied" {
                // The caregiver's own decision, surfaced distinctly for the
                // UI copy rather than as a provider failure.
                return .failure(.userCancelled)
            }
            guard oauthErrorRegistry.contains(providerError) else {
                // V-3: unknown provider text never enters the typed case. The
                // value is discarded here and nowhere retained.
                return .failure(.malformedResponse)
            }
            return .failure(.providerError(code: providerError))
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            return .failure(.malformedResponse)
        }
        return .success(code)
    }

    // MARK: - Token endpoint requests

    /// The authorization-code exchange. Form-encoded, PKCE material only:
    /// `grant_type`, `code`, `redirect_uri`, `client_id` and the one-attempt
    /// `code_verifier`. There is no secret field and no authorization header —
    /// the verifier IS the proof, and it is worth nothing once this request has
    /// been made.
    static func tokenExchangeRequest(code: String,
                                     verifier: String,
                                     clientID: String) -> URLRequest {
        formRequest(fields: [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", verifier),
        ])
    }

    /// The single bounded refresh: `grant_type=refresh_token` plus the stored
    /// refresh token and the public client id. The refresh token necessarily
    /// travels in the request BODY (that is the grant the endpoint defines) —
    /// never in the URL, never in a header, and the caller makes exactly one
    /// such request per need (§10, `maxRefreshAttemptsPerRequest`).
    static func refreshRequest(refreshToken: String, clientID: String) -> URLRequest {
        formRequest(fields: [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ])
    }

    /// Both token requests are POSTs to the one token endpoint with a
    /// form-encoded body and no query string at all — so no credential of any
    /// kind can appear in the URL, where a proxy, a crash report or a log
    /// would find it.
    private static func formRequest(fields: [(name: String, value: String)]) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(fields)
        return request
    }

    /// `application/x-www-form-urlencoded` with the RFC 3986 unreserved set
    /// percent-encoded and nothing else (the values here are ASCII codes,
    /// verifiers and URLs; a space never occurs, so `+` handling is not
    /// relied on).
    private static func formEncoded(_ fields: [(name: String, value: String)]) -> Data {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields.map { field -> String in
            let name = field.name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? field.name
            let value = field.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? field.value
            return "\(name)=\(value)"
        }
        .joined(separator: "&")
        return Data(body.utf8)
    }

    // MARK: - Token response

    /// A token endpoint's 2xx payload, reduced to what this app acts on.
    ///
    /// Deliberately NOT `CustomStringConvertible` and deliberately without any
    /// derived description: the value carries the token, so the only safe way
    /// to render it is never. Nothing in the app does (NFR-SP-002).
    struct TokenResponse: Equatable {
        let accessToken: String
        /// Present on an authorization-code exchange; may be absent on a
        /// refresh (Spotify keeps the existing one, in which case the stored
        /// record's token is retained by the caller).
        let refreshToken: String?
        /// Lifetime in seconds, as the provider reported it.
        let expiresIn: TimeInterval
        /// The granted scope string (`""` when the provider sent none). Kept
        /// so the session can compare the grant against the pinned set.
        let scope: String

        /// The instant this token stops being usable: `issuedAt + expiresIn`,
        /// pulled back by the skew so no request sets out with a token that
        /// dies in flight (§10). Pure arithmetic, pinned by the flow's tests;
        /// the session passes its injected `expirySkewSeconds`.
        func expiryInstant(issuedAt: Date, skewSeconds: TimeInterval) -> Date {
            issuedAt.addingTimeInterval(expiresIn - skewSeconds)
        }
    }

    /// Parses a 2xx token body. `nil` means MALFORMED — the caller reports
    /// `.malformedResponse`; a partially-understood body is never accepted,
    /// because a token with the wrong shape is not a token.
    ///
    /// Strict on purpose: `access_token` must be a non-empty string,
    /// `expires_in` a non-negative JSON number (a string-typed or boolean
    /// lifetime is a schema this client does not accept), and an optional
    /// `refresh_token`, when present, must be a non-empty string. Unknown
    /// extra fields are ignored. Nothing from the raw body is retained beyond
    /// the four fields above — in particular an error body never reaches this
    /// function, so no provider message can ride along (NFR-SP-002).
    static func parseTokenResponse(_ data: Data) -> TokenResponse? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let payload = object as? [String: Any] else {
            return nil
        }
        guard let accessToken = payload["access_token"] as? String,
              !accessToken.isEmpty else {
            return nil
        }
        guard let expiresIn = lifetime(from: payload["expires_in"]) else { return nil }

        let refreshToken: String?
        if let raw = payload["refresh_token"] {
            guard let value = raw as? String, !value.isEmpty else { return nil }
            refreshToken = value
        } else {
            refreshToken = nil
        }

        let scope: String
        if let raw = payload["scope"] {
            guard let value = raw as? String else { return nil }
            scope = value
        } else {
            scope = ""
        }

        return TokenResponse(accessToken: accessToken,
                             refreshToken: refreshToken,
                             expiresIn: expiresIn,
                             scope: scope)
    }

    /// `expires_in` must be a JSON number. `NSNumber` also covers booleans in
    /// `JSONSerialization`, so the CFBoolean type id is excluded explicitly.
    private static func lifetime(from raw: Any?) -> TimeInterval? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite, value >= 0 else { return nil }
        return value
    }
}

// MARK: - The presentation seam (implemented by T-111)

/// The one interactive step of the flow, behind a seam so the linking outcome
/// matrix is a unit test instead of a device session (design-l2 §26, the
/// `GoogleAuthFlow` precedent).
///
/// The concrete conformer is `ASWebSpotifyAuthSession` over
/// `ASWebAuthenticationSession` (T-111). It must throw `SpotifyAuthError`
/// and nothing else: `.noPresenter` when there is no controller to present
/// from, `.presentationFailed(code:)` with the system's numeric reason code
/// when the session cannot start or run, and `.userCancelled` when the
/// caregiver dismisses the sheet. The returned URL is handed straight to
/// `SpotifyAuthFlow.parseCallback` — the seam never inspects it, so the
/// exact-match validator is the only door a code can come through.
///
/// Nothing about the presented URL, the returned callback or its contents may
/// be logged by an implementation (the callback carries the authorization
/// code — NFR-SP-002).
protocol SpotifyAuthSession: AnyObject {
    @MainActor func authorize(url: URL, callbackURLScheme: String) async throws -> URL
}
