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
}
