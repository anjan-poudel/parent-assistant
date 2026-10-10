import XCTest
import CryptoKit
@testable import ElderlyAssistant

/// `SpotifyAuthFlow` (T-109, C-SP-04): the PKCE public-client flow's pure half.
///
/// This suite is also the producer of three review obligations:
///   * evidence obligation 3 — the callback reject matrix, one NAMED assertion
///     per rejection class, each proving the delivery is refused before
///     anything is parsed (and therefore before anything could be stored);
///   * evidence obligation 8 / M-3 — the authorize request's scope set is
///     pinned by exact equality, and the read-playback scope is asserted ABSENT
///     (the trimmed set is what the Dashboard registration must carry);
///   * verification item V-3 — a provider `error=` value outside the OAuth
///     registry maps to `.malformedResponse`, never to `.providerError(code:)`,
///     and the raw provider text is never retained.
///
/// "No session record is ever written for a rejected callback" is structural
/// here rather than asserted through a fake: this type has no store to write
/// to (no storage seam, no injected storage, no mutable state at all — the
/// file is a namespace of statics over `Foundation`/`CryptoKit`), and the
/// only successful output of `parseCallback` is an authorization-code string.
/// The single writer is `SpotifyAccountSession`, on `.success` only, and its
/// own suite pins that.
///
/// Every token value in this file is an obvious synthetic literal; no real
/// credential, code or verifier appears in the suite.
final class SpotifyAuthFlowTests: XCTestCase {

    /// The nonce "minted for this attempt" in the tests.
    private let attemptState = "test-state-4f2c9a"

    // MARK: - PKCE

    func testPKCEVerifierLengthStaysInsideTheRFC7636Bounds() {
        let pair = SpotifyAuthFlow.makePKCE()
        XCTAssertGreaterThanOrEqual(pair.verifier.count, 43)
        XCTAssertLessThanOrEqual(pair.verifier.count, 128)
        // The implementation's exact choice: 32 random bytes, unpadded — the
        // RFC minimum, 256 bits of entropy. Pinned so a change is deliberate.
        XCTAssertEqual(pair.verifier.count, 43)
        XCTAssertEqual(pair.challenge.count, 43)
    }

    func testPKCEChallengeIsTheS256DigestOfTheVerifier() throws {
        // The RFC 7636 §4.6 vector: the authority for the S256 spelling,
        // independent of this implementation.
        XCTAssertEqual(SpotifyAuthFlow.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

        // And the generated pair obeys the same relation, checked against a
        // reference computed here with CryptoKit rather than by asking the
        // type under test to confirm itself.
        let pair = SpotifyAuthFlow.makePKCE()
        let digest = Data(SHA256.hash(data: Data(pair.verifier.utf8)))
        let reference = digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(pair.challenge, reference)
        XCTAssertEqual(SpotifyAuthFlow.codeChallenge(for: pair.verifier), pair.challenge)
    }

    func testPKCEIdentifiersUseOnlyTheUnpaddedBase64URLAlphabet() {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for _ in 0..<8 {
            let pair = SpotifyAuthFlow.makePKCE()
            for identifier in [pair.verifier, pair.challenge] {
                XCTAssertTrue(identifier.unicodeScalars.allSatisfy { allowed.contains($0) },
                              "unexpected character in \(identifier)")
                XCTAssertFalse(identifier.contains("="))
                XCTAssertFalse(identifier.contains("+"))
                XCTAssertFalse(identifier.contains("/"))
            }
        }
    }

    func testFreshPKCEPairsDifferOnEveryCall() {
        // A verifier reused across attempts would turn a captured callback into
        // a replayable exchange; freshness is the property, not a nicety.
        let pairs = (0..<8).map { _ in SpotifyAuthFlow.makePKCE() }
        XCTAssertEqual(Set(pairs.map(\.verifier)).count, pairs.count)
        XCTAssertEqual(Set(pairs.map(\.challenge)).count, pairs.count)
    }

    // MARK: - Authorize URL

    func testAuthorizeURLRequestsExactlyThePinnedLeastPrivilegeScopeSet() throws {
        // Evidence obligation 8 / the M-3 tripwire. The requested set, the
        // pinned constant and the Dashboard registration are ONE set; the
        // assertions below spell the set out so a change to the constant
        // cannot silently move what is asked for, and assert the read-playback
        // scope ABSENT because the security design review found it has no call
        // site anywhere in this design (M-3, least privilege).
        let pair = SpotifyAuthFlow.makePKCE()
        let url = try XCTUnwrap(SpotifyAuthFlow.authorizeURL(clientID: "client-123",
                                                             state: attemptState,
                                                             challenge: pair.challenge))
        let requested = try XCTUnwrap(queryValue("scope", in: url))
            .split(separator: " ")
            .map(String.init)

        XCTAssertEqual(SpotifyAuthFlow.scopes,
                       ["user-read-private", "user-modify-playback-state"])
        XCTAssertEqual(requested, SpotifyAuthFlow.scopes,
                       "the authorize request must ask for exactly the pinned set")
        XCTAssertEqual(requested, ["user-read-private", "user-modify-playback-state"],
                       "requested == pinned == the set the Dashboard must register")
        XCTAssertEqual(Set(requested).count, requested.count, "no duplicated scope")
        XCTAssertFalse(requested.contains("user-read-playback-state"),
                       "M-3: the scope has no call site in this design, so it is not requested; "
                       + "re-adding it is a deliberate change to the pinned constant AND the "
                       + "Dashboard registration, never a silent one")

        // Every scope must be requested at sign-in (the calendar-share
        // addScopes lesson): all of them ride on the authorize URL itself.
        XCTAssertEqual(SpotifyAuthFlow.scopes.count, 2)
    }

    func testAuthorizeURLCarriesPKCEMaterialStateAndTheCodeResponseType() throws {
        let pair = SpotifyAuthFlow.makePKCE()
        let url = try XCTUnwrap(SpotifyAuthFlow.authorizeURL(clientID: "client-123",
                                                             state: attemptState,
                                                             challenge: pair.challenge))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "accounts.spotify.com")
        XCTAssertEqual(url.path, "/authorize")
        XCTAssertEqual(queryValue("client_id", in: url), "client-123")
        XCTAssertEqual(queryValue("response_type", in: url), "code")
        XCTAssertEqual(queryValue("redirect_uri", in: url), SpotifyAuthFlow.redirectURI)
        XCTAssertEqual(queryValue("state", in: url), attemptState)
        XCTAssertEqual(queryValue("code_challenge", in: url), pair.challenge)
        XCTAssertEqual(queryValue("code_challenge_method", in: url), "S256")
    }

    func testAuthorizeURLCarriesNoClientSecretAndNoCredentialMaterial() throws {
        let pair = SpotifyAuthFlow.makePKCE()
        let url = try XCTUnwrap(SpotifyAuthFlow.authorizeURL(clientID: "client-123",
                                                             state: attemptState,
                                                             challenge: pair.challenge))
        let raw = url.absoluteString
        XCTAssertFalse(raw.contains("secret"))
        XCTAssertFalse(raw.contains("access_token"))
        XCTAssertFalse(raw.contains("refresh_token"))
        // The authorize request carries the CHALLENGE; the verifier stays in
        // the process until the exchange.
        XCTAssertNil(queryValue("code_verifier", in: url))

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertNil(components.fragment)
        XCTAssertEqual(Set((components.queryItems ?? []).map(\.name)),
                       ["client_id", "response_type", "redirect_uri", "scope",
                        "state", "code_challenge", "code_challenge_method"])
    }

    func testAuthorizeURLRefusesToBuildWithoutClientIDStateOrChallenge() {
        let pair = SpotifyAuthFlow.makePKCE()
        XCTAssertNil(SpotifyAuthFlow.authorizeURL(clientID: "", state: attemptState,
                                                  challenge: pair.challenge))
        XCTAssertNil(SpotifyAuthFlow.authorizeURL(clientID: "   ", state: attemptState,
                                                  challenge: pair.challenge))
        XCTAssertNil(SpotifyAuthFlow.authorizeURL(clientID: "client-123", state: "",
                                                  challenge: pair.challenge))
        XCTAssertNil(SpotifyAuthFlow.authorizeURL(clientID: "client-123", state: attemptState,
                                                  challenge: ""))
    }

    // MARK: - Callback accept matrix

    func testCallbackAcceptsTheExactRegisteredRedirectAndReturnsTheCode() {
        let url = URL(string: "sahayak-spotify://callback?code=AQD-test-code-1&state=\(attemptState)")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(url, expectedState: attemptState),
                       .success("AQD-test-code-1"))

        // Extra query parameters are tolerated (the provider may append its
        // own), and percent-encoded code characters decode exactly.
        let extended = URL(string:
            "sahayak-spotify://callback?code=AQD-test-code-2&state=\(attemptState)&extra=1")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(extended, expectedState: attemptState),
                       .success("AQD-test-code-2"))

        let encoded = URL(string:
            "sahayak-spotify://callback?code=AQD%2Btest%2Fcode&state=\(attemptState)")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(encoded, expectedState: attemptState),
                       .success("AQD+test/code"))
    }

    // MARK: - Callback reject matrix (evidence obligation 3)
    //
    // One named test per rejection class. Every URL below carries a valid code
    // and the live nonce wherever the class allows it, so a pass proves the
    // gate for that class fires BEFORE anything is parsed — not merely that
    // some later check happened to fail.

    func testCallbackRejectsAWrongSchemeBeforeItParsesAnything() {
        let url = URL(string:
            "sahayak-spotify-evil://callback?code=AQD-test-code-1&state=\(attemptState)")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(url, expectedState: attemptState),
                       .failure(.redirectMismatch))
    }

    func testCallbackRejectsAWrongHostBeforeItParsesAnything() {
        let url = URL(string:
            "sahayak-spotify://not-callback?code=AQD-test-code-1&state=\(attemptState)")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(url, expectedState: attemptState),
                       .failure(.redirectMismatch))
    }

    func testCallbackRejectsASchemeOrHostDifferingOnlyInCase() {
        // Case-sensitive per design §11: a differing case is a DIFFERENT
        // scheme/host, not a match.
        let upperScheme = URL(string:
            "SAHAYAK-SPOTIFY://callback?code=AQD-test-code-1&state=\(attemptState)")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(upperScheme, expectedState: attemptState),
                       .failure(.redirectMismatch))
        let upperHost = URL(string:
            "sahayak-spotify://CALLBACK?code=AQD-test-code-1&state=\(attemptState)")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(upperHost, expectedState: attemptState),
                       .failure(.redirectMismatch))
    }

    func testCallbackRejectsANonEmptyPath() {
        let url = URL(string:
            "sahayak-spotify://callback/extra?code=AQD-test-code-1&state=\(attemptState)")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(url, expectedState: attemptState),
                       .failure(.redirectMismatch))
    }

    func testCallbackRejectsAuthorityTricksThatKeepTheHost() {
        // `someone@callback` parses as host `callback` with userinfo, and
        // `callback:8080` as host `callback` with a port; both are refused so
        // the accepted URL space is exactly the registered redirect.
        let userinfo = URL(string:
            "sahayak-spotify://someone@callback?code=AQD-test-code-1&state=\(attemptState)")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(userinfo, expectedState: attemptState),
                       .failure(.redirectMismatch))
        let port = URL(string:
            "sahayak-spotify://callback:8080?code=AQD-test-code-1&state=\(attemptState)")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(port, expectedState: attemptState),
                       .failure(.redirectMismatch))
    }

    func testCallbackRejectsAFragment() {
        let url = URL(string:
            "sahayak-spotify://callback?code=AQD-test-code-1&state=\(attemptState)#frag")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(url, expectedState: attemptState),
                       .failure(.redirectMismatch))
    }

    func testCallbackRejectsAMissingState() {
        let withoutQuery = URL(string: "sahayak-spotify://callback")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(withoutQuery, expectedState: attemptState),
                       .failure(.stateMismatch))
        let withoutState = URL(string: "sahayak-spotify://callback?code=AQD-test-code-1")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(withoutState, expectedState: attemptState),
                       .failure(.stateMismatch))
    }

    func testCallbackRejectsAMismatchedState() {
        let url = URL(string:
            "sahayak-spotify://callback?code=AQD-test-code-1&state=someone-elses-state")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(url, expectedState: attemptState),
                       .failure(.stateMismatch))
    }

    func testReplayedCallbackFromAnEarlierAttemptIsRejectedWithStateMismatch() {
        // The replay class: a delivery captured from attempt ONE arrives while
        // attempt TWO is waiting. It carries attempt one's nonce, so the
        // current attempt's expected nonce does not match — and with a fresh
        // PKCE pair per attempt (see `testFreshPKCEPairsDifferOnEveryCall`)
        // there is nothing left to complete the exchange with even if it were
        // accepted.
        let captured = URL(string:
            "sahayak-spotify://callback?code=AQD-attempt-one-code&state=attempt-one-state")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(captured, expectedState: "attempt-two-state"),
                       .failure(.stateMismatch))
    }

    func testCallbackRejectsAnEmptyExpectedNonceEvenForAMatchingDelivery() {
        // A caller with no nonce in hand never accepts one: an empty
        // expectation is a bug, not a wildcard.
        let url = URL(string: "sahayak-spotify://callback?code=AQD-test-code-1&state=")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(url, expectedState: ""),
                       .failure(.stateMismatch))
    }

    func testCallbackRejectsAMissingOrEmptyCode() {
        let missing = URL(string: "sahayak-spotify://callback?state=\(attemptState)")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(missing, expectedState: attemptState),
                       .failure(.malformedResponse))
        let empty = URL(string: "sahayak-spotify://callback?code=&state=\(attemptState)")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(empty, expectedState: attemptState),
                       .failure(.malformedResponse))
    }

    func testCallbackMapsAccessDeniedToUserCancelled() {
        // The caregiver's own decision — its own outcome for the UI copy, not
        // a provider failure.
        let bare = URL(string:
            "sahayak-spotify://callback?error=access_denied&state=\(attemptState)")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(bare, expectedState: attemptState),
                       .failure(.userCancelled))
        let described = URL(string:
            "sahayak-spotify://callback?error=access_denied&error_description=denied&state=\(attemptState)")!
        XCTAssertEqual(SpotifyAuthFlow.parseCallback(described, expectedState: attemptState),
                       .failure(.userCancelled))
    }

    func testCallbackMapsEveryRegisteredProviderCodeToProviderError() {
        let providerCodes = SpotifyAuthFlow.oauthErrorRegistry.subtracting(["access_denied"])
        XCTAssertFalse(providerCodes.isEmpty, "the registry cannot be empty or this proves nothing")
        for code in providerCodes {
            let url = URL(string:
                "sahayak-spotify://callback?error=\(code)&state=\(attemptState)")!
            XCTAssertEqual(SpotifyAuthFlow.parseCallback(url, expectedState: attemptState),
                           .failure(.providerError(code: code)),
                           "registry code \(code) must keep its typed case")
        }
        XCTAssertTrue(SpotifyAuthFlow.oauthErrorRegistry.contains("access_denied"),
                      "a denial is in the registry and additionally special-cased")
    }

    func testUnknownProviderCodesMapToMalformedResponseAndNeverToProviderError() {
        // V-3, the named assertion: values outside the registry are provider
        // text this client does not understand. They are NOT carried into the
        // typed case, where a future log line or UI string could pick them up.
        let unknown = [
            "unknown_error",             // simply not a registry code
            "access-denied",             // near-miss spelling
            "INTERACTION_REQUIRED",      // a real OIDC code, not in the RFC 6749 set
            "%3Cscript%3Ealert(1)%3C%2Fscript%3E", // hostile markup, percent-encoded
        ]
        for raw in unknown {
            let url = URL(string:
                "sahayak-spotify://callback?error=\(raw)&state=\(attemptState)")!
            let result = SpotifyAuthFlow.parseCallback(url, expectedState: attemptState)
            XCTAssertEqual(result, .failure(.malformedResponse), "unknown code \(raw)")
            XCTAssertNotEqual(result, .failure(.providerError(code: raw)),
                              "V-3: unknown provider text must never enter providerError(code:)")
        }
    }

    func testRejectedCallbacksNeverRetainTheProviderErrorDescription() {
        let sentinel = "provider-body-text-that-must-not-be-retained"
        let denied = URL(string:
            "sahayak-spotify://callback?error=access_denied&error_description=\(sentinel)&state=\(attemptState)")!
        let deniedResult = SpotifyAuthFlow.parseCallback(denied, expectedState: attemptState)
        XCTAssertEqual(deniedResult, .failure(.userCancelled))
        XCTAssertFalse(String(describing: deniedResult).contains(sentinel),
                       "the provider's description must not survive into the error value")

        let unknown = URL(string:
            "sahayak-spotify://callback?error=unknown_provider_code&error_description=\(sentinel)&state=\(attemptState)")!
        let unknownResult = SpotifyAuthFlow.parseCallback(unknown, expectedState: attemptState)
        XCTAssertEqual(unknownResult, .failure(.malformedResponse))
        XCTAssertFalse(String(describing: unknownResult).contains(sentinel),
                       "the raw provider text must not survive into the error value")
    }

    func testEveryRejectedCallbackReturnsAFailureAndNeverACode() {
        // The whole reject matrix in one walk: every class yields a Failure, so
        // there is no rejected delivery whose result could be mistaken for a
        // code — and a code is the only thing `parseCallback` can return, so a
        // rejection cannot hand the session anything to store.
        let rejections: [(String, String, SpotifyAuthError)] = [
            ("opaque://callback?code=x&state=\(attemptState)", attemptState, .redirectMismatch),
            ("sahayak-spotify://evil?code=x&state=\(attemptState)", attemptState, .redirectMismatch),
            ("sahayak-spotify://callback/", attemptState, .redirectMismatch),
            ("sahayak-spotify://callback?code=x", attemptState, .stateMismatch),
            ("sahayak-spotify://callback?code=x&state=wrong", attemptState, .stateMismatch),
            ("sahayak-spotify://callback?state=\(attemptState)", attemptState, .malformedResponse),
            ("sahayak-spotify://callback?error=access_denied&state=\(attemptState)",
             attemptState, .userCancelled),
            ("sahayak-spotify://callback?error=server_error&state=\(attemptState)",
             attemptState, .providerError(code: "server_error")),
            ("sahayak-spotify://callback?error=nonsense&state=\(attemptState)",
             attemptState, .malformedResponse),
            ("sahayak-spotify://callback?code=replayed&state=attempt-one-state",
             "attempt-two-state", .stateMismatch),
        ]
        for (raw, expectedState, expectedError) in rejections {
            let result = SpotifyAuthFlow.parseCallback(URL(string: raw)!, expectedState: expectedState)
            XCTAssertEqual(result, .failure(expectedError), raw)
            if case .success = result {
                XCTFail("a rejected callback must never return a code: \(raw)")
            }
        }
    }

    // MARK: - Token endpoint requests

    func testTokenExchangeRequestIsAFormEncodedPostWithPKCEMaterialOnly() throws {
        let request = SpotifyAuthFlow.tokenExchangeRequest(code: "AQD-test-code-1",
                                                           verifier: "test-verifier-value-43-chars",
                                                           clientID: "client-123")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, SpotifyAuthFlow.tokenEndpoint)
        XCTAssertEqual(request.url?.absoluteString, "https://accounts.spotify.com/api/token")
        let requestURL = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        XCTAssertNil(components.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                       "application/x-www-form-urlencoded")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertEqual(body,
                       "grant_type=authorization_code"
                       + "&code=AQD-test-code-1"
                       + "&redirect_uri=sahayak-spotify%3A%2F%2Fcallback"
                       + "&client_id=client-123"
                       + "&code_verifier=test-verifier-value-43-chars")
    }

    func testRefreshRequestCarriesOnlyTheRefreshGrant() throws {
        let request = SpotifyAuthFlow.refreshRequest(refreshToken: "test-refresh-token-1",
                                                     clientID: "client-123")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, SpotifyAuthFlow.tokenEndpoint)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertEqual(body,
                       "grant_type=refresh_token"
                       + "&refresh_token=test-refresh-token-1"
                       + "&client_id=client-123")
    }

    func testTokenRequestsPutNoCredentialInTheURL() {
        let exchange = SpotifyAuthFlow.tokenExchangeRequest(code: "AQD-test-code-1",
                                                            verifier: "test-verifier-value-43-chars",
                                                            clientID: "client-123")
        let refresh = SpotifyAuthFlow.refreshRequest(refreshToken: "test-refresh-token-1",
                                                     clientID: "client-123")
        for request in [exchange, refresh] {
            let url = request.url!
            XCTAssertEqual(url.absoluteString, "https://accounts.spotify.com/api/token")
            XCTAssertNil(url.query, "the token endpoint is POSTed to with a body, never a query")
            XCTAssertFalse(url.absoluteString.contains("test-verifier-value-43-chars"))
            XCTAssertFalse(url.absoluteString.contains("test-refresh-token-1"))
            XCTAssertFalse(url.absoluteString.contains("AQD-test-code-1"))
        }
    }

    func testNeitherTokenRequestBodyCarriesAClientSecretOrAnAuthorizationHeader() throws {
        let exchange = SpotifyAuthFlow.tokenExchangeRequest(code: "AQD-test-code-1",
                                                            verifier: "test-verifier-value-43-chars",
                                                            clientID: "client-123")
        let refresh = SpotifyAuthFlow.refreshRequest(refreshToken: "test-refresh-token-1",
                                                     clientID: "client-123")
        for request in [exchange, refresh] {
            let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
            XCTAssertFalse(body.contains("secret"),
                           "ADR-SP-01: no client secret exists to send")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                         "a public client authenticates with PKCE, not with a header")
            XCTAssertEqual(Set((request.allHTTPHeaderFields ?? [:]).keys), ["Content-Type"])
        }
    }

    func testEveryRequestThisFlowBuildsStaysOnTheAccountsHost() {
        // NFR-SP-003: this type's half of the egress allowlist.
        let pair = SpotifyAuthFlow.makePKCE()
        let urls = [
            SpotifyAuthFlow.authorizeEndpoint,
            SpotifyAuthFlow.tokenEndpoint,
            SpotifyAuthFlow.tokenExchangeRequest(code: "c", verifier: "v", clientID: "i").url!,
            SpotifyAuthFlow.refreshRequest(refreshToken: "r", clientID: "i").url!,
            SpotifyAuthFlow.authorizeURL(clientID: "client-123", state: attemptState,
                                         challenge: pair.challenge)!,
        ]
        for url in urls {
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "accounts.spotify.com", "unexpected egress to \(url)")
        }
        XCTAssertEqual(SpotifyAuthFlow.redirectURI,
                       "\(SpotifyAuthFlow.callbackScheme)://\(SpotifyAuthFlow.callbackHost)")
    }

    // MARK: - Token response parsing

    func testTokenResponseParsesTheAuthorizationCodeShape() throws {
        let data = Data((#"{"access_token":"test-access-token-1","expires_in":3600,"#
                        + #""refresh_token":"test-refresh-token-1","#
                        + #""scope":"user-read-private user-modify-playback-state"}"#).utf8)
        let response = try XCTUnwrap(SpotifyAuthFlow.parseTokenResponse(data))
        XCTAssertEqual(response,
                       SpotifyAuthFlow.TokenResponse(
                           accessToken: "test-access-token-1",
                           refreshToken: "test-refresh-token-1",
                           expiresIn: 3600,
                           scope: "user-read-private user-modify-playback-state"))
    }

    func testTokenResponseParsesTheMinimalRefreshShape() throws {
        // A refresh may return no new refresh token and no scope; both are
        // honestly reported as "the provider sent none" rather than guessed at.
        let data = Data(#"{"access_token":"test-access-token-2","expires_in":1800}"#.utf8)
        let response = try XCTUnwrap(SpotifyAuthFlow.parseTokenResponse(data))
        XCTAssertEqual(response.accessToken, "test-access-token-2")
        XCTAssertNil(response.refreshToken)
        XCTAssertEqual(response.expiresIn, 1800)
        XCTAssertEqual(response.scope, "")
    }

    func testTokenResponseRejectsMalformedPayloads() {
        // `nil` is `.malformedResponse` to the caller: a partially understood
        // body is never accepted as a token, and nothing from it is retained.
        let malformed: [String] = [
            "",
            "not json at all",
            "[]",
            "null",
            #"{"expires_in":3600}"#,                                    // no access_token
            #"{"access_token":"","expires_in":3600}"#,                  // empty token
            #"{"access_token":123,"expires_in":3600}"#,                 // wrong type
            #"{"access_token":"T"}"#,                                   // no lifetime
            #"{"access_token":"T","expires_in":"3600"}"#,               // string lifetime
            #"{"access_token":"T","expires_in":true}"#,                 // boolean lifetime
            #"{"access_token":"T","expires_in":-1}"#,                   // negative lifetime
            #"{"access_token":"T","expires_in":3600,"refresh_token":""}"#,
            #"{"access_token":"T","expires_in":3600,"refresh_token":7}"#,
            #"{"access_token":"T","expires_in":3600,"scope":42}"#,
            #"{"access_token":"T","expires_in":3600,"scope":null}"#,
        ]
        for raw in malformed {
            XCTAssertNil(SpotifyAuthFlow.parseTokenResponse(Data(raw.utf8)),
                         "must be refused as malformed: \(raw)")
        }
    }

    func testTokenResponseIgnoresFieldsItDoesNotActOn() throws {
        let data = Data((#"{"access_token":"test-access-token-3","expires_in":900,"#
                        + #""token_type":"test","custom_field":{"nested":true}}"#).utf8)
        let response = try XCTUnwrap(SpotifyAuthFlow.parseTokenResponse(data))
        XCTAssertEqual(response.accessToken, "test-access-token-3")
        XCTAssertEqual(response.expiresIn, 900)
    }

    // MARK: - Bounds and the skew (§32, FR-SP-008)

    func testExpiryInstantAppliesTheSixtySecondSkew() {
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let response = SpotifyAuthFlow.TokenResponse(accessToken: "T",
                                                     refreshToken: nil,
                                                     expiresIn: 3600,
                                                     scope: "")
        XCTAssertEqual(SpotifyAuthFlow.defaultExpirySkewSeconds, 60)
        XCTAssertEqual(response.expiryInstant(issuedAt: issuedAt,
                                              skewSeconds: SpotifyAuthFlow.defaultExpirySkewSeconds),
                       issuedAt.addingTimeInterval(3600 - 60),
                       "a token is usable only while now < expiry - skew")
    }

    func testTheInjectedBoundsAreTheThreeHundredSecondTimeoutAndOneRefresh() throws {
        // §32: the two injected parameters the session takes, given a single
        // home here so no call site repeats a bare literal.
        XCTAssertEqual(SpotifyAuthFlow.defaultLinkFlowTimeoutSeconds, 300)
        XCTAssertEqual(SpotifyAuthFlow.maxRefreshAttemptsPerRequest, 1)

        // And the refresh builder is a single request with no retry loop of
        // its own: exactly one grant per request body, and two calls are two
        // independent requests rather than a counted sequence.
        let refresh = SpotifyAuthFlow.refreshRequest(refreshToken: "test-refresh-token-1",
                                                     clientID: "client-123")
        let body = String(decoding: try XCTUnwrap(refresh.httpBody), as: UTF8.self)
        XCTAssertEqual(body.components(separatedBy: "grant_type=").count - 1, 1)
        XCTAssertEqual(SpotifyAuthFlow.refreshRequest(refreshToken: "test-refresh-token-1",
                                                      clientID: "client-123").httpBody,
                       refresh.httpBody)
    }

    // MARK: - Error vocabulary

    func testSpotifyAuthErrorCarriesTheFifteenNamedCases() {
        // The component spec's complete vocabulary (L2-D6, §26): every failure
        // the linking path can produce has a case, and each case is distinct.
        let vocabulary: [SpotifyAuthError] = [
            .notConfigured,
            .noPresenter,
            .userCancelled,
            .redirectMismatch,
            .stateMismatch,
            .providerError(code: "invalid_scope"),
            .exchangeFailed(statusCode: 400),
            .malformedResponse,
            .verificationFailed(statusCode: 401),
            .missingScopes(granted: "user-read-private"),
            .refreshFailed(statusCode: 500),
            .revoked,
            .storageFailure(.encryptedWriteFailed),
            .networkUnavailable,
            .presentationFailed(code: -1000),
        ]
        XCTAssertEqual(vocabulary.count, 15)
        XCTAssertEqual(Set(vocabulary.map { String(describing: $0) }).count, 15)

        // Associated values distinguish their cases, and the storage case
        // carries the classification and nothing else.
        XCTAssertNotEqual(SpotifyAuthError.exchangeFailed(statusCode: 400),
                          .exchangeFailed(statusCode: 401))
        XCTAssertNotEqual(SpotifyAuthError.refreshFailed(statusCode: 500),
                          .refreshFailed(statusCode: 503))
        XCTAssertNotEqual(SpotifyAuthError.providerError(code: "invalid_scope"),
                          .providerError(code: "server_error"))
        XCTAssertNotEqual(SpotifyAuthError.storageFailure(.encryptedWriteFailed),
                          .storageFailure(.encryptedReadFailed))
        XCTAssertNotEqual(SpotifyAuthError.missingScopes(granted: "user-read-private"),
                          .missingScopes(granted: ""))
        XCTAssertNotEqual(SpotifyAuthError.presentationFailed(code: -1000),
                          .presentationFailed(code: -1001))
    }

    // MARK: - Helpers

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}
