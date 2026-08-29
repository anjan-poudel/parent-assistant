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
/// It is intentionally conservative: any reasonably loud frame is speech,
/// and end-of-utterance fires only after a sustained quiet tail.
final class EnergyVAD: VoiceActivityDetector {
    let requiredSampleRate: Double = 16_000
    let frameLength: Int = 512
    var onSpeechStateChange: ((Bool) -> Void)?
    var onEndOfUtterance: (() -> Void)?

    private let speechRMSThreshold: Float
    private let silenceRMSThreshold: Float
    private var running = false
    private var speechActive = false
    private var quietFrames = 0
    private var requiredQuietFrames = 8
    private var hasReportedEnd = false

    init(speechRMSThreshold: Float = 0.018,
         silenceRMSThreshold: Float = 0.010) {
        self.speechRMSThreshold = speechRMSThreshold
        self.silenceRMSThreshold = silenceRMSThreshold
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
        quietFrames = 0
        hasReportedEnd = false
    }

    func process(_ pcm: [Int16]) {
        guard running, !pcm.isEmpty, !hasReportedEnd else { return }
        let rms = Self.rms(pcm)

        if rms >= speechRMSThreshold {
            quietFrames = 0
            if !speechActive {
                speechActive = true
                onSpeechStateChange?(true)
            }
            return
        }

        guard speechActive, rms <= silenceRMSThreshold else { return }
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
