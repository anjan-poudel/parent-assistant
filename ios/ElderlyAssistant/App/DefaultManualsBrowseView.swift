import SwiftUI

/// Settings → Manuals browse leaf (2026-09-07, bundled-manuals task):
/// the direct, camera-free entry to the SHIPPED default manuals. This is
/// the Settings-side equivalent of the helper's `ApplianceManualLibraryView`
/// (which needs a live helper session) — same row visuals, but listing
/// only the bundled catalog and opening rows through the coordinator,
/// which arms a session and presents it app-wide.
///
/// Tapping a manual opens an ARMED `ApplianceHelperSession` (already in
/// `.guidance`) via `coordinator.presentBundledManual`, so the existing
/// NavigationStack-wrapped helper sheet — the same sheet the AI Models
/// screen uses, via `pendingPluginPresentation` — renders the step cards
/// with zero camera and zero Gemini. An honest empty state covers the
/// interim where the catalog has not shipped.
struct DefaultManualsBrowseView: View {

    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.locale) private var locale
    @State private var manuals: [BundledManual] = []
    @State private var didFailToOpen = false

    var body: some View {
        LeafScreen(titleKey: "settings.manuals.title") {
            if manuals.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(manuals, id: \.id) { manual in
                        BundledManualRow(manual: manual) {
                            open(manual)
                        }
                    }
                }
            }
        }
        .task { manuals = ApplianceManualLibraryModel.bundledManuals() }
        // Bundled manuals cannot be deleted; a failed open is a content
        // problem (missing overview image) — title-only, no invented
        // "deleted" copy.
        .alert("appliance.manual.openFailedTitle", isPresented: $didFailToOpen) {
            Button("appliance.manual.cancel", role: .cancel) {}
        }
    }

    private var emptyState: some View {
        // Inside LeafScreen's ScrollView: pad, don't Spacer (which has no
        // room to expand in a scroll view).
        VStack(spacing: 20) {
            Image(systemName: "book.closed")
                .font(.system(size: 56))
                .foregroundColor(DesignTokens.textSecondary)
            Text("appliance.manual.bundledEmpty")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func open(_ manual: BundledManual) {
        guard coordinator.presentBundledManual(manual) else {
            didFailToOpen = true
            return
        }
    }
}
