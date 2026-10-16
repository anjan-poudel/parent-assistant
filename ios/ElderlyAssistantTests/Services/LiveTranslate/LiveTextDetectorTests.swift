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
    /// movement that is not there: the pass is skipped and the frame is
    /// restated from the last read instead (`.reused` — see the reuse tests
    /// below for the OCR half of the same rule).
    func testAStillSceneIsNotTrackedAndAChangedOneIs() async throws {
        engine.regions = [region("Exit")]
        let detector = makeDetector()
        _ = detector.begin()

        _ = await detector.recognize(try frame(luma: 0))
        clock.advance(by: detector.config.ocrSampleInterval / 2)
        _ = await detector.recognize(try frame(luma: 0))
        XCTAssertEqual(engine.trackCallCount, 0,
                       "the same picture as the last OCR'd frame has nothing to follow")
        XCTAssertEqual(engine.recognizeCallCount, 1,
                       "and nothing to re-read either: the frame is not dropped, it is restated")

        // A change that lands on the cadence is read: the sample interval has
        // passed since the last real pass, so a new picture deserves one.
        clock.advance(by: detector.config.ocrSampleInterval / 2)
        _ = await detector.recognize(try frame(luma: 90))
        XCTAssertEqual(engine.recognizeCallCount, 2)
        XCTAssertEqual(engine.trackCallCount, 0)

        // A change *inside* the interval is the case tracking exists for.
        clock.advance(by: detector.config.ocrSampleInterval / 2)
        _ = await detector.recognize(try frame(luma: 200))
        XCTAssertEqual(engine.trackCallCount, 1,
                       "a materially different picture is what tracking exists for")
    }

    func testTrackingIsNotEvenAttemptedWhenAnOCRPassRecognizedNothing() async throws {
        engine.regions = []
        let detector = makeDetector()
        _ = detector.begin()

        _ = await detector.recognize(try frame())
        // Past the reuse allowance: an unchanged frame is read again rather
        // than restated, which is the only way a still picture can ever gain
        // the text it did not have (and the reason the allowance exists at
        // all).
        clock.advance(by: detector.config.ocrSampleInterval
                        * detector.config.ocrUnchangedReuseIntervals)
        _ = await detector.recognize(try frame())

        XCTAssertEqual(engine.trackCallCount, 0,
                       "with nothing remembered there is no rectangle to follow: OCR runs instead")
        XCTAssertEqual(engine.recognizeCallCount, 2)
    }

    // MARK: Scenario: an unchanged frame costs no Vision pass at all

    /// The owner's directive (2026-09-22): dedupe the OCR request itself, not
    /// only the tracking one.
    ///
    /// Vision is deterministic for a fixed input, so recognition over the frame
    /// the last pass already read can only return the regions it returned then.
    /// The frame is still *handed to the stabiliser* — the pass is restated
    /// whole, ids and geometry included — and that is what keeps the
    /// corroboration honest: a region on a still scene goes on being observed
    /// pass after pass (`consecutiveDetections`, the appearance hysteresis, the
    /// departure grace) instead of ageing out because the detector stopped
    /// speaking.
    func testAnUnchangedFrameIsRestatedInsteadOfReadAgain() async throws {
        engine.regions = [region("Exit"), region("Push", y: 0.6)]
        let detector = makeDetector()
        XCTAssertTrue(detector.begin().isSuccess)

        let first = await detector.recognize(try frame(luma: 0))
        XCTAssertEqual(engine.recognizeCallCount, 1)

        clock.advance(by: detector.config.ocrSampleInterval / 2)
        let second = await detector.recognize(try frame(luma: 0))

        XCTAssertEqual(engine.recognizeCallCount, 1,
                       "the hot cost — the Vision pass — is skipped on an unchanged frame")
        XCTAssertEqual(engine.trackCallCount, 0)
        guard case .success(let read) = first, case .success(let reused) = second else {
            return XCTFail("expected two passes: \(first) / \(second)")
        }
        XCTAssertEqual(reused, read, "the restatement is the last read, whole")
        XCTAssertEqual(reused.regions.map(\.text), ["Exit", "Push"])
        XCTAssertTrue(reused.trackedBoxes.isEmpty)

        let reuses = bus.events(named: "ocr_pass_reused")
        XCTAssertEqual(reuses.count, 1, "the reuse is on the evidence bus")
        XCTAssertEqual(reuses.first?.outcome, "success")
        XCTAssertEqual(reuses.first?.metadata["regionCount"], "2")
        XCTAssertEqual(bus.events(named: "ocr_pass").count, 1,
                       "one Vision pass covered both frames")
    }

    /// The gate is a signature, not a proof: a page can turn behind a lamp, a
    /// sign can be walked past slowly, and a 64 × 64 luminance comparison can
    /// read either as unchanged. The restatement is therefore **bounded** — past
    /// the allowance the frame is read again whether or not the gate still says
    /// the picture is the one the last pass saw.
    func testAStillSceneIsReadAgainOnceTheReuseAllowanceHasPassed() async throws {
        engine.regions = [region("Exit")]
        let detector = makeDetector()
        _ = detector.begin()

        _ = await detector.recognize(try frame(luma: 0))
        clock.advance(by: detector.config.ocrSampleInterval
                        * detector.config.ocrUnchangedReuseIntervals)
        _ = await detector.recognize(try frame(luma: 0))

        XCTAssertEqual(engine.recognizeCallCount, 2,
                       "the allowance bounds the restatement; it does not replace the pass")
        XCTAssertTrue(bus.events(named: "ocr_pass_reused").isEmpty)
    }

    /// The allowance must be reachable at all, which is a statement about the
    /// camera tap: the tap delivers an unchanged scene at `stableSampleInterval`
    /// (0.7 s), so an allowance of one nominal interval (0.25 s) would have
    /// expired before the next sample ever arrived and every still frame would
    /// have gone on being read. The shipped bound is checked against it here
    /// rather than left to the reader of two config values.
    func testTheReuseAllowanceOutlastsTheStillSceneSampleInterval() {
        let config = LiveTranslateConfig.default
        let allowance = config.ocrSampleInterval * config.ocrUnchangedReuseIntervals
        XCTAssertGreaterThan(allowance, config.stableSampleInterval,
                             "a bound the tap's own cadence cannot reach is a dead knob")
    }

    /// The one thing that must never be restated: another window's regions. A
    /// crop is a fresh read of a box the elder drew, so the frame after one has
    /// no cached pass to restate and gets the full pass — the same rule the
    /// crop test above states for the tracking half.
    func testACropLeavesNothingToRestate() async throws {
        engine.regions = [region("Exit")]
        engine.trackedBoxes = ["Exit": box(0.25)]
        let detector = makeDetector()
        _ = detector.begin()

        _ = await detector.recognize(try frame(luma: 0))
        _ = await detector.recognizeCrop(try frame(luma: 90).pixelBuffer)
        let readsAfterTheCrop = engine.recognizeCallCount

        clock.advance(by: detector.config.ocrSampleInterval / 2)
        _ = await detector.recognize(try frame(luma: 180))

        XCTAssertEqual(engine.recognizeCallCount, readsAfterTheCrop + 1,
                       "the live frame after a crop is read, not restated over regions "
                       + "the crop already replaced")
        XCTAssertTrue(bus.events(named: "ocr_pass_reused").isEmpty)
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
        // Both callers run a real *OCR* pass, so the engine's entry hook fires
        // once per caller and the wait below is about the first of them — the
        // second firing is the second caller being served, not an
        // over-fulfilment to fail on.
        //
        // The clock is stepped past the reuse allowance between the two calls,
        // deliberately: on identical frames the second caller would otherwise be
        // *restated* from the first pass instead of reaching Vision at all
        // (`testAnUnchangedFrameIsRestatedInsteadOfReadAgain` pins that, and it
        // is the point of the reuse rule), and this test is about two passes
        // that do reach the engine.
        entered.assertForOverFulfill = false
        engine.hold = hold
        engine.onEnter = { entered.fulfill() }
        engine.regions = [region("Exit")]
        let detector = makeDetector()
        _ = detector.begin()

        let sample = try frame()
        let first = Task { await detector.recognize(sample) }
        await fulfillment(of: [entered], timeout: 5)
        // The first pass stamped its time when it started and is held inside the
        // engine, so this puts the *second* caller past the window without
        // moving the first one's stamp.
        clock.advance(by: LiveTranslateConfig.default.ocrSampleInterval
                      * (LiveTranslateConfig.default.ocrUnchangedReuseIntervals + 1))
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

    // MARK: Scenario: a pass never publishes nothing

    private func sceneLine(_ text: String, x: Double, y: Double) -> SceneTextLine {
        SceneTextLine(text: text,
                      normalizedBox: NormalizedBox(xMin: x, yMin: y,
                                                   xMax: x + 0.4, yMax: y + 0.08),
                      confidence: 0.9,
                      detectedLanguage: nil)
    }

    /// The owner's device verdict, at the one seam that decides it: **lines
    /// recognized, grouping empty, publication still carries the lines.**
    ///
    /// `SceneBlockGrouper.group` is total over the lines it can carry, so this
    /// is the guard for the ways a pass could still end up publishing nothing —
    /// and it is the guarantee the feature's contract needs whatever a future
    /// grouping rule does: the fallback is the per-line publication the feature
    /// shipped before blocks existed. The alternative is the failure the owner's
    /// device report was about — the overlay's empty state, "I don't see any
    /// text yet", drawn over a picture full of text this pass had just read.
    func testAPassWhoseGroupingFormedNoBlockStillPublishesItsLines() throws {
        let lines = [sceneLine("START", x: 0.2, y: 0.2),
                     sceneLine("2 MIN", x: 0.2, y: 0.4)]

        let published = LiveTextDetector.publishedBlocks(from: [],
                                                         fallbackLines: lines,
                                                         limit: 4)

        XCTAssertEqual(published.map(\.text), ["START", "2 MIN"],
                       "the lines a pass recognized are published even when the grouping "
                       + "formed no block: a group failure degrades the merge, never the text")
        XCTAssertEqual(published.map(\.normalizedBox), lines.map(\.normalizedBox),
                       "each line is published at its own geometry, nothing invented")
        XCTAssertEqual(published.map(\.memberStrings), [["START"], ["2 MIN"]])
    }

    /// The fallback is a floor and not a policy: when the grouping *did* form
    /// blocks, they are what the pass publishes — same array, same order, same
    /// identities, so nothing downstream can tell whether the floor was needed.
    func testAPassPublishesTheGroupingsBlocksWheneverTheGroupingFormedThem() {
        let lines = [sceneLine("START", x: 0.2, y: 0.2),
                     sceneLine("2 MIN", x: 0.2, y: 0.3)]
        let grouping = SceneBlockGrouper.group(lines: lines, objects: [], config: .default, limit: 4)
        XCTAssertEqual(grouping.count, 1, "the fixture is one merged surface")

        let published = LiveTextDetector.publishedBlocks(from: grouping,
                                                         fallbackLines: lines,
                                                         limit: 4)

        XCTAssertEqual(published, grouping,
                       "a grouping that formed blocks is published untouched — the fallback "
                       + "is for an empty grouping, not a second opinion about a full one")
    }

    /// …and the floor is bounded by the caller's cap like everything else, so
    /// the live overlay still carries the few surfaces it can draw.
    func testTheFallbackPublicationRespectsThePassCap() {
        let lines = (0..<6).map { sceneLine("L\($0)", x: 0.1, y: 0.05 + Double($0) * 0.15) }

        XCTAssertEqual(LiveTextDetector.publishedBlocks(from: [],
                                                        fallbackLines: lines,
                                                        limit: LiveTranslateConfig.default.maxVisibleBlocks).count,
                       LiveTranslateConfig.default.maxVisibleBlocks)
        XCTAssertEqual(LiveTextDetector.publishedBlocks(from: [], fallbackLines: lines, limit: nil).count,
                       6,
                       "…and the snapshot pass, which asks for no cap, gets every line")
    }

    /// The floor, through the shipped pass: a scene whose object request is
    /// **refused** still publishes its recognized text.
    ///
    /// This is the device regression end to end — the object pass is a SHOULD,
    /// and on the owner's device it was the thing that failed — so the pass's
    /// published regions are the assertion, not an internal.
    func testARefusedObjectPassStillPublishesThePassesText() async throws {
        objects.errorToThrow = StubFailure(message: "saliency refused this frame")
        engine.regions = [region("Exit"), region("Push", x: 0.2, y: 0.4)]
        let detector = makeDetector()
        _ = detector.begin()

        let result = try await ocrPass(detector, luma: 0)
        await detector.awaitObjectPass()

        guard case .success(let pass) = result else { return XCTFail("expected a pass: \(result)") }
        XCTAssertFalse(pass.regions.isEmpty,
                       "a scene whose object request was refused still publishes the text "
                       + "the pass recognized")
        XCTAssertEqual(pass.regions.flatMap { $0.text.split(separator: "\n").map(String.init) },
                       ["Exit", "Push"],
                       "as per-line blocks: the grouping degraded, the words did not")
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
        await detector.awaitObjectPass()
        XCTAssertEqual(objects.detectCallCount, 1, "the first OCR of a scene detects")

        // Inside the cadence, the pass reuses what it has: the object is the
        // expensive request, and a scene's objects do not change between two
        // frames a fifth of a second apart.
        _ = try await ocrPass(detector, luma: 30)
        await detector.awaitObjectPass()
        XCTAssertEqual(objects.detectCallCount, 1,
                       "the object pass is the slow pass: it is not run per frame")

        clock.advance(by: detector.config.objectPassCadenceSeconds + 1)
        _ = try await ocrPass(detector, luma: 60)
        await detector.awaitObjectPass()
        XCTAssertEqual(objects.detectCallCount, 2, "once the cadence is due, it runs again")

        XCTAssertEqual(bus.events(named: "object_pass").count, 2)
        XCTAssertEqual(bus.events(named: "object_pass").last?.metadata["count"], "1")
        XCTAssertEqual(bus.events(named: "object_pass").first?.outcome, "success")
    }

    /// The isolation rule, and the owner's "fires after a long delay" in the
    /// shape a test can decide: a pass's text is published **while** the object
    /// pass is still running.
    ///
    /// The object pass is the slow pass on real hardware — a saliency request
    /// and, on the first one of a session, the model load behind it — and it
    /// answers a question about *grouping* that the text does not depend on.
    /// So the text pass may not wait for it, in either direction: not for a
    /// detection that is slow, and not for one that never answers at all.
    ///
    /// The stub is held inside `detectObjects` on the test's own semaphore, so
    /// "the text pass returned before the object pass answered" is an observed
    /// fact (the object pass had started and had not finished) rather than a
    /// wall-clock guess. A detector that waited for the object pass fails this
    /// in its first assertion: it can only return after the gate's own timeout.
    func testASlowObjectPassCannotDelayTheTextThePassPublishes() async throws {
        engine.regions = [region("Exit")]
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        objects.objects = [sceneObject("microwave", 0.1, 0.1, 0.6, 0.6)]
        objects.onDetect = { _ in
            started.signal()
            // Bounded, so a detector that *does* wait on the object pass fails
            // the assertions below rather than hanging the suite.
            _ = gate.wait(timeout: .now() + 5)
        }
        let detector = makeDetector()
        _ = detector.begin()

        let result = try await ocrPass(detector, luma: 0)

        XCTAssertEqual(started.wait(timeout: .now() + 2), .success,
                       "the object pass was started by the first OCR pass")
        XCTAssertEqual(objects.detectCallCount, 1, "…and it is the pass it started")
        XCTAssertEqual(objects.completedDetections, 0,
                       "the object pass is still running, and the text pass has already "
                       + "returned: the text path does not join the object path")
        guard case .success(let pass) = result else { return XCTFail("expected a pass: \(result)") }
        XCTAssertEqual(pass.regions.map(\.text), ["Exit"],
                       "the text the pass recognized is published, not held back for the "
                       + "object pass to finish")

        gate.signal()
        await detector.awaitObjectPass()
        XCTAssertEqual(objects.completedDetections, 1, "…and the object pass lands on its own")
        XCTAssertEqual(bus.events(named: "object_pass").count, 1)
        XCTAssertEqual(bus.events(named: "object_pass").first?.metadata["count"], "1")
    }

    func testTheCachedObjectsStillGroupThePassThatDidNotDetect() async throws {
        objects.objects = [sceneObject("microwave", 0.1, 0.1, 0.6, 0.6)]
        engine.regions = [region("START", x: 0.2, y: 0.2)]
        let detector = makeDetector()
        _ = detector.begin()

        _ = try await ocrPass(detector, luma: 0)
        await detector.awaitObjectPass()
        let second = try await ocrPass(detector, luma: 30)
        await detector.awaitObjectPass()
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
        await detector.awaitObjectPass()

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
        await detector.awaitObjectPass()
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

        // The object pass is asynchronous — the text path never waits for it —
        // so the detection the first OCR pass schedules lands *after* that pass
        // has grouped. The measured passes come after it: one throwaway pass
        // warms the cache, then the scene is read with the appliance known.
        _ = try await ocrPass(detector, luma: 0)
        await detector.awaitObjectPass()

        let first = try await ocrPass(detector, luma: 60)
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

    // MARK: Scenario: a crop is a one-off pass, not a sighting

    /// Review finding 11 — the one-off crop resets the detector's own tracking
    /// state and not only the engine's rectangles.
    ///
    /// The crop's pass is not a sighting of the live scene: it reads a box the
    /// elder drew, and nothing about it may anchor the live cadence. Resetting
    /// only the engine's rectangles left the other half standing —
    /// `lastOCRPassAt` still timed the sample interval from the pass *before*
    /// the crop and `rememberedKeys` still named strings the crop replaced — so
    /// the very next live frame was handed to the *tracker* for geometry that
    /// no longer existed. One crop cost the live picture an interval with
    /// nothing on it. The observable here is the pass kind the detector picks
    /// for the frame after a crop.
    func testACropEndsTheTrackingWindowInsteadOfLeavingItHalfReset() async throws {
        engine.regions = [region("Exit"), region("Push", y: 0.6)]
        engine.trackedBoxes = ["Exit": box(0.25), "Push": box(0.55)]
        let detector = makeDetector()
        XCTAssertTrue(detector.begin().isSuccess)

        // A live pass, so the detector has just read the scene and would
        // otherwise track it for the rest of the sample interval.
        _ = await detector.recognize(try frame(luma: 0))
        XCTAssertEqual(engine.recognizeCallCount, 1)

        // The elder's crop: one pass over the box they pointed at.
        let cropped = await detector.recognizeCrop(try frame(luma: 90).pixelBuffer)
        guard case .success = cropped else { return XCTFail("the crop must read: \(cropped)") }
        XCTAssertEqual(engine.forgetCallCount, 1,
                       "the engine is told its rectangles describe a picture that is gone")

        // The live cadence resumes. It is still inside the sample interval, so
        // a half-reset detector tracks; a reset one reads.
        _ = await detector.recognize(try frame(luma: 180))
        XCTAssertEqual(engine.trackCallCount, 0,
                       "the frame after a crop must be read, not tracked over "
                       + "rectangles the crop already replaced")
        XCTAssertEqual(engine.recognizeCallCount, 3,
                       "the crop's own pass and the live pass after it are OCR passes")
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
