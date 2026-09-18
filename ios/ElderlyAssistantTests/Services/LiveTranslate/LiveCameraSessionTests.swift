import AVFoundation
import CoreMedia
import XCTest
@testable import ElderlyAssistant

/// T-006 — the capture stack's policy, exercised against a stubbed capture
/// layer: permission outcomes, the drop-not-queue cadence (with the thermal
/// response), the background/foreground lifecycle and the teardown
/// (FR-LCT-001/002, NFR-LCT-002/005).
///
/// Every sample is a real `CMSampleBuffer` over a real `CVPixelBuffer`, so the
/// session's own frame conversion is under test rather than a fixture, and
/// nothing here needs a camera.
final class LiveCameraSessionTests: XCTestCase {

    private var bus: LiveTranslateSanitisingBus!
    private var layer: LiveCameraCaptureStub!
    private var centre: NotificationCenter!
    private var clock: Clock!

    /// The injectable time source. The session reads it on every sample, so a
    /// test advances the cadence instead of sleeping.
    final class Clock {
        var now: TimeInterval = 1_000
        func advance(by seconds: TimeInterval) { now += seconds }
    }

    override func setUp() {
        super.setUp()
        bus = LiveTranslateSanitisingBus()
        layer = LiveCameraCaptureStub()
        centre = NotificationCenter()
        clock = Clock()
    }

    private func makeSession(config: LiveTranslateConfig = .default,
                             registration: FrameRegistration? = nil) -> LiveCameraSession {
        LiveCameraSession(config: config,
                          observabilityBus: bus,
                          capture: layer,
                          notificationCenter: centre,
                          registration: registration,
                          now: { [clock] in clock?.now ?? 0 })
    }

    private var interval: TimeInterval { LiveTranslateConfig.default.ocrSampleInterval }

    /// A real frame painted a solid luminance, so the frame-change gate has two
    /// different pictures to compare. `SampleBufferFactory` paints nothing, and
    /// two unpainted frames are — correctly — the same picture.
    private func paintedFrame(luma: UInt8, pts: Int,
                              width: Int = 64, height: Int = 48) throws -> CMSampleBuffer {
        let sample = try SampleBufferFactory.make(width: width, height: height,
                                                  pts: CMTime(value: CMTimeValue(pts), timescale: 1))
        let surface = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(surface, [])
        defer { CVPixelBufferUnlockBaseAddress(surface, []) }
        if let base = CVPixelBufferGetBaseAddress(surface) {
            let stride = CVPixelBufferGetBytesPerRow(surface)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for column in 0..<width {
                    let pixel = bytes + row * stride + column * 4
                    pixel[0] = luma
                    pixel[1] = luma
                    pixel[2] = luma
                    pixel[3] = 255
                }
            }
        }
        return sample
    }

    /// The next frame the session hands a consumer, with a short timeout so a
    /// regression that delivers nothing fails a test instead of hanging the
    /// suite. `AsyncSequence` has no parameterless `first()`.
    private func nextFrameFromStream(of session: LiveCameraSession) async -> CameraFrame? {
        var iterator = session.frames.makeAsyncIterator()
        return await nextFrame(iterator, within: 1.0)
    }

    // MARK: Scenario: live preview starts with no photo output configured

    func testThePreviewLayerIsAspectFitOverTheCaptureSessionsOwnLayer() {
        let session = makeSession()

        let preview = session.makePreviewLayer()

        XCTAssertEqual(preview.videoGravity, .resizeAspect,
                       "aspect-fit is what lets the shipped overlay mapping apply unchanged (NFR-LCT-012)")
        XCTAssertTrue(preview.session === layer.session,
                      "the preview must render the session the frames come from")
    }

    func testASuccessfulStartConfiguresOneVideoPipelineRunsItAndAnnouncesTheSession() async throws {
        let session = makeSession()

        let result = await session.start()

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(layer.configureCallCount, 1)
        XCTAssertEqual(layer.startRunningCallCount, 1)
        XCTAssertEqual(bus.events(named: "session_started").count, 1)
    }

    // MARK: Scenario: a sampled frame is used in memory and released

    func testASampledFrameCarriesItsInMemoryPixelBufferSizeAndTimestamp() async throws {
        let session = makeSession()
        _ = await session.start()

        let pts = CMTime(value: 42, timescale: 1)
        let delivered = try SampleBufferFactory.make(width: 640, height: 480, pts: pts)
        layer.deliver(delivered)

        let awaited1 = await nextFrameFromStream(of: session)
        let frame = try XCTUnwrap(awaited1)
        XCTAssertEqual(frame.pixelSize, CGSize(width: 640, height: 480))
        XCTAssertEqual(frame.timestamp, pts)
        XCTAssertTrue(frame.pixelBuffer === CMSampleBufferGetImageBuffer(delivered),
                      "the frame must be the delivered in-memory buffer, not a copy or a re-read")
    }

    // MARK: Scenario: frames are dropped, not queued, while a pass is in flight

    func testASampleInsideTheConfiguredIntervalIsDropped() async throws {
        let session = makeSession()
        _ = await session.start()
        var frames = session.frames.makeAsyncIterator()

        try layer.deliverFrame(width: 64, height: 48, pts: CMTime(value: 1, timescale: 1))
        clock.advance(by: interval / 2)
        try layer.deliverFrame(width: 64, height: 48, pts: CMTime(value: 2, timescale: 1))

        let first = await frames.next()
        XCTAssertEqual(first?.timestamp, CMTime(value: 1, timescale: 1),
                       "a sample inside the interval is dropped: the earlier frame is still the one waiting")
    }

    func testASampleDuringAnInFlightPassIsDroppedRatherThanQueued() async throws {
        let session = makeSession()
        _ = await session.start()

        // The stream holds at most one frame. If an in-flight sample were
        // queued rather than dropped, it would *replace* the older buffered
        // frame and be the first thing the consumer sees.
        try layer.deliverFrame(width: 64, height: 48, pts: CMTime(value: 10, timescale: 1))
        session.ocrPassInFlight = true
        clock.advance(by: interval)
        try layer.deliverFrame(width: 64, height: 48, pts: CMTime(value: 11, timescale: 1))
        session.ocrPassInFlight = false

        let awaited2 = await nextFrameFromStream(of: session)
        let first = try XCTUnwrap(awaited2)
        XCTAssertEqual(first.timestamp, CMTime(value: 10, timescale: 1),
                       "the in-flight sample must be dropped, not queued")
    }

    func testSamplingDegradesUnderAnInFlightPassRatherThanAccumulatingWork() async throws {
        let session = makeSession()
        _ = await session.start()

        session.ocrPassInFlight = true
        for index in 0..<10 {
            clock.advance(by: interval)
            try layer.deliverFrame(width: 64, height: 48,
                                   pts: CMTime(value: CMTimeValue(index), timescale: 1))
        }
        session.ocrPassInFlight = false

        clock.advance(by: interval)
        try layer.deliverFrame(width: 64, height: 48, pts: CMTime(value: 99, timescale: 1))

        let awaited3 = await nextFrameFromStream(of: session)
        let first = try XCTUnwrap(awaited3)
        XCTAssertEqual(first.timestamp, CMTime(value: 99, timescale: 1),
                       "ten in-flight samples must leave no backlog: the rate degrades, work does not accumulate (NFR-LCT-002)")
    }

    func testTheStreamBuffersAtMostOneFrame() async throws {
        let session = makeSession()
        _ = await session.start()
        var frames = session.frames.makeAsyncIterator()

        // Five *different* pictures, one cadence apart, so the frame-change gate
        // delivers every one of them: an unpainted buffer's contents are
        // whatever the pool last held, and two of those happening to look alike
        // would drop a sample at `stableSampleInterval` and leave this test
        // asserting about a stream with fewer than five frames in it.
        for index in 1...5 {
            clock.advance(by: interval)
            try layer.deliver(paintedFrame(luma: UInt8(index * 40), pts: index,
                                           width: 64, height: 48))
        }
        // Newest-only: the buffered frame is the last one delivered.
        let awaited4 = await frames.next()
        let first = try XCTUnwrap(awaited4)
        XCTAssertEqual(first.timestamp, CMTime(value: 5, timescale: 1))

        let extra = await nextFrame(frames, within: 0.2)
        XCTAssertNil(extra, "the stream must hold one frame, not a queue (the memory bound)")
    }

    // MARK: Scenario: permission outcomes are explicit and non-retryable where they must be

    func testTheFirstStartReturnsNotDeterminedWithoutStartingCaptureOrPrompting() async throws {
        layer.authorizationStatus = .notDetermined
        let session = makeSession()

        let result = await session.start()

        XCTAssertEqual(result.failureError, .cameraPermissionNotDetermined)
        XCTAssertEqual(layer.requestAccessCallCount, 0,
                       "the system prompt follows the elder's own explanation, never precedes it")
        XCTAssertEqual(layer.configureCallCount, 0,
                       "no frame may be requested before permission is granted")
        XCTAssertEqual(session.state, .idle)
    }

    func testTheSystemPromptIsRaisedOnlyAfterTheCallerHasExplained() async throws {
        layer.authorizationStatus = .notDetermined
        let session = makeSession()

        _ = await session.start()
        let second = await session.start()

        XCTAssertTrue(second.isSuccess)
        XCTAssertEqual(layer.requestAccessCallCount, 1)
        XCTAssertEqual(layer.configureCallCount, 1)
        XCTAssertEqual(session.state, .running)
    }

    func testADenialIsItsOwnResultAndNeverRaisesAPromptOrStartsCapture() async throws {
        layer.authorizationStatus = .denied
        let session = makeSession()

        let first = await session.start()
        let second = await session.start()

        XCTAssertEqual(first.failureError, .cameraPermissionDenied)
        XCTAssertEqual(second.failureError, .cameraPermissionDenied)
        XCTAssertEqual(layer.requestAccessCallCount, 0)
        XCTAssertEqual(layer.configureCallCount, 0)
        XCTAssertEqual(session.state, .failed(.cameraPermissionDenied))
        XCTAssertEqual(bus.events(named: "camera_denied").count, 2,
                       "each refusal is recorded; no retry is attempted in process")
    }

    func testADenialInsideTheSystemPromptIsReportedAsADenial() async throws {
        layer.authorizationStatus = .notDetermined
        layer.requestAccessResult = false
        let session = makeSession()

        _ = await session.start()
        let result = await session.start()

        XCTAssertEqual(result.failureError, .cameraPermissionDenied)
        XCTAssertEqual(layer.configureCallCount, 0)
        XCTAssertEqual(session.state, .failed(.cameraPermissionDenied))
        XCTAssertEqual(bus.events(named: "camera_denied").count, 1)
    }

    func testAMissingCaptureDeviceIsReportedAsSuchAndNeverRetriedAutomatically() async throws {
        layer.configurationError = .cameraUnavailable(.noCaptureDevice)
        let session = makeSession()

        let result = await session.start()

        XCTAssertEqual(result.failureError, .cameraUnavailable(.noCaptureDevice))
        XCTAssertEqual(session.state, .failed(.cameraUnavailable(.noCaptureDevice)))
        XCTAssertEqual(layer.configureCallCount, 1, "one attempt: no retry loop")
        XCTAssertEqual(layer.startRunningCallCount, 0)
        let events = bus.events(named: "camera_unavailable")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.metadata["reason"], "no_capture_device")
        XCTAssertEqual(events.first?.outcome, "failure")
    }

    func testAConfigurationFailureIsReportedAsItsOwnReason() async throws {
        layer.configurationError = .cameraUnavailable(.configurationFailed)
        let session = makeSession()

        let result = await session.start()

        XCTAssertEqual(result.failureError, .cameraUnavailable(.configurationFailed))
        XCTAssertEqual(bus.events(named: "camera_unavailable").first?.metadata["reason"],
                       "configuration_failed")
    }

    func testAResourceInUseFailureIsReportedAsItsOwnReason() async throws {
        layer.configurationError = .cameraUnavailable(.resourceInUse)
        let session = makeSession()

        let result = await session.start()

        XCTAssertEqual(result.failureError, .cameraUnavailable(.resourceInUse))
        XCTAssertEqual(bus.events(named: "camera_unavailable").first?.metadata["reason"],
                       "resource_in_use")
    }

    // MARK: Scenario: backgrounding and interruption pause, foregrounding resumes once

    func testBackgroundingPausesCaptureAndForegroundingResumesItExactlyOnce() async throws {
        let session = makeSession()
        _ = await session.start()

        centre.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        XCTAssertEqual(session.state, .interrupted(.backgrounded))
        XCTAssertEqual(layer.stopRunningCallCount, 1)
        let interrupted = bus.events(named: "camera_interrupted")
        XCTAssertEqual(interrupted.count, 1)
        XCTAssertEqual(interrupted.first?.metadata["reason"], "backgrounded")

        centre.post(name: UIApplication.willEnterForegroundNotification, object: nil)

        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(layer.startRunningCallCount, 2)
        XCTAssertEqual(bus.events(named: "camera_resumed").first?.metadata["reason"], "backgrounded")

        // A second foreground signal must not start a second capture (no loop).
        centre.post(name: UIApplication.willEnterForegroundNotification, object: nil)

        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(layer.startRunningCallCount, 2, "one resume per foreground transition")
        XCTAssertEqual(bus.events(named: "camera_resumed").count, 1)
    }

    func testNoFramesAreDeliveredWhileTheSessionIsBackgrounded() async throws {
        let session = makeSession()
        _ = await session.start()
        var frames = session.frames.makeAsyncIterator()

        centre.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        clock.advance(by: interval)
        try layer.deliverFrame(width: 64, height: 48, pts: CMTime(value: 7, timescale: 1))

        let frame = await nextFrame(frames, within: 0.2)
        XCTAssertNil(frame, "a paused session must deliver nothing, not even a buffered frame")
    }

    func testASystemInterruptionSurfacesAsAnHonestDegradedState() async throws {
        let session = makeSession()
        _ = await session.start()

        centre.post(name: AVCaptureSession.wasInterruptedNotification,
                    object: layer.session,
                    userInfo: [AVCaptureSessionInterruptionReasonKey:
                                AVCaptureSession.InterruptionReason.videoDeviceInUseByAnotherClient.rawValue])

        XCTAssertEqual(session.state, .interrupted(.systemInterruption),
                       "the view renders this state: never a silent stall")
        XCTAssertEqual(layer.stopRunningCallCount, 1)
        XCTAssertEqual(bus.events(named: "camera_interrupted").first?.metadata["reason"],
                       "system_interruption")
    }

    func testThermalPressureIsReportedAsAThermalInterruption() async throws {
        let session = makeSession()
        _ = await session.start()

        centre.post(name: AVCaptureSession.wasInterruptedNotification,
                    object: layer.session,
                    userInfo: [AVCaptureSessionInterruptionReasonKey:
                                AVCaptureSession.InterruptionReason
                                    .videoDeviceNotAvailableDueToSystemPressure.rawValue])

        XCTAssertEqual(session.state, .interrupted(.thermal))
        XCTAssertEqual(bus.events(named: "camera_interrupted").first?.metadata["reason"], "thermal")
    }

    /// The system can take the camera away in the moment between configuring
    /// the graph and running it. The session must not end that start running
    /// in the background: the interruption is held and applied to the
    /// completed start.
    func testAnInterruptionArrivingWhileStartingKeepsCaptureOutOfTheBackground() async throws {
        let session = makeSession()
        layer.onStartRunning = { [centre, layer] in
            centre?.post(name: AVCaptureSession.wasInterruptedNotification,
                         object: layer?.session,
                         userInfo: [AVCaptureSessionInterruptionReasonKey:
                                    AVCaptureSession.InterruptionReason
                                        .videoDeviceNotAvailableInBackground.rawValue])
        }

        let result = await session.start()
        layer.onStartRunning = nil

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(session.state, .interrupted(.backgrounded),
                       "the completed start must not leave a session running in the background")
        XCTAssertEqual(layer.startRunningCallCount, 1)
        XCTAssertEqual(layer.stopRunningCallCount, 1,
                       "the held interruption stopped the capture the start had just begun")
        XCTAssertEqual(bus.events(named: "camera_interrupted").first?.metadata["reason"], "backgrounded")
    }

    // MARK: Thermal response (NFR-LCT-002 scenario 3)

    func testTheCadenceSlowsByTheConfiguredFactorAtOrAboveTheThermalThreshold() {
        let config = LiveTranslateConfig.default
        let session = makeSession(config: config)

        layer.thermalState = .nominal
        XCTAssertEqual(session.effectiveSampleInterval, config.ocrSampleInterval)
        layer.thermalState = .fair
        XCTAssertEqual(session.effectiveSampleInterval, config.ocrSampleInterval)

        layer.thermalState = config.thermalStateThreshold
        XCTAssertEqual(session.effectiveSampleInterval,
                       config.ocrSampleInterval * config.thermalCadenceFactor)
        layer.thermalState = .critical
        XCTAssertEqual(session.effectiveSampleInterval,
                       config.ocrSampleInterval * config.thermalCadenceFactor)
    }

    func testTheReducedCadenceActuallyDropsTheSampleThatTheBaseCadenceWouldHaveTaken() async throws {
        let config = LiveTranslateConfig.default
        let session = makeSession(config: config)
        _ = await session.start()
        var frames = session.frames.makeAsyncIterator()

        try layer.deliverFrame(width: 64, height: 48, pts: CMTime(value: 1, timescale: 1))
        layer.thermalState = config.thermalStateThreshold
        // Past the nominal interval, inside the reduced one: the first-line
        // thermal response is a slower cadence, not a stopped camera.
        clock.advance(by: config.ocrSampleInterval * 1.5)
        try layer.deliverFrame(width: 64, height: 48, pts: CMTime(value: 2, timescale: 1))

        let first = await frames.next()
        XCTAssertEqual(first?.timestamp, CMTime(value: 1, timescale: 1))
    }

    // MARK: The frame-change gate (NFR-LCT-002)

    func testAStillSceneDropsToTheReducedCadenceAndAChangedOneDoesNot() async throws {
        let session = makeSession()
        _ = await session.start()
        var frames = session.frames.makeAsyncIterator()

        // The first frame of a session is always a change: there is nothing to
        // compare it with.
        try layer.deliver(paintedFrame(luma: 0, pts: 1))
        _ = await frames.next()

        // The same picture, one nominal interval later: recognition could not
        // learn anything new from it, so the sample is dropped rather than
        // recognized. This is the cost the device's own crash reports show
        // being paid at ~4 Hz over a scene that was not changing.
        clock.advance(by: interval)
        try layer.deliver(paintedFrame(luma: 0, pts: 2))

        // A different picture at the same cadence is news, and runs at the full
        // cadence: the reduced cadence is a bound on idling, never a lag on news.
        clock.advance(by: interval)
        try layer.deliver(paintedFrame(luma: 90, pts: 3))
        let news = await frames.next()
        XCTAssertEqual(news?.timestamp, CMTime(value: 3, timescale: 1),
                       "a materially different frame is delivered at the nominal cadence")
    }

    func testAStillSceneIsStillReadJustSlower() async throws {
        let config = LiveTranslateConfig.default
        let session = makeSession(config: config)
        _ = await session.start()
        var frames = session.frames.makeAsyncIterator()

        try layer.deliver(paintedFrame(luma: 0, pts: 1))
        _ = await frames.next()

        clock.advance(by: interval)
        try layer.deliver(paintedFrame(luma: 0, pts: 2))

        // The reduced cadence is still a cadence: at `stableSampleInterval` the
        // still scene is read again, so a sign that has been sitting there is
        // refreshed rather than forgotten.
        clock.advance(by: config.stableSampleInterval)
        try layer.deliver(paintedFrame(luma: 0, pts: 3))
        let refresh = await frames.next()
        XCTAssertEqual(refresh?.timestamp, CMTime(value: 3, timescale: 1),
                       "a still scene is read at the reduced interval, not never")
    }

    func testAStaleSceneSignalDropsTheCadenceEvenWhileTheFramesChange() async throws {
        // Motion that carries no new text — a hand, a reflection, a screen
        // playing video behind the sign — is the case the frame gate cannot
        // see: the pixels really do change. The pipeline can see it (it is the
        // component that sees the recognition results), so its signal is what
        // slows the tap down.
        let config = LiveTranslateConfig.default
        let session = makeSession(config: config)
        _ = await session.start()
        var frames = session.frames.makeAsyncIterator()

        try layer.deliver(paintedFrame(luma: 0, pts: 1))
        _ = await frames.next()

        session.ocrSceneStale = true
        clock.advance(by: interval)
        try layer.deliver(paintedFrame(luma: 90, pts: 2))
        clock.advance(by: config.stableSampleInterval)
        try layer.deliver(paintedFrame(luma: 180, pts: 3))

        let delivered = await frames.next()
        XCTAssertEqual(delivered?.timestamp, CMTime(value: 3, timescale: 1),
                       "under the stale signal a changed frame waits for the reduced interval")
    }

    func testTheGatesDecisionIsTheIntervalThatApplies() {
        let config = LiveTranslateConfig.default
        let session = makeSession(config: config)

        XCTAssertEqual(session.effectiveSampleInterval(changed: true, stale: false),
                       config.ocrSampleInterval,
                       "a changed scene in a scene the pipeline has not called stale runs at the nominal cadence")
        XCTAssertEqual(session.effectiveSampleInterval(changed: false, stale: false),
                       Swift.max(config.ocrSampleInterval, config.stableSampleInterval),
                       "an unchanged frame drops to the reduced cadence")
        XCTAssertEqual(session.effectiveSampleInterval(changed: true, stale: true),
                       Swift.max(config.ocrSampleInterval, config.stableSampleInterval),
                       "the pipeline's stale signal applies to a changing scene too")
    }

    // MARK: The window on the frames (owner follow-up, 2026-09-18)

    func testASessionStampsItsWindowOnItsFramesAndPutsItBackWhenItStops() async throws {
        let session = makeSession()
        _ = await session.start()
        session.zoomSurface.zoom(.closer)
        let window = session.zoomSurface.model.crop
        XCTAssertFalse(window.isWhole, "a zoomed session is showing part of its frame, not all of it")
        XCTAssertEqual(session.currentCrop, window)

        try layer.deliver(paintedFrame(luma: 0, pts: 1))
        let frame = await nextFrameFromStream(of: session)
        XCTAssertEqual(frame?.crop, window,
                       "the frame says which part of itself it is — the pass, the placement and the "
                       + "preview must not each guess")

        session.stop()
        XCTAssertEqual(session.currentCrop, .whole, "the window goes home with the session")

        // A surface the view is still holding can ask for a crop after the
        // teardown began; a stopped session stamps no frame, so the window is
        // not reopened.
        session.setCrop(window)
        XCTAssertEqual(session.currentCrop, .whole)
    }

    func testAPanForgetsTheGatesBaselineBecauseTheWindowIsADifferentPicture() async throws {
        let config = LiveTranslateConfig.default
        let session = makeSession(config: config)
        _ = await session.start()
        var frames = session.frames.makeAsyncIterator()

        // Zoom first — a factor change is its own reason to forget the gate —
        // and let one frame settle the baseline over that window.
        session.zoomSurface.zoom(.closer)
        clock.advance(by: interval)
        try layer.deliver(paintedFrame(luma: 0, pts: 1))
        _ = await frames.next()

        // The same picture, one nominal interval later: dropped, because
        // recognition could not learn anything new from it.
        clock.advance(by: interval)
        try layer.deliver(paintedFrame(luma: 0, pts: 2))

        // The elder drags: the window is a different rectangle of the same
        // scene, so those same pixels are a different picture — the gate's
        // baseline was measured somewhere the elder is no longer looking.
        session.zoomSurface.pan(to: CGPoint(x: -0.05, y: 0))
        XCTAssertFalse(session.currentCrop.isWhole)

        clock.advance(by: interval)
        try layer.deliver(paintedFrame(luma: 0, pts: 3))
        let reframed = await frames.next()
        XCTAssertEqual(reframed?.timestamp, CMTime(value: 3, timescale: 1),
                       "the first frame after a pan is read at the nominal cadence, not the reduced one")
        XCTAssertEqual(reframed?.crop, session.currentCrop)
    }

    func testTheSignatureRefusesAFormatItCannotReadRatherThanGuessing() throws {
        // The capture layer asks the platform for 32BGRA. A buffer in another
        // format is refused — and a refusal fails open, which is what keeps the
        // gate from turning an unreadable frame into "nothing changed".
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 32, 32,
                                         kCVPixelFormatType_OneComponent8, nil, &pixelBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)

        XCTAssertNil(LuminanceSignature.of(buffer, side: 8),
                     "a format the gate does not read is refused, never guessed at")
    }

    func testTheSignatureIsTheFramesMeanLuminanceOnAGrid() throws {
        let surface = try XCTUnwrap(CMSampleBufferGetImageBuffer(paintedFrame(luma: 100, pts: 1)))
        let signature = try XCTUnwrap(LuminanceSignature.of(surface, side: 8))
        XCTAssertEqual(signature.samples.count, 64, "4 KB of samples, and no copy of the frame")
        XCTAssertTrue(signature.samples.allSatisfy { $0 == 100 },
                      "a solid picture reads as one luminance value per sample")

        let brighter = try XCTUnwrap(LuminanceSignature.of(
            try XCTUnwrap(CMSampleBufferGetImageBuffer(paintedFrame(luma: 200, pts: 2))), side: 8))
        XCTAssertEqual(try XCTUnwrap(signature.meanAbsoluteDifference(from: brighter)),
                       100.0 / 255.0, accuracy: 0.0001,
                       "the difference is a fraction of full scale, which is what the threshold is")

        let coarser = try XCTUnwrap(LuminanceSignature.of(surface, side: 4))
        XCTAssertNil(signature.meanAbsoluteDifference(from: coarser),
                     "two signatures over different grids are not comparable")
    }

    func testTheChangeDetectorComparesAgainstTheLastFrameRecognitionRan() throws {
        var detector = FrameChangeDetector()
        let first = try XCTUnwrap(CameraFrame(sampleBuffer: paintedFrame(luma: 0, pts: 1)))

        XCTAssertTrue(detector.isMateriallyDifferent(first, side: 64, threshold: 0.02),
                      "the first frame after a start is always a change")
        detector.remember(first, side: 64)

        let same = try XCTUnwrap(CameraFrame(sampleBuffer: paintedFrame(luma: 0, pts: 2)))
        XCTAssertFalse(detector.isMateriallyDifferent(same, side: 64, threshold: 0.02))

        let under = try XCTUnwrap(CameraFrame(sampleBuffer: paintedFrame(luma: 3, pts: 3)))
        XCTAssertFalse(detector.isMateriallyDifferent(under, side: 64, threshold: 0.02),
                       "3/255 is under the 2% threshold: not a material change")
        let over = try XCTUnwrap(CameraFrame(sampleBuffer: paintedFrame(luma: 6, pts: 4)))
        XCTAssertTrue(detector.isMateriallyDifferent(over, side: 64, threshold: 0.02),
                      "6/255 is over it")

        detector.forget()
        XCTAssertTrue(detector.isMateriallyDifferent(same, side: 64, threshold: 0.02),
                      "a forgotten baseline makes the next frame a change, whatever it shows")
    }

    // MARK: Scenario: stopping tears everything down

    func testStopStopsCaptureFinishesTheStreamAndRemovesEveryObserver() async throws {
        let session = makeSession()
        _ = await session.start()
        var frames = session.frames.makeAsyncIterator()

        session.stop()

        XCTAssertEqual(session.state, .stopped)
        XCTAssertEqual(layer.stopRunningCallCount, 1)
        XCTAssertEqual(bus.events(named: "session_ended").count, 1)
        let finished = await frames.next()
        XCTAssertNil(finished, "the frame stream is finished, so no consumer is left waiting")

        // Every lifecycle observer is gone: the notifications do nothing.
        let eventsAfterStop = bus.events.count
        centre.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        centre.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        centre.post(name: AVCaptureSession.wasInterruptedNotification,
                    object: layer.session,
                    userInfo: [AVCaptureSessionInterruptionReasonKey:
                                AVCaptureSession.InterruptionReason.videoDeviceInUseByAnotherClient.rawValue])

        XCTAssertEqual(session.state, .stopped)
        XCTAssertEqual(layer.startRunningCallCount, 1, "nothing resumes a torn-down session")
        XCTAssertEqual(bus.events.count, eventsAfterStop, "no observer outlives the view")
    }

    func testAFrameDeliveredAfterStopIsNotHandedOn() async throws {
        let session = makeSession()
        _ = await session.start()
        session.stop()

        clock.advance(by: interval)
        try layer.deliverFrame(width: 64, height: 48, pts: CMTime(value: 3, timescale: 1))

        let frame = await nextFrame(session.frames.makeAsyncIterator(), within: 0.2)
        XCTAssertNil(frame, "the finished stream and the torn-down tap drop everything after stop")
    }

    func testStoppingASessionThatNeverStartedAnnouncesNothingAndIsIdempotent() async throws {
        let session = makeSession()

        session.stop()
        session.stop()

        XCTAssertEqual(session.state, .stopped)
        XCTAssertEqual(bus.events.count, 0)
        XCTAssertEqual(layer.stopRunningCallCount, 0)
    }

    func testAStoppedSessionIsNotRestartedBehindTheCallersBack() async throws {
        let session = makeSession()
        _ = await session.start()
        session.stop()

        let result = await session.start()

        XCTAssertEqual(result.failureError, .cameraUnavailable(.configurationFailed))
        XCTAssertEqual(layer.configureCallCount, 1)
        XCTAssertEqual(layer.startRunningCallCount, 1)
    }

    // MARK: Events stay content-free

    func testTheSessionEmitsOnlyCataloguedContentFreeEvents() async throws {
        let session = makeSession()
        _ = await session.start()
        centre.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        centre.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        session.stop()

        XCTAssertFalse(bus.events.isEmpty)
        for event in bus.events {
            XCTAssertEqual(event.component, LiveTranslateEventCatalogue.component)
            let entry = try XCTUnwrap(LiveTranslateEventCatalogue.entries[event.eventType],
                                      "\(event.eventType) is not in the pinned catalogue")
            XCTAssertTrue(entry.outcomes.contains(event.outcome),
                          "\(event.eventType) carries an undeclared outcome \(event.outcome)")
            XCTAssertTrue(entry.metadataKeys.isSuperset(of: Set(event.metadata.keys)),
                          "\(event.eventType) carries an undeclared metadata key")
            for value in event.metadata.values {
                XCTAssertFalse(value.contains(" "),
                               "metadata is counts and closed tokens, never free text")
            }
        }
        // The reasons are the closed vocabulary, not a rendered message.
        let reasons = bus.events.compactMap { $0.metadata["reason"] }
        XCTAssertTrue(reasons.allSatisfy { ["backgrounded", "system_interruption", "thermal"].contains($0) })
    }

    // MARK: Zoom and focus (owner report, 2026-09-17)

    func testASessionAdoptsTheZoomItsDeviceIsAlreadyAtAndStampsItOnItsFrames() async throws {
        // A device that was left zoomed by whoever held the phone before this
        // session (the opening zoom is the layer's, applied under the device's
        // own lock, and the device's range may have clamped it).
        layer.videoZoomFactorValue = 3
        let session = makeSession()

        _ = await session.start()

        XCTAssertEqual(session.currentVideoZoom, 3,
                       "the zoom is read back from the device, not assumed to be 1")

        try layer.deliverFrame(width: 64, height: 48, pts: CMTime(value: 1, timescale: 1))
        let awaited = await nextFrameFromStream(of: session)
        let frame = try XCTUnwrap(awaited)
        XCTAssertEqual(frame.zoomFactor, 3,
                       "the frame says what it is a picture of — the device's own crop of the sensor")
    }

    func testTheZoomTheDeviceAppliedIsTheZoomTheSessionHolds() async throws {
        let session = makeSession()
        _ = await session.start()
        // The device's own range is narrower than the app's: the platform
        // clamps, and the question is whether the session notices.
        layer.appliedZoomClamp = 1...2

        let applied = session.setZoom(6)

        XCTAssertEqual(applied, 2, "the answer is the device's, never the argument's")
        XCTAssertEqual(session.currentVideoZoom, 2,
                       "a readout built from the request would say 6× over a picture at 2×")
        XCTAssertEqual(layer.setZoomRequests, [6],
                       "the elder's number is what is asked for; the clamping is the platform's business")
    }

    func testASetZoomDropsTheFrameDiffBaselineSoTheZoomedPictureIsReadAtOnce() async throws {
        let session = makeSession()
        _ = await session.start()
        var frames = session.frames.makeAsyncIterator()

        try layer.deliver(paintedFrame(luma: 0, pts: 1))
        _ = await frames.next()

        // The gate's baseline is now the picture at 1×. The elder zooms: the
        // same scene is a *different picture* from here, and the frame that
        // shows the small print they just enlarged is the one frame the gate
        // must never drop as "unchanged" — so the baseline goes with the zoom.
        clock.advance(by: interval)
        session.setZoom(2)

        // Byte-identical pixels, one nominal interval later, and still read:
        // without the forgotten baseline this frame is a still scene and waits
        // for the reduced cadence.
        clock.advance(by: interval)
        try layer.deliver(paintedFrame(luma: 0, pts: 2))

        let awaited = await nextFrame(frames, within: 1.0)
        let zoomed = try XCTUnwrap(awaited, "the frame after a zoom is news, whatever the pixels said")
        XCTAssertEqual(zoomed.timestamp, CMTime(value: 2, timescale: 1))
        XCTAssertEqual(zoomed.zoomFactor, 2, "and it carries the zoom it was taken at")
    }

    func testASetZoomBeforeAStartClampsToTheAppBoundsAndLeavesTheDeviceAlone() async throws {
        let session = makeSession()
        layer.videoZoomFactorValue = 1

        let applied = session.setZoom(99)

        XCTAssertEqual(applied, LiveTranslateConfig.default.maxVideoZoom,
                       "a caller always gets a factor it can draw")
        XCTAssertTrue(layer.setZoomRequests.isEmpty,
                      "there is no configured device to zoom, so nothing is asked of one")
        XCTAssertEqual(session.currentVideoZoom, 1,
                       "and no frame has been taken at anything else, so nothing is claimed")
    }

    func testTheZoomCapabilitiesAreTheRunningDevicesAndNothingWhenThereIsNoDevice() async throws {
        let session = makeSession()
        XCTAssertEqual(session.zoomCapabilities, .unknown,
                       "with no device the model works from the app's own bounds alone")

        _ = await session.start()
        XCTAssertEqual(session.zoomCapabilities, layer.zoomCapabilitiesValue)

        // The valid range follows the device's active *format*, which the
        // platform can change under a running session: the seam is asked again
        // rather than read once.
        layer.zoomCapabilitiesValue = CameraZoomCapabilities(range: 1...4,
                                                             switchOverFactors: [2])
        XCTAssertEqual(session.zoomCapabilities.switchOverFactors, [2])

        session.stop()
        XCTAssertEqual(session.zoomCapabilities, .unknown,
                       "a torn-down session has no device and says so")
    }

    func testTheSurfaceTakesTheRunningDevicesBoundsOnItsFirstInteraction() async throws {
        let session = makeSession()
        _ = await session.start()   // the stub device reports 1...6, narrower than the app's 1...8

        session.zoomSurface.zoom(.closer)

        XCTAssertEqual(session.zoomSurface.model.bounds, 1...6,
                       "the first interaction asks the device what it can do")
        XCTAssertEqual(layer.setZoomRequests, [1.5])
        XCTAssertEqual(session.zoomSurface.model.factor, 1.5,
                       "and the control shows the factor the device took")
    }

    /// The whole zoom path on a virtual multi-lens device, in the unit the elder
    /// reads and the unit the device takes — the owner's iPhone 14 Pro Max,
    /// where the two differ by a factor of two.
    ///
    /// The config's keys are readout numbers ("the wide camera's view is 1×"),
    /// and this stub device is a triple: its own factor 1 is the ultra-wide the
    /// system camera prints as 0.5×, the wide camera is its factor 2, and its
    /// published hand-overs are 2 (wide) and 6 (the telephoto, which the readout
    /// calls 3×). Nothing between the view and the device may convert, and the
    /// session may convert exactly once.
    func testAReadoutZoomOnAVirtualDeviceIsConvertedIntoTheDevicesOwnFactors() async throws {
        let virtualDevice = CameraZoomCapabilities(range: 1...16, switchOverFactors: [2, 6],
                                                   widestLensIsUltraWide: true)
        layer.zoomCapabilitiesValue = virtualDevice
        layer.videoZoomFactorValue = 2   // where the layer's own opening left the device
        let session = makeSession()

        // At rest, before any device is running: the config's 1× in this
        // device's factors, not the raw 1 that would mean the ultra-wide.
        XCTAssertEqual(session.currentVideoZoom, 2,
                       "the session's at-rest factor is the config's opening view as this device takes it")

        _ = await session.start()
        XCTAssertEqual(session.zoomCapabilities.displayMultiplier, 0.5)
        XCTAssertEqual(session.currentVideoZoom, 2, "the device's own answer is adopted as it stands")

        session.zoomSurface.zoom(.closer)      // the elder presses +: 1× → 1.5×
        session.zoomSurface.zoom(.closer)      // 1.5× → 2×

        XCTAssertEqual(layer.setZoomRequests, [3, 4],
                       "the presses are the readout's half steps, asked for in the device's own factors")
        XCTAssertEqual(session.currentVideoZoom, 4, "and the device is where the readout says it is")
        XCTAssertEqual(session.zoomSurface.model.label, "2×",
                       "the control prints the elder's unit back to them")
        XCTAssertEqual(session.zoomSurface.model.bounds, 2...16,
                       "the config's 1×...8×, as this device's factors")
    }

    func testATapFocusesTheDeviceAndTheReArmKeepsLookingAtTheSamePoint() async throws {
        let session = makeSession()
        _ = await session.start()
        let point = CGPoint(x: 0.25, y: 0.75)

        session.setFocusLocked(true)
        session.focus(at: point)

        XCTAssertEqual(layer.focusRequests, [point],
                       "the tap's point reaches the device unchanged — the layer already converted it")
        XCTAssertFalse(session.zoomSurface.isFocusLocked,
                       "tapping a new label is asking to look at it, not to hold the last lock")

        // The device reports the subject area changed: the packet was turned
        // over, brought closer, or moved out of the light.
        layer.subjectAreaDidChange()
        XCTAssertEqual(layer.continuousFocusRequests, [point],
                       "the re-arm searches continuously at the point the elder last aimed at — "
                       + "a different mode from the tap's one-shot, or it would be a no-op")

        // While focus is held, the re-arm is exactly what must not happen: the
        // elder has said "do not move it".
        session.setFocusLocked(true)
        layer.subjectAreaDidChange()
        XCTAssertEqual(layer.continuousFocusRequests, [point], "a held focus is not re-armed")
    }

    func testTheReArmStartsFromTheConfiguredFocusPoint() async throws {
        let session = makeSession()
        _ = await session.start()

        layer.subjectAreaDidChange()

        XCTAssertEqual(layer.continuousFocusRequests,
                       [LiveTranslateConfig.default.focusPointOfInterest],
                       "with no tap yet, the configured point is where the camera looks")
    }

    func testTheFocusLockReachesTheDeviceAndIsMirroredOnTheControl() async throws {
        let session = makeSession()
        _ = await session.start()

        session.setFocusLocked(true)
        XCTAssertEqual(layer.focusLockRequests, [true])
        XCTAssertTrue(session.zoomSurface.isFocusLocked,
                      "the control and the device are never drawn disagreeing")

        session.setFocusLocked(false)
        XCTAssertEqual(layer.focusLockRequests, [true, false])
        XCTAssertFalse(session.zoomSurface.isFocusLocked)
    }

    func testALockPressedWithNoRunningCameraStillMovesTheControl() throws {
        let session = makeSession()

        session.setFocusLocked(true)

        XCTAssertTrue(session.zoomSurface.isFocusLocked,
                      "the elder pressed the control; one that flipped back because the camera "
                      + "happened to be between states would be the app arguing with itself")
        XCTAssertTrue(layer.focusLockRequests.isEmpty, "and there is no device to tell yet")
    }

    func testADeviceThatCannotBeToldWhereToFocusIsNotAsked() async throws {
        layer.supportsFocusPointOfInterest = false
        let session = makeSession()
        _ = await session.start()

        session.focus(at: CGPoint(x: 0.5, y: 0.5))

        XCTAssertTrue(layer.focusRequests.isEmpty,
                      "a device with no focus point of interest is not sent one")
    }

    // MARK: The picture's own stabilization on the session (C11)

    /// A registration that answers what a test says the picture did: the same
    /// seam `FrameAnchorEstimatorTests` drives directly, here so that the whole
    /// session — the cadence gate, the frame the consumer is handed, the zoom
    /// reset — can be exercised with an exact motion and no camera.
    private final class ScriptedFrameRegistration: FrameRegistration {
        private var motions: [FrameMotionMap?]
        private(set) var calls = 0

        init(_ motions: [FrameMotionMap?]) { self.motions = motions }

        func motion(from anchor: CVPixelBuffer, to current: CVPixelBuffer) -> FrameMotionMap? {
            defer { calls += 1 }
            return motions.isEmpty ? nil : motions.removeFirst()
        }
    }

    func testAnAcceptedFrameCarriesTheCorrectionAndTheWindowTheRecognitionReads() async throws {
        let registration = ScriptedFrameRegistration([FrameMotionMap.translation(CGPoint(x: 0.02, y: 0))])
        let session = makeSession(registration: registration)
        _ = await session.start()
        var frames = session.frames.makeAsyncIterator()

        try layer.deliver(paintedFrame(luma: 0, pts: 1))
        let anchoredFrame = await frames.next()
        let anchored = try XCTUnwrap(anchoredFrame)

        XCTAssertEqual(anchored.stabilization.offset, .zero,
                       "the first accepted frame is the anchor: there is nothing to correct against yet")
        XCTAssertEqual(anchored.stabilization.margin, LiveTranslateConfig.default.frameStabMargin,
                       "…and it is already inset: that inset is the room the correction is held in")
        XCTAssertEqual(anchored.crop, .whole,
                       "what the recognition pass is handed is the elder's own window, never the stabilized one")
        XCTAssertEqual(registration.calls, 0, "the anchor costs no registration")

        clock.advance(by: interval)
        try layer.deliver(paintedFrame(luma: 90, pts: 2))
        let heldFrame = await frames.next()
        let held = try XCTUnwrap(heldFrame)

        XCTAssertEqual(held.stabilization.offset.x, 0.008, accuracy: 1e-9,
                       "0.4 of a 2 % move, past the 1 % dead zone: the window took the tremor")
        XCTAssertEqual(held.stabilization.margin, anchored.stabilization.margin,
                       "the inset is a property of the feature being on, not of the correction")
        XCTAssertEqual(held.crop, .whole,
                       "and the pass still reads the raw frame: what is stabilized is what the elder looks at")
        XCTAssertEqual(registration.calls, 1, "one measurement, at the cadence the pass runs at")
    }

    func testWithThePictureStabilizerOffTheFrameIsExactlyWhatTheCameraSaw() async throws {
        var config = LiveTranslateConfig.default
        config.frameStabEnabled = false
        let registration = ScriptedFrameRegistration([FrameMotionMap.translation(CGPoint(x: 0.02, y: 0))])
        let session = makeSession(config: config, registration: registration)
        _ = await session.start()
        var frames = session.frames.makeAsyncIterator()

        try layer.deliver(paintedFrame(luma: 0, pts: 1))
        _ = await frames.next()
        clock.advance(by: interval)
        try layer.deliver(paintedFrame(luma: 90, pts: 2))
        let awaited = await frames.next()
        let frame = try XCTUnwrap(awaited)

        XCTAssertEqual(frame.stabilization, .none,
                       "off is the feature's own off: the display draws the elder's window and nothing else")
        XCTAssertEqual(frame.crop, .whole)
        XCTAssertEqual(registration.calls, 0, "and no registration is asked for")
    }

    func testAZoomPressDropsTheCorrectionAndTakesAFreshAnchor() async throws {
        // A zoom is a crop of the sensor: every pixel the frame carries has
        // moved and changed size, so a correction measured against the old
        // anchor is measuring a different picture. It goes at the gesture, not
        // after the next stale measurement.
        let registration = ScriptedFrameRegistration([
            FrameMotionMap.translation(CGPoint(x: 0.02, y: 0)),
            FrameMotionMap.translation(CGPoint(x: 0.02, y: 0)),
        ])
        let session = makeSession(registration: registration)
        _ = await session.start()
        var frames = session.frames.makeAsyncIterator()

        try layer.deliver(paintedFrame(luma: 0, pts: 1))
        _ = await frames.next()
        clock.advance(by: interval)
        try layer.deliver(paintedFrame(luma: 90, pts: 2))
        let heldFrame = await frames.next()
        let held = try XCTUnwrap(heldFrame)
        XCTAssertEqual(held.stabilization.offset.x, 0.008, accuracy: 1e-9,
                       "the premise: there is a correction, and the zoom has to drop it")

        session.zoomSurface.zoom(.closer)

        clock.advance(by: interval)
        try layer.deliver(paintedFrame(luma: 180, pts: 3))
        let reAnchoredFrame = await frames.next()
        let reAnchored = try XCTUnwrap(reAnchoredFrame)

        XCTAssertEqual(reAnchored.stabilization.offset, .zero,
                       "the correction goes with the picture it was measured against")
        XCTAssertEqual(reAnchored.stabilization.margin, LiveTranslateConfig.default.frameStabMargin,
                       "the inset stays: the window is inset, just not moved")
        XCTAssertEqual(registration.calls, 1,
                       "the first frame after a zoom is a new anchor, not a measurement against the old one")
    }

    // MARK: Helpers

    /// Awaits the next frame, or `nil` if none arrives within `seconds`. Used
    /// only for "nothing was delivered" assertions, at the end of a test: the
    /// cancelled wait terminates that stream's iterator.
    private func nextFrame(_ iterator: AsyncStream<CameraFrame>.AsyncIterator,
                           within seconds: TimeInterval) async -> CameraFrame? {
        let waiter = Task { () -> CameraFrame? in
            var iterator = iterator
            return await iterator.next()
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            waiter.cancel()
        }
        let frame = await waiter.value
        timeout.cancel()
        return frame
    }
}

