import XCTest
import AVFoundation
@testable import ElderlyAssistant

final class PiperVoiceSpeakerTests: XCTestCase {

    /// Fake synthesis engine: instant, returns a tiny valid WAV, records
    /// every call. Lets the speaker tests run without sherpa-onnx or the
    /// ~40 MB voice dirs.
    final class FakeTTSEngine: TTSEngine {
        var calls: [(text: String, dir: URL, speed: Float, speakerID: Int)] = []
        var fail = false
        var secondsOfAudio: AVAudioFrameCount = 2_205   // 0.1 s @ 22.05 kHz
        var warmCalls: [URL] = []
        var warmError: Error?

        func synthesize(_ text: String, voiceDirectory dir: URL, speed: Float,
                        speakerID: Int = 0) throws -> URL {
            calls.append((text, dir, speed, speakerID))
            if fail { throw TTSEngineError.synthesisFailed }
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("fake-tts-\(UUID().uuidString).wav")
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 22_050, channels: 1,
                                       interleaved: false)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: secondsOfAudio)!
            buf.frameLength = secondsOfAudio
            try file.write(from: buf)
            return url
        }
        func cancelSynthesis() {}
        func warm(voiceDirectory: URL) throws {
            warmCalls.append(voiceDirectory)
            if let warmError { throw warmError }
        }
    }

    private var tempRoot: URL!
    private var store: ModelStore!
    private var bus: MockObservabilityBus!
    private var engine: FakeTTSEngine!
    private var speaker: PiperVoiceSpeaker!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-tests-\(UUID().uuidString)")
        bus = MockObservabilityBus()
        store = try ModelStore(observabilityBus: bus, rootDirectoryOverride: tempRoot)
        engine = FakeTTSEngine()
        let system = SystemSpeechSpeaker(observabilityBus: bus)
        speaker = PiperVoiceSpeaker(
            fallback: system,
            observabilityBus: bus,
            modelStore: store,
            engine: engine,
            bundle: Bundle(url: tempRoot)!   // empty bundle → no bundled voices
        )
    }

    override func tearDownWithError() throws {
        speaker.cancel()
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Creates root/tts/<voice filename>/ so ttsVoiceDirectory finds it.
    private func installFakeVoice(_ id: ModelID) throws {
        let entry = ModelCatalog.entry(for: id)!
        let dir = tempRoot
            .appendingPathComponent("tts", isDirectory: true)
            .appendingPathComponent(entry.filename, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Voice routing

    func testVoiceRoutingByLocale() {
        XCTAssertEqual(PiperVoiceSpeaker.voiceID(for: Locale(identifier: "ne-NP")),
                       ModelCatalog.piperNepali)
        XCTAssertEqual(PiperVoiceSpeaker.voiceID(for: Locale(identifier: "ne")),
                       ModelCatalog.piperNepali)
        XCTAssertEqual(PiperVoiceSpeaker.voiceID(for: Locale(identifier: "en-US")),
                       ModelCatalog.piperEnglishUS)
        // Anything else falls to the English voice (no other voices ship).
        XCTAssertEqual(PiperVoiceSpeaker.voiceID(for: Locale(identifier: "hi-IN")),
                       ModelCatalog.piperEnglishUS)
    }

    // MARK: - Fallback behavior

    func testMissingNepaliVoiceFallsBackToSilenceNotGibberish() async {
        await speaker.speak("नमस्ते", locale: Locale(identifier: "ne-NP"))

        XCTAssertTrue(engine.calls.isEmpty, "engine must not run without an installed voice")
        let events = bus.emittedEvents.map(\.eventType)
        XCTAssertTrue(events.contains("tts_voice_missing_fallback"))
        // Master's NullSpeaker rule: iOS has no Nepali system voice, so a
        // system-TTS fallback would read Devanagari as gibberish — the
        // fallback for Nepali is SILENCE (replies stay on the card).
        XCTAssertFalse(events.contains("speak"),
                       "Nepali must never fall back to system TTS (gibberish)")
    }

    func testMissingEnglishVoiceFallsBackToSystemSpeech() async {
        await speaker.speak("hello", locale: Locale(identifier: "en-US"))

        XCTAssertTrue(engine.calls.isEmpty)
        let events = bus.emittedEvents.map(\.eventType)
        XCTAssertTrue(events.contains("tts_voice_missing_fallback"))
        XCTAssertTrue(events.contains("speak"),
                      "English system voice is good — fallback must speak")
    }

    func testFallsBackWhenSynthesisFails() async throws {
        try installFakeVoice(ModelCatalog.piperNepali)
        engine.fail = true

        await speaker.speak("नमस्ते", locale: Locale(identifier: "ne-NP"))

        XCTAssertEqual(engine.calls.count, 1)
        let events = bus.emittedEvents.map(\.eventType)
        XCTAssertTrue(events.contains("tts_synthesis_failed_fallback"))
        XCTAssertFalse(events.contains("speak"),
                       "Nepali engine failure falls back to silence, not system gibberish")
    }

    // MARK: - Happy path

    func testSynthesizesAndPlaysWithInstalledVoice() async throws {
        try installFakeVoice(ModelCatalog.piperNepali)

        await speaker.speak("औषधि खानुहोस्", locale: Locale(identifier: "ne-NP"))

        XCTAssertEqual(engine.calls.count, 1)
        let call = engine.calls[0]
        XCTAssertEqual(call.text, "औषधि खानुहोस्")
        XCTAssertTrue(call.dir.path.contains("ne_NP-google-medium-int8"))
        XCTAssertEqual(call.speed, PiperVoiceSpeaker.defaultSpeed,
                       "elderly-friendly pace must be applied")
        XCTAssertEqual(call.speakerID, 0,
                       "no voice selected — the default google-medium speaker 0 must be used")
        XCTAssertTrue(bus.emittedEvents.map(\.eventType).contains("speak"))
    }

    // MARK: - Warm-start seam (boot warm phase)

    func testWarmPreloadsInstalledVoice() throws {
        try installFakeVoice(ModelCatalog.piperNepali)

        var result: WarmStartEngineResult?
        speaker.warm(voiceID: ModelCatalog.piperNepali) { result = $0 }

        XCTAssertEqual(result, .ready)
        XCTAssertEqual(engine.warmCalls.count, 1)
        XCTAssertTrue(engine.warmCalls[0].path.contains("ne_NP-google-medium-int8"),
                      "the warm must construct the engine for the INSTALLED voice directory")
        XCTAssertTrue(engine.calls.isEmpty,
                      "warm must never synthesize audio")
    }

    func testWarmInstallsBundledVoiceLikeSpeakPath() throws {
        // An EMPTY bundle installs nothing — the bundled-install branch
        // of warm degrades exactly like speak's (voice_missing).
        var result: WarmStartEngineResult?
        speaker.warm(voiceID: ModelCatalog.piperEnglishUS) { result = $0 }

        XCTAssertEqual(result, .failed(reason: "voice_missing"))
        XCTAssertTrue(engine.warmCalls.isEmpty,
                      "the engine must not be constructed for a voice that cannot resolve")
    }

    func testWarmEngineFailureFailsHonestly() throws {
        try installFakeVoice(ModelCatalog.piperNepali)
        engine.warmError = TTSEngineError.engineInitFailed(URL(fileURLWithPath: "/fake"))

        var result: WarmStartEngineResult?
        speaker.warm(voiceID: ModelCatalog.piperNepali) { result = $0 }

        XCTAssertEqual(result, .failed(reason: "engine_init_failed"))
        XCTAssertEqual(engine.warmCalls.count, 1)
    }

    // MARK: - Cancel

    func testCancelDuringPlaybackSettlesPromptly() async throws {
        try installFakeVoice(ModelCatalog.piperEnglishUS)
        engine.secondsOfAudio = 44_100   // 2 s of audio — long enough to cancel into

        let started = Date()
        let speakTask = Task { await self.speaker.speak("hello there", locale: Locale(identifier: "en-US")) }
        try await Task.sleep(nanoseconds: 300_000_000)
        speaker.cancel()
        await speakTask.value

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5,
                          "cancel must settle the speak await, not wait for full playback")
    }

    func testCancelWhenIdleIsHarmless() {
        speaker.cancel()
        XCTAssertTrue(bus.emittedEvents.isEmpty)
    }
}
