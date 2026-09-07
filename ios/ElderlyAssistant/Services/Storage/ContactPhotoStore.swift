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

    private let fileManager: FileManager
    private let rootDirectory: URL

    init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else if let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            self.rootDirectory = base.appendingPathComponent("ContactPhotos",
                                                             isDirectory: true)
        } else {
            // Directory resolution can only fail in a broken sandbox —
            // degrade to a working scratch spot rather than trap at init;
            // every operation below still fails soft.
            self.rootDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("ContactPhotos", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.rootDirectory,
                                         withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Downscales `image` (≤512px longest edge, JPEG 0.8) and writes it
    /// as `<uuid>.jpg` under the store directory. Returns the file name
    /// to store on the contact, or nil when the write failed — the
    /// caller simply keeps the contact photo-less.
    @discardableResult
    func save(_ image: UIImage) -> String? {
        let thumbnail = Self.scaledForStorage(image)
        guard let data = thumbnail.jpegData(compressionQuality: Self.jpegQuality) else {
            return nil
        }
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

    /// Deletes a stored thumbnail (the contact's field is cleared by the
    /// caller). Never throws and never crashes — best-effort cleanup.
    func delete(named filename: String?) {
        guard let filename, Self.isPlainFilename(filename) else { return }
        try? fileManager.removeItem(at: fileURL(for: filename))
    }

    // MARK: - Helpers

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
