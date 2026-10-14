import XCTest
import UIKit
@testable import ElderlyAssistant

/// The haptics accessibility contract (native-responsiveness pass,
/// 2026-10-14). `HapticsPolicy` is the pure gate in front of every
/// haptic the app plays — `Haptics.play` reads the two system flags and
/// asks it — so its truth table is pinned here without a device: the
/// app must stay SILENT for anyone who asked the system for calmer
/// feedback (Reduce Motion) or who is listening to VoiceOver, and play
/// only when both gates are clear. The vocabulary size is pinned too:
/// "subtle, consistent" survives only if the three documented kinds are
/// a deliberate budget, not a starting point.
final class HapticsTests: XCTestCase {

    /// The full truth table — four inputs, two outcomes, no middle
    /// ground. A regression that flips either gate (e.g. making Reduce
    /// Motion depend on the kind, or letting VoiceOver through) fails
    /// here before it ever reaches a device.
    func testHapticsPlayOnlyWhenBothAccessibilityGatesAreClear() {
        XCTAssertTrue(HapticsPolicy.shouldPlay(reduceMotion: false,
                                               voiceOverRunning: false),
                      "the default system state must allow the app's press confirmations")
        XCTAssertFalse(HapticsPolicy.shouldPlay(reduceMotion: true,
                                                voiceOverRunning: false),
                       "Reduce Motion is a wholesale silence — no per-kind exceptions")
        XCTAssertFalse(HapticsPolicy.shouldPlay(reduceMotion: false,
                                                voiceOverRunning: true),
                       "VoiceOver confirms actions with speech of its own; a competing buzz is noise")
        XCTAssertFalse(HapticsPolicy.shouldPlay(reduceMotion: true,
                                                voiceOverRunning: true))
    }

    /// The vocabulary is deliberately tiny: a press feel, a selection
    /// tick, a success tick. A fourth kind is a vocabulary change that
    /// must be argued for, not slipped in — this test is the speed bump.
    func testVocabularyStaysTheThreeDocumentedKinds() {
        XCTAssertEqual(HapticKind.allCases.count, 3,
                       "tap/selection/success — see `HapticKind`'s doc for what each may say")
    }
}
