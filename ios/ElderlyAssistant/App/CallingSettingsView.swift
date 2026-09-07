import SwiftUI

/// The app an ADDRESS-BOOK row's call button opens when the row has no
/// per-contact channel pick saved (Phone-tab redesign, 2026-09-07) —
/// the global default behind `ChannelPreferenceStore`'s missing-entry
/// fallback. Binds the coordinator's `defaultCallApp` (a UI preference,
/// persisted in UserDefaults) so one change re-defaults every row that
/// never got an explicit pick; rows whose chooser pinned a channel keep
/// their own pick (they resolve BEFORE the default in
/// `AppCoordinator.resolvedCallChannel`).
///
/// The option labels reuse the app-name catalog keys the quick-access
/// row and the call/message flows already speak with, so the picker
/// always agrees with the rest of the app in either script.
struct CallingSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    /// The four selectable channels, in `CallApp`'s declaration order.
    /// Every case is a real outbound surface in the call-button
    /// vocabulary (same bar the FamilyContact preference fields hold).
    private static let channels: [CallApp] = [.faceTime, .phone, .messenger, .whatsApp]

    var body: some View {
        LeafScreen(titleKey: "settings.calling.title") {
            VStack(spacing: 16) {
                VStack(spacing: 12) {
                    ForEach(Self.channels, id: \.rawValue) { app in
                        channelRow(app)
                    }
                }
                Text("calling.defaultCaption")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func channelRow(_ app: CallApp) -> some View {
        let isSelected = app == coordinator.defaultCallApp
        return Button {
            coordinator.defaultCallApp = app
        } label: {
            HStack {
                Text(LocalizedStringKey(Self.nameKey(for: app)))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(DesignTokens.accent)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius)
                    .stroke(isSelected ? DesignTokens.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    /// Catalog name key for a channel — reuse, so the option label is
    /// the same string every other surface shows for that app. Keyed by
    /// switch (not rawValue) because the stored id ("whatsApp") and the
    /// catalog key ("app.name.whatsapp") differ in casing.
    private static func nameKey(for app: CallApp) -> String {
        switch app {
        case .faceTime: return "app.name.facetime"
        case .phone: return "app.name.phone"
        case .messenger: return "app.name.messenger"
        case .whatsApp: return "app.name.whatsapp"
        }
    }
}
