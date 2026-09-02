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

    func testHubCardsAreAtLeast100ptTall() {
        XCTAssertGreaterThanOrEqual(DesignTokens.hubCardMinHeight, 100)
    }

    func testConfirmationChipsAreAtLeast60ptTall() {
        XCTAssertGreaterThanOrEqual(DesignTokens.chipHeight, 60)
    }
}
