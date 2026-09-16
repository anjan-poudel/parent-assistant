import XCTest
@testable import ElderlyAssistant
import UIKit

/// `GoogleAccountSession`: the interactive flow's OUTCOME MATRIX.
///
/// The bug this file exists for (2026-09-17): `signIn(withPresenting:)`
/// was called with no scopes, so the token came back without
/// `calendar.events`/`contacts` and every Calendar call answered 401. The
/// fix asks for them with `addScopes` — and the state it introduces, an
/// elder who is SIGNED IN and has DECLINED the calendar grant, is the one
/// this suite is built around. It cannot be reached in the simulator
/// (Google's sheet needs an OAuth client, a real account and a human
/// tap), so the SDK sits behind `GoogleAuthFlow` and every branch is a
/// value here.
///
/// Nothing in this file touches `GIDSignIn`: the flow is faked, and the
/// SDK's numeric codes are spelled as raw values (see `GoogleSignInCode`).
///
/// The RESTORE path (2026-09-17) is here for the same reason: it cannot
/// be reached in the simulator either — a real restore needs a real
/// Keychain entry written by a real sign-in — and it is the path that
/// decides whether a connected household reads as connected at launch.
/// Its four outcomes (restored, restored-unscoped, nothing stored,
/// failed) are values through the same fake.
final class GoogleAccountSessionTests: XCTestCase {

    // MARK: - Harness

    /// The controller the fake flow is handed. Never presented: the flow
    /// being faked means no sheet is ever asked of it, which is also how
    /// these tests run without a window scene.
    private func presenter() -> () -> UIViewController? {
        { UIViewController() }
    }

    private func makeSession(clientID: String? = "test-client-id",
                             presenter: (() -> UIViewController?)? = nil,
                             flow: FakeAuthFlow,
                             bus: MockObservabilityBus) -> GoogleAccountSession {
        GoogleAccountSession(clientID: clientID,
                             presenter: presenter ?? self.presenter(),
                             flow: flow,
                             observabilityBus: bus,
                             defaults: .standard)
    }

    private func sessionEvents(_ bus: MockObservabilityBus,
                               _ type: String) -> [ObservabilityEvent] {
        bus.emittedEvents.filter { $0.component == "calendar_share_session" && $0.eventType == type }
    }

    // MARK: - Happy path: the scopes are actually asked for

    /// The regression itself. A sign-in that grants identity alone must be
    /// FOLLOWED by the scope request — this is the assertion the old code
    /// failed, and the 401 it caused on every Calendar call.
    func testSignInWithoutTheShareScopesAsksForThemAndConnects() async {
        let flow = FakeAuthFlow()
        // The SDK's sign-in sheet returns identity only: exactly what the
        // device console showed before the fix.
        flow.signInResult = .success(["email", "profile"])
        flow.addScopesResult = .success(
            GoogleAccountSession.requiredScopes + ["email", "profile"])
        let bus = MockObservabilityBus()

        let outcome = await makeSession(flow: flow, bus: bus).signIn()

        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(flow.addScopesCalls, 1,
                       "the calendar/contacts grant is requested explicitly — sign-in alone never carries it")
        XCTAssertEqual(flow.requestedScopes.first, GoogleAccountSession.requiredScopes,
                       "and it asks for exactly the scopes the share path needs")
        XCTAssertEqual(sessionEvents(bus, "calendar_share_session_sign_in").count, 1)
        XCTAssertEqual(sessionEvents(bus, "calendar_share_session_sign_in").first?.outcome, "success")
    }

    /// A session that already holds the grant does not get a second
    /// consent sheet: the card's re-connect must not cost the elder a
    /// screen of extra taps when nothing is missing.
    func testSignInThatAlreadyHoldsTheScopesSkipsTheConsentSheet() async {
        let flow = FakeAuthFlow()
        flow.signInResult = .success(GoogleAccountSession.requiredScopes)
        let bus = MockObservabilityBus()

        let outcome = await makeSession(flow: flow, bus: bus).signIn()

        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(flow.addScopesCalls, 0,
                       "nothing is missing, so nothing is asked for again")
    }

    /// Google returns the grant in the URL spelling the consent screen
    /// showed, but the SDK's own scope handling uses the SHORT form. Both
    /// must read as granted, or a perfectly authorized household is told
    /// it has no calendar access.
    func testGrantedScopesMatchEitherSpelling() async {
        let flow = FakeAuthFlow()
        flow.signInResult = .success(["calendar.events", "contacts"])
        let bus = MockObservabilityBus()

        let outcome = await makeSession(flow: flow, bus: bus).signIn()

        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(flow.addScopesCalls, 0)
    }

    /// `scopesAlreadyGranted` is the SDK's success arriving through the
    /// error channel (thrown when its own record of the grant has not
    /// caught up). Reporting it as a refusal would leave a fully
    /// authorized household staring at a warning.
    func testScopesAlreadyGrantedIsSuccessNotRefusal() async {
        let flow = FakeAuthFlow()
        flow.signInResult = .success(["email"])
        flow.addScopesResult = .failure(GoogleSignInCode.scopesAlreadyGranted.error)
        let bus = MockObservabilityBus()

        let outcome = await makeSession(flow: flow, bus: bus).signIn()

        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(sessionEvents(bus, "calendar_share_session_sign_in").count, 1,
                       "the success event is emitted, not a scopes-missing one")
    }

    // MARK: - The declined grant

    /// The outcome the whole change exists to make visible: the elder is
    /// SIGNED IN and closed Google's consent sheet.
    ///
    /// Both facts have to survive: the session is real (so this is not a
    /// failed sign-in) and it cannot share anything (so the card must not
    /// claim it can).
    func testDecliningTheScopeSheetLeavesASignedInSessionWithoutCalendarAccess() async {
        let flow = FakeAuthFlow()
        flow.signInResult = .success(["email"])
        flow.addScopesResult = .failure(GoogleSignInCode.canceled.error)
        let bus = MockObservabilityBus()

        let outcome = await makeSession(flow: flow, bus: bus).signIn()

        XCTAssertEqual(outcome, .connectedWithoutScopes)
        XCTAssertNotEqual(outcome, .cancelled,
                          "the SIGN-IN was not cancelled — only the consent was")
        XCTAssertFalse(outcome.isConnected,
                       "and nothing may drain the share queue into a token that cannot write")
        let events = sessionEvents(bus, "calendar_share_session_sign_in_scopes_missing")
        XCTAssertEqual(events.count, 1,
                       "its own event type: a declined grant is not a failed sign-in")
        XCTAssertEqual(events.first?.outcome, "cancelled",
                       "the elder's own choice, which is a product signal rather than an error")
        XCTAssertNil(events.first?.errorCode)
    }

    /// A consent call that SUCCEEDS and returns a list still missing the
    /// grant — a workspace admin restriction, typically. Same end state,
    /// different cause, and the difference is the outcome name in
    /// observability: "not granted" is not "declined".
    func testCallSucceedingWithoutTheGrantIsReportedAsRefusedNotDeclined() async {
        let flow = FakeAuthFlow()
        flow.signInResult = .success(["email"])
        flow.addScopesResult = .success(["email", "profile"])
        let bus = MockObservabilityBus()

        let outcome = await makeSession(flow: flow, bus: bus).signIn()

        XCTAssertEqual(outcome, .connectedWithoutScopes)
        let events = sessionEvents(bus, "calendar_share_session_sign_in_scopes_missing")
        XCTAssertEqual(events.first?.outcome, "failure")
        XCTAssertEqual(events.first?.errorCode, "scopes_not_granted")
    }

    /// The SDK failing around the consent sheet (a keychain error, an EMM
    /// refusal) still leaves a real session. Throwing the sign-in away
    /// over it would sign the elder out of an account that works.
    func testConsentSheetFailureKeepsTheSessionAndReportsIt() async {
        let flow = FakeAuthFlow()
        flow.signInResult = .success(["email"])
        flow.addScopesResult = .failure(GoogleSignInCode.keychain.error)
        let bus = MockObservabilityBus()

        let outcome = await makeSession(flow: flow, bus: bus).signIn()

        XCTAssertEqual(outcome, .connectedWithoutScopes)
        let events = sessionEvents(bus, "calendar_share_session_sign_in_scopes_missing")
        XCTAssertEqual(events.first?.outcome, "failure")
        XCTAssertEqual(events.first?.errorCode, "scopes_not_granted")
    }

    // MARK: - Closed sheet, failed sheet, no sheet

    func testElderClosingTheSignInSheetIsCancelledAndNothingElse() async {
        let flow = FakeAuthFlow()
        flow.signInResult = .failure(GoogleSignInCode.canceled.error)
        let bus = MockObservabilityBus()

        let outcome = await makeSession(flow: flow, bus: bus).signIn()

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(flow.addScopesCalls, 0, "no consent sheet after a cancelled sign-in")
        let events = sessionEvents(bus, "calendar_share_session_sign_in_cancelled")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.outcome, "cancelled")
    }

    /// A failed flow reports the SDK's NUMERIC code and never its
    /// description, which can carry the account being signed in
    /// (constitution C9 / the release-log privacy gate).
    func testSDKFailureCarriesItsNumericCodeAndNoDescription() async {
        let flow = FakeAuthFlow()
        flow.signInResult = .failure(GoogleSignInCode.unknown.error)
        let bus = MockObservabilityBus()

        let outcome = await makeSession(flow: flow, bus: bus).signIn()

        XCTAssertEqual(outcome, .unavailable)
        let events = sessionEvents(bus, "calendar_share_session_sign_in_failed")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.outcome, "failure")
        XCTAssertEqual(events.first?.errorCode, "sdk_\(GoogleSignInCode.unknown.rawValue)")
        XCTAssertEqual(events.first?.metadata, [:],
                       "no free-form metadata channel exists on this component")
    }

    /// No window to present from: the honest answer is "did not happen",
    /// and no sheet is started against nothing.
    func testNoPresenterFailsWithoutStartingAFlow() async {
        let flow = FakeAuthFlow()
        let bus = MockObservabilityBus()

        let outcome = await makeSession(presenter: { nil }, flow: flow, bus: bus).signIn()

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(flow.signInCalls, 0)
        XCTAssertEqual(sessionEvents(bus, "calendar_share_session_sign_in_failed").first?.errorCode,
                       "no_presenter")
    }

    /// No OAuth client in the bundle: the state the app ships in today.
    /// Nothing is presented and nothing crashes.
    func testNotConfiguredNeverStartsAFlow() async {
        let flow = FakeAuthFlow()
        let bus = MockObservabilityBus()

        let outcome = await makeSession(clientID: nil, flow: flow, bus: bus).signIn()

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(flow.signInCalls, 0)
        XCTAssertEqual(flow.addScopesCalls, 0)
        XCTAssertEqual(sessionEvents(bus, "calendar_share_session_sign_in_failed").first?.errorCode,
                       "not_configured")
    }

    /// `createAccount` is the same machine with a different event name —
    /// asserted so the two entry points cannot drift apart.
    func testCreateAccountRunsTheSameFlowUnderItsOwnEvent() async {
        let flow = FakeAuthFlow()
        flow.signInResult = .success(["email"])
        flow.addScopesResult = .failure(GoogleSignInCode.canceled.error)
        let bus = MockObservabilityBus()

        let outcome = await makeSession(flow: flow, bus: bus).createAccount()

        XCTAssertEqual(outcome, .connectedWithoutScopes)
        XCTAssertEqual(sessionEvents(bus, "calendar_share_session_create_account_scopes_missing").count, 1)
    }

    // MARK: - Restore: the launch path (2026-09-17)

    /// The bug this section exists for: a connected household's card
    /// showed SIGNED OUT on every launch, and events created before the
    /// elder signed in again were never shared — because nothing brought
    /// the SDK's Keychain-stored account back into the process. Its
    /// `currentUser` is nil in a cold process until a restore has run,
    /// and `isSignedIn` reads exactly that.
    ///
    /// No presenter on purpose below: a restore happens at launch,
    /// before any window exists, and needing one would make it
    /// impossible.
    func testRestoreBringsTheStoredSessionBackWithoutPresentingAnything() async {
        let flow = FakeAuthFlow()
        flow.hasPreviousSignInResult = true
        flow.restoreResult = .success(GoogleAccountSession.requiredScopes)
        let bus = MockObservabilityBus()

        let outcome = await makeSession(presenter: { nil }, flow: flow, bus: bus)
            .restorePreviousSession()

        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(flow.restoreCalls, 1)
        XCTAssertEqual(flow.signInCalls, 0, "a restore never opens a sign-in sheet")
        XCTAssertEqual(flow.addScopesCalls, 0,
                       "and never asks for a grant at launch — Google's consent screen is not a thing to put in front of an elder opening the app")
        let events = sessionEvents(bus, "calendar_share_session_restore")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.outcome, "success")
        XCTAssertNil(events.first?.errorCode)
    }

    /// A device that never connected, or one the elder signed out of: the
    /// SDK has nothing stored, so nothing is attempted and nothing is
    /// reported as wrong. `hasPreviousSignIn` is what makes this a value
    /// rather than an SDK error — the restore call is not even made.
    func testRestoreWithNoStoredAccountIsTheOrdinaryFreshState() async {
        let flow = FakeAuthFlow()
        flow.hasPreviousSignInResult = false
        let bus = MockObservabilityBus()

        let outcome = await makeSession(flow: flow, bus: bus).restorePreviousSession()

        XCTAssertEqual(outcome, .unavailable, "nothing was restored, and nothing is claimed")
        XCTAssertEqual(flow.hasPreviousSignInCalls, 1,
                       "the SDK's cache is asked first, so 'there is nothing to restore' stays distinguishable from 'the restore failed'")
        XCTAssertEqual(flow.restoreCalls, 0,
                       "and the restore itself is not attempted — a fake whose default result is a scoped SUCCESS proves the outcome above came from the guard, not from the flow")
        let events = sessionEvents(bus, "calendar_share_session_restore_no_previous")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.outcome, "success", "a fresh install is not a failure")
        XCTAssertTrue(sessionEvents(bus, "calendar_share_session_restore_failed").isEmpty)
    }

    /// The honest degradation: the account was there and could not be
    /// brought back — Google revoked the grant, the Keychain is
    /// unreadable, the token refresh failed. The app is left exactly
    /// where a device that never connected sits, which is what the card
    /// says and what the share queue's gate reads.
    func testRestoreThatFailsDegradesToSignedOut() async {
        let flow = FakeAuthFlow()
        flow.hasPreviousSignInResult = true
        // The SDK's own code for it: "no valid auth tokens in the
        // keychain ... returned by restorePreviousSignIn if the user has
        // not signed in before or if they have since signed out".
        flow.restoreResult = .failure(GoogleSignInCode.hasNoAuthInKeychain.error)
        let bus = MockObservabilityBus()
        let session = makeSession(flow: flow, bus: bus)

        let outcome = await session.restorePreviousSession()

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertFalse(session.isSignedIn,
                       "the signed-out state is the honest degradation — a stale 'signed in' would be the silent-skip bug in a new place")
        let events = sessionEvents(bus, "calendar_share_session_restore_failed")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.outcome, "failure")
        XCTAssertEqual(events.first?.errorCode,
                       "sdk_\(GoogleSignInCode.hasNoAuthInKeychain.rawValue)",
                       "the SDK's NUMERIC code, never its description (constitution C9)")
        XCTAssertEqual(events.first?.metadata, [:],
                       "no free-form metadata channel exists on this component")
    }

    /// Restored, and unable to share: the account is back but the
    /// Calendar/contacts grant is not. A real session either way — and
    /// the missing grant is READ, never asked for, because a consent
    /// sheet at launch is a demand the elder did not open the app for.
    func testRestoredSessionWithoutTheGrantIsReportedAsMissingNotSignedOut() async {
        let flow = FakeAuthFlow()
        flow.hasPreviousSignInResult = true
        flow.restoreResult = .success(["email", "profile"])
        let bus = MockObservabilityBus()

        let outcome = await makeSession(flow: flow, bus: bus).restorePreviousSession()

        XCTAssertEqual(outcome, .connectedWithoutScopes)
        XCTAssertFalse(outcome.isConnected,
                       "and nothing may drain the share queue into a token that cannot write")
        XCTAssertEqual(flow.addScopesCalls, 0)
        let events = sessionEvents(bus, "calendar_share_session_restore_scopes_missing")
        XCTAssertEqual(events.count, 1, "its own event type: a restored-but-unscoped account is not a failed restore")
        XCTAssertEqual(events.first?.outcome, "failure")
        XCTAssertEqual(events.first?.errorCode, "scopes_not_granted")
    }

    /// No OAuth client in the bundle: the state the app ships in today.
    /// The SDK cannot even be configured, so there is nothing to ask it
    /// and nothing to claim.
    func testRestoreIsNeverAttemptedWithoutAnOAuthClient() async {
        let flow = FakeAuthFlow()
        flow.hasPreviousSignInResult = true
        let bus = MockObservabilityBus()

        let outcome = await makeSession(clientID: nil, flow: flow, bus: bus)
            .restorePreviousSession()

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(flow.hasPreviousSignInCalls, 0)
        XCTAssertEqual(flow.restoreCalls, 0)
        let events = sessionEvents(bus, "calendar_share_session_restore_failed")
        XCTAssertEqual(events.first?.errorCode, "not_configured")
    }

    // MARK: - Scope reading

    /// The pure half of `hasRequiredScopes`: which granted lists count as
    /// "can share".
    func testScopeRequirementIsAllOfThemNotAnyOfThem() {
        let required = GoogleAccountSession.requiredScopes

        XCTAssertTrue(GoogleAccountSession.grantsRequiredScopes(required))
        XCTAssertTrue(GoogleAccountSession.grantsRequiredScopes(required + ["email"]))
        XCTAssertTrue(GoogleAccountSession.grantsRequiredScopes(["calendar.events", "contacts"]),
                      "the SDK's short spelling counts as granted")
        XCTAssertTrue(GoogleAccountSession.grantsRequiredScopes(
            ["https://www.googleapis.com/auth/calendar.events",
             "contacts",
             "https://www.googleapis.com/auth/userinfo.email"]),
                      "a mixed list counts as granted")
        XCTAssertFalse(GoogleAccountSession.grantsRequiredScopes([]),
                       "an absent list reads as empty, never as 'assume granted'")
        XCTAssertFalse(GoogleAccountSession.grantsRequiredScopes(["email", "profile"]),
                       "identity alone is not calendar access — the 401 this whole change is about")
        XCTAssertFalse(GoogleAccountSession.grantsRequiredScopes(["calendar.events"]),
                       "one of the two is not both: contacts is what keeps the invite out of spam")
    }

    /// The two scopes are exactly the narrow pair the design asked for —
    /// `calendar.events`, never the account-wide `calendar` scope that
    /// would expose every calendar the elder can see.
    func testRequiredScopesAreTheNarrowCalendarGrantAndContacts() {
        XCTAssertEqual(GoogleAccountSession.requiredScopes,
                       ["https://www.googleapis.com/auth/calendar.events",
                        "https://www.googleapis.com/auth/contacts"])
    }

    /// Signed out, the SDK has no user and the answer is false — read
    /// through the real SDK singleton (no configuration, no network, and
    /// no account in a test process).
    func testHasRequiredScopesIsFalseWithNoSignedInUser() {
        let session = makeSession(flow: FakeAuthFlow(), bus: MockObservabilityBus())

        XCTAssertFalse(session.isSignedIn)
        XCTAssertFalse(session.hasRequiredScopes,
                       "no session is not a scoped session")
    }
}

// MARK: - Fakes

/// The GoogleSignIn interactive surface as values: what each sheet
/// returns, and what (if anything) it throws.
private final class FakeAuthFlow: GoogleAuthFlow {

    var signInResult: Result<[String], Error> = .success([])
    var addScopesResult: Result<[String], Error> = .success([])
    /// Whether the SDK claims to hold an account from a previous launch.
    /// False by default: the launch path's ordinary state for a device
    /// that has never connected, and the state a test must opt OUT of to
    /// reach the restore at all.
    var hasPreviousSignInResult = false
    var restoreResult: Result<[String], Error> = .success([])

    private(set) var signInCalls = 0
    private(set) var addScopesCalls = 0
    private(set) var hasPreviousSignInCalls = 0
    private(set) var restoreCalls = 0
    /// Every scope list asked for, in call order — the assertion that the
    /// consent request carries the calendar grant.
    private(set) var requestedScopes: [[String]] = []

    func signIn(presenting controller: UIViewController) async throws -> [String] {
        signInCalls += 1
        return try signInResult.get()
    }

    func hasPreviousSignIn() -> Bool {
        hasPreviousSignInCalls += 1
        return hasPreviousSignInResult
    }

    func restorePreviousSignIn() async throws -> [String] {
        restoreCalls += 1
        return try restoreResult.get()
    }

    func addScopes(_ scopes: [String],
                   presenting controller: UIViewController) async throws -> [String] {
        addScopesCalls += 1
        requestedScopes.append(scopes)
        return try addScopesResult.get()
    }
}

/// The SDK's numeric error codes, spelled as raw values.
///
/// Raw values rather than `GIDSignInError` so this file needs no
/// GoogleSignIn import: the test target links the APP, not the package,
/// and the codes are part of the SDK's public contract (`GIDSignInErrorCode`,
/// verified against 8.0.0 — `kGIDSignInErrorCodeCanceled` is -5,
/// `…HasNoAuthInKeychain` is -4,
/// `…ScopesAlreadyGranted` is -8). `GoogleAccountSession` reads them
/// through the SDK's own enum, so a renumbering upstream turns these
/// assertions red rather than silently changing what the elder sees.
private enum GoogleSignInCode: Int {
    case unknown = -1
    case keychain = -2
    case hasNoAuthInKeychain = -4
    case canceled = -5
    case scopesAlreadyGranted = -8

    /// An `NSError` shaped like the SDK's own, which the session
    /// classifies by code alone. A property rather than a factory taking
    /// a bare `Int`, so the call sites read `GoogleSignInCode.canceled.error`
    /// and the code they name is the one this enum carries.
    var error: NSError {
        NSError(domain: "com.google.GIDSignIn", code: rawValue)
    }
}
