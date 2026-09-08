import Foundation

/// A speaker embedder turns an utterance's 16 kHz int16 PCM into a
/// `SpeakerEmbedding` — the on-device speaker-fingerprint frontend
/// (docs/research-sections/speaker-fingerprint.md §3.2).
///
/// Protocol shape deliberately mirrors `WakeWordEngine` /
/// `VoiceActivityDetector` (`requiredSampleRate` / `frameLength` /
/// `process`), so the same mic-tap conversion VoicePipeline already runs
/// (16 kHz int16 mono, see `VoicePipeline.installMicTap`) feeds every
/// implementation unchanged. `embed(collectedPCM:)` is the verification
/// path — the pipeline already holds the full capture in `pcmBuffer` in
/// exactly this format — while `process` exists for the streaming
/// contract (the future passive-scoring and wake-segment-gating paths,
/// research doc §3.1 insertion points b and Phase 3).
///
/// Implementations today:
///  - `MFCCSpeakerEmbedder` — deterministic, model-free MFCC-stats
///    fallback (this build; see its header for the honest accuracy gap vs
///    the recommended ECAPA CoreML embedder, research doc §4.1).
///  - `NullSpeakerEmbedder` — voice login disabled; every embed refuses,
///    so enrollment/verification can never silently proceed.
///  - `CoreMLSpeakerEmbedder` (ECAPA fp16) is the research doc's
///    recommended production path — it lands via `SpeakerEmbedderSelection`
///    once the Phase-0 conversion spike (research doc §11) ships.
protocol SpeakerEmbedder: AnyObject {
    /// Sample rate the embedder expects for input audio. The tap must
    /// convert to this rate before calling `process` / `embed`.
    var requiredSampleRate: Double { get }

    /// Number of samples per streaming frame for `process(_:)`.
    var frameLength: Int { get }

    /// Dimension of the vectors `embed` produces.
    var embeddingDimension: Int { get }

    /// Stable identity of this embedder (model + frontend version). A
    /// stored template is only valid against the same id — re-enrollment
    /// is required when it changes (research doc §10).
    var embedderID: String { get }

    /// Whether this embedder can produce embeddings. Null implementations
    /// return false; the service layer refuses enrollment/verification
    /// while unavailable instead of producing a garbage template.
    var isAvailable: Bool { get }

    /// Feed a single streaming frame (contract parity with the wake-word
    /// engine; the verification path uses `embed(collectedPCM:)`).
    func process(_ pcm: [Int16])

    /// Forget any streamed frames accumulated via `process(_:)`.
    func reset()

    /// Embed a complete utterance. The buffer is treated as one recording
    /// at `requiredSampleRate`; no internal state is read or mutated, so
    /// this call is re-entrant and deterministic.
    func embed(collectedPCM: [Int16]) -> Result<SpeakerEmbedding, SpeakerEmbeddingError>
}

extension SpeakerEmbedder {
    var isAvailable: Bool { true }
}

// MARK: - Errors

enum SpeakerEmbeddingError: Error, Equatable {
    /// The embedder cannot produce embeddings (Null implementation —
    /// voice login disabled in this build).
    case unavailable
    /// Not enough audible signal to embed (net seconds below the floor).
    case audioTooShort(netSpeechSeconds: Float)
    /// The buffer is effectively silent; an embedding of silence is
    /// meaningless (and would be a liability, not a feature).
    case audioTooQuiet(rmsDbFS: Float)
    /// Internal DSP/model failure.
    case processingFailed
}

// MARK: - Null implementation (compile-safe, honest)

/// Returns `.unavailable` for every embed. Used when voice login is
/// disabled so that enrollment and verification fail loudly and early —
/// never a silent stub pretending to fingerprint. `SpeakerEmbedderSelection`
/// documents exactly how this instance comes to exist; the Settings seam
/// derives its "voice login off" status from the same truth.
final class NullSpeakerEmbedder: SpeakerEmbedder {
    let requiredSampleRate: Double = 16_000
    let frameLength: Int = 512
    let embeddingDimension: Int = 0
    let embedderID: String = "null"
    var isAvailable: Bool { false }

    func process(_ pcm: [Int16]) { /* intentionally does nothing */ }
    func reset() {}
    func embed(collectedPCM: [Int16]) -> Result<SpeakerEmbedding, SpeakerEmbeddingError> {
        .failure(.unavailable)
    }
}

// MARK: - Selection (decision table, WakeWordEngineSelection-style)

/// Which embedder this launch gets. The deliberate honesty contract
/// (mirroring `WakeWordEngineSelection`): the real production embedder
/// (ECAPA CoreML) arrives only as the injected candidate closure, and
/// when it is absent the deterministic MFCC fallback ships — never a
/// Null engine pretending to be active. `disabled()` is the only Null
/// path and means exactly what it says: voice login is switched off.
enum SpeakerEmbedderSelection {

    /// Builds the best available embedder: the CoreML candidate when one
    /// exists (future ECAPA path — the candidate returns nil until the
    /// Phase-0 conversion spike lands), else the model-free MFCC
    /// fallback. This factory itself never returns Null.
    static func make(coreMLCandidate: (() -> SpeakerEmbedder?)? = nil) -> SpeakerEmbedder {
        if let candidate = coreMLCandidate?() {
            return candidate
        }
        return MFCCSpeakerEmbedder()
    }

    /// Explicitly disabled: Null embedder, so every enroll/verify call
    /// refuses. Distinct from "no CoreML model" — the MFCC fallback keeps
    /// working in that case.
    static func disabled() -> SpeakerEmbedder {
        NullSpeakerEmbedder()
    }
}

// MARK: - Status (honest derivation for the Settings seam)

/// What the Settings → "Voice login" screen can truthfully say, derived
/// from the same facts the service layer uses — the pattern behind
/// `WakeWordStatusResolver`: never claim Active when nothing is usable.
enum VoiceBiometricStatus: Equatable {
    /// Voice login disabled (Null embedder in this launch).
    case disabled
    /// No template stored yet — enrollment is the next step.
    case notEnrolled
    /// A template exists and was produced by the current embedder.
    case enrolled(embedderID: String)
    /// A template exists but the current embedder cannot score it
    /// (embedder changed) — re-enrollment required (research doc §10).
    case needsReenrollment(templateEmbedderID: String)
    /// A template marker exists but the payload cannot be read — treat
    /// exactly like needs-reenrollment in the UI; the data is unrecoverable
    /// by design (Keychain, this-device-only) and re-enrollment is the
    /// recovery path (research doc §7.1: "Retrain voice model").
    case templateUnreadable
}

enum VoiceBiometricStatusResolver {

    static func status(enabled: Bool,
                       profileLoad: Result<EnrolledVoiceProfile?, StorageError>,
                       currentEmbedderID: String) -> VoiceBiometricStatus {
        guard enabled else { return .disabled }
        switch profileLoad {
        case .failure:
            return .templateUnreadable
        case .success(.none):
            return .notEnrolled
        case .success(.some(let profile)):
            return profile.embedderID == currentEmbedderID
                ? .enrolled(embedderID: profile.embedderID)
                : .needsReenrollment(templateEmbedderID: profile.embedderID)
        }
    }
}
