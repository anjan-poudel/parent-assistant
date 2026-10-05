import XCTest
@testable import ElderlyAssistant

/// App-start interview routing (profile-interview, T-102 / C13,
/// FR-PI-016). The pure rule (`OnboardingState.coldStartInterviewStep`)
/// is pinned case-by-case against the design's edge table, and the
/// coordinator's composition (`coldStartInterviewRoute()`) is pinned as
/// the rule applied to its OWN step map and its OWN snapshot — the two
/// tests together cover "where does the wizard open on a cold start".
final class ColdStartRoutingTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    /// The coordinator's own `OnboardingState` reads `.standard`; the
    /// wiring tests mutate it, so both keys are snapshotted and restored
    /// around every test — nothing leaks into other suites.
    private var standardStatusesBackup: Any?
    private var standardSeenBackup: Any?

    override func setUp() {
        super.setUp()
        suiteName = "test.coldstart.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        standardStatusesBackup = UserDefaults.standard
            .object(forKey: "onboarding.stepStatuses")
        standardSeenBackup = UserDefaults.standard
            .object(forKey: "onboarding.hasSeen")
    }

    override func tearDown() {
        if let standardStatusesBackup {
            UserDefaults.standard.set(standardStatusesBackup,
                                      forKey: "onboarding.stepStatuses")
        } else {
            UserDefaults.standard.removeObject(forKey: "onboarding.stepStatuses")
        }
        if let standardSeenBackup {
            UserDefaults.standard.set(standardSeenBackup,
                                      forKey: "onboarding.hasSeen")
        } else {
            UserDefaults.standard.removeObject(forKey: "onboarding.hasSeen")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - The pure rule (edge table)

    @MainActor
    func testFreshInstallRoutesToLanguage() {
        let state = OnboardingState(defaults: defaults)
        XCTAssertEqual(state.firstPendingStep, .language)
        let route = OnboardingState.coldStartInterviewStep(
            firstPending: state.firstPendingStep,
            mandatoryFieldsRecorded: false)
        XCTAssertEqual(route, .language,
                       "an untouched fresh install opens where it always did")
    }

    @MainActor
    func testPreFinishRelaunchResumesAtTheFirstPendingStep() {
        let state = OnboardingState(defaults: defaults)
        state.markCompleted(.language)
        state.markCompleted(.permissions)
        state.markCompleted(.aboutYou)
        let route = OnboardingState.coldStartInterviewStep(
            firstPending: state.firstPendingStep,
            mandatoryFieldsRecorded: true)
        XCTAssertEqual(route, .familyContact,
                       "a quit-mid-wizard relaunch resumes where it stopped")
    }

    @MainActor
    func testInterviewCompleteRoutesNowhere() {
        let state = OnboardingState(defaults: defaults)
        OnboardingState.Step.allCases.forEach { state.markCompleted($0) }
        XCTAssertNil(state.firstPendingStep)
        XCTAssertNil(OnboardingState.coldStartInterviewStep(
            firstPending: state.firstPendingStep,
            mandatoryFieldsRecorded: true),
            "a completed interview starts the app normally")
    }

    @MainActor
    func testOptionalStepPendingRoutesWithTheSoftSkipPreserved() {
        let state = OnboardingState(defaults: defaults)
        OnboardingState.Step.allCases.forEach { state.markCompleted($0) }
        state.markSkipped(.voiceFingerprint)
        let route = OnboardingState.coldStartInterviewStep(
            firstPending: state.firstPendingStep,
            mandatoryFieldsRecorded: true)
        XCTAssertEqual(route, .voiceFingerprint)
    }

    @MainActor
    func testMandatoryMissingWithAboutYouCompletedRoutesBackToAboutYou() {
        // E8's repair path: the step map says About-you was done, but the
        // stored record is gone (corrupt payload discarded) — the route
        // sends the user back so the ordinary Next-and-save repairs it.
        let state = OnboardingState(defaults: defaults)
        state.markCompleted(.language)
        state.markCompleted(.permissions)
        state.markCompleted(.aboutYou)
        let route = OnboardingState.coldStartInterviewStep(
            firstPending: state.firstPendingStep,
            mandatoryFieldsRecorded: false)
        XCTAssertEqual(route, .aboutYou)
    }

    @MainActor
    func testMandatoryMissingNeverRoutesPastAboutYou() {
        // first pending is LATER than About-you → About-you is earlier.
        XCTAssertEqual(OnboardingState.coldStartInterviewStep(
            firstPending: .models, mandatoryFieldsRecorded: false),
            .aboutYou)
        // first pending is EARLIER → the earlier step wins.
        XCTAssertEqual(OnboardingState.coldStartInterviewStep(
            firstPending: .language, mandatoryFieldsRecorded: false),
            .language)
        // nothing pending at all, mandatory missing → About-you.
        XCTAssertEqual(OnboardingState.coldStartInterviewStep(
            firstPending: nil, mandatoryFieldsRecorded: false),
            .aboutYou)
    }

    @MainActor
    func testCorruptStatusMapReadsUnknownValuesAsPending() {
        defaults.set(["language": "completed",
                      "permissions": "completed",
                      "aboutYou": "definitely-not-a-real-status"],
                     forKey: "onboarding.stepStatuses")
        let state = OnboardingState(defaults: defaults)
        XCTAssertNil(state.status(of: .aboutYou),
                     "an unknown raw value reads as nothing recorded")
        XCTAssertEqual(state.firstPendingStep, .aboutYou)
        XCTAssertEqual(OnboardingState.coldStartInterviewStep(
            firstPending: state.firstPendingStep,
            mandatoryFieldsRecorded: true),
            .aboutYou,
            "the wizard opens at the unreadable step and stays skippable")
    }

    @MainActor
    func testWrongTypedStatusMapReadsAsNothingRecorded() {
        defaults.set(["language": 7, "models": ["nested": true]],
                     forKey: "onboarding.stepStatuses")
        let state = OnboardingState(defaults: defaults)
        XCTAssertEqual(state.pendingSteps, OnboardingState.Step.allCases,
                       "a wrong-typed map degrades to all-pending, no crash")
    }

    // MARK: - The predicate trims like the About-you Next gate

    @MainActor
    func testMandatoryPredicateTrimsLikeTheAboutYouNextGate() {
        // The wizard's Next gate and the router share one predicate —
        // whitespace-only values must read as missing in BOTH.
        XCTAssertFalse(AboutYouDraft.mandatoryFieldsRecorded(
            name: "   ", addressAs: "Mum"))
        XCTAssertFalse(AboutYouDraft.mandatoryFieldsRecorded(
            name: "Maya", addressAs: " \n "))
        XCTAssertTrue(AboutYouDraft.mandatoryFieldsRecorded(
            name: "  Maya ", addressAs: " Mum "))
        XCTAssertFalse(AboutYouDraft(name: " ", addressAs: "Mum").isComplete)
        XCTAssertTrue(AboutYouDraft(name: "Maya", addressAs: "Mum").isComplete)
    }

    // MARK: - The coordinator composition (wiring, not the rule)

    /// In-memory stand-in for the encrypted channel (same double the
    /// coordinator seam tests use).
    private final class InMemoryProfilePayloadStorage: ProfilePayloadStorage {
        var payloads: [String: Data] = [:]
        private let encoder = JSONEncoder()

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard let data = try? encoder.encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            payloads[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            .failure(.encryptedReadFailed)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            payloads[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? { payloads[key] }
        func hasPayload(key: String) -> Bool? { payloads[key] != nil }
    }

    @MainActor
    func testRouteComposesTheRuleWithTheCoordinatorsOwnInputs() {
        let storage = InMemoryProfilePayloadStorage()
        let coordinator = AppCoordinator(profileStorage: storage)
        XCTAssertEqual(
            coordinator.coldStartInterviewRoute(),
            OnboardingState.coldStartInterviewStep(
                firstPending: coordinator.onboardingState.firstPendingStep,
                mandatoryFieldsRecorded: false),
            "an empty store means mandatory fields are not recorded")
    }

    @MainActor
    func testRouteWithACompleteRecordTracksTheSnapshotAndStepMap() throws {
        let storage = InMemoryProfilePayloadStorage()
        storage.payloads[UserProfileStore.storageKey] = try JSONEncoder().encode(
            UserProfile(name: "Maya Gurung",
                        addressAs: "Mum",
                        dateOfBirth: nil,
                        emergencyDoctor: nil,
                        localHospital: nil))
        let coordinator = AppCoordinator(profileStorage: storage)
        XCTAssertEqual(
            coordinator.coldStartInterviewRoute(),
            OnboardingState.coldStartInterviewStep(
                firstPending: coordinator.onboardingState.firstPendingStep,
                mandatoryFieldsRecorded: true),
            "a loaded record with name + address-as counts as recorded")
    }

    @MainActor
    func testUnreadableRecordCountsAsMandatoryMissing() {
        let storage = InMemoryProfilePayloadStorage()
        storage.payloads[UserProfileStore.storageKey] = Data("not json".utf8)
        let coordinator = AppCoordinator(profileStorage: storage)

        // Pin the decision deterministically: no pending steps, but the
        // record is unreadable — the route must still be About-you.
        OnboardingState.Step.allCases.forEach {
            coordinator.onboardingState.markCompleted($0)
        }
        XCTAssertNil(coordinator.onboardingState.firstPendingStep)
        XCTAssertEqual(coordinator.coldStartInterviewRoute(), .aboutYou,
                       "an unreadable record is a mandatory-missing route, "
                       + "never a crash and never 'nothing to do'")
    }
}
