import SwiftUI

@main
struct ElderlyAssistantApp: App {
    @StateObject private var appCoordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            Group {
                if #available(iOS 16.1, *) {
                    // Redesign (2026-09-03 UI spec §2): SF Rounded app-wide
                    // for body/label text. Font.system(design:) calls that
                    // specify an explicit design (the serif greeting) are
                    // unaffected — this environment value only resolves for
                    // text that doesn't already pin a design. `.fontDesign`
                    // itself needs iOS 16.1 (deployment target is 16.0), so
                    // pre-16.1 devices just keep the default SF Pro body.
                    ContentView().fontDesign(.rounded)
                } else {
                    ContentView()
                }
            }
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
