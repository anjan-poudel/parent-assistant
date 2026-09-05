import XCTest
@testable import ElderlyAssistant

/// End-to-end proof that the bundled sherpa voices actually speak: loads
/// the real int8 VITS model through the real engine, synthesizes Nepali
/// and English text, asserts audible WAV output. Skips cleanly on fresh
/// clones where tools/fetch-tts-voices.sh hasn't been run.
final class SherpaTTSEngineSmokeTests: XCTestCase {

    private func assertVoiceSpeaks(_ resource: String, text: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        guard let dir = Bundle.main.url(forResource: resource,
                                        withExtension: nil,
                                        subdirectory: "tts") else {
            throw XCTSkip("TTS voices not bundled — run tools/fetch-tts-voices.sh")
        }
        let engine = SherpaTTSEngine()
        let wav = try engine.synthesize(text, voiceDirectory: dir, speed: 1.0)
        defer { try? FileManager.default.removeItem(at: wav) }

        let attrs = try FileManager.default.attributesOfItem(atPath: wav.path)
        let size = (attrs[.size] as? Int) ?? 0
        // ≥ ~0.5 s of 16-bit mono @ 22.05 kHz past the 44-byte header.
        XCTAssertGreaterThan(size, 44 + 22_050,
                             "synthesis produced too little audio — \(size) bytes",
                             file: file, line: line)
    }

    func testNepaliVoiceSynthesizesAudibleWAV() throws {
        try assertVoiceSpeaks("ne_NP-google-medium-int8",
                              text: "नमस्ते, तपाईंलाई कस्तो छ?")
    }

    func testEnglishVoiceSynthesizesAudibleWAV() throws {
        try assertVoiceSpeaks("en_US-lessac-medium-int8",
                              text: "Good morning, it is time for your medicine.")
    }
}
