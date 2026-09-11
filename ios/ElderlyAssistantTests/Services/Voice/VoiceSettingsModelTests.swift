import XCTest
@testable import ElderlyAssistant

/// Unit tests for the Voice personalization settings model
/// ([VOICE-SETTINGS]): toggle persistence round-trips (noise filter via
/// the AppCoordinator seam, accent biasing via UserDefaults), the
/// status-resolver → presentation mapping, and the enrollment flow state
/// machine. Pure logic only — fakes stand in for the audio recorder, the
/// pipeline suspender, and the biometric service; no real audio, no UI.
@MainActor
final class VoiceSettingsModelTests: XCTestCase {

    // MARK: - Fakes

    /// In-memory stand-in for `AppCoordinator.noiseFilterEnabled` (the
    /// coordinator persists UserDefaults AND hot-swaps the pipeline; the
    /// model only forwards).
    final class FakeNoiseFilterController: NoiseFilterPreferenceControlling {
        var noiseFilterEnabled: Bool
        init(initial: Bool) { noiseFilterEnabled = initial }
    }

    /// In-memory stand-in for `AppCoordinator.warmStartEnabled` (the
    /// coordinator persists UserDefaults "warmStartEngines" and is the
    /// value the boot's warm phase reads; the model only forwards).
    final class FakeWarmStartController: WarmStartPreferenceControlling {
        var warmStartEnabled: Bool
        init(initial: Bool) { warmStartEnabled = initial }
    }

    final class FakeEnrollmentService: VoiceEnrollmentServicing {
        var isEnabled: Bool = true
        var currentEmbedderID: String = "fake.v1"
        var loadResult: Result<EnrolledVoiceProfile?, StorageError> = .success(nil)
        var clearResult: Result<Void, StorageError> = .success(())
        /// Queue of enroll outcomes (last repeats on exhaustion).
        var enrollResults: [Result<EnrolledVoiceProfile, EnrollmentError>] = []

        private(set) var clearCalls = 0
        private(set) var enrollCalls: [[[Int16]]] = []

        static func profile(utteranceCount: Int = 3,
                            embedderID: String = "fake.v1") -> EnrolledVoiceProfile {
            EnrolledVoiceProfile(schemaVersion: VoiceBiometricStore.currentSchemaVersion,
                                 embedderID: embedderID,
                                 embedding: [0.6, 0.8, 0.0],
                                 createdAt: Date(),
                                 utteranceCount: utteranceCount,
                                 perUtteranceSpeechSeconds: Array(repeating: 1.5,
                                                                   count: utteranceCount))
        }

        func loadProfile() -> Result<EnrolledVoiceProfile?, StorageError> {
            loadResult
        }

        func clearProfile() -> Result<Void, StorageError> {
            clearCalls += 1
            if case .success = clearResult {
                loadResult = .success(nil)
            }
            return clearResult
        }

        func enroll(samples: [[Int16]], sampleRate: Double) async
            -> Result<EnrolledVoiceProfile, EnrollmentError> {
            enrollCalls.append(samples)
            guard !enrollResults.isEmpty else {
                return .failure(.embeddingFailed(.processingFailed))
            }
            let result = enrollResults[0]
            if enrollResults.count > 1 { enrollResults.removeFirst() }
            if case .success(let profile) = result {
                loadResult = .success(profile)
            }
            return result
        }
    }

    final class FakeRecorder: VoiceSampleRecorder {
        var pcmToReturn: [Int16] = [1, 2, 3, 4]
        var startError: VoiceSampleCaptureError?
        private(set) var startCalls = 0
        private(set) var stopCalls = 0

        func startCapture() async throws {
            startCalls += 1
            if let startError { throw startError }
        }

        func stopCapture() -> [Int16] {
            stopCalls += 1
            return pcmToReturn
        }
    }

    final class FakeSuspender: VoicePipelineSuspending {
        var allowSuspension = true
        private(set) var suspendCalls = 0
        private(set) var resumeCalls = 0

        func suspendForSampleCapture() -> Bool {
            suspendCalls += 1
            return allowSuspension
        }

        func resumeAfterSampleCapture() {
            resumeCalls += 1
        }
    }

    // MARK: - Hermetic defaults (accent toggle round-trips)

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.voicesettings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Noise filter toggle (controller seam)

    func testNoiseFilterDefaultsToControllerValue() {
        let controller = FakeNoiseFilterController(initial: false)
        let model = VoiceSettingsModel(noiseFilterController: controller,
                                       warmStartController: FakeWarmStartController(initial: true),
                                       defaults: defaults)
        XCTAssertFalse(model.noiseFilterEnabled,
                       "noise filter ships OFF — the A/B default is the legacy path")
    }

    func testNoiseFilterToggleRoundTripsThroughController() {
        let controller = FakeNoiseFilterController(initial: false)
        let model = VoiceSettingsModel(noiseFilterController: controller,
                                       warmStartController: FakeWarmStartController(initial: true),
                                       defaults: defaults)
        model.noiseFilterEnabled = true
        XCTAssertTrue(controller.noiseFilterEnabled,
                      "the model forwards the flip to the coordinator seam")
        // A fresh model over the same controller reads the flipped state
        // back — persistence is the controller's (the coordinator's), and
        // the model must never shadow it.
        let reloaded = VoiceSettingsModel(noiseFilterController: controller,
                                          warmStartController: FakeWarmStartController(initial: true),
                                          defaults: defaults)
        XCTAssertTrue(reloaded.noiseFilterEnabled,
                      "a new model must read the persisted state, not a default")
    }

    func testNoiseFilterToggleDoesNotTouchAccentDefaults() {
        let controller = FakeNoiseFilterController(initial: false)
        let model = VoiceSettingsModel(noiseFilterController: controller,
                                       warmStartController: FakeWarmStartController(initial: true),
                                       defaults: defaults)
        model.noiseFilterEnabled = true
        XCTAssertNil(defaults.object(forKey: DialectBiasSettings.defaultsKey),
                     "the noise toggle must not write the accent key")
    }

    // MARK: - Warm-start toggle (controller seam)

    func testWarmStartDefaultsToControllerValue() {
        let model = VoiceSettingsModel(noiseFilterController: FakeNoiseFilterController(initial: false),
                                       warmStartController: FakeWarmStartController(initial: true),
                                       defaults: defaults)
        XCTAssertTrue(model.warmStartEnabled,
                      "warm start ships ON — the first conversation must be fast out of the box")
    }

    func testWarmStartToggleRoundTripsThroughController() {
        let controller = FakeWarmStartController(initial: true)
        let model = VoiceSettingsModel(noiseFilterController: FakeNoiseFilterController(initial: false),
                                       warmStartController: controller,
                                       defaults: defaults)
        model.warmStartEnabled = false
        XCTAssertFalse(controller.warmStartEnabled,
                       "the model forwards the flip to the coordinator seam")

        let reloaded = VoiceSettingsModel(noiseFilterController: FakeNoiseFilterController(initial: false),
                                          warmStartController: controller,
                                          defaults: defaults)
        XCTAssertFalse(reloaded.warmStartEnabled,
                       "a new model must read the controller's state, not a default")
    }

    func testWarmStartToggleDoesNotWriteDefaultsDirectly() {
        let controller = FakeWarmStartController(initial: true)
        let model = VoiceSettingsModel(noiseFilterController: FakeNoiseFilterController(initial: false),
                                       warmStartController: controller,
                                       defaults: defaults)
        model.warmStartEnabled = false
        XCTAssertNil(defaults.object(forKey: "warmStartEngines"),
                     "the model must never shadow the coordinator's persistence — one writer")
    }

    func testWarmStartUnchangedValueDoesNotForward() {
        let controller = FakeWarmStartController(initial: true)
        let model = VoiceSettingsModel(noiseFilterController: FakeNoiseFilterController(initial: false),
                                       warmStartController: controller,
                                       defaults: defaults)
        controller.warmStartEnabled = false
        // Reassign the SAME value the model already holds — no forward.
        model.warmStartEnabled = true
        XCTAssertFalse(controller.warmStartEnabled,
                       "an unchanged toggle must not clobber the controller")
    }

    // MARK: - Accent bias toggle (UserDefaults round-trip)

    func testAccentBiasDefaultsOnWhenUnset() {
        let model = VoiceSettingsModel(noiseFilterController: FakeNoiseFilterController(initial: false),
                                       warmStartController: FakeWarmStartController(initial: true),
                                       defaults: defaults)
        XCTAssertTrue(model.accentBiasEnabled,
                      "accent biasing ships ON — the toggle is an escape hatch, not an opt-in gate")
    }

    func testAccentBiasToggleRoundTripsAcrossModelInstances() {
        let first = VoiceSettingsModel(noiseFilterController: FakeNoiseFilterController(initial: false),
                                       warmStartController: FakeWarmStartController(initial: true),
                                       defaults: defaults)
        first.accentBiasEnabled = false
        XCTAssertFalse(DialectBiasSettings.isEnabled(defaults: defaults))

        let second = VoiceSettingsModel(noiseFilterController: FakeNoiseFilterController(initial: false),
                                        warmStartController: FakeWarmStartController(initial: true),
                                        defaults: defaults)
        XCTAssertFalse(second.accentBiasEnabled,
                       "a new model must read the persisted OFF state")

        second.accentBiasEnabled = true
        let third = VoiceSettingsModel(noiseFilterController: FakeNoiseFilterController(initial: false),
                                       warmStartController: FakeWarmStartController(initial: true),
                                       defaults: defaults)
        XCTAssertTrue(third.accentBiasEnabled,
                      "a new model must read the persisted ON state")
    }

    // MARK: - Status resolver → presentation mapping

    private func makeSession(service: FakeEnrollmentService,
                             suspender: FakeSuspender? = nil) -> VoiceEnrollmentSession {
        VoiceEnrollmentSession(service: service,
                               recorder: FakeRecorder(),
                               pipelineSuspender: suspender)
    }

    func testStatusPresentationNotEnrolled() {
        let service = FakeEnrollmentService()
        let session = makeSession(service: service)
        XCTAssertEqual(session.biometricStatus, .notEnrolled)
        XCTAssertEqual(session.biometricPresentation, .notEnrolled)
    }

    func testStatusPresentationEnrolledCarriesUtteranceCount() {
        let service = FakeEnrollmentService()
        service.loadResult = .success(FakeEnrollmentService.profile(utteranceCount: 3))
        let session = makeSession(service: service)
        XCTAssertEqual(session.biometricPresentation,
                       .enrolled(utteranceCount: 3))
    }

    func testStatusPresentationNeedsReenrollmentOnEmbedderMismatch() {
        let service = FakeEnrollmentService()
        service.loadResult = .success(FakeEnrollmentService.profile(embedderID: "older.v1"))
        let session = makeSession(service: service)
        XCTAssertEqual(session.biometricStatus,
                       .needsReenrollment(templateEmbedderID: "older.v1"))
        XCTAssertEqual(session.biometricPresentation, .needsReenrollment)
    }

    func testStatusPresentationUnreadableOnLoadFailure() {
        let service = FakeEnrollmentService()
        service.loadResult = .failure(.encryptedReadFailed)
        let session = makeSession(service: service)
        XCTAssertEqual(session.biometricStatus, .templateUnreadable)
        XCTAssertEqual(session.biometricPresentation, .templateUnreadable)
    }

    func testStatusPresentationDisabledBeatsStoredProfile() {
        let service = FakeEnrollmentService()
        service.isEnabled = false
        service.loadResult = .success(FakeEnrollmentService.profile())
        let session = makeSession(service: service)
        XCTAssertEqual(session.biometricStatus, .disabled)
        XCTAssertEqual(session.biometricPresentation, .disabled,
                       "disabled must win — never claim a usable voice login")
    }

    // MARK: - Enrollment flow state machine

    func testEnrollmentHappyPathRequiresThreeSamplesThenSaves() async {
        let service = FakeEnrollmentService()
        service.enrollResults = [.success(FakeEnrollmentService.profile())]
        let recorder = FakeRecorder()
        let suspender = FakeSuspender()
        let session = VoiceEnrollmentSession(service: service,
                                             recorder: recorder,
                                             pipelineSuspender: suspender)

        await session.startRecording()
        XCTAssertEqual(session.phase, .recording(sampleIndex: 0))
        await session.stopRecording()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.collectedCount, 1)

        await session.startRecording()
        XCTAssertEqual(session.phase, .recording(sampleIndex: 1))
        await session.stopRecording()
        XCTAssertEqual(session.collectedCount, 2)

        await session.startRecording()
        XCTAssertEqual(session.phase, .recording(sampleIndex: 2))
        await session.stopRecording()

        guard case .ready(let profile) = session.phase else {
            XCTFail("expected .ready, got \(session.phase)")
            return
        }
        XCTAssertEqual(profile.utteranceCount, 3)
        XCTAssertEqual(service.enrollCalls.count, 1)
        XCTAssertEqual(service.enrollCalls[0].count, 3)
        XCTAssertEqual(session.collectedCount, 0, "banked samples clear after success")
        XCTAssertEqual(suspender.suspendCalls, 3)
        XCTAssertEqual(suspender.resumeCalls, 3,
                       "every sample teardown must resume the pipeline")
        XCTAssertEqual(session.biometricPresentation, .enrolled(utteranceCount: 3))
    }

    func testEnrollmentQualityFailureDropsOnlyTheRefusedSample() async {
        let service = FakeEnrollmentService()
        service.enrollResults = [
            .failure(.qualityGateFailed(sampleIndex: 1, issue: .speechTooShort)),
            .success(FakeEnrollmentService.profile()),
        ]
        let recorder = FakeRecorder()
        let session = VoiceEnrollmentSession(service: service,
                                             recorder: recorder,
                                             pipelineSuspender: nil)

        for _ in 0..<3 {
            await session.startRecording()
            await session.stopRecording()
        }
        XCTAssertEqual(session.phase,
                       .failed(.sampleQualityFailed(sampleIndex: 1,
                                                    issue: .speechTooShort)))
        XCTAssertEqual(session.collectedCount, 2,
                       "the refused sample is dropped, the good two are kept")

        // Re-record one replacement sample — enrollment retries with the
        // two banked samples plus the new one.
        recorder.pcmToReturn = [9, 9, 9]
        await session.startRecording()
        XCTAssertEqual(session.phase, .recording(sampleIndex: 2))
        await session.stopRecording()

        XCTAssertEqual(service.enrollCalls.count, 2)
        XCTAssertEqual(service.enrollCalls[1].count, 3)
        XCTAssertEqual(service.enrollCalls[1][2], [9, 9, 9],
                       "the replacement lands at the dropped sample's slot")
        guard case .ready = session.phase else {
            XCTFail("expected .ready after re-recording, got \(session.phase)")
            return
        }
    }

    func testEnrollmentInconsistentSampleSurfacesHonestFailure() async {
        let service = FakeEnrollmentService()
        service.enrollResults = [
            .failure(.inconsistentSample(sampleIndex: 0)),
            .success(FakeEnrollmentService.profile()),
        ]
        let session = VoiceEnrollmentSession(service: service,
                                             recorder: FakeRecorder(),
                                             pipelineSuspender: nil)
        for _ in 0..<3 {
            await session.startRecording()
            await session.stopRecording()
        }
        XCTAssertEqual(session.phase, .failed(.sampleInconsistent(sampleIndex: 0)))
        XCTAssertEqual(session.collectedCount, 2)
    }

    func testEnrollmentSaveFailureLeavesSamplesBanked() async {
        let service = FakeEnrollmentService()
        service.enrollResults = [.failure(.persistenceFailed)]
        let session = VoiceEnrollmentSession(service: service,
                                             recorder: FakeRecorder(),
                                             pipelineSuspender: nil)
        for _ in 0..<3 {
            await session.startRecording()
            await session.stopRecording()
        }
        XCTAssertEqual(session.phase, .failed(.saveFailed))
        XCTAssertEqual(session.collectedCount, 3,
                       "a save failure must not silently discard the samples")
        XCTAssertEqual(session.biometricPresentation, .notEnrolled,
                       "nothing is claimed that was not persisted")
    }

    func testEnrollmentDisabledServiceFailsHonestly() async {
        let service = FakeEnrollmentService()
        service.isEnabled = false
        service.enrollResults = [.failure(.disabled)]
        let session = VoiceEnrollmentSession(service: service,
                                             recorder: FakeRecorder(),
                                             pipelineSuspender: nil)
        for _ in 0..<3 {
            await session.startRecording()
            await session.stopRecording()
        }
        XCTAssertEqual(session.phase, .failed(.serviceDisabled))
    }

    func testEnrollmentRefusesWhenAssistantBusy() async {
        let suspender = FakeSuspender()
        suspender.allowSuspension = false
        let recorder = FakeRecorder()
        let session = VoiceEnrollmentSession(service: FakeEnrollmentService(),
                                             recorder: recorder,
                                             pipelineSuspender: suspender)
        await session.startRecording()
        XCTAssertEqual(session.phase, .failed(.assistantBusy))
        XCTAssertEqual(recorder.startCalls, 0,
                       "the mic must never start while the assistant is busy")
        XCTAssertEqual(suspender.resumeCalls, 0,
                       "nothing was suspended, nothing to resume")
    }

    func testEnrollmentStartFailureSurfacesAndResumesPipeline() async {
        let suspender = FakeSuspender()
        let recorder = FakeRecorder()
        recorder.startError = .noAudioInput
        let session = VoiceEnrollmentSession(service: FakeEnrollmentService(),
                                             recorder: recorder,
                                             pipelineSuspender: suspender)
        await session.startRecording()
        XCTAssertEqual(session.phase, .failed(.noAudioInput))
        XCTAssertEqual(suspender.resumeCalls, 1,
                       "a failed start must still resume a suspended pipeline")
    }

    func testStartRecordingWhileRecordingIsIgnored() async {
        let recorder = FakeRecorder()
        let session = VoiceEnrollmentSession(service: FakeEnrollmentService(),
                                             recorder: recorder,
                                             pipelineSuspender: nil)
        await session.startRecording()
        await session.startRecording() // second press must be a no-op
        XCTAssertEqual(session.phase, .recording(sampleIndex: 0))
        XCTAssertEqual(recorder.startCalls, 1)
    }

    func testDismissFailureReturnsToIdle() async {
        let service = FakeEnrollmentService()
        service.enrollResults = [.failure(.persistenceFailed)]
        let session = VoiceEnrollmentSession(service: service,
                                             recorder: FakeRecorder(),
                                             pipelineSuspender: nil)
        for _ in 0..<3 {
            await session.startRecording()
            await session.stopRecording()
        }
        session.dismissFailure()
        XCTAssertEqual(session.phase, .idle)
    }

    func testClearProfileIsIdempotentAndRefreshesStatus() async {
        let service = FakeEnrollmentService()
        service.loadResult = .success(FakeEnrollmentService.profile())
        let session = makeSession(service: service)
        XCTAssertEqual(session.biometricPresentation, .enrolled(utteranceCount: 3))

        session.clearProfile()
        XCTAssertEqual(service.clearCalls, 1)
        XCTAssertEqual(session.biometricStatus, .notEnrolled)
        XCTAssertEqual(session.biometricPresentation, .notEnrolled)

        session.clearProfile() // safe to press twice (service contract)
        XCTAssertEqual(service.clearCalls, 2)
        XCTAssertEqual(session.biometricStatus, .notEnrolled)
    }
}
