import XCTest
@testable import ElderlyAssistant

/// Accessibility floors are enforced at the token level (spec §8): any
/// view consuming `DesignTokens` inherits them, and this test makes sure
/// nobody quietly lowers a floor.
final class DesignTokensTests: XCTestCase {

    func testBodyTextFloor() {
        XCTAssertGreaterThanOrEqual(DesignTokens.minBodyPointSize, 18)
    }

    func testCaptionTextFloor() {
        XCTAssertGreaterThanOrEqual(DesignTokens.minCaptionPointSize, 15)
    }

    func testTapTargetFloor() {
        XCTAssertGreaterThanOrEqual(DesignTokens.minTapTargetSize, 44)
    }

    func testTalkButtonIsAtLeast120pt() {
        XCTAssertGreaterThanOrEqual(DesignTokens.talkButtonDiameter, 120)
    }

    /// Redesign 2026-09-03: the 2×2 hub grid became the bottom dock — its
    /// items rely on `minTapTargetSize` directly (see `HomeView.dockItem`),
    /// so this covers what `hubCardMinHeight` used to: the dock itself
    /// stays tall enough to comfortably hold a ≥44pt tap target per item.
    func testDockIsAtLeastTapTargetTall() {
        XCTAssertGreaterThanOrEqual(DesignTokens.dockHeight, DesignTokens.minTapTargetSize)
    }

    func testConfirmationChipsAreAtLeast60ptTall() {
        XCTAssertGreaterThanOrEqual(DesignTokens.chipHeight, 60)
    }

    /// Hold-to-reset duration (TALK-CRASH-FIX, 2026-09-07) stays in the
    /// intended band: comfortably past accidental holds (<0.5s), well
    /// within the "a few seconds" the feature asked for, and never so
    /// long that the progress ring's wait feels like a dead button.
    func testTalkResetHoldIsWithinTheIntendedBand() {
        XCTAssertGreaterThanOrEqual(DesignTokens.talkResetHoldSeconds, 1.0)
        XCTAssertLessThanOrEqual(DesignTokens.talkResetHoldSeconds, 3.5)
    }
}
