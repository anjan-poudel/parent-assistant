import Foundation
import AVFoundation

/// Press-to-record capture for voice-fingerprint enrollment
/// ([VOICE-SETTINGS]). Captures 16 kHz int16 mono PCM — the exact format
/// `SpeakerBiometricService.enroll` consumes — using the pipeline's own
/// mic-tap conversion recipe (`VoicePipeline.installMicTap`).
///
/// Tap-slot doctrine (same as `SearchPhraseCapture`, which this mirrors):
/// the voice pipeline and any leaf capture share ONE audio engine with a
/// single tap slot, so they must never run at the same time. The caller
/// (through `VoicePipelineSuspending`, i.e. AppCoordinator) suspends the
/// pipeline BEFORE `startCapture` and resumes it AFTER `stopCapture`;
/// this type never touches the pipeline itself.
///
/// Audio session: `AudioSessionManager.activate` asks mic permission at
/// the point of use, configures the same `.playAndRecord` +
/// `.measurement` preset the pipeline uses, and `deactivate` restores
/// the stack for the coordinator's pipeline resume.
///
/// Raw audio rules (research doc §10, enforced here too): samples exist
/// only in memory, are handed to the enrollment service as a transient
/// parameter, and are discarded by this type at the next `startCapture`.
/// Nothing is written to disk, nothing is retained, nothing is logged.
final class VoiceEnrollmentRecorder: VoiceSampleRecorder {

    private let audioEngine: AVAudioEngine
    private let audioSession: AudioSessionManager
    private let processingQueue = DispatchQueue(label: "voice.enrollment.recorder")

    /// Samples captured since the last `startCapture` (16 kHz int16
    /// mono), appended from the tap's processing queue.
    private var collected: [Int16] = []
    private var tapInstalled = false

    init(audioEngine: AVAudioEngine, audioSession: AudioSessionManager) {
        self.audioEngine = audioEngine
        self.audioSession = audioSession
    }

    /// Activates the session (mic permission asked here, at the point of
    /// use), installs the ONLY tap, and starts the engine. The caller
    /// has already suspended the voice pipeline. Throws the honest
    /// `VoiceSampleCaptureError` states; completion on the main queue.
    func startCapture() async throws {
        // Explicit continuation type: the multi-site resume(throwing:)
        // bodies made the compiler's generic inference unstable between
        // batch and single-file compilation modes.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            audioSession.activate { [weak self] result in
                guard let self else {
                    continuation.resume(throwing: VoiceSampleCaptureError.audioUnavailable)
                    return
                }
                switch result {
                case .failure(.microphonePermissionDenied):
                    continuation.resume(throwing: VoiceSampleCaptureError.microphonePermissionDenied)
                case .failure:
                    continuation.resume(throwing: VoiceSampleCaptureError.audioUnavailable)
                case .success:
                    // Hard repo rule (2026-09-02): never touch inputNode
                    // without the input-availability check — accessing it
                    // with the audio server unresponsive ABORTS the
                    // process (AudioToolbox _ReportRPCTimeout).
                    guard self.audioSession.isInputAvailable else {
                        self.audioSession.deactivate()
                        continuation.resume(throwing: VoiceSampleCaptureError.noAudioInput)
                        return
                    }
                    do {
                        try self.installTapAndStart()
                        continuation.resume(returning: ())
                    } catch {
                        self.teardownCapture()
                        continuation.resume(throwing: VoiceSampleCaptureError.audioUnavailable)
                    }
                }
            }
        }
    }

    /// Tears the capture down and returns the recorded samples (may be
    /// empty — the quality gates will refuse that honestly).
    func stopCapture() -> [Int16] {
        teardownCapture()
        return processingQueue.sync { collected }
    }

    // MARK: - Tap installation (VoicePipeline.installMicTap recipe)

    private func installTapAndStart() throws {
        let input = audioEngine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw VoiceSampleCaptureError.audioUnavailable
        }

        processingQueue.sync { collected = [] }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.processingQueue.async {
                self.handleAudioBuffer(buffer, converter: converter, target: targetFormat)
            }
        }
        tapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer,
                                   converter: AVAudioConverter,
                                   target: AVAudioFormat) {
        let capacity = AVAudioFrameCount(target.sampleRate * 0.1)
        guard let converted = AVAudioPCMBuffer(pcmFormat: target,
                                               frameCapacity: capacity) else { return }
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        guard status == .haveData || status == .inputRanDry, error == nil,
              let channelData = converted.int16ChannelData?.pointee else { return }
        let frameCount = Int(converted.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        collected.append(contentsOf: samples)
    }

    /// Remove the tap (under the input-availability guard), stop the
    /// engine, deactivate the session — the same teardown order
    /// `SearchPhraseCapture.finish` uses so the coordinator can resume
    /// the pipeline on a quiet audio stack.
    private func teardownCapture() {
        if tapInstalled, audioSession.isInputAvailable {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        tapInstalled = false
        if audioEngine.isRunning { audioEngine.stop() }
        audioSession.deactivate()
    }
}
