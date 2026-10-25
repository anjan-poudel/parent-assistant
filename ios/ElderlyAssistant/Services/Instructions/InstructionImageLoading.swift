import UIKit

/// C01/C08 — image decoding's failures (design L2 §3.3, §3.5, IF-21).
///
/// The three cases are the whole contract: the surface maps every case to
/// the one plain `instruction.image.unavailable` line. No `NSError`, error
/// domain, code or description escapes the loaders.
enum InstructionImageFailure: Error, Equatable {
    /// The bare-name guard refused the filename before any URL existed.
    case rejectedFilename
    /// The file does not resolve to anything on disk.
    case missingFile
    /// The file is present but its bytes do not decode as an image.
    case unreadableFile
}

/// The image-loading seam the instruction card and editor use (IF-21;
/// design L2 §3.5, §5.8).
///
/// An instruction image is a plain file in the app's own image store —
/// never an asset in the person's photo library. Both loaders read through
/// the shipping store API only, apply the bare-name guard before any store
/// call, and never log: the card emits one outcome event that carries no
/// path and no content.
@MainActor
protocol InstructionImageLoading {
    func loadImage(filename: String) -> Result<UIImage, InstructionImageFailure>
}

/// Routine instructions: the image lives in the entry's `VisualAidStore`
/// directory — the photo store this app already has (design D3, §5.8).
/// The store's own filename validation is reused, never duplicated.
@MainActor
struct VisualAidInstructionImageLoader: InstructionImageLoading {

    private let store: VisualAidStore
    private let entryId: UUID

    init(store: VisualAidStore, entryId: UUID) {
        self.store = store
        self.entryId = entryId
    }

    /// The bare-name guard runs before the store is touched, so a refused
    /// name costs nothing: no URL is built and no file is read. An absent
    /// file is `.missingFile` (the store's existence probe), a present
    /// but undecodable file is `.unreadableFile` (the store's read).
    func loadImage(filename: String) -> Result<UIImage, InstructionImageFailure> {
        guard InstructionFilename.isPlain(filename) else {
            return .failure(.rejectedFilename)
        }
        let aid = VisualAid(filename: filename)
        guard store.existingFileURL(aid, for: entryId) != nil else {
            return .failure(.missingFile)
        }
        guard let image = store.load(aid, for: entryId) else {
            return .failure(.unreadableFile)
        }
        return .success(image)
    }
}

/// Event instructions: the image lives in the same flat event-photo store
/// as the event's own photo (design §5.8).
@MainActor
struct EventPhotoInstructionImageLoader: InstructionImageLoading {

    private let store: ContactPhotoStore

    init(store: ContactPhotoStore) {
        self.store = store
    }

    /// The bytes are read through the store's `loadData` read-back API and
    /// decoded here, so an absent file and an undecodable file stay
    /// distinguishable: the store's image read collapses both into nil and
    /// the image stores' API is deliberately not widened (design §5.8,
    /// N-1). A file the system cannot read at all classifies as
    /// `.missingFile`, like an absent one — the surface renders the same
    /// plain fallback line for either.
    func loadImage(filename: String) -> Result<UIImage, InstructionImageFailure> {
        guard InstructionFilename.isPlain(filename) else {
            return .failure(.rejectedFilename)
        }
        guard let data = store.loadData(named: filename) else {
            return .failure(.missingFile)
        }
        guard let image = UIImage(data: data) else {
            return .failure(.unreadableFile)
        }
        return .success(image)
    }
}
