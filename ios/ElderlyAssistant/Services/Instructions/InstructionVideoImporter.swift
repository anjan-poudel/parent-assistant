import Foundation

/// IF-15 — the validate-only importer (design L2 §2.3 C03, §3.5, §9.2;
/// FR-RIE-004/006/010/011, NFR-RIE-009).
///
/// The picker or recorder has already produced the staged copy through
/// `InstructionVideoStore.stageSynchronously` (IF-5). This unit never
/// copies, stages or re-encodes those bytes again: it validates the file
/// that exists, in the fixed order cheap file facts → byte cap →
/// synchronous probe → bounded asynchronous inspection, and on **any**
/// failure it discards the staged draft through the store before
/// returning, so a rejected pick never lingers.
///
/// The asynchronous inspection is bounded by
/// `InstructionVideoConfiguration.validationTimeoutSeconds` (20 s,
/// §9.1). The inspector and the deadline run as two structured child
/// tasks; the first answer wins and the losing task is cancelled and
/// awaited before `validate` returns. Nothing is detached, so no task
/// outlives the call.
///
/// The importer owns no logging and emits no events — the capture
/// coordinator owns the single `instruction_media_import` emission
/// (§6.4, T-009). Every failure leaves this file as an
/// `InstructionImportError` case; no `NSError`, error domain or
/// description escapes.
protocol InstructionVideoImporting: Sendable {
    /// IF-15. Validates a staged file. On any failure the staged bytes are
    /// discarded before returning; the caller never has to.
    func validate(_ staged: StagedInstructionVideo,
                  limits: InstructionVideoLimits) async -> Result<AcceptedInstructionVideo, InstructionImportError>
}

extension InstructionVideoImporting {
    /// The picker/recorder completion hands its staging outcome straight to
    /// the importer (T-008's staging-failure scenario). A staging failure is
    /// returned **unchanged** — the store already removed what it created
    /// and there is nothing to accept or discard — while a staged value
    /// follows the normal validation path.
    ///
    /// This is a protocol extension, not a second requirement: existing
    /// conformers implement only IF-15's `validate(_:limits:)`. The typed
    /// `InstructionStorageError` crosses the boundary without remapping;
    /// nothing is accepted on a failure.
    func validate(_ stagingOutcome: Result<StagedInstructionVideo, InstructionImportError>,
                  limits: InstructionVideoLimits) async -> Result<AcceptedInstructionVideo, InstructionImportError> {
        switch stagingOutcome {
        case .failure(let error):
            return .failure(error)
        case .success(let staged):
            return await validate(staged, limits: limits)
        }
    }
}

/// C03's importer. Nonisolated and `Sendable` (design §7.1): it holds only
/// immutable injected collaborators, and the validation body runs off the
/// main thread, where the asynchronous inspection belongs (§9.2).
///
/// `prober` is an addition to design §3.5's declared initializer, required
/// by T-008's fixed order ("cheap file checks, byte cap, synchronous probe,
/// then async inspect"). It has a production default, so the design's
/// `InstructionVideoImporter(store:inspector:configuration:deadline:now:)`
/// call site remains source-compatible; see the T-008 notes for the
/// conflict record. The probe re-reads metadata from the bytes that
/// actually landed in `_pending`, which is cheap and catches a staged copy
/// that does not match the source the pre-staging probe saw.
final class InstructionVideoImporter: InstructionVideoImporting {

    /// Exactly one of these crosses the task-group boundary per call.
    private enum InspectionRace: Sendable {
        case inspected(Result<InstructionVideoMetadata, InstructionImportError>)
        case timedOut
    }

    private let store: InstructionVideoStore
    private let prober: InstructionVideoProbing
    private let inspector: InstructionVideoInspecting
    private let configuration: InstructionVideoConfiguration
    private let deadline: @Sendable (TimeInterval) async -> Void
    private let now: @Sendable () -> Date

    init(store: InstructionVideoStore,
         inspector: InstructionVideoInspecting,
         configuration: InstructionVideoConfiguration,
         prober: InstructionVideoProbing = AVInstructionVideoProber(),
         deadline: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
             await InstructionVideoImporter.sleep(seconds: seconds)
         },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.prober = prober
        self.inspector = inspector
        self.configuration = configuration
        self.deadline = deadline
        self.now = now
    }

    /// The production deadline (§9.2). `Task.sleep` is cancellation aware,
    /// so a winning inspection wakes the losing deadline immediately
    /// instead of holding the call for the full bound.
    static func sleep(seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        // Bounded so a nonsensical injected value cannot overflow UInt64.
        let clamped = min(seconds, 3_600)
        try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
    }

    // MARK: - IF-15

    func validate(_ staged: StagedInstructionVideo,
                  limits: InstructionVideoLimits) async -> Result<AcceptedInstructionVideo, InstructionImportError> {
        // Cancellation is a normal outcome, never a failure line (§2.4.4).
        if Task.isCancelled { return discard(staged, .cancelled) }

        // 1–2. Cheap file facts, then the byte cap — strictly greater is
        // too large, the cap itself is allowed. Both run before any
        // AVFoundation work, mirroring the store's ordering (§5.2).
        if let problem = stagedFileProblem(staged, limits: limits) {
            return discard(staged, problem)
        }

        // 3. The synchronous probe of the bytes that actually landed.
        let probed: InstructionVideoMetadata
        switch prober.probe(url: staged.stagedURL) {
        case .success(let metadata):
            probed = metadata
        case .failure(let error):
            return discard(staged, error)
        }
        if let problem = metadataProblem(probed, limits: limits) {
            return discard(staged, problem)
        }
        if Task.isCancelled { return discard(staged, .cancelled) }

        // 4. The bounded asynchronous inspection — the second check.
        let race = await raceInspection(url: staged.stagedURL)
        if Task.isCancelled { return discard(staged, .cancelled) }

        switch race {
        case .timedOut:
            return discard(staged, .validationTimedOut)
        case .inspected(.failure(let error)):
            return discard(staged, error)
        case .inspected(.success(let metadata)):
            if let problem = metadataProblem(metadata, limits: limits) {
                return discard(staged, problem)
            }
        }

        // Accepted: the caller owns the staged bytes from here (commit or
        // discard), so the importer must not discard them.
        return .success(AcceptedInstructionVideo(staged: staged, validatedAt: now()))
    }

    // MARK: - The bounded race (§9.2)

    /// Runs the inspector and the deadline as structured child tasks. The
    /// first answer wins; `cancelAll()` cancels the loser and the group's
    /// scope awaits its teardown before this function returns — a lost
    /// inspection cannot outlive the call.
    private func raceInspection(url: URL) async -> InspectionRace {
        await withTaskGroup(of: InspectionRace.self) { group in
            group.addTask { [inspector] in
                .inspected(await inspector.inspect(url: url))
            }
            group.addTask { [deadline, timeout = configuration.validationTimeoutSeconds] in
                await deadline(timeout)
                return .timedOut
            }
            guard let first = await group.next() else { return .timedOut }
            group.cancelAll()
            return first
        }
    }

    // MARK: - Checks

    /// The cheap, pre-AVFoundation facts: file URL, present, not a
    /// directory, readable, stat-able, and within the byte cap.
    private func stagedFileProblem(_ staged: StagedInstructionVideo,
                                   limits: InstructionVideoLimits) -> InstructionImportError? {
        let url = staged.stagedURL
        guard url.isFileURL else { return .unreadableSource }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            return .unreadableSource
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else {
            return .unreadableSource
        }
        // The recorded step-2 size and the bytes now on disk are both
        // checked; strictly greater is too large.
        if staged.byteCount > limits.maxBytes || size > limits.maxBytes {
            return .tooLarge
        }
        return nil
    }

    /// The metadata judgement shared by both checks (§5.2 step 3): playable
    /// and carrying a video track, a finite duration, and the inclusive
    /// 180-second cap judged on rounded whole seconds (N-10). The rounding
    /// is `InstructionVideoDuration`'s, the same arithmetic the store uses,
    /// so 179.6 s rounds to 180 and is accepted.
    private func metadataProblem(_ metadata: InstructionVideoMetadata,
                                 limits: InstructionVideoLimits) -> InstructionImportError? {
        guard metadata.isPlayable, metadata.hasVideoTrack else { return .unsupportedFormat }
        guard metadata.durationSeconds.isFinite else { return .unreadableSource }
        if InstructionVideoDuration.exceedsLimit(metadata.durationSeconds,
                                                 limit: limits.maxDurationSeconds) {
            return .tooLong
        }
        return nil
    }

    /// Every failure after a staged handle exists discards the draft before
    /// returning (IF-15). The discard is best-effort: its own failure is not
    /// this call's primary error, and the launch sweep removes anything
    /// left behind (§5.5).
    private func discard(_ staged: StagedInstructionVideo,
                         _ error: InstructionImportError) -> Result<AcceptedInstructionVideo, InstructionImportError> {
        _ = store.discard(staged)
        return .failure(error)
    }
}
