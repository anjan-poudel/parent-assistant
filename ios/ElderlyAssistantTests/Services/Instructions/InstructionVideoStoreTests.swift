import XCTest
@testable import ElderlyAssistant

/// C02's suite (T-002; design L2 §11.3 A/E, §5.2–§5.5).
///
/// Every test plants bytes only inside its own temporary directory and
/// injects that directory as the store's base; no real user data is read
/// or written and nothing touches the network. The two doubles —
/// `InstructionFileManagerSpy` (a `FileManager` subclass that records every
/// call and can script failures) and `InstructionStagingFileOpsSpy` (the
/// create-before-bytes seam) — share one ordered call log, which is what
/// makes the ordering claims (create before first write, rename before
/// delete) assertable.
///
/// B-3 (must-carry, review-l2): the staged destination is created with
/// `.completeFileProtection` before the first byte is written, filled by a
/// bounded chunked stream, and re-verified after the stream; no
/// `FileManager.copyItem` exists anywhere in the store (source scan).
/// Kill-window note (§5.3): a crash, kill or lock after creation leaves at
/// most an empty or partial file whose class was requested `.complete` at
/// creation — never a weaker-class file — and the pending purge removes it
/// after the grace window. R-5: a reported weaker protection class fails
/// closed; an unreported attribute proceeds (tolerated, never invented).
final class InstructionVideoStoreTests: XCTestCase {

    private var tempDirectory: URL!
    private var log: InstructionStoreCallLog!
    private var fileManager: InstructionFileManagerSpy!
    private var stagingOps: InstructionStagingFileOpsSpy!
    private var store: InstructionVideoStore!
    private var now: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("instruction-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        log = InstructionStoreCallLog()
        fileManager = InstructionFileManagerSpy(log: log)
        stagingOps = InstructionStagingFileOpsSpy(log: log)
        now = Date()
        store = InstructionVideoStore(fileManager: fileManager,
                                      baseDirectory: tempDirectory,
                                      now: { [weak self] in self?.now ?? Date() },
                                      fileOps: stagingOps)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - B-3: create-before-bytes, no copyItem, protection

    /// E.1: the destination is created with complete protection through the
    /// create-then-write seam, before the first chunk write — and it did not
    /// exist with any class before the creation call.
    func testCreateProtectedFileRunsBeforeFirstWrite() throws {
        let draftId = UUID()
        let source = try writeSource(named: "clip.mov", bytes: Data(repeating: 0xAB, count: 10))
        let destination = stagedURL(draftId: draftId, root: .routines)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "the destination must not exist with any class before the creation call")

        let result = store.stageSynchronously(from: source, into: .routines,
                                              limits: limits(), chunkBytes: 3,
                                              draftId: draftId, probe: validProbe())

        guard case .success(let staged) = result else {
            return XCTFail("staging failed: \(result)")
        }
        XCTAssertEqual(staged.draftId, draftId)
        XCTAssertEqual(staged.root, .routines)
        XCTAssertEqual(staged.stagedURL, destination)
        XCTAssertEqual(staged.byteCount, 10)
        XCTAssertEqual(staged.sourceExtension, "mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        let createIndex = try XCTUnwrap(logIndex(ofPrefix: "createProtectedFile"),
                                        "the destination must be created through the staging seam")
        let verifyIndices = log.events.indices.filter { log.events[$0].hasPrefix("verifyProtection") }
        let writeIndices = log.events.indices.filter { log.events[$0].hasPrefix("writeChunk") }
        XCTAssertEqual(verifyIndices.count, 2, "the attribute is verified after creation and after the stream")
        XCTAssertFalse(writeIndices.isEmpty)

        // B-3 ordering: create → verify → stream → verify (E.1, E.8).
        XCTAssertLessThan(createIndex, verifyIndices[0],
                          "creation must precede the first attribute read")
        XCTAssertLessThan(verifyIndices[0], writeIndices[0],
                          "the create-then-verify pair must precede the first byte")
        XCTAssertLessThan(writeIndices[writeIndices.count - 1], verifyIndices[1],
                          "the post-stream attribute read must follow the last byte")

        // The seam's own witness: the pre-created destination existed at
        // every single chunk write.
        for index in writeIndices {
            XCTAssertTrue(log.events[index].contains("existed=true"),
                          "every chunk write must land in the pre-created destination")
        }

        // E.1's source pin: the complete-protection request is present in
        // the store's code (staging create + both directory creates). The
        // pin holds the create-file attribute token `FileProtectionType.complete`
        // — the design's `.completeFileProtection` wording is the
        // `Data.WritingOptions` constant, which the create-then-stream seam
        // does not use (it creates with `createFile`, never `data.write`).
        let code = FeatureSourceScan.codeText(of: storeSourceURL())
        let protectedLines = code.split(separator: "\n").filter { $0.contains("FileProtectionType.complete") }
        XCTAssertGreaterThanOrEqual(protectedLines.count, 3,
                                    "the store must request complete protection by source pin")
    }

    /// E.2 / B-3: a source scan proves no `FileManager.copyItem` exists
    /// anywhere in the store — the only staging path is create-then-stream.
    func testStagingDoesNotUseCopyItem() {
        let code = FeatureSourceScan.codeText(of: storeSourceURL())
        XCTAssertFalse(code.isEmpty, "the source scan must actually read the store file")
        XCTAssertFalse(code.contains("copyItem"),
                       "B-3: no FileManager.copyItem may appear in the video store")
    }

    /// E.3: a weaker class reported immediately after creation deletes the
    /// file and the draft directory, before any byte is written.
    func testWeakerClassAtCreationDeletes() throws {
        let draftId = UUID()
        let source = try writeSource(named: "clip.mov", bytes: Data(repeating: 1, count: 8))
        stagingOps.protectionReports = [.completeUntilFirstUserAuthentication, .complete]

        let result = store.stageSynchronously(from: source, into: .routines,
                                              limits: limits(), chunkBytes: 4,
                                              draftId: draftId, probe: validProbe())

        XCTAssertEqual(result, .failure(.writeFailed(.protectionFailed)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL(draftId: draftId, root: .routines).path),
                       "the partial destination must be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftDirectoryURL(draftId: draftId, root: .routines).path),
                       "the draft directory must be removed")
        XCTAssertNil(logIndex(ofPrefix: "writeChunk"),
                     "no byte may be written when the created class is reported weaker")
    }

    /// E.4: the same report only on the post-stream read fails the same way,
    /// after the bytes were streamed — and cleans up the same way.
    func testWeakerClassAfterStreamFailsAndDeletes() throws {
        let draftId = UUID()
        let source = try writeSource(named: "clip.mov", bytes: Data(repeating: 2, count: 8))
        stagingOps.protectionReports = [.complete, .completeUntilFirstUserAuthentication]

        let result = store.stageSynchronously(from: source, into: .routines,
                                              limits: limits(), chunkBytes: 4,
                                              draftId: draftId, probe: validProbe())

        XCTAssertEqual(result, .failure(.writeFailed(.protectionFailed)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL(draftId: draftId, root: .routines).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftDirectoryURL(draftId: draftId, root: .routines).path))

        // The stream really ran before the second verify refused it.
        let writeIndices = log.events.indices.filter { log.events[$0].hasPrefix("writeChunk") }
        let verifyIndices = log.events.indices.filter { log.events[$0].hasPrefix("verifyProtection") }
        XCTAssertFalse(writeIndices.isEmpty)
        XCTAssertEqual(verifyIndices.count, 2)
        XCTAssertLessThan(writeIndices[writeIndices.count - 1], verifyIndices[1],
                          "the post-stream verify must follow the stream")
    }

    /// R-5: an unreported protection class is tolerated — the reads still
    /// happen and are recorded as unknown, never invented — and staging
    /// succeeds.
    func testUnreportedClassIsTolerated() throws {
        let draftId = UUID()
        let source = try writeSource(named: "clip.mov", bytes: Data(repeating: 3, count: 6))
        stagingOps.protectionReports = [nil, nil]

        let result = store.stageSynchronously(from: source, into: .routines,
                                              limits: limits(), chunkBytes: 2,
                                              draftId: draftId, probe: validProbe())

        guard case .success(let staged) = result else {
            return XCTFail("an unreported class must be tolerated, got \(result)")
        }
        XCTAssertEqual(staged.byteCount, 6)

        let verifies = log.events.filter { $0.hasPrefix("verifyProtection") }
        XCTAssertEqual(verifies.count, 2, "both attribute reads must still happen")
        for event in verifies {
            XCTAssertTrue(event.hasSuffix(":nil"),
                          "the reported class must be recorded as unknown, not invented: \(event)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.stagedURL.path))
    }

    // MARK: - Staging failures (mid-stream, caps, truncation)

    /// E.5: a write failure and, separately, a read failure after k bytes
    /// leave no file and no draft directory — no accepted file exists.
    func testMidStreamFailureLeavesNoAcceptedFile() throws {
        // The n-th write fails ⇒ writeFailed(.stagingFailed).
        var draftId = UUID()
        var source = try writeSource(named: "clip.mov", bytes: Data(repeating: 4, count: 20))
        stagingOps.failWriteAtChunk = 2

        var result = store.stageSynchronously(from: source, into: .routines,
                                              limits: limits(), chunkBytes: 4,
                                              draftId: draftId, probe: validProbe())

        XCTAssertEqual(result, .failure(.writeFailed(.stagingFailed)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL(draftId: draftId, root: .routines).path),
                       "a mid-stream write failure must leave no file under an owner root")
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftDirectoryURL(draftId: draftId, root: .routines).path))

        // The n-th read fails ⇒ unreadableSource.
        stagingOps.failWriteAtChunk = nil
        stagingOps.failReadAtChunk = 3
        draftId = UUID()
        source = try writeSource(named: "clip2.mov", bytes: Data(repeating: 5, count: 20))

        result = store.stageSynchronously(from: source, into: .routines,
                                          limits: limits(), chunkBytes: 4,
                                          draftId: draftId, probe: validProbe())

        XCTAssertEqual(result, .failure(.unreadableSource))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL(draftId: draftId, root: .routines).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftDirectoryURL(draftId: draftId, root: .routines).path))
    }

    /// A: a source larger than the cap is refused before anything is
    /// created or streamed — zero directory, destination and stream calls.
    func testSourceLargerThanCapIsRejectedBeforeCopy() throws {
        let source = try writeSource(named: "big.mov", bytes: Data(repeating: 0, count: 1000))

        let result = store.stageSynchronously(from: source, into: .routines,
                                              limits: limits(maxBytes: 100), probe: validProbe())

        XCTAssertEqual(result, .failure(.tooLarge))
        XCTAssertNil(logIndex(ofPrefix: "createDirectory"),
                     "no directory may be created for a rejected source")
        XCTAssertNil(logIndex(ofPrefix: "createProtectedFile"),
                     "no destination may be created for a rejected source")
        XCTAssertNil(logIndex(ofPrefix: "streamStart"),
                     "no stream may run for a rejected source")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rootURL(.routines).appendingPathComponent(InstructionVideoStore.pendingDirectoryName, isDirectory: true).path))
    }

    /// E.6: the 200 MiB cap is enforced cumulatively while streaming — the
    /// metadata is under the cap but the stream passes it.
    func testCumulativeCapAcrossChunks() throws {
        // Real source: 500 bytes. Scripted step-2 size: 400 — under the
        // 400-byte cap, so staging proceeds; the real stream then delivers
        // 500, which trips the cumulative cap.
        let source = try writeSource(named: "grows.mov", bytes: Data(repeating: 0x42, count: 500))
        fileManager.scriptedAttributes = [.size: Int64(400)]
        let draftId = UUID()

        let result = store.stageSynchronously(from: source, into: .routines,
                                              limits: limits(maxBytes: 400), chunkBytes: 100,
                                              draftId: draftId, probe: validProbe())

        XCTAssertEqual(result, .failure(.tooLarge))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL(draftId: draftId, root: .routines).path),
                       "the partial file must be deleted after a cumulative cap breach")
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftDirectoryURL(draftId: draftId, root: .routines).path))
        let writes = log.events.filter { $0.hasPrefix("writeChunk") }.count
        XCTAssertEqual(writes, 4, "the four in-cap chunks were streamed before the breach")
    }

    /// E.6: a source that delivers fewer bytes than the step-2 size is a
    /// truncated (or changed) source — refused, partial file deleted.
    func testTruncatedSourceFails() throws {
        // 300 real bytes; the step-2 size claims 500.
        let source = try writeSource(named: "short.mov", bytes: Data(repeating: 7, count: 300))
        fileManager.scriptedAttributes = [.size: Int64(500)]
        let draftId = UUID()

        let result = store.stageSynchronously(from: source, into: .routines,
                                              limits: limits(maxBytes: 500), chunkBytes: 100,
                                              draftId: draftId, probe: validProbe())

        XCTAssertEqual(result, .failure(.unreadableSource))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL(draftId: draftId, root: .routines).path),
                       "the truncated partial file must be deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftDirectoryURL(draftId: draftId, root: .routines).path))
    }

    // MARK: - Commit (rename-then-delete order, failure keeps the old file)

    /// The Gherkin commit scenario: the rename happens before the old path
    /// is removed, the new path exists first, and the old instruction file
    /// is untouched. The in-flight set protects the owner directory from a
    /// sweep that runs while the move is in flight.
    func testCommitOrderRenameThenDelete() throws {
        let owner = InstructionOwner.routine(UUID())
        let oldFile = try plantFile(named: "instruction-\(UUID().uuidString).mov",
                                    in: ownerDirectoryURL(owner),
                                    bytes: Data("old".utf8))
        // Age the owner directory so the grace window cannot protect it —
        // only the in-flight set can (and must).
        try setModificationDate(now.addingTimeInterval(-120), of: ownerDirectoryURL(owner))

        let draftId = UUID()
        let source = try writeSource(named: "clip.mov", bytes: Data(repeating: 0x11, count: 6))
        guard case .success(let staged) = store.stageSynchronously(from: source, into: .routines,
                                                                   limits: limits(), chunkBytes: 2,
                                                                   draftId: draftId, probe: validProbe()) else {
            return XCTFail("staging failed")
        }

        // Re-entrancy seam: while the move is in flight, the old staged
        // path still exists, the new path does not, and a zero-grace sweep
        // with an empty live set must still skip the owner directory.
        var sweptDuringMove: Result<Int, InstructionStorageError>?
        fileManager.onMoveItem = { [weak self] in
            guard let self else { return }
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.stagedURL.path),
                          "the staged path must still exist while the rename is in flight")
            let newPath = self.ownerDirectoryURL(owner)
                .appendingPathComponent(InstructionVideoStore.storedFilename(draftId: draftId,
                                                                             sourceExtension: staged.sourceExtension),
                                        isDirectory: false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: newPath.path),
                           "the new path must not exist before the rename completes")
            sweptDuringMove = self.store.purgeOrphanedOwners(in: .routines, live: [], graceSeconds: 0)
        }

        let result = store.commit(staged, for: owner)

        guard case .success(let filename) = result else {
            return XCTFail("commit failed: \(result)")
        }
        XCTAssertEqual(filename, InstructionVideoStore.storedFilename(draftId: draftId, sourceExtension: "mov"))
        XCTAssertEqual(sweptDuringMove, .success(0),
                       "the in-flight commit set must protect the owner directory from a concurrent sweep")

        // rename-then-delete: the move precedes the draft-directory removal.
        let moveIndex = try XCTUnwrap(logIndex(ofPrefix: "moveItem"))
        let removeIndex = try XCTUnwrap(logIndex(ofPrefix: "removeItem"))
        XCTAssertLessThan(moveIndex, removeIndex,
                          "commit must rename before it removes the draft directory")

        // The old file and its bytes are untouched; the new file is live.
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertEqual(try Data(contentsOf: oldFile), Data("old".utf8))
        let newPath = ownerDirectoryURL(owner).appendingPathComponent(filename, isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPath.path))
        XCTAssertEqual(try Data(contentsOf: newPath), Data(repeating: 0x11, count: 6))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.stagedURL.path),
                       "the staged path is gone after the rename")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.stagedURL.deletingLastPathComponent().path),
                       "the draft directory is gone after commit")
    }

    /// A failed new-path rename leaves the old file, its bytes and the
    /// staged draft exactly as they were — the sweep collects the draft.
    func testCommitRenameFailureKeepsOldFile() throws {
        let owner = InstructionOwner.routine(UUID())
        let oldFile = try plantFile(named: "instruction-\(UUID().uuidString).mov",
                                    in: ownerDirectoryURL(owner),
                                    bytes: Data("old".utf8))

        let draftId = UUID()
        let source = try writeSource(named: "clip.mov", bytes: Data(repeating: 0x22, count: 6))
        guard case .success(let staged) = store.stageSynchronously(from: source, into: .routines,
                                                                   limits: limits(), chunkBytes: 2,
                                                                   draftId: draftId, probe: validProbe()) else {
            return XCTFail("staging failed")
        }
        fileManager.failMoveItem = true

        let result = store.commit(staged, for: owner)

        XCTAssertEqual(result, .failure(.commitFailed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertEqual(try Data(contentsOf: oldFile), Data("old".utf8),
                       "a failed rename must leave the old file byte-identical")
        let newPath = ownerDirectoryURL(owner)
            .appendingPathComponent(InstructionVideoStore.storedFilename(draftId: draftId,
                                                                         sourceExtension: "mov"),
                                    isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.stagedURL.path),
                      "the staged bytes are left for the sweep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.stagedURL.deletingLastPathComponent().path))
    }

    // MARK: - Delete failures and idempotent teardown

    /// E.9: a spy whose `removeItem` throws reports `.deleteFailed`; absent
    /// owners are idempotent successes with zero removal calls.
    func testDeleteFailureIsReported() throws {
        let owner = InstructionOwner.routine(UUID())
        let file = try plantFile(named: "instruction-\(UUID().uuidString).mov",
                                 in: ownerDirectoryURL(owner),
                                 bytes: Data("x".utf8))

        fileManager.failRemoveItem = true
        assertFailure(store.delete(file.lastPathComponent, for: owner), .deleteFailed)
        assertFailure(store.deleteAll(for: owner), .deleteFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "the failed delete must leave the file in place for the next sweep")
        fileManager.failRemoveItem = false

        // Absent owner ⇒ success and zero calls to removeItem (E.9).
        let absentOwner = InstructionOwner.routine(UUID())
        let removalsBefore = log.events.filter { $0.hasPrefix("removeItem") }.count
        assertSuccess(store.delete("instruction-\(UUID().uuidString).mov", for: absentOwner))
        assertSuccess(store.deleteAll(for: absentOwner))
        XCTAssertEqual(log.events.filter { $0.hasPrefix("removeItem") }.count, removalsBefore,
                       "an absent owner must not be touched")
    }

    // MARK: - Purges (pending drafts and crash orphans)

    /// The pending purge removes only aged children of `_pending` — a young
    /// draft and every owner directory are untouched, and a stray file
    /// directly under `_pending` follows the same age rule.
    func testPurgePendingDraftsOnly() throws {
        let pending = rootURL(.routines)
            .appendingPathComponent(InstructionVideoStore.pendingDirectoryName, isDirectory: true)
        let oldDraftFile = try plantFile(named: "payload.mov",
                                         in: pending.appendingPathComponent("old-draft", isDirectory: true),
                                         bytes: Data("old".utf8))
        let youngDraftFile = try plantFile(named: "payload.mov",
                                           in: pending.appendingPathComponent("young-draft", isDirectory: true),
                                           bytes: Data("young".utf8))
        let stray = try plantFile(named: "stray.mov", in: pending, bytes: Data("stray".utf8))
        let owner = InstructionOwner.routine(UUID())
        let liveFile = try plantFile(named: "instruction-\(UUID().uuidString).mov",
                                     in: ownerDirectoryURL(owner),
                                     bytes: Data("live".utf8))
        try setModificationDate(now.addingTimeInterval(-120), of: oldDraftFile.deletingLastPathComponent())
        try setModificationDate(now.addingTimeInterval(-5), of: youngDraftFile.deletingLastPathComponent())
        try setModificationDate(now.addingTimeInterval(-120), of: stray)
        try setModificationDate(now.addingTimeInterval(-120), of: ownerDirectoryURL(owner))

        let result = store.purgePendingDrafts()

        XCTAssertEqual(result, .success(2), "the aged draft directory and the aged stray file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDraftFile.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: youngDraftFile.deletingLastPathComponent().path),
                      "a draft younger than the grace window must be kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveFile.path),
                      "the pending purge must never touch owner directories")
    }

    /// P-6: a readable owner list follows the live rules; an unreadable
    /// source (live == nil) keeps every file belonging to it.
    func testOrphanSweepKeepsUnreadableOwners() throws {
        let liveOwner = InstructionOwner.routine(UUID())
        let orphanOwner = InstructionOwner.routine(UUID())
        let eventOwner = InstructionOwner.event("EK-\(UUID().uuidString)")
        let liveFile = try plantFile(named: "instruction-\(UUID().uuidString).mov",
                                     in: ownerDirectoryURL(liveOwner),
                                     bytes: Data("live".utf8))
        let orphanFile = try plantFile(named: "instruction-\(UUID().uuidString).mov",
                                       in: ownerDirectoryURL(orphanOwner),
                                       bytes: Data("orphan".utf8))
        let eventFile = try plantFile(named: "instruction-\(UUID().uuidString).mov",
                                      in: ownerDirectoryURL(eventOwner),
                                      bytes: Data("event".utf8))
        try setModificationDate(now.addingTimeInterval(-120), of: ownerDirectoryURL(liveOwner))
        try setModificationDate(now.addingTimeInterval(-120), of: ownerDirectoryURL(orphanOwner))
        try setModificationDate(now.addingTimeInterval(-120), of: ownerDirectoryURL(eventOwner))

        // The routine source is readable: the live owner is kept, the
        // orphan is collected.
        XCTAssertEqual(store.purgeOrphanedOwners(in: .routines, live: [liveOwner],
                                                 graceSeconds: 60),
                       .success(1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanFile.path))

        // The event source is unreadable (live == nil): nothing may be
        // deleted, not even enumeration.
        XCTAssertEqual(store.purgeOrphanedOwners(in: .events, live: nil,
                                                 graceSeconds: 60),
                       .success(0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: eventFile.path),
                      "every file belonging to an unreadable source must be kept")
    }

    /// The sweep honours the grace window and the skip rules: a young
    /// directory, `_pending`, an unparseable name and a non-directory are
    /// all left alone; only the aged orphan is collected.
    func testOrphanSweepHonoursGrace() throws {
        let youngOwner = InstructionOwner.routine(UUID())
        let oldOwner = InstructionOwner.routine(UUID())
        let youngFile = try plantFile(named: "instruction-\(UUID().uuidString).mov",
                                      in: ownerDirectoryURL(youngOwner),
                                      bytes: Data("young".utf8))
        let oldFile = try plantFile(named: "instruction-\(UUID().uuidString).mov",
                                    in: ownerDirectoryURL(oldOwner),
                                    bytes: Data("old".utf8))
        let pendingDraft = try plantFile(
            named: "payload.mov",
            in: rootURL(.routines).appendingPathComponent(InstructionVideoStore.pendingDirectoryName, isDirectory: true),
            bytes: Data("draft".utf8))
        let unparseable = try plantFile(
            named: "file.mov",
            in: rootURL(.routines).appendingPathComponent("not-ours", isDirectory: true),
            bytes: Data("alien".utf8))
        let strayFile = try plantFile(named: "stray.mov", in: rootURL(.routines),
                                      bytes: Data("stray".utf8))
        try setModificationDate(now.addingTimeInterval(-10), of: ownerDirectoryURL(youngOwner))
        try setModificationDate(now.addingTimeInterval(-120), of: ownerDirectoryURL(oldOwner))
        try setModificationDate(now.addingTimeInterval(-120), of: pendingDraft.deletingLastPathComponent())
        try setModificationDate(now.addingTimeInterval(-120),
                                of: rootURL(.routines).appendingPathComponent("not-ours", isDirectory: true))
        try setModificationDate(now.addingTimeInterval(-120), of: strayFile)

        let result = store.purgeOrphanedOwners(in: .routines, live: [], graceSeconds: 60)

        XCTAssertEqual(result, .success(1), "only the aged orphan is collected")
        XCTAssertTrue(FileManager.default.fileExists(atPath: youngFile.path),
                      "a directory younger than the grace window is never collected")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDraft.path),
                      "_pending is skipped by name, whatever its age")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unparseable.path),
                      "an unparseable name is not ours to delete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: strayFile.path),
                      "a non-directory under the root is skipped")
    }

    // MARK: - Name guards (N-1, N-4)

    /// N-1/N-4: an invalid owner name is refused with `.invalidOwner`
    /// before any URL is built and before any file operation; payload
    /// filenames are refused the same way (`.deleteFailed` /
    /// `.rejectedFilename` / nil) without touching the disk.
    func testInvalidOwnerNameIsRefusedBeforePathBuild() {
        for badName in ["", ".", "..", "a/b", "a\\b", "/absolute/path"] {
            XCTAssertEqual(store.ownerDirectoryURL(named: badName, in: .routines),
                           .failure(.invalidOwner),
                           "the owner guard must refuse \(badName) before any URL is built")
        }
        let goodName = UUID().uuidString
        XCTAssertEqual(store.ownerDirectoryURL(named: goodName, in: .routines),
                       .success(rootURL(.routines).appendingPathComponent(goodName, isDirectory: true)))
        XCTAssertTrue(log.events.isEmpty,
                      "the name guard must run before any file operation is attempted")

        // The same boundary guards payload-supplied filenames (N-4): the
        // empty and dot-only inputs would otherwise resolve to the owner
        // directory itself.
        let owner = InstructionOwner.routine(UUID())
        assertFailure(store.delete("", for: owner), .deleteFailed)
        assertFailure(store.delete("../x.mov", for: owner), .deleteFailed)
        XCTAssertEqual(store.availability(filename: "", owner: owner), .rejectedFilename)
        XCTAssertEqual(store.availability(filename: "..", owner: owner), .rejectedFilename)
        XCTAssertNil(store.fileURL(filename: "a/b.mov", owner: owner))
        XCTAssertTrue(log.events.isEmpty,
                      "a refused filename must not reach FileManager")
    }

    // MARK: - Pre-staging rejections and availability (design §11.3 A/D)

    /// A: absent, directory, probe-refused and over-duration sources all
    /// return their typed error before anything is staged; exactly 180 s
    /// is accepted (the cap is inclusive).
    func testPreStagingRejectionsLeaveNothingBehind() throws {
        let absent = tempDirectory.appendingPathComponent("absent.mov", isDirectory: false)
        XCTAssertEqual(store.stageSynchronously(from: absent, into: .routines,
                                                limits: limits(), probe: validProbe()),
                       .failure(.unreadableSource))

        let directory = tempDirectory.appendingPathComponent("source-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(store.stageSynchronously(from: directory, into: .routines,
                                                limits: limits(), probe: validProbe()),
                       .failure(.unreadableSource))

        let source = try writeSource(named: "clip.mov", bytes: Data(repeating: 0, count: 8))
        let refusedProbe: (URL) -> Result<InstructionVideoMetadata, InstructionImportError> = { _ in
            .failure(.unsupportedFormat)
        }
        XCTAssertEqual(store.stageSynchronously(from: source, into: .routines,
                                                limits: limits(), probe: refusedProbe),
                       .failure(.unsupportedFormat))

        let longProbe: (URL) -> Result<InstructionVideoMetadata, InstructionImportError> = { _ in
            .success(InstructionVideoMetadata(durationSeconds: 180.5, hasVideoTrack: true, isPlayable: true))
        }
        XCTAssertEqual(store.stageSynchronously(from: source, into: .routines,
                                                limits: limits(), probe: longProbe),
                       .failure(.tooLong))

        XCTAssertTrue(log.events.filter { $0.hasPrefix("createDirectory") }.isEmpty,
                      "A: every pre-staging rejection must precede any directory creation")
        XCTAssertTrue(log.events.filter { $0.hasPrefix("createProtectedFile") }.isEmpty)
        XCTAssertTrue(log.events.filter { $0.hasPrefix("streamStart") }.isEmpty)

        // Exactly 180 s is accepted — the cap is inclusive.
        let boundaryProbe: (URL) -> Result<InstructionVideoMetadata, InstructionImportError> = { _ in
            .success(InstructionVideoMetadata(durationSeconds: 180, hasVideoTrack: true, isPlayable: true))
        }
        guard case .success = store.stageSynchronously(from: source, into: .routines,
                                                       limits: limits(), probe: boundaryProbe) else {
            return XCTFail("exactly 180 s must be accepted")
        }
    }

    /// D: the four availability classes — available, rejectedFilename,
    /// missingFile, unreadableFile — are the whole contract.
    func testAvailabilityReportsAllFourClasses() throws {
        let owner = InstructionOwner.routine(UUID())
        let file = try plantFile(named: "instruction-\(UUID().uuidString).mov",
                                 in: ownerDirectoryURL(owner),
                                 bytes: Data("v".utf8))

        guard case .available(let url) = store.availability(filename: file.lastPathComponent, owner: owner) else {
            return XCTFail("a present readable file must be .available")
        }
        XCTAssertEqual(url, file)

        XCTAssertEqual(store.availability(filename: "missing.mov", owner: owner), .missingFile)

        fileManager.unreadablePaths.insert(file.path)
        XCTAssertEqual(store.availability(filename: file.lastPathComponent, owner: owner), .unreadableFile)
        fileManager.unreadablePaths.remove(file.path)

        for badName in ["../x.mov", "a/b.mov", "", ".", ".."] {
            XCTAssertEqual(store.availability(filename: badName, owner: owner), .rejectedFilename,
                           "the bare-name guard must refuse \(badName) before any URL is built")
        }
    }

    // MARK: - Helpers

    private func rootURL(_ root: InstructionRoot) -> URL {
        tempDirectory.appendingPathComponent(root.rawValue, isDirectory: true)
    }

    private func ownerDirectoryURL(_ owner: InstructionOwner) -> URL {
        rootURL(owner.root).appendingPathComponent(owner.directoryName, isDirectory: true)
    }

    private func draftDirectoryURL(draftId: UUID, root: InstructionRoot) -> URL {
        rootURL(root)
            .appendingPathComponent(InstructionVideoStore.pendingDirectoryName, isDirectory: true)
            .appendingPathComponent(draftId.uuidString, isDirectory: true)
    }

    private func stagedURL(draftId: UUID, root: InstructionRoot) -> URL {
        draftDirectoryURL(draftId: draftId, root: root)
            .appendingPathComponent(InstructionVideoStore.stagedFilename(sourceExtension: "mov"),
                                    isDirectory: false)
    }

    private func writeSource(named name: String, bytes: Data) throws -> URL {
        let source = tempDirectory.appendingPathComponent(name, isDirectory: false)
        try bytes.write(to: source)
        return source
    }

    /// Plants a file (creating the directory on the way) with the REAL
    /// default FileManager, so the spies' logs stay clean for assertions.
    @discardableResult
    private func plantFile(named name: String, in directory: URL, bytes: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try bytes.write(to: url)
        return url
    }

    private func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func validProbe() -> (URL) -> Result<InstructionVideoMetadata, InstructionImportError> {
        { _ in .success(InstructionVideoMetadata(durationSeconds: 30,
                                                 hasVideoTrack: true,
                                                 isPlayable: true)) }
    }

    private func limits(maxBytes: Int64 = 1_000_000) -> InstructionVideoLimits {
        InstructionVideoLimits(maxDurationSeconds: 180, maxBytes: maxBytes)
    }

    private func logIndex(ofPrefix prefix: String) -> Int? {
        log.events.firstIndex { $0.hasPrefix(prefix) }
    }

    private func storeSourceURL() -> URL {
        FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/Services/Instructions/InstructionVideoStore.swift")
    }

    /// `Result<Void, _>` is not `Equatable` (Void is not), so the delete
    /// rows compare the failure payload through this seam.
    private func assertFailure<T>(_ result: Result<T, InstructionStorageError>,
                                  _ expected: InstructionStorageError,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        switch result {
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        case .success:
            XCTFail("expected \(expected), got success", file: file, line: line)
        }
    }

    private func assertSuccess<T>(_ result: Result<T, InstructionStorageError>,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        if case .failure(let error) = result {
            XCTFail("expected success, got \(error)", file: file, line: line)
        }
    }
}

// MARK: - Shared call log

/// One ordered log shared by both doubles, so cross-seam orderings
/// (create before first write, rename before delete) are assertable.
/// Test-only and single-threaded; `@unchecked Sendable` so the staging
/// spy (which must conform to the `Sendable` seam) can hold it.
private final class InstructionStoreCallLog: @unchecked Sendable {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

// MARK: - FileManager spy

/// Records every `FileManager` call the store makes and can script
/// failures. Real operations delegate to the superclass implementation,
/// so on-disk assertions (files exist / are gone) stay honest.
private final class InstructionFileManagerSpy: FileManager {
    private let log: InstructionStoreCallLog
    var failRemoveItem = false
    var failMoveItem = false
    /// When set, `attributesOfItem` returns exactly these values (used to
    /// lie about the step-2 source size).
    var scriptedAttributes: [FileAttributeKey: Any]?
    var unreadablePaths: Set<String> = []
    /// Runs inside `moveItem` before the real move happens — the
    /// re-entrancy seam for the in-flight commit set.
    var onMoveItem: (() -> Void)?

    init(log: InstructionStoreCallLog) {
        self.log = log
        super.init()
    }

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        log.append("fileExists:\((path as NSString).lastPathComponent)")
        return super.fileExists(atPath: path, isDirectory: isDirectory)
    }

    override func isReadableFile(atPath path: String) -> Bool {
        log.append("isReadableFile:\((path as NSString).lastPathComponent)")
        guard !unreadablePaths.contains(path) else { return false }
        return super.isReadableFile(atPath: path)
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        log.append("attributesOfItem:\((path as NSString).lastPathComponent)")
        if let scriptedAttributes {
            return scriptedAttributes
        }
        return try super.attributesOfItem(atPath: path)
    }

    override func createDirectory(at url: URL,
                                  withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        log.append("createDirectory:\(url.lastPathComponent)")
        try super.createDirectory(at: url,
                                  withIntermediateDirectories: createIntermediates,
                                  attributes: attributes)
    }

    override func removeItem(at url: URL) throws {
        log.append("removeItem:\(url.lastPathComponent)")
        if failRemoveItem {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.removeItem(at: url)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        log.append("moveItem:\(srcURL.lastPathComponent)->\(dstURL.lastPathComponent)")
        onMoveItem?()
        if failMoveItem {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func contentsOfDirectory(at url: URL,
                                      includingPropertiesForKeys keys: [URLResourceKey]?,
                                      options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        log.append("contentsOfDirectory:\(url.lastPathComponent)")
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}

// MARK: - Staging seam spy

/// The create-before-bytes seam double (design §11.4). Records every
/// staging call in one ordered log (create → verify → stream → verify),
/// reports a scripted protection class per read, fails the n-th read or
/// write, and by default performs the REAL operations — so staged bytes
/// really exist on disk and on-disk cleanup assertions stay honest.
private final class InstructionStagingFileOpsSpy: InstructionStagingFileOps {
    private let log: InstructionStoreCallLog
    /// What each `protectionClass` read reports, in order; a fresh staging
    /// attempt restarts at the first entry, and reads past the end report
    /// `.complete`.
    var protectionReports: [FileProtectionType?] = [.complete, .complete]
    private var protectionReadIndex = 0
    /// Fail the n-th read (1-based) instead of reading.
    var failReadAtChunk: Int?
    /// Fail the n-th write (1-based) instead of writing.
    var failWriteAtChunk: Int?
    private var chunkIndex = 0

    init(log: InstructionStoreCallLog) {
        self.log = log
    }

    func createProtectedFile(at url: URL) -> Bool {
        protectionReadIndex = 0
        chunkIndex = 0
        log.append("createProtectedFile:\(url.lastPathComponent)")
        return FileManager.default.createFile(atPath: url.path, contents: nil,
                                              attributes: [.protectionKey: FileProtectionType.complete])
    }

    func protectionClass(at url: URL) -> FileProtectionType? {
        let index = protectionReadIndex
        protectionReadIndex += 1
        let reported = index < protectionReports.count ? protectionReports[index] : .complete
        log.append("verifyProtection:\(url.lastPathComponent):\(reported?.rawValue ?? "nil")")
        return reported
    }

    func copyChunks(from source: URL, to destination: URL,
                    maxBytes: Int64, chunkBytes: Int) -> Result<Int64, InstructionImportError> {
        log.append("streamStart")
        guard let input = try? FileHandle(forReadingFrom: source),
              let output = try? FileHandle(forWritingTo: destination) else {
            return .failure(.unreadableSource)
        }
        defer {
            try? input.close()
            try? output.close()
        }
        var delivered: Int64 = 0
        while true {
            chunkIndex += 1
            let data: Data
            do {
                if failReadAtChunk == chunkIndex {
                    throw CocoaError(.fileReadUnknown)
                }
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
                if failWriteAtChunk == chunkIndex {
                    throw CocoaError(.fileWriteUnknown)
                }
                let destinationExisted = FileManager.default.fileExists(atPath: destination.path)
                try output.write(contentsOf: data)
                log.append("writeChunk:\(chunkIndex):\(data.count):existed=\(destinationExisted)")
            } catch {
                return .failure(.writeFailed(.stagingFailed))
            }
        }
    }
}
