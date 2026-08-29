import Foundation
import Speech
import AVFoundation

/// Captures a command utterance after wake-word detection and returns a
/// transcript. Implementations run **on-device only** (constitution §1).
///
/// The recognizer supports two audio-supply modes so it works with both
/// SFSpeechRecognizer (streaming, likes owning the tap) and Whisper
/// (buffer-based, needs the caller to hand it a whole utterance):
///
/// - **Owned-tap mode** (`ownsAudioCapture == true`): call `startListening`
///   and the recognizer installs its own input tap. VoicePipeline uses this
///   when no VAD is available.
/// - **Push mode** (`ownsAudioCapture == false`): call `startListening`,
///   then feed audio via `feed(_:)`, then call `finish()` when the user
///   stops talking. VoicePipeline uses this when VAD-gated capture is
///   available so the same audio can drive both the VAD and the STT
///   without contending for the input node's single tap slot.
protocol SpeechRecognizerProtocol: AnyObject {
    /// Whether the recognizer is available (permission granted + model /
    /// locale ready).
    var isAvailable: Bool { get }

    /// True when this recognizer installs and owns the mic tap itself. If
    /// false, the caller must push audio via `feed(_:)` and call `finish()`
    /// to signal end-of-utterance.
    var ownsAudioCapture: Bool { get }

    func requestAuthorization(_ callback: @escaping (Bool) -> Void)

    /// Begin recognition. `timeout` is a hard upper bound; VAD-driven
    /// callers should also call `finish()` when they detect silence.
    /// Completion runs on the main queue.
    func startListening(timeout: TimeInterval,
                        completion: @escaping (Result<String, RecognitionError>) -> Void)

    /// Push mode only. Ignored in owned-tap mode.
    func feed(_ buffer: AVAudioPCMBuffer)

    /// Push mode only. Signals end-of-utterance so the recognizer can
    /// finalise. Ignored in owned-tap mode (the built-in timeout does the
    /// same job).
    func finish()

    func cancel()
}

enum RecognitionError: Error {
    case notAuthorized
    case localeUnsupported
    case audioEngineFailed(Error)
    case recognitionFailed(Error)
    case timedOut
    case cancelled
}

// MARK: - SFSpeechRecognizer implementation (dual-mode)

final class OnDeviceSpeechRecognizer: SpeechRecognizerProtocol {
    private let recognizer: SFSpeechRecognizer?
    private let audioEngine: AVAudioEngine
    private let observabilityBus: ObservabilityBus
    private let pushMode: Bool

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timeoutWork: DispatchWorkItem?
    /// True while this recognizer owns the mic tap (owned-tap mode +
    /// currently listening). Only when this is true will `teardownTap`
    /// touch the shared audio engine — otherwise we'd destroy the
    /// VoicePipeline's shared wake-word tap on a hot-swap.
    private var installedTap = false

    var isAvailable: Bool {
        recognizer?.isAvailable == true &&
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    let ownsAudioCapture: Bool

    init(locale: Locale = Locale(identifier: "en-US"),
         audioEngine: AVAudioEngine,
         observabilityBus: ObservabilityBus,
         pushMode: Bool = false) {
        // Nepali is not supported by SFSpeechRecognizer on-device (as of iOS
        // 17). The scaffold uses en-US so the pipeline is testable today;
        // production Nepali comes via `WhisperSpeechRecognizer`.
        self.recognizer = SFSpeechRecognizer(locale: locale)
        self.audioEngine = audioEngine
        self.observabilityBus = observabilityBus
        self.pushMode = pushMode
        self.ownsAudioCapture = !pushMode
    }

    func requestAuthorization(_ callback: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { callback(status == .authorized) }
        }
    }

    func startListening(timeout: TimeInterval,
                        completion: @escaping (Result<String, RecognitionError>) -> Void) {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            completion(.failure(.localeUnsupported))
            return
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            completion(.failure(.notAuthorized))
            return
        }

        cancel()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        // Owned-tap mode installs a tap on the input node. Push mode leaves
        // the tap alone — VoicePipeline attaches one and pushes buffers via
        // `feed(_:)`.
        if !pushMode {
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            installedTap = true
            do {
                audioEngine.prepare()
                try audioEngine.start()
            } catch {
                teardownTap()
                completion(.failure(.audioEngineFailed(error)))
                return
            }
        }

        var didFinish = false
        let finishOnce: (Result<String, RecognitionError>) -> Void = { [weak self] result in
            guard !didFinish else { return }
            didFinish = true
            self?.teardownTap()
            self?.timeoutWork?.cancel()
            DispatchQueue.main.async { completion(result) }
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard self != nil else { return }
            if let result = result, result.isFinal {
                let text = result.bestTranscription.formattedString
                self?.emit(outcome: "success")
                finishOnce(.success(text))
            } else if let error = error {
                self?.emit(outcome: "failure", errorCode: "recognition_failed")
                finishOnce(.failure(.recognitionFailed(error)))
            }
        }

        let timeoutWork = DispatchWorkItem { [weak self] in
            self?.request?.endAudio()
            self?.emit(outcome: "timeout", errorCode: "timed_out")
            finishOnce(.failure(.timedOut))
        }
        self.timeoutWork = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard pushMode else { return }
        request?.append(buffer)
    }

    func finish() {
        guard pushMode else { return }
        request?.endAudio()
    }

    func cancel() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        teardownTap()
        timeoutWork?.cancel()
        timeoutWork = nil
    }

    private func teardownTap() {
        // Only tear down what we ourselves installed. If this recognizer
        // never started a listening session (e.g. it's the fallback STT
        // being hot-swapped OUT before it ever ran), the shared audio
        // engine + wake-word tap belong to VoicePipeline and must stay up.
        guard !pushMode, installedTap else { return }
        installedTap = false
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func emit(outcome: String, errorCode: String? = nil) {
        observabilityBus.emit(ObservabilityEvent(
            component: "speech_recognizer",
            eventType: "recognize_utterance",
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: [:]
        ))
    }
}
