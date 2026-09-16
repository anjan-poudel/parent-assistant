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
            // [UNIT-TEST-HOST] The app's automatic boot never runs under
            // XCTest: the post-first-frame composition is main-thread
            // work that would overlap the first test's execution (P0-1
            // defers it exactly one turn past launch) and trip the test
            // watchdog — reproducible host kill on iOS 18.3 simulators.
            // Tests construct their own coordinators and call `start()`
            // explicitly when they need boot behavior; the host app
            // boots nothing.
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
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
        // [PHOTO-AIDS] (2026-09-16) The fired reminder's photos, full
        // screen — mounted at the root for the same reason the timer
        // alarm is: it is the app's only in-app firing surface for
        // reminders, and it must cover whatever screen the elder is on.
        // Transparent no-op while nothing has fired (the overwhelming
        // case — only reminders with photos ever present it).
        .overlay(
            RoutineVisualAidOverlay(
                presentation: coordinator.firedRoutineVisualAids,
                store: coordinator.visualAidStore,
                locale: coordinator.activeLocale,
                onClose: coordinator.dismissFiredRoutineVisualAids
            )
        )
        // [MED-PHOTO-AIDS] (2026-09-16) The medication half of the same
        // idea: a dose whose entry carries photos presents the elder-facing
        // dose screen (photo large above the name and the dose line, one
        // "I took it") instead of a bare banner — safety-critical, so it
        // covers everything, root-mounted like the routine one. Reads the
        // MEDICATION photo store: dose photos live under their own prefixed
        // directory, never the routine store's.
        .overlay(
            MedicationVisualAidOverlay(
                presentation: coordinator.firedMedicationVisualAids,
                store: coordinator.medicationVisualAidStore,
                locale: coordinator.activeLocale,
                onAcknowledge: coordinator.confirmFiredMedicationDose,
                onClose: coordinator.dismissFiredMedicationVisualAids
            )
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
        // [RICH-EVENTS] (2026-09-17) One free-form event, full screen —
        // the reminder notification's Open action lands here, and the
        // Events list opens the same screen for an edit, so an event has
        // one face and not two. Presented app-wide because the
        // notification can be tapped from any screen.
        .sheet(item: $coordinator.pendingEventDetail) { presentation in
            EventDetailView(eventId: presentation.eventId,
                            onClose: coordinator.dismissEventDetail)
        }
        // [STARTUP-PERF] The progressive-boot spinner (a small capsule
        // listing what is loading) now lives INSIDE HomeView, anchored
        // above the speak button ([SPINNER-PLACEMENT]) — hosting it as a
        // top overlay here put the capsule over the top bar's calendar
        // date line. Boot only starts once onboarding finishes, so the
        // wizard never showed it anyway.
    }
}
