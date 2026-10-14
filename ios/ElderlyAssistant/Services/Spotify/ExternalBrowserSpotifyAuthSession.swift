import Foundation
import UIKit

// MARK: - Default-browser consent seam (iOS 27.0.1 ASWebAuthenticationSession workaround)

/// [2026-10-14] The fallback consent presenter behind the same
/// `SpotifyAuthSession` seam: the authorize URL is handed to the system,
/// which opens it in the user's DEFAULT BROWSER (Safari app, Chrome,
/// whatever is set). The OAuth callback scheme brings the app back to the
/// foreground and the callback URL arrives through the app's `.onOpenURL`
/// handler (`ExternalBrowserSpotifyAuthSession.handleOpenURL`).
///
/// WHY THIS EXISTS: on iOS 27.0.1 the system web-auth session refuses to
/// start (`presentationFailed(0)`) with a perfect window state, and the
/// owner asked for the default browser rather than an in-app Safari page.
/// An external open does not go through the web-auth door at all.
///
/// Contract (same as `ASWebSpotifyAuthSession`): the callback URL is
/// handed back UNINSPECTED — `SpotifyAuthFlow.parseCallback` remains the
/// only door a code can come through. Every other ending is a
/// `SpotifyAuthError`: the system refusing to open the URL →
/// `.presentationFailed(code: 0)` (the same refusal vocabulary the system
/// sheet uses); the caller cancelling (the link-flow timeout) →
/// `.userCancelled`. Nothing is logged, printed or retained here
/// (NFR-SP-002).
@MainActor
final class ExternalBrowserSpotifyAuthSession: SpotifyAuthSession {

    /// The in-flight attempt, if any — the `.onOpenURL` bridge delivers to
    /// this. Weak, so a leaked waiter can never hold the session.
    private static weak var active: ExternalBrowserSpotifyAuthSession?

    /// The app-level URL bridge: returns true when the URL belongs to this
    /// feature's callback scheme and a pending attempt consumed it.
    static func handleOpenURL(_ url: URL) -> Bool {
        guard url.scheme == SpotifyAuthFlow.callbackScheme else { return false }
        active?.deliver(url)
        return true
    }

    private var attempt: ExternalAuthAttempt?

    func authorize(url: URL, callbackURLScheme: String) async throws -> URL {
        let attempt = ExternalAuthAttempt()
        self.attempt = attempt

        // The whole presentation: hand the URL to the system. The default
        // browser opens; the app goes to the background; the callback
        // scheme brings it back and `deliver` resumes this wait.
        let opened = await UIApplication.shared.open(url)
        guard opened else {
            self.attempt = nil
            throw SpotifyAuthError.presentationFailed(
                code: ASWebSpotifyAuthSession.unreportedStartFailureCode)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard attempt.begin(continuation) else { return }
                Self.active = self
            }
        } onCancel: {
            // The link-flow timeout cancelled the task while the browser
            // held the user: end as the cancel outcome the flow already
            // maps. Nothing to dismiss — the callback, should it still
            // arrive, finds no waiter and is dropped.
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

    // MARK: - One attempt, ended exactly once

    @MainActor
    private final class ExternalAuthAttempt {
        private var continuation: CheckedContinuation<URL, Error>?
        private var earlyOutcome: Result<URL, Error>?
        private var ended = false

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

        func finish(with outcome: Result<URL, Error>) {
            guard !ended else { return }
            ended = true
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
