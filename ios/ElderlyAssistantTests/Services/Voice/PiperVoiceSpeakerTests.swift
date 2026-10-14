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

    // MARK: - [MIC-CONTINUITY-REGRESSION] playback seam balance

    /// A successful reply playback opens the voice-reply seam EXACTLY
    /// once and closes it EXACTLY once. This is the regression pin for
    /// the cut-transcript saga: the seam contract changed twice on
    /// 2026-10-14 (loud category switch → removed entirely → mode-only
    /// switch), and each un-pinned change broke either the gap or the
    /// loudness. Balance here + mode-only pin in AudioSessionPresetTests
    /// + seam-free pin in AckFastLaneTests = the whole chain is pinned.
    func testSuccessfulPlaybackBalancesTheSeamExactlyOnce() async throws {
        try installFakeVoice(ModelCatalog.piperNepali)

        let savedBegin = ResponsePlaybackModeSeam.begin
        let savedEnd = ResponsePlaybackModeSeam.end
        var begins = 0
        var ends = 0
        ResponsePlaybackModeSeam.begin = { begins += 1 }
        ResponsePlaybackModeSeam.end = { ends += 1 }
        defer {
            ResponsePlaybackModeSeam.begin = savedBegin
            ResponsePlaybackModeSeam.end = savedEnd
        }

        await speaker.speak("औषधि खानुहोस्", locale: Locale(identifier: "ne-NP"))

        XCTAssertEqual(begins, 1, "one playback = exactly one seam begin")
        XCTAssertEqual(ends, 1, "one playback = exactly one seam end — the "
                       + "session is never left in the playback mode")
    }

    // MARK: - [AUDIT-SPOKEN] speaker-boundary normalization seam

    /// The shared normalization pass runs INSIDE speak() — the one stop
    /// every spoken producer funnels through. A raw composition (dose
    /// unit, percent, prose dash) reaches the engine as spoken words
    /// without any producer changing: this is the seam contract.
    func testSpeakNormalizesSpokenTextAtTheSeam() async throws {
        try installFakeVoice(ModelCatalog.piperNepali)

        await speaker.speak("औषधि Amlodipine 500 mg — 50% छ।",
                            locale: Locale(identifier: "ne-NP"))

        XCTAssertEqual(engine.calls.count, 1)
        XCTAssertEqual(engine.calls[0].text,
                       "औषधि Amlodipine ५०० मिलीग्राम, ५० प्रतिशत छ।")
        XCTAssertTrue(bus.emittedEvents.map(\.eventType).contains("speak"),
                      "normalization must not disturb voice resolution")
    }

    /// The English path: the reported "15c" field case plus percent and
    /// hostname, normalized in one pass at the seam.
    func testSeamNormalizesEnglishMechanicals() async throws {
        try installFakeVoice(ModelCatalog.piperEnglishUS)

        await speaker.speak("It's 15c and 50% off at bbc.com.",
                            locale: Locale(identifier: "en-US"))

        XCTAssertEqual(engine.calls.count, 1)
        XCTAssertEqual(engine.calls[0].text,
                       "It's 15 degrees Celsius and 50 percent off at bbc.")
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
        // [COLD-AUDITION WARM-UP] The one-shot voice audition runs inside
        // the first speak of a process (persisted afterwards): on a cold
        // first run it outlasts the 1.5 s settle deadline below even
        // though the cancel itself settles promptly — the full-gate run
        // and a 5-iteration isolation run both failed ONLY the cold
        // iteration (~3.0 s) and passed every warm one (~0.4 s). A
        // throwaway warm-up utterance mirrors production (the first
        // reply warms the speaker), so the measurement pins the cancel
        // property, not the audition.
        engine.secondsOfAudio = 0
        await speaker.speak("warm", locale: Locale(identifier: "en-US"))
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

    // MARK: - [PIPELINE-TRACE] the tts hand-off row
    //
    // The trace's last stage: the reply handed to the speaker in, the
    // branch the speaker took out. The stage's duration is the ramp to
    // audio START (the playback itself is the tracer's `speak_finished`
    // span), so a cancelled utterance that never began audio leaves the
    // span unfinished — and the row then reads `off(not_spoken)` rather
    // than claiming a start that never happened.

    private func makeTracedSpeaker(_ recorder: PipelineTraceRecorder) -> PiperVoiceSpeaker {
        PiperVoiceSpeaker(
            fallback: SystemSpeechSpeaker(observabilityBus: bus),
            observabilityBus: bus,
            modelStore: store,
            engine: engine,
            bundle: Bundle(url: tempRoot)!,   // empty bundle → no bundled voices
            traceRecorder: recorder)
    }

    func testTtsRowRecordsTheUtteranceAndAudioStarted() async throws {
        try installFakeVoice(ModelCatalog.piperNepali)
        let recorder = PipelineTraceRecorder()
        let traced = makeTracedSpeaker(recorder)

        recorder.beginTurn()
        await traced.speak("औषधि खानुहोस्", locale: Locale(identifier: "ne-NP"))
        let trace = recorder.finishTurn()

        XCTAssertEqual(trace.rows.map(\.stage), PipelineTraceStage.allCases,
                       "the tts row is one of the full trace's stages")
        let tts = try XCTUnwrap(trace.rows.first { $0.stage == .tts })
        XCTAssertTrue(tts.ran)
        XCTAssertEqual(tts.decision, "spoken")
        XCTAssertEqual(tts.inputSummary, "औषधि खानुहोस्",
                       "what was handed to the speaker, on the card's line")
        XCTAssertGreaterThanOrEqual(tts.durationMs, 0)
        XCTAssertEqual(trace.ranCount, 1,
                       "the speaker was this fixture's only traced stage")
    }

    func testTtsRowRecordsTheFallbackBranchWhenTheVoiceIsMissing() async {
        let recorder = PipelineTraceRecorder()
        let traced = makeTracedSpeaker(recorder)

        recorder.beginTurn()
        await traced.speak("नमस्ते", locale: Locale(identifier: "ne-NP"))

        let tts = recorder.finishTurn().rows.first { $0.stage == .tts }
        XCTAssertEqual(tts?.ran, true)
        XCTAssertEqual(tts?.decision, "fallback",
                       "the branch taken is the row's decision — never a silent fallthrough")
        XCTAssertTrue(tts?.outputSummary.contains("voice missing") == true)
    }

    func testTtsRowRecordsASynthesisFailure() async throws {
        try installFakeVoice(ModelCatalog.piperNepali)
        engine.fail = true
        let recorder = PipelineTraceRecorder()
        let traced = makeTracedSpeaker(recorder)

        recorder.beginTurn()
        await traced.speak("नमस्ते", locale: Locale(identifier: "ne-NP"))

        let tts = recorder.finishTurn().rows.first { $0.stage == .tts }
        XCTAssertEqual(tts?.ran, true,
                       "the stage DID run — it failed, and says so")
        XCTAssertEqual(tts?.decision, "failed")
    }
}
