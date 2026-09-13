import Foundation
import CryptoKit
import ZIPFoundation

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
        if let entry = ModelCatalog.entry(for: id), entry.kind == .tts {
            return ttsVoiceDirectory(for: id) != nil
        }
        if let entry = ModelCatalog.entry(for: id), entry.kind == .kws {
            return kwsModelDirectory(for: id) != nil
        }
        // [T-037-a] CoreML-only encoder: a DIRECTORY artifact with no ggml
        // sibling, so the single-file `path(for:)` check below is not the
        // right shape (it would also report a half-written staging file).
        if let entry = ModelCatalog.entry(for: id), entry.kind == .intentEncoder {
            return isCoreMLCached(id)
        }
        return path(for: id) != nil
    }

    /// Install check covering BOTH artifact shapes: WhisperKit models are
    /// DIRECTORY artifacts (`directoryURL(for:)` — `isCached` only knows
    /// single files, so it would report an installed WhisperKit model as
    /// missing), every other kind is a single file. The Settings model
    /// screen uses this so its picker/downloads rows tell the truth about
    /// ANE models too.
    func isInstalled(_ entry: ModelCatalogEntry) -> Bool {
        entry.whisperKitZipURL != nil
            ? directoryURL(for: entry.id) != nil
            : isCached(entry.id)
    }

    // MARK: - TTS voices (sherpa-layout directories)

    /// URL of an installed TTS voice directory (contains model.onnx,
    /// tokens.txt, espeak-ng-data/). Nil when never installed.
    func ttsVoiceDirectory(for id: ModelID) -> URL? {
        guard let entry = ModelCatalog.entry(for: id),
              entry.kind == .tts else { return nil }
        let dir = rootDirectory
            .appendingPathComponent("tts", isDirectory: true)
            .appendingPathComponent(entry.filename, isDirectory: true)
        return fileManager.fileExists(atPath: dir.path) ? dir : nil
    }

    /// Installs a bundled TTS voice directory (Resources/Models/tts/<name>)
    /// into the ModelStore. Idempotent — returns the existing directory
    /// when already installed, nil when the catalog/bundle has no such
    /// voice (the caller then falls back to system TTS).
    func installBundledTTSVoice(for id: ModelID, bundle: Bundle = .main) -> URL? {
        guard let entry = ModelCatalog.entry(for: id),
              entry.kind == .tts,
              let resourceName = entry.bundledResourceName,
              let source = bundle.url(forResource: resourceName,
                                      withExtension: nil,
                                      subdirectory: "tts") else {
            return nil
        }
        let parent = rootDirectory.appendingPathComponent("tts", isDirectory: true)
        let dest = parent.appendingPathComponent(entry.filename, isDirectory: true)
        if fileManager.fileExists(atPath: dest.path) {
            return dest
        }
        do {
            try ensureDirectory(parent)
            try fileManager.copyItem(at: source, to: dest)
            emit("bundled_tts_voice_installed", outcome: "success", modelId: id,
                 errorCode: nil)
            return dest
        } catch {
            emit("bundled_tts_voice_install_failed", outcome: "failure",
                 modelId: id, errorCode: "copy")
            return nil
        }
    }

    // MARK: - KWS models (sherpa-layout directories)

    /// URL of an installed wake-word (sherpa-onnx KWS) model directory
    /// (encoder/decoder/joiner .onnx + tokens.txt + keywords.txt). Nil
    /// when never installed. Mirrors the TTS-voice directory handling —
    /// KWS models are directory artifacts, not single files.
    func kwsModelDirectory(for id: ModelID) -> URL? {
        guard let entry = ModelCatalog.entry(for: id),
              entry.kind == .kws else { return nil }
        let dir = rootDirectory
            .appendingPathComponent("kws", isDirectory: true)
            .appendingPathComponent(entry.filename, isDirectory: true)
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: dir.path, isDirectory: &isDir)
            && isDir.boolValue ? dir : nil
    }

    /// Installs a bundled wake-word model directory
    /// (Resources/Models/kws/<name> — bundle subdirectory "kws") into the
    /// ModelStore. Idempotent — returns the existing directory when
    /// already installed, nil when the catalog/bundle has no such model
    /// (the wake-word selection then falls back exactly as before).
    @discardableResult
    func installBundledKWSModel(for id: ModelID, bundle: Bundle = .main) -> URL? {
        guard let entry = ModelCatalog.entry(for: id),
              entry.kind == .kws,
              let resourceName = entry.bundledResourceName,
              let source = bundle.url(forResource: resourceName,
                                      withExtension: nil,
                                      subdirectory: "kws") else {
            return nil
        }
        let parent = rootDirectory.appendingPathComponent("kws", isDirectory: true)
        let dest = parent.appendingPathComponent(entry.filename, isDirectory: true)
        if fileManager.fileExists(atPath: dest.path) {
            return dest
        }
        do {
            try ensureDirectory(parent)
            try fileManager.copyItem(at: source, to: dest)
            emit("bundled_kws_model_installed", outcome: "success", modelId: id,
                 errorCode: nil)
            return dest
        } catch {
            emit("bundled_kws_model_install_failed", outcome: "failure",
                 modelId: id, errorCode: "copy")
            return nil
        }
    }

    // MARK: - CoreML encoder companion

    /// URL of the extracted `-encoder.mlmodelc` directory that whisper.cpp
    /// autodetects to run the encoder on the Neural Engine. Nil when the
    /// catalog entry has no CoreML companion. May not exist on disk yet
    /// — combine with `isCoreMLCached(_:)`.
    ///
    /// Whisper.cpp derives this path by stripping `.bin` from the ggml
    /// filename AND stripping a trailing `-qX_X` quantization suffix
    /// (`whisper-large-v3-nepali-q5_1.bin` → `whisper-large-v3-nepali-
    /// encoder.mlmodelc`), so we match that derivation exactly — a
    /// q5_1-preserving name here is silently ignored by the runtime.
    func coreMLBundleFinalURL(for id: ModelID) -> URL? {
        guard let entry = ModelCatalog.entry(for: id) else { return nil }
        // [T-037-a] A CoreML-only encoder (kind .intentEncoder) has no ggml
        // sibling to derive a Whisper-style `<stem>-encoder.mlmodelc` name
        // from — the entry's own filename IS the installed directory name.
        if entry.kind == .intentEncoder {
            return finalURL(for: entry)
        }
        guard entry.coreMLEncoderBundledName != nil
                || entry.coreMLEncoderDownloadURL != nil else {
            return nil
        }
        return derivedCoreMLBundleURL(for: entry)
    }

    /// Unpacks a downloaded encoder zip (M2 delivery) into the
    /// whisper.cpp-derived `<stem>-encoder.mlmodelc` location next to the
    /// model — or, for a CoreML-only entry (`kind == .intentEncoder`), into
    /// the entry's own final directory.
    ///
    /// [T-037-a] Checksum policy: a CoreML-only entry's catalog sha256 is
    /// the ZIP's own hash, so it is verified here BEFORE anything is
    /// unpacked — a mismatch throws `ModelStoreError.checksumMismatch` and
    /// leaves nothing behind. (The Whisper companion encoders cannot be
    /// checked this way: their entries hash the ggml `.bin`, not the
    /// encoder zip, so that path keeps its pre-existing behaviour.)
    ///
    /// Returns the installed directory URL, nil on failure.
    func installCoreMLEncoder(fromZip zipURL: URL, for id: ModelID) throws -> URL? {
        guard let entry = ModelCatalog.entry(for: id),
              let dest = coreMLBundleFinalURL(for: id) else { return nil }
        if entry.kind == .intentEncoder,
           !(try verifyChecksum(at: zipURL, expected: entry.sha256)) {
            emit("coreml_encoder_checksum_mismatch", outcome: "failure",
                 modelId: id, errorCode: "checksum")
            throw ModelStoreError.checksumMismatch
        }
        let unzipDir = zipURL.deletingLastPathComponent()
            .appendingPathComponent("encoder-unzip-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: unzipDir) }
        try fileManager.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        try fileManager.unzipItem(at: zipURL, to: unzipDir)
        // The zip contains a single `<stem>-encoder.mlmodelc` directory.
        let extracted = try fileManager.contentsOfDirectory(at: unzipDir,
            includingPropertiesForKeys: nil).first {
            $0.lastPathComponent.hasSuffix(".mlmodelc")
        }
        guard let extracted else {
            throw NSError(domain: "ModelStore", code: 6,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "encoder zip did not contain an .mlmodelc directory"])
        }
        try? fileManager.removeItem(at: dest)
        // A CoreML-only entry (`.intentEncoder`) has no ggml file to have
        // created its parent directory (the kind's own ModelStore folder),
        // so ensure it exists before the move. Deliberately scoped to that
        // kind: on the Whisper-companion path the parent is the ggml
        // model's own directory, and creating it early would let an
        // encoder install succeed in the anomalous "encoder before its
        // Whisper model" ordering, leaving an orphan encoder dir — the
        // pre-existing failure is the safer behaviour there.
        if entry.kind == .intentEncoder {
            try ensureDirectory(dest.deletingLastPathComponent())
        }
        try fileManager.moveItem(at: extracted, to: dest)
        emit("coreml_encoder_installed", outcome: "success", modelId: id,
             errorCode: nil)
        return dest
    }

    /// The whisper.cpp-derived encoder path regardless of whether the
    /// catalog ships one — used to REMOVE stale encoders left by older
    /// builds (whisper.cpp auto-loads whatever dir is on disk, and a
    /// hung encoder beats the catalog's "run on CPU" decision).
    private func derivedCoreMLBundleURL(for entry: ModelCatalogEntry) -> URL {
        let ggmlURL = finalURL(for: entry)
        var stem: String
        if ggmlURL.pathExtension == "bin" {
            stem = ggmlURL.deletingPathExtension().lastPathComponent
        } else {
            stem = ggmlURL.lastPathComponent
        }
        // Drop a trailing "-qX_X" (5 chars) like whisper.cpp does.
        if let dash = stem.lastIndex(of: "-") {
            let suffix = Array(stem[dash...])
            if suffix.count == 5, suffix[1] == "q", suffix[3] == "_" {
                stem = String(stem[..<dash])
            }
        }
        return ggmlURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(stem)-encoder.mlmodelc", isDirectory: true)
    }

    /// Deletes `-encoder.mlmodelc` dirs for catalog entries that no
    /// longer ship an encoder. Idempotent; called at app launch so old
    /// installs stop auto-loading encoders we've since unbundled.
    func removeStaleCoreMLBundles() {
        for entry in ModelCatalog.all
        where entry.kind == .whisperBase && entry.coreMLEncoderBundledName == nil {
            let url = derivedCoreMLBundleURL(for: entry)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
                emit("coreml_encoder_removed", outcome: "success",
                     modelId: entry.id, errorCode: nil)
            }
        }
    }

    /// True when the mlmodelc directory exists on disk next to the ggml.
    func isCoreMLCached(_ id: ModelID) -> Bool {
        guard let url = coreMLBundleFinalURL(for: id) else { return false }
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    /// Copies the app-bundled `-encoder.mlmodelc` (if any) into place next
    /// to the ggml file. Idempotent — noop when the target already exists
    /// or the bundle has no resource by that name. Called from `finalize`;
    /// safe to call standalone at app launch to catch first-run installs.
    ///
    /// Returns the installed URL on success, nil when nothing was installed.
    /// Errors are swallowed and emitted as observability — CoreML is an
    /// optimisation, and any failure falls back to CPU without impact.
    @discardableResult
    func installBundledCoreMLEncoder(for id: ModelID,
                                     bundle: Bundle = .main) -> URL? {
        guard let entry = ModelCatalog.entry(for: id),
              let resourceName = entry.coreMLEncoderBundledName,
              let dest = coreMLBundleFinalURL(for: id) else {
            return nil
        }
        if fileManager.fileExists(atPath: dest.path) {
            return dest
        }
        guard let source = bundle.url(forResource: resourceName,
                                      withExtension: "mlmodelc") else {
            emit("coreml_encoder_not_bundled", outcome: "info",
                 modelId: id, errorCode: nil)
            return nil
        }
        do {
            try ensureDirectory(dest.deletingLastPathComponent())
            try fileManager.copyItem(at: source, to: dest)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: dest.path
            )
            var mutable = dest
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = true
            try? mutable.setResourceValues(resource)
            emit("coreml_encoder_installed", outcome: "success",
                 modelId: id, errorCode: nil)
            return dest
        } catch {
            emit("coreml_encoder_install_failed", outcome: "failure",
                 modelId: id, errorCode: "copy")
            return nil
        }
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

        // Install the app-bundled CoreML encoder (if any) so whisper.cpp
        // picks it up on next `Whisper(fromFileURL:)`. Failure here is
        // logged, not raised — CPU fallback is fine.
        _ = installBundledCoreMLEncoder(for: id)

        emit("finalize_success", outcome: "success", modelId: id, errorCode: nil)
        return final
    }

    /// Deletes a cached model file. Idempotent. Also removes the
    /// `-encoder.mlmodelc` sibling if present.
    func delete(_ id: ModelID) throws {
        guard let entry = ModelCatalog.entry(for: id) else {
            throw ModelStoreError.unknownModel
        }
        let final = finalURL(for: entry)
        if fileManager.fileExists(atPath: final.path) {
            try fileManager.removeItem(at: final)
            emit("delete", outcome: "success", modelId: id, errorCode: nil)
        }
        if let coreml = coreMLBundleFinalURL(for: id),
           fileManager.fileExists(atPath: coreml.path) {
            try? fileManager.removeItem(at: coreml)
            emit("delete_coreml_encoder", outcome: "success",
                 modelId: id, errorCode: nil)
        }
        // WhisperKit models are directory artifacts under
        // whisperKit/<id> — the Settings trash button must clear them
        // too, or a "deleted" row silently comes back as Ready.
        if let dir = directoryURL(for: id) {
            try fileManager.removeItem(at: dir)
            emit("delete_whisperkit_directory", outcome: "success",
                 modelId: id, errorCode: nil)
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

    // MARK: - Bundled models

    /// Copies an app-bundled model into place next to the ggml files.
    /// Idempotent — no-op when the target already exists.
    ///
    /// [BOOT-REVIEW P1-5] Called at FIRST USE of the stack that needs the
    /// model, never at boot: the copy is a one-off hundreds-of-MB write,
    /// so the caller owns WHEN it is worth paying. `progress` reports
    /// determinate byte counts (first callback is `0 / total`, last is
    /// `total / total`) so the model-specific UI can show a real
    /// percentage instead of an indeterminate spinner.
    ///
    /// Failure leaves NOTHING behind — the partial file is removed before
    /// returning nil, so a half-written artifact can never be mistaken
    /// for an installed one by `isCached`/`path(for:)`.
    func installBundledModel(for id: ModelID,
                             bundle: Bundle = .main,
                             progress: ((Int64, Int64) -> Void)? = nil) -> URL? {
        guard let entry = ModelCatalog.entry(for: id),
              let resourceName = entry.bundledResourceName,
              let source = bundle.url(forResource: resourceName,
                                      withExtension: "bin") else {
            return nil
        }
        let dest = finalURL(for: entry)
        if fileManager.fileExists(atPath: dest.path) {
            return dest
        }
        let bundledBytes = (try? source.resourceValues(forKeys: [.fileSizeKey]))?
            .fileSize
        let total = bundledBytes.map(Int64.init) ?? Int64(entry.sizeBytes)
        // Disk-space pre-flight (same volume query the download path uses):
        // a 586 MB copy on a full device should fail fast and say why,
        // not write for a minute and then run out.
        if let free = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           free < total {
            emit("bundled_model_install_failed", outcome: "failure",
                 modelId: id, errorCode: "disk_full")
            return nil
        }
        do {
            try ensureDirectory(dest.deletingLastPathComponent())
            try streamCopy(from: source, to: dest, total: total,
                           progress: progress)
            // Same Data Protection Complete + exclude-from-backup the
            // download path applies (`finalize`) — a bundled copy is
            // exactly as sensitive as a downloaded one.
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: dest.path
            )
            var mutable = dest
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = true
            try? mutable.setResourceValues(resource)
            emit("bundled_model_installed", outcome: "success", modelId: id,
                 errorCode: nil)
            return dest
        } catch {
            // Never leave a partial artifact where `isCached` would see it.
            try? fileManager.removeItem(at: dest)
            emit("bundled_model_install_failed", outcome: "failure",
                 modelId: id, errorCode: "copy")
            return nil
        }
    }

    /// Chunked copy so a long bundled install can report determinate
    /// progress (the same 4 MB read the checksum pass uses, sized up so a
    /// 586 MB model reports ~140 honest updates instead of thousands).
    private func streamCopy(from source: URL, to dest: URL,
                            total: Int64,
                            progress: ((Int64, Int64) -> Void)?) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard fileManager.createFile(atPath: dest.path, contents: nil) else {
            throw ModelStoreError.cacheDirectoryFailed(
                CocoaError(.fileWriteUnknown))
        }
        let output = try FileHandle(forWritingTo: dest)
        defer { try? output.close() }
        progress?(0, total)
        var written: Int64 = 0
        while try autoreleasepool(invoking: { () throws -> Bool in
            let chunk = input.readData(ofLength: Self.copyChunkBytes)
            guard !chunk.isEmpty else { return false }
            try output.write(contentsOf: chunk)
            written += Int64(chunk.count)
            progress?(written, total)
            return true
        }) {}
    }

    /// Chunk size for bundled installs (4 MB).
    private static let copyChunkBytes = 4 * 1_048_576

    // MARK: - WhisperKit directory artifacts

    /// URL of an installed WhisperKit-style model DIRECTORY (not a single
    /// file). Nil when never installed.
    func directoryURL(for id: ModelID) -> URL? {
        let url = rootDirectory
            .appendingPathComponent("whisperKit", isDirectory: true)
            .appendingPathComponent(id.rawValue, isDirectory: true)
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue ? url : nil
    }

    /// Unpacks a zip of a WhisperKit model directory into
    /// `directoryURL(for:)`. The zip contains a single top-level model
    /// folder; its contents become the installed directory.
    func installWhisperKitModel(fromZip zipURL: URL, for id: ModelID) throws -> URL? {
        let dest = rootDirectory
            .appendingPathComponent("whisperKit", isDirectory: true)
            .appendingPathComponent(id.rawValue, isDirectory: true)
        // Verify the zip against the catalog checksum before unpacking —
        // same strict policy as single-file `finalize`.
        if let entry = ModelCatalog.entry(for: id),
           !(try verifyChecksum(at: zipURL, expected: entry.sha256)) {
            emit("whisperkit_checksum_mismatch", outcome: "failure",
                 modelId: id, errorCode: "checksum")
            throw ModelStoreError.checksumMismatch
        }
        let unzipDir = zipURL.deletingLastPathComponent()
            .appendingPathComponent("wk-unzip-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: unzipDir) }
        try fileManager.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        try fileManager.unzipItem(at: zipURL, to: unzipDir)
        // The zip holds one top-level model directory.
        let extracted = try fileManager.contentsOfDirectory(at: unzipDir,
            includingPropertiesForKeys: nil).first { url in
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue
        }
        guard let extracted else {
            throw NSError(domain: "ModelStore", code: 7,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "WhisperKit zip did not contain a model directory"])
        }
        try? fileManager.removeItem(at: dest)
        try ensureDirectory(dest.deletingLastPathComponent())
        try fileManager.moveItem(at: extracted, to: dest)
        // A locked device mid-install (Data-Protection-complete parent)
        // can fail the move halfway, leaving a partial directory that then
        // passes directoryURL's existence check — the recognizer engages
        // and dies deep inside WhisperKit with modelsUnavailable (field
        // report 2026-09-06, missing MelSpectrogram.mlmodelc). Treat a
        // short payload as an install failure and remove the partial.
        let expectedComponents = ["AudioEncoder.mlmodelc",
                                  "TextDecoder.mlmodelc",
                                  "MelSpectrogram.mlmodelc",
                                  "tokenizer.json"]
        let complete = expectedComponents.allSatisfy {
            fileManager.fileExists(atPath: dest.appendingPathComponent($0).path)
        }
        guard complete else {
            try? fileManager.removeItem(at: dest)
            emit("whisperkit_install_incomplete", outcome: "failure",
                 modelId: id, errorCode: "incomplete")
            throw NSError(domain: "ModelStore", code: 8,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "WhisperKit install incomplete — removed partial directory"])
        }
        emit("whisperkit_model_installed", outcome: "success", modelId: id,
             errorCode: nil)
        return dest
    }

    // MARK: - Internals

    /// NOTE (T-037-a): the last component is appended with an explicit
    /// `isDirectory` because `URL.appendingPathComponent(_:)` infers it
    /// from the filesystem WHEN THE PATH EXISTS — the same call returns
    /// `…/x.mlmodelc` before an install and `…/x.mlmodelc/` after one.
    /// Two callers comparing URLs (or recording a load path) would then
    /// disagree with no code change in between. Directory kinds state it
    /// up front so the URL is the same value on every call; the whisper /
    /// llama `.bin` kinds stay file URLs.
    private func finalURL(for entry: ModelCatalogEntry) -> URL {
        rootDirectory
            .appendingPathComponent(entry.kind.rawValue, isDirectory: true)
            .appendingPathComponent(entry.filename,
                                    isDirectory: entry.kind.isDirectoryArtifact)
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
