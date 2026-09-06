import XCTest
@testable import ElderlyAssistant

/// Step ↔ grounded-control grouping for the step cards.
final class ApplianceStepCardPlannerTests: XCTestCase {

    private func box() -> NormalizedBox {
        NormalizedBox(xMin: 0.1, yMin: 0.1, xMax: 0.3, yMax: 0.3)
    }

    private func control(_ label: String, stepNumber: Int?) -> GroundedControl {
        GroundedControl(label: label, stepNumber: stepNumber,
                        normalizedBox: box(), confidence: 0.9)
    }

    func testOneCardPerStepInOrderWithMatchingControls() {
        let cards = ApplianceStepCardPlanner.build(
            steps: ["first", "second", "third"],
            controls: [control("power", stepNumber: 2),
                       control("start", stepNumber: 1),
                       control("timer", stepNumber: 3)])
        XCTAssertEqual(cards.map(\.number), [1, 2, 3])
        XCTAssertEqual(cards.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(cards[0].controls.map(\.label), ["start"])
        XCTAssertEqual(cards[1].controls.map(\.label), ["power"])
        XCTAssertEqual(cards[2].controls.map(\.label), ["timer"])
    }

    func testMultipleControlsOnOneStepAllAttach() {
        let cards = ApplianceStepCardPlanner.build(
            steps: ["one", "two"],
            controls: [control("a", stepNumber: 2), control("b", stepNumber: 2)])
        XCTAssertEqual(cards[1].controls.map(\.label), ["a", "b"],
                       "order within a step follows payload order")
        XCTAssertTrue(cards[0].controls.isEmpty)
    }

    func testStepsWithoutControlsStayTextOnly() {
        let cards = ApplianceStepCardPlanner.build(
            steps: ["text only", "has a button"],
            controls: [control("start", stepNumber: 2)])
        XCTAssertTrue(cards[0].controls.isEmpty)
        XCTAssertEqual(cards[1].controls.map(\.label), ["start"])
    }

    func testMissingStepNumberFallsBackToPayloadPosition() {
        // Old overlay badged a missing stepNumber as index+1 — keep text
        // and image in sync the same way.
        let cards = ApplianceStepCardPlanner.build(
            steps: ["one", "two", "three"],
            controls: [control("explicit", stepNumber: 1),
                       control("forgot", stepNumber: nil)])
        XCTAssertEqual(cards[1].controls.map(\.label), ["forgot"],
                       "nil at payload index 1 pairs with step 2")
    }

    func testOutOfRangePositiveStepNumberClampsToLastCard() {
        let cards = ApplianceStepCardPlanner.build(
            steps: ["one", "two"],
            controls: [control("wanderer", stepNumber: 5)])
        XCTAssertEqual(cards[1].controls.map(\.label), ["wanderer"])
    }

    func testNonPositiveStepNumbersFallBackToPosition() {
        let cards = ApplianceStepCardPlanner.build(
            steps: ["one", "two"],
            controls: [control("zero", stepNumber: 0),
                       control("negative", stepNumber: -1)])
        XCTAssertEqual(cards[0].controls.map(\.label), ["zero"])
        XCTAssertEqual(cards[1].controls.map(\.label), ["negative"])
    }

    func testNoStepsProducesNoCards() {
        XCTAssertTrue(ApplianceStepCardPlanner.build(
            steps: [], controls: [control("start", stepNumber: 1)]).isEmpty)
    }
}
