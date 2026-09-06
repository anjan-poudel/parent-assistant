import XCTest
import UIKit
@testable import ElderlyAssistant

/// `ApplianceHelperSession` — the capture→answer pipeline: question-aware
/// photo-hash cache, the identity+question cache check (2026-09-06), the
/// single search-grounded retry (addendum §12.2), honest failure states,
/// and cache-only manual re-render (`presentManual`). The Gemini boundary
/// is faked with a sequenced transport.
@MainActor
final class ApplianceHelperSessionTests: XCTestCase {

    private var storage: GeminiInMemoryStorage!
    private var bus: MockObservabilityBus!
    private var tempThumbnails: URL!

    override func setUp() {
        super.setUp()
        storage = GeminiInMemoryStorage()
        bus = MockObservabilityBus()
        tempThumbnails = FileManager.default.temporaryDirectory
            .appendingPathComponent("appliance-session-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: tempThumbnails,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempThumbnails)
        super.tearDown()
    }

    private let locale = Locale(identifier: "ne")

    /// The cache every session (and test seed) shares for this test — same
    /// storage, same thumbnail directory, so stored entries and their
    /// image files are visible across instances.
    private func makeCache() -> ApplianceCache {
        ApplianceCache(storage: storage, thumbnailDirectory: tempThumbnails)
    }

    private func makeSession(transport: SequencedGeminiTransport,
                             question: String? = "चिया कसरी बनाउने") -> ApplianceHelperSession {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let client = GeminiClient(configStore: store, observabilityBus: bus,
                                  transport: transport)
        return ApplianceHelperSession(question: question, locale: locale,
                                      geminiClient: client,
                                      cache: makeCache(),
                                      observabilityBus: bus, speaker: nil)
    }

    private func makeImage(w: CGFloat = 400, h: CGFloat = 300) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    private func cacheHitCount() -> Int {
        bus.emittedEvents.filter { $0.eventType == "appliance_cache_hit" }.count
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

    /// A confident, grounded cached answer for a Panasonic NN-SN686S —
    /// the fixture the identity+question duplicate-detection tests seed.
    private func cachedPanasonicGuidance() -> ApplianceGuidance {
        ApplianceGuidance(
            identity: ApplianceIdentity(brand: "Panasonic", model: "NN-SN686S",
                                        category: "microwave", displayName: "Panasonic microwave"),
            steps: ["cached step"], groundedControls: [], spokenSummary: "cached",
            confidence: 0.92, knowledgeSource: .webSearchGrounded)
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

    // MARK: - Question-aware photo-hash cache (2026-09-06)

    func testSamePhotoSecondTimeHitsCacheWithoutNetwork() async {
        let transport = SequencedGeminiTransport(results: [
            .success(FakeGeminiTransport.jsonResponse(text: payload(confidence: 0.9)))
        ])
        let image = makeImage()
        let session = makeSession(transport: transport)
        session.handleCapturedPhoto(image)
        await waitForPipeline(session)
        XCTAssertEqual(transport.requestCount, 1)

        // A NEW session over the SAME storage, same photo bytes + same
        // question → cache.
        let transport2 = SequencedGeminiTransport(results: [])
        let session2 = makeSession(transport: transport2)
        session2.handleCapturedPhoto(image)
        await waitForPipeline(session2)

        guard case .guidance = session2.state else {
            XCTFail("expected cached guidance, got \(session2.state)")
            return
        }
        XCTAssertEqual(transport2.requestCount, 0, "photo-hash hit must not hit the network")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "appliance_cache_hit" && $0.metadata["via"] == "photo_hash"
        })
    }

    func testSamePhotoWithDifferentQuestionIsNotAFabricatedHit() async {
        // First run answers the default question…
        let transport = SequencedGeminiTransport(results: [
            .success(FakeGeminiTransport.jsonResponse(text: payload(confidence: 0.9)))
        ])
        let image = makeImage()
        let first = makeSession(transport: transport)
        first.handleCapturedPhoto(image)
        await waitForPipeline(first)
        XCTAssertEqual(transport.requestCount, 1)

        // …then the elder asks the SAME photo a DIFFERENT question. The
        // old entry must NOT be served — never answer a question the cache
        // did not answer.
        let transport2 = SequencedGeminiTransport(results: [
            .success(FakeGeminiTransport.jsonResponse(text: payload(confidence: 0.9,
                                                                    brand: "LG", model: "M1")))
        ])
        let second = makeSession(transport: transport2,
                                 question: "घडी कसरी मिलाउने")
        second.handleCapturedPhoto(image)
        await waitForPipeline(second)

        guard case let .guidance(presentation, _) = second.state else {
            XCTFail("expected fresh guidance, got \(second.state)")
            return
        }
        XCTAssertEqual(transport2.requestCount, 1,
                       "a different question must run the pipeline, not reuse the old answer")
        XCTAssertEqual(presentation.guidance.confidence, 0.9, accuracy: 0.0001)
        XCTAssertEqual(cacheHitCount(), 0, "no cache hit may be reported for a mismatch")
        XCTAssertEqual(makeCache().count, 2,
                       "each photo+question pair is its own cache entry")
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

    // MARK: - Identity + question duplicate detection (2026-09-06)

    func testLowConfidencePrefersAnExistingIdentityQuestionCacheEntryOverGroundedRetry() async {
        // A previous session cached a confident answer for this exact
        // brand+model under a DIFFERENT photo AND answered the SAME
        // question (identity is only knowable after the identify call —
        // the post-call check).
        makeCache().store(cachedPanasonicGuidance(), photoHash: "older-photo",
                          question: "चिया कसरी बनाउने")

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
                       "an identity+question cache hit must not pay for the grounded retry")
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.eventType == "appliance_cache_hit" && $0.metadata["via"] == "identity_question"
        })
    }

    func testConfidentFreshAnswerNeverDefersToTheCache() async {
        // Same appliance+question as the cached Panasonic manual, but the
        // fresh identify is CONFIDENT: its boxes belong to the photo in
        // front of the elder, so the fresh answer must be presented.
        makeCache().store(cachedPanasonicGuidance(), photoHash: "older-photo",
                          question: "चिया कसरी बनाउने")

        let transport = SequencedGeminiTransport(results: [
            .success(FakeGeminiTransport.jsonResponse(
                text: payload(confidence: 0.9, brand: "Panasonic", model: "NN-SN686S"))),
        ])
        let session = makeSession(transport: transport)
        session.handleCapturedPhoto(makeImage())
        await waitForPipeline(session)

        guard case let .guidance(presentation, _) = session.state else {
            XCTFail("expected guidance, got \(session.state)")
            return
        }
        XCTAssertEqual(presentation.guidance.confidence, 0.9, accuracy: 0.0001)
        XCTAssertEqual(presentation.guidance.knowledgeSource, .onDeviceModelKnowledge)
        XCTAssertEqual(cacheHitCount(), 0, "no cache hit when the fresh answer is confident")
        XCTAssertEqual(makeCache().count, 2,
                       "the fresh pair-replace is stored alongside the older-photo manual")
    }

    func testDifferentQuestionMissesTheIdentityQuestionCacheAndPaysForTheRetry() async {
        // The manual answered "Q1"; the elder now asks "Q2" of the same
        // appliance. Answers must never cross questions.
        makeCache().store(cachedPanasonicGuidance(), photoHash: "older-photo",
                          question: "सेटिङ कसरी खोल्ने")

        let transport = SequencedGeminiTransport(results: [
            .success(FakeGeminiTransport.jsonResponse(
                text: payload(confidence: 0.3, brand: "Panasonic", model: "NN-SN686S"))),
            .success(FakeGeminiTransport.jsonResponse(text: payload(confidence: 0.85))),
        ])
        let session = makeSession(transport: transport)
        session.handleCapturedPhoto(makeImage())
        await waitForPipeline(session)

        guard case let .guidance(presentation, _) = session.state else {
            XCTFail("expected guidance, got \(session.state)")
            return
        }
        XCTAssertEqual(transport.requestCount, 2,
                       "a different question must run the full flow including the retry")
        XCTAssertEqual(presentation.guidance.confidence, 0.85, accuracy: 0.0001)
        XCTAssertEqual(cacheHitCount(), 0)
    }

    // MARK: - Stored thumbnails (2026-09-06)

    func testPipelineStoresTheDownscaledPhotoWithTheEntry() async {
        let transport = SequencedGeminiTransport(results: [
            .success(FakeGeminiTransport.jsonResponse(text: payload(confidence: 0.9)))
        ])
        let session = makeSession(transport: transport)
        session.handleCapturedPhoto(makeImage())
        await waitForPipeline(session)

        let entry = try? XCTUnwrap(makeCache().allEntries().first)
        XCTAssertNotNil(entry?.imageFileName,
                        "the cache entry must carry its re-renderable photo")
        let jpeg = makeCache().imageJPEG(entryID: entry!.id)
        XCTAssertNotNil(jpeg)
        XCTAssertNotNil(UIImage(data: jpeg!), "the stored photo must decode")
    }

    // MARK: - Manuals library re-render (cache-only, no network)

    func testPresentManualRendersStoredGuidanceAndPhotoWithoutNetwork() async {
        // A manual exists from an earlier session (stored with its photo).
        let jpeg = makeImage(w: 400, h: 300).jpegData(compressionQuality: 0.8)!
        makeCache().store(cachedPanasonicGuidance(), photoHash: "older-photo",
                          question: "चिया कसरी बनाउने", imageJPEG: jpeg)
        let manualID = makeCache().allEntries().first!.id

        // A brand-new session with NO transport results: opening the
        // manual must not touch Gemini at all.
        let session = makeSession(transport: SequencedGeminiTransport(results: []))
        XCTAssertTrue(session.presentManual(entryID: manualID))
        XCTAssertTrue(session.isViewingManual)

        guard case let .guidance(presentation, image) = session.state else {
            XCTFail("expected guidance, got \(session.state)")
            return
        }
        XCTAssertEqual(presentation.guidance.identity.brand, "Panasonic")
        XCTAssertEqual(presentation.guidance.steps, ["cached step"])
        XCTAssertEqual(presentation.guidance.confidence, 0.92, accuracy: 0.0001)
        XCTAssertEqual(image.size, UIImage(data: jpeg)?.size,
                       "the re-rendered photo must be the stored one")
    }

    func testPresentManualWithUnknownIDReturnsFalseAndStaysPut() async {
        let session = makeSession(transport: SequencedGeminiTransport(results: []))
        XCTAssertFalse(session.presentManual(entryID: UUID()))
        guard case .capturing = session.state else {
            XCTFail("expected capturing, got \(session.state)")
            return
        }
    }

    func testPresentManualWithoutAStoredPhotoIsRefused() async {
        // Image-less legacy entries can't re-render the step-card UI —
        // they dedupe requests but are not openable manuals.
        makeCache().store(cachedPanasonicGuidance(), photoHash: "older-photo")
        let entryID = makeCache().allEntries().first!.id
        let session = makeSession(transport: SequencedGeminiTransport(results: []))
        XCTAssertFalse(session.presentManual(entryID: entryID))
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
