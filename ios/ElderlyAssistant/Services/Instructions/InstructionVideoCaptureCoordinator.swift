import Combine
import Foundation

/// C04 — the library picker seam (IF-16; design L2 §2.4, §3.5, §7.4).
///
/// The adapter presents the out-of-process system picker and owns no policy:
/// it never stages, validates, trims or decides. `makeStagedCopy` is invoked
/// on the main thread **inside** the system callback, before that callback
/// returns, because the URL the system hands over is valid only until then
/// (§7.4). `completion` is invoked exactly once on every path — picked,
/// cancelled, failed or dismissed — and always on the main thread.
///
/// T-010 supplies the production `PHPickerViewController` adapter; this unit
/// only declares the seam, so the whole capture suite runs without a device.
@MainActor
protocol InstructionVideoPicking: AnyObject {
    /// IF-16. `makeStagedCopy` runs synchronously inside the system callback
    /// and returns the staged draft (or a typed failure). `completion`
    /// receives that same result exactly once.
    func presentVideoPicker(
        makeStagedCopy: @escaping @MainActor (URL) -> Result<StagedInstructionVideo, InstructionImportError>,
        completion: @escaping @MainActor (Result<StagedInstructionVideo, InstructionImportError>) -> Void)

    /// Dismisses the presented picker. Idempotent.
    func dismiss()
}

/// C04 — the recorder seam (IF-17; design L2 §2.4, §3.5, §7.4).
///
/// The adapter presents the system camera recorder, caps its own capture at
/// `maximumDurationSeconds` (180 s, §9.1) and reports the chosen file through
/// the same callback-scoped staging contract as the picker. Permission
/// ordering is not its job: the coordinator has already resolved camera and
/// microphone before this is presented (§2.5.3, M-1). It never trims,
/// compresses, transcodes or previews.
@MainActor
protocol InstructionVideoRecording: AnyObject {
    /// IF-17. `makeStagedCopy` runs synchronously inside the recorder
    /// delegate callback, before it returns. `completion` is invoked exactly
    /// once on every path, on the main thread.
    func presentRecorder(
        maximumDurationSeconds: TimeInterval,
        quality: InstructionRecordingQuality,
        makeStagedCopy: @escaping @MainActor (URL) -> Result<StagedInstructionVideo, InstructionImportError>,
        completion: @escaping @MainActor (Result<StagedInstructionVideo, InstructionImportError>) -> Void)

    /// Dismisses the presented recorder. Idempotent.
    func dismiss()
}

/// C04 — the one-at-a-time capture state machine shared by the routine and
/// event editors (IF-28; design L2 §2.4, §7.3, §7.5, §11.3 J).
///
/// Responsibilities, and nothing else:
///
///  - **Single flight.** `pick()`/`record()` are refused while an attempt is
///    picking, recording or validating; the first operation's state, its
///    presenter and its staged draft are untouched (§7.3).
///  - **M-1 permission order.** Recording reads the camera first, requests it
///    only when undetermined, short-circuits on denial/restriction/
///    unavailability with zero microphone requests and no recorder, and reads
///    or requests the microphone only after the camera is usable (§2.5.3,
///    FR-RIE-025). The ordering itself lives in
///    `InstructionPermissionRequesting.prepareForRecording()`, so this file
///    cannot drift from the seam T-006 tested.
///  - **Validation.** A produced staged file goes to the importer; an
///    accepted value moves the state to `.ready`. Cancellation and validation
///    failure discard the staged bytes through the store and never hand an
///    accepted video to an editor.
///  - **Exactly-once consumption.** `consumeAccepted()` clears the state
///    before returning the value; a second call returns nil.
///  - **Honest events.** Exactly one `instruction_capture_permission` event
///    per denied/restricted/unavailable attempt and one
///    `instruction_media_import` outcome per resolved validation; a cancelled
///    attempt is silent (§6.4).
///
/// It owns no player, no preview, no autoplay, no audio-session activation,
/// no photo-library access and no transcode: the file imports only Combine
/// and Foundation, and `testReadyDoesNotStartPlayback` pins that at source.
///
/// **Typed failure payload (task-over-design note).** T-009's acceptance
/// criteria require a permission stop to surface as the `.failed` state,
/// carrying the typed `InstructionPermissionProblem`. Design L2 §2.4.3
/// instead keeps a denial "beside an idle sheet" with a separate
/// `permissionProblem` property. The task text is authoritative here, so
/// `.failed` carries `Failure`, a typed sum of the two ways an attempt can
/// stop; `permissionProblem` remains available as a computed view over the
/// state so the editor surface (T-018/T-023) can render the same plain line.
///
/// **Root (design-gap note).** §3.5's initializer omits the staging root,
/// but `InstructionVideoStore.stageSynchronously` requires one and a staged
/// value must carry it so a later commit can match the owner. The
/// coordinator is constructed per editor presentation (§2.18), so the root is
/// an immutable initializer parameter and cannot be forgotten per call.
@MainActor
final class InstructionVideoCaptureCoordinator: ObservableObject {

    /// Why an attempt stopped. Both cases are typed values; no string, no
    /// `NSError`, no OS description reaches the state.
    enum Failure: Equatable {
        /// A permission check stopped a recording attempt (M-1). The
        /// corresponding `instruction_capture_permission` event has already
        /// been emitted exactly once.
        case permission(InstructionPermissionProblem)
        /// The producer failed to stage, or the importer rejected the staged
        /// file. The corresponding `instruction_media_import` event has
        /// already been emitted exactly once.
        case importError(InstructionImportError)
    }

    /// The exact six states of the shared capture machine (design §3.5).
    /// `picking` and `recording` are the busy buckets for the two system
    /// surfaces; `validating` covers the asynchronous importer.
    enum State: Equatable {
        case idle
        case picking
        case recording
        case validating
        case ready(AcceptedInstructionVideo)
        case failed(Failure)
    }

    /// The current state. Every mutation happens on the main actor.
    @Published private(set) var state: State = .idle

    /// The permission problem carried by `.failed`, or nil. A computed view
    /// over the state, never a second stored source of truth, so "cleared by
    /// the next attempt or by dismissal" is structural.
    var permissionProblem: InstructionPermissionProblem? {
        guard case .failed(.permission(let problem)) = state else { return nil }
        return problem
    }

    /// The import failure carried by `.failed`, or nil. The editor maps it
    /// through `InstructionMessageKey.forImport`; the coordinator holds no
    /// copy itself (design §3.1 rule 7).
    var importFailure: InstructionImportError? {
        guard case .failed(.importError(let error)) = state else { return nil }
        return error
    }

    /// True while an attempt owns the single-flight slot.
    var isBusy: Bool {
        switch state {
        case .picking, .recording, .validating:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }

    /// The `.ready` payload, or nil. Ownership has not moved until
    /// `consumeAccepted()` is called.
    var accepted: AcceptedInstructionVideo? {
        guard case .ready(let accepted) = state else { return nil }
        return accepted
    }

    private let root: InstructionRoot
    private let store: InstructionVideoStore
    private let importer: InstructionVideoImporting
    private let permissions: InstructionPermissionRequesting
    private let makePicker: @MainActor () -> InstructionVideoPicking
    private let makeRecorder: @MainActor () -> InstructionVideoRecording
    private let configuration: InstructionCaptureConfiguration
    private let events: InstructionObservability
    private let probe: (URL) -> Result<InstructionVideoMetadata, InstructionImportError>
    private let now: () -> Date

    /// Per-attempt generation. Incremented by every attempt and by
    /// `cancel()`; a late callback or a late validation result from an older
    /// generation is ignored (and its bytes discarded) rather than allowed to
    /// resurrect a dismissed sheet.
    private var attemptId = 0
    private var attemptStartedAt: Date
    /// The staged draft this attempt produced, if any. Kept so `cancel()` can
    /// discard bytes the adapter produced but never completed, and so the
    /// validation-failure path can discard through the store defensively.
    private var stagedHandle: StagedInstructionVideo?
    private var picker: (any InstructionVideoPicking)?
    private var recorder: (any InstructionVideoRecording)?
    private var permissionTask: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?

    /// - Parameters:
    ///   - root: the staging root this editor session writes into
    ///     (`.routines` or `.events`). Immutable for the session.
    ///   - store: the one shared store the composition root owns.
    ///   - importer: IF-15's validate-only importer.
    ///   - permissions: IF-18's camera/microphone seam.
    ///   - makePicker / makeRecorder: lazily build the production adapters;
    ///     no system surface exists until the person asks for one.
    ///   - configuration: 3-minute / 200 MiB limits, quality and chunk size.
    ///   - events: the only instruction event writer (§6.4).
    ///   - probe: the synchronous pre-staging probe passed to the store.
    ///   - now: injected clock for `duration_ms`; production uses `Date.init`.
    init(root: InstructionRoot,
         store: InstructionVideoStore,
         importer: InstructionVideoImporting,
         permissions: InstructionPermissionRequesting,
         makePicker: @escaping @MainActor () -> InstructionVideoPicking,
         makeRecorder: @escaping @MainActor () -> InstructionVideoRecording,
         configuration: InstructionCaptureConfiguration,
         events: InstructionObservability,
         probe: @escaping (URL) -> Result<InstructionVideoMetadata, InstructionImportError>,
         now: @escaping () -> Date = Date.init) {
        self.root = root
        self.store = store
        self.importer = importer
        self.permissions = permissions
        self.makePicker = makePicker
        self.makeRecorder = makeRecorder
        self.configuration = configuration
        self.events = events
        self.probe = probe
        self.now = now
        self.attemptStartedAt = now()
    }

    // MARK: - IF-28: starting attempts

    /// Presents the library picker. Consulted permission-free by design: the
    /// library path still works after a camera or microphone denial (§2.4.3).
    /// Ignored while an attempt is in flight (§7.3).
    func pick() {
        guard !isBusy else { return }
        let attempt = beginAttempt()
        state = .picking
        let picker = makePicker()
        self.picker = picker
        picker.presentVideoPicker(
            makeStagedCopy: { [weak self] sourceURL in
                guard let self else { return .failure(.cancelled) }
                return self.stage(sourceURL, attempt: attempt)
            },
            completion: { [weak self] outcome in
                self?.handleCaptureOutcome(outcome, attempt: attempt)
            })
    }

    /// Starts a recording attempt. The camera is resolved before the
    /// microphone and before any recorder exists (M-1). Ignored while an
    /// attempt is in flight (§7.3).
    ///
    /// The state is `.recording` while the permission sequence runs, so a
    /// second `record()` or `pick()` cannot slip in during a system prompt.
    func record() {
        guard !isBusy else { return }
        let attempt = beginAttempt()
        state = .recording
        permissionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let problem = await self.permissions.prepareForRecording()
            guard self.isCurrent(attempt) else { return }
            if let problem {
                await self.finishPermissionStop(problem, attempt: attempt)
            } else {
                self.presentRecorder(attempt: attempt)
            }
            if self.isCurrent(attempt) {
                self.permissionTask = nil
            }
        }
    }

    // MARK: - IF-28: teardown

    /// Dismisses whatever system surface is presented, discards any staged
    /// bytes this attempt can name, and returns to `.idle` with no event
    /// (§7.5). Callable in every state; safe to call twice.
    func cancel() {
        invalidateAttempt()
        permissionTask?.cancel()
        permissionTask = nil
        validationTask?.cancel()
        validationTask = nil
        picker?.dismiss()
        picker = nil
        recorder?.dismiss()
        recorder = nil
        discardStagedHandle()
        if case .ready(let accepted) = state {
            _ = store.discard(accepted.staged)
        }
        state = .idle
    }

    /// Transfers ownership of the accepted staged bytes to the editor and
    /// clears the state **before** returning, so a double tap cannot save the
    /// same draft twice. A second call returns nil.
    func consumeAccepted() -> AcceptedInstructionVideo? {
        guard case .ready(let accepted) = state else { return nil }
        state = .idle
        // The host owns the bytes now: teardown must not delete them.
        stagedHandle = nil
        return accepted
    }

    /// Discards the accepted staged bytes through the store and returns to
    /// `.idle` (§7.5). A discard failure is best-effort: the owner no longer
    /// names the bytes and the launch sweep collects them (§5.5).
    func discardAccepted() {
        guard case .ready(let accepted) = state else { return }
        _ = store.discard(accepted.staged)
        stagedHandle = nil
        state = .idle
    }

    // MARK: - The attempt lifecycle

    /// Claims the single-flight slot for a new attempt. Any adapter or bytes
    /// left over from a previous, already-finished attempt are torn down
    /// first, so a `.ready` value that was never consumed cannot leak a
    /// `_pending` directory when the person chooses again.
    @discardableResult
    private func beginAttempt() -> Int {
        attemptId &+= 1
        permissionTask?.cancel()
        permissionTask = nil
        validationTask?.cancel()
        validationTask = nil
        picker?.dismiss()
        picker = nil
        recorder?.dismiss()
        recorder = nil
        discardStagedHandle()
        if case .ready(let accepted) = state {
            _ = store.discard(accepted.staged)
        }
        attemptStartedAt = now()
        return attemptId
    }

    private func invalidateAttempt() {
        attemptId &+= 1
    }

    private func isCurrent(_ attempt: Int) -> Bool {
        attempt == attemptId
    }

    /// IF-5 runs synchronously inside the system callback (the
    /// callback-scoped URL rule, §7.4). A stale callback stages nothing and
    /// reports cancellation to the adapter.
    private func stage(_ sourceURL: URL,
                       attempt: Int) -> Result<StagedInstructionVideo, InstructionImportError> {
        guard isCurrent(attempt) else { return .failure(.cancelled) }
        let result = store.stageSynchronously(
            from: sourceURL,
            into: root,
            limits: configuration.video.limits,
            chunkBytes: configuration.video.stagingChunkBytes,
            probe: probe)
        if case .success(let staged) = result {
            stagedHandle = staged
        }
        return result
    }

    /// Resolves the permission sequence's stop into exactly one permission
    /// event and the typed `.failed` state.
    ///
    /// `prepareForRecording()` collapses denied and restricted into
    /// `cameraDenied`/`microphoneDenied` (the person sees the same plain
    /// line), but the event catalogue distinguishes the closed `state`
    /// tokens. The failing permission is therefore read once more — a status
    /// read never prompts — so `restricted` is reported honestly. Nothing is
    /// requested a second time and the microphone is never read after a
    /// camera stop.
    private func finishPermissionStop(_ problem: InstructionPermissionProblem,
                                      attempt: Int) async {
        let permission: InstructionMediaPermission
        switch problem {
        case .cameraDenied, .cameraUnavailable:
            permission = .camera
        case .microphoneDenied:
            permission = .microphone
        }
        let reported = await permissions.status(for: permission)
        guard isCurrent(attempt) else { return }
        events.permission(Self.eventState(reported, for: problem), permission: permission)
        state = .failed(.permission(problem))
    }

    private func presentRecorder(attempt: Int) {
        guard isCurrent(attempt) else { return }
        let recorder = makeRecorder()
        self.recorder = recorder
        recorder.presentRecorder(
            maximumDurationSeconds: configuration.video.limits.maxDurationSeconds,
            quality: configuration.recordingQuality,
            makeStagedCopy: { [weak self] sourceURL in
                guard let self else { return .failure(.cancelled) }
                return self.stage(sourceURL, attempt: attempt)
            },
            completion: { [weak self] outcome in
                self?.handleCaptureOutcome(outcome, attempt: attempt)
            })
    }

    /// The adapter's one completion. A stale completion discards whatever
    /// staged bytes it carries and changes nothing else — least of all the
    /// *current* attempt's presenter references.
    private func handleCaptureOutcome(_ outcome: Result<StagedInstructionVideo, InstructionImportError>,
                                      attempt: Int) {
        guard isCurrent(attempt) else {
            if case .success(let staged) = outcome {
                _ = store.discard(staged)
            }
            return
        }

        // The system surface has finished with this attempt.
        picker = nil
        recorder = nil

        switch outcome {
        case .failure(.cancelled):
            // Cancellation is not a failure: no event, no copy (§6.1 rule 3).
            discardStagedHandle()
            state = .idle
        case .failure(let error):
            // Staging failed; the store has already removed what it created.
            // It is still an import attempt for the catalogue (§6.2).
            discardStagedHandle()
            emitImportFailure(error)
            state = .failed(.importError(error))
        case .success(let staged):
            stagedHandle = staged
            state = .validating
            validate(staged, attempt: attempt)
        }
    }

    private func validate(_ staged: StagedInstructionVideo, attempt: Int) {
        validationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.importer.validate(staged,
                                                      limits: self.configuration.video.limits)
            guard self.isCurrent(attempt) else {
                // `cancel()` won the race. Never hand an accepted video to an
                // editor after teardown; discard whatever the importer left.
                if case .success(let accepted) = result {
                    _ = self.store.discard(accepted.staged)
                }
                return
            }
            switch result {
            case .success(let accepted):
                self.stagedHandle = nil
                self.events.mediaImport(
                    outcome: .accepted,
                    kind: Self.videoKind,
                    durationMs: self.elapsedMilliseconds(since: self.attemptStartedAt),
                    error: nil)
                self.state = .ready(accepted)
            case .failure(let error):
                // The importer discards on failure by contract (IF-15); the
                // coordinator discards defensively so a non-conforming double
                // (or a future change) can never leak `_pending` bytes.
                _ = self.store.discard(staged)
                self.stagedHandle = nil
                if error == .cancelled {
                    self.state = .idle
                } else {
                    self.emitImportFailure(error)
                    self.state = .failed(.importError(error))
                }
            }
            self.validationTask = nil
        }
    }

    // MARK: - Events and helpers

    /// One `instruction_media_import` failed event. `InstructionObservability`
    /// suppresses the `.cancelled` case by contract; callers never reach here
    /// with it.
    private func emitImportFailure(_ error: InstructionImportError) {
        events.mediaImport(outcome: .failed,
                           kind: Self.videoKind,
                           durationMs: 0,
                           error: error)
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        let elapsed = now().timeIntervalSince(start)
        guard elapsed.isFinite else { return 0 }
        return Int(max(0, elapsed) * 1000)
    }

    private func discardStagedHandle() {
        guard let staged = stagedHandle else { return }
        stagedHandle = nil
        _ = store.discard(staged)
    }

    /// The permission event's `state` is one of the closed tokens
    /// `denied`/`restricted`/`unavailable` (§6.4). A status that can no longer
    /// explain the stop (an undetermined request or a racing grant) falls
    /// back to the problem's own denial token.
    private static func eventState(_ status: InstructionPermissionStatus,
                                   for problem: InstructionPermissionProblem) -> InstructionPermissionStatus {
        switch status {
        case .denied, .restricted, .unavailable:
            return status
        case .granted, .undetermined:
            switch problem {
            case .cameraUnavailable:
                return .unavailable
            case .cameraDenied, .microphoneDenied:
                return .denied
            }
        }
    }

    /// The closed event kind: `"video"`, normalised through the model's
    /// `reportable` vocabulary at the emitter boundary (§6.4).
    private static let videoKind = InstructionKind.video.rawValue
}
