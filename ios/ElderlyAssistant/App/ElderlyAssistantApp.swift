import SwiftUI

@main
struct ElderlyAssistantApp: App {
    @StateObject private var appCoordinator = AppCoordinator()

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
            // Spec §3.2: AppLanguage drives `.locale` directly at the
            // root. Every Text/catalog lookup, date, and number
            // formatter below this point follows it automatically.
            .environment(\.locale, appCoordinator.appLanguage.locale)
        }
    }
}
