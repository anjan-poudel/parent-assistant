import Foundation
import UIKit

// MARK: - C-SP-03: the Spotify account session (T-110)
//
// The caregiver-facing account lifecycle (design-l2 §10/§26): link(),
// unlink(), markRevoked(), validAccessToken(), status. This type owns the
// state machine; it owns NO storage and NO token path of its own beyond
// the two W1 components it composes:
//
//  - `SpotifyCredentialStore` (T-108, C-SP-02) is the one record on the
//    device — a successful link writes exactly one `spotify.session`
//    record through it, a failed link writes none, and every wipe is its
//    single-key `clear()` (FR-SP-008, FR-SP-010, NFR-SP-007).
//  - `SpotifyAuthFlow` (T-109, C-SP-04) supplies the PKCE pair, the
//    authorize URL, the exact-match callback validator and the token
//    request/response plumbing. Nothing here re-implements any of that.
//
// Egress (NFR-SP-003): the session's own transport calls reach exactly the
// two allowlisted hosts — `accounts.spotify.com` for the code exchange and
// the one bounded refresh, `api.spotify.com/v1/me` for the token
// verification / product re-check. No other host is named in this file.
//
// No remote revocation (V-1, ADR-SP-14). `unlink()` and `markRevoked()`
// are LOCAL wipes and the code says so: Spotify's documented surface has
// no third-party token-revocation endpoint (verified against
// developer.spotify.com's official OpenAPI schema — the 401 description's
// only advice for a revoked token is "You should re-authenticate the
// user" — and the refresh-tokens tutorial / the 2026-06-18 refresh-token
// -expiration blog, which direct apps to discard an `invalid_grant` token
// and re-run the sign-in flow). Nothing here attempts or claims a remote
// revoke; the wipe is the guarantee (FR-SP-010).
//
// Log discipline (NFR-SP-002). This file has no console surface at all —
// no print, no os_log, no Logger — and the one event emitter below takes
// NO metadata parameter, so a call site holding a token, an expiry or a
// provider body has nowhere to put one. `metadata` is `[:]` on every
// event, `errorCode` is a `SpotifyAuthError` case NAME only (never an
// associated value), and nothing derived from a record or a callback URL
// is ever emitted, stored or returned.
//
// Bus seam (design ambiguity, resolved): §26's initializer shows no bus
// parameter, while §10/§26 require this component to emit `spotify_link`
// and `spotify_unlink`. The least-invasive seam consistent with the
// nearest precedent (`GoogleAccountSession`) is one TRAILING, DEFAULTED
// `observabilityBus` parameter over `unwiredBus` (a file-private dropping
// sink): the §26 initializer stays callable exactly as written, unit tests
// inject a recording bus, and the production call site (T-119) passes the
// app's bus. Wiring that skips it loses this component's events and
// nothing else — see `unwiredBus`.
//
// Time (design-l2 §10, L2-D13): the expiry skew is applied EXACTLY ONCE,
// at record-write time, through `SpotifyAuthFlow.TokenResponse
// .expiryInstant(issuedAt:skewSeconds:)` (whose contract names this
// session as the caller). The stored `expiry` is therefore "the instant
// the token stops being usable", and `validAccessToken()` compares
// `Date() < record.expiry` — the same 60-second cushion §10's
// "Date() < expiry - 60 s" describes, stated against the provider's
// expiry rather than the pulled-back field. The capability-staleness
// derivation (L2-D13) reads the stored field the way §10 states it:
// because Spotify issues ~3,600-second tokens, `record.expiry - 3,600 s`
// is the last verification instant, and the opportunistic re-check runs
// when that instant is more than `capabilityStalenessSeconds` old.
@MainActor
final class SpotifyAccountSession: ObservableObject {

    // MARK: - Types (exactly §26 — the router and Settings consume these)

    /// The account's usable product. `.unknown` behaves as not
    /// remote-capable (L2-D14), so a fabricated capability is impossible.
    enum Product: Equatable { case premium, free, unknown }

    /// The state the Settings surface renders and the router reads.
    enum Status: Equatable {
        case notLinked
        case linking
        case linked(Product)
        case linkFailed(SpotifyAuthError)
    }

    /// What one `link()` attempt tells the caller. `.cancelled` is
    /// surfaced distinctly from `.failed` because a caregiver declining
    /// the sheet is not an error (L2-D7).
    enum LinkOutcome: Equatable {
        case linked(Product)
        case failed(SpotifyAuthError)
        case cancelled
    }

    // MARK: - Configuration

    /// The `Info.plist` key holding the public OAuth client id (design
    /// §19/§26; the `GIDClientID` precedent). The id is public by
    /// definition — there is no client secret anywhere (ADR-SP-01).
    private static let clientIDKey = "SpotifyClientID"

    /// The bundled client id, or nil when the key is absent/blank — the
    /// dormant state the whole feature degrades on (never a crash).
    ///
    /// `nonisolated` because §26 uses it as this type's `clientID` default
    /// argument, and default-argument expressions are evaluated outside
    /// the actor; a `Bundle.main` read is thread-safe by construction.
    nonisolated static var bundledClientID: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: clientIDKey) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The one host this session may reach besides the auth flow's token
    /// endpoint: the Web API host serving `GET /v1/me` (NFR-SP-003).
    static let profileEndpoint = URL(string: "https://api.spotify.com/v1/me")!

    /// The credential scheme for the profile request. Spelled here rather
    /// than reached for in the tool's transport file: this component's
    /// only header is assembled in one place, so the token is header-only
    /// by construction and nothing about this file moves when the tool's
    /// transport constants do.
    private static let authorizationScheme = "Bearer"

    /// Every event this component emits carries this component name
    /// (§26/§28's closed vocabulary).
    static let component = "spotify"

    // MARK: - State

    /// Where the consent sheet is presented from. Assignable after
    /// construction (the coordinator builds this in a lazy var before a
    /// window exists — the `calendarShareSession` precedent) and resolved
    /// at PRESENT time by `link()`, never captured.
    var presenter: (() -> UIViewController?)?

    /// The published state. Written only by this type, together with the
    /// store's record, so `isLinked` and routing cannot disagree (L2-R2).
    @Published private(set) var status: Status

    /// True exactly when `status` is `.linked(…)` (§26).
    var isLinked: Bool {
        if case .linked = status { return true }
        return false
    }

    /// The product the router's capability check reads (§13's
    /// `spotifyRemoteCapable`). Derived from the status — one source of
    /// truth — and `.unknown` whenever the account is not linked.
    var product: Product {
        if case .linked(let product) = status { return product }
        return .unknown
    }

    private let store: SpotifyCredentialStore
    private let flow: SpotifyAuthSession
    private let transport: LocalToolTransport
    private let clientID: String?

    /// §32's `spotify.maxRefreshAttemptsPerRequest` (default 1): the
    /// counted bound on refreshes per `validAccessToken()` request. The
    /// attempt is terminal whatever its outcome, so the shipped bound
    /// yields exactly one request and no loop (ADR-SP-13). A non-positive
    /// injected bound forbids the request entirely.
    private let refreshAttemptLimit: Int

    /// §32's `spotify.capabilityStalenessSeconds` (default 3,600): the
    /// bound on the derived product-verification age beyond which the
    /// opportunistic `/v1/me` re-check runs on the refresh path.
    private let capabilityStalenessSeconds: TimeInterval

    /// §32's `spotify.linkFlowTimeoutSeconds` (default 300): how long one
    /// interactive link attempt may stay open. Enforced here because the
    /// seam's signature (fixed by W1) carries no timeout.
    private let linkFlowTimeoutSeconds: TimeInterval

    /// The expiry skew (default 60 s), passed to the flow's
    /// `expiryInstant` when a record is written (§32).
    private let expirySkewSeconds: TimeInterval

    private let observabilityBus: ObservabilityBus

    init(store: SpotifyCredentialStore,
         flow: SpotifyAuthSession,
         transport: LocalToolTransport = URLSession.shared,
         clientID: String? = SpotifyAccountSession.bundledClientID,
         refreshAttemptLimit: Int = SpotifyAuthFlow.maxRefreshAttemptsPerRequest,
         capabilityStalenessSeconds: TimeInterval = 3600,
         linkFlowTimeoutSeconds: TimeInterval = SpotifyAuthFlow.defaultLinkFlowTimeoutSeconds,
         expirySkewSeconds: TimeInterval = SpotifyAuthFlow.defaultExpirySkewSeconds,
         observabilityBus: ObservabilityBus = SpotifyAccountSession.unwiredBus) {
        self.store = store
        self.flow = flow
        self.transport = transport
        self.clientID = clientID
        self.refreshAttemptLimit = refreshAttemptLimit
        self.capabilityStalenessSeconds = capabilityStalenessSeconds
        self.linkFlowTimeoutSeconds = linkFlowTimeoutSeconds
        self.expirySkewSeconds = expirySkewSeconds
        self.observabilityBus = observabilityBus
        // The store is the single source of truth for "is there an
        // account": a record at construction reads as linked, whatever
        // happened in the process before.
        self.status = store.record.map { .linked(Self.product(fromStored: $0.product)) } ?? .notLinked
    }

    // MARK: - link()

    /// Runs one caregiver-performed link attempt. Success writes EXACTLY
    /// ONE record; every failure writes none and leaves any previous
    /// record untouched (FR-SP-008; state machine A of §10).
    func link() async -> LinkOutcome {
        // Dormant state first: no public client id means the feature is
        // off, and nothing downstream is touched (no presenter read, no
        // flow, no network). Checked before the presenter so the most
        // fundamental missing input wins.
        guard let clientID, !clientID.isEmpty else {
            return finishLink(with: .notConfigured, outcome: "not_configured")
        }

        // Presenter resolved at present time (L2-D6): nil, or a closure
        // answering nil now, is the honest "it did not happen".
        guard let presenter, presenter() != nil else {
            return finishLink(with: .noPresenter, outcome: "no_presenter")
        }

        // A fresh PKCE pair and a fresh state nonce for THIS attempt, so a
        // callback from an earlier attempt can never complete a later one.
        let pkce = SpotifyAuthFlow.makePKCE()
        let state = Self.makeStateNonce()
        guard let authorizeURL = SpotifyAuthFlow.authorizeURL(clientID: clientID,
                                                              state: state,
                                                              challenge: pkce.challenge) else {
            // Unreachable with a non-empty client id and fresh material;
            // defensive honesty rather than presenting a URL that cannot
            // work.
            return finishLink(with: .malformedResponse, outcome: "failed")
        }

        status = .linking

        let callbackURL: URL
        switch await awaitCallback(url: authorizeURL) {
        case .callback(let url):
            callbackURL = url
        case .timedOut:
            // L2-D7: the flow's bound cancels the attempt and surfaces as
            // the cancel case — a caregiver who never got to decide is not
            // an error to report.
            return finishLink(with: .userCancelled, outcome: "cancelled")
        case .flowFailure(let error):
            return finishLink(with: error)
        }

        let code: String
        switch SpotifyAuthFlow.parseCallback(callbackURL, expectedState: state) {
        case .success(let value):
            code = value
        case .failure(let error):
            return finishLink(with: error)
        }

        // The authorization-code exchange: PKCE material only, no secret
        // (§11, ADR-SP-01).
        let exchangeRequest = SpotifyAuthFlow.tokenExchangeRequest(code: code,
                                                                   verifier: pkce.verifier,
                                                                   clientID: clientID)

        let exchangeData: Data
        do {
            let (data, response) = try await transport.fetchData(for: exchangeRequest)
            guard let http = response as? HTTPURLResponse else {
                // A non-HTTP answer is a transport anomaly, not a provider
                // verdict (the tool's own classification, §24) — and never
                // a reason to store anything.
                return finishLink(with: .networkUnavailable)
            }
            guard (200...299).contains(http.statusCode) else {
                return finishLink(with: .exchangeFailed(statusCode: http.statusCode))
            }
            exchangeData = data
        } catch {
            return finishLink(with: .networkUnavailable)
        }

        guard let token = SpotifyAuthFlow.parseTokenResponse(exchangeData) else {
            return finishLink(with: .malformedResponse)
        }

        // Scope verification (L2-D5): the grant must carry every pinned
        // scope. The check runs BEFORE the /v1/me request — it needs no
        // request (the exchange already reported the grant) and a grant
        // this app knows is insufficient must not drive egress. The
        // diagnostic carries the provider's declared scope string, which
        // is scope names only — never a credential, never logged.
        let grantedScopes = Self.grantedScopes(from: token.scope)
        guard Set(SpotifyAuthFlow.scopes).isSubset(of: grantedScopes) else {
            return finishLink(with: .missingScopes(granted: token.scope))
        }

        // The six-field record needs a refresh token: the authorization
        // -code grant always returns one, so its absence is a token
        // response this client does not accept (storing a record that can
        // never refresh would be a silent half-link).
        guard let refreshToken = token.refreshToken else {
            return finishLink(with: .malformedResponse)
        }

        // Verification (FR-SP-008): the token is trusted only after the
        // provider accepts it for a request — `GET /v1/me`, whose 2xx is
        // the truth check (the tokeninfo precedent). The profile's
        // `product` is read best-effort; an unparseable 2xx body is still
        // a verified token, with an unknown product.
        let profileProduct: String?
        switch await fetchProfile(accessToken: token.accessToken) {
        case .profile(let product):
            profileProduct = product
        case .failed(let error):
            return finishLink(with: error)
        }

        let issuedAt = Date()
        let record = SpotifySessionRecord(accessToken: token.accessToken,
                                          refreshToken: refreshToken,
                                          expiry: token.expiryInstant(issuedAt: issuedAt,
                                                                      skewSeconds: expirySkewSeconds),
                                          product: profileProduct,
                                          scope: token.scope.isEmpty ? nil : token.scope,
                                          linkedAt: issuedAt)

        switch store.save(record) {
        case .success:
            let product = Self.product(fromStored: record.product)
            status = .linked(product)
            emit(eventType: "spotify_link", outcome: "success", errorCode: nil)
            return .linked(product)
        case .failure(let error):
            // The store guarantees the previous record is untouched when
            // the write fails; the status flips only on a confirmed write.
            return finishLink(with: .storageFailure(error))
        }
    }

    // MARK: - Wipes (local only — the V-1 stance)

    /// The caregiver's unlink (FR-SP-010): delete the single record,
    /// locally. There is no remote revocation call — Spotify documents no
    /// third-party revocation endpoint, so none is attempted or claimed
    /// (ADR-SP-14). The status flips to `.notLinked` only on a CONFIRMED
    /// wipe; a failed delete surfaces its `StorageError` and the record
    /// stays visible.
    func unlink() -> Result<Void, StorageError> {
        let result = store.clear()
        switch result {
        case .success:
            status = .notLinked
            emit(eventType: "spotify_unlink", outcome: "success", errorCode: nil)
        case .failure(let error):
            emit(eventType: "spotify_unlink", outcome: "failed",
                 errorCode: Self.errorCodeName(.storageFailure(error)))
        }
        return result
    }

    /// The wipe used when the provider itself declared the grant gone:
    /// the refresh path's `invalid_grant` and the router's second-401
    /// path (§26). Identical to `unlink()` except for the reported
    /// outcome — `revoked` — so the surfaces can tell "a person removed
    /// this" from "Spotify rejected it".
    func markRevoked() -> Result<Void, StorageError> {
        let result = store.clear()
        switch result {
        case .success:
            status = .notLinked
            emit(eventType: "spotify_unlink", outcome: "revoked", errorCode: nil)
        case .failure(let error):
            emit(eventType: "spotify_unlink", outcome: "failed",
                 errorCode: Self.errorCodeName(.storageFailure(error)))
        }
        return result
    }

    // MARK: - validAccessToken()

    /// The one way a caller obtains a usable access token (state machine
    /// B, §10). Returns the current token while `Date() < record.expiry`
    /// (the stored field is already the 60-second-pulled-back instant);
    /// otherwise performs exactly one bounded refresh.
    ///
    /// Failure vocabulary, exactly §10: `invalid_grant` from the token
    /// endpoint → wipe + `.revoked`; a transport error →
    /// `.networkUnavailable`; any other non-2xx → `.refreshFailed
    /// (statusCode:)`; a store write failure → `.storageFailure`. The
    /// record is kept for every failure EXCEPT the provider's definitive
    /// rejection — only `invalid_grant` wipes.
    func validAccessToken() async -> Result<String, SpotifyAuthError> {
        guard let record = store.record else {
            // Defensive: the router asks only when the store holds a
            // record (§13's askability), so this is the "no account"
            // answer in the one case it can be reached — and `.revoked`
            // is the case whose treatment is unlinked (row 10), with no
            // wipe attempted here because there is nothing to wipe and no
            // provider verdict was obtained. No event: only a real wipe
            // emits.
            return .failure(.revoked)
        }

        // The single-application skew: compare against the stored
        // boundary directly.
        if Date() < record.expiry {
            return .success(record.accessToken)
        }

        // A linked record implies the client id existed at link time; if
        // it has since vanished (a bundle change), the refresh request
        // cannot be built honestly (PKCE refreshes carry `client_id`).
        // Nothing is attempted and nothing is wiped.
        guard let clientID, !clientID.isEmpty else {
            return .failure(.notConfigured)
        }

        // ADR-SP-13: at most `refreshAttemptLimit` attempts (default 1),
        // and every attempt is terminal — success, rejection and failure
        // all return from inside the body — so the shipped bound performs
        // exactly one request. A non-positive bound forbids the attempt.
        guard refreshAttemptLimit >= 1 else {
            return .failure(.networkUnavailable)
        }

        let request = SpotifyAuthFlow.refreshRequest(refreshToken: record.refreshToken,
                                                     clientID: clientID)
        var attemptsRemaining = refreshAttemptLimit
        while attemptsRemaining > 0 {
            attemptsRemaining -= 1

            let refreshData: Data
            do {
                let (data, response) = try await transport.fetchData(for: request)
                guard let http = response as? HTTPURLResponse else {
                    return .failure(.networkUnavailable)
                }
                guard (200...299).contains(http.statusCode) else {
                    if Self.isInvalidGrant(refreshData: data) {
                        // The provider's definitive rejection: the grant is
                        // gone, the local record is the token's only home,
                        // so it is wiped and the household is asked to link
                        // again (FR-SP-010; matrix row 10).
                        return wipeForRejection()
                    }
                    return .failure(.refreshFailed(statusCode: http.statusCode))
                }
                refreshData = data
            } catch {
                // Transport failure only: the grant was never judged, so
                // the record is KEPT (matrix row 11 — the search-failure
                // shape, never a wipe).
                return .failure(.networkUnavailable)
            }

            guard let token = SpotifyAuthFlow.parseTokenResponse(refreshData) else {
                return .failure(.malformedResponse)
            }

            // The refreshed record: the token and expiry always; the
            // refresh token retained or rotated per the response; the
            // product re-verified when the derived verification age says
            // so (best-effort — a failed re-check keeps the stored value);
            // `linkedAt` never moves.
            let now = Date()
            var updatedProduct = record.product
            if isCapabilityStale(record: record, now: now) {
                if case .profile(let fresh) = await fetchProfile(accessToken: token.accessToken),
                   let fresh {
                    updatedProduct = fresh
                }
            }

            let updated = SpotifySessionRecord(accessToken: token.accessToken,
                                               refreshToken: token.refreshToken ?? record.refreshToken,
                                               expiry: token.expiryInstant(issuedAt: now,
                                                                           skewSeconds: expirySkewSeconds),
                                               product: updatedProduct,
                                               scope: token.scope.isEmpty ? record.scope : token.scope,
                                               linkedAt: record.linkedAt)

            switch store.save(updated) {
            case .success:
                // The status carries the (possibly re-verified) product so
                // the router's capability read cannot lag the record.
                status = .linked(Self.product(fromStored: updated.product))
                return .success(token.accessToken)
            case .failure(let error):
                // Not persisted, so not handed out: the caller gets the
                // storage classification and the next request tries again.
                return .failure(.storageFailure(error))
            }
        }

        // Unreachable with the shipped bound of 1.
        return .failure(.networkUnavailable)
    }

    // MARK: - Link plumbing

    /// One interactive attempt's possible answers: the callback, the
    /// seam's typed failure, or the flow's own bound elapsing.
    private enum LinkRace {
        case callback(URL)
        case flowFailure(SpotifyAuthError)
        case timedOut
    }

    /// Runs the seam under the injected link-flow bound (L2-D7). The
    /// bound lives here because the seam's signature (fixed by T-109)
    /// carries no timeout; on expiry the seam's task is CANCELLED so a
    /// cooperative implementation can dismiss its sheet. The loser's
    /// result is never read.
    private func awaitCallback(url: URL) async -> LinkRace {
        let flow = self.flow
        let timeout = linkFlowTimeoutSeconds
        return await withTaskGroup(of: LinkRace.self) { group in
            group.addTask {
                do {
                    let callback = try await flow.authorize(url: url,
                                                            callbackURLScheme: SpotifyAuthFlow.callbackScheme)
                    return .callback(callback)
                } catch let error as SpotifyAuthError {
                    return .flowFailure(error)
                } catch {
                    // The seam contract says it throws SpotifyAuthError and
                    // nothing else; a foreign error is carried as its
                    // numeric code only, never as text.
                    return .flowFailure(.presentationFailed(code: (error as NSError).code))
                }
            }
            if timeout > 0 {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return .timedOut
                }
            }
            guard let first = await group.next() else { return .timedOut }
            group.cancelAll()
            return first
        }
    }

    /// Classifies the outcome of an attempt that did not store anything:
    /// the status becomes `.linkFailed(error)` and the event carries the
    /// matching closed outcome. `userCancelled` gets the dedicated
    /// `cancelled` outcome (and `LinkOutcome.cancelled`) so the UI can
    /// tell a decision from a failure.
    private func finishLink(with error: SpotifyAuthError,
                            outcome: String? = nil) -> LinkOutcome {
        status = .linkFailed(error)
        if error == .userCancelled {
            emit(eventType: "spotify_link", outcome: outcome ?? "cancelled",
                 errorCode: Self.errorCodeName(error))
            return .cancelled
        }
        emit(eventType: "spotify_link", outcome: outcome ?? "failed",
             errorCode: Self.errorCodeName(error))
        return .failed(error)
    }

    // MARK: - Refresh plumbing

    /// The `/v1/me` verification / product re-check. One bounded,
    /// single-shot request; the response body is read in memory only and
    /// nothing from it is retained except the `product` string (or nil).
    private enum ProfileOutcome {
        /// A 2xx: the token is verified. `product` is the provider's
        /// declared value, or nil when the body had none this client
        /// understands.
        case profile(product: String?)
        case failed(SpotifyAuthError)
    }

    private func fetchProfile(accessToken: String) async -> ProfileOutcome {
        var request = URLRequest(url: Self.profileEndpoint)
        request.httpMethod = "GET"
        request.setValue(Self.authorizationScheme + " " + accessToken,
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await transport.fetchData(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(.networkUnavailable)
            }
            guard (200...299).contains(http.statusCode) else {
                return .failed(.verificationFailed(statusCode: http.statusCode))
            }
            return .profile(product: Self.product(fromProfileBody: data))
        } catch {
            return .failed(.networkUnavailable)
        }
    }

    /// The wipe taken when the provider declared the grant gone. A
    /// successful wipe resets the status and emits `spotify_unlink` /
    /// `revoked`; a failed wipe keeps the record visible and reports the
    /// storage classification (the honest failure — the router's row-10
    /// treatment still applies to the returned `.revoked`, but the
    /// record, and the status, say what actually happened on disk).
    private func wipeForRejection() -> Result<String, SpotifyAuthError> {
        switch store.clear() {
        case .success:
            status = .notLinked
            emit(eventType: "spotify_unlink", outcome: "revoked", errorCode: nil)
            return .failure(.revoked)
        case .failure(let error):
            emit(eventType: "spotify_unlink", outcome: "failed",
                 errorCode: Self.errorCodeName(.storageFailure(error)))
            return .failure(.revoked)
        }
    }

    /// The provider's definitive rejection, recognised ONLY from a
    /// well-formed JSON body whose `error` member is exactly
    /// `invalid_grant` (RFC 6749 §5.2; Spotify's documented marker for
    /// an expired or revoked grant). Anything else — another error,
    /// unparseable text, a maintenance page — is NOT definitive and never
    /// wipes.
    private static func isInvalidGrant(refreshData: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: refreshData, options: []),
              let payload = object as? [String: Any],
              let error = payload["error"] as? String else {
            return false
        }
        return error == "invalid_grant"
    }

    /// The token lifetime the derivation assumes (§10, L2-D13: "Spotify
    /// issues ~3,600 s tokens") — a constant, because the six-field
    /// record deliberately stores no extra lifetime field.
    private static let assumedTokenLifetimeSeconds: TimeInterval = 3600

    /// L2-D13's derived verification instant, read from the stored field:
    /// the product was last verified around `expiry - 3,600 s`, and the
    /// re-check runs when that instant is more than
    /// `capabilityStalenessSeconds` old (§10). With the shipped defaults
    /// (3,600 s lifetime, 3,600 s bound) the re-check therefore runs on
    /// essentially every refresh — the risk table's "re-verify on every
    /// refresh" — while an injected bound can legitimately suppress it.
    private func isCapabilityStale(record: SpotifySessionRecord, now: Date) -> Bool {
        let verificationInstant = record.expiry.addingTimeInterval(-Self.assumedTokenLifetimeSeconds)
        return now.timeIntervalSince(verificationInstant) > capabilityStalenessSeconds
    }

    // MARK: - Value mapping (closed vocabularies only)

    /// The refresh request's non-2xx body is inspected for the one
    /// definitive error token; whitespace-tolerant because the JSON
    /// `error` member's exact bytes are the contract, not the spacing.
    static func grantedScopes(from scopeString: String) -> Set<String> {
        Set(scopeString.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }

    /// The provider's declared subscription level, reduced to the closed
    /// `Product` vocabulary. The official `product` description documents
    /// "premium", "free" and "open" — and says "open" "can be considered
    /// the same as free" — so `open` maps to `.free`; anything else
    /// (a missing field, an unknown or oddly-cased value) is `.unknown`,
    /// which the router treats exactly like `.free` (L2-D14).
    static func product(fromStored stored: String?) -> Product {
        switch stored {
        case "premium": return .premium
        case "free", "open": return .free
        default: return .unknown
        }
    }

    /// The `product` member of a `/v1/me` body, or nil when the 2xx body
    /// carries none this client understands. The body never leaves this
    /// function (NFR-SP-002).
    private static func product(fromProfileBody data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let payload = object as? [String: Any],
              let product = payload["product"] as? String,
              !product.isEmpty else {
            return nil
        }
        return product
    }

    /// A fresh 256-bit state nonce per attempt, hex-spelled so it is a
    /// plain URL-safe string. Freshness is the guarantee (a callback from
    /// an earlier attempt fails the exact-match state check); the spelling
    /// is deliberately not derived from anything recorded.
    private static func makeStateNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The `SpotifyAuthError` case NAME only — the whole of what an
    /// `errorCode` may carry. Explicit and total: associated values (a
    /// provider error's text, a status code, a storage reason) can never
    /// ride along, and a future case breaks this switch at compile time
    /// instead of falling through to a default.
    static func errorCodeName(_ error: SpotifyAuthError) -> String {
        switch error {
        case .notConfigured: return "notConfigured"
        case .noPresenter: return "noPresenter"
        case .userCancelled: return "userCancelled"
        case .redirectMismatch: return "redirectMismatch"
        case .stateMismatch: return "stateMismatch"
        case .providerError: return "providerError"
        case .exchangeFailed: return "exchangeFailed"
        case .malformedResponse: return "malformedResponse"
        case .verificationFailed: return "verificationFailed"
        case .missingScopes: return "missingScopes"
        case .refreshFailed: return "refreshFailed"
        case .revoked: return "revoked"
        case .storageFailure: return "storageFailure"
        case .networkUnavailable: return "networkUnavailable"
        case .presentationFailed: return "presentationFailed"
        }
    }

    // MARK: - Observability

    /// The single emitter. Component `spotify`, `durationMs` nil (an
    /// interactive flow's duration measures the caregiver reading
    /// Spotify's screen), `metadata: [:]` always — there is deliberately
    /// NO metadata parameter and no free-form error parameter, so a
    /// token, an expiry, a callback URL or a provider body has nowhere to
    /// go (NFR-SP-002).
    private func emit(eventType: String, outcome: String, errorCode: String?) {
        observabilityBus.emit(ObservabilityEvent(
            component: Self.component,
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: [:]
        ))
    }
}

// MARK: - Unwired sink

extension SpotifyAccountSession {
    /// The sink used when the caller supplies none.
    ///
    /// §26's initializer shows no bus parameter while §10 requires this
    /// component's events, so the bus arrives as a trailing defaulted
    /// parameter — the `GoogleAccountSession.unwiredBus` precedent. It
    /// exists so the session can be constructed before the coordinator
    /// has its bus in hand (both live in `lazy var`s) and so a test that
    /// asserts nothing about events can omit the parameter. It DROPS its
    /// events, which is why the production call site (T-119) is expected
    /// to pass the app's bus: wiring that skips it loses this component's
    /// events, and nothing else about the session.
    ///
    /// `nonisolated` for the same reason as `bundledClientID`: it is a
    /// default-argument expression. The sink is stateless and immutable.
    nonisolated static let unwiredBus: ObservabilityBus = DroppingSpotifyObservabilityBus()
}

/// File-private so it cannot collide with any other component's no-op bus
/// (the test target has one of its own) and cannot be reached from outside
/// this file's default argument.
private final class DroppingSpotifyObservabilityBus: ObservabilityBus {
    func emit(_ event: ObservabilityEvent) {}
}
