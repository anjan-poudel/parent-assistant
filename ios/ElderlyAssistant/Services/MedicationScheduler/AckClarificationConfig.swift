import Foundation

// MARK: - Ack Clarification Walk Configuration (design-l2 C4, D4)

/// The clarification walk's window configuration (design-l2 C4, IF-8).
///
/// The walk's response window is the SAME window as the confirmation
/// challenge's — one source, by construction (design-l2 D4, review-l2 R-2):
/// `responseWindowSeconds` composes from
/// `ConfirmationChallenge.defaultChallengeTimeoutSeconds`, the one named
/// home. This type carries no constant of its own and no call site
/// carries a literal; a shorter window is injected through the
/// initializer by tests (and any harness that needs one).
struct AckClarificationConfig: Equatable {
    /// How long the walk waits for each spoken answer before it ends
    /// honestly with `.expired` (nothing recorded, reminders untouched).
    let responseWindowSeconds: TimeInterval

    init(responseWindowSeconds: TimeInterval = ConfirmationChallenge.defaultChallengeTimeoutSeconds) {
        self.responseWindowSeconds = responseWindowSeconds
    }
}
