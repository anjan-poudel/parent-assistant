import XCTest
@testable import ElderlyAssistant

final class IntentLogStoreTests: XCTestCase {

    private func makeStore() -> IntentLogStore {
        IntentLogStore(directory: makeDirectory())
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("intentlog-tests-\(UUID().uuidString)", isDirectory: true)
    }

    /// The raw JSONL the store wrote — the file itself, not the decoded
    /// records, for the tests that are about what is ON DISK (V5, V8).
    private func rawLogText(in dir: URL) -> String {
        (try? String(contentsOf: dir.appendingPathComponent("intent-log.jsonl"),
                     encoding: .utf8)) ?? ""
    }

    /// The key set of one JSONL line, parsed — never compared as bytes:
    /// `JSONEncoder`'s key ordering is unspecified, so line bytes are not
    /// a stable artifact (T-054 §2.5, V5).
    private func keysOfLine(_ line: String) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        let dict = try XCTUnwrap(object as? [String: Any])
        return Set(dict.keys)
    }

    func testAppendAndRecentNewestFirst() throws {
        let store = makeStore()
        store.append(IntentLogStore.Record(path: "model", action: "call",
                                           slots: ["contact": "maiya"], outcome: "confirmed",
                                           timestamp: Date().addingTimeInterval(-60)))
        store.append(IntentLogStore.Record(path: "override", action: "call",
                                           slots: ["contact": "maiya"], outcome: "corrected",
                                           correctedTo: ["method": "phone"]))
        // appends are async — wait for the io queue to drain.
        try waitFor(store) { $0.count == 2 }

        let recent = store.recent()
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.first?.outcome, "corrected", "newest first")
        XCTAssertEqual(recent.first?.correctedTo?["method"], "phone")
    }

    func testCapTrimsOldest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intentlog-cap-\(UUID().uuidString)", isDirectory: true)
        let store = IntentLogStore(directory: dir)
        // Amortized trimming fires when the file exceeds maxRecords + 50.
        // maxRecords + 51 appends → trim fires on the last one → the file
        // holds exactly maxRecords, with the oldest 51 dropped.
        for i in 0..<(IntentLogStore.maxRecords + 51) {
            store.append(IntentLogStore.Record(path: "model", action: "call",
                                               slots: ["contact": "c\(i)"], outcome: "confirmed",
                                               timestamp: Date().addingTimeInterval(Double(i))))
        }
        try waitFor(store) { $0.count == IntentLogStore.maxRecords }
        let recent = store.recent(limit: IntentLogStore.maxRecords)
        XCTAssertEqual(recent.count, IntentLogStore.maxRecords)
        XCTAssertEqual(recent.last?.slots?["contact"], "c51", "oldest 51 trimmed")
    }

    func testExportProducesShareableJSONL() throws {
        let store = makeStore()
        store.append(IntentLogStore.Record(path: "model", action: "call",
                                           slots: ["contact": "maiya"], outcome: "confirmed"))
        try waitFor(store) { $0.count == 1 }
        let url = store.exportURL()
        XCTAssertNotNil(url)
        let text = try String(contentsOf: url!, encoding: .utf8)
        XCTAssertTrue(text.contains("\"outcome\":\"confirmed\""))
        XCTAssertTrue(text.contains("maiya"))
    }

    func testEmptyExportIsNil() {
        XCTAssertNil(makeStore().exportURL())
    }

    // MARK: - [INTENTLOG-CAPTURE] confidence field

    func testConfidenceRoundTripsThroughFile() throws {
        let store = makeStore()
        store.append(IntentLogStore.Record(path: "model", action: "call",
                                           slots: ["contact": "maiya"], outcome: "confirmed"))
        store.append(IntentLogStore.Record(path: "model", action: "call",
                                           slots: ["contact": "maiya"], outcome: "confirmed",
                                           confidence: 0.82))
        try waitFor(store) { $0.count == 2 }
        let recent = store.recent()
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.first?.confidence, 0.82, "newest first, confidence persisted")
        XCTAssertNil(recent.last?.confidence, "an unpopulated confidence stays nil, never 0")
        let text = try String(contentsOf: store.exportURL()!, encoding: .utf8)
        XCTAssertTrue(text.contains("\"confidence\":0.82"))
    }

    /// The schema-evolution requirement: a line written by the app
    /// BEFORE 2026-09-15 (no `confidence`, no `correctedTo`, no
    /// `latencyMs` — JSONEncoder omits nil optionals) must still decode.
    /// This is the on-device log of every existing install: dropping
    /// those lines would silently delete the family's whole history.
    func testLegacyRecordWithoutConfidenceDecodes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intentlog-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = """
        {"id":"\(UUID().uuidString)","timestamp":\(Date().timeIntervalSinceReferenceDate),\
        "path":"model","action":"call","slots":{"contact":"maiya"},"outcome":"confirmed"}
        """
        try (legacy + "\n").write(to: dir.appendingPathComponent("intent-log.jsonl"),
                                  atomically: true, encoding: .utf8)

        let records = IntentLogStore(directory: dir).recent()
        XCTAssertEqual(records.count, 1, "a legacy line is still a record")
        XCTAssertEqual(records.first?.action, "call")
        XCTAssertEqual(records.first?.slots?["contact"], "maiya")
        XCTAssertEqual(records.first?.outcome, "confirmed")
        XCTAssertNil(records.first?.confidence, "legacy records read as confidence-unknown")
        XCTAssertNil(records.first?.latencyMs)
    }

    // MARK: - [T-056-A] loop capture schema — T-054 §2.5 vectors V1–V7

    private func write(_ lines: [String], to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("intent-log.jsonl"),
                   atomically: true, encoding: .utf8)
    }

    private func recordLine(extra: String = "") -> String {
        """
        {"id":"\(UUID().uuidString)","timestamp":\(Date().timeIntervalSinceReferenceDate),\
        "path":"model","action":"call","slots":{"contact":"maiya"},"outcome":"confirmed"\(extra)}
        """
    }

    /// V1 — a line written before the loop existed. It must decode, it must
    /// keep every optional nil, and `readAll`'s `compactMap` must NOT drop
    /// it: dropping it would silently delete the family's whole history.
    func testV1PreExtensionLineDecodesWithNilHandle() throws {
        let dir = makeDirectory()
        // The minimum a shipped line ever carried: the five mandatory keys.
        try write([#"""
        {"id":"\#(UUID().uuidString)","timestamp":\#(Date().timeIntervalSinceReferenceDate),"path":"model","action":"call","outcome":"confirmed"}
        """#], to: dir)

        let records = IntentLogStore(directory: dir).recent()
        XCTAssertEqual(records.count, 1, "V1: the line is still a record")
        XCTAssertNil(records.first?.utteranceHandle)
        XCTAssertNil(records.first?.slots)
        XCTAssertNil(records.first?.confidence)
        XCTAssertNil(records.first?.latencyMs)
        XCTAssertNil(records.first?.correctedTo)
    }

    /// V2 — an opt-in line keeps its handle through a round trip.
    func testV2OptInLineDecodesItsHandle() throws {
        let dir = makeDirectory()
        try write([recordLine(extra: #","utteranceHandle":"3f9a1c7d2b6e8405""#)], to: dir)

        let records = IntentLogStore(directory: dir).recent()
        XCTAssertEqual(records.first?.utteranceHandle, "3f9a1c7d2b6e8405")
    }

    /// V3 — an explicit null. The writer never emits this (a nil optional
    /// is omitted), but a reader that chokes on it would drop a line some
    /// other producer wrote.
    func testV3ExplicitNullHandleDecodesAsNil() throws {
        let dir = makeDirectory()
        try write([recordLine(extra: #","utteranceHandle":null"#)], to: dir)

        let records = IntentLogStore(directory: dir).recent()
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.utteranceHandle)
    }

    /// V4 — the downgrade-safety proof: a line from a LATER schema (an
    /// unknown key) must not make this build drop the record.
    func testV4ForwardCompatibleLineWithUnknownKeyIsKept() throws {
        let dir = makeDirectory()
        try write([recordLine(extra: #","egressBucket":"ge_0_7","minedAt":12345"#)], to: dir)

        let records = IntentLogStore(directory: dir).recent()
        XCTAssertEqual(records.count, 1, "V4: a future field must not delete the line")
        XCTAssertEqual(records.first?.action, "call")
        XCTAssertNil(records.first?.utteranceHandle)
    }

    /// V5 — the C-7 proof, through the REAL seam: the same verdict written
    /// with the loop OFF carries exactly the shipped keys, and no
    /// `utteranceHandle` key at all (omitted, never null). Key SETS, not
    /// bytes: `JSONEncoder`'s ordering is unspecified.
    func testV5OptInOffRecordIsFieldForFieldTheShippedRecord() throws {
        let dir = makeDirectory()
        let store = IntentLogStore(directory: dir)
        let now = Date()
        let verdictAt = now.addingTimeInterval(1.5)
        // The shipped shape, built the way the pre-loop code built it —
        // same verdict, same slots, same confidence, same latency.
        store.append(IntentLogStore.Record(path: "model", action: "call",
                                           slots: ["contact": "maiya"],
                                           outcome: "confirmed",
                                           confidence: 0.7, latencyMs: 1500,
                                           timestamp: now))
        // The same verdict through the capture seam with no handle — the
        // only value the seam passes while the opt-in is off.
        store.append(IntentLogStore.Capture(action: "call",
                                            slots: ["contact": "maiya"],
                                            confidence: 0.7,
                                            requestedAt: now)
            .record(.confirmed, utteranceHandle: nil, at: verdictAt))
        try waitFor(store) { $0.count == 2 }

        let lines = rawLogText(in: dir).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        let shipped = try keysOfLine(lines[0])
        let seamed = try keysOfLine(lines[1])
        XCTAssertEqual(shipped, seamed, "V5: the OFF record's key set is unchanged")
        XCTAssertEqual(shipped, ["id", "timestamp", "path", "action", "slots",
                                 "outcome", "confidence", "latencyMs"],
                       "the shipped key set, with no loop field in it")
        XCTAssertFalse(lines[1].contains("utteranceHandle"),
                       "the key is omitted, never written as null")
    }

    /// V7 — the opt-out strip. A mix of handle-bearing and handle-free
    /// lines; after the strip every line still decodes with no handle, and
    /// nothing else about the log moved.
    func testV7OptOutStripRemovesEveryHandleAndPreservesOrder() throws {
        let dir = makeDirectory()
        let store = IntentLogStore(directory: dir)
        store.append(IntentLogStore.Record(path: "model", action: "call",
                                           slots: ["contact": "a"], outcome: "confirmed",
                                           utteranceHandle: "3f9a1c7d2b6e8405",
                                           timestamp: Date().addingTimeInterval(1)))
        store.append(IntentLogStore.Record(path: "model", action: "call",
                                           slots: ["contact": "b"], outcome: "denied",
                                           timestamp: Date().addingTimeInterval(2)))
        store.append(IntentLogStore.Record(path: "override", action: "call",
                                           slots: ["contact": "c"], outcome: "corrected",
                                           utteranceHandle: "0011223344556677",
                                           timestamp: Date().addingTimeInterval(3)))
        try waitFor(store) { $0.count == 3 }
        let idsBefore = store.recent(limit: 10).map(\.id)

        store.stripUtteranceHandles()

        let after = store.recent(limit: 10)
        XCTAssertEqual(after.count, 3, "V7: the strip deletes no record")
        XCTAssertEqual(after.map(\.id), idsBefore,
                       "V7: identity and file order are preserved")
        XCTAssertTrue(after.allSatisfy { $0.utteranceHandle == nil })
        XCTAssertFalse(rawLogText(in: dir).contains("utteranceHandle"),
                       "after the strip the file is the shipped file again")
        // ...and the export is field-for-field the shipped export.
        let export = try XCTUnwrap(store.exportURL())
        let exported = try String(contentsOf: export, encoding: .utf8)
        XCTAssertFalse(exported.contains("utteranceHandle"))
        XCTAssertTrue(exported.contains(#""outcome":"corrected""#))
    }

    /// The strip is a no-op when no line carries a handle — an opt-out on
    /// a loop that never ran must not rewrite the family's log.
    func testStripIsANoOpWithoutHandles() throws {
        let dir = makeDirectory()
        let store = IntentLogStore(directory: dir)
        store.append(IntentLogStore.Record(path: "model", action: "call",
                                           outcome: "confirmed"))
        try waitFor(store) { $0.count == 1 }
        let before = rawLogText(in: dir)

        store.stripUtteranceHandles()

        XCTAssertEqual(rawLogText(in: dir), before)
    }

    // MARK: - [INTENTLOG-CAPTURE] verdict → record mapping

    func testCaptureRecordsConfirmedVerdict() {
        let started = Date()
        let record = IntentLogStore.Capture(
            action: "call",
            slots: ["contact": "maiya", "method": "phone"],
            confidence: 0.91,
            requestedAt: started)
            .record(.confirmed, at: started.addingTimeInterval(1.5))

        XCTAssertEqual(record.outcome, "confirmed")
        XCTAssertEqual(record.path, "model", "the interpreted path is the only one with a confirmation")
        XCTAssertEqual(record.action, "call")
        XCTAssertEqual(record.slots?["contact"], "maiya")
        XCTAssertEqual(record.slots?["method"], "phone")
        XCTAssertEqual(record.confidence, 0.91)
        XCTAssertEqual(record.latencyMs, 1500, "question → verdict, in ms")
        XCTAssertNil(record.correctedTo)
    }

    func testCaptureRecordsDeniedVerdict() {
        let started = Date()
        let record = IntentLogStore.Capture(action: "call", confidence: 0.4,
                                            requestedAt: started)
            .record(.denied, at: started.addingTimeInterval(2))
        XCTAssertEqual(record.outcome, "denied")
        XCTAssertEqual(record.latencyMs, 2000)
    }

    func testCaptureRecordsTimeoutVerdict() {
        let started = Date()
        let record = IntentLogStore.Capture(action: "create_calendar_event",
                                            requestedAt: started)
            .record(.timeout, at: started.addingTimeInterval(45))
        XCTAssertEqual(record.outcome, "timeout")
        XCTAssertEqual(record.latencyMs, 45_000, "the 45 s window is the timeout's own latency")
    }

    func testCaptureRecordsCorrectionWithOverridePath() {
        let started = Date()
        let record = IntentLogStore.Capture(action: "call",
                                            slots: ["contact": "maiya", "method": "facetimeAudio"],
                                            confidence: 0.55,
                                            requestedAt: started)
            .record(.corrected, path: "override",
                    correctedTo: ["method": "phone"],
                    at: started.addingTimeInterval(3))
        XCTAssertEqual(record.outcome, "corrected")
        XCTAssertEqual(record.path, "override", "the historical correction path is preserved")
        XCTAssertEqual(record.correctedTo?["method"], "phone")
        XCTAssertEqual(record.slots?["method"], "facetimeAudio", "the plan that was rejected")
        XCTAssertEqual(record.confidence, 0.55)
        XCTAssertEqual(record.latencyMs, 3000)
    }

    func testCaptureWithoutStartCarriesNoLatency() {
        let record = IntentLogStore.Capture(action: "call").record(.confirmed)
        XCTAssertNil(record.confidence, "no interpreted command in hand → unknown, not 0")
        XCTAssertNil(record.latencyMs, "no start → no latency, never a fabricated 0")
    }

    func testCaptureLatencyNeverGoesNegative() {
        let started = Date()
        let record = IntentLogStore.Capture(action: "call", requestedAt: started)
            .record(.denied, at: started.addingTimeInterval(-3))
        XCTAssertEqual(record.latencyMs, 0, "a backwards clock must not write a negative latency")
    }

    /// End-to-end through the store: what the capture seam produces is
    /// what the family export (and therefore the retrain loop) reads.
    func testCaptureRecordAppendsAndExports() throws {
        let store = makeStore()
        store.append(IntentLogStore.Capture(action: "call",
                                            slots: ["contact": "maiya"],
                                            confidence: 0.7)
            .record(.denied, at: Date()))
        store.append(IntentLogStore.Capture(action: "create_calendar_event")
            .record(.timeout, at: Date()))
        try waitFor(store) { $0.count == 2 }

        let recent = store.recent()
        XCTAssertEqual(recent.first?.outcome, "timeout")
        XCTAssertEqual(recent.last?.outcome, "denied")
        XCTAssertEqual(recent.last?.confidence, 0.7)
        let text = try String(contentsOf: store.exportURL()!, encoding: .utf8)
        XCTAssertTrue(text.contains("\"outcome\":\"denied\""))
        XCTAssertTrue(text.contains("\"outcome\":\"timeout\""))
    }

    // MARK: - [INTENTLOG-CAPTURE] coordinator capture identities

    // `AppCoordinator` itself is not constructible in the unit suite
    // (AVAudioEngine / ModelStore / APNs — the store-level seam doctrine
    // NoIOInInitTests documents), so the confirm-tier WIRING is asserted
    // where the coordinator's flows actually resolve their verdicts:
    // on the pending-action value each flow captures.

    func testCallPendingActionCaptureMatchesTheRecordedSchema() {
        let command = makeCommand(action: .call, contact: "maiya", confidence: 0.83)
        let action = AppCoordinator.PendingCallAction(
            contact: FamilyContact(name: "maiya", phone: "+9779800000000",
                                   relationship: "daughter"),
            method: .phone,
            unsupportedRequestedApp: nil,
            sourceTranscript: "मैयालाई फोन गर",
            sourceCommand: command)

        let capture = action.capture
        XCTAssertEqual(capture.action, "call")
        XCTAssertEqual(capture.slots?["contact"], "maiya")
        XCTAssertEqual(capture.slots?["method"], "phone")
        XCTAssertEqual(capture.confidence, 0.83, "the interpreter's confidence rides along")
        XCTAssertEqual(capture.requestedAt, action.requestedAt)
        XCTAssertEqual(capture.record(.confirmed).outcome, "confirmed")
        // [T-056-A] The utterance travels with the capture — the loop's
        // handle is derived from it at append time (T-054 §2.3).
        XCTAssertEqual(capture.transcript, "मैयालाई फोन गर")
    }

    /// [T-056-A] A correction has two ends, and the loop needs both: the
    /// `corrected` record's handle resolves to the MISHEARD utterance, and
    /// the amended action's own (confirmed) record resolves to the
    /// AMENDMENT. This pins the seam that makes the second end reachable —
    /// the amendment utterance replaces the source transcript on the
    /// rebuilt action, and the original is untouched for the record
    /// already written.
    func testCallPendingActionAmendmentTranscriptTakesOverTheCapture() {
        let command = makeCommand(action: .call, contact: "maiya", confidence: 0.55)
        var amended = AppCoordinator.PendingCallAction(
            contact: FamilyContact(name: "maiya", phone: "+9779800000000",
                                   relationship: "daughter"),
            method: .facetimeAudio,
            unsupportedRequestedApp: nil,
            sourceTranscript: "मैयालाई फेसटाइम गर",
            sourceCommand: command)

        XCTAssertEqual(amended.capture.transcript, "मैयालाई फेसटाइम गर",
                       "before the correction the action's own utterance is the source")

        amended.amendmentTranscript = "होइन, फोन नै गर"

        XCTAssertEqual(amended.capture.transcript, "होइन, फोन नै गर",
                       "the amendment is what the amended action's verdict is about")
        XCTAssertEqual(amended.sourceTranscript, "मैयालाई फेसटाइम गर",
                       "the original utterance is preserved — the corrected record"
                       + " still points at the misheard plan")
    }

    func testTouchOriginatedCallCaptureHasNoConfidence() {
        let action = AppCoordinator.PendingCallAction(
            contact: FamilyContact(name: "maiya", phone: "+9779800000000",
                                   relationship: "daughter"),
            method: .facetimeVideo,
            unsupportedRequestedApp: nil,
            sourceTranscript: nil,
            sourceCommand: nil)

        let capture = action.capture
        XCTAssertNil(capture.confidence, "no interpreted command → confidence unknown")
        XCTAssertEqual(capture.slots?["method"], "facetimeVideo")
    }

    func testCalendarPendingEventCaptureHasNoSlots() {
        let started = Date()
        let event = AppCoordinator.PendingCalendarEvent(
            title: "डाक्टर भेट", startDate: started.addingTimeInterval(3600))

        let capture = event.capture
        XCTAssertEqual(capture.action, "create_calendar_event",
                       "the canonical InterpretedCommand.Action raw value")
        XCTAssertNil(capture.slots, "the event title is user content and is never captured")
        XCTAssertNotNil(capture.requestedAt)
        let record = capture.record(.denied)
        XCTAssertEqual(record.outcome, "denied")
        XCTAssertNotNil(record.latencyMs, "the question's clock is known, so latency is written")
        XCTAssertGreaterThanOrEqual(record.latencyMs ?? -1, 0)
    }

    // MARK: - tiny async helper

    private func waitFor(_ store: IntentLogStore,
                         timeout: TimeInterval = 5,
                         until predicate: @escaping (IntentLogStore) -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(store) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("timed out waiting for intent log")
        throw NSError(domain: "tests", code: 1)
    }
}
