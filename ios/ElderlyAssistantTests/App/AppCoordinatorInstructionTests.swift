import XCTest
import UniformTypeIdentifiers
@testable import ElderlyAssistant

/// T-022 — the coordinator's instruction composition half (design-l2
/// §2.15, §2.18, IF-32; C15).
///
/// Two kinds of proof live here:
/// - **behaviour**: the two save seams return exactly what the owning
///   service answered, the ONE shared video store is what every consumer
///   holds, the capture coordinator is per-editor-session, and the three
///   factories build the production adapters without starting anything;
/// - **source pins** (`FeatureSourceScan.codeText`, comments stripped):
///   the composition section never performs file IO, never registers a
///   timer/notification/permission request, never names a network,
///   transcode or photo-library adapter, and no view reaches a store.
///
/// The save seams are exercised through the coordinator's internal
/// `routineInstructionWriter` / `freeFormEventSaver` targets — the minimal
/// factory seam the task sanctions — so no unit test opens the encrypted
/// routine store, EventKit or Google. Production's initial values are the
/// real services; a test replaces them *before* first access, so the lazy
/// initializers never run.
@MainActor
final class AppCoordinatorInstructionTests: XCTestCase {

    // MARK: - Doubles

    /// Raw in-memory stand-in for the encrypted channel, so constructing
    /// the coordinator opens no Keychain or encrypted file.
    private final class InMemoryProfilePayloadStorage: ProfilePayloadStorage {
        var payloads: [String: Data] = [:]
        private let encoder = JSONEncoder()

        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            guard let data = try? encoder.encode(value) else {
                return .failure(.encryptedWriteFailed)
            }
            payloads[key] = data
            return .success(())
        }

        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            .failure(.encryptedReadFailed)   // this fake is raw-read only
        }

        func delete(key: String) -> Result<Void, StorageError> {
            payloads[key] = nil
            return .success(())
        }

        func readRawData(key: String) -> Data? { payloads[key] }
        func hasPayload(key: String) -> Bool? { payloads[key] != nil }
    }

    /// Records the exact commit/owner pair and answers an injected result —
    /// the scheduler's `Result` must reach the caller unchanged.
    private final class RecordingRoutineInstructionWriter: RoutineInstructionWriting {
        var result: Result<Void, InstructionWriteError> = .success(())
        private(set) var commits: [InstructionCommit] = []
        private(set) var entryIds: [UUID] = []

        func setInstruction(_ commit: InstructionCommit,
                            entryId: UUID) -> Result<Void, InstructionWriteError> {
            commits.append(commit)
            entryIds.append(entryId)
            return result
        }
    }

    /// Records the form and editing id, answers an injected outcome, and
    /// records the bridge's read-back. No EventKit is constructed.
    private final class RecordingFreeFormEventSaver: FreeFormEventSaving {
        var outcome: FreeFormEventSaveOutcome?
        var savedEvent: FreeFormEvent?
        private(set) var forms: [FreeFormEventForm] = []
        private(set) var editingIds: [String?] = []
        private(set) var readBackIds: [String] = []

        func save(_ form: FreeFormEventForm,
                  editing eventId: String?) -> FreeFormEventSaveOutcome? {
            forms.append(form)
            editingIds.append(eventId)
            return outcome
        }

        func event(withId eventId: String) -> FreeFormEvent? {
            readBackIds.append(eventId)
            return savedEvent
        }
    }

    /// T-025's launch-sweep seam: records each of the two purge operations
    /// with its exact arguments and answers scripted results, so the sweep
    /// contract is provable without touching a real instruction root.
    private final class RecordingInstructionSweeper: InstructionOrphanSweeping {
        struct OrphanCall: Equatable {
            let root: InstructionRoot
            let live: Set<InstructionOwner>?
            let graceSeconds: TimeInterval
        }

        private let lock = NSLock()
        private var pendingDraftCalls = 0
        private var orphanCallLog: [OrphanCall] = []

        var pendingResult: Result<Int, InstructionStorageError> = .success(0)
        var orphanResult: (InstructionRoot) -> Result<Int, InstructionStorageError> =
            { _ in .success(0) }
        /// Fired after every recorded call, on the thread that drove the
        /// sweep — the launch-once test waits for exactly three.
        var onCall: (() -> Void)?

        var pendingDraftCallCount: Int {
            lock.lock(); defer { lock.unlock() }
            return pendingDraftCalls
        }

        var orphanCalls: [OrphanCall] {
            lock.lock(); defer { lock.unlock() }
            return orphanCallLog
        }

        func purgePendingDrafts() -> Result<Int, InstructionStorageError> {
            lock.lock()
            pendingDraftCalls += 1
            lock.unlock()
            onCall?()
            return pendingResult
        }

        func purgeOrphanedOwners(in root: InstructionRoot,
                                 live: Set<InstructionOwner>?,
                                 graceSeconds: TimeInterval) -> Result<Int, InstructionStorageError> {
            lock.lock()
            orphanCallLog.append(OrphanCall(root: root,
                                            live: live,
                                            graceSeconds: graceSeconds))
            lock.unlock()
            onCall?()
            return orphanResult(root)
        }
    }

    // MARK: - Helpers

    private func makeCoordinator() -> AppCoordinator {
        AppCoordinator(profileStorage: InMemoryProfilePayloadStorage())
    }

    private func textCommit(_ text: String = "Take the blue pill") -> InstructionCommit {
        InstructionCommit(write: .set(InstructionPayload(kind: .text, text: text)),
                          pendingMedia: nil)
    }

    private func eventForm() -> FreeFormEventForm {
        var form = FreeFormEventForm(startDate: Date(timeIntervalSince1970: 1_000_000))
        form.title = "Doctor visit"
        form.notes = "Bring the blue folder"
        form.address = "Teaching Hospital"
        return form
    }

    /// The comment-stripped text of the whole coordinator.
    private func coordinatorSource() -> String {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/AppCoordinator.swift")
        return FeatureSourceScan.codeText(of: url)
    }

    /// The T-022 composition section: from the ONE store declaration to the
    /// first extension after the class body. Slicing this way keeps the
    /// pins scoped to what this unit added.
    private func instructionSection() -> String {
        let source = coordinatorSource()
        guard let start = source.range(of: "let instructionVideoStore = InstructionVideoStore()") else {
            XCTFail("the instruction composition section is missing from AppCoordinator")
            return ""
        }
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: "\nextension AppCoordinator") else {
            XCTFail("the instruction section has no extension terminator")
            return ""
        }
        return String(rest[..<end.lowerBound])
    }

    /// A method body by name, up to the next method declaration.
    private func methodRegion(_ name: String, in source: String) -> String {
        guard let start = source.range(of: "func \(name)") else {
            XCTFail("missing method \(name)")
            return ""
        }
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: "\n    func ") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    private func stored<T>(_ name: String, of object: Any, as type: T.Type) -> T? {
        Mirror(reflecting: object).children.first { $0.label == name }?.value as? T
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }

    /// A slice of the comment-stripped coordinator between two CODE markers
    /// (comments are stripped, so `// MARK:` strings never match).
    private func sourceSlice(from startMarker: String,
                             to endMarker: String) -> String {
        let source = coordinatorSource()
        guard let start = source.range(of: startMarker) else {
            XCTFail("missing source marker \(startMarker)")
            return ""
        }
        guard let end = source.range(of: endMarker,
                                     range: start.upperBound..<source.endIndex) else {
            XCTFail("missing end marker \(endMarker)")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    /// A routine fixture. `titleOverride` keeps the localized title
    /// deterministic (no catalogue lookup needed in assertions).
    private func makeEntry(id: UUID = UUID(),
                           instruction: Instruction? = nil,
                           aids: [VisualAid] = []) -> RoutineEntry {
        RoutineEntry(id: id,
                     category: .walk,
                     titleOverride: "Evening walk",
                     scheduleTimes: [DateComponents(hour: 17, minute: 30)],
                     isEnabled: true,
                     visualAids: aids,
                     instruction: instruction)
    }

    private func videoInstruction(filename: String? = "instruction-video.mov")
    -> Instruction {
        Instruction(kind: InstructionKind.video.rawValue,
                    caption: "Watch this",
                    filename: filename)
    }

    private let fixedFiredAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - IF-32: the routine save seam

    func testSaveRoutineInstructionDelegatesCommit() {
        let coordinator = makeCoordinator()
        let writer = RecordingRoutineInstructionWriter()
        coordinator.routineInstructionWriter = writer
        let entryId = UUID()
        let commit = textCommit()

        let result = coordinator.saveRoutineInstruction(commit, entryId: entryId)

        switch result {
        case .success:
            break
        case .failure(let error):
            return XCTFail("expected success, got \(error)")
        }
        XCTAssertEqual(writer.commits, [commit],
                       "the commit must reach the scheduler exactly once and unchanged")
        XCTAssertEqual(writer.entryIds, [entryId],
                       "the owner id must reach the scheduler exactly once and unchanged")

        // The seam is a pure pass-through: one delegation statement, no
        // second transaction and no success fallback in the coordinator.
        let body = methodRegion("saveRoutineInstruction", in: instructionSection())
        XCTAssertTrue(body.contains("routineInstructionWriter.setInstruction(commit, entryId: entryId)"),
                      "the coordinator must delegate exactly to the scheduler's setInstruction")
        XCTAssertFalse(body.contains("instructionVideoStore.commit"),
                       "the coordinator must not commit video bytes itself")
        XCTAssertFalse(body.contains("persist"),
                       "the coordinator must not duplicate the scheduler's transaction")
    }

    func testSaveRoutineInstructionReturnsFailure() {
        let coordinator = makeCoordinator()
        let writer = RecordingRoutineInstructionWriter()
        coordinator.routineInstructionWriter = writer
        let entryId = UUID()
        let commit = textCommit()

        let failures: [InstructionWriteError] = [
            .ownerNotFound,
            .unresolvedPayload,
            .mediaWriteFailed(.stagingFailed),
            .persistenceFailed
        ]
        for failure in failures {
            writer.result = .failure(failure)
            let result = coordinator.saveRoutineInstruction(commit, entryId: entryId)
            switch result {
            case .success:
                XCTFail("\(failure) must not be reported as a save")
            case .failure(let error):
                XCTAssertEqual(error, failure,
                               "the scheduler's typed failure must reach the editor unchanged")
            }
        }
        XCTAssertEqual(writer.commits.count, failures.count,
                       "every attempt is delegated; none is swallowed")
    }

    // MARK: - IF-25/IF-32: the event save seam

    func testSaveFreeFormEventDelegatesFormAndId() {
        let coordinator = makeCoordinator()
        let saver = RecordingFreeFormEventSaver()
        saver.outcome = FreeFormEventSaveOutcome(eventId: "event-1", instructionSaved: true)
        coordinator.freeFormEventSaver = saver
        let form = eventForm()

        let edited = coordinator.saveFreeFormEvent(form, editing: "event-1")
        let created = coordinator.saveFreeFormEvent(form, editing: nil)

        XCTAssertEqual(edited, saver.outcome,
                       "the service's outcome is returned unchanged")
        XCTAssertEqual(created, saver.outcome)
        XCTAssertEqual(saver.forms, [form, form],
                       "the form reaches the service unchanged")
        XCTAssertEqual(saver.editingIds, ["event-1", nil],
                       "the editing id is passed through verbatim, nil included")
        XCTAssertEqual(saver.readBackIds, ["event-1", "event-1"],
                       "the Google bridge reconciles from a read-back of what was saved")

        // The bridge side effect is kept on this exact path for create and
        // edit alike (design §3); losing it would stop the family's copy
        // from ever hearing about a new or moved appointment.
        let body = methodRegion("saveFreeFormEvent", in: coordinatorSource())
        XCTAssertTrue(body.contains("calendarShareService.eventCreated(localEventId: outcome.eventId"),
                      "the Google-bridge reconcile must remain a caller-side side effect")
    }

    func testSaveFreeFormEventReturnsPartialOutcome() {
        let coordinator = makeCoordinator()
        let saver = RecordingFreeFormEventSaver()
        let partial = FreeFormEventSaveOutcome(eventId: "event-2", instructionSaved: false)
        saver.outcome = partial
        coordinator.freeFormEventSaver = saver
        let form = eventForm()

        let outcome = coordinator.saveFreeFormEvent(form, editing: "event-2")

        XCTAssertEqual(outcome, partial,
                       "an event saved with an instruction failure is an honest partial result")
        XCTAssertFalse(outcome?.instructionSaved ?? true,
                       "the Boolean must not be flattened to 'saved'")
        XCTAssertEqual(outcome?.eventId, "event-2")

        // nil still means "nothing was written" and passes through.
        saver.outcome = nil
        XCTAssertNil(coordinator.saveFreeFormEvent(form, editing: nil),
                     "a service refusal must stay nil, not become a synthetic outcome")

        // The return type is the typed outcome, not a Boolean or the old
        // String? bridge.
        let signature = methodRegion("saveFreeFormEvent", in: coordinatorSource())
        XCTAssertTrue(signature.contains("-> FreeFormEventSaveOutcome?"),
                      "the coordinator reports the service's typed outcome")
        XCTAssertFalse(signature.contains("-> Bool"),
                       "a Boolean would lose the partial-outcome distinction")
    }

    // MARK: - The ONE shared store

    func testVideoStoreIsOneSharedInstance() {
        let coordinator = makeCoordinator()
        let store = coordinator.instructionVideoStore

        XCTAssertTrue(store === coordinator.instructionVideoStore,
                      "the property must answer the same instance every time")

        let importer = coordinator.instructionVideoImporter
        guard let importerStore = stored("store", of: importer, as: InstructionVideoStore.self) else {
            return XCTFail("the importer must hold the shared store")
        }
        XCTAssertTrue(importerStore === store,
                      "the importer validates files for the store that will commit them")

        let routineCoordinator = coordinator.instructionCaptureCoordinator(draftSession: .routines)
        let eventCoordinator = coordinator.instructionCaptureCoordinator(draftSession: .events)
        guard let routineStore = stored("store", of: routineCoordinator, as: InstructionVideoStore.self),
              let eventStore = stored("store", of: eventCoordinator, as: InstructionVideoStore.self) else {
            return XCTFail("both capture coordinators must hold the shared store")
        }
        XCTAssertTrue(routineStore === store, "routine captures stage into the ONE store")
        XCTAssertTrue(eventStore === store, "event captures stage into the ONE store")

        // One construction site in the coordinator, and both owner services
        // are given that same instance (design-l2 §2.18). A second
        // `InstructionVideoStore()` anywhere here would break the shared
        // instance invariant the sweep and availability read rely on.
        let source = coordinatorSource()
        XCTAssertEqual(occurrences(of: "InstructionVideoStore()", in: source), 1,
                       "the coordinator must construct exactly one video store")
        XCTAssertEqual(occurrences(of: "instructionVideoStore: instructionVideoStore", in: source), 2,
                       "the routine scheduler and the event service must both receive the shared store")
    }

    func testCaptureCoordinatorUsesSharedStore() {
        let coordinator = makeCoordinator()
        let routine = coordinator.instructionCaptureCoordinator(draftSession: .routines)
        let event = coordinator.instructionCaptureCoordinator(draftSession: .events)

        XCTAssertFalse(routine === event,
                       "each editor gets its own per-session state machine")

        guard let routineRoot = stored("root", of: routine, as: InstructionRoot.self),
              let eventRoot = stored("root", of: event, as: InstructionRoot.self) else {
            return XCTFail("a capture coordinator must carry its draft session root")
        }
        XCTAssertEqual(routineRoot, .routines)
        XCTAssertEqual(eventRoot, .events)

        guard let routineStore = stored("store", of: routine, as: InstructionVideoStore.self),
              let eventStore = stored("store", of: event, as: InstructionVideoStore.self) else {
            return XCTFail("a capture coordinator must hold the shared store")
        }
        XCTAssertTrue(routineStore === coordinator.instructionVideoStore)
        XCTAssertTrue(eventStore === coordinator.instructionVideoStore)
        XCTAssertTrue(routineStore === eventStore,
                      "both editor sessions are bound to the ONE store instance")

        // No system surface exists at coordinator construction: the picker
        // and recorder arrive as closures and are invoked only by the
        // editor's pick/record action.
        let body = methodRegion("instructionCaptureCoordinator", in: instructionSection())
        XCTAssertTrue(body.contains("makePicker: { self.makeInstructionVideoPicker() }"),
                      "the picker arrives lazily through the factory closure")
        XCTAssertTrue(body.contains("makeRecorder: { self.makeInstructionVideoRecorder() }"),
                      "the recorder arrives lazily through the factory closure")
        XCTAssertFalse(body.contains("PHPickerInstructionVideoPicker("),
                       "the capture coordinator must not be built with a picker")
        XCTAssertFalse(body.contains("UIImagePickerInstructionVideoRecorder("),
                       "the capture coordinator must not be built with a recorder")
    }

    // MARK: - The lazy factories

    func testPickerFactoryReturnsPHPickerAdapter() {
        let coordinator = makeCoordinator()

        let first = coordinator.makeInstructionVideoPicker()
        let second = coordinator.makeInstructionVideoPicker()

        XCTAssertTrue(first is PHPickerInstructionVideoPicker,
                      "the production picker is the out-of-process PHPicker adapter")
        XCTAssertTrue(second is PHPickerInstructionVideoPicker)
        XCTAssertFalse((first as AnyObject) === (second as AnyObject),
                       "each presentation gets its own adapter and session")
        XCTAssertEqual(PHPickerInstructionVideoPicker.makeConfiguration().filter, .videos,
                       "the picker stays video-only")
        XCTAssertEqual(PHPickerInstructionVideoPicker.makeConfiguration().selectionLimit, 1)
    }

    func testRecorderFactoryReturnsCameraAdapter() {
        let coordinator = makeCoordinator()

        let first = coordinator.makeInstructionVideoRecorder()
        let second = coordinator.makeInstructionVideoRecorder()

        XCTAssertTrue(first is UIImagePickerInstructionVideoRecorder,
                      "the production recorder is the camera adapter")
        XCTAssertTrue(second is UIImagePickerInstructionVideoRecorder)
        XCTAssertFalse((first as AnyObject) === (second as AnyObject),
                       "each presentation gets its own adapter and session")

        let capture = coordinator.instructionCaptureConfiguration
        let configuration = UIImagePickerInstructionVideoRecorder.configuration(
            maximumDurationSeconds: capture.video.limits.maxDurationSeconds,
            quality: capture.recordingQuality)
        XCTAssertEqual(configuration.maximumDurationSeconds, 180,
                       "the production recorder is capped at the configured three minutes")
        XCTAssertEqual(configuration.sourceType, .camera,
                       "the recorder is the camera, never a library surface")
        XCTAssertEqual(configuration.cameraCaptureMode, .video)
        XCTAssertEqual(configuration.mediaTypes, [UTType.movie.identifier],
                       "the recorder asks for the movie media type only")
    }

    func testPlaybackFactoryReturnsControllerWithoutStarting() {
        let coordinator = makeCoordinator()
        let url = URL(fileURLWithPath: "/tmp/t022-instruction-playback.mov")

        let controller = coordinator.makeInstructionPlayback(url: url, title: "How to take it")

        XCTAssertEqual(controller.state, .idle,
                       "construction performs no preflight and presents no player")
        XCTAssertNil(controller.player,
                     "no AVPlayer exists before the person taps Play")
        XCTAssertEqual(controller.title, "How to take it")

        // The factory must never call start(): the person's tap is the only
        // path that can present a player (FR-RIE-018).
        let body = methodRegion("makeInstructionPlayback", in: instructionSection())
        XCTAssertTrue(body.contains("AVKitInstructionVideoPlayer()"),
                      "the production playback adapter is the AVKit player")
        XCTAssertTrue(body.contains("InstructionPlaybackController("),
                      "the factory builds the one playback policy owner")
        XCTAssertFalse(body.contains(".start("),
                       "no factory may autoplay")
        XCTAssertFalse(instructionSection().contains(".start()"),
                       "the composition section never starts playback")
    }

    func testFactoriesBuildNoNetworkOrTranscodeAdapter() {
        let section = instructionSection()
        XCTAssertFalse(section.isEmpty)

        let forbidden = [
            "URLSession",
            "AVAssetExportSession",
            "PHPhotoLibrary",
            "PHAsset",
            "UIActivityViewController",
            "transcode",
            "upload",
            "http://",
            "https://"
        ]
        for token in forbidden {
            XCTAssertFalse(section.contains(token),
                           "the instruction composition must never name \(token)")
        }

        // The two production capture adapters are equally adapter-free.
        let adapterURL = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/InstructionCapture.swift")
        let adapters = FeatureSourceScan.codeText(of: adapterURL)
        XCTAssertFalse(adapters.isEmpty)
        for token in forbidden + ["isExcludedFromBackup"] {
            XCTAssertFalse(adapters.contains(token),
                           "the capture adapters must never name \(token)")
        }

        // No view reaches either owner's store: the composition root is the
        // only place that names one (design §2.15 rule 2, §11.3 Q).
        let appDirectory = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App")
        for view in ["ContentView.swift", "VisualAidViews.swift",
                     "RoutineSettingsView.swift", "EventsView.swift"] {
            let code = FeatureSourceScan.codeText(of: appDirectory.appendingPathComponent(view))
            XCTAssertFalse(code.isEmpty, "could not scan \(view)")
            for token in ["InstructionVideoStore", "instructionVideoStore",
                          "InstructionVideoImporter", "instructionVideoImporter"] {
                XCTAssertFalse(code.contains(token),
                               "\(view) must not reach the instruction store/\(token)")
            }
        }
    }

    // MARK: - No IO, timer, notification or permission at launch

    func testCoordinatorInitStillDoesNoFileIO() {
        // The same resolution `InstructionVideoStore.init` uses, without
        // creating anything (Application Support, else the temporary
        // directory). The check is before/after and relative, so a root a
        // previous run left behind can never masquerade as this init's IO.
        let fileManager = FileManager.default
        let base: URL
        if let applicationSupport = try? fileManager.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil,
                                                         create: false) {
            base = applicationSupport
        } else {
            base = fileManager.temporaryDirectory
        }
        let routineRoot = base.appendingPathComponent(InstructionRoot.routines.rawValue,
                                                      isDirectory: true)
        let eventRoot = base.appendingPathComponent(InstructionRoot.events.rawValue,
                                                    isDirectory: true)
        let routineExisted = fileManager.fileExists(atPath: routineRoot.path)
        let eventExisted = fileManager.fileExists(atPath: eventRoot.path)

        let coordinator = makeCoordinator()
        // Touch every launch-time seam and one per-editor factory: still no
        // directory may appear.
        _ = coordinator.instructionVideoStore
        _ = coordinator.instructionVideoImporter
        _ = coordinator.instructionCaptureCoordinator(draftSession: .routines)

        XCTAssertEqual(fileManager.fileExists(atPath: routineRoot.path), routineExisted,
                       "coordinator init must not create the routine instruction root")
        XCTAssertEqual(fileManager.fileExists(atPath: eventRoot.path), eventExisted,
                       "coordinator init must not create the event instruction root")

        // Source pin over the composition section: no file IO, no timer, no
        // notification registration, no launch-time permission request.
        let section = instructionSection()
        let forbiddenFileIO = [
            "FileManager",
            "createDirectory(",
            "createFile(",
            "contentsOfDirectory(",
            "copyItem(",
            "moveItem(",
            "removeItem(",
            ".write(to:"
        ]
        for token in forbiddenFileIO {
            XCTAssertFalse(section.contains(token),
                           "the instruction composition must not perform file IO (\(token))")
        }
        for token in ["Timer(", "UNUserNotificationCenter", "requestAuthorization",
                      "prepareForRecording", "UIApplication.shared"] {
            XCTAssertFalse(section.contains(token),
                           "the instruction composition must not register or request \(token) at launch")
        }

        // The two declaration sites that own the store are still the lazy
        // seam values, never eager reads.
        let source = coordinatorSource()
        XCTAssertTrue(source.contains("lazy var instructionVideoImporter"),
                      "the importer is built on first use, not at launch")
        XCTAssertTrue(source.contains("lazy var instructionEvents"),
                      "the typed observability value is built on first use")
    }

    // MARK: - T-025: the fired-screen composition (design §2.15.3, §4.11)

    func testPresentForegroundBuildsReminderContent() {
        let coordinator = makeCoordinator()
        let instruction = videoInstruction()
        let aid = VisualAid(filename: "photo-1.jpg", caption: "the blue box")
        let entry = makeEntry(instruction: instruction, aids: [aid])
        let context = RoutineInstructionFireContext(hadInstruction: true,
                                                    firedAt: fixedFiredAt)

        coordinator.presentRoutineVisualAids(for: entry, context: context)

        guard let presented = coordinator.firedRoutineVisualAids,
              case .reminder(let title, let aids, let publishedInstruction,
                             let expectsInstruction, let firedAt) = presented.content
        else {
            return XCTFail("a foreground firing must publish .reminder content")
        }
        XCTAssertEqual(presented.entryId, entry.id,
                       "the presentation is keyed by the routine entry id")
        XCTAssertEqual(title, entry.displayTitle(locale: coordinator.activeLocale),
                       "the title is resolved in the language the app is in NOW")
        XCTAssertEqual(aids, entry.visualAids, "the photos travel unchanged")
        XCTAssertEqual(publishedInstruction, instruction,
                       "the instruction travels unchanged (a missing file still shows the card)")
        XCTAssertTrue(expectsInstruction)
        XCTAssertEqual(firedAt, fixedFiredAt,
                       "the delivery date is the notification's, never a clock read")
    }

    func testExpectsInstructionMirrorsHadInstruction() {
        let coordinator = makeCoordinator()
        let entry = makeEntry(instruction: videoInstruction())

        coordinator.presentRoutineVisualAids(
            for: entry,
            context: RoutineInstructionFireContext(hadInstruction: false,
                                                   firedAt: fixedFiredAt))
        guard let photoOnly = coordinator.firedRoutineVisualAids,
              case .reminder(_, _, _, let expectsWhenFalse, _) = photoOnly.content else {
            return XCTFail("a foreground firing must publish .reminder content")
        }
        XCTAssertFalse(expectsWhenFalse,
                       "a pre-upgrade/photo-only payload must not claim an expected instruction")

        coordinator.presentRoutineVisualAids(
            for: entry,
            context: RoutineInstructionFireContext(hadInstruction: true,
                                                   firedAt: fixedFiredAt))
        guard let withInstruction = coordinator.firedRoutineVisualAids,
              case .reminder(_, _, _, let expectsWhenTrue, _) = withInstruction.content else {
            return XCTFail("a foreground firing must publish .reminder content")
        }
        XCTAssertTrue(expectsWhenTrue,
                      "expectsInstruction is the payload's had_instruction, mirrored")
    }

    func testTapWithInstructionPresentsReminder() {
        let coordinator = makeCoordinator()
        let entry = makeEntry(instruction: videoInstruction())

        coordinator.presentRoutineInstructionTap(entryId: entry.id,
                                                 entry: entry,
                                                 firedAt: fixedFiredAt)

        guard let first = coordinator.firedRoutineVisualAids,
              case .reminder(let title, let aids, let instruction,
                             let expectsInstruction, let firedAt) = first.content
        else {
            return XCTFail("a tap with a live owner must publish .reminder content")
        }
        XCTAssertEqual(first.entryId, entry.id)
        XCTAssertEqual(title, entry.displayTitle(locale: coordinator.activeLocale))
        XCTAssertEqual(aids, entry.visualAids)
        XCTAssertEqual(instruction, entry.instruction)
        XCTAssertTrue(expectsInstruction,
                      "this path only runs when had_instruction was true")
        XCTAssertEqual(firedAt, fixedFiredAt)

        // Dedupe by entry id (L1, R-13): the tap that follows a foreground
        // firing for the SAME entry does not reset the screen.
        coordinator.presentRoutineInstructionTap(entryId: entry.id,
                                                 entry: entry,
                                                 firedAt: fixedFiredAt.addingTimeInterval(60))
        XCTAssertEqual(coordinator.firedRoutineVisualAids?.content, first.content,
                       "the same entry must not be re-presented")

        // A different entry replaces it; the single cover never stacks.
        let other = makeEntry(instruction: videoInstruction())
        coordinator.presentRoutineInstructionTap(entryId: other.id,
                                                 entry: other,
                                                 firedAt: fixedFiredAt)
        XCTAssertEqual(coordinator.firedRoutineVisualAids?.entryId, other.id,
                       "a different entry replaces the published value")
    }

    func testTapWithRemovedInstructionPresentsRemoved() {
        let coordinator = makeCoordinator()
        let entry = makeEntry(instruction: nil)

        coordinator.presentRoutineInstructionTap(entryId: entry.id,
                                                 entry: entry,
                                                 firedAt: fixedFiredAt)

        guard let presented = coordinator.firedRoutineVisualAids,
              case .reminder(let title, _, let instruction,
                             let expectsInstruction, let firedAt) = presented.content
        else {
            return XCTFail("a live owner with no instruction still presents the card")
        }
        XCTAssertEqual(title, entry.displayTitle(locale: coordinator.activeLocale),
                       "the title and fire time survive a removed instruction")
        XCTAssertNil(instruction)
        XCTAssertTrue(expectsInstruction,
                      "an instruction was expected, so the card renders .removed")
        XCTAssertEqual(InstructionPresentation.state(for: instruction,
                                                     isExpected: expectsInstruction),
                       .removed,
                       "the removed fallback is derived from the one presentation rule")
        XCTAssertEqual(firedAt, fixedFiredAt)
    }

    func testTapWithNilEntryPresentsUnavailable() {
        let coordinator = makeCoordinator()
        let deletedId = UUID()

        coordinator.presentRoutineInstructionTap(entryId: deletedId,
                                                 entry: nil,
                                                 firedAt: fixedFiredAt)

        XCTAssertEqual(coordinator.firedRoutineVisualAids?.entryId, deletedId)
        // `.unavailable` is a value with no title, no aids and no time, so
        // the deleted-owner notice cannot claim any of them by construction.
        XCTAssertEqual(coordinator.firedRoutineVisualAids?.content, .unavailable,
                       "a deleted owner is the honest notice, never a dead tap")

        coordinator.dismissFiredRoutineVisualAids()
        XCTAssertNil(coordinator.firedRoutineVisualAids)
    }

    func testDismissClearsAndIsIdempotent() {
        let coordinator = makeCoordinator()
        let entry = makeEntry(instruction: videoInstruction())
        coordinator.presentRoutineVisualAids(
            for: entry,
            context: RoutineInstructionFireContext(hadInstruction: true,
                                                   firedAt: fixedFiredAt))
        XCTAssertNotNil(coordinator.firedRoutineVisualAids)

        coordinator.dismissFiredRoutineVisualAids()
        XCTAssertNil(coordinator.firedRoutineVisualAids,
                     "dismiss clears the fired state")

        coordinator.dismissFiredRoutineVisualAids()
        XCTAssertNil(coordinator.firedRoutineVisualAids,
                     "a second dismiss is a no-op")
    }

    // MARK: - T-025: the launch orphan sweep (design §4.9, §5.5, §11.3 K)

    func testSweepKeepsBytesForUnreadableRoutineSource() {
        let eventId = "event-\(UUID().uuidString)"
        let owners = LiveInstructionOwners.compose(
            routineEntries: nil,
            extras: [eventId: EventExtras(instruction: videoInstruction())])

        XCTAssertNil(owners.routines,
                     "an unreadable routine source is unknown, never an empty stand-in")
        XCTAssertEqual(owners.events, [InstructionOwner.event(eventId)])

        let spy = RecordingInstructionSweeper()
        let bus = MockObservabilityBus()
        AppCoordinator.performInstructionOrphanSweep(
            owners: owners,
            graceSeconds: InstructionVideoConfiguration.standard.orphanGraceSeconds,
            sweeper: spy,
            events: InstructionObservability(bus: bus))

        XCTAssertEqual(spy.orphanCalls.map(\.root), [.routines, .events])
        let routineCall = spy.orphanCalls.first { $0.root == .routines }
        let eventCall = spy.orphanCalls.first { $0.root == .events }
        XCTAssertNil(routineCall?.live,
                     "nil must reach the store, whose nil live set is a no-op — every routine file is kept")
        XCTAssertEqual(eventCall?.live, [InstructionOwner.event(eventId)],
                       "the readable event index still follows its live rules")
    }

    func testSweepKeepsBytesForUnreadableEventSource() {
        let entryId = UUID()
        let owners = LiveInstructionOwners.compose(
            routineEntries: [makeEntry(id: entryId, instruction: videoInstruction())],
            extras: nil)

        XCTAssertEqual(owners.routines, [InstructionOwner.routine(entryId)])
        XCTAssertNil(owners.events,
                     "an unreadable extras index is unknown, never an empty stand-in")

        let spy = RecordingInstructionSweeper()
        AppCoordinator.performInstructionOrphanSweep(
            owners: owners,
            graceSeconds: InstructionVideoConfiguration.standard.orphanGraceSeconds,
            sweeper: spy,
            events: InstructionObservability(bus: MockObservabilityBus()))

        let routineCall = spy.orphanCalls.first { $0.root == .routines }
        let eventCall = spy.orphanCalls.first { $0.root == .events }
        XCTAssertEqual(routineCall?.live, [InstructionOwner.routine(entryId)])
        XCTAssertNil(eventCall?.live,
                     "nil must reach the store, whose nil live set is a no-op — every event file is kept")
    }

    func testSweepUsesStrictReadsOnly() {
        let compose = sourceSlice(from: "func composeLiveInstructionOwners",
                                  to: "func enqueueInstructionOrphanSweep")
        XCTAssertFalse(compose.isEmpty, "the compose seam must be source-pinned")

        XCTAssertTrue(compose.contains("routineScheduler.entriesIfReadable()"),
                      "the routine root uses the strict read (IF-23)")
        XCTAssertTrue(compose.contains("eventExtrasStore.snapshot()"),
                      "the event root uses the strict read (IF-27)")
        for forbidden in ["loadEntries()", "routineScheduler.entries()",
                          "eventExtrasStore.all", ".all"] {
            XCTAssertFalse(compose.contains(forbidden),
                           "the live set must never be built from \(forbidden)")
        }
    }

    func testSweepHonoursTenantGrace() {
        XCTAssertEqual(InstructionVideoConfiguration.standard.orphanGraceSeconds, 60,
                       "the design fixes the orphan grace at 60 seconds")

        let spy = RecordingInstructionSweeper()
        AppCoordinator.performInstructionOrphanSweep(
            owners: LiveInstructionOwners(routines: [], events: []),
            graceSeconds: InstructionVideoConfiguration.standard.orphanGraceSeconds,
            sweeper: spy,
            events: InstructionObservability(bus: MockObservabilityBus()))

        XCTAssertEqual(spy.orphanCalls.map(\.graceSeconds), [60, 60],
                       "both roots are swept with the 60 s grace")

        let enqueue = sourceSlice(from: "func enqueueInstructionOrphanSweep",
                                  to: "static func performInstructionOrphanSweep")
        XCTAssertTrue(enqueue.contains("InstructionVideoConfiguration.standard.orphanGraceSeconds"),
                      "the grace value is captured from its ONE named home")
    }

    func testLiveSetUsesInstructionKindNotFileExistence() {
        let liveId = UUID()
        // A VIDEO instruction with no filename renders nothing (`isPresent`
        // is false) and no file exists — yet its kind still makes the owner
        // live, so the sweep can never delete bytes the index might name.
        let missingFilename = videoInstruction(filename: nil)
        XCTAssertFalse(missingFilename.isPresent)

        let liveEntry = makeEntry(id: liveId, instruction: missingFilename)
        let textEntry = makeEntry(instruction: Instruction(kind: InstructionKind.text.rawValue,
                                                           text: "Take it with water"))
        let imageEntry = makeEntry(instruction: Instruction(kind: InstructionKind.image.rawValue,
                                                            filename: "photo.jpg"))
        let unknownEntry = makeEntry(instruction: Instruction(kind: "link",
                                                              text: "unsupported kind"))

        let owners = LiveInstructionOwners.compose(
            routineEntries: [liveEntry, textEntry, imageEntry, unknownEntry],
            extras: nil)
        XCTAssertEqual(owners.routines, [InstructionOwner.routine(liveId)],
                       "only the video kind is live; filename existence is irrelevant")
        XCTAssertNil(owners.events)

        let eventOwners = LiveInstructionOwners.compose(
            routineEntries: nil,
            extras: ["event-live": EventExtras(instruction: videoInstruction(filename: nil)),
                     "event-text": EventExtras(instruction: Instruction(kind: "text",
                                                                        text: "Take it"))])
        XCTAssertEqual(eventOwners.events, [InstructionOwner.event("event-live")])
        XCTAssertNil(eventOwners.routines)
    }

    func testComposePerformsNoIO() {
        let compose = sourceSlice(from: "static func compose(routineEntries:",
                                  to: "protocol InstructionOrphanSweeping")
        XCTAssertFalse(compose.isEmpty, "the compose function must be source-pinned")
        for forbidden in ["FileManager", "fileExists", "availability(",
                          "InstructionVideoStore", "contentsOfDirectory",
                          "createDirectory", "removeItem", "attributesOfItem"] {
            XCTAssertFalse(compose.contains(forbidden),
                           "compose must perform no IO and name no store (\(forbidden))")
        }
        XCTAssertTrue(compose.contains("knownKind == .video"),
                      "liveness is the instruction kind, never a file probe")

        // Behaviour: a filename that does not exist on disk changes nothing.
        let entry = makeEntry(instruction: videoInstruction(
            filename: "absent-\(UUID().uuidString).mov"))
        XCTAssertEqual(LiveInstructionOwners.compose(routineEntries: [entry], extras: nil).routines,
                       [InstructionOwner.routine(entry.id)])
    }

    func testSweepRunsOnceAtLaunch() {
        let coordinator = makeCoordinator()
        let spy = RecordingInstructionSweeper()
        coordinator.instructionSweeper = spy
        let swept = expectation(description: "one launch sweep: 3 purge calls")
        swept.expectedFulfillmentCount = 3
        spy.onCall = { swept.fulfill() }

        coordinator.enqueueInstructionOrphanSweep()
        coordinator.enqueueInstructionOrphanSweep()

        wait(for: [swept], timeout: 2)
        XCTAssertTrue(coordinator.instructionSweepEnqueued,
                      "the one-shot guard is set by the first enqueue")
        XCTAssertEqual(spy.pendingDraftCallCount, 1,
                       "pending drafts are purged once")
        XCTAssertEqual(spy.orphanCalls.map(\.root), [.routines, .events],
                       "each root is swept once; the second enqueue is a no-op")
    }

    func testSweepPartialCountReported() {
        let bus = MockObservabilityBus()
        let spy = RecordingInstructionSweeper()
        spy.pendingResult = .success(2)
        spy.orphanResult = { root -> Result<Int, InstructionStorageError> in
            root == .routines ? .success(1) : .failure(.purgeFailed)
        }

        AppCoordinator.performInstructionOrphanSweep(
            owners: LiveInstructionOwners(routines: [], events: []),
            graceSeconds: 60,
            sweeper: spy,
            events: InstructionObservability(bus: bus))

        let purges = bus.emittedEvents.filter { $0.eventType == "instruction_orphan_purge" }
        XCTAssertEqual(purges.count, 3, "one event per purge call")
        XCTAssertTrue(purges.allSatisfy { $0.component == "instruction_media" })
        XCTAssertEqual(purges.map(\.outcome), ["completed", "completed", "failed"])
        XCTAssertEqual(purges.map { $0.metadata["count"] }, ["2", "1", "0"],
                       "a failed sweep reports 0 (a partial count), never a fabricated total")
        XCTAssertNil(purges[0].errorCode)
        XCTAssertNil(purges[1].errorCode)
        XCTAssertEqual(purges[2].errorCode, "purge_failed",
                       "the failure is a closed token, never OS prose")
    }

    // MARK: - T-025: the availability seam still delegates to the ONE store

    func testInstructionPlaybackAvailabilityDelegatesToSharedStore() {
        let coordinator = makeCoordinator()
        let owner = InstructionOwner.routine(UUID())
        let absent = "absent-\(UUID().uuidString).mov"

        let throughCoordinator = coordinator.instructionPlaybackAvailability(filename: absent,
                                                                             owner: owner)
        let throughStore = coordinator.instructionVideoStore.availability(filename: absent,
                                                                          owner: owner)

        XCTAssertEqual(throughCoordinator, throughStore,
                       "the seam must answer exactly what the ONE shared store answers")
        XCTAssertEqual(throughCoordinator, .missingFile,
                       "an absent name yields no play control")

        let body = methodRegion("instructionPlaybackAvailability", in: coordinatorSource())
        XCTAssertTrue(body.contains("instructionVideoStore.availability(filename: filename, owner: owner)"),
                      "one delegation to the shared store, no second instance and no IO of its own")
    }
}
