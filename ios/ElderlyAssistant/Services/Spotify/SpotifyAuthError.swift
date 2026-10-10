import Foundation

// MARK: - Spotify account-linking error vocabulary (T-109, C-SP-04, L2-D6)

/// Every way the Spotify account-linking path can fail — and the only failure
/// type it publishes (design-l2 §26, L2-D6).
///
/// The rule this enum exists for is "every failure has a case": no path in
/// `SpotifyAuthFlow` or `SpotifyAccountSession` throws an untyped error, and
/// none reports a failure across a component boundary as a bare `Error`. Each
/// case is CONTENT-FREE by construction — a numeric status, a registry code, a
/// storage reason — so an error can always be reduced to its case name for an
/// observability event (§18/§26) without a token, an authorization code, a
/// PKCE verifier, a callback URL or a raw provider body travelling with it
/// (NFR-SP-002, NFR-SP-009).
///
/// `providerError(code:)` admits ONLY codes from the OAuth error registry
/// (`SpotifyAuthFlow.oauthErrorRegistry`, verification item V-3): a provider
/// `error=` value outside that set maps to `malformedResponse` instead of
/// being carried through as free-form provider text.
enum SpotifyAuthError: Error, Equatable {

    /// No OAuth client id is in the bundle. The feature is dormant, never a
    /// crash — the `GoogleAccountSession` missing-client-id precedent.
    case notConfigured

    /// No host controller existed at present time (L2-D6). The honest answer
    /// is "it did not happen": never a crash, never a silent success.
    case noPresenter

    /// The caregiver cancelled, denied the grant, or the link flow hit its
    /// timeout (L2-D7). Not a bug and not a link failure: the household chose
    /// not to hand the account over (or never got the chance to).
    case userCancelled

    /// The callback's scheme, host, path or authority did not exactly match the
    /// registered redirect. Rejections happen BEFORE any query value is read,
    /// so a mismatched delivery can never contribute a code or a state.
    case redirectMismatch

    /// The callback carried no `state`, or one unequal to the nonce minted for
    /// this attempt — which is also how a replayed delivery from an earlier
    /// attempt is refused.
    case stateMismatch

    /// A provider `error=` value that belongs to the OAuth error registry.
    /// The associated value is a registry CONSTANT (one of the handful of
    /// fixed spellings), never free-form provider text — see
    /// `SpotifyAuthFlow.oauthErrorRegistry` and V-3.
    case providerError(code: String)

    /// The token endpoint answered a non-2xx status to the code exchange.
    case exchangeFailed(statusCode: Int)

    /// A callback or token response that validated but could not be parsed: a
    /// callback with neither a `code` nor a provider error, or a 2xx token
    /// body missing the fields a token must carry. Nothing about the raw body
    /// is retained (L2-D6).
    case malformedResponse

    /// `GET /v1/me` answered a non-2xx status: the token is not trusted for a
    /// request (FR-SP-008's "verified before first use").
    case verificationFailed(statusCode: Int)

    /// The grant came back without every scope the session needs.
    /// `granted` is the provider's DECLARED scope string — scope names only,
    /// never a credential.
    case missingScopes(granted: String)

    /// The one bounded refresh failed with a non-2xx status other than
    /// `invalid_grant`. The attempt is never repeated inside one request
    /// (ADR-SP-13).
    case refreshFailed(statusCode: Int)

    /// The provider said `invalid_grant`: the grant is gone, so the local
    /// record is wiped and the household is asked to link again.
    case revoked

    /// The encrypted store refused a read or a write. Carries the storage
    /// classification only; no record content travels with it.
    case storageFailure(StorageError)

    /// The request never reached the provider (transport error).
    case networkUnavailable

    /// The system web-auth session failed to start or to run, carrying the
    /// system's NUMERIC reason code and never its description (L2-D6).
    case presentationFailed(code: Int)
}
