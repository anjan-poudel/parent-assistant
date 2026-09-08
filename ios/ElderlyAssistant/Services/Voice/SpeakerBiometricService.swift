import Foundation

/// The speaker-fingerprint service layer: enrollment (N samples → one
/// persisted template) and verification (audio → score → decision),
/// on-device and offline throughout (research doc §2.3). UI is out of
/// scope by design — the Settings seam is `VoiceBiometricStatusResolver`,
/// and the future owner-only wake / per-speaker-personalization paths
/// (doc §3.1) consume these same two APIs.
///
/// What is wired vs not (honest scope statement):
///  - WIRED: embedder seam (MFCC fallback today, ECAPA CoreML candidate
///    slot), pure scorer, encrypted Keychain template persistence with
///    exact enrolled/absent/corrupt distinction, enrollment quality gates
///    (doc §7.4) + consistency gating, verification threshold + relaxed
///    retry step (doc §9.4 step 3).
///  - NOT WIRED (later phases / other tasks): CommandRouter gating
///    (doc §3.1 `blockedSensitiveAction` seam — the service exposes
///    `verify` for the AuthCoordinator to call), challenge-response
///    liveness (Phase 2), PIN fallback + lockout ladder (doc §9.3,
///    BLOCKER-2), wake-segment activation gating (Phase 3), UI.
///
/// Privacy rules (doc §10), enforced here:
///  - raw enrollment/verification audio is a transient in-memory
///    parameter; nothing is written to disk, nothing is retained;
///  - observability events are outcome-only — counts and reasons, NEVER
///    scores, embeddings, or audio (PII-free logs);
///  - the old template is never deleted before a new enrollment passes
///    every gate (doc §7.1), and `save` is the last step of enrollment.
final class SpeakerBiometricService {

    // MARK: - Policy constants (doc §7.4 / §4.3)

    /// Minimum enrollment utterances (doc: 3–5 is the industry anchor).
    static let minimumEnrollmentSamples = 3
    /// Per-sample consistency floor against the running centroid
    /// (doc §7.4: cosine ≥ ~0.5–0.6, i.e. same-speaker by a wide margin).
    static let enrollmentConsistencyFloor: Float = 0.55

    // MARK: - Dependencies

    private let embedder: SpeakerEmbedder
    private let store: VoiceBiometricStore
    private let verifier: SpeakerVerifier
    private let observabilityBus: ObservabilityBus?

    init(embedder: SpeakerEmbedder,
         store: VoiceBiometricStore,
         policy: VoiceVerificationPolicy = VoiceVerificationPolicy(),
         observabilityBus: ObservabilityBus? = nil) {
        self.embedder = embedder
        self.store = store
        self.verifier = SpeakerVerifier(policy: policy)
        self.observabilityBus = observabilityBus
    }

    /// Whether this launch can enroll/verify at all (false only for the
    /// disabled Null embedder).
    var isEnabled: Bool { embedder.isAvailable }

    /// The embedder identity a stored template must match — exposed for
    /// the Settings status seam (`VoiceBiometricStatusResolver`), which
    /// needs the same truth the service scores against (doc §10).
    var currentEmbedderID: String { embedder.embedderID }

    // MARK: - Enrollment

    /// Records `samples` (N ≥ 3 utterances at `sampleRate`, the pipeline's
    /// 16 kHz int16 format) into one persisted template.
    ///
    /// Per-sample gates, in order (doc §7.4): audible + net speech ≥ 1 s
    /// + SNR ≥ 15 dB, embedding, then same-speaker consistency vs the
    /// running centroid. Any failure rejects the WHOLE session with the
    /// offending sample index and reason — the caller (future Settings
    /// UI) re-prompts that phrase; the old template is untouched until a
    /// fresh session passes every gate and `save` succeeds.
    func enroll(samples: [[Int16]],
                sampleRate: Double = 16_000) async -> Result<EnrolledVoiceProfile, EnrollmentError> {
        guard embedder.isAvailable else { return .failure(.disabled) }
        guard samples.count >= Self.minimumEnrollmentSamples else {
            return .failure(.tooFewSamples(provided: samples.count))
        }

        var embeddings: [SpeakerEmbedding] = []
        var speechSeconds: [Float] = []
        for (index, sample) in samples.enumerated() {
            let quality = UtteranceQualityEvaluator.evaluate(pcm: sample, sampleRate: sampleRate)
            if let issue = qualityIssue(quality) {
                emit("voice_enroll_failure", outcome: "failure",
                     metadata: ["sampleIndex": "\(index)", "reason": "quality_\(issueKey(issue))"])
                return .failure(.qualityGateFailed(sampleIndex: index, issue: issue))
            }
            switch embedder.embed(collectedPCM: sample) {
            case .failure(let error):
                emit("voice_enroll_failure", outcome: "failure",
                     metadata: ["sampleIndex": "\(index)", "reason": "embed_\(errorKey(error))"])
                return .failure(.embeddingFailed(error))
            case .success(let embedding):
                if let centroid = SpeakerEmbedding.centroid(of: embeddings) {
                    guard let consistency = SpeakerEmbedding.cosine(embedding, centroid),
                          consistency >= Self.enrollmentConsistencyFloor else {
                        emit("voice_enroll_failure", outcome: "failure",
                             metadata: ["sampleIndex": "\(index)", "reason": "inconsistent_sample"])
                        return .failure(.inconsistentSample(sampleIndex: index))
                    }
                }
                embeddings.append(embedding)
                speechSeconds.append(quality.netSpeechSeconds)
            }
        }

        guard let centroid = SpeakerEmbedding.centroid(of: embeddings) else {
            return .failure(.embeddingFailed(.processingFailed))
        }
        let profile = EnrolledVoiceProfile(
            schemaVersion: VoiceBiometricStore.currentSchemaVersion,
            embedderID: centroid.embedderID,
            embedding: centroid.values,
            createdAt: Date(),
            utteranceCount: embeddings.count,
            perUtteranceSpeechSeconds: speechSeconds)
        switch store.save(profile) {
        case .failure:
            emit("voice_enroll_failure", outcome: "failure", metadata: ["reason": "persistence"])
            return .failure(.persistenceFailed)
        case .success:
            emit("voice_enroll_success", outcome: "success",
                 metadata: ["sampleCount": "\(profile.utteranceCount)",
                            "netSpeechSeconds": String(format: "%.1f",
                                                       speechSeconds.reduce(0, +))])
            return .success(profile)
        }
    }

    // MARK: - Verification

    /// Verifies one captured utterance against the enrolled template.
    /// Returns the decision (score included — scores stay in-process) or
    /// an error for the states no decision can fix: disabled, never
    /// enrolled, unreadable template, or an embedder change (the
    /// re-enrollment signal; doc §10). `relaxed` applies the retry
    /// threshold (doc §9.4 step 3) — the caller owns the retry ladder.
    func verify(pcm: [Int16],
                sampleRate: Double = 16_000,
                relaxed: Bool = false) async -> Result<VerificationDecision, VerificationError> {
        guard embedder.isAvailable else { return .failure(.disabled) }

        let profile: EnrolledVoiceProfile
        switch store.load() {
        case .success(.none):
            return .failure(.notEnrolled)
        case .failure:
            emit("voice_verify_failure", outcome: "failure", metadata: ["reason": "template_unreadable"])
            return .failure(.templateUnreadable)
        case .success(.some(let loaded)):
            profile = loaded
        }
        guard profile.embedderID == embedder.embedderID else {
            emit("voice_verify_failure", outcome: "failure", metadata: ["reason": "embedder_mismatch"])
            return .failure(.embedderMismatch(templateEmbedder: profile.embedderID,
                                              currentEmbedder: embedder.embedderID))
        }
        guard let template = SpeakerEmbedding(values: profile.embedding,
                                              embedderID: profile.embedderID) else {
            return .failure(.templateUnreadable)
        }

        let quality = UtteranceQualityEvaluator.evaluate(pcm: pcm, sampleRate: sampleRate)
        let embedding: SpeakerEmbedding
        switch embedder.embed(collectedPCM: pcm) {
        case .failure(let error):
            emit("voice_verify_failure", outcome: "failure",
                 metadata: ["reason": "embed_\(errorKey(error))"])
            return .failure(.embeddingFailed(error))
        case .success(let value):
            embedding = value
        }

        let decision = verifier.decide(embedding: embedding, template: template,
                                       quality: quality, relaxed: relaxed)
        switch decision.outcome {
        case .accept:
            emit("voice_verify_success", outcome: "success",
                 metadata: ["relaxed": relaxed ? "true" : "false"])
        case .reject(let reason):
            emit("voice_verify_failure", outcome: "failure",
                 metadata: ["reason": "reject_\(reasonKey(reason))",
                            "relaxed": relaxed ? "true" : "false"])
        }
        return .success(decision)
    }

    // MARK: - Profile management (Settings seam)

    func loadProfile() -> Result<EnrolledVoiceProfile?, StorageError> {
        store.load()
    }

    /// "Remove voice login" (doc §10, withdrawal). Idempotent; emits
    /// outcome-only.
    func clearProfile() -> Result<Void, StorageError> {
        let result = store.clear()
        switch result {
        case .success:
            emit("voice_profile_cleared", outcome: "success")
        case .failure:
            emit("voice_profile_cleared", outcome: "failure")
        }
        return result
    }

    // MARK: - Observability (outcome-only, no scores — doc §10)

    private func emit(_ eventType: String, outcome: String,
                      metadata: [String: String] = [:]) {
        observabilityBus?.emit(ObservabilityEvent(
            component: "voice_biometric",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: metadata))
    }

    private func qualityIssue(_ quality: UtteranceQuality) -> UtteranceQuality.Issue? {
        // The service applies the same gate as the verifier (one policy
        // source), but as a session-level refusal for enrollment.
        let issue = quality.issue(under: verifier.policy)
        return issue == .none ? nil : issue
    }

    private func issueKey(_ issue: UtteranceQuality.Issue) -> String {
        switch issue {
        case .none: return "none"
        case .speechTooShort: return "speech_too_short"
        case .tooNoisy: return "too_noisy"
        case .tooQuiet: return "too_quiet"
        }
    }

    private func reasonKey(_ reason: VerificationRejectReason) -> String {
        switch reason {
        case .speechTooShort: return "speech_too_short"
        case .tooNoisy: return "too_noisy"
        case .tooQuiet: return "too_quiet"
        case .belowThreshold: return "below_threshold"
        case .embedderMismatch: return "embedder_mismatch"
        }
    }

    private func errorKey(_ error: SpeakerEmbeddingError) -> String {
        switch error {
        case .unavailable: return "unavailable"
        case .audioTooShort: return "too_short"
        case .audioTooQuiet: return "too_quiet"
        case .processingFailed: return "processing_failed"
        }
    }
}

// MARK: - Errors

enum EnrollmentError: Error, Equatable, Sendable {
    /// Voice login disabled in this build (Null embedder).
    case disabled
    case tooFewSamples(provided: Int)
    /// Sample at `sampleIndex` failed a quality gate; re-prompt that
    /// phrase (doc §7.4: max ~2 quality retries per phrase is UI policy).
    case qualityGateFailed(sampleIndex: Int, issue: UtteranceQuality.Issue)
    /// Sample at `sampleIndex` scored below the same-speaker consistency
    /// floor against the running centroid (someone else spoke, or the
    /// sample was captured under wildly different acoustics).
    case inconsistentSample(sampleIndex: Int)
    case embeddingFailed(SpeakerEmbeddingError)
    case persistenceFailed
}

enum VerificationError: Error, Equatable, Sendable {
    case disabled
    case notEnrolled
    /// Marker present but payload unreadable — re-enrollment is the only
    /// recovery (Keychain this-device-only; doc §7.1).
    case templateUnreadable
    /// The enrolled template belongs to a different embedder (model or
    /// frontend changed). Never score across embedders — re-enroll.
    case embedderMismatch(templateEmbedder: String, currentEmbedder: String)
    case embeddingFailed(SpeakerEmbeddingError)
}
