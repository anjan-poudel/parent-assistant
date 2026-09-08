import Foundation

/// Pure speaker-verification scoring — deliberately free of any embedder
/// or ML runtime (the house pattern behind `WakeWordConfig`), so threshold
/// behaviour unit-tests without a model. Consumes `SpeakerEmbedding`
/// vectors and `UtteranceQuality` measurements and produces a decision.
///
/// Policy (research doc §4.3/§9.5): cosine similarity on L2-normalised
/// embeddings, a fixed accept threshold (no adaptive per-user
/// thresholds — with one enrolled speaker there are no true-score
/// statistics), plus a *documented* relaxed-step threshold the caller
/// applies only on a retry after a first failure (doc §9.4 step 3: a
/// stated policy step, not statistical adaptation).
///
/// THRESHOLD HONESTY: the doc's ~1%-FAR operating points (ECAPA ≈ 0.25)
/// do NOT transfer to the MFCC-stats fallback embedder — thresholds are
/// embedder-specific and uncalibrated here; real-recording calibration
/// is a Phase-0 gate (doc §4.3, §12 open question 3). The defaults below
/// are engineering placeholders that separate synthetic fixtures, nothing
/// more.
struct VoiceVerificationPolicy: Equatable, Sendable {
    var acceptThreshold: Float = 0.55
    /// Applied only on an explicit retry after a failure (doc §9.4 step 3).
    var relaxedThreshold: Float = 0.50
    /// Utterance-quality gates (doc §7.4): net speech ≥ ~1 s and
    /// SNR ≥ ~15 dB, or the utterance is refused before any score exists —
    /// enrolling/verifying on poor audio produces false accepts later.
    var minimumSpeechSeconds: Float = 1.0
    var minimumSNRDb: Float = 15.0
}

// MARK: - Utterance quality (pre-embedding gate)

struct UtteranceQuality: Equatable, Sendable {
    /// Whole-utterance RMS in dBFS.
    let rmsDbFS: Float
    /// Estimated SNR: 95th-percentile frame RMS over the noise floor
    /// (10th-percentile frame RMS). A constant-amplitude signal (pure
    /// tone, white noise) has SNR ≈ 0 — which is the correct answer for
    /// a gate that exists to refuse unvoiced energy.
    let snrDb: Float
    /// Seconds of frames whose RMS clears the noise floor by ≥ 10 dB.
    let netSpeechSeconds: Float

    enum Issue: Equatable, Sendable {
        case none
        case speechTooShort
        case tooNoisy
        case tooQuiet
    }

    /// The issue that would refuse this utterance under the policy, or
    /// `.none` when it passes every gate. `tooQuiet` is the silence
    /// refusal (reuse the embedder's floor); `tooNoisy` covers both
    /// low-SNR speech and non-speech energy, which the gate cannot
    /// distinguish — the honest error text says "couldn't hear you
    /// clearly", never "you are not the owner".
    func issue(under policy: VoiceVerificationPolicy) -> Issue {
        if rmsDbFS < MFCCSpeakerEmbedder.silenceFloorDbFS { return .tooQuiet }
        if netSpeechSeconds < policy.minimumSpeechSeconds { return .speechTooShort }
        if snrDb < policy.minimumSNRDb { return .tooNoisy }
        return .none
    }
}

/// Deterministic quality estimation over 16 kHz int16 PCM (frame/stat
/// based, no randomness, no model). Pure static functions so the gate
/// itself is pinned by tests.
enum UtteranceQualityEvaluator {

    /// Frame geometry shared with the embedder frontend (25 ms / 10 ms).
    static let frameLengthSamples = MelFilterbankFrontend.frameLengthSamples
    static let frameHopSamples = MelFilterbankFrontend.frameHopSamples
    /// Speech-clearance over the noise floor (dB).
    static let speechFrameMarginDb: Float = 10

    static func evaluate(pcm: [Int16], sampleRate: Double = 16_000) -> UtteranceQuality {
        let overallRms = MFCCSpeakerEmbedder.rmsDbFS(pcm)
        let frameRms: [Float] = frameRMSDb(pcm)
        guard !frameRms.isEmpty else {
            return UtteranceQuality(rmsDbFS: overallRms, snrDb: 0,
                                    netSpeechSeconds: 0)
        }
        let sorted = frameRms.sorted()
        let noiseFloor = percentile(sorted, 0.10)
        let signalLevel = percentile(sorted, 0.95)
        let snr = max(0, signalLevel - noiseFloor)
        let speechFrames = frameRms.filter { $0 >= noiseFloor + speechFrameMarginDb }.count
        let hopSeconds = Float(frameHopSamples) / Float(sampleRate)
        return UtteranceQuality(rmsDbFS: overallRms,
                                snrDb: snr,
                                netSpeechSeconds: Float(speechFrames) * hopSeconds)
    }

    private static func frameRMSDb(_ pcm: [Int16]) -> [Float] {
        var result: [Float] = []
        var start = 0
        while start + frameLengthSamples <= pcm.count {
            var sumSq: Double = 0
            for i in start..<(start + frameLengthSamples) {
                let v = Double(pcm[i])
                sumSq += v * v
            }
            let rms = (sumSq / Double(frameLengthSamples)).squareRoot()
            result.append(rms > 0 ? Float(20 * log10(rms / 32768.0)) : -100)
            start += frameHopSamples
        }
        return result
    }

    /// Nearest-rank percentile of a sorted array (deterministic).
    private static func percentile(_ sorted: [Float], _ p: Float) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1,
                        max(0, Int((Float(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }
}

// MARK: - Decision

enum VerificationRejectReason: Equatable, Sendable {
    case speechTooShort
    case tooNoisy
    case tooQuiet
    case belowThreshold
    case embedderMismatch
}

struct VerificationDecision: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case accept
        case reject(VerificationRejectReason)
    }

    let outcome: Outcome
    /// Cosine score that drove the decision; nil when no score was
    /// computed (quality refusal or embedder mismatch). Scores stay in
    /// the process — they are NEVER emitted to observability (research
    /// doc §10: PII-free logs, outcome-only events).
    let score: Float?
    let quality: UtteranceQuality?
}

/// Pure decision function over embedded vectors + measured quality.
struct SpeakerVerifier: Sendable {

    let policy: VoiceVerificationPolicy

    init(policy: VoiceVerificationPolicy = VoiceVerificationPolicy()) {
        self.policy = policy
    }

    /// Scores `embedding` against `template` and applies the policy.
    /// `relaxed` selects the retry threshold (doc §9.4 step 3); the
    /// caller — never this function — owns the retry ladder, so the
    /// relaxation stays a stated one-step policy instead of an adaptive
    /// threshold.
    func decide(embedding: SpeakerEmbedding,
                template: SpeakerEmbedding,
                quality: UtteranceQuality,
                relaxed: Bool = false) -> VerificationDecision {
        guard embedding.embedderID == template.embedderID else {
            return VerificationDecision(outcome: .reject(.embedderMismatch),
                                        score: nil, quality: quality)
        }
        switch quality.issue(under: policy) {
        case .none:
            break
        case .speechTooShort:
            return VerificationDecision(outcome: .reject(.speechTooShort),
                                        score: nil, quality: quality)
        case .tooNoisy:
            return VerificationDecision(outcome: .reject(.tooNoisy),
                                        score: nil, quality: quality)
        case .tooQuiet:
            return VerificationDecision(outcome: .reject(.tooQuiet),
                                        score: nil, quality: quality)
        }

        guard let score = SpeakerEmbedding.cosine(embedding, template) else {
            // Dimension mismatch: same refusal class as embedder mismatch —
            // a score across incompatible vectors must never exist.
            return VerificationDecision(outcome: .reject(.embedderMismatch),
                                        score: nil, quality: quality)
        }
        let threshold = relaxed ? policy.relaxedThreshold : policy.acceptThreshold
        let outcome: VerificationDecision.Outcome =
            score >= threshold ? .accept : .reject(.belowThreshold)
        return VerificationDecision(outcome: outcome, score: score,
                                    quality: quality)
    }
}
