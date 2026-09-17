import CoreMedia
import CoreText
import CoreVideo
import UIKit
import XCTest
@testable import ElderlyAssistant

/// T-030 — the part of the device-validation protocol that **can** be run
/// without a device: a fixture-image OCR pass over a dense, menu-like page,
/// through the real Vision path, in the standard test invocation.
///
/// Why this is the honest substitute for a camera run. The protocol's
/// OCR checks ask whether a busy page is read completely enough to be useful;
/// the part of that question which is about *the pipeline* — does a dense
/// page produce several regions, are their boxes sane, does the pass report
/// success rather than an empty state — is answerable against a rendered
/// frame with the same `LiveTextDetector` the device runs. The part which is
/// about *the camera* (focus, exposure, motion, glare, real paper, real
/// lighting) is not, and is recorded as NOT RUN in
/// `specs/LCT-device-validation-results.md` rather than approximated here.
///
/// This test is deliberately not named as device evidence: a simulator run is
/// a simulator run.
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

    func testADenseMenuLikePageIsReadAsSeveralRegionsWithSaneBoxes() throws {
        let frame = try XCTUnwrap(CameraFrame(sampleBuffer: SampleBufferFactory.make(
            width: 1200, height: 800, pts: CMTime(value: 1, timescale: 1))))
        try render(lines: menuPage, pointSize: 44, into: frame.pixelBuffer)

        let detector = LiveTextDetector(config: .default, observabilityBus: bus)
        XCTAssertTrue(detector.begin().isSuccess)
        let result = awaitResult(detector, frame)

        guard case .success(let pass) = result else {
            return XCTFail("a dense menu page must not be a failed pass: \(result)")
        }

        // The page must actually produce text. An empty pass here is a
        // finding about the fixture or the environment, not something to
        // assert around — the message says which reading was obtained.
        let texts = pass.regions.map(\.text).filter { !$0.isEmpty }
        XCTAssertFalse(texts.isEmpty,
                       "Vision read nothing from the rendered menu page — the fixture "
                       + "or the recognition path is the finding")
        XCTAssertGreaterThanOrEqual(pass.regions.count, 2,
                                    "a dense page was read as \(pass.regions.count) region(s); "
                                    + "the protocol's density question is about several lines "
                                    + "being read, so this count is the measurement to record: "
                                    + "\(texts)")

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
        "regions": \(pass.regions.count), \
        "nonEmptyRegions": \(texts.count), \
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

    // MARK: - Helpers

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
