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
    /// [NOISE-FILTER] Denoising stage applied to the capture stream only
    /// (P1 front-end — docs/research-sections/noise-filter.md). Nil (or a
    /// null stage) by default: byte-identical legacy behavior. The idle
    /// wake-word path is deliberately NOT processed in this phase — the
    /// doc gates wake-on-enhanced-stream behind a wake-FRR measurement
    /// (open question 7), and the VPIO session preset is untouched.
    private var noiseSuppressor: NoiseSuppressor?
    private let router: CommandRouter
    private let observabilityBus: ObservabilityBus
    /// [TURN-TIMING] Turn-scoped stage tracer (nil = timing off — tests
    /// and any construction site that does not opt in).
    private let turnTracer: VoiceTurnLatencyTracer?

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
    /// Capture-generation guard (TALK-CRASH-FIX, 2026-09-07).
    ///
    /// Every capture start — and every `stop()` — advances this counter.
    /// Each capture's async tails (the STT completion, the "stuck in
    /// listening" wedge guard, and the VAD end-of-utterance hop) capture
    /// the generation they were started under and bail out when it no
    /// longer matches. Without the guard, a completion settling a capture
    /// that `stop()` already cancelled still ran the full post-capture
    /// tail — `state = .routing`, `resumeWakeListening()` — against a
    /// stopped pipeline. AppCoordinator maps that .routing onto the UI
    /// session while it is `.stopped`: an illegal `.stopped → .understanding`
    /// transition that assertion-crashed in DEBUG ("stale-tail" crash,
    /// Talk-button tap while listening). The wedge guard had the reverse
    /// bug — it checked only `state == .capturingCommand`, so a stale
    /// guard could force-cancel a *newer* capture.
    ///
    /// Writes and checks are confined to the main queue (capture start,
    /// `stop()`, and every tail), so the counter itself never races; only
    /// `handleAudioBuffer`'s pre-existing `state` reads run on the
    /// processing queue.
    private var captureGeneration = 0

    // MARK: - Deferred return to idle (REST-DIP-FIX, 2026-09-08)

    /// [REST-DIP-FIX] Safety ceiling for the deferred return to idle.
    /// When the recognition completion routes a transcript whose reply is
    /// still outstanding (the router's async LLM interpreter round-trip —
    /// see `CommandRouter.isTurnReplyPending`), the pipeline holds
    /// `.routing` (the session shows "understanding") instead of dropping
    /// to `.idle` — the reported rest dip between "understanding" and the
    /// same turn's reply. The hold ends when the router resolves the
    /// token (`onTurnReplyResolved` → `releaseIdleHold`); this timeout is
    /// the fallback for a turn that never resolves, and it falls back to
    /// TODAY's behavior (return to idle / wake listening resumes).
    ///
    /// The value MUST exceed the longest legitimate same-turn reply
    /// latency — the interpreter chain's own bounded round-trip (the
    /// local leg's timeout, then GeminiClient's 25 s HTTP timeout on
    /// escalation, all of which guarantee the interpret completion
    /// eventually fires and clears the token) — so it never fires while a
    /// reply is genuinely on its way. It sits deliberately below the 40 s
    /// voice watchdog (AppCoordinator.voiceWatchdogSeconds — the
    /// coupled-numbers family: capture timeout, wedge guard, Gemini
    /// HTTP timeout, voice watchdog — re-checked together whenever one
    /// changes).
    private static let turnPendingSafetySeconds: TimeInterval = 35

    /// Armed while a route's async reply is outstanding: the pipeline
    /// holds `.routing` instead of calling `resumeWakeListening()`. The
    /// generation is the CAPTURE the hold belongs to — `stop()` disarms
    /// (see `stop()`), and a stale release (a superseded turn's
    /// completion) can never resume a newer capture's hold.
    private var idleHold: (generation: Int, safetyWork: DispatchWorkItem)?

    init(audioSession: AudioSessionManager,
         audioEngine: AVAudioEngine,
         wakeWordEngine: WakeWordEngine,
         wakeWordGate: WakeWordActivityGate? = nil,
         speechRecognizer: SpeechRecognizerProtocol,
         voiceActivityDetector: VoiceActivityDetector? = nil,
         noiseSuppressor: NoiseSuppressor? = nil,
         router: CommandRouter,
         observabilityBus: ObservabilityBus,
         turnTracer: VoiceTurnLatencyTracer? = nil) {
        self.audioSession = audioSession
        self.audioEngine = audioEngine
        self.wakeWordEngine = wakeWordEngine
        self.wakeWordGate = wakeWordGate
        self.speechRecognizer = speechRecognizer
        self.vad = voiceActivityDetector
        self.noiseSuppressor = noiseSuppressor
        self.router = router
        self.observabilityBus = observabilityBus
        self.turnTracer = turnTracer

        self.wakeWordEngine.onDetection = { [weak self] in
            self?.handleWakeDetected()
        }
        // [REST-DIP-FIX] Release hook for the deferred return to idle: the
        // router fires it when the turn's async reply dispatch finishes
        // (after the reply speech was committed). The router's completion
        // can land on ANY queue (LLaMA/Gemini/URLSession), so the handler
        // hops to main before touching pipeline state.
        router.onTurnReplyResolved = { [weak self] in
            self?.handleTurnReplyResolved()
        }
        wireVADCallbacks()
    }

    private func wireVADCallbacks() {
        // Re-wired at every capture start (handleWakeDetected) and after a
        // VAD hot-swap — always on the main queue. The closure captures the
        // capture generation at wire time so a fire that belongs to a
        // superseded capture can never act on a newer one.
        guard let vad else { return }
        let generation = captureGeneration
        vad.onEndOfUtterance = { [weak self] in
            guard let self else { return }
            // The VAD calls this from the pipeline's processing queue
            // (vad.process runs there, via handleAudioBuffer), but the
            // recognizer lifecycle is main-confined: a finish() issued
            // from the processing queue raced a main-queue stop()/cancel()
            // on the recognizers' internal buffers. Hop to main first,
            // then re-check generation + state — by the time the hop runs
            // the capture may already be over (stop(), or a newer capture
            // started), and finish() must not cross generations.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.captureGeneration == generation,
                      self.state == .capturingCommand else { return }
                self.emit("vad_end_of_utterance", outcome: "success")
                // [TURN-TIMING] The user stopped speaking — capture ends.
                self.turnTracer?.mark("vad_end")
                self.speechRecognizer.finish()
            }
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

    /// [NOISE-FILTER] Hot-swap the denoising stage (mirrors
    /// `setVoiceActivityDetector`). Nil = the capture path is
    /// byte-identical to the pre-stage behavior. Safe mid-session: the
    /// stage's streaming state starts cold (warmup passthrough), and the
    /// capture bookends re-arm on the next wake.
    func setNoiseSuppressor(_ newSuppressor: NoiseSuppressor?) {
        noiseSuppressor = newSuppressor
        newSuppressor?.setMode(state == .idle ? .idleListening : .capturing)
        emit("noise_suppressor_hot_swap", outcome: "success",
             metadata: ["engine": newSuppressor?.name ?? "off"])
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
        // Invalidate any in-flight capture BEFORE tearing the recognizer
        // down: its completion (settled by the cancel below, possibly
        // synchronously) must not run the post-capture tail against a
        // stopped pipeline — see `captureGeneration` (TALK-CRASH-FIX).
        captureGeneration += 1
        // [REST-DIP-FIX] Disarm any deferred return to idle: the hold
        // belongs to the cancelled turn. (Its generation is already stale
        // after the bump above, but cancelling the safety work and
        // clearing the slot now also lets a NEW capture's hold arm — the
        // arming guard requires an empty slot.)
        if let hold = idleHold {
            hold.safetyWork.cancel()
            idleHold = nil
        }
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
        // [TURN-TIMING] A cancelled capture's turn is abandoned — no
        // evidence to report.
        turnTracer?.cancelTurn()
    }

    /// Debug entry point.
    func simulateWakeWordDetection() {
        handleWakeDetected()
    }

    /// [TURN-TIMING] Internal for the seam tests (no audio hardware
    /// involved — `start()` is unreachable there, see the noise-filter
    /// seam's inputNode-abort doctrine): flips the pipeline to `.idle`
    /// so a full capture → route → reply turn can be driven through the
    /// real `handleWakeDetected` path via `simulateWakeWordDetection()`.
    func debugEnterIdleForTesting() {
        state = .idle
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

    // MARK: - Noise filter (P1 front-end)

    /// [NOISE-FILTER] Internal seam (same doctrine as the
    /// `AudioSessionControlling` test seam — the wiring must be testable
    /// without the mic tap). The denoising step of the capture fan-out:
    /// stage applied ONCE, before the STT push and the VAD slice. No
    /// stage (nil) = identity.
    func enhanceCaptureSamples(_ samples: [Int16]) -> [Int16] {
        guard let suppressor = noiseSuppressor else { return samples }
        let processed = suppressor.process(samples)
        if !processed.isEmpty || samples.isEmpty {
            return processed
        }
        // Contract violation guard: a stage that returns nothing for a
        // non-empty chunk would silently starve the capture — fall back
        // to raw and say so, never corrupt the stream.
        emit("noise_suppressor_starved", outcome: "fallback",
             metadata: ["engine": suppressor.name])
        return samples
    }

    /// [NOISE-FILTER] Internal seam: capture bookend — mode, streaming
    /// reset, telemetry window. The stage KEEPS its learned noise
    /// estimate across captures (room calibration — EnergyVAD's contract
    /// for its own noiseFloor).
    func beginNoiseFilterCapture() {
        noiseSuppressor?.setMode(.capturing)
        noiseSuppressor?.reset()
        noiseSuppressor?.captureStarted()
    }

    /// [NOISE-FILTER] Internal seam: capture bookend — close the
    /// per-utterance telemetry window, return the stage to the idle
    /// preset. Idempotent inside the stage (a duplicate end from a
    /// cancelled capture emits nothing).
    func endNoiseFilterCapture() {
        noiseSuppressor?.captureEnded()
        noiseSuppressor?.setMode(.idleListening)
    }

    /// [NOISE-FILTER] Internal for the seam tests (no audio hardware
    /// involved — pure fan-out over caller-supplied PCM).
    func feedCapture(pcm samples: [Int16], buffer: AVAudioPCMBuffer) {
        // [NOISE-FILTER] The denoising stage — applied ONCE here, after
        // the 48→16 kHz conversion and before the fan-out, so the STT
        // push and the endpointing VAD consume the identical enhanced
        // stream (the doc's single-choke-point design). No stage (nil) =
        // byte-identical legacy path. The stage is a STREAMING filter:
        // per-call output length may vary by up to its latency (its
        // doc), so the STT buffer is rebuilt from the enhanced samples
        // instead of mutating the converter's buffer.
        let enhanced = enhanceCaptureSamples(samples)
        // Push to STT — the STT is in push mode when a VAD is present.
        if !speechRecognizer.ownsAudioCapture {
            if noiseSuppressor != nil {
                speechRecognizer.feed(Self.makeInt16Buffer(from: enhanced,
                                                           format: buffer.format))
            } else {
                speechRecognizer.feed(buffer)
            }
        }
        // Push to VAD — chunks of its expected frame length.
        guard let vad = vad else { return }
        pcmBuffer.append(contentsOf: enhanced)
        let frameLength = vad.frameLength
        while pcmBuffer.count >= frameLength {
            let frame = Array(pcmBuffer.prefix(frameLength))
            pcmBuffer.removeFirst(frameLength)
            vad.process(frame)
        }
    }

    /// Builds a fresh 16 kHz int16 mono buffer holding `samples` — used
    /// for the STT push when the noise stage's output length differs
    /// from the converter's chunk length (streaming stage contract).
    /// Internal for the seam tests (no audio hardware involved).
    static func makeInt16Buffer(from samples: [Int16],
                                format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.int16ChannelData?.pointee.update(from: src.baseAddress!, count: src.count)
        }
        return buffer
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
        // A fresh capture epoch: the tails scheduled below (STT
        // completion, wedge guard, VAD end-of-utterance) all capture
        // `generation` and are inert once a stop() or a newer capture
        // bumps the counter — see `captureGeneration` (TALK-CRASH-FIX).
        captureGeneration += 1
        let generation = captureGeneration
        state = .capturingCommand
        pcmBuffer.removeAll()
        silenceCounter = 0
        // [NOISE-FILTER] Capture bookend (start) — see
        // `beginNoiseFilterCapture` for the contract.
        beginNoiseFilterCapture()
        emit("wake_word_detected", outcome: "success")
        // [TURN-TIMING] One voice turn starts here.
        turnTracer?.beginTurn()

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
            // Push mode: our tap stays live. Prime the VAD and wire its
            // end-of-utterance callback to THIS capture's generation.
            vad?.reset()
            vad?.start(endOfUtteranceMs: Self.endOfUtteranceMs)
            wireVADCallbacks()
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
            // Generation guard: this wedge belongs to the capture started
            // above. It previously checked only `state == .capturingCommand`,
            // so a wedge left over from a recycled capture could force-cancel
            // a brand-new capture ~18 s in. With the guard, a stale wedge
            // (stop(), or a newer capture) is a no-op.
            guard let self, self.captureGeneration == generation,
                  self.state == .capturingCommand else { return }
            self.state = .processing
            self.speechRecognizer.cancel()
        }

        speechRecognizer.startListening(timeout: Self.captureTimeoutSeconds) { [weak self] result in
            guard let self else { return }
            // Generation guard: this completion may be settling a capture
            // that stop() already invalidated (cancel settles the
            // recognizer, which completes this closure). Running the tail
            // then would flip `state = .routing` against the stopped
            // pipeline; AppCoordinator maps that .routing onto the UI
            // session's `.stopped → .understanding` — an illegal
            // transition that assertion-crashed in DEBUG (the "stale-tail"
            // Talk-button crash, TALK-CRASH-FIX). Stale completions are
            // dropped whole: stop() already reset the VAD/state, or a
            // newer capture owns the tail.
            guard self.captureGeneration == generation else { return }
            // [TURN-TIMING] Recognition settled (success OR failure) —
            // the ASR span closes here.
            self.turnTracer?.mark("asr_done")
            self.vad?.stop()
            // [NOISE-FILTER] Capture bookend (end) — see
            // `endNoiseFilterCapture` for the contract.
            self.endNoiseFilterCapture()
            // [REST-DIP-FIX] Requirement 3 — `.processing` (the session's
            // writing/transcribing state) must precede `.routing` for
            // EVERY live capture, not just wedge-forced ones: `.processing`
            // is otherwise only set by the 18 s "stuck in listening"
            // wedge, so on the normal VAD path (and instant STT
            // completions) a live capture still in `.capturingCommand`
            // here would jump straight to `.routing` and the session
            // would skip the writing state entirely. The completion and
            // the wedge are both main-confined so they cannot race — this
            // guard simply covers the completion-won case: if the wedge
            // already flipped `.processing`, leave it; a stale/stopped
            // completion never reaches here (generation guard above).
            if self.state == .capturingCommand {
                self.state = .processing
            }
            self.state = .routing
            switch result {
            case .success(let transcript):
                _ = self.router.route(transcript: transcript)
                // [TURN-TIMING] The router's synchronous decision is made.
                self.turnTracer?.mark("router_done")
            case .failure(let err):
                self.emit("recognition_failed", outcome: "failure",
                          errorCode: String(describing: err))
                let msg = "STT: \(err)"
                DispatchQueue.main.async { self.onSTTError?(msg) }
                // [TURN-TIMING] No reply can exist — close the turn.
                self.turnTracer?.endTurn()
            }
            if self.router.isTurnReplyPending {
                // The route handed the turn to an async dispatch whose
                // reply speech is still outstanding (the LLM interpreter
                // round-trip). Defer the return to idle — the session
                // stays on "understanding" (state `.routing`) until the
                // reply is committed or the safety timeout falls back to
                // today's behavior — instead of dropping to rest for the
                // beat before the reply starts (the reported rest dip).
                self.holdIdleForTurnReply(generation: generation)
                // The async LLM dispatch ends the turn (after the reply
                // speech finishes) — see CommandRouter's interpret path.
            } else {
                self.resumeWakeListening()
                // [TURN-TIMING] Synchronous turn — the dispatch already
                // resolved; finalizes now or after pending speech.
                self.turnTracer?.endTurn()
            }
        }
    }

    // MARK: - Deferred return to idle (REST-DIP-FIX, 2026-09-08)

    /// Holds the pipeline on `.routing` (the session's "understanding")
    /// instead of returning to idle: the turn's async reply is still
    /// outstanding (`router.isTurnReplyPending`, checked right after
    /// `route()` returned). Wake listening stays off while held — the
    /// session is visibly busy — and the escape hatches still work: the
    /// Talk-button tap mid-cycle runs `stop()` (which disarms the hold),
    /// and the safety timeout below restores today's behavior for a turn
    /// that never resolves.
    private func holdIdleForTurnReply(generation: Int) {
        guard idleHold == nil else { return }
        let safetyWork = DispatchWorkItem { [weak self] in
            // Safety fallback: the turn never resolved (a reply path that
            // neither spoke nor cleared the token) — fall back to today's
            // behavior and return to idle / resume wake listening.
            self?.releaseIdleHold()
        }
        idleHold = (generation, safetyWork)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.turnPendingSafetySeconds,
            execute: safetyWork)
    }

    /// Main-queue entry point for the router's resolution notification
    /// (its interpret completion can land on any queue — LLaMA / Gemini /
    /// URLSession workers).
    private func handleTurnReplyResolved() {
        DispatchQueue.main.async { [weak self] in
            self?.releaseIdleHold()
        }
    }

    /// Ends the deferred return to idle. When the hold is still armed for
    /// the CURRENT capture, resumes wake listening (the reply's
    /// speech-start hop was already enqueued by the router before it
    /// resolved the token, so the session maps to `.speaking`, never to
    /// rest). Idempotent; a stale hold (superseded capture — generation
    /// mismatch, or `stop()` already disarmed) is cleared without
    /// resuming.
    private func releaseIdleHold() {
        guard let hold = idleHold else { return }
        idleHold = nil
        hold.safetyWork.cancel()
        guard hold.generation == captureGeneration else { return }
        resumeWakeListening()
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

    private func emit(_ eventType: String, outcome: String,
                      errorCode: String? = nil,
                      metadata: [String: String] = [:]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "voice_pipeline",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: metadata
        ))
    }
}
