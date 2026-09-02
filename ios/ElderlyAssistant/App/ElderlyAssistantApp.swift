import SwiftUI

@main
struct ElderlyAssistantApp: App {
    @StateObject private var appCoordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
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
