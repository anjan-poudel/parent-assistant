import Foundation
import Accelerate

/// Pure DSP mathematics for the spectral-gate denoiser
/// (docs/research-sections/noise-filter.md P1 front-end). Everything here
/// is frames-in → frames-out: no hidden state, no I/O, no observability —
/// `SpectralGateDenoiser` (the `NoiseSuppressor` implementation) owns all
/// mutable state and threading; this file is the part the unit tests pin
/// down exhaustively.
///
/// The algorithm is the classic conservative spectral gate — deliberately
/// NOT a neural denoiser (DeepFilterNet3-class suppression needs model
/// artifacts, which is P1 step 2 and out of scope here; see the gap note
/// in SpectralGateDenoiser):
///
///  1. Sine-windowed 512-sample frames (32 ms @ 16 kHz), 50% overlap —
///     the same frame geometry the wake word and the VAD use; the sine
///     (sqrt-Hann) window is COLA-exact when squared (analysis ×
///     synthesis).
///  2. vDSP FFT (packed-real convention) → per-bin magnitudes.
///  3. Noise floor: per-bin exponential moving average over frames an
///     adaptive energy threshold classifies noise-only (the same shape
///     and calibrated constants as EnergyVAD's, so the two stages agree
///     on what "quiet" means for this population); frozen during speech.
///  4. Wiener-style per-bin gains with an over-subtraction factor and a
///     hard attenuation floor. Soft gains (no binary mask) to avoid
///     musical noise; the floor caps attenuation so soft/elderly speech
///     is never over-cut ("never remove the user's own speech", doc §6).
///  5. Inverse FFT → sine synthesis window → overlap-add (COLA-exact at
///     50% overlap).
///
/// Honest limits: stationary-noise suppression only (fan, TV hiss,
/// appliance hum, street rumble). It cannot separate competing SPEECH
/// (babble) — that needs the P2 speaker-conditioned gate; and its maximum
/// attenuation is the configured floor, deliberately mild.
struct SpectralGateConfig: Equatable {
    /// FFT/frame size in samples.
    var frameLength: Int = 512
    /// Overlap-add hop in samples (50% overlap).
    var hopLength: Int = 256
    var sampleRate: Double = 16_000

    /// Max per-bin attenuation (linear gain floor) — the suppression
    /// budget. mild = −12 dB, full = −20 dB.
    var gainFloorLinear: Float = 0.25

    /// Over-subtraction factor: divides the SNR before the Wiener map, so
    /// a bin exactly AT the noise estimate gets gain 1/(1+α).
    /// 2.0 → −9.5 dB at the floor level.
    var overSubtraction: Float = 2.0

    /// Per-bin upward-release coefficient for the noise estimate, applied
    /// only on noise-only frames (downward tracking is instant and
    /// ungated — see `trackNoiseEstimate`).
    var noiseUpdateAlpha: Float = 0.25

    /// Absolute per-bin magnitude floor (≈ −96 dBFS). Prevents
    /// divide-by-zero and runaway gains on dead-silent bins.
    var minNoiseMagnitude: Float = 0.000_016

    /// Adaptive energy-threshold constants — mirror EnergyVAD's
    /// calibrated values (`SileroVAD.swift`) so the two stages agree on
    /// what "quiet" means for this user population.
    var speechThresholdMultiplier: Float = 2.5
    var minSpeechThresholdRMS: Float = 0.012
    var maxSpeechThresholdRMS: Float = 0.10
    /// EMA coefficient for the RMS noise floor (EnergyVAD's `floorAlpha`).
    var noiseFloorAlpha: Float = 0.08

    /// Moving-average width in bins for the noise-estimate smoothing
    /// step — the anti-musical-noise pass (see `smoothNoiseEstimate`).
    var noiseSmoothingBins: Int = 5

    /// Presets from the research doc P1 step 3: mild while
    /// wake-listening, full during capture. Both are conservative by
    /// design — the doc's suppression budget is tuned on elderly-voice
    /// clips, not synthetic clean speech.
    static let idleMild = SpectralGateConfig(gainFloorLinear: 0.25)
    static let captureFull = SpectralGateConfig(gainFloorLinear: 0.10)
}

/// Adaptive frame-energy classification state (the EnergyVAD-shaped half
/// of the state; persists across captures as room calibration).
struct SpectralGateAdaptiveState {
    /// EMA of frame RMS over noise-only frames — same meaning as
    /// EnergyVAD's `noiseFloor`.
    var noiseFloorRMS: Float = 0
    /// Once speech is seen in a capture it stays set (the stage does not
    /// end-point — that is the VAD's job).
    var speechActive = false
}

/// All mutable DSP state for one suppressor instance, passed explicitly
/// through the pure core functions so tests can drive every transition.
struct SpectralGateState {
    /// Per-bin noise magnitude estimate (linear FFT magnitudes).
    var noiseEstimate: [Float]
    var adaptive: SpectralGateAdaptiveState

    init(binCount: Int) {
        noiseEstimate = [Float](repeating: 0, count: binCount)
        adaptive = SpectralGateAdaptiveState()
    }

    /// Capture boundary: streaming state resets; the noise estimates
    /// persist (room calibration carries across utterances within a
    /// session — the same contract EnergyVAD documents for its floor).
    mutating func resetForCapture() {
        adaptive.speechActive = false
    }
}

enum SpectralGateCore {

    // MARK: - Windowing

    /// Periodic sine window (sqrt-Hann) of length n — the correct
    /// analysis/synthesis pair for 50%-overlap OLA: with the SAME window
    /// applied on both sides, w²(m) + w²(m − n/2) = sin² + cos² = 1 for
    /// m ≥ n/2 (COLA-exact). A plain Hann fails this when squared
    /// (0.5 + 0.5·cos²), which would ripple the reconstruction.
    static func sineWindow(length: Int) -> [Float] {
        guard length > 1 else { return [1] }
        return (0..<length).map { m in
            sin(.pi * Float(m) / Float(length))
        }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples {
            sum += s * s
        }
        return sqrt(sum / Float(samples.count))
    }

    // MARK: - Real FFT wrapper (vDSP packed-real convention)

    /// Thin wrapper over `vDSP.FFT` (radix-2) using the documented
    /// packed-real convention, verified empirically:
    ///
    ///  - forward input: REAL signal x (length N) packed as two arrays of
    ///    length N/2 — realp = x[0..<N/2], imagp = x[N/2..<N].
    ///  - forward output: packed spectrum (N/2 complex values): realp[0]
    ///    = Re(X₀) (2×-scaled), imagp[0] = Re(X_{N/2}) (Nyquist),
    ///    realp[b]/imagp[b] = Re/Im(X_b) for 1 ≤ b < N/2.
    ///  - inverse: packed spectrum in → packed time out (realp = y[0..<N/2],
    ///    imagp = y[N/2..<N]), round-trip scale 2N (the API's 2× × the
    ///    transform's N) — normalized here so forward→inverse = identity.
    ///
    /// One instance per denoiser; thread-confined to the pipeline's
    /// processing queue (vDSP.FFT instances are not documented as
    /// thread-safe).
    final class FFT {
        let log2n: Int
        private let fft: vDSP.FFT<DSPSplitComplex>?

        init?(log2n: Int) {
            guard let fft = vDSP.FFT(log2n: vDSP_Length(log2n),
                                     radix: .radix2,
                                     ofType: DSPSplitComplex.self) else { return nil }
            self.log2n = log2n
            self.fft = fft
        }

        /// Real input (length N) → packed spectrum (two arrays of length
        /// N/2; the Nyquist bin lives in the imagp[0] slot).
        func forward(real input: [Float]) -> (real: [Float], imag: [Float]) {
            let halfN = input.count / 2
            var re = Array(input[0..<halfN])
            var im = Array(input[halfN..<input.count])
            var outRe = [Float](repeating: 0, count: halfN)
            var outIm = [Float](repeating: 0, count: halfN)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    outRe.withUnsafeMutableBufferPointer { orp in
                        outIm.withUnsafeMutableBufferPointer { oip in
                            let split = DSPSplitComplex(realp: rp.baseAddress!,
                                                        imagp: ip.baseAddress!)
                            var output = DSPSplitComplex(realp: orp.baseAddress!,
                                                         imagp: oip.baseAddress!)
                            fft?.forward(input: split, output: &output)
                        }
                    }
                }
            }
            return (outRe, outIm)
        }

        /// Packed spectrum (as produced by `forward`) → time-domain
        /// signal of length 2·halfN, normalized so the round trip is the
        /// identity (1/(2N)).
        func inverse(real inputRe: [Float], imag inputIm: [Float]) -> [Float] {
            let halfN = inputRe.count
            var re = inputRe
            var im = inputIm
            var outRe = [Float](repeating: 0, count: halfN)
            var outIm = [Float](repeating: 0, count: halfN)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    outRe.withUnsafeMutableBufferPointer { orp in
                        outIm.withUnsafeMutableBufferPointer { oip in
                            let split = DSPSplitComplex(realp: rp.baseAddress!,
                                                        imagp: ip.baseAddress!)
                            var output = DSPSplitComplex(realp: orp.baseAddress!,
                                                         imagp: oip.baseAddress!)
                            fft?.inverse(input: split, output: &output)
                        }
                    }
                }
            }
            let n = halfN * 2
            let scale = 1.0 / Float(2 * n)
            return vDSP.multiply(scale, outRe + outIm)
        }
    }

    // MARK: - Magnitudes

    /// Per-bin magnitudes for the packed spectrum (bins 0...N/2; the
    /// Nyquist bin is the imagp[0] slot). Bin scales are self-consistent
    /// per bin, which is all the gain map needs (ratios).
    static func magnitudes(real: [Float], imag: [Float]) -> [Float] {
        let halfN = real.count
        var mags = [Float](repeating: 0, count: halfN + 1)
        mags[0] = abs(real[0])
        for b in 1..<halfN {
            mags[b] = sqrt(real[b] * real[b] + imag[b] * imag[b])
        }
        mags[halfN] = abs(imag[0])
        return mags
    }

    // MARK: - Noise-only classification (adaptive energy threshold)

    /// Mirrors EnergyVAD's pre-speech loop: threshold =
    /// clamp(multiplier × noiseFloor, min, max); frames below it are
    /// noise-only and update the floor. Returns true for noise-only.
    static func classifyFrame(rms: Float,
                              state: inout SpectralGateAdaptiveState,
                              config: SpectralGateConfig) -> Bool {
        if state.speechActive {
            // Speech already seen this capture: the estimate stays frozen
            // (a pause is not evidence about the room's noise). This is
            // the conservative choice — it can only UNDER-suppress, never
            // eat speech.
            return false
        }
        let threshold = max(config.minSpeechThresholdRMS,
                            min(config.maxSpeechThresholdRMS,
                                state.noiseFloorRMS * config.speechThresholdMultiplier))
        if rms >= threshold {
            state.speechActive = true
            return false
        }
        state.noiseFloorRMS += config.noiseFloorAlpha * (rms - state.noiseFloorRMS)
        return true
    }

    // MARK: - Noise estimate (per-bin, speech-frozen EMA)

    /// Per-bin noise floor, shaped so it can never eat speech: an
    /// exponential moving average that updates ONLY on noise-only frames
    /// (the adaptive energy classifier gates it). During speech the
    /// estimate is FROZEN — a sustained speech bin (a formant, a tone)
    /// can never drag it up into the speech, and it can never chase
    /// noise dips below the room level (which would weaken the Wiener
    /// gain toward unity — the failure this shape exists to avoid).
    /// The deliberate consequence: a noise that STARTS mid-utterance is
    /// only learned after the next noise-only pause — the conservative
    /// choice (the stage under-suppresses, never eats speech). Zero-init
    /// means the very first frames pass through unattenuated (snr → ∞
    /// against a zero floor): the safe cold-start; across captures the
    /// estimate persists (room calibration).
    static func trackNoiseEstimate(_ noise: [Float],
                                   magnitudes: [Float],
                                   isNoiseOnly: Bool,
                                   config: SpectralGateConfig) -> [Float] {
        guard isNoiseOnly else { return noise }
        var updated = noise
        let oneMinusAlpha = 1 - config.noiseUpdateAlpha
        for b in updated.indices {
            updated[b] = max(oneMinusAlpha * noise[b] + config.noiseUpdateAlpha * magnitudes[b],
                             config.minNoiseMagnitude)
        }
        return updated
    }

    // MARK: - Gains

    /// Wiener-style per-bin gains with over-subtraction, clamped to
    /// [gainFloor, 1]. Never amplifies; the floor is the hard attenuation
    /// cap (the suppression budget).
    static func gains(magnitudes: [Float],
                      noise: [Float],
                      config: SpectralGateConfig) -> [Float] {
        var g = [Float](repeating: 0, count: magnitudes.count)
        for b in magnitudes.indices {
            let mag = magnitudes[b]
            let noiseFloor = max(noise[b], config.minNoiseMagnitude)
            // snrEff = power ratio / over-subtraction
            let snrEff = (mag * mag) / (noiseFloor * noiseFloor * config.overSubtraction)
            g[b] = max(min(snrEff / (snrEff + 1), 1), config.gainFloorLinear)
        }
        return g
    }

    /// Short moving average of the NOISE ESTIMATE across bins — the
    /// anti-musical-noise step. Noise spectra are smooth, so smoothing
    /// the floor (never the gains) removes the per-bin Rayleigh speckle
    /// that would make the suppression field itself sound tonal, while
    /// speech peaks pass through at unity. Deliberately NOT applied to
    /// the gains: a gain blur shaves tone/formant peaks by several dB
    /// (the soft-speech killer), and a gain dilation over a Rayleigh
    /// field lifts the whole floor toward the neighborhood maxima
    /// (measured: −5.6 dB → −1.4 dB suppression).
    static func smoothNoiseEstimate(_ noise: [Float], width: Int) -> [Float] {
        guard width > 1, noise.count > width else { return noise }
        var out = noise
        let radius = width / 2
        for i in 1..<(noise.count - 1) {
            var acc: Float = 0
            var n: Float = 0
            for j in max(0, i - radius)...min(noise.count - 1, i + radius) {
                acc += noise[j]
                n += 1
            }
            out[i] = acc / n
        }
        return out
    }

    // MARK: - Synthesis

    /// Applies per-bin gains to the packed spectrum and returns the
    /// windowed synthesis frame (length N) — sine synthesis window,
    /// inverse FFT normalized to unity round-trip.
    static func synthesize(real: [Float], imag: [Float], gains: [Float],
                           window: [Float], fft: FFT) -> [Float] {
        let halfN = real.count
        var re = real
        var im = imag
        // Packed layout: realp[0] is the DC bin (gain index 0); imagp[0]
        // is the NYQUIST bin (gain index halfN).
        re[0] *= gains[0]
        im[0] *= gains[halfN]
        for b in 1..<halfN {
            re[b] *= gains[b]
            im[b] *= gains[b]
        }
        let time = fft.inverse(real: re, imag: im)
        return vDSP.multiply(time, window)
    }

    // MARK: - Frame-level pure core

    /// One denoise step: N raw time samples in → N windowed synthesis
    /// samples out. All mutable state passes through `state` explicitly —
    /// this is the pure frames-in/frames-out function the unit tests
    /// drive directly.
    static func denoiseFrame(_ frame: [Float],
                             state: inout SpectralGateState,
                             config: SpectralGateConfig,
                             fft: FFT,
                             window: [Float]) -> [Float] {
        let windowed = vDSP.multiply(frame, window)
        let (re, im) = fft.forward(real: windowed)
        let mags = magnitudes(real: re, imag: im)
        let isNoiseOnly = classifyFrame(rms: rms(frame),
                                        state: &state.adaptive,
                                        config: config)
        state.noiseEstimate = trackNoiseEstimate(state.noiseEstimate,
                                                 magnitudes: mags,
                                                 isNoiseOnly: isNoiseOnly,
                                                 config: config)
        let smoothedFloor = smoothNoiseEstimate(state.noiseEstimate,
                                                width: config.noiseSmoothingBins)
        let g = gains(magnitudes: mags, noise: smoothedFloor, config: config)
        return synthesize(real: re, imag: im, gains: g, window: window, fft: fft)
    }

    // MARK: - Overlap-add mixing (pure)

    /// COLA-exact overlap-add for 50%-overlapped synthesis frames.
    /// `previousTail` is the previous frame's [H..<N) half (zero-filled
    /// for the stream's first frame); `currentFrame` is the new windowed
    /// synthesis frame (length N = 2·hop). The emitted segment mixes the
    /// two contributions; the current frame's tail carries forward.
    static func overlapAdd(previousTail: [Float], currentFrame: [Float],
                           hop: Int) -> (segment: [Float], newTail: [Float]) {
        precondition(previousTail.count == hop && currentFrame.count == hop * 2)
        var segment = [Float](repeating: 0, count: hop)
        for i in 0..<hop {
            segment[i] = previousTail[i] + currentFrame[i]
        }
        return (segment, Array(currentFrame[hop..<(hop * 2)]))
    }
}
