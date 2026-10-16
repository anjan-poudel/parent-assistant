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
        // 7 steps total (profile-interview T-102 inserted aboutYou /
        // emergencyContacts / voiceFingerprint after permissions).
        XCTAssertEqual(state.pendingSteps.count, 6)
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
        // [PROFILE-INTERVIEW T-102] The interview steps sit between
        // permissions and the pre-existing steps; About-you is next.
        XCTAssertEqual(state.firstPendingStep, .aboutYou)

        state.markCompleted(.aboutYou)
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

    /// [PROFILE-INTERVIEW T-102] A status map persisted before this
    /// feature (only the original step ids, seeded under the storage key
    /// the shipping format uses) must leave the three interview steps
    /// pending BY CONSTRUCTION — an absent id reads as pending — and
    /// `firstPendingStep` must reflect the updated order immediately.
    @MainActor
    func testLegacyStatusMapLeavesTheNewStepsPending() {
        defaults.set(["language": "completed",
                      "permissions": "completed",
                      "familyContact": "skipped",
                      "models": "completed"],
                     forKey: "onboarding.stepStatuses")
        let state = OnboardingState(defaults: defaults)
        XCTAssertNil(state.status(of: .aboutYou))
        XCTAssertNil(state.status(of: .emergencyContacts))
        XCTAssertNil(state.status(of: .voiceFingerprint))
        XCTAssertEqual(state.pendingSteps,
                       [.aboutYou, .familyContact, .emergencyContacts,
                        .voiceFingerprint])
        XCTAssertEqual(state.firstPendingStep, .aboutYou)
    }
}
