import XCTest
@testable import ElderlyAssistant

/// Pure decision logic (Services/Voice/SpeakerVerifier.swift): threshold
/// behaviour, the relaxed retry step (doc §9.4 step 3), quality-gate
/// refusals, and cross-embedder refusals — no audio or model involved,
/// everything via fixed vectors and fixed quality measurements.
final class SpeakerVerifierTests: XCTestCase {

    private let policy = VoiceVerificationPolicy(
        acceptThreshold: 0.55, relaxedThreshold: 0.50,
        minimumSpeechSeconds: 1.0, minimumSNRDb: 15.0)
    private lazy var verifier = SpeakerVerifier(policy: policy)

    private func quality(speech: Float = 2.0, snr: Float = 25.0,
                         rms: Float = -20) -> UtteranceQuality {
        UtteranceQuality(rmsDbFS: rms, snrDb: snr, netSpeechSeconds: speech)
    }

    private func emb(_ values: [Float], id: String = "stub.v1") -> SpeakerEmbedding {
        StubSpeakerEmbedder.embedding(values[0], values[1], values[2], embedderID: id)
    }

    private func unit(_ values: [Float], id: String = "stub.v1") -> SpeakerEmbedding {
        SpeakerEmbedding(values: values, embedderID: id)!.l2Normalized()
    }

    // MARK: - Threshold behaviour

    func testAcceptsExactTemplateMatch() {
        let template = unit([1, 2, 3])
        let decision = verifier.decide(embedding: unit([1, 2, 3]),
                                       template: template,
                                       quality: quality())
        XCTAssertEqual(decision.outcome, .accept)
        XCTAssertEqual(decision.score!, 1.0, accuracy: 1e-5)
    }

    func testAcceptsAboveThreshold() {
        // cos ≈ 0.95 > 0.55.
        let template = unit([1, 0, 0])
        let candidate = unit([10, 3, 0])
        let decision = verifier.decide(embedding: candidate, template: template,
                                       quality: quality())
        XCTAssertEqual(decision.outcome, .accept)
        XCTAssertGreaterThanOrEqual(decision.score!, policy.acceptThreshold)
    }

    func testRejectsBelowThresholdWithScore() {
        let template = unit([1, 0, 0])
        let decision = verifier.decide(embedding: unit([0, 1, 0]),
                                       template: template,
                                       quality: quality())
        XCTAssertEqual(decision.outcome, .reject(.belowThreshold))
        XCTAssertEqual(decision.score!, 0.0, accuracy: 1e-5,
                       "a rejection below threshold still carries its score — scores stay in-process (doc §10)")
    }

    func testThresholdComparisonIsInclusive() {
        // A candidate at cosine exactly 0.55 must accept (≥, not >).
        // cos θ = 0.55 with template (1,0): candidate = (0.55, √(1-0.55²)).
        let template = SpeakerEmbedding(values: [1, 0], embedderID: "stub.v1")!
        let y = Float((1 - 0.55 * 0.55).squareRoot())
        let candidate = SpeakerEmbedding(values: [0.55, y], embedderID: "stub.v1")!
        let decision = verifier.decide(embedding: candidate, template: template,
                                       quality: quality())
        XCTAssertEqual(decision.outcome, .accept,
                       "score == threshold is an accept (inclusive comparison)")
    }

    // MARK: - Relaxed retry step (doc §9.4 step 3)

    func testRelaxedStepAcceptsScoresInTheRelaxedBand() {
        // cos θ = 0.53: below 0.55 (reject), at/above 0.50 (relaxed accept).
        let template = SpeakerEmbedding(values: [1, 0], embedderID: "stub.v1")!
        let y = Float((1 - 0.53 * 0.53).squareRoot())
        let candidate = SpeakerEmbedding(values: [0.53, y], embedderID: "stub.v1")!

        let strict = verifier.decide(embedding: candidate, template: template,
                                     quality: quality(), relaxed: false)
        XCTAssertEqual(strict.outcome, .reject(.belowThreshold))

        let relaxed = verifier.decide(embedding: candidate, template: template,
                                      quality: quality(), relaxed: true)
        XCTAssertEqual(relaxed.outcome, .accept)
    }

    func testRelaxedStepDoesNotRescueFarMismatches() {
        let template = unit([1, 0, 0])
        let decision = verifier.decide(embedding: unit([0, 1, 0]),
                                       template: template,
                                       quality: quality(), relaxed: true)
        XCTAssertEqual(decision.outcome, .reject(.belowThreshold),
                       "the relaxation is a stated one-step policy, not an ever-loosening threshold")
    }

    // MARK: - Quality refusals (no score is ever computed for bad audio)

    func testRefusesShortSpeechBeforeScoring() {
        let decision = verifier.decide(embedding: unit([1, 0, 0]),
                                       template: unit([1, 0, 0]),
                                       quality: quality(speech: 0.4))
        XCTAssertEqual(decision.outcome, .reject(.speechTooShort))
        XCTAssertNil(decision.score,
                     "refused audio must produce no score — nothing to log, nothing to act on")
    }

    func testRefusesNoisyUtteranceBeforeScoring() {
        let decision = verifier.decide(embedding: unit([1, 0, 0]),
                                       template: unit([1, 0, 0]),
                                       quality: quality(snr: 9.0))
        XCTAssertEqual(decision.outcome, .reject(.tooNoisy))
        XCTAssertNil(decision.score)
    }

    func testRefusesSilentUtteranceBeforeScoring() {
        let decision = verifier.decide(embedding: unit([1, 0, 0]),
                                       template: unit([1, 0, 0]),
                                       quality: quality(rms: -60))
        XCTAssertEqual(decision.outcome, .reject(.tooQuiet))
        XCTAssertNil(decision.score)
    }

    // MARK: - Embedder integrity

    func testRefusesCrossEmbedderScoring() {
        let decision = verifier.decide(embedding: emb([1, 0, 0], id: "new.v2"),
                                       template: emb([1, 0, 0], id: "old.v1"),
                                       quality: quality())
        XCTAssertEqual(decision.outcome, .reject(.embedderMismatch))
        XCTAssertNil(decision.score)
    }

    func testRefusesDimensionMismatchAsEmbedderMismatch() {
        let template = SpeakerEmbedding(values: [1, 0, 0], embedderID: "stub.v1")!
        let wrongDim = SpeakerEmbedding(values: [1, 0], embedderID: "stub.v1")!
        let decision = verifier.decide(embedding: wrongDim, template: template,
                                       quality: quality())
        XCTAssertEqual(decision.outcome, .reject(.embedderMismatch),
                       "incompatible vectors are the same refusal class — a score must never exist")
    }

    func testDecisionCarriesQualityMeasurements() {
        let measured = quality(speech: 1.8, snr: 22.0)
        let decision = verifier.decide(embedding: unit([1, 0, 0]),
                                       template: unit([1, 0, 0]),
                                       quality: measured)
        XCTAssertEqual(decision.quality, measured,
                       "the quality that gated the decision is part of the result")
    }

    // MARK: - Quality evaluator (deterministic, synthetic audio)

    func testEvaluatorPassesCleanSyntheticSpeech() {
        let quality = UtteranceQualityEvaluator.evaluate(
            pcm: FixtureSpeakers.aUtterance(1, seconds: 3.0))
        XCTAssertGreaterThanOrEqual(quality.snrDb, 15.0,
                                    "syllabic fixture must clear the SNR gate (got \(quality.snrDb))")
        XCTAssertGreaterThanOrEqual(quality.netSpeechSeconds, 1.0,
                                    "…and the net-speech gate (got \(quality.netSpeechSeconds))")
        XCTAssertEqual(quality.issue(under: policy), .none)
    }

    func testEvaluatorFlagsConstantAmplitudeNoise() {
        // White noise: every frame has the same RMS → SNR ≈ 0 → refused.
        let quality = UtteranceQualityEvaluator.evaluate(
            pcm: SyntheticAudio.whiteNoise(seconds: 3.0))
        let issue = quality.issue(under: policy)
        XCTAssertNotEqual(issue, .none,
                          "constant-amplitude noise must never pass the gate")
    }

    func testEvaluatorFlagsShallowDynamicsAsTooNoisy() {
        // Same speaker, but the syllabic gap is only a 12 dB dip
        // (quietRatio 0.25): speech frames still clear the noise floor by
        // the required 10 dB, yet the speech-vs-floor SNR stays below the
        // 15 dB gate — the tooNoisy path, distinct from speechTooShort
        // (a signal whose every frame sits near the floor).
        let pcm = SyntheticAudio.harmonicSpeaker(f0: FixtureSpeakers.aF0,
                                                 seconds: 3.0,
                                                 quietRatio: 0.25)
        let quality = UtteranceQualityEvaluator.evaluate(pcm: pcm)
        XCTAssertGreaterThanOrEqual(quality.netSpeechSeconds, 1.0)
        XCTAssertLessThan(quality.snrDb, 15.0)
        XCTAssertEqual(quality.issue(under: policy), .tooNoisy)
    }

    func testEvaluatorFlagsShortUtterance() {
        let quality = UtteranceQualityEvaluator.evaluate(
            pcm: FixtureSpeakers.aUtterance(1, seconds: 0.5))
        XCTAssertEqual(quality.issue(under: policy), .speechTooShort)
    }

    func testEvaluatorFlagsSilence() {
        let quality = UtteranceQualityEvaluator.evaluate(
            pcm: SyntheticAudio.silence(seconds: 3.0))
        XCTAssertEqual(quality.issue(under: policy), .tooQuiet)
    }
}
