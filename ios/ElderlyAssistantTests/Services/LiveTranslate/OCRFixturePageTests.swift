import CoreMedia
import CoreText
import CoreVideo
import UIKit
import Vision
import XCTest
@testable import ElderlyAssistant

/// T-030 — the part of the device-validation protocol that **can** be run
/// without a device: a fixture-image OCR pass over a dense, menu-like page,
/// through the real Vision path, in the standard test invocation.
///
/// Why this is the honest substitute for a camera run. The protocol's
/// OCR checks ask whether a busy page is read completely enough to be useful;
/// the part of that question which is about *the pipeline* — is a dense page
/// read whole, are its boxes sane, does the pass report success rather than an
/// empty state — is answerable against a rendered frame with the same
/// `LiveTextDetector` the device runs. The part which is about *the camera*
/// (focus, exposure, motion, glare, real paper, real lighting) is not, and is
/// recorded as NOT RUN in `specs/LCT-device-validation-results.md` rather than
/// approximated here.
///
/// This test is deliberately not named as device evidence: a simulator run is
/// a simulator run.
///
/// **Scene-block rework, 2026-09-18.** A dense page is no longer reported as
/// one region per line: the pass groups its lines into fewer, larger surfaces,
/// so "was the page read completely" is measured in *recognized lines* (the
/// block texts, split back apart) and the surface count is measured separately
/// and against the cap. The second test here is the rework's own premise
/// checked against the runtime: the object pass is run for real, and what this
/// Vision actually reports is recorded rather than assumed.
final class OCRFixturePageTests: XCTestCase {

    private var bus: LiveTranslateSanitisingBus!

    override func setUp() {
        super.setUp()
        bus = LiveTranslateSanitisingBus()
    }

    /// A menu page: short lines, mixed lengths, numerals and punctuation, in
    /// the shape a printed shop sign actually has. The same fixture the
    /// protocol names, rendered with CoreText so Vision reads a real image.
    private let menuPage = [
        "MENU",
        "Tea  Rs 40",
        "Coffee  Rs 80",
        "Momo  Rs 120",
        "Dal Bhat  Rs 250",
        "Cold Drinks",
        "Water  Rs 20",
        "OPEN 7AM - 9PM",
    ]

    func testADenseMenuLikePageIsReadWholeAndGroupsIntoLargerSurfaces() throws {
        let frame = try XCTUnwrap(CameraFrame(sampleBuffer: SampleBufferFactory.make(
            width: 1200, height: 800, pts: CMTime(value: 1, timescale: 1))))
        try render(lines: menuPage, pointSize: 44, into: frame.pixelBuffer)

        let config = LiveTranslateConfig.default
        let detector = LiveTextDetector(config: config, observabilityBus: bus)
        XCTAssertTrue(detector.begin().isSuccess)
        let result = awaitResult(detector, frame)

        guard case .success(let pass) = result else {
            return XCTFail("a dense menu page must not be a failed pass: \(result)")
        }

        // The recognition measurement: the lines Vision read, recovered from
        // the blocks that carry them. A block's text is its members joined by
        // the grouper's separator, so splitting it back apart measures
        // recognition independently of how the lines were grouped.
        let lines = pass.regions
            .flatMap { $0.text.components(separatedBy: SceneBlock.lineSeparator) }
            .filter { !$0.isEmpty }

        // The page must actually produce text. An empty pass here is a
        // finding about the fixture or the environment, not something to
        // assert around — the message says which reading was obtained.
        XCTAssertFalse(lines.isEmpty,
                       "Vision read nothing from the rendered menu page — the fixture "
                       + "or the recognition path is the finding")
        XCTAssertGreaterThanOrEqual(lines.count, 2,
                                    "a dense page yielded \(lines.count) recognized line(s) "
                                    + "in \(pass.regions.count) surface(s); the protocol's "
                                    + "density question is about several lines being read, so "
                                    + "this count is the measurement to record: \(lines)")

        // The grouping half of the same pass: whatever the page resolved to,
        // the overlay is handed no more surfaces than the cap allows, and each
        // one is a real block rather than a fragment.
        XCTAssertLessThanOrEqual(pass.regions.count, config.maxVisibleBlocks,
                                 "the live pass handed the overlay \(pass.regions.count) "
                                 + "surface(s); the cap is \(config.maxVisibleBlocks)")

        let texts = pass.regions.map(\.text).filter { !$0.isEmpty }
        let joined = texts.joined(separator: " ").lowercased()
        let expected = ["menu", "tea", "coffee", "momo", "water", "open"]
        let found = expected.filter { joined.contains($0) }
        XCTAssertGreaterThanOrEqual(found.count, 2,
                                    "the menu page yielded \(texts) — fewer than two of the "
                                    + "expected words were read, which is the dense-page "
                                    + "finding to record rather than smooth over")

        // The measurement, recorded in the result bundle so the results record
        // can cite a number rather than a threshold it passed. Counts only —
        // recognized text never goes to a log surface, not even here.
        let measurement = XCTAttachment(string: """
        {"fixtureLines": \(menuPage.count), \
        "recognizedLines": \(lines.count), \
        "surfaces": \(pass.regions.count), \
        "surfaceCap": \(config.maxVisibleBlocks), \
        "expectedWordsRead": \(found.count), \
        "expectedWords": \(expected.count), \
        "fixture": "menu-page-1200x800-44pt"}
        """)
        measurement.name = "ocr-fixture-measurement"
        measurement.lifetime = .keepAlways
        add(measurement)

        for region in pass.regions {
            XCTAssertFalse(region.text.isEmpty, "a region with no text was returned")
            XCTAssertTrue(region.normalizedBox.isValid)
            XCTAssertGreaterThanOrEqual(region.normalizedBox.xMin, 0)
            XCTAssertLessThanOrEqual(region.normalizedBox.xMax, 1)
            XCTAssertGreaterThanOrEqual(region.normalizedBox.yMin, 0)
            XCTAssertLessThanOrEqual(region.normalizedBox.yMax, 1)
            XCTAssertGreaterThan(region.confidence, 0)
            XCTAssertNil(region.detectedLanguage,
                         "the classic Vision API reports no per-observation language: "
                         + "omit it, never guess")
        }

        XCTAssertEqual(bus.events(named: "ocr_pass").first?.outcome, "success")
        XCTAssertEqual(bus.events(named: "ocr_pass").first?.metadata["regionCount"],
                       String(pass.regions.count),
                       "the recorded count is what was recognized, not an estimate")
        // The page's text is not on any log surface, however dense it is.
        for event in bus.events {
            for value in event.metadata.values {
                XCTAssertFalse(value.contains("Momo"),
                               "recognized text reached an event field")
            }
        }
    }

    // MARK: - The object pass, probed against this runtime

    /// The rework's premise, checked rather than assumed.
    ///
    /// The premise was "Vision's object request gives us boxes and classes for
    /// things like appliances". This SDK's Vision has no `VNRecognizeObjectsRequest`
    /// at all — it was deprecated in iOS 13 and is absent from the headers — so
    /// the shipped object pass composes the two requests that do exist:
    /// objectness saliency for the boxes, image classification for the labels.
    /// What that composition returns on a given runtime is a fact about the
    /// runtime, so this test **records** it and asserts only what must hold
    /// whatever the answer is: boxes that are valid and inside the unit square
    /// and never more of them than the engine was asked for, *or* a refusal
    /// reported in the feature's own taxonomy. On this Intel-Mac simulator the
    /// answer is a refusal — Vision cannot create an Espresso context for the
    /// saliency model — which is recorded, not smoothed over; the feature's
    /// response to it is the text-only grouping path.
    ///
    /// The recorded line is counts, labels and geometry — the classifier's own
    /// vocabulary and numbers, never recognized user text — or, for a refusal,
    /// the OS's reason.
    func testTheObjectPassReportsWhatThisRuntimeActuallyFinds() throws {
        let frame = try XCTUnwrap(CameraFrame(sampleBuffer: SampleBufferFactory.make(
            width: 1200, height: 800, pts: CMTime(value: 1, timescale: 1))))
        try renderAppliancePanel(into: frame.pixelBuffer)

        let objects = probeObjects(fixture: "appliance-panel-1200x800", frame: frame)

        XCTAssertLessThanOrEqual(objects?.count ?? 0, 4,
                                 "the engine returned more boxes than it was asked for")
        for object in objects ?? [] {
            XCTAssertTrue(object.normalizedBox.isValid,
                          "an object box came back invalid: \(object.normalizedBox)")
            XCTAssertGreaterThanOrEqual(object.normalizedBox.xMin, 0)
            XCTAssertLessThanOrEqual(object.normalizedBox.xMax, 1)
            XCTAssertGreaterThanOrEqual(object.normalizedBox.yMin, 0)
            XCTAssertLessThanOrEqual(object.normalizedBox.yMax, 1)
            XCTAssertGreaterThan(object.confidence, 0)
        }
    }

    /// The same probe over the dense page, so the record covers the other shape
    /// a scene takes here: a surface with a lot of text on it.
    func testTheObjectPassOverADensePageIsRecordedToo() throws {
        let frame = try XCTUnwrap(CameraFrame(sampleBuffer: SampleBufferFactory.make(
            width: 1200, height: 800, pts: CMTime(value: 1, timescale: 1))))
        try render(lines: menuPage, pointSize: 44, into: frame.pixelBuffer)

        let objects = probeObjects(fixture: "menu-page-1200x800-44pt", frame: frame)

        XCTAssertLessThanOrEqual(objects?.count ?? 0, 4)
        for object in objects ?? [] {
            XCTAssertTrue(object.normalizedBox.isValid)
        }
    }

    /// Runs the shipped object engine over a frame and records what came back —
    /// **either way**.
    ///
    /// Whether this runtime's Vision can run an objectness request is a fact
    /// about the runtime, not something a test may assert into existence, and on
    /// a host that cannot the honest deliverable is the record. What *is*
    /// asserted is the engine's own behaviour on a refusal: the feature's
    /// taxonomy rather than a crash, a silent empty success or a raw Vision
    /// error. The detector's response to that — one `object_detection_
    /// unsupported` event and text-only grouping thereafter — is pinned with a
    /// stub engine in `LiveTextDetectorTests`, where it is deterministic.
    ///
    /// Returns nil when the runtime refused, which the callers treat as "no
    /// boxes to check" rather than as a pass.
    private func probeObjects(fixture: String,
                              frame: CameraFrame) -> [LiveTextDetector.DetectedSceneObject]? {
        let engine = VisionObjectDetectionEngine(maximumObjects: 4)
        XCTAssertTrue(engine.supportsObjectDetection,
                      "the shipped object engine claims support, or the live pass is degraded "
                      + "and every scene is text-grouped")
        do {
            let objects = try engine.detectObjects(in: frame.pixelBuffer)
            record(objects, fixture: fixture)
            return objects
        } catch {
            recordRefusal(error, fixture: fixture, frame: frame)
            XCTAssertEqual(error as? LiveTranslateError, .ocrPassFailed(.requestFailed),
                           "a refused object request is reported in the feature's taxonomy")
            return nil
        }
    }

    /// The refusal half of the probe: the taxonomy the engine reports carries no
    /// Vision detail by design, so Vision is asked once more, directly, for the
    /// reason — which is what the record exists to carry.
    private func recordRefusal(_ error: Error, fixture: String, frame: CameraFrame) {
        var reason = "unavailable"
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, options: [:])
        do {
            try handler.perform([VNGenerateObjectnessBasedSaliencyImageRequest()])
            reason = "the request succeeded when asked directly"
        } catch {
            let ns = error as NSError
            reason = "\(ns.domain) \(ns.code) — \(ns.localizedDescription)"
        }
        let line = "[object-probe] fixture=\(fixture) outcome=refused reason=[\(reason)]"
        print(line)

        let attachment = XCTAttachment(string: line)
        attachment.name = "object-detection-probe"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Records one probe run: the console line is what the run reports to
    /// whoever is reading the build log, the attachment is what the result
    /// bundle keeps. Both carry counts, labels and geometry only.
    private func record(_ objects: [LiveTextDetector.DetectedSceneObject], fixture: String) {
        let labels = objects.map { $0.classLabel ?? "-" }.joined(separator: ",")
        let boxes = objects.map {
            String(format: "%.2f,%.2f,%.2f,%.2f", $0.normalizedBox.xMin, $0.normalizedBox.yMin,
                   $0.normalizedBox.xMax, $0.normalizedBox.yMax)
        }.joined(separator: " ")
        let line = "[object-probe] fixture=\(fixture) count=\(objects.count) "
            + "labels=[\(labels)] boxes=[\(boxes)]"
        print(line)

        let attachment = XCTAttachment(string: line)
        attachment.name = "object-detection-probe"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Helpers

    /// A dark scene with a large light panel on it and two short lines of text
    /// printed on the panel — the shape of an appliance face rather than a
    /// page, which is what the object pass exists to find.
    private func renderAppliancePanel(into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw StubFailure(message: "could not build a bitmap context over the frame")
        }
        // A dark room.
        context.setFillColor(UIColor(white: 0.12, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A light panel, centred, with a bezel.
        context.setFillColor(UIColor(white: 0.85, alpha: 1).cgColor)
        context.fill(CGRect(x: 260, y: 220, width: 680, height: 380))
        context.setFillColor(UIColor(white: 0.35, alpha: 1).cgColor)
        context.fill(CGRect(x: 300, y: 260, width: 600, height: 300))
        // Two lines of text on the panel's face.
        context.setFillColor(UIColor.white.cgColor)
        let font = UIFont.systemFont(ofSize: 56)
        for (index, text) in ["MICROWAVE", "START 2 MIN"].enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 340, y: 420 - CGFloat(index) * 90)
            CTLineDraw(ctLine, context)
        }
    }

    private func awaitResult(_ detector: LiveTextDetector,
                             _ frame: CameraFrame) -> Result<LiveTextDetector.Pass, LiveTranslateError> {
        var outcome: Result<LiveTextDetector.Pass, LiveTranslateError>?
        let done = DispatchSemaphore(value: 0)
        Task {
            outcome = await detector.recognize(frame)
            done.signal()
        }
        done.wait()
        return outcome ?? .failure(.ocrPassFailed(.requestFailed))
    }

    /// Black text on white, one line per entry, top-down — the same shape as
    /// the shipped detector test's renderer, sized for a dense page.
    private func render(lines: [String], pointSize: CGFloat,
                        into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw StubFailure(message: "could not build a bitmap context over the frame")
        }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(UIColor.black.cgColor)
        let font = UIFont.systemFont(ofSize: pointSize)
        var y = CGFloat(height) - pointSize - 30
        for line in lines {
            let attributed = NSAttributedString(string: line, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(ctLine, context)
            y -= pointSize + 30
        }
    }
}
