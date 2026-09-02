import XCTest
@testable import ElderlyAssistant

final class OnboardingStateTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.onboarding.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    @MainActor
    func testFreshStateHasAllStepsPending() {
        let state = OnboardingState(defaults: defaults)
        XCTAssertFalse(state.hasSeenOnboarding)
        XCTAssertEqual(state.pendingSteps, OnboardingState.Step.allCases)
    }

    @MainActor
    func testCompletedStepLeavesPendingList() {
        let state = OnboardingState(defaults: defaults)
        state.markCompleted(.language)
        XCTAssertFalse(state.pendingSteps.contains(.language))
        XCTAssertEqual(state.pendingSteps.count, 3)
    }

    /// Spec §4.2: EVERY step is skippable — including family contact —
    /// and skipped steps surface on the Home reminder card.
    @MainActor
    func testSkippedStepsRemainPending() {
        let state = OnboardingState(defaults: defaults)
        state.markSkipped(.familyContact)
        XCTAssertEqual(state.status(of: .familyContact), .skipped)
        XCTAssertTrue(state.pendingSteps.contains(.familyContact))
    }

    @MainActor
    func testFinishFlipsHasSeenOnboarding() {
        let state = OnboardingState(defaults: defaults)
        state.finish()
        XCTAssertTrue(state.hasSeenOnboarding)
    }

    @MainActor
    func testFirstPendingStepOrder() {
        let state = OnboardingState(defaults: defaults)
        state.markCompleted(.language)
        state.markCompleted(.permissions)
        XCTAssertEqual(state.firstPendingStep, .familyContact)
    }

    @MainActor
    func testPersistenceAcrossInstances() {
        let state = OnboardingState(defaults: defaults)
        state.markCompleted(.language)
        state.markSkipped(.models)
        state.finish()

        let restored = OnboardingState(defaults: defaults)
        XCTAssertTrue(restored.hasSeenOnboarding)
        XCTAssertEqual(restored.status(of: .language), .completed)
        XCTAssertEqual(restored.status(of: .models), .skipped)
        XCTAssertTrue(restored.pendingSteps.contains(.models))
    }
}
