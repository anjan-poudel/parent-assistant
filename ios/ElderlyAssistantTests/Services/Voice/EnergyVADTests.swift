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
}
