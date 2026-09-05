import SwiftUI
import UIKit

/// Shared design tokens for the "Warm & Soft" style (spec §3.1).
///
/// All views consume these constants — never per-view literals — so the
/// accessibility requirements (≥18pt body, ≥44pt targets, WCAG AA contrast)
/// are enforceable in one place (unit-tested per spec §8).
enum DesignTokens {

    // MARK: Palette (Warm & Soft)

    static let background = Color(red: 0.980, green: 0.953, blue: 0.914)      // #FAF3E9
    static let card = Color.white
    static let accent = Color(red: 0.165, green: 0.498, blue: 0.384)          // #2A7F62
    static let textPrimary = Color(red: 0.239, green: 0.184, blue: 0.141)     // #3D2F24
    static let textSecondary = Color(red: 0.541, green: 0.459, blue: 0.384)   // #8A7562
    static let userBubble = Color(red: 0.902, green: 0.945, blue: 0.925)      // #E6F1EC
    static let setupReminder = Color(red: 0.992, green: 0.945, blue: 0.890)   // #FDF1E3

    // Voice-session state colors (§3.3)
    static let stateIdle = accent
    static let stateListening = Color(red: 0.780, green: 0.498, blue: 0.161)  // #C77F2A
    static let stateTranscribing = Color(red: 0.541, green: 0.427, blue: 0.231) // #8A6D3B
    static let stateUnderstanding = Color(red: 0.361, green: 0.353, blue: 0.541) // #5C5A8A
    static let stateError = Color.red
    static let stateStopped = Color.gray

    // MARK: - Talk hero glow (redesign spec §2 — Diya Warmth)
    //
    // Amber, distinct from `accent` green on purpose: amber = "listening /
    // live", green = "confirmed / done". The hero's gradient and breathing
    // rings use these; nothing else should.
    static let talkGlowStart = Color(red: 0.965, green: 0.698, blue: 0.365)   // #F6B25E
    static let talkGlowEnd = Color(red: 0.851, green: 0.510, blue: 0.180)     // #D9822E

    /// Icon-badge tints (redesign spec §2 — replaces bare gray SF Symbols).
    /// Each badge is `tint` on `background`, matching the icon's semantic
    /// color family used elsewhere (meds/reminders = accent family, call =
    /// blue, settings = purple, emergency = red).
    enum BadgeTint {
        case meds, reminders, call, settings, emergency

        var background: Color {
            switch self {
            case .meds: return Color(red: 0.902, green: 0.945, blue: 0.925)      // #E6F1EC
            case .reminders: return Color(red: 0.992, green: 0.918, blue: 0.824) // #FDEAD2
            case .call: return Color(red: 0.906, green: 0.933, blue: 0.973)      // #E6EEF8
            case .settings: return Color(red: 0.937, green: 0.918, blue: 0.965)  // #EFEAF6
            case .emergency: return Color.white
            }
        }
        var tint: Color {
            switch self {
            case .meds: return DesignTokens.accent
            case .reminders: return Color(red: 0.706, green: 0.392, blue: 0.118) // #B4641E
            case .call: return Color(red: 0.165, green: 0.373, blue: 0.561)      // #2A5F8F
            case .settings: return DesignTokens.stateUnderstanding
            case .emergency: return Color(red: 0.706, green: 0.251, blue: 0.118) // #B4401E
            }
        }
    }

    // MARK: Type scale (spec §3.1, redesign spec §7)
    //
    // These are computed, not stored: `UIFontMetrics` scales the base value
    // against the user's current Dynamic Type setting, so 18pt/15pt become
    // the floor at the *default* content size category, not a hard ceiling
    // that ignores a user who's turned their system text size up. Every
    // existing call site (`DesignTokens.minBodyPointSize`, etc.) picks this
    // up automatically — no per-view changes needed.

    /// Minimum body size — accessibility floor, not a suggestion.
    static var minBodyPointSize: CGFloat { scaled(18) }
    /// Minimum caption/label size — captions are "secondary" text, still ≥15pt.
    static var minCaptionPointSize: CGFloat { scaled(15) }
    static var titlePointSize: CGFloat { scaled(28) }
    static var greetingPointSize: CGFloat { scaled(30) }

    private static func scaled(_ base: CGFloat) -> CGFloat {
        UIFontMetrics.default.scaledValue(for: base)
    }

    /// Serif display for greetings/headings; sans for body.
    static func greetingFont(size: CGFloat = DesignTokens.greetingPointSize) -> Font {
        .system(size: size, weight: .bold, design: .serif)
    }

    // MARK: Shape & spacing

    /// Bumped from 14pt (redesign spec §2) — softer, more "cushioned" cards.
    static let cardCornerRadius: CGFloat = 20
    static let bubbleCornerRadius: CGFloat = 10
    static let minTapTargetSize: CGFloat = 44
    static let interElementSpacing: CGFloat = 8
    /// The hero Talk button is a full circle ≥120pt (spec §3.1, D5).
    static let talkButtonDiameter: CGFloat = 132
    static let chipHeight: CGFloat = 60
    /// Bottom shortcut dock (redesign spec §3.1 — replaces the 2×2 hub grid;
    /// Home is the only screen that shows it).
    static let dockHeight: CGFloat = 76
    static let iconBadgeDiameter: CGFloat = 40
}
