import SwiftUI

/// Persisted colour skin. Existing raw IDs remain valid across upgrades.
enum AppTheme: String, CaseIterable, Identifiable {
    case cream, sage, sky, lavender, dusk, lightPink
    case midnight, darkRose

    var isDark: Bool { self == .midnight || self == .darkRose }
    var preferredColorScheme: ColorScheme { isDark ? .dark : .light }

    var id: String { rawValue }
    var nameKey: String { "theme.\(rawValue)" }
    var descriptionKey: String { "appearance.skin.\(rawValue).description" }

    init(rawOrDefault raw: String?) {
        self = raw.flatMap(AppTheme.init(rawValue:)) ?? .sky
    }
}
