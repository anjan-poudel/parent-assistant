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
}
