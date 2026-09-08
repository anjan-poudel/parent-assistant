import XCTest
@testable import ElderlyAssistant

/// Feed service tests (feed-agent task, 2026-09-08) — bounded fetch,
/// TTL cache, per-source failure isolation, stale-grace, topic
/// filtering, and PII-free observability.
final class FeedServiceTests: XCTestCase {

    /// A one-item RSS fixture whose title is embedded in the XML.
    private func rss(title: String, summary: String = "",
                     enclosure: String = "") -> Data {
        var xml = "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>C</title>"
        xml += "<item><title>\(title)</title><link>https://example.com/i</link>"
        if !summary.isEmpty {
            xml += "<description>\(summary)</description>"
        }
        xml += enclosure
        xml += "</item></channel></rss>"
        return Data(xml.utf8)
    }

    /// A store seeded with the given sources/topics and NO defaults.
    private func makeStore(
        sources: [(name: String, url: String)],
        topics: [String] = []
    ) -> FeedSettingsStore {
        let store = FeedSettingsStore(storage: InMemoryStorage())
        for source in store.load().sources {
            _ = store.removeSource(id: source.id)
        }
        for source in sources {
            XCTAssertTrue(store.addSource(name: source.name, urlString: source.url),
                          "test source setup failed")
        }
        for topic in topics {
            XCTAssertTrue(store.addTopic(topic))
        }
        return store
    }

    private func makeService(store: FeedSettingsStore,
                             transport: StubFeedTransport,
                             bus: CapturingObservabilityBus = CapturingObservabilityBus())
        -> FeedService {
        FeedService(settings: store, transport: transport, observability: bus)
    }

    private func now(_ day: Int, hour: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = day
        components.hour = hour
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    // MARK: - Happy path

    func testRefreshComposesItemsFromAllSources() async {
        let store = makeStore(sources: [
            ("A", "https://a.example.com/rss"),
            ("B", "https://b.example.com/rss")
        ])
        let transport = StubFeedTransport(responses: [
            "https://a.example.com/rss": .success(rss(title: "Story A")),
            "https://b.example.com/rss": .success(rss(title: "Story B"))
        ])
        let service = makeService(store: store, transport: transport)

        let result = await service.refresh(now: now(8, hour: 8))

        XCTAssertFalse(result.fromCache)
        XCTAssertTrue(result.failedSourceNames.isEmpty)
        XCTAssertEqual(Set(result.items.map(\.sourceName)), ["A", "B"])
    }

    // MARK: - Failure isolation

    func testOneFailingSourceDoesNotBlankTheFeed() async {
        let store = makeStore(sources: [
            ("Good", "https://good.example.com/rss"),
            ("Bad", "https://bad.example.com/rss")
        ])
        let transport = StubFeedTransport(responses: [
            "https://good.example.com/rss": .success(rss(title: "Good story"))
            // "bad" is absent from the stub → throws
        ])
        let service = makeService(store: store, transport: transport)

        let result = await service.refresh(now: now(8, hour: 8))

        XCTAssertEqual(result.items.map(\.sourceName), ["Good"])
        XCTAssertEqual(result.failedSourceNames, ["Bad"])
    }

    func testAllSourcesFailWithNoCacheYieldsEmptyAndFailures() async {
        let store = makeStore(sources: [
            ("A", "https://a.example.com/rss"),
            ("B", "https://b.example.com/rss")
        ])
        let transport = StubFeedTransport(responses: [:])
        let service = makeService(store: store, transport: transport)

        let result = await service.refresh(now: now(8, hour: 8))

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(Set(result.failedSourceNames), ["A", "B"])
        XCTAssertFalse(result.fromCache)
    }

    // MARK: - TTL cache

    func testFreshCacheIsServedWithoutTransportCalls() async {
        let store = makeStore(sources: [("A", "https://a.example.com/rss")])
        let transport = StubFeedTransport(responses: [
            "https://a.example.com/rss": .success(rss(title: "Story A"))
        ])
        let service = makeService(store: store, transport: transport)

        _ = await service.refresh(now: now(8, hour: 8))
        XCTAssertEqual(transport.callCount, 1)

        let cached = await service.refresh(
            now: now(8, hour: 8).addingTimeInterval(FeedService.cacheTTL - 60))
        XCTAssertTrue(cached.fromCache)
        XCTAssertEqual(cached.items.count, 1)
        XCTAssertEqual(transport.callCount, 1, "TTL window must not refetch")
    }

    func testExpiredCacheRefetches() async {
        let store = makeStore(sources: [("A", "https://a.example.com/rss")])
        let transport = StubFeedTransport(responses: [
            "https://a.example.com/rss": .success(rss(title: "Story A"))
        ])
        let service = makeService(store: store, transport: transport)

        _ = await service.refresh(now: now(8, hour: 8))
        let refetched = await service.refresh(
            now: now(8, hour: 8).addingTimeInterval(FeedService.cacheTTL + 60))

        XCTAssertFalse(refetched.fromCache)
        XCTAssertEqual(transport.callCount, 2)
    }

    func testAllFailAfterCacheReturnsStaleItemsWithFailures() async {
        let store = makeStore(sources: [("A", "https://a.example.com/rss")])
        let transport = StubFeedTransport(responses: [
            "https://a.example.com/rss": .success(rss(title: "Story A"))
        ])
        let service = makeService(store: store, transport: transport)

        _ = await service.refresh(now: now(8, hour: 8))

        // Source now dies and the TTL has expired: the stale items are
        // the honest answer, with the failure names attached.
        transport.responses = [:]
        let stale = await service.refresh(
            now: now(8, hour: 8).addingTimeInterval(FeedService.cacheTTL + 60))

        XCTAssertTrue(stale.fromCache)
        XCTAssertEqual(stale.items.count, 1)
        XCTAssertEqual(stale.failedSourceNames, ["A"])
    }

    // MARK: - Topics

    func testTopicsFilterAppliedPerSource() async {
        let store = makeStore(
            sources: [("A", "https://a.example.com/rss")],
            topics: ["health"]
        )
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel><title>C</title>
        <item><title>Health clinic opens</title><link>https://e/1</link></item>
        <item><title>Sports roundup</title><link>https://e/2</link></item>
        </channel></rss>
        """
        let transport = StubFeedTransport(responses: [
            "https://a.example.com/rss": .success(Data(xml.utf8))
        ])
        let service = makeService(store: store, transport: transport)

        let result = await service.refresh(now: now(8, hour: 8))

        XCTAssertEqual(result.items.map(\.title), ["Health clinic opens"])
    }

    // MARK: - Per-source item cap

    func testPerSourceItemCapIsEnforced() async {
        let store = makeStore(sources: [("A", "https://a.example.com/rss")])
        var xml = "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>C</title>"
        for index in 0..<30 {
            xml += "<item><title>S\(index)</title><link>https://e/\(index)</link></item>"
        }
        xml += "</channel></rss>"
        let transport = StubFeedTransport(responses: [
            "https://a.example.com/rss": .success(Data(xml.utf8))
        ])
        let service = makeService(store: store, transport: transport)

        let result = await service.refresh(now: now(8, hour: 8))

        XCTAssertEqual(result.items.count, FeedService.maxItemsPerSource)
    }

    // MARK: - Observability (PII-free)

    func testObservabilityLogsHostAndCountsOnly() async {
        let store = makeStore(sources: [
            ("Secret Source", "https://user:token@feeds.example.com/private?key=abc")
        ])
        let bus = CapturingObservabilityBus()
        let transport = StubFeedTransport(responses: [
            "https://user:token@feeds.example.com/private?key=abc":
                .success(rss(title: "Story"))
        ])
        let service = makeService(store: store, transport: transport, bus: bus)

        _ = await service.refresh(now: now(8, hour: 8))

        let events = bus.events.filter { $0.component == "feed" }
        XCTAssertFalse(events.isEmpty)
        for event in events {
            XCTAssertEqual(event.metadata["host"], "feeds.example.com",
                           "only the hostname may be logged")
            XCTAssertFalse(event.metadata.values.contains {
                $0.contains("token") || $0.contains("Story")
            }, "titles, tokens and query strings must never reach the log")
        }
        XCTAssertEqual(
            bus.events.first(where: { $0.component == "feed" })?.metadata["entry_count"],
            "1")
    }

    func testHostExtraction() {
        XCTAssertEqual(FeedService.host(of: "https://user:pw@x.example.com/a?q=1"),
                       "x.example.com")
        XCTAssertEqual(FeedService.host(of: "not a url"), "")
    }
}

// MARK: - Test doubles

/// Transport stub keyed by source URL string.
private final class StubFeedTransport: FeedTransport {
    var responses: [String: Result<Data, Error>]
    private(set) var callCount = 0

    init(responses: [String: Result<Data, Error>]) {
        self.responses = responses
    }

    func fetchFeedData(from url: URL, timeout: TimeInterval) async throws
        -> (Data, URLResponse) {
        callCount += 1
        guard let result = responses[url.absoluteString] else {
            throw URLError(.cannotFindHost)
        }
        switch result {
        case .success(let data):
            return (data, URLResponse())
        case .failure(let error):
            throw error
        }
    }
}

private final class CapturingObservabilityBus: ObservabilityBus {
    private(set) var events: [ObservabilityEvent] = []
    func emit(_ event: ObservabilityEvent) {
        events.append(event)
    }
}

private final class InMemoryStorage: EncryptedLocalStorage {
    private var values: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        do {
            values[key] = try encoder.encode(value)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard let data = values[key] else { return .failure(.encryptedReadFailed) }
        do {
            return .success(try decoder.decode(T.self, from: data))
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        values.removeValue(forKey: key)
        return .success(())
    }
}
