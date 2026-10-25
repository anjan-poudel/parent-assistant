import Foundation

/// The video import limits (design L2 §3.4, §9.1).
///
/// Both values are fixed by the feature constitution (OD-2: receive-as-is
/// video up to 3 minutes and 200 MiB) and are never user-configurable, read
/// from `UserDefaults`, a remote config or the environment. Production
/// constructs the value once from `.standard` and injects it; tests build
/// their own.
struct InstructionVideoLimits: Equatable {
    /// Inclusive cap judged on the rounded whole-second duration: exactly
    /// 180 s is accepted (design §9.1, §5.2 step 3).
    let maxDurationSeconds: TimeInterval

    /// 200 MiB, defined as 200 × 1024 × 1024 bytes.
    let maxBytes: Int64

    static let standard = InstructionVideoLimits(
        maxDurationSeconds: 180,
        maxBytes: 209_715_200
    )
}

/// The video pipeline's timing and staging values (design L2 §3.4, §9.1).
struct InstructionVideoConfiguration: Equatable {
    let limits: InstructionVideoLimits

    /// The importer's bound on asynchronous validation (IF-15).
    let validationTimeoutSeconds: TimeInterval

    /// Owners younger than this are never swept as orphans (P-6, IF-12).
    let orphanGraceSeconds: TimeInterval

    /// The bounded chunk size of the protected staging stream (P-10, D18):
    /// peak memory is one chunk, so a 200 MiB file is 200 reads rather than
    /// thousands.
    let stagingChunkBytes: Int

    static let standard = InstructionVideoConfiguration(
        limits: .standard,
        validationTimeoutSeconds: 20,
        orphanGraceSeconds: 60,
        stagingChunkBytes: 1_048_576
    )
}

/// The recorder's capture quality (design L2 §3.4, §9.1). `.high` keeps a
/// medicine label readable; the OS already caps the recording at the
/// configured 3 minutes.
enum InstructionRecordingQuality: String, Equatable {
    case high
    case medium
}

/// The capture configuration handed to the recorder presenter (IF-17;
/// design L2 §3.4, §9.1).
struct InstructionCaptureConfiguration: Equatable {
    let video: InstructionVideoConfiguration
    let recordingQuality: InstructionRecordingQuality

    static let standard = InstructionCaptureConfiguration(
        video: .standard,
        recordingQuality: .high
    )
}
