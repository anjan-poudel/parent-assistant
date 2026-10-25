import XCTest
@testable import ElderlyAssistant

/// C03's importer suite (T-008; design L2 §2.3, §3.5, §9.2, §11.3 E).
///
/// Every test plants bytes only inside its own temporary directory and
/// points a real `InstructionVideoStore` at it, so the staged draft,
/// the discard and the "nothing lingers" assertions are honest on-disk
/// facts. The prober and inspector doubles are fast and controllable, and
/// the deadline seam is injected: the suite never waits the real 20 s
/// bound. No test touches the network, a real AVAsset or user data.
///
/// The importer is validate-only: `testImporterNeverCallsCopyItem` pins
/// the absence of copy/stage/transcode tokens in its source, and
/// `testValidStagedFileAcceptedWithoutCopy` proves behaviourally that the
/// staged bytes are neither rewritten nor duplicated.
final class InstructionVideoImportTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: InstructionVideoStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("instruction-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = InstructionVideoStore(baseDirectory: tempDirectory,
                                      now: { importTestFixedDate })
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Acceptance and the no-copy contract

    /// The valid-file scenario: the accepted value names the staged URL,
    /// the bytes are untouched and no second file appears.
    func testValidStagedFileAcceptedWithoutCopy() async throws {
        let staged = try stageVideo()
        let originalBytes = try Data(contentsOf: staged.stagedURL)
        let originalDate = try modificationDate(of: staged.stagedURL)

        let importer = makeImporter(prober: MockInstructionProber(result: .success(validVideoMetadata)),
                                    inspector: MockInstructionInspector(result: .success(validVideoMetadata)))
        let result = await importer.validate(staged, limits: .standard)

        guard case .success(let accepted) = result else {
            return XCTFail("a valid staged file must be accepted, got \(result)")
        }
        XCTAssertEqual(accepted.staged, staged,
                       "the accepted value must keep the staged draft it validated")
        XCTAssertEqual(accepted.staged.stagedURL, staged.stagedURL,
                       "the accepted value must name the staged URL")
        XCTAssertEqual(accepted.validatedAt, importTestFixedDate)

        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.stagedURL.path),
                      "acceptance transfers ownership; the importer must not discard")
        XCTAssertEqual(try Data(contentsOf: staged.stagedURL), originalBytes,
                       "the staged bytes must not be copied or re-encoded")
        XCTAssertEqual(try modificationDate(of: staged.stagedURL), originalDate,
                       "the staged file must not be rewritten")
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: staged.stagedURL.deletingLastPathComponent().path)
        XCTAssertEqual(siblings.count, 1, "validation must not create a second copy")
    }

    /// B-3's importer half: a comment-stripped source scan finds no
    /// `copyItem`, staging call or export session in the importer.
    func testImporterNeverCallsCopyItem() {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/Services/Instructions/InstructionVideoImporter.swift")
        let code = FeatureSourceScan.codeText(of: url)

        XCTAssertFalse(code.isEmpty, "the source scan must actually read the importer")
        XCTAssertTrue(code.contains("func validate"),
                      "positive control: the scan read the importer's body")
        XCTAssertTrue(code.contains("inspector.inspect"),
                      "positive control: the bounded inspection call is present")
        XCTAssertTrue(code.contains("prober.probe"),
                      "positive control: the synchronous probe call is present")

        for forbidden in ["copyItem", "stageSynchronously", "AVAssetExportSession",
                          "moveItem", "createFile", "FileHandle"] {
            XCTAssertFalse(code.contains(forbidden),
                           "the importer must never copy, stage or re-encode bytes (\(forbidden))")
        }
    }

    // MARK: - Limits and boundaries (§5.4, N-10)

    /// The byte cap is judged before the probe and before inspection:
    /// strictly more than 209,715,200 bytes is `.tooLarge`, and the draft
    /// is discarded.
    func testOversizeRejectedBeforeInspect() async throws {
        let staged = try makeStagedVideo(byteCount: 209_715_201, fileSize: 209_715_201)
        let recorder = ImportCallRecorder()
        let importer = makeImporter(
            prober: MockInstructionProber(result: .success(validVideoMetadata), recorder: recorder),
            inspector: MockInstructionInspector(result: .success(validVideoMetadata), recorder: recorder))

        let result = await importer.validate(staged, limits: .standard)

        XCTAssertEqual(result, .failure(.tooLarge),
                       "strictly greater than 209,715,200 bytes is too large")
        XCTAssertEqual(recorder.count(.probe), 0,
                       "the byte cap must be judged before the synchronous probe")
        XCTAssertEqual(recorder.count(.inspect), 0,
                       "the byte cap must be judged before the asynchronous inspection")
        assertStagedBytesGone(staged)
    }

    /// N-10: the cap is inclusive on rounded whole seconds — exactly 180 s
    /// and 179.6 s (which rounds to 180) are accepted.
    func testInclusive180SecondsAccepted() async throws {
        let acceptedDurations = [180.0, 179.6]
        for seconds in acceptedDurations {
            let staged = try stageVideo()
            let metadata = InstructionVideoMetadata(durationSeconds: seconds,
                                                    hasVideoTrack: true,
                                                    isPlayable: true)
            let importer = makeImporter(prober: MockInstructionProber(result: .success(metadata)),
                                        inspector: MockInstructionInspector(result: .success(metadata)))

            let result = await importer.validate(staged, limits: .standard)

            guard case .success = result else {
                XCTFail("\(seconds) s rounds to 180 s and must be accepted, got \(result)")
                continue
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.stagedURL.path))
        }
    }

    /// The other side of the inclusive cap: 181 s and 180.5 s (which rounds
    /// to 181) are `.tooLong`, and the staged bytes are discarded.
    func test181SecondsRejected() async throws {
        for seconds in [181.0, 180.5] {
            let staged = try stageVideo()
            let metadata = InstructionVideoMetadata(durationSeconds: seconds,
                                                    hasVideoTrack: true,
                                                    isPlayable: true)
            let importer = makeImporter(prober: MockInstructionProber(result: .success(validVideoMetadata)),
                                        inspector: MockInstructionInspector(result: .success(metadata)))

            let result = await importer.validate(staged, limits: .standard)

            XCTAssertEqual(result, .failure(.tooLong),
                           "\(seconds) s rounds to 181 s and must be refused")
            assertStagedBytesGone(staged)
        }
    }

    /// A missing video track is `.unsupportedFormat` from either check —
    /// the synchronous probe catches it before inspection, and the async
    /// inspection catches a staged file whose probe answer was wrong.
    func testNoVideoTrackRejected() async throws {
        let noTrack = InstructionVideoMetadata(durationSeconds: 30,
                                               hasVideoTrack: false,
                                               isPlayable: true)

        // 1. The probe refuses; the inspector is never asked.
        let probeStaged = try stageVideo()
        let probeRecorder = ImportCallRecorder()
        let probeImporter = makeImporter(
            prober: MockInstructionProber(result: .success(noTrack), recorder: probeRecorder),
            inspector: MockInstructionInspector(result: .success(validVideoMetadata), recorder: probeRecorder))
        let probeResult = await probeImporter.validate(probeStaged, limits: .standard)
        XCTAssertEqual(probeResult, .failure(.unsupportedFormat))
        XCTAssertEqual(probeRecorder.count(.inspect), 0,
                       "a probe failure must short-circuit the asynchronous inspection")
        assertStagedBytesGone(probeStaged)

        // 2. The inspection refuses.
        let inspectStaged = try stageVideo()
        let inspectImporter = makeImporter(prober: MockInstructionProber(result: .success(validVideoMetadata)),
                                           inspector: MockInstructionInspector(result: .success(noTrack)))
        let inspectResult = await inspectImporter.validate(inspectStaged, limits: .standard)
        XCTAssertEqual(inspectResult, .failure(.unsupportedFormat))
        assertStagedBytesGone(inspectStaged)
    }

    // MARK: - The 20-second bound (§9.2)

    /// An inspector that never answers loses to the injected deadline; the
    /// call returns `.validationTimedOut` quickly and the bound passed to
    /// the deadline is the configured 20 s.
    func testTimeoutReturnsValidationTimedOut() async throws {
        let staged = try stageVideo()
        let inspector = NeverAnsweringInspector()
        let recorder = ImportCallRecorder()
        let importer = makeImporter(
            prober: MockInstructionProber(result: .success(validVideoMetadata)),
            inspector: inspector,
            deadline: recordingDeadline(recorder: recorder, delayNanoseconds: 50_000_000))

        let started = Date()
        let result = await importer.validate(staged, limits: .standard)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result, .failure(.validationTimedOut))
        XCTAssertLessThan(elapsed, 1.0,
                          "the injected deadline must resolve the race without a real 20 s wait")
        XCTAssertEqual(recorder.deadlineIntervals, [20],
                       "the importer must pass validationTimeoutSeconds to the deadline")
        XCTAssertEqual(inspector.activeCount, 0,
                       "the losing inspection task must be cancelled and awaited")
    }

    /// The timeout path discards the staged bytes and leaves no inspection
    /// task alive: started and finished both read exactly one.
    func testTimeoutDiscardsStagedFile() async throws {
        let staged = try stageVideo()
        let inspector = NeverAnsweringInspector()
        let importer = makeImporter(
            prober: MockInstructionProber(result: .success(validVideoMetadata)),
            inspector: inspector,
            deadline: recordingDeadline(recorder: ImportCallRecorder(), delayNanoseconds: 50_000_000))

        let result = await importer.validate(staged, limits: .standard)

        XCTAssertEqual(result, .failure(.validationTimedOut))
        assertStagedBytesGone(staged)
        XCTAssertEqual(inspector.startedCount, 1)
        XCTAssertEqual(inspector.finishedCount, 1,
                       "the inspection task must be torn down before validate returns")
        XCTAssertEqual(inspector.activeCount, 0, "no inspection task may outlive the call")
    }

    /// Caller cancellation is a normal outcome — `.cancelled`, never a
    /// failure line — and still discards the staged draft and awaits the
    /// cancelled inspection.
    func testCancellationDiscardsStagedFile() async throws {
        let staged = try stageVideo()
        let inspector = NeverAnsweringInspector()
        let importer = makeImporter(prober: MockInstructionProber(result: .success(validVideoMetadata)),
                                    inspector: inspector,
                                    deadline: { seconds in await quietDeadline(seconds) })

        let validation = Task { await importer.validate(staged, limits: .standard) }
        defer { validation.cancel() }
        try await waitUntil("the inspection must start before the task is cancelled") {
            inspector.startedCount == 1
        }
        validation.cancel()

        let result = await validation.value

        XCTAssertEqual(result, .failure(.cancelled))
        assertStagedBytesGone(staged)
        XCTAssertEqual(inspector.activeCount, 0,
                       "cancellation must await the inspection's teardown")
    }

    // MARK: - Staging failure passthrough

    /// A store seam that cannot stage reports `.writeFailed(.stagingFailed)`;
    /// the importer returns that exact typed error, never remaps it, never
    /// inspects and never accepts.
    func testWriteFailurePropagatesStorageError() async throws {
        let failingStore = InstructionVideoStore(baseDirectory: tempDirectory,
                                                 now: { importTestFixedDate },
                                                 fileOps: FailingStagingFileOps())
        let source = tempDirectory.appendingPathComponent("failing-source.mov", isDirectory: false)
        try Data(repeating: 0x11, count: 64).write(to: source)
        let draftId = UUID()

        let staging = failingStore.stageSynchronously(
            from: source,
            into: .routines,
            limits: .standard,
            draftId: draftId,
            probe: { _ in .success(validVideoMetadata) })

        XCTAssertEqual(staging, .failure(.writeFailed(.stagingFailed)),
                       "the failing store seam must report writeFailed(.stagingFailed)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftDirectoryURL(draftId: draftId).path),
                       "a failed staging removes the draft directory it created")

        let recorder = ImportCallRecorder()
        let importer = makeImporter(
            prober: MockInstructionProber(result: .success(validVideoMetadata), recorder: recorder),
            inspector: MockInstructionInspector(result: .success(validVideoMetadata), recorder: recorder))

        let propagated = await importer.validate(staging, limits: .standard)
        XCTAssertEqual(propagated, .failure(.writeFailed(.stagingFailed)),
                       "the storage error must cross the importer unchanged")
        XCTAssertEqual(recorder.count(.probe), 0)
        XCTAssertEqual(recorder.count(.inspect), 0)

        // The same identity rule for another storage cause: no remapping,
        // no acceptance, no discard (there are no bytes to discard).
        let protectionFailure = await importer.validate(
            Result<StagedInstructionVideo, InstructionImportError>.failure(.writeFailed(.protectionFailed)),
            limits: .standard)
        XCTAssertEqual(protectionFailure, .failure(.writeFailed(.protectionFailed)))
    }

    // MARK: - Threading

    /// The validation body — synchronous probe included — runs off the
    /// main thread when awaited from the main actor, and the inspection
    /// task is off-main too (design §9.2, §7.1).
    @MainActor
    func testValidationRunsOffMain() async throws {
        let staged = try stageVideo()
        let recorder = ImportCallRecorder()
        let importer = makeImporter(
            prober: MockInstructionProber(result: .success(validVideoMetadata), recorder: recorder),
            inspector: MockInstructionInspector(result: .success(validVideoMetadata), recorder: recorder))

        let result = await importer.validate(staged, limits: .standard)

        guard case .success = result else {
            return XCTFail("a valid staged file must be accepted, got \(result)")
        }
        XCTAssertEqual(recorder.count(.probe), 1)
        XCTAssertEqual(recorder.count(.inspect), 1)
        XCTAssertEqual(recorder.mainThreadFlags(.probe), [false],
                       "the synchronous probe must run off the main thread")
        XCTAssertEqual(recorder.mainThreadFlags(.inspect), [false],
                       "the inspection task must run off the main thread")
    }

    // MARK: - Helpers

    private func makeImporter(
        store: InstructionVideoStore? = nil,
        prober: InstructionVideoProbing = MockInstructionProber(result: .success(validVideoMetadata)),
        inspector: InstructionVideoInspecting = MockInstructionInspector(result: .success(validVideoMetadata)),
        deadline: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            await quietDeadline(seconds)
        }
    ) -> InstructionVideoImporter {
        InstructionVideoImporter(store: store ?? self.store,
                                 inspector: inspector,
                                 configuration: .standard,
                                 prober: prober,
                                 deadline: deadline,
                                 now: { importTestFixedDate })
    }

    /// Stages real bytes through the production store, exactly as the
    /// picker/recorder path does, and returns the staged handle.
    private func stageVideo(bytes: Data = Data(repeating: 0xAB, count: 128),
                            durationSeconds: Double = 30) throws -> StagedInstructionVideo {
        let source = tempDirectory.appendingPathComponent("source-\(UUID().uuidString).mov",
                                                          isDirectory: false)
        try bytes.write(to: source)
        let result = store.stageSynchronously(
            from: source,
            into: .routines,
            limits: .standard,
            probe: { _ in
                .success(InstructionVideoMetadata(durationSeconds: durationSeconds,
                                                  hasVideoTrack: true,
                                                  isPlayable: true))
            })
        switch result {
        case .success(let staged):
            return staged
        case .failure(let error):
            XCTFail("test setup staging failed: \(error)")
            throw ImportTestSetupError.staging
        }
    }

    /// Builds a staged handle by hand — used only for the oversize case,
    /// where the production store would (correctly) refuse to stage. The
    /// file is grown sparsely so the 200 MiB-cap test stays instant.
    private func makeStagedVideo(byteCount: Int64, fileSize: Int64) throws -> StagedInstructionVideo {
        let draftId = UUID()
        let directory = draftDirectoryURL(draftId: draftId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(
            InstructionVideoStore.stagedFilename(sourceExtension: "mov"),
            isDirectory: false)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ImportTestSetupError.staging
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(fileSize))
        try handle.close()
        return StagedInstructionVideo(draftId: draftId,
                                      root: .routines,
                                      stagedURL: url,
                                      byteCount: byteCount,
                                      metadata: validVideoMetadata,
                                      sourceExtension: "mov",
                                      stagedAt: importTestFixedDate)
    }

    private func draftDirectoryURL(draftId: UUID) -> URL {
        tempDirectory
            .appendingPathComponent(InstructionRoot.routines.rawValue, isDirectory: true)
            .appendingPathComponent(InstructionVideoStore.pendingDirectoryName, isDirectory: true)
            .appendingPathComponent(draftId.uuidString, isDirectory: true)
    }

    private func assertStagedBytesGone(_ staged: StagedInstructionVideo,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.stagedURL.path),
                       "the rejected staged payload must be discarded", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.stagedURL.deletingLastPathComponent().path),
                       "the draft directory must be discarded too", file: file, line: line)
    }

    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    /// Polls a condition without sleeping on wall-clock guesswork; the
    /// timeout only ever trips when a test is genuinely stuck.
    private func waitUntil(_ message: String,
                           timeout: TimeInterval = 2,
                           _ condition: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= limit {
                XCTFail(message)
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

// MARK: - Fixed values and helpers

/// One instant for every staged/validated value, so `validatedAt` is
/// comparable without depending on the wall clock.
private let importTestFixedDate = Date(timeIntervalSince1970: 1_700_000_000)

private let validVideoMetadata = InstructionVideoMetadata(durationSeconds: 30,
                                                          hasVideoTrack: true,
                                                          isPlayable: true)

/// A deadline that never fires on its own but wakes when its task is
/// cancelled, so a winning inspection never holds the call for 20 s.
private func quietDeadline(_ seconds: TimeInterval) async {
    _ = seconds
    try? await Task.sleep(nanoseconds: 60_000_000_000)
}

private func recordingDeadline(recorder: ImportCallRecorder,
                               delayNanoseconds: UInt64) -> @Sendable (TimeInterval) async -> Void {
    { seconds in
        recorder.recordDeadline(seconds)
        try? await Task.sleep(nanoseconds: delayNanoseconds)
    }
}

private enum ImportTestSetupError: Error {
    case staging
}

// MARK: - Doubles (design §11.4)

/// Records each prober/inspector call and whether it ran on the main
/// thread — the threading proof `testValidationRunsOffMain` reads.
private final class ImportCallRecorder: @unchecked Sendable {
    enum Call: String {
        case probe
        case inspect
    }

    private let lock = NSLock()
    private var calls: [Call: [Bool]] = [:]
    private var deadlines: [TimeInterval] = []

    func record(_ call: Call, isMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        calls[call, default: []].append(isMainThread)
    }

    func recordDeadline(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        deadlines.append(seconds)
    }

    func count(_ call: Call) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls[call]?.count ?? 0
    }

    func mainThreadFlags(_ call: Call) -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return calls[call] ?? []
    }

    var deadlineIntervals: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return deadlines
    }
}

private struct MockInstructionProber: InstructionVideoProbing {
    let result: Result<InstructionVideoMetadata, InstructionImportError>
    var recorder: ImportCallRecorder? = nil

    func probe(url: URL) -> Result<InstructionVideoMetadata, InstructionImportError> {
        recorder?.record(.probe, isMainThread: Thread.isMainThread)
        return result
    }
}

private struct MockInstructionInspector: InstructionVideoInspecting {
    let result: Result<InstructionVideoMetadata, InstructionImportError>
    var recorder: ImportCallRecorder? = nil

    func inspect(url: URL) async -> Result<InstructionVideoMetadata, InstructionImportError> {
        recorder?.record(.inspect, isMainThread: Thread.isMainThread)
        return result
    }
}

/// An inspector that never answers on its own; the importer's cancellation
/// is the only thing that releases it. Started/finished are locked counters
/// so the suite can prove the losing task was awaited, not merely
/// abandoned.
private final class NeverAnsweringInspector: InstructionVideoInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var wasCancelled = false
    private var started = 0
    private var finished = 0

    func inspect(url: URL) async -> Result<InstructionVideoMetadata, InstructionImportError> {
        lock.lock()
        started += 1
        lock.unlock()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if wasCancelled || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            self.cancelAndResume()
        }

        lock.lock()
        finished += 1
        lock.unlock()
        return .failure(.unreadableSource)
    }

    private func cancelAndResume() {
        lock.lock()
        wasCancelled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    var startedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var finishedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return started - finished
    }
}

/// The store seam double for the staging-failure scenario: creation
/// refuses, so `stageSynchronously` cleans up and reports
/// `.writeFailed(.stagingFailed)`.
private struct FailingStagingFileOps: InstructionStagingFileOps {
    func createProtectedFile(at url: URL) -> Bool { false }

    func protectionClass(at url: URL) -> FileProtectionType? { nil }

    func copyChunks(from source: URL, to destination: URL,
                    maxBytes: Int64, chunkBytes: Int) -> Result<Int64, InstructionImportError> {
        .failure(.writeFailed(.stagingFailed))
    }
}
