import AVFoundation
import UIKit

/// Production `CameraCapturePresenting` (voice app launcher, camera
/// special path, 2026-09-16): the system camera UI —
/// `UIImagePickerController` with `sourceType = .camera` — presented from
/// the app's own window.
///
/// Why the system picker and not a custom capture UI: it is the standard,
/// already-accessible camera an elder recognises, it needs no camera
/// entitlement of its own, and its permission prompt is the one iOS
/// understands (design §Decisions D2). The catalog's `camera` entry has no
/// URL scheme to open, which is exactly why this class exists.
///
/// Everything device-, permission- or presentation-shaped is injected, so
/// the paths that matter — no camera (the simulator every test run uses),
/// permission already refused, permission asked at point of use, the
/// chosen photo, a cancel, and a missing host — are all covered without a
/// device, and the decision layer (`CameraCaptureFlow`) never has to know
/// UIKit exists.
final class PhotoCameraPresenter: NSObject, CameraCapturePresenting {

    /// The view controller the picker is presented from — resolved AT
    /// PRESENT TIME (never cached: the key window can change while a
    /// conversation is in flight). nil is reported as `.cannotPresent`,
    /// never as a missing camera.
    private let host: () -> UIViewController?
    /// Whether the device has a usable capture device. Injected so tests
    /// can script the simulator's `false` (and a device's `true`) instead
    /// of depending on the machine the suite runs on.
    private let cameraIsAvailable: () -> Bool
    /// The app's current camera authorization, read BEFORE presenting so a
    /// refusal is answered with the honest guidance line instead of a
    /// picker that cannot work.
    private let cameraAuthorization: () -> AVAuthorizationStatus
    /// The point-of-use permission request (only when the status is still
    /// `.notDetermined`). Injected for the same reason as the probe.
    private let requestCameraAccess: (@escaping (Bool) -> Void) -> Void
    /// How the picker reaches the screen. Injected so the presenter's
    /// outcome mapping is testable without a window hierarchy — the real
    /// one is `host.present(picker, animated: true)`.
    private let present: (UIViewController, UIViewController) -> Void

    /// Builds the picker that gets configured. Injected so a test can
    /// assert the configuration (source type, capture mode, delegate,
    /// presentation style) without asking a camera-less test machine for a
    /// camera source — the production value is a plain
    /// `UIImagePickerController`.
    private let makePicker: () -> UIImagePickerController

    /// The in-flight session. Held (and cleared when it ends) so the
    /// delegate callbacks reach the completion exactly once.
    private var completion: ((CameraCaptureOutcome) -> Void)?

    init(host: @escaping () -> UIViewController? = PhotoCameraPresenter.keyWindowTopmost,
         cameraIsAvailable: @escaping () -> Bool = {
             UIImagePickerController.isSourceTypeAvailable(.camera)
         },
         cameraAuthorization: @escaping () -> AVAuthorizationStatus = {
             AVCaptureDevice.authorizationStatus(for: .video)
         },
         requestCameraAccess: @escaping (@escaping (Bool) -> Void) -> Void = { completion in
             AVCaptureDevice.requestAccess(for: .video) { granted in
                 DispatchQueue.main.async { completion(granted) }
             }
         },
         present: @escaping (UIViewController, UIViewController) -> Void = { host, picker in
             host.present(picker, animated: true)
         },
         makePicker: @escaping () -> UIImagePickerController = { UIImagePickerController() }) {
        self.host = host
        self.cameraIsAvailable = cameraIsAvailable
        self.cameraAuthorization = cameraAuthorization
        self.requestCameraAccess = requestCameraAccess
        self.present = present
        self.makePicker = makePicker
        super.init()
    }

    /// Probed before presenting. MAIN THREAD ONLY (it reads UIKit and
    /// AVFoundation); `CameraCaptureFlow.start()` runs on main.
    var availability: CameraAvailability {
        // The no-device answer comes first: a device with no camera has no
        // permission question to ask, and the simulator must hear the
        // "nothing to photograph with" line rather than a permission
        // lecture.
        guard cameraIsAvailable() else { return .noCamera }
        guard host() != nil else { return .cannotPresent }
        switch cameraAuthorization() {
        case .authorized, .notDetermined:
            // `.notDetermined` counts as available: the prompt is asked at
            // point of use, which is the moment the elder asked for the
            // camera — asking at launch would be a cold, unexplained
            // prompt, and the design's whole point is that the elder's
            // request IS the consent.
            return .available
        case .denied, .restricted:
            return .permissionDenied
        @unknown default:
            // A future status this build does not know: refusing to guess
            // "available" keeps the failure honest (never a black screen).
            return .permissionDenied
        }
    }

    func presentCamera(completion: @escaping (CameraCaptureOutcome) -> Void) {
        // UIKit and AVFoundation are main-thread-only, and the flow's
        // caller may be anywhere.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.presentCamera(completion: completion)
            }
            return
        }
        // [APP-LAUNCHER F5] One session per presenter. Overwriting the
        // slot is how a photo goes missing: the first session's completion
        // is dropped on the floor, and when its picker's delegate callback
        // arrives it finds `completion == nil` and reports nothing at all —
        // the elder pressed the shutter and heard silence. A second
        // request while one is live is answered immediately and honestly
        // instead, and the running session is left untouched.
        guard self.completion == nil else {
            completion(.unavailable(.cannotPresent))
            return
        }
        self.completion = completion
        if cameraAuthorization() == .notDetermined {
            requestCameraAccess { [weak self] granted in
                guard let self else { return }
                // The injected request already hops back to main: a granted
                // request is a real "available" and gets the picker, a
                // refused one is the permission line.
                granted ? self.presentPicker()
                        : self.finish(.unavailable(.permissionDenied))
            }
            return
        }
        presentPicker()
    }

    /// Presents the picker — or reports, honestly, why it cannot be.
    private func presentPicker() {
        guard cameraIsAvailable() else { return finish(.unavailable(.noCamera)) }
        let authorization = cameraAuthorization()
        guard authorization != .denied, authorization != .restricted else {
            return finish(.unavailable(.permissionDenied))
        }
        guard let host = host() else { return finish(.unavailable(.cannotPresent)) }
        let picker = makePicker()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = self
        // Full screen: an elder who asked for the camera should see the
        // camera, not a card they can swipe away by accident.
        picker.modalPresentationStyle = .fullScreen
        present(host, picker)
    }

    /// Delivers the single outcome of this session (idempotent: a delegate
    /// callback arriving after the session ended is dropped rather than
    /// double-reported).
    private func finish(_ outcome: CameraCaptureOutcome) {
        guard let completion else { return }
        self.completion = nil
        completion(outcome)
    }

    /// The topmost view controller of the app's key window — the only
    /// place a UIKit modal can be presented from in a SwiftUI app. Main
    /// thread only (callers hop first).
    static func keyWindowTopmost() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes.flatMap(\.windows).first { $0.isKeyWindow }
            ?? scenes.first?.windows.first
        guard var top = keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            // A sheet/card already up is where the camera belongs — over
            // the app's own chrome, never behind it.
            top = presented
        }
        return top
    }
}

// MARK: - UIImagePickerControllerDelegate

extension PhotoCameraPresenter: UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        // `.originalImage` is the camera's full-resolution photo (`.edited`
        // only exists after in-picker editing, which this flow does not
        // offer). An info dictionary with no image — a media type the
        // picker should never hand a `.photo` capture — is reported as a
        // cancel rather than as a bogus "saved".
        guard let image = info[.originalImage] as? UIImage else {
            return finish(.cancelled)
        }
        finish(.captured(image))
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        // [APP-LAUNCHER F4] Dismiss here too — this callback used to trust
        // that "the picker dismisses itself on cancel", and it does not:
        // `dismiss(animated:)` is the PRESENTER's job in this flow, and the
        // capture path has always done it. Without it the camera stayed on
        // screen over the app while the flow had already reported the
        // cancel and moved on — a dead sheet the elder could only stare at.
        picker.dismiss(animated: true)
        // The flow speaks the gentle acknowledgement; this layer only
        // reports.
        finish(.cancelled)
    }
}
