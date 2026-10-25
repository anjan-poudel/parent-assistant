import XCTest
@testable import ElderlyAssistant

/// T-007 — the only sanctioned diagnostics writer for the instruction feature
/// (design L2 §3.6 IF-29, §6.4 event catalogue, §6.6 sanitisation;
/// NFR-RIE-002, NFR-RIE-004).
///
/// Every case here is a value assertion against a recording bus: no test
/// touches a real sink, the console or the disk. The suite pins the seven
/// exact event names, the two component strings, each closed outcome
/// vocabulary, the `duration_ms`/`count`/`state` field shapes, the absence of
/// any content-bearing parameter, and the fact that cancellation is not a
/// failure line. The catalogue's `error_code` tokens are asserted through the
/// emitted events, so a token that is not in the §3.3 table cannot appear.
final class InstructionObservabilityTests: XCTestCase {

    private var bus: RecordingInstructionBus!
    private var emitter: InstructionObservability!

    override func setUp() {
        super.setUp()
        bus = RecordingInstructionBus()
        emitter = InstructionObservability(bus: bus)
    }

    override func tearDown() {
        emitter = nil
        bus = nil
        super.tearDown()
    }

    // MARK: - Import

    /// First scenario: the import event carries its fixed name, the media
    /// component, the closed outcome, `kind` and — on the accepted path only
    /// — `duration_ms`; a failed import carries the §3.3 token and no
    /// duration (design §6.4).
    func testImportEventNameAndFields() {
        emitter.mediaImport(outcome: .accepted, kind: "video",
                            durationMs: 1234, error: nil)

        guard let accepted = singleEvent("instruction_media_import") else { return }
        XCTAssertEqual(accepted.component, "instruction_media")
        XCTAssertEqual(accepted.outcome, "accepted")
        XCTAssertEqual(accepted.durationMs, 1234)
        XCTAssertNil(accepted.errorCode)
        XCTAssertEqual(accepted.metadata, ["kind": "video"])
        assertSanitisedUnchanged(accepted)

        // The duration is an Int clamped to >= 0 (design §6.4).
        bus.reset()
        emitter.mediaImport(outcome: .accepted, kind: "video",
                            durationMs: -40, error: nil)
        XCTAssertEqual(singleEvent("instruction_media_import")?.durationMs, 0)

        let failures: [(InstructionImportError, String)] = [
            (.unreadableSource, "unreadable_source"),
            (.unsupportedFormat, "unsupported_format"),
            (.tooLong, "too_long"),
            (.tooLarge, "too_large"),
            (.validationTimedOut, "validation_timeout"),
            (.writeFailed(.stagingFailed), "write_failed")
        ]
        for (error, token) in failures {
            bus.reset()
            emitter.mediaImport(outcome: .failed, kind: "video",
                                durationMs: 99, error: error)
            guard let failed = singleEvent("instruction_media_import") else { return }
            XCTAssertEqual(failed.component, "instruction_media")
            XCTAssertEqual(failed.outcome, "failed")
            // Duration is accepted-only in the catalogue.
            XCTAssertNil(failed.durationMs)
            XCTAssertEqual(failed.errorCode, token)
            XCTAssertEqual(failed.metadata, ["kind": "video"])
            assertSanitisedUnchanged(failed)
        }
    }

    // MARK: - Delete

    /// Delete events carry `count` and, on failure, the store's token — and
    /// nothing else. The feature's file count is 0 or 1 (design §6.4).
    func testDeleteEventCountsOnly() {
        emitter.mediaDelete(outcome: .deleted, count: 1, error: nil)
        guard let deleted = singleEvent("instruction_media_delete") else { return }
        XCTAssertEqual(deleted.component, "instruction_media")
        XCTAssertEqual(deleted.outcome, "deleted")
        XCTAssertEqual(deleted.metadata, ["count": "1"])
        XCTAssertNil(deleted.errorCode)
        XCTAssertNil(deleted.durationMs)
        assertSanitisedUnchanged(deleted)

        bus.reset()
        emitter.mediaDelete(outcome: .absent, count: 0, error: nil)
        XCTAssertEqual(singleEvent("instruction_media_delete")?.metadata,
                       ["count": "0"])

        let storageFailures: [(InstructionStorageError, String)] = [
            (.invalidOwner, "invalid_owner"),
            (.stagingFailed, "staging_failed"),
            (.protectionFailed, "protection_failed"),
            (.commitFailed, "commit_failed"),
            (.deleteFailed, "delete_failed"),
            (.purgeFailed, "purge_failed")
        ]
        for (error, token) in storageFailures {
            bus.reset()
            emitter.mediaDelete(outcome: .failed, count: 0, error: error)
            guard let failed = singleEvent("instruction_media_delete") else { return }
            XCTAssertEqual(failed.outcome, "failed")
            XCTAssertEqual(failed.errorCode, token)
            XCTAssertEqual(failed.metadata, ["count": "0"])
            assertSanitisedUnchanged(failed)
        }

        // A stray error on a non-failed outcome never becomes a code.
        bus.reset()
        emitter.mediaDelete(outcome: .deleted, count: 1, error: .deleteFailed)
        XCTAssertNil(singleEvent("instruction_media_delete")?.errorCode)

        // The catalogue's count is 0 or 1; the emitter cannot widen it.
        bus.reset()
        emitter.mediaDelete(outcome: .deleted, count: 7, error: nil)
        XCTAssertEqual(singleEvent("instruction_media_delete")?.metadata,
                       ["count": "1"])
        bus.reset()
        emitter.mediaDelete(outcome: .absent, count: -3, error: nil)
        XCTAssertEqual(singleEvent("instruction_media_delete")?.metadata,
                       ["count": "0"])
    }

    // MARK: - Availability

    /// Availability emits exactly the three non-available outcomes, its kind
    /// is the normalised `"video"`, and there is no code or duration.
    func testAvailabilityKindsAreClosed() {
        let outcomes: [(InstructionAvailabilityOutcome, String)] = [
            (.rejected, "rejected"),
            (.missing, "missing"),
            (.unreadable, "unreadable")
        ]
        for (outcome, token) in outcomes {
            bus.reset()
            emitter.mediaAvailability(outcome: outcome, kind: "video")
            guard let event = singleEvent("instruction_media_availability") else { return }
            XCTAssertEqual(event.component, "instruction_media")
            XCTAssertEqual(event.outcome, token)
            XCTAssertEqual(event.metadata, ["kind": "video"])
            XCTAssertNil(event.errorCode)
            XCTAssertNil(event.durationMs)
            assertSanitisedUnchanged(event)
        }

        // `kind` is closed by construction: a decoded raw value that is not
        // a known kind becomes "unknown", never arbitrary bytes.
        bus.reset()
        emitter.mediaAvailability(outcome: .missing,
                                  kind: "Take the blue pill")
        XCTAssertEqual(singleEvent("instruction_media_availability")?.metadata,
                       ["kind": "unknown"])
    }

    // MARK: - Playback

    /// Playback emits ready/failed/closed, always with `duration_ms`, and a
    /// code only on failure.
    func testPlaybackOutcomesAreClosed() {
        emitter.playback(outcome: .ready, durationMs: 250, error: nil)
        guard let ready = singleEvent("instruction_playback") else { return }
        XCTAssertEqual(ready.component, "instruction_playback")
        XCTAssertEqual(ready.outcome, "ready")
        XCTAssertEqual(ready.durationMs, 250)
        XCTAssertNil(ready.errorCode)
        XCTAssertEqual(ready.metadata, [:])
        assertSanitisedUnchanged(ready)

        let failures: [(InstructionPlaybackFailure, String)] = [
            (.unsupported, "unsupported"),
            (.playerFailed, "player_failed"),
            (.interrupted, "interrupted"),
            (.timedOut, "timed_out")
        ]
        for (failure, token) in failures {
            bus.reset()
            emitter.playback(outcome: .failed, durationMs: 900, error: failure)
            guard let failed = singleEvent("instruction_playback") else { return }
            XCTAssertEqual(failed.outcome, "failed")
            XCTAssertEqual(failed.durationMs, 900)
            XCTAssertEqual(failed.errorCode, token)
            XCTAssertEqual(failed.metadata, [:])
            assertSanitisedUnchanged(failed)
        }

        bus.reset()
        emitter.playback(outcome: .closed, durationMs: 12, error: nil)
        guard let closed = singleEvent("instruction_playback") else { return }
        XCTAssertEqual(closed.outcome, "closed")
        XCTAssertEqual(closed.durationMs, 12)
        XCTAssertNil(closed.errorCode)

        // Negative durations clamp to zero on every playback outcome.
        bus.reset()
        emitter.playback(outcome: .closed, durationMs: -9, error: nil)
        XCTAssertEqual(singleEvent("instruction_playback")?.durationMs, 0)
    }

    // MARK: - Image load

    /// Image loads are outcome-only: loaded/missing/unreadable plus
    /// `duration_ms`, and no error code (design §3.3, §6.4).
    func testImageLoadOutcomesAreClosed() {
        let outcomes: [(InstructionImageOutcome, String)] = [
            (.loaded, "loaded"),
            (.missing, "missing"),
            (.unreadable, "unreadable")
        ]
        for (outcome, token) in outcomes {
            bus.reset()
            emitter.imageLoad(outcome: outcome, durationMs: 8)
            guard let event = singleEvent("instruction_image_load") else { return }
            XCTAssertEqual(event.component, "instruction_media")
            XCTAssertEqual(event.outcome, token)
            XCTAssertEqual(event.durationMs, 8)
            XCTAssertNil(event.errorCode)
            XCTAssertEqual(event.metadata, [:])
            assertSanitisedUnchanged(event)
        }

        bus.reset()
        emitter.imageLoad(outcome: .loaded, durationMs: -1)
        XCTAssertEqual(singleEvent("instruction_image_load")?.durationMs, 0)
    }

    // MARK: - Capture permission

    /// The permission event puts the closed denial state in the `state` key
    /// and the media in `kind`; it is not a failed operation (design §6.4
    /// final paragraph).
    func testCapturePermissionOutcomesAreClosed() {
        let stoppingStates: [(InstructionPermissionStatus, String)] = [
            (.denied, "denied"),
            (.restricted, "restricted"),
            (.unavailable, "unavailable")
        ]
        for (status, token) in stoppingStates {
            for permission in [InstructionMediaPermission.camera,
                               InstructionMediaPermission.microphone] {
                bus.reset()
                emitter.permission(status, permission: permission)
                guard let event = singleEvent("instruction_capture_permission") else { return }
                XCTAssertEqual(event.component, "instruction_media")
                // The denial is a state, not an outcome: the event's own
                // outcome is the generic non-failure token.
                XCTAssertEqual(event.outcome, "info")
                XCTAssertEqual(event.metadata["state"], token)
                XCTAssertEqual(event.metadata["kind"],
                               permission == .camera ? "camera" : "microphone")
                XCTAssertNil(event.errorCode)
                XCTAssertNil(event.durationMs)
                assertSanitisedUnchanged(event)
            }
        }

        // The state vocabulary is closed for every status the seam can
        // report — no status falls through to a description.
        let everyStatus: [(InstructionPermissionStatus, String)] = [
            (.granted, "granted"),
            (.denied, "denied"),
            (.restricted, "restricted"),
            (.undetermined, "undetermined"),
            (.unavailable, "unavailable")
        ]
        for (status, token) in everyStatus {
            bus.reset()
            emitter.permission(status, permission: .camera)
            XCTAssertEqual(singleEvent("instruction_capture_permission")?
                            .metadata["state"], token)
        }
    }

    // MARK: - Orphan purge

    /// Purge emits once per call with `count`; a failed sweep carries the
    /// partial count and the store token (design §6.4, §6.2 launch sweep).
    func testOrphanPurgeCountsAndPartialFlag() {
        emitter.orphanPurge(outcome: .completed, count: 3, error: nil)
        guard let completed = singleEvent("instruction_orphan_purge") else { return }
        XCTAssertEqual(completed.component, "instruction_media")
        XCTAssertEqual(completed.outcome, "completed")
        XCTAssertEqual(completed.metadata, ["count": "3"])
        XCTAssertNil(completed.errorCode)
        XCTAssertNil(completed.durationMs)
        assertSanitisedUnchanged(completed)

        // `.failed` is the catalogue's partial-sweep signal: the count the
        // caller could observe is carried, and the code names the stop.
        bus.reset()
        emitter.orphanPurge(outcome: .failed, count: 2, error: .purgeFailed)
        guard let failed = singleEvent("instruction_orphan_purge") else { return }
        XCTAssertEqual(failed.outcome, "failed")
        XCTAssertEqual(failed.metadata, ["count": "2"])
        XCTAssertEqual(failed.errorCode, "purge_failed")
        assertSanitisedUnchanged(failed)

        let storageFailures: [(InstructionStorageError, String)] = [
            (.invalidOwner, "invalid_owner"),
            (.stagingFailed, "staging_failed"),
            (.protectionFailed, "protection_failed"),
            (.commitFailed, "commit_failed"),
            (.deleteFailed, "delete_failed"),
            (.purgeFailed, "purge_failed")
        ]
        for (error, token) in storageFailures {
            bus.reset()
            emitter.orphanPurge(outcome: .failed, count: 0, error: error)
            XCTAssertEqual(singleEvent("instruction_orphan_purge")?.errorCode,
                           token)
        }

        // A negative count is never a count.
        bus.reset()
        emitter.orphanPurge(outcome: .completed, count: -4, error: nil)
        XCTAssertEqual(singleEvent("instruction_orphan_purge")?.metadata,
                       ["count": "0"])
    }

    // MARK: - No free text

    /// Second Gherkin scenario: the typed signatures make free-form content
    /// impossible to pass, and no string dictionary exists.
    ///
    /// Swift has no reflection over parameter types at runtime, so the
    /// compile-time half of the proof is a source pin over the shipping file:
    /// the only `String` parameter in the seven declarations is `kind`, which
    /// the emitter normalises. The runtime half calls every emitter and
    /// proves a content-shaped `kind` is reduced to `"unknown"` and that no
    /// sentinel reaches any event field.
    func testNoEmitterAcceptsFreeText() {
        let url = FeatureSourceScan.iosDirectory()
            .appendingPathComponent(
                "ElderlyAssistant/Services/Instructions/InstructionObservability.swift")
        // Comments are stripped before the scan, so documentation that
        // names the forbidden shapes cannot blind or false-fail the pin.
        let source = FeatureSourceScan.codeText(of: url)
        XCTAssertFalse(source.isEmpty, "the emitter source scanned as empty")

        // No free-form dictionary channel and no second log sink, anywhere.
        for forbidden in ["[String: String]", "[String: Any]",
                          "print(", "debugPrint(", "NSLog(", "os_log(", "fputs("] {
            XCTAssertFalse(source.contains(forbidden),
                           "InstructionObservability must not contain \(forbidden)")
        }

        // The seven IF-29 declarations: `kind` is the only String parameter.
        // `kind` is the design's signature and is normalised through
        // `InstructionKind.reportable(_:)`, so it has no free-form route out.
        let expectedStringParameters = [
            "mediaImport": 1,
            "mediaDelete": 0,
            "mediaAvailability": 1,
            "playback": 0,
            "imageLoad": 0,
            "permission": 0,
            "orphanPurge": 0
        ]
        let signature = try! NSRegularExpression(
            pattern: "func ([A-Za-z0-9_]+)\\(([^)]*)\\)")
        let whole = NSRange(source.startIndex..<source.endIndex, in: source)
        var checked: Set<String> = []
        for match in signature.matches(in: source, options: [], range: whole) {
            let name = Range(match.range(at: 1), in: source)
                .map { String(source[$0]) } ?? "?"
            guard let expected = expectedStringParameters[name] else { continue }
            checked.insert(name)
            let parameters = Range(match.range(at: 2), in: source)
                .map { String(source[$0]) } ?? ""
            XCTAssertEqual(occurrences(of: "String", in: parameters), expected,
                           "\(name) must take no String but the closed kind")
            if expected > 0 {
                XCTAssertTrue(parameters.contains("kind: String"),
                              "\(name)'s String parameter must be kind")
            }
            XCTAssertFalse(parameters.contains("[String"))
            for forbidden in ["URL", "Data", "Any", "filename", "caption",
                              "title", "identifier", "path", "url", "text"] {
                XCTAssertFalse(parameters.lowercased()
                                .contains(forbidden.lowercased()),
                               "\(name) declares a \(forbidden) parameter")
            }
        }
        XCTAssertEqual(checked, Set(expectedStringParameters.keys),
                       "not every IF-29 declaration was scanned")

        // Runtime: content-shaped input cannot reach any event field.
        let sentinels = ["Take the blue pill", "instruction-2.mov",
                         "https://example.com/private", "/tmp/private.mov"]
        for sentinel in sentinels {
            emitter.mediaImport(outcome: .accepted, kind: sentinel,
                                durationMs: 1, error: nil)
            emitter.mediaAvailability(outcome: .missing, kind: sentinel)
        }
        XCTAssertFalse(bus.allEvents.isEmpty)
        for event in bus.allEvents {
            let strings = [event.component, event.eventType, event.outcome,
                           event.errorCode ?? ""]
                + Array(event.metadata.keys) + Array(event.metadata.values)
            for sentinel in sentinels {
                for value in strings {
                    XCTAssertFalse(value.contains(sentinel),
                                   "content leaked into an event field")
                }
            }
            // Every key is already allow-listed — this feature adds none.
            for key in event.metadata.keys {
                XCTAssertTrue(LogSanitiser.allowedKeys.contains(key),
                              "\(key) is not in LogSanitiser.allowedKeys")
            }
        }
        XCTAssertTrue(bus.events(named: "instruction_media_import")
            .allSatisfy { $0.metadata["kind"] == "unknown" })
        XCTAssertTrue(bus.events(named: "instruction_media_availability")
            .allSatisfy { $0.metadata["kind"] == "unknown" })
    }

    // MARK: - Cancellation

    /// Cancellation is not a failure: it emits nothing and has no copy line
    /// (design §6.1 rule 3, §6.2; the §3.3 table's `.cancelled` row).
    func testCancelledIsNotAFailureLine() {
        emitter.mediaImport(outcome: .failed, kind: "video",
                            durationMs: 42, error: .cancelled)

        XCTAssertTrue(bus.allEvents.isEmpty,
                      "a cancelled import must not emit an event")
        XCTAssertNil(InstructionMessageKey.forImport(.cancelled),
                     "a cancelled import must not produce copy")

        // A real import failure still emits exactly one diagnostic line.
        emitter.mediaImport(outcome: .failed, kind: "video",
                            durationMs: 42, error: .tooLong)
        XCTAssertEqual(bus.allEvents.count, 1)
        XCTAssertEqual(bus.allEvents.first?.errorCode, "too_long")
    }

    // MARK: - Helpers

    /// One event of the named type, failing the test when the count is not
    /// exactly one. Every emitter call is expected to produce one line.
    private func singleEvent(_ eventType: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) -> ObservabilityEvent? {
        let matching = bus.events(named: eventType)
        XCTAssertEqual(matching.count, 1,
                       "expected exactly one \(eventType) event",
                       file: file, line: line)
        return matching.first
    }

    /// The shipped bus boundary must keep every field: all keys are already
    /// allow-listed and all values are closed tokens, counts or codes.
    private func assertSanitisedUnchanged(_ event: ObservabilityEvent,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) {
        let clean = LogSanitiser().sanitise(event)
        XCTAssertEqual(clean.component, event.component, file: file, line: line)
        XCTAssertEqual(clean.eventType, event.eventType, file: file, line: line)
        XCTAssertEqual(clean.outcome, event.outcome, file: file, line: line)
        XCTAssertEqual(clean.durationMs, event.durationMs, file: file, line: line)
        XCTAssertEqual(clean.errorCode, event.errorCode, file: file, line: line)
        XCTAssertEqual(clean.metadata, event.metadata, file: file, line: line)
        for key in event.metadata.keys {
            XCTAssertTrue(LogSanitiser.allowedKeys.contains(key),
                          "\(key) is not in LogSanitiser.allowedKeys",
                          file: file, line: line)
        }
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}

/// Records every event the emitter sends. A fire-and-forget emitter never
/// reads the bus back, so a plain class is enough; the tests are synchronous.
private final class RecordingInstructionBus: ObservabilityBus {
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
