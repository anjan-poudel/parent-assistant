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

    // Voice-session state colors — traffic-light scheme (visual-polish,
    // 2026-09-08):
    //   REST  (.idle, .stopped)      → blue family  — calm "ready, press me"
    //   WAIT  (listening/transcribing/understanding) → one AMBER family —
    //     the old brown/purple variants collapsed into a single coherent
    //     amber ramp whose subtle depth steps mark progress, never hue
    //     jumps, so the whole mid-cycle reads "processing — hold on"
    //   GO    (.speaking)            → green (hue-separated from `accent`)
    //   STOP  (.error)               → red (never used for idle/off)
    // Every fill keeps ≥4.5:1 white-glyph contrast (unit-tested in
    // DesignTokensTests) and ≥3:1 against the cream background.
    static let stateIdle = Color(red: 0.231, green: 0.431, blue: 0.647)      // #3B6EA5 — rest blue
    /// "Voice is off" (visual-polish 2026-09-08): the honest dimmed-blue
    /// sibling of `stateIdle` — same hue family, clearly darker, so an
    /// off/stopped hero never reads as an alarm (red is reserved for
    /// `.error`) yet never masquerades as fully "ready". Boot-time start
    /// FAILURES land in `.error` (red) via the pipeline watchdog, so this
    /// token stays an off-state color, not an error color. Settings'
    /// voice `.off` status cards share it.
    static let stateStopped = Color(red: 0.306, green: 0.384, blue: 0.478)   // #4E627A — dimmed blue
    /// Assistant-is-listening amber (#A8620C, visual-polish 2026-09-08).
    /// Traffic-light "wait" — the lightest step of the amber processing
    /// ramp; deliberately DEEP enough that white glyphs on the hero hold
    /// ≥4.5:1 (the old #C77F2A ran at ~3.2:1).
    static let stateListening = Color(red: 0.659, green: 0.384, blue: 0.047) // #A8620C
    /// Transcribing — second, deeper amber step of the processing ramp
    /// ("still working").
    static let stateTranscribing = Color(red: 0.561, green: 0.322, blue: 0.031) // #8F5208
    /// Understanding — deepest amber/bronze step of the ramp. Also the
    /// awaiting-confirmation tint (waiting on a yes/no is still "wait").
    static let stateUnderstanding = Color(red: 0.478, green: 0.290, blue: 0.059) // #7A4A0F
    /// Speaking green (#2E7A18, visual-polish 2026-09-08): traffic-light
    /// "go". A yellow-green (hue ≈106°) deliberately far from `accent`
    /// (#2A7F62, hue ≈160°) and from the amber ramp (hue ≈33°) so
    /// speaking can never be mistaken for listening OR for an accent-
    /// green action — including under common color-vision deficiencies.
    static let stateSpeaking = Color(red: 0.180, green: 0.478, blue: 0.094)  // #2E7A18
    /// Error red (#C02F2A, visual-polish 2026-09-08): the "stop" light.
    /// Replaces bare `Color.red` (#FF3B30, ~3.5:1 with white glyphs) with
    /// a deep crimson holding ≥5.7:1 — every settings/log error accent
    /// that read this token gets the better contrast for free.
    static let stateError = Color(red: 0.753, green: 0.184, blue: 0.165)     // #C02F2A

    // MARK: - Warm amber glow (redesign spec §2 — Diya Warmth)
    //
    // Static warm-amber pair for NON-voice-stage warmth: the FaceAvatar
    // initials gradient and the Appliance scan reticle. Deliberately NOT
    // the talk stage's glow — since visual-polish 2026-09-08 the hero's
    // light (halo, breathing rings, carousel dots, shadow) derives from
    // the ACTIVE state tint, so a resting hero breathes blue, a listening
    // one amber, a speaking one green.
    static let warmGlowStart = Color(red: 0.965, green: 0.698, blue: 0.365)  // #F6B25E
    static let warmGlowEnd = Color(red: 0.851, green: 0.510, blue: 0.180)    // #D9822E

    /// Icon-badge tints (redesign spec §2 — replaces bare gray SF Symbols).
    /// Each badge is `tint` on `background`, matching the icon's semantic
    /// color family used elsewhere (meds = accent family, reminders =
    /// bronze, call = warm vermilion, appliance = brown, settings =
    /// purple, emergency = red, apps/directions = blue-cyan category).
    /// Visual-polish 2026-09-08: `call` moved out of the blue family to a
    /// warm vermilion (#C2541F) so the ONLY blues left are the app-
    /// category badges (apps, directions) — the hero's traffic-light blue
    /// rest never competes with a navy call tile — and `settings` now
    /// keeps its own purple instead of borrowing the voice-state palette.
    enum BadgeTint {
        case meds, reminders, call, appliance, settings, apps, emergency, directions

        var background: Color {
            switch self {
            case .meds: return Color(red: 0.902, green: 0.945, blue: 0.925)      // #E6F1EC
            case .reminders: return Color(red: 0.992, green: 0.918, blue: 0.824) // #FDEAD2
            case .call: return Color(red: 0.976, green: 0.886, blue: 0.835)      // #F9E2D5 — pale salmon
            case .appliance: return Color(red: 0.992, green: 0.945, blue: 0.890)  // #FDF1E3
            case .settings: return Color(red: 0.937, green: 0.918, blue: 0.965)  // #EFEAF6
            case .apps: return Color(red: 0.878, green: 0.941, blue: 0.949)      // #E0F0F2
            case .emergency: return Color.white
            case .directions: return Color(red: 0.867, green: 0.945, blue: 0.969) // #DDF1F7
            }
        }
        var tint: Color {
            switch self {
            case .meds: return DesignTokens.accent
            case .reminders: return Color(red: 0.706, green: 0.392, blue: 0.118) // #B4641E
            case .call: return Color(red: 0.761, green: 0.329, blue: 0.122)      // #C2541F — warm vermilion
            case .appliance: return Color(red: 0.541, green: 0.427, blue: 0.231)  // #8A6D3B
            // Settings keeps its own purple (#5C5A8A, 2026-09-08) — it
            // used to alias the voice-state understanding token, which
            // has since joined the amber processing ramp; a gear badge
            // must not silently track voice-state colors.
            case .settings: return Color(red: 0.361, green: 0.353, blue: 0.541)  // #5C5A8A
            case .apps: return Color(red: 0.122, green: 0.478, blue: 0.549)      // #1F7A8C
            case .emergency: return Color(red: 0.706, green: 0.251, blue: 0.118) // #B4401E
            // Directions/maps (2026-09-07): the one dock badge in the
            // blue-cyan family that reads "navigation" — lighter and
            // brighter than the Quick apps' teal so the two never merge
            // (the call badge left the blue family in visual-polish
            // 2026-09-08, so no navy neighbor remains).
            case .directions: return Color(red: 0.106, green: 0.522, blue: 0.639) // #1B85A3
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
    static var minBodyPointSize: CGFloat { scaled(21) }
    /// Minimum caption/label size — captions are "secondary" text, still ≥15pt.
    static var minCaptionPointSize: CGFloat { scaled(18) }
    static var titlePointSize: CGFloat { scaled(32) }
    static var greetingPointSize: CGFloat { scaled(33) }

    private static func scaled(_ base: CGFloat) -> CGFloat {
        UIFontMetrics.default.scaledValue(for: base)
    }

    /// Greeting/heading display font (visual-polish 2026-09-08): the
    /// serif ("New York") display face gave way to rounded SF — friendlier
    /// and warmer for short human-facing words ("Good morning", leaf
    /// titles). Body/list text stays on the regular sans design for dense
    /// reading. Same scale behavior as before: callers pass a token size.
    static func greetingFont(size: CGFloat = DesignTokens.greetingPointSize) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    /// Warm rounded SF for SHORT catalog microcopy — status lines, hint
    /// carousel, chips, hero captions — the "warm & soft" voice of the
    /// app (visual-polish 2026-09-08). Dense reading matter (outcome
    /// rows, transcripts, leaf lists) deliberately stays on the regular
    /// design for legibility.
    ///
    /// Devanagari note (2026-09-04, see `ElderlyAssistantApp`): SF
    /// Rounded's Devanagari coverage is not verified, so Nepali glyphs
    /// resolve through the system's fallback Devanagari face — same
    /// rendering the regular design gives them today, no tofu risk.
    /// That is why this helper is applied ONLY to short catalog strings
    /// and never to dynamic (Gemini/STT-generated) Nepali content.
    static func warmFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: Shape & spacing

    /// Bumped from 14pt (redesign spec §2) — softer, more "cushioned" cards.
    static let cardCornerRadius: CGFloat = 20
    static let bubbleCornerRadius: CGFloat = 10
    static let minTapTargetSize: CGFloat = 44
    static let interElementSpacing: CGFloat = 8
    /// The hero Talk button is a full circle ≥120pt (spec §3.1, D5).
    static let talkButtonDiameter: CGFloat = 132
    /// Long-press duration for the Talk hero's hold-to-reset path
    /// (TALK-CRASH-FIX, 2026-09-07): how long a hold must last before
    /// voice activation is cancelled and the session returns to idle.
    /// 2.0s — comfortably past any accidental hold (taps are sub-0.3s),
    /// short enough that the wait never feels like a dead button (the
    /// progress ring + "keep holding" hint make it legible either way),
    /// and inside the "a few seconds" the feature brief asked for. If it
    /// ever changes, the progress ring animates over this same value, so
    /// ring completion and the reset stay in sync automatically.
    static let talkResetHoldSeconds: TimeInterval = 2.0
    static let chipHeight: CGFloat = 60
    /// Bottom shortcut dock (redesign spec §3.1 — replaces the 2×2 hub grid;
    /// Home is the only screen that shows it).
    static let dockHeight: CGFloat = 88
    static let iconBadgeDiameter: CGFloat = 44
}
