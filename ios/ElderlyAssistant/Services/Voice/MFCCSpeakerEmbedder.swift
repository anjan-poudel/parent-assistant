import Foundation

/// Deterministic, model-free speaker embedder: MFCC frames (12 cepstra
/// c1…c12 — c0 dropped for gain invariance, see `MFCCFeatureExtractor` —
/// plus delta + delta-delta = 36-d) aggregated over the utterance by mean
/// and standard-deviation statistics into a 72-d vector, L2-normalised.
///
/// WHY THIS EXISTS (honest gap, research doc §4.1/§11 Phase 0):
/// the recommended production embedder is ECAPA-TDNN fp16 via CoreML
/// (~40 MB, VoxCeleb1 EER ≈ 0.80%). Shipping it requires the Phase-0
/// spike — a CoreML conversion with a Swift fbank frontend, an A14-family
/// latency measurement, and (open question #2) a licence-chain check on
/// the checkpoint's VoxCeleb training-data provenance — none of which
/// exists in this repo yet. This embedder is the deliberate interim: it
/// needs no model file, no network, no licence, runs entirely on-device
/// in pure Swift, and is fully deterministic (no random seeds, no float
/// nondeterminism across platforms of concern — fixed integer frame
/// sizes, fixed filterbank). Its speaker-discriminative power is a
/// classical MFCC baseline — real-world EER is unmeasured and certainly
/// far above ECAPA's ~1%; thresholds must be recalibrated on real
/// recordings before this path is used for anything security-sensitive.
/// `embedderID` ("mfcc.stats.v1") is the versioned marker: any template
/// enrolled under this embedder is rejected wholesale once the CoreML
/// embedder lands, forcing re-enrollment instead of silently mixing
/// incompatible scores (research doc §10).
///
/// FORWARD-COMPATIBILITY: the mel-filterbank frontend below
/// (`MelFilterbankFrontend` — pre-emphasis, Hamming frames, FFT, 26
/// triangular mel filters, log) is exactly the "fbank computed in Swift,
/// encoder-only model graph" frontend the research doc §4.2 prescribes
/// for the ECAPA CoreML path. `MFCCFeatureExtractor` is the only piece
/// replaced by the encoder; the streaming `process(_:)` contract and the
/// embedder seam survive.
final class MFCCSpeakerEmbedder: SpeakerEmbedder {

    let requiredSampleRate: Double = 16_000
    let frameLength: Int = 512
    let embeddingDimension: Int = MFCCFeatureExtractor.featureDimension * 2 // mean + std
    let embedderID: String = "mfcc.stats.v1"

    /// Streaming-accumulated frames for the `process(_:)` contract. The
    /// verification path (`embed(collectedPCM:)`) never reads or mutates
    /// this buffer — it is here so the embedder can be driven exactly
    /// like `WakeWordEngine` from a mic tap in the future passive-scoring
    /// path (research doc §3.1, insertion point b).
    private var streamed: [Int16] = []

    /// Embedding floor: utterances below this RMS are silence, not voice.
    /// -50 dBFS is well below any plausible speech at conversational
    /// distance; the quality gate (SpeakerVerifier) uses a stricter
    /// signal-quality floor on top of this hard silence refusal.
    static let silenceFloorDbFS: Float = -50

    func process(_ pcm: [Int16]) {
        streamed.append(contentsOf: pcm)
    }

    func reset() {
        streamed.removeAll(keepingCapacity: true)
    }

    func embed(collectedPCM: [Int16]) -> Result<SpeakerEmbedding, SpeakerEmbeddingError> {
        guard !collectedPCM.isEmpty else {
            return .failure(.audioTooShort(netSpeechSeconds: 0))
        }
        let rmsDb = Self.rmsDbFS(collectedPCM)
        guard rmsDb >= Self.silenceFloorDbFS else {
            return .failure(.audioTooQuiet(rmsDbFS: rmsDb))
        }

        let frames = MelFilterbankFrontend.frames(collectedPCM)
        guard let mfccs = MFCCFeatureExtractor.mfccFrames(fromFrames: frames),
              !mfccs.isEmpty else {
            return .failure(.audioTooShort(netSpeechSeconds: 0))
        }
        // One frame = 10 ms hop; below ~0.3 s of audio the stats vector is
        // noise (research doc §7.4: net speech ≥ ~1 s at the gate — the
        // embedder floor is deliberately lower, the gate is the policy).
        let netSpeechSeconds = Float(mfccs.count) * MFCCFeatureExtractor.frameHopSeconds
        guard netSpeechSeconds >= 0.25 else {
            return .failure(.audioTooShort(netSpeechSeconds: netSpeechSeconds))
        }

        var means = [Float](repeating: 0, count: MFCCFeatureExtractor.featureDimension)
        for frame in mfccs {
            for i in 0..<MFCCFeatureExtractor.featureDimension {
                means[i] += frame[i]
            }
        }
        let count = Float(mfccs.count)
        for i in 0..<means.count { means[i] /= count }

        var stds = [Float](repeating: 0, count: MFCCFeatureExtractor.featureDimension)
        for frame in mfccs {
            for i in 0..<MFCCFeatureExtractor.featureDimension {
                let delta = frame[i] - means[i]
                stds[i] += delta * delta
            }
        }
        for i in 0..<stds.count { stds[i] = (stds[i] / count).squareRoot() }

        let vector = means + stds
        guard let embedding = SpeakerEmbedding(values: vector, embedderID: embedderID) else {
            return .failure(.processingFailed)
        }
        return .success(embedding.l2Normalized())
    }

    /// RMS in dBFS (20·log10(rms / 32768)); -100 for a silent buffer.
    static func rmsDbFS(_ pcm: [Int16]) -> Float {
        guard !pcm.isEmpty else { return -100 }
        var sumSq: Double = 0
        for s in pcm {
            let v = Double(s)
            sumSq += v * v
        }
        let rms = (sumSq / Double(pcm.count)).squareRoot()
        guard rms > 0 else { return -100 }
        return Float(20 * log10(rms / 32768.0))
    }
}

// MARK: - Mel filterbank frontend (pure, deterministic)

/// Mel filterbank + MFCC + delta features over 16 kHz int16 PCM.
/// Pure static functions — no state, no randomness, no I/O — so tests
/// pin exact values and the future CoreML fbank port can be validated
/// against this file bit-for-bit (research doc §4.2).
enum MelFilterbankFrontend {

    /// 25 ms frame / 10 ms hop at 16 kHz — the standard speech-feature
    /// frontend configuration the research doc's fbank prescription
    /// assumes.
    static let frameLengthSamples = 400
    static let frameHopSamples = 160
    static let frameHopSeconds: Float = 0.010
    /// FFT size the frames are zero-padded to (radix-2 requirement).
    static let fftLength = 512
    /// Mel filterbank size (26 is the SpeechBrain/ECAPA convention the
    /// doc's fbank frontend must eventually match).
    static let melFilterCount = 26
    /// Analysis band 0–8 kHz.
    static let maxFrequencyHz: Float = 8000
    /// Pre-emphasis coefficient (standard speech value).
    static let preEmphasis: Float = 0.97

    static func frames(_ pcm: [Int16]) -> [[Float]] {
        let n = pcm.count
        guard n >= frameLengthSamples else { return [] }
        var result: [[Float]] = []
        var start = 0
        while start + frameLengthSamples <= n {
            var frame = [Float](repeating: 0, count: frameLengthSamples)
            var previous = Float(pcm[start]) // no pre-emphasis before sample 0
            for i in 0..<frameLengthSamples {
                let sample = Float(pcm[start + i])
                let emphasized = sample - preEmphasis * previous
                // Hamming window: 0.54 - 0.46·cos(2πi/(N-1))
                let window = 0.54 - 0.46 * Float(cos(2.0 * Double.pi * Double(i) / Double(frameLengthSamples - 1)))
                frame[i] = emphasized * window
                previous = sample
            }
            result.append(frame)
            start += frameHopSamples
        }
        return result
    }

    /// 26 log-mel energies per frame (the fbank matrix a CoreML encoder
    /// would consume; the deterministic reference for that port).
    static func logMelEnergies(fromFrames frames: [[Float]]) -> [[Float]] {
        return frames.map { frame in
            let spectrum = powerSpectrum(frame)
            return applyMelFilterbank(spectrum)
        }
    }

    // MARK: - Internals

    /// |FFT|² over bins 0...(fftLength/2), zero-padded radix-2 FFT
    /// (deterministic iterative Cooley-Tukey, bit-reversal permutation).
    static func powerSpectrum(_ frame: [Float]) -> [Float] {
        var re = frame
        var im = [Float](repeating: 0, count: fftLength)
        re.append(contentsOf: [Float](repeating: 0, count: fftLength - frame.count))

        // Bit-reversal permutation (length is a power of two by contract).
        var j = 0
        for i in 1..<fftLength {
            var bit = fftLength >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }

        var length = 2
        while length <= fftLength {
            let half = length >> 1
            let angle = -2.0 * Double.pi / Double(length)
            let wRe = Float(cos(angle))
            let wIm = Float(sin(angle))
            var start = 0
            while start < fftLength {
                var wCurRe: Float = 1
                var wCurIm: Float = 0
                for k in 0..<half {
                    let even = start + k
                    let odd = even + half
                    let tRe = wCurRe * re[odd] - wCurIm * im[odd]
                    let tIm = wCurRe * im[odd] + wCurIm * re[odd]
                    re[odd] = re[even] - tRe
                    im[odd] = im[even] - tIm
                    re[even] = re[even] + tRe
                    im[even] = im[even] + tIm
                    let nextRe = wCurRe * wRe - wCurIm * wIm
                    wCurIm = wCurRe * wIm + wCurIm * wRe
                    wCurRe = nextRe
                }
                start += length
            }
            length <<= 1
        }

        let bins = fftLength / 2 + 1
        var spectrum = [Float](repeating: 0, count: bins)
        for i in 0..<bins {
            spectrum[i] = re[i] * re[i] + im[i] * im[i]
        }
        return spectrum
    }

    /// Triangular filters evenly spaced in mel scale over 0–maxFrequencyHz,
    /// applied to a power spectrum of fftLength/2+1 bins at 16 kHz.
    static func applyMelFilterbank(_ spectrum: [Float]) -> [Float] {
        let sampleRate: Float = 16_000
        let bins = fftLength / 2 + 1

        func hzToMel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }

        let melLow = hzToMel(0)
        let melHigh = hzToMel(maxFrequencyHz)
        let pointCount = melFilterCount + 2
        var points = [Float](repeating: 0, count: pointCount)
        for i in 0..<pointCount {
            let mel = melLow + (melHigh - melLow) * Float(i) / Float(pointCount - 1)
            points[i] = melToHz(mel)
        }
        // Bin index of a frequency: bin = hz / (sampleRate / fftLength).
        let hzPerBin = sampleRate / Float(fftLength)
        func bin(of hz: Float) -> Float { hz / hzPerBin }

        var result = [Float](repeating: 0, count: melFilterCount)
        for f in 0..<melFilterCount {
            let left = bin(of: points[f])
            let center = bin(of: points[f + 1])
            let right = bin(of: points[f + 2])
            var energy: Float = 0
            for binIndex in 0..<bins {
                let b = Float(binIndex)
                let weight: Float
                if b <= left || b >= right {
                    weight = 0
                } else if b < center {
                    weight = (b - left) / (center - left)
                } else {
                    weight = (right - b) / (right - center)
                }
                if weight > 0 {
                    energy += weight * spectrum[binIndex]
                }
            }
            // Log floor: 1e-8 keeps silence deterministic instead of -inf.
            result[f] = log(max(energy, 1e-8))
        }
        return result
    }
}

// MARK: - MFCC features

enum MFCCFeatureExtractor {

    static let cepstraCount = 12
    static let featureDimension = cepstraCount * 3 // cepstra + Δ + ΔΔ
    static let frameHopSeconds = MelFilterbankFrontend.frameHopSeconds

    /// 36-d MFCC (+Δ+ΔΔ) per frame; nil when the signal produced no frames.
    ///
    /// The cepstra are c1…c12 — c0 is DELIBERATELY dropped. c0 is the sum
    /// of the log-mel energies: total loudness. It dominates any
    /// L2-normalised stats vector (measured: ~0.96 of the unit mass on
    /// synthetic fixtures, which pushed two very different synthetic
    /// speakers to cosine 0.98) and it tracks recording gain, not the
    /// speaker. The c1…c12 DCT coefficients are exactly gain-invariant
    /// (a constant offset in the log-mel domain contributes nothing to
    /// k ≥ 1), so dropping c0 makes the embedding loudness-robust AND
    /// speaker-discriminative — the standard MFCC design choice.
    static func mfccFrames(fromFrames frames: [[Float]]) -> [[Float]]? {
        guard !frames.isEmpty else { return nil }
        var cepstraFrames: [[Float]] = []
        for frame in frames {
            let energies = MelFilterbankFrontend.applyMelFilterbank(
                MelFilterbankFrontend.powerSpectrum(frame))
            var cepstra = [Float](repeating: 0, count: cepstraCount)
            // DCT-II (unscaled): c[k] = Σ logmel[j]·cos(π·k·(j+0.5)/J),
            // for k = 1…12 (k = 0 skipped — see the type comment).
            for k in 1...cepstraCount {
                var sum: Float = 0
                for j in 0..<energies.count {
                    sum += energies[j] * Float(cos(Double.pi * Double(k) * (Double(j) + 0.5) / Double(energies.count)))
                }
                cepstra[k - 1] = sum
            }
            cepstraFrames.append(cepstra)
        }
        var result: [[Float]] = []
        for t in 0..<cepstraFrames.count {
            result.append(deltaAppended(cepstraFrames, at: t))
        }
        return result
    }

    /// Appends symmetric-window (W=2) delta and delta-delta to frame t's
    /// cepstra. Edge frames use the window they have (shrink at the
    /// boundary) — deterministic and bounded, never padded with zeros
    /// that would fabricate static "frames" at the utterance edges.
    private static func deltaAppended(_ frames: [[Float]], at t: Int) -> [Float] {
        var feature = frames[t]
        let delta = deltaFeature(frames, at: t)
        feature.append(contentsOf: delta)
        let deltaDelta = deltaFeatureOfDeltas(frames, at: t)
        feature.append(contentsOf: deltaDelta)
        return feature
    }

    private static func deltaFeature(_ frames: [[Float]], at t: Int) -> [Float] {
        let window = 2
        let range = max(0, t - window)...min(frames.count - 1, t + window)
        var numerator = [Float](repeating: 0, count: cepstraCount)
        var denominator: Float = 0
        for i in range {
            let w = Float(i - t)
            denominator += w * w
            for c in 0..<cepstraCount {
                numerator[c] += w * frames[i][c]
            }
        }
        guard denominator > 0 else {
            return [Float](repeating: 0, count: cepstraCount)
        }
        return numerator.map { $0 / denominator }
    }

    private static func deltaFeatureOfDeltas(_ frames: [[Float]], at t: Int) -> [Float] {
        let window = 2
        let range = max(0, t - window)...min(frames.count - 1, t + window)
        var numerator = [Float](repeating: 0, count: cepstraCount)
        var denominator: Float = 0
        for i in range {
            let w = Float(i - t)
            denominator += w * w
            let deltaAtI = deltaFeature(frames, at: i)
            for c in 0..<cepstraCount {
                numerator[c] += w * deltaAtI[c]
            }
        }
        guard denominator > 0 else {
            return [Float](repeating: 0, count: cepstraCount)
        }
        return numerator.map { $0 / denominator }
    }
}
