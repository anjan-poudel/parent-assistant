import Foundation

/// Warm preset themes for the app background (skinnable home, 2026-09-07).
///
/// The SCREEN BACKGROUND is the only themed surface: text stays
/// `DesignTokens.textPrimary` (near-black) and cards stay white, so the
/// light presets keep the existing WCAG AA contrast by construction. The
/// one caveat is `dusk` — a muted warm NIGHT tone, still deliberately kept
/// slightly lighter than the near-black text that sits on it (its RGB is
/// ~0.85 per channel vs ~0.24/0.18/0.14 for textPrimary; the luminance gap
/// is pinned by AppThemeTests). A photo-picker background is a noted
/// future option — preset colors only today.
enum AppTheme: String, CaseIterable, Identifiable {
    case cream, sage, sky, lavender, dusk

    var id: String { rawValue }

    /// Background color per theme. RGB components are 0–1; the view layer
    /// builds the `Color` (`Color(theme:)` in RedesignComponents.swift) —
    /// this file stays SwiftUI-free so the palette is unit-testable
    /// without importing SwiftUI (repo pattern).
    var background: (red: Double, green: Double, blue: Double) {
        switch self {
        case .cream:    return (0.980, 0.953, 0.914)   // #FAF3E9 — today's DesignTokens.background
        case .sage:     return (0.925, 0.949, 0.914)
        case .sky:      return (0.914, 0.941, 0.953)
        case .lavender: return (0.941, 0.925, 0.953)
        case .dusk:     return (0.855, 0.847, 0.820)   // muted warm night — see contrast note above
        }
    }

    /// Localized display-name key per theme.
    var nameKey: String { "theme.\(rawValue)" }

    /// Non-failable decode for the coordinator's launch restore: a missing
    /// key or a raw value naming no case falls back to `.cream` (the
    /// launch default). `init(rawValue:)` stays failable — an unknown raw
    /// string genuinely does NOT decode (pinned by AppThemeTests) — only
    /// this restore path swallows it, so a stale persisted value can never
    /// wedge the app (same house rule as `voiceEngineStack`/wake word).
    init(rawOrDefault raw: String?) {
        self = raw.flatMap(AppTheme.init(rawValue:)) ?? .cream
    }
}
