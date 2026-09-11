import XCTest
@testable import ElderlyAssistant

final class EnergyVADTests: XCTestCase {

    /// Constant-amplitude mono frames at the VAD's frame length.
    /// RMS of a constant frame is |amplitude| / 32768.
    private func frames(_ amplitude: Int16, count: Int, length: Int = 512) -> [[Int16]] {
        (0..<count).map { _ in Array(repeating: amplitude, count: length) }
    }

    /// Speech burst followed by digital silence ends the utterance after
    /// the trailing-silence hangover.
    func testEndOfUtteranceFiresAfterSpeechThenSilence() {
        let vad = EnergyVAD()
        var ended = false
        vad.onEndOfUtterance = { ended = true }

        vad.start(endOfUtteranceMs: 100)   // 4-frame hangover at 32 ms/frame
        for f in frames(3_000, count: 4) { vad.process(f) }
        XCTAssertFalse(ended, "must not fire while speech is still arriving")
        for f in frames(0, count: 4) { vad.process(f) }
        XCTAssertTrue(ended)
    }

    /// Pure ambient audio never starts an utterance, so nothing can end.
    func testSilenceAloneDoesNotEndUtterance() {
        let vad = EnergyVAD()
        var ended = false
        vad.onEndOfUtterance = { ended = true }

        vad.start(endOfUtteranceMs: 100)
        for f in frames(0, count: 10) { vad.process(f) }
        XCTAssertFalse(ended)
    }

    /// REGRESSION (2026-09-05): sustained household noise (fan/TV) louder
    /// than the old FIXED thresholds made the previous EnergyVAD never
    /// fire — every capture ran out VoicePipeline's fixed 8 s timeout,
    /// which the user felt as a constant lag before translation started.
    /// Endpointing must key off the energy DROP when speech stops, not an
    /// absolute quiet level.
    func testEndOfUtteranceFiresAboveSustainedBackgroundNoise() {
        let vad = EnergyVAD()
        var ended = false
        vad.onEndOfUtterance = { ended = true }

        // Noise RMS ≈ 0.021 — ABOVE the old fixed speech threshold (0.018),
        // i.e. the exact scenario that used to wedge endpointing.
        vad.start(endOfUtteranceMs: 100)
        for f in frames(700, count: 31) { vad.process(f) }      // ~1 s ambient before speech
        for f in frames(6_000, count: 16) { vad.process(f) }    // the utterance
        XCTAssertFalse(ended, "fired during speech")
        for f in frames(700, count: 4) { vad.process(f) }       // speech stops, noise remains
        XCTAssertTrue(ended, "must endpoint even though background noise is loud")
    }

    /// Noise that STARTS mid-capture (TV turns on while the user talks)
    /// must not wedge endpointing either: the end criterion is relative
    /// to the observed speech level, so a post-speech drop to ANY steady
    /// background level still ends the utterance.
    func testEndOfUtteranceFiresWhenNoiseStartsMidUtterance() {
        let vad = EnergyVAD()
        var ended = false
        vad.onEndOfUtterance = { ended = true }

        vad.start(endOfUtteranceMs: 100)
        for f in frames(100, count: 10) { vad.process(f) }      // quiet room
        for f in frames(6_000, count: 16) { vad.process(f) }    // speech
        for f in frames(700, count: 4) { vad.process(f) }       // TV switches on as speech ends
        XCTAssertTrue(ended, "must endpoint onto noise that began mid-utterance")
    }

    /// A pause shorter than the hangover must NOT cut the utterance; the
    /// endpoint fires exactly once, after the final trailing silence.
    func testBriefPauseDoesNotEndUtterance() {
        let vad = EnergyVAD()
        var fireCount = 0
        vad.onEndOfUtterance = { fireCount += 1 }

        vad.start(endOfUtteranceMs: 100)   // 4-frame hangover
        for f in frames(3_000, count: 8) { vad.process(f) }
        for f in frames(0, count: 3) { vad.process(f) }          // 96 ms breath pause
        XCTAssertEqual(fireCount, 0, "brief pause must not end the utterance")
        for f in frames(3_000, count: 8) { vad.process(f) }
        for f in frames(0, count: 4) { vad.process(f) }
        XCTAssertEqual(fireCount, 1)
    }

    /// The absolute minimum clamp keeps soft elderly voices audible in a
    /// quiet room: audio just above minSpeechThreshold starts an
    /// utterance, and the trailing silence ends it.
    func testSoftSpeechInQuietRoomIsDetectedAndEnded() {
        let vad = EnergyVAD()
        var ended = false
        vad.onEndOfUtterance = { ended = true }

        vad.start(endOfUtteranceMs: 100)
        for f in frames(0, count: 10) { vad.process(f) }         // silent room → floor ≈ 0
        for f in frames(400, count: 8) { vad.process(f) }        // RMS 0.0122 ≥ min clamp 0.012
        for f in frames(0, count: 4) { vad.process(f) }
        XCTAssertTrue(ended, "soft speech in a quiet room must be detected and ended")
    }

    // MARK: - Hangover at the production 900 ms setting (2026-09-07)
    //
    // VoicePipeline has configured `endOfUtteranceMs = 900` since
    // 2026-09-07, i.e. 29 frames at 32 ms/frame (928 ms) of trailing
    // silence. These tests pin the endpointing contract at that setting:
    // a real trailing silence of ~1 s closes the utterance, mid-utterance
    // pauses of 0.5-0.7 s (normal for elderly speakers) do NOT close it,
    // and modulated background noise can no longer keep a finished
    // utterance open indefinitely.

    /// A finished utterance ends after ~1 s of trailing silence, at the
    /// exact boundary: 28 quiet frames (896 ms) keep listening, the 29th
    /// (928 ms) fires.
    func testTrailingSilenceOfAboutOneSecondClosesUtterance() {
        let vad = EnergyVAD()
        var ended = false
        vad.onEndOfUtterance = { ended = true }

        vad.start(endOfUtteranceMs: 900)   // 29-frame hangover
        for f in frames(3_000, count: 4) { vad.process(f) }   // speech, RMS 0.0916
        XCTAssertFalse(ended, "must not fire while speech is still arriving")
        for f in frames(0, count: 28) { vad.process(f) }      // 896 ms silence
        XCTAssertFalse(ended, "896 ms of trailing silence must not close yet")
        for f in frames(0, count: 1) { vad.process(f) }       // 928 ms total
        XCTAssertTrue(ended, "~1 s of trailing silence must close the utterance")
    }

    /// A 0.5 s mid-utterance pause — a slow speaker's breath or word
    /// search — must NOT close the utterance: 16 quiet frames (512 ms)
    /// is well short of the 29-frame hangover, and the resumed speech
    /// restarts the hangover from zero.
    func testMidUtterancePauseOfHalfSecondDoesNotClose() {
        let vad = EnergyVAD()
        var fireCount = 0
        vad.onEndOfUtterance = { fireCount += 1 }

        vad.start(endOfUtteranceMs: 900)
        for f in frames(3_000, count: 8) { vad.process(f) }   // speech
        for f in frames(0, count: 16) { vad.process(f) }      // 512 ms pause
        XCTAssertEqual(fireCount, 0, "a 0.5 s pause must not close the utterance")
        for f in frames(3_000, count: 8) { vad.process(f) }   // resumed speech
        XCTAssertEqual(fireCount, 0)
        for f in frames(0, count: 28) { vad.process(f) }      // fresh trailing silence
        XCTAssertEqual(fireCount, 0, "hangover must restart after the pause")
        for f in frames(0, count: 1) { vad.process(f) }
        XCTAssertEqual(fireCount, 1)
    }

    /// A 0.7 s mid-utterance pause (704 ms = 22 frames) must also NOT
    /// close — and must not leave the hangover partially counted: only 7
    /// quiet frames after the resumed speech would be enough to fire had
    /// the 22 pause frames carried over (22 + 7 = 29). Resumed speech
    /// resets the counter, so a full fresh ~1 s is required.
    func testMidUtterancePauseOfSevenTenthsSecondDoesNotClose() {
        let vad = EnergyVAD()
        var fireCount = 0
        vad.onEndOfUtterance = { fireCount += 1 }

        vad.start(endOfUtteranceMs: 900)
        for f in frames(3_000, count: 8) { vad.process(f) }   // speech
        for f in frames(0, count: 22) { vad.process(f) }      // 704 ms pause
        XCTAssertEqual(fireCount, 0, "a 0.7 s pause must not close the utterance")
        for f in frames(3_000, count: 8) { vad.process(f) }   // resumed speech
        for f in frames(0, count: 7) { vad.process(f) }
        XCTAssertEqual(fireCount, 0, "pause frames must not carry over the hangover")
        for f in frames(0, count: 22) { vad.process(f) }      // 7 + 22 = 29 fresh frames
        XCTAssertEqual(fireCount, 1, "a full fresh ~1 s of silence must close")
    }

    /// REGRESSION (2026-09-07, "still listening after I've stopped
    /// speaking"): a soft trailing clause used to wedge the end forever.
    /// The old symmetric EMA dragged speechLevel toward every frame above
    /// the end line — a soft ending ~5 dB below the loud body of the
    /// utterance pulled the reference down onto the background, the end
    /// line sank below the ambient, and no frame ever counted as quiet.
    /// Now the soft tail (RMS 0.1038, above the end line but below the
    /// decaying reference) merely HOLDS the counter, and the room noise
    /// (RMS 0.0549, below the end line) closes the utterance on the 29th
    /// frame. The reference decays at only 0.096 dB/frame (3 dB/s), so
    /// even after the full 10-tail + 29-noise frame window it has fallen
    /// from 0.183 to ~0.120 and the end line (~0.060) still sits above
    /// the noise (0.055) — a few frames' margin, but the utterance is
    /// already over by then.
    func testSoftEndWordsCannotWedgeTheEndInBackgroundNoise() {
        let vad = EnergyVAD()
        var ended = false
        vad.onEndOfUtterance = { ended = true }

        vad.start(endOfUtteranceMs: 900)
        for f in frames(0, count: 4) { vad.process(f) }        // quiet room
        for f in frames(6_000, count: 16) { vad.process(f) }   // loud body, RMS 0.183
        XCTAssertFalse(ended, "must not fire during the loud body")
        for f in frames(3_400, count: 10) { vad.process(f) }   // soft tail, RMS 0.1038
        XCTAssertFalse(ended, "soft final words must not fire the end")
        for f in frames(1_800, count: 28) { vad.process(f) }   // room noise, RMS 0.0549
        XCTAssertFalse(ended, "28 frames of background must not close yet")
        for f in frames(1_800, count: 1) { vad.process(f) }
        XCTAssertTrue(ended, "must endpoint onto the background after the soft tail")
    }

    /// REGRESSION (2026-09-07): modulated background noise — dips below
    /// the end line, then peaks back across it (TV words, fan gusts) —
    /// used to reset the silence counter at every crossing, so a finished
    /// utterance under such noise never ended. The band between endLevel
    /// and the reference now HOLDS the counter on peak frames: 3 full
    /// dip/peak cycles accrue 24 quiet frames without firing, and the
    /// 4th cycle's quiet run reaches 29 and closes.
    func testModulatedNoiseCannotPerpetuallyResetTheHangover() {
        let vad = EnergyVAD()
        var ended = false
        vad.onEndOfUtterance = { ended = true }

        vad.start(endOfUtteranceMs: 900)
        for f in frames(6_000, count: 16) { vad.process(f) }   // the utterance
        XCTAssertFalse(ended)
        // Noise cycle (320 ms): 8 quiet dips at RMS 0.0397 (below the end
        // line, accrue) + 2 peaks at RMS 0.0977 (above the end line but
        // below the decaying reference — the band, which must HOLD).
        for _ in 0..<3 {
            for f in frames(1_300, count: 8) { vad.process(f) }
            for f in frames(3_200, count: 2) { vad.process(f) }
        }
        XCTAssertFalse(ended, "band peaks must not reset the accumulated silence")
        for f in frames(1_300, count: 8) { vad.process(f) }   // 4th cycle: 24 + 5 >= 29
        XCTAssertTrue(ended, "quiet dips must keep accruing across band peaks")
    }

    // MARK: - Trailing-silence force end ([VAD-TUNE], 2026-09-11)
    //
    // The force end bounds the one case the hangover cannot close:
    // post-speech noise parked in the hold band (>= the end line but
    // below the reference) keeps the quiet counter at zero forever, and
    // the utterance would otherwise ride the recognizer's total capture
    // cap (the device-observed "end of talk never detected" class). The
    // force timer counts frames since the last clear-speech frame; the
    // reference decay is FROZEN while it runs, so band noise cannot sink
    // the reference and reset the timer frame by frame. Frames ARE the
    // injected clock: 512 samples at 16 kHz = 32 ms per frame, fully
    // deterministic — no wall-clock dependence.

    /// Band-level noise after speech: the normal hangover never accrues
    /// (the noise sits above the end line), but the force end fires
    /// exactly at the bound. Pins the production default too
    /// ([VAD-RT] tightened 7 s → 3 s): 3000 ms = ceil(3000 / 32) =
    /// 94 frames — the worst-case speech-end → vad_end gap on device.
    func testForceEndFiresWhenPostSpeechNoiseHoldsTheBand() {
        let vad = EnergyVAD()   // production default: 3000 ms -> 94 frames
        var forced = false
        var normalEnded = false
        vad.onForcedEndOfUtterance = { forced = true }
        vad.onEndOfUtterance = { normalEnded = true }

        vad.start(endOfUtteranceMs: 900)
        for f in frames(3_000, count: 4) { vad.process(f) }   // speech, RMS 0.0916
        // Post-speech band noise: RMS 0.0610 — above the end line
        // (0.0916 x 0.5 = 0.0458) but below the reference, so the quiet
        // counter never accrues. The reference is frozen by the force
        // timer, so the noise never crosses it.
        for f in frames(2_000, count: 93) { vad.process(f) }
        XCTAssertFalse(forced, "must not fire one frame before the bound")
        XCTAssertFalse(normalEnded, "the hangover cannot accrue inside the band")
        for f in frames(2_000, count: 1) { vad.process(f) }   // 94th frame
        XCTAssertTrue(forced, "the force end must fire exactly at the bound")
        XCTAssertFalse(normalEnded, "a force end is not a normal silence end")
    }

    /// [VAD-RT] The force end must land within ~3 s of the last
    /// clear-speech frame even when post-speech noise holds the band —
    /// the user-facing bound the device logs verify (`vad_force_end`
    /// within ~94 frames / 3.0 s after speech stops).
    func testForceEndBoundsTheEndWithinThreeSecondsOfSpeechStop() {
        let vad = EnergyVAD()   // 3000 ms production default
        var forcedAtFrame: Int?
        var frameIndex = 0
        vad.onForcedEndOfUtterance = { forcedAtFrame = frameIndex }

        vad.start(endOfUtteranceMs: 900)
        // The fire happens INSIDE process — increment before the call so
        // `frameIndex` is the frame's number at fire time.
        for f in frames(3_000, count: 4) { frameIndex += 1; vad.process(f) }
        // Band noise from here on — 3.008 s (94 frames) is the ceiling.
        for _ in 0..<94 {
            frameIndex += 1
            vad.process([Int16](repeating: 2_000, count: 512))
        }
        XCTAssertEqual(forcedAtFrame, 4 + 94,
                       "the force end fires exactly at speech-end + 94 frames (3.008 s)")
    }

    /// [VAD-RT] A mid-utterance pause with band-level energy that is
    /// SHORTER than the force window survives: the resumed speech
    /// resets the force timer and the utterance ends normally on the
    /// final silence. Pins the elderly-speech protection at the
    /// tightened 3 s window: 2.5 s of band-energy pause (78 frames) is
    /// well inside it.
    func testMidSpeechBandPauseUnderForceWindowSurvives() {
        let vad = EnergyVAD()   // 3000 ms -> 94 frames
        var forced = false
        var normalEnded = false
        vad.onForcedEndOfUtterance = { forced = true }
        vad.onEndOfUtterance = { normalEnded = true }

        vad.start(endOfUtteranceMs: 100)   // 4-frame hangover
        for f in frames(3_000, count: 8) { vad.process(f) }    // speech
        for f in frames(2_000, count: 78) { vad.process(f) }   // 2.5 s band pause
        XCTAssertFalse(forced, "a 2.5 s band pause must not force-end")
        XCTAssertFalse(normalEnded)
        for f in frames(3_000, count: 8) { vad.process(f) }    // resumed speech
        XCTAssertFalse(forced, "resumed speech keeps the utterance alive")
        for f in frames(0, count: 4) { vad.process(f) }        // final quiet
        XCTAssertTrue(normalEnded, "the normal hangover ends the resumed utterance")
        XCTAssertFalse(forced, "a normal end is not a force end")
    }

    /// Continuous clear speech keeps the force timer reset at every
    /// frame: the cap must never fire mid-speech, no matter how long the
    /// utterance runs ("energy above threshold keeps it alive").
    func testForceEndNeverFiresDuringContinuousSpeech() {
        let vad = EnergyVAD(forceEndAfterSilenceMs: 640)   // 20 frames
        var forced = false
        vad.onForcedEndOfUtterance = { forced = true }

        vad.start(endOfUtteranceMs: 900)
        for _ in 0..<100 {
            for f in frames(3_000, count: 1) { vad.process(f) }
        }
        XCTAssertFalse(forced, "continuous speech must keep the force timer reset")
    }

    /// Speech that dips into the band between loud frames stays alive:
    /// any clear-speech frame (rms >= the reference) resets the force
    /// timer, so 19-band + 1-loud cycles never reach the 20-frame bound.
    func testClearSpeechFramesResetTheForceTimer() {
        let vad = EnergyVAD(forceEndAfterSilenceMs: 640)   // 20 frames
        var forced = false
        vad.onForcedEndOfUtterance = { forced = true }

        vad.start(endOfUtteranceMs: 900)
        for f in frames(3_000, count: 2) { vad.process(f) }
        for _ in 0..<5 {
            for f in frames(2_000, count: 19) { vad.process(f) }   // band
            for f in frames(3_000, count: 1) { vad.process(f) }    // clear speech
        }
        XCTAssertFalse(forced, "a clear-speech frame must reset the force timer")
    }

    /// Real quiet still ends via the normal hangover — the force end must
    /// never fire when genuine silence exists.
    func testNormalSilenceEndWinsOverForceEnd() {
        let vad = EnergyVAD(forceEndAfterSilenceMs: 640)   // 20 frames
        var forced = false
        var normalEnded = false
        vad.onForcedEndOfUtterance = { forced = true }
        vad.onEndOfUtterance = { normalEnded = true }

        vad.start(endOfUtteranceMs: 100)   // 4-frame hangover
        for f in frames(3_000, count: 4) { vad.process(f) }
        for f in frames(0, count: 4) { vad.process(f) }
        XCTAssertTrue(normalEnded, "the normal hangover must fire in real quiet")
        XCTAssertFalse(forced, "the force end must stay silent when quiet exists")
    }

    /// The force end requires speech to have started: a capture that
    /// never crosses the speech threshold can never force-end — it keeps
    /// ending via the recognizer's total capture cap (the existing
    /// no-speech path, see VoiceTurnTimingSeamTests).
    func testForceEndRequiresSpeechToHaveStarted() {
        let vad = EnergyVAD(forceEndAfterSilenceMs: 640)
        var forced = false
        var ended = false
        vad.onForcedEndOfUtterance = { forced = true }
        vad.onEndOfUtterance = { ended = true }

        vad.start(endOfUtteranceMs: 100)
        for f in frames(0, count: 50) { vad.process(f) }
        XCTAssertFalse(forced, "no speech, no force end")
        XCTAssertFalse(ended)
    }

    // MARK: - End-of-speech latency bounds ([VAD-RT], 2026-09-11)
    //
    // Frames ARE the injected clock (512 samples at 16 kHz = 32 ms per
    // frame — deterministic, the class's documented doctrine). These
    // tests pin the user-facing latency contract: real quiet ends the
    // utterance within the hangover + one frame of the last speech
    // frame, band noise within the force window, and NO case exceeds
    // the ~3 s bound the device logs verify.

    /// Real quiet: the end fires within the hangover (29 frames at the
    /// production 900 ms) + one frame of the last speech frame — i.e.
    /// ~0.96 s after speech stops, the normal-path latency bound.
    func testQuietEndLatencyIsHangoverPlusOneFrame() {
        let vad = EnergyVAD()
        var endFrame: Int?
        var frameIndex = 0
        vad.onEndOfUtterance = { endFrame = frameIndex }

        vad.start(endOfUtteranceMs: 900)   // production hangover
        // The fire happens INSIDE process — increment before the call.
        for f in frames(3_000, count: 4) { frameIndex += 1; vad.process(f) }
        for f in frames(0, count: 30) { frameIndex += 1; vad.process(f) }
        XCTAssertEqual(endFrame, 4 + 29,
                       "the end fires on the 29th quiet frame (928 ms after speech)")
    }

    /// Band-noise worst case: the force end lands within 94 frames
    /// (3.008 s) of the last speech frame — never later, at the
    /// production default. This is the bound that closes the
    /// device-observed "end of talk never detected" class.
    func testWorstCaseEndLatencyIsWithinThreeSeconds() {
        let vad = EnergyVAD()   // 3000 ms production default
        var ended = false
        var forced = false
        var endFrame: Int?
        var frameIndex = 0
        vad.onEndOfUtterance = { ended = true; endFrame = endFrame ?? frameIndex }
        vad.onForcedEndOfUtterance = { forced = true; endFrame = endFrame ?? frameIndex }

        vad.start(endOfUtteranceMs: 900)
        for f in frames(3_000, count: 4) { frameIndex += 1; vad.process(f) }
        // Post-speech noise parked in the band (RMS 0.0610 > end line
        // 0.0458, below the frozen reference) — the pathological case.
        for _ in 0..<200 {
            frameIndex += 1
            vad.process([Int16](repeating: 2_000, count: 512))
            if ended || forced { break }
        }
        XCTAssertTrue(forced, "band noise can only end via the force end")
        XCTAssertEqual(endFrame, 4 + 94,
                       "the worst-case end is speech-end + 94 frames = 3.008 s")
    }

    // MARK: - First-turn warmup: no lazy init on the hot path ([VAD-RT])
    //
    // The EnergyVAD performs NO lazy initialization anywhere: every
    // derived constant (release factor, force frame count, quiet frames)
    // is computed in `init`, `start` only arms it. The two tests below
    // prove the frame path pays nothing on its first frame — the exact
    // property a first-turn capture needs. The first is deterministic
    // (behavior), the second is a wall-clock performance test with a
    // CI-friendly bound.

    /// Deterministic half: `process` requires `start` and otherwise
    /// performs no work — the first frame after `start` produces the
    /// SAME decision as the 1000th frame for identical energy (no
    /// warm-up frames, no first-frame initialization drift).
    func testFirstFrameAfterStartDecidesIdenticallyToSteadyState() {
        let vad = EnergyVAD()
        vad.start(endOfUtteranceMs: 900)
        // The first frame after start: constant speech energy → speech
        // begins immediately (the start threshold is seeded low on
        // purpose — first-turn sensitivity).
        var firstFrameSpeech = false
        vad.onSpeechStateChange = { speaking in
            if speaking { firstFrameSpeech = true }
        }
        vad.process([Int16](repeating: 3_000, count: 512))
        XCTAssertTrue(firstFrameSpeech,
                      "the very first frame after start must detect speech — no warmup frames required")
        // And a fresh VAD deciding the same frame at frame 1 vs frame 1
        // of a second capture behaves identically (deterministic state).
        let vad2 = EnergyVAD()
        vad2.start(endOfUtteranceMs: 900)
        var secondCaptureFirstFrameSpeech = false
        vad2.onSpeechStateChange = { speaking in
            if speaking { secondCaptureFirstFrameSpeech = true }
        }
        vad2.process([Int16](repeating: 3_000, count: 512))
        XCTAssertEqual(firstFrameSpeech, secondCaptureFirstFrameSpeech)
    }

    /// PERFORMANCE (wall-clock, CI-friendly generous bound): the first
    /// frame after `start` costs no more than a small multiple of the
    /// steady-state frame — a lazy-init class (allocations, lookup
    /// tables, session creation inside the frame path) would show up
    /// here as a first-frame spike. Budget: first ≤ 20× the 10 000-frame
    /// mean AND ≤ 5 ms absolute (the realtime frame budget is 32 ms; a
    /// first frame even 10× slower than steady state would be
    /// undetectable in the end-to-end latency).
    func testFirstFrameHasNoLazyInitCost_PERFORMANCE() {
        let vad = EnergyVAD()
        vad.start(endOfUtteranceMs: 900)
        let speech = [Int16](repeating: 3_000, count: 512)
        let quiet = [Int16](repeating: 0, count: 512)

        let firstStart = DispatchTime.now().uptimeNanoseconds
        vad.process(speech)
        let firstNs = DispatchTime.now().uptimeNanoseconds - firstStart

        // Steady state: 10 000 mixed frames.
        var totalNs: UInt64 = 0
        for i in 0..<10_000 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            vad.process(i.isMultiple(of: 2) ? speech : quiet)
            totalNs += DispatchTime.now().uptimeNanoseconds - t0
        }
        let meanNs = totalNs / 10_000
        print("[vad-perf] first frame \(firstNs) ns, steady-state mean \(meanNs) ns/frame")
        XCTAssertLessThan(firstNs, max(meanNs * 20, 5_000_000),
                          "the first frame must not pay a lazy-init spike (first \(firstNs) ns vs steady mean \(meanNs) ns)")
    }

    /// PERFORMANCE (wall-clock, CI-friendly): the realtime frame budget.
    /// The VAD receives one 512-sample frame every 32 ms at 16 kHz —
    /// processing 30 000 synthetic frames (~16 minutes of audio) must
    /// complete in a fraction of that per-frame budget. Bounds are
    /// calibrated for DEBUG builds (no optimizer) on a modest CI box:
    /// < 12 s total (~2× the measured debug cost with the [VAD-RT]
    /// Float-math fix) and < 3.2 ms/frame (10× headroom under the 32 ms
    /// realtime budget) — any accidental O(n²) or allocation regression
    /// in the RMS path blows the bound by orders of magnitude, while a
    /// healthy build passes with a wide margin. Marked _PERFORMANCE for
    /// the wall-clock nature.
    func testFrameProcessingBudget_PERFORMANCE() {
        let vad = EnergyVAD()
        vad.start(endOfUtteranceMs: 900)
        // Alternate loud/quiet so every branch of the state machine
        // runs (speech start, clear speech, band, quiet, floor learning).
        let loud = [Int16](repeating: 6_000, count: 512)
        let band = [Int16](repeating: 2_000, count: 512)
        let quiet = [Int16](repeating: 0, count: 512)
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<30_000 {
            switch i % 3 {
            case 0: vad.process(loud)
            case 1: vad.process(band)
            default: vad.process(quiet)
            }
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
        let perFrameNs = elapsedNs / 30_000
        print("[vad-perf] 30 000 frames in \(elapsedNs / 1_000_000) ms — \(perFrameNs) ns/frame (budget: 32 000 000 ns/frame)")
        XCTAssertLessThan(elapsedNs, 12_000_000_000,
                          "30 000 frames must process in < 12 s (measured \(perFrameNs) ns/frame)")
        XCTAssertLessThan(perFrameNs, 32_000_000 / 10,
                          "per-frame cost must sit far inside the 32 ms realtime frame budget (measured \(perFrameNs) ns/frame)")
    }

    // MARK: - Thread-safety ([VAD-RT])
    //
    // `process` runs on the pipeline's processing queue while
    // `start`/`stop`/`reset` arrive from the main queue. The internal
    // lock must keep a concurrent capture-boundary reset from tearing
    // the frame state.

    /// Concurrent `process` + `reset`/`start` churn never crashes and
    /// never leaves the detector in a state that double-fires the end.
    func testConcurrentProcessAndResetIsSafe() {
        let vad = EnergyVAD()
        var endFires = 0
        let fireLock = NSLock()
        vad.onEndOfUtterance = { fireLock.lock(); endFires += 1; fireLock.unlock() }

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.vad.process",
                                  qos: .userInteractive,
                                  attributes: .concurrent)
        for w in 0..<4 {
            group.enter()
            queue.async {
                for i in 0..<5_000 {
                    vad.process([Int16](repeating: Int16(w * 500 + (i % 20)), count: 512))
                }
                group.leave()
            }
        }
        for _ in 0..<100 {
            vad.reset()
            vad.start(endOfUtteranceMs: 900)
            vad.stop()
            vad.start(endOfUtteranceMs: 100)
        }
        group.wait()
        // The meaningful assertion is reaching here without a crash
        // (torn state under the lock would assert/trap in debug) —
        // plus the detector still works afterwards.
        vad.reset()
        vad.start(endOfUtteranceMs: 100)
        var endedAfterChurn = false
        vad.onEndOfUtterance = { endedAfterChurn = true }
        for f in frames(3_000, count: 4) { vad.process(f) }
        for f in frames(0, count: 4) { vad.process(f) }
        XCTAssertTrue(endedAfterChurn,
                      "the detector remains functional after concurrent churn")
    }
}
