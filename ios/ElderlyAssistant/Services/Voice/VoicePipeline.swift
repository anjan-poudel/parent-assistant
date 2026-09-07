import Foundation
import AVFoundation

/// Orchestrates the always-on voice loop:
///
///  audio session → mic tap → wake-word engine → (VAD →) speech recognizer → router
///
/// State machine:
///
///   idle → capturingCommand → routing → idle
///
/// The mic tap is installed once and lives for the pipeline's lifetime. In
/// `.idle` it feeds the wake-word engine; in `.capturingCommand` it either
/// feeds the STT directly (owned-tap mode) or feeds VAD + STT (push mode).
final class VoicePipeline {

    enum State: Equatable {
        case stopped
        case idle
        case capturingCommand
        case processing         // audio closed, STT running inference
        case routing
        case error(String)
    }

    @Published private(set) var state: State = .stopped
    /// Called with a short human-readable failure whenever the STT step
    /// itself errors (permission, timeout, engine failure). ContentView
    /// surfaces this so the user can see what went wrong instead of a
    /// silent no-op.
    var onSTTError: ((String) -> Void)?

    private let audioSession: AudioSessionManager
    private let wakeWordEngine: WakeWordEngine
    /// Consulted (on the processing queue) before every idle-state audio
    /// chunk reaches the wake-word engine, and before inbound wake
    /// detections start a capture (wake word #4, 2026-09-06) — see
    /// `WakeWordActivityGate` for what closes it and why. In short:
    ///
    ///  - Self-hearing mitigation: while the assistant's own TTS reply is
    ///    playing, the mic hears it — the audio session is `.playAndRecord`
    ///    with `.measurement` mode and NO acoustic echo cancellation
    ///    (AudioSessionManager) — so a reply containing the phrase "Hey
    ///    Sahayak" could otherwise wake the assistant mid-speech. We
    ///    suppress here rather than switching the global audio-session
    ///    mode: a mode/AEC change is a regression risk for the always-on
    ///    tap and the recognizers that share it.
    ///  - The Settings "listen for Hey Sahayak" toggle: turning listening
    ///    OFF must stop keyword detection immediately, not at the next
    ///    launch (audio feeding stops, so the engine can never fire).
    ///
    /// The Talk button (`simulateWakeWordDetection`) is HUMAN intent and
    /// must keep working with listening switched off — it consults only
    /// the gate's `allowsWakeDetection` half (speaking), never the
    /// enable half. Nil = always open, exactly the pre-wake-word behavior.
    private let wakeWordGate: WakeWordActivityGate?
    private var speechRecognizer: SpeechRecognizerProtocol
    private var vad: VoiceActivityDetector?
    private let router: CommandRouter
    private let observabilityBus: ObservabilityBus

    private let audioEngine: AVAudioEngine
    private let processingQueue = DispatchQueue(label: "voice.pipeline.processing",
                                                qos: .userInteractive)

    /// Max time the user can keep talking before capture is force-ended
    /// (VAD normally ends it much sooner). Also the `timeout` handed to
    /// `SpeechRecognizerProtocol.startListening`.
    private static let captureTimeoutSeconds: TimeInterval = 8.0
    /// Extra grace period, ON TOP of `captureTimeoutSeconds`, before the
    /// "stuck in listening" watchdog force-cancels the recognizer. Must
    /// comfortably exceed the slowest recognizer's own worst-case latency
    /// (a cloud recognizer's full network round-trip, not just on-device
    /// inference) — see the wiring comment at the watchdog's call site.
    private static let wedgeGuardMarginSeconds: TimeInterval = 10.0
    /// Trailing silence (ms) the VAD must observe before declaring the
    /// utterance over. Raised 200 -> 900 on 2026-09-07: the 200 ms
    /// hangover was shorter than a natural mid-utterance pause for
    /// elderly speakers (0.5-0.7 s — a breath, a word-search, a slow
    /// clause), so pauses cut captures in half; 900 ms (29 frames at
    /// 32 ms/frame) both survives those pauses and still ends a finished
    /// utterance ~0.9 s after the last word — well inside the 8 s capture
    /// cap and the target "end within ~0.8-1.5 s of trailing silence".
    /// Long enough is cheap here: the VAD only fires once per capture,
    /// and the recognizer simply transcribes everything up to that point.
    private static let endOfUtteranceMs: Int = 900
    private var pcmBuffer: [Int16] = []
    /// Held only during the VAD-gated capture phase — how far past silence
    /// onset we've counted before firing `finish()`.
    private var silenceCounter: Int = 0

    init(audioSession: AudioSessionManager,
         audioEngine: AVAudioEngine,
         wakeWordEngine: WakeWordEngine,
         wakeWordGate: WakeWordActivityGate? = nil,
         speechRecognizer: SpeechRecognizerProtocol,
         voiceActivityDetector: VoiceActivityDetector? = nil,
         router: CommandRouter,
         observabilityBus: ObservabilityBus) {
        self.audioSession = audioSession
        self.audioEngine = audioEngine
        self.wakeWordEngine = wakeWordEngine
        self.wakeWordGate = wakeWordGate
        self.speechRecognizer = speechRecognizer
        self.vad = voiceActivityDetector
        self.router = router
        self.observabilityBus = observabilityBus

        self.wakeWordEngine.onDetection = { [weak self] in
            self?.handleWakeDetected()
        }
        wireVADCallbacks()
    }

    private func wireVADCallbacks() {
        vad?.onEndOfUtterance = { [weak self] in
            guard let self, self.state == .capturingCommand else { return }
            self.emit("vad_end_of_utterance", outcome: "success")
            self.speechRecognizer.finish()
        }
    }

    // MARK: - Public API

    /// Hot-swap the STT. Used once WhisperSpeechRecognizer's model download
    /// completes: we upgrade from SFSpeechRecognizer to Whisper without
    /// tearing down the wake-word loop.
    func setSpeechRecognizer(_ newRecognizer: SpeechRecognizerProtocol) {
        speechRecognizer.cancel()
        speechRecognizer = newRecognizer
        emit("stt_hot_swap", outcome: "success")
    }

    func setVoiceActivityDetector(_ newVAD: VoiceActivityDetector?) {
        vad?.stop()
        vad = newVAD
        wireVADCallbacks()
        emit("vad_hot_swap", outcome: "success")
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        audioSession.activate { [weak self] result in
            switch result {
            case .failure(let err):
                self?.state = .error("audio session: \(err)")
                completion(.failure(err))
            case .success:
                self?.speechRecognizer.requestAuthorization { granted in
                    guard granted else {
                        self?.state = .error("speech recognition denied")
                        completion(.failure(RecognitionError.notAuthorized))
                        return
                    }
                    do {
                        try self?.installMicTap()
                        try self?.wakeWordEngine.start()
                        self?.state = .idle
                        self?.emit("pipeline_started", outcome: "success")
                        completion(.success(()))
                    } catch {
                        self?.state = .error("mic tap: \(error)")
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func stop() {
        wakeWordEngine.stop()
        vad?.stop()
        speechRecognizer.cancel()
        if audioEngine.isRunning { audioEngine.stop() }
        // inputNode aborts the whole process when the audio server is
        // unresponsive (AudioToolbox _ReportRPCTimeout) — never touch it
        // without the input-availability check.
        if audioSession.isInputAvailable {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        audioSession.deactivate()
        state = .stopped
        emit("pipeline_stopped", outcome: "success")
    }

    /// Debug entry point.
    func simulateWakeWordDetection() {
        handleWakeDetected()
    }

    // MARK: - Tap installation

    private func installMicTap() throws {
        // Accessing inputNode when the audio server is unresponsive
        // ABORTS the process (AudioToolbox _ReportRPCTimeout — seen on
        // the simulator 2026-09-02). Fail gracefully instead.
        guard audioSession.isInputAvailable else {
            throw NSError(domain: "VoicePipeline", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "no audio input available"])
        }
        let input = audioEngine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: wakeWordEngine.requiredSampleRate,
            channels: 1,
            interleaved: true
        )!
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw NSError(domain: "VoicePipeline", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot build audio converter"])
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.processingQueue.async {
                self.handleAudioBuffer(buffer, converter: converter, target: targetFormat)
            }
        }

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

        switch state {
        case .idle:
            feedWakeWord(samples)
        case .capturingCommand:
            feedCapture(pcm: samples, buffer: converted)
        case .stopped, .processing, .routing, .error:
            break
        }
    }

    private func feedWakeWord(_ samples: [Int16]) {
        // Gate check FIRST, before buffering: while the gate is closed
        // (assistant speaking / listening switched off) the audio is
        // dropped wholesale, never queued — queuing would flush stale TTS
        // audio into the engine right after the reply ends, which is
        // exactly the false wake this gate exists to prevent.
        guard wakeWordGate?.allowsWakeWordAudio ?? true else { return }
        pcmBuffer.append(contentsOf: samples)
        let frameLength = wakeWordEngine.frameLength
        while pcmBuffer.count >= frameLength {
            let frame = Array(pcmBuffer.prefix(frameLength))
            pcmBuffer.removeFirst(frameLength)
            wakeWordEngine.process(frame)
        }
    }

    private func feedCapture(pcm samples: [Int16], buffer: AVAudioPCMBuffer) {
        // Push to STT — the STT is in push mode when a VAD is present.
        if !speechRecognizer.ownsAudioCapture {
            speechRecognizer.feed(buffer)
        }
        // Push to VAD — chunks of its expected frame length.
        guard let vad = vad else { return }
        pcmBuffer.append(contentsOf: samples)
        let frameLength = vad.frameLength
        while pcmBuffer.count >= frameLength {
            let frame = Array(pcmBuffer.prefix(frameLength))
            pcmBuffer.removeFirst(frameLength)
            vad.process(frame)
        }
    }

    // MARK: - Wake handling

    private func handleWakeDetected() {
        // Second gate at the DETECTION end, not just the audio-feed end: a
        // keyword event already in flight when the reply started (the
        // engine fires on its own queue; the handler hops to main) must
        // not start a capture while the assistant is still talking. Only
        // the speaking half of the gate applies here — the enable half is
        // deliberately NOT consulted, because the Talk button runs
        // `simulateWakeWordDetection()` through this same path and must
        // keep working with listening switched off.
        guard state == .idle, wakeWordGate?.allowsWakeDetection ?? true else { return }
        state = .capturingCommand
        pcmBuffer.removeAll()
        silenceCounter = 0
        emit("wake_word_detected", outcome: "success")

        if speechRecognizer.ownsAudioCapture {
            // Legacy path: STT owns the input node. Tear down our tap and
            // let it install its own. This is what happens when no VAD is
            // configured and the STT is SFSpeechRecognizer in owned-tap
            // mode. Both recognizers are push-mode now, so this branch is
            // dormant — but keep the inputNode guard for the same
            // _ReportRPCTimeout abort as installMicTap/stop.
            if audioSession.isInputAvailable {
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            if audioEngine.isRunning { audioEngine.stop() }
        } else {
            // Push mode: our tap stays live. Prime the VAD.
            vad?.reset()
            vad?.start(endOfUtteranceMs: Self.endOfUtteranceMs)
        }

        // `Self.captureTimeoutSeconds` after startListening, if we haven't
        // already exited capturingCommand, the STT's own timeout has fired
        // finish() and is now grinding through inference/a network call.
        // Flip the state so the UI stops saying "Listening for your
        // command…".
        //
        // AND force the recognizer to produce its completion: a recognizer
        // that hangs without honouring its timeout (SFSpeech waiting on
        // its on-device model, Whisper push-mode without a VAD end, or a
        // cloud recognizer whose HTTP call never returns) would otherwise
        // wedge the pipeline in this state forever ("stuck in listening").
        // cancel() triggers the completion path.
        //
        // `wedgeGuardMarginSeconds` on top of the capture timeout is
        // deliberately generous — wide enough to cover a full network
        // round-trip for a cloud-backed recognizer (GeminiSpeechRecognizer)
        // on top of the max capture time, not just on-device inference.
        // A tighter margin here (previously a hardcoded 5.1s/5.0s pair)
        // was measured on-device to cancel legitimate in-flight Gemini
        // requests before they could return — see the 2026-09-04 fix.
        // On-device recognizers finish well within this and are
        // unaffected; this only widens the worst-case "truly wedged"
        // ceiling, it doesn't change the common-case latency.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureTimeoutSeconds + Self.wedgeGuardMarginSeconds) { [weak self] in
            guard let self, self.state == .capturingCommand else { return }
            self.state = .processing
            self.speechRecognizer.cancel()
        }

        speechRecognizer.startListening(timeout: Self.captureTimeoutSeconds) { [weak self] result in
            guard let self else { return }
            self.vad?.stop()
            self.state = .routing
            switch result {
            case .success(let transcript):
                _ = self.router.route(transcript: transcript)
            case .failure(let err):
                self.emit("recognition_failed", outcome: "failure",
                          errorCode: String(describing: err))
                let msg = "STT: \(err)"
                DispatchQueue.main.async { self.onSTTError?(msg) }
            }
            self.resumeWakeListening()
        }
    }

    private func resumeWakeListening() {
        if speechRecognizer.ownsAudioCapture {
            // The STT tore down our tap; put it back.
            do {
                try installMicTap()
                state = .idle
            } catch {
                state = .error("resume: \(error)")
            }
        } else {
            // Our tap was live throughout; just flip state.
            state = .idle
        }
    }

    // MARK: - Observability

    private func emit(_ eventType: String, outcome: String, errorCode: String? = nil) {
        observabilityBus.emit(ObservabilityEvent(
            component: "voice_pipeline",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: [:]
        ))
    }
}
