import AVFoundation
import Combine
import CoreMedia
import XCTest
@testable import ElderlyAssistant

/// T-026's second half — the session model (FR-LCT-018, FR-LCT-022,
/// FR-LCT-023; NFR-LCT-010, NFR-LCT-011).
///
/// The pipeline suite proves what one cycle publishes; this suite proves the
/// *life* around it: start is idempotent, the frame loop is the only task the
/// model owns and the next frame is the retry, the model is the single
/// observation surface the view renders (including the consent prompt, the
/// indicator and the toggle it forwards rather than copies), ordering is
/// enforced at the model boundary, and closing is a structural teardown after
/// which nothing renders and nothing calls back.
///
/// The integration test at the end wires the real components together — the
/// real camera session over a stubbed capture *layer*, the real detector over
/// a stubbed recognition engine, the real cache, gate, tier and client — so
/// the frame path from a delivered sample buffer to a rendered publication is
/// exercised end to end with only the platform seams doubled.
final class LiveTranslateSessionModelTests: XCTestCase {

    private let config = LiveTranslateConfig.default
    private let nepali = Locale(identifier: "ne-NP")

    /// A string the injected curated table answers, and its translation.
    private let curatedText = "Light"
    private let curatedTranslation = "बत्ती"
    /// A string no device layer can answer, so it reaches the cloud path.
    private let cloudText = "Members only beyond this point"

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    // MARK: - Harness

    /// The shared composition (`LiveTranslateSessionTestHarness.swift`) plus
    /// the model under test, so a test reads the model and the components it
    /// drives from one value.
    @MainActor
    private struct Harness {
        let parts: LiveTranslateSessionTestParts
        let model: LiveTranslateSessionModel

        var camera: LiveCameraSession { parts.camera }
        var capture: SessionCaptureLayer { parts.capture }
        var engine: SessionRecognitionEngine { parts.engine }
        var speech: SessionSpeechPath { parts.speech }
        var device: SessionDevice { parts.device }
        var audio: SessionAudioSession { parts.audio }
        var gate: LiveTranslateConsentGate { parts.gate }
        var transport: TierTranslationTransport { parts.transport }
        var notifications: NotificationCenter { parts.notifications }
        var bus: LiveTranslateSanitisingBus { parts.bus }
        var log: SessionLog { parts.log }
        var clock: SessionClock { parts.clock }
        var defaults: UserDefaults { parts.defaults }
    }

    /// The one way this suite builds a session: the shared factory, wrapped.
    @MainActor
    private func makeHarness(authorization: CameraAuthorizationStatus = .granted,
                             consent: Bool = false,
                             configured: Bool = false,
                             configurationError: LiveTranslateError? = nil,
                             dictionary: [String: String]? = nil,
                             transport: TierTranslationTransport = TierTranslationTransport()) -> Harness {
        let parts = makeLiveTranslateSessionTestParts(authorization: authorization,
                                                      consent: consent,
                                                      configured: configured,
                                                      configurationError: configurationError,
                                                      dictionary: dictionary ?? [:],
                                                      transport: transport,
                                                      locale: nepali,
                                                      config: config)
        suiteNames.append(parts.suiteName)
        return Harness(parts: parts,
                       model: LiveTranslateSessionModel(dependencies: parts.dependencies))
    }

    // MARK: - Frame helpers

    /// Reports the geometry the model cannot derive (T-027's view does this on
    /// appear and on every size change).
    @MainActor
    private func reportLayout(_ harness: Harness) {
        harness.model.updateLayout(containerSize: CGSize(width: 390, height: 844),
                                   safeArea: CGRect(x: 0, y: 47, width: 390, height: 763),
                                   occupiedRects: [CGRect(x: 0, y: 780, width: 390, height: 64)])
    }

    /// Delivers one frame through the capture layer — the same path
    /// `AVCaptureVideoDataOutput` uses — and waits for the recognition pass it
    /// triggers, so the next delivery is not dropped by the backpressure flag.
    @MainActor
    private func deliverPass(_ harness: Harness,
                             width: Int = 1920,
                             height: Int = 1080,
                             file: StaticString = #filePath,
                             line: UInt = #line) async throws {
        let passesBefore = harness.engine.recognizeCallCount
        harness.clock.advance()
        let pts = CMTime(value: CMTimeValue(harness.clock.now * 600), timescale: 600)
        let buffer = try SampleBufferFactory.make(width: width, height: height, pts: pts)
        harness.capture.deliver(buffer)
        await waitUntil("the delivered frame to be recognised", file: file, line: line) {
            harness.engine.recognizeCallCount > passesBefore
        }
        // The recognition call marks the *start* of the pass, and the tap drops
        // samples while one is in flight (`LiveCameraSession.ocrPassInFlight`,
        // T-026). Handing the next frame over at this instant would hand it to
        // a drop — the tap shedding a sample, which is the feature working, not
        // a recognition that did not happen. So the helper waits for the pass
        // it triggered to be free again: the frame source's own "ready for the
        // next sample" signal, and the guarantee this helper's contract names.
        await waitUntil("the recognition pass to finish", file: file, line: line) {
            !harness.camera.ocrPassInFlight
        }
    }

    /// Delivers `count` frames.
    @MainActor
    private func deliverPasses(_ count: Int, in harness: Harness) async throws {
        for _ in 0..<count { try await deliverPass(harness) }
    }

    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 5,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task<Never, Never>.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    /// A provider envelope for a request whose items are these texts, in this
    /// order: the wire ids are the request's own positions
    /// (`CloudTranslationTier.send` hands the client `String(index)`), which is
    /// what the shipped parser validates against.
    private static func respondingTransport() -> TierTranslationTransport {
        let transport = TierTranslationTransport()
        transport.autoRespond = { byID in
            let out = byID.mapValues { "ने:" + $0 }
            return String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!
        }
        return transport
    }

    private func detected(_ text: String, box: (Double, Double, Double, Double) = (0.1, 0.1, 0.5, 0.2))
        -> LiveTextDetector.DetectedTextRegion {
        LiveTextDetector.DetectedTextRegion(text: text,
                                            normalizedBox: NormalizedBox(xMin: box.0, yMin: box.1,
                                                                         xMax: box.2, yMax: box.3),
                                            detectedLanguage: "en",
                                            confidence: 0.9)
    }

    // MARK: - Scenario: A full cycle produces one coherent publication

    @MainActor
    func testScenarioAFullCycleProducesOneCoherentPublicationThroughTheModel() async throws {
        // The whole frame path, end to end: a delivered sample buffer, the
        // real capture session's cadence, the real detector over a stubbed
        // recogniser, the real cache and the model's surface — with the
        // dictionary answering, so no cloud is involved at all.
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]
        await harness.model.start()
        XCTAssertEqual(harness.model.phase, .running)

        try await deliverPasses(3, in: harness)

        await waitUntil("the curated region to be published as resolved") {
            guard let publication = harness.model.publication,
                  let region = publication.regions.first(where: { $0.text == self.curatedText })
            else { return false }
            if case .resolved = publication.result(for: region).outcome { return true }
            return false
        }

        let publication = try XCTUnwrap(harness.model.publication)
        // One publication per cycle, and every one of them whole: the model's
        // surface is the publication and not a second derivation of it.
        XCTAssertEqual(harness.model.surface.placements, publication.placements)
        XCTAssertEqual(harness.model.surface.policy, publication.policy)
        XCTAssertEqual(harness.model.surface.locale, nepali)

        // Outcomes and placements arrive together: the drawn rect and the
        // outcome it was measured from are one value.
        XCTAssertFalse(publication.placements.isEmpty, "a laid-out session places its regions")
        for placement in publication.placements {
            XCTAssertEqual(publication.outcomes[placement.region.id], placement.result)
        }

        // No network was attempted: every visible string was curated.
        XCTAssertEqual(harness.transport.requestCount, 0)
        XCTAssertFalse(harness.log.all.contains("audio.active"),
                       "a dictionary-only cycle opens no microphone and no audio session")
    }

    // MARK: - Scenario: The dictionary path needs no network at all

    @MainActor
    func testScenarioTheDictionaryPathNeedsNoNetworkAtAll() async throws {
        // The same claim from the model's side, with no provider key and no
        // network client configured: a curated scene still shows translations,
        // because the device answers and the model renders what it answered. A
        // string no layer can answer is not sent either — with no consent
        // recorded it waits for the elder's decision, which is the point of
        // the prompt.
        let harness = makeHarness(configured: false,
                                  dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText), detected(cloudText, box: (0.5, 0.5, 0.9, 0.7))]
        await harness.model.start()

        try await deliverPasses(3, in: harness)

        await waitUntil("the curated region to resolve") {
            guard let publication = harness.model.publication,
                  let region = publication.regions.first(where: { $0.text == self.curatedText })
            else { return false }
            if case .resolved = publication.result(for: region).outcome { return true }
            return false
        }
        let publication = try XCTUnwrap(harness.model.publication)
        let curated = try XCTUnwrap(publication.regions.first { $0.text == self.curatedText })
        guard case .resolved(_, let translation, let tier) = publication.result(for: curated).outcome else {
            return XCTFail("a curated string resolves on device")
        }
        XCTAssertEqual(translation, curatedTranslation)
        XCTAssertEqual(tier, .dictionary)

        let uncurated = try XCTUnwrap(publication.regions.first { $0.text == self.cloudText })
        guard case .pending = publication.result(for: uncurated).outcome else {
            return XCTFail("an uncurated string is not silently degraded before the elder has been asked")
        }
        XCTAssertEqual(harness.transport.requestCount, 0,
                       "the dictionary path needs no network at all")
        XCTAssertTrue(harness.model.consent.isPromptPresented,
                      "the uncurated string asks the elder at its point of first need")
    }

    // MARK: - Scenario: Closing cancels in-flight work and tears everything down

    @MainActor
    func testScenarioClosingCancelsInFlightWorkAndTearsEverythingDown() async throws {
        // A session with everything live at once: an open command window, a
        // started camera, a begun detector, speech on the queue.
        let harness = makeHarness(consent: true, configured: true, transport: Self.respondingTransport())
        reportLayout(harness)
        harness.engine.regions = [detected(cloudText)]
        await harness.model.start()
        try await deliverPasses(2, in: harness)
        harness.model.listenForCommand()
        XCTAssertTrue(harness.device.hasOpenWindow, "the command window is open before the close")
        harness.model.handleCapture(.command(.readAll))

        await harness.model.close()

        XCTAssertEqual(harness.model.phase, .closed)
        XCTAssertNil(harness.model.previewLayer)
        XCTAssertNil(harness.model.publication, "nothing is on screen after a close")

        // Recognition is released, the command window is drained, the audio
        // session is released, and only then does the camera stop — the
        // design's own order, read as one sequence rather than four counts.
        await waitUntil("the camera to stop last") {
            harness.capture.isRunning == false && harness.log.index(of: "camera.stop") != nil
        }
        let log = harness.log.all
        let recognition = try XCTUnwrap(log.firstIndex(of: "detector.forget"))
        let drain = try XCTUnwrap(log.firstIndex(of: "speech.drain"))
        let window = try XCTUnwrap(log.firstIndex(of: "device.cancel"))
        let audio = try XCTUnwrap(log.firstIndex(of: "audio.inactive"))
        let camera = try XCTUnwrap(log.firstIndex(of: "camera.stop"))
        XCTAssertLessThan(recognition, drain, "recognition stops before the session's speech is drained")
        XCTAssertLessThan(drain, window, "speech is drained before the microphone window closes")
        XCTAssertLessThan(window, camera, "the command window closes before the camera session stops")
        XCTAssertLessThan(audio, camera, "the audio session is released before the camera session stops")
        XCTAssertEqual(harness.capture.session.isRunning, false)
        XCTAssertEqual(harness.device.cancelCount, 1, "the window is closed exactly once")
        XCTAssertFalse(harness.device.hasOpenWindow)
    }

    // MARK: - Scenario: no publication or callback after close (DoD)

    @MainActor
    func testNothingRendersOrCallsBackAfterClose() async throws {
        let harness = makeHarness(consent: true, configured: true, transport: Self.respondingTransport())
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPasses(2, in: harness)
        harness.model.listenForCommand()
        await harness.model.close()

        // 1. A publication that arrives after the close renders nothing —
        //    including one with a higher counter, which the ordering guard
        //    alone would have accepted.
        let late = LiveTranslatePublication(sequence: 999,
                                            regions: [],
                                            outcomes: [:],
                                            placements: [],
                                            policy: harness.model.policy)
        harness.model.receive(late)
        XCTAssertNil(harness.model.publication)
        XCTAssertTrue(harness.model.surface.placements.isEmpty)

        // 2. No callback reaches the model: a command window that reports
        //    after the close is dropped, and a command dispatched by hand does
        //    nothing.
        let spokenBefore = harness.speech.spokenTexts.count
        harness.model.handleCapture(.command(.readAll))
        harness.model.handleCapture(.reprompt)
        XCTAssertEqual(harness.speech.spokenTexts.count, spokenBefore,
                       "no callback speaks after the session closed")

        // 3. No new work starts: no microphone window, no speech.
        harness.model.listenForCommand()
        XCTAssertFalse(harness.model.isListening)
        XCTAssertTrue(harness.speech.spokenTexts.isEmpty || spokenBefore == harness.speech.spokenTexts.count)
        XCTAssertEqual(harness.device.startCount, 1, "the closed session opens no second window")
    }

    // MARK: - Scenario: start is idempotent (T-027's re-entrant appear)

    @MainActor
    func testStartIsIdempotentAcrossAReentrantAppear() async throws {
        // SwiftUI may present the same view twice (a sheet re-entering, a
        // rotation). A second start must not build a second session — the
        // evidence is that the camera is configured once and one delivered
        // frame produces exactly one recognition pass.
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]

        await harness.model.start()
        await harness.model.start()

        XCTAssertEqual(harness.log.count(of: "camera.configure"), 1,
                       "a re-entrant appear does not configure a second capture session")
        XCTAssertEqual(harness.log.count(of: "camera.start"), 1)
        XCTAssertEqual(harness.model.phase, .running)

        try await deliverPass(harness)
        XCTAssertEqual(harness.engine.recognizeCallCount, 1,
                       "one frame is one pass: a second frame loop would double every tick")
    }

    // MARK: - Scenario: nothing is built until the feature is opened (DoD)

    @MainActor
    func testNothingIsBuiltUntilStart() async {
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])

        XCTAssertEqual(harness.model.phase, .idle)
        XCTAssertNil(harness.model.publication)
        XCTAssertNil(harness.model.previewLayer)
        XCTAssertTrue(harness.log.all.isEmpty,
                      "building the model creates no capture session, no recognition request and no network client")

        await harness.model.start()
        XCTAssertEqual(harness.model.phase, .running)
        XCTAssertNotNil(harness.model.previewLayer)
        XCTAssertEqual(harness.log.all, ["camera.configure", "camera.start"])
    }

    // MARK: - Scenario: Backgrounding pauses rather than running a background session

    @MainActor
    func testScenarioBackgroundingPausesAndForegroundingResumesOnce() async throws {
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPasses(2, in: harness)

        // Backgrounded: capture pauses, and a frame delivered while the app is
        // away is not processed — the tap drops it, which is what "no frames
        // are processed while backgrounded" means observably.
        harness.notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await waitUntil("the model to pause") { harness.model.isPaused }
        XCTAssertEqual(harness.camera.state, .interrupted(.backgrounded))
        let passesBefore = harness.engine.recognizeCallCount
        harness.clock.advance()
        harness.capture.deliver(try SampleBufferFactory.make(width: 1920, height: 1080,
                                                             pts: CMTime(value: 900, timescale: 600)))
        try? await Task<Never, Never>.sleep(for: .milliseconds(80))
        XCTAssertEqual(harness.engine.recognizeCallCount, passesBefore,
                       "no frame is processed while the app is backgrounded")

        // Foregrounded: one resume. A second foreground signal with no
        // background between them is a no-op, so the counter stays at one.
        harness.notifications.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await waitUntil("the model to resume") { harness.model.resumeCount == 1 }
        harness.notifications.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try? await Task<Never, Never>.sleep(for: .milliseconds(40))
        XCTAssertEqual(harness.model.resumeCount, 1,
                       "a repeated foreground signal while running resumes nothing a second time")
        XCTAssertFalse(harness.model.isPaused)

        // The frames flow again, and the resumed session re-renders the scene.
        try await deliverPasses(2, in: harness)
        await waitUntil("the resumed session to render again") {
            harness.model.publication?.hasVisibleText == true
        }
    }

    // MARK: - Scenario: no tick queues behind a slow pass (NFR-LCT-011)

    @MainActor
    func testScenarioNoFrameIsProcessedWhileAPassIsInFlight() async throws {
        // The pipeline owns the pass and sets the camera's flag while Vision
        // runs; the tap drops samples rather than queueing them. Driving the
        // flag directly is what makes the claim structural at this seam: no
        // recognition runs, and the delivery does not accumulate.
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]
        await harness.model.start()

        harness.camera.ocrPassInFlight = true
        harness.clock.advance()
        harness.capture.deliver(try SampleBufferFactory.make(width: 1920, height: 1080,
                                                             pts: CMTime(value: 600, timescale: 600)))
        try? await Task<Never, Never>.sleep(for: .milliseconds(80))
        XCTAssertEqual(harness.engine.recognizeCallCount, 0,
                       "a frame that arrives during a pass is dropped, not queued")

        harness.camera.ocrPassInFlight = false
        try await deliverPass(harness)
        XCTAssertEqual(harness.engine.recognizeCallCount, 1,
                       "the next tick after the pass is the retry")
    }

    // MARK: - Scenario: Publication ordering is monotone (AM-6 at the model)

    @MainActor
    func testPublicationOrderIsEnforcedAtTheModelBoundary() async {
        // AM-6's counter is the feature's only ordering signal. A re-delivered
        // or late publication is refused rather than rendered as a rewind —
        // the model is where "never render an older state" is enforced.
        let harness = makeHarness()
        let policy = harness.model.policy

        harness.model.receive(LiveTranslatePublication(sequence: 4, regions: [], outcomes: [:],
                                                       placements: [], policy: policy))
        XCTAssertEqual(harness.model.publication?.sequence, 4)

        harness.model.receive(LiveTranslatePublication(sequence: 4, regions: [], outcomes: [:],
                                                       placements: [], policy: policy))
        XCTAssertEqual(harness.model.publication?.sequence, 4, "a repeated sequence is not a new state")

        harness.model.receive(LiveTranslatePublication(sequence: 3, regions: [], outcomes: [:],
                                                       placements: [], policy: policy))
        XCTAssertEqual(harness.model.publication?.sequence, 4, "an older publication never renders")

        harness.model.receive(LiveTranslatePublication(sequence: 5, regions: [], outcomes: [:],
                                                       placements: [], policy: policy))
        XCTAssertEqual(harness.model.publication?.sequence, 5)
    }

    // MARK: - The single observation surface

    @MainActor
    func testTheModelIsTheSingleObservationSurface() async throws {
        // Everything the view renders is a property of the model — including
        // the consent prompt, which the controller owns and the model forwards.
        // The evidence for "one surface" is that a change in the forwarded
        // object reaches the model's own `objectWillChange`.
        let harness = makeHarness()
        var changes = 0
        let token = harness.model.objectWillChange.sink { _ in changes += 1 }
        defer { token.cancel() }

        // Before any publication the surface is the empty state: renderable,
        // and not a claim about a scene.
        XCTAssertTrue(harness.model.surface.placements.isEmpty)
        XCTAssertEqual(harness.model.surface.locale, nepali)
        XCTAssertFalse(harness.model.cloudIndicator.isActive)

        // The consent prompt is the controller's state, observed through the
        // model: the first cloud need presents it and says so.
        let decision = harness.model.consent.cloudNeedDetected()
        XCTAssertEqual(decision, .awaitingDecision)
        XCTAssertTrue(harness.model.consent.isPromptPresented)
        XCTAssertGreaterThan(changes, 0,
                             "the controller's change reaches the view through the model's own publisher")
    }

    @MainActor
    func testConsentAnswersRouteThroughTheModelToTheGate() async {
        let harness = makeHarness()
        _ = harness.model.consent.cloudNeedDetected()
        XCTAssertTrue(harness.model.consent.isPromptPresented)

        harness.model.grantCloudConsent()
        XCTAssertEqual(harness.gate.currentDecision(), .granted)
        XCTAssertFalse(harness.model.consent.isPromptPresented)

        // The same two calls record the other answer on the same gate: a
        // decline fails closed, and it is the model's route the view uses.
        harness.model.declineCloudConsent()
        XCTAssertEqual(harness.gate.currentDecision(), .denied)
        XCTAssertFalse(harness.gate.currentDecision().allowsEgress)
        XCTAssertFalse(harness.model.consent.isPromptPresented)
    }

    // MARK: - Commands and speech (C12's seams)

    @MainActor
    func testCommandsRouteThroughTheModel() async throws {
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPasses(3, in: harness)
        await waitUntil("the region to be rendered") {
            harness.model.publication?.hasVisibleText == true
        }

        // "read this to me" speaks what is drawn.
        harness.model.handleCapture(.command(.readAll))
        XCTAssertEqual(harness.speech.spokenTexts, [curatedTranslation],
                       "the spoken string is the drawn string")

        // The toggle command writes through the one setting the touch control
        // also writes, and the model mirrors what was stored.
        XCTAssertFalse(harness.model.alwaysShowOriginal)
        harness.model.handleCapture(.command(.setShowOriginal(true)))
        XCTAssertTrue(harness.model.alwaysShowOriginal)
        XCTAssertTrue(harness.defaults.bool(forKey: LiveTranslateSettings.alwaysShowOriginalKey))

        // A command that was not understood is answered in the assistant's own
        // words — the shipped re-prompt, not a new sentence (T-005's rule).
        let reprompt = harness.model.repromptText
        harness.model.handleCapture(.reprompt)
        XCTAssertEqual(harness.speech.spokenTexts.last, reprompt)
        XCTAssertFalse(reprompt.isEmpty)
        XCTAssertEqual(LiveTranslateSessionModel.repromptKey, "router.reprompt",
                       "the re-prompt is the shipped sentence, reused")
        XCTAssertFalse(harness.model.isListening, "an outcome ends the window")

        // The windows that ended without a command say nothing at all.
        let spoken = harness.speech.spokenTexts.count
        for outcome: LiveTranslateCommandCapture.Outcome in [.turnEnded, .noSpeech, .unavailable,
                                                             .cancelled, .refused(.sessionClosed)] {
            harness.model.handleCapture(outcome)
        }
        XCTAssertEqual(harness.speech.spokenTexts.count, spoken,
                       "a window that ends without a command is not an error the elder must hear")

        // "close translation" is the session's one explicit exit.
        harness.model.handleCapture(.command(.close))
        await waitUntil("the close command to tear the session down") { harness.model.phase == .closed }
        XCTAssertNil(harness.model.publication)
    }

    @MainActor
    func testTheMicrophoneGateSeesTheFeaturesOwnSpeech() async {
        // The gate is `LiveTranslateSpeech.isSpeaking`, read live: while the
        // feature is speaking, no window opens, so it cannot hear itself.
        let harness = makeHarness()
        await harness.model.start()
        harness.speech.setSpeaking(true)

        harness.model.listenForCommand()

        XCTAssertFalse(harness.model.isListening)
        XCTAssertEqual(harness.device.startCount, 0, "the microphone never opens on the feature's own voice")

        harness.speech.setSpeaking(false)
        harness.model.listenForCommand()
        XCTAssertTrue(harness.model.isListening)
        XCTAssertEqual(harness.device.startCount, 1)
    }

    // MARK: - The indicator the tier drives is the one on screen

    @MainActor
    func testTheCloudIndicatorTheTierDrivesIsTheOneOnScreen() async throws {
        // The tier is handed the model's own indicator, so the counter it
        // turns on is the counter the elder sees — asserted through the
        // model's surface while a real request is held open.
        let transport = Self.respondingTransport()
        let latch = TransportLatch()
        transport.latch = latch
        let harness = makeHarness(consent: true, configured: true, transport: transport)
        reportLayout(harness)
        harness.engine.regions = [detected(cloudText)]
        await harness.model.start()

        try await deliverPasses(2, in: harness)
        await waitUntil("the cloud request to be in flight") { transport.requestCount == 1 }
        XCTAssertTrue(harness.model.cloudIndicator.isActive,
                      "the indicator is on while a request is in flight")

        await latch.open()
        await waitUntil("the request to end") { transport.requestCount == 1 }
        await waitUntil("the region to resolve") {
            guard let publication = harness.model.publication,
                  let region = publication.regions.first(where: { $0.text == self.cloudText })
            else { return false }
            if case .resolved = publication.result(for: region).outcome { return true }
            return false
        }
        await waitUntil("the indicator to return to off") { harness.model.cloudIndicator.isActive == false }
    }

    // MARK: - T-008's surfaces

    @MainActor
    func testStartFailureIsRenderedAsThePermissionSurface() async {
        let denied = makeHarness(authorization: .denied)
        await denied.model.start()
        XCTAssertEqual(denied.model.phase, .failed(.cameraPermissionDenied))
        XCTAssertEqual(denied.model.cameraSurface, .denied)
        XCTAssertNil(denied.model.previewLayer, "a denied start shows the card, never a blank preview")

        let undetermined = makeHarness(authorization: .notDetermined)
        await undetermined.model.start()
        XCTAssertEqual(undetermined.model.phase, .failed(.cameraPermissionNotDetermined))
        XCTAssertEqual(undetermined.model.cameraSurface, .explanation)

        // The explanation's "continue" is the call that asks.
        await undetermined.model.continueFromCameraExplanation()
        XCTAssertEqual(undetermined.model.phase, .running)
        XCTAssertNil(undetermined.model.cameraSurface)
        XCTAssertEqual(undetermined.log.count(of: "camera.configure"), 1)
    }

    // MARK: - Layout

    @MainActor
    func testLayoutReportedBeforeStartIsFlushedIntoThePipeline() async throws {
        // SwiftUI lays the view out before `onAppear` in some presentations. A
        // layout reported then must not be dropped: without it the placement
        // has no container to map into and the overlay would draw nothing.
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]

        await harness.model.start()
        try await deliverPasses(3, in: harness)

        await waitUntil("the flushed layout to place the region") {
            harness.model.surface.placements.isEmpty == false
        }
        let placement = try XCTUnwrap(harness.model.surface.placements.first)
        // A placement exists only if the pipeline knew both the container and
        // the frame's geometry, and it carries the measured lines the overlay
        // draws — so the flushed layout is the layout the callout was placed
        // in, not a second one the view would compute.
        XCTAssertFalse(placement.lines.isEmpty, "the placement was measured against the reported container")
        XCTAssertEqual(placement.lines.first?.text, curatedTranslation)
    }

    @MainActor
    func testAnUnchangedLayoutIsDropped() async throws {
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        await harness.model.start()
        await waitUntil("the first publication") { harness.model.publication != nil }

        let sequenceBefore = try XCTUnwrap(harness.model.publication?.sequence)
        reportLayout(harness) // identical geometry: a layout pass that changed nothing
        try? await Task<Never, Never>.sleep(for: .milliseconds(40))
        XCTAssertEqual(harness.model.publication?.sequence, sequenceBefore,
                       "a layout pass that changed nothing publishes nothing")
    }
}
