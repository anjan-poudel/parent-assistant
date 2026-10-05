import SwiftUI

/// Changes affect the existing hierarchy immediately, without resetting navigation.
struct AppearanceSettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.appAppearance) private var appearance

    var body: some View {
        LeafScreen(titleKey: "settings.appearance.title") {
            VStack(alignment: .leading, spacing: 20) {
                AppearancePreview()
                sectionTitle("appearance.textSize")
                Text("textSize.independentChoices")
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(AppTextSize.allCases) { size in
                    selectionRow(nameKey: size.nameKey, descriptionKey: size.descriptionKey,
                                 selected: coordinator.appTextSize == size,
                                 identifier: "textSize.\(size.rawValue)") {
                        coordinator.appTextSize = size
                    }
                }
                sectionTitle("appearance.visualStyle")
                Text("appearance.independentChoices")
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                ForEach(AppVisualStyle.allCases) { style in
                    selectionRow(nameKey: style.nameKey, descriptionKey: style.descriptionKey,
                                 selected: coordinator.appVisualStyle == style,
                                 identifier: "appearance.style.\(style.rawValue)",
                                 swatchSkin: coordinator.appTheme) {
                        coordinator.appVisualStyle = style
                    }
                }
                sectionTitle("appearance.colourSkin")
                ForEach(AppTheme.allCases) { skin in
                    selectionRow(nameKey: skin.nameKey, descriptionKey: skin.descriptionKey,
                                 selected: coordinator.appTheme == skin,
                                 identifier: "appearance.skin.\(skin.rawValue)", swatchSkin: skin) {
                        coordinator.appTheme = skin
                    }
                }
            }
        }
    }

    private func sectionTitle(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
            .foregroundStyle(appearance.colors.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    private func selectionRow(nameKey: String, descriptionKey: String, selected: Bool,
                              identifier: String, swatchSkin: AppTheme? = nil,
                              action: @escaping () -> Void) -> some View {
        return Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                if let swatchSkin {
                    let colors = AppColors.palette(for: swatchSkin)
                    VStack(spacing: 3) {
                        Circle().fill(colors.background)
                        Circle().fill(colors.accent)
                        Circle().fill(colors.textPrimary)
                    }
                    .frame(width: 20, height: 66)
                    .overlay { Capsule().strokeBorder(appearance.colors.separator, lineWidth: 1) }
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(LocalizedStringKey(nameKey))
                        .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                        .foregroundStyle(appearance.colors.textPrimary)
                    Text(LocalizedStringKey(descriptionKey))
                        .font(.system(size: appearance.typography.captionPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(selected ? appearance.colors.accentForeground : appearance.colors.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize, alignment: .leading)
            .appSurface(role: .control)
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius)
                    .strokeBorder(selected ? appearance.colors.accentForeground : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
        .accessibilityValue(Text(LocalizedStringKey(selected ? "appearance.selected" : "appearance.notSelected")))
    }
}

private struct AppearancePreview: View {
    @Environment(\.appAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("appearance.preview")
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(appearance.colors.textPrimary)
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                Text("appearance.preview.talk")
                    .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("appearance.preview.talk")
            }
            .foregroundStyle(appearance.colors.onAccent)
            .padding(16)
            .frame(maxWidth: .infinity)
            .appSurface(role: .accent)
            HStack(spacing: 10) {
                Image(systemName: "bell.fill")
                    .foregroundStyle(appearance.badgeTint(.reminders))
                    .padding(10)
                    .background(appearance.badgeBackground(.reminders), in: .circle)
                Text("appearance.preview.card")
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSurface()
            Text(LocalizedStringKey(appearance.style.nameKey))
                .font(.system(size: appearance.typography.captionPointSize, weight: .semibold))
                .foregroundStyle(appearance.colors.onAccent)
                .padding(12)
                .frame(maxWidth: .infinity)
                .appSurface(role: .dock)
        }
        .padding(18)
        .background(LinearGradient(colors: [appearance.colors.brandCanvasTop,
                                           appearance.colors.brandCanvasBottom],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius + 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appearance.preview")
    }
}
