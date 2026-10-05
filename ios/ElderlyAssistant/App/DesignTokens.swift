import SwiftUI
import UIKit

/// Shared accessibility, layout and invariant operational colours.
/// Skin colours belong to the environment's AppAppearance palette.
enum DesignTokens {


    // Voice-session state colors preserve the manual's traffic-light model:
    //   REST (.idle, .stopped) → navy/blue
    //   WAIT (listening/transcribing/understanding) → amber depth ramp
    //   GO (.speaking) → green
    //   STOP (.error) → red
    // Brand magenta is deliberately absent from this table. Every fill keeps
    // ≥4.5:1 white-glyph contrast and ≥3:1 against the warm-white background.
    static let stateIdle = Color(red: 0.086, green: 0.239, blue: 0.451)      // #163D73 — rest blue
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

    // MARK: - Live camera translation highlight

    /// The green the live overlay's boxes are washed with — the owner's own
    /// description of the look they asked for (2026-09-18): "the bounding box
    /// can be TRANSPARENT GREEN with DARK COLORED TEXT — text plus the
    /// transparent green overlay".
    ///
    /// A **new** token rather than `stateSpeaking`, which is the only other
    /// green in this table. The state fills above are a vocabulary the elder
    /// learns about the *voice* (listening, speaking, failed), and reusing one
    /// would make a translation box say something about the microphone. It is
    /// also the wrong green for the job: the state greens are tuned to hold
    /// white glyphs at ≥4.5:1 on an opaque fill, and this one is tuned to do
    /// the opposite — stay light enough under a wash that near-black type
    /// inside it clears the contrast floor, while still reading as green over
    /// the photograph behind it.
    ///
    /// The wash's opacity is not here: it is an operational value with a
    /// config key (`LiveTranslateConfig.overlayHighlightOpacity`), because a
    /// device check may want a heavier or lighter wash without touching the
    /// token table.
    static let overlayHighlight = Color(red: 0.204, green: 0.659, blue: 0.325) // #34A853
    /// Fixed ink for text drawn over camera/photograph highlight washes.
    static let overlayText = Color(red: 0.043, green: 0.122, blue: 0.267)

    enum BadgeTint {
        case meds, reminders, call, appliance, settings, apps, feeds, emergency, directions

    }

    /// Pale blue-white wash behind the voice-state badge role.
    static let stateVoiceRestWash = Color(red: 0.910, green: 0.941, blue: 0.980) // #E8F0FA

    // MARK: Operational camera typography
    //
    // These system-scaled floors are ONLY for camera/evidence annotation geometry
    // and headless rendering fixtures. They do not represent the app's UI preference:
    // readable UI text must use the environment's AppAppearance.typography.
    static var minBodyPointSize: CGFloat { scaled(21) }
    static var minCaptionPointSize: CGFloat { scaled(18) }

    private static func scaled(_ base: CGFloat) -> CGFloat {
        UIFontMetrics.default.scaledValue(for: base)
    }

    /// Greeting/heading display font (visual-polish 2026-09-08): the
    /// serif ("New York") display face gave way to rounded SF — friendlier
    /// and warmer for short human-facing words ("Good morning", leaf
    /// titles). Body/list text stays on the regular sans design for dense
    /// reading. Callers pass the environment-resolved point size explicitly.
    static func greetingFont(size: CGFloat) -> Font {
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
