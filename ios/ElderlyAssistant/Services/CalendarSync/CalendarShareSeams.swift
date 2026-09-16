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
    /// 401/403 — the token was revoked or the scope was never granted.
    /// The service pauses and surfaces this rather than retrying.
    case unauthorized
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

    /// Whether a retry could plausibly succeed. `unauthorized` and
    /// `notConfigured` are NOT retryable: retrying a revoked token is a
    /// busy-loop, and the user has to act. `notFound` is not retryable
    /// either — what was there is gone; only a RE-CREATE helps.
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .transport: return true
        case .notSignedIn, .notConfigured, .unauthorized, .notFound,
             .malformedResponse:
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
    /// `unauthorized` is the case this exists for: 401/403 means the
    /// token was revoked or the Calendar/contacts grant was never given,
    /// and the ONLY recovery is the OAuth flow. A card that explains the
    /// failure without offering that tap leaves the household with a
    /// dead end. `notSignedIn` is the same dead end with a different
    /// cause, so it gets the same tap.
    ///
    /// Everything else is either ours to retry (rate limited, 5xx,
    /// transport), already satisfied (`notFound`), or a state no tap on
    /// this card can change (`notConfigured`, `malformedResponse`).
    var isActionableFromSettings: Bool {
        switch self {
        case .unauthorized, .notSignedIn: return true
        case .notConfigured, .rateLimited, .server, .notFound,
             .malformedResponse, .transport:
            return false
        }
    }
}

// MARK: - Interactive auth flow

/// The GoogleSignIn SDK's interactive entry points, reduced to the ONE
/// fact this app acts on: the scopes the account holds when the sheet
/// closes.
///
/// A protocol rather than calls straight into `GIDSignIn.sharedInstance`
/// because the branch that matters most cannot be reached any other way.
/// An interactive OAuth flow needs an OAuth client, a real Google
/// account and a human tapping Google's sheet, so "the elder signed in
/// and then DECLINED the calendar grant" — the exact state this feature
/// shipped a bug in — would be a device-only path that no test could
/// pin. Behind this seam it is a one-line fake.
///
/// Presentation is passed in rather than resolved here: the presenter is
/// a UI concern the session already owns, and a seam that looked up a
/// window itself could not be driven from a test at all.
protocol GoogleAuthFlow: AnyObject {
    /// Presents Google's sign-in sheet. Returns the scopes the account
    /// holds afterwards. Throws whatever the SDK threw — the session
    /// maps the code, and never the description (constitution C9).
    func signIn(presenting controller: UIViewController) async throws -> [String]

    /// Presents Google's scope-consent sheet on the current user for
    /// `scopes`, returning the scopes held afterwards.
    ///
    /// The scopes are passed IN rather than read from a constant here so
    /// the session stays the one place that decides what this feature
    /// needs.
    func addScopes(_ scopes: [String],
                   presenting controller: UIViewController) async throws -> [String]
}

// MARK: - Interactive flow outcome

/// How one interactive Google flow ended, as a value.
///
/// A `Bool` is not enough, and the case it cannot express is the whole
/// reason this type exists: the scope sheet can close with the elder
/// SIGNED IN and having declined the calendar/contacts grant. "Signed in"
/// and "can share" are different facts, and a card that folds them into
/// one tells the family their reminders are going out when nothing can
/// reach Google at all.
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
    /// Whether a usable session exists right now. The SDK answers this
    /// from its Keychain-stored account, so it survives relaunches.
    var isSignedIn: Bool { get }
    /// The connected account's address, for the Settings card. Never
    /// logged.
    var accountEmail: String? { get }

    /// Whether the connected account holds EVERY scope the share path
    /// needs (`calendar.events` + `contacts`).
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

    /// Drops the session. Tokens are cleared from the Keychain; the
    /// share queue is NOT touched here (the service owns that decision).
    func signOut()

    /// A currently-valid access token, refreshing silently when needed.
    /// nil means "no session" or "refresh failed" — the caller pauses
    /// rather than guessing which.
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
