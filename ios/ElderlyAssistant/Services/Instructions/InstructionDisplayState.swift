/// The six collapsed instruction shapes a surface can render (design L2
/// §4.10; the T-003 brief calls the same table §4.9).
///
/// Exactly six cases are legal. `.unavailable` is deliberately absent: it is
/// a `FiredRoutineVisualAids.Content` case for a deleted owner, owned by
/// T-021, not a display state. The enum carries no image, URL or control —
/// only what the card needs to say.
enum InstructionDisplayState: Equatable {
    /// Render nothing at all (`EmptyView`), not an empty container.
    case none
    /// The instruction's words, full width.
    case text(text: String)
    /// A photo in the owner's store, with an optional one-line caption.
    case image(filename: String, caption: String?)
    /// A video in the owner's store, with an optional one-line caption.
    case video(filename: String, caption: String?)
    /// A kind this build cannot render, plus whatever saved text exists.
    /// Never a play, open or link control.
    case unsupported(text: String?)
    /// The owner expected an instruction at fire time and none is present.
    case removed
}

/// The single place a stored instruction becomes a display state (design L2
/// §3.4 IF-3, §4.10).
///
/// The function is total, pure and static: it reads no store, no file and no
/// locale, so it cannot accidentally turn local playability into UI state.
/// Availability is the store's answer at render time; a known image/video
/// instruction therefore maps to its case even when the file has gone
/// (design §4.10, §11.3 D/F-12).
enum InstructionPresentation {
    /// `nil` or not-present ⇒ `.removed` when the owner expected an
    /// instruction, else `.none`. Known kinds map to their own case; an
    /// unknown kind maps to `.unsupported` with its trimmed saved text.
    static func state(for instruction: Instruction?,
                      isExpected: Bool) -> InstructionDisplayState {
        guard let instruction, instruction.isPresent else {
            return isExpected ? .removed : .none
        }

        guard let kind = instruction.knownKind else {
            // Forward tolerance: a future kind still shows the plain
            // unsupported note, never a control that cannot work.
            return .unsupported(text: instruction.trimmedText)
        }

        switch kind {
        case .text:
            guard let text = instruction.trimmedText else {
                return isExpected ? .removed : .none
            }
            return .text(text: text)
        case .image:
            guard let filename = instruction.filename, !filename.isEmpty else {
                return isExpected ? .removed : .none
            }
            return .image(filename: filename, caption: instruction.trimmedCaption)
        case .video:
            guard let filename = instruction.filename, !filename.isEmpty else {
                return isExpected ? .removed : .none
            }
            return .video(filename: filename, caption: instruction.trimmedCaption)
        }
    }
}

/// The single mapping from this feature's typed failures to the plain copy
/// keys a view resolves (design L2 §3.4 IF-4, §3.3 mapping table, §6.7).
///
/// The mapping is pure and total: it reads no store, file, locale or clock,
/// and no case returns an error code, an internal type name or a diagnostic.
/// The keys are the shipping catalogue's `instruction.*` family (§10.5);
/// a view resolves them through `L10n`, so services hold no copy (§3.1
/// rule 7).
///
/// `forWrite` maps the routine/event write seam's `InstructionWriteError`
/// (declared beside its routine owner in `RoutineScheduler.swift`, P-4).
enum InstructionMessageKey {

    /// The import failure's plain line. `.cancelled` is `nil` — the person
    /// dismissed the picker or recorder, so there is no copy and no event
    /// (design §6.1 rule 3). Unreadable, unsupported and timed-out sources
    /// share one honest sentence: the phone cannot use this video.
    static func forImport(_ error: InstructionImportError) -> String? {
        switch error {
        case .unreadableSource, .unsupportedFormat, .validationTimedOut:
            return "instruction.video.unreadable"
        case .tooLong:
            return "instruction.video.tooLong"
        case .tooLarge:
            return "instruction.video.tooLarge"
        case .writeFailed:
            return "instruction.video.saveFailed"
        case .cancelled:
            return nil
        }
    }

    /// Every playback failure renders the same one-line fallback inside the
    /// cover; Close stays available (design §6.2, FR-RIE-020).
    static func forPlayback(_ failure: InstructionPlaybackFailure) -> String {
        "instruction.video.unavailable"
    }

    /// Every image failure renders the same one-line fallback; the reminder
    /// still renders around it (design §6.2, FR-RIE-020).
    static func forImage(_ failure: InstructionImageFailure) -> String {
        "instruction.image.unavailable"
    }

    /// The recording permission note. A denial names the permission the
    /// person must allow in Settings; a missing camera offers the picker
    /// instead (design §6.2, FR-RIE-025).
    static func forPermission(_ problem: InstructionPermissionProblem) -> String {
        switch problem {
        case .cameraDenied:
            return "instruction.camera.denied"
        case .microphoneDenied:
            return "instruction.microphone.denied"
        case .cameraUnavailable:
            return "instruction.camera.unavailable"
        }
    }

    /// The routine write seam's line (design §3.3 mapping table, IF-4).
    ///
    /// `ownerNotFound` is the removed-route case: the person is looking at
    /// a reminder that no longer exists, so the copy says it was removed
    /// rather than blaming the save. Every other writable failure says the
    /// instruction could not be saved; a failed media *write* points at the
    /// video line because that is what was being stored.
    ///
    /// The table assigns `.deleteFailed` / `.purgeFailed` no user copy (they
    /// are logged only). This function is total and cannot return nil, so
    /// those two — unreachable for a media *write* — fall back to the
    /// generic save line.
    static func forWrite(_ error: InstructionWriteError) -> String {
        switch error {
        case .ownerNotFound:
            return "instruction.removed"
        case .unresolvedPayload, .persistenceFailed:
            return "instruction.saveFailed"
        case .mediaWriteFailed(let storageError):
            switch storageError {
            case .invalidOwner:
                return "instruction.saveFailed"
            case .stagingFailed, .protectionFailed, .commitFailed:
                return "instruction.video.saveFailed"
            case .deleteFailed, .purgeFailed:
                return "instruction.saveFailed"
            }
        }
    }
}
