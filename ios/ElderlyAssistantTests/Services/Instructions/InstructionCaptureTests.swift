import Foundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ElderlyAssistant

/// C04's capture suite (T-009; design L2 §2.4, §7.2–§7.5, §11.3 J/R,
/// §6.4; FR-RIE-004/005/006/010/025, NFR-RIE-009).
///
/// Every test drives the real `InstructionVideoCaptureCoordinator` against
/// injected doubles for the system picker/recorder, the permission seam and
/// the importer, and a real `InstructionVideoStore` rooted in a per-test
/// temporary directory. No device, camera, microphone, photo library,
/// AVPlayer or user data is touched.
///
/// The suite pins the six Gherkin scenarios:
///
///  - **Single flight** — a second pick or record while one is in flight is
///    ignored: the first state stands, no second surface is presented and no
///    second staged draft exists (`testPickTwiceIsSingleFlight`,
///    `testRecordWhilePickingIsRefused`, `testPickWhileRecordingIsRefused`).
///  - **M-1 camera before microphone** — with both undetermined the camera is
///    requested first and the microphone only after it is usable; a denial,
///    restriction or missing camera short-circuits with zero microphone
///    requests and no recorder (`testCameraRequestedBeforeMicrophone`,
///    `testDeniedCameraSkipsMicrophone`,
///    `testRestrictedCameraSkipsMicrophone`,
///    `testRecordingStartsOnlyWhenBothAuthorized`).
///  - **Validation and exactly-once ownership** — a staged file the importer
///    accepts becomes `.ready`; `consumeAccepted()` returns it once and
///    clears the state; `discardAccepted()` discards through the store
///    (`testValidationSuccessBecomesReady`,
///    `testConsumeAcceptedIsExactlyOnce`, `testDiscardAcceptedReturnsToIdle`).
///  - **Cancellation and failure discard staged bytes** — neither ever hands
///    an accepted video to an editor
///    (`testCancelDuringValidationDiscardsStaged`,
///    `testValidationFailureDiscardsStaged`).
///  - **The typed permission payload** —
///    `testPermissionProblemCarriesCase`.
///  - **No player, no autoplay** — `testReadyDoesNotStartPlayback`.
///  - **Exactly one event per attempt** —
///    `testCaptureEventsEmittedOncePerAttempt`.
final class InstructionCaptureTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: InstructionVideoStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("instruction-capture-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = InstructionVideoStore(baseDirectory: tempDirectory,
                                      now: { CaptureTestValues.date })
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Single flight (§7.3, first Gherkin scenario)

    /// A second `pick()` while the first is still presenting is ignored: the
    /// state stays `.picking`, no second picker is presented and no second
    /// staged draft appears. `cancel()` then discards the one draft through
    /// the store.
    @MainActor
    func testPickTwiceIsSingleFlight() throws {
        let picker = FakeInstructionVideoPicker()
        let source = try writeSource()
        picker.script = { makeStagedCopy, _ in
            _ = makeStagedCopy(source)
        }
        let coordinator = makeCoordinator(importer: acceptingImporter(),
                                          makePicker: { picker })

        coordinator.pick()

        XCTAssertEqual(coordinator.state, .picking)
        XCTAssertTrue(coordinator.isBusy)
        XCTAssertEqual(picker.presentCount, 1)
        XCTAssertEqual(pendingDraftCount(), 1)

        coordinator.pick()

        XCTAssertEqual(coordinator.state, .picking,
                       "the second pick must leave the first operation's state unchanged")
        XCTAssertEqual(picker.presentCount, 1, "no second picker may be presented")
        XCTAssertEqual(pendingDraftCount(), 1, "no second staged file may be created")

        coordinator.cancel()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(picker.dismissCount, 1)
        XCTAssertEqual(pendingDraftCount(), 0,
                       "cancel discards the staged bytes through the store")
    }

    /// `record()` while `.picking` is refused before any permission read or
    /// recorder construction.
    @MainActor
    func testRecordWhilePickingIsRefused() throws {
        let picker = FakeInstructionVideoPicker()
        let recorder = FakeInstructionVideoRecorder()
        let permissions = CapturePermissionRequester()
        let source = try writeSource()
        picker.script = { makeStagedCopy, _ in
            _ = makeStagedCopy(source)
        }
        let coordinator = makeCoordinator(importer: acceptingImporter(),
                                          permissions: permissions,
                                          makePicker: { picker },
                                          makeRecorder: { recorder })

        coordinator.pick()
        XCTAssertEqual(coordinator.state, .picking)

        coordinator.record()

        XCTAssertEqual(coordinator.state, .picking,
                       "a refused record must not disturb the pick")
        XCTAssertEqual(recorder.presentCount, 0, "no recorder may be presented")
        XCTAssertTrue(permissions.calls.isEmpty,
                      "a refused record must not read or request any permission")
        XCTAssertEqual(picker.presentCount, 1)
        XCTAssertEqual(pendingDraftCount(), 1)

        coordinator.cancel()
    }

    /// `pick()` while `.recording` is refused: no picker is presented and the
    /// recorder stays exactly as it was.
    @MainActor
    func testPickWhileRecordingIsRefused() async throws {
        let picker = FakeInstructionVideoPicker()
        let recorder = FakeInstructionVideoRecorder()
        let permissions = CapturePermissionRequester()
        permissions.cameraStatus = .granted
        permissions.microphoneStatus = .granted
        let coordinator = makeCoordinator(importer: acceptingImporter(),
                                          permissions: permissions,
                                          makePicker: { picker },
                                          makeRecorder: { recorder })

        coordinator.record()
        await waitUntil("the recorder must be presented once both permissions are usable") {
            recorder.presentCount == 1
        }
        XCTAssertEqual(coordinator.state, .recording)

        coordinator.pick()

        XCTAssertEqual(coordinator.state, .recording,
                       "a refused pick must not disturb the recording")
        XCTAssertEqual(picker.presentCount, 0, "no picker may be presented while recording")
        XCTAssertEqual(recorder.presentCount, 1)

        coordinator.cancel()
        XCTAssertEqual(recorder.dismissCount, 1)
    }

    // MARK: - M-1: camera before microphone (§2.5.3, §11.3 R)

    /// With both permissions undetermined, the request order is camera then
    /// microphone, and the recorder appears only after both resolve granted.
    @MainActor
    func testCameraRequestedBeforeMicrophone() async throws {
        let recorder = FakeInstructionVideoRecorder()
        let permissions = CapturePermissionRequester()
        permissions.cameraStatus = .undetermined
        permissions.cameraRequestOutcome = .granted
        permissions.microphoneStatus = .undetermined
        permissions.microphoneRequestOutcome = .granted
        let coordinator = makeCoordinator(importer: acceptingImporter(),
                                          permissions: permissions,
                                          makeRecorder: { recorder })

        coordinator.record()
        await waitUntil("the recorder must appear after both permissions resolve") {
            recorder.presentCount == 1
        }

        XCTAssertEqual(permissions.calls, [
            .status(.camera),
            .request(.camera),
            .status(.microphone),
            .request(.microphone),
        ], "camera is read and requested before the microphone is even read")
        XCTAssertEqual(recorder.maximumDurations, [180],
                       "the recorder is capped at the configured 3 minutes")
        XCTAssertEqual(recorder.qualities, [.high])
        XCTAssertEqual(coordinator.state, .recording)

        coordinator.cancel()
    }

    /// A denied camera stops the attempt: the microphone is never requested
    /// or read, no recorder appears, the typed problem rides `.failed`, and
    /// exactly one permission event is emitted. The library picker still
    /// opens because it consults no permission.
    @MainActor
    func testDeniedCameraSkipsMicrophone() async throws {
        let bus = RecordingCaptureBus()
        let picker = FakeInstructionVideoPicker()
        let recorder = FakeInstructionVideoRecorder()
        let permissions = CapturePermissionRequester()
        permissions.cameraStatus = .denied
        permissions.microphoneStatus = .undetermined
        let coordinator = makeCoordinator(importer: acceptingImporter(),
                                          permissions: permissions,
                                          makePicker: { picker },
                                          makeRecorder: { recorder },
                                          bus: bus)

        coordinator.record()
        await waitUntil("a denied camera must stop the attempt") {
            coordinator.state == .failed(.permission(.cameraDenied))
        }

        XCTAssertEqual(coordinator.permissionProblem, .cameraDenied)
        XCTAssertEqual(permissions.requestCount, 0,
                       "an already-denied camera is read, never re-prompted")
        XCTAssertEqual(permissions.microphoneRequestCount, 0,
                       "the microphone must never be requested after a camera denial")
        XCTAssertEqual(permissions.microphoneReadCount, 0,
                       "the microphone status must not even be read after a camera denial")
        XCTAssertEqual(recorder.presentCount, 0, "no recorder may be presented")
        XCTAssertEqual(bus.events(named: "instruction_capture_permission").count, 1,
                       "one permission event per stopped attempt")
        let event = try XCTUnwrap(bus.events(named: "instruction_capture_permission").first)
        XCTAssertEqual(event.metadata, ["state": "denied", "kind": "camera"])
        XCTAssertEqual(event.outcome, "info")
        XCTAssertNil(event.errorCode)

        // The pick path is permission-free: it still works after a denial.
        picker.script = { _, completion in completion(.failure(.cancelled)) }
        coordinator.pick()
        XCTAssertEqual(picker.presentCount, 1,
                       "the library picker must still open after a camera denial")
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(bus.events(named: "instruction_media_import").count, 0,
                       "a cancelled pick emits no import event")
    }

    /// A restricted camera has the same user outcome as a denial but is
    /// reported honestly as `restricted` in the event's closed `state` token.
    @MainActor
    func testRestrictedCameraSkipsMicrophone() async throws {
        let bus = RecordingCaptureBus()
        let recorder = FakeInstructionVideoRecorder()
        let permissions = CapturePermissionRequester()
        permissions.cameraStatus = .restricted
        permissions.microphoneStatus = .undetermined
        let coordinator = makeCoordinator(importer: acceptingImporter(),
                                          permissions: permissions,
                                          makeRecorder: { recorder },
                                          bus: bus)

        coordinator.record()
        await waitUntil("a restricted camera must stop the attempt") {
            coordinator.permissionProblem == .cameraDenied
        }

        XCTAssertEqual(coordinator.permissionProblem, .cameraDenied)
        XCTAssertEqual(permissions.requestCount, 0,
                       "an already-restricted camera is read, never re-prompted")
        XCTAssertEqual(permissions.microphoneRequestCount, 0)
        XCTAssertEqual(permissions.microphoneReadCount, 0)
        XCTAssertEqual(recorder.presentCount, 0)
        let event = try XCTUnwrap(bus.events(named: "instruction_capture_permission").first)
        XCTAssertEqual(event.metadata, ["state": "restricted", "kind": "camera"],
                       "restriction is its own closed event state, not collapsed onto denial")
    }

    /// Recording starts only when both permissions are authorized. An
    /// already-granted pair is read, not re-prompted; a refused microphone
    /// after a usable camera never presents the recorder.
    @MainActor
    func testRecordingStartsOnlyWhenBothAuthorized() async throws {
        // Both granted: reads only, then the recorder is presented.
        let grantedRecorder = FakeInstructionVideoRecorder()
        let grantedPermissions = CapturePermissionRequester()
        grantedPermissions.cameraStatus = .granted
        grantedPermissions.microphoneStatus = .granted
        let grantedCoordinator = makeCoordinator(importer: acceptingImporter(),
                                                 permissions: grantedPermissions,
                                                 makeRecorder: { grantedRecorder })

        grantedCoordinator.record()
        await waitUntil("an authorized pair must present the recorder") {
            grantedRecorder.presentCount == 1
        }
        XCTAssertEqual(grantedPermissions.calls,
                       [.status(.camera), .status(.microphone)],
                       "an already-granted permission is read, never re-requested")
        grantedCoordinator.cancel()

        // Camera usable, microphone refused: the recorder never appears.
        let deniedRecorder = FakeInstructionVideoRecorder()
        let deniedPermissions = CapturePermissionRequester()
        deniedPermissions.cameraStatus = .undetermined
        deniedPermissions.cameraRequestOutcome = .granted
        deniedPermissions.microphoneStatus = .undetermined
        deniedPermissions.microphoneRequestOutcome = .denied
        let deniedCoordinator = makeCoordinator(importer: acceptingImporter(),
                                                permissions: deniedPermissions,
                                                makeRecorder: { deniedRecorder })

        deniedCoordinator.record()
        await waitUntil("a refused microphone must stop the attempt") {
            deniedCoordinator.state == .failed(.permission(.microphoneDenied))
        }

        XCTAssertEqual(deniedCoordinator.permissionProblem, .microphoneDenied)
        XCTAssertEqual(deniedRecorder.presentCount, 0,
                       "recording starts only when both permissions are authorized")
        XCTAssertEqual(deniedPermissions.microphoneRequestCount, 1)
    }

    // MARK: - Validation and exactly-once ownership (§7.5, fourth scenario)

    /// A staged file the importer accepts moves to `.ready` with that exact
    /// accepted value, and the bytes stay staged until ownership moves.
    @MainActor
    func testValidationSuccessBecomesReady() async throws {
        let picker = FakeInstructionVideoPicker()
        let source = try writeSource()
        var staged: StagedInstructionVideo?
        picker.script = { makeStagedCopy, completion in
            let result = makeStagedCopy(source)
            staged = try? result.get()
            completion(result)
        }
        let importer = acceptingImporter()
        let coordinator = makeCoordinator(importer: importer,
                                          makePicker: { picker })

        coordinator.pick()
        XCTAssertEqual(coordinator.state, .validating,
                       "a successful staging resolves through validation before ready")

        let stagedValue = try XCTUnwrap(staged)
        let expected = AcceptedInstructionVideo(staged: stagedValue,
                                                validatedAt: CaptureTestValues.date)
        await waitUntil("the accepted video must reach ready") {
            coordinator.state == .ready(expected)
        }

        XCTAssertEqual(coordinator.accepted, expected)
        XCTAssertNil(coordinator.permissionProblem)
        XCTAssertNil(coordinator.importFailure)
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertEqual(importer.validatedStaged, [stagedValue])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedValue.stagedURL.path),
                      "acceptance transfers ownership; the coordinator must not discard")
    }

    /// `consumeAccepted()` returns the value once, clears the state and hands
    /// ownership to the editor; a second call returns nil and teardown must
    /// not delete the host-owned bytes.
    @MainActor
    func testConsumeAcceptedIsExactlyOnce() async throws {
        let (coordinator, accepted, _) = try await makeReadyCoordinator()

        XCTAssertEqual(coordinator.consumeAccepted(), accepted)
        XCTAssertEqual(coordinator.state, .idle, "the accepted value is cleared before returning")
        XCTAssertNil(coordinator.accepted)
        XCTAssertNil(coordinator.consumeAccepted(), "a second consume must return nil")

        coordinator.discardAccepted()
        XCTAssertTrue(FileManager.default.fileExists(atPath: accepted.staged.stagedURL.path),
                      "after consume the editor owns the bytes; discardAccepted must not delete them")
    }

    /// `discardAccepted()` discards the staged draft through the store and
    /// returns to `.idle`.
    @MainActor
    func testDiscardAcceptedReturnsToIdle() async throws {
        let (coordinator, accepted, _) = try await makeReadyCoordinator()
        XCTAssertTrue(FileManager.default.fileExists(atPath: accepted.staged.stagedURL.path))

        coordinator.discardAccepted()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.accepted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: accepted.staged.stagedURL.path),
                       "discardAccepted must discard the staged bytes through the store")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: accepted.staged.stagedURL.deletingLastPathComponent().path),
                       "the draft directory must be gone too")

        coordinator.discardAccepted()
        XCTAssertEqual(coordinator.state, .idle)
    }

    /// Cancelling while the importer is still running discards the staged
    /// bytes, returns to `.idle`, and ignores a validation that resolves
    /// afterwards: no ready value, no event, no accepted video for an editor.
    @MainActor
    func testCancelDuringValidationDiscardsStaged() async throws {
        let bus = RecordingCaptureBus()
        let picker = FakeInstructionVideoPicker()
        let source = try writeSource()
        let importer = SuspendedInstructionImporter()
        var staged: StagedInstructionVideo?
        picker.script = { makeStagedCopy, completion in
            let result = makeStagedCopy(source)
            staged = try? result.get()
            completion(result)
        }
        let coordinator = makeCoordinator(importer: importer,
                                          makePicker: { picker },
                                          bus: bus)

        coordinator.pick()
        let stagedValue = try XCTUnwrap(staged)
        XCTAssertEqual(coordinator.state, .validating)

        coordinator.pick()
        XCTAssertEqual(coordinator.state, .validating,
                       "a pick while validating is a no-op")
        XCTAssertEqual(picker.presentCount, 1,
                       "no second picker may be presented while validating")

        await waitUntil("the importer must be running") {
            importer.startedCount == 1
        }

        coordinator.cancel()

        XCTAssertEqual(coordinator.state, .idle)
        // The picker's completion already ended and released the system
        // surface (handleCaptureOutcome nils the adapter), so by the time the
        // importer is running there is nothing left for cancel() to dismiss.
        // The staged bytes are still the coordinator's to discard.
        XCTAssertEqual(picker.dismissCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedValue.stagedURL.path),
                       "cancel must discard the staged bytes through the store")

        // A validation that resolves after cancel must not resurrect ready.
        importer.resolveAccepting(validatedAt: CaptureTestValues.date)
        await waitUntil("the late validation must finish") {
            importer.finishedCount == 1
        }
        await settle()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.accepted,
                     "never hand an accepted video to an editor after cancellation")
        XCTAssertTrue(bus.allEvents.isEmpty, "a cancelled attempt emits no events")
    }

    /// A validation failure discards the staged bytes through the store (even
    /// if the importer double forgot to), ends in `.failed` with the typed
    /// import error, and emits one failed import event with the design token.
    @MainActor
    func testValidationFailureDiscardsStaged() async throws {
        let bus = RecordingCaptureBus()
        let picker = FakeInstructionVideoPicker()
        let source = try writeSource()
        let importer = failingImporter(.tooLong)
        var staged: StagedInstructionVideo?
        picker.script = { makeStagedCopy, completion in
            let result = makeStagedCopy(source)
            staged = try? result.get()
            completion(result)
        }
        let coordinator = makeCoordinator(importer: importer,
                                          makePicker: { picker },
                                          bus: bus)

        coordinator.pick()
        let stagedValue = try XCTUnwrap(staged)
        await waitUntil("the refusal must reach failed") {
            coordinator.state == .failed(.importError(.tooLong))
        }

        XCTAssertEqual(coordinator.importFailure, .tooLong)
        XCTAssertEqual(coordinator.permissionProblem, nil)
        XCTAssertNil(coordinator.accepted,
                     "a rejected video must never be handed to an editor")
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedValue.stagedURL.path),
                       "validation failure must discard the staged bytes through the store")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: stagedValue.stagedURL.deletingLastPathComponent().path))

        let events = bus.events(named: "instruction_media_import")
        XCTAssertEqual(events.count, 1, "one import outcome per attempt")
        XCTAssertEqual(events.first?.outcome, "failed")
        XCTAssertEqual(events.first?.errorCode, "too_long")
        XCTAssertNil(events.first?.durationMs, "duration_ms is accepted-only")
        XCTAssertEqual(events.first?.metadata, ["kind": "video"])
    }

    // MARK: - The typed permission payload (third Gherkin scenario)

    /// The permission problem is a typed case on `.failed` for all three
    /// problems — never a bare string.
    @MainActor
    func testPermissionProblemCarriesCase() async throws {
        let cameraCases: [(InstructionPermissionStatus, InstructionPermissionProblem)] = [
            (.denied, .cameraDenied),
            (.restricted, .cameraDenied),
            (.unavailable, .cameraUnavailable),
        ]
        for (cameraStatus, expected) in cameraCases {
            let permissions = CapturePermissionRequester()
            permissions.cameraStatus = cameraStatus
            permissions.microphoneStatus = .undetermined
            let recorder = FakeInstructionVideoRecorder()
            let coordinator = makeCoordinator(importer: acceptingImporter(),
                                              permissions: permissions,
                                              makeRecorder: { recorder })

            coordinator.record()
            await waitUntil("\(expected) must reach the failed state") {
                coordinator.permissionProblem == expected
            }

            guard case .failed(.permission(let problem)) = coordinator.state else {
                XCTFail("the problem must ride the failed state as typed payload, got \(coordinator.state)")
                continue
            }
            XCTAssertEqual(problem, expected)
            XCTAssertEqual(coordinator.permissionProblem, expected)
            XCTAssertNil(coordinator.importFailure)
            XCTAssertFalse(coordinator.isBusy)
            XCTAssertEqual(permissions.requestCount, 0,
                           "an already-denied, restricted or missing camera is never re-prompted")
            XCTAssertEqual(permissions.microphoneRequestCount, 0,
                           "a camera stop must not request the microphone")
            XCTAssertEqual(recorder.presentCount, 0,
                           "no recorder may be presented when the camera is unusable")
        }

        let microphonePermissions = CapturePermissionRequester()
        microphonePermissions.cameraStatus = .granted
        microphonePermissions.microphoneStatus = .denied
        let microphoneRecorder = FakeInstructionVideoRecorder()
        let microphoneCoordinator = makeCoordinator(importer: acceptingImporter(),
                                                    permissions: microphonePermissions,
                                                    makeRecorder: { microphoneRecorder })
        microphoneCoordinator.record()
        await waitUntil("microphoneDenied must reach the failed state") {
            microphoneCoordinator.permissionProblem == .microphoneDenied
        }
        guard case .failed(.permission(let problem)) = microphoneCoordinator.state else {
            return XCTFail("the microphone problem must be typed, got \(microphoneCoordinator.state)")
        }
        XCTAssertEqual(problem, .microphoneDenied)
        XCTAssertEqual(microphonePermissions.requestCount, 0,
                       "an already-denied microphone is read, never re-prompted")
        XCTAssertEqual(microphoneRecorder.presentCount, 0,
                       "recording starts only when both permissions are authorized")
    }

    // MARK: - No player, no preview, no autoplay (sixth Gherkin scenario)

    /// The coordinator owns no playback or capture hardware path: a source
    /// scan (comments stripped) finds no player, audio session, photo-library
    /// picker, transcode or platform-view import. A ready video is a value,
    /// not a playing surface.
    func testReadyDoesNotStartPlayback() {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent(
                "ElderlyAssistant/Services/Instructions/InstructionVideoCaptureCoordinator.swift")
        let code = FeatureSourceScan.codeText(of: url)

        XCTAssertFalse(code.isEmpty, "the source scan must actually read the coordinator")
        XCTAssertTrue(code.contains("func consumeAccepted"),
                      "positive control: the scan read the coordinator body")
        XCTAssertTrue(code.contains("state = .ready(accepted)"),
                      "positive control: the ready transition is present")

        let imports = code
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("import ") }
        XCTAssertEqual(imports, ["import Combine", "import Foundation"],
                       "the coordinator depends on no AI, voice, playback or capture framework")

        let forbidden = [
            "AVPlayer", "AVPlayerItem", "AVAudioSession", "AVAudioPlayer",
            "AVAssetExportSession", "PHPhotoLibrary", "PHPickerViewController",
            "UIImagePickerController", "import AVFoundation", "import AVKit",
            "import PhotosUI", "import UIKit", ".play()", "setActive",
            "InstructionVideoPlaying", "AVAudioEngine",
            "Llama", "Gemini", "Whisper",
        ]
        for token in forbidden {
            XCTAssertFalse(code.contains(token),
                           "the capture coordinator must own no player, preview, audio session, "
                               + "photo library, transcode, AI or voice path (\(token))")
        }
    }

    // MARK: - Events: exactly one per attempt (§6.4)

    /// One `instruction_capture_permission` per denied attempt, one
    /// `instruction_media_import` outcome per resolved validation, and
    /// nothing at all for cancellation. Status reads never emit.
    @MainActor
    func testCaptureEventsEmittedOncePerAttempt() async throws {
        let bus = RecordingCaptureBus()
        let clock = CaptureClock()
        let permissions = CapturePermissionRequester()
        permissions.cameraStatus = .denied
        let source = try writeSource()

        let importer = ScriptedInstructionImporter { staged in
            .success(AcceptedInstructionVideo(staged: staged,
                                              validatedAt: CaptureTestValues.date))
        }
        var nextPickerScript: CaptureScript?
        let coordinator = makeCoordinator(
            importer: importer,
            permissions: permissions,
            makePicker: {
                let picker = FakeInstructionVideoPicker()
                picker.script = nextPickerScript
                return picker
            },
            makeRecorder: { FakeInstructionVideoRecorder() },
            bus: bus,
            clock: clock)

        // 1. Denied camera: exactly one permission event, no import event.
        coordinator.record()
        await waitUntil("the denied camera must stop the attempt") {
            coordinator.permissionProblem == .cameraDenied
        }
        XCTAssertEqual(bus.allEvents.count, 1,
                       "a denied attempt emits exactly one event despite the status re-read")
        XCTAssertEqual(bus.events(named: "instruction_capture_permission").count, 1)
        XCTAssertEqual(bus.events(named: "instruction_media_import").count, 0)

        // 2. Accepted pick: exactly one import event with duration and kind.
        bus.reset()
        importer.result = { staged in
            clock.advance(by: 1.5)
            return .success(AcceptedInstructionVideo(staged: staged,
                                                     validatedAt: CaptureTestValues.date))
        }
        nextPickerScript = { makeStagedCopy, completion in
            completion(makeStagedCopy(source))
        }
        coordinator.pick()
        await waitUntil("the accepted pick must reach ready") {
            coordinator.accepted != nil
        }
        let acceptedEvents = bus.events(named: "instruction_media_import")
        XCTAssertEqual(acceptedEvents.count, 1, "one import outcome per attempt")
        XCTAssertEqual(bus.allEvents.count, 1,
                       "an accepted import emits no permission event")
        XCTAssertEqual(acceptedEvents.first?.outcome, "accepted")
        XCTAssertEqual(acceptedEvents.first?.metadata, ["kind": "video"])
        XCTAssertEqual(acceptedEvents.first?.durationMs, 1500,
                       "duration_ms is computed from the injected clock")
        XCTAssertNil(acceptedEvents.first?.errorCode)

        // 3. Rejected pick: one failed import event with the design token.
        bus.reset()
        importer.result = { _ in .failure(.tooLong) }
        nextPickerScript = { makeStagedCopy, completion in
            completion(makeStagedCopy(source))
        }
        coordinator.pick()
        await waitUntil("the rejected pick must reach failed") {
            coordinator.state == .failed(.importError(.tooLong))
        }
        let failedEvents = bus.events(named: "instruction_media_import")
        XCTAssertEqual(failedEvents.count, 1, "one import outcome per attempt")
        XCTAssertEqual(bus.allEvents.count, 1)
        XCTAssertEqual(failedEvents.first?.outcome, "failed")
        XCTAssertEqual(failedEvents.first?.errorCode, "too_long")
        XCTAssertNil(failedEvents.first?.durationMs)

        // 4. Cancelled pick: silent.
        bus.reset()
        nextPickerScript = { _, completion in completion(.failure(.cancelled)) }
        coordinator.pick()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(bus.allEvents.isEmpty, "cancellation is not a failure and emits nothing")
    }

    // MARK: - Platform capture adapters (T-010; §2.4, §7.4, §9.1, §11.3 J/P)

    /// The library picker is `PHPickerViewController` in video mode: a videos
    /// filter, one selection, no preselection and `.current` representation so
    /// the system never transcodes. The adapter presents exactly the
    /// configuration the factory builds.
    @MainActor
    func testPickerUsesPHPickerVideoConfig() throws {
        let configuration = PHPickerInstructionVideoPicker.makeConfiguration()
        XCTAssertEqual(configuration.filter, .videos,
                       "the library picker offers videos only")
        XCTAssertNotEqual(configuration.filter, PHPickerFilter.images,
                          "an image filter is never used")
        XCTAssertEqual(configuration.selectionLimit, 1,
                       "one instruction video per pick")
        XCTAssertEqual(configuration.preferredAssetRepresentationMode, .current,
                       "the chosen file is received as-is, with no system transcode")
        XCTAssertTrue(configuration.preselectedAssetIdentifiers.isEmpty,
                      "no asset is preselected")

        // The adapter presents that exact configuration.
        var presented: PHPickerViewController?
        let picker = PHPickerInstructionVideoPicker(present: { controller in
            presented = controller as? PHPickerViewController
        })
        picker.presentVideoPicker(makeStagedCopy: { _ in .failure(.cancelled) },
                                  completion: { _ in })
        let surface = try XCTUnwrap(presented,
                                    "the adapter must present a PHPickerViewController")
        XCTAssertEqual(surface.configuration.filter, .videos)
        XCTAssertEqual(surface.configuration.selectionLimit, 1)
        XCTAssertEqual(surface.configuration.preferredAssetRepresentationMode, .current)
        XCTAssertTrue(surface.configuration.preselectedAssetIdentifiers.isEmpty)
        picker.dismiss()
    }

    /// The library path is permission-free at source: no `PHPhotoLibrary`
    /// authorization request or status read, no photo-library usage key and no
    /// image filter. The source scan strips comments first.
    func testPickerRequestsNoPhotoLibraryPermission() {
        let code = captureAdapterSource()
        XCTAssertTrue(code.contains("PHPickerViewController"),
                      "positive control: the library surface is the system picker")
        XCTAssertTrue(code.contains("PHPickerConfiguration"),
                      "positive control: the picker is configured explicitly")
        XCTAssertTrue(code.contains("filter = .videos"),
                      "positive control: video mode is pinned")

        let forbidden = [
            "PHPhotoLibrary",
            "requestAuthorization",
            "authorizationStatus",
            "NSPhotoLibraryUsageDescription",
            ".images",
            "UTType.image",
            "PHPickerConfiguration(photoLibrary:",
        ]
        for token in forbidden {
            XCTAssertFalse(code.contains(token),
                           "PHPicker video mode must stay permission-free (\(token))")
        }

        let importLines = code
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        XCTAssertFalse(importLines.contains("import Photos"),
                       "the adapter never imports the photo-library framework")
    }

    /// The provider's callback-scoped URL is staged **during** the callback,
    /// once, before the completion reports. The callback URL is not retained.
    @MainActor
    func testPickerStagesDuringCallback() async throws {
        let source = try writeSource()
        let provider = makeFileProvider(at: source)
        let staged = makeStagedVideo()
        var events: [String] = []
        var stagedSource: URL?
        var stagedBytes: Data?
        var outcomes: [Result<StagedInstructionVideo, InstructionImportError>] = []
        var presented: PHPickerViewController?
        let picker = PHPickerInstructionVideoPicker(present: { controller in
            presented = controller as? PHPickerViewController
        })

        picker.presentVideoPicker(makeStagedCopy: { url in
            events.append("stage")
            stagedSource = url
            // The provider's temporary copy is deleted the moment its callback
            // returns, so the bytes must be read here — which is exactly the
            // callback-scoped contract this case pins.
            stagedBytes = try? Data(contentsOf: url)
            return .success(staged)
        }, completion: { outcome in
            events.append("complete")
            outcomes.append(outcome)
        })

        XCTAssertNotNil(presented, "the adapter must present through the injected closure")
        picker.loadAndStage(from: provider)
        await waitUntil("the provider load must finish inside its callback") {
            outcomes.count == 1
        }

        XCTAssertEqual(events, ["stage", "complete"],
                       "staging runs synchronously inside the provider callback, "
                           + "before the completion reports")
        let callbackURL = try XCTUnwrap(stagedSource,
                                        "the staging callback received the provider's URL")
        XCTAssertTrue(callbackURL.isFileURL)
        XCTAssertEqual(stagedBytes,
                       Data(repeating: 0xAB, count: 256),
                       "the callback staged the provider's own file bytes")
        XCTAssertEqual(outcomes, [.success(staged)])
        XCTAssertEqual(outcomes.count, 1, "completion fires exactly once")
    }

    /// Both system surfaces report cancellation as `.cancelled`, attempt no
    /// staging, and cannot double-report when dismissed twice. A provider
    /// cancellation maps to `.cancelled`, never to a staging failure.
    @MainActor
    func testPickerCancelReportsCancelled() async throws {
        // 1. Picker: empty results are the person's cancellation.
        var presented: PHPickerViewController?
        var stagedCalls = 0
        var pickerOutcomes: [Result<StagedInstructionVideo, InstructionImportError>] = []
        let picker = PHPickerInstructionVideoPicker(present: { controller in
            presented = controller as? PHPickerViewController
        })
        picker.presentVideoPicker(makeStagedCopy: { _ in
            stagedCalls += 1
            return .failure(.cancelled)
        }, completion: { pickerOutcomes.append($0) })

        let surface = try XCTUnwrap(presented)
        picker.picker(surface, didFinishPicking: [])
        XCTAssertEqual(pickerOutcomes, [.failure(.cancelled)])
        XCTAssertEqual(stagedCalls, 0, "cancellation attempts no staging")

        picker.dismiss()
        picker.dismiss()
        XCTAssertEqual(pickerOutcomes.count, 1,
                       "dismissal is idempotent and cannot double-report")

        // 2. Provider cancellation maps to cancelled.
        var providerOutcomes: [Result<StagedInstructionVideo, InstructionImportError>] = []
        picker.presentVideoPicker(makeStagedCopy: { _ in
            stagedCalls += 1
            return .failure(.cancelled)
        }, completion: { providerOutcomes.append($0) })
        picker.loadAndStage(from: makeCancelledProvider())
        await waitUntil("a cancelled provider load must report cancelled") {
            providerOutcomes.count == 1
        }
        XCTAssertEqual(providerOutcomes, [.failure(.cancelled)])
        XCTAssertEqual(stagedCalls, 0)

        // 3. The recorder's cancel callback reports cancelled and stages
        // nothing; its dismissal is idempotent too.
        var recorderSurface: UIImagePickerController?
        var recorderStagedCalls = 0
        var recorderOutcomes: [Result<StagedInstructionVideo, InstructionImportError>] = []
        let recorder = UIImagePickerInstructionVideoRecorder(present: { controller in
            recorderSurface = controller as? UIImagePickerController
        }, makeSurface: { _, _ in UIImagePickerController() })
        recorder.presentRecorder(maximumDurationSeconds: 180,
                                 quality: .high,
                                 makeStagedCopy: { _ in
                                     recorderStagedCalls += 1
                                     return .failure(.cancelled)
                                 },
                                 completion: { recorderOutcomes.append($0) })
        let camera = try XCTUnwrap(recorderSurface)
        recorder.imagePickerControllerDidCancel(camera)
        XCTAssertEqual(recorderOutcomes, [.failure(.cancelled)])
        XCTAssertEqual(recorderStagedCalls, 0, "a recorder cancel attempts no staging")
        recorder.dismiss()
        recorder.dismiss()
        XCTAssertEqual(recorderOutcomes.count, 1, "dismissal cannot double-report")
    }

    /// The recorder's platform maximum and quality are the configured ones
    /// (180 s / `.high` from `InstructionCaptureConfiguration.standard`), and
    /// the adapter passes the coordinator's duration straight through.
    ///
    /// The contract is asserted on the pure configuration value: a simulator
    /// has no camera, and `UIImagePickerController` raises when camera-only
    /// properties are set on an unavailable source. The device build applies
    /// this same value in `makeRecorder`.
    @MainActor
    func testRecorderMaximumDurationIs180() throws {
        let configuration = UIImagePickerInstructionVideoRecorder.configuration(
            maximumDurationSeconds: 180, quality: .high)
        XCTAssertEqual(configuration.maximumDurationSeconds, 180,
                       "the platform cap is the configured three minutes")
        XCTAssertEqual(configuration.videoQuality, .typeHigh,
                       "the configured quality reaches the platform")
        XCTAssertEqual(configuration.mediaTypes, [UTType.movie.identifier])
        XCTAssertEqual(configuration.sourceType, .camera)
        XCTAssertEqual(configuration.cameraCaptureMode, .video)

        let medium = UIImagePickerInstructionVideoRecorder.configuration(
            maximumDurationSeconds: 60, quality: .medium)
        XCTAssertEqual(medium.maximumDurationSeconds, 60)
        XCTAssertEqual(medium.videoQuality, .typeMedium)

        // The adapter presents the surface its factory supplies, with the
        // coordinator's configured duration passed straight through.
        var presented: UIImagePickerController?
        var requestedDuration: TimeInterval?
        var requestedQuality: InstructionRecordingQuality?
        let adapter = UIImagePickerInstructionVideoRecorder(present: { controller in
            presented = controller as? UIImagePickerController
        }, makeSurface: { duration, quality in
            requestedDuration = duration
            requestedQuality = quality
            return UIImagePickerController()
        })
        adapter.presentRecorder(maximumDurationSeconds: 180,
                                quality: .high,
                                makeStagedCopy: { _ in .failure(.cancelled) },
                                completion: { _ in })
        XCTAssertNotNil(try XCTUnwrap(presented))
        XCTAssertEqual(requestedDuration, 180)
        XCTAssertEqual(requestedQuality, .high)
        adapter.dismiss()
    }

    /// Camera and microphone are the recorder's only capture: camera source,
    /// video capture mode and the movie media type (whose camera session
    /// records audio). The adapter owns no audio-session or permission policy
    /// of its own.
    @MainActor
    func testRecorderUsesCameraAndMicrophone() {
        let configuration = UIImagePickerInstructionVideoRecorder.configuration(
            maximumDurationSeconds: 180, quality: .high)
        XCTAssertEqual(configuration.sourceType, .camera,
                       "the recorder is the camera, never a library surface")
        XCTAssertEqual(configuration.cameraCaptureMode, .video)
        XCTAssertEqual(configuration.mediaTypes, [UTType.movie.identifier],
                       "a movie is the only media type; the camera session records its audio track")

        let code = captureAdapterSource()
        let required = [
            "sourceType: .camera",
            "cameraCaptureMode: .video",
            "mediaTypes: [UTType.movie.identifier]",
            "maximumDurationSeconds: maximumDurationSeconds",
            "recorder.sourceType = configuration.sourceType",
        ]
        for token in required {
            XCTAssertTrue(code.contains(token),
                          "the camera/microphone contract must be pinned at source (\(token))")
        }

        let forbidden = [
            "AVAudioSession", "AVCaptureDevice", "AVCaptureSession",
            "setCategory", "recordPermission", "microphone",
        ]
        for token in forbidden {
            XCTAssertFalse(code.contains(token),
                           "the recorder must not own audio-session or permission policy (\(token))")
        }
    }

    /// No photo-library source, capture mode, media type or permission exists
    /// in the recorder, and no image path exists in either adapter.
    @MainActor
    func testRecorderHasNoPhotoLibraryMode() {
        let configuration = UIImagePickerInstructionVideoRecorder.configuration(
            maximumDurationSeconds: 180, quality: .high)
        XCTAssertNotEqual(configuration.sourceType, .photoLibrary)
        XCTAssertNotEqual(configuration.sourceType, .savedPhotosAlbum)
        XCTAssertNotEqual(configuration.cameraCaptureMode, .photo)

        let code = captureAdapterSource()
        let forbidden = [
            "sourceType = .photoLibrary",
            "sourceType = .savedPhotosAlbum",
            "cameraCaptureMode = .photo",
            "UIImagePickerControllerSourceTypePhotoLibrary",
            "PHPickerConfiguration(photoLibrary:",
            ".images",
            "PHPhotoLibrary",
            "UTType.image",
            "NSPhotoLibraryUsageDescription",
        ]
        for token in forbidden {
            XCTAssertFalse(code.contains(token),
                           "no photo-library path may exist in either adapter (\(token))")
        }
    }

    /// A failed staged copy is reported with its typed storage cause, never
    /// swallowed: the picker and the recorder both complete exactly once with
    /// `writeFailed(.stagingFailed)`.
    @MainActor
    func testStagingFailurePropagates() async throws {
        let source = try writeSource()
        let stagedFailure = InstructionImportError.writeFailed(.stagingFailed)

        var pickerOutcomes: [Result<StagedInstructionVideo, InstructionImportError>] = []
        let picker = PHPickerInstructionVideoPicker(present: { _ in })
        picker.presentVideoPicker(makeStagedCopy: { _ in .failure(stagedFailure) },
                                  completion: { pickerOutcomes.append($0) })
        picker.loadAndStage(from: makeFileProvider(at: source))
        await waitUntil("a failed staging must be reported, not swallowed") {
            pickerOutcomes.count == 1
        }
        XCTAssertEqual(pickerOutcomes, [.failure(stagedFailure)],
                       "the picker reports writeFailed with the storage cause")
        XCTAssertEqual(pickerOutcomes.count, 1)

        // A provider with no movie representation cannot stage either.
        var unavailableOutcomes: [Result<StagedInstructionVideo, InstructionImportError>] = []
        picker.presentVideoPicker(makeStagedCopy: { _ in .failure(stagedFailure) },
                                  completion: { unavailableOutcomes.append($0) })
        picker.loadAndStage(from: NSItemProvider())
        XCTAssertEqual(unavailableOutcomes, [.failure(stagedFailure)])
        XCTAssertEqual(unavailableOutcomes.count, 1)

        // A provider load that genuinely fails (not a cancellation) is a
        // staging failure too; Foundation wraps the loader's error.
        var failedOutcomes: [Result<StagedInstructionVideo, InstructionImportError>] = []
        picker.presentVideoPicker(makeStagedCopy: { _ in .failure(stagedFailure) },
                                  completion: { failedOutcomes.append($0) })
        picker.loadAndStage(from: makeFailedProvider())
        await waitUntil("a failed provider load must report a staging failure") {
            failedOutcomes.count == 1
        }
        XCTAssertEqual(failedOutcomes, [.failure(stagedFailure)])
        XCTAssertEqual(failedOutcomes.count, 1)

        // The recorder propagates the same typed failure from its delegate.
        var presented: UIImagePickerController?
        var recorderOutcomes: [Result<StagedInstructionVideo, InstructionImportError>] = []
        var recorderStaged = 0
        let recorder = UIImagePickerInstructionVideoRecorder(present: { controller in
            presented = controller as? UIImagePickerController
        }, makeSurface: { _, _ in UIImagePickerController() })
        recorder.presentRecorder(maximumDurationSeconds: 180,
                                 quality: .high,
                                 makeStagedCopy: { _ in
                                     recorderStaged += 1
                                     return .failure(stagedFailure)
                                 },
                                 completion: { recorderOutcomes.append($0) })
        let camera = try XCTUnwrap(presented)
        recorder.imagePickerController(camera,
                                       didFinishPickingMediaWithInfo: [.mediaURL: source])
        XCTAssertEqual(recorderStaged, 1)
        XCTAssertEqual(recorderOutcomes, [.failure(stagedFailure)])
        XCTAssertEqual(recorderOutcomes.count, 1)
    }

    /// The adapter keeps no URL or item provider after its callback returns,
    /// and its provider callback holds only a weak reference to it. A source
    /// pin proves there is no stored URL/provider property at all and that the
    /// only hop is a synchronous main hop.
    @MainActor
    func testNoCallbackScopedURLIsRetained() async throws {
        let source = try writeSource()
        let staged = makeStagedVideo()
        var outcomes: [Result<StagedInstructionVideo, InstructionImportError>] = []
        var adapter: PHPickerInstructionVideoPicker? = PHPickerInstructionVideoPicker(present: { _ in })
        let weakAdapter = WeakInstructionCaptureAdapter(adapter)
        adapter?.presentVideoPicker(makeStagedCopy: { _ in .success(staged) },
                                    completion: { outcomes.append($0) })
        adapter?.loadAndStage(from: makeFileProvider(at: source))
        await waitUntil("the provider load must finish") { outcomes.count == 1 }

        // Scoped so no local strong reference outlives the release below;
        // the deallocation check is about the adapter, not the test.
        do {
            let finished = try XCTUnwrap(adapter)
            XCTAssertFalse(retainsCallbackScopedValue(finished),
                           "the adapter retains neither the callback-scoped URL nor the item provider")
        }
        XCTAssertEqual(outcomes, [.success(staged)])

        adapter = nil
        await waitUntil("a finished adapter must not be retained by its provider callback") {
            weakAdapter.value == nil
        }

        let code = captureAdapterSource()
        XCTAssertFalse(code.contains("var sourceURL"))
        XCTAssertFalse(code.contains("var callbackURL"))
        XCTAssertFalse(code.contains("var itemProvider"))
        XCTAssertFalse(code.contains("var provider"))
        XCTAssertTrue(code.contains("DispatchQueue.main.sync"),
                      "the only hop from the provider callback is a synchronous main hop")
        XCTAssertFalse(code.contains("DispatchQueue.main.async"),
                       "an async hop would outlive the callback-scoped URL")
    }

    /// The combined design pins for both adapters: the exact guarded imports,
    /// one provider load site, and no player, transcode, upload, network,
    /// share-sheet, photo-permission or logging path (§11.3 P).
    func testAdaptersSourcePinsMatchDesign() {
        let code = captureAdapterSource()

        let required = [
            "final class PHPickerInstructionVideoPicker",
            "final class UIImagePickerInstructionVideoRecorder",
            "func presentVideoPicker",
            "func presentRecorder",
            "loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier)",
            "static func makeConfiguration",
            "static func makeRecorder",
            "MainActor.assumeIsolated",
        ]
        for token in required {
            XCTAssertTrue(code.contains(token),
                          "the design contract must stay present (\(token))")
        }

        let loadSites = code.components(separatedBy: "loadFileRepresentation(").count - 1
        XCTAssertEqual(loadSites, 1,
                       "one provider load path: the single callback-scoped staging site")

        // Every UIKit/PhotosUI/UTType import sits inside the single
        // `#if os(iOS)` guard that wraps the whole file.
        let guardedImports = """
        #if os(iOS)
        import Foundation
        import PhotosUI
        import UIKit
        import UniformTypeIdentifiers
        """
        XCTAssertTrue(code.hasPrefix(guardedImports),
                      "the file opens with #if os(iOS) and imports inside it")
        XCTAssertEqual(code.components(separatedBy: "#if os(iOS)").count - 1, 1,
                       "exactly one os(iOS) guard")
        XCTAssertEqual(code.components(separatedBy: "#endif").count - 1, 1)
        XCTAssertTrue(code.trimmingCharacters(in: .whitespacesAndNewlines)
                        .hasSuffix("#endif"),
                      "the os(iOS) guard closes at the end of the file")

        let forbidden = [
            "AVPlayer", "AVPlayerItem", "AVAssetExportSession", "AVAssetWriter",
            "AVAudioSession", "AVKit", "AVCaptureSession", "AVCaptureDevice",
            "PHPhotoLibrary", "PHAsset", "NSPhotoLibraryUsageDescription",
            "UIActivityViewController", "URLSession", "upload", "transcribe",
            "isExcludedFromBackup", "videoExportPreset", "FileManager",
            "print(", "debugPrint", "NSLog", "os_log", "Logger",
            "localizedDescription", "url.path", "DispatchQueue.main.async",
        ]
        for token in forbidden {
            XCTAssertFalse(code.contains(token),
                           "no player/transcode/upload/network/permission/logging path (\(token))")
        }
    }

    // MARK: - Helpers

    @MainActor
    private func makeCoordinator(
        root: InstructionRoot = .routines,
        importer: InstructionVideoImporting,
        permissions: InstructionPermissionRequesting = CapturePermissionRequester(),
        makePicker: @escaping @MainActor () -> InstructionVideoPicking = { FakeInstructionVideoPicker() },
        makeRecorder: @escaping @MainActor () -> InstructionVideoRecording = { FakeInstructionVideoRecorder() },
        bus: RecordingCaptureBus = RecordingCaptureBus(),
        clock: CaptureClock = CaptureClock()
    ) -> InstructionVideoCaptureCoordinator {
        InstructionVideoCaptureCoordinator(
            root: root,
            store: store,
            importer: importer,
            permissions: permissions,
            makePicker: makePicker,
            makeRecorder: makeRecorder,
            configuration: .standard,
            events: InstructionObservability(bus: bus),
            probe: { _ in .success(CaptureTestValues.metadata) },
            now: { clock.now })
    }

    /// Drives one accepted pick and returns the coordinator, the accepted
    /// value and the staged draft so a test can assert on all three.
    @MainActor
    private func makeReadyCoordinator() async throws
        -> (InstructionVideoCaptureCoordinator, AcceptedInstructionVideo, StagedInstructionVideo) {
        let picker = FakeInstructionVideoPicker()
        let source = try writeSource()
        var staged: StagedInstructionVideo?
        picker.script = { makeStagedCopy, completion in
            let result = makeStagedCopy(source)
            staged = try? result.get()
            completion(result)
        }
        let coordinator = makeCoordinator(importer: acceptingImporter(),
                                          makePicker: { picker })
        coordinator.pick()

        let stagedValue = try XCTUnwrap(staged)
        let accepted = AcceptedInstructionVideo(staged: stagedValue,
                                                validatedAt: CaptureTestValues.date)
        await waitUntil("the coordinator must reach ready") {
            coordinator.state == .ready(accepted)
        }
        return (coordinator, accepted, stagedValue)
    }

    private func acceptingImporter(validatedAt: Date = CaptureTestValues.date)
        -> ScriptedInstructionImporter {
        ScriptedInstructionImporter { staged in
            .success(AcceptedInstructionVideo(staged: staged, validatedAt: validatedAt))
        }
    }

    private func failingImporter(_ error: InstructionImportError) -> ScriptedInstructionImporter {
        ScriptedInstructionImporter { _ in .failure(error) }
    }

    /// Writes real source bytes outside any store root, exactly as a system
    /// callback URL would point at a temporary file.
    private func writeSource(bytes: Data = Data(repeating: 0xAB, count: 256),
                             name: String = "clip.mov") throws -> URL {
        let url = tempDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)", isDirectory: false)
        try bytes.write(to: url)
        return url
    }

    /// The number of per-attempt draft directories under a root's `_pending`.
    /// One per successful staging attempt, zero after discard.
    private func pendingDraftCount(root: InstructionRoot = .routines) -> Int {
        let pending = tempDirectory
            .appendingPathComponent(root.rawValue, isDirectory: true)
            .appendingPathComponent(InstructionVideoStore.pendingDirectoryName, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: pending.path) else {
            return 0
        }
        return children.count
    }

    /// Holds a weak reference so a test can prove a finished adapter is not
    /// retained by its provider callback.
    private final class WeakInstructionCaptureAdapter {
        weak var value: PHPickerInstructionVideoPicker?

        init(_ value: PHPickerInstructionVideoPicker?) {
            self.value = value
        }
    }

    /// The production adapter file's text with comments stripped, so a
    /// documentation mention cannot satisfy or trip a pin.
    private func captureAdapterSource() -> String {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/App/InstructionCapture.swift")
        let code = FeatureSourceScan.codeText(of: url)
        XCTAssertFalse(code.isEmpty,
                       "the adapter source scan must actually read InstructionCapture.swift")
        return code
    }

    /// A staged value the adapter can hand back without the store: the
    /// adapters never touch the bytes, they only relay the callback's result.
    private func makeStagedVideo() -> StagedInstructionVideo {
        StagedInstructionVideo(
            draftId: UUID(),
            root: .routines,
            stagedURL: tempDirectory.appendingPathComponent("\(UUID().uuidString).mov"),
            byteCount: 256,
            metadata: CaptureTestValues.metadata,
            sourceExtension: "mov",
            stagedAt: CaptureTestValues.date)
    }

    /// A real item provider with an in-process movie file representation, so
    /// the adapter's provider seam runs without a PHPicker sheet. The
    /// provider's copy is what the staging callback must receive.
    private func makeFileProvider(at url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.movie.identifier,
                                            fileOptions: [],
                                            visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    /// A provider whose load reports Foundation's user-cancellation error.
    private func makeCancelledProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.movie.identifier,
                                            fileOptions: [],
                                            visibility: .all) { completion in
            completion(nil, false,
                       NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            return nil
        }
        return provider
    }

    /// A provider whose load reports an ordinary (non-cancellation) failure.
    private func makeFailedProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.movie.identifier,
                                            fileOptions: [],
                                            visibility: .all) { completion in
            completion(nil, false,
                       NSError(domain: "InstructionCaptureTests", code: 42))
            return nil
        }
        return provider
    }

    /// True when a value's stored-property graph contains a URL or an item
    /// provider — exactly the callback-scoped values an adapter must not keep.
    private func retainsCallbackScopedValue(_ value: Any) -> Bool {
        if value is URL || value is NSItemProvider { return true }
        for child in Mirror(reflecting: value).children
        where retainsCallbackScopedValue(child.value) {
            return true
        }
        return false
    }

    /// Polls a main-actor condition; the timeout only trips when a test is
    /// genuinely stuck. Polling yields the main actor, so the coordinator's
    /// unstructured tasks make progress.
    @MainActor
    private func waitUntil(_ message: String,
                           timeout: TimeInterval = 3,
                           _ condition: () -> Bool) async {
        let limit = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= limit {
                XCTFail(message)
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// One bounded main-actor yield for state changes that have no observable
    /// counter of their own (the late validation after cancellation).
    @MainActor
    private func settle() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}

// MARK: - Closed test values

private enum CaptureTestValues {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let metadata = InstructionVideoMetadata(durationSeconds: 30,
                                                   hasVideoTrack: true,
                                                   isPlayable: true)
}

/// The callback types the capture protocols hand to an adapter. Named once so
/// the doubles and the scripting closures agree on the isolation.
private typealias CaptureStagingClosure =
    @MainActor (URL) -> Result<StagedInstructionVideo, InstructionImportError>
private typealias CaptureCompletionClosure =
    @MainActor (Result<StagedInstructionVideo, InstructionImportError>) -> Void
private typealias CaptureScript = @MainActor (CaptureStagingClosure, CaptureCompletionClosure) -> Void

/// An injectable clock: the coordinator's only use of `now()` is the accepted
/// import's `duration_ms`, so a test can advance it deterministically.
private final class CaptureClock {
    var now: Date

    init(now: Date = CaptureTestValues.date) {
        self.now = now
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

// MARK: - Doubles (design §11.4)

/// §11.4 `FakeInstructionVideoPicker`: scripts picked/cancelled/failed,
/// records presentation and dismissal, and exposes the two callbacks so a
/// test can stage inside the callback and hold or deliver completion.
@MainActor
private final class FakeInstructionVideoPicker: InstructionVideoPicking {
    private(set) var presentCount = 0
    private(set) var dismissCount = 0
    private(set) var makeStagedCopy: CaptureStagingClosure?
    private(set) var completion: CaptureCompletionClosure?
    var script: CaptureScript?

    func presentVideoPicker(makeStagedCopy: @escaping CaptureStagingClosure,
                            completion: @escaping CaptureCompletionClosure) {
        presentCount += 1
        self.makeStagedCopy = makeStagedCopy
        self.completion = completion
        script?(makeStagedCopy, completion)
    }

    func dismiss() {
        dismissCount += 1
    }
}

/// §11.4 `FakeInstructionVideoRecorder`: the same script shape plus the
/// duration/quality it was configured with and whether it was presented.
@MainActor
private final class FakeInstructionVideoRecorder: InstructionVideoRecording {
    private(set) var presentCount = 0
    private(set) var dismissCount = 0
    private(set) var maximumDurations: [TimeInterval] = []
    private(set) var qualities: [InstructionRecordingQuality] = []
    private(set) var makeStagedCopy: CaptureStagingClosure?
    private(set) var completion: CaptureCompletionClosure?
    var script: CaptureScript?

    func presentRecorder(maximumDurationSeconds: TimeInterval,
                         quality: InstructionRecordingQuality,
                         makeStagedCopy: @escaping CaptureStagingClosure,
                         completion: @escaping CaptureCompletionClosure) {
        presentCount += 1
        maximumDurations.append(maximumDurationSeconds)
        qualities.append(quality)
        self.makeStagedCopy = makeStagedCopy
        self.completion = completion
        script?(makeStagedCopy, completion)
    }

    func dismiss() {
        dismissCount += 1
    }
}

/// Records every `status`/`request` call in order and scripts each answer.
/// Mirrors T-006's `RecordingPermissionRequester`; the counts make the M-1
/// "zero microphone requests/reads" assertions explicit.
private final class CapturePermissionRequester: InstructionPermissionRequesting, @unchecked Sendable {
    enum Call: Equatable {
        case status(InstructionMediaPermission)
        case request(InstructionMediaPermission)
    }

    private(set) var calls: [Call] = []

    var cameraStatus: InstructionPermissionStatus = .undetermined
    var microphoneStatus: InstructionPermissionStatus = .undetermined
    var cameraRequestOutcome: InstructionPermissionStatus = .granted
    var microphoneRequestOutcome: InstructionPermissionStatus = .granted

    func status(for permission: InstructionMediaPermission) async -> InstructionPermissionStatus {
        calls.append(.status(permission))
        switch permission {
        case .camera: return cameraStatus
        case .microphone: return microphoneStatus
        }
    }

    func request(_ permission: InstructionMediaPermission) async -> InstructionPermissionStatus {
        calls.append(.request(permission))
        switch permission {
        case .camera: return cameraRequestOutcome
        case .microphone: return microphoneRequestOutcome
        }
    }

    var requestCount: Int {
        calls.filter { call in
            if case .request = call { return true }
            return false
        }.count
    }

    var microphoneRequestCount: Int {
        calls.filter { call in
            if case .request(.microphone) = call { return true }
            return false
        }.count
    }

    var microphoneReadCount: Int {
        calls.filter { call in
            if case .status(.microphone) = call { return true }
            return false
        }.count
    }
}

/// The importer double used by the success and failure cases. `result` is
/// assignable between attempts so one coordinator can drive several outcomes.
/// It never discards: that is the point of the coordinator's defensive
/// discard in the failure path.
private final class ScriptedInstructionImporter: InstructionVideoImporting, @unchecked Sendable {
    private let lock = NSLock()
    private var validated: [StagedInstructionVideo] = []
    var result: (StagedInstructionVideo) -> Result<AcceptedInstructionVideo, InstructionImportError>

    init(_ result: @escaping (StagedInstructionVideo) -> Result<AcceptedInstructionVideo, InstructionImportError>) {
        self.result = result
    }

    func validate(_ staged: StagedInstructionVideo,
                  limits: InstructionVideoLimits) async -> Result<AcceptedInstructionVideo, InstructionImportError> {
        lock.lock()
        validated.append(staged)
        lock.unlock()
        return result(staged)
    }

    var validatedStaged: [StagedInstructionVideo] {
        lock.lock()
        defer { lock.unlock() }
        return validated
    }
}

/// An importer that stays suspended until the test resolves it. It ignores
/// task cancellation on purpose: `testCancelDuringValidationDiscardsStaged`
/// needs a validation that *does* resolve after `cancel()` to prove the
/// coordinator discards the late acceptance instead of handing it to an
/// editor. Started/finished are locked counters.
private final class SuspendedInstructionImporter: InstructionVideoImporting, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<AcceptedInstructionVideo, InstructionImportError>, Never>?
    private var buffered: Result<AcceptedInstructionVideo, InstructionImportError>?
    private var pendingStaged: StagedInstructionVideo?
    private var started = 0
    private var finished = 0

    func validate(_ staged: StagedInstructionVideo,
                  limits: InstructionVideoLimits) async -> Result<AcceptedInstructionVideo, InstructionImportError> {
        lock.lock()
        started += 1
        pendingStaged = staged
        lock.unlock()

        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<AcceptedInstructionVideo, InstructionImportError>, Never>) in
            lock.lock()
            if let buffered {
                self.buffered = nil
                lock.unlock()
                continuation.resume(returning: buffered)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        lock.lock()
        finished += 1
        lock.unlock()
        return result
    }

    /// Resolves the suspended validation with an accepted value built from
    /// the staged draft it was given. Safe to call after `cancel()`.
    func resolveAccepting(validatedAt: Date) {
        lock.lock()
        let staged = pendingStaged
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        guard let staged else { return }
        let result = Result<AcceptedInstructionVideo, InstructionImportError>.success(
            AcceptedInstructionVideo(staged: staged, validatedAt: validatedAt))
        if let continuation {
            continuation.resume(returning: result)
        } else {
            lock.lock()
            buffered = result
            lock.unlock()
        }
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
}

/// The recording bus for the event assertions. Every emit happens on the main
/// actor in production; the tests read the array from the same actor.
private final class RecordingCaptureBus: ObservabilityBus {
    private(set) var allEvents: [ObservabilityEvent] = []

    func emit(_ event: ObservabilityEvent) {
        allEvents.append(event)
    }

    func events(named eventType: String) -> [ObservabilityEvent] {
        allEvents.filter { $0.eventType == eventType }
    }

    func reset() {
        allEvents.removeAll()
    }
}
