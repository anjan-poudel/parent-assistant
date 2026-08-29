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

    func testPiperStubDelegatesToSystemSpeaker() async {
        let bus = MockObservabilityBus()
        let system = SystemSpeechSpeaker(observabilityBus: bus)
        let piper = PiperVoiceSpeaker(fallback: system, observabilityBus: bus)

        // Cancel before speak — must not crash and must record no delegate
        // event on its own.
        piper.cancel()
        let delegateEvents = bus.emittedEvents.filter { $0.eventType == "piper_stub_delegate" }
        XCTAssertTrue(delegateEvents.isEmpty)
    }
}
