import SwiftUI

// C09/C13 — the consent prompt and the revocation control (T-015,
// FR-LCT-013, FR-LCT-015, NFR-LCT-004).
//
// What this file exists to make true:
//
//  - **The decision is presented, not steered.** Grant and decline are the
//    same kind of thing here: one `ConsentAction` type with no field that
//    could mark either as preferred, both built by the same view helper with
//    the same style and the same minimum tap-target height. There is no
//    default button, no keyboard shortcut, no destructive role and no
//    emphasis — equal weight is a property of the *types*, not of the review
//    that reads the copy.
//  - **A plain card, not a system alert.** The prompt is presented by the
//    session view over the live camera. It never appears over a decision the
//    elder did not initiate and it never dismisses itself: the view has no
//    timer and no dismiss control, because an automatic dismissal would be an
//    implicit consent (FR-LCT-013).
//  - **Copy is always a catalog value.** Every word the elder reads comes
//    from `L10n` by key, in the active language, so the owner's OD3 review
//    changes one place (NFR-LCT-004).
//  - **The explanation is about text, never images.** The body copy is the
//    reviewed draft (T-005) and states that only recognized text leaves the
//    device (T-015 scenario 5).
//  - **The control has two honest states.** While a grant is in force it
//    offers revocation; otherwise it offers the decision again, so an elder
//    who declined or revoked can change their mind deliberately — through
//    the control, never through an automatic re-prompt.

/// One choice the prompt offers. Deliberately two fields and no more: a
/// `isPrimary`, a `role` or a `style` would be exactly the per-action
/// emphasis the equal-weight requirement forbids, so there is none to set.
struct ConsentAction: Equatable {

    enum Kind: String, Equatable {
        case grant
        case decline
    }

    let kind: Kind
    /// The catalog's wording for this choice, in the active language.
    let title: String

    /// The stable identifier automation and the accessibility tree address
    /// this control by.
    var accessibilityIdentifier: String { "livetranslate.consent.\(kind.rawValue)" }
}

/// The pure surface behind `ConsentPromptView`: every string the prompt shows
/// and the two choices, in the active language.
struct ConsentPromptSurface: Equatable {

    let title: String
    /// The disclosure: what is sent, what is not, and that it stops when the
    /// elder says so.
    let message: String
    /// Exactly two actions — grant first, decline second, both styled alike.
    let actions: [ConsentAction]
    /// Set when the elder's answer could not be recorded. The prompt stays on
    /// screen: the answer did not take effect, and the elder is told so
    /// rather than being shown a success that did not happen (AM-4 part 3).
    let failureMessage: String?
    let locale: Locale

    init(locale: Locale, failureMessage: String? = nil) {
        self.locale = locale
        self.title = L10n.str("livetranslate.consent.title", locale: locale)
        self.message = L10n.str("livetranslate.consent.body", locale: locale)
        self.actions = [
            ConsentAction(kind: .grant,
                          title: L10n.str("livetranslate.consent.grant", locale: locale)),
            ConsentAction(kind: .decline,
                          title: L10n.str("livetranslate.consent.decline", locale: locale))
        ]
        self.failureMessage = failureMessage
    }
}

/// The elder-facing prompt: one card, one explanation, two equally weighted
/// choices.
struct ConsentPromptView: View {

    let surface: ConsentPromptSurface
    let onGrant: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(surface.title)
                .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("livetranslate.consent.heading")

            Text(surface.message)
                .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("livetranslate.consent.message")

            if let failure = surface.failureMessage {
                Text(failure)
                    .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("livetranslate.consent.failure")
            }

            VStack(spacing: 12) {
                ForEach(surface.actions, id: \.kind) { action in
                    actionButton(action)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// The one button construction in this file: both choices come through it,
    /// so neither can acquire a style the other does not have.
    private func actionButton(_ action: ConsentAction) -> some View {
        Button {
            switch action.kind {
            case .grant: onGrant()
            case .decline: onDecline()
            }
        } label: {
            Text(action.title)
                .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.accent)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }
}

// MARK: - The status control (session view and Settings)

/// The pure surface of the consent control: either "a grant is in force, here
/// is how to stop it" or "here is the decision".
///
/// Both surfaces that offer revocation (the session view and Settings) render
/// this type against the same gate, so "reachable from both" is one control
/// used twice rather than two controls that could drift.
struct ConsentControlSurface: Equatable {

    /// The state the control is in, and everything it shows.
    enum State: Equatable {
        /// No grant is in force: the prompt, so the elder can decide — or
        /// change a previous decision — deliberately.
        case decision(ConsentPromptSurface)
        /// A grant is in force: what that means, and the one way out of it.
        case granted(title: String, message: String, revokeTitle: String)
        /// The elder withdrew and the withdrawal did not fully take effect.
        /// The control says what is true and keeps the retry within reach —
        /// a failure the elder can act on, not just read about (AM-4).
        case revocationIncomplete(title: String, message: String, revokeTitle: String)
    }

    let state: State

    static func decision(locale: Locale, failureMessage: String? = nil) -> ConsentControlSurface {
        ConsentControlSurface(state: .decision(ConsentPromptSurface(locale: locale,
                                                                    failureMessage: failureMessage)))
    }

    static func granted(locale: Locale) -> ConsentControlSurface {
        ConsentControlSurface(state: .granted(
            title: L10n.str("livetranslate.consent.grantedTitle", locale: locale),
            message: L10n.str("livetranslate.consent.grantedNote", locale: locale),
            revokeTitle: L10n.str("livetranslate.consent.revoke", locale: locale)))
    }

    static func revocationIncomplete(locale: Locale) -> ConsentControlSurface {
        ConsentControlSurface(state: .revocationIncomplete(
            title: L10n.str("livetranslate.consent.revokeFailedTitle", locale: locale),
            message: L10n.str("livetranslate.consent.revokeFailedNote", locale: locale),
            revokeTitle: L10n.str("livetranslate.consent.revoke", locale: locale)))
    }
}

/// The elder-facing control for both surfaces.
struct ConsentControlView: View {

    let surface: ConsentControlSurface
    let onGrant: () -> Void
    let onDecline: () -> Void
    let onRevoke: () -> Void

    var body: some View {
        switch surface.state {
        case .decision(let prompt):
            ConsentPromptView(surface: prompt, onGrant: onGrant, onDecline: onDecline)
        case .granted(let title, let message, let revokeTitle),
             .revocationIncomplete(let title, let message, let revokeTitle):
            grantedCard(title: title, message: message, revokeTitle: revokeTitle)
        }
    }

    private func grantedCard(title: String, message: String, revokeTitle: String) -> some View {
        VStack(spacing: 16) {
            Text(title)
                .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // The one action here is the elder's way out; it is never a
            // default, and it carries no blame.
            Button(action: onRevoke) {
                Text(revokeTitle)
                    .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("livetranslate.consent.revokeControl")
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }
}
