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
/// Nothing personal is stored here. The SDK keeps the account and its
/// tokens in the Keychain; this type adds no storage of its own — in
/// particular it never mirrors a token into `UserDefaults`, where a
/// credential would sit in a plaintext plist (the share layer's other
/// defaults entry — the inbound sync token — is opaque and non-personal by
/// comparison).
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
    /// `calendar.events` is the narrowest grant that can create, rewrite
    /// and delete the family's twins — deliberately NOT the full
    /// `calendar` scope, which would also hand over every calendar the
    /// account can see. `contacts` is what `People v1` needs to put the
    /// caregiver in the elder's own address book before inviting them
    /// (design §4.2 — an invite from an unknown address lands in spam).
    ///
    /// `profile`/`email` are not listed: the SDK asks for identity as
    /// part of its own sign-in flow, and asking twice would show the
    /// elder a consent screen listing a permission they already gave.
    static let requiredScopes = [
        "https://www.googleapis.com/auth/calendar.events",
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
         defaults: UserDefaults = .standard) {
        // Deliberately NIL-safe: no permission prompt, no SDK call and no
        // network work happens at construction (the coordinator builds
        // this in a lazy var during launch), and an absent client id is a
        // supported state rather than a failure.
        self.clientID = clientID
        self.presenter = presenter
        self.flow = flow
        self.observabilityBus = observabilityBus
        // `defaults` is accepted to keep the share layer's construction
        // shape uniform and is deliberately UNUSED: the SDK owns the
        // account state (Keychain) and nothing about a Google session
        // belongs in a plist. It stays in the signature so a caller can
        // pass the app's suite without a special case here.
        _ = defaults
    }

    // MARK: - Configuration

    var isConfigured: Bool { clientID != nil }

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

    /// Drops the session. Synchronous, and safe off the main actor: the
    /// SDK clears its Keychain entry and does no UI work here, so there is
    /// nothing to hop for — and the protocol is synchronous, so a hop
    /// would have to be a lie (a fire-and-forget task racing the caller's
    /// next read of `isSignedIn`).
    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        emit("calendar_share_session_signed_out", outcome: "success")
    }

    /// A currently-valid access token, refreshed silently if needed.
    ///
    /// nil covers "not configured", "no session" and "refresh failed"
    /// alike, which is what the caller's pause-and-retry decision needs;
    /// the three are told apart in observability, not in this return
    /// value.
    func accessToken() async -> String? {
        guard isConfigured else { return nil }
        guard let user = GIDSignIn.sharedInstance.currentUser else { return nil }
        let token: String? = await withCheckedContinuation { continuation in
            // The SDK calls back on the main queue; resuming a continuation
            // from there is fine, and the refresh itself is the SDK's
            // business (it owns the Keychain, the expiry and the retry).
            user.refreshTokensIfNeeded { refreshed, error in
                continuation.resume(returning: refreshed?.accessToken.tokenString)
            }
        }
        if token == nil {
            // Only the FAILED-refresh case is reported here: "no session"
            // is a normal state that the gateway already reports as
            // `.notSignedIn` when it calls this, and emitting both would
            // double-count one absence.
            emit("calendar_share_session_token_refresh_failed", outcome: "failure",
                 errorCode: "no_token")
        }
        return token
    }

    // MARK: - Interactive flow

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
        let outcome = await Self.runFlow(clientID: clientID,
                                         presenter: presenter,
                                         flow: flow)
        switch outcome {
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
    /// method exists to fix: the token came back without
    /// `calendar.events`, and every Calendar call answered 401.
    @MainActor private static func runFlow(clientID: String,
                                           presenter: (() -> UIViewController?)?,
                                           flow: GoogleAuthFlow) async -> FlowOutcome {
        // Configure (or re-hand the config to) the SDK before the first
        // presentation. `GIDConfiguration` is the client id and nothing
        // else: this app has no home server to name as a `serverClientID`,
        // and the share path authenticates to Google's own APIs with the
        // user's token, not to a backend of ours.
        configureSDK(clientID: clientID)
        guard let controller = presenter?() else { return .noPresenter }
        do {
            // The result is reduced to its granted scopes: `GIDSignInResult.user`
            // is NON-OPTIONAL in the async interface (verified against 8.0.0 —
            // the Swift importer turns the completion form's `_Nullable`
            // result into a thrown error instead), so returning without
            // throwing IS a signed-in user, and the only open question is
            // what it was allowed to do.
            let granted = try await flow.signIn(presenting: controller)
            if grantsRequiredScopes(granted) { return .signedIn }
            return await requestScopes(flow: flow, controller: controller)
        } catch {
            return outcome(for: error)
        }
    }

    /// The consent sheet, and the three ways it can land.
    @MainActor private static func requestScopes(flow: GoogleAuthFlow,
                                                 controller: UIViewController) async -> FlowOutcome {
        do {
            let granted = try await flow.addScopes(requiredScopes, presenting: controller)
            // Granted list still short after a SUCCESSFUL call: Google
            // accepted the request and did not add the grant (a
            // workspace admin restriction is the usual reason). Nothing
            // the elder can re-tap fixes that, so it is reported as a
            // refusal rather than as a decline.
            return grantsRequiredScopes(granted) ? .signedIn
                                                 : .signedInWithoutScopes(declined: false)
        } catch {
            let code = (error as NSError).code
            // The SDK's "these scopes are already granted" — thrown when
            // its own `grantedScopes` record has not caught up with the
            // auth state. That is the SUCCESS case arriving through the
            // error channel, and reporting it as a refusal would leave a
            // fully-authorized household staring at a warning.
            if code == GIDSignInError.scopesAlreadyGranted.rawValue {
                return .signedIn
            }
            // Closing the consent sheet is a DECISION, not a failure:
            // the elder is signed in and chose not to hand over their
            // calendar. Same end state as a refusal, different outcome
            // to report.
            if code == GIDSignInError.canceled.rawValue {
                return .signedInWithoutScopes(declined: true)
            }
            // Anything else is the SDK failing around a real session, so
            // the session is kept and reported honestly rather than
            // discarding a working sign-in over a scope-sheet error.
            return .signedInWithoutScopes(declined: false)
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
/// each result reduced to the granted-scope list this app acts on.
///
/// Everything here is a translation and nothing else: no policy, no
/// retries, no interpretation of which scopes matter. The session owns
/// those decisions, which is what keeps the declined-grant path a unit
/// test.
///
/// `grantedScopes` is `_Nullable` in the SDK's header, and an absent
/// list is returned as EMPTY rather than as "assume granted": the cost of
/// the assumption being wrong is a queue that fails item by item with a
/// 401, and the cost of being right about a missing grant is one honest
/// line on the Settings card.
final class GoogleSignInAuthFlow: GoogleAuthFlow {

    func signIn(presenting controller: UIViewController) async throws -> [String] {
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: controller)
        return result.user.grantedScopes ?? []
    }

    func addScopes(_ scopes: [String],
                   presenting controller: UIViewController) async throws -> [String] {
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
        return result.user.grantedScopes ?? []
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
