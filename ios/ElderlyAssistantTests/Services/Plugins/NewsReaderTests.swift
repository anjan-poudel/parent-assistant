import XCTest
@testable import ElderlyAssistant

/// [NEWS-READER] (2026-09-08) `NewsReader` unit tests:
///  - SpeechSource surface (sourceID, `.briefing` lane, nil pull channel,
///    en+ne gating),
///  - fire(): the checking line is enqueued FIRST (never a silent
///    round-trip), then ONE digest announcement with the right card;
///  - per-source outcome mapping (`fetchSource`): ok / empty / failed for
///    HTTP, transport throws, malformed XML, missing transport, bad URL —
///    and the bounded 8 s per-source timeout on the request;
///  - honest failures: all sources down → the single `news.allFailed`
///    line; one source down → its per-source failure line;
///  - the in-flight guard: a second fire() during the round-trip speaks
///    the honest "already fetching" line and emits `news_fire_skipped`;
///  - feed-order determinism (concurrent fetches render in feed order);
///  - PII-free observability: headline text never reaches the bus.
final class NewsReaderTests: XCTestCase {

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    // MARK: - Fakes

    private final class Queue: SpeakQueueProtocol {
        var enqueued: [Announcement] = []
        var isSpeaking: Bool = false
        var currentCard: AnnouncementCard?
        func enqueue(_ announcement: Announcement) { enqueued.append(announcement) }
    }

    private final class Bus: ObservabilityBus {
        var emitted: [ObservabilityEvent] = []
        func emit(_ event: ObservabilityEvent) { emitted.append(event) }
    }

    private final class InMemoryStorage: EncryptedLocalStorage {
        var store: [String: Data] = [:]
        private let encoder = JSONEncoder()
        private let decoder = JSONDecoder()
        func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
            store[key] = (try? encoder.encode(value)) ?? Data()
            return .success(())
        }
        func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
            guard let data = store[key], let value = try? decoder.decode(type, from: data) else {
                return .failure(.encryptedReadFailed)
            }
            return .success(value)
        }
        func delete(key: String) -> Result<Void, StorageError> {
            store.removeValue(forKey: key)
            return .success(())
        }
    }

    private final class StubTransport: LocalToolTransport {
        /// Scripted per-request behavior; nil = throw (a dead feed).
        var handler: ((URLRequest) async throws -> (Data, URLResponse))?
        private(set) var requests: [URLRequest] = []
        func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            guard let handler else { throw URLError(.cannotConnectToHost) }
            return try await handler(request)
        }
    }

    /// Gate transport: blocks the in-flight fetch until the test releases
    /// it, so the re-entrancy guard is tested deterministically (no sleep
    /// races).
    private final class GatedTransport: LocalToolTransport {
        private var entryContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var hasEntered = false
        func waitUntilEntered() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if hasEntered { continuation.resume() } else { entryContinuation = continuation }
            }
        }
        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
        func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
            hasEntered = true
            entryContinuation?.resume()
            entryContinuation = nil
            await withCheckedContinuation { releaseContinuation = $0 }
            let body = "<rss version=\"2.0\"><channel><item><title>Gated headline</title></item></channel></rss>"
            return (Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    private func rss(_ titles: [String]) -> String {
        let items = titles.map { "<item><title>\($0)</title></item>" }.joined()
        return "<rss version=\"2.0\"><channel>\(items)</channel></rss>"
    }

    private func http(_ request: URLRequest, status: Int, body: String) -> (Data, URLResponse) {
        (Data(body.utf8),
         HTTPURLResponse(url: request.url!, statusCode: status,
                         httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    private func source(_ name: String, url: String = "https://example.com/feed") -> NewsSource {
        NewsSource(name: name, urlString: url, languageCode: "en")
    }

    private struct Harness {
        let queue = Queue()
        let bus = Bus()
        let storage = InMemoryStorage()
        let transport = StubTransport()

        func reader(configured: [NewsSource] = [],
                    transport: LocalToolTransport? = nil,
                    locale: Locale = Locale(identifier: "en-US")) -> NewsReader {
            let store = NewsSourceStore(storage: storage)
            if !configured.isEmpty { _ = store.save(configured) }
            return NewsReader(queue: queue,
                              observability: bus,
                              store: store,
                              transport: transport ?? self.transport,
                              locale: locale)
        }
    }

    // MARK: - SpeechSource surface

    func testSourceSurface() async {
        let harness = Harness()
        let reader = harness.reader()
        XCTAssertEqual(reader.sourceID, "news_reader")
        XCTAssertEqual(reader.defaultPriority, .briefing)
        let pulled = await reader.nextAnnouncement()
        XCTAssertNil(pulled, "the reader is push-driven — nothing is ever staged for the pull channel")
        XCTAssertTrue(reader.isApplicable(locale: en))
        XCTAssertTrue(reader.isApplicable(locale: ne))
        XCTAssertFalse(reader.isApplicable(locale: Locale(identifier: "fr-FR")))
    }

    // MARK: - fire() shape

    func testFireAnnouncesCheckingBeforeTheDigest() async {
        let harness = Harness()
        let configured = [source("BBC World", url: "https://example.com/bbc")]
        harness.transport.handler = { request in
            self.http(request, status: 200, body: self.rss(["First headline", "Second headline"]))
        }
        let reader = harness.reader(configured: configured)

        await reader.fire()

        XCTAssertEqual(harness.queue.enqueued.count, 2)
        XCTAssertEqual(harness.queue.enqueued[0].text,
                       L10n.str("news.checking", locale: en),
                       "the checking line is enqueued BEFORE the round-trip — never a silent fetch")
        XCTAssertEqual(harness.queue.enqueued[0].priority, .briefing)
        XCTAssertEqual(harness.queue.enqueued[0].card?.title,
                       L10n.str("news.cardTitle", locale: en))
        XCTAssertEqual(harness.queue.enqueued[1].text,
                       "From BBC World: First headline. Second headline.")
        XCTAssertEqual(harness.queue.enqueued[1].sourceID, "news_reader")
        XCTAssertEqual(harness.queue.enqueued[1].priority, .briefing)
    }

    func testFireComposesInNepali() async {
        let harness = Harness()
        let configured = [source("Ratopati", url: "https://example.com/ratopati")]
        harness.transport.handler = { request in
            self.http(request, status: 200, body: self.rss(["पहिलो शीर्षक"]))
        }
        let reader = harness.reader(configured: configured, locale: ne)

        await reader.fire()

        XCTAssertEqual(harness.queue.enqueued[0].text,
                       L10n.str("news.checking", locale: ne))
        XCTAssertEqual(harness.queue.enqueued[1].text,
                       L10n.fmt("news.sourceLine", locale: ne, "Ratopati") + " पहिलो शीर्षक।")
        XCTAssertEqual(harness.queue.enqueued[1].card?.title,
                       L10n.str("news.cardTitle", locale: ne))
    }

    // MARK: - Honest failures

    func testAllSourcesFailedSpeaksSingleHonestLine() async {
        let harness = Harness()
        harness.transport.handler = nil   // every fetch throws
        let reader = harness.reader()     // defaults: 6 sources

        await reader.fire()

        XCTAssertEqual(harness.queue.enqueued.count, 2)
        XCTAssertEqual(harness.queue.enqueued[1].text,
                       L10n.str("news.allFailed", locale: en),
                       "every source down → ONE honest line, not six failure lines")
    }

    func testOneFailedSourceGetsItsHonestPerSourceLine() async {
        let harness = Harness()
        let configured = [
            source("BBC World", url: "https://example.com/bbc"),
            source("Dead Feed", url: "https://example.com/dead")
        ]
        harness.transport.handler = { request in
            if request.url!.absoluteString.contains("dead") {
                throw URLError(.cannotConnectToHost)
            }
            return self.http(request, status: 200, body: self.rss(["Live headline"]))
        }
        let reader = harness.reader(configured: configured)

        await reader.fire()

        XCTAssertEqual(harness.queue.enqueued[1].text,
                       "From BBC World: Live headline.\n"
                       + L10n.fmt("news.sourceFailed", locale: en, "Dead Feed"))
    }

    func testTransportlessReaderFailsHonestly() async {
        let harness = Harness()
        let reader = NewsReader(queue: harness.queue,
                                observability: harness.bus,
                                store: NewsSourceStore(storage: harness.storage),
                                transport: nil,
                                locale: en)
        await reader.fire()
        XCTAssertEqual(harness.queue.enqueued.last?.text,
                       L10n.str("news.allFailed", locale: en))
    }

    // MARK: - fetchSource outcome mapping

    func testFetchSourceMapsOutcomes() async {
        let good = source("Good", url: "https://example.com/good")
        let emptyFeed = source("Empty", url: "https://example.com/empty")
        let badStatus = source("BadStatus", url: "https://example.com/500")
        let malformed = source("Malformed", url: "https://example.com/broken")
        // A URL string that cannot parse at all (invalid host character)
        // — exercises the `guard let source.url` branch, not the
        // transport-throw branch.
        let badURL = NewsSource(name: "BadURL",
                                urlString: "http://exa mple.com/feed",
                                languageCode: "en")

        let transport = StubTransport()
        transport.handler = { request in
            switch request.url!.path {
            case "/good": return self.http(request, status: 200, body: self.rss(["H1", "H2"]))
            case "/empty": return self.http(request, status: 200, body: self.rss([]))
            case "/500": return self.http(request, status: 500, body: "server error")
            case "/broken": return self.http(request, status: 200, body: "<rss><channel>oops")
            default: throw URLError(.cannotConnectToHost)
            }
        }

        // `fetchSource` is async — resolve each outcome BEFORE the
        // assertion (await inside an XCTAssert autoclosure is illegal).
        let goodResult = await NewsReader.fetchSource(good, transport: transport, timeout: 8)
        let emptyResult = await NewsReader.fetchSource(emptyFeed, transport: transport, timeout: 8)
        let badStatusResult = await NewsReader.fetchSource(badStatus, transport: transport, timeout: 8)
        let malformedResult = await NewsReader.fetchSource(malformed, transport: transport, timeout: 8)
        let badURLResult = await NewsReader.fetchSource(badURL, transport: transport, timeout: 8)
        let noTransportResult = await NewsReader.fetchSource(good, transport: nil, timeout: 8)

        XCTAssertEqual(goodResult,
                       NewsDigestComposer.SourceResult(source: good, outcome: .ok(["H1", "H2"])))
        XCTAssertEqual(emptyResult,
                       NewsDigestComposer.SourceResult(source: emptyFeed, outcome: .empty))
        XCTAssertEqual(badStatusResult,
                       NewsDigestComposer.SourceResult(source: badStatus, outcome: .failed),
                       "a non-2xx is a FAILURE, never 'nothing new'")
        XCTAssertEqual(malformedResult,
                       NewsDigestComposer.SourceResult(source: malformed, outcome: .failed))
        XCTAssertEqual(badURLResult,
                       NewsDigestComposer.SourceResult(source: badURL, outcome: .failed))
        XCTAssertEqual(noTransportResult,
                       NewsDigestComposer.SourceResult(source: good, outcome: .failed))
    }

    func testFetchSourceBoundsEachRequestWithTheEightSecondTimeout() async {
        let transport = StubTransport()
        transport.handler = { request in
            self.http(request, status: 200, body: self.rss(["H1"]))
        }
        let target = source("Good", url: "https://example.com/good")
        _ = await NewsReader.fetchSource(target, transport: transport, timeout: 8)
        XCTAssertEqual(transport.requests.first?.timeoutInterval,
                       NewsReader.perSourceTimeoutSeconds)
    }

    // MARK: - In-flight guard

    func testSecondFireWhileInFlightSpeaksAlreadyFetchingAndEmitsSkipped() async {
        let harness = Harness()
        let gated = GatedTransport()
        let reader = harness.reader(configured: [source("Slow", url: "https://example.com/slow")],
                                    transport: gated)

        let first = Task { await reader.fire() }
        await gated.waitUntilEntered()

        await reader.fire()   // in-flight — guarded, must not double-fetch

        gated.release()
        await first.value

        XCTAssertEqual(harness.queue.enqueued.map(\.text), [
            L10n.str("news.checking", locale: en),
            L10n.str("news.alreadyFetching", locale: en),
            "From Slow: Gated headline."
        ], "the guarded second fire speaks the honest line and never re-enqueues a digest")
        XCTAssertTrue(harness.bus.emitted.contains {
            $0.component == "news_reader" && $0.eventType == "news_fire_skipped"
                && $0.metadata["state"] == "in_flight"
        })
    }

    // MARK: - Determinism + privacy

    func testConcurrentFetchesRenderInFeedOrder() async {
        let harness = Harness()
        let configured = [
            source("Slow Source", url: "https://example.com/slow"),
            source("Fast Source", url: "https://example.com/fast")
        ]
        harness.transport.handler = { request in
            if request.url!.absoluteString.contains("slow") {
                try? await Task.sleep(nanoseconds: 100_000_000)   // 100 ms
            }
            return self.http(request, status: 200, body: self.rss(["H"]))
        }
        let reader = harness.reader(configured: configured)
        await reader.fire()

        let lines = harness.queue.enqueued[1].text.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("From Slow Source:"),
                      "results render in configured feed order regardless of completion order")
        XCTAssertTrue(lines[1].hasPrefix("From Fast Source:"))
    }

    func testObservabilityNeverCarriesHeadlines() async {
        let harness = Harness()
        harness.transport.handler = { request in
            self.http(request, status: 200,
                      body: self.rss(["Secret headline one", "Secret headline two"]))
        }
        let reader = harness.reader()
        await reader.fire()

        let newsEvents = harness.bus.emitted.filter { $0.component == "news_reader" }
        XCTAssertFalse(newsEvents.isEmpty, "the reader must be observable at all")
        for event in newsEvents {
            let everything = ([event.eventType, event.outcome]
                + [event.errorCode].compactMap { $0 }
                + event.metadata.keys + event.metadata.values)
                .joined(separator: " ")
            XCTAssertFalse(everything.contains("Secret headline"),
                           "headline text must never reach the observability bus")
        }
        let delivered = newsEvents.first { $0.eventType == "news_digest_delivered" }
        XCTAssertEqual(delivered?.metadata["source_count"], "6" as String?)
        XCTAssertEqual(delivered?.metadata["headline_count"], "12" as String?)
    }

    func testSourceResultEventsCarryCountsAndTagsOnly() async {
        let harness = Harness()
        harness.transport.handler = { request in
            self.http(request, status: 200, body: self.rss(["H1", "H2"]))
        }
        let reader = harness.reader()
        await reader.fire()

        let sourceEvents = harness.bus.emitted.filter {
            $0.component == "news_reader" && $0.eventType == "news_source_result"
        }
        XCTAssertEqual(sourceEvents.count, 6)
        for event in sourceEvents {
            XCTAssertEqual(Set(event.metadata.keys), ["index", "outcome", "headline_count"],
                           "per-source metadata is counts and tags only — no names, no headlines")
            XCTAssertEqual(event.metadata["outcome"], "ok" as String?)
            XCTAssertEqual(event.metadata["headline_count"], "2" as String?)
        }
    }
}
