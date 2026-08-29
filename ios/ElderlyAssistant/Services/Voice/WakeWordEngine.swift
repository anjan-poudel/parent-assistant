import Foundation
import AVFoundation

/// A wake-word engine consumes a stream of PCM audio frames and calls its
/// `onDetection` handler whenever the trained keyword ("Hey Sahayak") fires.
///
/// The concrete implementation is Porcupine (`PorcupineWakeWordEngine`), used
/// only when the Porcupine Swift package is added to the project AND a
/// Picovoice access key is configured. When neither is present, a
/// `NullWakeWordEngine` is used so the rest of the pipeline still compiles
/// and runs — you just have to trigger detection manually via
/// `VoicePipeline.simulateWakeWordDetection()` (wired to a debug button in
/// `ContentView`).
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

/// No-op engine used when Porcupine is not available. Lets the rest of the
/// pipeline (audio capture, permissions, STT, command routing) run and be
/// tested end-to-end via the debug "Simulate wake word" button.
final class NullWakeWordEngine: WakeWordEngine {
    let requiredSampleRate: Double = 16_000
    let frameLength: Int = 512
    var onDetection: (() -> Void)?

    func start() throws {}
    func stop() {}
    func process(_ pcm: [Int16]) { /* intentionally does nothing */ }
}

// MARK: - Porcupine implementation (guarded)

/// Real wake-word detector using Picovoice's on-device Porcupine engine.
///
/// To enable:
///  1. Add the Porcupine iOS Swift package to `project.yml` (see comment
///     block in that file), run `./build.sh generate` to refresh the
///     Xcode project.
///  2. Sign up at https://console.picovoice.ai/ (free tier) and copy your
///     access key. Set it via the `PICOVOICE_ACCESS_KEY` env var at build
///     time OR paste it into `voice-config.plist` (git-ignored).
///  3. Train the "Hey Sahayak" wake word in the Picovoice Console, download
///     the iOS `.ppn` file, and drop it into
///     `ios/ElderlyAssistant/Resources/hey-sahayak_ios.ppn`.
///  4. Rebuild. `PorcupineWakeWordEngine` will now compile and be picked up
///     by `VoicePipeline.makeWakeWordEngine()`.
#if canImport(Porcupine)
import Porcupine

final class PorcupineWakeWordEngine: WakeWordEngine {
    let requiredSampleRate: Double = 16_000
    var frameLength: Int { Int(Porcupine.frameLength) }
    var onDetection: (() -> Void)?

    private let porcupine: Porcupine
    private let onDetectionQueue: DispatchQueue

    init(accessKey: String, keywordPath: String,
         sensitivity: Float = 0.6,
         onDetectionQueue: DispatchQueue = .main) throws {
        self.porcupine = try Porcupine(
            accessKey: accessKey,
            keywordPath: keywordPath,
            sensitivity: sensitivity
        )
        self.onDetectionQueue = onDetectionQueue
    }

    deinit {
        porcupine.delete()
    }

    func start() throws { /* Porcupine is stateless; nothing to start */ }
    func stop() { /* likewise */ }

    func process(_ pcm: [Int16]) {
        do {
            let index = try porcupine.process(pcm: pcm)
            if index >= 0 {
                onDetectionQueue.async { [weak self] in
                    self?.onDetection?()
                }
            }
        } catch {
            // Silently drop malformed frames — the tap may hand us short
            // buffers during route changes.
        }
    }
}
#endif
