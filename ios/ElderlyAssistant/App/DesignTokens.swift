import SwiftUI
import UIKit

/// Shared design tokens for the VoiceBridge visual language.
///
/// The supplied identity uses deep navy, burgundy, coral and pale blush
/// on spacious white surfaces. Functional voice states keep their distinct
/// semantic colours so listening, speaking and failure never rely on the
/// brand gradient alone. All views consume these constants so the ≥18pt
/// body floor, ≥44pt targets and contrast guarantees remain centralized.
enum DesignTokens {

    // MARK: Palette (VoiceBridge)

    static let background = Color.white                                      // #FFFFFF
    static let card = Color(red: 0.973, green: 0.980, blue: 0.988)            // #F8FAFC
    static let accent = Color(red: 0.733, green: 0.118, blue: 0.302)          // #BB1E4D
    static let textPrimary = Color(red: 0.043, green: 0.122, blue: 0.267)     // #0B1F44
    static let textSecondary = Color(red: 0.420, green: 0.447, blue: 0.502)   // #6B7280
    static let userBubble = Color(red: 1.000, green: 0.941, blue: 0.957)      // #FFF0F4
    static let setupReminder = Color(red: 1.000, green: 0.941, blue: 0.957)   // #FFF0F4

    // Voice-session state colors preserve the manual's traffic-light model:
    //   REST (.idle, .stopped) → navy/blue
    //   WAIT (listening/transcribing/understanding) → amber depth ramp
    //   GO (.speaking) → green
    //   STOP (.error) → red
    // Brand magenta is deliberately absent from this table. Every fill keeps
    // ≥4.5:1 white-glyph contrast and ≥3:1 against the warm-white background.
    static let stateIdle = Color(red: 0.086, green: 0.239, blue: 0.451)      // #163D73 — rest blue
    /// Deep VoiceBridge magenta used for branded loading surfaces. It is
    /// intentionally separate from `stateError`: brand never means failure.
    static let brandPink = Color(red: 0.733, green: 0.118, blue: 0.302)      // #BB1E4D
    static let brandWine = Color(red: 0.722, green: 0.118, blue: 0.302)      // #B81E4D
    static let brandCoral = Color(red: 1.000, green: 0.302, blue: 0.478)     // #FF4D7A
    static let brandBlush = Color(red: 1.000, green: 0.839, blue: 0.882)     // #FFD6E1
    // Reference Home background: warm white with broad dusty-rose ribbons.
    static let brandCanvasTop = Color(red: 0.988, green: 0.969, blue: 0.961) // #FCF7F5
    static let brandCanvasBottom = Color(red: 0.973, green: 0.918, blue: 0.929) // #F8EAED
    static let brandDustyRose = Color(red: 0.863, green: 0.647, blue: 0.706) // #DCA5B4
    static let brandDeepRose = Color(red: 0.678, green: 0.325, blue: 0.435) // #AD536F

    // Glossy idle/loading Talk face from the supplied Home design.
    static let talkHighlight = Color(red: 0.945, green: 0.455, blue: 0.518) // #F17484
    static let talkMid = Color(red: 0.659, green: 0.071, blue: 0.278) // #A81247
    static let talkDeep = Color(red: 0.396, green: 0.012, blue: 0.161) // #650329
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
    /// Speaking green: hue-separated from brand magenta and the amber ramp,
    /// including under common color-vision deficiencies.
    static let stateSpeaking = Color(red: 0.180, green: 0.478, blue: 0.094)  // #2E7A18
    /// Error red (#C02F2A, visual-polish 2026-09-08): the "stop" light.
    /// Replaces bare `Color.red` (#FF3B30, ~3.5:1 with white glyphs) with
    /// a deep crimson holding ≥5.7:1 — every settings/log error accent
    /// that read this token gets the better contrast for free.
    static let stateError = Color(red: 0.753, green: 0.184, blue: 0.165)     // #C02F2A

    // MARK: - Brand glow
    //
    // The reference artwork layers coral, crimson and burgundy ribbons.
    // These colors are reserved for identity, primary actions and the
    // assistant's glow; semantic status fills above remain unambiguous.
    static let warmGlowStart = brandCoral
    static let warmGlowEnd = brandWine

    static let brandGradient = LinearGradient(
        colors: [brandWine, brandCoral],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)

    /// Icon-badge tints collapse app categories onto four semantic roles:
    ///
    ///   • `brandAction` — medication, phone and reminders use VoiceBridge
    ///                     magenta on blush.
    ///   • `voiceState` — launchers use the hero's calm rest blue.
    ///   • `emergency` — stop red is reserved for urgency.
    ///   • `neutralCategory` — supporting destinations use brand navy.
    ///
    /// Case names remain semantic at call sites even where categories share
    /// one color role; strong color communicates priority, not decoration.
    enum BadgeTint {
        case meds, reminders, call, appliance, settings, apps, feeds, emergency, directions

        /// The four semantic colour roles. `CaseIterable` so
        /// `DesignTokensTests` can pin that no fifth role creeps back in.
        enum Role: CaseIterable {
            case brandAction, voiceState, emergency, neutralCategory
        }

        /// Which role this category's badge wears. This mapping IS the
        /// consolidation — the colour tables below switch on it, so a
        /// category can never drift to its own hue again.
        var role: Role {
            switch self {
            case .meds, .reminders, .call:
                return .brandAction
            case .apps:
                return .voiceState
            case .emergency:
                return .emergency
            case .appliance, .settings, .feeds, .directions:
                return .neutralCategory
            }
        }

        var background: Color {
            switch role {
            case .brandAction: return DesignTokens.brandBlush
            case .voiceState: return DesignTokens.stateVoiceRestWash
            case .emergency: return DesignTokens.card
            case .neutralCategory: return DesignTokens.brandBlush.opacity(0.72)
            }
        }

        var tint: Color {
            switch role {
            case .brandAction: return DesignTokens.accent
            case .voiceState: return DesignTokens.stateIdle
            case .emergency: return DesignTokens.stateError
            case .neutralCategory: return DesignTokens.textPrimary
            }
        }
    }

    /// Pale blue-white wash behind the voice-state badge role.
    static let stateVoiceRestWash = Color(red: 0.910, green: 0.941, blue: 0.980) // #E8F0FA

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
    /// [HOME-TIMER-CHIP] The ticking digits of the home timer chip — a
    /// step above the body floor (elderly legibility: the remaining time
    /// is the ONE number on Home that must be readable at a glance),
    /// below the title sizes so the chip stays a chip.
    static var homeTimerDigitPointSize: CGFloat { scaled(28) }

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

    /// Large continuous-feeling corners echo the supplied app icon and cards.
    static let cardCornerRadius: CGFloat = 24
    static let bubbleCornerRadius: CGFloat = 14
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
    /// Two-row Home dock: two 56pt rows, divider and vertical padding.
    static let dockHeight: CGFloat = 152
    static let iconBadgeDiameter: CGFloat = 44
}
