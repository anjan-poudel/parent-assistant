import Photos
import UIKit

/// Production `PhotoSaving` (voice app launcher, camera special path,
/// 2026-09-16): writes one captured photo into the user's library through
/// `PHPhotoLibrary`, ADD-ONLY.
///
/// Add-only is a deliberate privacy boundary, not an implementation
/// detail: the app declares `NSPhotoLibraryAddUsageDescription` (T2) and
/// asks for `.addOnly` access, so it can never read the elder's library —
/// a camera flow that could enumerate someone's photos is a much bigger
/// promise than the one the elder made by saying "क्यामेरा खोल".
///
/// The verdict is honest and single-valued: `completion(true)` only when
/// the library really reported success. Every other path — no JPEG
/// representation, permission refused, a failed write — reports
/// `completion(false)`, which `CameraCaptureFlow` speaks out loud
/// (constitution: no silent stubs; an elder must never believe a photo
/// exists when it does not).
final class PhotosLibraryPhotoSaver: PhotoSaving {

    /// Whole-image JPEG quality. 0.9 keeps a phone photo's detail at a
    /// fraction of the original size — these are memory photos for a
    /// family, not print masters.
    private let compressionQuality: CGFloat

    /// Turns the captured image into the bytes the library will store.
    /// Injected so the "cannot encode" path is deterministic in tests (a
    /// `UIImage` with no JPEG representation) and so a test can see the
    /// exact bytes handed to the library.
    private let encodeJPEG: (UIImage) -> Data?

    /// The current add-only authorization, READ ONLY, with no prompt. Used
    /// by the pre-flight (when the status is already decided) and by the
    /// save itself, which must never ask (see `savePhoto`). Injected so
    /// tests can script every status without a device.
    private let photoAuthorizationStatus: () -> PHAuthorizationStatus

    /// The authorization round trip (the prompt), injected so tests can
    /// script every status without a device that has already been asked.
    /// [APP-LAUNCHER F7] Called from `prepareToSave` ONLY — never from the
    /// post-shutter path.
    private let requestAuthorization: (@escaping (PHAuthorizationStatus) -> Void) -> Void

    /// Builds the change block that creates the asset — the ONLY place an
    /// asset is created, and the seam a test uses to see the exact bytes
    /// the library would receive. The default is the add-only creation
    /// request; nothing else here can write to (or read from) the library.
    private let makeAssetCreationBlock: (Data) -> () -> Void

    /// Runs a change block and reports the library's own verdict. Injected
    /// so tests can drive real success/failure without touching the photo
    /// library.
    private let performChanges: (@escaping () -> Void,
                                 @escaping (Bool, Error?) -> Void) -> Void

    init(compressionQuality: CGFloat = 0.9,
         encodeJPEG: ((UIImage) -> Data?)? = nil,
         photoAuthorizationStatus: @escaping () -> PHAuthorizationStatus = {
             // `.addOnly` — iOS 14+, and the app's deployment floor is 16,
             // so there is no older branch to keep. Read-only: this call
             // never prompts.
             PHPhotoLibrary.authorizationStatus(for: .addOnly)
         },
         requestAuthorization: @escaping (@escaping (PHAuthorizationStatus) -> Void) -> Void
            = { completion in
                // `.addOnly` — iOS 14+, and the app's deployment floor is
                // 16, so there is no older branch to keep.
                PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: completion)
            },
         makeAssetCreationBlock: @escaping (Data) -> () -> Void = { data in
             {
                 let request = PHAssetCreationRequest.forAsset()
                 request.addResource(with: .photo, data: data, options: nil)
             }
         },
         performChanges: @escaping (@escaping () -> Void,
                                    @escaping (Bool, Error?) -> Void) -> Void
            = { changes, completion in
                PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
            }) {
        self.compressionQuality = compressionQuality
        self.encodeJPEG = encodeJPEG
            ?? { $0.jpegData(compressionQuality: compressionQuality) }
        self.photoAuthorizationStatus = photoAuthorizationStatus
        self.requestAuthorization = requestAuthorization
        self.makeAssetCreationBlock = makeAssetCreationBlock
        self.performChanges = performChanges
    }

    /// [APP-LAUNCHER F7] Resolves the add-only permission BEFORE the
    /// camera opens: an already-decided status is read, and a
    /// `.notDetermined` one is asked about NOW — the moment the elder
    /// asked for the camera, which is the same "the request IS the
    /// consent" moment the camera prompt is asked in. A refusal here stops
    /// the flow before the picker is presented, so the elder is told they
    /// need to allow photo access INSTEAD of taking a photo that would
    /// have been thrown away.
    func prepareToSave(completion: @escaping (Bool) -> Void) {
        switch photoAuthorizationStatus() {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            requestAuthorization { status in
                completion(status == .authorized || status == .limited)
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            // A status this build does not know: refusing to guess keeps
            // the outcome honest (nothing is captured that cannot be
            // stored).
            completion(false)
        }
    }

    func savePhoto(_ image: UIImage, completion: @escaping (Bool) -> Void) {
        guard let data = encodeJPEG(image) else {
            // A UIImage with no JPEG representation cannot be written at
            // all — say so rather than writing an empty asset.
            return completion(false)
        }
        // [APP-LAUNCHER F7] A READ, never a request. The permission
        // conversation already happened in `prepareToSave` (before the
        // camera), so this path can only ever confirm what was decided:
        // prompting here would be asking permission for a photo the elder
        // has already taken — the moment at which a "no" can only throw
        // the photo away. A status that is still undecided (a caller that
        // skipped the pre-flight) reports the honest failure instead of
        // writing without consent.
        let status = photoAuthorizationStatus()
        guard status == .authorized || status == .limited else {
            return completion(false)
        }
        performChanges(makeAssetCreationBlock(data)) { success, _ in
            // The error itself is deliberately not surfaced: the elder
            // gets the honest spoken verdict either way, and the reason
            // (disk full, library locked) is not something they can act on
            // from here. `success` IS the truth of the write, which is
            // what the flow reports.
            completion(success)
        }
    }
}
