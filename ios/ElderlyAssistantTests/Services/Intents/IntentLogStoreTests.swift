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
