import AVFoundation

/// C05 — the camera and microphone permission seam (design L2 §2.5, §3.5,
/// IF-18; FR-RIE-005, FR-RIE-025; must-carry M-1).
///
/// The capture coordinator consults this seam and never calls AVFoundation
/// authorization directly. Reading status never prompts; requesting is
/// explicit and asks the OS only for an undetermined permission. No
/// AVFoundation error, status or type escapes the seam: every answer is a
/// value, and no user content or path is ever logged from this file.

/// The two media permissions the recording path asks for, in the locked
/// order (§2.5.3): camera first, microphone second.
enum InstructionMediaPermission: Equatable {
    case camera
    case microphone
}

/// The five-case status (§3.5, R-9). `restricted` is a real case, not a
/// denial: its copy differs (T-007 owns the mapping) and it follows the
/// same no-re-prompt rule as a denial. `unavailable` is returned only for
/// the camera — no camera hardware — and can never be reported for the
/// microphone (no `unavailable` trap, §11.2).
enum InstructionPermissionStatus: Equatable {
    case granted
    case denied
    case restricted
    case undetermined
    case unavailable        // no camera hardware / cannot present
}

/// The plain problem a failed recording preparation reports (§2.4.3).
/// A denial is not an error state: it is a value beside an idle sheet, and
/// the plain permission line is the whole response. T-007 owns the copy.
enum InstructionPermissionProblem: Equatable {
    case cameraDenied
    case microphoneDenied
    case cameraUnavailable
}

/// IF-18. Value-encoded status; `Sendable` so the requester can cross the
/// recorder boundary (§2.5.4, R-9). `status` never prompts, and `request`
/// never throws and never traps on a denied state (§2.5.2).
protocol InstructionPermissionRequesting: Sendable {
    func status(for permission: InstructionMediaPermission) async -> InstructionPermissionStatus
    func request(_ permission: InstructionMediaPermission) async -> InstructionPermissionStatus
}

/// The production seam over `AVCaptureDevice` and `AVAudioSession`.
/// A stateless value: the OS is the source of truth (§3.5), so every call
/// re-reads it.
///
/// Reads map the OS answer to the five-case status and never prompt.
/// `request` asks the OS only when the platform status is undetermined;
/// an already-granted, denied or restricted permission is returned as-is
/// (the OS will not re-prompt).
struct AVFoundationInstructionPermissions: InstructionPermissionRequesting {
    init() {}

    func status(for permission: InstructionMediaPermission) async -> InstructionPermissionStatus {
        switch permission {
        case .camera:
            return Self.cameraStatus(from: Self.platformCameraStatus(),
                                     hasCamera: Self.hasCameraHardware())
        case .microphone:
            return Self.microphoneStatus(from: Self.platformMicrophoneStatus())
        }
    }

    func request(_ permission: InstructionMediaPermission) async -> InstructionPermissionStatus {
        switch permission {
        case .camera:
            // No camera hardware means there is nothing to ask for and no
            // recorder to present.
            guard Self.hasCameraHardware() else { return .unavailable }
            switch Self.platformCameraStatus() {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined:
                let granted = await Self.requestCameraAccess()
                return granted ? .granted : .denied
            @unknown default:
                // A future OS case is a restriction, never a prompt.
                return .restricted
            }
        case .microphone:
            switch Self.platformMicrophoneStatus() {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined:
                let granted = await Self.requestMicrophoneAccess()
                return granted ? .granted : .denied
            @unknown default:
                return .restricted
            }
        }
    }
}

// MARK: - Platform mapping (§2.5.1)

extension AVFoundationInstructionPermissions {
    /// Maps the platform camera answer to the five-case status. No camera
    /// hardware is `.unavailable` regardless of the platform answer; an
    /// unknown platform value maps to `.restricted` — never dropped and
    /// never collapsed onto a case the app knows (§2.5.1).
    static func cameraStatus(from platformStatus: AVAuthorizationStatus,
                             hasCamera: Bool) -> InstructionPermissionStatus {
        guard hasCamera else { return .unavailable }
        switch platformStatus {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .undetermined
        @unknown default: return .restricted
        }
    }

    /// Maps the platform microphone answer. `AVAudioSession` has no
    /// restricted case of its own, and this function never returns
    /// `.unavailable` — the microphone can always be asked about
    /// (§11.2 "no unavailable trap").
    static func microphoneStatus(from platformStatus: AVAudioSession.RecordPermission) -> InstructionPermissionStatus {
        switch platformStatus {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .restricted
        }
    }
}

// MARK: - The locked recording sequence (§2.5.3, M-1)

extension InstructionPermissionRequesting {
    /// FR-RIE-025 / M-1: camera first, microphone only after the camera is
    /// usable. Reads each status (a read never prompts) and requests only
    /// the undetermined permission. A camera denial or restriction
    /// short-circuits — the microphone is never asked about — and the
    /// matching problem is returned; `nil` means both permissions are
    /// usable for recording.
    ///
    /// T-009's capture coordinator calls this from `record()`; it is the
    /// single implementation of the order, so the coordinator cannot drift
    /// from it.
    func prepareForRecording() async -> InstructionPermissionProblem? {
        let cameraStatus = await status(for: .camera)
        let resolvedCamera = cameraStatus == .undetermined
            ? await request(.camera)
            : cameraStatus

        switch resolvedCamera {
        case .granted:
            break
        case .denied, .restricted:
            return .cameraDenied
        case .unavailable:
            return .cameraUnavailable
        case .undetermined:
            // A request that still answers undetermined is not usable.
            return .cameraDenied
        }

        let microphoneStatus = await status(for: .microphone)
        let resolvedMicrophone = microphoneStatus == .undetermined
            ? await request(.microphone)
            : microphoneStatus

        return resolvedMicrophone == .granted ? nil : .microphoneDenied
    }
}

// MARK: - Platform reads and prompts (R-9)

private extension AVFoundationInstructionPermissions {
    /// A pure read; never prompts.
    static func platformCameraStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// A pure read; never prompts.
    static func platformMicrophoneStatus() -> AVAudioSession.RecordPermission {
        AVAudioSession.sharedInstance().recordPermission
    }

    /// True when any camera exists. On the simulator this is false, which is
    /// what makes camera status `.unavailable` there (§2.5.1).
    static func hasCameraHardware() -> Bool {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified)
        return !session.devices.isEmpty
    }

    /// R-9: the prompt-presenting call runs on the main actor, where the
    /// system prompt belongs. The completion (any queue) is bridged through
    /// a checked continuation, so the value comes back as the request
    /// outcome and no AVFoundation error can escape.
    static func requestCameraAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
