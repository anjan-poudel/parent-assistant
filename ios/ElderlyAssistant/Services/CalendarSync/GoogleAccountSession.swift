import Foundation
import UIKit
import GoogleSignIn

// MARK: - Google account session (calendar & family sharing, 2026-09-16)

/// The production `GoogleAccountSessionProtocol`: the elder's ONE Google
/// account, connected once on this device (design §2 decision 3), held by
/// the GoogleSignIn SDK.
///
/// This file is the whole SDK surface of the share feature. Everything
/// above it — the queue, the invite policy, the inbound filter — talks to
/// `GoogleAccountSessionProtocol`, so the app runs, the tests run and the
/// Settings card is honest with no OAuth client, no Google account and no
/// simulator session (design §0): with no client id in the bundle the type
/// still constructs, reports `isConfigured == false`, and every call that
/// would need Google answers false instead of presenting a button that
/// cannot work.
///
/// Connecting is TWO sheets, not one (2026-09-17). The sign-in sheet
/// proves who the elder is; the Calendar/contacts grant is asked for
/// afterwards with `addScopes`, because that is the only entry point
/// GoogleSignIn 8.0.0 exposes to the Swift async interface. A flow that
/// ends after the first sheet leaves a session that can do nothing this
/// feature needs, which is why `signIn()` reports a four-way outcome
/// rather than a Bool.
///
/// A connected account is RESTORED at launch (2026-09-17), not merely
/// read. The SDK keeps the account and its tokens in the Keychain but
/// holds the live session in memory, and `currentUser` is nil in a cold
/// process until `restorePreviousSignIn` has run — so `isSignedIn` alone
/// reported every connected household as signed out on every launch, the
/// card showed the pre-connect state, and events created before the
/// elder signed in again were never shared (the queue is gated on
/// `isSignedIn`). `restorePreviousSession()` is that missing step: no
/// sheet, no user interaction, one Keychain read plus at most one token
/// refresh, and an honest "nothing was brought back" when it fails.
///
/// The token follows the GRANT, not the refresh (2026-09-17). Google
/// mints an access token per grant, and the SDK's silent refresh hands
/// back the cached one for as long as it looks fresh — so for up to an
/// hour after the elder consented, this session's Calendar calls went out
/// with the identity-only token minted before `addScopes` ran, and Google
/// answered 401/403 while the console showed a household that had just
/// granted everything. The flows now return the token they minted, the
/// session keeps the freshest one with its expiry (`grantedToken`), and
/// `accessToken()` prefers it over the SDK's refresh until it expires.
///
/// Nothing personal is stored here. The SDK keeps the account and its
/// tokens in the Keychain; this type adds no storage of its own — in
/// particular it never mirrors a token into `UserDefaults`, where a
/// credential would sit in a plaintext plist (the share layer's other
/// defaults entry — the inbound sync token — is opaque and non-personal by
/// comparison). The cached token is process memory: it dies with the
/// process, and sign-out and a failed restore drop it explicitly.
///
/// Privacy (constitution C9 / the release-log privacy gate): no console
/// output anywhere in this file. Its observability events carry an outcome
/// and a NUMERIC SDK code, never an address, a name or an error
/// description — `localizedDescription` on an OAuth error can carry the
/// account being signed in, which is exactly what the gate exists to stop.
final class GoogleAccountSession: GoogleAccountSessionProtocol {

    // MARK: Required scopes

    /// The OAuth scopes this feature cannot work without, in the URL
    /// spelling Google's own consent screen shows.
    ///
    /// `calendar` — the ACCOUNT-WIDE grant, NOT `calendar.events`
    /// (2026-09-17). The narrow grant is enough for every EVENT call this
    /// layer makes: `events.list` on the elder's primary calendar, the
    /// twins' insert/update/delete inside a calendar the app already
    /// knows the id of, and the accept patch. It is not enough for the
    /// family calendar's own lifecycle, and that lifecycle comes FIRST:
    /// `ensureFamilyCalendar` has to list the account's calendars and
    /// create one, and Google answers 403 to both of those with
    /// `calendar.events` in hand — a device console showed exactly that
    /// split, inbound `events.list` succeeding while
    /// `calendarList.list`/`calendars.insert` were refused.
    ///
    /// A share path that cannot find or create its own calendar has
    /// nowhere to write a twin, so the first thing every write does would
    /// fail no matter how well the scopes covered events. The wide grant
    /// is therefore the honest requirement rather than an over-ask — and
    /// it is why the consent screen must list Calendar as well: `addScopes`
    /// cannot hand back a grant the console does not offer.
    ///
    /// `contacts` is what `People v1` needs to put the caregiver in the
    /// elder's own address book before inviting them (design §4.2 — an
    /// invite from an unknown address lands in spam).
    ///
    /// `profile`/`email` are not listed: the SDK asks for identity as
    /// part of its own sign-in flow, and asking twice would show the
    /// elder a consent screen listing a permission they already gave.
    ///
    /// This list is both what the consent sheet asks for and what
    /// `hasRequiredScopes` reads back, so an account still holding only
    /// the old `calendar.events` grant reports as
    /// `connectedWithoutScopes` — which is the truth: it is signed in and
    /// cannot reach the family calendar. Signing out and connecting again
    /// is what replaces the grant.
    static let requiredScopes = [
        "https://www.googleapis.com/auth/calendar",
        "https://www.googleapis.com/auth/contacts",
    ]

    // MARK: Bundle configuration

    /// The Info.plist key Google's own tooling writes the iOS OAuth client
    /// id to. Read from the BUNDLE rather than a generated constant so the
    /// client id can be swapped per build configuration without this file
    /// knowing anything about the build system.
    private static let clientIDKey = "GIDClientID"

    /// The configured OAuth client id, or nil when the app was built
    /// without one. Trimmed, and blank counts as absent: an empty
    /// `GIDClientID` is the state a placeholder build is in, and it must
    /// read as "not configured" rather than as a client id that fails
    /// later inside the SDK.
    static var bundledClientID: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: clientIDKey) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The app's own key-window lookup, used when the construction site
    /// supplies no presenter.
    ///
    /// Nonisolated on purpose: it is a DEFAULT ARGUMENT value, evaluated
    /// where the session is built (AppCoordinator's `lazy var`), so it
    /// cannot be `@MainActor`-isolated without making that construction
    /// site main-actor-bound. Reading the scene list off-main is the same
    /// shape `SystemExternalItemOpener` already uses for
    /// `UIApplication.shared`; the controller it returns is only ever
    /// TOUCHED on the main actor, by the sign-in flow below.
    ///
    /// `first { $0.isKeyWindow }` rather than `keyWindow`: the deprecated
    /// `UIApplication.keyWindow` is scene-blind, and on a device with a
    /// presented sheet it can name the wrong window to present from.
    static func keyWindowPresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let window = scenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return window?.rootViewController
    }

    // MARK: State

    /// Resolved once at construction. Nil is the "not configured" state the
    /// whole feature degrades on, so it is a plain value here rather than a
    /// bundle read on every `isConfigured` (which the status card calls on
    /// every refresh).
    private let clientID: String?

    /// Where the sign-in sheet is presented from. Assignable AFTER
    /// construction because the coordinator builds this object in a
    /// `lazy var` during app setup, before any window it could present
    /// from exists.
    var presenter: (() -> UIViewController?)?

    /// The SDK's interactive surface, behind the seam declared in
    /// `CalendarShareSeams` so the outcome matrix — granted, declined,
    /// cancelled, failed — is a unit test instead of a device session.
    private let flow: GoogleAuthFlow

    private let observabilityBus: ObservabilityBus

    /// The clock the token cache reads. Injectable for the same reason
    /// `GoogleCalendarGateway` takes one: expiry has to be a value in a
    /// test rather than "whatever `Date()` said when the suite ran".
    private let now: () -> Date

    /// The freshest access token a FLOW handed over in this process, and
    /// the instant it stops being usable (2026-09-17).
    ///
    /// A refresh is not enough to keep this current, which is the whole
    /// reason the cache exists. Google mints one access token per GRANT,
    /// and `refreshTokensIfNeeded` hands back the SDK's cached one for as
    /// long as it looks fresh — so for up to an hour after the elder
    /// granted Calendar access, every refresh returned the token minted
    /// BEFORE that grant, the Calendar API was called with an
    /// identity-scoped token, and Google answered 401/403. The flow's own
    /// result carries the token minted WITH the grant, so it is kept here
    /// and preferred while it lasts.
    ///
    /// In memory only, and deliberately so: the SDK owns the account's
    /// Keychain entry and this type adds no storage of its own (see the
    /// type comment). `private(set)` rather than `private` so the rule
    /// "the flow's token is what gets kept" is assertable — no test
    /// process has a signed-in `GIDSignIn`, so the only way to observe
    /// the choice is to read what was kept.
    private(set) var grantedToken: GoogleAccessToken?

    /// An access token and the instant it stops being usable.
    struct GoogleAccessToken: Equatable {
        /// The token string, exactly as the SDK spelled it.
        let value: String
        /// When it expires: the SDK's own estimate when it reports one,
        /// otherwise the short window this type assumes (see
        /// `unreportedTokenLifetime`).
        let expiresAt: Date

        /// Whether the token can still be handed to Google at `instant`.
        ///
        /// Strictly `<`: a token whose expiry is exactly now counts as
        /// gone. The alternative on the other side of the boundary is one
        /// silent refresh, while a wrong "still good" is a request Google
        /// answers 401/403 — and this boundary is where that whole class
        /// of failures lives.
        func isFresh(at instant: Date) -> Bool { instant < expiresAt }
    }

    /// How long a token is trusted when no expiry comes with it.
    ///
    /// `GIDToken.expirationDate` is nullable in the SDK's header, and an
    /// expiry this app has to guess is not one it can promise anything
    /// about: five minutes is short enough that a wrong "still fresh"
    /// costs a request rather than an hour of them, and long enough to
    /// cover the gap between a grant and the flush that follows it.
    static let unreportedTokenLifetime: TimeInterval = 5 * 60

    /// Whether `GIDConfiguration` has been handed to the SDK in this
    /// process. Static because the thing being configured — `GIDSignIn`'s
    /// shared instance — is a process singleton: configuring per session
    /// object would be a no-op the second time and a lie about who owns
    /// the SDK's state.
    @MainActor private static var isSDKConfigured = false

    init(clientID: String? = GoogleAccountSession.bundledClientID,
         presenter: (() -> UIViewController?)? = GoogleAccountSession.keyWindowPresenter,
         flow: GoogleAuthFlow = GoogleSignInAuthFlow(),
         observabilityBus: ObservabilityBus = GoogleAccountSession.unwiredBus,
         now: @escaping () -> Date = Date.init,
         defaults: UserDefaults = .standard) {
        // Deliberately NIL-safe: no permission prompt, no SDK call and no
        // network work happens at construction (the coordinator builds
        // this in a lazy var during launch), and an absent client id is a
        // supported state rather than a failure.
        self.clientID = clientID
        self.presenter = presenter
        self.flow = flow
        self.observabilityBus = observabilityBus
        self.now = now
        // `defaults` is accepted to keep the share layer's construction
        // shape uniform and is deliberately UNUSED: the SDK owns the
        // account state (Keychain) and nothing about a Google session
        // belongs in a plist. It stays in the signature so a caller can
        // pass the app's suite without a special case here.
        _ = defaults
    }

    // MARK: - Configuration

    var isConfigured: Bool { clientID != nil }

    /// The SDK's IN-MEMORY user. Nil in a process that has not restored
    /// or signed in yet, whatever the Keychain holds — see
    /// `restorePreviousSession()`, which is what makes this true at
    /// launch for an already-connected household.
    var isSignedIn: Bool { GIDSignIn.sharedInstance.currentUser != nil }

    var accountEmail: String? { GIDSignIn.sharedInstance.currentUser?.profile?.email }

    /// Whether the connected account holds every scope the share path
    /// needs, read from the SDK's own record of the grant.
    ///
    /// `grantedScopes` is optional in the SDK, and an absent list reads
    /// as EMPTY rather than as "assume granted": the cost of the
    /// assumption being wrong is a queue that fails item by item with a
    /// 401, and the cost of being right about a missing grant is one
    /// honest line on the Settings card.
    var hasRequiredScopes: Bool {
        guard let granted = GIDSignIn.sharedInstance.currentUser?.grantedScopes else {
            return false
        }
        return Self.grantsRequiredScopes(granted)
    }

    /// Whether a granted-scope list satisfies `requiredScopes`.
    ///
    /// The comparison normalizes the `https://www.googleapis.com/auth/`
    /// prefix instead of string-matching one spelling, because the two
    /// ends of this value do not agree on one: the consent request is
    /// written in the URL form Google's screen displays, while the SDK's
    /// own scope helper (`GIDScopes`) stores and compares the SHORT form
    /// (`email`, `profile`), and Google's token endpoint has returned
    /// both spellings over the SDK's lifetime. An exact match against
    /// either form would silently read a granted scope as missing — which
    /// is the failure mode this whole change exists to remove.
    ///
    /// Normalizing the prefix is ALL it does: the comparison itself stays
    /// exact, so `calendar` and `calendar.events` remain two different
    /// grants (2026-09-17). Google's hierarchy is real and one-directional
    /// — the wide grant covers everything the narrow one does, not the
    /// other way round — and a list holding only `calendar.events` cannot
    /// list or create a calendar, which is the 403 this feature hit on a
    /// device. Nothing here may be written to read the narrow grant as
    /// satisfying the wide one.
    static func grantsRequiredScopes(_ granted: [String]) -> Bool {
        let normalized = Set(granted.map(normalizeScope))
        return requiredScopes.allSatisfy { normalized.contains(normalizeScope($0)) }
    }

    private static func normalizeScope(_ scope: String) -> String {
        let prefix = "https://www.googleapis.com/auth/"
        return scope.hasPrefix(prefix) ? String(scope.dropFirst(prefix.count)) : scope
    }

    // MARK: - Flows

    /// Presents Google's sign-in flow AND the Calendar/contacts consent
    /// that must follow it.
    ///
    /// There is deliberately NO "already signed in → connected" shortcut
    /// even though the contract would allow one: the case the user is
    /// actually here for is the one where the SDK still reports a user
    /// whose token Google has revoked, or whose grant was never given,
    /// and skipping the flow would leave them with no way to
    /// re-authorise from this screen.
    func signIn() async -> GoogleSessionOutcome {
        await interactiveFlow(event: "calendar_share_session_sign_in")
    }

    /// Presents Google's account-CREATION flow, for the household where
    /// the elder has no Google account at all (design §2 decision 3).
    ///
    /// DEVIATION, and it is the SDK's, not this app's: GoogleSignIn 8.0.0
    /// exposes NO distinct create-account entry point. The public surface
    /// (`Sources/Public/GoogleSignIn/GIDSignIn.h`) offers
    /// `signInWithPresentingViewController:`, `restorePreviousSignIn` and
    /// `addScopes:` — the SDK's internal options type that would carry a
    /// "create an account" intent is not public, and `signIn` is the only
    /// interactive entry point. So this presents the
    /// STANDARD sign-in flow, whose Google-hosted screen is where Google
    /// itself offers "Create account"; the elder with no account reaches
    /// account creation one tap in, on Google's own page, without this app
    /// pretending to a distinction the SDK does not expose. The method
    /// still exists as its own seam because that is what the elder's
    /// screen calls and what a future SDK with a real entry point would
    /// change in exactly one place.
    func createAccount() async -> GoogleSessionOutcome {
        await interactiveFlow(event: "calendar_share_session_create_account")
    }

    // MARK: - Scope ledger (2026-09-17)

    var requiredScopes: [String] { Self.requiredScopes }

    /// [SCOPE-LEDGER] Asks Google for the SPECIFIC scopes the ledger
    /// found missing — the card's Grant button. Presents the consent
    /// sheet for exactly those scopes; the fresh post-grant token is
    /// cached the same way sign-in caches it, so the very next gateway
    /// call carries the new grant.
    func grantScopes(_ scopes: [String]) async -> Bool {
        guard !scopes.isEmpty else { return true }
        guard let clientID else {
            emit("calendar_share_session_scopes_grant_failed",
                 outcome: "failure", errorCode: "not_configured")
            return false
        }
        guard let controller = presenter?() else {
            emit("calendar_share_session_scopes_grant_failed",
                 outcome: "failure", errorCode: "no_presenter")
            return false
        }
        let flow = self.flow
        let outcome = await Self.runScopeGrant(clientID: clientID, flow: flow,
                                               controller: controller, scopes: scopes)
        switch outcome {
        case .granted(let auth):
            remember(auth)
            emit("calendar_share_session_scopes_granted", outcome: "success")
            return true
        case .declined:
            // The elder's decision, not a failure — the card keeps the
            // Grant button and the console names the choice.
            emit("calendar_share_session_scopes_declined", outcome: "cancelled")
            return false
        case .failed(let code):
            emit("calendar_share_session_scopes_grant_failed",
                 outcome: "failure", errorCode: code)
            return false
        }
    }

    /// The three ways a scope grant can land. `.granted` carries the
    /// post-grant auth result (token included) so the session's cache is
    /// updated from the same value the flow handed over.
    private enum ScopeGrantOutcome {
        case granted(GoogleAuthResult)
        case declined
        case failed(String)
    }

    /// Presents the consent sheet for `scopes` and reduces the SDK's
    /// answer to the outcome. Main-actor confined like every other flow.
    @MainActor private static func runScopeGrant(clientID: String,
                                                 flow: GoogleAuthFlow,
                                                 controller: UIViewController,
                                                 scopes: [String]) async -> ScopeGrantOutcome {
        configureSDK(clientID: clientID)
        do {
            let result = try await flow.addScopes(scopes, presenting: controller)
            // Same judgement as the sign-in flow: the sheet succeeded but
            // the grant did not land is a refusal to report, not a grant
            // to pretend at.
            return grantsRequiredScopes(result.grantedScopes)
                ? .granted(result)
                : .declined
        } catch {
            let code = (error as NSError).code
            // The SDK's "already granted" arrives through the error
            // channel when its own record lags the auth state — that IS
            // a grant (the token cache is left alone: there is no fresh
            // token to remember, and the existing one is the granted
            // one).
            if code == GIDSignInError.scopesAlreadyGranted.rawValue {
                return .granted(GoogleAuthResult(grantedScopes: scopes,
                                                 accessToken: "",
                                                 expiresAt: nil))
            }
            if code == GIDSignInError.canceled.rawValue {
                return .declined
            }
            return .failed("sdk_\(code)")
        }
    }

    /// Brings back the account a previous launch connected (2026-09-17).
    ///
    /// This is the SDK's own documented app-start entry point: its header
    /// says not to call `signIn` during launch and to call
    /// `restorePreviousSignIn` instead. Nothing is presented, no
    /// presenter is consulted, and it is safe to call before a window
    /// exists — which is precisely where it is called from.
    ///
    /// Idempotent and cheap when a session is already in memory: a signed
    /// in device answers `connected`/`connectedWithoutScopes` from the
    /// live user without touching the Keychain again. That is what lets
    /// the call sit on the foreground path as well as the launch path —
    /// a restore that failed at launch (offline, Google unreachable for
    /// the token refresh) is simply retried on the next activation
    /// instead of leaving the household signed out for the whole process.
    ///
    /// The scope grant is READ, never requested: a restored account that
    /// is missing `calendar`/`contacts` is reported honestly as
    /// `connectedWithoutScopes` and no sheet is shown. Asking at launch
    /// would put Google's consent screen in front of an elder who
    /// opened the app to check the time.
    func restorePreviousSession() async -> GoogleSessionOutcome {
        guard let clientID else {
            // Same degradation as the interactive flows: with no OAuth
            // client the SDK cannot be configured, so there is nothing
            // to restore and nothing is claimed. No event beyond the
            // failure is emitted, because nothing was attempted.
            emit("calendar_share_session_restore_failed", outcome: "failure",
                 errorCode: "not_configured")
            return .unavailable
        }
        if isSignedIn {
            // Already live in this process — a foreground re-entry, or a
            // restore that landed earlier. Re-running it would re-read
            // the Keychain for an answer already held, and reporting a
            // skip as a restore would inflate the event the launch path
            // is read for.
            emit("calendar_share_session_restore_skipped", outcome: "success")
            return hasRequiredScopes ? .connected : .connectedWithoutScopes
        }
        // Read before the hop, like `interactiveFlow`: the SDK object is
        // the seam, and it must not be re-read from inside the awaited
        // call.
        let flow = self.flow
        let outcome = await Self.runRestore(clientID: clientID, flow: flow)
        switch outcome {
        case .restored(let auth):
            remember(auth)
            emit("calendar_share_session_restore", outcome: "success")
            return .connected
        case .restoredWithoutScopes(let auth):
            // Restored, and unable to share. Its own event rather than a
            // failure, exactly as on the interactive path: the session
            // is REAL, and what is missing is a grant the family can
            // give from Settings.
            //
            // The token is kept even so: it is what the account is
            // spending right now, and a cache entry the seed of the next
            // re-connect will overwrite is worth more than an empty one.
            remember(auth)
            emit("calendar_share_session_restore_scopes_missing",
                 outcome: "failure", errorCode: "scopes_not_granted")
            return .connectedWithoutScopes
        case .noPreviousSession:
            // A fresh install, or an elder who signed out — the ordinary
            // state of a device that never connected, and NOT a failure.
            // The card's `signedOut` is the truth here. Nothing is held
            // either: whatever this process cached belongs to a session
            // the Keychain no longer has.
            grantedToken = nil
            emit("calendar_share_session_restore_no_previous", outcome: "success")
            return .unavailable
        case .failed(let code):
            // A revoked grant, a Keychain failure, a dead network on the
            // refresh. The session is left exactly as it is — absent —
            // which is the honest degradation: `isSignedIn` stays false,
            // the card says signed out, and the next launch or
            // activation tries again. The cached token goes with it: a
            // credential the restore just failed to re-establish is not
            // one to keep handing to the gateway.
            grantedToken = nil
            emit("calendar_share_session_restore_failed", outcome: "failure",
                 errorCode: code)
            return .unavailable
        }
    }

    /// Drops the session. Synchronous, and safe off the main actor: the
    /// SDK clears its Keychain entry and does no UI work here, so there is
    /// nothing to hop for — and the protocol is synchronous, so a hop
    /// would have to be a lie (a fire-and-forget task racing the caller's
    /// next read of `isSignedIn`).
    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        // The cached token is a credential for the account just dropped,
        // so it goes in the same breath: keeping it would leave a second,
        // invisible session behind the one the elder ended.
        grantedToken = nil
        emit("calendar_share_session_signed_out", outcome: "success")
    }

    /// A currently-valid access token: the one minted for the current
    /// grant when it is held and still fresh, otherwise a silent refresh
    /// (2026-09-17).
    ///
    /// nil covers "not configured", "no session" and "refresh failed"
    /// alike, which is what the caller's pause-and-retry decision needs;
    /// the three are told apart in observability, not in this return
    /// value.
    func accessToken() async -> String? {
        guard isConfigured else { return nil }
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            // No session in memory: whatever was cached belongs to an
            // account this process can no longer ask Google about, so it
            // goes with the session rather than outliving it.
            grantedToken = nil
            return nil
        }
        // The grant-time token FIRST, and the silent refresh only when
        // there is none or it has expired. Refreshing here is precisely
        // the call that hands back the pre-grant token for up to an hour
        // after the elder consented — see `grantedToken` — so it is the
        // fallback, never the default.
        let instant = now()
        if let granted = grantedToken, granted.isFresh(at: instant) {
            return granted.value
        }
        let refreshed: GoogleAccessToken? = await withCheckedContinuation { continuation in
            // The SDK calls back on the main queue; resuming a continuation
            // from there is fine, and the refresh itself is the SDK's
            // business (it owns the Keychain, the expiry and the retry).
            user.refreshTokensIfNeeded { refreshedUser, _ in
                guard let refreshedUser,
                      !refreshedUser.accessToken.tokenString.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                // A refresh that produced a token is the freshest thing
                // this process has seen, so it is kept under the same
                // rule as a flow's — including its own expiry, which is
                // what stops the cache from outliving it.
                continuation.resume(returning: GoogleAccessToken(
                    value: refreshedUser.accessToken.tokenString,
                    expiresAt: refreshedUser.accessToken.expirationDate
                        ?? instant.addingTimeInterval(Self.unreportedTokenLifetime)))
            }
        }
        guard let refreshed else {
            // Only the FAILED-refresh case is reported here: "no session"
            // is a normal state that the gateway already reports as
            // `.notSignedIn` when it calls this, and emitting both would
            // double-count one absence. An expired cache entry is left
            // where it is: it is only ever preferred while it looks
            // fresh, so the next call retries the refresh either way.
            emit("calendar_share_session_token_refresh_failed", outcome: "failure",
                 errorCode: "no_token")
            return nil
        }
        grantedToken = refreshed
        return refreshed.value
    }

    /// Keeps the token a flow just handed over. LAST write wins: every
    /// flow result is newer than anything held before it, and the whole
    /// point of the cache is that the newest one is the one minted for
    /// the grant the elder just gave.
    ///
    /// A result with no usable token string (empty — the gateway rejects
    /// those anyway) leaves the previous entry alone rather than wiping a
    /// working token with nothing.
    private func remember(_ auth: GoogleAuthResult) {
        guard !auth.accessToken.isEmpty else { return }
        grantedToken = GoogleAccessToken(
            value: auth.accessToken,
            expiresAt: auth.expiresAt
                ?? now().addingTimeInterval(Self.unreportedTokenLifetime))
    }

    // MARK: - Flow internals

    /// The five ways an interactive flow can end. `signedIn`,
    /// `signedInWithoutScopes` and `cancelled` are user outcomes; the
    /// other two are states of the app.
    private enum FlowOutcome: Equatable {
        /// Signed in AND holding every scope the share path needs.
        case signedIn
        /// Signed in, but the Calendar/contacts grant is not there.
        /// `declined` splits the elder's own choice (they closed the
        /// consent sheet) from Google's refusal — the same end state,
        /// two different things to report.
        case signedInWithoutScopes(declined: Bool)
        /// The elder closed Google's sheet. Not an error, and worth its
        /// own outcome: a run of these is a product signal, not a bug.
        case cancelled
        /// No view controller to present from — the window is gone, or the
        /// caller never assigned one. The honest answer is "did not
        /// happen", not a crash and not a silent success.
        case noPresenter
        /// The SDK failed. Carries its NUMERIC code only; never the
        /// error's description.
        case failed(String)
    }

    /// Runs one interactive flow and reports its outcome.
    ///
    /// The flow itself lives in a `@MainActor` function that is simply
    /// awaited: the presenting controller must be READ and the sheet
    /// STARTED on the main actor, and the SDK's async form resumes where
    /// the answer is known — so there is no callback to bridge and no
    /// continuation to reason about.
    private func interactiveFlow(event: String) async -> GoogleSessionOutcome {
        guard let clientID else {
            emit("\(event)_failed", outcome: "failure", errorCode: "not_configured")
            return .unavailable
        }
        // Read before the hop, so the main-actor work never reaches back
        // into `self` for state that can change while the sheet is open.
        let presenter = self.presenter
        let flow = self.flow
        let report = await Self.runFlow(clientID: clientID,
                                        presenter: presenter,
                                        flow: flow)
        // The token comes back BEFORE the branch below, and for every
        // ending that has a session: an elder who declined the consent
        // sheet is still signed in, and the sign-in's own token is the
        // freshest this process holds for them.
        if let auth = report.auth { remember(auth) }
        switch report.outcome {
        case .signedIn:
            emit(event, outcome: "success")
            return .connected
        case .signedInWithoutScopes(let declined):
            // Its own event type rather than a failed sign-in: the
            // session EXISTS. A card that reported this as a failure
            // would send the family looking for a problem with the
            // account instead of tapping the consent again.
            emit("\(event)_scopes_missing",
                 outcome: declined ? "cancelled" : "failure",
                 errorCode: declined ? nil : "scopes_not_granted")
            return .connectedWithoutScopes
        case .cancelled:
            emit("\(event)_cancelled", outcome: "cancelled")
            return .cancelled
        case .noPresenter:
            emit("\(event)_failed", outcome: "failure", errorCode: "no_presenter")
            return .unavailable
        case .failed(let code):
            emit("\(event)_failed", outcome: "failure", errorCode: code)
            return .unavailable
        }
    }

    /// One interactive flow's result: how it ended, plus the token the
    /// session was holding when it did.
    ///
    /// The token rides BESIDE the outcome rather than as a case on it,
    /// because it is not part of that vocabulary: every ending that
    /// leaves a live session produces one — including both
    /// "signed in without the scopes" endings — and the cache wants it in
    /// all of them, while the endings with no session (cancelled, no
    /// presenter, failed) produce none.
    private struct FlowReport {
        let outcome: FlowOutcome
        let auth: GoogleAuthResult?
    }

    /// How a RESTORE ended.
    ///
    /// Its own type rather than a reuse of `FlowOutcome`, and the two
    /// share no interesting case: a restore is never cancelled (it shows
    /// no sheet), never lacks a presenter (it takes none), and cannot
    /// come back "signed in" with nothing to say about it — while an
    /// interactive flow can never end in "there was nobody to sign in".
    /// One shared enum would mean writing two branches that can never run
    /// and hoping no reader takes them for live paths.
    private enum RestoreOutcome: Equatable {
        /// A session is back AND holds every scope the share path needs.
        /// Carries the restored user's scopes-and-token, so the cache
        /// starts this process with the token the restore refreshed
        /// rather than asking the SDK for it again.
        case restored(GoogleAuthResult)
        /// A session is back, without the Calendar/contacts grant. Not
        /// asked for again here — see `restorePreviousSession`.
        case restoredWithoutScopes(GoogleAuthResult)
        /// The SDK held no account to restore.
        case noPreviousSession
        /// The SDK failed. Carries its NUMERIC code only, never the
        /// error's description (constitution C9).
        case failed(String)
    }

    /// One restore, on the main actor, as a value.
    ///
    /// The configuration step is the SAME one the interactive flow runs,
    /// and it has to happen first: `GIDConfiguration` carries the OAuth
    /// client id, and a restore that needs to refresh an expired token
    /// with no configuration to refresh against would fail for a reason
    /// that has nothing to do with the household's account.
    ///
    /// `hasPreviousSignIn` is asked BEFORE the restore so "nothing stored
    /// to restore" is a value the caller can report as the ordinary state
    /// it is, rather than as an SDK error the family should worry about.
    /// The SDK's own header documents the same split.
    @MainActor private static func runRestore(clientID: String,
                                              flow: GoogleAuthFlow) async -> RestoreOutcome {
        configureSDK(clientID: clientID)
        guard flow.hasPreviousSignIn() else { return .noPreviousSession }
        do {
            let auth = try await flow.restorePreviousSignIn()
            return grantsRequiredScopes(auth.grantedScopes)
                ? .restored(auth)
                : .restoredWithoutScopes(auth)
        } catch {
            // Every failure lands here — a revoked grant
            // (`hasNoAuthInKeychain`), a Keychain error, a cancelled
            // refresh, a dead network. They are told apart by the numeric
            // code in observability and are the SAME state to the app: no
            // session, honestly reported.
            return .failed("sdk_\((error as NSError).code)")
        }
    }

    /// One interactive flow, on the main actor, as a value.
    ///
    /// `signIn(withPresenting:)`'s async form is the SAME entry point the
    /// completion-handler form calls — the SDK derives it — so this is
    /// Google's flow, not a re-implementation of it.
    ///
    /// The scope request is a SECOND sheet on purpose. GoogleSignIn 8.0.0
    /// offers `additionalScopes` only on a `signInWithPresentingViewController:`
    /// overload the Swift async interface does not expose (there is one
    /// async `signIn(withPresenting:)`, and it asks for identity alone),
    /// so the only supported path to a Calendar grant is `addScopes` on
    /// the user it returns. Asking at sign-in time was the bug this
    /// method exists to fix: the token came back without the
    /// calendar/contacts grant, and every Calendar call answered 401.
    @MainActor private static func runFlow(clientID: String,
                                           presenter: (() -> UIViewController?)?,
                                           flow: GoogleAuthFlow) async -> FlowReport {
        // Configure (or re-hand the config to) the SDK before the first
        // presentation. `GIDConfiguration` is the client id and nothing
        // else: this app has no home server to name as a `serverClientID`,
        // and the share path authenticates to Google's own APIs with the
        // user's token, not to a backend of ours.
        configureSDK(clientID: clientID)
        guard let controller = presenter?() else {
            return FlowReport(outcome: .noPresenter, auth: nil)
        }
        do {
            // The result carries the scopes AND the token: `GIDSignInResult.user`
            // is NON-OPTIONAL in the async interface (verified against 8.0.0 —
            // the Swift importer turns the completion form's `_Nullable`
            // result into a thrown error instead), so returning without
            // throwing IS a signed-in user, and the two open questions are
            // what it was allowed to do and which token it holds.
            let auth = try await flow.signIn(presenting: controller)
            if grantsRequiredScopes(auth.grantedScopes) {
                return FlowReport(outcome: .signedIn, auth: auth)
            }
            return await requestScopes(flow: flow, controller: controller, signIn: auth)
        } catch {
            return FlowReport(outcome: outcome(for: error), auth: nil)
        }
    }

    /// The consent sheet, and the three ways it can land.
    ///
    /// `signIn` is the result the sign-in sheet produced, carried in as
    /// the session's fallback token: the elder who declines this sheet is
    /// still signed in, and their sign-in token is then the freshest one
    /// the process holds.
    @MainActor private static func requestScopes(flow: GoogleAuthFlow,
                                                 controller: UIViewController,
                                                 signIn: GoogleAuthResult) async -> FlowReport {
        do {
            let auth = try await flow.addScopes(requiredScopes, presenting: controller)
            // Granted list still short after a SUCCESSFUL call: Google
            // accepted the request and did not add the grant (a
            // workspace admin restriction is the usual reason). Nothing
            // the elder can re-tap fixes that, so it is reported as a
            // refusal rather than as a decline.
            //
            // The token still comes back with it — it is the token the
            // account is spending, and throwing it away here is how the
            // NEXT call would end up with the pre-grant one again.
            return grantsRequiredScopes(auth.grantedScopes)
                ? FlowReport(outcome: .signedIn, auth: auth)
                : FlowReport(outcome: .signedInWithoutScopes(declined: false), auth: auth)
        } catch {
            let code = (error as NSError).code
            // The SDK's "these scopes are already granted" — thrown when
            // its own `grantedScopes` record has not caught up with the
            // auth state. That is the SUCCESS case arriving through the
            // error channel, and reporting it as a refusal would leave a
            // fully-authorized household staring at a warning. No token
            // comes back through an error, so the sign-in's is the one to
            // keep — the SDK is asserting the grant predates it.
            if code == GIDSignInError.scopesAlreadyGranted.rawValue {
                return FlowReport(outcome: .signedIn, auth: signIn)
            }
            // Closing the consent sheet is a DECISION, not a failure:
            // the elder is signed in and chose not to hand over their
            // calendar. Same end state as a refusal, different outcome
            // to report.
            if code == GIDSignInError.canceled.rawValue {
                return FlowReport(outcome: .signedInWithoutScopes(declined: true), auth: signIn)
            }
            // Anything else is the SDK failing around a real session, so
            // the session is kept and reported honestly rather than
            // discarding a working sign-in over a scope-sheet error.
            return FlowReport(outcome: .signedInWithoutScopes(declined: false), auth: signIn)
        }
    }

    @MainActor private static func configureSDK(clientID: String) {
        guard !isSDKConfigured else { return }
        // `serverClientID: nil` is explicit rather than omitted: it is the
        // property that decides whether the SDK will ask for a server auth
        // code, and this app has no server to send one to.
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID,
                                                                  serverClientID: nil)
        isSDKConfigured = true
    }

    /// The SDK's failure as a content-free outcome. The code is read
    /// through the SDK's own enum so a future version's renumbering is a
    /// compile error here rather than a mislabelled outcome in a log.
    ///
    /// The spelling is `GIDSignInError.canceled`, verified against
    /// GoogleSignIn 8.0.0: the header's typedef is `GIDSignInErrorCode`
    /// (from `NS_ERROR_ENUM`), and the Swift importer drops the `Code`
    /// suffix — `GIDSignInErrorCode` is NOT a name in scope.
    private static func outcome(for error: Error) -> FlowOutcome {
        let code = (error as NSError).code
        if code == GIDSignInError.canceled.rawValue { return .cancelled }
        return .failed("sdk_\(code)")
    }

    // MARK: - Observability

    /// The single emitter — component `calendar_share_session`, snake_case
    /// event types, and NO free-form metadata parameter at all. That last
    /// part is the privacy rule made structural: a call site holding a
    /// profile, an address or an OAuth error cannot pass any of them
    /// through, because there is nowhere to put them.
    ///
    /// `durationMs` is nil: an interactive flow's duration is mostly the
    /// elder reading Google's screen, so it measures nothing this app can
    /// act on (the timings worth recording are the REST calls', and those
    /// are emitted by the gateway).
    private func emit(_ eventType: String, outcome: String, errorCode: String? = nil) {
        observabilityBus.emit(ObservabilityEvent(
            component: "calendar_share_session",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: [:]
        ))
    }
}

// MARK: - The SDK's interactive surface

/// `GIDSignIn` as a `GoogleAuthFlow` — Google's own entry points, with
/// each result reduced to the scopes this app acts on and the token that
/// carries them.
///
/// Everything here is a translation and nothing else: no policy, no
/// retries, no interpretation of which scopes matter. The session owns
/// those decisions, which is what keeps the declined-grant path a unit
/// test.
///
/// The TOKEN is taken off the user each flow RETURNED, never off
/// `GIDSignIn.sharedInstance.currentUser` afterwards. That is not a
/// style preference: the two disagree for up to an hour after a grant
/// (the shared instance keeps its pre-grant token while it still looks
/// fresh), and reaching for the shared one is precisely the bug this
/// seam was widened to fix.
///
/// `grantedScopes` is `_Nullable` in the SDK's header, and an absent
/// list is returned as EMPTY rather than as "assume granted": the cost of
/// the assumption being wrong is a queue that fails item by item with a
/// 401, and the cost of being right about a missing grant is one honest
/// line on the Settings card.
final class GoogleSignInAuthFlow: GoogleAuthFlow {

    func signIn(presenting controller: UIViewController) async throws -> GoogleAuthResult {
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: controller)
        return Self.authResult(for: result.user)
    }

    /// The SDK's Keychain cache, asked synchronously (there is nothing to
    /// await: no network, no UI, no callback — the header declares this
    /// as a plain `BOOL`).
    func hasPreviousSignIn() -> Bool {
        GIDSignIn.sharedInstance.hasPreviousSignIn()
    }

    /// The async form of `restorePreviousSignInWithCompletion:`, taken
    /// from the SAME Objective-C entry point: the completion's nullable
    /// `user` becomes the thrown error case, so a returned user is a real
    /// session and the only open question is what it was allowed to do.
    ///
    /// Configure-only-when-needed is deliberate, and inside the SDK's
    /// contract: restoring an account whose token is still valid does no
    /// network work at all.
    func restorePreviousSignIn() async throws -> GoogleAuthResult {
        let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
        return Self.authResult(for: user)
    }

    /// The consent sheet's result — and the ONLY source of the token
    /// minted for the grant it just added. `user.addScopes` returns the
    /// updated user; asking the shared instance for it afterwards is what
    /// used to hand back the pre-grant token.
    func addScopes(_ scopes: [String],
                   presenting controller: UIViewController) async throws -> GoogleAuthResult {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            // Reachable only if the account vanished between the sign-in
            // sheet and the consent sheet — a sign-out from another
            // surface. Reported in the SDK's own vocabulary for "there is
            // no authenticated user", so the session classifies it as a
            // failed flow rather than as an elder declining a sheet they
            // were never shown.
            throw NSError(domain: kGIDSignInErrorDomain,
                          code: GIDSignInError.hasNoAuthInKeychain.rawValue)
        }
        let result = try await user.addScopes(scopes, presenting: controller)
        return Self.authResult(for: result.user)
    }

    /// One SDK user, reduced to the scopes the session acts on and the
    /// token it holds — the two facts every entry point above returns.
    private static func authResult(for user: GIDGoogleUser) -> GoogleAuthResult {
        GoogleAuthResult(grantedScopes: user.grantedScopes ?? [],
                         accessToken: user.accessToken.tokenString,
                         expiresAt: user.accessToken.expirationDate)
    }
}

// MARK: - Unwired sink

extension GoogleAccountSession {
    /// The sink used when the caller supplies none.
    ///
    /// It exists so `GoogleAccountSession()` can be constructed before the
    /// app has its bus in hand (the coordinator builds both in `lazy var`s)
    /// and so a test that asserts nothing about events can omit the
    /// parameter. It DROPS its events, which is why the production call
    /// site is expected to pass the app's bus: wiring that skips it loses
    /// this component's events, and nothing else about the session.
    static let unwiredBus: ObservabilityBus = DroppingObservabilityBus()
}

/// File-private so it cannot collide with any other component's no-op bus
/// (the test target has one of its own) and cannot be reached from outside
/// this file's default argument.
private final class DroppingObservabilityBus: ObservabilityBus {
    func emit(_ event: ObservabilityEvent) {}
}
