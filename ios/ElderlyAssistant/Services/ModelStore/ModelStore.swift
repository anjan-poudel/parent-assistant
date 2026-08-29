import Foundation
import CryptoKit

enum ModelStoreError: Error {
    case unknownModel
    case notCached
    case checksumMismatch
    case dependencyMissing(ModelID)
    case cacheDirectoryFailed(Error)
}

enum ModelChecksumPolicy {
    case strict
    case skip
}

/// Owns the on-disk cache of downloaded model files. Backed by the app's
/// Application Support directory with `FileProtectionType.complete` — files
/// are only readable while the device is unlocked, matching the
/// constitution's Data Protection Class Complete requirement.
///
/// The store does NOT run downloads itself; it exposes paths and integrity
/// checks. `ModelDownloadService` writes into `stagingURL(for:)`, then calls
/// `finalize(_:)` on success.
final class ModelStore {

    private let fileManager: FileManager
    private let observabilityBus: ObservabilityBus
    private let rootDirectory: URL
    private let checksumPolicy: ModelChecksumPolicy

    init(fileManager: FileManager = .default,
         observabilityBus: ObservabilityBus,
         rootDirectoryOverride: URL? = nil,
         checksumPolicy: ModelChecksumPolicy = .strict) throws {
        self.fileManager = fileManager
        self.observabilityBus = observabilityBus
        self.checksumPolicy = checksumPolicy

        if let override = rootDirectoryOverride {
            self.rootDirectory = override
        } else {
            let base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.rootDirectory = base.appendingPathComponent("Models", isDirectory: true)
        }
        try ensureDirectory(rootDirectory)
    }

    // MARK: - Public API

    /// URL where a fully-installed model file lives on disk. Nil if the file
    /// has never been downloaded, or was deleted since.
    func path(for id: ModelID) -> URL? {
        guard let entry = ModelCatalog.entry(for: id) else { return nil }
        let url = finalURL(for: entry)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Where a partial download should be written before finalization.
    /// Kept out of the "final" area so half-downloaded files can't be
    /// mistaken for ready ones.
    func stagingURL(for id: ModelID) throws -> URL {
        guard let entry = ModelCatalog.entry(for: id) else {
            throw ModelStoreError.unknownModel
        }
        let staging = rootDirectory.appendingPathComponent("staging", isDirectory: true)
        try ensureDirectory(staging)
        return staging.appendingPathComponent(entry.filename)
    }

    func isCached(_ id: ModelID) -> Bool {
        path(for: id) != nil
    }

    /// A model is "available" when it is cached AND all its declared
    /// dependencies are cached.
    func isAvailable(_ id: ModelID) -> Bool {
        guard let entry = ModelCatalog.entry(for: id) else { return false }
        guard isCached(entry.id) else { return false }
        if let dep = entry.dependsOn, !isCached(dep) { return false }
        return true
    }

    /// LoRAs currently installed that target the given base model.
    func activeLoRAs(for baseId: ModelID) -> [ModelCatalogEntry] {
        ModelCatalog.all.filter { $0.dependsOn == baseId && isCached($0.id) }
    }

    /// Move a completed download from staging into the final location and
    /// verify its checksum. Deletes the staging file either way. Also marks
    /// the final file as "exclude from iCloud backup" so a device restore
    /// doesn't drag a couple of GB of model weights through the user's
    /// iCloud quota (the app re-downloads on demand).
    @discardableResult
    func finalize(_ id: ModelID) throws -> URL {
        guard let entry = ModelCatalog.entry(for: id) else {
            throw ModelStoreError.unknownModel
        }
        let staged = try stagingURL(for: id)
        let final = finalURL(for: entry)

        defer {
            try? fileManager.removeItem(at: staged)
        }

        guard fileManager.fileExists(atPath: staged.path) else {
            throw ModelStoreError.notCached
        }
        try ensureDirectory(final.deletingLastPathComponent())

        // Verify checksum before promoting into the final area. App builds
        // use strict verification; tests may explicitly opt out with
        // `.skip` so they can stage tiny fake files.
        let matched = try verifyChecksum(at: staged, expected: entry.sha256)
        if !matched {
            emit("finalize_checksum_mismatch", outcome: "failure",
                 modelId: id, errorCode: "checksum")
            throw ModelStoreError.checksumMismatch
        }

        if fileManager.fileExists(atPath: final.path) {
            try fileManager.removeItem(at: final)
        }
        try fileManager.moveItem(at: staged, to: final)

        // Data Protection Complete + exclude-from-backup.
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: final.path
        )
        var mutable = final
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        try? mutable.setResourceValues(resource)

        emit("finalize_success", outcome: "success", modelId: id, errorCode: nil)
        return final
    }

    /// Deletes a cached model file. Idempotent.
    func delete(_ id: ModelID) throws {
        guard let entry = ModelCatalog.entry(for: id) else {
            throw ModelStoreError.unknownModel
        }
        let final = finalURL(for: entry)
        if fileManager.fileExists(atPath: final.path) {
            try fileManager.removeItem(at: final)
            emit("delete", outcome: "success", modelId: id, errorCode: nil)
        }
    }

    /// Bytes of disk currently used by cached models.
    func cachedBytes() -> Int64 {
        var total: Int64 = 0
        for entry in ModelCatalog.all {
            let url = finalURL(for: entry)
            if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    // MARK: - Internals

    private func finalURL(for entry: ModelCatalogEntry) -> URL {
        rootDirectory
            .appendingPathComponent(entry.kind.rawValue, isDirectory: true)
            .appendingPathComponent(entry.filename)
    }

    private func ensureDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        } catch {
            throw ModelStoreError.cacheDirectoryFailed(error)
        }
    }

    private func verifyChecksum(at url: URL, expected: String) throws -> Bool {
        if checksumPolicy == .skip { return true }

        // Streaming SHA-256 so we don't load 2 GB models into RAM.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1_048_576)  // 1 MB
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex.lowercased() == expected.lowercased()
    }

    private func emit(_ eventType: String, outcome: String,
                      modelId: ModelID, errorCode: String?) {
        observabilityBus.emit(ObservabilityEvent(
            component: "model_store",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: errorCode,
            metadata: ["state": modelId.rawValue]
        ))
    }
}
