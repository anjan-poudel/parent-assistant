import SwiftUI

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

    // MARK: Type scale (spec §3.1)

    /// Minimum body size — accessibility floor, not a suggestion.
    static let minBodyPointSize: CGFloat = 18
    /// Minimum caption/label size — captions are "secondary" text, still ≥15pt.
    static let minCaptionPointSize: CGFloat = 15
    static let titlePointSize: CGFloat = 28
    static let greetingPointSize: CGFloat = 30

    /// Serif display for greetings/headings; sans for body.
    static func greetingFont(size: CGFloat = DesignTokens.greetingPointSize) -> Font {
        .system(size: size, weight: .bold, design: .serif)
    }

    // MARK: Shape & spacing

    static let cardCornerRadius: CGFloat = 14
    static let bubbleCornerRadius: CGFloat = 10
    static let minTapTargetSize: CGFloat = 44
    static let interElementSpacing: CGFloat = 8
    /// The hero Talk button is a full circle ≥120pt (spec §3.1, D5).
    static let talkButtonDiameter: CGFloat = 132
    static let chipHeight: CGFloat = 60
    static let hubCardMinHeight: CGFloat = 100
}
