import XCTest
@testable import ElderlyAssistant

/// The service layer end-to-end (Services/Voice/SpeakerBiometricService.swift):
/// enroll → persisted template → verify accept/reject, with the REAL MFCC
/// embedder over synthetic fixtures (no recordings committed). Error paths
/// (quality gates, consistency, embedder mismatch, persistence, disabled)
/// use the stub embedder and the in-memory storage double.
final class SpeakerBiometricServiceTests: XCTestCase {

    private var storage: VoiceBiometricInMemoryStorage!
    private var recorder: SpeakerBiometricEventRecorder!
    private var embedder: MFCCSpeakerEmbedder!

    override func setUp() {
        super.setUp()
        storage = VoiceBiometricInMemoryStorage()
        recorder = SpeakerBiometricEventRecorder()
        embedder = MFCCSpeakerEmbedder()
    }

    override func tearDown() {
        storage = nil
        recorder = nil
        embedder = nil
        super.tearDown()
    }

    private func service(policy: VoiceVerificationPolicy = VoiceVerificationPolicy())
        -> SpeakerBiometricService {
        SpeakerBiometricService(embedder: embedder,
                                store: VoiceBiometricStore(storage: storage),
                                policy: policy,
                                observabilityBus: recorder)
    }

    // MARK: - Enrollment happy path

    func testEnrollThreeSamplesPersistsCentroidTemplate() async {
        let service = service()
        let result = await service.enroll(samples: [
            FixtureSpeakers.aUtterance(1),
            FixtureSpeakers.aUtterance(2),
            FixtureSpeakers.aUtterance(3)
        ])
        guard case .success(let profile) = result else {
            return XCTFail("expected enrollment success, got \(result)")
        }
        XCTAssertEqual(profile.utteranceCount, 3)
        XCTAssertEqual(profile.embedding.count, 72)
        XCTAssertEqual(profile.embedderID, "mfcc.stats.v1")
        XCTAssertEqual(profile.perUtteranceSpeechSeconds.count, 3)

        // The template is the centroid of the three sample embeddings.
        let sampleEmbeddings = [
            try! embedder.embed(collectedPCM: FixtureSpeakers.aUtterance(1)).get(),
            try! embedder.embed(collectedPCM: FixtureSpeakers.aUtterance(2)).get(),
            try! embedder.embed(collectedPCM: FixtureSpeakers.aUtterance(3)).get()
        ]
        let centroid = SpeakerEmbedding.centroid(of: sampleEmbeddings)!
        XCTAssertEqual(profile.embedding, centroid.values,
                       "the persisted template must be the utterance centroid")

        // Persisted under the encrypted-storage seam.
        XCTAssertEqual(storage.writtenKeys,
                       [VoiceBiometricStore.profileKey, VoiceBiometricStore.markerKey])
    }

    func testEnrollRefusesTooFewSamples() async {
        let service = service()
        let result = await service.enroll(samples: [
            FixtureSpeakers.aUtterance(1),
            FixtureSpeakers.aUtterance(2)
        ])
        XCTAssertEqual(result, .failure(.tooFewSamples(provided: 2)))
        XCTAssertTrue(storage.writtenKeys.isEmpty, "nothing may be persisted")
    }

    // MARK: - Verification happy path

    func testVerifyAcceptsTheEnrolledSpeaker() async throws {
        let service = service()
        _ = try await service.enroll(samples: [
            FixtureSpeakers.aUtterance(1),
            FixtureSpeakers.aUtterance(2),
            FixtureSpeakers.aUtterance(3)
        ]).get()

        let result = await service.verify(pcm: FixtureSpeakers.aUtterance(9))
        guard case .success(let decision) = result else {
            return XCTFail("expected a decision, got \(result)")
        }
        XCTAssertEqual(decision.outcome, .accept,
                       "a fresh utterance from the enrolled speaker must accept")
        XCTAssertGreaterThanOrEqual(decision.score!, VoiceVerificationPolicy().acceptThreshold)
    }

    func testVerifyRejectsADifferentSpeaker() async throws {
        let service = service()
        _ = try await service.enroll(samples: [
            FixtureSpeakers.aUtterance(1),
            FixtureSpeakers.aUtterance(2),
            FixtureSpeakers.aUtterance(3)
        ]).get()

        let result = await service.verify(pcm: FixtureSpeakers.bUtterance(1))
        guard case .success(let decision) = result else {
            return XCTFail("expected a decision, got \(result)")
        }
        XCTAssertEqual(decision.outcome, .reject(.belowThreshold),
                       "the synthetic other speaker must fall below the threshold")
        XCTAssertLessThan(decision.score!, VoiceVerificationPolicy().acceptThreshold)
    }

    func testVerifyWithoutEnrollmentReturnsNotEnrolled() async {
        let result = await service().verify(pcm: FixtureSpeakers.aUtterance(1))
        XCTAssertEqual(result, .failure(.notEnrolled))
    }

    // MARK: - Quality gates (doc §7.4)

    func testEnrollRejectsShortSampleWithIndexAndReason() async {
        let service = service()
        let result = await service.enroll(samples: [
            FixtureSpeakers.aUtterance(1),
            FixtureSpeakers.aUtterance(2),
            FixtureSpeakers.aUtterance(3, seconds: 0.4) // too short
        ])
        XCTAssertEqual(result, .failure(.qualityGateFailed(sampleIndex: 2,
                                                           issue: .speechTooShort)))
        XCTAssertTrue(storage.writtenKeys.isEmpty,
                      "a failed enrollment must persist nothing")
    }

    func testEnrollRejectsNoisySample() async {
        let service = service()
        // Loud constant noise: quality-gated before any embedding.
        let result = await service.enroll(samples: [
            FixtureSpeakers.aUtterance(1),
            SyntheticAudio.whiteNoise(seconds: 3.0, amplitude: 3000),
            FixtureSpeakers.aUtterance(3)
        ])
        guard case .failure(.qualityGateFailed(sampleIndex: 1, issue: let issue)) = result else {
            return XCTFail("expected qualityGateFailed, got \(result)")
        }
        XCTAssertNotEqual(issue, .none)
    }

    func testVerifyRefusesNoisyUtteranceAsADecisionNotAnError() async throws {
        let service = service()
        _ = try await service.enroll(samples: [
            FixtureSpeakers.aUtterance(1),
            FixtureSpeakers.aUtterance(2),
            FixtureSpeakers.aUtterance(3)
        ]).get()
        let result = await service.verify(pcm: SyntheticAudio.whiteNoise(seconds: 3.0, amplitude: 3000))
        guard case .success(let decision) = result else {
            return XCTFail("quality refusals are decisions (retryable), not errors: \(result)")
        }
        if case .accept = decision.outcome {
            XCTFail("noise must never accept")
        }
        XCTAssertNil(decision.score, "refused audio must carry no score")
    }

    // MARK: - Consistency gate (doc §7.4: same-speaker by a wide margin)

    func testEnrollRejectsInconsistentSampleAndPreservesOldTemplate() async throws {
        let service = service()
        _ = try await service.enroll(samples: [
            FixtureSpeakers.aUtterance(1),
            FixtureSpeakers.aUtterance(2),
            FixtureSpeakers.aUtterance(3)
        ]).get()

        // Re-enrollment attempt where the third "take" is a different
        // speaker: the session fails and the OLD template survives
        // untouched (doc §7.1: never delete before the new one passes).
        let result = await service.enroll(samples: [
            FixtureSpeakers.aUtterance(4),
            FixtureSpeakers.aUtterance(5),
            FixtureSpeakers.bUtterance(2)
        ])
        guard case .failure(.inconsistentSample(sampleIndex: 2)) = result else {
            return XCTFail("expected inconsistentSample(2), got \(result)")
        }
        guard case .success(.some(let survived)) = service.loadProfile() else {
            return XCTFail("the old template must survive a failed re-enrollment")
        }
        XCTAssertEqual(survived.utteranceCount, 3)
    }

    // MARK: - Embedder identity

    func testVerifyRefusesTemplateFromAnotherEmbedder() async {
        // Plant a template that decodes fine but was produced by a
        // different embedder generation (the ECAPA migration scenario,
        // doc §10: re-enrollment required, never silent mixing).
        let other = EnrolledVoiceProfile(
            schemaVersion: VoiceBiometricStore.currentSchemaVersion,
            embedderID: "ecapa.coreml.v1",
            embedding: [Float](repeating: 0.1, count: 78),
            createdAt: Date(), utteranceCount: 3,
            perUtteranceSpeechSeconds: [2, 2, 2])
        _ = VoiceBiometricStore(storage: storage).save(other)

        let result = await service().verify(pcm: FixtureSpeakers.aUtterance(1))
        XCTAssertEqual(result,
                       .failure(.embedderMismatch(templateEmbedder: "ecapa.coreml.v1",
                                                  currentEmbedder: "mfcc.stats.v1")))
    }

    // MARK: - Disabled embedder

    func testDisabledEmbedderRefusesEverything() async {
        let service = SpeakerBiometricService(
            embedder: NullSpeakerEmbedder(),
            store: VoiceBiometricStore(storage: storage),
            observabilityBus: recorder)
        XCTAssertFalse(service.isEnabled)

        let enroll = await service.enroll(samples: [
            FixtureSpeakers.aUtterance(1),
            FixtureSpeakers.aUtterance(2),
            FixtureSpeakers.aUtterance(3)
        ])
        XCTAssertEqual(enroll, .failure(.disabled))

        let verify = await service.verify(pcm: FixtureSpeakers.aUtterance(1))
        XCTAssertEqual(verify, .failure(.disabled))
    }

    // MARK: - Persistence failure

    func testEnrollFailsWhenPersistenceFails() async {
        storage.failWrites = true
        let service = service()
        let result = await service.enroll(samples: [
            FixtureSpeakers.aUtterance(1),
            FixtureSpeakers.aUtterance(2),
            FixtureSpeakers.aUtterance(3)
        ])
        XCTAssertEqual(result, .failure(.persistenceFailed))
    }

    func testVerifyReportsUnreadableTemplateAsError() async throws {
        // Enroll for real, then corrupt the profile payload but keep the
        // marker — the store must surface it as unreadable, and the
        // service must turn that into a distinct error (re-enrollment
        // signal), never a silent notEnrolled or a false accept.
        let service = service()
        _ = try await service.enroll(samples: [
            FixtureSpeakers.aUtterance(1),
            FixtureSpeakers.aUtterance(2),
            FixtureSpeakers.aUtterance(3)
        ]).get()
        storage.plantRaw(key: VoiceBiometricStore.profileKey,
                         data: Data("corrupted".utf8))

        let result = await service.verify(pcm: FixtureSpeakers.aUtterance(1))
        XCTAssertEqual(result, .failure(.templateUnreadable))
    }

    // MARK: - Relaxed retry (doc §9.4 step 3)

    func testRelaxedFlagReachesTheVerifier() async throws {
        // Stub-based: pin an embedding whose score sits in the relaxed
        // band, prove the flag selects the relaxed threshold.
        let stub = StubSpeakerEmbedder()
        // Embeddings: 3 enrollment samples → template direction (1,0,0);
        // verify candidate → cos 0.53 direction (relaxed band only).
        // The stub repeats the last result, so both verify calls get the
        // 0.53 candidate.
        stub.embedResults = [
            .success(StubSpeakerEmbedder.embedding(1, 0, 0)),
            .success(StubSpeakerEmbedder.embedding(1, 0, 0)),
            .success(StubSpeakerEmbedder.embedding(1, 0, 0)),
            .success(SpeakerEmbedding(
                values: [0.53, (1 - 0.53 * 0.53).squareRoot(), 0],
                embedderID: "stub.v1")!.l2Normalized())
        ]
        let service = SpeakerBiometricService(
            embedder: stub,
            store: VoiceBiometricStore(storage: storage),
            policy: VoiceVerificationPolicy(acceptThreshold: 0.55, relaxedThreshold: 0.50),
            observabilityBus: recorder)

        // Note: enrollment samples go through the QUALITY gate first —
        // stub PCM is silence, so seed stub-friendly PCM: real fixtures
        // embedded by the stub deterministically.
        let samples = [FixtureSpeakers.aUtterance(1),
                       FixtureSpeakers.aUtterance(2),
                       FixtureSpeakers.aUtterance(3)]
        guard case .success = await service.enroll(samples: samples) else {
            return XCTFail("stub enrollment must succeed (quality from real fixtures)")
        }

        let strict = try await service.verify(pcm: FixtureSpeakers.aUtterance(4)).get()
        XCTAssertEqual(strict.outcome, .reject(.belowThreshold))
        let relaxed = try await service.verify(pcm: FixtureSpeakers.aUtterance(4), relaxed: true).get()
        XCTAssertEqual(relaxed.outcome, .accept,
                       "relaxed=true must apply the retry threshold (doc §9.4 step 3)")
    }

    // MARK: - Privacy contract (doc §10: outcome-only observability)

    func testObservabilityEventsAreOutcomeOnly() async throws {
        let service = service()
        _ = try await service.enroll(samples: [
            FixtureSpeakers.aUtterance(1),
            FixtureSpeakers.aUtterance(2),
            FixtureSpeakers.aUtterance(3)
        ]).get()
        _ = try await service.verify(pcm: FixtureSpeakers.aUtterance(1)).get()
        _ = await service.verify(pcm: FixtureSpeakers.bUtterance(1))
        _ = service.clearProfile()

        let types = recorder.events.map(\.eventType)
        XCTAssertTrue(types.contains("voice_enroll_success"))
        XCTAssertTrue(types.contains("voice_verify_success"))
        XCTAssertTrue(types.contains("voice_verify_failure"))
        XCTAssertTrue(types.contains("voice_profile_cleared"))

        for event in recorder.events {
            let blob = (event.metadata.values.joined(separator: " ")
                        + event.outcome + (event.errorCode ?? ""))
            XCTAssertFalse(blob.lowercased().contains("score"),
                           "verification scores must never leave the process (doc §10)")
            XCTAssertFalse(blob.lowercased().contains("embedding"))
        }
        guard let failure = recorder.events.first(where: { $0.eventType == "voice_verify_failure" }) else {
            return XCTFail("a rejected verification must emit voice_verify_failure")
        }
        XCTAssertEqual(failure.outcome, "failure")
        XCTAssertTrue(failure.metadata.keys.contains("reason"),
                      "failures carry a reason (honest error surface), nothing more")
    }

    func testClearProfileIsIdempotentThroughTheService() {
        let service = service()
        guard case .success = service.clearProfile() else {
            return XCTFail("first clear must succeed")
        }
        guard case .success = service.clearProfile() else {
            return XCTFail("clear must be idempotent")
        }
    }
}
