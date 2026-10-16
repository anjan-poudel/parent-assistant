import UIKit
import XCTest
@testable import ElderlyAssistant

/// One label scan, from the shutter to a candidate ([MED-OCR], 2026-09-18).
///
/// The scanner is the flow that DECIDES: which camera outcome it got, whether
/// the reading ran, what the family is told, and what the ledger records. The
/// camera itself (`CameraCapturePresenting`) and Vision
/// (`MedicationLabelRecognizing`) are both behind seams here, so every path is
/// covered on a simulator with no camera, no permission prompt and no
/// rendered label.
///
/// The two properties pinned throughout: **the photo survives every reading
/// failure** (the family pressed the shutter; a bad read is not a reason to
/// throw their picture away) and **nothing is silent** (every path speaks and
/// emits exactly once, and a failed read says so out loud rather than leaving
/// a form that looks ignored).
final class MedicationLabelScannerTests: XCTestCase {

    private let english = Locale(identifier: "en")

    // MARK: - Doubles

    private final class FakePresenter: CameraCapturePresenting {
        var availability: CameraAvailability
        var outcome: CameraCaptureOutcome
        /// True: the session stays open until the test fires it — the
        /// in-flight state the one-session-at-a-time test needs.
        var holdSession = false
        private(set) var presentCount = 0
        private var pending: ((CameraCaptureOutcome) -> Void)?

        init(availability: CameraAvailability = .available,
             outcome: CameraCaptureOutcome = .cancelled) {
            self.availability = availability
            self.outcome = outcome
        }

        func presentCamera(completion: @escaping (CameraCaptureOutcome) -> Void) {
            presentCount += 1
            guard holdSession else { return completion(outcome) }
            pending = completion
        }

        /// Fires the held session's outcome.
        func finishHeldSession(with outcome: CameraCaptureOutcome) {
            let completion = pending
            pending = nil
            completion?(outcome)
        }
    }

    private final class FakeRecognizer: MedicationLabelRecognizing {
        var lines: [String] = []
        var error: MedicationLabelOCRError?
        private(set) var recognizedImages: [UIImage] = []

        func recognizeLines(in image: UIImage) throws -> [String] {
            recognizedImages.append(image)
            if let error { throw error }
            return lines
        }
    }

    /// What the scanner said and recorded, in order. A class so the channels
    /// (which are stored and therefore escaping) can capture it.
    private final class Recorder {
        struct Event {
            let eventType: String
            let outcome: String
        }
        private(set) var spoken: [String] = []
        private(set) var events: [Event] = []

        func note(_ text: String) { spoken.append(text) }
        func note(eventType: String, outcome: String) {
            events.append(Event(eventType: eventType, outcome: outcome))
        }

        var outcomes: [String] { events.map(\.outcome) }
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func makeScanner(presenter: FakePresenter,
                             recognizer: FakeRecognizer,
                             recorder: Recorder) -> MedicationLabelScanner {
        // `deliver`/`offload` inline: the flow is driven synchronously, so a
        // test needs no queue hopping to observe it.
        MedicationLabelScanner(
            presenter: presenter,
            recognizer: recognizer,
            locale: { self.english },
            channels: MedicationLabelScanner.Channels(
                speak: { recorder.note($0) },
                emit: { recorder.note(eventType: $0, outcome: $1) }
            ),
            deliver: { $0() },
            offload: { $0() }
        )
    }

    // MARK: - The reading

    /// The happy path: the photo comes back with the candidate the parser
    /// made of the recognized lines, and the family hears the name that was
    /// read — the field they will check first.
    func testCapturedLabelReturnsThePhotoAndTheParsedCandidate() {
        let recorder = Recorder()
        let presenter = FakePresenter(outcome: .captured(makeImage()))
        let recognizer = FakeRecognizer()
        recognizer.lines = ["Amoxicillin", "500 mg", "1-0-1"]
        let scanner = makeScanner(presenter: presenter, recognizer: recognizer, recorder: recorder)

        var result: MedicationLabelScanResult?
        scanner.start { result = $0 }

        guard case .scanned(let image, let candidate)? = result else {
            return XCTFail("expected .scanned, got \(String(describing: result))")
        }
        XCTAssertEqual(candidate?.name, "Amoxicillin")
        XCTAssertEqual(candidate?.strength, "500 mg")
        XCTAssertEqual(candidate?.scheduleTimes,
                       [DateComponents(hour: 8, minute: 0),
                        DateComponents(hour: 20, minute: 0)])
        XCTAssertEqual(recognizer.recognizedImages.count, 1)
        XCTAssertTrue(image === recognizer.recognizedImages[0],
                      "the photo handed back is the photo that was recognized")
        XCTAssertTrue(recorder.spoken.contains { $0.contains("Amoxicillin") },
                      "the name that was read is spoken: \(recorder.spoken)")
        XCTAssertEqual(recorder.outcomes, ["scanned"])
        XCTAssertEqual(recorder.events.first?.eventType, MedicationLabelScanner.eventType)
    }

    /// A label that read fine but says nothing this parser understands is NOT
    /// a failure: the photo is still attached and the app says plainly that
    /// it could not read it, so the family fills the form themselves.
    func testUnreadableLabelKeepsThePhotoAndSaysNothingWasRead() {
        let recorder = Recorder()
        let presenter = FakePresenter(outcome: .captured(makeImage()))
        let recognizer = FakeRecognizer()
        recognizer.lines = ["!! ??", "12345"]
        let scanner = makeScanner(presenter: presenter, recognizer: recognizer, recorder: recorder)

        var result: MedicationLabelScanResult?
        scanner.start { result = $0 }

        guard case .scanned(_, let candidate)? = result else {
            return XCTFail("expected .scanned, got \(String(describing: result))")
        }
        XCTAssertEqual(candidate, .empty,
                       "an empty candidate, not nil: the read ran and found nothing usable")
        XCTAssertEqual(recorder.outcomes, ["noText"])
        XCTAssertEqual(recorder.spoken,
                       [L10n.str("meds.scan.noText", locale: english)])
    }

    /// A strength or a schedule WITHOUT a name does not speak the "read it"
    /// line: telling someone the label was read over a blank name field is a
    /// claim this app does not make.
    func testStrengthWithoutANameDoesNotClaimTheLabelWasRead() {
        let recorder = Recorder()
        let presenter = FakePresenter(outcome: .captured(makeImage()))
        let recognizer = FakeRecognizer()
        recognizer.lines = ["500 mg"]
        let scanner = makeScanner(presenter: presenter, recognizer: recognizer, recorder: recorder)

        var result: MedicationLabelScanResult?
        scanner.start { result = $0 }

        guard case .scanned(_, let candidate)? = result else {
            return XCTFail("expected .scanned, got \(String(describing: result))")
        }
        XCTAssertNil(candidate?.name)
        XCTAssertEqual(candidate?.strength, "500 mg")
        XCTAssertEqual(recorder.outcomes, ["noText"])
    }

    /// Vision refusing the request is still not a lost photo: the scan ends
    /// in `.scanned` with a NIL candidate (distinct from the empty one — the
    /// ledger records which it was), and the picture reaches the medicine.
    func testRecognitionFailureReturnsThePhotoWithNoCandidate() {
        let recorder = Recorder()
        let photo = makeImage()
        let presenter = FakePresenter(outcome: .captured(photo))
        let recognizer = FakeRecognizer()
        recognizer.error = .noUsableImage
        let scanner = makeScanner(presenter: presenter, recognizer: recognizer, recorder: recorder)

        var result: MedicationLabelScanResult?
        scanner.start { result = $0 }

        guard case .scanned(let image, let candidate)? = result else {
            return XCTFail("expected .scanned, got \(String(describing: result))")
        }
        XCTAssertNil(candidate)
        XCTAssertTrue(image === photo)
        XCTAssertEqual(recorder.outcomes, ["ocrFailed"])
        XCTAssertEqual(recorder.spoken,
                       [L10n.str("meds.scan.noText", locale: english)])
    }

    // MARK: - The camera

    /// A closed camera is a one-word acknowledgement, never silence, and no
    /// OCR pass runs over a photo that was never taken.
    func testCancelledCameraIsAcknowledgedAndNothingIsRead() {
        let recorder = Recorder()
        let presenter = FakePresenter(outcome: .cancelled)
        let recognizer = FakeRecognizer()
        let scanner = makeScanner(presenter: presenter, recognizer: recognizer, recorder: recorder)

        var result: MedicationLabelScanResult?
        scanner.start { result = $0 }

        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(recognizer.recognizedImages.isEmpty)
        XCTAssertEqual(recorder.outcomes, ["cancelled"])
        XCTAssertEqual(recorder.spoken,
                       [L10n.str("apps.camera.cancelled", locale: english)])
    }

    /// The three reasons the camera cannot be shown each get their OWN line:
    /// a phone with no camera, a refused permission and nothing to present
    /// from have three different fixes, and collapsing them would send
    /// someone to Settings over hardware.
    func testUnavailableCameraSpeaksTheReasonAndNeverPresentsOrReads() {
        let cases: [(CameraAvailability, String, String)] = [
            (.noCamera, "apps.camera.unavailable", "noCamera"),
            (.permissionDenied, "apps.camera.permissionDenied", "permissionDenied"),
            (.cannotPresent, "apps.camera.cannotPresent", "cannotPresent")
        ]
        for (availability, key, outcome) in cases {
            let recorder = Recorder()
            let presenter = FakePresenter(availability: availability)
            let recognizer = FakeRecognizer()
            let scanner = makeScanner(presenter: presenter, recognizer: recognizer, recorder: recorder)

            var result: MedicationLabelScanResult?
            scanner.start { result = $0 }

            XCTAssertEqual(result, .unavailable(availability))
            XCTAssertEqual(presenter.presentCount, 0, "no sheet may appear for \(availability)")
            XCTAssertTrue(recognizer.recognizedImages.isEmpty)
            XCTAssertEqual(recorder.spoken, [L10n.str(key, locale: english)])
            XCTAssertEqual(recorder.outcomes, [outcome])
        }
    }

    /// A second tap while the camera is up is ANSWERED, not stacked: the
    /// running session keeps its single pending outcome (overwriting it is
    /// how a scan goes missing) and the second request is told honestly that
    /// it cannot run right now.
    func testSecondStartWhileRunningIsRefusedAndTheFirstSessionSurvives() {
        let recorder = Recorder()
        let presenter = FakePresenter()
        presenter.holdSession = true
        let recognizer = FakeRecognizer()
        recognizer.lines = ["Amlodipine"]
        let scanner = makeScanner(presenter: presenter, recognizer: recognizer, recorder: recorder)

        var first: MedicationLabelScanResult?
        var second: MedicationLabelScanResult?
        scanner.start { first = $0 }
        scanner.start { second = $0 }

        XCTAssertEqual(second, .unavailable(.cannotPresent))
        XCTAssertEqual(presenter.presentCount, 1, "one camera, one session")

        presenter.finishHeldSession(with: .captured(makeImage()))
        guard case .scanned(_, let candidate)? = first else {
            return XCTFail("expected the first session to finish, got \(String(describing: first))")
        }
        XCTAssertEqual(candidate?.name, "Amlodipine")
    }

    /// The ledger never carries user content (C9): the event type is the
    /// fixed one and the outcome names the PATH only, for every ending.
    func testEveryOutcomeIsEmittedOnTheFixedEventTypeWithoutContent() {
        for outcome in [CameraCaptureOutcome.captured(makeImage()), .cancelled] {
            let recorder = Recorder()
            let presenter = FakePresenter(outcome: outcome)
            let recognizer = FakeRecognizer()
            recognizer.lines = ["Amoxicillin 500 mg"]
            let scanner = makeScanner(presenter: presenter, recognizer: recognizer, recorder: recorder)

            scanner.start { _ in }

            XCTAssertEqual(recorder.events.count, 1)
            XCTAssertEqual(recorder.events.first?.eventType, "medication_label_scan")
            XCTAssertFalse(recorder.outcomes.contains { $0.contains("Amoxicillin") },
                           "no recognized text in the ledger: \(recorder.outcomes)")
        }
    }
}
