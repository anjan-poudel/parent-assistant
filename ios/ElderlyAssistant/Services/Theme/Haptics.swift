import SwiftUI
import UIKit

// MARK: - Haptics (native-responsiveness pass, 2026-10-14)
//
// The app's ONE haptic vocabulary. Before this file the app produced no
// haptics at all: every primary interaction (a settings row, a
// confirmation, silencing a ringing alarm) confirmed itself only on
// screen, and for an elder looking at the phone from arm's length — or
// mid-turn, when the reply is still being spoken — a silent press can
// read as "the tap didn't land". The Taptic Engine is the native channel
// for exactly that confirmation, and it costs nothing on the main thread.
//
// [RESPONSIVENESS] Why a generator call and not the iOS 17
// `.sensoryFeedback` modifier: `sensoryFeedback` fires when an
// `Equatable` trigger VALUE changes, so every call site would have to
// hold a counter/Bool that flips per interaction — state whose only
// purpose is to re-trigger the modifier, and one more value the
// `.equatable()` slices would have to compare. The generator call inside
// the action closure is the no-state form, works unchanged on the 16.0
// floor, and needs no per-site plumbing. If the floor ever moves to 17+,
// `.sensoryFeedback` can be adopted behind this same vocabulary — the
// three kinds below are the seam, not the generators.
//
// The accessibility contract (owner directive: subtle, consistent, and
// never fighting the user's own settings):
//   * `accessibilityReduceMotion` — no haptics at all (see
//     `HapticsPolicy` for why motion-sensitive users get silence here
//     too, and why it is wholesale rather than per-kind).
//   * VoiceOver — no haptics at all: VoiceOver confirms every action it
//     activates with speech of its own, and a competing buzz only
//     muddies that channel. This is the same wholesale-withholding rule
//     `DegradedModeStatusPill` states for its own feedback ("silent —
//     no sound, haptics, or interruption").
//   * The system's own Sounds & Haptics switches are honored by UIKit
//     automatically: with System Haptics off, the generators no-op.
//
// Deliberately NOT wired here (owned elsewhere / pipeline territory):
// the Talk hero's activation feedback (the hero is being rebuilt in a
// parallel session — it should call `Haptics.play(.tap)` at its own
// press site), the dock and the Home yes/no confirmation chips (same
// two excluded files), and the wake-word path (a haptic at KWS
// detection would fire for a phone lying on a table, not in a hand —
// the spoken wake acknowledgment is the feedback there).

/// The three feels the app is allowed to use. Kept deliberately tiny —
/// a haptic vocabulary only stays "subtle, consistent" if every site
/// picks from the same short list rather than dialing custom feedback.
/// `CaseIterable` so the vocabulary size is pinned by a test
/// (`HapticsTests`): a fourth feel is a deliberate vocabulary change.
enum HapticKind: CaseIterable {
    /// A control was pressed and the app registered it: settings rows,
    /// tab pills, card actions. Light impact — felt, never startling.
    case tap
    /// A choice changed under the finger (the settings tab pills landing
    /// on a new tab). The system selection tick, not an impact.
    case selection
    /// A consequential action completed — silencing a ringing alarm.
    /// The success notification's double-tick; reserved for the moments
    /// where "it worked" is the message.
    case success
}

/// The pure accessibility half of the haptic decision (native-
/// responsiveness pass): whether ANY haptic may play, given the two
/// system switches that matter. Split out from `Haptics` so it is
/// unit-testable without a device, exactly like the other pure seams
/// (`HistoryRowOrderer`, `StoragePlacementPolicy`).
///
/// Both gates are wholesale — no per-kind exceptions. Reduce Motion is
/// about MORE THAN visuals for the users who enable it: it is the
/// system's "fewer non-essential sensory effects" switch, and the elders
/// this app serves who turn it on are asking for calmer feedback, not
/// for the same feedback in a different channel. VoiceOver is the same
/// argument from the other side: its users already receive a spoken
/// confirmation for every action it activates, and an unasked-for buzz
/// layered on that is noise in a channel the user is actively listening
/// to. When in doubt, the app stays silent — the visual confirmation
/// (the row's push, the alarm's dismissal) still happens either way.
enum HapticsPolicy {

    /// Whether a haptic may play. Pure: the caller reads the two system
    /// flags (see `Haptics.play`), so the truth table is testable.
    static func shouldPlay(reduceMotion: Bool, voiceOverRunning: Bool) -> Bool {
        !reduceMotion && !voiceOverRunning
    }
}

/// The app's haptic player. `@MainActor` because `UIFeedbackGenerator`s
/// are main-thread objects — which also means every call site is a UI
/// action by construction, and a haptic can never be fired from the
/// voice pipeline's queues by accident.
@MainActor
enum Haptics {

    /// One shared generator per kind, created once: `prepare()` keeps
    /// the Taptic Engine primed for a few seconds, so re-preparing the
    /// SAME instance after each play keeps the next press instant
    /// (a fresh generator per call would arrive cold and land late —
    /// the one thing a confirmation haptic must never do).
    private static let tapGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let successGenerator = UINotificationFeedbackGenerator()

    /// Plays `kind`, unless the accessibility gates say otherwise (see
    /// `HapticsPolicy`) or the system's Sounds & Haptics switch is off
    /// (UIKit handles that one inside the generators themselves).
    static func play(_ kind: HapticKind) {
        guard HapticsPolicy.shouldPlay(
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            voiceOverRunning: UIAccessibility.isVoiceOverRunning) else { return }

        switch kind {
        case .tap:
            tapGenerator.impactOccurred()
            tapGenerator.prepare()
        case .selection:
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
        case .success:
            successGenerator.notificationOccurred(.success)
            successGenerator.prepare()
        }
    }
}

extension View {
    /// Fires the standard press confirmation alongside this view's own
    /// tap handling. `simultaneousGesture` deliberately: it runs the
    /// haptic WITHOUT consuming or reordering the tap the control itself
    /// needs, so `Button` actions and `NavigationLink` pushes keep
    /// working byte-for-byte — this modifier can be attached to either.
    ///
    /// Call sites pass the kind that matches what happened; the default
    /// is the generic `tap` feel. Under VoiceOver this gesture usually
    /// does not fire at all (activation is a direct accessibility
    /// action, not a tap), which is consistent with `HapticsPolicy`'s
    /// wholesale suppression there.
    func hapticOnTap(_ kind: HapticKind = .tap) -> some View {
        simultaneousGesture(TapGesture().onEnded { Haptics.play(kind) })
    }
}
