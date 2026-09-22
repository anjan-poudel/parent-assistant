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
    /// A second uncurated string, so a question can be asked *after* the cloud
    /// switch is turned on — the one the switch's scenario resolves.
    private let secondCloudText = "Push the green button"

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
        /// The session's date clock — what the brain's interval is paced on,
        /// advanced by a suite that means "the clock has opened".
        var dateClock: SessionDateClock { parts.dateClock }
        var defaults: UserDefaults { parts.defaults }
        /// The session's suspension seam — what the clock hold was asked to
        /// wait for (Workstream B).
        var sleeper: RecordingSleeper { parts.sleeper }
    }

    /// The one way this suite builds a session: the shared factory, wrapped.
    @MainActor
    private func makeHarness(authorization: CameraAuthorizationStatus = .granted,
                             consent: Bool = false,
                             configured: Bool = false,
                             configurationError: LiveTranslateError? = nil,
                             dictionary: [String: String]? = nil,
                             transport: TierTranslationTransport = TierTranslationTransport(),
                             extractMode: Bool = false,
                             locale: Locale = Locale(identifier: "ne-NP"),
                             config: LiveTranslateConfig = .default,
                             /// The cloud tier's master switch (owner
                             /// directive, 2026-09-19) in the session's own
                             /// settings. `nil` leaves the key absent — the
                             /// household that has never chosen — which is the
                             /// state the switch's own scenarios read the
                             /// config default from.
                             geminiCloudEnabled: Bool? = true,
                             /// The feature's master switch (review finding 1)
                             /// in the session's own settings. **On by default
                             /// here** — every scenario in this suite that
                             /// predates the switch is about what a running
                             /// session does — while `nil` is the shipped state
                             /// (the key absent, the session refusing to open).
                             liveTranslateEnabled: Bool? = true,
                             /// The session's on-device brain, scripted. A
                             /// scenario about the *order* of the cascade hands
                             /// one in, so what the device is does not depend on
                             /// whatever assistant brains the host holds.
                             brain: LocalBrainTranslating? = nil,
                             /// The point, tap & ask session this host runs, when
                             /// the scenario is about the anchored box the focus
                             /// mode's two buttons sit on (Workstream B).
                             pointAsk: PointAskSessionDependencies? = nil) -> Harness {
        let parts = makeLiveTranslateSessionTestParts(authorization: authorization,
                                                      consent: consent,
                                                      configured: configured,
                                                      configurationError: configurationError,
                                                      dictionary: dictionary ?? [:],
                                                      transport: transport,
                                                      locale: locale,
                                                      extractMode: extractMode,
                                                      config: config,
                                                      brain: brain,
                                                      geminiCloudEnabled: geminiCloudEnabled,
                                                      pointAsk: pointAsk,
                                                      liveTranslateEnabled: liveTranslateEnabled)
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
    /// `AVCaptureVideoDataOutput` uses — and waits for the whole cycle it
    /// triggers: the pass runs, the tap is free for the next sample, and the
    /// publication this pass produced has reached the session model.
    @MainActor
    private func deliverPass(_ harness: Harness,
                             width: Int = 1920,
                             height: Int = 1080,
                             file: StaticString = #filePath,
                             line: UInt = #line) async throws {
        let passesBefore = harness.engine.recognizeCallCount
        let publishedBefore = harness.model.publication?.sequence ?? 0
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
        // Free is not *finished*: the flag is cleared the moment Vision returns
        // (`LiveTranslationPipeline.ingest`, the statement after
        // `recogniser.recognize`), and the stabiliser's consumption and the
        // publication the model renders both follow it — `publish()` is the
        // last thing the cycle does. A caller that reads the model as soon as
        // the flag clears is racing that hop across two actors and reads the
        // previous cycle's publication whenever the pipeline's own work between
        // them runs long. So the wait is for this pass's publication to land on
        // the model, ordered by the publication sequence (AM-6): every
        // successful pass advances it, and only a suppressed jitter-only cycle
        // does not — which identical scripted boxes cannot be.
        await waitUntil("the pass's publication to reach the session", file: file, line: line) {
            (harness.model.publication?.sequence ?? 0) > publishedBefore
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

    // MARK: - The cloud tier's master switch (owner directive, 2026-09-19)

    /// A household that has never touched the switch opens with it off, and
    /// what the model shows is what the store holds — the directive's "does
    /// not cascade" at the session boundary.
    @MainActor
    func testTheModelOpensWithTheCloudSwitchOffUntilTheStoreSaysOtherwise() async {
        let untouched = makeHarness(geminiCloudEnabled: nil)
        XCTAssertFalse(untouched.model.geminiCloudEnabled,
                       "the cloud tier must not cascade for a household that never opted in")
        XCTAssertFalse(LiveTranslateConfig.default.geminiCloudEnabledDefault,
                       "the value comes from the config's nominal default, pinned there")

        let turnedOn = makeHarness(geminiCloudEnabled: true)
        XCTAssertTrue(turnedOn.model.geminiCloudEnabled,
                      "a session opens with the stored opt-in, not with the shipped default")
    }

    /// The write path: one setter, one key, and the model mirrors what was
    /// stored rather than keeping a copy of its own — the same shape the
    /// display preference has.
    @MainActor
    func testTheCloudSwitchWritesThroughTheOneSetterAndLeavesTheDisplayPreferenceAlone() async {
        let harness = makeHarness(geminiCloudEnabled: nil)
        XCTAssertFalse(harness.model.geminiCloudEnabled)

        harness.model.setGeminiCloudEnabled(true)
        XCTAssertTrue(harness.model.geminiCloudEnabled)
        XCTAssertTrue(harness.defaults.bool(forKey: LiveTranslateSettings.geminiCloudEnabledKey),
                      "the model wrote the declared key, not a private copy")
        XCTAssertFalse(harness.model.alwaysShowOriginal,
                       "the two settings are independent: one does not move the other")

        harness.model.setGeminiCloudEnabled(false)
        XCTAssertFalse(harness.model.geminiCloudEnabled)
        XCTAssertFalse(harness.defaults.bool(forKey: LiveTranslateSettings.geminiCloudEnabledKey),
                       "opting back out persists too")
    }

    /// The row's copy, from the same surface the Settings leaf draws: both
    /// languages resolve, and the switch's own value is what the row shows.
    @MainActor
    func testTheCloudSwitchSurfaceDrawsTheStoredValueInBothLanguages() async {
        let harness = makeHarness(geminiCloudEnabled: true)
        let surface = harness.model.geminiCloudToggleSurface
        XCTAssertTrue(surface.isOn, "the row shows the stored value")
        XCTAssertFalse(surface.title.isEmpty)
        XCTAssertFalse(surface.note.isEmpty)
        XCTAssertTrue(surface.title.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) },
                      "Nepali first (T-005)")

        // The same surface type the row and the Settings leaf build, in the
        // other language: one vocabulary, two languages.
        let english = GeminiCloudToggleSurface(isOn: true, locale: Locale(identifier: "en"))
        XCTAssertNotEqual(english.title, surface.title, "the title follows the active language")
        XCTAssertNotEqual(english.note, surface.note, "so does the line under it")

        // A value, re-derived from the model's own state on every read: the
        // row cannot show a frame-old copy of the switch.
        XCTAssertEqual(surface, harness.model.geminiCloudToggleSurface)
    }

    /// The wiring, end to end through the interface the Settings leaf uses:
    /// with the switch off nothing is sent and nobody is prompted; turning it
    /// on in a running session opens the pre-existing consent-gated path for
    /// the next question, with no restart.
    @MainActor
    func testTheSwitchReachesTheRunningPipelineWithoutARestart() async throws {
        // Unpaced — both pacing clocks at zero — because this scenario is
        // about the switch reaching the RUNNING pipeline, not about the
        // pacing: this suite's passes all happen inside a few hundred
        // milliseconds of wall time, so a scenario that delivers its frames
        // and waits would be measuring the shipped 1.5 s dispatch interval
        // and 8 s brain interval instead of the wiring it is named for. One
        // helper, owned by the suite that needs it most
        // (`LiveTranslationPipelineTests`, whose twin scenario is unpaced for
        // the same reason); the shipped values stay pinned by
        // `LiveTranslateConfigTests`.
        let harness = makeHarness(consent: true, configured: true,
                                  transport: Self.respondingTransport(),
                                  config: LiveTranslationPipelineTests.unpacedDispatchConfig(),
                                  geminiCloudEnabled: false)
        reportLayout(harness)
        harness.engine.regions = [detected(cloudText)]
        await harness.model.start()
        try await deliverPasses(2, in: harness)
        await waitUntil("the closed switch to settle the region") {
            guard let publication = harness.model.publication,
                  let region = publication.regions.first(where: { $0.text == self.cloudText }) else {
                return false
            }
            if case .degraded = publication.result(for: region).outcome { return true }
            return false
        }

        XCTAssertEqual(harness.transport.requestCount, 0,
                       "the switch off means the tier is never asked")
        XCTAssertFalse(harness.model.consent.isPromptPresented,
                       "and the household is not prompted about a tier it did not turn on")

        // The Settings leaf's write, through the model's own entry point.
        harness.model.setGeminiCloudEnabled(true)
        // The push into the pipeline is a task of its own (the same shape the
        // display preference uses), so the next frames are delivered after that
        // hop has had its window.
        try? await Task<Never, Never>.sleep(for: .milliseconds(60))

        harness.engine.regions = [detected(cloudText),
                                  detected(secondCloudText, box: (0.1, 0.5, 0.5, 0.6))]
        try await deliverPasses(2, in: harness)
        await waitUntil("the new question to be answered through the cloud") {
            guard let publication = harness.model.publication,
                  let region = publication.regions.first(where: { $0.text == self.secondCloudText }) else {
                return false
            }
            if case .resolved = publication.result(for: region).outcome { return true }
            return false
        }

        let publication = try XCTUnwrap(harness.model.publication)
        let region = try XCTUnwrap(publication.regions.first { $0.text == secondCloudText })
        guard case .resolved(_, _, let tier) = publication.result(for: region).outcome else {
            return XCTFail("a question asked with the switch on resolves through the gate")
        }
        XCTAssertEqual(tier, .cloud)
        XCTAssertEqual(harness.transport.requestCount, 1,
                       "the switch opening is one question, and the string that degraded while "
                       + "it was closed is not re-sent")
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

    // MARK: - The OCR-first extract mode (owner verdict, 2026-09-18)

    /// The mode as the session says it, which is the only place the view learns
    /// it: a session opens showing the recognized text (the shipped default),
    /// nothing is translated until the elder taps a block, the tap translates
    /// **that** block, and the toggle puts the translated view back on screen.
    ///
    /// The pipeline suite pins the work; this pins the session's own three
    /// statements about it — `isExtracting`, `translateAllSurface` and
    /// `translateRegion` — because the mode is only real if what the control
    /// shows, what the surface renders and what the pipeline is willing to
    /// start are the same value.
    @MainActor
    func testTheSessionOpensShowingTheRecognizedTextAndTranslatesOnlyWhatIsTapped() async throws {
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation],
                                  extractMode: true)
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPasses(3, in: harness)

        XCTAssertTrue(harness.model.isExtracting,
                      "a session opens in extract mode (owner verdict, 2026-09-18)")
        XCTAssertFalse(harness.model.translateAllSurface.isTranslatingOn,
                       "the control shows the mode that is on, not the one it would switch to")
        let extracting = try XCTUnwrap(harness.model.publication)
        XCTAssertTrue(extracting.policy.extractionMode,
                      "the published policy is the mode the placements were measured under")
        XCTAssertEqual(harness.model.surface.policy, extracting.policy)
        XCTAssertEqual(harness.model.surface.placements.first?.lines.map(\.text), [curatedText],
                       "what the view renders is the recognized text, in place")

        // The curated table could answer this string, and does not: in this
        // mode nothing is translated that nobody asked about.
        let sign = try XCTUnwrap(extracting.regions.first { $0.text == curatedText })
        guard case .pending = extracting.result(for: sign).outcome else {
            return XCTFail("extract mode resolved a region the elder did not tap")
        }
        XCTAssertEqual(harness.transport.requestCount, 0)

        // The tap — one block, the device's own answer.
        harness.model.translateRegion(sign.id)
        await waitUntil("the tapped block to be translated") {
            guard let publication = harness.model.publication,
                  let region = publication.regions.first(where: { $0.text == self.curatedText }),
                  case .resolved = publication.result(for: region).outcome else { return false }
            return true
        }
        let answered = try XCTUnwrap(harness.model.publication)
        let tapped = try XCTUnwrap(answered.regions.first { $0.text == curatedText })
        XCTAssertEqual(answered.result(for: tapped),
                       .resolved(originalText: curatedText,
                                 translation: curatedTranslation,
                                 tier: .dictionary))
        XCTAssertEqual(answered.placements.first?.lines.first?.text, curatedTranslation,
                       "an answered block draws its translation where it stood")
        XCTAssertEqual(harness.transport.requestCount, 0,
                       "the device answered, so nothing was asked of the network")

        // The toggle: the translated view, and the answer already paid for is
        // not thrown away with it.
        harness.model.setExtractMode(false)
        await waitUntil("the translated view") {
            harness.model.publication?.policy.extractionMode == false
        }
        let translated = try XCTUnwrap(harness.model.publication)
        XCTAssertFalse(harness.model.isExtracting)
        XCTAssertTrue(harness.model.translateAllSurface.isTranslatingOn,
                      "the control now shows the translated view is on")
        let answeredInTranslatedView = try XCTUnwrap(translated.regions.first { $0.text == curatedText })
        XCTAssertEqual(translated.result(for: answeredInTranslatedView).sourceTier, .dictionary,
                       "leaving extract mode discarded an answer the elder already had")
    }

    // MARK: - The warden's notices reach the screen (owner directive, 2026-09-19)

    /// The two moments the elder is owed an explanation for — a model load the
    /// camera feature is paying for, and a model the voice stack has taken —
    /// are pushed by `LocalBrainTranslationTier` and land on this model's
    /// published surface. What the tier's own suite proves is that it *pushes*;
    /// what this section proves is that what it pushes becomes a sentence on
    /// screen and then goes away on its own.
    ///
    /// The sink under test is the one the session actually installs
    /// (`wardenNoticeSink(for:)`, handed to the pipeline in `start()`), not a
    /// re-written copy of it — so a test that passes here passes for the
    /// reason the feature works.

    /// Idle is the state the banner must never be in: a session that has said
    /// nothing has nothing to render, and the view draws no banner at all.
    @MainActor
    func testASessionWithNoNoticeRendersNoBanner() async throws {
        let harness = makeHarness()
        await harness.model.start()

        XCTAssertNil(harness.model.wardenNotice)
        XCTAssertNil(harness.model.wardenNoticeSurface,
                     "idle is the absence of a sentence, not an empty one")
        await harness.model.close()
    }

    /// The whole chain, through the sink the tier is given: a load announced →
    /// the model's published state → the sentence the banner draws, resolved
    /// from the catalog in the language the session is running in.
    @MainActor
    func testALoadAnnouncedThroughTheSinkBecomesTheCatalogSentenceOnScreen() async throws {
        let harness = makeHarness(locale: nepali)
        await harness.model.start()

        // Exactly what the tier does, on the tier's own thread: the sink is
        // `@Sendable` and its caller may be any actor.
        let sink = LiveTranslateSessionModel.wardenNoticeSink(for: harness.model)
        sink(.loadingModel)

        await waitUntil("the announced load to reach the model") {
            harness.model.wardenNotice == .loadingModel
        }
        let surface = try XCTUnwrap(harness.model.wardenNoticeSurface)
        XCTAssertEqual(surface.notice, .loadingModel)
        XCTAssertEqual(surface.copy,
                       L10n.str(LocalBrainWardenNotice.loadingModel.copyKey, locale: nepali),
                       "the banner draws the catalog's sentence, not the key and not a literal")
        XCTAssertNotEqual(surface.copy, LocalBrainWardenNotice.loadingModel.copyKey,
                          "the catalog key is not the elder-facing words")
        XCTAssertNotEqual(surface.copy, LocalBrainWardenNotice.loadingModel.rawValue,
                          "the case name is not the elder-facing words")
        XCTAssertTrue(surface.copy.contains("पर्खनुहोस्"),
                      "the owner asked for 'hold on a sec' in both languages: \(surface.copy)")

        await harness.model.close()
        XCTAssertNil(harness.model.wardenNotice)
    }

    /// The same push in an English session renders the English sentence, and
    /// differs from the Nepali one — the copy is resolved in the *active*
    /// language rather than in a language fixed at build time.
    @MainActor
    func testTheBannerSaysTheSameMomentInTheActiveLanguage() async throws {
        let english = Locale(identifier: "en")
        let harness = makeHarness(locale: english)
        await harness.model.start()

        LiveTranslateSessionModel.wardenNoticeSink(for: harness.model)(.offloadedForVoiceTurn)
        await waitUntil("the hand-off to reach the model") {
            harness.model.wardenNotice == .offloadedForVoiceTurn
        }
        let surface = try XCTUnwrap(harness.model.wardenNoticeSurface)
        XCTAssertEqual(surface.copy,
                       L10n.str(LocalBrainWardenNotice.offloadedForVoiceTurn.copyKey,
                                locale: english))
        XCTAssertTrue(surface.copy.lowercased().contains("voice"),
                      "the sentence names what took the model: \(surface.copy)")
        XCTAssertNotEqual(surface.copy,
                          WardenNoticeSurface(notice: .offloadedForVoiceTurn, locale: nepali).copy,
                          "the two languages must not render the same words")

        await harness.model.close()
    }

    /// A status, not a modal: nothing is tapped, nothing is acknowledged, and
    /// the sentence takes itself down after `wardenNoticeDismissSeconds`.
    @MainActor
    func testANoticeDismissesItselfAfterTheConfiguredWindow() async throws {
        var config = LiveTranslateConfig.default
        config.wardenNoticeDismissSeconds = 0.2
        let harness = makeHarness(config: config)
        await harness.model.start()

        LiveTranslateSessionModel.wardenNoticeSink(for: harness.model)(.loadingModel)
        await waitUntil("the notice to appear") {
            harness.model.wardenNotice == .loadingModel
        }
        XCTAssertNotNil(harness.model.wardenNoticeSurface,
                        "the notice is on screen the moment it arrives, not after a delay")

        await waitUntil("the notice to take itself down") {
            harness.model.wardenNotice == nil
        }
        XCTAssertNil(harness.model.wardenNoticeSurface,
                     "a dismissed notice draws no banner at all")

        await harness.model.close()
    }

    /// Two moments can land close together (a load announced, then the handle
    /// taken). The newer sentence replaces the older one and gets its own full
    /// window — the older notice's timer must not blank it early.
    @MainActor
    func testASecondNoticeReplacesTheFirstAndKeepsItsOwnWindow() async throws {
        var config = LiveTranslateConfig.default
        config.wardenNoticeDismissSeconds = 0.3
        let harness = makeHarness(config: config)
        await harness.model.start()

        let sink = LiveTranslateSessionModel.wardenNoticeSink(for: harness.model)
        sink(.loadingModel)
        sink(.offloadedForVoiceTurn)
        await waitUntil("the newer notice to replace the older one") {
            harness.model.wardenNotice == .offloadedForVoiceTurn
        }
        XCTAssertEqual(harness.model.wardenNoticeSurface?.notice, .offloadedForVoiceTurn,
                       "the sentence on screen is the newer moment's")

        await waitUntil("the newer notice to take itself down") {
            harness.model.wardenNotice == nil
        }
        await harness.model.close()
    }

    /// Closing takes the sentence with it, exactly as it takes the spinner and
    /// the held picture: nothing a closed session was saying may outlive it.
    @MainActor
    func testClosingTheSessionTakesANoticeDownWithIt() async throws {
        // Long enough that the notice would still be up when the close runs:
        // what is asserted is the teardown, not the timer.
        var config = LiveTranslateConfig.default
        config.wardenNoticeDismissSeconds = 600
        let harness = makeHarness(config: config)
        await harness.model.start()

        LiveTranslateSessionModel.wardenNoticeSink(for: harness.model)(.loadingModel)
        await waitUntil("the notice to appear") {
            harness.model.wardenNotice == .loadingModel
        }

        await harness.model.close()
        XCTAssertNil(harness.model.wardenNotice)
        XCTAssertNil(harness.model.wardenNoticeSurface)

        // A notice pushed after close is dropped rather than painted onto a
        // session that has ended.
        LiveTranslateSessionModel.wardenNoticeSink(for: harness.model)(.offloadedForVoiceTurn)
        try await Task<Never, Never>.sleep(for: .milliseconds(50))
        XCTAssertNil(harness.model.wardenNotice)
    }

    // MARK: - The feature's master switch (review finding 1)

    /// The switch's production reader: the session's own door. Nothing is
    /// built, nothing starts and nothing is asked of the camera while the
    /// household has the feature off — and off is a **stored** answer now
    /// (review round 2, finding 1), not the absent key.
    @MainActor
    func testTheSessionRefusesToOpenWhileTheFeatureSwitchIsOff() async throws {
        // The opt-out, written by whoever the Settings leaf hands the choice
        // to. An absent key is the other test below.
        let harness = makeHarness(liveTranslateEnabled: false)
        XCTAssertFalse(harness.model.liveTranslateEnabled,
                       "the model reads the setting, and a stored false closes the door")

        await harness.model.start()

        XCTAssertEqual(harness.model.phase, .idle,
                       "a switched-off feature opens no session: no camera, no pass, no send")
        XCTAssertEqual(harness.log.count(of: "camera.start"), 0,
                       "the camera is never started — nothing is built to start it")
        XCTAssertNil(harness.model.publication)

        // The elder turns it on. The refusal was a *deferral*: the same model
        // opens, with no second session and no relaunch.
        harness.model.setLiveTranslateEnabled(true)
        XCTAssertTrue(harness.model.liveTranslateEnabled,
                      "the model reads the setting back, not the argument")

        await harness.model.start()

        XCTAssertEqual(harness.model.phase, .running)
        XCTAssertEqual(harness.log.count(of: "camera.start"), 1,
                       "the camera starts once the feature is on")
    }

    /// The other half of the same door, and the merge-safety decision itself
    /// (review round 2, finding 1): an **untouched** switch opens the session,
    /// because the nominal default is what master shipped. This is also the
    /// test that pins the getter's shape — a `defaults.bool(forKey:)` without
    /// the presence check reads an absent key as `false` and would leave the
    /// feature dark with no copy to explain it, which is the hazard the
    /// default exists to avoid.
    @MainActor
    func testAnUntouchedFeatureSwitchOpensTheSession() async throws {
        let harness = makeHarness(liveTranslateEnabled: nil)
        XCTAssertTrue(harness.model.liveTranslateEnabled,
                      "an absent key reads the config's nominal default, which is on")

        await harness.model.start()

        XCTAssertEqual(harness.model.phase, .running)
        XCTAssertEqual(harness.log.count(of: "camera.start"), 1,
                       "an untouched switch is not a closed door")
    }

    /// And the switch is the *door*, not an off-ramp: a session already open is
    /// not torn down by a later write. The surface that says why the feature is
    /// closed (and the spoken line that offers Settings) belongs to the
    /// workstream that owns the UI; this suite pins the Services-side half.
    @MainActor
    func testTurningTheSwitchOffDoesNotTearDownASessionAlreadyOpen() async throws {
        let harness = makeHarness(liveTranslateEnabled: true)
        await harness.model.start()
        XCTAssertEqual(harness.model.phase, .running)

        harness.model.setLiveTranslateEnabled(false)

        XCTAssertFalse(harness.model.liveTranslateEnabled, "the switch itself moves")
        XCTAssertEqual(harness.model.phase, .running,
                       "an open session stays open: the switch decides whether a session opens")
    }

    // MARK: - The focus read's identity (review finding 7)

    /// A tap that supersedes an in-flight read must neither install the picture
    /// the *older* tap asked for nor end the wait the newer tap is still
    /// inside — the two halves of the read's identity check (review finding 7).
    ///
    /// The device is **gated** rather than slow (`RecordingBrain.heldCalls`),
    /// which is what makes the interleaving a fixture instead of a race: the
    /// elder's first tap reaches the device and is held there, the second tap
    /// is held behind it, and the test then lets the *superseded* read's
    /// generation through while the read that replaced it is still suspended.
    /// The superseded read really does finish its work — its generation came
    /// back through the gate and its plan settled with its answer — so "it
    /// installed nothing" is a claim about the identity check, not about work
    /// that never ran. A second tap cancels the first *task*, but the plan is
    /// an unstructured task's and is not a child of the tap's: the cancellation
    /// is cooperative and the read answers what it was asked.
    ///
    /// Which is why the wait for the superseded read's tail is the *inverse*
    /// one: that tail announces nothing, that being the rule. The newest read
    /// stays at its gate for the whole window, so nothing else in the session
    /// can move the two observables, and the premise is asserted inside the
    /// window rather than assumed.
    @MainActor
    func testASupersededFocusedReadCannotInstallItsOwnPicture() async throws {
        // The pacing clock is the harness's, not this test's subject: the live
        // pass's own device attempt stamps it, and the shipped
        // `brainAttemptMinInterval` (8 s) would then refuse *every* focused
        // read's device stage — the reads would be answered elsewhere and never
        // reach the gate this test is about.
        var config = LiveTranslateConfig.default
        config.brainAttemptMinInterval = 0
        let brain = RecordingBrain()
        brain.answers = [curatedText: curatedTranslation]
        let harness = makeHarness(consent: true,
                                  configured: true,
                                  transport: Self.respondingTransport(),
                                  config: config,
                                  brain: brain)
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPass(harness)

        // The live pass asks the device too, and it is answered: the gate is
        // armed only once nothing is in flight, so the two reads are the only
        // generations that can hold a place in it.
        await waitUntil("the live pass's device attempt to come and go") {
            brain.generationsAnswered >= 1 && brain.generationsAnswered == brain.calls.count
        }

        // Every generation from here on is held, and the test decides the order
        // they come back in.
        let supersededText = "Prescription line one and its instructions"
        let newestText = "A different line to read"
        brain.answers = [supersededText: "ने:superseded", newestText: "ने:newest"]
        brain.heldCalls = 2

        // The elder's first tap: its crop is read and its plan reaches the
        // device, which holds it.
        harness.engine.regions = [detected(supersededText)]
        tapFocused(harness)
        await waitUntil("the superseded read's generation to reach the gate") {
            brain.waitingAtGate == 1 && brain.calls.last == [supersededText]
        }

        // The second tap, on another line, one wait behind it at the same gate.
        harness.engine.regions = [detected(newestText)]
        tapFocused(harness)
        await waitUntil("the newest read's generation to reach the gate behind it") {
            brain.waitingAtGate == 2 && brain.calls.last == [newestText]
        }

        // The superseded read is let through *while the newest read is still
        // held*: its answer comes back, its plan settles, and its tail —
        // guarded by nothing but the read's identity — reaches the session.
        brain.releaseOneHeldCall()
        await waitUntil("the superseded read's generation to come back") {
            brain.generationsThroughTheGate == 1
        }

        // A bounded window in which the replaced read's effects *would* have
        // shown up: the picture it asked for on the surface, and the wait it
        // did not own ended.
        for _ in 0..<20 {
            XCTAssertEqual(brain.waitingAtGate, 1, "the newest read is held throughout")
            if harness.model.focusedCapture != nil || !harness.model.focusInProgress { break }
            try await Task<Never, Never>.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(harness.model.focusedCapture,
                     "the superseded read must not install the picture it was asked for, "
                     + "however complete its answer is")
        XCTAssertTrue(harness.model.focusInProgress,
                      "and it must not end the wait the newest tap is still inside")

        // The newest read's own answer: the picture the elder asked for last,
        // installed by the read that still owns the wait.
        brain.releaseOneHeldCall()
        await waitUntil("the newest read's picture to be packed") {
            harness.model.focusedCapture?.publication.regions.first?.text == newestText
        }
        XCTAssertEqual(harness.model.focusedCapture?.publication.regions.count, 1)
        XCTAssertFalse(harness.model.focusInProgress,
                       "the read that owns the wait is the one that ends it")
        XCTAssertEqual(brain.generationsThroughTheGate, 2)
    }

    // MARK: - The display preference on a packed capture (review finding 12)

    /// The show-original toggle re-measures a packed focused capture, exactly as
    /// it re-measures a held frame: the strings are read and answered already,
    /// so the only thing a display preference may change is where they are
    /// drawn. A toggle that stopped working on the one picture the elder
    /// pointed at would be the lie about a display preference the feature must
    /// not tell.
    @MainActor
    func testTheShowOriginalToggleRePlacesAPackedFocusedCapture() async throws {
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPass(harness)

        tapFocused(harness)
        await waitUntil("the focused read to pack its picture") {
            harness.model.focusedCapture != nil
        }
        let packed = try XCTUnwrap(harness.model.focusedCapture)
        XCTAssertFalse(packed.publication.policy.alwaysShowOriginal,
                       "the session opens showing the translation")
        let passesWhenPacked = harness.engine.recognizeCallCount

        harness.model.toggleAlwaysShowOriginal()

        await waitUntil("the packed capture to be re-measured under the new policy") {
            harness.model.focusedCapture?.publication.policy.alwaysShowOriginal == true
        }
        let rePlaced = try XCTUnwrap(harness.model.focusedCapture)

        XCTAssertEqual(rePlaced.publication.regions.map(\.text),
                       packed.publication.regions.map(\.text),
                       "the same read's strings")
        XCTAssertEqual(rePlaced.pixelRect, packed.pixelRect,
                       "the same crop, re-measured — not a second read")
        XCTAssertEqual(rePlaced.rows.count, packed.rows.count,
                       "the card is rebuilt with the placement, so the two cannot disagree")
        XCTAssertEqual(harness.engine.recognizeCallCount, passesWhenPacked,
                       "re-placing is placement: no second pass and no second answer")
    }

    // MARK: - The rect belongs to a frame (review round 2, finding 5)

    /// A rect is a *place on a picture*: a rect measured against one frame and
    /// cropped from another is a crop of a region nobody pointed at. The
    /// session therefore crops the frame the rect was measured on — the
    /// `measuredOn` seam the anchor's caller hands over — and not whatever the
    /// camera has delivered since.
    @MainActor
    func testAFocusedReadCropsTheFrameItsRectWasMeasuredOn() async throws {
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPass(harness)

        // The frame the rect will be measured against, and then a later,
        // differently-sized one: what `latestFrame` holds at the tap is no
        // longer the frame the rect belongs to.
        let anchored = try XCTUnwrap(harness.model.anchoredFrame)
        try await deliverPass(harness, width: 640, height: 480)

        tapFocused(harness, measuredOn: anchored)
        await waitUntil("the focused read to pack its picture") {
            harness.model.focusedCapture != nil
        }

        let capture = try XCTUnwrap(harness.model.focusedCapture)
        XCTAssertEqual(capture.pixelRect,
                       CGRect(x: 192, y: 108, width: 768, height: 108),
                       "the box is measured on the frame the caller named, not on the "
                       + "frame the camera delivered in the meantime (which would be 64x48)")
    }

    // MARK: - The answer to a prompt reaches the standing capture (review round 2, finding 3)

    /// A focused read whose strings reached the consent prompt leaves its card
    /// saying "translating…" — nothing else can be said, the ask is open. The
    /// elder's answer releases the ask and the answers land in the ledger, and
    /// the picture they are looking at is where they must appear: without the
    /// re-pack the card stayed unanswerable and the only way to see the answer
    /// was a second tap, which re-cropped and re-read the page for the same
    /// ledger — the read paid for twice.
    @MainActor
    func testAnsweringThePromptRepacksTheStandingFocusedCapture() async throws {
        // A device with no model installed, so the read's device stage is an
        // answer and not a generation: what this scenario is about is where an
        // answer goes once the question is answered.
        //
        // And the brain's clock is not this scenario's subject either
        // (`brainAttemptMinInterval` is a pacing rule with its own tests): a
        // capture the clock refuses is released, unasked, for a later plan —
        // which is a different scenario's question, and one that would leave
        // this test reading a card nothing had asked about.
        let brain = RecordingBrain()
        brain.unavailable = true
        var config = LiveTranslateConfig.default
        config.brainAttemptMinInterval = 0
        let harness = makeHarness(consent: false,
                                  configured: true,
                                  transport: Self.respondingTransport(),
                                  config: config,
                                  brain: brain)
        reportLayout(harness)
        // The live picture carries nothing to read, so the one ask in this
        // session — and so the one question the prompt is about — is the tap's.
        harness.engine.regions = []
        await harness.model.start()
        try await deliverPass(harness)

        // The tap reads a sentence-class string, which only the cloud can
        // answer — and there is no consent yet, so the ask is held and the
        // question is on screen.
        harness.engine.regions = [detected(cloudText)]
        tapFocused(harness)
        await waitUntil("the focused read to pack its picture") {
            harness.model.focusedCapture != nil
        }
        let held = try XCTUnwrap(harness.model.focusedCapture)
        XCTAssertTrue(harness.model.consent.isPromptPresented,
                      "the held ask is the question the elder is being asked")
        XCTAssertEqual(Self.resolvedTranslations(in: held), [],
                       "nothing is translated while the question is open")
        XCTAssertTrue(held.publication.outcomes.values.contains { outcome in
            if case .pending = outcome.outcome { return true }
            return false
        }, "and the card says so rather than claiming an answer")

        // The elder answers. The answer releases the recorded ask, and the
        // standing card renders it — no second tap, no second read.
        let readsWhenHeld = harness.engine.recognizeCallCount
        harness.model.grantCloudConsent()

        await waitUntil("the released answer to reach the standing card") {
            !Self.resolvedTranslations(in: harness.model.focusedCapture).isEmpty
        }
        let answered = try XCTUnwrap(harness.model.focusedCapture)
        XCTAssertEqual(Self.resolvedTranslations(in: answered), ["ने:" + cloudText])
        XCTAssertEqual(harness.transport.requestCount, 1,
                       "the released ask went to the tier it was waiting on, once")
        XCTAssertEqual(answered.pixelRect, held.pixelRect,
                       "the answer is drawn onto the picture the elder pointed at")
        XCTAssertEqual(harness.engine.recognizeCallCount, readsWhenHeld,
                       "a render of an answer the session already paid for is not a second read")
    }

    /// The translations a packed capture is showing, source text aside — the
    /// one thing these two scenarios read off a capture.
    private static func resolvedTranslations(in capture: LiveTranslateFocusedCapture?)
        -> [String] {
        guard let capture else { return [] }
        return capture.publication.outcomes.values.compactMap { result in
            guard case .resolved(_, let translation, _) = result.outcome else { return nil }
            return translation
        }.sorted()
    }

    /// One tap on the focused path's own geometry: the box the elder pointed
    /// at, with the pixel rect left to the model to derive **from the frame the
    /// caller measured it on** — the anchored frame by default, exactly as the
    /// live view hands it over.
    @MainActor
    private func tapFocused(_ harness: Harness, measuredOn frame: CameraFrame? = nil) {
        harness.model.translateFocusedRegion(
            box: NormalizedBox(xMin: 0.1, yMin: 0.1, xMax: 0.5, yMax: 0.2),
            pixelRect: .null,
            measuredOn: frame ?? harness.model.anchoredFrame)
    }

    // MARK: - "translate here" (Workstream B, the voice path)

    /// A label-class line the curated table does not answer: the shape the
    /// on-device model leads for in the *live* cycle, which is the generation
    /// that stamps the brain's clock.
    private let liveLabelText = "Push the green button"
    /// The crop's own string — a different label-class line, so the live
    /// cycle's attempt has not been paid for it.
    private let cropLabelText = "Pull the red lever"

    /// The point, tap & ask composition this host runs, assembled the way the
    /// PointAsk suites assemble it (`PointAskAutoAnalyzeOnAnchorTests`): the
    /// real gate, settings, cache and client over the shipped seams, with the
    /// recognisers scripted. Copied rather than shared for the reason the
    /// polling helper above is — that suite's factory is private to its file —
    /// and it is the *host*'s copy that matters here: the session builds its
    /// own quiet model from it.
    @MainActor
    private func makePointAskDependencies() -> PointAskSessionDependencies {
        let bus = LiveTranslateSanitisingBus()
        let config = PointAskConfig()
        let suiteName = "livetranslate.pointask.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        suiteNames.append(suiteName)
        let configStore = GeminiConfigStore(storage: GeminiInMemoryStorage())
        configStore.save("fake-key")
        return PointAskSessionDependencies(
            locale: nepali,
            consentGate: PointAskConsentGate(storage: LabelTranslationCacheTestStorage(),
                                             config: config,
                                             observabilityBus: bus),
            settings: PointAskSettings(defaults: defaults, config: config),
            cache: LabelTranslationCache(storage: LabelTranslationCacheTestStorage(),
                                         observabilityBus: bus,
                                         dictionary: [:]),
            client: GeminiClient(configStore: configStore,
                                 observabilityBus: bus,
                                 transport: FakeGeminiTransport()),
            objectEngine: StubPointAskObjectEngine(),
            ocrEngine: StubPointAskOCREngine(),
            observabilityBus: bus,
            config: config,
            speak: { _ in })
    }

    /// **The words and the touch are one path.** "translate here" calls the same
    /// `translateFocusedRegion(box:pixelRect:measuredOn:)` the Translate button
    /// calls, so with an anchor on screen "here" is the box the elder pointed
    /// at — the most specific answer available, and the one the button uses.
    @MainActor
    func testTranslateHereReadsTheBoxTheElderAnchored() async throws {
        let harness = makeHarness(pointAsk: makePointAskDependencies())
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPass(harness)

        // The elder taps the live picture. The host's own configuration keeps
        // the anchor quiet (the box is a *target*, not PointAsk's question), so
        // the box lands and nothing else runs. The anchor is resolved
        // *asynchronously* — PointAsk's tap hands the frame to a task and reads
        // the point on the main actor before the box exists — so the wait is
        // for the box, not for the call to return.
        harness.model.pointAsk?.handleTap(atNormalizedPoint: CGPoint(x: 0.5, y: 0.5))
        await waitUntil("the tap to land its anchored box") {
            harness.model.pointAsk?.anchoredTarget != nil
        }
        let anchor = try XCTUnwrap(harness.model.pointAsk?.anchoredTarget,
                                   "the tap lands a box for the focus flow to read")

        harness.model.translateHere()
        await waitUntil("the spoken focus read to pack its picture") {
            harness.model.focusedCapture != nil
        }

        let capture = try XCTUnwrap(harness.model.focusedCapture)
        let frame = try XCTUnwrap(harness.model.anchoredFrame)
        let box = anchor.box
        let size = frame.pixelSize
        XCTAssertEqual(capture.pixelRect,
                       CGRect(x: box.xMin * size.width,
                              y: box.yMin * size.height,
                              width: (box.xMax - box.xMin) * size.width,
                              height: (box.yMax - box.yMin) * size.height),
                       "the words mean the box the elder named with their finger")
    }

    /// With nothing anchored, "here" is the **middle of the picture the camera
    /// is aimed at** — the case that makes the command worth having: an elder
    /// holding the phone up has already said where, and a command that answered
    /// "tap it first" would require the very dexterity the voice path exists to
    /// avoid.
    @MainActor
    func testTranslateHereWithoutAnAnchorReadsTheMiddleOfThePicture() async throws {
        let harness = makeHarness()
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPass(harness)

        harness.model.translateHere()
        await waitUntil("the spoken focus read to pack its picture") {
            harness.model.focusedCapture != nil
        }

        let capture = try XCTUnwrap(harness.model.focusedCapture)
        let frame = try XCTUnwrap(harness.model.anchoredFrame)
        let size = frame.pixelSize
        // The session's **own** config's number (review finding: the injected
        // config on the session path), not the shipped static: a session driven
        // over its own numbers must place "here" by them, or the number the
        // suite arranged is one nothing consults.
        let inset = harness.model.spokenFocusBoxInset
        let expected = CGRect(x: inset * size.width,
                              y: inset * size.height,
                              width: (1 - 2 * inset) * size.width,
                              height: (1 - 2 * inset) * size.height)
        XCTAssertEqual(capture.pixelRect, expected,
                       "the middle half of each axis is the region — a region, not the "
                       + "whole picture, which is what keeps this the focus path")
        XCTAssertLessThan(capture.pixelRect.width, size.width)
        XCTAssertLessThan(capture.pixelRect.height, size.height)
    }

    /// A "translate here" that arrives before there is a picture is **held, not
    /// dropped**: the next frame the camera delivers is the one it meant. The
    /// window is short in practice, and handled because "practically never" is
    /// not "never" — a command that silently did nothing would be a stub.
    @MainActor
    func testTranslateHereBeforeTheFirstFrameIsAnsweredByThatFrame() async throws {
        let harness = makeHarness()
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]
        await harness.model.start()
        XCTAssertNil(harness.model.anchoredFrame, "nothing has been delivered yet")

        harness.model.translateHere()
        XCTAssertNil(harness.model.focusedCapture,
                     "no picture, no crop: the ask waits rather than reading the wrong thing")

        try await deliverPass(harness)

        await waitUntil("the held ask to be answered by the first delivered frame") {
            harness.model.focusedCapture != nil
        }
    }

    /// A closed session neither crops nor asks: the command passes through the
    /// same guard the button does, so the voice path cannot reach a session that
    /// has ended.
    @MainActor
    func testTranslateHereAfterCloseDoesNothing() async throws {
        let harness = makeHarness()
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPass(harness)
        await harness.model.close()

        harness.model.translateHere()
        try await Task<Never, Never>.sleep(for: .milliseconds(80))

        XCTAssertNil(harness.model.focusedCapture, "a closed session reads nothing")
        XCTAssertEqual(harness.sleeper.callCount, 0, "and schedules nothing")
    }

    // MARK: - The clock hold, taken (Workstream B, finding 5)

    /// **The stall this exists to end.** A crop read inside
    /// `brainAttemptMinInterval` of a live attempt is released by the plan — the
    /// card says "not right now" — and nothing else in the session would ever
    /// ask again: the live ticks behind the picture plan the *live* regions, not
    /// this crop's. So the session waits out the plan's own remaining time (the
    /// number the plan reports, not a constant here) and asks again, and the
    /// answer lands on the picture the elder is looking at.
    ///
    /// **The clock is a seam here, and the wait is where the test says it is.**
    /// The session's own `now` is injectable (`LiveTranslateSession
    /// Dependencies.now` — the same wall clock production gets, shiftable), so
    /// the interval is a whole number of seconds large enough that the crop
    /// read cannot fall outside it by accident, and the *test* opens the clock
    /// — from the wait's own hook — rather than sleeping the interval through
    /// and hoping the re-ask lands on the far side. What is asserted is
    /// therefore the shape: a wait was scheduled with the plan's remaining
    /// time, and the re-ask it led to settled what the first ask could not.
    @MainActor
    func testAFocusedReadTheBrainClockHoldsIsAskedAgainWhenTheClockOpens() async throws {
        let brain = RecordingBrain()
        var config = LiveTranslateConfig.default
        // Longer than any test can take to reach the crop, so "the crop read is
        // inside the plan's interval" is a fact about the scenario rather than
        // about the machine's speed.
        config.brainAttemptMinInterval = 30
        let harness = makeHarness(consent: true,
                                  configured: true,
                                  transport: Self.respondingTransport(),
                                  config: config,
                                  brain: brain)
        // The clock opens as the wait begins: the shift is what a real wait
        // would have bought, in no time at all. The wait then **parks**, so the
        // state the deferral left behind — one generation paid, one wait
        // scheduled, nothing asked since — is something the test reads rather
        // than races: released, the re-ask would land before the next
        // assertion.
        harness.sleeper.observe { harness.dateClock.advance(config.brainAttemptMinInterval + 1) }
        harness.sleeper.parksTheWait = true
        reportLayout(harness)
        // A label-class string no device layer can answer, so the live cycle is
        // the one that pays for a generation — and paying for it is what stamps
        // the clock the crop will run into. Three passes rather than one: a
        // region the stabiliser has only just seen is not yet a region worth
        // translating, and this scenario is not about that rule.
        harness.engine.regions = [detected(liveLabelText)]
        await harness.model.start()
        try await deliverPasses(3, in: harness)
        await waitUntil("the live cycle's own generation to be paid") {
            brain.generationsAnswered > 0
        }
        XCTAssertEqual(brain.calls.count, 1, "the live cycle asked the device, once")

        // The tap reads a *different* label-class line — one the live cycle has
        // not paid for — so the closed clock releases it rather than asking.
        harness.engine.regions = [detected(cropLabelText)]
        brain.answers[cropLabelText] = "रातो लिभर तान्नुहोस्"
        let readsBeforeTheCrop = harness.engine.recognizeCallCount
        tapFocused(harness)

        await waitUntil("the clock-held read to pack its picture and park its wait") {
            harness.model.focusedCapture != nil && harness.sleeper.callCount == 1
        }
        let held = try XCTUnwrap(harness.model.focusedCapture)
        XCTAssertFalse(held.deferredKeys.isEmpty,
                       "the clock released the crop's string rather than asking the device")
        XCTAssertTrue(Self.resolvedTranslations(in: held).isEmpty,
                      "and nothing about it is answered yet")
        XCTAssertEqual(brain.calls.count, 1, "no generation was spent inside the hold")

        let wait = try XCTUnwrap(harness.sleeper.waits.first,
                                 "one wait, scheduled by the read that was deferred")
        XCTAssertEqual(harness.sleeper.waits.count, 1, "and exactly one")
        XCTAssertGreaterThan(wait, 0)
        XCTAssertLessThanOrEqual(wait, config.brainAttemptMinInterval,
                                 "the wait is what remains of the plan's own interval")

        // The wait ends, into a clock the hook has opened.
        harness.sleeper.releaseParkedWait()
        await waitUntil("the re-ask to land when the clock opens") {
            !Self.resolvedTranslations(in: harness.model.focusedCapture).isEmpty
        }
        XCTAssertEqual(brain.calls.count, 2, "the re-ask is the second generation")
        XCTAssertEqual(Self.resolvedTranslations(in: harness.model.focusedCapture),
                       ["रातो लिभर तान्नुहोस्"],
                       "and its answer is what the elder is looking at")
        XCTAssertEqual(harness.engine.recognizeCallCount, readsBeforeTheCrop + 1,
                       "the re-ask is a plan, not a second read of the page: the crop is "
                       + "the only pass this whole scenario added")
    }

    /// **Only the clock's deferrals are waited on.** A string the plan's batch
    /// budget released was released for a budget reason, and the clock has
    /// nothing to say about it: a wait scheduled here would ask again for the
    /// same budget at the same price, and the re-ask would be the plan's own
    /// "no" repeated. The row keeps its sentence and the next tap is what asks
    /// again.
    ///
    /// The scenario is arranged so that the clock is genuinely *silent* rather
    /// than merely open: the live picture carries a sentence-class string the
    /// cloud leads for, so the device is never asked and no attempt is ever
    /// stamped — `brainClockRemaining()` is zero for want of an attempt, not
    /// for want of time. That is the state in which a re-drive scheduled off
    /// `deferredKeys` alone would ask again immediately, which is what the
    /// `waits` assertion below is the guard against.
    @MainActor
    func testABudgetDeferralSchedulesNoWaitAtAll() async throws {
        var config = LiveTranslateConfig.default
        // The narrow, device-only focus the cap exists for: the crop's one
        // string is released rather than asked about.
        config.focusMaxBatchCalls = 0
        let brain = RecordingBrain()
        let harness = makeHarness(consent: true,
                                  configured: true,
                                  transport: Self.respondingTransport(),
                                  config: config,
                                  brain: brain)
        reportLayout(harness)
        // The live picture carries a sentence-class string, which the cloud
        // leads for: no generation is paid, so nothing stamps the clock — the
        // deferral about to happen is the budget's and nobody else's.
        harness.engine.regions = [detected(cloudText)]
        await harness.model.start()
        try await deliverPass(harness)

        // The crop reads a **different** string: the same one would be answered
        // out of the session's memory, which is a resolution rather than a
        // deferral and would assert nothing about either clock.
        harness.engine.regions = [detected(cropLabelText)]
        tapFocused(harness)
        await waitUntil("the budget-held read to pack its picture") {
            harness.model.focusedCapture != nil
        }
        XCTAssertFalse(try XCTUnwrap(harness.model.focusedCapture).deferredKeys.isEmpty,
                       "the budget released the string rather than asking")

        // The re-drive decision runs on the read's own tail; give it the window
        // the clock's would have needed, then read what was scheduled.
        try await Task<Never, Never>.sleep(for: .milliseconds(150))

        XCTAssertEqual(harness.sleeper.callCount, 0,
                       "a budget is not a clock: nothing is asked again on a timer")
        XCTAssertTrue(brain.calls.isEmpty,
                      "and the released string was not bought twice")
    }

    /// A scheduled re-ask belongs to the picture it was scheduled for. The
    /// elder putting that picture down — "back to the camera" — takes the wait
    /// with it, so a re-ask that wakes up cannot plan strings for a crop nobody
    /// is looking at any more.
    @MainActor
    func testPuttingTheFocusedPictureDownCancelsTheScheduledReAsk() async throws {
        let brain = RecordingBrain()
        var config = LiveTranslateConfig.default
        config.brainAttemptMinInterval = 30
        let harness = makeHarness(consent: true,
                                  configured: true,
                                  transport: Self.respondingTransport(),
                                  config: config,
                                  brain: brain)
        // The wait **parks**, so the hold is still in flight when the elder puts
        // the picture down: the task is provably inside `sleepFor` at that
        // moment, which is what makes a cancellation observable rather than a
        // race between a wait that has already returned and a cancel.
        harness.sleeper.parksTheWait = true
        reportLayout(harness)
        harness.engine.regions = [detected(liveLabelText)]
        await harness.model.start()
        try await deliverPasses(3, in: harness)
        await waitUntil("the live cycle's own generation to be paid") {
            brain.generationsAnswered > 0
        }
        let generationsWhenHeld = brain.calls.count

        harness.engine.regions = [detected(cropLabelText)]
        brain.answers[cropLabelText] = "रातो लिभर तान्नुहोस्"
        tapFocused(harness)
        // The read packs its picture first and schedules the hold on its tail,
        // so the wait is for the *wait* — the crop standing on screen is not
        // yet the hold.
        await waitUntil("the clock-held read to pack its picture and take its wait") {
            harness.model.focusedCapture != nil && harness.sleeper.callCount == 1
        }
        XCTAssertFalse(try XCTUnwrap(harness.model.focusedCapture).deferredKeys.isEmpty,
                       "the clock released the crop's string")

        harness.model.returnToLive()
        XCTAssertNil(harness.model.focusedCapture, "the crop is put down")

        // The wait ends the way a real one would have — only late, and into a
        // session that has moved on. What the task does with that is the claim:
        // it looks at `Task.isCancelled` and asks nothing.
        harness.sleeper.releaseParkedWait()
        try await Task<Never, Never>.sleep(for: .milliseconds(150))

        XCTAssertEqual(brain.calls.count, generationsWhenHeld,
                       "the cancelled wait re-asked nothing: the picture it was for is gone")
        XCTAssertNil(harness.model.focusedCapture)
    }

    /// **The hold is bounded** (review finding 9). A clock that is still closed
    /// when the first re-ask runs is a clock that will refuse the second one
    /// too, so a session that re-armed on the clock alone would ask again for
    /// as long as the picture stood — with the interval in minutes on a device,
    /// a plan running for the rest of the session, for an answer the same
    /// pacing rule keeps refusing. `focusRedriveMaxAttempts` is the bound, and
    /// the config's number is the number of waits: the clock refused every
    /// re-ask here (it never opens — the interval is longer than this test
    /// lives), so what is asserted is the *bound* and not the clock.
    @MainActor
    func testTheClockHoldIsRetriedOnlyAsManyTimesAsTheConfigurationAllows() async throws {
        let brain = RecordingBrain()
        var config = LiveTranslateConfig.default
        config.brainAttemptMinInterval = 30
        config.focusRedriveMaxAttempts = 2
        let harness = makeHarness(consent: true,
                                  configured: true,
                                  transport: Self.respondingTransport(),
                                  config: config,
                                  brain: brain)
        reportLayout(harness)
        harness.engine.regions = [detected(liveLabelText)]
        await harness.model.start()
        try await deliverPasses(3, in: harness)
        await waitUntil("the live cycle's own generation to be paid") {
            brain.generationsAnswered > 0
        }
        let generationsWhenHeld = brain.calls.count

        harness.engine.regions = [detected(cropLabelText)]
        brain.answers[cropLabelText] = "रातो लिभर तान्नुहोस्"
        tapFocused(harness)

        // The sleeper returns at once, so the whole chain runs here: two waits
        // (the read's own and the first re-drive's), then the bound.
        await waitUntil("the re-drive chain to reach its bound") {
            harness.sleeper.callCount == config.focusRedriveMaxAttempts
        }
        // A third wait would appear in no time at all; give it the window anyway,
        // so "the bound is `maxAttempts`" is not an assertion about scheduling
        // luck.
        try await Task<Never, Never>.sleep(for: .milliseconds(200))

        XCTAssertEqual(harness.sleeper.callCount, config.focusRedriveMaxAttempts,
                       "the clock hold is bounded by the config, not by the clock")
        XCTAssertEqual(brain.calls.count, generationsWhenHeld,
                       "and every re-ask was refused by the clock: no generation was spent")
        XCTAssertFalse(try XCTUnwrap(harness.model.focusedCapture).deferredKeys.isEmpty,
                       "the string is still unasked, and the next tap is what asks again")
    }

    /// **A held picture refuses the read, out loud** (review finding 4). The
    /// freeze owns the surface: no box is drawn over a held frame and its card
    /// is the reading surface, so there is nothing on it to point at — and the
    /// focused read's only exit is `returnToLive`, which is the thaw, so a read
    /// started over a held frame would destroy the snapshot the elder is
    /// reading on its way to showing its own picture.
    ///
    /// Refused rather than silently ignored: they asked for something, and the
    /// sentence names the way out they already have on screen. The counterfactual
    /// is asserted with it — no crop, no read — because a refusal that still
    /// read the page would be a refusal in name only.
    @MainActor
    func testAPictureThatIsHeldRefusesAFocusedReadOutLoud() async throws {
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPass(harness)
        harness.model.captureSnapshot()
        await waitUntil("the frame to be held") { harness.model.isFrozen }
        let readsWhenFrozen = harness.engine.recognizeCallCount
        let spokenWhenFrozen = harness.speech.spokenTexts.count

        tapFocused(harness)
        try await Task<Never, Never>.sleep(for: .milliseconds(120))

        XCTAssertEqual(LiveTranslateSessionModel.frozenRefusalKey, "livetranslate.focus.frozen",
                       "the refusal is the feature's own sentence, in the catalog")
        let refusal = L10n.str(LiveTranslateSessionModel.frozenRefusalKey, locale: nepali)
        XCTAssertFalse(refusal.isEmpty)
        XCTAssertEqual(harness.speech.spokenTexts.count, spokenWhenFrozen + 1,
                       "the refusal is spoken: one sentence, on the tap's own stack")
        XCTAssertEqual(harness.speech.spokenTexts.last, refusal)
        XCTAssertNotEqual(refusal, harness.model.repromptText,
                          "it names the way out rather than being the catch-all re-prompt")
        XCTAssertNil(harness.model.focusedCapture, "no crop was packed over the held picture")
        XCTAssertEqual(harness.engine.recognizeCallCount, readsWhenFrozen,
                       "and the held page was not read: a refusal is not a slow yes")
        XCTAssertTrue(harness.model.isFrozen, "the snapshot still owns the surface")
    }

    /// **The focused read goes with the pause** (review finding 15), exactly as
    /// it goes with a close and with a thaw. A backgrounded session keeps no
    /// crop: the picture is one the elder is no longer looking at, the strings
    /// on it are the thing `close` releases, and the clock wait scheduled for
    /// it would otherwise wake up in the background and start a plan — a plan
    /// that can reach the cloud — for a picture nobody can see.
    ///
    /// The live picture's own state is deliberately *not* this test's subject:
    /// a pause is a claim about frames, and `resume` re-declares what is on
    /// screen from the cache.
    @MainActor
    func testPausingTakesTheFocusedPictureAndItsScheduledReAskWithIt() async throws {
        let brain = RecordingBrain()
        var config = LiveTranslateConfig.default
        config.brainAttemptMinInterval = 30
        let harness = makeHarness(consent: true,
                                  configured: true,
                                  transport: Self.respondingTransport(),
                                  config: config,
                                  brain: brain)
        harness.sleeper.parksTheWait = true
        reportLayout(harness)
        harness.engine.regions = [detected(liveLabelText)]
        await harness.model.start()
        try await deliverPasses(3, in: harness)
        await waitUntil("the live cycle's own generation to be paid") {
            brain.generationsAnswered > 0
        }
        let generationsWhenHeld = brain.calls.count

        harness.engine.regions = [detected(cropLabelText)]
        brain.answers[cropLabelText] = "रातो लिभर तान्नुहोस्"
        tapFocused(harness)
        // The wait **parks**, so the hold is provably in flight when the elder
        // backgrounds the phone: a wait that had already returned would make
        // this a race rather than a cancellation.
        await waitUntil("the clock-held read to pack its picture and take its wait") {
            harness.model.focusedCapture != nil && harness.sleeper.callCount == 1
        }

        harness.model.pause()
        XCTAssertNil(harness.model.focusedCapture,
                     "a backgrounded session keeps no crop: the strings go with it")

        // The wait ends the way a real one would have — only late, and into a
        // session that has moved on. What the task does with that is the claim:
        // it looks at `Task.isCancelled` and asks nothing.
        harness.sleeper.releaseParkedWait()
        try await Task<Never, Never>.sleep(for: .milliseconds(200))

        XCTAssertEqual(brain.calls.count, generationsWhenHeld,
                       "the cancelled wait planned nothing: the crop it was for is gone")
        XCTAssertNil(harness.model.focusedCapture,
                     "and no picture was installed into a session nobody is looking at")
    }

    /// The rule the focused surface is drawn with is the **session's own
    /// config's** (review finding: the injected config on the surface path),
    /// not the shipped default read at draw time. A rule read from
    /// `LiveTranslateConfig.default` would silently ignore the numbers the
    /// session was built with, which is exactly the kind of second source of
    /// truth a suite driving its own config cannot see.
    @MainActor
    func testTheFocusRuleIsTheSessionsOwnConfiguration() {
        var config = LiveTranslateConfig.default
        config.focusPanelHeightFraction = 0.5
        config.focusPanelGrowthStep = 0.1
        config.focusImageMaxGrowth = 1.2
        let harness = makeHarness(config: config)

        XCTAssertEqual(harness.model.focusRule,
                       LiveTranslateFocusLayout.Rule(panelHeightFraction: 0.5,
                                                     maximumImageGrowth: 1.2,
                                                     growthStep: 0.1))
        XCTAssertNotEqual(harness.model.focusRule, LiveTranslateFocusLayout.Rule.shipped,
                          "a configured session does not draw with the shipped numbers")
    }
}
