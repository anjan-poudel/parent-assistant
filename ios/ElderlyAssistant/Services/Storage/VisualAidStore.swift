import UIKit

/// On-disk photos for reminder "visual aids" (photo-visual-aids task,
/// 2026-09-16): the picture of the medicine box that fires with the
/// medication reminder, the route that fires with the walk.
///
/// Layout: `Application Support/VisualAids/<entryId>/<filename>.jpg`.
/// One directory per ENTRY (not per aid) so deleting a reminder can drop
/// its whole folder in one call and two entries can never collide on a
/// file name. The model side (`RoutineEntry.visualAids`) stores bare file
/// names only — never a path, never the bytes — exactly the split
/// `ContactPhotoStore` / `FamilyContact.photoFilename` uses.
///
/// Deliberately NOT Photos and NOT the Keychain:
///
///  - **Not Photos** — a reminder's photo is app data, not the user's
///    library. It must be deleted with the reminder, must not appear in
///    the photo picker or be shared to other apps, and must not require
///    photo-library write access. `PHPickerViewController` (the capture
///    path) needs NO permission at all because it runs out of process.
///  - **Not the encrypted channel** — a JPEG that can only be read
///    through a Keychain round trip is little use to a screen that has to
///    paint it immediately, and `EncryptedLocalStorage` is built for
///    small payloads. `.completeFileProtection` on the file keeps the
///    image behind the device lock, the same protection class as the
///    encrypted store (`constitution.md` §Security).
///
/// Every method is non-throwing and fails soft, like `ContactPhotoStore`:
/// a failed write returns nil, a missing/corrupt read returns nil, a
/// failed delete is a no-op. A visual aid is a nicety — never worth a
/// crash or an error dialog in front of an elderly user; the reminder
/// itself always renders, image or not.
///
/// `init(rootDirectory:)` mirrors `ContactPhotoStore`/`ModelStore` so
/// tests run against a throwaway directory.
final class VisualAidStore {

    /// Longest edge, in PIXELS, of a stored aid. 1600 is the ceiling the
    /// task fixed: big enough to read a label or recognize a package on a
    /// full-screen elder-facing view, small enough that three of them cost
    /// a few hundred KB. Input is never upscaled — a smaller image keeps
    /// its size.
    static let maxDimension: CGFloat = 1600
    /// JPEG quality for stored aids. 0.8 — the point where a photo of a
    /// package still shows crisp printed text.
    static let jpegQuality: CGFloat = 0.8
    /// How many aids one entry may carry (the picker's multi-select cap:
    /// three is "which of these boxes", not an album).
    static let maxPerEntry = 3

    private let fileManager: FileManager
    private let rootDirectory: URL

    /// Resolves the root path and NOTHING else: init performs no disk IO
    /// (the constant-time boot contract `NoIOInInitTests` guards — the
    /// shared instance is built by `AppCoordinator.init`, and the sibling
    /// `ContactPhotoStore` is `lazy` for the same reason). The root
    /// directory is created by the first WRITE: `save` writes with
    /// `withIntermediateDirectories`, which creates the root on the way.
    /// Resolving with `create: false` is a pure path lookup — no
    /// directory is made, and the directory need not exist yet.
    init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else if let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            self.rootDirectory = base.appendingPathComponent("VisualAids",
                                                             isDirectory: true)
        } else {
            // Directory resolution can only fail in a broken sandbox —
            // degrade to a working scratch spot rather than trap at init;
            // every operation below still fails soft.
            self.rootDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("VisualAids", isDirectory: true)
        }
    }

    // MARK: - Public API

    /// Downscales `image` (≤1600px longest edge, JPEG 0.8) and writes it
    /// under the entry's directory. Returns the `VisualAid` to append to
    /// the entry, or nil when the image had no usable bitmap or the write
    /// failed — the caller simply ends up with one fewer photo.
    @discardableResult
    func save(_ image: UIImage, for entryId: UUID, caption: String? = nil) -> VisualAid? {
        guard let data = Self.jpegData(image) else { return nil }
        let aid = VisualAid(filename: UUID().uuidString + ".jpg", caption: caption)
        let directory = directoryURL(for: entryId)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // `.completeFileProtection`: only readable while the device is
            // unlocked (constitution §Security — same class as the
            // encrypted entry store).
            try data.write(to: directory.appendingPathComponent(aid.filename, isDirectory: false),
                           options: [.atomic, .completeFileProtection])
            return aid
        } catch {
            return nil
        }
    }

    /// The stored image for an aid, or nil when the id/file name is
    /// unsafe, the file is absent, or it is unreadable.
    func load(_ aid: VisualAid, for entryId: UUID) -> UIImage? {
        guard let url = fileURL(for: aid, entryId: entryId) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// The on-disk URL for an aid that ACTUALLY EXISTS, or nil. Exists for
    /// the one caller that needs a URL rather than an image: a
    /// `UNNotificationAttachment` is built from a file URL and throws on a
    /// missing file, so the caller must be able to ask first instead of
    /// discovering it at fire time.
    func existingFileURL(_ aid: VisualAid, for entryId: UUID) -> URL? {
        guard let url = fileURL(for: aid, entryId: entryId),
              fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Deletes one stored aid. The entry's `visualAids` array is the
    /// caller's to update. Never throws, never crashes.
    func delete(_ aid: VisualAid, for entryId: UUID) {
        guard let url = fileURL(for: aid, entryId: entryId) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Drops an entry's whole aid directory — called when the reminder
    /// itself is removed, so deleting a medication reminder never leaves
    /// its box photo behind on disk.
    func deleteAll(for entryId: UUID) {
        guard let directory = safeDirectoryURL(for: entryId) else { return }
        try? fileManager.removeItem(at: directory)
    }

    // MARK: - Helpers

    /// The compression used for every stored aid: uniform downscale to
    /// `maxDimension` on the longest edge (never a crop — a cropped
    /// medicine box is a different, misleading picture), orientation baked
    /// into the pixels by `UIGraphicsImageRenderer` (JPEG readers must not
    /// be trusted to honor an EXIF flag), then JPEG at `jpegQuality`.
    /// Returns nil only for an image with no usable bitmap.
    static func jpegData(_ image: UIImage,
                         maxDimension: CGFloat = VisualAidStore.maxDimension,
                         jpegQuality: CGFloat = VisualAidStore.jpegQuality) -> Data? {
        guard image.size.width > 0, image.size.height > 0,
              image.cgImage != nil || image.ciImage != nil else { return nil }
        return scaledForStorage(image, maxDimension: maxDimension)?
            .jpegData(compressionQuality: jpegQuality)
    }

    /// Fits the image into `maxDimension` on its longest edge, never
    /// upscaling a smaller image, re-rendered at scale 1 (one output pixel
    /// per source pixel — the deterministic sizes tests assert on) with
    /// the orientation baked in. `nil` when the image has no usable
    /// bitmap (a zero-size or CGImage-less UIImage).
    static func scaledForStorage(_ image: UIImage,
                                 maxDimension: CGFloat = VisualAidStore.maxDimension) -> UIImage? {
        let size = CGSize(width: image.size.width * image.scale,
                          height: image.size.height * image.scale)
        guard size.width > 0, size.height > 0,
              image.cgImage != nil || image.ciImage != nil else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1            // `size` is already in output pixels
        format.opaque = true        // JPEG carries no alpha
        let maxEdge = max(size.width, size.height)
        guard maxEdge > maxDimension else {
            // Render at the pixel size even when no downscale is needed —
            // the orientation bake and uniform pixel format are the point.
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        let scale = maxDimension / maxEdge
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func directoryURL(for entryId: UUID) -> URL {
        rootDirectory.appendingPathComponent(entryId.uuidString, isDirectory: true)
    }

    /// The entry directory, or nil when the id is empty (never from
    /// `UUID`, but a defensive guard keeps a malformed value from
    /// resolving to the store root and taking every other entry's photos
    /// with it on `deleteAll`).
    private func safeDirectoryURL(for entryId: UUID) -> URL? {
        let name = entryId.uuidString
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\") else { return nil }
        return directoryURL(for: entryId)
    }

    /// Nil unless BOTH the entry id and the file name are plain,
    /// traversal-free components — a hand-edited/corrupt payload must
    /// never smuggle a path out of the store root.
    private func fileURL(for aid: VisualAid, entryId: UUID) -> URL? {
        guard let directory = safeDirectoryURL(for: entryId),
              Self.isPlainFilename(aid.filename) else { return nil }
        return directory.appendingPathComponent(aid.filename, isDirectory: false)
    }

    private static func isPlainFilename(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
    }
}
