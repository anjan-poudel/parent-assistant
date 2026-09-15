import XCTest
@testable import ElderlyAssistant

final class IntentLogStoreTests: XCTestCase {

    private func makeStore() -> IntentLogStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intentlog-tests-\(UUID().uuidString)", isDirectory: true)
        return IntentLogStore(directory: dir)
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
