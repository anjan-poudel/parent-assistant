import XCTest
@testable import ElderlyAssistant

final class EnergyVADTests: XCTestCase {

    func testEndOfUtteranceFiresAfterSpeechThenSilence() {
        let vad = EnergyVAD(speechRMSThreshold: 0.01, silenceRMSThreshold: 0.005)
        let ended = expectation(description: "end of utterance")
        vad.onEndOfUtterance = { ended.fulfill() }

        vad.start(endOfUtteranceMs: 100)
        vad.process(Array(repeating: Int16(3_000), count: vad.frameLength))

        for _ in 0..<5 {
            vad.process(Array(repeating: Int16(0), count: vad.frameLength))
        }

        wait(for: [ended], timeout: 1.0)
    }

    func testSilenceAloneDoesNotEndUtterance() {
        let vad = EnergyVAD(speechRMSThreshold: 0.01, silenceRMSThreshold: 0.005)
        let ended = expectation(description: "end of utterance should not fire")
        ended.isInverted = true
        vad.onEndOfUtterance = { ended.fulfill() }

        vad.start(endOfUtteranceMs: 100)
        for _ in 0..<5 {
            vad.process(Array(repeating: Int16(0), count: vad.frameLength))
        }

        wait(for: [ended], timeout: 0.2)
    }
}
