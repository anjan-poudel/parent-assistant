import XCTest
@testable import ElderlyAssistant

/// Deterministic fallback embedder (Services/Voice/MFCCSpeakerEmbedder.swift)
/// — the model-free interim until the ECAPA CoreML spike lands (research
/// doc §4.1/§11). Tests pin: determinism (same input → identical bytes of
/// embedding), same-speaker/cross-speaker separation on synthetic fixtures,
/// silence/too-short refusals, and the frontend's contract values.
final class MFCCSpeakerEmbedderTests: XCTestCase {

    private let embedder = MFCCSpeakerEmbedder()

    // MARK: - Contract

    func testContractValues() {
        XCTAssertEqual(embedder.requiredSampleRate, 16_000)
        XCTAssertEqual(embedder.frameLength, 512)
        XCTAssertEqual(embedder.embeddingDimension, 72) // 36 features × (mean + std)
        XCTAssertEqual(embedder.embedderID, "mfcc.stats.v1")
        XCTAssertTrue(embedder.isAvailable)
    }

    // MARK: - Determinism

    func testSameInputEmbedsIdentically() {
        let pcm = FixtureSpeakers.aUtterance(1)
        let first = try! embedder.embed(collectedPCM: pcm).get()
        let second = try! embedder.embed(collectedPCM: pcm).get()
        XCTAssertEqual(first, second,
                       "the fallback embedder must be bit-for-bit deterministic")
        XCTAssertEqual(first.values.count, 72)
    }

    func testEmbeddingIsUnitNorm() {
        let embedding = try! embedder.embed(collectedPCM: FixtureSpeakers.aUtterance(1)).get()
        var normSq: Float = 0
        for v in embedding.values { normSq += v * v }
        XCTAssertEqual(normSq, 1.0, accuracy: 1e-4,
                       "embeddings are L2-normalised by contract (doc §4.3)")
    }

    func testEmbeddingCarriesEmbedderID() {
        let embedding = try! embedder.embed(collectedPCM: FixtureSpeakers.aUtterance(1)).get()
        XCTAssertEqual(embedding.embedderID, "mfcc.stats.v1")
    }

    // MARK: - Same-speaker separation

    func testSameSpeakerDifferentTakesScoreHigh() {
        // Same f0/tilt, different phase + noise seed + duration — the
        // synthetic stand-in for "same speaker, two utterances".
        let take1 = try! embedder.embed(collectedPCM: FixtureSpeakers.aUtterance(1, seconds: 3.0)).get()
        let take2 = try! embedder.embed(collectedPCM: FixtureSpeakers.aUtterance(2, seconds: 2.6)).get()
        let similarity = SpeakerEmbedding.cosine(take1, take2)!
        XCTAssertGreaterThanOrEqual(similarity, 0.90,
                                    "same-speaker synthetic takes must embed close together (got \(similarity))")
    }

    // MARK: - Cross-speaker separation

    func testDifferentSpeakersScoreLowerThanSameSpeaker() {
        let a1 = try! embedder.embed(collectedPCM: FixtureSpeakers.aUtterance(1)).get()
        let a2 = try! embedder.embed(collectedPCM: FixtureSpeakers.aUtterance(2)).get()
        let b1 = try! embedder.embed(collectedPCM: FixtureSpeakers.bUtterance(1)).get()

        let sameSpeaker = SpeakerEmbedding.cosine(a1, a2)!
        let crossSpeaker = SpeakerEmbedding.cosine(a1, b1)!

        // The separation margin the verifier's threshold needs to exist:
        // same-speaker must clear the default accept threshold (0.55)
        // while the other speaker lands decisively below it. Exact values
        // are fixture-dependent; the margins leave room for the DSP to be
        // tuned without flipping the policy result.
        XCTAssertGreaterThanOrEqual(sameSpeaker, 0.90,
                                    "same-speaker score too low (got \(sameSpeaker))")
        XCTAssertLessThanOrEqual(crossSpeaker, 0.45,
                                 "cross-speaker score too high (got \(crossSpeaker))")
        XCTAssertGreaterThan(sameSpeaker - crossSpeaker, 0.4,
                             "separation margin too thin (same \(sameSpeaker), cross \(crossSpeaker))")
    }

    // MARK: - Refusals (never a garbage template)

    func testEmptyBufferRefuses() {
        XCTAssertEqual(embedder.embed(collectedPCM: []),
                       .failure(.audioTooShort(netSpeechSeconds: 0)))
    }

    func testSilenceRefusesAsTooQuiet() {
        let result = embedder.embed(collectedPCM: SyntheticAudio.silence(seconds: 3))
        guard case .failure(.audioTooQuiet(let db)) = result else {
            return XCTFail("expected .audioTooQuiet, got \(result)")
        }
        XCTAssertLessThan(db, MFCCSpeakerEmbedder.silenceFloorDbFS)
    }

    func testBarelyAudibleRefuses() {
        // -60 dBFS constant tone: above absolute zero, below the floor.
        var pcm: [Int16] = []
        for i in 0..<(3 * 16_000) {
            pcm.append(Int16((sin(2 * Double.pi * 200 * Double(i) / 16_000) * 10).rounded()))
        }
        guard case .failure(.audioTooQuiet) = embedder.embed(collectedPCM: pcm) else {
            return XCTFail("expected .audioTooQuiet for a -60 dBFS tone")
        }
    }

    func testTinyUtteranceRefusesAsTooShort() {
        // 0.1 s: enough amplitude, not enough frames for a stats vector.
        let pcm = FixtureSpeakers.aUtterance(1, seconds: 0.1)
        guard case .failure(.audioTooShort(let seconds)) = embedder.embed(collectedPCM: pcm) else {
            return XCTFail("expected .audioTooShort")
        }
        XCTAssertLessThan(seconds, 0.25)
    }

    // MARK: - Streaming contract

    func testProcessAccumulatesAndResetClears() {
        let frame = [Int16](repeating: 100, count: embedder.frameLength)
        embedder.process(frame)
        // No observable buffer access by design (streaming is a future
        // contract); the test pins that process/reset are harmless and
        // that embed() ignores streamed state entirely.
        let pcm = FixtureSpeakers.aUtterance(1)
        let before = try! embedder.embed(collectedPCM: pcm).get()
        embedder.process(frame)
        embedder.reset()
        let after = try! embedder.embed(collectedPCM: pcm).get()
        XCTAssertEqual(before, after,
                       "embed(collectedPCM:) must be stateless w.r.t. the stream")
    }

    // MARK: - Frontend contract values

    func testFrontendFramingGeometry() {
        // 3.0 s at 16 kHz = 48 000 samples → 25 ms frames on a 10 ms hop:
        // starts at 0…47 600, step 160 → 298 frames.
        let frames = MelFilterbankFrontend.frames(FixtureSpeakers.aUtterance(1, seconds: 3.0))
        XCTAssertEqual(frames.count, 298,
                       "frame count must follow (samples - frame)/hop + 1")
        XCTAssertEqual(frames.first?.count, MelFilterbankFrontend.frameLengthSamples)
    }

    func testMFCCFrameDimensions() {
        let frames = MelFilterbankFrontend.frames(FixtureSpeakers.aUtterance(1, seconds: 1.0))
        let mfccs = MFCCFeatureExtractor.mfccFrames(fromFrames: frames)!
        XCTAssertFalse(mfccs.isEmpty)
        XCTAssertEqual(mfccs.first!.count, 36) // 12 cepstra (c0 dropped) + Δ + ΔΔ
        XCTAssertTrue(mfccs.first!.allSatisfy { $0.isFinite },
                      "every feature must be finite (no -inf from log(0))")
    }

    func testLogMelDimensions() {
        let frames = MelFilterbankFrontend.frames(FixtureSpeakers.aUtterance(1, seconds: 1.0))
        let energies = MelFilterbankFrontend.logMelEnergies(fromFrames: frames)
        XCTAssertEqual(energies.first!.count, MelFilterbankFrontend.melFilterCount)
        XCTAssertTrue(energies.first!.allSatisfy { $0.isFinite })
    }

    func testPowerSpectrumIsParsevalBounded() {
        // |FFT|² of a windowed frame: total power must equal the time-domain
        // energy (Parseval) up to float error — pins the FFT implementation.
        let frame = MelFilterbankFrontend.frames(FixtureSpeakers.aUtterance(1, seconds: 0.5)).first!
        let spectrum = MelFilterbankFrontend.powerSpectrum(frame)
        XCTAssertEqual(spectrum.count, MelFilterbankFrontend.fftLength / 2 + 1)
        var timeEnergy: Float = 0
        for v in frame { timeEnergy += v * v }
        var freqEnergy: Float = 0
        for i in 0..<spectrum.count {
            freqEnergy += (i == 0 || i == spectrum.count - 1) ? spectrum[i] : 2 * spectrum[i]
        }
        let fftLength = Float(MelFilterbankFrontend.fftLength)
        XCTAssertEqual(freqEnergy / fftLength, timeEnergy, accuracy: timeEnergy * 0.05,
                       "FFT must conserve energy (Parseval)")
    }
}
