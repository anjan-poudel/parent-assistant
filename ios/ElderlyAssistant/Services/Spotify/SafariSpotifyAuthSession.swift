import Foundation
import SafariServices
import UIKit

// MARK: - In-app Safari consent seam (iOS 26.6.2 ASWebAuthenticationSession workaround)

/// [2026-10-14] The fallback consent presenter behind the same
/// `SpotifyAuthSession` seam: an `SFSafariViewController` shown from the
/// anchor, with the OAuth callback delivered through the app's
/// `.onOpenURL` handler (`SafariSpotifyAuthSession.handleOpenURL`).
///
/// WHY THIS EXISTS: on iOS 26.6.2 the system web-auth session refuses to
/// start (`presentationFailed(0)`) with a perfect window state — the
/// system-side reason is not visible to the app. An in-app Safari
/// controller does not go through that door at all: presenting it cannot
/// be refused the same way, and the callback scheme opens back into the
/// app through the ordinary URL path.
///
/// Contract (same as `ASWebSpotifyAuthSession`): the callback URL is
/// handed back UNINSPECTED — `SpotifyAuthFlow.parseCallback` remains the
/// only door a code can come through. Every other ending is a
/// `SpotifyAuthError`: no presenter → `.noPresenter`; the caregiver
/// dismissing the Safari page → `.userCancelled`; the caller cancelling
/// (the link-flow timeout) → `.userCancelled`. Nothing is logged, printed
/// or retained here (NFR-SP-002).
@MainActor
final class SafariSpotifyAuthSession: SpotifyAuthSession {

    /// The in-flight attempt, if any — the `.onOpenURL` bridge delivers to
    /// this. Weak, so a leaked waiter can never hold the session.
    private static weak var active: SafariSpotifyAuthSession?

    /// Resolved at present time, like the system-session seam.
    private let presenter: @MainActor () -> UIViewController?

    init(presenter: @escaping @MainActor () -> UIViewController? = ASWebSpotifyAuthSession.topPresentingViewController) {
        self.presenter = presenter
    }

    /// The app-level URL bridge: returns true when the URL belongs to this
    /// feature's callback scheme and a pending attempt consumed it.
    static func handleOpenURL(_ url: URL) -> Bool {
        guard url.scheme == SpotifyAuthFlow.callbackScheme else { return false }
        active?.deliver(url)
        return true
    }

    private var attempt: SafariAuthAttempt?

    func authorize(url: URL, callbackURLScheme: String) async throws -> URL {
        guard let anchor = presenter() else {
            throw SpotifyAuthError.noPresenter
        }

        let attempt = SafariAuthAttempt()
        self.attempt = attempt

        let safari = SFSafariViewController(url: url)
        safari.modalPresentationStyle = .fullScreen
        // The caregiver closing the page is the cancel outcome; the proxy
        // is retained so the system's weak delegate link stays valid.
        attempt.retainProxy = SafariDoneProxy { [weak attempt] in
            attempt?.finish(with: .failure(SpotifyAuthError.userCancelled))
        }
        safari.delegate = attempt.retainProxy

        // [DIAGNOSTIC 2026-10-14] The same state snapshot the system seam
        // takes, so a failure here is attributable the same way.
        ASWebSpotifyAuthSession.lastPresentationState =
            "safari | \(Self.captureWindowState(anchor: anchor))"

        anchor.present(safari, animated: true)
        attempt.attach(safari)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard attempt.begin(continuation) else { return }
                Self.active = self
            }
        } onCancel: {
            // The link-flow timeout cancelled the task: close the page and
            // end as the cancel outcome the flow already maps.
            Task { @MainActor in
                attempt.finish(with: .failure(SpotifyAuthError.userCancelled))
            }
        }
    }

    private func deliver(_ url: URL) {
        attempt?.finish(with: .success(url))
        attempt = nil
        Self.active = nil
    }

    private func clear() {
        attempt = nil
        Self.active = nil
    }

    @MainActor
    private static func captureWindowState(anchor: UIViewController) -> String {
        let window = anchor.viewIfLoaded?.window ?? anchor.view.window
        return "anchWin=\(window != nil ? "y" : "n") "
             + "key=\(window?.isKeyWindow == true ? "y" : "n") "
             + "appState=\(UIApplication.shared.applicationState.rawValue)"
    }

    // MARK: - One attempt, ended exactly once

    /// The continuation plus the presented controller. Finished by the
    /// first arrival — the callback URL, the caregiver's Done, or the
    /// timeout cancellation — and never a second time.
    @MainActor
    private final class SafariAuthAttempt {
        private var continuation: CheckedContinuation<URL, Error>?
        private var earlyOutcome: Result<URL, Error>?
        private var ended = false
        private weak var presented: SFSafariViewController?

        /// Retained by the attempt so the system's weak delegate link
        /// stays alive for the page's lifetime.
        var retainProxy: SafariDoneProxy?

        /// Whether the attempt has already been decided.
        var hasEnded: Bool { ended }

        /// Installs the wait; returns false when the attempt already ended.
        func begin(_ continuation: CheckedContinuation<URL, Error>) -> Bool {
            if let outcome = earlyOutcome {
                earlyOutcome = nil
                resume(continuation, with: outcome)
                return false
            }
            self.continuation = continuation
            return true
        }

        func attach(_ safari: SFSafariViewController) {
            presented = safari
            guard ended else { return }
            // An outcome that arrived before presentation completed must
            // still close the page.
            safari.dismiss(animated: false)
        }

        func finish(with outcome: Result<URL, Error>) {
            guard !ended else { return }
            ended = true
            retainProxy = nil
            presented?.dismiss(animated: true)
            resume(continuation, with: outcome)
            continuation = nil
        }

        private func resume(_ continuation: CheckedContinuation<URL, Error>?,
                            with outcome: Result<URL, Error>) {
            guard let continuation else { return }
            switch outcome {
            case .success(let url): continuation.resume(returning: url)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }
}

/// The system's weak delegate link for the Safari page: Done → the cancel
/// outcome.
@MainActor
private final class SafariDoneProxy: NSObject, SFSafariViewControllerDelegate {
    private let onDone: () -> Void

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        onDone()
    }
}
