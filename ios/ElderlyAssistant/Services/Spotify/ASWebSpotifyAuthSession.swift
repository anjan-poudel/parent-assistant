import Foundation
import AuthenticationServices
import UIKit

// MARK: - C-SP-04 presenter half: the system web-auth session (T-111)

/// The startable slice of `ASWebAuthenticationSession` this feature drives,
/// behind a protocol so the outcome matrix — callback, dismissal, refused
/// start — is a unit test instead of a device session.
///
/// The system class is concrete and cannot be instantiated into a working
/// sheet in a test process, so the seam wraps exactly the four members the
/// auth session touches: the presentation context, `start()`, `cancel()`
/// and the completion handler (passed at construction). Nothing else about
/// the system type is reachable through here, which keeps the seam honest:
/// a conformer can only be started, cancelled and completed.
@MainActor
protocol SystemWebAuthSession: AnyObject {

    /// The context the sheet anchors to. Must be set BEFORE `start()`: the
    /// system reports its absence as the numeric error code 2
    /// (`presentationContextNotProvided`).
    var presentationContextProvider: ASWebAuthenticationPresentationContextProviding? { get set }

    /// Starts the sheet. `false` means the system refused to start it — a
    /// refusal that carries no error code of its own (the documented codes
    /// arrive through the completion handler instead).
    func start() -> Bool

    /// Dismisses the sheet. The system answers with `canceledLogin` (code 1),
    /// which this feature maps to `.userCancelled`.
    func cancel()
}

/// Builds the one system session for one link attempt.
typealias SystemWebAuthSessionFactory = @MainActor (
    _ url: URL,
    _ callbackURLScheme: String,
    _ completion: @escaping (URL?, Error?) -> Void
) -> SystemWebAuthSession

/// The concrete `SpotifyAuthSession` behind C-SP-04 (design-l2 §11, §26):
/// `ASWebAuthenticationSession`, presented from the app's top view
/// controller.
///
/// **The seam's one contract.** `authorize` returns the callback URL the
/// system delivered, byte for byte and UNINSPECTED — the exact-match
/// validator is `SpotifyAuthFlow.parseCallback`, and it is the only door a
/// code can come through. Every other ending is a `SpotifyAuthError`:
///
/// * no presentable view controller at present time → `.noPresenter` (and
///   no sheet is created — never a crash, never a silent success);
/// * the caregiver dismissing the sheet — the system's `canceledLogin` —
///   → `.userCancelled`, the case the account session already maps to its
///   cancelled outcome (L2-D7);
/// * any other system report → `.presentationFailed(code:)` carrying the
///   system's NUMERIC code and nothing else: never its description, never
///   the URL (L2-D6).
///
/// **Logging (NFR-SP-002).** There is no logger, no console write and no
/// event emitter in this file. The authorize URL, the callback URL and the
/// authorization code it carries, and the PKCE material travel through
/// this type as values the code hands back — nowhere in it CAN record one,
/// because there is nowhere to put one. The completion handler's arguments
/// are read once, in the mapping below, and dropped.
///
/// **Cancellation.** The account session's link-flow timeout (L2-D7)
/// cancels the task awaiting `authorize`; that cancellation dismisses the
/// system sheet and ends the attempt as `.userCancelled` — the flow's own
/// timeout vocabulary. A cancellation that lands before the sheet exists
/// ends the attempt the same way and never presents anything.
@MainActor
final class ASWebSpotifyAuthSession: SpotifyAuthSession {

    /// The code reported when `start()` returns `false` without the system
    /// vending an error object.
    ///
    /// The system's error vocabulary (codes 1/2/3) arrives through the
    /// completion handler; a bare refusal has no code of its own. Zero is
    /// the honest stand-in — "the system reported no numeric reason" —
    /// because the alternative would be to invent one of the documented
    /// codes for a cause the system did not name. The associated value
    /// stays a number: no description, no text.
    static let unreportedStartFailureCode = 0

    /// Resolved at PRESENT time, never captured at construction (the
    /// `calendarShareSession` precedent, AppCoordinator 9314–9322): the
    /// composition root builds this object before any window exists, and a
    /// controller captured then would be a detached one.
    private let presenter: @MainActor () -> UIViewController?

    /// The system-session builder, injected so tests can stand the system
    /// with a stub that completes on command.
    private let systemSessionFactory: SystemWebAuthSessionFactory

    /// Production construction: the coordinator's own presenter resolution
    /// and the live `ASWebAuthenticationSession`.
    convenience init() {
        self.init(presenter: ASWebSpotifyAuthSession.topPresentingViewController,
                  systemSessionFactory: ASWebSpotifyAuthSession.makeSystemSession)
    }

    init(presenter: @escaping @MainActor () -> UIViewController?,
         systemSessionFactory: @escaping SystemWebAuthSessionFactory) {
        self.presenter = presenter
        self.systemSessionFactory = systemSessionFactory
    }

    // MARK: - The one interactive step

    /// Presents `url` in the system sheet and returns the callback URL the
    /// system delivered.
    ///
    /// See the type comment for the full outcome contract: the URL is
    /// returned uninspected (the flow validates it), and every failure is a
    /// `SpotifyAuthError` this seam throws — never an untyped system error.
    func authorize(url: URL, callbackURLScheme: String) async throws -> URL {
        guard let anchor = presenter() else {
            throw SpotifyAuthError.noPresenter
        }

        let attempt = WebAuthAttempt()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                attempt.begin(continuation)
                // A cancellation that landed before this line — or a
                // caller whose task is already cancelled — must not present
                // a sheet nobody is waiting for (the flow's timeout,
                // L2-D7). When the attempt already ended, begin() has
                // resumed the continuation; the finish below is then the
                // dropped late arrival.
                guard !attempt.hasEnded, !Task.isCancelled else {
                    attempt.finish(with: .failure(SpotifyAuthError.userCancelled))
                    return
                }

                let completion: (URL?, Error?) -> Void = { callback, error in
                    // The completion's thread is undocumented; every touch of
                    // the attempt's state happens on the main actor, so the
                    // report hops first. The callback URL is only ever read
                    // here and handed on — never logged, described or
                    // retained (NFR-SP-002).
                    Task { @MainActor in
                        attempt.finish(with: Self.outcome(callback: callback, error: error))
                    }
                }

                let session = systemSessionFactory(url, callbackURLScheme, completion)
                session.presentationContextProvider = WindowAnchorProvider(anchor: anchor)
                attempt.attach(session)
                guard session.start() else {
                    attempt.finish(with: .failure(
                        SpotifyAuthError.presentationFailed(code: Self.unreportedStartFailureCode)))
                    return
                }
            }
        } onCancel: {
            // The caller went away — the link flow's timeout cancels the
            // task (L2-D7). Dismiss the sheet and end the attempt as the
            // cancellation outcome the flow already maps.
            Task { @MainActor in
                attempt.cancel()
            }
        }
    }

    // MARK: - Outcome mapping (L2-D6)

    /// Maps one system completion to the seam's typed vocabulary.
    ///
    /// * a URL → success, returned as delivered;
    /// * `canceledLogin` (code 1) → `.userCancelled` — the caregiver's own
    ///   decision, which is not a failure;
    /// * any other error → `.presentationFailed(code:)` with the numeric
    ///   code only.
    ///
    /// A completion with neither a URL nor an error is the sheet closing
    /// without a result — the interactive-dismissal shape some system
    /// versions report instead of `canceledLogin` — and it surfaces as
    /// `.userCancelled`: the household chose not to complete the link,
    /// which is the same claim the cancel code makes, and the only other
    /// typed answers would misattribute a presentation failure the system
    /// never reported.
    private static func outcome(callback: URL?, error: Error?) -> Result<URL, Error> {
        if let error {
            return .failure(mappedFailure(error))
        }
        guard let callback else {
            return .failure(SpotifyAuthError.userCancelled)
        }
        return .success(callback)
    }

    /// `canceledLogin` is the system's dismissal signal — the sheet's
    /// Cancel button, the permission alert's cancel, or a programmatic
    /// `cancel()` — and maps to `.userCancelled`. Every other error keeps
    /// its numeric code and nothing else.
    private static func mappedFailure(_ error: Error) -> SpotifyAuthError {
        let systemError = error as NSError
        if systemError.domain == ASWebAuthenticationSessionError.errorDomain,
           systemError.code == ASWebAuthenticationErrorCode.canceledLogin {
            return .userCancelled
        }
        return .presentationFailed(code: systemError.code)
    }

    /// The numeric vocabulary of the system error domain, spelled once.
    ///
    /// Read from `ASWebAuthenticationSessionError.Code` rather than a bare
    /// literal so a system rename cannot silently change which code means
    /// "the user dismissed".
    private enum ASWebAuthenticationErrorCode {
        static let canceledLogin = ASWebAuthenticationSessionError.canceledLogin.rawValue
    }

    // MARK: - Anchor presentation

    /// The topmost view controller the sheet presents from — the same
    /// resolution as the coordinator's own `topPresentingViewController()`
    /// (AppCoordinator ~9336): the foreground-active scene's key window
    /// (falling back to the first scene and window), walked past anything
    /// already presented so the sheet never lands under an open modal.
    ///
    /// Main-actor-isolated like the UIKit reads it makes: the presenter is
    /// resolved at PRESENT time by `authorize` above, which is main-actor,
    /// so no scene work ever happens off-main.
    ///
    /// Returns nil before the scene exists, which `authorize` reports as
    /// `.noPresenter` — never a crash, and never a sheet from nowhere.
    static func topPresentingViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
              var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    /// The production system session: the one place this feature touches
    /// `ASWebAuthenticationSession` itself.
    private static func makeSystemSession(
        url: URL,
        callbackURLScheme: String,
        completion: @escaping (URL?, Error?) -> Void
    ) -> SystemWebAuthSession {
        LiveSystemWebAuthSession(url: url,
                                 callbackURLScheme: callbackURLScheme,
                                 completion: completion)
    }
}

// MARK: - The live system session

/// `ASWebAuthenticationSession` behind `SystemWebAuthSession`, forwarding
/// the four members the seam defines and nothing else.
///
/// The completion handler is passed at construction (the system's own
/// contract) — this type only forwards it, so no path here can reorder,
/// rewrite or drop a system report.
@MainActor
private final class LiveSystemWebAuthSession: SystemWebAuthSession {

    private let session: ASWebAuthenticationSession

    init(url: URL,
         callbackURLScheme: String,
         completion: @escaping (URL?, Error?) -> Void) {
        session = ASWebAuthenticationSession(url: url,
                                             callbackURLScheme: callbackURLScheme,
                                             completionHandler: completion)
    }

    var presentationContextProvider: ASWebAuthenticationPresentationContextProviding? {
        get { session.presentationContextProvider }
        set { session.presentationContextProvider = newValue }
    }

    func start() -> Bool { session.start() }

    func cancel() { session.cancel() }
}

/// The context the system sheet anchors to: the presenting controller's own
/// window.
///
/// A controller that is not in a window cannot anchor a sheet honestly, and
/// this type does not invent one: the fallback window is detached, the
/// system rejects it and reports `presentationContextInvalid` (code 3)
/// through the completion handler, which `authorize` maps to
/// `.presentationFailed(code: 3)` — a typed, honest answer rather than a
/// sheet pointed at the wrong place.
@MainActor
private final class WindowAnchorProvider: NSObject,
                                           ASWebAuthenticationPresentationContextProviding {

    /// Weak: the provider only ever reports where the controller IS, and a
    /// deallocated controller must not be kept alive by the sheet's
    /// context.
    private weak var anchor: UIViewController?

    init(anchor: UIViewController) {
        self.anchor = anchor
        super.init()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor?.viewIfLoaded?.window
            ?? anchor?.view.window
            ?? UIWindow()
    }
}

// MARK: - One attempt, ended exactly once

/// One link attempt's continuation, ended by whichever report arrives
/// first and never a second time.
///
/// Two reports can race for one attempt — the system's completion and the
/// caller's cancellation (the flow timeout, L2-D7) — and resuming a
/// `CheckedContinuation` twice traps. The first arrival wins; every later
/// one is dropped. Main-actor-confined: every arrival path hops to the main
/// actor first (the completion's thread is undocumented), so no lock is
/// introduced (the §concurrency stance) and none is needed.
@MainActor
private final class WebAuthAttempt {

    private var continuation: CheckedContinuation<URL, Error>?
    private var earlyOutcome: Result<URL, Error>?
    private var ended = false
    private var session: SystemWebAuthSession?

    /// Whether the attempt has already been decided.
    var hasEnded: Bool { ended }

    /// Installs the wait. An outcome that arrived before the continuation
    /// existed — a cancellation can land between the handler being
    /// installed and the sheet being built — resumes it here, so a
    /// cancellation is never lost and the wait never hangs.
    func begin(_ continuation: CheckedContinuation<URL, Error>) {
        if let outcome = earlyOutcome {
            earlyOutcome = nil
            resume(continuation, with: outcome)
            return
        }
        self.continuation = continuation
    }

    /// The sheet, once it exists. An attempt that already ended must not
    /// keep a sheet up.
    func attach(_ session: SystemWebAuthSession) {
        guard !ended else {
            session.cancel()
            return
        }
        self.session = session
    }

    /// Ends the attempt with the first outcome that arrives.
    func finish(with outcome: Result<URL, Error>) {
        guard !ended else { return }
        ended = true
        session = nil
        guard let continuation else {
            earlyOutcome = outcome
            return
        }
        self.continuation = nil
        resume(continuation, with: outcome)
    }

    /// The caller's task went away: dismiss the sheet and end the attempt
    /// as the cancellation outcome — what a user dismissal also produces,
    /// because from the household's perspective both are "the link did not
    /// happen" (L2-D7).
    func cancel() {
        session?.cancel()
        finish(with: .failure(SpotifyAuthError.userCancelled))
    }

    private func resume(_ continuation: CheckedContinuation<URL, Error>,
                        with outcome: Result<URL, Error>) {
        switch outcome {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
