import Foundation
import UIKit

// MARK: - Calendar share seams (calendar & family sharing, 2026-09-16)
//
// The contracts `CalendarShareService` depends on, declared in ONE place
// so the three implementation files (Google REST, Google account
// session, and the service itself) cannot drift apart, and so tests can
// fake each seam in three lines.
//
// House style throughout (`GeminiClient`): production code talks to a
// narrow protocol, the production conformance is a thin side-effect-only
// shell, and every decision worth testing lives above the seam with no
// live network and no UI.

// MARK: - HTTP seam

/// The one HTTP call the Google REST layer makes. Declared as a protocol
/// rather than calling `URLSession` directly for the same reason
/// `GeminiTransport` is: the request-building rules — attendee JSON,
/// RRULE, find-or-create, inbound accept — are worth asserting on, and
/// asserting on them must not require a network.
protocol CalendarShareTransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// `URLSession` as a `CalendarShareTransport`.
///
/// A WRAPPER, not the retroactive `extension URLSession: …` that
/// `GeminiTransport` uses — and the reason is not taste. `GeminiTransport`
/// already gives `URLSession` a `send(_:) async throws -> (Data, URLResponse)`
/// in this module, and a second extension adding the identical member is
/// an "invalid redeclaration of 'send'" compile error, not an ambiguity
/// (both are in the app target, so there is no module boundary to
/// disambiguate across). Renaming either one is worse: `send` is the
/// house name for this seam and the Gemini one cannot move without
/// touching every Gemini fake.
///
/// The wrapper keeps the seam name, keeps the gateway's default argument
/// one word long, and leaves the collision gone for good — a second
/// conformance of an SDK type is something a future reader will not have
/// to notice.
struct URLSessionCalendarShareTransport: CalendarShareTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

// MARK: - Errors

/// Failure classes the share layer distinguishes. Deliberately COARSE and
/// content-free: these values reach observability metadata and the
/// Settings status line, so they must never carry a response body, a
/// title or an address (constitution C9 / the release-log privacy gate).
enum GoogleShareError: Error, Equatable {
    /// The REST layer was used without a session — a programming error,
    /// not a user state (the service gates on sign-in before it gets
    /// here).
    case notSignedIn
    /// No OAuth client id is configured. The honest "not configured"
    /// state (design §0) — never a crash, never a silent no-op.
    case notConfigured
    /// 401 — Google does not accept this token at all: it was revoked, it
    /// expired, or the session behind it is gone. The service pauses and
    /// surfaces this rather than retrying.
    case unauthorized
    /// 403 — the token IS valid and Google knows who is calling, but the
    /// account holds no grant for what was asked (2026-09-17).
    ///
    /// Its own case rather than a second spelling of `unauthorized`
    /// because the two are different stories that were being told as one,
    /// and merging them is exactly how the bug that split them stayed
    /// invisible in a device log: a 403 after a consent sheet means the
    /// token IN HAND was minted for the wrong scopes — the stale-token
    /// bug `GoogleAccountSession` now prevents — while a 401 means there
    /// is no usable session at all. The recovery is the same (the family
    /// reconnects) and so is the pause; the diagnosis is not, and the
    /// card says which one it is.
    case insufficientScopes
    /// 429 / quota. Retryable with backoff.
    case rateLimited
    /// 5xx. Retryable with backoff.
    case server(Int)
    /// 404 — the thing we addressed is GONE (a twin someone deleted on
    /// Google's side). Distinct from the other failures because it is
    /// the one failure with a defined recovery: an update re-creates, a
    /// delete is already satisfied. Folding it into "the write failed"
    /// would make both paths either retry forever or duplicate the
    /// family's event, so the domain outcome gets its own case.
    case notFound
    /// A 2xx whose body did not contain what we asked for.
    case malformedResponse
    /// A transport-level failure. Carries the error CLASS only (a
    /// `URLError.Code` raw value as a string), never a description —
    /// the same no-PII rule as the rest of this type.
    case transport(String)

    /// Whether a retry could plausibly succeed. `unauthorized`,
    /// `insufficientScopes` and `notConfigured` are NOT retryable:
    /// retrying a revoked token or a withheld grant is a busy-loop, and
    /// the user has to act. `notFound` is not retryable either — what was
    /// there is gone; only a RE-CREATE helps.
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .transport: return true
        case .notSignedIn, .notConfigured, .unauthorized, .insufficientScopes,
             .notFound, .malformedResponse:
            return false
        }
    }

    /// Whether this failure means "the session exists but Google will not
    /// accept it for this call" — the class the flush stops a whole pass
    /// on.
    ///
    /// 401 and 403 are two causes of ONE state: nothing queued can
    /// succeed until the family reconnects, so working through the queue
    /// is a busy-loop and an attempt counter is a delay on a dead end.
    /// The two are kept apart in the LOG and on the CARD (401: the
    /// session is gone; 403: the token in hand is scoped wrongly), never
    /// in what the queue does about them.
    ///
    /// `notSignedIn` is deliberately NOT here. It is the SDK holding no
    /// account rather than Google refusing one, the service treats it as
    /// an ordinary failed attempt today, and quietly widening the pause
    /// to cover it would be a behaviour change smuggled in beside a
    /// classification fix.
    var isAuthorizationFailure: Bool {
        switch self {
        case .unauthorized, .insufficientScopes: return true
        case .notSignedIn, .notConfigured, .rateLimited, .server, .notFound,
             .malformedResponse, .transport:
            return false
        }
    }
}

// MARK: - Failure class → Settings wording

extension GoogleShareError {

    /// The string-catalog key for this failure class, resolved in the app
    /// language by the Settings card.
    ///
    /// It lives HERE, beside the enum, rather than as a private switch in
    /// the view, for the reason every catalog lookup in this app does:
    /// an exhaustive switch over the enum is a compile error the moment a
    /// failure class is added, while a `default:` in a view is a silent
    /// English-less card. The associated values of `server` and
    /// `transport` are deliberately dropped — a status code and a
    /// `URLError` class label are diagnostics, not sentences for an
    /// elder, and the release log-surface rule treats them as the same
    /// kind of raw upstream value that must not reach a surface.
    var settingsMessageKey: String {
        switch self {
        case .notSignedIn: return "calendarShare.error.notSignedIn"
        case .notConfigured: return "calendarShare.error.notConfigured"
        case .unauthorized: return "calendarShare.error.unauthorized"
        case .insufficientScopes: return "calendarShare.error.insufficientScopes"
        case .rateLimited: return "calendarShare.error.rateLimited"
        case .server: return "calendarShare.error.server"
        case .notFound: return "calendarShare.error.notFound"
        case .malformedResponse: return "calendarShare.error.malformedResponse"
        case .transport: return "calendarShare.error.transport"
        }
    }

    /// Whether the family can DO something about this failure from the
    /// Settings card — and the one action that helps: connect the account
    /// again.
    ///
    /// `unauthorized` is the case this exists for: a 401 means the token
    /// was revoked, and the ONLY recovery is the OAuth flow. A card that
    /// explains the failure without offering that tap leaves the
    /// household with a dead end. `notSignedIn` is the same dead end with
    /// a different cause, so it gets the same tap. `insufficientScopes`
    /// is the same shape again — 403 rather than 401, the consent
    /// refused rather than the token withdrawn — and its line names the
    /// extra step the fix needs (sign out first, so the SDK cannot hand
    /// back the token it minted without the grant).
    ///
    /// Everything else is either ours to retry (rate limited, 5xx,
    /// transport), already satisfied (`notFound`), or a state no tap on
    /// this card can change (`notConfigured`, `malformedResponse`).
    var isActionableFromSettings: Bool {
        switch self {
        case .unauthorized, .insufficientScopes, .notSignedIn: return true
        case .notConfigured, .rateLimited, .server, .notFound,
             .malformedResponse, .transport:
            return false
        }
    }
}

// MARK: - Auth flow result

/// What one Google flow hands back: the scopes the account holds
/// afterwards, and the access token minted to carry them (2026-09-17).
///
/// The token is here because the scopes ALONE were the whole bug. A grant
/// is only usable through a token minted for it, and the SDK keeps
/// handing back the token it minted BEFORE the elder consented — it still
/// looks fresh for up to an hour — so a session that reduced a flow to
/// its scope list had nothing better to spend and every Calendar call
/// went out with an identity-scoped token. That is the 401/403 the device
/// console showed, and one value taken straight off the user the flow
/// returned is what lets the session keep the good token instead.
///
/// `expiresAt` is the SDK's own estimate (`GIDToken.expirationDate`),
/// which is nullable in the header, so nil is a state callers must handle
/// rather than a value they may assume.
struct GoogleAuthResult: Equatable {
    /// The scopes the account holds when the flow ends.
    let grantedScopes: [String]
    /// The access token the flow produced, exactly as the SDK spelled it.
    let accessToken: String
    /// When that token stops being usable, as the SDK estimates it. Nil
    /// when Google/the SDK reported no expiry.
    let expiresAt: Date?
}

// MARK: - Auth flow

/// The GoogleSignIn SDK's session entry points, reduced to the two facts
/// this app acts on: the scopes the account holds afterwards, and the
/// token that carries them.
///
/// A protocol rather than calls straight into `GIDSignIn.sharedInstance`
/// because the branch that matters most cannot be reached any other way.
/// An interactive OAuth flow needs an OAuth client, a real Google
/// account and a human tapping Google's sheet, so "the elder signed in
/// and then DECLINED the calendar grant" — the exact state this feature
/// shipped a bug in — would be a device-only path that no test could
/// pin. Behind this seam it is a one-line fake.
///
/// The RESTORE pair (2026-09-17) is here for the same reason and is not
/// interactive at all: it needs a Keychain entry a real sign-in wrote,
/// which no simulator test has, and it is the path that decides whether
/// a connected household reads as connected at launch. The seam is
/// named for the session rather than for the sheets because the two
/// halves are the same question asked in two ways — who is signed in,
/// and what are they allowed to do.
///
/// Presentation is passed in rather than resolved here: the presenter is
/// a UI concern the session already owns, and a seam that looked up a
/// window itself could not be driven from a test at all. The restore
/// takes NO presenter, deliberately: it must be callable before a window
/// exists.
protocol GoogleAuthFlow: AnyObject {
    /// Presents Google's sign-in sheet. Returns the scopes the account
    /// holds afterwards, WITH the token that carries them. Throws
    /// whatever the SDK threw — the session maps the code, and never the
    /// description (constitution C9).
    func signIn(presenting controller: UIViewController) async throws -> GoogleAuthResult

    /// Whether the SDK holds an account from a PREVIOUS launch, in its
    /// own Keychain cache. Reads no network and presents nothing, which
    /// is why it is synchronous: it is the decision "is there anything
    /// to restore at all", asked before a restore is attempted.
    ///
    /// `true` is not a promise that the session still works — Google can
    /// have revoked the grant since — so a `true` that is followed by a
    /// throwing restore is the ordinary revoked-token case, not a
    /// contradiction (see `restorePreviousSignIn`).
    func hasPreviousSignIn() -> Bool

    /// Restores that account WITHOUT presenting anything — the entry
    /// point the SDK documents for app start (its own header says not to
    /// call `signIn` from launch and to restore instead).
    ///
    /// Returns the same value `signIn` returns — scopes plus the token
    /// that carries them — so the session's scope policy applies unchanged
    /// to a restored account and its cache starts this process with the
    /// token the restore just refreshed. Throws whatever the SDK threw —
    /// including `kGIDSignInErrorCodeHasNoAuthInKeychain` when the elder
    /// has signed out or revoked the grant since, which the session
    /// reports as a failed restore.
    ///
    /// Refresh is the SDK's business here: it restores from its cache and
    /// silently refreshes an expired token, so a launch restore costs one
    /// network call at most and no user interaction ever.
    func restorePreviousSignIn() async throws -> GoogleAuthResult

    /// Presents Google's scope-consent sheet on the current user for
    /// `scopes`, returning the scopes held afterwards and the token
    /// minted for them.
    ///
    /// This result's token is the whole point of the 2026-09-17 fix: it
    /// is the ONLY place the post-grant token can be obtained, because
    /// the SDK's own refresh hands back the pre-grant one for as long as
    /// that one looks fresh.
    ///
    /// The scopes are passed IN rather than read from a constant here so
    /// the session stays the one place that decides what this feature
    /// needs.
    func addScopes(_ scopes: [String],
                   presenting controller: UIViewController) async throws -> GoogleAuthResult
}

// MARK: - Flow outcome

/// How one Google flow ended, as a value.
///
/// A `Bool` is not enough, and the case it cannot express is the whole
/// reason this type exists: the scope sheet can close with the elder
/// SIGNED IN and having declined the calendar/contacts grant. "Signed in"
/// and "can share" are different facts, and a card that folds them into
/// one tells the family their reminders are going out when nothing can
/// reach Google at all.
///
/// A RESTORED session (2026-09-17) is reported through this same type,
/// and lands in three of the four cases: `connected`,
/// `connectedWithoutScopes`, or `unavailable` for the ways a restore can
/// fail to bring anything back (no stored account, a revoked grant, no
/// client id). It cannot land in `cancelled` — nobody is shown a sheet
/// to close — and the caller's decision is identical for all of them
/// (render the honest status, drain nothing unless `isConnected`).
enum GoogleSessionOutcome: Equatable {
    /// Connected AND holding every scope the share path needs. The only
    /// outcome that unblocks the queue.
    case connected
    /// Signed in, but Google did not grant the calendar/contacts scopes —
    /// declined on the consent sheet, or refused for the account. The
    /// session is real and survives; the share path cannot use it, and
    /// the card says exactly that.
    case connectedWithoutScopes
    /// The elder closed Google's sheet. Not an error, and not a session:
    /// a run of these is a product signal, not a bug.
    case cancelled
    /// No client id, no presenter, or the SDK failed. The flow did not
    /// happen — `isConfigured` and observability tell those three apart;
    /// the CALLER's next move is the same for all of them (render the
    /// honest status).
    case unavailable

    /// Whether a usable, fully-scoped session exists afterwards. The one
    /// question the service's queue asks before it drains anything.
    var isConnected: Bool { self == .connected }
}

// MARK: - Account session

/// The Google account the family connected once, on-device (design
/// §2 decision 3). A protocol so the whole share path is testable
/// without the GoogleSignIn SDK, an OAuth client, or a signed-in
/// simulator.
///
/// `isConfigured` is the graceful-degradation hinge (design §0): with no
/// client id in the bundle, GoogleSignIn cannot even be initialised, and
/// every surface must say so honestly instead of offering a button that
/// cannot work.
protocol GoogleAccountSessionProtocol: AnyObject {
    /// Whether an OAuth client id is present in the bundle.
    var isConfigured: Bool { get }
    /// Whether a usable session exists right now.
    ///
    /// CORRECTED (2026-09-17): the SDK answers this from the account it
    /// holds IN MEMORY, not from the Keychain, so a cold process reports
    /// `false` until `restorePreviousSession()` has run once — the
    /// stored account does not survive a relaunch here, it is only
    /// reachable through the restore. Anything that reads this at launch
    /// must therefore have restored first, or it reads a connected
    /// household as signed out.
    var isSignedIn: Bool { get }
    /// The connected account's address, for the Settings card. Never
    /// logged.
    var accountEmail: String? { get }

    /// Whether the connected account holds EVERY scope the share path
    /// needs (`calendar` + `contacts`).
    ///
    /// Separate from `isSignedIn` because the two are genuinely
    /// different states on a device: an account can be signed in and
    /// still have no Calendar/contacts grant — the elder declined the
    /// consent sheet, the grant was revoked at Google, or the account
    /// was connected by a build that asked for identity alone. Sharing
    /// is impossible in all three, so the card must be able to say so.
    /// False when nobody is signed in, which is why callers read it
    /// only after `isSignedIn`.
    var hasRequiredScopes: Bool { get }

    /// Presents Google's sign-in flow, then asks for the share scopes.
    ///
    /// Returns the OUTCOME rather than a Bool: "cancelled", "failed",
    /// "signed in but without Calendar access" and "fully connected" are
    /// four different things to put on an elder's screen, and only the
    /// last one may start the queue.
    func signIn() async -> GoogleSessionOutcome

    /// Presents Google's account-CREATION flow (design §2 decision 3:
    /// the elder may not have a Google account at all), then signs in.
    func createAccount() async -> GoogleSessionOutcome

    /// Brings back the account a PREVIOUS launch connected, without
    /// presenting anything (2026-09-17).
    ///
    /// Separate from `signIn` rather than folded into it because the two
    /// are the opposite kind of act: one needs a window, a human and a
    /// sheet, the other happens at launch, must never touch the UI, and
    /// is allowed to come back with nothing. `isSignedIn` alone cannot
    /// stand in for it — the SDK holds its account in the Keychain and
    /// answers `currentUser == nil` until this has run once in the
    /// process, so a session that is merely READ at launch reports every
    /// connected household as signed out (the silent-skip bug this
    /// method exists to remove).
    ///
    /// Like `signIn`, the return value is the whole outcome rather than a
    /// Bool: a restored account can turn out to be missing the
    /// Calendar/contacts grant, and that is a different thing to put on
    /// the elder's screen from "no account". Nothing is presented for a
    /// missing grant here — a launch is not the moment to ask, and the
    /// card's re-connect is the path that asks.
    ///
    /// A failure is not an error state of the app: it leaves exactly what
    /// a signed-out device has (`isSignedIn == false`), which is the
    /// honest degradation, and the restore is retried on the next launch
    /// or activation.
    func restorePreviousSession() async -> GoogleSessionOutcome

    /// Drops the session. Tokens are cleared from the Keychain; the
    /// share queue is NOT touched here (the service owns that decision).
    func signOut()

    /// A currently-valid access token, refreshing silently when needed.
    /// nil means "no session" or "refresh failed" — the caller pauses
    /// rather than guessing which.
    ///
    /// The token handed over is the one minted for the CURRENT grant
    /// whenever the session holds it (2026-09-17), because the SDK's
    /// refresh returns the pre-grant token for as long as that one looks
    /// fresh — the reason every Calendar call went out unscoped after a
    /// consent sheet. A silent refresh is the fallback, used when no
    /// grant-time token is held or the one held has expired.
    func accessToken() async -> String?
}

// MARK: - Calendar / People gateway

/// One incoming event from Google, as a plain value — no JSON crosses
/// this seam (the same rule `CalendarEventRecord` follows for EventKit).
struct GoogleIncomingEvent: Equatable {
    let eventId: String
    let title: String
    let startDate: Date
    let endDate: Date?
    /// The organizer's address, when Google reports one. Used for the
    /// imported reminder's context, never for logging.
    let organizerEmail: String?
    /// Whether the elder's own attendee entry says `needsAction` — the
    /// only events the inbound path acts on.
    let needsResponse: Bool
}

/// One page of the inbound listing.
struct GoogleIncomingPage: Equatable {
    let events: [GoogleIncomingEvent]
    /// Google's continuation token. Persisted so the next poll is
    /// incremental; nil when the server did not provide one (the caller
    /// then repeats a full window scan).
    let nextSyncToken: String?
}

/// The Google Calendar v3 + People v1 surface the share service drives.
///
/// Every method is `async` and returns a value-or-nil / Bool rather than
/// throwing: the service's queue treats "did not happen" as the thing it
/// needs to know, and the error CLASS is emitted to observability inside
/// the implementation. Callers that need to distinguish "unauthorized"
/// from "rate limited" read `lastErrorClass` — one property beats a
/// four-way Result on every signature for the two places that care.
protocol GoogleCalendarGatewayProtocol: AnyObject {
    /// Find-or-create the dedicated shared calendar (summary
    /// "Sahayak Family"). Returns its calendar id, or nil when Google
    /// could not be reached or the account is not usable. The id is
    /// cached by the implementation after the first success.
    func ensureFamilyCalendar() async -> String?

    /// Creates the twin. Returns Google's event id, or nil.
    func createEvent(_ draft: CalendarTwinDraft) async -> String?

    /// Rewrites an existing twin. False when the event is gone (404 —
    /// the caller re-creates) or the write failed.
    func updateEvent(id: String, with draft: CalendarTwinDraft) async -> Bool

    /// Removes the twin. False only when the delete FAILED — an
    /// implementation that finds the twin already gone reports true, and
    /// one that reports the 404 as a failure leaves `lastErrorClass` at
    /// `.notFound`, which the caller also reads as "the goal state is
    /// reached". Both spellings drain the same tombstone.
    func deleteEvent(id: String) async -> Bool

    /// People v1: makes sure `email` exists as one of the elder's Google
    /// contacts, creating it when absent (design §4.2 — keeps invites out
    /// of spam). Best-effort: a failure must never block the invite.
    ///
    /// `name` and `phone` are the contact's own details, carried when the
    /// family has them (design §2.2 bullet 4) so the elder's address book
    /// gains a person they can recognise and call — not just an address.
    /// Either may be nil, and the implementation falls back to the
    /// address rather than inventing one.
    func ensureContact(email: String, name: String?, phone: String?) async -> Bool

    /// Events on the elder's primary calendar inside the inbound window.
    /// `syncToken` non-nil requests an incremental page.
    func listIncoming(syncToken: String?) async -> GoogleIncomingPage?

    /// Patches the elder's attendee entry on `eventId` to `accepted`
    /// (no notification emails — the organizer already invited them).
    func acceptInvitation(eventId: String) async -> Bool

    /// The error class from the most recent failed call, for the
    /// service's pause-vs-retry decision. nil after a success.
    var lastErrorClass: GoogleShareError? { get }
}
