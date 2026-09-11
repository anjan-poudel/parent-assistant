import XCTest
@testable import ElderlyAssistant

/// Feed translation tests (feed translation task, 2026-09-08) —
/// translate-ON-ASK pipeline: prompt bounds, reply parsing, honest
/// unavailable/invalid states, per-item cache trimming, the
/// GeminiClient adapter, per-card display resolution (including the
/// AI-translated marker pin), and read-aloud following the displayed
/// text.
final class FeedTranslatorTests: XCTestCase {

    private func item(title: String, summary: String = "") -> FeedItem {
        FeedItem(id: "item-1", title: title, summary: summary, kind: .text,
                 publishedAt: nil, linkURL: "https://example.com",
                 imageURL: nil, mediaURL: nil, sourceName: "Test")
    }

    // MARK: - Prompt (bounded, target language)

    func testPromptTargetsNepaliForNepaliLanguage() {
        let prompt = FeedTranslator.prompt(title: "Headline", summary: "Body",
                                           language: .nepali)
        XCTAssertTrue(prompt.contains("into Nepali"))
    }

    func testPromptTargetsEnglishForEnglishLanguage() {
        let prompt = FeedTranslator.prompt(title: "Headline", summary: "Body",
                                           language: .english)
        XCTAssertTrue(prompt.contains("into English"))
    }

    func testPromptEmbedsTheContent() {
        let prompt = FeedTranslator.prompt(title: "A headline", summary: "A body",
                                           language: .nepali)
        XCTAssertTrue(prompt.contains("Headline: A headline"))
        XCTAssertTrue(prompt.contains("Summary: A body"))
    }

    func testTranslateBoundsTitleAndSummaryCharacterSafe() {
        // Fixture sizes are in CHARACTERS (verified by the pin below):
        // "काठमाडौँ" is 4 grapheme clusters/word → ×300 = 1200 chars;
        // "स्वास्थ्य" is 2 clusters/word → ×400 = 800 chars. Both must
        // STRICTLY exceed bound+1, or prefix(bound+1) collapses to the
        // whole string and the sentinel proves nothing (the exact
        // fixture bug this test once had — "स्वास्थ्य"×150 is only 300
        // chars, under the 701-char summary sentinel).
        let longNepaliTitle = String(repeating: "काठमाडौँ", count: 300)
        let longNepaliSummary = String(repeating: "स्वास्थ्य", count: 400)
        XCTAssertGreaterThan(longNepaliTitle.count, FeedTranslator.maxTitleChars + 1)
        XCTAssertGreaterThan(longNepaliSummary.count, FeedTranslator.maxSummaryChars + 1)
        let prompt = FeedTranslator.prompt(title: longNepaliTitle,
                                           summary: longNepaliSummary,
                                           language: .nepali)
        // The prompt carries the Character-safe prefixes only — a
        // sentinel one cluster beyond the bound must never appear.
        let boundedTitle = String(longNepaliTitle.prefix(FeedTranslator.maxTitleChars))
        let beyondTitle = String(longNepaliTitle.prefix(FeedTranslator.maxTitleChars + 1))
        XCTAssertTrue(prompt.contains(boundedTitle))
        XCTAssertFalse(prompt.contains(beyondTitle))
        XCTAssertFalse(prompt.contains(String(longNepaliSummary.prefix(
            FeedTranslator.maxSummaryChars + 1))))
    }

    // MARK: - Reply parsing

    func testParseTwoLinesGivesTitleAndSummary() {
        let parsed = FeedTranslator.parse(response: "नेपाली शीर्षक\nनेपाली सारांश")
        XCTAssertEqual(parsed, FeedTranslation(title: "नेपाली शीर्षक",
                                               summary: "नेपाली सारांश"))
    }

    func testParseSingleLineGivesTitleOnly() {
        XCTAssertEqual(FeedTranslator.parse(response: "केवल शीर्षक"),
                       FeedTranslation(title: "केवल शीर्षक", summary: ""))
    }

    func testParseSkipsBlankLines() {
        let parsed = FeedTranslator.parse(response: "\n\nTitle line\n\nSummary line\n")
        XCTAssertEqual(parsed, FeedTranslation(title: "Title line",
                                               summary: "Summary line"))
    }

    func testParseDiscardsCommentaryBeyondSecondLine() {
        // The prompt demands two lines; anything after is commentary and
        // must never pollute the translation.
        let parsed = FeedTranslator.parse(
            response: "शीर्षक\nसारांश\nHere is a helpful explanation")
        XCTAssertEqual(parsed, FeedTranslation(title: "शीर्षक", summary: "सारांश"))
    }

    func testParseEmptyResponseIsNil() {
        XCTAssertNil(FeedTranslator.parse(response: ""))
        XCTAssertNil(FeedTranslator.parse(response: "   \n  "))
    }

    // MARK: - Translate (stub client)

    func testTranslateSuccessReturnsParsedTranslation() async throws {
        let bus = CapturingBus()
        let translator = FeedTranslator(client: StubClient(result: .success("नमस्ते\nसमाचार")),
                                        observability: bus)
        let translation = try await translator.translate(title: "Hello",
                                                         summary: "News",
                                                         language: .nepali)
        XCTAssertEqual(translation, FeedTranslation(title: "नमस्ते", summary: "समाचार"))
        XCTAssertEqual(
            bus.events.last(where: { $0.component == "feed" })?.outcome, "success")
    }

    func testTranslateInvalidResponseThrowsAndNeverFabricates() async {
        let bus = CapturingBus()
        let translator = FeedTranslator(client: StubClient(result: .success("")),
                                        observability: bus)
        do {
            _ = try await translator.translate(title: "Hello", summary: "",
                                               language: .nepali)
            XCTFail("empty reply must throw, never fabricate a translation")
        } catch let error as FeedTranslationError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        XCTAssertEqual(
            bus.events.last(where: { $0.component == "feed" })?.errorCode,
            "invalid_response")
    }

    func testTranslateUnavailablePropagatesHonestError() async {
        let bus = CapturingBus()
        let translator = FeedTranslator(client: StubClient(result: .failure(.unavailable)),
                                        observability: bus)
        do {
            _ = try await translator.translate(title: "Hello", summary: "",
                                               language: .nepali)
            XCTFail("unavailable must throw")
        } catch let error as FeedTranslationError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        XCTAssertEqual(
            bus.events.last(where: { $0.component == "feed" })?.errorCode,
            "unavailable")
    }

    func testObservabilityIsPIIFree() async throws {
        let bus = CapturingBus()
        let translator = FeedTranslator(client: StubClient(result: .success("नमस्ते\nसमाचार")),
                                        observability: bus)
        _ = try await translator.translate(title: "Secret headline",
                                           summary: "Secret summary",
                                           language: .nepali)
        for event in bus.events where event.component == "feed" {
            XCTAssertTrue(event.metadata.isEmpty,
                          "translation events carry no metadata at all — titles/summaries never reach the log")
        }
    }

    // MARK: - Cache trimming

    func testTrimmedCapsTheCacheWithoutAlteringSurvivingEntries() {
        var cache: [String: FeedTranslation] = [:]
        cache["a"] = FeedTranslation(title: "A", summary: "")
        cache["b"] = FeedTranslation(title: "B", summary: "")
        cache["c"] = FeedTranslation(title: "C", summary: "")

        let trimmed = FeedTranslator.trimmed(cache, limit: 2)
        XCTAssertEqual(trimmed.count, 2)
        // Eviction is unspecified WHICH entry (a cost bound, not a
        // recency contract) — but every survivor is an unchanged
        // original and exactly one entry was dropped.
        for (key, value) in trimmed {
            XCTAssertEqual(cache[key], value)
        }
        XCTAssertEqual(Set(cache.keys).subtracting(Set(trimmed.keys)).count, 1)
    }

    func testTrimmedIsNoOpUnderLimit() {
        var cache: [String: FeedTranslation] = [:]
        cache["a"] = FeedTranslation(title: "A", summary: "")
        XCTAssertEqual(FeedTranslator.trimmed(cache, limit: 2), cache)
    }

    // MARK: - GeminiClient adapter (the app's cloud path)

    func testGeminiAdapterCompletesTextThroughExistingPath() async throws {
        let store = GeminiConfigStore(storage: InMemoryStorage())
        store.save("test-key")
        let client = GeminiClient(
            configStore: store,
            observabilityBus: CapturingBus(),
            transport: StubGeminiTransport(json:
                #"{"candidates":[{"content":{"parts":[{"text":"नमस्ते\nसमाचार"}]}}]}"#),
            streamingTransport: StubGeminiTransport(json: ""),
            costGovernor: nil)

        let text = try await client.completeText(prompt: "translate this")
        XCTAssertEqual(text, "नमस्ते\nसमाचार")
    }

    func testGeminiAdapterMapsNoKeyToUnavailable() async {
        let client = GeminiClient(
            configStore: GeminiConfigStore(storage: InMemoryStorage()),
            observabilityBus: CapturingBus(),
            transport: StubGeminiTransport(json: ""),
            streamingTransport: StubGeminiTransport(json: ""),
            costGovernor: nil)

        do {
            _ = try await client.completeText(prompt: "translate this")
            XCTFail("no API key must fail fast")
        } catch let error as FeedTranslationError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Per-card display resolution (marker + read-aloud pins)

    func testNoTranslationShowsOriginalWithoutMarker() {
        let display = FeedCardDisplayResolver.resolve(
            item: item(title: "English headline", summary: "English body"),
            translation: nil, showingOriginal: false)
        XCTAssertEqual(display.title, "English headline")
        XCTAssertEqual(display.summary, "English body")
        XCTAssertFalse(display.isShowingTranslation, "originals never carry the AI marker")
        XCTAssertFalse(display.hasTranslation)
    }

    func testCachedTranslationShowsTranslatedWithMarker() {
        let display = FeedCardDisplayResolver.resolve(
            item: item(title: "English headline"),
            translation: FeedTranslation(title: "नेपाली शीर्षक", summary: "नेपाली सारांश"),
            showingOriginal: false)
        XCTAssertEqual(display.title, "नेपाली शीर्षक")
        XCTAssertTrue(display.isShowingTranslation, "translated cards carry the AI marker")
        XCTAssertTrue(display.hasTranslation)
    }

    func testShowingOriginalToggleRevertsAndDropsMarker() {
        // The second tap reverts to the original (cached toggle) — the
        // marker follows: it exists ONLY while the translation shows.
        let display = FeedCardDisplayResolver.resolve(
            item: item(title: "English headline"),
            translation: FeedTranslation(title: "नेपाली शीर्षक", summary: ""),
            showingOriginal: true)
        XCTAssertEqual(display.title, "English headline")
        XCTAssertFalse(display.isShowingTranslation)
        XCTAssertTrue(display.hasTranslation, "the cached translation still powers the toggle")
    }

    func testReadAloudSpeaksExactlyTheDisplayedText() {
        // The read-aloud path composes from the SAME resolution the card
        // renders — translated when the translation shows, original
        // otherwise.
        let item = item(title: "English headline", summary: "English body")
        let translated = FeedCardDisplayResolver.resolve(
            item: item,
            translation: FeedTranslation(title: "नेपाली शीर्षक", summary: "नेपाली सारांश"),
            showingOriginal: false)
        let spoken = FeedSpeechSanitizer.speechText(title: translated.title,
                                                    summary: translated.summary)
        XCTAssertEqual(spoken, "नेपाली शीर्षक. नेपाली सारांश")

        let original = FeedCardDisplayResolver.resolve(
            item: item, translation: nil, showingOriginal: false)
        XCTAssertEqual(FeedSpeechSanitizer.speechText(title: original.title,
                                                      summary: original.summary),
                       "English headline. English body")
    }

    func testResolverShowsOriginalUntilATranslationLands() {
        // The PROGRESSIVE contract's display half (feed translation
        // task, 2026-09-09): cards render the ORIGINAL text the moment
        // items publish — a translation only ever replaces it after the
        // batch (or the per-item ask) stores one. nil translation ALWAYS
        // yields the original, so originals can never be blocked,
        // held back, or fabricated.
        let display = FeedCardDisplayResolver.resolve(
            item: item(title: "Untranslated until it lands"),
            translation: nil, showingOriginal: false)
        XCTAssertEqual(display.title, "Untranslated until it lands")
        XCTAssertFalse(display.hasTranslation)
    }

    // MARK: - Progressive batch (visible page, one call)

    func testBatchPromptNumbersEveryItemAndBoundsContent() {
        let items = [item(title: "One", summary: "First"),
                     item(title: "Two", summary: "Second")]
        let prompt = FeedTranslator.batchPrompt(items: items, language: .nepali)
        XCTAssertTrue(prompt.contains("2 news headlines"))
        XCTAssertTrue(prompt.contains("into Nepali"))
        XCTAssertTrue(prompt.contains("1. Headline: One"))
        XCTAssertTrue(prompt.contains("2. Headline: Two"))
        XCTAssertTrue(prompt.contains(#""translations""#))
    }

    func testParseBatchAlignsByIndexAndToleratesMissingEntries() {
        let response = #"{"translations":[{"title":"नेपाली एक","summary":"सार"},{"title":"नेपाली दुई","summary":""}]}"#
        let aligned = FeedTranslator.parseBatch(response: response, count: 3)
        XCTAssertEqual(aligned?.count, 3)
        XCTAssertEqual(aligned?[0], FeedBatchEntry(title: "नेपाली एक", summary: "सार"))
        XCTAssertEqual(aligned?[1], FeedBatchEntry(title: "नेपाली दुई", summary: ""))
        XCTAssertNil(aligned?[2], "missing third entry → that item fails alone, never fabricated")
    }

    func testParseBatchRejectsNonJSONAndEmptyEnvelopes() {
        XCTAssertNil(FeedTranslator.parseBatch(response: "not json", count: 1))
        XCTAssertNil(FeedTranslator.parseBatch(response: #"{"translations":[]}"#, count: 2),
                     "an empty reply to a non-empty batch is non-compliance, not success")
    }

    func testTranslateBatchSuccessMakesExactlyOneCall() async {
        let client = StubClient(text: .success(""), json: .success(
            #"{"translations":[{"title":"नेपाली एक","summary":"सारांश"},{"title":"नेपाली दुई","summary":""}]}"#))
        let translator = FeedTranslator(client: client, observability: CapturingBus())
        let results = await translator.translateBatch(
            [item(title: "One"), item(title: "Two")], language: .nepali)
        XCTAssertEqual(results.map { $0.outcome }, [
            .success(FeedTranslation(title: "नेपाली एक", summary: "सारांश")),
            .success(FeedTranslation(title: "नेपाली दुई", summary: ""))
        ])
        XCTAssertEqual(client.jsonCallCount, 1)
        XCTAssertEqual(client.textCallCount, 0,
                       "the batch path is ONE call — the cheaper shape the spec prefers")
    }

    func testTranslateBatchFallsBackToPerItemWhenBatchShapeFails() async {
        let client = StubClient(text: .success("नमस्ते\nसमाचार"),
                                json: .success("not json"))
        let translator = FeedTranslator(client: client, observability: CapturingBus())
        let results = await translator.translateBatch(
            [item(title: "A"), item(title: "B")], language: .nepali)
        XCTAssertEqual(client.jsonCallCount, 1)
        XCTAssertEqual(client.textCallCount, 2,
                       "per-item fallback covers every item of the failed batch")
        XCTAssertEqual(results.map { $0.outcome }, [
            .success(FeedTranslation(title: "नमस्ते", summary: "समाचार")),
            .success(FeedTranslation(title: "नमस्ते", summary: "समाचार"))
        ])
    }

    func testTranslateBatchUnavailableMarksAllFailedWithoutPerItemStorm() async {
        let client = StubClient(text: .failure(.unavailable),
                                json: .failure(.unavailable))
        let translator = FeedTranslator(client: client, observability: CapturingBus())
        let results = await translator.translateBatch(
            [item(title: "A"), item(title: "B")], language: .nepali)
        XCTAssertEqual(client.jsonCallCount, 1)
        XCTAssertEqual(client.textCallCount, 0,
                       "no cloud must never trigger a per-item retry storm")
        XCTAssertEqual(results.map { $0.outcome }, [.failure, .failure])
    }

    func testProgressiveFlowOriginalFirstThenTranslatedSwap() async {
        // The progressive contract end to end (pure halves): original-
        // first render, then the swap once the batch lands, and the
        // language sort still reads the ORIGINAL script afterwards.
        let items = [item(title: "English headline", summary: "English body")]
        let before = FeedCardDisplayResolver.resolve(item: items[0], translation: nil,
                                                     showingOriginal: false)
        XCTAssertEqual(before.title, "English headline")
        XCTAssertFalse(before.hasTranslation)

        let client = StubClient(text: .success(""), json: .success(
            #"{"translations":[{"title":"नेपाली शीर्षक","summary":"नेपाली सारांश"}]}"#))
        let translator = FeedTranslator(client: client, observability: CapturingBus())
        let results = await translator.translateBatch(items, language: .nepali)
        guard case .success(let translation)? = results.first?.outcome else {
            return XCTFail("the batch must translate the item")
        }
        let after = FeedCardDisplayResolver.resolve(item: items[0],
                                                    translation: translation,
                                                    showingOriginal: false)
        XCTAssertEqual(after.title, "नेपाली शीर्षक")
        XCTAssertTrue(after.isShowingTranslation)
        // Translated items never re-sort: the detector/sorter see the
        // ORIGINAL FeedItem text only (translations live outside it).
        XCTAssertEqual(FeedLanguageDetector.language(of: items[0]), .latin)
    }
}

// MARK: - Test doubles

/// Stub provider client for `FeedTranslator` — scripted per shape
/// (text vs JSON) with call counters so the batch/fallback shapes are
/// pinned exactly.
private final class StubClient: FeedTranslationClient {
    enum Outcome {
        case success(String)
        case failure(FeedTranslationError)
    }

    private let textResult: Outcome
    private let jsonResult: Outcome
    private(set) var textCallCount = 0
    private(set) var jsonCallCount = 0

    /// One scripted result for both shapes.
    init(result: Outcome) {
        self.textResult = result
        self.jsonResult = result
    }

    /// Independent scripts for the two shapes.
    init(text: Outcome, json: Outcome) {
        self.textResult = text
        self.jsonResult = json
    }

    func completeText(prompt: String) async throws -> String {
        textCallCount += 1
        switch textResult {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }

    func completeJSON(prompt: String) async throws -> String {
        jsonCallCount += 1
        switch jsonResult {
        case .success(let json): return json
        case .failure(let error): throw error
        }
    }
}

/// Stub `GeminiTransport` returning a canned JSON body (or nothing).
private final class StubGeminiTransport: GeminiTransport, GeminiStreamingTransport {
    private let json: String

    init(json: String) {
        self.json = json
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        throw URLError(.unsupportedURL)
    }
}

private final class CapturingBus: ObservabilityBus {
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
