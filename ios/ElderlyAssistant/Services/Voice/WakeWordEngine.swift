import Foundation
import AVFoundation

/// A wake-word engine consumes a stream of PCM audio frames and calls its
/// `onDetection` handler whenever the trained keyword ("ये कान्छी") fires.
///
/// The real implementation is the sherpa-onnx keyword spotter
/// (`SherpaKWSWakeWordEngine`, Services/Voice/SherpaKWSWakeWordEngine.swift),
/// used when the Settings → "Voice activation" toggle is ON and the KWS
/// model directory is bundled — see `WakeWordEngineSelection` and
/// tools/fetch-kws-model.sh. When any of that is missing, a
/// `NullWakeWordEngine` is used so the rest of the pipeline still compiles
/// and runs exactly as before the wake-word feature — Talk button and
/// `VoicePipeline.simulateWakeWordDetection()` untouched. While the engine
/// is live, `VoicePipeline` consults `WakeWordActivityGate` before feeding
/// it mic audio and before acting on detections (self-hearing mitigation,
/// 2026-09-06).
protocol WakeWordEngine: AnyObject {
    /// Sample rate the engine expects for input audio. The audio tap must
    /// convert to this rate before calling `process(_:)`.
    var requiredSampleRate: Double { get }

    /// Number of samples per processing frame. The tap must chunk audio into
    /// this frame length before calling `process(_:)`.
    var frameLength: Int { get }

    /// Handler invoked on the main queue when the keyword is detected.
    var onDetection: (() -> Void)? { get set }

    func start() throws
    func stop()

    /// Process a single frame of int16-PCM samples at `requiredSampleRate`.
    func process(_ pcm: [Int16])
}

// MARK: - Null implementation (compile-safe fallback)

/// No-op engine used when no real wake-word engine could be built (toggle
/// off, or no KWS model in this build). Lets the rest of the pipeline
/// (audio capture, permissions, STT, command routing) run and be tested
/// end-to-end via the debug "Simulate wake word" button. It is NEVER a
/// silent stub: selection records why it was chosen, and the Settings →
/// "Voice activation" screen derives its status from that same truth.
final class NullWakeWordEngine: WakeWordEngine {
    let requiredSampleRate: Double = 16_000
    let frameLength: Int = 512
    var onDetection: (() -> Void)?

    func start() throws {}
    func stop() {}
    func process(_ pcm: [Int16]) { /* intentionally does nothing */ }
}
