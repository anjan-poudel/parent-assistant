import SwiftUI

// T-176 — the consent sheet: the elder-facing disclosure and its two answers
// (design-l1 §8.4, §17; FR-CNR-009, NFR-CNR-009/010). The shipped consent
// doctrine, rendered for cloud chat.
//
// What this file exists to make true:
//
//  - **The decision is presented, not steered.** "Yes" and "no" are the same
//    kind of thing here: one `CloudChatConsentAction` type with no field that
//    could mark either as preferred, both built by the same view helper with
//    the same style and the same minimum tap-target height. There is no
//    default button, no keyboard shortcut, no destructive role and no
//    emphasis — equal weight is a property of the *types*, not of the review
//    that reads the copy (the shipped `ConsentAction` rule).
//  - **The question cannot be dismissed away.** `.interactiveDismissDisabled`
//    removes the swipe-to-dismiss gesture that would otherwise close the
//    sheet: dismissal is not an answer, and an automatic or gesture dismissal
//    would be an implicit consent (FR-CNR-009, the `ConsentPromptController`
//    doctrine). There is no timer here and no dismiss control, so the only
//    way out of this view is one of the two answers.
//  - **Plain language, catalogue only.** Every word the elder reads is an
//    L10n value by key in the active language — title, disclosure and both
//    answers are T-171's consent keys, so the OD-12/13 copy review changes
//    one place. No provider, model, server, route or "cloud" term appears in
//    either language's copy (the family's own term bar), and no string here
//    composes a format argument.
//  - **House accessibility: large type, big targets.** Text takes the
//    environment's `AppTypography.bodyPointSize` (≥18 pt at every size
//    class, the app's own legibility floor) and both answers take the full
//    `DesignTokens.minTapTargetSize` height, so the two choices stay equally
//    reachable at accessibility sizes. VoiceOver reads each answer's
//    catalogue title; the stable identifiers below are what automation and
//    the accessibility tree address the controls by.

/// One answer the sheet offers. Deliberately two fields and no more: an
/// `isPrimary`, a `role` or a `style` would be exactly the per-action
/// emphasis the equal-weight requirement forbids, so there is none to set.
struct CloudChatConsentAction: Equatable {

    enum Kind: String, Equatable {
        /// The elder's yes: answers go to the internet.
        case allow
        /// The elder's no: answers stay on this phone. Never marked as the
        /// lesser choice — declining is fine, and the copy says so.
        case notNow
    }

    let kind: Kind
    /// The catalogue's wording for this choice, in the active language.
    let title: String

    /// The stable identifier automation and the accessibility tree address
    /// this control by.
    var accessibilityIdentifier: String { "cloudchat.consent.\(kind.rawValue)" }
}

/// The pure surface behind `CloudChatConsentSheet`: every string the sheet
/// shows and the two choices, in the active language.
///
/// There is deliberately no failure line: the consent family carries no
/// "could not be saved" key (T-171's 18-key set is the reviewed copy), so a
/// failure is surfaced where it can be honest — the answer call's
/// `AnswerOutcome.writeFailed`, the gate's `consent_write_failed` event, and
/// a failed grant leaving the question on screen — rather than by inventing
/// a string in code.
struct CloudChatConsentSheetSurface: Equatable {

    let title: String
    /// The disclosure: what is sent, where it goes, what stays on the phone,
    /// and that saying no is fine.
    let message: String
    /// Exactly two actions — allow first, not-now second, both styled alike.
    let actions: [CloudChatConsentAction]
    let locale: Locale

    init(locale: Locale) {
        self.locale = locale
        self.title = L10n.str("cloud.chat.consent.title", locale: locale)
        self.message = L10n.str("cloud.chat.consent.body", locale: locale)
        self.actions = [
            CloudChatConsentAction(kind: .allow,
                                   title: L10n.str("cloud.chat.consent.allow",
                                                   locale: locale)),
            CloudChatConsentAction(kind: .notNow,
                                   title: L10n.str("cloud.chat.consent.notNow",
                                                   locale: locale))
        ]
    }
}

/// The elder-facing sheet: one explanation, two equally weighted answers.
///
/// Presented by the coordinator (T-177) while
/// `CloudChatConsentPrompt.isPromptPresented` is true, in the language the
/// prompt was built with.
struct CloudChatConsentSheet: View {
    @Environment(\.appAppearance) private var appearance

    let surface: CloudChatConsentSheetSurface
    let onAllow: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(surface.title)
                .font(DesignTokens.warmFont(size: appearance.typography.bodyPointSize,
                                            weight: .semibold))
                .foregroundColor(appearance.colors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cloudchat.consent.heading")

            Text(surface.message)
                .font(DesignTokens.warmFont(size: appearance.typography.bodyPointSize))
                .foregroundColor(appearance.colors.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cloudchat.consent.message")

            VStack(spacing: 12) {
                ForEach(surface.actions, id: \.kind) { action in
                    actionButton(action)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .appSurface()
        // The elder's answer is the only way out of this view. Removing the
        // interactive dismissal is the doctrine made structural: a swipe
        // that closed the sheet would leave the question "answered" by a
        // gesture the routing decision never saw.
        .interactiveDismissDisabled(true)
    }

    /// The one button construction in this file: both answers come through
    /// it, so neither can acquire a style the other does not have. The
    /// visible title is the accessibility label; the identifier is stable
    /// for automation.
    private func actionButton(_ action: CloudChatConsentAction) -> some View {
        Button {
            switch action.kind {
            case .allow: onAllow()
            case .notNow: onNotNow()
            }
        } label: {
            Text(action.title)
                .font(DesignTokens.warmFont(size: appearance.typography.bodyPointSize,
                                            weight: .semibold))
                .foregroundStyle(appearance.colors.onAccent)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
                .appSurface(role: .accent, cornerRadius: DesignTokens.bubbleCornerRadius)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }
}
