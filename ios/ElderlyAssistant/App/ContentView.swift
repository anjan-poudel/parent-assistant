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
        // [TIMER-ALARM] (2026-09-10) The full-screen ringing alarm —
        // mounted at the root so it covers every screen (it is a
        // fullScreenCover, which also sits above the app's sheets).
        // Transparent no-op while the engine is idle.
        .overlay(
            TimerAlarmOverlay(engine: coordinator.timerAlarmEngine,
                              onStop: coordinator.stopTimerAlarm)
        )
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
        // [STARTUP-PERF] The progressive-boot spinner (a small capsule
        // listing what is loading) now lives INSIDE HomeView, anchored
        // above the speak button ([SPINNER-PLACEMENT]) — hosting it as a
        // top overlay here put the capsule over the top bar's calendar
        // date line. Boot only starts once onboarding finishes, so the
        // wizard never showed it anyway.
    }
}
