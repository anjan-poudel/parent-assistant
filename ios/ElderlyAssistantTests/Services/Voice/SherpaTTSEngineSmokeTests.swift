import XCTest
import CryptoKit
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

    func testChitwanVoiceSynthesizesAudibleWAV() throws {
        // Voice-personalisation P0 (slice B): the second Nepali voice,
        // bundled alongside google-medium (tools/fetch-tts-voices.sh).
        try assertVoiceSpeaks("ne_NP-chitwan-medium-int8",
                              text: "नमस्ते, तपाईंलाई कस्तो छ?")
    }

    func testGoogleMediumAlternateSpeakerProducesDifferentAudio() throws {
        // The 18-speaker claim (research §3.4, verified in the shipped
        // int8 export's onnx.json + its "sid" graph input): sid 5 must
        // yield DIFFERENT audio than sid 0. If the export ever collapses
        // speakers, this fails — the honest canary for the claim.
        guard let dir = Bundle.main.url(forResource: "ne_NP-google-medium-int8",
                                        withExtension: nil,
                                        subdirectory: "tts") else {
            throw XCTSkip("TTS voices not bundled — run tools/fetch-tts-voices.sh")
        }
        let engine = SherpaTTSEngine()
        let text = "नमस्ते, तपाईंलाई कस्तो छ?"
        let wav0 = try engine.synthesize(text, voiceDirectory: dir, speed: 1.0,
                                         speakerID: 0)
        defer { try? FileManager.default.removeItem(at: wav0) }
        let wav5 = try engine.synthesize(text, voiceDirectory: dir, speed: 1.0,
                                         speakerID: 5)
        defer { try? FileManager.default.removeItem(at: wav5) }

        let hash0 = SHA256.hash(data: try Data(contentsOf: wav0))
        let hash5 = SHA256.hash(data: try Data(contentsOf: wav5))
        XCTAssertNotEqual(hash0, hash5,
                          "google-medium sid 5 produced byte-identical audio to sid 0 — "
                          + "the export no longer preserves its 18 speakers")
    }
}
