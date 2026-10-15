import UIKit

/// The typed failures of the on-device evidence store (design L2, D8;
/// IF-13). A closed, small set — and every case says exactly what is true
/// on disk when it is returned:
///
///  - `.compressionFailed` — the capped JPEG could not be produced (an
///    image with no usable bitmap, or a frame that will not come under the
///    cap even at the legibility floor). The write is not attempted, so
///    nothing is persisted.
///  - `.storageUnavailable` — the entry directory or the file could not be
///    created or written. Any photo already stored for the record is left
///    exactly as it was (the write is atomic).
///  - `.removeFailed` — a file that EXISTS could not be deleted.
///
/// "The file is not there" is deliberately not an error anywhere in this
/// store: for a delete the absent file IS the goal state, and for a read it
/// is an honest `nil` — never a fabricated image.
enum EvidenceStoreError: Error, Equatable {
    case compressionFailed
    case storageUnavailable
    case removeFailed
}

/// On-device photo evidence for a recorded dose (C5; FR-MSR-013,
/// FR-MSR-014, NFR-MSR-003).
///
/// Layout — one directory per ENTRY, one file per RECORD (the
/// `VisualAidStore` pattern, for the same reason: removing a medication
/// drops its whole folder in one call, and two entries can never collide on
/// a file name):
///
///     Application Support/MedicationEvidence/<entryId>/<logId>.jpg
///
/// The model side (`MedicationAdherenceLog.evidencePhotoFileName`) carries
/// the BARE FILE NAME only — never a path, never the bytes. `store` mints
/// the name from the adherence-log id and returns it; `fileURL` resolves it
/// again when a caller genuinely needs a URL.
///
/// The cap is `maxPhotoBytes` (200 * 1024 = 204,800 bytes — the FR-D04b
/// precedent value, re-declared here as a named constant so no call site
/// carries a literal; the dementia photo machinery is not called, wired or
/// changed, FR-MSR-020). Compression is this store's own: a size ladder
/// crossed with a JPEG-quality ladder, and never an oversize write — a
/// photo that cannot be brought under the cap fails `.compressionFailed`
/// and persists nothing, rather than storing an unreadable smudge and
/// calling it evidence.
///
/// Failure discipline: soft toward the truth, never toward a claim. A
/// missing or corrupt read is `nil`, a failed write is a typed failure, a
/// delete of an absent file is success (idempotent — the goal state already
/// holds), and the entry cascade is a fail-soft `Void` so removing a
/// medication never fails in the family's face over a photo.
///
/// On-device only: nothing in this file touches the network. Files are
/// written with `.completeFileProtection` — the encrypted store's own
/// protection class — so evidence is unreadable while the device is locked.
///
/// Threading: every method is synchronous. The caller runs store calls off
/// the main thread and returns to it for model writes (C5); the camera's
/// one-capture-at-a-time discipline serialises same-record writes, and
/// different records' files are independent.
final class MedicationEvidenceStore {

    /// The ceiling on a stored evidence photo, in bytes: 200 * 1024. Named
    /// once (the FR-D04b cap the design fixes for evidence), applied by
    /// default to every instance.
    static let maxPhotoBytes = 200 * 1024

    /// Longest edge, in pixels, where a stored photo's compression starts.
    /// 1600 — the ceiling the app's other stored photos use: big enough to
    /// read a label or a pill imprint on a full-screen view, small enough
    /// that the JPEG that comes out of it is a few hundred KB at most.
    /// Input is never upscaled.
    static let maxLongestEdge: CGFloat = 1600

    /// The smallest longest edge the ladder will try, in pixels. 320 is the
    /// legibility floor: below it a photo can no longer show the box, the
    /// pill or its imprint, so a frame still over the cap at this size
    /// fails honestly instead of being stored as a smudge that claims to be
    /// evidence.
    static let minimumLongestEdge: CGFloat = 320

    /// The JPEG qualities tried at each candidate size, best first. 0.8 is
    /// the app's stored-photo quality; the ladder stops at 0.3, where
    /// ringing on printed text starts costing more legibility than the
    /// bytes it saves.
    private static let qualityLadder: [CGFloat] = [0.8, 0.65, 0.5, 0.4, 0.3]

    /// Each candidate size after the first is this fraction of the previous
    /// one — a smooth descent from the image's own size to the floor.
    private static let downscaleStep: CGFloat = 0.8

    /// The Application Support folder every instance stores under.
    private static let directoryName = "MedicationEvidence"

    private let fileManager: FileManager
    private let rootDirectory: URL

    /// This instance's cap in bytes — the named constant unless a test
    /// injects a smaller value to exercise the compression-failure branch
    /// (a real camera frame cannot reach it: the ladder always finds a fit
    /// at or above the legibility floor).
    let maxPhotoBytes: Int

    /// Resolves the root path and NOTHING else: init performs no disk IO
    /// (the constant-time boot contract `NoIOInInitTests` protects — the
    /// shared instance is built while the app is still starting). The root
    /// directory is created by the first successful write.
    init(fileManager: FileManager = .default,
         rootDirectory: URL? = nil,
         maxPhotoBytes: Int = MedicationEvidenceStore.maxPhotoBytes) {
        self.fileManager = fileManager
        self.maxPhotoBytes = maxPhotoBytes
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else if let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            self.rootDirectory = base.appendingPathComponent(
                MedicationEvidenceStore.directoryName, isDirectory: true)
        } else {
            // Directory resolution can only fail in a broken sandbox —
            // degrade to a working scratch spot rather than trap; every
            // operation below still fails soft.
            self.rootDirectory = fileManager.temporaryDirectory.appendingPathComponent(
                MedicationEvidenceStore.directoryName, isDirectory: true)
        }
    }

    // MARK: - Public API

    /// Compresses `image` under the cap and writes it for the record at
    /// `logId`, replacing any earlier photo for the SAME record in place
    /// (one photo per record: the same log id mints the same file name, and
    /// the atomic write means the old file is never half-gone).
    ///
    /// Returns the bare file name to store on the adherence log. Nothing is
    /// written on failure: a `.compressionFailed` never touches the disk,
    /// and a `.storageUnavailable` leaves an existing photo untouched.
    func store(image: UIImage, for logId: UUID, entryId: UUID) -> Result<String, EvidenceStoreError> {
        // Compression FIRST: a frame that cannot be made storable leaves no
        // directory, no partial file, nothing.
        guard let data = Self.cappedJPEGData(image, maxBytes: maxPhotoBytes) else {
            return .failure(.compressionFailed)
        }
        guard let directory = safeDirectoryURL(for: entryId) else {
            return .failure(.storageUnavailable)
        }
        let fileName = Self.fileName(for: logId)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // `.completeFileProtection`: readable only while the device is
            // unlocked — the same class as the encrypted entry store.
            try data.write(to: directory.appendingPathComponent(fileName, isDirectory: false),
                           options: [.atomic, .completeFileProtection])
        } catch {
            return .failure(.storageUnavailable)
        }
        return .success(fileName)
    }

    /// The stored photo for a record, or nil when the name is not a plain
    /// file name, the file is absent, or its bytes are not a readable
    /// image. Never a fabricated image: a surface that calls this must be
    /// able to render an honest "no photo".
    func load(fileName: String, entryId: UUID) -> UIImage? {
        guard let url = fileURL(for: fileName, entryId: entryId) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Deletes one record's photo. Absent = success (the goal state already
    /// holds — idempotent by construction), and a name that cannot resolve
    /// inside this store is by definition not a file in it. Only a file
    /// that IS there and will not go returns `.removeFailed`.
    func delete(fileName: String, entryId: UUID) -> Result<Void, EvidenceStoreError> {
        guard let url = fileURL(for: fileName, entryId: entryId) else { return .success(()) }
        do {
            try fileManager.removeItem(at: url)
            return .success(())
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Lost the race with another removal (or never existed): the
            // goal state holds either way.
            return .success(())
        } catch {
            return .failure(.removeFailed)
        }
    }

    /// Drops an entry's whole evidence directory — the entry-delete cascade
    /// (`removeMedication`, beside the visual-aid cascade). Void and
    /// fail-soft, like `VisualAidStore.deleteAll`: removing a medication
    /// must never fail in the family's face over a photo, and a directory
    /// with no evidence in it (a dose the elder never photographed, or an
    /// entry already cascaded) is a no-op.
    func deleteAll(for entryId: UUID) {
        guard let directory = safeDirectoryURL(for: entryId) else { return }
        try? fileManager.removeItem(at: directory)
    }

    /// Resolves a stored file name to its URL, or nil when either component
    /// is not a plain path element — a corrupt stored payload must never
    /// smuggle a path out of the store root, in either direction. Pure path
    /// resolution, no disk IO: the name is what `store` returned, and an
    /// existence check is the caller's business if it needs one.
    func fileURL(for fileName: String, entryId: UUID) -> URL? {
        guard let directory = safeDirectoryURL(for: entryId),
              Self.isPlainFileName(fileName) else { return nil }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - Compression

    /// The capped JPEG for `image`, or nil when one cannot be produced.
    ///
    /// Two ladders, crossed: candidate sizes start at the image's own
    /// longest edge (never upscaled, never above `maxLongestEdge`) and
    /// descend to `minimumLongestEdge`; at each size the quality ladder is
    /// tried best-first. The first candidate under `maxBytes` wins, so the
    /// store prefers resolution over polish — a slightly blocky large photo
    /// shows a pill imprint better than a pristine small one. Rendering
    /// happens once per size; orientation is baked into the pixels, so a
    /// JPEG reader never has to honour an EXIF flag.
    ///
    /// nil means exactly "this image cannot be stored within the rules": no
    /// usable bitmap, or nothing under the cap at the legibility floor.
    private static func cappedJPEGData(
        _ image: UIImage,
        maxBytes: Int,
        maxLongestEdge: CGFloat = MedicationEvidenceStore.maxLongestEdge,
        minimumLongestEdge: CGFloat = MedicationEvidenceStore.minimumLongestEdge
    ) -> Data? {
        guard maxBytes > 0 else { return nil }
        let pixelSize = CGSize(width: image.size.width * image.scale,
                               height: image.size.height * image.scale)
        guard pixelSize.width > 0, pixelSize.height > 0,
              image.cgImage != nil || image.ciImage != nil else { return nil }

        var longestEdge = min(max(pixelSize.width, pixelSize.height), maxLongestEdge)
        // The floor is at least one pixel, so the descent below provably
        // terminates whatever a caller passes.
        let floor = min(max(minimumLongestEdge, 1), longestEdge)
        while true {
            if let candidate = scaled(image, longestEdge: longestEdge) {
                for quality in qualityLadder {
                    if let data = candidate.jpegData(compressionQuality: quality),
                       data.count <= maxBytes {
                        return data
                    }
                }
            }
            if longestEdge <= floor { return nil }
            longestEdge = max(longestEdge * downscaleStep, floor)
        }
    }

    /// The image fitted into `longestEdge` on its longer side — never
    /// upscaled, re-rendered at scale 1 (one output pixel per source pixel)
    /// with the orientation baked in and any alpha composited away (JPEG
    /// carries none). nil only for an image with no usable bitmap.
    private static func scaled(_ image: UIImage, longestEdge: CGFloat) -> UIImage? {
        let size = CGSize(width: image.size.width * image.scale,
                          height: image.size.height * image.scale)
        guard size.width > 0, size.height > 0,
              image.cgImage != nil || image.ciImage != nil else { return nil }
        let longest = max(size.width, size.height)
        let factor = longest > longestEdge ? longestEdge / longest : 1
        let target = CGSize(width: max(1, size.width * factor),
                            height: max(1, size.height * factor))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: - Paths

    private static func fileName(for logId: UUID) -> String {
        logId.uuidString + ".jpg"
    }

    private func directoryURL(for entryId: UUID) -> URL {
        rootDirectory.appendingPathComponent(entryId.uuidString, isDirectory: true)
    }

    /// The entry directory, or nil when the name is not a plain path
    /// component. The name comes from `UUID.uuidString`, so this can only
    /// fail for a value constructed outside the type's rules — but the
    /// guard is what keeps a malformed id from resolving to the store root
    /// and taking every other entry's photos with it on `deleteAll`.
    private func safeDirectoryURL(for entryId: UUID) -> URL? {
        guard Self.isPlainFileName(entryId.uuidString) else { return nil }
        return directoryURL(for: entryId)
    }

    /// True only for a plain, traversal-free component: no empties, no dot
    /// entries, no separators.
    private static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
    }
}
