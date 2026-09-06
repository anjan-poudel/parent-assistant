import XCTest
@testable import ElderlyAssistant

/// Cost governance (open item #5, 2026-09-06): unit tests for
/// `GeminiCostGovernor` itself — local-calendar-day rollover, persistence,
/// cap accounting semantics, once-per-day observability, pruning, and
/// concurrent `recordCall` safety. Date injection (`now:`) drives the
/// rollover boundary without touching wall-clock time.
final class GeminiCostGovernorTests: XCTestCase {

    /// A fixed local day — built through `Calendar.current` so the
    /// governor's own local-calendar keying is stable regardless of the
    /// test machine's time zone.
    private func localDate(_ y: Int, _ m: Int, _ d: Int, hour: Int = 10) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    /// The `@Published` mirrors hop to the main queue; drain it before
    /// asserting on them so the enqueued update has run.
    private func drainMain() async {
        await MainActor.run {}
    }

    private func costEvents(_ bus: MockObservabilityBus, _ type: String) -> [ObservabilityEvent] {
        bus.emittedEvents.filter { $0.component == "gemini_cost" && $0.eventType == type }
    }

    // MARK: - Day rollover

    func testRolloverResetsCountOnNewLocalDay() async {
        var current = localDate(2026, 9, 6)
        let storage = GeminiInMemoryStorage()
        let governor = GeminiCostGovernor(storage: storage, observabilityBus: MockObservabilityBus(),
                                          now: { current })

        governor.recordCall()
        governor.recordCall()
        governor.recordCall()
        await drainMain()
        XCTAssertEqual(governor.callsToday, 3)
        XCTAssertTrue(governor.allowsCall())

        // Next local day: the count rolls over. `callsToday` is a
        // UI mirror that republishes on mutation only — so the rollover
        // is proven by the NEXT record starting from zero, not by
        // reading the mirror cold after moving the clock.
        current = localDate(2026, 9, 7)
        governor.recordCall()
        await drainMain()
        XCTAssertEqual(governor.callsToday, 1,
                       "a new local day must start counting from zero")
        XCTAssertTrue(governor.allowsCall())

        // And the clock can move back (timezone travel / clock fix): the
        // earlier day's count is still there.
        current = localDate(2026, 9, 6)
        governor.recordCall()
        await drainMain()
        XCTAssertEqual(governor.callsToday, 4)
    }

    func testCountsPersistAcrossInstances() async {
        let storage = GeminiInMemoryStorage()
        let now = localDate(2026, 9, 6)
        let first = GeminiCostGovernor(storage: storage, observabilityBus: MockObservabilityBus(),
                                       now: { now })
        first.recordCall()
        first.recordCall()

        let second = GeminiCostGovernor(storage: storage, observabilityBus: MockObservabilityBus(),
                                        now: { now })
        await drainMain()
        XCTAssertEqual(second.callsToday, 2)
        XCTAssertEqual(second.softDailyCap, GeminiCostGovernor.defaultSoftDailyCap)
    }

    // MARK: - Cap accounting

    func testAllowsUpToCapThenBlocksAndStaysBlocked() async {
        let governor = GeminiCostGovernor(storage: GeminiInMemoryStorage(),
                                          observabilityBus: MockObservabilityBus(),
                                          now: { self.localDate(2026, 9, 6) })
        governor.setSoftDailyCap(10)

        XCTAssertTrue(governor.allowsCall())
        for _ in 0..<10 { governor.recordCall() }   // 10th fills the cap
        XCTAssertFalse(governor.allowsCall(), "count == cap must refuse further calls")

        // recordCall after the cap is still counted (an in-flight attempt
        // that was allowed before the cap closed) — but the gate stays shut.
        governor.recordCall()
        await drainMain()
        XCTAssertEqual(governor.callsToday, 11)
        XCTAssertFalse(governor.allowsCall())
    }

    func testSetSoftDailyCapPersistsAndClamps() async {
        let storage = GeminiInMemoryStorage()
        let now = localDate(2026, 9, 6)
        let governor = GeminiCostGovernor(storage: storage, observabilityBus: MockObservabilityBus(),
                                          now: { now })

        governor.setSoftDailyCap(42)
        await drainMain()
        XCTAssertEqual(governor.softDailyCap, 42)

        // Out-of-bounds values clamp to the hard bounds. Each mutation
        // is followed by a main-queue drain — the mirror republishes
        // asynchronously, so asserting between mutation and drain races
        // the update.
        governor.setSoftDailyCap(5)
        await drainMain()
        XCTAssertEqual(governor.softDailyCap, GeminiCostGovernor.minimumSoftDailyCap)
        governor.setSoftDailyCap(100_000)
        await drainMain()
        XCTAssertEqual(governor.softDailyCap, GeminiCostGovernor.maximumSoftDailyCap)

        // And the clamped cap persists across instances.
        let reloaded = GeminiCostGovernor(storage: storage, observabilityBus: MockObservabilityBus(),
                                          now: { now })
        await drainMain()
        XCTAssertEqual(reloaded.softDailyCap, GeminiCostGovernor.maximumSoftDailyCap)
    }

    // MARK: - Observability

    func testWarningFiresOncePerDayAt80Percent() async {
        var current = localDate(2026, 9, 6)
        let bus = MockObservabilityBus()
        let governor = GeminiCostGovernor(storage: GeminiInMemoryStorage(), observabilityBus: bus,
                                          now: { current })
        // Default cap 200 → warning threshold 160.
        XCTAssertEqual(GeminiCostGovernor.warningThreshold(cap: 200), 160)

        for _ in 0..<159 { governor.recordCall() }
        XCTAssertTrue(costEvents(bus, "daily_cap_warning").isEmpty, "below 80% must not warn")

        governor.recordCall()   // 160 — first crossing of 80%
        XCTAssertEqual(costEvents(bus, "daily_cap_warning").count, 1)

        for _ in 0..<39 { governor.recordCall() }   // up to 199
        XCTAssertEqual(costEvents(bus, "daily_cap_warning").count, 1,
                       "warning is once-per-day, not per-record")

        governor.recordCall()   // 200 — the cap crossing is its own event
        XCTAssertEqual(costEvents(bus, "daily_cap_warning").count, 1)
        XCTAssertEqual(costEvents(bus, "daily_cap_reached").count, 1)

        // A NEW local day may warn again.
        current = localDate(2026, 9, 7)
        for _ in 0..<160 { governor.recordCall() }
        XCTAssertEqual(costEvents(bus, "daily_cap_warning").count, 2)
    }

    func testCapReachedEventFiresOnlyOnCrossing() {
        let bus = MockObservabilityBus()
        let governor = GeminiCostGovernor(storage: GeminiInMemoryStorage(), observabilityBus: bus,
                                          now: { self.localDate(2026, 9, 6) })
        governor.setSoftDailyCap(10)

        for _ in 0..<9 { governor.recordCall() }
        XCTAssertTrue(costEvents(bus, "daily_cap_reached").isEmpty)

        governor.recordCall()   // 10th — crossing
        XCTAssertEqual(costEvents(bus, "daily_cap_reached").count, 1)

        // Attempts recorded beyond the cap (in-flight overshoot) are not
        // fresh crossings and must not re-fire the event.
        for _ in 0..<5 { governor.recordCall() }
        XCTAssertEqual(costEvents(bus, "daily_cap_reached").count, 1)
    }

    // MARK: - Pruning

    func testPrunesDaysOlderThanRetentionWindow() {
        var current = localDate(2026, 9, 1)
        let storage = GeminiInMemoryStorage()
        let governor = GeminiCostGovernor(storage: storage, observabilityBus: MockObservabilityBus(),
                                          now: { current })

        for day in 1...20 {
            current = localDate(2026, 9, day)
            governor.recordCall()
        }

        let persisted: GeminiCostGovernor.Persisted
        switch storage.read(key: GeminiCostGovernor.storageKey, type: GeminiCostGovernor.Persisted.self) {
        case .success(let value): persisted = value
        case .failure: return XCTFail("expected persisted payload")
        }
        // 20 days of records, retention window of 7 → only 2026-09-14..20.
        XCTAssertEqual(persisted.dailyCounts.count, 7)
        XCTAssertEqual(persisted.dailyCounts.keys.sorted().first, "2026-09-14")
        XCTAssertEqual(persisted.dailyCounts.keys.sorted().last, "2026-09-20")
    }

    // MARK: - Thread safety

    func testConcurrentRecordCallsLoseNone() async {
        let governor = GeminiCostGovernor(storage: GeminiInMemoryStorage(),
                                          observabilityBus: MockObservabilityBus(),
                                          now: { self.localDate(2026, 9, 6) })
        let total = 500
        DispatchQueue.concurrentPerform(iterations: total) { _ in
            governor.recordCall()
        }
        await drainMain()
        XCTAssertEqual(governor.callsToday, total,
                       "concurrent recordCalls must not lose increments")
    }
}

/// Cap behavior through `GeminiClient` (open item #5, 2026-09-06): the
/// gate throws `dailyCapReached` BEFORE any network work; success and
/// HTTP/network failure both count as billable attempts; `notConfigured`
/// does not; a nil governor stays unlimited.
final class GeminiClientCostGovernorTests: XCTestCase {

    private var configStore: GeminiConfigStore!
    private var bus: MockObservabilityBus!
    private var transport: CountingGeminiTransport!
    private var storage: GeminiInMemoryStorage!
    private var governor: GeminiCostGovernor!
    private var current: Date!

    override func setUp() {
        super.setUp()
        current = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 9))
        configStore = GeminiConfigStore(storage: GeminiInMemoryStorage())
        configStore.save("fake-key")
        bus = MockObservabilityBus()
        transport = CountingGeminiTransport()
        storage = GeminiInMemoryStorage()
    }

    private func makeGovernedClient(cap: Int, streaming: GeminiStreamingTransport? = nil) -> GeminiClient {
        governor = GeminiCostGovernor(storage: storage, observabilityBus: bus, now: { self.current })
        governor.setSoftDailyCap(cap)
        return GeminiClient(configStore: configStore, observabilityBus: bus,
                            transport: transport,
                            streamingTransport: streaming ?? URLSession.shared,
                            costGovernor: governor)
    }

    private func drainMain() async {
        await MainActor.run {}
    }

    private func expectDailyCapReached(_ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected dailyCapReached")
        } catch GeminiClient.GeminiClientError.dailyCapReached {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCappedClientThrowsDailyCapReachedBeforeAnyNetworkCall() async throws {
        let client = makeGovernedClient(cap: 10)
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: "first"))
        _ = try await client.generateJSON(prompt: "first")
        await drainMain()
        XCTAssertEqual(governor.callsToday, 1)
        XCTAssertEqual(transport.callCount, 1)

        // Fill the cap through the governor directly (simulating the rest
        // of a busy day) so the next client call must be refused.
        for _ in 0..<9 { governor.recordCall() }
        await drainMain()
        XCTAssertFalse(governor.allowsCall())

        await expectDailyCapReached {
            _ = try await client.generateJSON(prompt: "second")
        }
        XCTAssertEqual(transport.callCount, 1,
                       "a capped attempt must not reach the network at all")
    }

    func testSuccessHTTPFailureAndNetworkFailureAllCountAsBillable() async throws {
        let client = makeGovernedClient(cap: 200)

        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: "ok"))
        _ = try await client.generateJSON(prompt: "success")

        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: "err", statusCode: 500))
        do {
            _ = try await client.generateJSON(prompt: "http failure")
            XCTFail("expected httpError")
        } catch GeminiClient.GeminiClientError.httpError(let status, _) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        struct NetworkDown: Error {}
        transport.nextResult = .failure(NetworkDown())
        do {
            _ = try await client.generateJSON(prompt: "network failure")
            XCTFail("expected propagated network error")
        } catch is NetworkDown {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        await drainMain()
        XCTAssertEqual(transport.callCount, 3)
        XCTAssertEqual(governor.callsToday, 3,
                       "the cost is the attempt — success AND failures count")
    }

    func testNotConfiguredDoesNotCountAgainstCap() async {
        configStore.clear()
        let client = makeGovernedClient(cap: 10)

        do {
            _ = try await client.generateJSON(prompt: "x")
            XCTFail("expected notConfigured")
        } catch GeminiClient.GeminiClientError.notConfigured {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await drainMain()
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertEqual(governor.callsToday, 0,
                       "a call that never left the device is not billable")
        XCTAssertTrue(governor.allowsCall())
    }

    func testCappedStreamingPathThrowsBeforeNetwork() async throws {
        let client = makeGovernedClient(cap: 10, streaming: TrapStreamingTransport())

        // Burn the whole day's budget through the regular (faked) path.
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: "ok"))
        _ = try await client.understand(
            audioData: Data([1, 2, 3]), mimeType: "audio/wav",
            context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne"))
        for _ in 0..<9 { governor.recordCall() }
        await drainMain()
        XCTAssertFalse(governor.allowsCall())

        await expectDailyCapReached {
            _ = try await client.understandStreaming(
                audioData: Data([1, 2, 3]), mimeType: "audio/wav",
                context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne"),
                onPartialTranscript: { _ in })
        }
    }

    func testNilGovernorKeepsUnlimitedBehavior() async throws {
        // Default construction (no costGovernor) — the pre-governance
        // contract: no cap gate exists, calls flow, nothing is counted.
        let client = GeminiClient(configStore: configStore, observabilityBus: bus,
                                  transport: transport)
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(text: "ok"))
        _ = try await client.generateJSON(prompt: "x")
        XCTAssertEqual(transport.callCount, 1)
    }
}

/// `GeminiStreamingTransport` fake that fails loudly if ever invoked —
/// proves the cap gate throws before the streaming path touches the
/// network.
private final class TrapStreamingTransport: GeminiStreamingTransport {
    struct ShouldNotBeCalled: Error {}
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        throw ShouldNotBeCalled()
    }
}

/// `GeminiTransport` fake that counts every network call — lets the cap
/// tests assert "NO network call when capped" precisely.
private final class CountingGeminiTransport: GeminiTransport {
    private(set) var callCount = 0
    var nextResult: Result<(Data, URLResponse), Error> =
        .success(FakeGeminiTransport.jsonResponse(text: "ok"))

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        switch nextResult {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
