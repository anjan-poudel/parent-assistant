import Foundation
import AVFoundation

/// Voice activity detector: decides whether a chunk of PCM audio contains
/// speech, and reports when the user has stopped talking — after the
/// trailing-silence hangover VoicePipeline configures (900 ms since
/// 2026-09-07, see `VoicePipeline.endOfUtteranceMs`). Used to gate the
/// speech recognizer: VoicePipeline calls the recognizer's `finish()` on
/// `onEndOfUtterance`, so a finished command flips to transcription
/// within ~1.0-1.5 s of the user's last word instead of riding the
/// capture cap.
///
/// Concrete production impl is the Silero ONNX model (~2 MB). The Null
/// implementation is a permissive fallback that always treats audio as
/// speech — useful for tests and for the scaffold state before the ONNX
/// model has been downloaded.
protocol VoiceActivityDetector: AnyObject {
    /// Sample rate the detector expects (16 kHz for Silero).
    var requiredSampleRate: Double { get }
    /// Number of samples per processing frame (typically 512 at 16 kHz).
    var frameLength: Int { get }
    /// Called with the *smoothed* speech state, not raw frame decisions.
    var onSpeechStateChange: ((Bool) -> Void)? { get set }
    /// Called once when trailing silence exceeds `endOfUtteranceMs`.
    var onEndOfUtterance: (() -> Void)? { get set }
    /// Called once when the trailing-silence FORCE END trips instead of
    /// the normal quiet-run end: the utterance contained speech, but no
    /// end-of-utterance fired within the detector's force-end window
    /// because post-speech noise kept every frame above the end line
    /// (see `EnergyVAD.forceEndAfterSilenceMs`). Distinct from
    /// `onEndOfUtterance` so callers can report an honest event
    /// (`vad_force_end`) and tell a user-pause from a silence-detection.
    var onForcedEndOfUtterance: (() -> Void)? { get set }

    func start(endOfUtteranceMs: Int)
    func stop()
    func reset()
    func process(_ pcm: [Int16])
}

extension VoiceActivityDetector {
    /// Default no-op storage: implementations that never force-end
    /// (`NullVAD`, the guarded Silero impl, test fakes) conform without
    /// declaring the property.
    var onForcedEndOfUtterance: (() -> Void)? {
        get { nil }
        set { }
    }
}

// MARK: - Null implementation (fallback, tests)

/// Always returns "speech present"; never emits end-of-utterance on its
/// own. Callers must impose their own timeout. This is the safest failure
/// mode: the STT will still run, we just won't cut it short.
final class NullVAD: VoiceActivityDetector {
    let requiredSampleRate: Double = 16_000
    let frameLength: Int = 512
    var onSpeechStateChange: ((Bool) -> Void)?
    var onEndOfUtterance: (() -> Void)?

    private var reportedSpeech = false

    func start(endOfUtteranceMs: Int) {
        if !reportedSpeech {
            reportedSpeech = true
            onSpeechStateChange?(true)
        }
    }
    func stop() {}
    func reset() { reportedSpeech = false }
    func process(_ pcm: [Int16]) {}
}

// MARK: - Lightweight local VAD (MVP)

/// Energy-based VAD used for the iOS MVP before the Silero runtime is linked.
///
/// Two cooperating mechanisms, both adaptive — no fixed absolute levels:
///
/// 1. SPEECH START uses an adaptive absolute threshold: an EMA of ambient
///    frame RMS (`noiseFloor`) tracks the room while no speech is active,
///    and speech begins when a frame exceeds `speechMultiplier` x floor
///    (clamped to [minSpeechThreshold, maxSpeechThreshold]).
///
/// 2. SPEECH END uses a RELATIVE drop: while speech is active, an EMA of
///    the speech energy (`speechLevel`) is maintained, and any frame below
///    `max(minSpeechThreshold, speechLevel x dropRatio)` counts toward the
///    trailing-silence hangover. Keying off the DROP from observed speech
///    energy — not an absolute quiet level — is what makes endpointing
///    work in real homes: when the user stops talking, RMS falls from
///    speech level to whatever the background is (fan/TV/street), and the
///    end-of-utterance fires after the hangover no matter how loud that
///    background happens to be.
///
/// Why: the previous fixed thresholds (0.018/0.010 RMS) silently stopped
/// endpointing outside quiet rooms — ordinary background noise sits ABOVE
/// a quiet-room threshold, the quiet counter kept resetting, and every
/// capture ran out VoicePipeline's fixed 8 s timeout before transcription
/// even started (the "constant lag" reported 2026-09-05). A first adaptive
/// attempt that learned the floor only from below-threshold frames still
/// failed: noise louder than the seed threshold is classified AS speech,
/// so the floor could never rise to meet it (chicken-and-egg). The
/// relative-drop end criterion has no such dependency.
///
/// But the relative-drop criterion as first built over-corrected the
/// OTHER way (2026-09-07, user-reported "still listening after I've
/// stopped speaking"): `speechLevel` was a symmetric EMA dragged toward
/// every frame ABOVE the end line — including the utterance's own soft
/// final words — so a trailing that stayed within ~6 dB of the recent
/// loud level pulled the reference down onto the background, endLevel
/// fell below the ambient, and the quiet run could never complete; every
/// capture then ran out VoicePipeline's fixed 8 s cap. The reference is
/// therefore now ONE-SIDED: frames at or above it pull it up fast
/// (attack), and below it it decays only by time (~3 dB/s) — never by
/// being dragged toward a soft frame or the ambient. The band between
/// endLevel and the reference HOLDS the silence counter (neither counts
/// nor resets), so modulated background noise (TV words, fan gusts)
/// can no longer postpone the end indefinitely, while a frame AT or
/// above the reference — clearly the user still talking — still resets
/// the counter so a resumed utterance after a pause restarts the
/// hangover cleanly.
///
/// TRAILING-SILENCE FORCE END ([VAD-TUNE], 2026-09-11): the hold band has
/// one hole the 2026-09-07 design cannot close on its own. When speech
/// stops and the remaining audio parks IN the band (post-speech noise at
/// or above the end line — quiet elderly speech leaves `speechLevel` low,
/// so `endLevel` sits near the `minSpeechThreshold` clamp, and the
/// phone's input AGC keeps boosted room noise above it), the quiet
/// counter never accrues and the utterance never ends. A third mechanism
/// therefore runs alongside the hangover: a force-end timer counts frames
/// since the last clear-speech frame (`rms >= speechLevel`). While it
/// runs, the reference DECAY IS FROZEN — the reference must not sink
/// toward the background, or band noise would cross it frame-by-frame and
/// keep resetting the timer forever (the same chicken-and-egg the
/// 2026-09-07 note describes). After `forceEndAfterSilenceMs` (7 s
/// production) with no clear-speech frame, the utterance is force-ended
/// via `onForcedEndOfUtterance` — VoicePipeline then emits `vad_force_end`
/// and feeds the recognizer exactly like a normal end.
///
/// Trade-off (deliberate): a speaker who falls silent for the whole force
/// window and THEN resumes — with the interim energy in the band — is cut
/// at the force end. That is the same cut the recognizer's fixed capture
/// cap used to impose at 8 s; the force end just moves it to speech-end +
/// 7 s, keeps the audio (finish(), never cancel()), and reports honestly.
/// The freeze also means a quieter continuation no longer re-anchors the
/// reference by decay (the old ~1-2 s re-anchor path); it is held in the
/// band until the force end. Energy at or above the reference still
/// resets everything, so continuous speech keeps the utterance alive.
final class EnergyVAD: VoiceActivityDetector {
    let requiredSampleRate: Double = 16_000
    let frameLength: Int = 512
    var onSpeechStateChange: ((Bool) -> Void)?
    var onEndOfUtterance: (() -> Void)?
    var onForcedEndOfUtterance: (() -> Void)?

    /// Speech-start threshold = noiseFloor x this (before clamping).
    private let speechMultiplier: Float
    /// EMA rate for the noise floor (~1 s to converge at 31.25 fps).
    private let floorAlpha: Float
    /// End-of-speech line = speechLevel x this (6 dB below the recent
    /// speech reference), floored at minSpeechThreshold so near-silent
    /// tails in quiet rooms still count.
    private let dropRatio: Float
    /// Attack rate for speechLevel: how fast the reference follows a
    /// frame AT or ABOVE it (~90 ms to 63% at 31.25 fps). Loud speech
    /// re-anchors the end line quickly; see the class note (2026-09-07)
    /// for why the reference is never dragged DOWN toward an observed
    /// frame.
    private let speechLevelAlpha: Float
    /// Time-only decay of speechLevel while frames arrive below it,
    /// in dB per second. ~3 dB/s is slow enough that the end line stays
    /// above fan/TV noise for the whole ~0.9 s hangover window (0.096 dB
    /// per 32 ms frame — only ~2.8 dB across the window — so a background
    /// more than ~3 dB below the end line at speech end is still counted
    /// as quiet on its 29th frame) and fast enough that a sustained
    /// quieter continuation re-anchors the reference within ~1-2 s via
    /// the attack (2026-09-07).
    private let speechLevelReleaseDbPerSecond: Float
    /// = 10^(-(dB/s) x 32 ms / 20), precomputed so the hot path only
    /// multiplies.
    private let releaseFactorPerFrame: Float
    /// Absolute clamps on the speech-start threshold: keeps sensitivity in
    /// a silent room (floor ~ 0) and bounds it in a very loud one.
    private let minSpeechThreshold: Float
    private let maxSpeechThreshold: Float
    /// Trailing-silence force-end window (see the class note): ms since
    /// the last clear-speech frame (`rms >= speechLevel`) after which a
    /// still-active utterance is force-ended. Must be well above
    /// `endOfUtteranceMs` (the normal end always wins in real quiet) and
    /// below the recognizer's total capture cap (22 s), which bounds the
    /// no-speech and continuous-speech cases.
    private let forceEndAfterSilenceMs: Int
    /// `forceEndAfterSilenceMs` in 32 ms frames, precomputed.
    private let forceEndAfterSilenceFrames: Int
    /// Ambient RMS estimate. Seeded low so first use is maximally
    /// sensitive. NOT reset per utterance — a property of the room.
    private var noiseFloor: Float
    private let initialNoiseFloor: Float
    /// Running speech-energy reference while `speechActive`: pulled UP by
    /// frames at/above it, otherwise decays only by time
    /// (`speechLevelReleaseDbPerSecond`) — never dragged toward a soft
    /// frame or the ambient (2026-09-07). Reset per utterance. [VAD-TUNE]
    /// The decay is FROZEN while the force-end timer is running
    /// (`framesSinceClearSpeech > 0`) — see the class note.
    private var speechLevel: Float = 0

    private var running = false
    private var speechActive = false
    private var quietFrames = 0
    private var requiredQuietFrames = 8
    private var hasReportedEnd = false
    /// [VAD-TUNE] Frames since the last clear-speech frame while
    /// `speechActive` — the force-end timer. Reset by any frame at or
    /// above the reference.
    private var framesSinceClearSpeech = 0

    init(speechMultiplier: Float = 2.5,
         floorAlpha: Float = 0.08,
         dropRatio: Float = 0.5,
         speechLevelAlpha: Float = 0.3,
         speechLevelReleaseDbPerSecond: Float = 3.0,
         minSpeechThreshold: Float = 0.012,
         maxSpeechThreshold: Float = 0.10,
         initialNoiseFloor: Float = 0.005,
         forceEndAfterSilenceMs: Int = 7000) {
        self.speechMultiplier = speechMultiplier
        self.floorAlpha = floorAlpha
        self.dropRatio = dropRatio
        self.speechLevelAlpha = speechLevelAlpha
        self.speechLevelReleaseDbPerSecond = speechLevelReleaseDbPerSecond
        // A 512-sample frame at 16 kHz is 32 ms.
        self.releaseFactorPerFrame = Float(pow(
            10.0,
            Double(-speechLevelReleaseDbPerSecond) * 0.032 / 20.0))
        self.minSpeechThreshold = minSpeechThreshold
        self.maxSpeechThreshold = maxSpeechThreshold
        self.initialNoiseFloor = initialNoiseFloor
        self.noiseFloor = initialNoiseFloor
        self.forceEndAfterSilenceMs = forceEndAfterSilenceMs
        self.forceEndAfterSilenceFrames = max(1, Int(ceil(
            (Double(forceEndAfterSilenceMs) / 1000.0) /
            (Double(frameLength) / requiredSampleRate))))
    }

    private var speechStartThreshold: Float {
        min(maxSpeechThreshold, max(minSpeechThreshold, noiseFloor * speechMultiplier))
    }

    func start(endOfUtteranceMs: Int) {
        requiredQuietFrames = max(1, Int(ceil((Double(endOfUtteranceMs) / 1000.0) /
                                            (Double(frameLength) / requiredSampleRate))))
        running = true
        reset()
    }

    func stop() {
        running = false
    }

    func reset() {
        speechActive = false
        speechLevel = 0
        quietFrames = 0
        hasReportedEnd = false
        framesSinceClearSpeech = 0
        // noiseFloor survives reset(): room calibration carries across
        // utterances within a capture session.
    }

    func process(_ pcm: [Int16]) {
        guard running, !pcm.isEmpty, !hasReportedEnd else { return }
        let rms = Self.rms(pcm)

        if !speechActive {
            if rms >= speechStartThreshold {
                speechActive = true
                speechLevel = rms
                quietFrames = 0
                framesSinceClearSpeech = 0
                onSpeechStateChange?(true)
            } else {
                noiseFloor += floorAlpha * (rms - noiseFloor)
            }
            return
        }

        // Speech active (2026-09-07): three energy bands decide what a
        // frame means for ending the utterance:
        //
        //  rms >= speechLevel             clear speech — reset the silence
        //                                 counter, pull the reference up
        //  endLevel <= rms < speechLevel  the band — HOLDS the counter: a
        //                                 soft final word or a noise
        //                                 transient may sit here, but it
        //                                 neither counts toward the end nor
        //                                 postpones it
        //  rms < endLevel                 quiet — accrue toward the
        //                                 trailing-silence hangover
        //
        // The reference is ONE-SIDED: pulled up only by frames at or above
        // it, below it decays only by time (`speechLevelReleaseDbPerSecond`,
        // ~3 dB/s). The old symmetric EMA was dragged down by every frame
        // above the end line — including the utterance's own soft final
        // words — until endLevel fell below the ambient noise and no frame
        // ever counted as quiet; captures then rode VoicePipeline's fixed
        // cap ("still listening after I've stopped speaking", see the class
        // note). The hold band stops modulated background noise (TV words,
        // fan gusts) that crosses the end line from perpetually resetting
        // the hangover, while a frame AT or above the reference — clearly
        // the user still talking — still resets it, so a resumed utterance
        // after a pause restarts the hangover cleanly.
        if rms >= speechLevel {
            quietFrames = 0
            framesSinceClearSpeech = 0
            speechLevel += speechLevelAlpha * (rms - speechLevel)
            return
        }

        // Below the reference: it decays by time, never toward this frame
        // (a soft trailing word or ambient noise must not become the new
        // reference; see above). [VAD-TUNE] The decay is FROZEN while the
        // force-end timer is running — decaying into band noise would let
        // the noise cross the reference and reset the timer frame by
        // frame, so the force end could never fire (see the class note).
        if framesSinceClearSpeech == 0 {
            speechLevel *= releaseFactorPerFrame
        }

        let endLevel = max(minSpeechThreshold, speechLevel * dropRatio)

        // Every below-reference frame — band OR quiet — is "not clear
        // speech": accrue the force-end timer first. In production the
        // normal hangover (0.9 s) always fires long before the force
        // window (7 s) whenever real quiet exists; the force end only
        // trips when noise parks in the band and the quiet counter never
        // accrues.
        framesSinceClearSpeech += 1
        if framesSinceClearSpeech >= forceEndAfterSilenceFrames {
            hasReportedEnd = true
            speechActive = false
            onSpeechStateChange?(false)
            onForcedEndOfUtterance?()
            return
        }

        if rms >= endLevel {
            // The band: hold the quiet counter (see above) — this frame is
            // neither quiet enough to accrue nor loud enough to reset.
            return
        }

        // Quiet-counted frame — also teach the floor (a mid-speech gap is
        // a sample of the room), but never the speechLevel reference.
        noiseFloor += floorAlpha * (rms - noiseFloor)
        quietFrames += 1
        if quietFrames >= requiredQuietFrames {
            hasReportedEnd = true
            speechActive = false
            onSpeechStateChange?(false)
            onEndOfUtterance?()
        }
    }

    private static func rms(_ pcm: [Int16]) -> Float {
        var sum: Float = 0
        for sample in pcm {
            let normalized = Float(sample) / 32_768.0
            sum += normalized * normalized
        }
        return sqrt(sum / Float(pcm.count))
    }
}

// MARK: - Silero ONNX implementation (guarded)

/// Real VAD backed by the Silero v5 ONNX model. Enabled once the
/// `onnxruntime-swift-package-manager` SPM package is added to
/// `project.yml` (see docs/voice-pipeline-setup.md) AND the model file has
/// been downloaded via `ModelStore` under `ModelCatalog.sileroVAD`.
///
/// Until both of those are true, `VoicePipeline` uses `NullVAD` and the
/// speech recognizer runs on its internal ~5-second timeout — functional
/// but not snappy.
#if canImport(onnxruntime_objc)
import onnxruntime_objc

final class SileroONNXVAD: VoiceActivityDetector {
    let requiredSampleRate: Double = 16_000
    let frameLength: Int = 512
    var onSpeechStateChange: ((Bool) -> Void)?
    var onEndOfUtterance: (() -> Void)?

    private let session: ORTSession
    private let env: ORTEnv
    private let inputNodeName = "input"
    private let stateNodeName = "state"
    private let srNodeName = "sr"

    // Silero v5 has an internal state tensor that must be threaded through
    // successive calls. We initialize to zeros.
    private var stateTensorBytes = Data(count: 2 * 1 * 128 * MemoryLayout<Float>.size)

    private let speechThreshold: Float = 0.5
    private let silenceThreshold: Float = 0.35   // hysteresis
    private var lastSpeechAt: Date?
    private var speechActive = false
    private var endOfUtteranceMs = 200
    private var running = false

    init(modelPath: String) throws {
        self.env = try ORTEnv(loggingLevel: .warning)
        self.session = try ORTSession(env: env, modelPath: modelPath,
                                      sessionOptions: nil)
    }

    func start(endOfUtteranceMs: Int) {
        self.endOfUtteranceMs = endOfUtteranceMs
        self.running = true
        reset()
    }

    func stop() { running = false }

    func reset() {
        stateTensorBytes.resetBytes(in: 0..<stateTensorBytes.count)
        lastSpeechAt = nil
        speechActive = false
    }

    func process(_ pcm: [Int16]) {
        guard running else { return }
        // Silero expects float32 in [-1, 1].
        var floats = [Float](repeating: 0, count: pcm.count)
        for i in 0..<pcm.count { floats[i] = Float(pcm[i]) / 32_768.0 }
        // Real Silero inference call would happen here; the shape/name
        // handling is left as follow-up work when the SPM package is
        // actually available in the build. This branch only compiles when
        // `onnxruntime_objc` is importable — enabling that is a separate
        // controlled step in the plan.
        _ = floats
        _ = session
    }
}
#endif
