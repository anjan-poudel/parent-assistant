#if os(iOS)
import Foundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

// C04 — the two production capture surfaces behind T-009's seams
// (design L2 §2.4, §7.4, §9.1, §11.3 J/P; FR-RIE-004/005/006/025).
//
// These adapters own presentation and translation only. They never stage,
// validate, trim, compress, transcode, preview or upload: the chosen file's
// URL goes straight into the injected `makeStagedCopy` callback, synchronously
// inside the system callback that produced it (§7.4). Neither adapter reads or
// requests a photo-library authorization; the picker is out of process and the
// recorder uses the camera's own permission, which T-006 resolves before this
// surface is presented.
//
// Task-over-design note (T-010): design L1 §C04 maps a PHPicker result with no
// movie representation to `.unreadableSource`. The task text is authoritative
// and requires every provider-load failure to map to
// `.writeFailed(.stagingFailed)`, so that is what this file does. Only a
// provider cancellation (Foundation's `NSUserCancelledError`) maps to
// `.cancelled`.
//
// Naming note: design L1 calls these types `InstructionVideoLibraryPicker` and
// `SystemInstructionVideoRecorder`; design L2 §2.0 and task T-010 specify the
// `PHPickerInstructionVideoPicker` / `UIImagePickerInstructionVideoRecorder`
// names used here.

/// Storage for the staging callback a system surface was presented with.
private typealias InstructionCaptureStaging =
    @MainActor (URL) -> Result<StagedInstructionVideo, InstructionImportError>

/// Storage for the exactly-once completion a system surface reports through.
private typealias InstructionCaptureCompletion =
    @MainActor (Result<StagedInstructionVideo, InstructionImportError>) -> Void

/// Runs `body` on the main thread **synchronously**.
///
/// `NSItemProvider.loadFileRepresentation` delivers its completion on a queue
/// Foundation chooses, and the URL it hands over is deleted the moment that
/// completion returns. The staging callback is `@MainActor`, so the hop must be
/// `DispatchQueue.main.sync` — never `async` — and `MainActor.assumeIsolated`
/// proves the isolation once the main thread is reached (design §7.4).
private func instructionCaptureRunOnMainSynchronously<T>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated { body() }
    }
    return DispatchQueue.main.sync {
        MainActor.assumeIsolated { body() }
    }
}

/// Maps a provider failure into the closed import vocabulary (T-010).
///
/// A cancellation (the person dismissed the loading sheet, or the load was
/// cancelled) is `.cancelled`; every other load failure means the chosen movie
/// could not be staged, which is `.writeFailed(.stagingFailed)`. The
/// `NSError`, its domain and its description never escape this function.
private func instructionCaptureProviderFailure(for error: Error?) -> InstructionImportError {
    guard let error else { return .writeFailed(.stagingFailed) }
    return instructionCaptureIsCancellation(error) ? .cancelled : .writeFailed(.stagingFailed)
}

/// `NSItemProvider` normalises every loader failure into its own error domain
/// and preserves the loader's own error under `NSUnderlyingError`; an already
/// normalised error can also arrive directly. Cancellation is recognised at
/// either level, so a dismissed load reports `.cancelled` instead of a false
/// staging failure.
private func instructionCaptureIsCancellation(_ error: Error) -> Bool {
    let failure = error as NSError
    if failure.domain == NSCocoaErrorDomain, failure.code == NSUserCancelledError {
        return true
    }
    if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled {
        return true
    }
    if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
        return instructionCaptureIsCancellation(underlying)
    }
    return false
}

// MARK: - Library picker (IF-16)

/// The production `InstructionVideoPicking` adapter: an out-of-process
/// `PHPickerViewController` restricted to videos.
///
/// Why `PHPickerViewController`: it runs outside the app's process, so it needs
/// no photo-library authorization request and no `NSPhotoLibraryUsageDescription`
/// — the person sees only their own chosen video and this app never gains
/// library access. There is deliberately no `PHPhotoLibrary` call anywhere in
/// this file, no photo/image filter, and no preselection.
///
/// Presentation is injected so the adapter is exercised in tests without a
/// window hierarchy; production presents the controller the closure receives.
/// `completion` is called exactly once on every path — picked, cancelled,
/// failed or dismissed — always on the main actor.
@MainActor
final class PHPickerInstructionVideoPicker: NSObject, InstructionVideoPicking {

    /// The one picker configuration this feature allows (design L1 §C04;
    /// design L2 §7.4).
    ///
    /// `.videos` is the only filter, one item at a time, no preselected
    /// identifiers and `.current` representation so the system never
    /// transcodes the person's file. Static and pure so the suite inspects it
    /// without presenting UI.
    static func makeConfiguration() -> PHPickerConfiguration {
        var configuration = PHPickerConfiguration()
        configuration.filter = .videos
        configuration.selectionLimit = 1
        configuration.preselectedAssetIdentifiers = []
        configuration.preferredAssetRepresentationMode = .current
        return configuration
    }

    /// How the constructed controller reaches the screen. Injected so tests
    /// never open UI.
    private let present: @MainActor (UIViewController) -> Void

    /// The current session's staging callback, cleared the moment the session
    /// resolves. It is never a URL and never an item provider — the two values
    /// the callback-scoped rule forbids retaining (§7.4).
    private var makeStagedCopy: InstructionCaptureStaging?
    private var completion: InstructionCaptureCompletion?
    private var picker: PHPickerViewController?

    init(present: @escaping @MainActor (UIViewController) -> Void) {
        self.present = present
        super.init()
    }

    func presentVideoPicker(
        makeStagedCopy: @escaping @MainActor (URL) -> Result<StagedInstructionVideo, InstructionImportError>,
        completion: @escaping @MainActor (Result<StagedInstructionVideo, InstructionImportError>) -> Void) {
        // The coordinator enforces single flight (§7.3); a direct double
        // presentation is refused honestly instead of overwriting the first
        // session's completion.
        guard self.completion == nil else {
            completion(.failure(.cancelled))
            return
        }
        self.makeStagedCopy = makeStagedCopy
        self.completion = completion

        let picker = PHPickerViewController(configuration: Self.makeConfiguration())
        picker.delegate = self
        self.picker = picker
        present(picker)
    }

    /// Programmatic teardown. Idempotent: reports `.cancelled` exactly once
    /// while a session is open and does nothing afterwards (the coordinator's
    /// `cancel()` invalidates its attempt first, so a late completion is
    /// ignored).
    func dismiss() {
        finish(.failure(.cancelled))
        picker?.dismiss(animated: false)
        picker = nil
    }

    /// The provider seam the delegate calls. Internal so the suite can drive a
    /// real `NSItemProvider` without presenting UI or manufacturing a
    /// `PHPickerResult`, which has no public initializer.
    ///
    /// The file is staged **inside** the provider callback, before it returns
    /// (§7.4); nothing here stores the callback URL or the item provider.
    func loadAndStage(from provider: NSItemProvider) {
        guard completion != nil else { return }
        guard provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
            // No movie representation: the person chose something this
            // feature cannot stage (task T-010 maps this to a staging
            // failure, not to an asset or format judgement).
            finish(.failure(.writeFailed(.stagingFailed)))
            return
        }
        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
            guard let self else { return }
            // Map the failure before hopping: only Sendable values cross the
            // callback boundary.
            let failure: InstructionImportError? = url == nil
                ? instructionCaptureProviderFailure(for: error)
                : nil
            instructionCaptureRunOnMainSynchronously {
                // Runs before the provider callback returns, so `url` is still
                // valid.
                self.stageLoadedFile(url, failure: failure)
            }
        }
    }

    private func stageLoadedFile(_ url: URL?, failure: InstructionImportError?) {
        guard completion != nil else { return }
        guard let url, let makeStagedCopy else {
            finish(.failure(failure ?? .writeFailed(.stagingFailed)))
            return
        }
        // IF-5's staging runs here, synchronously inside the provider callback.
        finish(makeStagedCopy(url))
    }

    /// The only exit. Clears the session before reporting so a reentrant or
    /// late callback cannot report twice, and dismisses any surface still
    /// held.
    private func finish(_ outcome: Result<StagedInstructionVideo, InstructionImportError>) {
        guard let completion else { return }
        self.completion = nil
        makeStagedCopy = nil
        let surface = picker
        picker = nil
        surface?.dismiss(animated: false)
        completion(outcome)
    }
}

extension PHPickerInstructionVideoPicker: PHPickerViewControllerDelegate {

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        // A late callback for a session that already finished is dropped.
        guard completion != nil, picker === self.picker else { return }
        // The delegate owns dismissing the system surface.
        picker.dismiss(animated: true)
        self.picker = nil
        // Empty results are the person's cancellation: no staging, no event.
        guard let provider = results.first?.itemProvider else {
            finish(.failure(.cancelled))
            return
        }
        loadAndStage(from: provider)
    }
}

// MARK: - Camera recorder (IF-17)

/// The production `InstructionVideoRecording` adapter: the system camera in
/// video mode, capped at the coordinator's configured duration.
///
/// `UIImagePickerController` is the recorder because it is the standard,
/// already-accessible camera an elder recognises, and its video capture
/// records the microphone alongside the camera — the movie media type is the
/// only media type this adapter asks for. Permission ordering is not its job:
/// T-006 resolves camera and, only after that, microphone before this surface
/// exists (§2.5.3, FR-RIE-025).
///
/// No photo-library source, no photo capture mode, no image media type, no
/// in-picker editing/trimming and no transcode. Presentation is injected;
/// `completion` is called exactly once on every path.
@MainActor
final class UIImagePickerInstructionVideoRecorder: NSObject, InstructionVideoRecording {

    /// The one recorder shape this feature allows (design L2 §2.4, §9.1).
    ///
    /// Camera source in video capture mode, the movie media type only, the
    /// configured maximum duration (the coordinator passes 180 s), and the
    /// configured quality. A pure value so the suite can pin the contract on
    /// a simulator with no camera; `makeRecorder` applies it to a real
    /// controller on a device.
    struct Configuration: Equatable {
        let sourceType: UIImagePickerController.SourceType
        let mediaTypes: [String]
        let cameraCaptureMode: UIImagePickerController.CameraCaptureMode
        let maximumDurationSeconds: TimeInterval
        let videoQuality: UIImagePickerController.QualityType
    }

    static func configuration(maximumDurationSeconds: TimeInterval,
                              quality: InstructionRecordingQuality) -> Configuration {
        Configuration(
            sourceType: .camera,
            mediaTypes: [UTType.movie.identifier],
            cameraCaptureMode: .video,
            maximumDurationSeconds: maximumDurationSeconds,
            videoQuality: quality == .high ? .typeHigh : .typeMedium
        )
    }

    /// Applies the one allowed configuration to the system controller.
    ///
    /// The camera source and its three camera-only properties are assigned
    /// only when the platform reports a camera. `UIImagePickerController`
    /// raises an Objective-C exception when a camera-only property is set on
    /// a controller whose source is unavailable (the simulator), so this
    /// guard keeps construction safe without changing the device path. The
    /// contract itself is the `Configuration` value above and is what the
    /// suite asserts.
    static func makeRecorder(maximumDurationSeconds: TimeInterval,
                             quality: InstructionRecordingQuality) -> UIImagePickerController {
        let configuration = configuration(maximumDurationSeconds: maximumDurationSeconds,
                                          quality: quality)
        let recorder = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(configuration.sourceType) {
            recorder.sourceType = configuration.sourceType
            recorder.cameraCaptureMode = configuration.cameraCaptureMode
            recorder.videoMaximumDuration = configuration.maximumDurationSeconds
            recorder.videoQuality = configuration.videoQuality
        }
        recorder.mediaTypes = configuration.mediaTypes
        recorder.allowsEditing = false
        return recorder
    }

    /// How the constructed controller reaches the screen. Injected so tests
    /// never open UI.
    private let present: @MainActor (UIViewController) -> Void

    /// Builds the surface. Injectable so the suite can exercise the delegate
    /// contract on a simulator, where a camera source cannot be constructed.
    private let makeSurface: @MainActor (TimeInterval, InstructionRecordingQuality) -> UIImagePickerController

    private var makeStagedCopy: InstructionCaptureStaging?
    private var completion: InstructionCaptureCompletion?
    private var recorder: UIImagePickerController?

    init(present: @escaping @MainActor (UIViewController) -> Void,
         makeSurface: (@MainActor (TimeInterval, InstructionRecordingQuality) -> UIImagePickerController)? = nil) {
        self.present = present
        self.makeSurface = makeSurface ?? { maximumDurationSeconds, quality in
            Self.makeRecorder(maximumDurationSeconds: maximumDurationSeconds,
                              quality: quality)
        }
        super.init()
    }

    func presentRecorder(
        maximumDurationSeconds: TimeInterval,
        quality: InstructionRecordingQuality,
        makeStagedCopy: @escaping @MainActor (URL) -> Result<StagedInstructionVideo, InstructionImportError>,
        completion: @escaping @MainActor (Result<StagedInstructionVideo, InstructionImportError>) -> Void) {
        guard self.completion == nil else {
            completion(.failure(.cancelled))
            return
        }
        self.makeStagedCopy = makeStagedCopy
        self.completion = completion

        let recorder = makeSurface(maximumDurationSeconds, quality)
        recorder.delegate = self
        self.recorder = recorder
        present(recorder)
    }

    /// Programmatic teardown. Idempotent: reports `.cancelled` exactly once
    /// while a session is open and does nothing afterwards.
    func dismiss() {
        finish(.failure(.cancelled))
        recorder?.dismiss(animated: false)
        recorder = nil
    }

    /// The only exit. Clears the session before reporting, so a second
    /// delegate call or dismissal can neither double-report nor crash, and
    /// dismisses the surface exactly as the delegate contract requires.
    private func finish(_ outcome: Result<StagedInstructionVideo, InstructionImportError>,
                        dismissing surface: UIViewController? = nil) {
        guard let completion else { return }
        self.completion = nil
        makeStagedCopy = nil
        let recorded = recorder
        recorder = nil
        (surface ?? recorded)?.dismiss(animated: false)
        completion(outcome)
    }
}

extension UIImagePickerInstructionVideoRecorder: UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        // A late callback from a session that already finished is dropped.
        guard completion != nil, picker === recorder else { return }
        // `mediaURL` is valid only until this delegate call returns, so the
        // staging callback runs here — before dismissal and before the
        // completion reports (§7.4).
        let result: Result<StagedInstructionVideo, InstructionImportError>
        if let url = info[.mediaURL] as? URL, let makeStagedCopy {
            result = makeStagedCopy(url)
        } else {
            // A video was accepted but there is no file to stage.
            result = .failure(.writeFailed(.stagingFailed))
        }
        finish(result, dismissing: picker)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        guard completion != nil, picker === recorder else { return }
        // Cancellation attempts no staging and emits no event.
        finish(.failure(.cancelled), dismissing: picker)
    }
}

#endif
