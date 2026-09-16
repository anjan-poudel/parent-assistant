import Foundation
import UIKit

/// Camera capture seams (voice app launcher, camera special path,
/// 2026-09-16).
///
/// iOS exposes NO URL scheme a third-party app can use to open the Camera
/// app (the community `camera://` only resolves inside Shortcuts), so the
/// catalog's `camera` entry carries no URL at all (`AppLauncher.Kind.camera`)
/// and is answered in-process instead: the system camera UI —
/// `UIImagePickerController` with `sourceType = .camera` — is presented by
/// this app, and the captured photo is saved to the Photos library.
///
/// Everything that touches UIKit or the photo library sits behind the two
/// protocols below, so:
///   · the flow that DECIDES what to say (this file) is unit-testable with
///     doubles, on the simulator, with no camera and no permissions, and
///   · the production implementations (`PhotoCameraPresenter`,
///     `PhotosLibraryPhotoSaver`) are thin adapters whose only job is to
///     translate the system's callbacks into these outcomes.

/// Whether the system camera UI can be presented at all.
enum CameraAvailability: Equatable {
    /// A capture device exists and this app is allowed to use it.
    case available
    /// No usable capture device: the simulator, or camera-less hardware.
    case noCamera
    /// Camera access was refused or restricted for this app.
    case permissionDenied
}

/// What one camera session produced. Every path out of the camera is one
/// of these — a dismissed sheet and a failed presentation are outcomes,
/// never exceptions, because the elder must always hear what happened.
enum CameraCaptureOutcome: Equatable {
    /// The shutter fired. The image is handed to the save step.
    case captured(UIImage)
    /// The elder closed the camera without taking a photo.
    case cancelled
    /// The camera UI never appeared — the reason decides which honest
    /// guidance the flow speaks (no device vs no permission).
    case unavailable(CameraAvailability)
}

/// The injectable presentation seam. Production is `PhotoCameraPresenter`
/// (the system picker); tests supply a double that scripts any outcome,
/// which is how the no-camera and permission-denied paths are covered
/// without a device.
protocol CameraCapturePresenting: AnyObject {
    /// Probed BEFORE presenting, so an unavailable camera is answered with
    /// spoken guidance instead of a sheet that cannot appear.
    var availability: CameraAvailability { get }

    /// Presents the system camera UI. Calls `completion` exactly once,
    /// with the single outcome of the session; implementations must not
    /// require the camera to be available (a presenter may still report
    /// `.unavailable` when the device changed under it).
    func presentCamera(completion: @escaping (CameraCaptureOutcome) -> Void)
}

/// The injectable photo-library write seam. Production is
/// `PhotosLibraryPhotoSaver` (`PHPhotoLibrary` add-only); tests supply a
/// double that reports saved / not-saved on demand.
protocol PhotoSaving: AnyObject {
    /// Saves `image` to the user's photo library — ADD-ONLY, never read.
    /// `completion(true)` only when the asset was really created;
    /// `completion(false)` is reported to the elder, never swallowed.
    func savePhoto(_ image: UIImage, completion: @escaping (Bool) -> Void)
}

/// Orchestrates one camera capture: probe → present → save → say what
/// actually happened.
///
/// The design (docs/superpowers/specs/2026-09-16-app-deeplink-launcher-design.md
/// §Decisions D2, §Error handling) makes the SPOKEN outcome part of the
/// feature: "photo saved" after a capture, an honest failure when the save
/// did not happen, guidance when the camera cannot be presented. Those
/// lines live here — not in the UIKit adapters — so they can be pinned by
/// tests, and so the coordinator's only job is to hand the flow the real
/// speaker/card/bus channels.
///
/// `start()` is called on the main thread and returns immediately; the
/// camera session outlives it, and every callback is marshalled back onto
/// the main queue before any channel is invoked (speech, the outcome card
/// and the observability bus are all main-confined elsewhere in the app).
final class CameraCaptureFlow {

    /// Where the flow's words and outcomes go. The coordinator wires these
    /// to its speaker, its outcome card and the observability bus — the
    /// flow never touches them directly, which is what keeps it testable.
    struct Channels {
        /// Speak this aloud.
        let speak: (String) -> Void
        /// Show this on the outcome card: (SF Symbol, text).
        let announce: (String, String) -> Void
        /// Observability: (eventType, outcome). Metadata-free by contract —
        /// no image, no file name, nothing user-identifying (constitution
        /// C9).
        let emit: (String, String) -> Void
    }

    private let presenter: CameraCapturePresenting
    private let saver: PhotoSaving
    private let locale: () -> Locale
    private let channels: Channels
    /// The main-queue hop applied to every system callback. Injected so
    /// tests can drive the flow synchronously; production is
    /// `DispatchQueue.main.async`.
    private let deliver: (@escaping () -> Void) -> Void

    init(presenter: CameraCapturePresenting,
         saver: PhotoSaving,
         locale: @escaping () -> Locale,
         channels: Channels,
         deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.presenter = presenter
        self.saver = saver
        self.locale = locale
        self.channels = channels
        self.deliver = deliver
    }

    /// Begins the capture. Safe to call once per flow instance (each
    /// launch builds a new one).
    func start() {
        switch presenter.availability {
        case .available:
            presenter.presentCamera { [weak self] outcome in
                guard let self else { return }
                self.deliver { self.handle(outcome) }
            }
        case .noCamera, .permissionDenied:
            // Never present a sheet that cannot appear: the honest
            // guidance is the whole answer, and it is the same line the
            // coordinator speaks when no presenter is wired at all.
            handle(.unavailable(presenter.availability))
        }
    }

    private func handle(_ outcome: CameraCaptureOutcome) {
        switch outcome {
        case .unavailable(let reason):
            let key = reason == .permissionDenied
                ? "apps.camera.permissionDenied"
                : "apps.camera.unavailable"
            let text = L10n.str(key, locale: locale())
            channels.announce("exclamationmark.triangle.fill", text)
            channels.speak(text)
            channels.emit("camera_capture_unavailable",
                          reason == .permissionDenied ? "permissionDenied" : "noCamera")
        case .cancelled:
            // The elder answered a spoken confirmation a moment ago and
            // then closed the camera: a one-word acknowledgement, so the
            // assistant never goes silent mid-conversation. Nothing is
            // saved and nothing is claimed.
            channels.speak(L10n.str("apps.camera.cancelled", locale: locale()))
            channels.emit("camera_capture_cancelled", "cancelled")
        case .captured(let image):
            saver.savePhoto(image) { [weak self] saved in
                guard let self else { return }
                self.deliver { self.finishSave(saved: saved) }
            }
        }
    }

    /// The save's honest verdict. A failed write is spoken — the elder
    /// pressed the shutter and must not be left believing a photo exists
    /// when it does not (constitution: no silent stubs).
    private func finishSave(saved: Bool) {
        let text = L10n.str(saved ? "apps.camera.photoSaved" : "apps.camera.saveFailed",
                            locale: locale())
        channels.announce(saved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", text)
        channels.speak(text)
        channels.emit("camera_capture_finished", saved ? "photoSaved" : "saveFailed")
    }
}
