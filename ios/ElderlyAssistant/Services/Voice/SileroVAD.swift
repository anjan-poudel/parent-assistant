import Foundation
import AVFoundation

/// Voice activity detector: decides whether a chunk of PCM audio contains
/// speech, and reports when the user has stopped talking (~200 ms of
/// silence). Used to gate the speech recognizer — only stream audio into
/// Whisper while `VoiceActivityDetector.isSpeech` is true, and stop the
/// STT within 200 ms of the trailing silence so the user's command feels
/// snappy.
///
/// Concrete production impl is the Silero ONNX model (~2 MB). The Null
/// implementation is a permissive fallback that always treats audio as
/// speech — useful for tests and for the scaffold state before the ONNX
/// model has been downloaded.
protocol VoiceActivityDetector: AnyObject {
    /// Sample rate the detector expects (16 kHz for Silero).
    var requiredSampleRate: Double { get }
    /// Number of samples per processing frame (typically 512 at 16 kHz).
    var frameLength: Int { get }
    /// Called with the *smoothed* speech state, not raw frame decisions.
    var onSpeechStateChange: ((Bool) -> Void)? { get set }
    /// Called once when trailing silence exceeds `endOfUtteranceMs`.
    var onEndOfUtterance: (() -> Void)? { get set }

    func start(endOfUtteranceMs: Int)
    func stop()
    func reset()
    func process(_ pcm: [Int16])
}

// MARK: - Null implementation (fallback, tests)

/// Always returns "speech present"; never emits end-of-utterance on its
/// own. Callers must impose their own timeout. This is the safest failure
/// mode: the STT will still run, we just won't cut it short.
final class NullVAD: VoiceActivityDetector {
    let requiredSampleRate: Double = 16_000
    let frameLength: Int = 512
    var onSpeechStateChange: ((Bool) -> Void)?
    var onEndOfUtterance: (() -> Void)?

    private var reportedSpeech = false

    func start(endOfUtteranceMs: Int) {
        if !reportedSpeech {
            reportedSpeech = true
            onSpeechStateChange?(true)
        }
    }
    func stop() {}
    func reset() { reportedSpeech = false }
    func process(_ pcm: [Int16]) {}
}

// MARK: - Lightweight local VAD (MVP)

/// Energy-based VAD used for the iOS MVP before the Silero runtime is linked.
///
/// Two cooperating mechanisms, both adaptive — no fixed absolute levels:
///
/// 1. SPEECH START uses an adaptive absolute threshold: an EMA of ambient
///    frame RMS (`noiseFloor`) tracks the room while no speech is active,
///    and speech begins when a frame exceeds `speechMultiplier` x floor
///    (clamped to [minSpeechThreshold, maxSpeechThreshold]).
///
/// 2. SPEECH END uses a RELATIVE drop: while speech is active, an EMA of
///    the speech energy (`speechLevel`) is maintained, and any frame below
///    `max(minSpeechThreshold, speechLevel x dropRatio)` counts toward the
///    trailing-silence hangover. Keying off the DROP from observed speech
///    energy — not an absolute quiet level — is what makes endpointing
///    work in real homes: when the user stops talking, RMS falls from
///    speech level to whatever the background is (fan/TV/street), and the
///    end-of-utterance fires after the hangover no matter how loud that
///    background happens to be.
///
/// Why: the previous fixed thresholds (0.018/0.010 RMS) silently stopped
/// endpointing outside quiet rooms — ordinary background noise sits ABOVE
/// a quiet-room threshold, the quiet counter kept resetting, and every
/// capture ran out VoicePipeline's fixed 8 s timeout before transcription
/// even started (the "constant lag" reported 2026-09-05). A first adaptive
/// attempt that learned the floor only from below-threshold frames still
/// failed: noise louder than the seed threshold is classified AS speech,
/// so the floor could never rise to meet it (chicken-and-egg). The
/// relative-drop end criterion has no such dependency.
final class EnergyVAD: VoiceActivityDetector {
    let requiredSampleRate: Double = 16_000
    let frameLength: Int = 512
    var onSpeechStateChange: ((Bool) -> Void)?
    var onEndOfUtterance: (() -> Void)?

    /// Speech-start threshold = noiseFloor x this (before clamping).
    private let speechMultiplier: Float
    /// EMA rate for the noise floor (~1 s to converge at 31.25 fps).
    private let floorAlpha: Float
    /// End-of-speech level = speechLevel x this (6 dB drop), floored at
    /// minSpeechThreshold so near-silent tails in quiet rooms still count.
    private let dropRatio: Float
    /// EMA rate for speechLevel while speech frames arrive.
    private let speechLevelAlpha: Float
    /// Absolute clamps on the speech-start threshold: keeps sensitivity in
    /// a silent room (floor ~ 0) and bounds it in a very loud one.
    private let minSpeechThreshold: Float
    private let maxSpeechThreshold: Float
    /// Ambient RMS estimate. Seeded low so first use is maximally
    /// sensitive. NOT reset per utterance — a property of the room.
    private var noiseFloor: Float
    private let initialNoiseFloor: Float
    /// Running speech-energy estimate while `speechActive`. Frozen during
    /// the quiet tail so the drop reference can't decay into the noise it
    /// is trying to measure against.
    private var speechLevel: Float = 0

    private var running = false
    private var speechActive = false
    private var quietFrames = 0
    private var requiredQuietFrames = 8
    private var hasReportedEnd = false

    init(speechMultiplier: Float = 2.5,
         floorAlpha: Float = 0.08,
         dropRatio: Float = 0.5,
         speechLevelAlpha: Float = 0.3,
         minSpeechThreshold: Float = 0.012,
         maxSpeechThreshold: Float = 0.10,
         initialNoiseFloor: Float = 0.005) {
        self.speechMultiplier = speechMultiplier
        self.floorAlpha = floorAlpha
        self.dropRatio = dropRatio
        self.speechLevelAlpha = speechLevelAlpha
        self.minSpeechThreshold = minSpeechThreshold
        self.maxSpeechThreshold = maxSpeechThreshold
        self.initialNoiseFloor = initialNoiseFloor
        self.noiseFloor = initialNoiseFloor
    }

    private var speechStartThreshold: Float {
        min(maxSpeechThreshold, max(minSpeechThreshold, noiseFloor * speechMultiplier))
    }

    func start(endOfUtteranceMs: Int) {
        requiredQuietFrames = max(1, Int(ceil((Double(endOfUtteranceMs) / 1000.0) /
                                            (Double(frameLength) / requiredSampleRate))))
        running = true
        reset()
    }

    func stop() {
        running = false
    }

    func reset() {
        speechActive = false
        speechLevel = 0
        quietFrames = 0
        hasReportedEnd = false
        // noiseFloor survives reset(): room calibration carries across
        // utterances within a capture session.
    }

    func process(_ pcm: [Int16]) {
        guard running, !pcm.isEmpty, !hasReportedEnd else { return }
        let rms = Self.rms(pcm)

        if !speechActive {
            if rms >= speechStartThreshold {
                speechActive = true
                speechLevel = rms
                quietFrames = 0
                onSpeechStateChange?(true)
            } else {
                noiseFloor += floorAlpha * (rms - noiseFloor)
            }
            return
        }

        // Speech active: end when energy drops below a fraction of the
        // running speech level (or the absolute minimum) for the whole
        // hangover window.
        let endLevel = max(minSpeechThreshold, speechLevel * dropRatio)
        if rms >= endLevel {
            quietFrames = 0
            speechLevel += speechLevelAlpha * (rms - speechLevel)
            return
        }

        // Quiet-counted frame — also teach the floor (a mid-speech gap is
        // a sample of the room), but never the speechLevel reference.
        noiseFloor += floorAlpha * (rms - noiseFloor)
        quietFrames += 1
        if quietFrames >= requiredQuietFrames {
            hasReportedEnd = true
            speechActive = false
            onSpeechStateChange?(false)
            onEndOfUtterance?()
        }
    }

    private static func rms(_ pcm: [Int16]) -> Float {
        var sum: Float = 0
        for sample in pcm {
            let normalized = Float(sample) / 32_768.0
            sum += normalized * normalized
        }
        return sqrt(sum / Float(pcm.count))
    }
}

// MARK: - Silero ONNX implementation (guarded)

/// Real VAD backed by the Silero v5 ONNX model. Enabled once the
/// `onnxruntime-swift-package-manager` SPM package is added to
/// `project.yml` (see docs/voice-pipeline-setup.md) AND the model file has
/// been downloaded via `ModelStore` under `ModelCatalog.sileroVAD`.
///
/// Until both of those are true, `VoicePipeline` uses `NullVAD` and the
/// speech recognizer runs on its internal ~5-second timeout — functional
/// but not snappy.
#if canImport(onnxruntime_objc)
import onnxruntime_objc

final class SileroONNXVAD: VoiceActivityDetector {
    let requiredSampleRate: Double = 16_000
    let frameLength: Int = 512
    var onSpeechStateChange: ((Bool) -> Void)?
    var onEndOfUtterance: (() -> Void)?

    private let session: ORTSession
    private let env: ORTEnv
    private let inputNodeName = "input"
    private let stateNodeName = "state"
    private let srNodeName = "sr"

    // Silero v5 has an internal state tensor that must be threaded through
    // successive calls. We initialize to zeros.
    private var stateTensorBytes = Data(count: 2 * 1 * 128 * MemoryLayout<Float>.size)

    private let speechThreshold: Float = 0.5
    private let silenceThreshold: Float = 0.35   // hysteresis
    private var lastSpeechAt: Date?
    private var speechActive = false
    private var endOfUtteranceMs = 200
    private var running = false

    init(modelPath: String) throws {
        self.env = try ORTEnv(loggingLevel: .warning)
        self.session = try ORTSession(env: env, modelPath: modelPath,
                                      sessionOptions: nil)
    }

    func start(endOfUtteranceMs: Int) {
        self.endOfUtteranceMs = endOfUtteranceMs
        self.running = true
        reset()
    }

    func stop() { running = false }

    func reset() {
        stateTensorBytes.resetBytes(in: 0..<stateTensorBytes.count)
        lastSpeechAt = nil
        speechActive = false
    }

    func process(_ pcm: [Int16]) {
        guard running else { return }
        // Silero expects float32 in [-1, 1].
        var floats = [Float](repeating: 0, count: pcm.count)
        for i in 0..<pcm.count { floats[i] = Float(pcm[i]) / 32_768.0 }
        // Real Silero inference call would happen here; the shape/name
        // handling is left as follow-up work when the SPM package is
        // actually available in the build. This branch only compiles when
        // `onnxruntime_objc` is importable — enabling that is a separate
        // controlled step in the plan.
        _ = floats
        _ = session
    }
}
#endif
