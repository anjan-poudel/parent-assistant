import XCTest
import AVFoundation
import SwiftUI
@testable import ElderlyAssistant

/// Integration-seam tests for the noise-filter front-end wiring in
/// `VoicePipeline` — the same doctrine as `AudioSessionControlling` /
/// `AudioSessionPresetTests`: the pipeline's capture fan-out, hot-swap,
/// and capture bookends are exercised with fakes, WITHOUT any audio
/// hardware (the mic tap and `AVAudioEngine.inputNode` are never touched —
/// the inputNode abort hazard documented in `installMicTap` and the
/// SherpaKWS test class is a test-host killer, so no test here reaches
/// `start()`).
final class VoicePipelineNoiseFilterSeamTests: XCTestCase {

    // MARK: - Fakes

    /// Minimal `AudioSessionControlling` fake — input reported as
    /// unavailable so NOTHING can ever reach the real input node.
    private final class RecordingSession: AudioSessionControlling {
        var isInputAvailable = false
        var notificationSource: AnyObject? { nil }
        func requestRecordPermission(_ callback: @escaping (Bool) -> Void) {
            callback(true)
        }
        func setCategory(_ category: AVAudioSession.Category,
                         mode: AVAudioSession.Mode,
                         options: AVAudioSession.CategoryOptions) throws {}
        func setActive(_ active: Bool,
                       options: AVAudioSession.SetActiveOptions) throws {}
        func setMode(_ mode: AVAudioSession.Mode) throws {}
        func setVoiceProcessingEnabled(_ enabled: Bool) throws {}
    }

    private final class RecordingBus: ObservabilityBus {
        private(set) var events: [ObservabilityEvent] = []
        func emit(_ event: ObservabilityEvent) {
            events.append(event)
        }
        func events(ofType type: String) -> [ObservabilityEvent] {
            events.filter { $0.eventType == type }
        }
    }

    private final class FakeRecognizer: SpeechRecognizerProtocol {
        var isAvailable = true
        let ownsAudioCapture = false
        private(set) var fedBuffers: [AVAudioPCMBuffer] = []
        private(set) var fedSamples: [Int16] = []
        private(set) var startCalls = 0
        private var completion: ((Result<String, RecognitionError>) -> Void)?

        func requestAuthorization(_ callback: @escaping (Bool) -> Void) {
            callback(true)
        }

        func startListening(timeout: TimeInterval,
                            completion: @escaping (Result<String, RecognitionError>) -> Void) {
            startCalls += 1
            self.completion = completion
        }

        func feed(_ buffer: AVAudioPCMBuffer) {
            fedBuffers.append(buffer)
            let frames = Int(buffer.frameLength)
            guard let data = buffer.int16ChannelData?.pointee else { return }
            fedSamples.append(contentsOf: UnsafeBufferPointer(start: data, count: frames))
        }

        func finish() {}

        func cancel() {
            guard let completion else { return }
            self.completion = nil
            completion(.failure(.cancelled))
        }
    }

    private final class FakeVAD: VoiceActivityDetector {
        let requiredSampleRate: Double = 16_000
        let frameLength = 512
        var onSpeechStateChange: ((Bool) -> Void)?
        var onEndOfUtterance: (() -> Void)?
        private(set) var frames: [[Int16]] = []
        private(set) var startCalls = 0
        func start(endOfUtteranceMs: Int) { startCalls += 1 }
        func stop() {}
        func reset() { frames.removeAll() }
        func process(_ pcm: [Int16]) { frames.append(pcm) }
    }

    /// Recording stage: identity processing, records every protocol call
    /// in order so the pipeline's bookend contract is pinned exactly.
    private final class FakeNoiseSuppressor: NoiseSuppressor {
        enum Call: Equatable {
            case process(Int)
            case reset
            case mode(NoiseSuppressorMode)
            case captureStarted
            case captureEnded
        }
        let requiredSampleRate: Double = 16_000
        let name = "fake_engine"
        let latencySamples = 0
        var calls: [Call] = []
        /// When true, `process` returns [] (contract violation probe).
        var starve = false

        func process(_ samples: [Int16]) -> [Int16] {
            calls.append(.process(samples.count))
            return starve ? [] : samples
        }
        func reset() { calls.append(.reset) }
        func setMode(_ mode: NoiseSuppressorMode) { calls.append(.mode(mode)) }
        func captureStarted() { calls.append(.captureStarted) }
        func captureEnded() { calls.append(.captureEnded) }
    }

    /// Minimal `VoiceCommandCoordinating` fake — trimmed copy of the
    /// CommandRouterTests mock (kept complete so protocol evolution
    /// surfaces here as a compile error, not a silent default).
    private final class MockVoiceCommandCoordinator: VoiceCommandCoordinating {
        var isAwaitingConfirmation = false
        var brainReadiness = BrainReadiness.available
        var isAwaitingCallConfirmation = false
        var activeLocale: Locale { Locale(identifier: "ne-NP") }
        var canAnswerLiveQuestionsFromWeb = false
        var isOnDeviceStack = false
        var navigationCandidates: [DirectionsCandidate] = []
        var isAwaitingNavigationDisambiguation = false
        var pendingRephraseCommand: InterpretedCommand? { nil }
        var recordedTranscripts: [String] = []

        func recordTranscript(_ text: String) { recordedTranscripts.append(text) }
        func oldestPendingReminderEntryId() -> UUID? { nil }
        func handleMedicationAcknowledgement(entryId: UUID) {}
        func startVoiceAckConfirmation(for entryId: UUID) -> String? { nil }
        func handleConfirmationResponse(_ response: ConfirmationResponse) {}
        func noteSpeakingStarted() {}
        func noteSpeakingEnded() {}
        func noteAssistantSpoke(_ text: String) {}
        func noteGenericReply(_ text: String) {}
        func addVoiceReminder(title: String, time: DateComponents) {}
        func requestCallConfirmation(contactQuery: String?, callType: String?,
                                     requestedApp: String?, sourceTranscript: String?,
                                     sourceCommand: InterpretedCommand?) -> String? { nil }
        func startRephraseConfirmation(_ command: InterpretedCommand,
                                       sourceTranscript: String?) {}
        func takePendingRephraseCommand()
            -> (command: InterpretedCommand, sourceTranscript: String?)? { nil }
        func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }
        func composeMessage(toContactNamed name: String?, body: String,
                            requestedApp: String?) -> MessageComposeOutcome {
            .contactNotFound
        }
        func presentPluginView(_ view: AnyView) {}
        func requestContactSearch(query: String?) {}
        func requestNavigation(to target: DirectionsRoute.PlaceTarget) {}
        func requestNavigationDisambiguation(targets: [DirectionsCandidate]) -> String? { nil }
        func requestAlarmSet(at time: Date, label: String?) async -> AlarmTimerSetOutcome { .failed }
        func requestTimerStart(durationSeconds: Int, label: String?) async -> AlarmTimerSetOutcome { .failed }
        func fireMorningBriefing() {}
    }

    // MARK: - Helpers

    private static let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: 16_000,
                                              channels: 1,
                                              interleaved: true)!

    private func makePipeline(noiseSuppressor: NoiseSuppressor? = nil)
        -> (pipeline: VoicePipeline, recognizer: FakeRecognizer,
            vad: FakeVAD, bus: RecordingBus) {
        let bus = RecordingBus()
        let recognizer = FakeRecognizer()
        let vad = FakeVAD()
        let defaults = UserDefaults(suiteName: "noise-seam-\(UUID().uuidString)")!
        let session = AudioSessionManager(observabilityBus: bus,
                                          audioSession: RecordingSession(),
                                          defaults: defaults)
        // Never started: init only wires callbacks and stores the stage —
        // no inputNode, no tap, no audio server.
        let pipeline = VoicePipeline(
            audioSession: session,
            audioEngine: AVAudioEngine(),
            wakeWordEngine: NullWakeWordEngine(),
            wakeWordGate: nil,
            speechRecognizer: recognizer,
            voiceActivityDetector: vad,
            noiseSuppressor: noiseSuppressor,
            router: CommandRouter(coordinator: MockVoiceCommandCoordinator(),
                                  observabilityBus: bus),
            observabilityBus: bus
        )
        return (pipeline, recognizer, vad, bus)
    }

    private func makeBuffer(filledWith samples: [Int16]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.format,
                                      frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.int16ChannelData?.pointee.update(from: src.baseAddress!,
                                                    count: src.count)
        }
        return buffer
    }

    private func samples(from buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let data = buffer.int16ChannelData?.pointee else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    private func deterministicNoise(count: Int, amplitude: Float, seed: UInt64) -> [Int16] {
        struct LCG: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return state
            }
        }
        var rng = LCG(state: seed)
        return (0..<count).map { _ in
            Int16(Float.random(in: -1...1, using: &rng) * amplitude * 32_768.0)
        }
    }

    // MARK: - Enhancement seam

    func testEnhanceSeamIsIdentityWithoutStage() {
        let (pipeline, _, _, bus) = makePipeline()
        let input = deterministicNoise(count: 1000, amplitude: 0.1, seed: 1)
        XCTAssertEqual(pipeline.enhanceCaptureSamples(input), input)
        XCTAssertTrue(bus.events(ofType: "noise_suppressor_starved").isEmpty)
    }

    func testEnhanceSeamRoutesThroughInjectedStage() {
        let fake = FakeNoiseSuppressor()
        let (pipeline, _, _, _) = makePipeline(noiseSuppressor: fake)
        let input = deterministicNoise(count: 777, amplitude: 0.1, seed: 2)
        XCTAssertEqual(pipeline.enhanceCaptureSamples(input), input)
        XCTAssertEqual(fake.calls, [.process(777)])
    }

    func testStarvationFallbackPassesRawAndEmitsHonestEvent() {
        let fake = FakeNoiseSuppressor()
        fake.starve = true
        let (pipeline, _, _, bus) = makePipeline(noiseSuppressor: fake)
        let input = deterministicNoise(count: 777, amplitude: 0.1, seed: 3)

        XCTAssertEqual(pipeline.enhanceCaptureSamples(input), input,
                       "a starved stage must fall back to raw, never corrupt the capture")
        let events = bus.events(ofType: "noise_suppressor_starved")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.outcome, "fallback")
        XCTAssertEqual(events.first?.metadata["engine"], "fake_engine")
    }

    // MARK: - Capture fan-out

    func testFeedCaptureWithoutStageFeedsOriginalBufferIdentity() {
        let (pipeline, recognizer, vad, _) = makePipeline()
        let input = deterministicNoise(count: 2048, amplitude: 0.1, seed: 4)
        let buffer = makeBuffer(filledWith: input)

        pipeline.feedCapture(pcm: input, buffer: buffer)

        // Byte-identical legacy path: the converter's own buffer object
        // goes to the STT untouched.
        XCTAssertEqual(recognizer.fedBuffers.count, 1)
        XCTAssertTrue(recognizer.fedBuffers[0] === buffer,
                      "no stage ⇒ the original buffer is fed, byte-identical legacy behavior")
        // VAD consumes the same stream sliced into its 512-frame geometry.
        XCTAssertEqual(vad.frames, input.chunked(by: 512))
    }

    func testFeedCaptureWithStagePushesEnhancedStreamToSTTAndVAD() {
        let real = SpectralGateDenoiser(observabilityBus: RecordingBus())
        let (pipeline, recognizer, vad, _) = makePipeline(noiseSuppressor: real)
        let input = deterministicNoise(count: 2048, amplitude: 0.02, seed: 5)
        let buffer = makeBuffer(filledWith: input)

        pipeline.feedCapture(pcm: input, buffer: buffer)

        // Expected: a parallel instance fed identically must produce the
        // exact same enhanced stream (deterministic pure DSP).
        let twin = SpectralGateDenoiser(observabilityBus: RecordingBus())
        let expected = twin.process(input)

        XCTAssertEqual(samples(from: recognizer.fedBuffers.last!), expected,
                       "the STT must receive exactly the stage's output")
        XCTAssertEqual(recognizer.fedBuffers.last!.format.sampleRate, 16_000)
        XCTAssertEqual(recognizer.fedBuffers.last!.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(recognizer.fedBuffers.last!.format.channelCount, 1)
        XCTAssertEqual(Int(recognizer.fedBuffers.last!.frameLength), expected.count,
                       "the rebuilt STT buffer carries exactly the enhanced chunk")

        // The endpointing VAD consumes the SAME enhanced stream, sliced
        // into its frame geometry.
        XCTAssertEqual(vad.frames, expected.chunked(by: 512))
    }

    // MARK: - Hot swap

    func testHotSwapEmitsHonestEngineName() {
        let (pipeline, _, _, bus) = makePipeline()
        let fake = FakeNoiseSuppressor()

        pipeline.setNoiseSuppressor(fake)
        var events = bus.events(ofType: "noise_suppressor_hot_swap")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.metadata["engine"], "fake_engine")

        pipeline.setNoiseSuppressor(nil)
        events = bus.events(ofType: "noise_suppressor_hot_swap")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.metadata["engine"], "off")
    }

    func testHotSwapPropagatesCurrentStateAsMode() {
        let (pipeline, _, _, _) = makePipeline()
        let fake = FakeNoiseSuppressor()
        pipeline.setNoiseSuppressor(fake)
        // Pipeline is .stopped (never started in these tests) ⇒ not idle.
        XCTAssertEqual(fake.calls.last, .mode(.capturing))
    }

    // MARK: - Capture bookends

    func testCaptureBookendsDriveStageInOrder() {
        let fake = FakeNoiseSuppressor()
        let (pipeline, _, _, _) = makePipeline(noiseSuppressor: fake)

        pipeline.beginNoiseFilterCapture()
        pipeline.endNoiseFilterCapture()

        XCTAssertEqual(fake.calls, [
            .mode(.capturing),
            .reset,
            .captureStarted,
            .captureEnded,
            .mode(.idleListening),
        ])
    }

    func testBookendsAreNoOpsWithoutStage() {
        let (pipeline, _, _, _) = makePipeline()
        pipeline.beginNoiseFilterCapture()
        pipeline.endNoiseFilterCapture()
        // Must not crash, emit, or touch anything.
    }

    // MARK: - Wake-engine hot-swap ([STARTUP-R2])

    /// Recording wake engine — starts/stop calls counted, `fireDetection`
    /// triggers the handler the pipeline wired.
    private final class FakeWakeWordEngine: WakeWordEngine {
        let requiredSampleRate: Double = 16_000
        let frameLength: Int = 512
        var onDetection: (() -> Void)?
        private(set) var startCalls = 0
        private(set) var stopCalls = 0
        var failStart = false

        func start() throws {
            if failStart { throw NSError(domain: "FakeWakeWordEngine", code: 1) }
            startCalls += 1
        }

        func stop() { stopCalls += 1 }
        func process(_ pcm: [Int16]) {}

        func fireDetection() { onDetection?() }
    }

    func testSetWakeWordEngineSwapsInAndStartsWhenIdle() {
        let (pipeline, recognizer, _, bus) = makePipeline()
        pipeline.debugEnterIdleForTesting()

        let real = FakeWakeWordEngine()
        pipeline.setWakeWordEngine(real)

        XCTAssertEqual(real.startCalls, 1,
                       "the swapped-in engine starts against a live pipeline")
        XCTAssertEqual(bus.events(ofType: "kws_hot_swap").last?.outcome,
                       "success")

        // The re-wired detection drives a real capture — the swap is a
        // first-class wake path, not a display-only substitution.
        real.fireDetection()
        XCTAssertEqual(pipeline.state, .capturingCommand)
        XCTAssertEqual(recognizer.startCalls, 1,
                       "a detection on the swapped engine starts STT exactly like the original engine's")
    }

    func testSetWakeWordEngineDoesNotStartWhileStopped() {
        let (pipeline, _, _, _) = makePipeline()
        // Never debugEnterIdleForTesting — the pipeline stays .stopped,
        // matching a swap landing after a recycle.
        let real = FakeWakeWordEngine()
        pipeline.setWakeWordEngine(real)
        XCTAssertEqual(real.startCalls, 0,
                       "no start against a stopped pipeline (the boot's start() owns that)")
        // Detection is still wired for when the pipeline does start.
        XCTAssertNotNil(real.onDetection)
    }

    func testSetWakeWordEngineReportsStartFailureHonestly() {
        let (pipeline, _, _, bus) = makePipeline()
        pipeline.debugEnterIdleForTesting()

        let real = FakeWakeWordEngine()
        real.failStart = true
        pipeline.setWakeWordEngine(real)

        let event = bus.events(ofType: "kws_hot_swap").last
        XCTAssertEqual(event?.outcome, "failure")
        XCTAssertEqual(event?.errorCode, "start_failed")
        // The pipeline keeps its pre-swap behavior: .idle stays usable.
        XCTAssertEqual(pipeline.state, .idle)
    }
}

private extension Array where Element == Int16 {
    func chunked(by size: Int) -> [[Int16]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
