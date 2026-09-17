import CoreGraphics
import UIKit
import Vision
import XCTest

// Capability record — Devanagari (Nepali) OCR on this platform.
//
// Scope, stated plainly so this file cannot be mistaken for feature work:
// this probe exists because an earlier directive briefly considered a custom
// Devanagari recognizer for the live camera translation feature. That was
// **dropped**: v1 is English source → Nepali target, and Nepali/Devanagari
// OCR is not v1 scope. Nothing here is a requirement, nothing here gates the
// feature, and no product source is exercised or changed. This is the short
// capability check that puts on the record what the platform can actually do.
//
// The probe uses the same Vision API the feature uses — `VNRecognizeTextRequest`,
// configured as `VisionTextRecognitionEngine` configures it (`recognitionLevel
// = .accurate`, `automaticallyDetectsLanguage = true`, no `recognitionLanguages`)
// — so the answer describes the feature's real environment rather than a
// different stack.
//
// **These tests assert only what is safely true**: the harness runs, the
// request completes, the English control is read. A capability *absence* is a
// finding, not a failure: the suite must not go red because the platform
// cannot read Devanagari. Nothing here asserts that `hi-IN` works, and nothing
// asserts that it does not. The verbatim findings live in
// `specs/hi-in-probe-notes.md`; this file is only the instrument.
final class HiINCapabilityProbeTests: XCTestCase {

    /// A Nepali string the app actually ships — `Localizable.xcstrings`, the
    /// live-translation "translating…" status. Real content, not synthetic.
    private let nepali = "अनुवाद हुँदैछ…"

    /// The English counterpart, a string the feature exists to read. If the
    /// Devanagari result is a null, this control is what attributes it to the
    /// script rather than to a broken harness.
    private let english = "Emergency Exit"

    // MARK: Probe 1 — what the revision in use claims to support

    func testProbe1TheRevisionInUsesSupportedRecognitionLanguages() throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let revision = request.revision

        let languages = try VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate, revision: revision)

        print("=== PROBE-1 ===")
        print("revision: \(revision)")
        print("count: \(languages.count)")
        print("languages: \(languages)")

        let devanagari = languages.filter {
            let code = $0.lowercased()
            return code.hasPrefix("ne") || code.hasPrefix("hi") || code.hasPrefix("sa") || code.hasPrefix("mr")
        }
        print("devanagari-capable codes present: \(devanagari)")

        XCTAssertFalse(languages.isEmpty, "this device lists no text recognition languages at all")
        XCTAssertTrue(languages.contains("en-US"),
                      "the English source language the shipped engine relies on is absent")
    }

    // MARK: Probe 2 — Devanagari, no recognitionLanguages (platform default)

    func testProbe2DevanagariWithThePlatformDefault() throws {
        let image = try renderedImage(nepali, pointSize: 96)
        let request = defaultConfiguredRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])

        let observations = request.results ?? []
        print("=== PROBE-2 (no recognitionLanguages) ===")
        printCandidates(observations)

        // The harness ran and the request completed. What it produced is the
        // finding; an absence must not fail this suite.
        XCTAssertNotNil(request.results, "the request did not complete on this device")
    }

    // MARK: Probe 3 — Devanagari, recognitionLanguages = ["hi-IN"]

    func testProbe3DevanagariWithHiINRequested() throws {
        let image = try renderedImage(nepali, pointSize: 96)
        let request = defaultConfiguredRequest()
        request.recognitionLanguages = ["hi-IN"]
        try VNImageRequestHandler(cgImage: image).perform([request])

        let observations = request.results ?? []
        print("=== PROBE-3 (recognitionLanguages = [\"hi-IN\"]) ===")
        print("request.recognitionLanguages after set: \(request.recognitionLanguages)")
        printCandidates(observations)

        XCTAssertNotNil(request.results, "the request did not complete on this device")
    }

    // MARK: Probe 4 — is the setter honoured, ignored, or does it throw?

    func testProbe4WhetherTheLanguageSetterIsHonoured() throws {
        let request = defaultConfiguredRequest()
        let before = request.recognitionLanguages

        var threw = false
        do {
            request.recognitionLanguages = ["hi-IN"]
        } catch {
            threw = true
            print("=== PROBE-4 ===")
            print("setting recognitionLanguages = [\"hi-IN\"] THREW: \(error)")
        }

        if !threw {
            let after = request.recognitionLanguages
            let accepted = after.contains("hi-IN")
            print("=== PROBE-4 ===")
            print("default recognitionLanguages (before): \(before)")
            print("after setting [\"hi-IN\"]: \(after)")
            print("state: \(accepted ? "HONOURED (the value stayed on the request)" : "SILENTLY IGNORED (the set left the value unchanged)")")
            print("note: acceptance of the value is not the same as recognising the script; the PROBE-3 output is the observable half.")
        }
    }

    // MARK: Probe 5 — the control

    func testProbe5EnglishControlIsRecognized() throws {
        let image = try renderedImage(english, pointSize: 96)
        let request = defaultConfiguredRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])

        let observations = request.results ?? []
        print("=== PROBE-5 (English control, no recognitionLanguages) ===")
        printCandidates(observations)

        let first = try XCTUnwrap(observations.first,
                                  "the harness itself is broken: nothing was recognized in the English control")
        let top = try XCTUnwrap(first.topCandidates(1).first,
                                "the control observation carried no candidates")
        XCTAssertTrue(top.string.localizedCaseInsensitiveContains("emergency"),
                      "the control was not read: \(top.string)")
    }

    // MARK: Helpers

    /// The shipped engine's configuration, to the letter: accurate, automatic
    /// language detection on, and no `recognitionLanguages` — the platform's
    /// own default is what probe 2 measures.
    private func defaultConfiguredRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        if #available(iOS 16.0, *) {
            request.automaticallyDetectsLanguage = true
        }
        return request
    }

    /// Renders one line of text in memory: large point size, black on plain
    /// white. No fixture is added to the repository; the image exists only for
    /// the duration of the test.
    private func renderedImage(_ text: String, pointSize: CGFloat) throws -> CGImage {
        let size = CGSize(width: 1600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: pointSize),
                .foregroundColor: UIColor.black
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let stringSize = string.size()
            string.draw(at: CGPoint(x: (size.width - stringSize.width) / 2,
                                    y: (size.height - stringSize.height) / 2))
        }
        guard let cgImage = image.cgImage else {
            throw NSError(domain: "HiINCapabilityProbe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "the renderer produced no CGImage"])
        }
        return cgImage
    }

    /// Prints every observation and every candidate, verbatim — the whole
    /// point of the probe is that no helper paraphrases Vision's output.
    private func printCandidates(_ observations: [VNRecognizedTextObservation]) {
        let totalCandidates = observations.reduce(0) { $0 + $1.topCandidates(5).count }
        print("observations: \(observations.count), candidates: \(totalCandidates)")
        for (index, observation) in observations.enumerated() {
            let candidates = observation.topCandidates(5)
            print("observation \(index): candidates=\(candidates.count)")
            for candidate in candidates {
                print("  candidate \(candidate.string) (confidence \(candidate.confidence))")
            }
        }
    }
}
