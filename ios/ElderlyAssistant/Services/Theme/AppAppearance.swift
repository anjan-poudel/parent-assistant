import SwiftUI

struct AppAppearance: Equatable {
    let skin: AppTheme
    let style: AppVisualStyle

    static let `default` = AppAppearance(skin: .sky, style: .soft)

    var colors: AppColors { AppColors.palette(for: skin) }

    func badgeTint(_ tint: DesignTokens.BadgeTint) -> Color {
        switch tint {
        case .emergency: DesignTokens.stateError
        case .call: Color(red: 0.075, green: 0.365, blue: 0.235)
        case .directions: Color(red: 0.545, green: 0.282, blue: 0.031)
        case .feeds, .apps: Color(red: 0.086, green: 0.267, blue: 0.525)
        case .meds, .reminders: colors.accent
        case .appliance, .settings: colors.textPrimary
        }
    }

    func badgeBackground(_ tint: DesignTokens.BadgeTint) -> Color {
        switch tint {
        case .emergency: colors.card
        case .call: Color(red: 0.867, green: 0.949, blue: 0.890)
        case .directions: Color(red: 1.0, green: 0.914, blue: 0.780)
        case .feeds, .apps: colors.userBubble
        case .meds, .reminders: colors.brandBlush
        case .appliance, .settings: colors.setupReminder
        }
    }
}

extension EnvironmentValues {
    @Entry var appAppearance: AppAppearance = .default
}

/// Immutable, cached semantic palettes. Surface style never changes these colours.
struct AppColors {
    let background: Color
    let card: Color
    let accent: Color
    let textPrimary: Color
    let textSecondary: Color
    let userBubble: Color
    let setupReminder: Color
    let brandPink: Color
    let brandWine: Color
    let brandCoral: Color
    let brandBlush: Color
    let brandCanvasTop: Color
    let brandCanvasBottom: Color
    let brandDustyRose: Color
    let brandDeepRose: Color
    let talkHighlight: Color
    let talkMid: Color
    let talkDeep: Color
    let warmGlowStart: Color
    let warmGlowEnd: Color
    let onAccent: Color
    let separator: Color

    var brandGradient: LinearGradient {
        LinearGradient(colors: [brandWine, brandCoral], startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }

    private init(background: UInt32, card: UInt32, accent: UInt32,
                 ink: UInt32, secondary: UInt32, wash: UInt32,
                 canvasBottom: UInt32, ribbon: UInt32, deep: UInt32,
                 highlight: UInt32, mid: UInt32, talkDeep: UInt32) {
        self.background = Color(hex: background)
        self.card = Color(hex: card)
        self.accent = Color(hex: accent)
        textPrimary = Color(hex: ink)
        textSecondary = Color(hex: secondary)
        userBubble = Color(hex: wash)
        setupReminder = Color(hex: wash)
        brandPink = Color(hex: accent)
        brandWine = Color(hex: mid)
        brandCoral = Color(hex: highlight)
        brandBlush = Color(hex: wash)
        brandCanvasTop = Color(hex: background)
        brandCanvasBottom = Color(hex: canvasBottom)
        brandDustyRose = Color(hex: ribbon)
        brandDeepRose = Color(hex: deep)
        talkHighlight = Color(hex: highlight)
        talkMid = Color(hex: mid)
        self.talkDeep = Color(hex: talkDeep)
        warmGlowStart = Color(hex: ribbon)
        warmGlowEnd = Color(hex: canvasBottom)
        onAccent = .white
        separator = Color(hex: secondary).opacity(0.24)
    }

    static func palette(for skin: AppTheme) -> AppColors {
        switch skin {
        case .sky: sky
        case .cream: cream
        case .sage: sage
        case .lavender: lavender
        case .dusk: dusk
        case .lightPink: pink
        }
    }

    private static let sky = AppColors(
        background: 0xE9F4FD, card: 0xFFFFFF, accent: 0xAD1741,
        ink: 0x102D50, secondary: 0x385069, wash: 0xD9EAF8,
        canvasBottom: 0xC4DFF4, ribbon: 0x91BEDD, deep: 0x356B96,
        highlight: 0xBE3452, mid: 0xA3163B, talkDeep: 0x630F2A)
    private static let cream = AppColors(
        background: 0xFFF6E8, card: 0xFFFDFA, accent: 0x86421F,
        ink: 0x36291F, secondary: 0x5E4937, wash: 0xF5E2C7,
        canvasBottom: 0xEFDBBB, ribbon: 0xD8B783, deep: 0x936536,
        highlight: 0x97552D, mid: 0x83401E, talkDeep: 0x512B19)
    private static let sage = AppColors(
        background: 0xEAF5EF, card: 0xFAFFFC, accent: 0x186052,
        ink: 0x173B33, secondary: 0x35564B, wash: 0xCCE6DA,
        canvasBottom: 0xBDDDCF, ribbon: 0x91C4B1, deep: 0x377968,
        highlight: 0x23705E, mid: 0x14594A, talkDeep: 0x123D34)
    private static let lavender = AppColors(
        background: 0xF2EEFC, card: 0xFFFCFF, accent: 0x623D8D,
        ink: 0x302348, secondary: 0x514264, wash: 0xE4D9F5,
        canvasBottom: 0xD5C9EB, ribbon: 0xB6A0D7, deep: 0x765498,
        highlight: 0x775096, mid: 0x5C3483, talkDeep: 0x3B2356)
    private static let dusk = AppColors(
        background: 0xE5EAF1, card: 0xF8FAFE, accent: 0x354F78,
        ink: 0x202C40, secondary: 0x3E4D62, wash: 0xD2DDEB,
        canvasBottom: 0xBDCADA, ribbon: 0x8EABC7, deep: 0x486385,
        highlight: 0x4C6489, mid: 0x334E74, talkDeep: 0x25344F)
    private static let pink = AppColors(
        background: 0xFFF0F4, card: 0xFFFCFD, accent: 0x9E2850,
        ink: 0x482335, secondary: 0x654453, wash: 0xF8D8E4,
        canvasBottom: 0xEDC5D5, ribbon: 0xDCA0B6, deep: 0x9C486B,
        highlight: 0xAD3B60, mid: 0x94234C, talkDeep: 0x5E1B37)
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
