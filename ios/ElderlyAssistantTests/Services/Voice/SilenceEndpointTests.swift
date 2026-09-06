import XCTest
@testable import ElderlyAssistant

/// Pure tests for the voice-activity endpoint used by the Phone leaf's
/// one-shot mic capture (voice-contact-search, 2026-09-07). The capture
/// feeds per-buffer RMS; these tests pin down the boundary semantics so
/// a name spoken into the mic is never cut off by a cough or a pause.
final class SilenceEndpointTests: XCTestCase {

    /// Same profile `SearchPhraseCapture` constructs for a live capture.
    private func makeEndpoint() -> SilenceEndpoint {
        SilenceEndpoint(speechThreshold: 0.012,
                        minSpeechSeconds: 0.3,
                        trailingSilenceSeconds: 1.0,
                        maxSilenceBeforeSpeechSeconds: 3.0)
    }

    private static let loud: Float = 0.1    // well above threshold
    private static let quiet: Float = 0.001 // well below threshold

    func testPureSilenceEventuallyGivesUp() {
        var endpoint = makeEndpoint()
        // Quiet accrues per feed and the give-up window (3.0s) is
        // inclusive: the 6th 0.5s feed lands exactly on the boundary,
        // so feeds 1-5 stay listening and feed 6 aborts.
        for _ in 0..<5 {
            XCTAssertEqual(endpoint.feed(rms: Self.quiet, duration: 0.5),
                           .keepListening)
        }
        XCTAssertEqual(endpoint.feed(rms: Self.quiet, duration: 0.5),
                       .gaveUpWaitingForSpeech)
    }

    func testSpeechThenTrailingSilenceEndsUtterance() {
        var endpoint = makeEndpoint()
        // 0.4s of speech crosses minSpeechSeconds…
        XCTAssertEqual(endpoint.feed(rms: Self.loud, duration: 0.4), .keepListening)
        // …then 1.0s of quiet ends the utterance (0.5 + 0.5).
        XCTAssertEqual(endpoint.feed(rms: Self.quiet, duration: 0.5), .keepListening)
        XCTAssertEqual(endpoint.feed(rms: Self.quiet, duration: 0.5), .endUtterance)
    }

    func testShortBlipDoesNotEndUtterance() {
        var endpoint = makeEndpoint()
        // A cough or false trigger: 0.1s of sound is below the 0.3s
        // speech floor, so trailing silence must NOT finalize.
        XCTAssertEqual(endpoint.feed(rms: Self.loud, duration: 0.1), .keepListening)
        XCTAssertEqual(endpoint.feed(rms: Self.quiet, duration: 1.0), .keepListening)
        XCTAssertEqual(endpoint.feed(rms: Self.quiet, duration: 1.0), .keepListening)
        // Even 2.0s of quiet is not an end without real speech.
        XCTAssertEqual(endpoint.feed(rms: Self.quiet, duration: 0.9), .keepListening)
        // Only the no-speech give-up window (3.0s total quiet) aborts.
        XCTAssertEqual(endpoint.feed(rms: Self.quiet, duration: 0.1),
                       .gaveUpWaitingForSpeech)
    }

    func testSpeakingKeepsListening() {
        var endpoint = makeEndpoint()
        for _ in 0..<10 {
            XCTAssertEqual(endpoint.feed(rms: Self.loud, duration: 0.5),
                           .keepListening)
        }
    }

    func testResumedSpeechAfterPauseDoesNotPrematurelyEnd() {
        var endpoint = makeEndpoint()
        // Real speech crosses the floor…
        XCTAssertEqual(endpoint.feed(rms: Self.loud, duration: 0.5), .keepListening)
        // …a 0.9s pause is below the 1.0s trailing window…
        XCTAssertEqual(endpoint.feed(rms: Self.quiet, duration: 0.9), .keepListening)
        // …and resumed speech RESETS the quiet counter: had the 0.9s
        // pause kept counting, a further 0.9s of quiet would already
        // exceed the trailing window and end the capture mid-name.
        XCTAssertEqual(endpoint.feed(rms: Self.loud, duration: 0.1), .keepListening)
        XCTAssertEqual(endpoint.feed(rms: Self.quiet, duration: 0.9), .keepListening)
        // Only a full 1.0s of fresh trailing quiet ends the utterance.
        XCTAssertEqual(endpoint.feed(rms: Self.quiet, duration: 0.1), .endUtterance)
    }

    func testThresholdBoundaryIsInclusive() {
        var endpoint = makeEndpoint()
        // RMS exactly at the threshold counts as speech (>=).
        XCTAssertEqual(endpoint.feed(rms: 0.012, duration: 0.5), .keepListening)
        XCTAssertEqual(endpoint.feed(rms: Self.quiet, duration: 0.5), .keepListening)
        XCTAssertEqual(endpoint.feed(rms: Self.quiet, duration: 0.5), .endUtterance)
    }
}
