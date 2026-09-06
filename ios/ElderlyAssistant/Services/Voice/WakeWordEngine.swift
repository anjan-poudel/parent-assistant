import Foundation
import AVFoundation

/// A wake-word engine consumes a stream of PCM audio frames and calls its
/// `onDetection` handler whenever the trained keyword ("Hey Sahayak") fires.
///
/// The concrete implementation is Porcupine (`PorcupineWakeWordEngine`), used
/// only when the Porcupine Swift package is added to the project, the
/// Settings → "Voice activation" toggle is ON, an access key is configured,
/// and the trained `.ppn` is bundled — see `WakeWordEngineSelection` and
/// docs/wake-word-setup.md. When any of that is missing, a
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
/// To enable (2026-09-06, full family-facing steps in docs/wake-word-setup.md):
///  1. Uncomment the Porcupine SPM package in `ios/project.yml`, run
///     `./build.sh generate` to refresh the Xcode project.
///  2. A family member pastes the Picovoice access key into Settings →
///     "Voice activation" (stored in the Keychain via
///     `WakeWordAccessKeyStore`) — or a team build can embed it as the
///     `PicovoiceAccessKey` Info.plist value. The app never ships a key.
///  3. Train the "Hey Sahayak" wake word in the Picovoice Console, download
///     the iOS `.ppn` file, and drop it into
///     `ios/ElderlyAssistant/Resources/hey-sahayak_ios.ppn`.
///  4. Rebuild. `PorcupineWakeWordEngine` will now compile, and
///     `AppCoordinator.makeWakeWordEngine()` builds it when the Settings
///     toggle (default ON) is enabled — status shown on the Settings screen.
///
/// This file's `#if canImport(Porcupine)` guard (and its mirror,
/// `AppCoordinator.isWakeWordRuntimeLinked`) is what keeps a build honest:
/// no Porcupine package, no real engine, no "Active" claim.
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
