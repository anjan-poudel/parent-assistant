import XCTest
import AVFoundation
@testable import ElderlyAssistant

final class SpeakerTests: XCTestCase {

    func testSystemSpeakerFallsBackToLanguageThenEnglish() {
        // AVSpeechSynthesisVoice(language:) is available for at least
        // en-US on every simulator/device; nonsense locales fall back.
        let bus = MockObservabilityBus()
        let speaker = SystemSpeechSpeaker(observabilityBus: bus)

        // Cancel is a no-op when nothing is playing — must not crash.
        speaker.cancel()

        XCTAssertEqual(bus.emittedEvents.count, 0,
                       "Speaker must not emit events on cancel-when-idle.")
    }

    func testPiperSpeakerCancelWhenIdleIsHarmless() throws {
        let bus = MockObservabilityBus()
        let system = SystemSpeechSpeaker(observabilityBus: bus)
        let store = try ModelStore(
            observabilityBus: bus,
            rootDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-tests-\(UUID().uuidString)")
        )
        let piper = PiperVoiceSpeaker(fallback: system,
                                      observabilityBus: bus,
                                      modelStore: store)

        // Cancel before speak — must not crash, must emit nothing.
        piper.cancel()
        XCTAssertTrue(bus.emittedEvents.isEmpty)
    }

    func testPiperSpeakerCancelDoesNotEndASeamItNeverBegan() throws {
        // [MIC-CONTINUITY-REGRESSION] A cancel that never began playback
        // can never touch the seam — an outstanding begin from another
        // speaker (the ack's, a nested reply's) must not be consumed.
        var begins = 0
        var ends = 0
        ResponsePlaybackModeSeam.begin = { begins += 1 }
        ResponsePlaybackModeSeam.end = { ends += 1 }
        defer {
            ResponsePlaybackModeSeam.begin = {}
            ResponsePlaybackModeSeam.end = {}
        }

        let bus = MockObservabilityBus()
        let system = SystemSpeechSpeaker(observabilityBus: bus)
        let store = try ModelStore(
            observabilityBus: bus,
            rootDirectoryOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("speaker-tests-\(UUID().uuidString)")
        )
        let piper = PiperVoiceSpeaker(fallback: system,
                                      observabilityBus: bus,
                                      modelStore: store)

        piper.cancel()
        XCTAssertEqual(begins, 0)
        XCTAssertEqual(ends, 0,
                       "a cancel that never began playback must not end a "
                       + "concurrent ack's seam")
    }

    // MARK: - [VOLUME-BOOST] Gain math (percent → linear factor)

    /// [MIC-CONTINUITY-REGRESSION] The shipped default IS the loud
    /// baseline (owner field verdict 2026-10-14: "that loudness at
    /// 100 %"). A default drifting back to the pre-baseline quietness is
    /// a loudness regression, not a neutral refactor.
    func testShippedDefaultIsTheLoudBaseline() {
        XCTAssertEqual(VoiceOutputVolume.defaultPercent, 100)
    }

    func testGainFactorMapsPercentToLinearAndClampsFirst() {
        // [VOLUME-BASELINE] The fold: gain = percent/100 × 3 — 100 % is
        // the loud baseline the owner validated at the old 300 %.
        XCTAssertEqual(VoiceOutputGain.linearFactor(percent: 100), 3.0, accuracy: 0.0001)
        XCTAssertEqual(VoiceOutputGain.linearFactor(percent: 150), 4.5, accuracy: 0.0001)
        XCTAssertEqual(VoiceOutputGain.linearFactor(percent: 200), 6.0, accuracy: 0.0001)
        XCTAssertEqual(VoiceOutputGain.linearFactor(percent: 50), 1.5, accuracy: 0.0001)
        // Out-of-range percentages clamp BEFORE the math: the transfer can
        // never see a gain the UI cannot produce.
        XCTAssertEqual(VoiceOutputGain.linearFactor(percent: 1000), 9.0, accuracy: 0.0001)
        XCTAssertEqual(VoiceOutputGain.linearFactor(percent: -20), 1.5, accuracy: 0.0001)
    }

    func testGainDecibelFormMatchesTheLinearFactor() {
        // 100 % = 0 dB (the shipped loudness), 150 % ≈ +3.52 dB,
        // 200 % ≈ +6.02 dB, 50 % ≈ −6.02 dB — the honest "how much
        // louder" numbers.
        XCTAssertEqual(VoiceOutputGain.decibels(percent: 100), 9.5424, accuracy: 0.01)
        XCTAssertEqual(VoiceOutputGain.decibels(percent: 150), 13.0643, accuracy: 0.01)
        XCTAssertEqual(VoiceOutputGain.decibels(percent: 200), 15.5630, accuracy: 0.01)
        XCTAssertEqual(VoiceOutputGain.decibels(percent: 50), 3.5218, accuracy: 0.01)
    }

    func testLimiterCeilingIsMinusOneDBFS() {
        XCTAssertEqual(VoiceOutputGain.ceilingDBFS, -1)
        XCTAssertEqual(VoiceOutputGain.ceilingLinear, 0.8913, accuracy: 0.001)
    }

    func testSoftKneeIsMinusTwelveDBFS() {
        XCTAssertEqual(VoiceOutputGain.kneeDBFS, -15)
        XCTAssertEqual(VoiceOutputGain.kneeLinear, 0.1778, accuracy: 0.001)
    }

    // MARK: - [VOLUME-BOOST] Transfer behavior (boost side)

    func testBoostRaisesTheBodyEvenWhenPeaksAreAtFullScale() {
        // The regression this transfer exists for: Piper speech peaks
        // near full scale, and the original whole-buffer limiter applied
        // ≈ ceiling/peak ≈ 1.0× to EVERYTHING — the 150 % setting bought
        // nothing on real replies. The knee gives the body of the speech
        // the full gain while the peaks compress.
        var samples: [Float] = [1.0, -1.0, 0.1, -0.05, 0.0]
        let result = VoiceOutputGain.apply(gain: 2.0, to: &samples)

        XCTAssertEqual(result.appliedGain, 2.0, accuracy: 0.0001)
        XCTAssertTrue(result.didLimit, "full-scale peaks enter the knee")
        // The body keeps the FULL requested gain — exactly what the old
        // limiter refused to do.
        XCTAssertEqual(samples[2], 0.2, accuracy: 0.0001)
        XCTAssertEqual(samples[3], -0.1, accuracy: 0.0001)
        // The peaks compress toward — and never cross — the ceiling.
        XCTAssertGreaterThan(samples[0], 0.6, "compressed, not flattened")
        XCTAssertLessThan(samples[0], VoiceOutputGain.ceilingLinear)
        XCTAssertLessThanOrEqual(VoiceOutputGain.peak(of: samples),
                                 VoiceOutputGain.ceilingLinear + 0.0001)
    }

    func testBoostCompressesLoudSamplesInsteadOfPullingTheBufferDown() {
        // 0.95 × 1.5 = 1.425 would hard-clip; the knee compresses it
        // toward the ceiling instead of squaring it off — and unlike the
        // original limiter it does NOT pull the quieter samples down with
        // it.
        var samples: [Float] = [0.95, 0.1]
        let result = VoiceOutputGain.apply(gain: 1.5, to: &samples)

        XCTAssertTrue(result.didLimit, "the requested gain crossed the knee")
        XCTAssertEqual(result.appliedGain, 1.5, accuracy: 0.0001)
        // The quiet sample keeps the full gain (the old whole-buffer
        // limiter would have given it ≈ 0.938×).
        XCTAssertEqual(samples[1], 0.15, accuracy: 0.0001)
        XCTAssertGreaterThan(samples[0], VoiceOutputGain.kneeLinear,
                             "compressed, not flattened")
        XCTAssertLessThanOrEqual(samples[0], VoiceOutputGain.ceilingLinear + 0.0001)
    }

    func testTransferNeverExceedsTheCeilingAtAnySetting() {
        // Every reachable percentage, against a file that is already at
        // full scale — the worst case a boost can meet.
        for percent in stride(from: VoiceOutputVolume.minimumPercent,
                              through: VoiceOutputVolume.maximumPercent,
                              by: VoiceOutputVolume.stepPercent) {
            var samples: [Float] = [1.0, -1.0, 0.891, -0.3, 0.0]
            let result = VoiceOutputGain.apply(
                gain: VoiceOutputGain.linearFactor(percent: percent), to: &samples)
            XCTAssertLessThanOrEqual(VoiceOutputGain.peak(of: samples),
                                     VoiceOutputGain.ceilingLinear + 0.0001,
                                     "\(percent)% must never pass the ceiling")
            XCTAssertLessThanOrEqual(result.peakOut,
                                     VoiceOutputGain.ceilingLinear + 0.0001)
        }
    }

    func testBelowKneeSamplesKeepTheFullRequestedGain() {
        // The honest half of the trade: below the knee the boost is
        // exact, with no limiting and no compression.
        var samples: [Float] = [0.1, -0.05]
        let result = VoiceOutputGain.apply(gain: 1.5, to: &samples)
        XCTAssertFalse(result.didLimit)
        XCTAssertEqual(result.appliedGain, 1.5, accuracy: 0.0001)
        XCTAssertEqual(samples[0], 0.15, accuracy: 0.0001)
        XCTAssertEqual(samples[1], -0.075, accuracy: 0.0001)
    }

    func testAttenuationIsPureLinearAndNeverCompresses() {
        // The quiet-room half of the range: 50 % halves the file's own
        // amplitude exactly — no knee, no compression, no distortion.
        var samples: [Float] = [0.95, -0.5, 0.25, 0.1]
        let result = VoiceOutputGain.apply(gain: 0.5, to: &samples)
        XCTAssertFalse(result.didLimit)
        XCTAssertEqual(result.appliedGain, 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples, [0.475, -0.25, 0.125, 0.05])
    }

    func testDigitalSilenceStaysSilent() {
        // Gain amplifies what is there; there is nothing here. Silence
        // must not become noise, and no division by a zero peak.
        var samples: [Float] = [0, 0, 0]
        let result = VoiceOutputGain.apply(gain: 1.5, to: &samples)
        XCTAssertEqual(result.appliedGain, 0)
        XCTAssertEqual(samples, [0, 0, 0])
        XCTAssertFalse(result.didLimit)
    }

    func testMultiChannelBufferUsesOneSharedTransfer() {
        // Loud left, quiet right: both go through the SAME transfer, so
        // the stereo image cannot shift under the boost — and the quiet
        // channel's below-knee samples keep the exact full gain.
        var channels: [[Float]] = [[0.95, 0.5], [0.1, 0.05]]
        let result = VoiceOutputGain.apply(gain: 1.5, toChannels: &channels)
        XCTAssertEqual(result.appliedGain, 1.5, accuracy: 0.0001)
        XCTAssertTrue(result.didLimit)
        XCTAssertEqual(channels[1][0], 0.15, accuracy: 0.0001)
        XCTAssertEqual(channels[1][1], 0.075, accuracy: 0.0001)
        XCTAssertGreaterThan(channels[0][0], VoiceOutputGain.kneeLinear)
        XCTAssertLessThanOrEqual(channels[0][0], VoiceOutputGain.ceilingLinear + 0.0001)
    }

    func testNonFiniteSamplesBecomeSilenceNeverNaN() {
        // A broken synthesis must not put NaN into the player.
        var samples: [Float] = [.nan, .infinity, 0.5]
        VoiceOutputGain.apply(gain: 1.5, to: &samples)
        XCTAssertTrue(samples.allSatisfy { $0.isFinite })
    }

    // MARK: - [VOLUME-BOOST] File transform (gain applied before playback)

    func testEverySettingProducesAGainedCopy() throws {
        // [VOLUME-BASELINE] No percent maps to raw anymore — 100 % itself
        // carries the 3× baseline, so every setting plays a processed copy.
        let wav = try writeGainTestWAV(peak: 0.9)
        defer { try? FileManager.default.removeItem(at: wav) }

        let out = try SpokenReplyGainProcessor.playbackURL(for: wav, percent: 100)
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertNotEqual(out, wav, "100 % is the loud baseline, not raw")
    }

    func testBoostedPlaybackWritesALimitedCopyAndLeavesTheSourceAlone() throws {
        let wav = try writeGainTestWAV(peak: 0.95)
        defer { try? FileManager.default.removeItem(at: wav) }
        let original = try Data(contentsOf: wav)

        let out = try SpokenReplyGainProcessor.playbackURL(for: wav, percent: 150)
        defer { try? FileManager.default.removeItem(at: out) }

        XCTAssertNotEqual(out, wav, "a boosted reply plays from a processed copy")
        XCTAssertEqual(try Data(contentsOf: wav), original,
                       "the source file is never rewritten in place — a shared "
                       + "asset (bell/cue/ack slot) must not inherit the gain")
        XCTAssertTrue(out.path.hasPrefix(FileManager.default.temporaryDirectory.path),
                      "the copy lives in the temp directory, owned by the caller")
        let peak = peakOfWAV(at: out)
        XCTAssertGreaterThan(peak, 0, "the copy is real audio, not a silent file")
        XCTAssertLessThanOrEqual(peak, VoiceOutputGain.ceilingLinear + 0.0001,
                                 "the copy can never exceed the −1 dBFS ceiling")
    }

    func testLowestSettingStillBoostsBelowTheKneeSamples() throws {
        // [VOLUME-BASELINE] The quiet-room half of the range is now
        // "softer than 100 %", not attenuation: 50 % = 1.5× — below-knee
        // samples get exactly that.
        let wav = try writeGainTestWAV(peak: 0.8)
        defer { try? FileManager.default.removeItem(at: wav) }

        let out = try SpokenReplyGainProcessor.playbackURL(for: wav, percent: 50)
        defer { try? FileManager.default.removeItem(at: out) }

        let peak = peakOfWAV(at: out)
        XCTAssertGreaterThan(peak, 0, "the copy is real audio, not a silent file")
        XCTAssertLessThanOrEqual(peak, VoiceOutputGain.ceilingLinear + 0.0001)
    }

    // MARK: - [VOLUME-BOOST] Scope: non-TTS playback is untouched

    func testNonReplyPlaybackPathsCannotReachTheGain() throws {
        // The alarm bell (TimerAlarmBellPlayer), the wake-word cue and
        // any system sound read their own assets and hand them straight
        // to AVAudioPlayer — the gain is a transform of the SPEAKER's
        // reply WAV, reachable only through the reply processor, and it
        // touches no session or global volume. Pinned here as the
        // property that would have to break for a non-reply path to
        // change: processing never mutates the audio session, and its
        // only artifact is a temp copy the caller owns.
        let sessionBefore = AVAudioSession.sharedInstance().category
        let wav = try writeGainTestWAV(peak: 0.9)
        defer { try? FileManager.default.removeItem(at: wav) }

        let out = try SpokenReplyGainProcessor.playbackURL(for: wav, percent: 150)
        defer { try? FileManager.default.removeItem(at: out) }

        XCTAssertEqual(AVAudioSession.sharedInstance().category, sessionBefore,
                       "the boost never touches the shared audio session")
        XCTAssertTrue(out.path.hasPrefix(FileManager.default.temporaryDirectory.path),
                      "the only artifact is a temp file — nothing global to leak into "
                      + "the bell, the wake cue or another app")
    }

    // MARK: - Helpers

    /// A tiny mono 22.05 kHz WAV whose loudest sample is `peak` — the
    /// same shape sherpa's reply WAVs have.
    private func writeGainTestWAV(peak: Float) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050,
                                   channels: 1)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-gain-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(format.sampleRate / 10)   // 0.1 s
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            samples[i] = i % 2 == 0 ? peak : -peak / 2
        }
        try file.write(from: buffer)
        return url
    }

    /// Reads a WAV back and returns its loudest |sample|.
    private func peakOfWAV(at url: URL) -> Float {
        guard let file = try? AVAudioFile(forReading: url) else { return -1 }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: frames) else { return -1 }
        try? file.read(into: buffer)
        guard let data = buffer.floatChannelData else { return -1 }
        var peak: Float = 0
        for ch in 0..<Int(file.processingFormat.channelCount) {
            for i in 0..<Int(buffer.frameLength) {
                let value = data[ch][i]
                if value.isFinite { peak = max(peak, abs(value)) }
            }
        }
        return peak
    }
}
