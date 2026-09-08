import XCTest
@testable import ElderlyAssistant

/// Streaming behavior of the spectral-gate denoiser (noise-filter P1
/// front-end) — the `NoiseSuppressor` implementation that sits in the
/// capture fan-out. Covers the streaming contract (warmup passthrough,
/// constant hop delay, chunking invariance, cumulative length), the
/// suppression/preservation guarantees on synthetic tone+noise signals,
/// capture-boundary reset semantics, and the honest observability events
/// (component `noise_suppressor`, engine `spectral_gate`, model `none`).
final class SpectralGateDenoiserTests: XCTestCase {

    private var bus: RecordingBus!
    private var denoiser: SpectralGateDenoiser!

    override func setUp() {
        super.setUp()
        bus = RecordingBus()
        denoiser = SpectralGateDenoiser(observabilityBus: bus)
    }

    // MARK: - Helpers

    private final class RecordingBus: ObservabilityBus {
        private(set) var events: [ObservabilityEvent] = []
        func emit(_ event: ObservabilityEvent) {
            events.append(event)
        }
        func events(ofType type: String) -> [ObservabilityEvent] {
            events.filter { $0.eventType == type }
        }
    }

    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func noise(count: Int, amplitude: Float, seed: UInt64) -> [Int16] {
        var rng = LCG(state: seed)
        return (0..<count).map { _ in
            Int16(Float.random(in: -1...1, using: &rng) * amplitude * 32_768.0)
        }
    }

    private func tone(freq: Double, sampleRate: Double, count: Int,
                      amplitude: Float) -> [Int16] {
        (0..<count).map { n in
            Int16(amplitude * sin(Float(2 * .pi * freq * Double(n) / sampleRate))
                  * 32_768.0)
        }
    }

    private func rms(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return sqrt(sumSquares / Double(samples.count) / Double(32_768 * 32_768))
    }

    private func db(_ rms: Double) -> Double { 20 * log10(max(rms, 1.0 / 32_768)) }

    /// Goertzel magnitude at an arbitrary frequency (not FFT-bin-aligned).
    private func goertzel(_ samples: [Int16], freq: Double,
                          sampleRate: Double) -> Double {
        let omega = 2.0 * .pi * freq / sampleRate
        let coeff = 2.0 * cos(omega)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for s in samples {
            let x = Double(s) / 32_768.0
            s0 = x + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return sqrt(max(power, 0))
    }

    private func feed(_ chunks: [[Int16]], into denoiser: SpectralGateDenoiser) -> [Int16] {
        var out: [Int16] = []
        for chunk in chunks {
            out.append(contentsOf: denoiser.process(chunk))
        }
        return out
    }

    // MARK: - Null stage

    func testNullNoiseSuppressorIsHonestIdentity() {
        let null = NullNoiseSuppressor()
        XCTAssertEqual(null.name, "null")
        XCTAssertEqual(null.latencySamples, 0)
        XCTAssertEqual(null.requiredSampleRate, 16_000)
        let input = noise(count: 100, amplitude: 0.5, seed: 1)
        XCTAssertEqual(null.process(input), input, "identity, no copy surprises")
    }

    // MARK: - Streaming contract

    func testEmptyInputReturnsEmptyOutput() {
        XCTAssertTrue(denoiser.process([]).isEmpty)
    }

    func testWarmupPrefixIsRawPassthrough() {
        let input = noise(count: 2000, amplitude: 0.05, seed: 3)
        var out: [Int16] = []
        var i = 0
        while i < input.count {
            let take = min(137, input.count - i)
            out.append(contentsOf: denoiser.process(Array(input[i..<(i + take)])))
            i += take
        }
        XCTAssertEqual(Array(out.prefix(denoiser.latencySamples)),
                       Array(input.prefix(denoiser.latencySamples)),
                       "the first latencySamples stream samples pass through raw")
    }

    func testChunkingInvariance() {
        // The stage must be a function of the STREAM, not of how the
        // caller chunks it: identical inputs in different chunkings
        // produce identical output.
        let input = noise(count: 4096, amplitude: 0.05, seed: 5)
        let oneShot = SpectralGateDenoiser(observabilityBus: bus)
        let asOneChunk = oneShot.process(input)

        let chunked = SpectralGateDenoiser(observabilityBus: bus)
        var out: [Int16] = []
        var i = 0
        while i < input.count {
            let take = min(97, input.count - i)
            out.append(contentsOf: chunked.process(Array(input[i..<(i + take)])))
            i += take
        }
        XCTAssertEqual(out, asOneChunk)
    }

    func testCumulativeLengthContractHolds() {
        // After A input samples, total emitted ∈ [A − 2·hop, A] — the
        // stage never drops more than its buffered tail and never
        // fabricates samples.
        let input = noise(count: 5000, amplitude: 0.05, seed: 7)
        var total = 0
        var i = 0
        while i < input.count {
            let take = min(137, input.count - i)
            total += denoiser.process(Array(input[i..<(i + take)])).count
            i += take
        }
        XCTAssertLessThanOrEqual(total, input.count)
        XCTAssertGreaterThanOrEqual(total, input.count - 2 * denoiser.latencySamples)
    }

    func testUnityGainConfigReconstructsInputDelayed() {
        // gainFloor 1.0 + tiny over-subtraction ⇒ gains ≈ 1 everywhere:
        // the whole chain (warmup + sine analysis/synthesis + overlap-add
        // + FFT round-trip + int16 conversion) must reconstruct the input
        // delayed by exactly latencySamples.
        let unity = SpectralGateDenoiser(
            observabilityBus: bus,
            config: SpectralGateConfig(gainFloorLinear: 1.0, overSubtraction: 0.001))
        let input = noise(count: 4096, amplitude: 0.1, seed: 9)
        let out = unity.process(input)
        XCTAssertEqual(out.count, input.count)
        // Error budget: FFT round-trip (~1e-5 relative) + int16
        // quantization (±0.5 LSB) ⇒ a few LSBs of slack is right.
        for n in unity.latencySamples..<input.count {
            let expected: Double
            if n < 2 * unity.latencySamples {
                // The stream's FIRST emitted segment has only ONE
                // contributing frame: its squared sine window ramp is the
                // exact reconstruction there (the COLA pair starts at the
                // second segment). This is correct STFT edge behavior —
                // a 16 ms fade-in at capture start, not an error.
                let m = n - unity.latencySamples
                let w = sin(.pi * Double(m) / 512.0)
                expected = Double(input[m]) * w * w
            } else {
                expected = Double(input[n - unity.latencySamples])
            }
            XCTAssertEqual(Double(out[n]), expected, accuracy: 4.0,
                           "sample \(n) must reconstruct its delayed input")
        }
    }

    func testSilenceInSilenceOut() {
        let silence = [Int16](repeating: 0, count: 2048)
        let out = denoiser.process(silence)
        XCTAssertEqual(out.count, silence.count)
        XCTAssertTrue(out.allSatisfy { $0 == 0 }, "silence stays silence")
    }

    func testFullScaleInputDoesNotTrapOrOverflow() {
        let full = (0..<4096).map { Int16($0 % 2 == 0 ? -32_768 : 32_767) }
        let out = denoiser.process(full)
        XCTAssertEqual(out.count, full.count)
        // Warmup passthrough must reproduce full-scale samples exactly.
        XCTAssertEqual(Array(out.prefix(denoiser.latencySamples)),
                       Array(full.prefix(denoiser.latencySamples)))
    }

    // MARK: - Suppression / preservation (synthetic signals)

    func testStationaryNoiseSuppressedAfterLearning() {
        // 2 s of stationary noise: the estimate converges in the first
        // ~0.5 s (all frames classify noise-only), then steady-state
        // suppression of the delayed stream.
        let input = noise(count: 32_768, amplitude: 0.02, seed: 11)
        let out = feed(input.chunked(by: 512), into: denoiser)

        // Steady state: last 8192 outputs vs their aligned inputs
        // (output[n] ⇄ input[n − latencySamples]).
        let window = 8192
        let outRegion = Array(out.suffix(window))
        let inStart = out.count - window - denoiser.latencySamples
        let inRegion = Array(input[inStart..<(inStart + window)])
        let reduction = db(rms(inRegion)) - db(rms(outRegion))
        XCTAssertGreaterThanOrEqual(reduction, 4,
                                    "stationary noise must be suppressed ≥ 4 dB, got \(reduction)")
        XCTAssertLessThanOrEqual(reduction, 20,
                                 "the suppression budget caps the depth, got \(reduction)")
    }

    func testTonePreservedAndNoiseReducedInMixedSignal() {
        // Realistic sequence: a short noise-only lead (the wake tail /
        // room calibration), then tone+noise (the utterance).
        let lead = noise(count: 8_192, amplitude: 0.02, seed: 13)
        let mixed = zip(tone(freq: 440, sampleRate: 16_000, count: 24_000,
                             amplitude: 0.2),
                        noise(count: 24_000, amplitude: 0.02, seed: 17)).map(+)
        let input = lead + mixed
        let out = feed(input.chunked(by: 512), into: denoiser)

        // Aligned steady-state window.
        let window = 8192
        let outRegion = Array(out.suffix(window))
        let inStart = out.count - window - denoiser.latencySamples
        let inRegion = Array(input[inStart..<(inStart + window)])

        // Tone energy preserved within ±1 dB.
        let toneIn = goertzel(inRegion, freq: 440, sampleRate: 16_000)
        let toneOut = goertzel(outRegion, freq: 440, sampleRate: 16_000)
        let toneDeltaDb = 20 * log10(toneOut / toneIn)
        XCTAssertEqual(toneDeltaDb, 0, accuracy: 1.0,
                       "the tone must pass through (±1 dB), got \(toneDeltaDb) dB")

        // Noise energy (probed away from the tone) reduced ≥ 3 dB — the
        // single-capture worst case: the estimate was calibrated on only
        // 0.5 s of pre-speech room audio (Rayleigh sampling noise).
        // With an ideal at-the-mean estimate the Wiener map (α=2) is
        // theoretically ~−5.6 dB; across captures the persisted estimate
        // approaches that. The bound pins what the stage GUARANTEES on a
        // first capture — the conservative budget trades depth for
        // soft-speech protection.
        let noiseIn = goertzel(inRegion, freq: 1_200, sampleRate: 16_000)
        let noiseOut = goertzel(outRegion, freq: 1_200, sampleRate: 16_000)
        let noiseReductionDb = 20 * log10(noiseOut / noiseIn)
        XCTAssertLessThanOrEqual(noiseReductionDb, -3,
                                 "the noise band must be suppressed ≥ 3 dB, got \(noiseReductionDb) dB")
    }

    func testSoftSpeechPassesThroughUnattenuated() {
        // The doc's hard requirement: quiet speech must never be eaten.
        // A soft tone ~10 dB above the room noise (above the adaptive
        // speech threshold, mirroring EnergyVAD's constants), AFTER the
        // room was learned: its energy must survive within 1 dB.
        let lead = noise(count: 8_192, amplitude: 0.02, seed: 19)
        let soft = zip(tone(freq: 440, sampleRate: 16_000, count: 24_000,
                            amplitude: 0.05),
                       noise(count: 24_000, amplitude: 0.02, seed: 23)).map(+)
        let input = lead + soft
        let out = feed(input.chunked(by: 512), into: denoiser)

        let window = 8192
        let outRegion = Array(out.suffix(window))
        let inStart = out.count - window - denoiser.latencySamples
        let inRegion = Array(input[inStart..<(inStart + window)])
        let toneIn = goertzel(inRegion, freq: 440, sampleRate: 16_000)
        let toneOut = goertzel(outRegion, freq: 440, sampleRate: 16_000)
        let deltaDb = 20 * log10(toneOut / toneIn)
        XCTAssertEqual(deltaDb, 0, accuracy: 1.0,
                       "soft speech must not be attenuated, got \(deltaDb) dB")
    }

    func testSubThresholdSpeechStaysWithinSuppressionBudget() {
        // Honest limitation pin: speech BELOW the adaptive speech
        // threshold (~6 dB SNR — the same floor EnergyVAD uses, so the
        // whole pipeline treats it as room noise) may be partially
        // suppressed — but the gain floor caps the damage at the
        // configured budget, never removal. If a future model lifts this
        // limitation, this test tightens rather than breaks.
        let lead = noise(count: 8_192, amplitude: 0.02, seed: 19)
        let faint = zip(tone(freq: 440, sampleRate: 16_000, count: 24_000,
                             amplitude: 0.03),
                        noise(count: 24_000, amplitude: 0.02, seed: 23)).map(+)
        let input = lead + faint
        let out = feed(input.chunked(by: 512), into: denoiser)

        let window = 8192
        let outRegion = Array(out.suffix(window))
        let inStart = out.count - window - denoiser.latencySamples
        let inRegion = Array(input[inStart..<(inStart + window)])
        let toneIn = goertzel(inRegion, freq: 440, sampleRate: 16_000)
        let toneOut = goertzel(outRegion, freq: 440, sampleRate: 16_000)
        let deltaDb = 20 * log10(toneOut / toneIn)
        XCTAssertLessThanOrEqual(deltaDb, 1.0, "never amplified")
        XCTAssertGreaterThanOrEqual(deltaDb, -12,
                                    "attenuation bounded well above the −20 dB floor")
    }

    // MARK: - Capture boundaries

    func testResetClearsStreamingButKeepsNoiseEstimate() {
        // First capture: learn the room.
        _ = feed(noise(count: 16_384, amplitude: 0.02, seed: 29).chunked(by: 512),
                 into: denoiser)
        denoiser.reset()

        // Second capture: the warmup prefix restarts (raw passthrough)…
        let second = noise(count: 16_384, amplitude: 0.02, seed: 31)
        let out = feed(second.chunked(by: 512), into: denoiser)
        XCTAssertEqual(Array(out.prefix(denoiser.latencySamples)),
                       Array(second.prefix(denoiser.latencySamples)))

        // …and suppression is active from the START (no re-learning
        // delay): the estimate persisted across the reset.
        let early = 4096
        let outEarly = Array(out[denoiser.latencySamples..<(denoiser.latencySamples + early)])
        let inEarly = Array(second[0..<early])
        let reduction = db(rms(inEarly)) - db(rms(outEarly))
        XCTAssertGreaterThanOrEqual(reduction, 3,
                                    "persisted estimate must suppress from the first frame, got \(reduction) dB")
    }

    // MARK: - Observability

    func testUtteranceEventCarriesHonestMetadata() {
        denoiser.captureStarted()
        _ = feed(noise(count: 32_768, amplitude: 0.02, seed: 37).chunked(by: 512),
                 into: denoiser)
        denoiser.captureEnded()

        let events = bus.events(ofType: "noise_suppressor_utterance")
        XCTAssertEqual(events.count, 1)
        guard let event = events.first else { return }
        XCTAssertEqual(event.component, "noise_suppressor")
        XCTAssertEqual(event.metadata["engine"], "spectral_gate")
        XCTAssertEqual(event.metadata["model"], "none", "honest: no model is running")
        XCTAssertEqual(event.metadata["mode"], "capturing")
        XCTAssertEqual(event.metadata["latency_samples"], "256")
        XCTAssertGreaterThan(Double(event.metadata["frames"] ?? "0") ?? 0, 0)
        let suppression = Double(event.metadata["suppression_db"] ?? "0") ?? 0
        XCTAssertGreaterThanOrEqual(suppression, 1.0,
                                    "2 s of learned noise must show ≥ 1 dB, got \(suppression)")
    }

    func testDuplicateCaptureEndEmitsNothing() {
        denoiser.captureStarted()
        _ = denoiser.process(noise(count: 1024, amplitude: 0.02, seed: 41))
        denoiser.captureEnded()
        denoiser.captureEnded() // e.g. a cancelled capture's stale bookend
        XCTAssertEqual(bus.events(ofType: "noise_suppressor_utterance").count, 1,
                       "captureEnded must be idempotent")
    }

    func testSetModeEmitsStateEventAndDeduplicates() {
        denoiser.setMode(.capturing)
        denoiser.setMode(.capturing) // no-op repeat
        let capturing = bus.events(ofType: "noise_suppressor_state")
        XCTAssertEqual(capturing.count, 1)
        XCTAssertEqual(capturing.first?.metadata["mode"], "capturing")
        XCTAssertEqual(capturing.first?.metadata["engine"], "spectral_gate")
        XCTAssertEqual(capturing.first?.metadata["model"], "none")

        denoiser.setMode(.idleListening)
        let all = bus.events(ofType: "noise_suppressor_state")
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.last?.metadata["mode"], "idle_listening")
    }

    func testCaptureStartedEmitsStateEvent() {
        denoiser.captureStarted()
        let states = bus.events(ofType: "noise_suppressor_state")
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.metadata["suppression"], "on")
    }
}

private extension Array where Element == Int16 {
    func chunked(by size: Int) -> [[Int16]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
