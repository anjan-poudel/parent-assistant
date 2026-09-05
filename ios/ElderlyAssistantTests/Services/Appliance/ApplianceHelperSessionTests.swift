import XCTest
@testable import ElderlyAssistant

/// `ApplianceHelperSession` — the capture→answer pipeline: photo-hash
/// cache, the low-confidence brand+model cache check, the single
/// search-grounded retry (addendum §12.2), and honest failure states.
/// The Gemini boundary is faked with a sequenced transport.
@MainActor
final class ApplianceHelperSessionTests: XCTestCase {

    private var storage: GeminiInMemoryStorage!
    private var bus: MockObservabilityBus!

    override func setUp() {
        super.setUp()
        storage = GeminiInMemoryStorage()
        bus = MockObservabilityBus()
    }

    private let locale = Locale(identifier: "ne")

    private func makeSession(transport: SequencedGeminiTransport,
                             question: String? = "चिया कसरी बनाउने") -> ApplianceHelperSession {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let client = GeminiClient(configStore: store, observabilityBus: bus,
                                  transport: transport)
        return ApplianceHelperSession(question: question, locale: locale,
                                      geminiClient: client,
                                      cache: ApplianceCache(storage: storage),
                                      observabilityBus: bus, speaker: nil)
    }

    private func makeImage(w: CGFloat = 400, h: CGFloat = 300) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    private func payload(confidence: Double, brand: String? = nil, model: String? = nil) -> String {
        let brandJSON = brand.map { "\"\($0)\"" } ?? "null"
        let modelJSON = model.map { "\"\($0)\"" } ?? "null"
        return """
        {"identity": {"brand": \(brandJSON), "model": \(modelJSON),
                      "category": "microwave", "displayName": "test microwave"},
         "steps": ["step one", "step two"],
         "groundedControls": [],
         "spokenSummary": "summary",
         "confidence": \(confidence)}
        """
    }

    /// Waits until the session leaves `.working` (the pipeline runs on an
    /// unstructured Task inside the session).
    private func waitForPipeline(_ session: ApplianceHelperSession,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if case .working = session.state {
                try? await Task.sleep(nanoseconds: 10_000_000)
            } else {
                return
            }
        }
        XCTFail("pipeline never left .working", file: file, line: line)
    }

    // MARK: - Happy path

    func testSuccessfulIdentifyPresentsGuidanceAndCaches() async {
        let transport = SequencedGeminiTransport(results: [
            .success(FakeGeminiTransport.jsonResponse(text: payload(confidence: 0.9,
                                                                    brand: "LG", model: "M1")))
        ])
        let session = makeSession(transport: transport)
        session.handleCapturedPhoto(makeImage())
        await waitForPipeline(session)

        guard case let .guidance(presentation, _) = session.state else {
            XCTFail("expected guidance, got \(session.state)")
            return
        }
        XCTAssertFalse(presentation.hedged)
        XCTAssertEqual(presentation.guidance.identity.displayName, "test microwave")
        XCTAssertEqual(presentation.guidance.knowledgeSource, .onDeviceModelKnowledge)
        XCTAssertEqual(transport.requestCount, 1, "confident answer → no grounded retry")
        XCTAssertEqual(ApplianceCache(storage: storage).count, 1)
    }

    func testNetworkFailureLandsInUnavailableWithLocalizedMessage() async {
        struct NetworkDown: Error {}
        let transport = SequencedGeminiTransport(results: [.failure(NetworkDown())])
        let session = makeSession(transport: transport)
        session.handleCapturedPhoto(makeImage())
        await waitForPipeline(session)

        guard case let .unavailable(message) = session.state else {
            XCTFail("expected unavailable, got \(session.state)")
            return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNotEqual(message, "appliance.error.generic",
                          "the message must be resolved, not a raw key")
    }

    // MARK: - Photo-hash cache

    func testSamePhotoSecondTimeHitsCacheWithoutNetwork() async {
        let transport = SequencedGeminiTransport(results: [
            .success(FakeGeminiTransport.jsonResponse(text: payload(confidence: 0.9)))
        ])
        let image = makeImage()
        let session = makeSession(transport: transport)
        session.handleCapturedPhoto(image)
        await waitForPipeline(session)
        XCTAssertEqual(transport.requestCount, 1)

        // A NEW session over the SAME storage, same photo bytes → cache.
        let transport2 = SequencedGeminiTransport(results: [])
        let session2 = makeSession(transport: transport2)
        session2.handleCapturedPhoto(image)
        await waitForPipeline(session2)

        guard case .guidance = session2.state else {
            XCTFail("expected cached guidance, got \(session2.state)")
            return
        }
        XCTAssertEqual(transport2.requestCount, 0, "photo-hash hit must not hit the network")
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "gemini_vision_cache_hit" })
    }

    // MARK: - Low-confidence tiers (addendum §12.2 + design §2's post-call check)

    func testLowConfidenceTriggersOneGroundedRetryAndPicksTheWinner() async {
        let transport = SequencedGeminiTransport(results: [
            .success(FakeGeminiTransport.jsonResponse(text: payload(confidence: 0.3))),
            .success(FakeGeminiTransport.jsonResponse(text: payload(confidence: 0.85))),
        ])
        let session = makeSession(transport: transport)
        session.handleCapturedPhoto(makeImage())
        await waitForPipeline(session)

        guard case let .guidance(presentation, _) = session.state else {
            XCTFail("expected guidance, got \(session.state)")
            return
        }
        XCTAssertEqual(transport.requestCount, 2, "one grounded retry, not more")
        XCTAssertEqual(presentation.guidance.confidence, 0.85, accuracy: 0.0001)
        XCTAssertEqual(presentation.guidance.knowledgeSource, .webSearchGrounded)
        XCTAssertFalse(presentation.hedged)
    }

    func testLowConfidenceWithWorseGroundedRetryKeepsTheFreshAnswer() async {
        let transport = SequencedGeminiTransport(results: [
            .success(FakeGeminiTransport.jsonResponse(text: payload(confidence: 0.3))),
            .success(FakeGeminiTransport.jsonResponse(text: payload(confidence: 0.2))),
        ])
        let session = makeSession(transport: transport)
        session.handleCapturedPhoto(makeImage())
        await waitForPipeline(session)

        guard case let .guidance(presentation, _) = session.state else {
            XCTFail("expected guidance, got \(session.state)")
            return
        }
        XCTAssertEqual(presentation.guidance.confidence, 0.3, accuracy: 0.0001)
        XCTAssertEqual(presentation.guidance.knowledgeSource, .onDeviceModelKnowledge)
        // §4.1: a still-low-confidence answer is presented HEDGED, never refused.
        XCTAssertTrue(presentation.hedged)
    }

    func testLowConfidencePrefersAnExistingBrandModelCacheEntryOverGroundedRetry() async {
        // A previous session cached a confident answer for this exact
        // brand+model under a DIFFERENT photo (design §2: brand+model is
        // only knowable after the call — the post-call cache check).
        let cachedGuidance = ApplianceGuidance(
            identity: ApplianceIdentity(brand: "Panasonic", model: "NN-SN686S",
                                        category: "microwave", displayName: "Panasonic microwave"),
            steps: ["cached step"], groundedControls: [], spokenSummary: "cached",
            confidence: 0.92, knowledgeSource: .webSearchGrounded)
        ApplianceCache(storage: storage).store(cachedGuidance, photoHash: "older-photo")

        let transport = SequencedGeminiTransport(results: [
            .success(FakeGeminiTransport.jsonResponse(
                text: payload(confidence: 0.3, brand: "Panasonic", model: "NN-SN686S"))),
        ])
        let session = makeSession(transport: transport)
        session.handleCapturedPhoto(makeImage())
        await waitForPipeline(session)

        guard case let .guidance(presentation, _) = session.state else {
            XCTFail("expected guidance, got \(session.state)")
            return
        }
        XCTAssertEqual(presentation.guidance.confidence, 0.92, accuracy: 0.0001,
                       "the cached confident answer wins over the weak fresh one")
        XCTAssertEqual(transport.requestCount, 1,
                       "a brand+model cache hit must not pay for the grounded retry")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "gemini_vision_cache_hit" && $0.metadata["via"] == "brand_model"
        })
    }

    // MARK: - Capture failure

    func testUnusablePhotoIsAnHonestFailureNotACall() async {
        let transport = SequencedGeminiTransport(results: [])
        let session = makeSession(transport: transport)
        session.handleCapturedPhoto(UIImage())   // zero-size, no bitmap
        await waitForPipeline(session)

        guard case .unavailable = session.state else {
            XCTFail("expected unavailable, got \(session.state)")
            return
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    // MARK: - Retake

    func testRetakeReturnsToCapturing() async {
        struct NetworkDown: Error {}
        let transport = SequencedGeminiTransport(results: [.failure(NetworkDown())])
        let session = makeSession(transport: transport)
        session.handleCapturedPhoto(makeImage())
        await waitForPipeline(session)
        session.retake()
        guard case .capturing = session.state else {
            XCTFail("expected capturing after retake, got \(session.state)")
            return
        }
    }
}

/// A `GeminiTransport` that plays back a fixed sequence of results — the
/// low-confidence → grounded-retry flow needs two different responses.
final class SequencedGeminiTransport: GeminiTransport {
    private var results: [Result<(Data, URLResponse), Error>]
    private(set) var requestCount = 0

    init(results: [Result<(Data, URLResponse), Error>]) {
        self.results = results
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        guard !results.isEmpty else {
            struct NoMoreResponses: Error {}
            throw NoMoreResponses()
        }
        let next = results.removeFirst()
        switch next {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
