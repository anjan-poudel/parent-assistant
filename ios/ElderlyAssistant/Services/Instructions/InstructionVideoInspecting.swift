import AVFoundation
import Foundation

/// The three facts both metadata paths answer (design L2 §3.5, §2.3).
///
/// Neither the prober nor the inspector decodes a frame, writes a thumbnail
/// or reads audio. The duration is raw seconds; the 180-second cap is
/// *judged elsewhere* (the store, through `InstructionVideoDuration`), so
/// this value stays a measurement rather than a policy decision.
struct InstructionVideoMetadata: Equatable {
    let durationSeconds: Double
    let hasVideoTrack: Bool
    let isPlayable: Bool
}

/// The synchronous pre-staging probe (IF-13), called on the main thread from
/// inside the system callback before any byte is staged (design §5.2).
protocol InstructionVideoProbing: Sendable {
    func probe(url: URL) -> Result<InstructionVideoMetadata, InstructionImportError>
}

/// The asynchronous post-staging inspection (IF-14). It owns no timer — the
/// importer bounds it with `validationTimeoutSeconds` (design §9.2).
protocol InstructionVideoInspecting: Sendable {
    func inspect(url: URL) async -> Result<InstructionVideoMetadata, InstructionImportError>
}

/// C03 — everything that can go wrong between "the family chose a file" and
/// "the bytes are validated and staged" (design §3.3).
///
/// `Equatable` so tests compare values, and every AVFoundation failure is
/// mapped into one of these cases: no `NSError`, error domain, code or
/// description ever escapes this file.
enum InstructionImportError: Error, Equatable {
    /// Not a file URL, absent, unreadable, or a metadata load threw.
    case unreadableSource
    /// Not playable, or no video track.
    case unsupportedFormat
    /// The rounded duration exceeds `maxDurationSeconds`.
    case tooLong
    /// The source exceeds `maxBytes`.
    case tooLarge
    /// The async inspector exceeded the importer's bound.
    case validationTimedOut
    /// A staging, protection, commit or delete failure from the store.
    case writeFailed(InstructionStorageError)
    /// The person dismissed the picker or recorder.
    case cancelled
}

/// Synchronous AVFoundation metadata reader (IF-13).
///
/// Uses the synchronous accessors (`isPlayable`, `duration`,
/// `tracks(withMediaType:)`). They are deprecated on the current SDK but not
/// removed, the project builds without warnings-as-errors, and the
/// synchronous form is the only one that can answer inside the system
/// callback window (design §2.3 rule 1, OI-2).
struct AVInstructionVideoProber: InstructionVideoProbing {
    init() {}

    func probe(url: URL) -> Result<InstructionVideoMetadata, InstructionImportError> {
        if let problem = instructionSourceProblem(for: url) {
            return .failure(problem)
        }

        let asset = AVURLAsset(url: url)
        guard asset.isPlayable else { return .failure(.unsupportedFormat) }

        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite else { return .failure(.unreadableSource) }

        guard !asset.tracks(withMediaType: .video).isEmpty else {
            return .failure(.unsupportedFormat)
        }

        return .success(InstructionVideoMetadata(durationSeconds: seconds,
                                                 hasVideoTrack: true,
                                                 isPlayable: true))
    }
}

/// Asynchronous AVFoundation metadata reader (IF-14).
///
/// Every thrown load failure becomes `.unreadableSource` — a thrown
/// `NSError` is never propagated or logged (design §2.3 rule 4, §9.2). A
/// source that loads but is not playable, or has no video track, is
/// `.unsupportedFormat`; a non-finite duration is `.unreadableSource`.
struct AVInstructionVideoInspector: InstructionVideoInspecting {
    init() {}

    func inspect(url: URL) async -> Result<InstructionVideoMetadata, InstructionImportError> {
        if let problem = instructionSourceProblem(for: url) {
            return .failure(problem)
        }

        let asset = AVURLAsset(url: url)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)

            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite else { return .failure(.unreadableSource) }
            guard isPlayable, !videoTracks.isEmpty else {
                return .failure(.unsupportedFormat)
            }

            return .success(InstructionVideoMetadata(durationSeconds: seconds,
                                                     hasVideoTrack: true,
                                                     isPlayable: true))
        } catch {
            // A thrown load is an unreadable source, not a format
            // judgement (design §9.2). The importer discards the staged
            // bytes on this result.
            return .failure(.unreadableSource)
        }
    }
}

/// The shared "can this path even be opened" pre-check. Maps every
/// pre-AVFoundation problem to `.unreadableSource` and never touches the
/// network: only `file:` URLs are accepted (design §2.3 rule 2).
private func instructionSourceProblem(for url: URL) -> InstructionImportError? {
    guard url.isFileURL else { return .unreadableSource }

    var isDirectory: ObjCBool = false
    let path = url.path
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          !isDirectory.boolValue,
          FileManager.default.isReadableFile(atPath: path) else {
        return .unreadableSource
    }
    return nil
}
