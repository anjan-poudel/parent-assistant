import XCTest
import AVFoundation
import SwiftUI
@testable import ElderlyAssistant

/// [LAT-M2] Seam tests for the ack fast lane: the file-backed
/// pre-synthesized ack cache, the warm-time builder, the router's
/// hit/miss wiring, and the production player's honest fallbacks.
/// No audio hardware, no sherpa-onnx — fake engines write real tiny
/// WAVs (the same pattern as PiperVoiceSpeakerTests).
final class AckFastLaneTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")
    private let en = Locale(identifier: "en")

    // MARK: - Fakes

    /// Instant synthesis engine: returns a tiny valid WAV, records every
    /// call. Per-text failure for partial-build tests.
    final class FakeTTSEngine: TTSEngine {
        var calls: [(text: String, dir: URL, speed: Float, speakerID: Int)] = []
        var failingTexts: Set<String> = []

        func synthesize(_ text: String, voiceDirectory dir: URL, speed: Float,
                        speakerID: Int = 0) throws -> URL {
            calls.append((text, dir, speed, speakerID))
            if failingTexts.contains(text) { throw TTSEngineError.synthesisFailed }
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ack-test-\(UUID().uuidString).wav")
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 22_050, channels: 1,
                                       interleaved: false)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buf = AVAudioPCMBuffer(pcmFormat: format,
                                       frameCapacity: 2_205)!   // 0.1 s
            buf.frameLength = 2_205
            try file.write(from: buf)
            return url
        }
        func cancelSynthesis() {}
        func warm(voiceDirectory: URL) throws {}
    }

    /// Records the fast-lane hand-off. `hit` controls the cache decision.
    private final class FakePreAckPlayer: PreAckPlaying {
        var onPlaybackFinished: (() -> Void)?
        var hit = true
        private(set) var playCalls: [(variant: Int, locale: Locale)] = []
        private(set) var cancelCalls = 0

        @discardableResult
        func playCachedAck(variant: Int, locale: Locale) -> Bool {
            playCalls.append((variant, locale))
            return hit
        }
        func cancel() { cancelCalls += 1 }
    }

    private final class FakeAckSpeaker: Speaker {
        private(set) var utterances: [(text: String, locale: Locale)] = []
        func speak(_ text: String, locale: Locale) async {
            utterances.append((text, locale))
        }
        func cancel() {}
    }

    private final class FakeAckCoordinator: VoiceCommandCoordinating {
        var isAwaitingConfirmation = false
        var brainReadiness = BrainReadiness.available
        var isAwaitingCallConfirmation = false
        var activeLocale: Locale { Locale(identifier: "ne-NP") }

        var assistantSpoken: [String] = []
        var speakingStarted = 0
        var speakingEnded = 0
        var timerStartOutcome: AlarmTimerSetOutcome = .scheduled

        func noteAssistantSpoke(_ text: String) { assistantSpoken.append(text) }
        func noteSpeakingStarted() { speakingStarted += 1 }
        func noteSpeakingEnded() { speakingEnded += 1 }
        func noteGenericReply(_ text: String) {}
        func requestTimerStart(durationSeconds: Int, label: String?) async -> AlarmTimerSetOutcome {
            timerStartOutcome
        }
        func requestAlarmSet(at time: Date, label: String?) async -> AlarmTimerSetOutcome { .failed }
        func recordTranscript(_ text: String) {}
        func oldestPendingReminderEntryId() -> UUID? { nil }
        func handleMedicationAcknowledgement(entryId: UUID) {}
        func startVoiceAckConfirmation(for entryId: UUID) -> String? { nil }
        func handleConfirmationResponse(_ response: ConfirmationResponse) {}
        func addVoiceReminder(title: String, time: DateComponents) {}
        var pendingRephraseCommand: InterpretedCommand? { nil }
        func requestCallConfirmation(contactQuery: String?, callType: String?, requestedApp: String?,
                                     sourceTranscript: String?, sourceCommand: InterpretedCommand?) -> String? { nil }
        func startRephraseConfirmation(_ command: InterpretedCommand, sourceTranscript: String?) {}
        func takePendingRephraseCommand() -> (command: InterpretedCommand, sourceTranscript: String?)? { nil }
        func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }
        func composeMessage(toContactNamed name: String?, body: String,
                            requestedApp: String?) -> MessageComposeOutcome { .contactNotFound }
        func presentPluginView(_ view: AnyView) {}
        func requestContactSearch(query: String?) {}
        func requestNavigation(to target: DirectionsRoute.PlaceTarget) {}
        func requestNavigationDisambiguation(targets: [DirectionsCandidate]) -> String? { nil }
        func fireMorningBriefing() {}
        func fireNewsReader() {}
    }

    private final class RecordingBus: ObservabilityBus {
        private(set) var events: [ObservabilityEvent] = []
        func emit(_ event: ObservabilityEvent) { events.append(event) }
    }

    // MARK: - Harness helpers

    private var tempRoot: URL!
    private var cache: AckAudioCache!
    private var savedSeamBegin: (() -> Void)?
    private var savedSeamEnd: (() -> Void)?

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ack-fast-lane-\(UUID().uuidString)")
        cache = AckAudioCache(root: tempRoot.appendingPathComponent("cache"))
        savedSeamBegin = ResponsePlaybackModeSeam.begin
        savedSeamEnd = ResponsePlaybackModeSeam.end
        ResponsePlaybackModeSeam.begin = {}
        ResponsePlaybackModeSeam.end = {}
    }

    override func tearDownWithError() throws {
        ResponsePlaybackModeSeam.begin = savedSeamBegin!
        ResponsePlaybackModeSeam.end = savedSeamEnd!
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeRouter(_ coordinator: FakeAckCoordinator,
                            player: PreAckPlaying?,
                            bus: RecordingBus = RecordingBus(),
                            tracer: VoiceTurnLatencyTracer? = nil)
        -> (CommandRouter, FakeAckSpeaker, RecordingBus) {
        let speaker = FakeAckSpeaker()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: speaker,
                                   interpreter: NullCommandInterpreter(),
                                   preAckPlayer: player,
                                   turnTracer: tracer)
        return (router, speaker, bus)
    }

    private func waitForAsyncSpeak() {
        let exp = expectation(description: "async speak settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 3.0)
    }

    private func ackVariant(_ n: Int, locale: Locale) -> String {
        L10n.str("voiceAck.moment\(n)", locale: locale)
    }

    private func writeTinyWAV(_ name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 22_050, channels: 1,
                                   interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_205)!
        buf.frameLength = 2_205
        try file.write(from: buf)
        return url
    }

    // MARK: - Cache store/lookup

    func testCacheHitOnlyAfterStore() throws {
        let spec = AckVoiceSpec.resolve(locale: ne)
        XCTAssertNil(cache.wavURL(variant: 1, spec: spec),
                     "an unbuilt slot reads as a miss")
        let wav = try writeTinyWAV("src.wav")
        try cache.store(wav: wav, variant: 1, spec: spec)
        XCTAssertNotNil(cache.wavURL(variant: 1, spec: spec))
        XCTAssertNil(cache.wavURL(variant: 2, spec: spec),
                     "sibling variants are independent slots")
    }

    func testCacheSlotsAreScopedByVoiceSpeakerAndLocale() throws {
        let neSpec = AckVoiceSpec.resolve(locale: ne)
        let enSpec = AckVoiceSpec.resolve(locale: en)
        let wav = try writeTinyWAV("src.wav")
        try cache.store(wav: wav, variant: 1, spec: neSpec)

        XCTAssertNotNil(cache.wavURL(variant: 1, spec: neSpec))
        XCTAssertNil(cache.wavURL(variant: 1, spec: enSpec),
                     "the English slot is never filled by a Nepali build")
        XCTAssertNil(cache.wavURL(
            variant: 1,
            spec: AckVoiceSpec(voiceID: neSpec.voiceID,
                               speakerID: neSpec.speakerID + 1,
                               locale: neSpec.locale)),
            "a different speaker id is a different slot")
    }

    func testRemoveDropsOneSpecOnly() throws {
        let neSpec = AckVoiceSpec.resolve(locale: ne)
        let enSpec = AckVoiceSpec.resolve(locale: en)
        let wav = try writeTinyWAV("src.wav")
        try cache.store(wav: wav, variant: 1, spec: neSpec)
        try cache.store(wav: wav, variant: 1, spec: enSpec)

        cache.remove(spec: neSpec)
        XCTAssertNil(cache.wavURL(variant: 1, spec: neSpec))
        XCTAssertNotNil(cache.wavURL(variant: 1, spec: enSpec),
                        "removal is per-spec, never whole-store")
    }

    // MARK: - Warm-time builder

    func testBuilderStoresAllThreeVariants() {
        let engine = FakeTTSEngine()
        let spec = AckVoiceSpec.resolve(locale: ne)
        let variants = (1...3).map {
            AckCacheBuilder.Variant(index: $0, text: ackVariant($0, locale: ne))
        }

        let result = AckCacheBuilder.build(engine: engine,
                                           voiceDirectory: tempRoot,
                                           speed: 0.95,
                                           variants: variants,
                                           spec: spec,
                                           cache: cache)

        XCTAssertEqual(result, .ready)
        XCTAssertEqual(engine.calls.map(\.text), variants.map(\.text),
                       "every variant is synthesized with its catalog text")
        for n in 1...3 {
            XCTAssertNotNil(cache.wavURL(variant: n, spec: spec),
                            "variant \(n) must be cached after the build")
        }
    }

    func testBuilderReportsPartialWhenOneVariantFails() {
        let engine = FakeTTSEngine()
        engine.failingTexts.insert(ackVariant(2, locale: ne))
        let spec = AckVoiceSpec.resolve(locale: ne)
        let variants = (1...3).map {
            AckCacheBuilder.Variant(index: $0, text: ackVariant($0, locale: ne))
        }

        let result = AckCacheBuilder.build(engine: engine,
                                           voiceDirectory: tempRoot,
                                           speed: 0.95,
                                           variants: variants,
                                           spec: spec,
                                           cache: cache)

        XCTAssertEqual(result, .partial(built: 2))
        XCTAssertNotNil(cache.wavURL(variant: 1, spec: spec))
        XCTAssertNotNil(cache.wavURL(variant: 3, spec: spec))
        XCTAssertNil(cache.wavURL(variant: 2, spec: spec),
                     "the failed variant stays a miss")
    }

    func testBuilderFailsHonestlyWhenNothingBuilds() {
        let engine = FakeTTSEngine()
        engine.failingTexts = Set((1...3).map { ackVariant($0, locale: ne) })
        let spec = AckVoiceSpec.resolve(locale: ne)
        let variants = (1...3).map {
            AckCacheBuilder.Variant(index: $0, text: ackVariant($0, locale: ne))
        }

        let result = AckCacheBuilder.build(engine: engine,
                                           voiceDirectory: tempRoot,
                                           speed: 0.95,
                                           variants: variants,
                                           spec: spec,
                                           cache: cache)

        XCTAssertEqual(result, .failed(reason: "synthesis_failed"))
        XCTAssertNil(cache.wavURL(variant: 1, spec: spec))
    }

    // MARK: - Router seam: cache hit

    func testFastLaneHitSkipsSynthesisAndKeepsNotes() {
        let coordinator = FakeAckCoordinator()
        let player = FakePreAckPlayer()
        let (router, speaker, bus) = makeRouter(coordinator, player: player)

        _ = router.route(transcript: "set a timer for 5 minutes")
        waitForAsyncSpeak()

        XCTAssertEqual(player.playCalls.map(\.variant), [1],
                       "the ack routes through the fast lane with its rotating variant")
        XCTAssertEqual(player.playCalls.map(\.locale), [ne])
        XCTAssertTrue(speaker.utterances.allSatisfy { $0.text != ackVariant(1, locale: ne) },
                      "a cache hit must not synthesize the ack (the confirmation may still synthesize)")
        XCTAssertEqual(coordinator.assistantSpoken.first, ackVariant(1, locale: ne),
                       "the conversation card still shows the ack text")
        XCTAssertEqual(coordinator.speakingStarted, 2,
                       "ack + confirmation each commit a speaking-state note — the fast lane drops nothing")
        XCTAssertFalse(bus.events.contains { $0.eventType == "ack_cache_miss" },
                       "a hit never logs a miss")
    }

    func testFastLaneAckBalancesSpeakBookkeeping() {
        let coordinator = FakeAckCoordinator()
        let player = FakePreAckPlayer()
        let bus = RecordingBus()
        let tracer = VoiceTurnLatencyTracer(observabilityBus: bus)
        let (router, _, _) = makeRouter(coordinator, player: player,
                                        bus: bus, tracer: tracer)
        tracer.onTurnFinalized = { _, _ in }
        tracer.beginTurn()

        _ = router.route(transcript: "set a timer for 5 minutes")
        XCTAssertEqual(coordinator.speakingStarted, 1)

        // The ack's playback settles (production: player delegate).
        player.onPlaybackFinished?()
        XCTAssertEqual(coordinator.speakingEnded, 1,
                       "the player's finished note closes the speaking state")
        waitForAsyncSpeak()
        tracer.endTurn()

        let timing = bus.events.first { $0.eventType == "voice_turn_timing" }
        XCTAssertNotNil(timing, "the turn finalizes with balanced speak notes")
        let stages = (try? JSONDecoder().decode(
            [VoiceTurnLatencyTracer.StageTiming].self,
            from: (timing?.metadata["stages"] ?? "[]").data(using: .utf8)!)) ?? []
        XCTAssertEqual(stages.filter { $0.stage == "speak_queued" }.count, 2,
                       "ack + confirmation each mark speak_queued")
        XCTAssertEqual(stages.filter { $0.stage == "speak_finished" }.count, 2,
                       "ack (player) + confirmation (lane) each mark speak_finished")
    }

    // MARK: - Router seam: miss and dormant

    func testFastLaneMissFallsBackToSynthesisWithHonestEvent() {
        let coordinator = FakeAckCoordinator()
        let player = FakePreAckPlayer()
        player.hit = false
        let (router, speaker, bus) = makeRouter(coordinator, player: player)

        _ = router.route(transcript: "set a timer for 5 minutes")
        waitForAsyncSpeak()

        XCTAssertTrue(speaker.utterances.contains {
            $0.text == ackVariant(1, locale: ne)
        }, "a miss speaks the ack through the existing synthesis path")
        let miss = bus.events.first { $0.eventType == "ack_cache_miss" }
        XCTAssertNotNil(miss, "a miss with an installed fast lane is logged honestly")
        XCTAssertEqual(miss?.component, "command_router")
        XCTAssertEqual(coordinator.assistantSpoken.first, ackVariant(1, locale: ne),
                       "the ack text is unchanged by the fallback")
    }

    func testNoFastLaneKeepsLegacyPathWithoutMissEvent() {
        let coordinator = FakeAckCoordinator()
        let (router, speaker, bus) = makeRouter(coordinator, player: nil)

        _ = router.route(transcript: "set a timer for 5 minutes")
        waitForAsyncSpeak()

        XCTAssertTrue(speaker.utterances.contains {
            $0.text == ackVariant(1, locale: ne)
        }, "the dormant seam keeps the pre-fast-lane synthesis path")
        XCTAssertFalse(bus.events.contains { $0.eventType == "ack_cache_miss" },
                       "a dormant seam (no player) logs nothing — byte-identical legacy behavior")
    }

    func testFastLaneHitRotatesVariants() {
        let coordinator = FakeAckCoordinator()
        let player = FakePreAckPlayer()
        let (router, _, _) = makeRouter(coordinator, player: player)

        for _ in 0..<4 {
            _ = router.route(transcript: "set a timer for 5 minutes")
        }

        XCTAssertEqual(player.playCalls.map(\.variant), [1, 2, 3, 1],
                       "variant rotation is unchanged — only the audio path differs")
    }

    // MARK: - Production player

    func testPlayerReturnsFalseOnCacheMissWithoutAudio() {
        var seamBegins = 0
        var seamEnds = 0
        ResponsePlaybackModeSeam.begin = { seamBegins += 1 }
        ResponsePlaybackModeSeam.end = { seamEnds += 1 }
        let bus = RecordingBus()
        let player = AckFastLanePlayer(cache: cache, observabilityBus: bus)

        let played = player.playCachedAck(variant: 1, locale: ne)

        XCTAssertFalse(played, "a cold cache reads as a miss — the router falls back")
        XCTAssertEqual(seamBegins, 0, "a miss never touches the audio session")
        XCTAssertEqual(seamEnds, 0)
        XCTAssertFalse(bus.events.contains { $0.eventType == "ack_cache_hit" })
    }

    func testPlayerPlaysCachedWavAndSettlesOnCancel() throws {
        var seamBegins = 0
        var seamEnds = 0
        ResponsePlaybackModeSeam.begin = { seamBegins += 1 }
        ResponsePlaybackModeSeam.end = { seamEnds += 1 }
        let bus = RecordingBus()
        let player = AckFastLanePlayer(cache: cache, observabilityBus: bus)
        let spec = AckVoiceSpec.resolve(locale: ne)
        try cache.store(wav: writeTinyWAV("cached.wav"), variant: 1, spec: spec)

        var finished = 0
        player.onPlaybackFinished = { finished += 1 }
        let played = player.playCachedAck(variant: 1, locale: ne)

        XCTAssertTrue(played, "a cached WAV plays without synthesis")
        XCTAssertEqual(seamBegins, 1, "playback begins the voice-reply session mode")
        let hit = bus.events.first { $0.eventType == "ack_cache_hit" }
        XCTAssertNotNil(hit, "a hit is logged with its setup cost")
        XCTAssertEqual(hit?.metadata["locale"], "ne-NP")

        player.cancel()
        XCTAssertEqual(seamEnds, 1, "settling restores the session mode exactly once")
        XCTAssertEqual(finished, 1, "the finished note fires exactly once per started playback")
        player.cancel()
        XCTAssertEqual(finished, 1, "a cancel with nothing playing is a no-op")
    }

    // MARK: - Speaker warm seam

    func testBuildAckCacheStoresVariantsThroughSpeakerSeam() throws {
        let store = try ModelStore(observabilityBus: RecordingBus(),
                                   rootDirectoryOverride: tempRoot)
        let bus = RecordingBus()
        let engine = FakeTTSEngine()
        let speaker = PiperVoiceSpeaker(
            fallback: SystemSpeechSpeaker(observabilityBus: bus),
            observabilityBus: bus,
            modelStore: store,
            engine: engine,
            bundle: Bundle(url: tempRoot)!,
            ackCache: cache)
        // Install the fake Nepali voice directory so the seam resolves it.
        let entry = ModelCatalog.entry(for: ModelCatalog.piperNepali)!
        let dir = tempRoot
            .appendingPathComponent("tts", isDirectory: true)
            .appendingPathComponent(entry.filename, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let done = expectation(description: "ack cache built")
        var result: AckCacheWarmResult?
        speaker.buildAckCache(locale: ne) { built in
            result = built
            done.fulfill()
        }
        wait(for: [done], timeout: 3.0)

        XCTAssertEqual(result, .ready)
        let spec = AckVoiceSpec.resolve(locale: ne)
        for n in 1...3 {
            XCTAssertNotNil(cache.wavURL(variant: n, spec: spec),
                            "the speaker seam caches every variant")
        }
        XCTAssertEqual(Set(engine.calls.map(\.text)),
                       Set((1...3).map { ackVariant($0, locale: ne) }),
                       "the seam synthesizes the catalog ack texts")
        XCTAssertTrue(bus.events.contains {
            $0.component == "ack_cache" && $0.eventType == "warm"
                && $0.outcome == "ready"
        }, "the build reports its warm outcome on the bus")
    }

    func testBuildAckCacheFailsHonestlyWithoutVoice() {
        let store = try! ModelStore(observabilityBus: RecordingBus(),
                                    rootDirectoryOverride: tempRoot)
        let bus = RecordingBus()
        let speaker = PiperVoiceSpeaker(
            fallback: SystemSpeechSpeaker(observabilityBus: bus),
            observabilityBus: bus,
            modelStore: store,
            engine: FakeTTSEngine(),
            bundle: Bundle(url: tempRoot)!,
            ackCache: cache)

        let done = expectation(description: "ack cache build settled")
        var result: AckCacheWarmResult?
        speaker.buildAckCache(locale: ne) { built in
            result = built
            done.fulfill()
        }
        wait(for: [done], timeout: 3.0)

        XCTAssertEqual(result, .failed(reason: "voice_missing"),
                       "a missing voice fails the build honestly — the ack path falls back")
        XCTAssertTrue(bus.events.contains {
            $0.component == "ack_cache" && $0.eventType == "warm"
                && $0.outcome == "failed" && $0.errorCode == "voice_missing"
        })
    }
}
