import SwiftUI

@main
struct ElderlyAssistantApp: App {
    @StateObject private var appCoordinator = AppCoordinator()
    // [BOOT-M1] Feature readiness registry (constant-time startup
    // architecture) — owned here next to the coordinator/startupBoot and
    // injected into the environment below so every surface can render
    // honest per-feature status (unavailable/preparing/ready/failed).
    @StateObject private var readinessRegistry = ReadinessRegistry()

    var body: some Scene {
        WindowGroup {
            // NOTE: previously applied `.fontDesign(.rounded)` app-wide here
            // for a warmer look (redesign spec §2). Reverted 2026-09-04:
            // SF Rounded's Devanagari glyph coverage is not reliably
            // verified across iOS versions, and this was never visually
            // confirmed against real Nepali text before landing — not
            // worth risking tofu/fallback glyphs on dynamic (Gemini-
            // generated, non-catalog) Nepali text for a cosmetic font
            // choice. Revisit only after confirming full Devanagari
            // coverage under SF Rounded on the actual target OS versions.
            ContentView()
            .environmentObject(appCoordinator)
            .environmentObject(appCoordinator.voiceSession)
            .environmentObject(appCoordinator.modelDownloadService)
            // [STARTUP-PERF] Progressive boot progress — the spinner
            // overlay reads this (stage labels + honest failures).
            .environmentObject(appCoordinator.startupBoot)
            // [BOOT-M1] Honest per-feature status for every surface —
            // same injection pattern as startupBoot above.
            .environmentObject(readinessRegistry)
            // Spec §3.2: AppLanguage drives `.locale` directly at the
            // root. Every Text/catalog lookup, date, and number
            // formatter below this point follows it automatically.
            .environment(\.locale, appCoordinator.appLanguage.locale)
        }
    }
}
