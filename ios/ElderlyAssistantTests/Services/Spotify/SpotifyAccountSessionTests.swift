import XCTest
import UIKit
@testable import ElderlyAssistant

/// Guards the Spotify account session (T-110, C-SP-03 / design-l2 §10,
/// §26): the link state machine (success writes exactly one record; every
/// failure writes none), the single bounded refresh with the 60-second
/// expiry skew and the product re-check on the refresh path, and the
/// local-only wipes (V-1: no remote revocation call exists to make).
///
/// The doubles are the W1 fakes this feature already owns — a recording
/// `EncryptedLocalStorage` (`SpotifyInMemoryStorage`, shared with the
/// credential-store suite) and the shared `RecordingObservabilityBus` —
/// plus a scripted `SpotifyAuthSession` seam and a scripted
/// `LocalToolTransport`. Every load-bearing test asserts call COUNTS and
/// STORED STATE (the definition of done's refresh-bound and wipe-path
/// requirement), not just return values: the storage's raw payloads are
/// compared byte-for-byte across failures, and the transport's captured
/// requests are counted per endpoint kind.
final class SpotifyAccountSessionTests: XCTestCase {

    // MARK: - Fixture

    /// One session over one fake world, with every knob a test needs.
    @MainActor
    private final class Fixture {
        let storage: SpotifyInMemoryStorage
        let store: SpotifyCredentialStore
        let flow: FakeSpotifyAuthSession
        let transport: StubAccountTransport
        let bus: RecordingObservabilityBus
        let session: SpotifyAccountSession

        init(preLinkedRecord: SpotifySessionRecord? = nil,
             clientID: String? = "client-test-1",
             presenter: (() -> UIViewController?)? = { UIViewController() },
             refreshAttemptLimit: Int = 1,
             capabilityStalenessSeconds: TimeInterval = 3600,
             linkFlowTimeoutSeconds: TimeInterval = 300,
             expirySkewSeconds: TimeInterval = 60) {
            // All local work first — the store's seeding and the session's
            // construction — then the property assignments.
            let storage = SpotifyInMemoryStorage()
            let store = SpotifyCredentialStore(storage: storage)
            if let preLinkedRecord {
                store.save(preLinkedRecord)
            }
            let flow = FakeSpotifyAuthSession()
            let transport = StubAccountTransport()
            let bus = RecordingObservabilityBus()
            let session = SpotifyAccountSession(store: store,
                                                flow: flow,
                                                transport: transport,
                                                clientID: clientID,
                                                refreshAttemptLimit: refreshAttemptLimit,
                                                capabilityStalenessSeconds: capabilityStalenessSeconds,
                                                linkFlowTimeoutSeconds: linkFlowTimeoutSeconds,
                                                expirySkewSeconds: expirySkewSeconds,
                                                observabilityBus: bus)
            session.presenter = presenter
            self.storage = storage
            self.store = store
            self.flow = flow
            self.transport = transport
            self.bus = bus
            self.session = session
        }

        /// The stored payload snapshot a failure path must not disturb.
        var storedSnapshot: [String: Data] { storage.rawPayloads }
    }

    // MARK: - Values

    private let pinnedScope = "user-read-private user-modify-playback-state"
    private let staleAccessToken = "stored-access-fixture-001"
    private let staleRefreshToken = "stored-refresh-fixture-001"

    /// Deterministic by design: the default expiry is a FIXED future
    /// instant (not `Date()`), so two `makeRecord()` calls are equal and
    /// whole-record equality assertions are stable.
    private func makeRecord(accessToken: String? = nil,
                            refreshToken: String? = nil,
                            expiry: Date = Date(timeIntervalSince1970: 1_800_003_600),
                            product: String? = "premium",
                            scope: String? = nil,
                            linkedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> SpotifySessionRecord {
        SpotifySessionRecord(accessToken: accessToken ?? staleAccessToken,
                             refreshToken: refreshToken ?? staleRefreshToken,
                             expiry: expiry,
                             product: product,
                             scope: scope ?? pinnedScope,
                             linkedAt: linkedAt)
    }

    private static func tokenBody(access: String,
                                  refresh: String?,
                                  expiresIn: TimeInterval = 3600,
                                  scope: String = "user-read-private user-modify-playback-state") -> Data {
        var payload: [String: Any] = [
            "access_token": access,
            "token_type": "Bearer",
            "expires_in": expiresIn,
            "scope": scope,
        ]
        if let refresh {
            payload["refresh_token"] = refresh
        }
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Gherkin 1: a successful link stores one record and reports linked

    @MainActor
    func testSuccessfulLinkStoresExactlyOneRecordAndReportsLinkedWithAFreshCapabilityTimestamp() async {
        let fixture = Fixture()
        fixture.transport.exchangeReply = .body(Self.tokenBody(access: "fresh-access-1",
                                                               refresh: "fresh-refresh-1"), 200)
        fixture.transport.profileReply = .body(Data(#"{"product":"premium","id":"caregiver"}"#.utf8), 200)

        let before = Date()
        let outcome = await fixture.session.link()
        let after = Date()

        // The reported state.
        XCTAssertEqual(outcome, .linked(.premium))
        XCTAssertEqual(fixture.session.status, .linked(.premium))
        XCTAssertEqual(fixture.session.product, .premium)
        XCTAssertTrue(fixture.session.isLinked)

        // "Exactly one record": one key, one write, every field from the
        // exchange and the verification — never a second persistence path.
        XCTAssertEqual(fixture.storage.rawPayloads.count, 1)
        XCTAssertEqual(fixture.storage.writtenKeys, [SpotifyCredentialStore.storageKey])
        let record = try! XCTUnwrap(fixture.store.record)
        XCTAssertEqual(record.accessToken, "fresh-access-1")
        XCTAssertEqual(record.refreshToken, "fresh-refresh-1")
        XCTAssertEqual(record.product, "premium")
        XCTAssertEqual(record.scope, pinnedScope)

        // "A fresh capability timestamp": the expiry is this attempt's
        // issued-at plus one lifetime minus the 60-second skew, and the
        // link instant is this attempt's.
        XCTAssertGreaterThanOrEqual(record.expiry, before.addingTimeInterval(3600 - 60))
        XCTAssertLessThanOrEqual(record.expiry, after.addingTimeInterval(3600 - 60))
        XCTAssertGreaterThanOrEqual(record.linkedAt, before)
        XCTAssertLessThanOrEqual(record.linkedAt, after)

        // The attempt's request sequence: one consent URL, one exchange,
        // one verification — and the token never in a URL (header-only).
        XCTAssertEqual(fixture.flow.authorizeCalls, 1)
        XCTAssertEqual(fixture.transport.exchangeRequests.count, 1)
        XCTAssertEqual(fixture.transport.profileRequests.count, 1)
        XCTAssertEqual(fixture.transport.requests.count, 2)
        let authorizeURL = try! XCTUnwrap(fixture.flow.lastAuthorizeURL)
        XCTAssertTrue(authorizeURL.absoluteString.contains("user-read-private"))
        XCTAssertTrue(authorizeURL.absoluteString.contains("code_challenge_method=S256"))
        let profileRequest = fixture.transport.profileRequests[0]
        XCTAssertEqual(profileRequest.httpMethod, "GET")
        XCTAssertEqual(profileRequest.value(forHTTPHeaderField: "Authorization"),
                       "Bearer fresh-access-1")
        for request in fixture.transport.requests {
            XCTAssertFalse(request.url?.absoluteString.contains("fresh-access-1") ?? true)
            XCTAssertNil(request.url?.query)
        }

        // One event, closed vocabulary, empty metadata.
        XCTAssertEqual(fixture.bus.events.count, 1)
        let event = fixture.bus.events[0]
        XCTAssertEqual(event.component, "spotify")
        XCTAssertEqual(event.eventType, "spotify_link")
        XCTAssertEqual(event.outcome, "success")
        XCTAssertNil(event.errorCode)
        XCTAssertEqual(event.metadata, [:])
        XCTAssertNil(event.durationMs)
    }

    @MainActor
    func testALinkedRecordOnDiskDrivesTheLinkedStatusAtConstruction() {
        let fixture = Fixture(preLinkedRecord: makeRecord(product: "premium"))
        XCTAssertEqual(fixture.session.status, .linked(.premium))
        XCTAssertEqual(fixture.session.product, .premium)
        XCTAssertTrue(fixture.session.isLinked)
    }

    @MainActor
    func testConstructionMapsTheStoredProductIntoTheClosedVocabulary() {
        // The official `product` description documents "premium", "free"
        // and "open" (and says "open" "can be considered the same as
        // free"); anything else is `.unknown`, which the router treats
        // exactly like `.free` (L2-D14). Data-driven so each mapping is
        // its own assertion.
        let cases: [(String?, SpotifyAccountSession.Product)] = [
            ("premium", .premium),
            ("free", .free),
            ("open", .free),
            ("something-new", .unknown),
            (nil, .unknown),
        ]
        for (stored, expected) in cases {
            let fixture = Fixture(preLinkedRecord: makeRecord(product: stored))
            XCTAssertEqual(fixture.session.product, expected,
                           "stored product \(stored ?? "nil") must map to \(expected)")
        }
    }

    @MainActor
    func testSessionConstructsWithTheExactDesignInitializerShape() {
        // §26: store + flow are the two required arguments; everything
        // else carries an injected default. This construction is the pin.
        let session = SpotifyAccountSession(store: SpotifyCredentialStore(storage: SpotifyInMemoryStorage()),
                                            flow: FakeSpotifyAuthSession())
        XCTAssertEqual(session.status, .notLinked)
        XCTAssertFalse(session.isLinked)
        XCTAssertEqual(session.product, .unknown)
    }

    // MARK: - Gherkin 2: every link failure stores nothing

    @MainActor
    func testCancelledLinkStoresNothingAndLeavesThePreviousRecordUnchanged() async {
        let fixture = Fixture(preLinkedRecord: makeRecord())
        let snapshot = fixture.storedSnapshot
        fixture.flow.script = { _ in throw SpotifyAuthError.userCancelled }

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(fixture.session.status, .linkFailed(.userCancelled))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        XCTAssertEqual(fixture.store.record, makeRecord())
        XCTAssertEqual(fixture.storage.writtenKeys, [SpotifyCredentialStore.storageKey])
        XCTAssertEqual(fixture.bus.events.last?.outcome, "cancelled")
        XCTAssertEqual(fixture.bus.events.last?.errorCode, "userCancelled")
    }

    @MainActor
    func testFlowTimeoutCancelsTheAttemptAndStoresNothing() async {
        // L2-D7: the injected 300-second bound, shrunk to a testable
        // value; the seam "stays open" far past it.
        let fixture = Fixture(preLinkedRecord: makeRecord(),
                              linkFlowTimeoutSeconds: 0.05)
        let snapshot = fixture.storedSnapshot
        fixture.flow.delay = 0.5

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(fixture.session.status, .linkFailed(.userCancelled))
        XCTAssertEqual(fixture.flow.authorizeCalls, 1, "the seam was started exactly once")
        XCTAssertTrue(fixture.flow.wasCancelled, "the timed-out seam task is cancelled")
        XCTAssertEqual(fixture.transport.requests.count, 0, "no exchange ran after the timeout")
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        XCTAssertEqual(fixture.bus.events.count, 1)
        XCTAssertEqual(fixture.bus.events[0].outcome, "cancelled")
    }

    @MainActor
    func testAccessDeniedCallbackIsReportedAsCancelledAndStoresNothing() async {
        let fixture = Fixture()
        fixture.flow.script = { url in
            Self.callback(replacing: url, items: [URLQueryItem(name: "error", value: "access_denied")])
        }

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(fixture.session.status, .linkFailed(.userCancelled))
        XCTAssertEqual(fixture.storage.rawPayloads.count, 0)
        XCTAssertEqual(fixture.transport.requests.count, 0)
        XCTAssertEqual(fixture.bus.events[0].outcome, "cancelled")
    }

    @MainActor
    func testPresentationFailureStoresNothingAndReportsTheCaseNameOnly() async {
        let fixture = Fixture()
        fixture.flow.script = { _ in
            throw NSError(domain: "com.apple.AuthenticationServices.WebAuthenticationSession",
                          code: 7)
        }

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .failed(.presentationFailed(code: 7)))
        XCTAssertEqual(fixture.session.status, .linkFailed(.presentationFailed(code: 7)))
        XCTAssertEqual(fixture.storage.rawPayloads.count, 0)
        let event = fixture.bus.events[0]
        XCTAssertEqual(event.outcome, "failed")
        XCTAssertEqual(event.errorCode, "presentationFailed",
                       "the case name only — the numeric code never rides along")
        XCTAssertFalse(event.errorCode?.contains("7") ?? true)
    }

    @MainActor
    func testNoPresenterStoresNothingAndNeverStartsTheFlow() async {
        let fixture = Fixture(presenter: nil)

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .failed(.noPresenter))
        XCTAssertEqual(fixture.session.status, .linkFailed(.noPresenter))
        XCTAssertEqual(fixture.flow.authorizeCalls, 0)
        XCTAssertEqual(fixture.transport.requests.count, 0)
        XCTAssertEqual(fixture.storage.rawPayloads.count, 0)
        XCTAssertEqual(fixture.bus.events[0].outcome, "no_presenter")
        XCTAssertEqual(fixture.bus.events[0].errorCode, "noPresenter")
    }

    @MainActor
    func testNotConfiguredIsDormantAndTouchesNeitherFlowNorTransport() async {
        let fixture = Fixture(clientID: nil, presenter: nil)

        let outcome = await fixture.session.link()

        // §10: the dormant state — no crash, no sheet, no request.
        XCTAssertEqual(outcome, .failed(.notConfigured))
        XCTAssertEqual(fixture.session.status, .linkFailed(.notConfigured))
        XCTAssertEqual(fixture.flow.authorizeCalls, 0)
        XCTAssertEqual(fixture.transport.requests.count, 0)
        XCTAssertEqual(fixture.storage.rawPayloads.count, 0)
        XCTAssertEqual(fixture.bus.events[0].outcome, "not_configured")
        XCTAssertEqual(fixture.bus.events[0].errorCode, "notConfigured")
    }

    @MainActor
    func testProviderErrorCallbackStoresNothingAndReportsTheCaseNameOnly() async {
        let fixture = Fixture(preLinkedRecord: makeRecord())
        let snapshot = fixture.storedSnapshot
        fixture.flow.script = { url in
            Self.callback(replacing: url, items: [URLQueryItem(name: "error", value: "invalid_scope")])
        }

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .failed(.providerError(code: "invalid_scope")))
        XCTAssertEqual(fixture.session.status, .linkFailed(.providerError(code: "invalid_scope")))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        XCTAssertEqual(fixture.transport.requests.count, 0)
        let event = fixture.bus.events[0]
        XCTAssertEqual(event.outcome, "failed")
        XCTAssertEqual(event.errorCode, "providerError",
                       "the case name only — the registry code never rides along")
        XCTAssertFalse(event.errorCode?.contains("invalid_scope") ?? true)
    }

    @MainActor
    func testRedirectMismatchStoresNothing() async {
        let fixture = Fixture(preLinkedRecord: makeRecord())
        let snapshot = fixture.storedSnapshot
        fixture.flow.script = { url in
            // Same query, the wrong scheme: the exact-match gate refuses
            // before reading any query value.
            var components = URLComponents(url: Self.callback(replacing: url), resolvingAgainstBaseURL: false)!
            components.scheme = "not-sahayak"
            return components.url!
        }

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .failed(.redirectMismatch))
        XCTAssertEqual(fixture.session.status, .linkFailed(.redirectMismatch))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        XCTAssertEqual(fixture.bus.events[0].errorCode, "redirectMismatch")
    }

    @MainActor
    func testStateMismatchStoresNothing() async {
        let fixture = Fixture(preLinkedRecord: makeRecord())
        let snapshot = fixture.storedSnapshot
        fixture.flow.script = { url in
            Self.callback(replacing: url, stateOverride: "a-nonce-from-another-attempt")
        }

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .failed(.stateMismatch))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        XCTAssertEqual(fixture.bus.events[0].errorCode, "stateMismatch")
    }

    @MainActor
    func testExchangeNon2xxStoresNothing() async {
        let fixture = Fixture(preLinkedRecord: makeRecord())
        let snapshot = fixture.storedSnapshot
        fixture.transport.exchangeReply = .body(Data(#"{"error":"invalid_grant"}"#.utf8), 400)

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .failed(.exchangeFailed(statusCode: 400)))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        XCTAssertEqual(fixture.transport.exchangeRequests.count, 1)
        XCTAssertEqual(fixture.transport.profileRequests.count, 0,
                       "a failed exchange never reaches verification")
        XCTAssertEqual(fixture.bus.events[0].errorCode, "exchangeFailed")
    }

    @MainActor
    func testExchangeTransportFailureStoresNothing() async {
        let fixture = Fixture(preLinkedRecord: makeRecord())
        let snapshot = fixture.storedSnapshot
        fixture.transport.exchangeReply = .failure(URLError(.notConnectedToInternet))

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .failed(.networkUnavailable))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        XCTAssertEqual(fixture.bus.events[0].errorCode, "networkUnavailable")
    }

    @MainActor
    func testNonHTTPAnswerAtExchangeStoresNothing() async {
        let fixture = Fixture(preLinkedRecord: makeRecord())
        let snapshot = fixture.storedSnapshot
        fixture.transport.exchangeReply = .nonHTTP(Data())

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .failed(.networkUnavailable))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
    }

    @MainActor
    func testMalformedTokenBodyStoresNothing() async {
        let fixture = Fixture(preLinkedRecord: makeRecord())
        let snapshot = fixture.storedSnapshot
        fixture.transport.exchangeReply = .body(Data(#"{"token_type":"Bearer"}"#.utf8), 200)

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .failed(.malformedResponse))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        XCTAssertEqual(fixture.storage.writtenKeys, [SpotifyCredentialStore.storageKey],
                       "only the seeded record's write exists")
    }

    @MainActor
    func testMissingRefreshTokenInTheExchangeStoresNothing() async {
        // The six-field record needs a refresh token; a response without
        // one cannot build a record that could ever refresh.
        let fixture = Fixture(preLinkedRecord: makeRecord())
        let snapshot = fixture.storedSnapshot
        fixture.transport.exchangeReply = .body(Self.tokenBody(access: "a", refresh: nil), 200)

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .failed(.malformedResponse))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
    }

    @MainActor
    func testMissingScopesStoresNothingAndSkipsTheProfileRequest() async {
        let fixture = Fixture(preLinkedRecord: makeRecord())
        let snapshot = fixture.storedSnapshot
        fixture.transport.exchangeReply = .body(
            Self.tokenBody(access: "a", refresh: "r", scope: "user-read-private"), 200)

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .failed(.missingScopes(granted: "user-read-private")))
        XCTAssertEqual(fixture.session.status, .linkFailed(.missingScopes(granted: "user-read-private")))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        XCTAssertEqual(fixture.transport.exchangeRequests.count, 1)
        XCTAssertEqual(fixture.transport.profileRequests.count, 0,
                       "a grant this app knows is insufficient does not drive egress")
        let event = fixture.bus.events[0]
        XCTAssertEqual(event.errorCode, "missingScopes")
        XCTAssertFalse(event.errorCode?.contains("user-read-private") ?? true)
    }

    @MainActor
    func testVerificationNon2xxStoresNothing() async {
        let fixture = Fixture(preLinkedRecord: makeRecord())
        let snapshot = fixture.storedSnapshot
        fixture.transport.exchangeReply = .body(Self.tokenBody(access: "a", refresh: "r"), 200)
        fixture.transport.profileReply = .body(Data(), 403)

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .failed(.verificationFailed(statusCode: 403)))
        XCTAssertEqual(fixture.session.status, .linkFailed(.verificationFailed(statusCode: 403)))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        XCTAssertEqual(fixture.bus.events[0].errorCode, "verificationFailed")
    }

    @MainActor
    func testVerificationTransportFailureStoresNothing() async {
        let fixture = Fixture(preLinkedRecord: makeRecord())
        let snapshot = fixture.storedSnapshot
        fixture.transport.exchangeReply = .body(Self.tokenBody(access: "a", refresh: "r"), 200)
        fixture.transport.profileReply = .failure(URLError(.timedOut))

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .failed(.networkUnavailable))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
    }

    @MainActor
    func testUnparseableProfileBodyStillVerifiesWithAnUnknownProduct() async {
        // The tokeninfo precedent: the 2xx IS the truth check; an
        // unparseable body leaves the product unknown, never a failure.
        let fixture = Fixture()
        fixture.transport.exchangeReply = .body(Self.tokenBody(access: "a", refresh: "r"), 200)
        fixture.transport.profileReply = .body(Data("not json".utf8), 200)

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .linked(.unknown))
        XCTAssertEqual(fixture.store.record?.product, nil)
    }

    @MainActor
    func testStorageWriteFailureLeavesThePreviousRecordAndReportsStorageFailure() async {
        let fixture = Fixture(preLinkedRecord: makeRecord())
        fixture.storage.failWrites = true
        let snapshot = fixture.storedSnapshot
        fixture.transport.exchangeReply = .body(Self.tokenBody(access: "a", refresh: "r"), 200)
        fixture.transport.profileReply = .body(Data(#"{"product":"premium"}"#.utf8), 200)

        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .failed(.storageFailure(.encryptedWriteFailed)))
        XCTAssertEqual(fixture.session.status, .linkFailed(.storageFailure(.encryptedWriteFailed)))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        XCTAssertEqual(fixture.store.record, makeRecord())
        XCTAssertEqual(fixture.bus.events[0].outcome, "failed")
        XCTAssertEqual(fixture.bus.events[0].errorCode, "storageFailure")
    }

    @MainActor
    func testFailedReLinkAfterASuccessfulLinkLeavesTheStoredRecordUnchanged() async {
        // A previous record from an earlier link attempt is "any previous
        // record" too.
        let fixture = Fixture()
        fixture.transport.exchangeReply = .body(Self.tokenBody(access: "first-access",
                                                               refresh: "first-refresh"), 200)
        fixture.transport.profileReply = .body(Data(#"{"product":"premium"}"#.utf8), 200)
        _ = await fixture.session.link()
        let snapshot = fixture.storedSnapshot
        let linked = fixture.store.record

        fixture.flow.script = { _ in throw SpotifyAuthError.userCancelled }
        let outcome = await fixture.session.link()

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        XCTAssertEqual(fixture.store.record, linked)
        XCTAssertEqual(fixture.storage.rawPayloads.count, 1)
    }

    // MARK: - Gherkin 3: one refresh attempt, wipe only on rejection

    @MainActor
    func testValidAccessTokenWithinTheExpiryWindowMakesNoRequest() async {
        let fixture = Fixture(preLinkedRecord: makeRecord(expiry: Date().addingTimeInterval(300)))

        let result = await fixture.session.validAccessToken()

        XCTAssertEqual(result, .success(staleAccessToken))
        XCTAssertEqual(fixture.transport.requests.count, 0,
                       "a token inside the window is used with zero egress")
        XCTAssertEqual(fixture.bus.events.count, 0)
        XCTAssertEqual(fixture.storage.rawPayloads.count, 1)
    }

    @MainActor
    func testExpiredTokenRefreshesExactlyOnceAndPersistsTheRefreshedRecord() async {
        let fixture = Fixture(preLinkedRecord: makeRecord(expiry: Date().addingTimeInterval(-5)))
        fixture.transport.refreshReply = .body(Self.tokenBody(access: "rotated-access",
                                                              refresh: "rotated-refresh"), 200)
        fixture.transport.profileReply = .body(Data(#"{"product":"free"}"#.utf8), 200)

        let before = Date()
        let result = await fixture.session.validAccessToken()
        let after = Date()

        XCTAssertEqual(result, .success("rotated-access"))
        // Exactly one refresh attempt — counted at the transport.
        XCTAssertEqual(fixture.transport.refreshRequests.count, 1)
        XCTAssertEqual(fixture.transport.exchangeRequests.count, 0)
        // The refreshed record: rotated token, retained-or-rotated refresh
        // token, fresh expiry, untouched linkedAt; exactly one key still.
        let record = try! XCTUnwrap(fixture.store.record)
        XCTAssertEqual(record.accessToken, "rotated-access")
        XCTAssertEqual(record.refreshToken, "rotated-refresh")
        XCTAssertEqual(record.linkedAt, makeRecord().linkedAt)
        XCTAssertGreaterThanOrEqual(record.expiry, before.addingTimeInterval(3600 - 60))
        XCTAssertLessThanOrEqual(record.expiry, after.addingTimeInterval(3600 - 60))
        XCTAssertEqual(fixture.storage.rawPayloads.count, 1)
        XCTAssertEqual(fixture.session.status, .linked(.free),
                       "the re-verified product reaches the status the router reads")
        XCTAssertEqual(fixture.bus.events.count, 0, "no event on the refresh path")
    }

    @MainActor
    func testRefreshRetainsTheStoredRefreshTokenWhenTheResponseOmitsOne() async {
        let fixture = Fixture(preLinkedRecord: makeRecord(expiry: Date().addingTimeInterval(-5)))
        fixture.transport.refreshReply = .body(Self.tokenBody(access: "rotated-access", refresh: nil), 200)

        let result = await fixture.session.validAccessToken()

        XCTAssertEqual(result, .success("rotated-access"))
        XCTAssertEqual(fixture.store.record?.refreshToken, staleRefreshToken,
                       "retained or rotated per the response — absent means retained")
    }

    @MainActor
    func testRefreshTransportFailureKeepsTheRecordAndReportsNetworkUnavailable() async {
        let fixture = Fixture(preLinkedRecord: makeRecord(expiry: Date().addingTimeInterval(-5)))
        let snapshot = fixture.storedSnapshot
        fixture.transport.refreshReply = .failure(URLError(.networkConnectionLost))

        let result = await fixture.session.validAccessToken()

        // Matrix row 11: the search-failure shape — the record survives.
        XCTAssertEqual(result, .failure(.networkUnavailable))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        let record = fixture.store.record
        XCTAssertEqual(record?.accessToken, staleAccessToken)
        XCTAssertEqual(record?.refreshToken, staleRefreshToken)
        XCTAssertEqual(fixture.session.status, .linked(.premium), "still linked — nothing was wiped")
        XCTAssertEqual(fixture.transport.refreshRequests.count, 1, "exactly one attempt, then stop")
        XCTAssertEqual(fixture.transport.profileRequests.count, 0)
        XCTAssertEqual(fixture.bus.events.count, 0)
    }

    @MainActor
    func testInvalidGrantWipesTheRecordAndReportsRevoked() async {
        let fixture = Fixture(preLinkedRecord: makeRecord(expiry: Date().addingTimeInterval(-5)))
        fixture.transport.refreshReply = .body(Data(#"{"error":"invalid_grant"}"#.utf8), 400)

        let result = await fixture.session.validAccessToken()

        // Matrix row 10: wipe + unlinked treatment.
        XCTAssertEqual(result, .failure(.revoked))
        XCTAssertNil(fixture.store.record)
        XCTAssertEqual(fixture.session.status, .notLinked)
        XCTAssertFalse(fixture.session.isLinked)
        XCTAssertEqual(fixture.storage.rawPayloads.count, 0,
                       "the single-key wipe leaves nothing behind")
        XCTAssertEqual(fixture.storage.keysCarryingMaterial(staleAccessToken), [],
                       "no credential material survives anywhere in the seam")
        XCTAssertEqual(fixture.transport.refreshRequests.count, 1)
        XCTAssertEqual(fixture.transport.profileRequests.count, 0)
        XCTAssertEqual(fixture.bus.events.count, 1)
        let event = fixture.bus.events[0]
        XCTAssertEqual(event.eventType, "spotify_unlink")
        XCTAssertEqual(event.outcome, "revoked")
        XCTAssertNil(event.errorCode)
        XCTAssertEqual(event.metadata, [:])
    }

    @MainActor
    func testRefreshNonInvalidGrantErrorKeepsTheRecordAndReportsRefreshFailed() async {
        let fixture = Fixture(preLinkedRecord: makeRecord(expiry: Date().addingTimeInterval(-5)))
        let snapshot = fixture.storedSnapshot
        fixture.transport.refreshReply = .body(Data(#"{"error":"server_error"}"#.utf8), 500)

        let result = await fixture.session.validAccessToken()

        XCTAssertEqual(result, .failure(.refreshFailed(statusCode: 500)))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        XCTAssertNotNil(fixture.store.record)
        XCTAssertEqual(fixture.bus.events.count, 0, "no event — and certainly no wipe")
    }

    @MainActor
    func testUnparseableRefreshBodyKeepsTheRecordAndReportsMalformedResponse() async {
        let fixture = Fixture(preLinkedRecord: makeRecord(expiry: Date().addingTimeInterval(-5)))
        let snapshot = fixture.storedSnapshot
        fixture.transport.refreshReply = .body(Data(#"{"token_type":"Bearer"}"#.utf8), 200)

        let result = await fixture.session.validAccessToken()

        XCTAssertEqual(result, .failure(.malformedResponse))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        XCTAssertNotNil(fixture.store.record)
    }

    @MainActor
    func testRefreshStoreWriteFailureKeepsTheStoredRecordAndReportsStorageFailure() async {
        let fixture = Fixture(preLinkedRecord: makeRecord(expiry: Date().addingTimeInterval(-5)))
        fixture.storage.failWrites = true
        let snapshot = fixture.storedSnapshot
        fixture.transport.refreshReply = .body(Self.tokenBody(access: "rotated-access", refresh: nil), 200)

        let result = await fixture.session.validAccessToken()

        XCTAssertEqual(result, .failure(.storageFailure(.encryptedWriteFailed)))
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
        XCTAssertEqual(fixture.store.record?.accessToken, staleAccessToken,
                       "not persisted, so not handed out and not visible")
        XCTAssertEqual(fixture.bus.events.count, 0)
    }

    @MainActor
    func testTheRefreshBoundIsExactlyOneAttemptPerRequest() async {
        let fixture = Fixture(preLinkedRecord: makeRecord(expiry: Date().addingTimeInterval(-5)))
        fixture.transport.refreshReply = .body(Data(#"{"error":"server_error"}"#.utf8), 500)

        let first = await fixture.session.validAccessToken()
        XCTAssertEqual(first, .failure(.refreshFailed(statusCode: 500)))
        XCTAssertEqual(fixture.transport.refreshRequests.count, 1,
                       "one attempt per request — no loop, whatever the failure")

        let second = await fixture.session.validAccessToken()
        XCTAssertEqual(second, .failure(.refreshFailed(statusCode: 500)))
        XCTAssertEqual(fixture.transport.refreshRequests.count, 2,
                       "a second request is a second, single attempt")
    }

    @MainActor
    func testProductIsReverifiedOnRefreshAndAFailedReverifyKeepsTheStoredValue() async {
        let fixture = Fixture(preLinkedRecord: makeRecord(expiry: Date().addingTimeInterval(-5),
                                                          product: "free"))
        fixture.transport.refreshReply = .body(Self.tokenBody(access: "rotated-1", refresh: nil), 200)
        fixture.transport.profileReply = .body(Data(#"{"product":"premium"}"#.utf8), 200)

        let first = await fixture.session.validAccessToken()

        XCTAssertEqual(first, .success("rotated-1"))
        XCTAssertEqual(fixture.transport.profileRequests.count, 1)
        XCTAssertEqual(fixture.store.record?.product, "premium")
        XCTAssertEqual(fixture.session.product, .premium)

        // A second refresh whose re-check fails: the refresh still
        // succeeds and the stored product is kept (best-effort).
        fixture.store.save(makeRecord(expiry: Date().addingTimeInterval(-5), product: "premium"))
        fixture.transport.profileReply = .failure(URLError(.timedOut))
        fixture.transport.refreshReply = .body(Self.tokenBody(access: "rotated-2", refresh: nil), 200)

        let second = await fixture.session.validAccessToken()

        XCTAssertEqual(second, .success("rotated-2"))
        XCTAssertEqual(fixture.store.record?.product, "premium", "the old value is kept")
        XCTAssertEqual(fixture.session.product, .premium)
    }

    @MainActor
    func testCapabilityStalenessSkipsTheReverifyWhenTheDerivedAgeIsYoung() async {
        // §32's `spotify.capabilityStalenessSeconds`, injected large: the
        // derived verification age is younger than the bound, so the
        // refresh runs alone.
        let fixture = Fixture(preLinkedRecord: makeRecord(expiry: Date().addingTimeInterval(-5),
                                                          product: "premium"),
                              capabilityStalenessSeconds: 100_000)
        fixture.transport.refreshReply = .body(Self.tokenBody(access: "rotated", refresh: nil), 200)

        let result = await fixture.session.validAccessToken()

        XCTAssertEqual(result, .success("rotated"))
        XCTAssertEqual(fixture.transport.refreshRequests.count, 1)
        XCTAssertEqual(fixture.transport.profileRequests.count, 0,
                       "the staleness bound gates the re-check")
        XCTAssertEqual(fixture.store.record?.product, "premium")
    }

    @MainActor
    func testLinkedRecordWithoutAClientIDReportsNotConfiguredAndMakesNoRequest() async {
        // A bundle change can remove the id after linking; the refresh
        // request cannot be built honestly without it (PKCE refreshes
        // carry `client_id`), so nothing is attempted and nothing wiped.
        let fixture = Fixture(preLinkedRecord: makeRecord(expiry: Date().addingTimeInterval(-5)),
                              clientID: nil)
        let snapshot = fixture.storedSnapshot

        let result = await fixture.session.validAccessToken()

        XCTAssertEqual(result, .failure(.notConfigured))
        XCTAssertEqual(fixture.transport.requests.count, 0)
        XCTAssertEqual(fixture.storedSnapshot, snapshot)
    }

    @MainActor
    func testValidAccessTokenWithNoRecordReportsRevokedWithoutAWipeOrEvent() async {
        let fixture = Fixture()

        let result = await fixture.session.validAccessToken()

        XCTAssertEqual(result, .failure(.revoked),
                       "the defensive no-account answer maps to unlinked treatment (row 10)")
        XCTAssertEqual(fixture.transport.requests.count, 0)
        XCTAssertEqual(fixture.bus.events.count, 0,
                       "no wipe happened, so no wipe is reported")
        XCTAssertEqual(fixture.storage.rawPayloads.count, 0)
    }

    @MainActor
    func testANonPositiveRefreshLimitForbidsTheRequest() async {
        let fixture = Fixture(preLinkedRecord: makeRecord(expiry: Date().addingTimeInterval(-5)),
                              refreshAttemptLimit: 0)

        let result = await fixture.session.validAccessToken()

        XCTAssertEqual(result, .failure(.networkUnavailable))
        XCTAssertEqual(fixture.transport.requests.count, 0,
                       "the injected bound is honoured — no request is made")
        XCTAssertNotNil(fixture.store.record)
    }

    // MARK: - Gherkin 4: unlink wipes locally, no remote revocation

    @MainActor
    func testUnlinkWipesLocallyWithNoRemoteRevocationCall() async {
        let fixture = Fixture(preLinkedRecord: makeRecord())

        let result = fixture.session.unlink()

        assertWipeConfirmed(result)
        XCTAssertNil(fixture.store.record)
        XCTAssertEqual(fixture.session.status, .notLinked)
        XCTAssertFalse(fixture.session.isLinked)
        XCTAssertEqual(fixture.storage.rawPayloads.count, 0)
        XCTAssertEqual(fixture.storage.keysCarryingMaterial(staleRefreshToken), [])
        // The V-1 stance: the wipe is local — no request left the device.
        XCTAssertEqual(fixture.transport.requests.count, 0)
        XCTAssertEqual(fixture.bus.events.count, 1)
        XCTAssertEqual(fixture.bus.events[0].eventType, "spotify_unlink")
        XCTAssertEqual(fixture.bus.events[0].outcome, "success")
        XCTAssertNil(fixture.bus.events[0].errorCode)
        XCTAssertEqual(fixture.bus.events[0].metadata, [:])
    }

    @MainActor
    func testUnlinkWipeFailureKeepsTheRecordAndReportsFailed() {
        let fixture = Fixture(preLinkedRecord: makeRecord())
        fixture.storage.failDeletes = true

        let result = fixture.session.unlink()

        assertWipeRefused(result)
        XCTAssertEqual(fixture.store.record, makeRecord(),
                       "the status flips only on a confirmed wipe")
        XCTAssertEqual(fixture.session.status, .linked(.premium))
        XCTAssertEqual(fixture.bus.events[0].outcome, "failed")
        XCTAssertEqual(fixture.bus.events[0].errorCode, "storageFailure")
    }

    @MainActor
    func testMarkRevokedWipesAndReportsRevoked() {
        let fixture = Fixture(preLinkedRecord: makeRecord())

        let result = fixture.session.markRevoked()

        assertWipeConfirmed(result)
        XCTAssertNil(fixture.store.record)
        XCTAssertEqual(fixture.session.status, .notLinked)
        XCTAssertEqual(fixture.storage.rawPayloads.count, 0)
        XCTAssertEqual(fixture.transport.requests.count, 0)
        XCTAssertEqual(fixture.bus.events.count, 1)
        XCTAssertEqual(fixture.bus.events[0].eventType, "spotify_unlink")
        XCTAssertEqual(fixture.bus.events[0].outcome, "revoked")
        XCTAssertNil(fixture.bus.events[0].errorCode)
        XCTAssertEqual(fixture.bus.events[0].metadata, [:])
    }

    @MainActor
    func testMarkRevokedWipeFailureKeepsTheRecordAndReportsFailed() {
        let fixture = Fixture(preLinkedRecord: makeRecord())
        fixture.storage.failDeletes = true

        let result = fixture.session.markRevoked()

        assertWipeRefused(result)
        XCTAssertEqual(fixture.store.record, makeRecord())
        XCTAssertEqual(fixture.session.status, .linked(.premium))
        XCTAssertEqual(fixture.bus.events[0].outcome, "failed")
        XCTAssertEqual(fixture.bus.events[0].errorCode, "storageFailure")
    }

    @MainActor
    func testReLinkAfterUnlinkWritesExactlyOneFreshRecordWithNoResidualState() async {
        let fixture = Fixture()
        fixture.transport.exchangeReply = .body(Self.tokenBody(access: "first-access",
                                                               refresh: "first-refresh",
                                                               scope: pinnedScope), 200)
        fixture.transport.profileReply = .body(Data(#"{"product":"premium"}"#.utf8), 200)
        let first = await fixture.session.link()
        XCTAssertEqual(first, .linked(.premium))
        XCTAssertEqual(fixture.storage.rawPayloads.count, 1)

        assertWipeConfirmed(fixture.session.unlink())
        XCTAssertEqual(fixture.storage.rawPayloads.count, 0)

        fixture.transport.exchangeReply = .body(Self.tokenBody(access: "second-access",
                                                               refresh: "second-refresh",
                                                               scope: pinnedScope), 200)
        let second = await fixture.session.link()
        XCTAssertEqual(second, .linked(.premium))

        XCTAssertEqual(fixture.storage.rawPayloads.count, 1, "still exactly one record")
        XCTAssertEqual(fixture.store.record?.accessToken, "second-access")
        XCTAssertEqual(fixture.store.record?.refreshToken, "second-refresh")
        XCTAssertEqual(fixture.bus.eventTypes,
                       ["spotify_link", "spotify_unlink", "spotify_link"])
    }

    // MARK: - Log discipline (NFR-SP-002)

    @MainActor
    func testEveryEmittedEventCarriesEmptyMetadataAndAClosedVocabulary() async {
        let fixture = Fixture()
        fixture.transport.exchangeReply = .body(Self.tokenBody(access: "a", refresh: "r"), 200)
        fixture.transport.profileReply = .body(Data(#"{"product":"premium"}"#.utf8), 200)
        _ = await fixture.session.link()
        _ = fixture.session.unlink()
        let revoked = Fixture(preLinkedRecord: makeRecord(expiry: Date().addingTimeInterval(-5)))
        revoked.transport.refreshReply = .body(Data(#"{"error":"invalid_grant"}"#.utf8), 400)
        _ = await revoked.session.validAccessToken()

        let closedOutcomes: [String: Set<String>] = [
            "spotify_link": ["success", "failed", "cancelled", "not_configured", "no_presenter"],
            "spotify_unlink": ["success", "failed", "revoked"],
        ]
        for bus in [fixture.bus, revoked.bus] {
            for event in bus.events {
                XCTAssertEqual(event.component, "spotify")
                XCTAssertEqual(event.metadata, [:])
                XCTAssertNil(event.durationMs)
                let allowed = try! XCTUnwrap(closedOutcomes[event.eventType],
                                             "unexpected event type \(event.eventType)")
                XCTAssertTrue(allowed.contains(event.outcome),
                              "\(event.outcome) is not in \(event.eventType)'s closed set")
                if let errorCode = event.errorCode {
                    XCTAssertTrue(Self.errorCaseNames.contains(errorCode),
                                  "errorCode must be a SpotifyAuthError case name")
                }
            }
        }
    }

    @MainActor
    func testErrorCodesNeverCarryAssociatedValues() async {
        // The three associated-value cases the link/refresh paths can
        // emit: none of their payloads may ride along in errorCode.
        let scoped = Fixture()
        scoped.flow.script = { url in
            Self.callback(replacing: url, items: [URLQueryItem(name: "error", value: "invalid_scope")])
        }
        _ = await scoped.session.link()

        let presented = Fixture()
        presented.flow.script = { _ in throw NSError(domain: "test", code: 12345) }
        _ = await presented.session.link()

        let refreshed = Fixture(preLinkedRecord: makeRecord(expiry: Date().addingTimeInterval(-5)))
        refreshed.transport.refreshReply = .body(Data(), 529)
        _ = await refreshed.session.validAccessToken()

        for event in scoped.bus.events + presented.bus.events + refreshed.bus.events {
            if let errorCode = event.errorCode {
                XCTAssertFalse(errorCode.contains("invalid_scope"))
                XCTAssertFalse(errorCode.contains("12345"))
                XCTAssertFalse(errorCode.contains("529"))
            }
        }
        XCTAssertEqual(scoped.bus.events[0].errorCode, "providerError")
        XCTAssertEqual(presented.bus.events[0].errorCode, "presentationFailed")
        XCTAssertEqual(refreshed.bus.events.count, 0)
    }

    // MARK: - Shared helpers

    /// `Result<Void, StorageError>` has no synthesized Equatable (`Void`
    /// is not Equatable), so wipe outcomes are pattern-matched, not
    /// compared.
    private func assertWipeConfirmed(_ result: Result<Void, StorageError>,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        if case .failure(let error) = result {
            XCTFail("expected a confirmed wipe, got \(error)", file: file, line: line)
        }
    }

    private func assertWipeRefused(_ result: Result<Void, StorageError>,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        switch result {
        case .success:
            XCTFail("expected the wipe to fail", file: file, line: line)
        case .failure(.encryptedWriteFailed):
            break
        case .failure(.encryptedReadFailed):
            XCTFail("expected encryptedWriteFailed", file: file, line: line)
        }
    }

    private static let errorCaseNames: Set<String> = [
        "notConfigured", "noPresenter", "userCancelled", "redirectMismatch",
        "stateMismatch", "providerError", "exchangeFailed", "malformedResponse",
        "verificationFailed", "missingScopes", "refreshFailed", "revoked",
        "storageFailure", "networkUnavailable", "presentationFailed",
    ]

    /// A callback URL in the registered shape, carrying the state nonce
    /// the authorize URL actually declared (exactly how the real seam
    /// round-trips), plus the caller's extra/delta query items.
    private static func callback(replacing authorizeURL: URL,
                                 stateOverride: String? = nil,
                                 items: [URLQueryItem] = []) -> URL {
        let state = stateOverride
            ?? URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value
            ?? ""
        var components = URLComponents()
        components.scheme = SpotifyAuthFlow.callbackScheme
        components.host = SpotifyAuthFlow.callbackHost
        components.path = ""
        let hasError = items.contains { $0.name == "error" }
        var query = hasError ? [URLQueryItem]() : [URLQueryItem(name: "code", value: "auth-code-fixture")]
        query.append(URLQueryItem(name: "state", value: state))
        query.append(contentsOf: items)
        components.queryItems = query
        return components.url!
    }
}

// MARK: - Doubles

/// The scripted presentation seam: records its calls, can "stay open" for
/// a testable delay (the flow-timeout path), and builds its callback from
/// the authorize URL it was handed — the one way a test can satisfy the
/// nonce the session minted internally.
@MainActor
private final class FakeSpotifyAuthSession: SpotifyAuthSession {
    private(set) var authorizeCalls = 0
    private(set) var lastAuthorizeURL: URL?
    /// True once the attempt's task was cancelled mid-flight (the
    /// session's timeout path cancels the seam).
    private(set) var wasCancelled = false
    var delay: TimeInterval = 0
    /// The attempt's scripted answer. Nil returns a valid callback.
    var script: ((URL) throws -> URL)?

    func authorize(url: URL, callbackURLScheme: String) async throws -> URL {
        authorizeCalls += 1
        lastAuthorizeURL = url
        if delay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                wasCancelled = true
                throw SpotifyAuthError.userCancelled
            }
        }
        if let script {
            return try script(url)
        }
        return SpotifyAccountSessionTests.callbackURLForTests(url)
    }
}

/// Scripted `LocalToolTransport` for the session's three request kinds.
/// Requests are captured and classified by host + grant body, so call
/// counts are per-endpoint facts rather than totals.
private final class StubAccountTransport: LocalToolTransport {
    enum Reply {
        case body(Data, Int)
        case failure(Error)
        case nonHTTP(Data)
    }

    var exchangeReply: Reply = .body(Data(), 500)
    var refreshReply: Reply = .body(Data(), 500)
    var profileReply: Reply = .body(Data(), 500)
    private(set) var requests: [URLRequest] = []

    var tokenRequests: [URLRequest] {
        requests.filter { $0.url?.host == "accounts.spotify.com" }
    }
    var exchangeRequests: [URLRequest] {
        tokenRequests.filter { Self.body($0).contains("grant_type=authorization_code") }
    }
    var refreshRequests: [URLRequest] {
        tokenRequests.filter { Self.body($0).contains("grant_type=refresh_token") }
    }
    var profileRequests: [URLRequest] {
        requests.filter { $0.url?.host == "api.spotify.com" }
    }

    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let reply: Reply
        if request.url?.host == "api.spotify.com" {
            reply = profileReply
        } else if Self.body(request).contains("grant_type=refresh_token") {
            reply = refreshReply
        } else {
            reply = exchangeReply
        }
        switch reply {
        case .failure(let error):
            throw error
        case .nonHTTP(let data):
            let response = URLResponse(url: request.url ?? URL(string: "https://accounts.spotify.com")!,
                                       mimeType: nil,
                                       expectedContentLength: 0,
                                       textEncodingName: nil)
            return (data, response)
        case .body(let data, let statusCode):
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://accounts.spotify.com")!,
                                           statusCode: statusCode,
                                           httpVersion: nil,
                                           headerFields: nil)!
            return (data, response)
        }
    }

    private static func body(_ request: URLRequest) -> String {
        guard let data = request.httpBody else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Shared helpers

extension SpotifyAccountSessionTests {
    /// The fixture callback a script-less fake returns: a valid nonce
    /// echo for the authorize URL it was handed. File-scope so the fake
    /// can reach it without exposing the test case's private methods.
    fileprivate static func callbackURLForTests(_ authorizeURL: URL) -> URL {
        let state = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        var components = URLComponents()
        components.scheme = SpotifyAuthFlow.callbackScheme
        components.host = SpotifyAuthFlow.callbackHost
        components.path = ""
        components.queryItems = [
            URLQueryItem(name: "code", value: "auth-code-fixture"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }
}
