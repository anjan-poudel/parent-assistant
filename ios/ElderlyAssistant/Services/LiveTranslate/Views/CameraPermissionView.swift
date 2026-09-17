import SwiftUI
import UIKit

// C13 (session-view surfaces) — the three pre-capture camera states (T-008,
// FR-LCT-002, NFR-LCT-004).
//
// What this file exists to make true:
//
//  - **The rationale precedes the OS prompt.** The explanation state is what
//    the elder sees before anything is asked of them, and the only control it
//    offers re-calls the session's `start()` (T-006's two-step permission
//    contract). Nothing here polls the system or re-derives permission: the
//    state comes from the session's own explicit start result.
//  - **A refusal is recoverable and never a dead end.** The denied state
//    carries one control, which opens the app's own Settings page through the
//    shipped `UIApplication.openSettingsURLString` pattern.
//  - **The unavailable state blames nobody and offers no false hope.** Its
//    state type carries **no cause at all**, so no rendering path can leak one;
//    its copy is the catalog's cause-neutral wording, and the only action it
//    offers is `none` — there is no retry button, because the recovery is a
//    Settings change or a different device, neither of which this screen can do.
//  - **Camera access is never bundled with anything else.** The only consent
//    the elder is asked for here is the camera's, and the cloud-translation
//    consent is a separate prompt at its point of first need (T-015).
//
// The surface is a card, not a replacement: the states that do not need the
// camera stay presented around it (T-027 composes it over the session view).

/// The pure surface behind `CameraPermissionView`: which pre-capture state the
/// feature is in, the copy it shows in the active language, and the one action
/// it offers.
struct CameraPermissionSurface: Equatable {

    /// The three states this surface owns. `.unavailable` deliberately carries
    /// no error: the cause is recorded once, as a content-free event, by the
    /// session that discovered it — and the elder is told what is true without
    /// being told a cause the code cannot verify.
    enum State: Equatable {
        /// Permission has not been requested yet: the rationale, in the
        /// elder's language, before the system prompt appears.
        case explanation
        /// Permission was refused. The one recovery is a Settings change.
        case denied
        /// The device has no usable camera, or the capture session could not
        /// be configured. Nothing this screen can do changes that.
        case unavailable
    }

    /// The action a state offers. `none` is a real answer, not a missing one:
    /// the design forbids a retry that cannot succeed.
    enum Action: Equatable {
        case continueToPrompt
        case openSettings
        case none
    }

    let state: State
    /// The active language. Copy is resolved here, against the app language,
    /// rather than through the view hierarchy — the same `L10n` path the rest
    /// of the feature's non-view code uses, so a Nepali session reads Nepali.
    let locale: Locale

    init(state: State, locale: Locale) {
        self.state = state
        self.locale = locale
    }

    /// Maps the session's **own** explicit start result (T-006) onto a
    /// pre-capture state. `nil` means permission is resolved: there is nothing
    /// pre-capture left to show, and capture may run.
    static func state(for result: Result<Void, LiveTranslateError>) -> State? {
        switch result {
        case .success:
            return nil
        case .failure(.cameraPermissionNotDetermined):
            return .explanation
        case .failure(.cameraPermissionDenied):
            return .denied
        case .failure:
            // No device, a session that would not configure, a resource held
            // by another client: one cause-neutral state, because the elder's
            // next step is the same for all of them and none of them is their
            // doing.
            return .unavailable
        }
    }

    // MARK: Copy (catalog keys only)

    /// What the elder reads. A catalog value in every case — never a literal
    /// compiled into the view.
    var message: String {
        switch state {
        case .explanation: return L10n.str("livetranslate.camera.explanation", locale: locale)
        case .denied: return L10n.str("livetranslate.camera.denied", locale: locale)
        case .unavailable: return L10n.str("livetranslate.state.unavailable", locale: locale)
        }
    }

    /// The control's label, or `nil` when the state offers no action.
    var actionTitle: String? {
        switch state {
        case .explanation: return L10n.str("onboarding.stepPermissions.allow", locale: locale)
        case .denied: return L10n.str("state.error.openSettings", locale: locale)
        case .unavailable: return nil
        }
    }

    var action: Action {
        switch state {
        case .explanation: return .continueToPrompt
        case .denied: return .openSettings
        case .unavailable: return .none
        }
    }

    /// The app's own Settings page — the shipped deep link, produced only for
    /// the state whose recovery it is.
    var settingsURL: URL? {
        guard action == .openSettings else { return nil }
        return URL(string: UIApplication.openSettingsURLString)
    }
}

/// The elder-facing card for those states. Large text, one clear action, and
/// no dead ends.
struct CameraPermissionView: View {

    let surface: CameraPermissionSurface
    /// Re-calls the session's `start()` — the one permitted way past the
    /// explanation (FR-LCT-002). The view never starts capture itself.
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(surface.message)
                .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("livetranslate.camera.message")

            if let title = surface.actionTitle {
                actionButton(title)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private func actionButton(_ title: String) -> some View {
        Button {
            switch surface.action {
            case .continueToPrompt:
                onContinue()
            case .openSettings:
                // Only the system can lift a refusal; this points at it.
                if let url = surface.settingsURL {
                    UIApplication.shared.open(url)
                }
            case .none:
                break
            }
        } label: {
            Text(title)
                .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.accent)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("livetranslate.camera.action")
    }
}
