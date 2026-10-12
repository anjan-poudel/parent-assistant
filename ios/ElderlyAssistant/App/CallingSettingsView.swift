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
///
/// call-dialer-primary-secondary (C6 view half, T-154): the screen
/// carries its SECOND labelled section — the fallback dialer, the
/// chain's second step (`secondaryCallApp`, landed in T-146) — built by
/// the same four-channel row pattern as the primary picker, so each
/// section selects only against its own stored pick. Both section
/// titles carry the heading trait and each selected row carries the
/// selected trait (NFR-CDP-006 / V-4): the checkmark and the stroke
/// stay, but they are no longer the only signal of selection.
struct CallingSettingsView: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject var coordinator: AppCoordinator

    /// The four selectable channels, in `CallApp`'s declaration order.
    /// Every case is a real outbound surface in the call-button
    /// vocabulary (same bar the FamilyContact preference fields hold).
    private static let channels: [CallApp] = [.faceTime, .phone, .messenger, .whatsApp]

    var body: some View {
        LeafScreen(titleKey: "settings.calling.title") {
            VStack(spacing: 16) {
                section(titleKey: "settings.calling.primaryTitle",
                        selected: coordinator.defaultCallApp) { app in
                    coordinator.defaultCallApp = app
                }
                section(titleKey: "settings.calling.secondaryTitle",
                        selected: coordinator.secondaryCallApp) { app in
                    coordinator.secondaryCallApp = app
                }
                Text("calling.defaultCaption")
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// One labelled picker section: the shipped caption-style title over
    /// the four rows of the shared row pattern. `selected` is the
    /// section's OWN stored pick, so the two sections never share a
    /// checkmark. The title carries the heading trait — a plain `Text`
    /// header alone is not a VoiceOver heading (V-4), so the trait is
    /// added rather than claimed.
    private func section(titleKey: String,
                         selected: CallApp,
                         pick: @escaping (CallApp) -> Void) -> some View {
        VStack(spacing: 12) {
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            ForEach(Self.channels, id: \.rawValue) { app in
                channelRow(app, isSelected: app == selected, pick: pick)
            }
        }
    }

    /// The shipped row pattern with its selection and pick injected, so
    /// ONE row builder serves both sections. Selection is conveyed
    /// without sight: the glyph is decorative (hidden from assistive
    /// tech) and the selected trait is the signal — the
    /// `AppearanceSettingsView` rule; a sighted user still gets the
    /// checkmark and the accent stroke, unchanged.
    private func channelRow(_ app: CallApp, isSelected: Bool,
                            pick: @escaping (CallApp) -> Void) -> some View {
        return Button {
            pick(app)
        } label: {
            HStack {
                Text(LocalizedStringKey(Self.nameKey(for: app)))
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .foregroundStyle(appearance.colors.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26)).foregroundStyle(appearance.colors.accentForeground)
                        .accessibilityHidden(true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .appSurface(role: .card, cornerRadius: DesignTokens.cardCornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius)
                    .stroke(isSelected ? appearance.colors.accentForeground : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Catalog name key for a channel — one vocabulary (L2-D8): the
    /// shared chain helper is the single source, so the picker, the
    /// confirmation disclosure and both announcements can never drift
    /// apart. Keyed by switch there (not rawValue) because the stored id
    /// ("whatsApp") and the catalog key ("app.name.whatsapp") differ in
    /// casing.
    private static func nameKey(for app: CallApp) -> String {
        CallChannelChain.nameKey(for: app)
    }
}
