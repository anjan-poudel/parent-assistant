import CoreMedia
import CoreText
import CoreVideo
import UIKit
import Vision
import XCTest
@testable import ElderlyAssistant

/// T-007 — the detector's contract: two non-interchangeable request kinds, the
/// OCR cadence, the drop-a-failed-pass rule, the tracking degradation and the
/// language it refuses to invent (FR-LCT-003/004, NFR-LCT-001/002/005).
///
/// Two layers deliberately. The **policy** is exercised against a scripted
/// recognition engine, so the pass-kind decisions and the failure paths are
/// exact and camera-free. The **shipped engine** is exercised for real on a
/// rendered frame, so "on device" is evidenced by Vision rather than asserted.
final class LiveTextDetectorTests: XCTestCase {

    private var bus: LiveTranslateSanitisingBus!
    private var engine: ScriptedRecognitionEngine!
    /// The object seam, scripted and empty by default: a policy test decides
    /// the scene's objects the way it decides its lines.
    private var objects: StubObjectDetectionEngine!
    private var clock: Clock!

    /// The injectable time source: the cadence is advanced, never slept.
    final class Clock {
        var now: TimeInterval = 1_000
        func advance(by seconds: TimeInterval) { now += seconds }
    }

    override func setUp() {
        super.setUp()
        bus = LiveTranslateSanitisingBus()
        engine = ScriptedRecognitionEngine()
        objects = StubObjectDetectionEngine()
        clock = Clock()
    }

    private func makeDetector(config: LiveTranslateConfig = .default) -> LiveTextDetector {
        LiveTextDetector(config: config,
                         observabilityBus: bus,
                         engine: engine,
                         objectEngine: objects,
                         now: { [clock] in clock?.now ?? 0 })
    }

    private func frame() throws -> CameraFrame {
        try XCTUnwrap(CameraFrame(sampleBuffer: SampleBufferFactory.make(
            width: 64, height: 48, pts: CMTime(value: 1, timescale: 1))))
    }

    /// A frame painted a solid luminance, so the frame-change gate can tell one
    /// delivered frame from the next. `SampleBufferFactory.make` paints nothing,
    /// and two unpainted frames are — correctly — the same picture, which the
    /// feature now reads as "recognition could not learn anything new".
    private func frame(luma: UInt8, width: Int = 64, height: Int = 48) throws -> CameraFrame {
        let sample = try SampleBufferFactory.make(width: width, height: height,
                                                  pts: CMTime(value: 1, timescale: 1))
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
        return try XCTUnwrap(CameraFrame(sampleBuffer: sample))
    }

    private func region(_ text: String, x: Double = 0.2, y: Double = 0.2) -> LiveTextDetector.DetectedTextRegion {
        LiveTextDetector.DetectedTextRegion(
            text: text,
            normalizedBox: NormalizedBox(xMin: x, yMin: y, xMax: x + 0.2, yMax: y + 0.1),
            detectedLanguage: nil,
            confidence: 0.9)
    }

    private func box(_ x: Double) -> NormalizedBox {
        NormalizedBox(xMin: x, yMin: 0.1, xMax: x + 0.2, yMax: 0.2)
    }

    /// The same painted frame, carrying the window the display is showing
    /// (owner follow-up, 2026-09-18). The session stamps this on every frame it
    /// delivers, so this is what a pass actually receives once the elder has
    /// zoomed or panned.
    private func frame(luma: UInt8, crop: LiveCameraCrop,
                       width: Int = 64, height: Int = 48) throws -> CameraFrame {
        let base = try frame(luma: luma, width: width, height: height)
        return CameraFrame(pixelBuffer: base.pixelBuffer,
                           pixelSize: base.pixelSize,
                           timestamp: base.timestamp,
                           zoomFactor: base.zoomFactor,
                           crop: crop)
    }

    /// A window exactly half of the frame on each axis, centred (or moved by
    /// `pan`): half of a 64 × 48 frame is 32 × 24 pixels whatever the rounding
    /// rule, so the assertions below are about *which* pixels Vision was given
    /// and not about a rounding convention.
    private func window(pan: CGPoint = .zero) -> LiveCameraCrop {
        var config = LiveTranslateConfig.default
        config.panWindowFraction = 0.5
        return LiveCameraZoomModel(config: config, factor: 4, pan: pan,
                                   deviceRange: 1...8, deviceSwitchOverFactors: []).crop
    }

    // MARK: Scenario: the OCR pass is the only source of recognized text

    func testAnOCRPassProducesTextAndNoTrackedGeometry() async throws {
        engine.regions = [region("Exit"), region("Push", y: 0.6)]
        let detector = makeDetector()
        XCTAssertTrue(detector.begin().isSuccess)

        let result = await detector.recognize(try frame())

        guard case .success(let pass) = result else { return XCTFail("expected a pass: \(result)") }
        XCTAssertEqual(pass.regions.map(\.text), ["Exit", "Push"])
        XCTAssertTrue(pass.trackedBoxes.isEmpty,
                      "an OCR pass anchors geometry; it does not report tracked boxes")
        XCTAssertEqual(bus.events(named: "ocr_pass").first?.metadata["regionCount"], "2")
        XCTAssertEqual(bus.events(named: "ocr_pass").first?.outcome, "success")
    }

    func testATrackingPassProducesGeometryOnlyAndCannotChangeText() async throws {
        engine.regions = [region("Exit"), region("Push", y: 0.6)]
        engine.trackedBoxes = ["Exit": box(0.25), "Push": box(0.55)]
        let detector = makeDetector()
        XCTAssertTrue(detector.begin().isSuccess)

        _ = await detector.recognize(try frame(luma: 0))
        clock.advance(by: detector.config.ocrSampleInterval / 2)
        let result = await detector.recognize(try frame(luma: 90))

        guard case .success(let pass) = result else { return XCTFail("expected a pass: \(result)") }
        XCTAssertEqual(engine.trackCallCount, 1, "the second pass is the tracking kind")
        XCTAssertTrue(pass.regions.isEmpty,
                      "a tracking pass has no string in its output: text changes only on an OCR pass")
        XCTAssertEqual(pass.trackedBoxes, ["Exit": box(0.25), "Push": box(0.55)])
    }

    // MARK: Scenario: tracking carries position between OCR passes

    func testATrackingLossOmitsTheKeyRatherThanMovingOrDroppingTheRegion() async throws {
        engine.regions = [region("Exit"), region("Push", y: 0.6)]
        // The tracker held "Exit" and lost "Push" on this frame.
        engine.trackedBoxes = ["Exit": box(0.25)]
        let detector = makeDetector()
        _ = detector.begin()

        _ = await detector.recognize(try frame(luma: 0))
        clock.advance(by: detector.config.ocrSampleInterval / 2)
        let result = await detector.recognize(try frame(luma: 90))

        guard case .success(let pass) = result else { return XCTFail("expected a pass: \(result)") }
        XCTAssertEqual(Array(pass.trackedBoxes.keys), ["Exit"],
                       "a lost key is absent, so the stabiliser keeps the last OCR-confirmed geometry")
        XCTAssertEqual(pass.trackedBoxes["Exit"], box(0.25))
    }

    /// The tracking pass costs one `VNTrackRectangleRequest` per remembered
    /// rectangle, so a still scene used to buy a burst of Vision requests for
    /// geometry that could only come back the same. A tracker cannot find
    /// movement that is not there: the pass is skipped and the frame gets the
    /// OCR refresh it was delivered for.
    func testAStillSceneIsNotTrackedAndAChangedOneIs() async throws {
        engine.regions = [region("Exit")]
        let detector = makeDetector()
        _ = detector.begin()

        _ = await detector.recognize(try frame(luma: 0))
        clock.advance(by: detector.config.ocrSampleInterval / 2)
        _ = await detector.recognize(try frame(luma: 0))
        XCTAssertEqual(engine.trackCallCount, 0,
                       "the same picture as the last OCR'd frame has nothing to follow")
        XCTAssertEqual(engine.recognizeCallCount, 2,
                       "the frame is not dropped: it is read again (an OCR refresh)")

        clock.advance(by: detector.config.ocrSampleInterval / 2)
        _ = await detector.recognize(try frame(luma: 90))
        XCTAssertEqual(engine.trackCallCount, 1,
                       "a materially different picture is what tracking exists for")
    }

    func testTrackingIsNotEvenAttemptedWhenAnOCRPassRecognizedNothing() async throws {
        engine.regions = []
        let detector = makeDetector()
        _ = detector.begin()

        _ = await detector.recognize(try frame())
        clock.advance(by: detector.config.ocrSampleInterval / 2)
        _ = await detector.recognize(try frame())

        XCTAssertEqual(engine.trackCallCount, 0,
                       "with nothing remembered there is no rectangle to follow: OCR runs instead")
        XCTAssertEqual(engine.recognizeCallCount, 2)
    }

    // MARK: Scenario: an unreadable frame is not an error

    func testAnEmptyPassSucceedsWithNoRegionsAndReportsTheEmptyOutcome() async throws {
        engine.regions = []
        let detector = makeDetector()
        _ = detector.begin()

        let result = await detector.recognize(try frame())

        XCTAssertEqual(result, .success(LiveTextDetector.Pass(regions: [], trackedBoxes: [:])))
        let events = bus.events(named: "ocr_pass")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.outcome, "empty", "zero regions is the empty-state hint")
        XCTAssertEqual(events.first?.metadata["regionCount"], "0")
        XCTAssertTrue(bus.events(named: "ocr_pass_failed").isEmpty)
    }

    // MARK: Scenario: a failed pass is dropped, never surfaced

    func testAFailedPassIsReportedAsAFailureRecordedOnceAndNotLatched() async throws {
        engine.errorToThrow = StubFailure(message: "vision refused")
        let detector = makeDetector()
        _ = detector.begin()

        let failed = await detector.recognize(try frame())

        XCTAssertEqual(failed.failureError, .ocrPassFailed(.requestFailed))
        XCTAssertEqual(bus.events(named: "ocr_pass_failed").count, 1)
        XCTAssertFalse(detector.isPassInFlight, "a failed pass must not wedge the in-flight flag")
        XCTAssertTrue(bus.events(named: "ocr_pass").isEmpty)

        // The next pass simply tries again — and succeeds.
        engine.errorToThrow = nil
        engine.regions = [region("Exit")]
        let retried = await detector.recognize(try frame())

        guard case .success(let pass) = retried else { return XCTFail("expected a pass: \(retried)") }
        XCTAssertEqual(pass.regions.map(\.text), ["Exit"])
    }

    func testNoRecognizedTextReachesTheEvents() async throws {
        engine.regions = [region("Emergency Exit"), region("आपतकालीन निकास", y: 0.6)]
        engine.trackedBoxes = ["Emergency Exit": box(0.3)]
        let detector = makeDetector()
        _ = detector.begin()

        _ = await detector.recognize(try frame())
        clock.advance(by: detector.config.ocrSampleInterval / 2)
        _ = await detector.recognize(try frame())

        for event in bus.events {
            XCTAssertEqual(event.component, LiveTranslateEventCatalogue.component)
            let entry = try XCTUnwrap(LiveTranslateEventCatalogue.entries[event.eventType])
            XCTAssertTrue(entry.outcomes.contains(event.outcome))
            XCTAssertTrue(entry.metadataKeys.isSuperset(of: Set(event.metadata.keys)))
            for value in event.metadata.values {
                XCTAssertFalse(value.contains(" "), "metadata carries counts and tokens, never text")
            }
            XCTAssertNil(event.metadata["text"])
        }
    }

    // MARK: Scenario: unsupported tracking degrades to OCR-only

    func testUnsupportedTrackingIsAnnouncedOnceAndTheDetectorKeepsWorkingWithOCR() async throws {
        engine.supportsTracking = false
        engine.regions = [region("Exit")]
        let detector = makeDetector()

        XCTAssertTrue(detector.begin().isSuccess, "tracking is a SHOULD: the feature stays usable")
        XCTAssertEqual(bus.events(named: "tracking_unsupported").count, 1)

        let result = await detector.recognize(try frame())

        guard case .success(let pass) = result else { return XCTFail("expected a pass: \(result)") }
        XCTAssertEqual(pass.regions.map(\.text), ["Exit"])
        XCTAssertEqual(engine.trackCallCount, 0)
        XCTAssertEqual(bus.events(named: "tracking_unsupported").count, 1,
                       "the degradation is announced once, not once per pass")
    }

    func testTurningTrackingOffInConfigIsNotADegradationAndIsNotReported() async throws {
        engine.supportsTracking = true
        engine.regions = [region("Exit")]
        var config = LiveTranslateConfig.default
        config.trackingEnabled = false
        let detector = makeDetector(config: config)

        _ = detector.begin()
        _ = await detector.recognize(try frame())
        clock.advance(by: config.ocrSampleInterval / 2)
        _ = await detector.recognize(try frame())

        XCTAssertEqual(engine.trackCallCount, 0, "a configured off is not a pass kind")
        XCTAssertTrue(bus.events(named: "tracking_unsupported").isEmpty,
                      "tracking switched off by configuration is the feature working as configured")
    }

    func testATrackingRequestTheDeviceRefusesDegradesTheDetectorAtThatMoment() async throws {
        engine.regions = [region("Exit")]
        engine.trackingError = StubFailure(message: "no tracker")
        let detector = makeDetector()
        _ = detector.begin()

        _ = await detector.recognize(try frame(luma: 0))
        clock.advance(by: detector.config.ocrSampleInterval / 2)
        let tracking = await detector.recognize(try frame(luma: 90))

        XCTAssertEqual(tracking, .failure(.trackingUnsupported),
                       "the refused request is reported to the caller, which drops it like any failed pass")
        XCTAssertEqual(bus.events(named: "tracking_unsupported").count, 1)

        // Degraded: the next frame runs OCR, and the refusal is not re-reported.
        clock.advance(by: detector.config.ocrSampleInterval / 2)
        let next = await detector.recognize(try frame(luma: 0))
        guard case .success(let pass) = next else { return XCTFail("expected a pass: \(next)") }
        XCTAssertEqual(pass.regions.map(\.text), ["Exit"])
        XCTAssertEqual(engine.trackCallCount, 1, "tracking is not attempted again after the refusal")
        XCTAssertEqual(bus.events(named: "tracking_unsupported").count, 1)
    }

    // MARK: The cadence (NFR-LCT-002)

    func testThePassKindFollowsTheConfiguredCadence() async throws {
        engine.regions = [region("Exit")]
        let detector = makeDetector()
        _ = detector.begin()
        _ = await detector.recognize(try frame(luma: 0))

        // A changed frame inside the interval is the tracking case.
        clock.advance(by: detector.config.ocrSampleInterval / 2)
        _ = await detector.recognize(try frame(luma: 90))
        XCTAssertEqual(engine.trackCallCount, 1)

        let base = LiveTranslateConfig.default.ocrSampleInterval
        XCTAssertEqual(detector.passKind(at: clock.now), .tracking,
                       "a changed frame inside the interval is followed")
        XCTAssertEqual(detector.passKind(at: clock.now + base / 2), .ocr,
                       "at the cadence an OCR pass is due")

        // The cadence is the config's value, not a literal: doubling it makes
        // the same moment fall inside the interval again.
        var slower = LiveTranslateConfig.default
        slower.ocrSampleInterval = base * 2
        let relaxed = makeDetector(config: slower)
        _ = relaxed.begin()
        _ = await relaxed.recognize(try frame(luma: 0))
        clock.advance(by: base)
        _ = await relaxed.recognize(try frame(luma: 90))
        XCTAssertEqual(engine.trackCallCount, 2,
                       "one base interval is still inside a doubled cadence: the changed frame is followed")
    }

    func testTrackingIsNeverTheFirstPassOfASession() async throws {
        engine.regions = [region("Exit")]
        let detector = makeDetector()
        _ = detector.begin()

        XCTAssertEqual(detector.passKind(at: clock.now), .ocr,
                       "there is nothing remembered to track before the first OCR pass")
    }

    // MARK: Lifecycle

    func testRecognizingBeforeBeginIsReportedRatherThanRun() async throws {
        let detector = makeDetector()

        let result = await detector.recognize(try frame())

        XCTAssertEqual(result.failureError, .ocrUnavailable(.requestCreationFailed))
        XCTAssertEqual(engine.recognizeCallCount, 0, "no pass is run without a session")
    }

    func testEndForgetsWhatWasRememberedAndTheDetectorIsUsableAgainAfterBegin() async throws {
        engine.regions = [region("Exit")]
        let detector = makeDetector()
        _ = detector.begin()
        _ = await detector.recognize(try frame())

        detector.end()
        detector.end()

        XCTAssertEqual(engine.forgetCallCount, 1, "end() is idempotent")
        let afterEnd = await detector.recognize(try frame())
        XCTAssertEqual(afterEnd.failureError, .ocrUnavailable(.requestCreationFailed))

        _ = detector.begin()
        let result = await detector.recognize(try frame(luma: 0))
        guard case .success = result else { return XCTFail("expected a pass after re-begin: \(result)") }
        clock.advance(by: LiveTranslateConfig.default.ocrSampleInterval / 2)
        _ = await detector.recognize(try frame(luma: 90))
        XCTAssertEqual(engine.trackCallCount, 1,
                       "the re-begun session remembers the OCR pass it just made")
    }

    func testIsPassInFlightIsTrueForTheWholePassAndFalseAfterwards() async throws {
        let hold = DispatchSemaphore(value: 0)
        let entered = expectation(description: "the pass reached the engine")
        engine.hold = hold
        engine.onEnter = { entered.fulfill() }
        engine.regions = [region("Exit")]
        let detector = makeDetector()
        _ = detector.begin()
        XCTAssertFalse(detector.isPassInFlight)

        let sample = try frame()
        let pass = Task { await detector.recognize(sample) }
        await fulfillment(of: [entered], timeout: 5)

        XCTAssertTrue(detector.isPassInFlight,
                      "the camera's tap reads this to drop samples while Vision is busy")
        hold.signal()
        _ = await pass.value
        XCTAssertFalse(detector.isPassInFlight)
    }

    func testTwoConcurrentCallersAreSerialisedRatherThanRacingTheRequestHandler() async throws {
        let hold = DispatchSemaphore(value: 0)
        let entered = expectation(description: "the first pass reached the engine")
        // Both callers now run an *OCR* pass: the frames are identical, so the
        // scene gate declines to track and reads the frame again (see
        // `testAStillSceneIsNotTrackedAndAChangedOneIs`). The engine's entry
        // hook therefore fires once per caller, and the wait below is about the
        // first of them — the second firing is the second caller being served,
        // not an over-fulfilment to fail on.
        entered.assertForOverFulfill = false
        engine.hold = hold
        engine.onEnter = { entered.fulfill() }
        engine.regions = [region("Exit")]
        let detector = makeDetector()
        _ = detector.begin()

        let sample = try frame()
        let first = Task { await detector.recognize(sample) }
        await fulfillment(of: [entered], timeout: 5)
        let second = Task { await detector.recognize(sample) }
        // One permit per pass: the first caller is released here, and the
        // second takes the second permit when the engine hands it the pass.
        hold.signal()
        hold.signal()

        _ = await first.value
        _ = await second.value

        XCTAssertEqual(engine.maxConcurrentRecognitions, 1,
                       "one pass at a time: Vision's request handler is never shared")
        XCTAssertEqual(engine.recognizeCallCount + engine.trackCallCount, 2,
                       "the second caller was served (as the pass its cadence calls for), not dropped")
    }

    // MARK: Recognition is on device (NFR-LCT-001)

    // MARK: Scenario: the elder's window (owner follow-up, 2026-09-18)

    func testAnOCRPassReadsTheWindowAndReportsItsBoxesInTheFramesOwnCoordinates() async throws {
        // What the elder can see is what recognition reads — a whole-buffer pass
        // would OCR text they cannot see and miss the label they zoomed in for —
        // and what comes back is in the *frame's* coordinates, because that is
        // the space every consumer of a box speaks (the stabiliser, the
        // placement, the overlay).
        let crop = window()
        XCTAssertEqual(crop.box, NormalizedBox(xMin: 0.25, yMin: 0.25, xMax: 0.75, yMax: 0.75))
        engine.regions = [region("Exit", x: 0.25, y: 0.4)]
        let detector = makeDetector()
        XCTAssertTrue(detector.begin().isSuccess)

        let result = await detector.recognize(try frame(luma: 30, crop: crop))

        guard case .success(let pass) = result else { return XCTFail("expected a pass: \(result)") }
        XCTAssertEqual(engine.recognizedBufferSizes.last, CGSize(width: 32, height: 24),
                       "Vision is handed the window at the sensor's own resolution — half of a "
                       + "64 × 48 frame — not the whole buffer and not an enlarged screen image")
        let box = try XCTUnwrap(pass.regions.first?.normalizedBox)
        XCTAssertEqual(box.xMin, 0.375, accuracy: 1e-12)
        XCTAssertEqual(box.yMin, 0.45, accuracy: 1e-12)
        XCTAssertEqual(box.xMax, 0.475, accuracy: 1e-12)
        XCTAssertEqual(box.yMax, 0.5, accuracy: 1e-12)
        XCTAssertNotEqual(box.xMin, 0.25,
                          "the window's own coordinates would have put the box at the frame's left edge")
    }

    func testATrackingPassFollowsTheWindowTooAndReportsFrameCoordinates() async throws {
        let crop = window()
        engine.regions = [region("Exit")]
        engine.trackedBoxes = ["Exit": box(0.25)]
        let detector = makeDetector()
        _ = detector.begin()

        _ = await detector.recognize(try frame(luma: 0, crop: crop))
        clock.advance(by: detector.config.ocrSampleInterval / 2)
        let result = await detector.recognize(try frame(luma: 90, crop: crop))

        guard case .success(let pass) = result else { return XCTFail("expected a pass: \(result)") }
        XCTAssertEqual(engine.trackCallCount, 1, "the window is the picture a tracker follows in")
        let tracked = try XCTUnwrap(pass.trackedBoxes["Exit"])
        XCTAssertEqual(tracked.xMin, 0.375, accuracy: 1e-12,
                       "a tracked box is in the frame's coordinates, like a recognized one")
        XCTAssertEqual(tracked.yMin, 0.3, accuracy: 1e-12)
    }

    func testAMovedWindowDropsWhatWasRememberedBeforeThePassKindIsChosen() async throws {
        // The engine remembers the last OCR pass's rectangles *in the buffer
        // that pass saw*. A tracker following one of them in a differently
        // cropped buffer would put a region's geometry — and the text drawn
        // over that geometry — on a different label, so the rectangles go
        // before the frame's pass kind is even chosen.
        let first = window()
        let moved = window(pan: CGPoint(x: 0.25, y: 0))
        engine.regions = [region("Exit")]
        engine.trackedBoxes = ["Exit": box(0.25)]
        let detector = makeDetector()
        _ = detector.begin()

        _ = await detector.recognize(try frame(luma: 0, crop: first))
        XCTAssertEqual(engine.forgetCallCount, 1,
                       "the first pass runs on the session's window, not the whole frame: nothing "
                       + "remembered before it is about this picture")

        clock.advance(by: detector.config.ocrSampleInterval / 2)
        let result = await detector.recognize(try frame(luma: 90, crop: moved))

        XCTAssertEqual(engine.trackCallCount, 0,
                       "a changed scene would normally be tracked; a moved window cannot be, "
                       + "because the remembered rectangle belongs to the old picture")
        XCTAssertEqual(engine.forgetCallCount, 2, "and it is dropped before the pass kind is chosen")
        guard case .success(let pass) = result else { return XCTFail("expected a pass: \(result)") }
        XCTAssertEqual(pass.regions.map(\.text), ["Exit"], "the frame gets the OCR pass that re-anchors")
    }

    func testASessionThatNeverMovedItsWindowStillPaysNoForgetForIt() async throws {
        // The whole-frame window is the feature's pre-window behaviour, and it
        // must stay free of the window's bookkeeping: no engine forget, no
        // dropped anchors, for every session that never zooms.
        engine.regions = [region("Exit")]
        engine.trackedBoxes = ["Exit": box(0.25)]
        let detector = makeDetector()
        _ = detector.begin()

        _ = await detector.recognize(try frame(luma: 0))
        clock.advance(by: detector.config.ocrSampleInterval / 2)
        let result = await detector.recognize(try frame(luma: 90))

        XCTAssertEqual(engine.forgetCallCount, 0)
        guard case .success(let pass) = result else { return XCTFail("expected a pass: \(result)") }
        XCTAssertEqual(pass.trackedBoxes["Exit"], box(0.25),
                       "the box comes back exactly as Vision reported it: no crop, no conversion")
    }

    func testTheDetectorReachesNoNetworkAndDownloadsNoModel() {
        let file = FeatureSourceScan.iosDirectory()
            .appendingPathComponent(FeatureSourceScan.liveTranslateSources)
            .appendingPathComponent("LiveTextDetector.swift")
        let code = FeatureSourceScan.codeText(of: file)
        XCTAssertFalse(code.isEmpty, "the detector source must be scanned, not skipped")

        let networkAndDownload = [
            "URLSession", "URLRequest", "dataTask", "URLComponents", "NWConnection",
            "http://", "https://", "GeminiClient", "VNCoreMLModel", "MLModel",
            "url(forResource"
        ]
        for token in networkAndDownload {
            let pattern = NSRegularExpression.escapedPattern(for: token)
            XCTAssertNil(FeatureSourceScan.firstMatch(of: pattern, in: code),
                         "\(token) does not belong in on-device recognition (FR-LCT-003)")
        }
        XCTAssertTrue(code.contains("import Vision"), "recognition is Vision's, and it is local")
    }

    // MARK: Scenario: the object pass is the slow pass, so it runs on its own cadence

    private func sceneObject(_ label: String?,
                             _ xMin: Double, _ yMin: Double,
                             _ xMax: Double, _ yMax: Double) -> LiveTextDetector.DetectedSceneObject {
        LiveTextDetector.DetectedSceneObject(
            classLabel: label,
            normalizedBox: NormalizedBox(xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax),
            confidence: 0.7)
    }

    /// One OCR pass per call, by advancing the clock past the OCR interval
    /// before each frame.
    private func ocrPass(_ detector: LiveTextDetector, luma: UInt8) async throws
        -> Result<LiveTextDetector.Pass, LiveTranslateError> {
        clock.advance(by: detector.config.ocrSampleInterval + 1)
        return await detector.recognize(try frame(luma: luma))
    }

    func testTheObjectPassRunsOnTheFirstOCROfASceneAndThenOnItsCadence() async throws {
        objects.objects = [sceneObject("microwave", 0.1, 0.1, 0.6, 0.6)]
        engine.regions = [region("START", x: 0.2, y: 0.2)]
        let detector = makeDetector()
        _ = detector.begin()

        _ = try await ocrPass(detector, luma: 0)
        XCTAssertEqual(objects.detectCallCount, 1, "the first OCR of a scene detects")

        // Inside the cadence, the pass reuses what it has: the object is the
        // expensive request, and a scene's objects do not change between two
        // frames a fifth of a second apart.
        _ = try await ocrPass(detector, luma: 30)
        XCTAssertEqual(objects.detectCallCount, 1,
                       "the object pass is the slow pass: it is not run per frame")

        clock.advance(by: detector.config.objectPassCadenceSeconds + 1)
        _ = try await ocrPass(detector, luma: 60)
        XCTAssertEqual(objects.detectCallCount, 2, "once the cadence is due, it runs again")

        XCTAssertEqual(bus.events(named: "object_pass").count, 2)
        XCTAssertEqual(bus.events(named: "object_pass").last?.metadata["count"], "1")
        XCTAssertEqual(bus.events(named: "object_pass").first?.outcome, "success")
    }

    func testTheCachedObjectsStillGroupThePassThatDidNotDetect() async throws {
        objects.objects = [sceneObject("microwave", 0.1, 0.1, 0.6, 0.6)]
        engine.regions = [region("START", x: 0.2, y: 0.2)]
        let detector = makeDetector()
        _ = detector.begin()

        _ = try await ocrPass(detector, luma: 0)
        let second = try await ocrPass(detector, luma: 30)
        XCTAssertEqual(objects.detectCallCount, 1, "no second detection")

        guard case .success(let pass) = second else { return XCTFail("expected a pass: \(second)") }
        XCTAssertEqual(pass.objects.count, 1,
                       "the cached objects are the pass's objects: a pass without a detection "
                       + "groups against the scene the last detection described")
    }

    func testAFailedObjectPassDegradesAndThePassStillSucceeds() async throws {
        objects.errorToThrow = StubFailure(message: "no saliency here")
        engine.regions = [region("Exit")]
        let detector = makeDetector()
        _ = detector.begin()

        let result = try await ocrPass(detector, luma: 0)

        guard case .success(let pass) = result else {
            return XCTFail("the object pass is a SHOULD: a scene with no objects is grouped "
                           + "by text geometry, which is what every pass did before: \(result)")
        }
        XCTAssertEqual(pass.regions.map(\.text), ["Exit"])
        XCTAssertTrue(pass.objects.isEmpty)
        XCTAssertEqual(bus.events(named: "object_pass_failed").count, 1,
                       "a refused object request is reported as a failure, once")
        XCTAssertEqual(bus.events(named: "object_pass_failed").first?.errorCode,
                       LiveTranslateError.ocrPassFailed(.requestFailed).logSafeErrorCode,
                       "the taxonomy's code, in the shape ocr_pass_failed records one")
        XCTAssertTrue(bus.events(named: "object_detection_unsupported").isEmpty,
                      "the runtime has the capability: it refused this request, which is a "
                      + "different fact and a different event")

        // And it stays degraded: the request is not retried every frame.
        _ = try await ocrPass(detector, luma: 30)
        XCTAssertEqual(objects.detectCallCount, 1,
                       "a failed object pass is not a per-frame retry loop")
    }

    func testAnEngineWithNoObjectSupportAnnouncesItOnceAndStaysUsable() async throws {
        let unsupported = StubObjectDetectionEngine(supportsObjectDetection: false)
        let detector = LiveTextDetector(config: .default,
                                        observabilityBus: bus,
                                        engine: engine,
                                        objectEngine: unsupported,
                                        now: { [clock] in clock?.now ?? 0 })
        engine.regions = [region("Exit")]
        XCTAssertTrue(detector.begin().isSuccess)
        XCTAssertEqual(bus.events(named: "object_detection_unsupported").count, 1)

        let result = try await ocrPass(detector, luma: 0)
        guard case .success(let pass) = result else { return XCTFail("expected a pass: \(result)") }
        XCTAssertEqual(pass.regions.map(\.text), ["Exit"])
        XCTAssertTrue(bus.events(named: "object_pass").isEmpty,
                      "an unsupported engine is never asked, so it never reports a pass")
    }

    func testTheLivePassIsCappedAndTheStillPassIsNot() async throws {
        // Five separated panels: more surfaces than the cap allows.
        var lines: [LiveTextDetector.DetectedTextRegion] = []
        for panel in 0..<5 {
            let y = 0.02 + Double(panel) * 0.18
            lines.append(LiveTextDetector.DetectedTextRegion(
                text: "P\(panel)",
                normalizedBox: NormalizedBox(xMin: 0.1, yMin: y, xMax: 0.6, yMax: y + 0.06),
                detectedLanguage: nil, confidence: 0.9))
        }
        engine.regions = lines
        let detector = makeDetector()
        _ = detector.begin()

        let live = await detector.recognize(try frame())
        guard case .success(let livePass) = live else { return XCTFail("expected a pass: \(live)") }
        XCTAssertEqual(livePass.regions.count, detector.config.maxVisibleBlocks,
                       "the live overlay carries the few surfaces a person can read")

        let still = await detector.recognizeStillFrame(try frame())
        guard case .success(let stillPass) = still else { return XCTFail("expected a pass: \(still)") }
        XCTAssertEqual(stillPass.regions.count, 5,
                       "the snapshot card is the fully-readable mode: it has no overlay to crowd")
        XCTAssertTrue(livePass.regions.allSatisfy { stillPass.regions.contains($0) },
                      "the still path's blocks are the live path's blocks — the cap selects "
                      + "from one grouping rather than regrouping the scene")
    }

    func testATrackingPassCarriesABlocksGeometryUnderTheBlocksIdentity() async throws {
        // Two lines inside one object: the pass hands the stabiliser one
        // surface, and a tracking pass follows that surface — not its lines.
        objects.objects = [sceneObject("microwave", 0.1, 0.1, 0.7, 0.7)]
        engine.regions = [region("START", x: 0.2, y: 0.2), region("2 MIN", x: 0.2, y: 0.35)]
        // The engine follows *lines* — that is what it was given — and the
        // detector re-keys them into the block the stabiliser holds.
        engine.trackedBoxes = ["START": NormalizedBox(xMin: 0.25, yMin: 0.25,
                                                      xMax: 0.45, yMax: 0.35),
                               "2 MIN": NormalizedBox(xMin: 0.25, yMin: 0.40,
                                                      xMax: 0.45, yMax: 0.50)]
        let detector = makeDetector()
        _ = detector.begin()

        let first = await detector.recognize(try frame(luma: 0))
        guard case .success(let firstPass) = first else { return XCTFail("expected a pass: \(first)") }
        XCTAssertEqual(firstPass.regions.map(\.text), ["START\n2 MIN"],
                       "the object's lines are one surface")
        XCTAssertNotNil(firstPass.regions.first?.blockIdentity,
                        "a block reaches the stabiliser with the identity that makes it sticky")

        clock.advance(by: detector.config.ocrSampleInterval / 2)
        let second = await detector.recognize(try frame(luma: 90))
        guard case .success(let secondPass) = second else { return XCTFail("expected a pass: \(second)") }
        XCTAssertTrue(secondPass.regions.isEmpty, "a tracking pass has no text")
        XCTAssertEqual(secondPass.trackedBoxes.count, 1)
        let tracked = secondPass.trackedBoxes["START\n2 MIN"]
        XCTAssertEqual(tracked?.xMin ?? -1, 0.25, accuracy: 0.0001,
                       "the block's geometry comes back under the block's own key")
        XCTAssertEqual(tracked?.yMin ?? -1, 0.25, accuracy: 0.0001,
                       "…and it is the union of the members that were followed")
        XCTAssertEqual(tracked?.yMax ?? -1, 0.50, accuracy: 0.0001)
    }
}

// MARK: - The shipped engine, on a rendered frame

/// The same detector, driven by `VisionTextRecognitionEngine` — the shipped
/// path — over frames rendered in memory. This is where "on device" stops
/// being a claim.
final class VisionTextRecognitionEngineTests: XCTestCase {

    private var bus: LiveTranslateSanitisingBus!

    override func setUp() {
        super.setUp()
        bus = LiveTranslateSanitisingBus()
    }

    private func makeDetector() -> LiveTextDetector {
        LiveTextDetector(config: .default, observabilityBus: bus)
    }

    private func recognize(_ text: String, pointSize: CGFloat = 72) throws -> LiveTextDetector.Pass? {
        let frame = try XCTUnwrap(CameraFrame(sampleBuffer: SampleBufferFactory.make(
            width: 1200, height: 400, pts: CMTime(value: 1, timescale: 1))))
        try render(lines: [text], pointSize: pointSize, into: frame.pixelBuffer)
        let detector = makeDetector()
        XCTAssertTrue(detector.begin().isSuccess)
        guard case .success(let pass) = awaitResult(detector, frame) else { return nil }
        return pass
    }

    /// `recognize` is asynchronous; this bridges it for the synchronous
    /// helpers above without a second event-loop library.
    private func awaitResult(_ detector: LiveTextDetector, _ frame: CameraFrame) -> Result<LiveTextDetector.Pass, LiveTranslateError> {
        var outcome: Result<LiveTextDetector.Pass, LiveTranslateError>?
        let done = DispatchSemaphore(value: 0)
        Task {
            outcome = await detector.recognize(frame)
            done.signal()
        }
        done.wait()
        return outcome ?? .failure(.ocrPassFailed(.requestFailed))
    }

    func testEnglishTextIsRecognizedOnDeviceWithAValidBoxInReadingOrientation() throws {
        let pass = try XCTUnwrap(recognize("Emergency Exit"))

        let region = try XCTUnwrap(pass.regions.first { $0.text.localizedCaseInsensitiveContains("emergency") },
                                   "Vision read nothing from the rendered frame: \(pass.regions.map(\.text))")
        XCTAssertTrue(region.normalizedBox.isValid)
        XCTAssertGreaterThanOrEqual(region.normalizedBox.xMin, 0)
        XCTAssertLessThanOrEqual(region.normalizedBox.xMax, 1)
        XCTAssertGreaterThanOrEqual(region.normalizedBox.yMin, 0)
        XCTAssertLessThanOrEqual(region.normalizedBox.yMax, 1)
        // The line is rendered near the top of the frame. Vision reports boxes
        // with a bottom-left origin, so this is only true if the detector
        // mirrored `y` into the feature's top-left representation.
        XCTAssertLessThan(region.normalizedBox.center.y, 0.5,
                          "the box must be in the feature's top-left orientation")
        XCTAssertGreaterThan(region.confidence, 0)
        XCTAssertNil(region.detectedLanguage,
                     "the classic Vision API reports no per-observation language: omit it, never guess")
        XCTAssertEqual(bus.events(named: "ocr_pass").first?.outcome, "success")
    }

    func testTheTrackingPassFollowsARememberedRectangleAndNeverReturnsText() throws {
        let frame = try XCTUnwrap(CameraFrame(sampleBuffer: SampleBufferFactory.make(
            width: 1200, height: 400, pts: CMTime(value: 1, timescale: 1))))
        try render(lines: ["Emergency Exit"], pointSize: 72, into: frame.pixelBuffer)
        let engine = VisionTextRecognitionEngine()

        let regions = try engine.recognizeText(in: frame.pixelBuffer)
        let text = try XCTUnwrap(regions.first?.text)
        let tracked = try engine.followRememberedRectangles(in: frame.pixelBuffer)

        XCTAssertNotNil(tracked[text], "the same frame must still hold the rectangle it just found")
        XCTAssertEqual(tracked.count, 1)
        for value in tracked.values {
            XCTAssertTrue(value.isValid, "the tracking pass reports geometry, and geometry is valid or absent")
        }
    }

    func testForgettingTheRectanglesEndsTracking() throws {
        let frame = try XCTUnwrap(CameraFrame(sampleBuffer: SampleBufferFactory.make(
            width: 1200, height: 400, pts: CMTime(value: 1, timescale: 1))))
        try render(lines: ["Emergency Exit"], pointSize: 72, into: frame.pixelBuffer)
        let engine = VisionTextRecognitionEngine()

        _ = try engine.recognizeText(in: frame.pixelBuffer)
        engine.forgetRememberedRectangles()

        XCTAssertEqual(try engine.followRememberedRectangles(in: frame.pixelBuffer), [:])
    }

    /// A tracking pass runs one `VNTrackRectangleRequest` per remembered
    /// rectangle, one after another on a serial handler: a dense scene is the
    /// shape that turns one delivered frame into a dozen Vision requests. The
    /// cap is the shipped policy, and it follows the largest boxes — the ones
    /// big enough for the overlay to draw.
    func testTheTrackingPassFollowsTheLargestRectanglesAndOnlySoManyOfThem() {
        let remembered: [(text: String, area: Double)] = [
            ("smallest", 0.01), ("largest", 0.09), ("third", 0.05), ("fourth", 0.04),
            ("fifth", 0.03), ("sixth", 0.02), ("second", 0.08), ("seventh", 0.07)
        ]

        XCTAssertEqual(VisionTextRecognitionEngine.rectanglesToFollow(remembered, maximum: 3),
                       ["largest", "second", "seventh"],
                       "one request per region the elder can see: the surplus is not followed")
        XCTAssertEqual(VisionTextRecognitionEngine.rectanglesToFollow(remembered, maximum: 8).count, 8,
                       "a scene under the cap is followed whole")
        XCTAssertEqual(VisionTextRecognitionEngine.rectanglesToFollow([("b", 0.5), ("a", 0.5)],
                                                                      maximum: 1),
                       ["a"],
                       "equal areas are decided by the string, so one scene has one fixed answer")
        XCTAssertTrue(VisionTextRecognitionEngine.rectanglesToFollow(remembered, maximum: 0).isEmpty,
                      "a cap of zero follows nothing rather than everything")
    }

    /// The platform gap, made visible in code rather than only in prose: this
    /// runtime's Vision has no Devanagari (or Devanagari-adjacent) recognition
    /// language, so the Nepali half of T-007's first scenario cannot be
    /// satisfied by Vision here. The day Apple ships one, this test fails and
    /// points at the integration test that must then assert real recognition.
    func testTheRuntimeHasNoDevanagariRecognitionLanguage() throws {
        let languages = try VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate, revision: 3)

        let devanagari = languages.filter {
            let code = $0.lowercased()
            return code.hasPrefix("ne") || code.hasPrefix("hi") || code.hasPrefix("sa") || code.hasPrefix("mr")
        }
        XCTAssertEqual(devanagari, [],
                       "Vision now lists Devanagari (\(devanagari)): T-007's Nepali recognition scenario can be "
                       + "asserted for real — extend the integration test and close the TG-02 open item")
    }

    func testADevanagariFrameIsNotAnErrorAndNeverInventsTextOrLanguage() throws {
        let frame = try XCTUnwrap(CameraFrame(sampleBuffer: SampleBufferFactory.make(
            width: 1200, height: 400, pts: CMTime(value: 1, timescale: 1))))
        try render(lines: ["आपतकालीन निकास"], pointSize: 72, into: frame.pixelBuffer)
        let detector = makeDetector()
        XCTAssertTrue(detector.begin().isSuccess)

        let result = awaitResult(detector, frame)

        // Whatever Vision makes of the glyphs here, the contract this test
        // pins is: a Devanagari frame is not a failure, no language is
        // invented, and the empty outcome is reported honestly when nothing is
        // recognized.
        guard case .success(let pass) = result else {
            return XCTFail("a Devanagari frame must not be a failed pass: \(result)")
        }
        for region in pass.regions {
            XCTAssertNil(region.detectedLanguage, "no language may be invented for a recognized string")
        }
        let event = try XCTUnwrap(bus.events(named: "ocr_pass").first)
        XCTAssertEqual(event.outcome, pass.regions.isEmpty ? "empty" : "success",
                       "the outcome must match what the pass actually produced")
    }

    // MARK: Helpers

    /// Renders a line of text into `pixelBuffer` in black on white, near the
    /// top of the frame. CoreText, so the frame is a real image Vision reads.
    private func render(lines: [String], pointSize: CGFloat, into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw StubFailure(message: "could not build a bitmap context over the frame")
        }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(UIColor.black.cgColor)
        let font = UIFont.systemFont(ofSize: pointSize)
        var y = CGFloat(height) - pointSize - 40
        for line in lines {
            let attributed = NSAttributedString(string: line, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(ctLine, context)
            y -= pointSize + 40
        }
    }
}

// MARK: - The scripted engine

/// The recognition seam, scripted: what Vision returns, what it throws, and
/// what it was asked for. Real `CVPixelBuffer`s still arrive, so the detector's
/// frame handling is the code under test.
final class ScriptedRecognitionEngine: LiveTextRecognitionEngine {

    var supportsTracking = true
    var regions: [LiveTextDetector.DetectedTextRegion] = []
    var trackedBoxes: [String: NormalizedBox] = [:]
    var errorToThrow: Error?
    var trackingError: Error?

    private(set) var recognizeCallCount = 0
    private(set) var trackCallCount = 0
    private(set) var forgetCallCount = 0
    private(set) var maxConcurrentRecognitions = 0
    /// The pixel size of every buffer Vision was handed, in order: what the
    /// pass actually read, which is how "recognition follows the window" is
    /// measured without a camera.
    private(set) var recognizedBufferSizes: [CGSize] = []

    /// Holds a pass open so a test can inspect the in-flight state.
    var hold: DispatchSemaphore?
    var onEnter: (() -> Void)?

    private let lock = NSLock()
    private var active = 0

    func recognizeText(in pixelBuffer: CVPixelBuffer) throws -> [LiveTextDetector.DetectedTextRegion] {
        lock.lock()
        recognizeCallCount += 1
        active += 1
        maxConcurrentRecognitions = max(maxConcurrentRecognitions, active)
        recognizedBufferSizes.append(CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                            height: CVPixelBufferGetHeight(pixelBuffer)))
        lock.unlock()
        defer {
            lock.lock(); active -= 1; lock.unlock()
        }
        onEnter?()
        hold?.wait()
        if let errorToThrow { throw errorToThrow }
        return regions
    }

    func followRememberedRectangles(in pixelBuffer: CVPixelBuffer) throws -> [String: NormalizedBox] {
        lock.lock(); trackCallCount += 1; lock.unlock()
        if let trackingError { throw trackingError }
        return trackedBoxes
    }

    func forgetRememberedRectangles() {
        lock.lock(); forgetCallCount += 1; lock.unlock()
    }
}
