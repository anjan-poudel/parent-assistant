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
    /// There IS a camera and the permission is in order, but there is no
    /// view controller to present the picker from (no key window yet, or
    /// the app is between scenes). T4's presenter reports it; it is kept
    /// distinct from `noCamera` because the guidance differs — the elder
    /// should try again, not conclude their phone has no camera.
    case cannotPresent
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
    /// [APP-LAUNCHER F7] Resolves the add-only authorization BEFORE the
    /// camera is presented. `completion(true)` means a save can be
    /// attempted later; `completion(false)` means it cannot — and an elder
    /// who is about to press a shutter must be told that BEFORE the shot,
    /// not after it.
    ///
    /// This is the whole point of the split: the permission prompt (and
    /// the refusal it can end in) belongs in front of the camera, while
    /// there is still nothing to lose. Doing it after the shutter meant a
    /// first-time refusal threw the photo away.
    func prepareToSave(completion: @escaping (Bool) -> Void)

    /// Saves `image` to the user's photo library — ADD-ONLY, never read.
    /// `completion(true)` only when the asset was really created;
    /// `completion(false)` is reported to the elder, never swallowed.
    ///
    /// MUST NOT prompt: by the time this is called the elder has already
    /// taken the photo, and a permission sheet over the just-dismissed
    /// camera is both a worse moment to ask and impossible to attach an
    /// outcome to (`prepareToSave` is that conversation).
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

    /// True from the moment a session begins until its outcome (or its
    /// save) has been reported. [APP-LAUNCHER F5] The flow is built ONCE
    /// and lives for the app's lifetime (`AppCoordinator.cameraCapture`),
    /// so without this a second "क्यामेरा खोल" while the camera was still
    /// up stacked a second picker over the first and overwrote the
    /// presenter's single completion slot — after which the elder's shot
    /// reported into a nil slot and the photo was silently lost.
    private var isRunning = false

    /// Begins the capture. One session at a time: a second `start()` while
    /// a session is in flight is answered with the honest "cannot right
    /// now" line and changes nothing about the session already running.
    func start() {
        guard !isRunning else {
            // Deliberately NOT `handle(.unavailable(...))`: that would end
            // the running session's state. This is a report about the
            // second request only.
            deliver { [weak self] in
                self?.reportUnavailable(.cannotPresent)
            }
            return
        }
        isRunning = true
        switch presenter.availability {
        case .available:
            // [APP-LAUNCHER F7] The save permission is resolved HERE —
            // before the picker is presented, while the only thing a
            // refusal costs is a sentence. A refusal never reaches the
            // shutter, so there is no photo to discard.
            saver.prepareToSave { [weak self] granted in
                guard let self else { return }
                self.deliver {
                    guard self.isRunning else { return }
                    if granted {
                        self.presentCamera()
                    } else {
                        self.reportSavePermissionDenied()
                    }
                }
            }
        case .noCamera, .permissionDenied, .cannotPresent:
            // Never present a sheet that cannot appear: the honest
            // guidance is the whole answer, and it is the same line the
            // coordinator speaks when no presenter is wired at all.
            //
            // [APP-LAUNCHER F15] Routed through `deliver` like every other
            // outcome. Every channel below (speech, the outcome card, the
            // bus) is main-confined, and this branch used to call them
            // synchronously on whatever queue `start()` arrived on — a
            // caller off main spoke off main, which is exactly the
            // isolation the injected hop exists to keep.
            let reason = presenter.availability
            deliver { [weak self] in
                self?.handle(.unavailable(reason))
            }
        }
    }

    private func presentCamera() {
        presenter.presentCamera { [weak self] outcome in
            guard let self else { return }
            self.deliver { self.handle(outcome) }
        }
    }

    private func handle(_ outcome: CameraCaptureOutcome) {
        switch outcome {
        case .unavailable(let reason):
            reportUnavailable(reason)
        case .cancelled:
            // The elder answered a spoken confirmation a moment ago and
            // then closed the camera: a one-word acknowledgement, so the
            // assistant never goes silent mid-conversation. Nothing is
            // saved and nothing is claimed.
            channels.speak(L10n.str("apps.camera.cancelled", locale: locale()))
            channels.emit("camera_capture_cancelled", "cancelled")
            isRunning = false
        case .captured(let image):
            saver.savePhoto(image) { [weak self] saved in
                guard let self else { return }
                self.deliver { self.finishSave(saved: saved) }
            }
        }
    }

    /// The camera could not be shown, for a reason the elder can act on.
    /// Ends the session (nothing more will be reported for it).
    private func reportUnavailable(_ reason: CameraAvailability) {
        let key = Self.unavailableKey(for: reason)
        let text = L10n.str(key, locale: locale())
        channels.announce("exclamationmark.triangle.fill", text)
        channels.speak(text)
        channels.emit("camera_capture_unavailable", Self.outcomeName(for: reason))
        isRunning = false
    }

    /// [APP-LAUNCHER F7] The photo-library permission was refused (or is
    /// restricted), so a capture could not be saved even if it were taken.
    /// Said BEFORE the camera, in its own words: this is a different
    /// problem from a refused camera permission, and it has a different
    /// fix (`apps.camera.savePermissionDenied` points at Photos, not at
    /// Camera). Nothing is presented, nothing is captured, and no photo is
    /// ever discarded after the fact.
    private func reportSavePermissionDenied() {
        let text = L10n.str("apps.camera.savePermissionDenied", locale: locale())
        channels.announce("exclamationmark.triangle.fill", text)
        channels.speak(text)
        channels.emit("camera_capture_unavailable", "savePermissionDenied")
        isRunning = false
    }

    /// Why the camera cannot be presented, in the elder's words: a device
    /// with no camera, a refused permission and a camera that cannot be
    /// shown right now are three different problems with three different
    /// things to do about them. Collapsing them would send someone to
    /// Settings over a phone that has no camera at all.
    ///
    /// Internal rather than private since [MED-OCR] (2026-09-18): the
    /// medication-label scanner presents the same camera and must answer the
    /// same three reasons with the same three lines — one table, so the two
    /// camera surfaces can never drift into telling a household with no
    /// camera to check its Settings.
    static func unavailableKey(for reason: CameraAvailability) -> String {
        switch reason {
        case .permissionDenied: return "apps.camera.permissionDenied"
        case .cannotPresent: return "apps.camera.cannotPresent"
        case .available, .noCamera: return "apps.camera.unavailable"
        }
    }

    /// The observability outcome name for the same reason (metadata-free,
    /// C9 — the reason is a device/permission fact, never user content).
    /// Internal for the same reason as `unavailableKey` above.
    static func outcomeName(for reason: CameraAvailability) -> String {
        switch reason {
        case .permissionDenied: return "permissionDenied"
        case .cannotPresent: return "cannotPresent"
        case .available, .noCamera: return "noCamera"
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
        // The session is over: the next "क्यामेरा खोल" gets a fresh one.
        isRunning = false
    }
}
