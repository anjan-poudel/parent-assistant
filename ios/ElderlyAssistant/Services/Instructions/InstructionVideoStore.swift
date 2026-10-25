import Foundation

/// C02 — the video store's failures (design L2 §3.3, §5).
///
/// `Equatable` so callers and tests compare values; no OS error domain,
/// code or description ever escapes the store (design §6.1). `.deleteFailed`
/// is reachable (N-1) and applies to VIDEO only — the image stores keep
/// their shipping best-effort `Void` API (§5.8).
///
/// NOTE (T-002): the TEMPORARY placeholder declaration of this enum in
/// `InstructionVideoInspecting.swift` (added for T-001's standalone
/// compileability) MUST be deleted when this file lands — two
/// declarations of one type do not compile. The case set matches exactly,
/// so deleting the placeholder block loses no case.
enum InstructionStorageError: Error, Equatable {
    /// An owner directory name is not a plain path component (N-1, §4.3).
    case invalidOwner
    /// `_pending` or the destination file could not be created, or the
    /// streamed fill failed.
    case stagingFailed
    /// A weaker-than-`.complete` protection class was reported; the bytes
    /// were deleted (fail closed, §5.3).
    case protectionFailed
    /// The same-volume rename failed; `_pending` is left for the sweep.
    case commitFailed
    /// An existing path could not be removed, or a name was refused before
    /// a path was built (N-4).
    case deleteFailed
    /// A sweep stopped early. The fixed case set carries no partial count;
    /// the caller logs the failure and the next launch retries (§5.5).
    case purgeFailed
}

/// The store's answer to "can this filename play right now" (IF-10;
/// design §3.5). Never throws — the four cases are the contract. Only
/// `.available` hands out a URL, and that URL is valid only for the call
/// that received it (§7.4).
enum InstructionPlaybackAvailability: Equatable {
    /// Exists, is a regular file and is readable.
    case available(URL)
    /// The bare-name guard refused the filename before any URL was built.
    case rejectedFilename
    /// Absent.
    case missingFile
    /// Exists but attributes or readability say no.
    case unreadableFile
}

/// A staged-but-not-committed video (design §3.5): the bytes live at
/// `<root>/_pending/<draftId>/payload.<ext>` and no index names them yet.
struct StagedInstructionVideo: Equatable {
    let draftId: UUID
    let root: InstructionRoot
    let stagedURL: URL
    /// The step-2 source size; the stream must deliver exactly this.
    let byteCount: Int64
    let metadata: InstructionVideoMetadata
    /// Sanitized at staging time (`InstructionFilename.sanitizedExtension`).
    let sourceExtension: String
    let stagedAt: Date
}

/// A staged video that passed asynchronous validation (design §3.5); the
/// editor's handoff value.
struct AcceptedInstructionVideo: Equatable {
    let staged: StagedInstructionVideo
    let validatedAt: Date
}

/// C02 — the store's only staging file-operation seam (design §3.5; lives
/// here, no new source file). Production is `SystemInstructionStagingFileOps`:
/// a create with no bytes and the complete-protection attribute, an
/// attribute read, and a bounded `FileHandle` read/write loop that closes
/// both handles on every path. A test double reports a weaker protection
/// class at creation or after the stream and fails the n-th read or write —
/// which is what makes the create-before-bytes order and the fail-closed
/// cleanup real (§11.3 E).
protocol InstructionStagingFileOps: Sendable {
    /// Creates the destination with NO bytes and the complete-protection
    /// attribute (`.completeFileProtection`) — the create-before-bytes
    /// guarantee (B-3, §5.2 step 5).
    func createProtectedFile(at url: URL) -> Bool
    /// The reported class, or nil when the platform reports none (R-5:
    /// tolerated — the creation already asked for `.complete`).
    func protectionClass(at url: URL) -> FileProtectionType?
    /// Streams the source into the existing file in bounded chunks.
    /// `.tooLarge` when the cumulative count exceeds `maxBytes`;
    /// `.unreadableSource` on a read failure; `.writeFailed(.stagingFailed)`
    /// on a write failure. Returns the bytes delivered.
    func copyChunks(from source: URL, to destination: URL,
                    maxBytes: Int64, chunkBytes: Int) -> Result<Int64, InstructionImportError>
}

/// The production staging seam: create-then-stream, never copy (§5.2).
struct SystemInstructionStagingFileOps: InstructionStagingFileOps {
    init() {}

    func createProtectedFile(at url: URL) -> Bool {
        FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.protectionKey: FileProtectionType.complete])
    }

    func protectionClass(at url: URL) -> FileProtectionType? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.protectionKey] as? FileProtectionType
    }

    func copyChunks(from source: URL, to destination: URL,
                    maxBytes: Int64, chunkBytes: Int) -> Result<Int64, InstructionImportError> {
        guard let input = try? FileHandle(forReadingFrom: source) else {
            return .failure(.unreadableSource)
        }
        guard let output = try? FileHandle(forWritingTo: destination) else {
            try? input.close()
            return .failure(.writeFailed(.stagingFailed))
        }
        defer {
            try? input.close()
            try? output.close()
        }
        var delivered: Int64 = 0
        while true {
            let data: Data
            do {
                data = try input.read(upToCount: chunkBytes) ?? Data()
            } catch {
                return .failure(.unreadableSource)
            }
            if data.isEmpty {
                return .success(delivered)
            }
            delivered += Int64(data.count)
            if delivered > maxBytes {
                return .failure(.tooLarge)
            }
            do {
                try output.write(contentsOf: data)
            } catch {
                return .failure(.writeFailed(.stagingFailed))
            }
        }
    }
}

/// C02 — the only code that touches instruction video bytes (design L2
/// §2.2, §5). It owns the two roots, the `_pending` staging area, the
/// pre-staging size stat, the protected create-then-stream staging write,
/// the same-volume rename, availability classification, deletion and the
/// two sweeps.
///
/// Nonisolated and `@unchecked Sendable` for one stated reason (§7.1):
/// the only mutable state is the in-flight commit-name set behind an
/// `NSLock`; the root paths are immutable; `FileManager` is documented
/// safe for concurrent use for these calls. The unchecked conformance is
/// a reviewed claim, not a convenience. No method logs — failures return
/// typed errors to the caller, which maps them to events (§2.2 rule 7).
///
/// `stageSynchronously` is main-thread-only by contract (IF-5): it must
/// run inside the system callback, before the callback returns, because
/// the source URL dies with the callback (§7.4). It is not dispatched.
final class InstructionVideoStore: @unchecked Sendable {

    /// The staging directory name shared by both roots (§5.1, §9.3).
    static let pendingDirectoryName = "_pending"

    /// The staged payload name: `payload.<ext>` (§9.3). The extension is
    /// sanitized once at staging and carried by `StagedInstructionVideo`.
    static func stagedFilename(sourceExtension: String) -> String {
        "payload.\(sourceExtension)"
    }

    /// The committed bare filename: `instruction-<draftId>.<ext>` (§9.3).
    /// Unique per staging attempt, so a replace never overwrites the file
    /// the index still points at.
    static func storedFilename(draftId: UUID, sourceExtension: String) -> String {
        "instruction-\(draftId.uuidString).\(sourceExtension)"
    }

    private let fileManager: FileManager
    private let routinesRoot: URL
    private let eventsRoot: URL
    private let now: () -> Date
    private let fileOps: InstructionStagingFileOps
    /// Guards `inFlightCommitNames`; held only around set insert/remove and
    /// the sweep's snapshot copy (§7.2).
    private let commitLock = NSLock()
    private var inFlightCommitNames: Set<String> = []

    /// Resolves paths and NOTHING else — zero FileManager calls beyond the
    /// pure path lookups below (§5.1, pinned by
    /// `NoIOInInitTests.testInitDoesNoFileIO`). Resolution order: the
    /// injected base (tests always pass one), else the Application Support
    /// lookup with `create: false` (a pure path lookup, exactly as
    /// `VisualAidStore.init`), else the temporary directory (a broken
    /// sandbox only). Directories are created by the first write.
    init(fileManager: FileManager = .default,
         baseDirectory: URL? = nil,
         now: @escaping () -> Date = Date.init,
         fileOps: InstructionStagingFileOps = SystemInstructionStagingFileOps()) {
        self.fileManager = fileManager
        self.now = now
        self.fileOps = fileOps
        let base: URL
        if let baseDirectory {
            base = baseDirectory
        } else if let applicationSupport = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            base = applicationSupport
        } else {
            base = fileManager.temporaryDirectory
        }
        self.routinesRoot = base.appendingPathComponent(InstructionRoot.routines.rawValue, isDirectory: true)
        self.eventsRoot = base.appendingPathComponent(InstructionRoot.events.rawValue, isDirectory: true)
    }

    // MARK: - Staging (IF-5)

    /// IF-5. MUST be called on the main thread from inside a system
    /// callback, before the callback returns (the callback-scoped URL rule,
    /// §7.4). `probe` is the synchronous pre-staging inspector supplied by
    /// C03.
    ///
    /// Fixed order (§5.2): readable file, size stat, probe, `_pending`
    /// directory, destination created with `.completeFileProtection`
    /// before any byte, bounded chunked fill, protection re-verify. Every
    /// step after the first directory creation removes what it created:
    /// the partial destination first, then the draft directory.
    func stageSynchronously(
        from sourceURL: URL,
        into root: InstructionRoot,
        limits: InstructionVideoLimits,
        chunkBytes: Int = InstructionVideoConfiguration.standard.stagingChunkBytes,
        draftId: UUID = UUID(),
        probe: (URL) -> Result<InstructionVideoMetadata, InstructionImportError>
    ) -> Result<StagedInstructionVideo, InstructionImportError> {
        // 1. Readable file, not a directory.
        guard sourceURL.isFileURL else { return .failure(.unreadableSource) }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: sourceURL.path) else {
            return .failure(.unreadableSource)
        }

        // 2. The step-2 size stat — the byte count the stream must deliver.
        // Cheap, so it runs before AVFoundation opens the source (§5.2).
        guard let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
              let sourceSize = attributes[.size] as? Int64 else {
            return .failure(.unreadableSource)
        }
        if sourceSize > limits.maxBytes {
            return .failure(.tooLarge)
        }

        // 3. The synchronous probe, then the store's own metadata defences.
        let metadata: InstructionVideoMetadata
        switch probe(sourceURL) {
        case .success(let probed):
            metadata = probed
        case .failure(let error):
            return .failure(error)
        }
        guard metadata.isPlayable, metadata.hasVideoTrack else {
            return .failure(.unsupportedFormat)
        }
        guard metadata.durationSeconds.isFinite else {
            return .failure(.unreadableSource)
        }
        if InstructionVideoDuration.exceedsLimit(metadata.durationSeconds,
                                                 limit: limits.maxDurationSeconds) {
            return .failure(.tooLong)
        }

        // 4. The draft directory, created complete-protected.
        let draftDirectory = rootURL(root)
            .appendingPathComponent(Self.pendingDirectoryName, isDirectory: true)
            .appendingPathComponent(draftId.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: draftDirectory,
                                            withIntermediateDirectories: true,
                                            attributes: [.protectionKey: FileProtectionType.complete])
        } catch {
            return .failure(.writeFailed(.stagingFailed))
        }

        // 5. Create the destination with NO bytes and complete protection —
        // before the first byte arrives (B-3). A reported weaker class
        // deletes everything and fails closed; an unreported attribute
        // proceeds (R-5).
        let sanitizedExtension = InstructionFilename.sanitizedExtension(sourceURL.pathExtension)
        let destination = draftDirectory.appendingPathComponent(
            Self.stagedFilename(sourceExtension: sanitizedExtension),
            isDirectory: false)
        guard fileOps.createProtectedFile(at: destination) else {
            cleanupStaging(file: destination, draftDirectory: draftDirectory)
            return .failure(.writeFailed(.stagingFailed))
        }
        if let reported = fileOps.protectionClass(at: destination), reported != .complete {
            cleanupStaging(file: destination, draftDirectory: draftDirectory)
            return .failure(.writeFailed(.protectionFailed))
        }

        // 6. The bounded chunked fill. The cap is enforced cumulatively
        // while streaming, and the delivered count must equal the step-2
        // size exactly (a truncated or changed source is refused).
        switch fileOps.copyChunks(from: sourceURL, to: destination,
                                  maxBytes: limits.maxBytes, chunkBytes: chunkBytes) {
        case .success(let delivered):
            guard delivered == sourceSize else {
                cleanupStaging(file: destination, draftDirectory: draftDirectory)
                return .failure(.unreadableSource)
            }
        case .failure(let error):
            cleanupStaging(file: destination, draftDirectory: draftDirectory)
            return .failure(error)
        }

        // 7. Re-verify the attribute after the stream.
        if let reported = fileOps.protectionClass(at: destination), reported != .complete {
            cleanupStaging(file: destination, draftDirectory: draftDirectory)
            return .failure(.writeFailed(.protectionFailed))
        }

        // 8. Accepted.
        return .success(StagedInstructionVideo(
            draftId: draftId,
            root: root,
            stagedURL: destination,
            byteCount: sourceSize,
            metadata: metadata,
            sourceExtension: sanitizedExtension,
            stagedAt: now()))
    }

    // MARK: - Commit, discard, delete (IF-6..IF-9)

    /// IF-6. Same-volume rename; returns the stored BARE filename. The move
    /// preserves the creation protection class, which is re-verified before
    /// the name is returned (§5.4). A failed rename leaves the staged bytes
    /// for the sweep and the index unchanged.
    func commit(_ staged: StagedInstructionVideo,
                for owner: InstructionOwner) -> Result<String, InstructionStorageError> {
        // 1. Owner name is a plain component, else .invalidOwner (N-1).
        let ownerDirectory: URL
        switch ownerDirectoryURL(for: owner) {
        case .success(let url):
            ownerDirectory = url
        case .failure(let error):
            return .failure(error)
        }
        // 2. Root match — a programming error, no move (§5.4).
        guard staged.root == owner.root else { return .failure(.commitFailed) }
        // The minted name is guarded too, as a cheap invariant (§3.5): the
        // write path mints it, so no payload name can reach here.
        let filename = Self.storedFilename(draftId: staged.draftId,
                                           sourceExtension: staged.sourceExtension)
        guard InstructionFilename.isPlain(filename) else { return .failure(.commitFailed) }

        // The owner directory is protected from a concurrent sweep from
        // before it exists until the rename completes (§5.5, §7.2).
        commitLock.lock()
        inFlightCommitNames.insert(owner.directoryName)
        commitLock.unlock()
        defer {
            commitLock.lock()
            inFlightCommitNames.remove(owner.directoryName)
            commitLock.unlock()
        }

        // 3. Create the owner directory with complete protection.
        do {
            try fileManager.createDirectory(at: ownerDirectory,
                                            withIntermediateDirectories: true,
                                            attributes: [.protectionKey: FileProtectionType.complete])
        } catch {
            return .failure(.commitFailed)
        }

        // 4. A retried commit whose destination already exists with the
        // staged size is a success — no move (ambiguity-safe retry, §5.4).
        let destination = ownerDirectory.appendingPathComponent(filename, isDirectory: false)
        if fileManager.fileExists(atPath: destination.path) {
            let existingSize = (try? fileManager.attributesOfItem(atPath: destination.path))?[.size] as? Int64
            if existingSize == staged.byteCount {
                return .success(filename)
            }
        }

        // 5. The same-volume rename: the file either appears complete under
        // the final name or does not appear (§5.4). On failure the staged
        // file is left for the sweep.
        do {
            try fileManager.moveItem(at: staged.stagedURL, to: destination)
        } catch {
            return .failure(.commitFailed)
        }

        // 6. Verify the destination's protection (the move preserves it).
        // A reported weaker class removes the destination and fails — the
        // same R-5 rule: unreported proceeds, reported weaker fails closed.
        if let reported = (try? fileManager.attributesOfItem(atPath: destination.path))?[.protectionKey] as? FileProtectionType,
           reported != .complete {
            _ = try? fileManager.removeItem(at: destination)
            return .failure(.commitFailed)
        }

        // 7. Remove the now-empty draft directory best-effort; the sweep
        // collects it if this fails.
        _ = try? fileManager.removeItem(at: staged.stagedURL.deletingLastPathComponent())
        return .success(filename)
    }

    /// IF-7. Removes the draft directory. Absent ⇒ .success.
    func discard(_ staged: StagedInstructionVideo) -> Result<Void, InstructionStorageError> {
        let draftDirectory = staged.stagedURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: draftDirectory.path) else { return .success(()) }
        do {
            try fileManager.removeItem(at: draftDirectory)
            return .success(())
        } catch {
            return .failure(.deleteFailed)
        }
    }

    /// IF-8. Removes one stored file. Absent ⇒ .success (idempotent
    /// teardown). A payload-supplied name is guarded before any URL is
    /// built (N-4): the empty component would otherwise resolve to the
    /// owner directory itself.
    func delete(_ filename: String,
                for owner: InstructionOwner) -> Result<Void, InstructionStorageError> {
        guard InstructionFilename.isPlain(filename) else { return .failure(.deleteFailed) }
        let ownerDirectory: URL
        switch ownerDirectoryURL(for: owner) {
        case .success(let url):
            ownerDirectory = url
        case .failure(let error):
            return .failure(error)
        }
        let file = ownerDirectory.appendingPathComponent(filename, isDirectory: false)
        guard fileManager.fileExists(atPath: file.path) else { return .success(()) }
        do {
            try fileManager.removeItem(at: file)
            return .success(())
        } catch {
            return .failure(.deleteFailed)
        }
    }

    /// IF-9. Removes the owner's whole directory. Absent ⇒ .success.
    func deleteAll(for owner: InstructionOwner) -> Result<Void, InstructionStorageError> {
        let ownerDirectory: URL
        switch ownerDirectoryURL(for: owner) {
        case .success(let url):
            ownerDirectory = url
        case .failure(let error):
            return .failure(error)
        }
        guard fileManager.fileExists(atPath: ownerDirectory.path) else { return .success(()) }
        do {
            try fileManager.removeItem(at: ownerDirectory)
            return .success(())
        } catch {
            return .failure(.deleteFailed)
        }
    }

    // MARK: - Availability (IF-10)

    /// IF-10. Never throws; the four cases are the contract. Only
    /// `.available` hands out a URL, valid for the call that received it
    /// (§7.4).
    func availability(filename: String,
                      owner: InstructionOwner) -> InstructionPlaybackAvailability {
        guard InstructionFilename.isPlain(filename) else { return .rejectedFilename }
        guard case .success(let ownerDirectory) = ownerDirectoryURL(for: owner) else {
            return .rejectedFilename
        }
        let url = ownerDirectory.appendingPathComponent(filename, isDirectory: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .missingFile
        }
        guard fileManager.isReadableFile(atPath: url.path) else { return .unreadableFile }
        return .available(url)
    }

    /// Existence-checked URL for a playback handoff; nil when the name is
    /// unsafe or the file is absent (§3.5). A TOCTOU deletion after this
    /// call lands in the playback failure path, never here (§2.6.5).
    func fileURL(filename: String, owner: InstructionOwner) -> URL? {
        guard InstructionFilename.isPlain(filename) else { return nil }
        guard case .success(let ownerDirectory) = ownerDirectoryURL(for: owner) else {
            return nil
        }
        let url = ownerDirectory.appendingPathComponent(filename, isDirectory: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return url
    }

    // MARK: - Purges (IF-11, IF-12)

    /// IF-11. Off-main. For each root, removes every `_pending` child whose
    /// modification date is at least the design-fixed grace (60 s,
    /// `InstructionVideoConfiguration.standard.orphanGraceSeconds`) old; a
    /// file directly under `_pending` follows the same rule. Returns the
    /// removed count. A removal failure stops the sweep with `.purgeFailed`.
    func purgePendingDrafts() -> Result<Int, InstructionStorageError> {
        let grace = InstructionVideoConfiguration.standard.orphanGraceSeconds
        var removed = 0
        for root in InstructionRoot.allCases {
            let pending = rootURL(root).appendingPathComponent(Self.pendingDirectoryName,
                                                               isDirectory: true)
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(at: pending,
                                                               includingPropertiesForKeys: [.contentModificationDateKey],
                                                               options: [])
            } catch {
                // No _pending under this root — nothing to purge.
                continue
            }
            for child in children {
                guard let modificationDate =
                        (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                    // An unreadable date is not provably old — keep it.
                    continue
                }
                if now().timeIntervalSince(modificationDate) < grace { continue }
                do {
                    try fileManager.removeItem(at: child)
                    removed += 1
                } catch {
                    return .failure(.purgeFailed)
                }
            }
        }
        return .success(removed)
    }

    /// IF-12. Off-main. One root per call: the caller passes that root's
    /// live set, so "unknown" is expressible per root (P-6). `live == nil`
    /// means the index could not be read — nothing is swept for that root.
    /// Otherwise each child directory follows the fixed rules: `_pending`
    /// skipped by name, non-directories skipped, unparseable owner names
    /// skipped (not ours to delete), younger-than-grace skipped, in-flight
    /// commit names skipped, live owners skipped — everything else is an
    /// orphan and is removed (§5.5).
    func purgeOrphanedOwners(in root: InstructionRoot,
                             live: Set<InstructionOwner>?,
                             graceSeconds: TimeInterval) -> Result<Int, InstructionStorageError> {
        guard let live else { return .success(0) }
        let liveNames = Set(live.map(\.directoryName))
        let inFlight = inFlightCommitNamesSnapshot()
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(at: rootURL(root),
                                                           includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                           options: [])
        } catch {
            // An unreadable or absent root proves nothing: delete nothing.
            return .success(0)
        }
        var removed = 0
        for child in children {
            let name = child.lastPathComponent
            guard name != Self.pendingDirectoryName else { continue }
            guard let values = try? child.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true else {
                continue
            }
            guard Self.isRecognizedOwnerDirectoryName(name) else { continue }
            guard let modificationDate = values.contentModificationDate else { continue }
            if now().timeIntervalSince(modificationDate) < graceSeconds { continue }
            if inFlight.contains(name) { continue }
            if liveNames.contains(name) { continue }
            do {
                try fileManager.removeItem(at: child)
                removed += 1
            } catch {
                return .failure(.purgeFailed)
            }
        }
        return .success(removed)
    }

    // MARK: - Path and name guards

    /// N-1: the owner-directory guard — the single place an owner name
    /// becomes a URL. Internal (not private) so the suite can trip it
    /// directly: every `InstructionOwner` the model can produce is safe by
    /// construction (an uppercase UUID string or `ev-` + hex), so the
    /// public API cannot reach the refusal; the guard exists so a future id
    /// source cannot escape the root (§4.3). The name is validated before
    /// any URL is built.
    func ownerDirectoryURL(named name: String,
                           in root: InstructionRoot) -> Result<URL, InstructionStorageError> {
        guard InstructionFilename.isPlain(name) else { return .failure(.invalidOwner) }
        return .success(rootURL(root).appendingPathComponent(name, isDirectory: true))
    }

    private func ownerDirectoryURL(for owner: InstructionOwner) -> Result<URL, InstructionStorageError> {
        ownerDirectoryURL(named: owner.directoryName, in: owner.root)
    }

    private func rootURL(_ root: InstructionRoot) -> URL {
        switch root {
        case .routines:
            return routinesRoot
        case .events:
            return eventsRoot
        }
    }

    /// Whether a directory name under a root could have been minted by this
    /// store: an uppercase/lowercase UUID (routine) or `ev-` + 32 hex
    /// (event). Anything else is not ours to delete (§5.5 step 3). The
    /// sweep answers liveness by comparing directory NAMES against the live
    /// set's names (`InstructionOwner.directoryName` is injective), because
    /// an event owner's name is a one-way digest and cannot be parsed back
    /// into an id.
    private static func isRecognizedOwnerDirectoryName(_ name: String) -> Bool {
        if UUID(uuidString: name) != nil { return true }
        guard name.hasPrefix("ev-") else { return false }
        let digest = name.dropFirst(3)
        return digest.count == 32 && digest.allSatisfy { $0.isHexDigit }
    }

    private func inFlightCommitNamesSnapshot() -> Set<String> {
        commitLock.lock()
        defer { commitLock.unlock() }
        return inFlightCommitNames
    }

    /// Removes everything staging created (§5.2): the partial payload
    /// first, then its draft directory.
    private func cleanupStaging(file: URL, draftDirectory: URL) {
        _ = try? fileManager.removeItem(at: file)
        _ = try? fileManager.removeItem(at: draftDirectory)
    }
}
