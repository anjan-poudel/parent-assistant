import XCTest
@testable import ElderlyAssistant

// MARK: - Synthetic audio fixtures (deterministic; no real recordings)

/// Fully deterministic synthetic "voice" generators for speaker-separation
/// tests. No real recordings are committed (privacy — research doc §10);
/// these signals stand in for the calibration corpus until Phase 0
/// (doc §11), which measures real elderly Nepali voices on device.
enum SyntheticAudio {

    /// Harmonic "voice-like" signal: harmonics 1...8 of `f0` with a
    /// 1/k^`tilt` amplitude falloff (tilt < 1 = brighter timbre), a
    /// formant-style spectral peak (a Gaussian gain bump at `formantHz`,
    /// ~200 Hz wide — the spectral-envelope feature that actually
    /// separates speakers for this frontend), a syllabic on/off envelope
    /// (200 ms syllables at `quietRatio` amplitude during gaps — mimics
    /// the ~30 dB speech/silence dynamic the SNR gate expects), plus a
    /// seeded white-noise floor.
    ///
    /// `phase` and `seed` perturb the SAME speaker's takes (power spectra
    /// are phase-invariant, so different phases embed nearly identically);
    /// `f0`/`tilt`/`formantHz` change the SPEAKER. Measured on the first
    /// run: without a formant, two stationary harmonic combs embed
    /// 0.98-similar regardless of f0 — flat 1/k spectra have no
    /// envelope shape to distinguish; the formant is the fixture's
    /// stand-in for a vowel.
    static func harmonicSpeaker(f0: Double,
                                seconds: Double,
                                phase: Double = 0,
                                tilt: Double = 1.0,
                                formantHz: Double? = nil,
                                formantGain: Double = 6.0,
                                quietRatio: Float = 0.02,
                                noiseDbFS: Float = -45,
                                seed: UInt64 = 42,
                                sampleRate: Double = 16_000) -> [Int16] {
        let count = Int(seconds * sampleRate)
        let noiseAmplitude = Float(pow(10.0, Double(noiseDbFS) / 20.0))
        let peakScale: Float = 3000 // ≈ -20.7 dBFS speech peak
        var lcg = LCG(seed: seed)
        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let syllableIndex = Int(t * 1000) / 200
            let amp: Float = syllableIndex % 2 == 0 ? 1.0 : quietRatio
            var signal: Double = 0
            for k in 1...8 {
                let freq = Double(k) * f0
                var gain = 1.0 / pow(Double(k), tilt)
                if let formant = formantHz {
                    let d = (freq - formant) / 200.0
                    gain *= 1.0 + formantGain * exp(-d * d)
                }
                signal += gain * sin(2.0 * Double.pi * freq * t + Double(k) * phase)
            }
            let noise = (lcg.next() * 2 - 1) * noiseAmplitude
            let sample = Float(signal) * amp * peakScale + noise
            let clamped = max(-32767, min(32767, Int32(sample.rounded())))
            pcm[i] = Int16(clamped)
        }
        return pcm
    }

    /// White noise at a constant amplitude (no syllabic structure) — the
    /// "not speech" fixture for quality-gate refusals.
    static func whiteNoise(seconds: Double,
                           amplitude: Float = 3000,
                           seed: UInt64 = 7,
                           sampleRate: Double = 16_000) -> [Int16] {
        let count = Int(seconds * sampleRate)
        var lcg = LCG(seed: seed)
        return (0..<count).map { _ in
            let sample = (lcg.next() * 2 - 1) * amplitude
            return Int16(max(-32767, min(32767, Int32(sample.rounded()))))
        }
    }

    static func silence(seconds: Double, sampleRate: Double = 16_000) -> [Int16] {
        [Int16](repeating: 0, count: Int(seconds * sampleRate))
    }

    /// Deterministic linear congruential generator (Numerical Recipes
    /// constants) — no SystemRandomNumberGenerator, so fixtures reproduce
    /// bit-for-bit across runs.
    struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
        }
    }
}

// MARK: - Fixture speakers

/// Speaker A: 105 Hz fundamental, formant 400 Hz. Speaker B: 300 Hz,
/// brighter tilt, formant 3000 Hz — a deliberately distinct synthetic
/// "other speaker". Measured separation of the shipped frontend on these
/// fixtures (c0-dropped MFCC stats, L2-normalised): same-speaker cosine
/// ≈ 0.997, cross-speaker ≈ 0.18. The parameters were tuned until the
/// margin was wide (not razor-thin): the tests assert same ≥ 0.90 and
/// cross ≤ 0.45, so a ~0.1 shift in the DSP cannot flip the policy.
enum FixtureSpeakers {
    static let aF0: Double = 105
    static let aFormant: Double = 400
    static let bF0: Double = 300
    static let bTilt: Double = 0.4
    static let bFormant: Double = 3000

    static func aUtterance(_ n: Int, seconds: Double = 3.0) -> [Int16] {
        SyntheticAudio.harmonicSpeaker(f0: aF0, seconds: seconds,
                                       phase: Double(n) * 0.9,
                                       formantHz: aFormant,
                                       seed: UInt64(42 + n))
    }

    static func bUtterance(_ n: Int, seconds: Double = 3.0) -> [Int16] {
        SyntheticAudio.harmonicSpeaker(f0: bF0, seconds: seconds,
                                       phase: Double(n) * 0.7,
                                       tilt: bTilt,
                                       formantHz: bFormant,
                                       seed: UInt64(90 + n))
    }
}

// MARK: - In-memory EncryptedLocalStorage double

/// JSON-backed in-memory storage with raw-byte planting (corrupt-payload
/// tests) and a failure switch (persistence-failure paths). Records write
/// order so tests can pin the profile-before-marker invariant.
final class VoiceBiometricInMemoryStorage: EncryptedLocalStorage {
    private(set) var raw: [String: Data] = [:]
    private(set) var writtenKeys: [String] = []
    private(set) var deletedKeys: [String] = []
    var failWrites = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func plantRaw(key: String, data: Data) {
        raw[key] = data
    }

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        guard !failWrites else { return .failure(.encryptedWriteFailed) }
        do {
            raw[key] = try encoder.encode(value)
            writtenKeys.append(key)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard let data = raw[key] else { return .failure(.encryptedReadFailed) }
        do {
            return .success(try decoder.decode(T.self, from: data))
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        raw.removeValue(forKey: key)
        deletedKeys.append(key)
        return .success(())
    }
}

// MARK: - Stub embedder

/// Deterministic embedder stub for threshold/error-path tests: returns
/// whatever embedding the test pinned per call, records what it was fed.
final class StubSpeakerEmbedder: SpeakerEmbedder {
    let requiredSampleRate: Double = 16_000
    let frameLength: Int = 512
    let embeddingDimension: Int = 3
    var embedderID: String = "stub.v1"
    var available: Bool = true
    var isAvailable: Bool { available }

    /// Queue of results returned by `embed` (repeats the last on exhaustion).
    var embedResults: [Result<SpeakerEmbedding, SpeakerEmbeddingError>] = []
    private(set) var embedCalls: [[Int16]] = []
    private(set) var processedFrames: [[Int16]] = []
    private(set) var resetCount = 0

    func process(_ pcm: [Int16]) { processedFrames.append(pcm) }
    func reset() { resetCount += 1 }

    func embed(collectedPCM: [Int16]) -> Result<SpeakerEmbedding, SpeakerEmbeddingError> {
        embedCalls.append(collectedPCM)
        guard !embedResults.isEmpty else {
            return .failure(.processingFailed)
        }
        let result = embedResults[0]
        if embedResults.count > 1 { embedResults.removeFirst() }
        return result
    }

    static func embedding(_ x: Float, _ y: Float, _ z: Float,
                          embedderID: String = "stub.v1") -> SpeakerEmbedding {
        SpeakerEmbedding(values: [x, y, z], embedderID: embedderID)!.l2Normalized()
    }
}

// MARK: - Observability recorder

/// Captures emitted events so tests can pin the outcome-only contract:
/// events exist, carry counts/reasons — and NEVER a score or embedding.
final class SpeakerBiometricEventRecorder: ObservabilityBus {
    private(set) var events: [ObservabilityEvent] = []
    func emit(_ event: ObservabilityEvent) { events.append(event) }
}
