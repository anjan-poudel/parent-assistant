import SwiftUI

/// Thin host (spec §6): picks Onboarding wizard vs Home from
/// `OnboardingState.hasSeenOnboarding`. Voice starts only once onboarding
/// has been run through (spec §4.2 — the wizard runs before voice engages).
struct ContentView: View {
    @EnvironmentObject var coordinator: AppCoordinator

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
    }
}
