import SwiftUI

/// Settings → "Appearance" (skinnable home, 2026-09-07): pick one of the
/// warm preset background themes. Tapping a row sets `coordinator.appTheme`
/// and the WHOLE app re-skins instantly (every screen draws its background
/// through `Color(theme:)`). Preset colors only today — a photo-picker
/// background is a noted future option, and the palette keeps text/card
/// contrast by design (see `AppTheme`'s contrast note on `dusk`).
struct AppearanceSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        LeafScreen(titleKey: "settings.appearance.title") {
            VStack(spacing: 12) {
                ForEach(AppTheme.allCases) { theme in
                    themeRow(theme)
                }
            }
        }
    }

    /// One selectable theme: a swatch of the actual background color, the
    /// localized name, and a checkmark on the active theme — the same
    /// shape as `LanguageSettingsView.languageRow`.
    private func themeRow(_ theme: AppTheme) -> some View {
        let isSelected = theme == coordinator.appTheme
        return Button {
            coordinator.appTheme = theme
        } label: {
            HStack(spacing: 14) {
                Circle()
                    .fill(Color(theme: theme))
                    .frame(width: 30, height: 30)
                    // A hairline ring keeps the light swatches (cream on a
                    // white card) visible without affecting the theme look.
                    .overlay(
                        Circle().stroke(DesignTokens.textSecondary.opacity(0.25), lineWidth: 1)
                    )
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(theme.nameKey))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(DesignTokens.accent)
                        .accessibilityHidden(true)
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
}
