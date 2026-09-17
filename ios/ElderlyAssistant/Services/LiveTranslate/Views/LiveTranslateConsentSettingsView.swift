import SwiftUI

// T-015 — the Settings entry point for the consent control.
//
// Revocation must not depend on the camera running, and the elder must be
// able to change a decision without having a live scene in front of them, so
// the same control the session view shows is reachable here. It drives the
// SAME gate instance the session view drives (`AppCoordinator`'s one
// controller), which is what makes "a decision made in Settings takes effect
// over the session view without a restart" true by construction rather than
// by a refresh that might be forgotten.
//
// The surface is `ConsentControlView`: while a grant is in force it offers
// revocation; otherwise it offers the decision itself — the same prompt, the
// same equally weighted choices, the same catalog copy. Opening this screen
// is a deliberate act by the elder, so offering the decision here is not the
// automatic re-prompt that failure-table row 8 forbids.

struct LiveTranslateConsentSettingsView: View {

    /// The app's shared prompt/control state.
    @ObservedObject var controller: ConsentPromptController
    @Environment(\.locale) private var locale

    var body: some View {
        LeafScreen(titleKey: "settings.livetranslate.title") {
            VStack(spacing: 16) {
                ConsentControlView(surface: controller.controlSurface,
                                   onGrant: { controller.grant() },
                                   onDecline: { controller.decline() },
                                   onRevoke: { controller.revoke() })
            }
            .padding(.bottom, 32)
        }
        .onAppear {
            // The language may have changed since the controller was built,
            // and the decision may have been made on another surface: both
            // are re-read from source rather than remembered.
            controller.updateLocale(locale)
            controller.refreshControl()
        }
    }
}
