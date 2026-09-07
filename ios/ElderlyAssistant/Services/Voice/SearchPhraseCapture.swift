import Foundation
import AVFoundation

/// Pure silence/voice endpoint decision for the one-shot capture below
/// (voice-contact-search, 2026-09-07). Unit-testable without audio.
///
/// Feeds per-buffer RMS windows; emits:
///  - `.endUtterance` once the user has spoken at least
///    `minSpeechSeconds` and then stayed quiet for
///    `trailingSilenceSeconds` — the caller should finalize the STT;
///  - `.gaveUpWaitingForSpeech` when nothing but silence arrived for
///    `maxSilenceBeforeSpeechSeconds` — the caller should abort;
///  - `.keepListening` otherwise. Short blips (below
///    `minSpeechSeconds`) followed by silence do NOT end the utterance —
///    a cough or a false trigger must not cut off a name.
struct SilenceEndpoint {
    /// RMS below this counts as silence (linear Float samples).
    let speechThreshold: Float
    /// Total speech needed before trailing silence may end the capture.
    let minSpeechSeconds: TimeInterval
    /// Quiet run after real speech that ends the utterance.
    let trailingSilenceSeconds: TimeInterval
    /// Quiet run before ANY speech that aborts the capture.
    let maxSilenceBeforeSpeechSeconds: TimeInterval

    enum Signal: Equatable {
        case keepListening
        case endUtterance
        case gaveUpWaitingForSpeech
    }

    private(set) var speechSeconds: TimeInterval = 0
    private(set) var quietSeconds: TimeInterval = 0

    mutating func feed(rms: Float, duration: TimeInterval) -> Signal {
        if rms >= speechThreshold {
            speechSeconds += duration
            quietSeconds = 0
            return .keepListening
        }
        quietSeconds += duration
        if speechSeconds >= minSpeechSeconds {
            return quietSeconds >= trailingSilenceSeconds ? .endUtterance : .keepListening
        }
        return quietSeconds >= maxSilenceBeforeSpeechSeconds ? .gaveUpWaitingForSpeech : .keepListening
    }
}

/// One-shot "search phrase" capture for the Phone leaf's mic button
/// (voice-contact-search, 2026-09-07). Refinement-only by design: the
/// PRIMARY hands-free path is the voice command through `CommandRouter`
/// ("मैयाको फोन नम्बर खोज"); this button is for when the elder is
/// already ON the Phone screen and prefers to speak the name.
///
/// Why a dedicated type instead of reusing `VoicePipeline`'s capture:
/// the pipeline owns one always-on mic tap on the shared engine with a
/// single-tap slot (its own code removes any tap before installing, and
/// the owned-tap STT lifecycle that tore the tap down wedged the audio
/// server — 7 crash reports, 2026-09-02, see `OnDeviceSpeechRecognizer`).
/// So a leaf capture runs while the pipeline is SUSPENDED
/// (coordinator stop → capture → coordinator start — the same cycle
/// `recoverVoiceCycle` exercises): this capture installs the only tap,
/// activates the session itself, and tears both down before the
/// coordinator restarts the pipeline.
///
/// The recognizer is the coordinator's push-mode SFSpeech fallback
/// (`OnDeviceSpeechRecognizer`): `feed(_:)`/`finish()`/`cancel()` are
/// honored without the recognizer ever touching the shared tap (its
/// `cancel()` nils the request, so in-flight feeds become no-ops).
/// Locale caveat is the existing one — SFSpeech has no Nepali (as of
/// iOS 17); Devanagari voice search stays on the Home talk flow.
/// Permission is asked at the point of use, never on appear.
///
/// All callbacks run on the main queue; `start`/`cancel`/completion are
/// main-queue only and the completion fires exactly once.
final class SearchPhraseCapture {

    enum Failure: Error, Equatable {
        case notAuthorized
        case noAudioInput
        case audioUnavailable
        /// The assistant's voice pipeline is mid-turn or mid-reply —
        /// transient; the caller should reset silently, never alarm.
        case busy
        case noSpeech
        case recognitionFailed
        case cancelled
    }

    private enum Phase {
        case idle
        case listening
    }

    /// Fixed upper bound for one utterance (a name/number is short).
    /// Normally `SilenceEndpoint` ends the capture far earlier; this is
    /// the recognizer-timeout safety floor, mirroring
    /// `VoicePipeline.captureTimeoutSeconds`.
    private static let maxSpeechSeconds: TimeInterval = 8

    private let audioSession: AudioSessionManager
    private let audioEngine: AVAudioEngine
    private let recognizer: SpeechRecognizerProtocol

    private var phase: Phase = .idle
    private var endpoint = SilenceEndpoint(speechThreshold: 0.012,
                                           minSpeechSeconds: 0.3,
                                           trailingSilenceSeconds: 1.0,
                                           maxSilenceBeforeSpeechSeconds: 3.0)
    /// True after the endpoint fired `.endUtterance` — fires `finish()`
    /// once; the endpoint keeps reporting endUtterance on every quiet
    /// buffer until teardown (same window `VoicePipeline` lives with).
    private var didEndUtterance = false
    /// True when the capture self-aborted for total silence (`finish`
    /// reports `.noSpeech`, NOT `.cancelled` — the caller must be able
    /// to tell an auto-abort from a user-tap cancel).
    private var gaveUpWaitingForSpeech = false
    /// True on user cancel (second tap / leaf disappeared).
    private var cancelled = false
    /// True only between `installTap` and `finish` teardown — removal is
    /// skipped when we never installed a tap (auth-denied paths) so we
    /// can never remove someone else's tap.
    private var tapInstalled = false
    private var completion: ((Result<String, Failure>) -> Void)?

    init(audioSession: AudioSessionManager,
         audioEngine: AVAudioEngine,
         recognizer: SpeechRecognizerProtocol) {
        self.audioSession = audioSession
        self.audioEngine = audioEngine
        self.recognizer = recognizer
    }

    // MARK: - Public API

    /// Captures one phrase. `completion` runs on the main queue exactly
    /// once. Precondition: the coordinator has suspended the voice
    /// pipeline (engine stopped, tap removed) — see the file doc.
    func start(completion: @escaping (Result<String, Failure>) -> Void) {
        assert(Thread.isMainThread)
        guard phase == .idle, self.completion == nil else { return }
        self.completion = completion
        cancelled = false
        gaveUpWaitingForSpeech = false
        didEndUtterance = false
        tapInstalled = false
        endpoint = SilenceEndpoint(speechThreshold: 0.012,
                                   minSpeechSeconds: 0.3,
                                   trailingSilenceSeconds: 1.0,
                                   maxSilenceBeforeSpeechSeconds: 3.0)

        // Speech permission is the recognizer's to ask; the session's
        // activate() then asks mic permission (AudioSessionManager).
        recognizer.requestAuthorization { [weak self] granted in
            guard let self else { return }
            guard !self.cancelled else {
                self.finish(.failure(.cancelled))
                return
            }
            guard granted, self.recognizer.isAvailable else {
                self.finish(.failure(.notAuthorized))
                return
            }
            guard self.audioSession.isInputAvailable else {
                // Accessing inputNode with the audio server unresponsive
                // ABORTS the process (_ReportRPCTimeout) — same guard as
                // VoicePipeline.
                self.finish(.failure(.noAudioInput))
                return
            }
            self.activateSessionAndListen()
        }
    }

    /// Ends the capture early (second tap on the mic button while
    /// listening, or the leaf disappeared). A live recognition is
    /// cancelled — no transcript is harvested from a cancelled task.
    func cancel() {
        assert(Thread.isMainThread)
        guard phase != .idle else {
            // Nothing started yet (or already finished) — still surface
            // a cancelled outcome so the coordinator's cleanup ordering
            // stays uniform.
            if completion != nil {
                finish(.failure(.cancelled))
            }
            return
        }
        cancelled = true
        recognizer.cancel()
    }

    // MARK: - Capture lifecycle

    private func activateSessionAndListen() {
        audioSession.activate { [weak self] result in
            guard let self else { return }
            guard !self.cancelled else {
                self.finish(.failure(.cancelled))
                return
            }
            switch result {
            case .failure(.microphonePermissionDenied):
                self.finish(.failure(.notAuthorized))
            case .failure:
                self.finish(.failure(.audioUnavailable))
            case .success:
                self.installTapAndStart()
            }
        }
    }

    private func installTapAndStart() {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Our tap is the ONLY tap here (pipeline suspended) — but clear
        // any straggler so a stale tap can't double-feed the recognizer.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognizer.feed(buffer)
            let rms = Self.rms(of: buffer)
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            DispatchQueue.main.async {
                guard self.phase == .listening,
                      !self.didEndUtterance, !self.gaveUpWaitingForSpeech else { return }
                switch self.endpoint.feed(rms: rms, duration: duration) {
                case .endUtterance:
                    self.didEndUtterance = true
                    self.recognizer.finish()
                case .gaveUpWaitingForSpeech:
                    // Nothing but silence for the whole window — no
                    // transcript to harvest; cancelling keeps the
                    // recognizer from grinding to its own timeout.
                    self.gaveUpWaitingForSpeech = true
                    self.recognizer.cancel()
                case .keepListening:
                    break
                }
            }
        }
        tapInstalled = true
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            finish(.failure(.audioUnavailable))
            return
        }
        phase = .listening
        recognizer.startListening(timeout: Self.maxSpeechSeconds) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self.finish(.failure(.noSpeech))
                } else {
                    self.finish(.success(trimmed))
                }
            case .failure(let error):
                self.finish(.failure(self.mapFailure(error)))
            }
        }
    }

    private func mapFailure(_ error: RecognitionError) -> Failure {
        switch error {
        case .notAuthorized, .localeUnsupported:
            return .notAuthorized
        case .timedOut:
            // Either total silence (endpoint already gave up first) or an
            // over-long utterance the endpoint somehow missed — either
            // way there is no transcript to harvest.
            return .noSpeech
        case .audioEngineFailed:
            return .audioUnavailable
        case .recognitionFailed, .cancelled:
            if gaveUpWaitingForSpeech { return .noSpeech }
            if cancelled { return .cancelled }
            return .recognitionFailed
        }
    }

    /// Tear down (tap + engine + session) then deliver — main queue.
    /// Order mirrors VoicePipeline.stop: remove the tap under the
    /// input-availability guard, stop the engine, deactivate the session
    /// we activated, THEN call the completion so the coordinator can
    /// restart the pipeline on a quiet audio stack.
    private func finish(_ result: Result<String, Failure>) {
        assert(Thread.isMainThread)
        guard completion != nil else { return }
        phase = .idle
        if tapInstalled, audioSession.isInputAvailable {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        tapInstalled = false
        if audioEngine.isRunning { audioEngine.stop() }
        audioSession.deactivate()
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    // MARK: - Audio helpers

    /// Linear RMS over the buffer's first channel plane (Float32, the
    /// input node's deinterleaved format). The endpoint threshold is
    /// tuned for this scale.
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0],
              buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        let samples = UnsafeBufferPointer(start: channelData, count: frames)
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(frames)).squareRoot()
    }
}
