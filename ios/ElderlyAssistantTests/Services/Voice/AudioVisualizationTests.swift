import XCTest
import Foundation
import AVFoundation
@testable import ElderlyAssistant

/// Pure-logic tests for the audio-reactive hero's signal math
/// ([AUDIO-REACTIVE-HERO], 2026-10-14 — see
/// `Services/Voice/AudioVisualization.swift` for the owner's verdict and
/// the design): frame RMS + band extraction, the dB display mapping,
/// attack/release ballistics, the publish throttle, the playback band
/// track (build + interpolation), and the publisher's owner-switch
/// priority. No UI, no audio hardware, no live engine: every input is a
/// synthesized buffer or a WAV this file writes itself, so the suite is
/// deterministic on every machine.
final class AudioVisualizationTests: XCTestCase {

    private let fft = SpectralGateCore.FFT(log2n: 9)!
    private let frameLength = AudioLevelExtraction.fftLength
    private let sampleRate: Double = 16_000

    // MARK: - Helpers

    /// Float sine samples at `amplitude` — the shape every extraction
    /// assertion is built on.
    private func sine(freq: Double, count: Int, amplitude: Float,
                      sampleRate: Double) -> [Float] {
        (0..<count).map { n in
            amplitude * sin(Float(2 * .pi * freq * Double(n) / sampleRate))
        }
    }

    /// The same sine as Int16 PCM, the exact shape the pipeline's
    /// capture fan-out hands the visualization tap.
    private func sinePCM(freq: Double, count: Int, amplitude: Double,
                         sampleRate: Double) -> [Int16] {
        (0..<count).map { n in
            Int16((amplitude * 32767.0 * sin(2 * .pi * freq * Double(n) / sampleRate))
                .rounded())
        }
    }

    /// A 16-bit PCM WAV written through AVAudioFile's own processing
    /// pipeline (float buffer in, int16 file out) — the canonical
    /// write recipe, and the same container Piper replies ship in.
    /// Linear amplitude ramp so adjacent overlap frames differ and the
    /// interpolation assertions have something real to interpolate.
    private func writeRampedToneWAV(freq: Double,
                                    seconds: Double,
                                    sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-viz-tests-\(UUID().uuidString).wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let count = Int(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = buffer.floatChannelData![0]
        for i in 0..<count {
            let amp = 0.02 + 0.06 * Double(i) / Double(count)
            samples[i] = Float(amp * sin(2 * .pi * freq * Double(i) / sampleRate))
        }
        try file.write(from: buffer)
        return url
    }

    /// Narrow test double for the speaker seam — the publisher's timer
    /// pull is exercised without any AVAudioPlayer or hardware.
    private final class StubSpeakerSource: SpeakerLevelSource {
        var elapsed: TimeInterval = 0
        var envelope: Double? = 0.5
        var bands = [0.1, 0.2, 0.3, 0.4, 0.5]
        func envelopeLevel() -> Double? { envelope }
        func bandLevels(at time: TimeInterval) -> [Double] { bands }
    }

    // MARK: - Frame RMS

    func testFrameRMSSilenceIsZeroAndBandsSilent() {
        let pcm = [Int16](repeating: 0, count: frameLength)
        let frame = AudioLevelExtraction.frame(fromPCM: pcm, fft: fft)
        XCTAssertEqual(frame.rms, 0, accuracy: 1e-9)
        XCTAssertEqual(frame.bandRMS, [Float](repeating: 0, count: AudioBandPlan.count))
    }

    func testFrameRMSConstantFrameEqualsNormalizedConstant() {
        // 16384 / 32768 = 0.5 exactly — RMS of a constant is the constant.
        let pcm = [Int16](repeating: 16384, count: frameLength)
        let frame = AudioLevelExtraction.frame(fromPCM: pcm, fft: fft)
        XCTAssertEqual(frame.rms, 0.5, accuracy: 1e-4)
    }

    func testFrameRMSSineIsAmplitudeOverRootTwo() {
        let samples = sine(freq: 1_000, count: frameLength, amplitude: 0.5,
                           sampleRate: sampleRate)
        let frame = AudioLevelExtraction.frame(fromFloats: samples, fft: fft,
                                               sampleRate: sampleRate)
        XCTAssertEqual(Double(frame.rms), 0.5 / 2.0.squareRoot(), accuracy: 1e-4)
    }

    func testFrameWithoutFFTStillComputesEnvelopeHonestly() {
        // nil FFT = bands cannot be computed: the documented degradation
        // is "envelope only, bands silent" — never a fabricated band.
        let samples = sine(freq: 1_000, count: frameLength, amplitude: 0.5,
                           sampleRate: sampleRate)
        let frame = AudioLevelExtraction.frame(fromFloats: samples, fft: nil,
                                               sampleRate: sampleRate)
        XCTAssertEqual(Double(frame.rms), 0.5 / 2.0.squareRoot(), accuracy: 1e-4)
        XCTAssertEqual(frame.bandRMS, [Float](repeating: 0, count: AudioBandPlan.count))
    }

    // MARK: - Band plan / extraction

    func testBandRangesTileTheSpectrumAt16k() {
        // 16 kHz / 512 = 31.25 Hz bins. Exact expected ranges pin the
        // band edges AND the contiguity (each band starts where the last
        // ends) — a gap would silently drop energy between bars.
        let ranges = AudioBandPlan.binRanges(sampleRate: 16_000, fftLength: 512)
        XCTAssertEqual(ranges.count, AudioBandPlan.count)
        XCTAssertEqual(ranges, [7..<13, 13..<26, 26..<52, 52..<103, 103..<205])
        for i in 1..<ranges.count {
            XCTAssertEqual(ranges[i].lowerBound, ranges[i - 1].upperBound,
                           "band \(i) does not start where band \(i - 1) ends")
        }
    }

    func testBandRangesScaleWithSampleRate() {
        // 22050 Hz / 512 = 43.066 Hz bins (the Piper WAV rate).
        let ranges = AudioBandPlan.binRanges(sampleRate: 22_050, fftLength: 512)
        XCTAssertEqual(ranges[0], 5..<10)
        XCTAssertEqual(ranges[4].lowerBound, 75)
    }

    func testToneEnergyLandsInItsOwnBand() {
        // Exact-bin tones (binWidth 31.25 Hz): 500 Hz → bin 16 (band 1),
        // 1000 Hz → bin 32 (band 2), 3000 Hz → bin 96 (band 3). The
        // amplitude estimator is calibrated so ONE tone of amplitude A
        // reads back ≈ A in its band — assert that, plus cross-band
        // leakage under a tenth (window sidelobes are ~−40 dB there).
        let cases: [(freq: Double, band: Int)] = [(500, 1), (1_000, 2), (3_000, 3)]
        for (freq, expectedBand) in cases {
            let samples = sine(freq: freq, count: frameLength, amplitude: 0.5,
                               sampleRate: sampleRate)
            let bands = AudioLevelExtraction.bandRMS(fromFloats: samples, fft: fft,
                                                     sampleRate: sampleRate)
            XCTAssertEqual(Double(bands[expectedBand]), 0.5, accuracy: 0.05,
                           "\(freq) Hz must read back in band \(expectedBand)")
            for (index, level) in bands.enumerated() where index != expectedBand {
                XCTAssertLessThan(level, 0.1,
                                  "\(freq) Hz leaked into band \(index)")
            }
        }
    }

    // MARK: - Display mapping

    func testDbNormalizationClampsAndIsLinearInWindow() {
        XCTAssertEqual(AudioLevelMapping.normalized(db: -50, floorDb: -50, ceilingDb: -12), 0)
        XCTAssertEqual(AudioLevelMapping.normalized(db: -12, floorDb: -50, ceilingDb: -12), 1)
        XCTAssertEqual(AudioLevelMapping.normalized(db: -31, floorDb: -50, ceilingDb: -12),
                       0.5, accuracy: 1e-9)
        XCTAssertEqual(AudioLevelMapping.normalized(db: -5, floorDb: -50, ceilingDb: -12), 1,
                       "above the ceiling clamps, never overshoots")
        XCTAssertEqual(AudioLevelMapping.normalized(db: -90, floorDb: -50, ceilingDb: -12), 0)
        // Non-finite (log of zero) and NaN read as silence, not a crash.
        XCTAssertEqual(AudioLevelMapping.normalized(db: -.infinity, floorDb: -50, ceilingDb: -12), 0)
        XCTAssertEqual(AudioLevelMapping.normalized(db: .nan, floorDb: -50, ceilingDb: -12), 0)
    }

    func testRmsNormalizationUses20Log10() {
        // rms = 10^(dB/20) at each window edge.
        XCTAssertEqual(AudioLevelMapping.normalized(rms: pow(10, -50.0 / 20),
                                                    floorDb: -50, ceilingDb: -12), 0)
        XCTAssertEqual(AudioLevelMapping.normalized(rms: pow(10, -12.0 / 20),
                                                    floorDb: -50, ceilingDb: -12), 1)
        XCTAssertEqual(AudioLevelMapping.normalized(rms: pow(10, -31.0 / 20),
                                                    floorDb: -50, ceilingDb: -12),
                       0.5, accuracy: 1e-6)
        // Zero / negative / NaN are silence — the guard, not a NaN level.
        XCTAssertEqual(AudioLevelMapping.normalized(rms: 0, floorDb: -50, ceilingDb: -12), 0)
        XCTAssertEqual(AudioLevelMapping.normalized(rms: -1, floorDb: -50, ceilingDb: -12), 0)
        XCTAssertEqual(AudioLevelMapping.normalized(rms: .nan, floorDb: -50, ceilingDb: -12), 0)
    }

    func testBandTiltIsMonotonicAndCoversEveryBand() {
        // The tilt array is indexed by band; a shorter array would fall
        // back to the last gain for high bands (see `mapped`), so pin
        // coverage AND the rising shape the "highs are not dead" display
        // depends on.
        XCTAssertEqual(AudioLevelMapping.bandTiltGain.count, AudioBandPlan.count)
        for i in 1..<AudioLevelMapping.bandTiltGain.count {
            XCTAssertGreaterThan(AudioLevelMapping.bandTiltGain[i],
                                 AudioLevelMapping.bandTiltGain[i - 1])
        }
    }

    func testMappedAppliesTiltAndClamps() {
        // A hot frame: band energy way above the band ceiling still maps
        // to ≤ 1 after the tilt multiplies.
        let hot = AudioLevelFrame(rms: 1, bandRMS: [Float](repeating: 1,
                                                           count: AudioBandPlan.count))
        let mapped = AudioLevelAnalyzer.mapped(hot)
        XCTAssertEqual(mapped.envelope, 1)
        for (index, level) in mapped.bands.enumerated() {
            XCTAssertGreaterThanOrEqual(level, 0)
            XCTAssertLessThanOrEqual(level, 1, "band \(index) overshot past the tilt")
        }
        // Silence maps to exact baseline.
        XCTAssertEqual(AudioLevelAnalyzer.mapped(.silence()), .baseline)
    }

    // MARK: - Ballistics

    func testAttackIsFastAndReleaseIsSlow() {
        // Envelope: τ_attack 15 ms, τ_release 220 ms. One 32 ms frame
        // (the mic's natural cadence) must jump ~88% of the way up and
        // fall only ~13% of the way down — the classic meter feel the
        // owner asked for ("bounce like a speaker").
        let smoothing = AudioLevelSmoothing.envelope
        let up = smoothing.step(current: 0, target: 1, dt: 0.032)
        XCTAssertEqual(up, 1 - exp(-0.032 / 0.015), accuracy: 1e-6)
        XCTAssertGreaterThan(up, 0.85)
        let down = smoothing.step(current: 1, target: 0, dt: 0.032)
        XCTAssertEqual(down, exp(-0.032 / 0.22), accuracy: 1e-6)
        XCTAssertGreaterThan(down, 0.8)
    }

    func testSmoothingEdgeCasesAreInert() {
        let smoothing = AudioLevelSmoothing.envelope
        XCTAssertEqual(smoothing.step(current: 0.4, target: 1, dt: 0), 0.4,
                       "dt ≈ 0 must not move the level")
        XCTAssertEqual(smoothing.step(current: 0.4, target: 1, dt: -1), 0.4,
                       "a negative dt must not move the level")
        XCTAssertEqual(smoothing.step(current: 0.4, target: 0.4, dt: 0.032), 0.4,
                       "at the target, no direction is picked and nothing moves")
    }

    func testAnalyzerClampsTargetsAndResizesBands() {
        var analyzer = AudioLevelAnalyzer()
        // A huge dt ≈ the coefficient → 1, so levels land on the clamped
        // targets: >1 clamps to 1, <0 clamps to 0.
        let levels = analyzer.update(envelopeTarget: 1.5,
                                     bandTargets: [2.0, -0.5, 0.25],
                                     dt: 1.0)
        XCTAssertEqual(levels.envelope, 1, accuracy: 1e-6)
        XCTAssertEqual(levels.bands.count, 3, "the band array resizes to the target's count")
        for (index, expected) in [1.0, 0.0, 0.25].enumerated() {
            XCTAssertEqual(levels.bands[index], expected, accuracy: 1e-6)
        }
    }

    func testReleaseTowardRestDecaysMonotonicallyToRest() {
        var analyzer = AudioLevelAnalyzer()
        _ = analyzer.update(envelopeTarget: 1, bandTargets: [1, 1, 1, 1, 1], dt: 1.0)
        var previous = analyzer.levels
        XCTAssertFalse(previous.isAtRest)
        // 1/30 s ticks, bounded at 4 s — the tail must reach rest well
        // inside that (envelope τ 0.22 → ~1.2 s to the 0.005 threshold).
        var ticks = 0
        while !analyzer.levels.isAtRest {
            let levels = analyzer.releaseTowardRest(dt: 1.0 / 30.0)
            XCTAssertGreaterThanOrEqual(levels.envelope, 0)
            XCTAssertLessThanOrEqual(levels.envelope, previous.envelope)
            previous = levels
            ticks += 1
            XCTAssertLessThan(ticks, 120, "the release tail never reached rest")
        }
        XCTAssertEqual(analyzer.levels.envelope, 0, accuracy: 0.005)
    }

    func testIsAtRestBoundaries() {
        XCTAssertTrue(AudioLevels(envelope: 0.004,
                                  bands: [0.019, 0.019, 0.019, 0.019, 0.019]).isAtRest)
        XCTAssertFalse(AudioLevels(envelope: 0.006, bands: [0, 0, 0, 0, 0]).isAtRest)
        XCTAssertFalse(AudioLevels(envelope: 0, bands: [0, 0, 0.03, 0, 0]).isAtRest)
        XCTAssertTrue(AudioLevels.baseline.isAtRest)
    }

    // MARK: - Publish throttle

    func testPublishThrottleAllowsFirstThenRespectsInterval() {
        var throttle = PublishThrottle()
        XCTAssertTrue(throttle.shouldPublish(now: 1_000), "the first publish always passes")
        XCTAssertFalse(throttle.shouldPublish(now: 1_000.010))
        XCTAssertFalse(throttle.shouldPublish(now: 1_000.027))
        XCTAssertTrue(throttle.shouldPublish(now: 1_000.028), "≥ minInterval passes")
        XCTAssertFalse(throttle.shouldPublish(now: 1_000.029),
                       "the window restarts at the last successful publish")
        XCTAssertTrue(throttle.shouldPublish(now: 1_000.056))
    }

    func testPublishThrottleIntervalCoversTheMicCadence() {
        // The natural mic cadence is 32 ms frames (31.25 Hz). The
        // throttle window must be SHORTER than that so real frames are
        // never dropped — pin the relationship, not just the number.
        var throttle = PublishThrottle()
        let frameInterval = Double(AudioLevelExtraction.fftLength) / 16_000
        XCTAssertLessThan(throttle.minInterval, frameInterval)
        XCTAssertTrue(throttle.shouldPublish(now: 0))
        var now: TimeInterval = 0
        var published = 0
        for _ in 0..<10 {
            now += frameInterval
            if throttle.shouldPublish(now: now) { published += 1 }
        }
        XCTAssertEqual(published, 10, "every 32 ms frame must publish")
    }

    // MARK: - Playback band track

    func testBandTrackBuildsFromThePlayedFile() throws {
        // 0.5 s, 440 Hz, 22.05 kHz — Piper's shipped geometry. Frame
        // count is the 50%-overlap series: 1 + (11025 − 512) / 256 = 42.
        let url = try writeRampedToneWAV(freq: 440, seconds: 0.5, sampleRate: 22_050)
        let track = try XCTUnwrap(AudioBandTrack.build(from: url))
        XCTAssertEqual(track.frames.count, 42)
        XCTAssertEqual(track.hopSeconds, 256.0 / 22_050, accuracy: 1e-9)

        let middle = track.frames[track.frames.count / 2]
        let dominant = middle.bands.enumerated().max(by: { $0.element < $1.element })
        XCTAssertEqual(dominant?.offset, 1,
                       "440 Hz must dominate band 1 (400–800 Hz)")
        XCTAssertGreaterThan(middle.bands[1], 0.25)
        // The ramp rises: the track's first and last frames must show it.
        XCTAssertGreaterThan(track.frames.last!.envelope,
                             track.frames.first!.envelope + 0.1)
    }

    func testBandTrackSamplingInterpolatesAndClamps() throws {
        let url = try writeRampedToneWAV(freq: 440, seconds: 0.5, sampleRate: 22_050)
        let track = try XCTUnwrap(AudioBandTrack.build(from: url))

        // Exact frame times return exact frames.
        XCTAssertEqual(track.levels(at: 0), track.frames[0])
        XCTAssertEqual(track.levels(at: -5), track.frames[0])
        XCTAssertEqual(track.levels(at: 1_000_000), track.frames[track.frames.count - 1],
                       "past the end holds the last frame instead of snapping to zero")

        // Half a hop past frame 1: the exact linear midpoint of frames 1
        // and 2 — the same arithmetic both envelope and bands use.
        let a = track.frames[1]
        let b = track.frames[2]
        XCTAssertGreaterThan(b.envelope, a.envelope, "the ramp must separate adjacent frames")
        let mid = track.levels(at: track.hopSeconds * 1.5)
        XCTAssertEqual(mid.envelope, a.envelope + (b.envelope - a.envelope) * 0.5,
                       accuracy: 1e-12)
        for i in a.bands.indices {
            XCTAssertEqual(mid.bands[i], a.bands[i] + (b.bands[i] - a.bands[i]) * 0.5,
                           accuracy: 1e-12)
        }
    }

    func testBandTrackBuildFailsHonestlyOnAnUnreadableFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-audio-\(UUID().uuidString).wav")
        XCTAssertNil(AudioBandTrack.build(from: missing),
                     "an unreadable file degrades to nil (metering only), never a fake track")
    }

    // MARK: - Publisher owner switch

    func testMicWinsWhileCapturingAndSpeakerTakesItBack() {
        let publisher = AudioLevelPublisher()
        publisher.captureStarted()
        XCTAssertEqual(publisher.source, .mic)
        XCTAssertTrue(publisher.hasLiveSignal)

        // A reply starting while the mic captures arms the feed but must
        // NOT seize the meter — the owner's rule: mic wins while
        // capturing.
        let stub = StubSpeakerSource()
        publisher.speakerStarted(source: stub)
        XCTAssertEqual(publisher.source, .mic)

        // Capture ending hands the still-armed speaker feed the meter.
        publisher.captureEnded()
        XCTAssertEqual(publisher.source, .speakerLive)
        XCTAssertTrue(publisher.hasLiveSignal)

        // Playback ending with nothing flowing settles to idle. (Levels
        // are still baseline here — the stub never ticked — so the tail
        // is at rest instantly.)
        publisher.speakerEnded()
        XCTAssertEqual(publisher.source, .none)
        XCTAssertFalse(publisher.hasLiveSignal)
    }

    func testMeterlessSpeakerNeverReportsLiveSignal() {
        // AVSpeechSynthesizer (and NullSpeaker) expose no audio level at
        // all. The honest contract: the source is marked meterless and
        // `hasLiveSignal` stays FALSE so the UI keeps the idle fallback
        // motion — never a fake meter.
        let publisher = AudioLevelPublisher()
        publisher.speakerStartedMeterless()
        XCTAssertEqual(publisher.source, .speakerMeterless)
        XCTAssertFalse(publisher.hasLiveSignal)
        publisher.speakerEnded()
        XCTAssertEqual(publisher.source, .none)
    }

    func testCaptureFramesPublishEnvelopeAndBandsOnMain() {
        let publisher = AudioLevelPublisher()
        publisher.captureStarted()
        XCTAssertEqual(publisher.source, .mic)

        // A 1 kHz tone at 0.5 amplitude: rms 0.354 (−9 dB, above the
        // envelope ceiling) → one 32 ms attack step lands ≈ 0.88; the
        // tone is an exact bin in band 2 → that band climbs fast too.
        let pcm = sinePCM(freq: 1_000, count: frameLength, amplitude: 0.5,
                          sampleRate: sampleRate)
        publisher.ingestCaptureFrame(pcm, sampleRate: sampleRate)

        // Flush the main queue: the ingest hop is enqueued before the
        // fulfill block, so FIFO guarantees the publish already ran.
        let flushed = expectation(description: "main queue flushed")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 1)

        XCTAssertGreaterThan(publisher.envelope, 0.5)
        XCTAssertGreaterThan(publisher.bands[2], 0.4)
        XCTAssertEqual(publisher.source, .mic)

        // Capture ending with those hot readings latches the source
        // through the release tail (the bars fall, they never snap).
        publisher.captureEnded()
        XCTAssertEqual(publisher.source, .mic,
                       "the tail keeps the source latched while levels decay")
        let deadline = Date().addingTimeInterval(3)
        while publisher.hasLiveSignal, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(publisher.hasLiveSignal,
                       "the tail must drain to idle within its bounded decay")
        XCTAssertEqual(publisher.envelope, 0, accuracy: 1e-9)
        XCTAssertEqual(publisher.bands, AudioLevels.baseline.bands)
    }

    func testIngestWithoutCaptureIsIgnored() {
        // Frames arriving outside a capture epoch (a late hop from a
        // torn-down pipeline) must not invent a mic source.
        let publisher = AudioLevelPublisher()
        let pcm = sinePCM(freq: 1_000, count: frameLength, amplitude: 0.5,
                          sampleRate: sampleRate)
        publisher.ingestCaptureFrame(pcm, sampleRate: sampleRate)
        let flushed = expectation(description: "main queue flushed")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 1)
        XCTAssertEqual(publisher.source, .none)
        XCTAssertEqual(publisher.envelope, 0)
    }
}
