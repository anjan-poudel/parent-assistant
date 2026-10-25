/// Closed outcome vocabularies for the seven `instruction_*` events
/// (design L2 §3.6 IF-29, §6.4). Each raw value is a token the event
/// catalogue permits; the emitter exists for no other outcome.
enum InstructionImportOutcome: String, Equatable {
    case accepted
    case failed
}

/// Delete outcomes (design §6.4): `count` is 0 for `.absent`, and the
/// feature's file count is 0 or 1 for the other two.
enum InstructionDeleteOutcome: String, Equatable {
    case deleted
    case absent
    case failed
}

/// Availability outcomes (design §6.4): emitted only when the store's
/// answer is anything but `.available`.
enum InstructionAvailabilityOutcome: String, Equatable {
    case rejected
    case missing
    case unreadable
}

/// Playback outcomes (design §6.4): `.ready`, `.failed` and `.closed`
/// (the last only after a player existed).
enum InstructionPlaybackOutcome: String, Equatable {
    case ready
    case failed
    case closed
}

/// Image-load outcomes (design §6.4): one per resolved load.
enum InstructionImageOutcome: String, Equatable {
    case loaded
    case missing
    case unreadable
}

/// Orphan-purge outcomes (design §6.4): `.failed` means the sweep stopped
/// early and its `count` is partial.
enum InstructionPurgeOutcome: String, Equatable {
    case completed
    case failed
}

/// The only `error_code` tokens the instruction feature may emit
/// (design L2 §3.3 mapping table, §6.6).
///
/// Every token is lowercase snake_case, identifier-shaped and at most 19
/// characters, so `LogSanitiser`'s existing code bound accepts it without any
/// allow-list change. No OS error domain, code or description has a case
/// here: a failure is mapped at the emitter boundary and the token is the
/// only thing that leaves this file.
enum InstructionErrorCode: String, Equatable {
    case unreadableSource = "unreadable_source"
    case unsupportedFormat = "unsupported_format"
    case tooLong = "too_long"
    case tooLarge = "too_large"
    case validationTimedOut = "validation_timeout"
    case writeFailed = "write_failed"
    case invalidOwner = "invalid_owner"
    case stagingFailed = "staging_failed"
    case protectionFailed = "protection_failed"
    case commitFailed = "commit_failed"
    case deleteFailed = "delete_failed"
    case purgeFailed = "purge_failed"
    case unsupported = "unsupported"
    case playerFailed = "player_failed"
    case interrupted = "interrupted"
    case timedOut = "timed_out"

    /// Import failures map one-to-one onto the §3.3 table. `.cancelled` has
    /// no code: cancellation is not a failure and emits no event (§6.1
    /// rule 3, §6.2), so this initializer returns `nil` for it.
    init?(_ error: InstructionImportError) {
        switch error {
        case .unreadableSource:
            self = .unreadableSource
        case .unsupportedFormat:
            self = .unsupportedFormat
        case .tooLong:
            self = .tooLong
        case .tooLarge:
            self = .tooLarge
        case .validationTimedOut:
            self = .validationTimedOut
        case .writeFailed:
            // The §3.3 table's token for the import case is `write_failed`;
            // the wrapped store failure is not re-labelled.
            self = .writeFailed
        case .cancelled:
            return nil
        }
    }

    /// Store failures keep their own §3.3 token, whether they surface from a
    /// delete or a purge.
    init(storage error: InstructionStorageError) {
        switch error {
        case .invalidOwner:
            self = .invalidOwner
        case .stagingFailed:
            self = .stagingFailed
        case .protectionFailed:
            self = .protectionFailed
        case .commitFailed:
            self = .commitFailed
        case .deleteFailed:
            self = .deleteFailed
        case .purgeFailed:
            self = .purgeFailed
        }
    }

    /// Playback failures keep their own §3.3 token; all four render the same
    /// plain copy line.
    init(playback failure: InstructionPlaybackFailure) {
        switch failure {
        case .unsupported:
            self = .unsupported
        case .playerFailed:
            self = .playerFailed
        case .interrupted:
            self = .interrupted
        case .timedOut:
            self = .timedOut
        }
    }
}

/// The only writer of this feature's `instruction_*` events (IF-29; design
/// L2 §3.6, §6.4, §6.6).
///
/// Every method is fire-and-forget and builds its payload from typed values
/// only: outcomes and states come from `String`-raw enums, `kind` is
/// normalised through `InstructionKind.reportable(_:)`, error tokens come
/// from `InstructionErrorCode`, and counts and durations are integers. No
/// method accepts prose, a string dictionary, a file name, a link, a title, a
/// caption, an identifier or a directory component, so a future contributor
/// cannot pass household content without changing a signature and having the
/// review see it. This file writes no console output and adds no second sink;
/// the injected bus is the shipped sanitising one.
///
/// `@unchecked Sendable` is stated rather than inferred: `ObservabilityBus`
/// is a pre-existing non-Sendable protocol owned by another component, and
/// this value stores only that reference and never mutates it — the same
/// rationale `InstructionVideoStore` records for its own conformance
/// (design §3.1 rule 4, §7.1).
struct InstructionObservability: @unchecked Sendable {

    private let bus: ObservabilityBus

    init(bus: ObservabilityBus) {
        self.bus = bus
    }

    // MARK: - Import

    /// `instruction_media_import`, component `instruction_media`
    /// (design §6.4). An accepted import carries `duration_ms` and no code;
    /// a failed one carries the typed error's token and no duration.
    ///
    /// Cancellation is not a failure (§6.1 rule 3, §6.2): a `.failed`
    /// outcome paired with `.cancelled` emits nothing at all.
    func mediaImport(outcome: InstructionImportOutcome, kind: String,
                     durationMs: Int, error: InstructionImportError?) {
        let reportableKind = InstructionKind.reportable(kind)
        switch outcome {
        case .accepted:
            bus.emit(ObservabilityEvent(
                component: "instruction_media",
                eventType: "instruction_media_import",
                durationMs: Self.clampedDuration(durationMs),
                outcome: outcome.rawValue,
                errorCode: nil,
                metadata: ["kind": reportableKind]
            ))
        case .failed:
            if error == .cancelled { return }
            bus.emit(ObservabilityEvent(
                component: "instruction_media",
                eventType: "instruction_media_import",
                durationMs: nil,
                outcome: outcome.rawValue,
                errorCode: error.flatMap { InstructionErrorCode($0)?.rawValue },
                metadata: ["kind": reportableKind]
            ))
        }
    }

    // MARK: - Delete

    /// `instruction_media_delete`, component `instruction_media`
    /// (design §6.4). `count` is the feature's 0-or-1 file count, so a
    /// caller cannot turn the field into an arbitrary number, and
    /// `error_code` appears only on `.failed`.
    func mediaDelete(outcome: InstructionDeleteOutcome, count: Int,
                     error: InstructionStorageError?) {
        var errorCode: String?
        if outcome == .failed, let error {
            errorCode = InstructionErrorCode(storage: error).rawValue
        }
        bus.emit(ObservabilityEvent(
            component: "instruction_media",
            eventType: "instruction_media_delete",
            durationMs: nil,
            outcome: outcome.rawValue,
            errorCode: errorCode,
            metadata: ["count": String(Self.clampedFileCount(count))]
        ))
    }

    // MARK: - Availability

    /// `instruction_media_availability`, component `instruction_media`
    /// (design §6.4). Emitted only for a non-`.available` answer; the kind
    /// is normalised, so a decoded raw value can never carry arbitrary bytes
    /// into the field.
    func mediaAvailability(outcome: InstructionAvailabilityOutcome,
                           kind: String) {
        bus.emit(ObservabilityEvent(
            component: "instruction_media",
            eventType: "instruction_media_availability",
            durationMs: nil,
            outcome: outcome.rawValue,
            errorCode: nil,
            metadata: ["kind": InstructionKind.reportable(kind)]
        ))
    }

    // MARK: - Playback

    /// `instruction_playback`, component `instruction_playback`
    /// (design §6.4). Every terminal outcome carries `duration_ms`; only
    /// `.failed` carries a code.
    func playback(outcome: InstructionPlaybackOutcome, durationMs: Int,
                  error: InstructionPlaybackFailure?) {
        var errorCode: String?
        if outcome == .failed, let error {
            errorCode = InstructionErrorCode(playback: error).rawValue
        }
        bus.emit(ObservabilityEvent(
            component: "instruction_playback",
            eventType: "instruction_playback",
            durationMs: Self.clampedDuration(durationMs),
            outcome: outcome.rawValue,
            errorCode: errorCode,
            metadata: [:]
        ))
    }

    // MARK: - Image load

    /// `instruction_image_load`, component `instruction_media`
    /// (design §6.4). Outcome-only: the three image failures share one
    /// plain copy line and the catalogue defines no image error code.
    func imageLoad(outcome: InstructionImageOutcome, durationMs: Int) {
        bus.emit(ObservabilityEvent(
            component: "instruction_media",
            eventType: "instruction_image_load",
            durationMs: Self.clampedDuration(durationMs),
            outcome: outcome.rawValue,
            errorCode: nil,
            metadata: [:]
        ))
    }

    // MARK: - Capture permission

    /// `instruction_capture_permission`, component `instruction_media`
    /// (design §6.4, §6.4's final paragraph).
    ///
    /// A denial is a state, not a failed operation: the closed status token
    /// rides the `state` key and the request's media rides `kind` as
    /// `"camera"`/`"microphone"`. The event's own outcome is the generic
    /// non-failure token `info`, because the catalogue defines no outcome
    /// for this event and the design explicitly places these values in
    /// `state`.
    func permission(_ state: InstructionPermissionStatus,
                    permission: InstructionMediaPermission) {
        bus.emit(ObservabilityEvent(
            component: "instruction_media",
            eventType: "instruction_capture_permission",
            durationMs: nil,
            outcome: "info",
            errorCode: nil,
            metadata: ["state": Self.stateToken(state),
                       "kind": Self.kindToken(permission)]
        ))
    }

    // MARK: - Orphan purge

    /// `instruction_orphan_purge`, component `instruction_media`
    /// (design §6.4). Emitted once per purge call; a `.failed` outcome means
    /// the sweep stopped early, so its `count` is the partial count and the
    /// code names the store failure.
    func orphanPurge(outcome: InstructionPurgeOutcome, count: Int,
                     error: InstructionStorageError?) {
        var errorCode: String?
        if outcome == .failed, let error {
            errorCode = InstructionErrorCode(storage: error).rawValue
        }
        bus.emit(ObservabilityEvent(
            component: "instruction_media",
            eventType: "instruction_orphan_purge",
            durationMs: nil,
            outcome: outcome.rawValue,
            errorCode: errorCode,
            metadata: ["count": String(max(0, count))]
        ))
    }

    // MARK: - Closed value helpers

    /// `duration_ms` is an `Int` clamped to ≥ 0 (design §6.4).
    private static func clampedDuration(_ durationMs: Int) -> Int {
        max(0, durationMs)
    }

    /// The delete catalogue's count is 0 or 1: 0 for `.absent`, 1 for a
    /// removed file. A caller cannot widen it into a free number.
    private static func clampedFileCount(_ count: Int) -> Int {
        min(max(0, count), 1)
    }

    /// The permission status vocabulary is closed by construction: every
    /// `InstructionPermissionStatus` maps to one fixed token.
    private static func stateToken(_ state: InstructionPermissionStatus) -> String {
        switch state {
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .undetermined:
            return "undetermined"
        case .unavailable:
            return "unavailable"
        }
    }

    /// The permission event's `kind` is `camera`/`microphone` and nothing
    /// else (design §6.4).
    private static func kindToken(_ permission: InstructionMediaPermission) -> String {
        switch permission {
        case .camera:
            return "camera"
        case .microphone:
            return "microphone"
        }
    }
}
