import SwiftUI
import UIKit

/// A text-size preference independent of the colour skin and surface style.
enum AppTextSize: String, CaseIterable, Identifiable {
    case system, small, medium, large, xl, xxl

    var id: String { rawValue }
    var nameKey: String { "textSize.\(rawValue)" }
    var descriptionKey: String { "textSize.\(rawValue).description" }

    init(rawOrDefault raw: String?) {
        self = raw.flatMap(AppTextSize.init(rawValue:)) ?? .system
    }

    /// Nil deliberately means inherit the device setting, including accessibility sizes.
    var dynamicTypeSize: DynamicTypeSize? {
        switch self {
        case .system: nil
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xl: .xLarge
        case .xxl: .xxLarge
        }
    }

    var contentSizeCategory: UIContentSizeCategory? {
        switch self {
        case .system: nil
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xl: .extraLarge
        case .xxl: .extraExtraLarge
        }
    }
}

private struct AppTextSizeModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var inheritedSize
    @Environment(\.appAppearance) private var appearance
    let selection: AppTextSize

    func body(content: Content) -> some View {
        content
            .environment(\.dynamicTypeSize, selection.dynamicTypeSize ?? inheritedSize)
            .environment(\.appAppearance, AppAppearance(
                skin: appearance.skin, style: appearance.style, textSize: selection,
                systemContentSizeCategory: inheritedCategory))
    }

    private var inheritedCategory: UIContentSizeCategory {
        switch inheritedSize {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

extension View {
    /// Changes native text styles and ScaledMetric without replacing the view hierarchy.
    func appTextSize(_ selection: AppTextSize) -> some View {
        modifier(AppTextSizeModifier(selection: selection))
    }
}
