import Foundation

/// Light background presets for the app.
///
/// VoiceBridge's warm white is the default canvas. Optional presets tint
/// only the screen background; navy text, white cards and magenta actions
/// remain stable so the brand hierarchy and accessible contrast survive
/// every selection.
enum AppTheme: String, CaseIterable, Identifiable {
    case cream, sage, sky, lavender, dusk, lightPink

    var id: String { rawValue }

    /// Background color per theme. RGB components are 0–1; the view layer
    /// builds the `Color` (`Color(theme:)` in RedesignComponents.swift) —
    /// this file stays SwiftUI-free so the palette is unit-testable
    /// without importing SwiftUI (repo pattern).
    var background: (red: Double, green: Double, blue: Double) {
        switch self {
        case .cream:    return (1.000, 1.000, 1.000)   // #FFFFFF — VoiceBridge light background
        case .sage:     return (0.945, 0.969, 0.949)
        case .sky:      return (0.941, 0.961, 0.984)
        case .lavender: return (0.965, 0.945, 0.976)
        case .dusk:     return (0.875, 0.871, 0.890)
        case .lightPink: return (1.000, 0.941, 0.957)  // #FFF0F4 — brand tint
        }
    }

    /// Localized display-name key per theme.
    var nameKey: String { "theme.\(rawValue)" }

    /// Non-failable decode for launch restore: a missing or unknown value
    /// falls back to the VoiceBridge warm-white preset.
    init(rawOrDefault raw: String?) {
        self = raw.flatMap(AppTheme.init(rawValue:)) ?? .cream
    }
}
