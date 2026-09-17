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

    private func makeSession(config: LiveTranslateConfig = .default) -> LiveCameraSession {
        LiveCameraSession(config: config,
                          observabilityBus: bus,
                          capture: layer,
                          notificationCenter: centre,
                          now: { [clock] in clock?.now ?? 0 })
    }

    private var interval: TimeInterval { LiveTranslateConfig.default.ocrSampleInterval }

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

        for index in 1...5 {
            clock.advance(by: interval)
            try layer.deliverFrame(width: 64, height: 48,
                                   pts: CMTime(value: CMTimeValue(index), timescale: 1))
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

