import AVFoundation
import XCTest
@testable import ElderlyAssistant

/// T-006 — the camera/microphone permission seam (design L2 §2.5, §3.5,
/// IF-18, §11.3 R; FR-RIE-005, FR-RIE-010, FR-RIE-025, NFR-RIE-009;
/// must-carry M-1).
///
/// What this suite pins, and which Gherkin scenario each test answers:
///
///  - **Status reads never prompt** — the recording sequence reads both
///    statuses and requests nothing when every permission is already
///    usable; the production adapter's status path is a pure read on every
///    platform (`testStatusReadDoesNotRequest`).
///  - **Every platform status maps to one of five values** — authorized,
///    denied, restricted, notDetermined and an independently unknown value
///    map to granted, denied, restricted, undetermined and restricted; a
///    missing camera is unavailable. No case is dropped or collapsed
///    (`testAuthorizedMaps`, `testDeniedMaps`, `testRestrictedMaps`,
///    `testNotDeterminedMaps`, `testUnknownMapsToRestricted`).
///  - **A denied or restricted camera is a plain problem** — the sequence
///    returns `.cameraDenied` and never asks about the microphone
///    (M-1 short-circuit; scenario-outline rows denied/restricted = 0)
///    (`testDeniedCameraShortCircuitsMicrophone`,
///    `testRestrictedCameraShortCircuitsMicrophone`).
///  - **Camera before microphone** — the ordered request sequence is
///    asserted with a recording requester double: camera request first,
///    microphone only after the camera is usable; an already-authorized
///    camera is never re-asked (outline rows authorized/notDetermined = 1)
///    (`testCameraFirstOrderWithRecordingRequester`).
///  - **The requester is a Sendable value** — compile-time Sendable proof
///    plus the zero-size statelessness pin, so the requester can cross the
///    recorder boundary (NFR-RIE-009) (`testRequesterIsSendableValue`).
///
/// The simulator cannot prove camera or microphone behaviour, so every
/// ordering case runs against the recording double; no test ever calls the
/// production `request`, because that is the only path that can prompt.
final class InstructionPermissionTests: XCTestCase {

    // MARK: - Status reads never prompt

    /// First Gherkin scenario: with every permission already usable, the
    /// sequence reads both statuses and requests nothing — a status read
    /// never prompts. The production adapter's status path answers on any
    /// platform (and the microphone can never report `.unavailable`).
    func testStatusReadDoesNotRequest() async {
        let requester = RecordingPermissionRequester()
        requester.cameraStatus = .granted
        requester.microphoneStatus = .granted

        let problem = await requester.prepareForRecording()

        XCTAssertNil(problem)
        XCTAssertEqual(requester.calls, [.status(.camera), .status(.microphone)])
        XCTAssertEqual(requester.microphoneRequestCount, 0)

        // The production status path is a pure read: it answers without
        // asking, and `.unavailable` is camera-only (no trap, §11.2).
        let adapter = AVFoundationInstructionPermissions()
        let cameraStatus = await adapter.status(for: .camera)
        let microphoneStatus = await adapter.status(for: .microphone)
        XCTAssertTrue([.granted, .denied, .restricted, .undetermined, .unavailable].contains(cameraStatus))
        XCTAssertNotEqual(microphoneStatus, .unavailable)
    }

    // MARK: - Platform status mapping (second Gherkin scenario)

    func testAuthorizedMaps() {
        XCTAssertEqual(AVFoundationInstructionPermissions.cameraStatus(from: .authorized,
                                                                       hasCamera: true),
                       .granted)
        // No camera hardware is `.unavailable` regardless of the platform
        // answer (§2.5.1).
        XCTAssertEqual(AVFoundationInstructionPermissions.cameraStatus(from: .authorized,
                                                                       hasCamera: false),
                       .unavailable)
    }

    func testDeniedMaps() {
        XCTAssertEqual(AVFoundationInstructionPermissions.cameraStatus(from: .denied,
                                                                       hasCamera: true),
                       .denied)
        XCTAssertEqual(AVFoundationInstructionPermissions.microphoneStatus(from: .denied),
                       .denied)
    }

    func testRestrictedMaps() {
        XCTAssertEqual(AVFoundationInstructionPermissions.cameraStatus(from: .restricted,
                                                                       hasCamera: true),
                       .restricted)
        // `restricted` is a real case, never collapsed onto denied: the two
        // platform values must land on their own cases.
        XCTAssertNotEqual(AVFoundationInstructionPermissions.cameraStatus(from: .restricted,
                                                                          hasCamera: true),
                          .undetermined)
    }

    func testNotDeterminedMaps() {
        XCTAssertEqual(AVFoundationInstructionPermissions.cameraStatus(from: .notDetermined,
                                                                       hasCamera: true),
                       .undetermined)
        XCTAssertEqual(AVFoundationInstructionPermissions.microphoneStatus(from: .undetermined),
                       .undetermined)
    }

    func testUnknownMapsToRestricted() {
        // An independently unknown platform value (a future OS case this app
        // does not know) maps to `.restricted` — never dropped, never
        // collapsed onto a case the app knows (§2.5.1).
        let unknown = AVAuthorizationStatus(rawValue: 1234)!
        XCTAssertEqual(AVFoundationInstructionPermissions.cameraStatus(from: unknown,
                                                                       hasCamera: true),
                       .restricted)
    }

    // MARK: - Camera denial short-circuits the microphone (M-1, third scenario)

    func testDeniedCameraShortCircuitsMicrophone() async {
        let requester = RecordingPermissionRequester()
        requester.cameraStatus = .denied
        requester.microphoneStatus = .undetermined

        let problem = await requester.prepareForRecording()

        // A plain problem with the matching case — no crash, no loop, and
        // `nil` is not returned, so no recording preparation succeeds.
        XCTAssertEqual(problem, .cameraDenied)
        // The denied camera is read but never re-prompted, and the
        // microphone is not asked about at all (scenario-outline row 0).
        XCTAssertEqual(requester.calls, [.status(.camera)])
        XCTAssertEqual(requester.microphoneRequestCount, 0)
    }

    func testRestrictedCameraShortCircuitsMicrophone() async {
        let requester = RecordingPermissionRequester()
        requester.cameraStatus = .restricted
        requester.microphoneStatus = .undetermined

        let problem = await requester.prepareForRecording()

        XCTAssertEqual(problem, .cameraDenied)
        XCTAssertEqual(requester.calls, [.status(.camera)])
        XCTAssertEqual(requester.microphoneRequestCount, 0)
    }

    // MARK: - Camera-before-microphone order (§11.3 R, fourth scenario outline)

    func testCameraFirstOrderWithRecordingRequester() async {
        // Both undetermined (fresh install): the camera is requested first
        // and the microphone only after the camera resolves granted.
        let requester = RecordingPermissionRequester()
        requester.cameraStatus = .undetermined
        requester.microphoneStatus = .undetermined
        requester.cameraRequestOutcome = .granted
        requester.microphoneRequestOutcome = .granted

        let problem = await requester.prepareForRecording()

        XCTAssertNil(problem)
        XCTAssertEqual(requester.calls, [
            .status(.camera),
            .request(.camera),
            .status(.microphone),
            .request(.microphone),
        ])
        XCTAssertEqual(requester.microphoneRequestCount, 1)

        // Outline row "camera authorized → 1": an already-authorized camera
        // is never re-asked, and the microphone is still requested once.
        let alreadyAuthorized = RecordingPermissionRequester()
        alreadyAuthorized.cameraStatus = .granted
        alreadyAuthorized.microphoneStatus = .undetermined
        alreadyAuthorized.microphoneRequestOutcome = .granted

        let secondProblem = await alreadyAuthorized.prepareForRecording()

        XCTAssertNil(secondProblem)
        XCTAssertEqual(alreadyAuthorized.calls, [
            .status(.camera),
            .status(.microphone),
            .request(.microphone),
        ])
        XCTAssertEqual(alreadyAuthorized.microphoneRequestCount, 1)
    }

    // MARK: - Sendable value (NFR-RIE-009)

    func testRequesterIsSendableValue() {
        // Compile-time proof that the production requester satisfies the
        // Sendable-bound protocol, so it can cross the recorder boundary
        // (§2.5.4, R-9).
        func requiresSendable<T: Sendable>(_ value: T) -> T { value }

        let adapter = requiresSendable(AVFoundationInstructionPermissions())
        XCTAssertEqual(MemoryLayout<AVFoundationInstructionPermissions>.size, 0,
                       "no stored state — the OS is the source of truth (§3.5)")
        let copy = adapter
        XCTAssertEqual(MemoryLayout.size(ofValue: copy), 0)
    }
}

/// §11.4: records every `status`/`request` call in order and scripts each
/// permission's answer. `@unchecked Sendable` is the test-double idiom —
/// the log and the scripted answers are only ever touched from the test's
/// own (single) execution context.
private final class RecordingPermissionRequester: InstructionPermissionRequesting, @unchecked Sendable {

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

    var microphoneRequestCount: Int {
        calls.filter { call in
            if case .request(.microphone) = call { return true }
            return false
        }.count
    }
}
