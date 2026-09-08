import XCTest
@testable import ElderlyAssistant

/// Pure DSP tests for the spectral-gate core (noise-filter P1 front-end,
/// docs/research-sections/noise-filter.md) — the frames-in/frames-out
/// mathematics behind `SpectralGateDenoiser`. No streaming state, no
/// observability, no hardware: window/COLA properties, the Wiener gain
/// map, noise-estimate convergence, adaptive classification, FFT
/// round-trip, and overlap-add mixing.
final class SpectralGateCoreTests: XCTestCase {

    private let config = SpectralGateConfig.captureFull
    private let frameLength = 512
    private let hop = 256
    private let fft = SpectralGateCore.FFT(log2n: 9)!
    private let window = SpectralGateCore.sineWindow(length: 512)

    // MARK: - Helpers

    /// Deterministic LCG so every run asserts the same numbers.
    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func noise(count: Int, amplitude: Float, seed: UInt64) -> [Float] {
        var rng = LCG(state: seed)
        return (0..<count).map { _ in Float.random(in: -1...1, using: &rng) * amplitude }
    }

    private func tone(freq: Double, sampleRate: Double, count: Int,
                      amplitude: Float) -> [Float] {
        (0..<count).map { n in
            amplitude * sin(Float(2 * .pi * freq * Double(n) / sampleRate))
        }
    }

    private func energy(_ samples: [Float]) -> Float {
        samples.reduce(0) { $0 + $1 * $1 }
    }

    private func makeState() -> SpectralGateState {
        SpectralGateState(binCount: frameLength / 2 + 1)
    }

    // MARK: - Window / COLA

    func testSineWindowIsCOLAExactAtHalfOverlap() {
        let w = SpectralGateCore.sineWindow(length: 512)
        // The sine (sqrt-Hann) window satisfies w²(m) + w²(m − N/2) =
        // sin² + cos² = 1 for m ≥ N/2 — the property that makes the
        // 50%-overlap OLA reconstruct exactly when the same window is
        // applied on analysis and synthesis. (A plain Hann would fail
        // this: 0.5 + 0.5·cos² — the ripple this guard exists to catch.)
        for m in 256..<512 {
            let sum = w[m] * w[m] + w[m - 256] * w[m - 256]
            XCTAssertEqual(sum, 1.0, accuracy: 1e-4,
                           "COLA must hold at sample \(m)")
        }
    }

    func testSineWindowIsZeroAtStartAndTinyAtEnd() {
        let w = SpectralGateCore.sineWindow(length: 512)
        XCTAssertEqual(w[0], 0, accuracy: 1e-6)
        // Periodic sine: the last tap is sin(π·511/512) ≈ π/512, not
        // exactly zero — small enough to be irrelevant (the frame edge
        // is windowed by ~6e-3) and required for exact COLA.
        XCTAssertLessThan(w[511], 0.01)
    }

    // MARK: - Gain map

    func testGainAtNoiseLevelMatchesWienerFormula() {
        // A bin exactly AT the noise estimate: snrEff = 1/α = 0.5,
        // gain = 0.5/1.5 = 0.3333… (the −9.5 dB the over-subtraction
        // factor promises).
        let magnitudes = [Float](repeating: 0.01, count: 64)
        let noiseFloor = [Float](repeating: 0.01, count: 64)
        let g = SpectralGateCore.gains(magnitudes: magnitudes, noise: noiseFloor,
                                       config: config)
        for gain in g {
            XCTAssertEqual(gain, 1.0 / 3.0, accuracy: 1e-3)
        }
    }

    func testGainForLoudToneIsNearUnity() {
        // 40 dB above the noise floor: the tone bin must pass through
        // essentially untouched (the "never remove the user's speech"
        // half of the contract).
        let magnitudes: [Float] = [1.0]
        let noiseFloor: [Float] = [0.01]
        let g = SpectralGateCore.gains(magnitudes: magnitudes, noise: noiseFloor,
                                       config: config)
        XCTAssertEqual(g[0], 1.0, accuracy: 1e-3)
    }

    func testGainRespectsFloorAndUnityBounds() {
        let magnitudes = noise(count: 64, amplitude: 0.5, seed: 11)
        let noiseFloor = noise(count: 64, amplitude: 0.3, seed: 22)
        let g = SpectralGateCore.gains(magnitudes: magnitudes, noise: noiseFloor,
                                       config: config)
        for gain in g {
            XCTAssertLessThanOrEqual(gain, 1.0, "never amplify")
            XCTAssertGreaterThanOrEqual(gain, config.gainFloorLinear,
                                        "the floor is the hard attenuation cap")
        }
        // Dead silence: the floor caps the attenuation exactly.
        let silent = SpectralGateCore.gains(magnitudes: [0], noise: [0.01],
                                            config: config)
        XCTAssertEqual(silent[0], config.gainFloorLinear, accuracy: 1e-6)
    }

    func testSmoothNoiseEstimateAveragesAcrossBins() {
        // The anti-musical-noise pass: a 5-bin mean over the FLOOR (not
        // the gains) — a single-bin Rayleigh spike in the estimate is
        // flattened, edges are copied.
        let raw: [Float] = [0.1, 0.1, 0.5, 0.1, 0.1, 0.1, 0.1]
        let smoothed = SpectralGateCore.smoothNoiseEstimate(raw, width: 5)
        XCTAssertEqual(smoothed[0], 0.1, accuracy: 1e-6, "edge copied")
        XCTAssertEqual(smoothed[3], 0.18, accuracy: 1e-6,
                       "spike center averaged over the window: (0.1+0.5+0.1+0.1+0.1)/5")
        XCTAssertLessThan(smoothed[2], 0.3, "spike reduced")
        // A constant floor is unchanged (the smoothing is stable).
        let flat = [Float](repeating: 0.4, count: 16)
        XCTAssertEqual(SpectralGateCore.smoothNoiseEstimate(flat, width: 5), flat)
    }

    // MARK: - Noise estimate (gated minimum tracking)

    func testNoiseEstimateConvergesOnStationaryNoise() {
        let magnitudes = [Float](repeating: 0.01, count: 16)
        var estimate = [Float](repeating: 0, count: 16)
        for _ in 0..<30 {
            estimate = SpectralGateCore.trackNoiseEstimate(
                estimate, magnitudes: magnitudes, isNoiseOnly: true, config: config)
        }
        // Upward release with α = 0.25: 1 − 0.75³⁰ ≈ 0.9998 of the way.
        for e in estimate {
            XCTAssertEqual(e, 0.01, accuracy: 1e-3)
        }
    }

    func testNoiseEstimateNeverRisesOnSpeechFrames() {
        // A speech bin (loud, sustained) must NOT drag the estimate up —
        // that is what would make the gate eat the speech itself.
        let magnitudes = [Float](repeating: 1.0, count: 16)
        let estimate = [Float](repeating: 0.01, count: 16)
        let after = SpectralGateCore.trackNoiseEstimate(
            estimate, magnitudes: magnitudes, isNoiseOnly: false, config: config)
        XCTAssertEqual(after, estimate, "speech frames must not move the floor up")
    }

    func testNoiseEstimateNeverMovesDownDuringSpeech() {
        // Speech-freeze goes BOTH ways: a bin dipping below the estimate
        // during speech is NOT chased. (Chasing dips drives the estimate
        // toward the noise distribution's extreme minima, which pushes
        // the Wiener gain back toward unity — the failure the frozen
        // shape exists to avoid. The room level is the honest floor.)
        let magnitudes = [Float](repeating: 0.005, count: 16)
        let estimate = [Float](repeating: 0.01, count: 16)
        let after = SpectralGateCore.trackNoiseEstimate(
            estimate, magnitudes: magnitudes, isNoiseOnly: false, config: config)
        XCTAssertEqual(after, estimate)
    }

    func testNoiseEstimateRisesOnlyOnNoiseOnlyFrames() {
        let magnitudes = [Float](repeating: 0.05, count: 16)
        let estimate = [Float](repeating: 0.01, count: 16)
        let held = SpectralGateCore.trackNoiseEstimate(
            estimate, magnitudes: magnitudes, isNoiseOnly: false, config: config)
        XCTAssertEqual(held, estimate)
        let released = SpectralGateCore.trackNoiseEstimate(
            estimate, magnitudes: magnitudes, isNoiseOnly: true, config: config)
        for e in released {
            XCTAssertEqual(e, 0.01 + 0.25 * 0.04, accuracy: 1e-6)
        }
    }

    func testNoiseEstimateNeverFallsBelowAbsoluteFloor() {
        let magnitudes = [Float](repeating: 0, count: 16)
        let estimate = [Float](repeating: 0, count: 16)
        let after = SpectralGateCore.trackNoiseEstimate(
            estimate, magnitudes: magnitudes, isNoiseOnly: true, config: config)
        for e in after {
            XCTAssertEqual(e, config.minNoiseMagnitude)
        }
    }

    // MARK: - Adaptive classification

    func testClassifyLearnsFloorThenDetectsSpeech() {
        var state = SpectralGateAdaptiveState()
        // Quiet frames below the minimum threshold are noise: the floor
        // rides up toward them (EnergyVAD's exact shape — EMA, so give it
        // enough frames to converge).
        for _ in 0..<60 {
            XCTAssertTrue(SpectralGateCore.classifyFrame(rms: 0.005, state: &state,
                                                         config: config))
        }
        XCTAssertEqual(state.noiseFloorRMS, 0.005, accuracy: 1e-3)
        // Clear speech: rms above multiplier × floor and above the
        // absolute minimum.
        XCTAssertFalse(SpectralGateCore.classifyFrame(rms: 0.05, state: &state,
                                                      config: config))
        XCTAssertTrue(state.speechActive)
    }

    func testClassifyLatchesUntilCaptureReset() {
        var state = SpectralGateAdaptiveState()
        _ = SpectralGateCore.classifyFrame(rms: 0.05, state: &state, config: config)
        XCTAssertTrue(state.speechActive)
        // Once speech is seen, even dead quiet is NOT noise-only — the
        // estimate stays frozen for the rest of the capture.
        XCTAssertFalse(SpectralGateCore.classifyFrame(rms: 0.001, state: &state,
                                                      config: config))
        // The capture-boundary reset (SpectralGateState.resetForCapture)
        // clears the latch but keeps the learned floor.
        state.speechActive = false
        state.noiseFloorRMS = 0.005
        XCTAssertTrue(SpectralGateCore.classifyFrame(rms: 0.001, state: &state,
                                                     config: config))
    }

    // MARK: - Frame round-trip

    func testDenoiseFrameAtUnityGainIsWindowedRoundTrip() {
        // Cold state (zero noise estimate) ⇒ gains ≈ 1 ⇒ the synthesis
        // must reconstruct the windowed input: out ≈ frame · w². This
        // pins FFT round-trip + window application together.
        let frame = noise(count: 512, amplitude: 0.1, seed: 42)
        var state = makeState()
        let out = SpectralGateCore.denoiseFrame(frame, state: &state,
                                                config: config, fft: fft,
                                                window: window)
        XCTAssertEqual(out.count, frame.count)
        for i in frame.indices {
            XCTAssertEqual(out[i], frame[i] * window[i] * window[i],
                           accuracy: 1e-3, "sample \(i)")
        }
    }

    func testDenoiseFrameSuppressesNoiseOnlyFrame() {
        // Pre-learned room: the estimate equals the frame's own bin
        // magnitudes (converged EMA), adaptive floor high enough that the
        // frame classifies noise-only.
        let frame = noise(count: 512, amplitude: 0.02, seed: 7)
        let windowed = zip(frame, window).map(*)
        let (re, im) = fft.forward(real: windowed)
        let mags = SpectralGateCore.magnitudes(real: re, imag: im)
        var estimate = [Float](repeating: 0, count: mags.count)
        for _ in 0..<30 {
            estimate = SpectralGateCore.trackNoiseEstimate(
                estimate, magnitudes: mags, isNoiseOnly: true, config: config)
        }
        var state = makeState()
        state.noiseEstimate = estimate
        state.adaptive.noiseFloorRMS = 0.1

        let out = SpectralGateCore.denoiseFrame(frame, state: &state,
                                                config: config, fft: fft,
                                                window: window)
        let reductionDb = 10 * log10(energy(out) / energy(frame))
        XCTAssertLessThan(reductionDb, -4, "noise-only frame must be suppressed")
        XCTAssertGreaterThan(reductionDb, -20, "the suppression budget caps it")
    }

    // MARK: - Overlap-add

    func testOverlapAddMixesAndCarriesTail() {
        let (segment, tail) = SpectralGateCore.overlapAdd(
            previousTail: [1, 2], currentFrame: [3, 4, 5, 6], hop: 2)
        XCTAssertEqual(segment, [4, 6], "prev tail + current head")
        XCTAssertEqual(tail, [5, 6], "current tail carries forward")
    }

    func testOverlapAddFirstFrameWithZeroTailIsJustCurrentHead() {
        let (segment, tail) = SpectralGateCore.overlapAdd(
            previousTail: [0, 0], currentFrame: [3, 4, 5, 6], hop: 2)
        XCTAssertEqual(segment, [3, 4])
        XCTAssertEqual(tail, [5, 6])
    }
}
