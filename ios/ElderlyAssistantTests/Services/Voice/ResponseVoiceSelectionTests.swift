import XCTest
import AVFoundation
@testable import ElderlyAssistant

/// Voice-personalisation P0 (slice B): the persisted "which voice replies"
/// choice + the one-shot audition channel, and — through the REAL
/// `PiperVoiceSpeaker` — the routing/fallback chain a picked voice rides
/// on. Persistence and audition tests use their own UserDefaults suite;
/// the speaker-routing tests use `.standard` (the production store the
/// speaker reads) and clean both keys up around themselves.
final class ResponseVoiceSelectionTests: XCTestCase {

    /// Production storage keys — private in `ResponseVoiceSelection`;
    /// pinned here so the tests can simulate foreign/corrupt storage the
    /// app never writes (older-version data, bit rot). If the production
    /// keys ever change, THIS test must change with them.
    private let selectionKey = "ttsResponseVoiceSelection"
    private let auditionKey = "ttsVoiceAuditionRequest"
    private let preferenceByLanguageKey = "ttsVoicePreferenceByLanguage"

    // MARK: Fixtures

    private let google0 = ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: 0)
    private let google5 = ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: 5)
    private let chitwan = ResponseVoice(voiceID: ModelCatalog.piperNepaliChitwan, speakerID: 0)

    private var suiteName: String!
    private var suite: UserDefaults!
    private var tempRoot: URL!
    private var store: ModelStore!
    private var bus: MockObservabilityBus!
    private var engine: RecordingEngine!
    private var speaker: PiperVoiceSpeaker!

    override func setUpWithError() throws {
        suiteName = "ResponseVoiceSelectionTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        // Production store: never inherit a stray choice/audition from an
        // earlier test or an app run on this simulator.
        ResponseVoiceSelection.clear(defaults: .standard)
        ResponseVoiceSelection.clearAudition(defaults: .standard)
        ResponseVoiceSelection.clearRememberedVoices(defaults: .standard)

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-selection-tests-\(UUID().uuidString)")
        bus = MockObservabilityBus()
        store = try ModelStore(observabilityBus: bus, rootDirectoryOverride: tempRoot)
        engine = RecordingEngine()
        speaker = PiperVoiceSpeaker(
            fallback: SystemSpeechSpeaker(observabilityBus: bus),
            observabilityBus: bus,
            modelStore: store,
            engine: engine,
            bundle: Bundle(url: tempRoot)!
        )
    }

    override func tearDownWithError() throws {
        speaker.cancel()
        if let suiteName {
            suite.removePersistentDomain(forName: suiteName)
        }
        ResponseVoiceSelection.clear(defaults: .standard)
        ResponseVoiceSelection.clearAudition(defaults: .standard)
        ResponseVoiceSelection.clearRememberedVoices(defaults: .standard)
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

    private func emitted(_ type: String) -> ObservabilityEvent? {
        bus.emittedEvents.first { $0.eventType == type }
    }

    // MARK: - Persistence

    func testPersistedChoiceRoundTrips() {
        XCTAssertNil(ResponseVoiceSelection.persisted(defaults: suite),
                     "fresh storage: no choice — the locale default rules")
        XCTAssertTrue(ResponseVoiceSelection.apply(chitwan, defaults: suite))
        XCTAssertEqual(ResponseVoiceSelection.persisted(defaults: suite), chitwan)
        XCTAssertTrue(ResponseVoiceSelection.apply(google5, defaults: suite))
        XCTAssertEqual(ResponseVoiceSelection.persisted(defaults: suite), google5,
                       "a later confirmed choice replaces the earlier one")
        ResponseVoiceSelection.clear(defaults: suite)
        XCTAssertNil(ResponseVoiceSelection.persisted(defaults: suite))
    }

    func testExplicitDefaultChoiceIsTreatedAsDefault() {
        // Tapping "Use this voice" on today's voice stores it explicitly;
        // it must still read back as the default, never as a change.
        XCTAssertTrue(ResponseVoiceSelection.apply(google0, defaults: suite))
        XCTAssertTrue(ResponseVoiceSelection.isDefault(google0))
        XCTAssertEqual(ResponseVoiceSelection.persisted(defaults: suite), google0)
    }

    func testApplyRefusesVoiceOutsideTheCatalog() {
        let ghost = ResponseVoice(voiceID: ModelID("piper-ne-voice-that-never-existed"),
                                  speakerID: 0)
        XCTAssertFalse(ResponseVoiceSelection.apply(ghost, defaults: suite),
                       "a non-catalog voice must be refused, not stored")
        XCTAssertNil(ResponseVoiceSelection.persisted(defaults: suite),
                     "the refused apply must leave no choice behind")
    }

    func testApplyRefusesOutOfRangeSpeakers() {
        XCTAssertFalse(ResponseVoiceSelection.apply(
            ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: 18),
            defaults: suite),
            "google-medium has sids 0-17 — 18 is out of range")
        XCTAssertFalse(ResponseVoiceSelection.apply(
            ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: -1),
            defaults: suite))
        XCTAssertFalse(ResponseVoiceSelection.apply(
            ResponseVoice(voiceID: ModelCatalog.piperNepaliChitwan, speakerID: 1),
            defaults: suite),
            "chitwan is single-speaker — only sid 0 exists")
        XCTAssertNil(ResponseVoiceSelection.persisted(defaults: suite))
    }

    func testCorruptStoredChoiceReadsAsNone() {
        suite.set(Data("not-json-at-all".utf8), forKey: selectionKey)
        XCTAssertNil(ResponseVoiceSelection.persisted(defaults: suite),
                     "undecodable storage must read as NO choice, not crash")
    }

    func testStoredChoiceWithRetiredSpeakerReadsAsNone() {
        // Simulate storage written by an older app version whose speaker
        // range was larger: valid JSON, impossible speaker.
        let stale = ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: 99)
        suite.set(try! JSONEncoder().encode(stale), forKey: selectionKey)
        XCTAssertNil(ResponseVoiceSelection.persisted(defaults: suite),
                     "a stored choice that no longer fits the voice must be "
                     + "invalidated — fall back to the locale default, never "
                     + "route somewhere odd")
    }

    func testIsDefaultFacts() {
        XCTAssertTrue(ResponseVoiceSelection.isDefault(google0))
        XCTAssertFalse(ResponseVoiceSelection.isDefault(chitwan))
        XCTAssertFalse(ResponseVoiceSelection.isDefault(google5),
                       "a google-medium speaker change is a real choice too")
    }

    // MARK: - Per-language memory of explicit picks (fix 2)

    func testRememberedVoicesStartEmptyAndRecordPerLanguage() {
        XCTAssertEqual(ResponseVoiceSelection.rememberedVoices(defaults: suite), [:])
        XCTAssertTrue(ResponseVoiceSelection.remember(chitwan, for: "ne", defaults: suite))
        XCTAssertEqual(ResponseVoiceSelection.rememberedVoices(defaults: suite)["ne"],
                       chitwan)
        XCTAssertNil(ResponseVoiceSelection.rememberedVoices(defaults: suite)["en"],
                     "a pick in one language never leaks into another")
    }

    func testRememberedVoicesKeepTheWholeVoiceIncludingTheSpeaker() {
        XCTAssertTrue(ResponseVoiceSelection.remember(google5, for: "ne", defaults: suite))
        XCTAssertEqual(ResponseVoiceSelection.rememberedVoices(defaults: suite)["ne"],
                       google5,
                       "the speaker is part of the pick — a speaker 5 choice "
                       + "must not come back as speaker 0")
    }

    func testRememberedVoicesAreKeyedByLowercasedLanguage() {
        XCTAssertTrue(ResponseVoiceSelection.remember(chitwan, for: "NE", defaults: suite))
        XCTAssertEqual(ResponseVoiceSelection.rememberedVoices(defaults: suite)["ne"],
                       chitwan)
    }

    func testRememberRefusesVoicesOutsideTheCatalog() {
        let ghost = ResponseVoice(voiceID: ModelID("piper-ne-voice-that-never-existed"),
                                  speakerID: 0)
        XCTAssertFalse(ResponseVoiceSelection.remember(ghost, for: "ne", defaults: suite))
        XCTAssertEqual(ResponseVoiceSelection.rememberedVoices(defaults: suite), [:],
                       "a non-catalog pick must never enter the memory")
    }

    func testCorruptRememberedStorageReadsAsEmpty() {
        suite.set(Data("not-json-at-all".utf8), forKey: preferenceByLanguageKey)
        XCTAssertEqual(ResponseVoiceSelection.rememberedVoices(defaults: suite), [:],
                       "undecodable storage must read as NO memory, not crash")
    }

    /// The end-to-end shape of fix 2, against the REAL resolver + storage
    /// the coordinator drives: pick chitwan for ne → switch to en → switch
    /// back to ne → chitwan (not the ne default).
    func testLanguageRoundTripRestoresTheChitwanPick() throws {
        // 1. The user explicitly picks chitwan while running Nepali.
        XCTAssertTrue(ResponseVoiceSelection.apply(chitwan, defaults: suite))
        XCTAssertTrue(ResponseVoiceSelection.remember(chitwan, for: "ne", defaults: suite))

        // 2. ne → en: chitwan cannot speak English, and nothing is
        //    remembered for en — the en default answers.
        let toEnglish = LanguageModelResolver.resolvedVoicePreference(
            current: ResponseVoiceSelection.persisted(defaults: suite),
            language: "en",
            remembered: ResponseVoiceSelection.rememberedVoices(defaults: suite))
        XCTAssertEqual(toEnglish,
                       ResponseVoice(voiceID: ModelCatalog.piperEnglishUS, speakerID: 0))
        XCTAssertTrue(ResponseVoiceSelection.apply(try XCTUnwrap(toEnglish),
                                                   defaults: suite))

        // 3. en → ne: the remembered chitwan pick returns, NOT piperNepali.
        let backToNepali = LanguageModelResolver.resolvedVoicePreference(
            current: ResponseVoiceSelection.persisted(defaults: suite),
            language: "ne",
            remembered: ResponseVoiceSelection.rememberedVoices(defaults: suite))
        XCTAssertEqual(backToNepali, chitwan,
                       "the custom Nepali voice survives the en round trip")
    }

    func testFirstEverSwitchToEnglishUsesTheEnglishDefault() throws {
        // No pick has ever been made: the automatic switch is the first
        // voice write, and it must be the en default…
        let toEnglish = LanguageModelResolver.resolvedVoicePreference(
            current: ResponseVoice(voiceID: ModelCatalog.piperNepali, speakerID: 0),
            language: "en",
            remembered: ResponseVoiceSelection.rememberedVoices(defaults: suite))
        XCTAssertEqual(toEnglish,
                       ResponseVoice(voiceID: ModelCatalog.piperEnglishUS, speakerID: 0))

        // …and it must NOT be recorded as a user pick: the coordinator's
        // auto-switch writes `apply` only. If it remembered, the memory
        // would be overwritten by the very switch it exists to undo.
        XCTAssertTrue(ResponseVoiceSelection.apply(try XCTUnwrap(toEnglish),
                                                   defaults: suite))
        XCTAssertEqual(ResponseVoiceSelection.rememberedVoices(defaults: suite), [:],
                       "the automatic switch must leave no user-pick memory")
    }

    // MARK: - One-shot audition channel

    func testAuditionConsumesOnceForExactText() {
        ResponseVoiceSelection.requestAudition(of: chitwan, for: "नमस्ते",
                                               defaults: suite)
        XCTAssertEqual(ResponseVoiceSelection.consumeAudition(matchingText: "नमस्ते",
                                                              defaults: suite),
                       chitwan)
        XCTAssertNil(ResponseVoiceSelection.consumeAudition(matchingText: "नमस्ते",
                                                            defaults: suite),
                     "an audition request is ONE-SHOT — it must not linger "
                     + "for a later utterance of the same text")
    }

    func testAuditionWithDifferentTextIsDropped() {
        ResponseVoiceSelection.requestAudition(of: chitwan, for: "नमस्ते",
                                               defaults: suite)
        XCTAssertNil(ResponseVoiceSelection.consumeAudition(matchingText: "बिहानै",
                                                            defaults: suite),
                     "a request must only fire for its EXACT utterance")
        XCTAssertNil(ResponseVoiceSelection.consumeAudition(matchingText: "नमस्ते",
                                                            defaults: suite),
                     "a mismatched consume must clear the stale request, "
                     + "not keep it for later")
    }

    func testAuditionExpiresAfterTTL() {
        let old = Date().addingTimeInterval(-(ResponseVoiceSelection.auditionTTL + 1))
        ResponseVoiceSelection.requestAudition(of: chitwan, for: "नमस्ते",
                                               at: old, defaults: suite)
        XCTAssertNil(ResponseVoiceSelection.consumeAudition(matchingText: "नमस्ते",
                                                            defaults: suite),
                     "an expired request (preview never spoke) must be "
                     + "ignored and cleared — it can't change a much-later "
                     + "utterance")
    }

    func testLatestAuditionReplacesEarlierOne() {
        ResponseVoiceSelection.requestAudition(of: chitwan, for: "नमस्ते",
                                               defaults: suite)
        ResponseVoiceSelection.requestAudition(of: google5, for: "नमस्ते",
                                               defaults: suite)
        XCTAssertEqual(ResponseVoiceSelection.consumeAudition(matchingText: "नमस्ते",
                                                              defaults: suite),
                       google5,
                       "only the most recent preview request may win")
    }

    // MARK: - Speaker routing (real PiperVoiceSpeaker + fake engine)

    func testPersistedChitwanRoutesNepaliUtterances() async throws {
        try installFakeVoice(ModelCatalog.piperNepali)
        try installFakeVoice(ModelCatalog.piperNepaliChitwan)
        XCTAssertTrue(ResponseVoiceSelection.apply(chitwan, defaults: .standard))

        await speaker.speak("औषधि खानुहोस्", locale: Locale(identifier: "ne-NP"))

        XCTAssertEqual(engine.calls.count, 1)
        XCTAssertTrue(engine.calls[0].dir.path.contains("ne_NP-chitwan-medium-int8"))
        XCTAssertEqual(engine.calls[0].speakerID, 0)
        XCTAssertEqual(emitted("tts_voice_selected")?.metadata["state"],
                       "piper-ne-chitwan-medium-int8#0")
    }

    func testPersistedGoogleSpeaker5RoutesSid5() async throws {
        try installFakeVoice(ModelCatalog.piperNepali)
        XCTAssertTrue(ResponseVoiceSelection.apply(google5, defaults: .standard))

        await speaker.speak("नमस्ते", locale: Locale(identifier: "ne-NP"))

        XCTAssertEqual(engine.calls.count, 1)
        XCTAssertTrue(engine.calls[0].dir.path.contains("ne_NP-google-medium-int8"),
                      "google-medium's speakers share ONE voice directory")
        XCTAssertEqual(engine.calls[0].speakerID, 5,
                       "the sid tensor must carry the chosen speaker")
        XCTAssertEqual(emitted("tts_voice_selected")?.metadata["state"],
                       "piper-ne-female-v1#5")
    }

    func testPersistedVoiceMissingFallsBackExactlyAsBefore() async throws {
        // Chitwan is chosen but NOT installed (voice files absent in this
        // build). The chain must behave exactly like the pre-picker
        // missing-voice path: no engine call, Nepali silence fallback.
        try installFakeVoice(ModelCatalog.piperNepali)
        XCTAssertTrue(ResponseVoiceSelection.apply(chitwan, defaults: .standard))

        await speaker.speak("नमस्ते", locale: Locale(identifier: "ne-NP"))

        XCTAssertTrue(engine.calls.isEmpty,
                      "engine must not run without the voice installed")
        XCTAssertNotNil(emitted("tts_voice_selected"))
        XCTAssertNotNil(emitted("tts_voice_missing_fallback"))
        XCTAssertNil(emitted("speak"),
                     "Nepali missing-voice fallback is SILENCE — never "
                     + "system-TTS gibberish")
    }

    func testAuditionRidesAnyUtteranceAndForcesNepaliLocale() async throws {
        // A preview in Settings speaks the Nepali sample even when the UI
        // language is English: request + speak the exact English text — the
        // speaker must use the auditioned voice and treat it as Nepali.
        try installFakeVoice(ModelCatalog.piperNepaliChitwan)
        ResponseVoiceSelection.requestAudition(of: chitwan, for: "Hello!",
                                               defaults: .standard)

        await speaker.speak("Hello!", locale: Locale(identifier: "en-US"))

        XCTAssertEqual(engine.calls.count, 1)
        XCTAssertTrue(engine.calls[0].dir.path.contains("ne_NP-chitwan-medium-int8"),
                      "the audition must ride this exact utterance")
        XCTAssertEqual(emitted("tts_voice_audition")?.metadata["state"],
                       "piper-ne-chitwan-medium-int8#0")
    }

    func testAuditionNeverLeaksIntoOtherUtterances() async throws {
        try installFakeVoice(ModelCatalog.piperNepali)
        ResponseVoiceSelection.requestAudition(of: chitwan, for: "नमस्ते",
                                               defaults: .standard)

        await speaker.speak("औषधि खानुहोस्", locale: Locale(identifier: "ne-NP"))

        XCTAssertEqual(engine.calls.count, 1)
        XCTAssertTrue(engine.calls[0].dir.path.contains("ne_NP-google-medium-int8"))
        XCTAssertEqual(engine.calls[0].speakerID, 0)
        XCTAssertNil(emitted("tts_voice_audition"),
                     "a different utterance must not pick the preview voice up")
        XCTAssertNil(emitted("tts_voice_selected"),
                     "default routing must not emit a selection event")
    }

    func testAuditionIsOneShotAtTheSpeaker() async throws {
        try installFakeVoice(ModelCatalog.piperNepali)
        try installFakeVoice(ModelCatalog.piperNepaliChitwan)
        ResponseVoiceSelection.requestAudition(of: chitwan, for: "नमस्ते",
                                               defaults: .standard)

        await speaker.speak("नमस्ते", locale: Locale(identifier: "ne-NP"))
        await speaker.speak("नमस्ते", locale: Locale(identifier: "ne-NP"))

        XCTAssertEqual(engine.calls.count, 2)
        XCTAssertTrue(engine.calls[0].dir.path.contains("chitwan"),
                      "first utterance previews the auditioned voice")
        XCTAssertTrue(engine.calls[1].dir.path.contains("google"),
                      "the SAME text a second later must be back on the live "
                      + "voice — the request is consumed once")
    }
}

/// Instant fake synthesis engine (mirrors PiperVoiceSpeakerTests'): records
/// every call, returns a tiny valid WAV so playback settles quickly.
final class RecordingEngine: TTSEngine {
    var calls: [(text: String, dir: URL, speed: Float, speakerID: Int)] = []

    func synthesize(_ text: String, voiceDirectory dir: URL, speed: Float,
                    speakerID: Int = 0) throws -> URL {
        calls.append((text, dir, speed, speakerID))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recording-tts-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 22_050, channels: 1,
                                   interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_205)!
        buf.frameLength = 2_205
        try file.write(from: buf)
        return url
    }
    func cancelSynthesis() {}
}
