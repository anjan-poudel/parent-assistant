import Foundation

/// The noise-filter front-end that ships TODAY: a streaming spectral-gate
/// denoiser (classic DSP, zero model artifacts) implementing the
/// `NoiseSuppressor` stage contract (docs/research-sections/noise-filter.md
/// P1 step 1). Injected into `VoicePipeline.feedCapture` — 16 kHz int16
/// mono in, 16 kHz int16 mono out, uniform algorithmic delay of one hop
/// (256 samples = 16 ms), warmup prefix passthrough (see the protocol's
/// cumulative-length contract for the per-call length behavior).
///
/// GAP vs the doc's P1 recommendation, stated honestly: the doc's
/// preferred suppressor is DeepFilterNet3 (INT8 CoreML port, ~2.2 MB).
/// That needs model artifacts + ModelStore delivery (P1 step 2) which is
/// out of scope for this task; the doc's fallback (RNNoise) is also a
/// model file. What ships instead is the model-free classic front-end,
/// behind the SAME stage contract — when the DFN3 artifact lands it slots
/// in as another `NoiseSuppressor` implementation without touching the
/// pipeline. Same for the P2 speaker-conditioned gate (babble separation
/// is explicitly NOT what this stage does).
///
/// Honest capability statement: stationary-noise suppression (fan, TV
/// hiss, appliance hum) at a conservative budget (mild −12 dB / full
/// −20 dB max per-bin attenuation). It does NOT remove competing speech
/// and it cannot make noisy audio clean — the observability events say
/// exactly what ran ("engine": "spectral_gate", "model": "none").
final class SpectralGateDenoiser: NoiseSuppressor {

    let requiredSampleRate: Double = 16_000
    /// Honest engine name — a DSP gate, not a neural model.
    let name = "spectral_gate"

    private let observabilityBus: ObservabilityBus
    private let fft: SpectralGateCore.FFT
    private let window: [Float]
    private let baseConfig: SpectralGateConfig

    /// Single lock for ALL mutable state: `process` runs on the
    /// pipeline's processing queue, while the bookend calls
    /// (`reset`/`setMode`/`captureStarted`/`captureEnded`) arrive from the
    /// main queue at capture boundaries. The lock is uncontended except at
    /// those boundaries (one acquisition per tap chunk otherwise), so the
    /// hot path pays nothing measurable.
    private let lock = NSLock()

    // Guarded by `lock`. Nil until the first `setMode` — so the FIRST
    // mode transition always emits its state event (a default value
    // would swallow it via the dedupe check).
    private var mode: NoiseSuppressorMode?
    private var coreState: SpectralGateState
    private var stats = Stats()

    // Streaming state (also guarded by `lock` — `reset` clears it from
    // the main queue while `process` drains it on the processing queue).
    private var inputBuffer: [Float] = []
    private var warmupCursor = 0
    private var framesDone = 0
    private var overlapTail: [Float]

    /// Constant algorithmic delay: one hop (N − H = 256 samples = 16 ms
    /// @ 16 kHz). The first `latencySamples` stream samples pass through
    /// unprocessed (the stage literally cannot have a full frame yet);
    /// everything after is the denoised stream delayed uniformly.
    let latencySamples: Int

    init(observabilityBus: ObservabilityBus,
         config: SpectralGateConfig = .captureFull,
         fftLog2n: Int = 9) {
        precondition(SpectralGateDenoiser.isSupported(config),
                     "unsupported SpectralGateConfig geometry")
        self.observabilityBus = observabilityBus
        self.baseConfig = config
        self.latencySamples = config.hopLength
        self.fft = SpectralGateCore.FFT(log2n: fftLog2n)!
        self.window = SpectralGateCore.sineWindow(length: config.frameLength)
        self.coreState = SpectralGateState(binCount: config.frameLength / 2 + 1)
        self.overlapTail = [Float](repeating: 0, count: config.hopLength)
    }

    private static func isSupported(_ config: SpectralGateConfig) -> Bool {
        config.frameLength == config.hopLength * 2
            && config.frameLength.isPowerOfTwo
    }

    // MARK: - NoiseSuppressor

    func process(_ samples: [Int16]) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }

        let config = currentConfig()
        // [VAD-RT] Pure-Float normalization (was a Double division per
        // sample on the capture path).
        inputBuffer.append(contentsOf: samples.map { Float($0) / 32768 })

        var out: [Float] = []
        out.reserveCapacity(samples.count)

        // Warmup prefix: the first `latencySamples` stream samples pass
        // through raw (see the property doc). Reads only — frame
        // consumption below owns the buffer's frontier.
        let warmupRemaining = latencySamples - warmupCursor
        if warmupRemaining > 0 {
            let available = inputBuffer.count - warmupCursor
            let take = min(available, warmupRemaining)
            if take > 0 {
                out.append(contentsOf: inputBuffer[warmupCursor..<(warmupCursor + take)])
                warmupCursor += take
            }
        }

        // Frame processing: each 2·hop window advances the consumed
        // frontier by one hop; the overlap-add emits one hop of output.
        let hop = config.hopLength
        let n = config.frameLength
        while inputBuffer.count >= framesDone * hop + n {
            let start = framesDone * hop
            let frame = Array(inputBuffer[start..<(start + n)])
            let y = SpectralGateCore.denoiseFrame(frame,
                                                  state: &coreState,
                                                  config: config,
                                                  fft: fft,
                                                  window: window)
            let (segment, newTail) = SpectralGateCore.overlapAdd(previousTail: overlapTail,
                                                                 currentFrame: y,
                                                                 hop: hop)
            out.append(contentsOf: segment)
            overlapTail = newTail
            framesDone += 1
        }

        let output = Self.toInt16(out)
        stats.accumulate(input: samples, output: output)
        return output
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        // Streaming state restarts; the learned noise estimates persist —
        // room calibration carries across utterances (EnergyVAD's
        // documented contract for its own floor).
        inputBuffer.removeAll(keepingCapacity: true)
        warmupCursor = 0
        framesDone = 0
        overlapTail = [Float](repeating: 0, count: baseConfig.hopLength)
        coreState.resetForCapture()
    }

    func setMode(_ mode: NoiseSuppressorMode) {
        lock.lock()
        let changed = self.mode != mode
        self.mode = mode
        lock.unlock()
        guard changed else { return }
        emitStateEvent(mode: mode)
    }

    func captureStarted() {
        lock.lock()
        stats.beginCapture()
        let current = mode ?? .capturing
        lock.unlock()
        emitStateEvent(mode: current)
    }

    func captureEnded() {
        lock.lock()
        guard let snapshot = stats.endCapture() else {
            lock.unlock()
            return
        }
        let current = mode ?? .capturing
        lock.unlock()
        emitUtteranceEvent(snapshot, mode: current)
    }

    // MARK: - Config

    /// The doc's per-state presets (P1 step 3): mild while wake-listening,
    /// full during capture. The base config's shape is kept; only the
    /// strength fields switch. Before any `setMode`, processing assumes
    /// capture (process only ever runs during capture anyway).
    private func currentConfig() -> SpectralGateConfig {
        var config = baseConfig
        switch mode ?? .capturing {
        case .idleListening:
            config.gainFloorLinear = SpectralGateConfig.idleMild.gainFloorLinear
        case .capturing:
            config.gainFloorLinear = SpectralGateConfig.captureFull.gainFloorLinear
        }
        return config
    }

    // MARK: - Conversion

    private static func toInt16(_ samples: [Float]) -> [Int16] {
        var out = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices {
            // Gains never exceed 1.0, so clipping is a belt-and-braces
            // guard, not an expected path. [VAD-RT] Float×int scaling —
            // the old `* 32_768.0` ran Double math per sample.
            out[i] = Int16(clamping: Int32((samples[i] * 32768).rounded()))
        }
        return out
    }

    // MARK: - Observability (doc §5: per-utterance RMS, engine, preset)

    private struct Stats {
        var inputSumSquares: Double = 0
        var outputSumSquares: Double = 0
        var inputSamples = 0
        var frames = 0
        var captureOpen = false

        mutating func beginCapture() {
            inputSumSquares = 0
            outputSumSquares = 0
            inputSamples = 0
            frames = 0
            captureOpen = true
        }

        mutating func accumulate(input: [Int16], output: [Int16]) {
            guard captureOpen else { return }
            for s in input {
                let f = Double(s) / 32_768.0
                inputSumSquares += f * f
            }
            for s in output {
                let f = Double(s) / 32_768.0
                outputSumSquares += f * f
            }
            inputSamples += input.count
            frames += 1
        }

        /// Returns nil when no capture is open (idempotent — a duplicate
        /// `captureEnded` from a cancelled capture emits nothing).
        mutating func endCapture() -> Snapshot? {
            guard captureOpen else { return nil }
            captureOpen = false
            guard inputSamples > 0 else { return nil }
            let inRms = sqrt(inputSumSquares / Double(inputSamples))
            let outRms = sqrt(outputSumSquares / Double(inputSamples))
            return Snapshot(inRms: inRms, outRms: outRms, frames: frames)
        }
    }

    struct Snapshot {
        let inRms: Double
        let outRms: Double
        let frames: Int

        var suppressionDb: Double { Self.db(inRms) - Self.db(outRms) }

        static func db(_ rms: Double) -> Double {
            // Floor at one LSB of int16 (−90.3 dBFS) so log10 never
            // sees zero.
            20 * log10(max(rms, 1.0 / 32_768.0))
        }
    }

    private func emitStateEvent(mode: NoiseSuppressorMode) {
        observabilityBus.emit(ObservabilityEvent(
            component: "noise_suppressor",
            eventType: "noise_suppressor_state",
            durationMs: nil,
            outcome: "applied",
            errorCode: nil,
            metadata: [
                "engine": name,
                "model": "none",
                "mode": mode.metadataValue,
                "suppression": "on",
            ]
        ))
    }

    private func emitUtteranceEvent(_ snapshot: Snapshot, mode: NoiseSuppressorMode) {
        observabilityBus.emit(ObservabilityEvent(
            component: "noise_suppressor",
            eventType: "noise_suppressor_utterance",
            durationMs: nil,
            outcome: "success",
            errorCode: nil,
            metadata: [
                "engine": name,
                "model": "none",
                "mode": mode.metadataValue,
                "in_rms_db": String(format: "%.1f", Snapshot.db(snapshot.inRms)),
                "out_rms_db": String(format: "%.1f", Snapshot.db(snapshot.outRms)),
                "suppression_db": String(format: "%.1f", snapshot.suppressionDb),
                "frames": "\(snapshot.frames)",
                "latency_samples": "\(latencySamples)",
            ]
        ))
    }
}

private extension NoiseSuppressorMode {
    var metadataValue: String {
        switch self {
        case .idleListening: return "idle_listening"
        case .capturing: return "capturing"
        }
    }
}

private extension Int {
    var isPowerOfTwo: Bool { self > 0 && (self & (self - 1)) == 0 }
}
