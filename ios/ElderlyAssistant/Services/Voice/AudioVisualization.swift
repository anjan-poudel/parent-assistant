import Foundation
import AVFoundation
import Combine

// [AUDIO-REACTIVE-HERO] (2026-10-14) — the Talk hero's real signal feed.
//
// Owner's verdict (verbatim): "the animation is shit. the main button
// should bounce like a speaker when talking or when mic sound comes in.
// the side bars should move like a CD player's equalizer - not random
// but based on music."
//
// This file replaces the canned sine-wave motion with REAL signal-driven
// motion, through one source-of-truth model both audio sides feed:
//
//  · MIC (capture): VoicePipeline slices the SAME enhanced 16 kHz frames
//    the VAD consumes and pushes them to `ingestCaptureFrame` on the
//    pipeline's processing queue. Frame RMS drives the envelope; a
//    windowed FFT over five log-spaced bands drives the equalizer bars.
//  · SPEAKER (Piper): `PiperVoiceSpeaker.play` hands over a
//    `PiperPlaybackLevelSource` built on the AVAudioPlayer that is about
//    to play the reply. The envelope is the player's OWN live metering
//    (`averagePower` — a documented AVAudioPlayer API); the bands are
//    precomputed from the exact WAV bytes being played and sampled at
//    the player's own `currentTime` clock. Both are real data from the
//    actual audio; neither is fabricated. (AVAudioPlayer exposes no
//    tap/installTap seam — it is not an AVAudioEngine node — so a live
//    per-band tap is not available on this path; the
//    precomputed-from-the-played-file track is the honest substitute.)
//  · SPEAKER (system / AVSpeechSynthesizer): AVSpeechSynthesizer exposes
//    NO audio-level API at all — there is no signal to read. That path
//    publishes `.speakerMeterless` and the UI falls back to the EXISTING
//    subtle idle motion, clearly labelled in TalkButton. Nothing here
//    ever fakes a meter.
//
// Owner switch (the task's rule): mic wins while capturing, speaker wins
// while playing, idle fallback otherwise. Source transitions keep the
// meter latched through a short ballistic release tail (< ~1 s) so the
// bars fall to rest instead of snapping — standard meter behavior, not
// invented motion: the tail only ever decays the last REAL reading.
//
// Threading: capture frames arrive on the pipeline's processing queue
// (the FFT + analyzer are confined there behind `micLock`, exactly like
// the denoiser's thread-confined FFT — see SpectralGateCore). Everything
// else — published values, the 30 Hz driver timer, the source switch —
// is main-queue confined; publishes hop to main and are throttled to
// ≤ ~35 Hz (the natural cadence is 31.25 Hz mic frames / 30 Hz timer).

// MARK: - Display mapping ([AUDIO-REACTIVE-HERO])

/// The dB windows and band tilt the meters display through. Plain
/// constants, deliberately in ONE place: the owner judges the motion by
/// eye on the device, and tuning must never mean touching logic.
enum AudioLevelMapping {
    /// Envelope window: RMS −50 dBFS (a quiet room) … −12 dBFS (a loud,
    /// close voice). Linear-in-dB is the perceptual mapping — a level
    /// meter that is linear in amplitude reads as "nothing then
    /// everything".
    static let envelopeFloorDb: Double = -50
    static let envelopeCeilingDb: Double = -12
    /// Per-band window: wider floor because each band only sees a slice
    /// of the spectrum.
    static let bandFloorDb: Double = -60
    static let bandCeilingDb: Double = -12
    /// Display tilt (pinking correction), applied to the normalised band
    /// levels: speech energy falls ~6 dB/octave, so an untilted display
    /// would read as "the highs are dead". The tilt changes how a band's
    /// energy is DRAWN, never what is drawn — every bar still rises and
    /// falls with its own band's actual energy dynamics.
    static let bandTiltGain: [Double] = [0.60, 0.80, 1.00, 1.35, 1.80]

    /// dB → 0…1 through a [floor, ceiling] window, clamped. Non-finite
    /// (log of zero) reads as silence.
    static func normalized(db: Double, floorDb: Double, ceilingDb: Double) -> Double {
        guard db.isFinite else { return 0 }
        let t = (db - floorDb) / (ceilingDb - floorDb)
        return min(1, max(0, t))
    }

    /// RMS → 0…1 through a dB window.
    static func normalized(rms: Double, floorDb: Double, ceilingDb: Double) -> Double {
        guard rms > 0, rms.isFinite else { return 0 }
        return normalized(db: 20 * log10(rms), floorDb: floorDb, ceilingDb: ceilingDb)
    }
}

/// The five log-spaced equalizer bands (edges in Hz) both the mic FFT
/// and the playback track extract through. Edges are shared constants —
/// the two paths can never disagree about what "band 2" means.
enum AudioBandPlan {
    static let edgesHz: [Double] = [200, 400, 800, 1600, 3200, 6400]
    static var count: Int { edgesHz.count - 1 }

    /// FFT bin ranges (inclusive floors, exclusive tops) covering each
    /// band at `sampleRate` with an `fftLength`-point transform. Bin 0
    /// (DC) and the Nyquist slot are never included — the packed-real
    /// convention stores them 2×-scaled (see `SpectralGateCore.FFT`),
    /// and no band edge reaches them anyway.
    static func binRanges(sampleRate: Double, fftLength: Int) -> [Range<Int>] {
        let halfN = fftLength / 2
        let binWidth = sampleRate / Double(fftLength)
        return (0..<count).map { band in
            let low = max(1, Int((edgesHz[band] / binWidth).rounded(.up)))
            let high = min(halfN - 1,
                           Int((edgesHz[band + 1] / binWidth).rounded(.down)))
            return low..<(max(low, high) + 1)
        }
    }
}

// MARK: - Raw frame extraction ([AUDIO-REACTIVE-HERO])

/// One analysis frame's PHYSICAL readings — the units the math and the
/// tests work in. Display mapping happens in `AudioLevelAnalyzer.mapped`.
struct AudioLevelFrame: Equatable {
    /// Frame RMS of the (unwindowed) samples, 0…1 for int16-normalised
    /// audio.
    let rms: Float
    /// Per-band RMS, one entry per `AudioBandPlan` band.
    let bandRMS: [Float]

    static func silence(bands: Int = AudioBandPlan.count) -> AudioLevelFrame {
        AudioLevelFrame(rms: 0, bandRMS: [Float](repeating: 0, count: bands))
    }
}

/// Stateless frame → levels math: RMS + windowed-FFT band energies. One
/// `SpectralGateCore.FFT` instance is passed in per caller (the class is
/// thread-confined by the same doctrine the denoiser documents); a nil
/// FFT degrades honestly to "envelope only, bands silent".
enum AudioLevelExtraction {
    /// 512 samples = 32 ms at 16 kHz — the VAD's frame length, and the
    /// denoiser's FFT size. Reusing both means no extra resampling stage
    /// on the mic path.
    static let fftLength = 512

    /// The sqrt-Hann (sine) window — the same analysis window the
    /// spectral-gate denoiser uses (SpectralGateCore.sineWindow).
    static let window: [Float] = SpectralGateCore.sineWindow(length: fftLength)
    static let windowMean: Float = {
        guard !window.isEmpty else { return 1 }
        return window.reduce(0, +) / Float(window.count)
    }()

    /// Int16 PCM frame (16 kHz, as the pipeline's capture fan-out
    /// delivers it) → raw levels.
    static func frame(fromPCM pcm: [Int16],
                      fft: SpectralGateCore.FFT?,
                      sampleRate: Double = 16_000) -> AudioLevelFrame {
        guard !pcm.isEmpty else { return .silence() }
        var floats = [Float](repeating: 0, count: pcm.count)
        var sum: Float = 0
        for i in pcm.indices {
            // Float math, integer divisor — the same hot-path doctrine
            // EnergyVAD.rms documents (32768 = 2^15 is exact in Float).
            let normalized = Float(pcm[i]) / 32768
            floats[i] = normalized
            sum += normalized * normalized
        }
        let rms = sqrt(sum / Float(pcm.count))
        return AudioLevelFrame(rms: rms,
                               bandRMS: bandRMS(fromFloats: floats, fft: fft,
                                                sampleRate: sampleRate))
    }

    /// Float samples → raw levels (the playback-track path).
    static func frame(fromFloats samples: [Float],
                      fft: SpectralGateCore.FFT?,
                      sampleRate: Double) -> AudioLevelFrame {
        guard !samples.isEmpty else { return .silence() }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = sqrt(sum / Float(samples.count))
        return AudioLevelFrame(rms: rms,
                               bandRMS: bandRMS(fromFloats: samples, fft: fft,
                                                sampleRate: sampleRate))
    }

    /// Windowed FFT → per-band RMS. Amplitude normalisation removes the
    /// N/2 FFT gain and the window's mean so bandRMS ≈ the amplitude of
    /// a pure tone in that band (empirical scale, not exact RMS — the dB
    /// window in `AudioLevelMapping` is calibrated to this convention).
    static func bandRMS(fromFloats samples: [Float],
                        fft: SpectralGateCore.FFT?,
                        sampleRate: Double) -> [Float] {
        guard let fft, samples.count == fftLength else {
            return [Float](repeating: 0, count: AudioBandPlan.count)
        }
        var windowed = [Float](repeating: 0, count: fftLength)
        for i in 0..<fftLength { windowed[i] = samples[i] * window[i] }
        let spectrum = fft.forward(real: windowed)
        let halfN = fftLength / 2
        let norm = 2 / (Float(fftLength) * windowMean)
        var bands = [Float](repeating: 0, count: AudioBandPlan.count)
        for (band, range) in AudioBandPlan
            .binRanges(sampleRate: sampleRate, fftLength: fftLength).enumerated() {
            var power: Float = 0
            for b in range {
                guard b >= 1, b < halfN else { continue }
                let re = spectrum.real[b]
                let im = spectrum.imag[b]
                let amplitude = sqrt(re * re + im * im) * norm
                power += amplitude * amplitude
            }
            bands[band] = sqrt(power)
        }
        return bands
    }
}

// MARK: - Smoothed display levels ([AUDIO-REACTIVE-HERO])

/// One instant of DISPLAY levels, 0…1. This is what the hero reads.
struct AudioLevels: Equatable {
    var envelope: Double
    var bands: [Double]

    static let baseline = AudioLevels(envelope: 0,
                                      bands: [Double](repeating: 0, count: AudioBandPlan.count))

    /// The meter is visually settled — nothing left worth rendering.
    var isAtRest: Bool {
        envelope < 0.005 && bands.allSatisfy { $0 < 0.02 }
    }
}

/// Owner-specified ballistics: fast attack, slow release ("bounce like a
/// speaker" — a cone jumps with the waveform and settles slower). τ is
/// the 63 % time constant; with 32 ms frames a 15 ms attack is
/// effectively one-frame at full jump, a 220 ms release takes ~10
/// frames to fall back — the classic meter feel.
struct AudioLevelSmoothing: Equatable {
    var attackSeconds: Double
    var releaseSeconds: Double

    static let envelope = AudioLevelSmoothing(attackSeconds: 0.015,
                                              releaseSeconds: 0.22)
    /// Bars release a little quicker than the disc so the equalizer
    /// reads as "live" rather than "syrupy".
    static let bands = AudioLevelSmoothing(attackSeconds: 0.020,
                                           releaseSeconds: 0.12)

    /// One exponential step toward `target`. Direction picks the
    /// constant: rising uses attack, falling release. Pure — dt comes
    /// from the caller's clock, so the same function serves the 31.25 Hz
    /// mic cadence, the 30 Hz speaker timer, and the test suite.
    func step(current: Double, target: Double, dt: TimeInterval) -> Double {
        guard dt > 0 else { return current }
        let tau = target > current ? attackSeconds : releaseSeconds
        guard tau > 0 else { return target }
        let coefficient = 1 - exp(-dt / tau)
        return current + (target - current) * coefficient
    }
}

/// Stateful per-source smoother: raw frame (or already-mapped target) in,
/// `AudioLevels` out. One instance per producer (mic analyzer lives on
/// the processing queue, speaker analyzer on main) — no sharing, no lock
/// contention.
struct AudioLevelAnalyzer {
    private(set) var levels: AudioLevels = .baseline
    var envelopeSmoothing: AudioLevelSmoothing = .envelope
    var bandSmoothing: AudioLevelSmoothing = .bands

    /// Re-seed with a caller's current display levels — the release tail
    /// borrows the live readings so the bars fall from where they were
    /// instead of snapping. `levels` is private(set), so the seed is a
    /// method, not an assignment from outside the struct.
    mutating func seed(_ newLevels: AudioLevels) {
        levels = newLevels
    }

    /// Raw physical frame → display targets → smoothed levels.
    mutating func update(raw frame: AudioLevelFrame, dt: TimeInterval) -> AudioLevels {
        let mapped = Self.mapped(frame)
        return update(envelopeTarget: mapped.envelope,
                      bandTargets: mapped.bands, dt: dt)
    }

    /// Mapped 0…1 targets → smoothed levels. The speaker path feeds this
    /// directly (its targets come already normalised from metering /
    /// the precomputed track).
    mutating func update(envelopeTarget: Double,
                         bandTargets: [Double],
                         dt: TimeInterval) -> AudioLevels {
        let envelope = envelopeSmoothing.step(current: levels.envelope,
                                              target: envelopeTarget.clamped01,
                                              dt: dt)
        var bands = levels.bands
        if bands.count != bandTargets.count {
            bands = [Double](repeating: 0, count: bandTargets.count)
        }
        for i in bands.indices {
            bands[i] = bandSmoothing.step(current: bands[i],
                                          target: bandTargets[i].clamped01,
                                          dt: dt)
        }
        levels = AudioLevels(envelope: envelope, bands: bands)
        return levels
    }

    /// Ballistic release to rest (source ended): decay the LAST REAL
    /// readings toward zero. Never invents a reading.
    mutating func releaseTowardRest(dt: TimeInterval) -> AudioLevels {
        let envelope = envelopeSmoothing.step(current: levels.envelope,
                                              target: 0, dt: dt)
        var bands = levels.bands
        for i in bands.indices {
            bands[i] = envelopeSmoothing.step(current: bands[i], target: 0, dt: dt)
        }
        levels = AudioLevels(envelope: envelope, bands: bands)
        return levels
    }

    /// Stateless raw→display mapping (no smoothing) — also the track
    /// builder's per-frame converter.
    static func mapped(_ frame: AudioLevelFrame) -> AudioLevels {
        let envelope = AudioLevelMapping.normalized(rms: Double(frame.rms),
                                                    floorDb: AudioLevelMapping.envelopeFloorDb,
                                                    ceilingDb: AudioLevelMapping.envelopeCeilingDb)
        let bands = frame.bandRMS.enumerated().map { index, rms -> Double in
            let tilt = AudioLevelMapping.bandTiltGain[min(index,
                                                          AudioLevelMapping.bandTiltGain.count - 1)]
            return min(1, AudioLevelMapping.normalized(rms: Double(rms),
                                                       floorDb: AudioLevelMapping.bandFloorDb,
                                                       ceilingDb: AudioLevelMapping.bandCeilingDb) * tilt)
        }
        return AudioLevels(envelope: envelope, bands: bands)
    }
}

private extension Double {
    var clamped01: Double { min(1, max(0, self)) }
}

/// Publish-rate bound: ≤ ~35 Hz so SwiftUI never re-renders faster than
/// the eye can read. 28 ms ≈ 35.7 Hz — just under the mic path's natural
/// 32 ms (31.25 Hz) cadence, so real frames are never dropped.
struct PublishThrottle {
    var minInterval: TimeInterval = 0.028
    private var lastPublished: TimeInterval = -.greatestFiniteMagnitude

    mutating func shouldPublish(now: TimeInterval) -> Bool {
        guard now - lastPublished >= minInterval else { return false }
        lastPublished = now
        return true
    }
}

// MARK: - Speaker-side feed ([AUDIO-REACTIVE-HERO])

/// What the publisher pulls from while a speaker plays. Implemented by
/// `PiperPlaybackLevelSource` (AVAudioPlayer metering + precomputed
/// band track). The protocol is deliberately narrow so a test double —
/// or a future engine — can drive the same seam.
protocol SpeakerLevelSource: AnyObject {
    /// Playback position on the SOURCE's own clock (the player's
    /// `currentTime`) — the track is sampled through it.
    var elapsed: TimeInterval { get }
    /// Live output envelope 0…1. nil = no live reading available; the
    /// publisher then reads the track's own envelope at `elapsed`.
    func envelopeLevel() -> Double?
    /// Precomputed band levels 0…1 at `time` (mapped, unsmoothed — the
    /// publisher's analyzer does the ballistics). Empty until ready.
    func bandLevels(at time: TimeInterval) -> [Double]
}

/// The reply-PCM envelope/band series for one playback, precomputed from
/// the EXACT file the AVAudioPlayer will play (the gained copy when the
/// volume boost is active — what plays is what is analysed).
struct AudioBandTrack {
    let frames: [AudioLevels]
    let hopSeconds: TimeInterval

    /// Linear interpolation between adjacent frames; clamps at both
    /// ends, so a clock slightly past the file's end holds the last
    /// frame instead of snapping to zero.
    func levels(at time: TimeInterval) -> AudioLevels {
        guard !frames.isEmpty else { return .baseline }
        guard time > 0 else { return frames[0] }
        let position = time / hopSeconds
        guard position < Double(frames.count - 1) else { return frames[frames.count - 1] }
        let lower = Int(position)
        let fraction = position - Double(lower)
        let a = frames[lower]
        let b = frames[lower + 1]
        guard fraction > 0 else { return a }
        var bands = a.bands
        for i in bands.indices where i < b.bands.count {
            bands[i] = a.bands[i] + (b.bands[i] - a.bands[i]) * fraction
        }
        return AudioLevels(envelope: a.envelope + (b.envelope - a.envelope) * fraction,
                           bands: bands)
    }

    /// Reads `url` (any AVAudioFile-readable container; Piper WAVs are
    /// mono 22.05 kHz) and produces the 50 %-overlap frame series.
    /// Channels are averaged. Returns nil on any read failure — the
    /// caller degrades to metering-only (envelope) and silent bars,
    /// never to fabricated data. Runs off-main; cost for a typical
    /// 5 s reply is a few milliseconds.
    static func build(from url: URL) -> AudioBandTrack? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let totalFrames = AVAudioFramePosition(file.length)
        guard totalFrames > 0 else { return nil }
        let chunk: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: chunk) else { return nil }
        var mono: [Float] = []
        mono.reserveCapacity(Int(totalFrames))
        while file.framePosition < totalFrames {
            do { try file.read(into: buffer) } catch { break }
            let framesRead = Int(buffer.frameLength)
            guard framesRead > 0, let data = buffer.floatChannelData else { break }
            let channels = Int(format.channelCount)
            for i in 0..<framesRead {
                var sum: Float = 0
                for ch in 0..<channels { sum += data[ch][i] }
                mono.append(sum / Float(channels))
            }
        }
        let fftLength = AudioLevelExtraction.fftLength
        guard mono.count >= fftLength,
              let fft = SpectralGateCore.FFT(log2n: 9) else { return nil }
        let hop = fftLength / 2
        var frames: [AudioLevels] = []
        var start = 0
        while start + fftLength <= mono.count {
            let slice = Array(mono[start..<(start + fftLength)])
            let raw = AudioLevelExtraction.frame(fromFloats: slice, fft: fft,
                                                 sampleRate: format.sampleRate)
            frames.append(AudioLevelAnalyzer.mapped(raw))
            start += hop
        }
        guard !frames.isEmpty else { return nil }
        return AudioBandTrack(frames: frames,
                              hopSeconds: Double(hop) / format.sampleRate)
    }
}

/// AVAudioPlayer-backed speaker source ([AUDIO-REACTIVE-HERO]).
///
/// The envelope is the player's own live metering — `isMeteringEnabled`
/// (set by `PiperVoiceSpeaker.play` before `play()`) +
/// `updateMeters()`/`averagePower(forChannel:)`, dBFS of the audio being
/// played. When metering yields no usable reading (the docs' −160 dB
/// silence floor, or a player that never meters), the envelope falls
/// back to the precomputed track at `elapsed` — still the same audio's
/// own signal, never fabricated.
///
/// The band track is built asynchronously from the playback file the
/// moment this source is created; `bandLevels(at:)` returns [] until it
/// lands (a few ms into playback), and the UI simply holds bars steady
/// for that first blink. Nothing on the playback path is delayed for
/// analysis — `play()` is not gated on the build (turn latency is
/// sacred).
final class PiperPlaybackLevelSource: SpeakerLevelSource {
    private weak var player: AVAudioPlayer?
    private let trackLock = NSLock()
    private var track: AudioBandTrack?

    init(player: AVAudioPlayer, playbackURL: URL) {
        self.player = player
        Task.detached(priority: .utility) { [weak self] in
            let built = AudioBandTrack.build(from: playbackURL)
            guard let self else { return }
            self.trackLock.lock()
            self.track = built
            self.trackLock.unlock()
        }
    }

    var elapsed: TimeInterval { player?.currentTime ?? 0 }

    func envelopeLevel() -> Double? {
        guard let player else { return nil }
        player.updateMeters()
        // Channel 0 is representative: shipped voices are mono, and the
        // metering is a display input, not a measurement.
        let db = Double(player.averagePower(forChannel: 0))
        if db > -160 {
            return AudioLevelMapping.normalized(db: db,
                                                floorDb: AudioLevelMapping.envelopeFloorDb,
                                                ceilingDb: AudioLevelMapping.envelopeCeilingDb)
        }
        return precomputed()?.envelope
    }

    func bandLevels(at time: TimeInterval) -> [Double] {
        precomputed()?.bands ?? []
    }

    private func precomputed() -> AudioLevels? {
        trackLock.lock()
        defer { trackLock.unlock() }
        guard let track else { return nil }
        return track.levels(at: elapsed)
    }
}

// MARK: - The source-of-truth model ([AUDIO-REACTIVE-HERO])

/// The single model both audio sides feed and the hero observes. One
/// owner at a time (the task's rule): mic while capturing, speaker while
/// playing, idle fallback otherwise. `TalkButton` reads `envelope`
/// (disc bounce + state-glyph breathing), `bands` (equalizer bars), and
/// `source` (whether REAL signal is flowing — the honest gate between
/// signal-driven motion and the existing idle fallback).
final class AudioLevelPublisher: ObservableObject {
    /// Which side currently owns the meter.
    enum Source: Equatable {
        /// Nothing is flowing (or a release tail is finishing).
        case none
        /// Live capture frames — the mic family.
        case mic
        /// Speaker playback with a real signal feed (Piper: metering +
        /// the played file's own band track).
        case speakerLive
        /// Speaker playback the system exposes NO signal for
        /// (AVSpeechSynthesizer / NullSpeaker). The UI must fall back to
        /// idle motion — never a fake meter. Commented as such at every
        /// consumption site.
        case speakerMeterless
    }

    @Published private(set) var envelope: Double = 0
    @Published private(set) var bands: [Double] = AudioLevels.baseline.bands
    @Published private(set) var source: Source = .none

    /// True exactly when the published levels are REAL signal — the
    /// hero's one gate between signal-driven motion and the fallback.
    var hasLiveSignal: Bool { source == .mic || source == .speakerLive }

    // MARK: Mic side (processing-queue producer, lock-protected)

    private let micLock = NSLock()
    private var captureActive = false
    private var micAnalyzer = AudioLevelAnalyzer()
    private var micFFT: SpectralGateCore.FFT?
    private var micFFTAttempted = false
    private var lastMicFrameAt: TimeInterval = 0

    // MARK: Main side (UI-confined)

    private var captureActiveMain = false
    private var speakerActive = false
    private var speakerHasSignal = false
    private var speakerLevelSource: SpeakerLevelSource?
    private var speakerAnalyzer = AudioLevelAnalyzer()
    private var tailAnalyzer = AudioLevelAnalyzer()
    private var tailActive = false
    private var driverTimer: Timer?
    private var lastDriverTick: TimeInterval = 0
    private var throttle = PublishThrottle()

    // MARK: - Mic feed (called by VoicePipeline)

    /// Capture epoch began (VoicePipeline.beginCapture — before the state
    /// flip, so the first frame is never dropped by the guard below).
    func captureStarted() {
        micLock.lock()
        captureActive = true
        micAnalyzer = AudioLevelAnalyzer()
        lastMicFrameAt = 0
        micLock.unlock()

        onMain {
            // Owner switch (the task's rule): mic WINS while capturing.
            // A live speaker feed is detached whole — the speaker's own
            // `speakerEnded` (settle/cancel) is idempotent against this.
            self.captureActiveMain = true
            self.tailActive = false
            self.speakerActive = false
            self.speakerHasSignal = false
            self.speakerLevelSource = nil
            self.speakerAnalyzer = AudioLevelAnalyzer()
            self.source = .mic
            self.stopDriverTimer()
        }
    }

    /// Capture epoch ended (the STT completion tail, or `stop()`).
    func captureEnded() {
        micLock.lock()
        captureActive = false
        micLock.unlock()

        onMain {
            self.captureActiveMain = false
            // Mic released the meter: a still-playing speaker feed takes
            // it back (the other half of the owner switch); otherwise the
            // release tail carries the last readings down.
            if self.speakerActive, self.speakerHasSignal,
               self.speakerLevelSource != nil {
                self.source = .speakerLive
                self.lastDriverTick = CFAbsoluteTimeGetCurrent()
                self.ensureDriverTimer()
            } else {
                self.beginReleaseTail()
            }
        }
    }

    /// One contiguous 16 kHz frame (512 samples — the VAD's slice) from
    /// the pipeline's processing queue. Computes on the calling thread,
    /// publishes on main, throttled. NEVER runs on the audio render
    /// thread — the pipeline hands frames over from its processing
    /// queue (a plain serial DispatchQueue), not from an audio tap.
    func ingestCaptureFrame(_ pcm: [Int16], sampleRate: Double = 16_000) {
        let levels: AudioLevels
        micLock.lock()
        guard captureActive else { micLock.unlock(); return }
        if !micFFTAttempted {
            // Thread-confined to the processing queue — the same doctrine
            // SpectralGateCore.FFT documents for the denoiser's instance.
            micFFT = SpectralGateCore.FFT(log2n: 9)
            micFFTAttempted = true
        }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = lastMicFrameAt == 0 ? Double(AudioLevelExtraction.fftLength) / sampleRate
                                     : min(max(now - lastMicFrameAt, 0.001), 0.25)
        lastMicFrameAt = now
        let frame = AudioLevelExtraction.frame(fromPCM: pcm, fft: micFFT,
                                               sampleRate: sampleRate)
        levels = micAnalyzer.update(raw: frame, dt: dt)
        micLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.source == .mic else { return }
            self.publish(levels)
        }
    }

    // MARK: - Speaker feed (called by PiperVoiceSpeaker)

    /// A reply started playing with a REAL signal source (Piper). The
    /// 30 Hz driver timer pulls envelope + bands until `speakerEnded`.
    func speakerStarted(source levelSource: SpeakerLevelSource) {
        onMain {
            self.speakerActive = true
            self.speakerHasSignal = true
            self.speakerLevelSource = levelSource
            self.speakerAnalyzer = AudioLevelAnalyzer()
            self.tailActive = false
            // Mic wins while capturing (owner rule): the feed is armed,
            // but the source flips to the speaker only once capture
            // ends (see `captureEnded`).
            guard !self.captureActiveMain else { return }
            self.source = .speakerLive
            self.lastDriverTick = CFAbsoluteTimeGetCurrent()
            self.ensureDriverTimer()
        }
    }

    /// A reply is playing but the platform exposes NO audio signal for it
    /// (AVSpeechSynthesizer — no level API exists on the synthesizer —
    /// or the NullSpeaker silence fallback). Honest no-data: the source
    /// is marked meterless so the UI keeps the EXISTING idle motion and
    /// never renders a fake meter.
    func speakerStartedMeterless() {
        onMain {
            self.speakerActive = true
            self.speakerHasSignal = false
            self.speakerLevelSource = nil
            guard !self.captureActiveMain else { return } // mic keeps the meter
            self.source = .speakerMeterless
            self.beginReleaseTail() // decay any residue from a prior live reply
        }
    }

    /// Playback settled or was cancelled. Idempotent.
    func speakerEnded() {
        onMain {
            self.speakerActive = false
            self.speakerHasSignal = false
            self.speakerLevelSource = nil
            self.beginReleaseTail()
        }
    }

    // MARK: - Main-queue driver

    /// A source ended: decay the last REAL readings to rest (never snap,
    /// never invent). The source latches through the tail so the hero
    /// keeps rendering the fall for the ~300 ms it lasts.
    private func beginReleaseTail() {
        guard !captureActiveMain, !speakerActive else { return }
        tailAnalyzer.seed(currentLevels())
        tailActive = !tailAnalyzer.levels.isAtRest
        if tailActive {
            lastDriverTick = CFAbsoluteTimeGetCurrent()
            ensureDriverTimer()
        } else {
            publish(.baseline, force: true)
            source = .none
            stopDriverTimer()
        }
    }

    private func driverTick() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = min(max(now - lastDriverTick, 0.001), 0.25)
        lastDriverTick = now

        // Mic owns the meter while capturing — its frames are pushed in
        // from the processing queue; the timer has nothing to do.
        guard !captureActiveMain else { return }

        if speakerActive {
            if speakerHasSignal, let levelSource = speakerLevelSource {
                let levels = speakerAnalyzer.update(
                    envelopeTarget: levelSource.envelopeLevel() ?? 0,
                    bandTargets: levelSource.bandLevels(at: levelSource.elapsed),
                    dt: dt)
                publish(levels)
                return
            }
            // Meterless playback: nothing to pull. Hold rest; the
            // residual release (if any) still finishes below.
        }

        guard tailActive else {
            stopDriverTimer()
            return
        }
        let levels = tailAnalyzer.releaseTowardRest(dt: dt)
        if levels.isAtRest {
            tailActive = false
            publish(.baseline, force: true)
            if !speakerActive { source = .none }
            stopDriverTimer()
        } else {
            publish(levels)
        }
    }

    private func ensureDriverTimer() {
        onMain {
            guard self.driverTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.driverTick()
            }
            // .common keeps the meter ticking during scrolls/tracking.
            RunLoop.main.add(timer, forMode: .common)
            self.driverTimer = timer
        }
    }

    private func stopDriverTimer() {
        onMain {
            self.driverTimer?.invalidate()
            self.driverTimer = nil
        }
    }

    // MARK: - Publish

    /// Main-queue publish, throttled to ≤ ~35 Hz. Field-level compares
    /// keep identical values from waking SwiftUI's update loop.
    private func publish(_ levels: AudioLevels, force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        guard force || throttle.shouldPublish(now: now) else { return }
        if envelope != levels.envelope { envelope = levels.envelope }
        if bands != levels.bands { bands = levels.bands }
    }

    private func currentLevels() -> AudioLevels {
        AudioLevels(envelope: envelope, bands: bands)
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
