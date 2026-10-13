import UIKit

/// On-disk thumbnails for curated-contact photos (family-and-friends
/// task, 2026-09-07). Every image is downscaled to a ≤512px-longest-edge
/// JPEG (quality 0.8) under Application Support/ContactPhotos/ and the
/// contact record only ever stores the file name
/// (`FamilyContact.photoFilename`) — never a path. Downscaling happens at
/// write time through `UIGraphicsImageRenderer`, which also bakes the
/// UIImage's orientation into the pixels (JPEG readers must not be
/// trusted to honor an orientation flag) and strips source metadata.
///
/// Photos are best-effort VISUALS, never a crash source and never worth
/// a failure surfaced to an elderly user: every method is non-throwing —
/// a write that fails returns nil, a missing/corrupt file reads back as
/// nil, a delete that fails is a no-op — and the UI falls back to the
/// initials avatar whenever a photo is absent. The store is deliberately
/// NOT the encrypted Keychain channel: a family photo that is unreadable
/// without the thumb is useless, and `.completeFileProtection` on the
/// JPEG keeps it behind the device lock like the rest of the app's data.
///
/// `init(rootDirectory:)` mirrors `ModelStore`'s override seam so tests
/// run against a throwaway directory; production callers use the default.
final class ContactPhotoStore {

    /// Longest edge (points) of a stored thumbnail. Input is never
    /// upscaled — a smaller image keeps its size.
    static let maxDimension: CGFloat = 512
    static let jpegQuality: CGFloat = 0.8

    /// The directory name this store's photos live under (rich-events
    /// task, 2026-09-17). A parameter rather than a constant because the
    /// class is the house's whole thumbnail implementation — downscale,
    /// orientation bake, `.completeFileProtection`, the plain-filename
    /// guard — and the free-form Events feature needs all of it with one
    /// difference: its photos belong in a directory of their own, so an
    /// event photo can never be read or deleted as a contact's. The
    /// default keeps every existing caller byte-identical.
    static let defaultDirectoryName = "ContactPhotos"

    private let fileManager: FileManager
    private let rootDirectory: URL

    init(fileManager: FileManager = .default,
         rootDirectory: URL? = nil,
         directoryName: String = ContactPhotoStore.defaultDirectoryName) {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else if let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            self.rootDirectory = base.appendingPathComponent(directoryName,
                                                             isDirectory: true)
        } else {
            // Directory resolution can only fail in a broken sandbox —
            // degrade to a working scratch spot rather than trap at init;
            // every operation below still fails soft.
            self.rootDirectory = fileManager.temporaryDirectory
                .appendingPathComponent(directoryName, isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.rootDirectory,
                                         withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Downscales `image` (≤512px longest edge, JPEG 0.8) and writes it
    /// as `<uuid>.jpg` under the store directory. Returns the file name
    /// to store on the contact, or nil when the write failed — the
    /// caller simply keeps the contact photo-less. The bytes written are
    /// exactly `processedJPEG(image)` — there is no second encoding
    /// path to drift from.
    @discardableResult
    func save(_ image: UIImage) -> String? {
        guard let data = Self.processedJPEG(image) else { return nil }
        let filename = UUID().uuidString + ".jpg"
        do {
            // `.completeFileProtection`: only readable while the device
            // is unlocked (constitution §Security — same class as the
            // encrypted contact store).
            try data.write(to: fileURL(for: filename), options: [.atomic, .completeFileProtection])
            return filename
        } catch {
            return nil
        }
    }

    /// The stored thumbnail for a file name, or nil when the name is
    /// missing/unsafe or the file is absent or unreadable.
    func load(named filename: String?) -> UIImage? {
        guard let filename, Self.isPlainFilename(filename) else { return nil }
        return UIImage(contentsOfFile: fileURL(for: filename).path)
    }

    /// The exact bytes of a stored thumbnail — the processed JPEG on
    /// disk, byte-identical to what was written at store time — or nil
    /// when the name is missing/unsafe or the file is absent or
    /// unreadable. This is the read-back and copy byte source (design
    /// §1.9): handing the bytes to another API avoids a decode +
    /// re-encode round trip, so the bytes the app holds are the bytes
    /// that leave it. Never throws and never logs the name — a file name
    /// is personal data (NFR-FCU-002 PII discipline).
    func loadData(named filename: String?) -> Data? {
        guard let filename, Self.isPlainFilename(filename) else { return nil }
        return try? Data(contentsOf: fileURL(for: filename))
    }

    /// Copies an existing stored thumbnail to a NEW `<uuid>.jpg` file
    /// name and returns that name, or nil when the source is
    /// missing/unsafe or the copy could not be written — never throws.
    /// The bytes are copied verbatim, so the new file is byte-identical
    /// to the original and no decode/re-encode can drift it; the copy is
    /// stored with the same `.completeFileProtection` as `save`. The
    /// unlink path (design §1.9 `.unlinkKeepingDisplayedPhotoLocally`)
    /// consumes this to keep the displayed photo app-local BEFORE the
    /// link is cleared; nil there means "do not clear" (never lose).
    @discardableResult
    func copy(named filename: String?) -> String? {
        guard let filename, Self.isPlainFilename(filename),
              let data = loadData(named: filename) else { return nil }
        let newName = UUID().uuidString + ".jpg"
        do {
            try data.write(to: fileURL(for: newName),
                           options: [.atomic, .completeFileProtection])
            return newName
        } catch {
            return nil
        }
    }

    /// Deletes a stored thumbnail (the contact's field is cleared by the
    /// caller). Never throws and never crashes — best-effort cleanup.
    func delete(named filename: String?) {
        guard let filename, Self.isPlainFilename(filename) else { return }
        try? fileManager.removeItem(at: fileURL(for: filename))
    }

    // MARK: - Helpers

    /// The single canonical preprocessing seam: downscale through
    /// `scaledForStorage` (≤512px longest edge, orientation baked,
    /// metadata stripped) then JPEG-encode at `jpegQuality`. Every
    /// caller that stores bytes — `save` here, the system-photo write
    /// seam and the wizard save flow — consumes THIS function, so no
    /// second encoding path can drift the bytes. Deterministic: the same
    /// input yields byte-identical output across calls. Non-throwing and
    /// nil when the input has no decodable pixel backing (e.g. an empty
    /// `UIImage`), so callers fall back to the non-writable path
    /// (FR-FCU-010) instead of surfacing a failure to the user.
    static func processedJPEG(_ image: UIImage) -> Data? {
        // Same usable-bitmap guard as `VisualAidStore.jpegData` (house
        // pattern): a zero-size or bitmap-less UIImage is a capture
        // failure, never a blank photo.
        guard image.size.width > 0, image.size.height > 0,
              image.cgImage != nil || image.ciImage != nil else { return nil }
        return Self.scaledForStorage(image)
            .jpegData(compressionQuality: Self.jpegQuality)
    }

    /// Fits the image into `maxDimension` on its longest edge, never
    /// upscaling a smaller image, re-rendered through
    /// `UIGraphicsImageRenderer` at scale 1 (one output pixel per
    /// source pixel — the deterministic size tests assert on) with the
    /// orientation baked in.
    static func scaledForStorage(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let size = CGSize(width: image.size.width * image.scale,
                          height: image.size.height * image.scale)
        let maxEdge = max(size.width, size.height)
        guard maxEdge > Self.maxDimension else {
            // Render at the pixel size even when no downscale is needed —
            // the orientation bake and uniform pixel format are the point.
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        let scale = Self.maxDimension / maxEdge
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func fileURL(for filename: String) -> URL {
        rootDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    /// Only bare file names may reach the disk — a stored value is
    /// always a `<uuid>.jpg` from `save`, but a hand-edited/corrupt
    /// payload must never smuggle path components out of the store
    /// directory.
    private static func isPlainFilename(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
    }
}
