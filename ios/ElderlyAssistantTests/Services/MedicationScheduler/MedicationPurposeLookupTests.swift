import XCTest
@testable import ElderlyAssistant

/// "What is this medicine for?" — the settings-side web lookup
/// ([MED-PURPOSE-LOOKUP], 2026-09-18).
///
/// The lookup runs through the SAME search stack the voice tool uses
/// (`SearchTool` over `LocalToolTransport`), which is why the assertions here
/// are about the four honest outcomes rather than about a new client:
///
///  - the credential PAIR gate (both halves, or nothing fires),
///  - the shared daily quota (`SearchQuota` — one budget for voice and
///    settings alike, spent on ATTEMPT like the router spends it),
///  - never a fabricated answer: an unconfigured tool, an empty result set,
///    a broken body and a failed round-trip are four different reports, and
///    none of them is ever a `.found`.
final class MedicationPurposeLookupTests: XCTestCase {

    private let suiteName = "MedicationPurposeLookupTests"
    private var defaults: UserDefaults!
    /// A fixed "now" so the quota's day bucket is deterministic — a test that
    /// rolled over at midnight would be a test that fails at midnight.
    private let fixedNow = Date(timeIntervalSince1970: 1_787_000_000)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Doubles

    /// A scripted CSE round-trip. Records the requests so the URL, the query
    /// and the timeout are assertable without a network.
    private final class StubTransport: LocalToolTransport {
        private(set) var capturedRequests: [URLRequest] = []
        private let data: Data
        private let statusCode: Int
        private let error: Error?

        init(data: Data = Data(), statusCode: Int = 200, error: Error? = nil) {
            self.data = data
            self.statusCode = statusCode
            self.error = error
        }

        func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
            capturedRequests.append(request)
            if let error { throw error }
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://stub.local")!,
                                           statusCode: statusCode,
                                           httpVersion: nil,
                                           headerFields: nil)!
            return (data, response)
        }
    }

    private struct StubError: Error {}

    private func cseJSON(_ items: [(title: String, snippet: String, link: String)]) -> Data {
        let payload: [String: Any] = [
            "items": items.map { ["title": $0.title, "snippet": $0.snippet, "link": $0.link] }
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func makeService(credentials: MedicationPurposeLookupService.Credentials? =
                                MedicationPurposeLookupService.Credentials(
                                    apiKey: "test-key", searchEngineID: "test-cx"),
                             transport: LocalToolTransport?,
                             locale: Locale = Locale(identifier: "en"))
        -> MedicationPurposeLookupService {
        MedicationPurposeLookupService(credentials: { credentials },
                                       transport: transport,
                                       locale: { locale },
                                       defaults: defaults,
                                       now: { self.fixedNow })
    }

    private func seedUsedSearches(_ count: Int, on day: Date) {
        defaults.set(SearchQuota.dayStamp(for: day), forKey: SearchQuota.dayKey)
        defaults.set(count, forKey: SearchQuota.countKey)
    }

    private var usedSearches: Int { SearchQuota.readCount(defaults: defaults) }

    // MARK: - The query

    /// The query is the question the family is asking, in English in both app
    /// languages: the indexed medical pages mix scripts, and an English query
    /// retrieves both.
    func testQueryIsTheQuestionTheFamilyIsAsking() {
        XCTAssertEqual(MedicationPurposeLookupService.query(forMedicine: "Amlodipine"),
                       "what is Amlodipine used for")
    }

    // MARK: - Found

    /// The top hit becomes the field's text, through `SearchTool`'s own
    /// summary shaping (title, two-sentence cap, source host), and the shared
    /// quota records the attempt.
    func testFoundReturnsTheTopResultSummaryAndSpendsOneSearch() async {
        let transport = StubTransport(data: cseJSON([
            (title: "Amlodipine: uses",
             snippet: "Amlodipine is used to treat high blood pressure. It relaxes your blood vessels.",
             link: "https://www.nhs.uk/medicines/amlodipine"),
            (title: "Second hit",
             snippet: "This second result must not reach the field.",
             link: "https://example.com/second")
        ]))
        let service = makeService(transport: transport)

        let outcome = await service.lookupPurpose(forMedicine: "Amlodipine")

        guard case .found(let text) = outcome else {
            return XCTFail("expected .found, got \(outcome)")
        }
        XCTAssertTrue(text.contains("Amlodipine"), text)
        XCTAssertTrue(text.contains("nhs.uk"), "the source host is spoken: \(text)")
        XCTAssertFalse(text.contains("Second hit"),
                       "one result only — the field is a line, not a results page: \(text)")
        XCTAssertEqual(usedSearches, 1)

        let request = transport.capturedRequests.first
        XCTAssertEqual(request?.url?.host, "www.googleapis.com")
        XCTAssertEqual(request?.url?.path, "/customsearch/v1")
        let queryItems = request?.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
        } ?? []
        XCTAssertEqual(queryItems.first { $0.name == "q" }?.value, "what is Amlodipine used for")
        XCTAssertEqual(queryItems.first { $0.name == "key" }?.value, "test-key")
        XCTAssertEqual(queryItems.first { $0.name == "cx" }?.value, "test-cx")
        XCTAssertEqual(request?.timeoutInterval, MedicationPurposeLookupService.fetchTimeoutSeconds)
    }

    /// A name with whitespace around it is asked about trimmed — the family
    /// typed it by hand.
    func testNameIsTrimmedBeforeTheSearch() async {
        let transport = StubTransport(data: cseJSON([
            (title: "Metformin", snippet: "Used for diabetes.", link: "https://example.com/m")
        ]))
        let service = makeService(transport: transport)

        let outcome = await service.lookupPurpose(forMedicine: "  Metformin \n")

        guard case .found = outcome else { return XCTFail("expected .found, got \(outcome)") }
        let queryItems = transport.capturedRequests.first?.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
        } ?? []
        XCTAssertEqual(queryItems.first { $0.name == "q" }?.value, "what is Metformin used for")
    }

    /// The Nepali summary uses the Nepali sentence stop — the same
    /// `SearchTool` shaping the voice search uses, resolved for the app's
    /// active language.
    func testNepaliLocaleUsesTheNepaliSentenceStop() async {
        let transport = StubTransport(data: cseJSON([
            (title: "एम्लोडिपिन", snippet: "रक्तचापको लागि प्रयोग गरिन्छ।", link: "https://example.com/n")
        ]))
        let service = makeService(transport: transport, locale: Locale(identifier: "ne"))

        let outcome = await service.lookupPurpose(forMedicine: "एम्लोडिपिन")

        guard case .found(let text) = outcome else {
            return XCTFail("expected .found, got \(outcome)")
        }
        XCTAssertTrue(text.contains("।"), text)
    }

    // MARK: - The honest non-answers

    /// A blank name is not an unconfigured tool and not a failed search:
    /// there is nothing to ask about, nothing leaves the device, and nothing
    /// is spent.
    func testBlankNameAsksNothingAndSpendsNothing() async {
        let transport = StubTransport(data: cseJSON([]))
        let service = makeService(transport: transport)

        let outcome = await service.lookupPurpose(forMedicine: "   \n ")

        XCTAssertEqual(outcome, .noResults)
        XCTAssertTrue(transport.capturedRequests.isEmpty)
        XCTAssertEqual(usedSearches, 0)
    }

    /// No credential pair, no search — and no quota spent on a search that
    /// never fired. This is the line the family sees instead of silence.
    func testUnconfiguredToolIsReportedWithoutSpending() async {
        let transport = StubTransport(data: cseJSON([]))
        let service = makeService(credentials: nil, transport: transport)

        let outcome = await service.lookupPurpose(forMedicine: "Amlodipine")

        XCTAssertEqual(outcome, .notConfigured)
        XCTAssertTrue(transport.capturedRequests.isEmpty)
        XCTAssertEqual(usedSearches, 0)
    }

    /// Credentials without a transport is a wiring failure, reported as
    /// itself rather than as an empty answer.
    func testMissingTransportIsUnavailable() async {
        let service = makeService(transport: nil)

        let outcome = await service.lookupPurpose(forMedicine: "Amlodipine")

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(usedSearches, 0)
    }

    /// A search that matched nothing is `.noResults` — NOT an empty
    /// `.found`, which would put a blank "answer" in the field.
    func testEmptyResultsAreNoResults() async {
        let service = makeService(transport: StubTransport(data: cseJSON([])))

        let outcome = await service.lookupPurpose(forMedicine: "Amlodipine")

        XCTAssertEqual(outcome, .noResults)
        XCTAssertEqual(usedSearches, 1, "the search DID run, and Google counted it")
    }

    /// A broken body and an empty result set are the same answer — the
    /// router's own reading of `parseSearchJSON`'s [].
    func testUnreadableBodyIsNoResults() async {
        let service = makeService(transport: StubTransport(data: Data("not json at all".utf8)))

        let outcome = await service.lookupPurpose(forMedicine: "Amlodipine")

        XCTAssertEqual(outcome, .noResults)
    }

    /// An item with no title, snippet or link is dropped by the parser, so a
    /// set of empty items is no results either.
    func testEmptyItemsAreNoResults() async {
        let service = makeService(transport: StubTransport(
            data: cseJSON([(title: "", snippet: "", link: "")])))

        let outcome = await service.lookupPurpose(forMedicine: "Amlodipine")

        XCTAssertEqual(outcome, .noResults)
    }

    /// A failed round-trip is reported as unavailable and NEVER as an answer.
    /// The attempt still spent the quota: Google was asked, and attempt-based
    /// accounting is how the router spends it too.
    func testTransportFailureIsUnavailableAndStillSpentTheAttempt() async {
        let service = makeService(transport: StubTransport(error: StubError()))

        let outcome = await service.lookupPurpose(forMedicine: "Amlodipine")

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(usedSearches, 1)
    }

    /// A non-200 is a failed search, not an answer.
    func testNon200IsUnavailable() async {
        let service = makeService(transport: StubTransport(
            data: cseJSON([(title: "Amlodipine", snippet: "x", link: "https://example.com")]),
            statusCode: 503))

        let outcome = await service.lookupPurpose(forMedicine: "Amlodipine")

        XCTAssertEqual(outcome, .unavailable)
    }

    // MARK: - The shared quota

    /// Today's budget is spent: the lookup stops BEFORE the request, so
    /// nothing leaves the device and the shared count does not move.
    func testCapReachedStopsBeforeTheRequest() async {
        seedUsedSearches(SearchQuota.dailyLimit, on: fixedNow)
        let transport = StubTransport(data: cseJSON([]))
        let service = makeService(transport: transport)

        let outcome = await service.lookupPurpose(forMedicine: "Amlodipine")

        XCTAssertEqual(outcome, .capReached)
        XCTAssertTrue(transport.capturedRequests.isEmpty)
        XCTAssertEqual(usedSearches, SearchQuota.dailyLimit)
    }

    /// A count recorded on a PREVIOUS day never blocks today's lookup — the
    /// household crosses midnight and gets its budget back, exactly as the
    /// voice search does.
    func testYesterdaysCountDoesNotBlockTodaysLookup() async {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: fixedNow)!
        seedUsedSearches(SearchQuota.dailyLimit, on: yesterday)
        let transport = StubTransport(data: cseJSON([
            (title: "Amlodipine", snippet: "Used for blood pressure.", link: "https://example.com")
        ]))
        let service = makeService(transport: transport)

        let outcome = await service.lookupPurpose(forMedicine: "Amlodipine")

        guard case .found = outcome else { return XCTFail("expected .found, got \(outcome)") }
        XCTAssertEqual(usedSearches, 1, "the new day's bucket starts at one")
    }

    /// The quota is one budget for voice and settings alike: a lookup and the
    /// voice tool read and write the same two keys.
    func testTheQuotaIsTheSameStoreTheVoiceSearchUses() {
        seedUsedSearches(7, on: fixedNow)

        XCTAssertEqual(usedSearches, 7)
        XCTAssertEqual(defaults.string(forKey: SearchQuota.dayKey),
                       SearchQuota.dayStamp(for: fixedNow))
    }
}
