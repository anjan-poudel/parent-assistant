import SwiftUI

/// Thin host (spec §6): picks Onboarding wizard vs Home from
/// `OnboardingState.hasSeenOnboarding`. Voice starts only once onboarding
/// has been run through (spec §4.2 — the wizard runs before voice engages).
struct ContentView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if coordinator.onboardingState.hasSeenOnboarding {
                HomeView()
            } else {
                OnboardingWizardView()
            }
        }
        .onAppear {
            if coordinator.onboardingState.hasSeenOnboarding {
                coordinator.start()
            }
        }
        // External calendar import stays fresh: foreground rescans
        // (native-app edits land immediately), background queues the
        // hourly BGAppRefresh (calendar-driven task, 2026-09-07).
        .onChange(of: scenePhase) { phase in
            coordinator.handleScenePhase(phase)
        }
        // send_message trial wiring (AppCoordinator.composeMessage): the
        // native SMS compose sheet, presented app-wide so it can surface
        // regardless of which screen the voice command landed on.
        .sheet(item: $coordinator.pendingMessageDraft) { draft in
            MessageComposeView(draft: draft) {
                coordinator.pendingMessageDraft = nil
            }
        }
        // .plugin intent: a plugin-provided view (e.g. the appliance
        // photo + overlay), presented app-wide.
        .sheet(item: $coordinator.pendingPluginPresentation) { presentation in
            presentation.view
        }
        // Voice-driven navigation (directions task, 2026-09-07): the
        // in-app MapKit fallback — a static route + spoken steps sheet
        // for when no map app is installed or the user forced `.inApp`.
        // The sheet's dismiss (Close button or swipe) clears the
        // published item; the view stops its session on disappear.
        .sheet(item: $coordinator.pendingNavigationPresentation) { presentation in
            InAppNavigationView(session: presentation.session)
        }
        // [STARTUP-PERF] The progressive-boot spinner: a small capsule
        // row listing what is loading (Nepali + English), dismissed when
        // the background boot completes. Hosted here so it covers the
        // onboarding wizard AND Home.
        .overlay(alignment: .top) {
            StartupProgressOverlay()
        }
    }
}
