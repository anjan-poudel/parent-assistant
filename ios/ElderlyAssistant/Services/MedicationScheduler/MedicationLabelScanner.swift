import Foundation
import UIKit

// [MED-OCR] (2026-09-18) One label scan, from the shutter to a candidate.
//
// The camera half is the SAME seam the voice app launcher uses
// (`CameraCapturePresenting` / `PhotoCameraPresenter`, 2026-09-16): the system
// picker, the permission asked at point of use, and the honest
// no-camera / permission-denied / cannot-present answers all come from there.
// This type adds exactly two things on top:
//
//  - the OCR pass (behind `MedicationLabelRecognizing`, so no test needs a
//    camera or a rendered label), and
//  - the spoken outcomes, which belong to the feature rather than to UIKit:
//    a scan that read nothing must SAY so, because a silently empty form
//    looks to the family like the app ignored them.
//
// The session's own contract, copied deliberately from `CameraCaptureFlow`:
// one session at a time (a second tap while the camera is up is answered,
// not stacked), every channel invoked on the main queue, and every path out
// ending in exactly one `MedicationLabelScanResult`.

/// What one scan produced.
///
/// `.scanned` carries the photo even when the text did not come — the family
/// pressed the shutter and asked for the box to be on the medicine, and a
/// failed read is not a reason to throw their picture away.
enum MedicationLabelScanResult: Equatable {
    /// The shutter fired. `candidate` is what the parser made of the label:
    /// `nil` when recognition itself failed (nothing could be read at all),
    /// `MedicationLabelCandidate.empty` when the label simply said nothing
    /// this parser understands. Both are reported honestly and both still
    /// carry the image for the visual aid.
    case scanned(image: UIImage, candidate: MedicationLabelCandidate?)
    /// The family closed the camera without taking a photo. Nothing is
    /// attached, nothing is prefilled.
    case cancelled
    /// The camera never appeared — the reason decides which honest guidance
    /// was spoken (no device, no permission, nothing to present from).
    case unavailable(CameraAvailability)
}

/// Presents the camera, runs on-device OCR, says what happened.
final class MedicationLabelScanner {

    /// Where the scan's words and outcomes go. The coordinator wires these
    /// to its speaker and the observability bus; the scanner never touches
    /// either directly, which is what keeps it testable.
    struct Channels {
        /// Speak this aloud.
        let speak: (String) -> Void
        /// Observability: (eventType, outcome). Metadata-free by contract —
        /// no image, no recognized text, nothing user-identifying (C9).
        let emit: (String, String) -> Void
    }

    private let presenter: CameraCapturePresenting
    private let recognizer: MedicationLabelRecognizing
    private let locale: () -> Locale
    private let channels: Channels
    /// The main-queue hop applied to every system callback and to the OCR
    /// result. Injected so tests drive the flow synchronously; production is
    /// `DispatchQueue.main.async`.
    private let deliver: (@escaping () -> Void) -> Void
    /// Where the recognition pass runs. Vision is synchronous and can take a
    /// moment on a dense label, so production hands it to a background queue
    /// and the result comes back through `deliver`; tests run it inline.
    private let offload: (@escaping () -> Void) -> Void

    /// True from the moment a session begins until its result is delivered.
    /// A second `start()` while one is running changes nothing about the
    /// session already up (the presenter has one completion slot, and
    /// overwriting it is how a scan goes missing).
    private var isRunning = false

    init(presenter: CameraCapturePresenting,
         recognizer: MedicationLabelRecognizing,
         locale: @escaping () -> Locale,
         channels: Channels,
         deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         offload: @escaping (@escaping () -> Void) -> Void = { work in
             DispatchQueue.global(qos: .userInitiated).async(execute: work)
         }) {
        self.presenter = presenter
        self.recognizer = recognizer
        self.locale = locale
        self.channels = channels
        self.deliver = deliver
        self.offload = offload
    }

    /// Begins a scan. `completion` is called exactly once, on the main
    /// queue, for every possible ending.
    func start(completion: @escaping (MedicationLabelScanResult) -> Void) {
        guard !isRunning else {
            // A report about the second tap only — the running session is
            // left exactly as it is.
            deliver { [weak self] in
                self?.reportUnavailable(.cannotPresent, completion: completion)
            }
            return
        }
        isRunning = true
        switch presenter.availability {
        case .available:
            presenter.presentCamera { [weak self] outcome in
                guard let self else { return }
                self.deliver { self.handle(outcome, completion: completion) }
            }
        case .noCamera, .permissionDenied, .cannotPresent:
            // Never present a sheet that cannot appear: the honest guidance
            // is the whole answer.
            let reason = presenter.availability
            deliver { [weak self] in
                self?.reportUnavailable(reason, completion: completion)
            }
        }
    }

    private func handle(_ outcome: CameraCaptureOutcome,
                        completion: @escaping (MedicationLabelScanResult) -> Void) {
        switch outcome {
        case .unavailable(let reason):
            reportUnavailable(reason, completion: completion)
        case .cancelled:
            // The family answered the camera with a close, and the app says
            // so in one word — never silence mid-conversation.
            channels.speak(L10n.str("apps.camera.cancelled", locale: locale()))
            channels.emit(Self.eventType, "cancelled")
            isRunning = false
            completion(.cancelled)
        case .captured(let image):
            // The photo is in hand; the reading happens off the main thread.
            // A recognition failure is NOT an error path out of the flow: the
            // scan still ends in `.scanned` with a nil candidate, so the
            // picture the family just took reaches the medicine and the app
            // says plainly that nothing could be read.
            offload { [weak self] in
                guard let self else { return }
                let candidate = self.recognize(image)
                self.deliver { self.finish(image: image, candidate: candidate, completion: completion) }
            }
        }
    }

    /// The OCR pass, off the main thread. Any failure is reported as "no
    /// candidate" — the caller's next move is the same either way, and the
    /// observability event records which of the two it was.
    private func recognize(_ image: UIImage) -> MedicationLabelCandidate? {
        do {
            let lines = try recognizer.recognizeLines(in: image)
            return MedicationLabelParser.candidate(fromLines: lines)
        } catch {
            return nil
        }
    }

    /// The scan's honest verdict, spoken and emitted, before the caller's
    /// completion runs.
    private func finish(image: UIImage,
                        candidate: MedicationLabelCandidate?,
                        completion: @escaping (MedicationLabelScanResult) -> Void) {
        // The name is what the family will check first, so it is what the
        // spoken line names. A label that yielded a strength or a schedule
        // but no name still speaks the "could not read it" line: telling
        // someone "I read your label" over a blank name field is the kind of
        // claim this app does not make.
        if let name = candidate?.name {
            channels.speak(L10n.fmt("meds.scan.found", locale: locale(), name))
            channels.emit(Self.eventType, "scanned")
        } else {
            channels.speak(L10n.str("meds.scan.noText", locale: locale()))
            channels.emit(Self.eventType, candidate == nil ? "ocrFailed" : "noText")
        }
        isRunning = false
        completion(.scanned(image: image, candidate: candidate))
    }

    /// The camera could not be shown, for a reason the family can act on.
    private func reportUnavailable(_ reason: CameraAvailability,
                                   completion: @escaping (MedicationLabelScanResult) -> Void) {
        channels.speak(L10n.str(CameraCaptureFlow.unavailableKey(for: reason),
                                locale: locale()))
        channels.emit(Self.eventType, CameraCaptureFlow.outcomeName(for: reason))
        isRunning = false
        completion(.unavailable(reason))
    }

    static let eventType = "medication_label_scan"
}
