import XCTest
@testable import ElderlyAssistant

/// [LOCAL-TOOLS] (2026-09-07) Web-search tool contract (pure seams — no
/// network):
///  - the request URL is exactly the Google Custom Search JSON API v1
///    shape, with the query percent-encoded (Devanagari survives the wire
///    round trip),
///  - parsing accepts the real wire shape, treats malformed/empty payloads
///    as [] (the router then falls back to its generic re-prompt), and
///    drops results blank in every field,
///  - the spoken summary takes the top two results, caps each snippet at
///    two sentences (with correct UTF-16 boundaries), de-duplicates
///    title-prefixed snippets, collapses stray whitespace, and appends the
///    "— host" source line (no host → no line; nothing speakable → nil),
///  - the question gate fires only on genuine questions (whole-token
///    question words anywhere, or a trailing "?") — never on statements,
///  - `SearchConfigStore` mirrors `GeminiConfigStore` (storage-backed,
///    configured only when BOTH credential halves exist, clear removes
///    both),
///  - `SearchQuota` buckets attempts per yyyyMMdd day stamp with cross-day
///    rollover and a hard daily limit.
final class SearchToolTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")
    private let en = Locale(identifier: "en")

    // MARK: - URL shape

    func testRequestURLTargetsGoogleCustomSearchWithExactQueryItems() {
        let url = SearchTool.requestURL(query: "capital of France",
                                        apiKey: "AIza-key-123",
                                        searchEngineId: "cx-0001")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(components?.scheme, "https")
        XCTAssertEqual(components?.host, "www.googleapis.com")
        XCTAssertEqual(components?.path, "/customsearch/v1")
        XCTAssertEqual(components?.queryItems, [
            URLQueryItem(name: "key", value: "AIza-key-123"),
            URLQueryItem(name: "cx", value: "cx-0001"),
            URLQueryItem(name: "q", value: "capital of France")
        ])
    }

    func testRequestURLPercentEncodesDevanagariQuery() {
        let query = "काठमाडौंको मौसम"
        let url = SearchTool.requestURL(query: query, apiKey: "k", searchEngineId: "cx")

        // The wire URL carries the query percent-encoded (क = U+0915 →
        // E0 A4 95 in UTF-8) — no raw Devanagari bytes on the wire…
        XCTAssertTrue(url.absoluteString.contains("%E0%A4%95"),
                      "Devanagari must be percent-encoded: \(url.absoluteString)")
        XCTAssertFalse(url.absoluteString.contains("काठमाडौं"))
        // …and URLComponents still decodes the exact original query.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first { $0.name == "q" }?.value, query)
    }

    // MARK: - Parsing

    func testParseHappyPathDecodesAllResults() {
        let data = Data("""
        {"items": [
            {"title": "Kathmandu weather today", "snippet": "Rain likely by evening.",
             "link": "https://www.kathmandupost.com/meteo"},
            {"title": "मौसम पूर्वानुमान", "snippet": "आज पानी पर्ने सम्भावना।",
             "link": "https://hamrakura.com/weather"}
        ]}
        """.utf8)

        XCTAssertEqual(SearchTool.parseSearchJSON(data: data), [
            SearchTool.SearchResult(title: "Kathmandu weather today",
                                    snippet: "Rain likely by evening.",
                                    url: "https://www.kathmandupost.com/meteo"),
            SearchTool.SearchResult(title: "मौसम पूर्वानुमान",
                                    snippet: "आज पानी पर्ने सम्भावना।",
                                    url: "https://hamrakura.com/weather")
        ])
    }

    func testParseToleratesMissingOptionalFields() {
        // Google omits snippet/link per result; each optional is "" then.
        let data = Data("""
        {"items": [
            {"title": "Only a title"},
            {"snippet": "Only a snippet"},
            {"link": "https://example.com"}
        ]}
        """.utf8)

        XCTAssertEqual(SearchTool.parseSearchJSON(data: data), [
            SearchTool.SearchResult(title: "Only a title", snippet: "", url: ""),
            SearchTool.SearchResult(title: "", snippet: "Only a snippet", url: ""),
            SearchTool.SearchResult(title: "", snippet: "", url: "https://example.com")
        ])
    }

    func testParseReturnsEmptyForMalformedPayloads() {
        XCTAssertEqual(SearchTool.parseSearchJSON(data: Data("not json".utf8)), [])
        // No `items` key at all — the wire shape for an unmatched query.
        XCTAssertEqual(SearchTool.parseSearchJSON(data: Data(#"{"queries": {}}"#.utf8)), [])
        // Empty result set.
        XCTAssertEqual(SearchTool.parseSearchJSON(data: Data(#"{"items": []}"#.utf8)), [])
        // Items is not an array.
        XCTAssertEqual(SearchTool.parseSearchJSON(data: Data(#"{"items": "oops"}"#.utf8)), [])
        // Empty payload.
        XCTAssertEqual(SearchTool.parseSearchJSON(data: Data()), [])
    }

    func testParseDropsResultsBlankInEveryField() {
        let data = Data("""
        {"items": [
            {"title": "", "snippet": "", "link": ""},
            {"title": "   ", "snippet": "\\n", "link": ""},
            {"title": "Keep me", "snippet": "", "link": ""}
        ]}
        """.utf8)

        XCTAssertEqual(SearchTool.parseSearchJSON(data: data), [
            SearchTool.SearchResult(title: "Keep me", snippet: "", url: "")
        ])
    }

    // MARK: - Spoken summary

    private func result(_ title: String, _ snippet: String, _ url: String) -> SearchTool.SearchResult {
        SearchTool.SearchResult(title: title, snippet: snippet, url: url)
    }

    func testSummaryReplyJoinsTopTwoResultsWithSourceLines() {
        let results = [
            result("Kathmandu weather today",
                   "Rain likely by evening. Showers taper overnight. High near 24.",
                   "https://www.kathmandupost.com/meteo"),
            result("Weather in Kathmandu",
                   "Sunny spells and a fresh breeze for most of the week.",
                   "https://www.bbc.com/weather"),
            // A third speakable result must NOT be spoken — top two only.
            result("Weather tomorrow", "Dry and warm.", "https://www.example.com")
        ]

        XCTAssertEqual(SearchTool.summaryReply(for: results, locale: en),
                       "Kathmandu weather today. Rain likely by evening. Showers taper overnight."
                       + " — kathmandupost.com\n"
                       + "Weather in Kathmandu. Sunny spells and a fresh breeze for most of the week."
                       + " — bbc.com")
    }

    func testSummaryReplyCapsSnippetAtTwoSentences() {
        let results = [result("", "The rain stopped. The sun came out. And birds sang.", "")]
        // The cut lands AFTER the second sentence's stop — the third
        // sentence never reaches a human ear.
        XCTAssertEqual(SearchTool.summaryReply(for: results, locale: en),
                       "The rain stopped. The sun came out.")
    }

    func testSummaryReplyCutsNepaliSnippetAtTheDandaBoundary() {
        // देवनागरी sentence stops are the danda (।) — same two-sentence cap.
        let results = [result("मौसम पूर्वानुमान",
                              "आज पानी पर्छ। भोलि घाम लाग्छ। पर्सि फेरि पानी पर्नेछ।",
                              "https://hamrakura.com")]
        // Title and snippet join with the Nepali danda, not the ASCII stop.
        XCTAssertEqual(SearchTool.summaryReply(for: results, locale: ne),
                       "मौसम पूर्वानुमान। आज पानी पर्छ। भोलि घाम लाग्छ। — hamrakura.com")
    }

    func testSummaryReplyHandlesAstralCharactersBeforeTheCut() {
        // The sentence boundary is found in UTF-16 offsets; the slice must
        // still cut on a character boundary when surrogate-pair characters
        // precede the cut point (regression guard for the Range
        // conversion). 🌧 = U+1F327 — one character, TWO UTF-16 units.
        let results = [result("Week ahead",
                              "Sunny today. Then 🌧 rain. And more rain later.",
                              "")]
        XCTAssertEqual(SearchTool.summaryReply(for: results, locale: en),
                       "Week ahead. Sunny today. Then 🌧 rain.")
    }

    func testSummaryReplyDeduplicatesTitlePrefixedSnippet() {
        // Google snippets re-open with the title — "Title. Title …" would
        // double-speak it; the snippet alone is spoken.
        let results = [result("Kathmandu weather today",
                              "Kathmandu weather today, rain by evening.",
                              "https://www.kathmandupost.com/meteo")]
        XCTAssertEqual(SearchTool.summaryReply(for: results, locale: en),
                       "Kathmandu weather today, rain by evening. — kathmandupost.com")
    }

    func testSummaryReplyCollapsesStrayWhitespaceAndNewlines() {
        // CSE snippets are HTML-ish text full of newline runs that would
        // garble TTS — every whitespace run becomes one space.
        let results = [result("Kathmandu\nweather\ttoday",
                              "Rain by evening.\n\n  Then clearing  overnight.",
                              "https://example.com")]
        XCTAssertEqual(SearchTool.summaryReply(for: results, locale: en),
                       "Kathmandu weather today. Rain by evening. Then clearing overnight."
                       + " — example.com")
    }

    func testSummaryReplyOmitsSourceLineWhenUrlHasNoHost() {
        // A result whose URL has no parseable host is still spoken — but
        // without the "— host" attribution, because a source line needs a
        // real source.
        let noHost = [result("A plain headline", "And one sentence of detail.", "not a url")]
        XCTAssertEqual(SearchTool.summaryReply(for: noHost, locale: en),
                       "A plain headline. And one sentence of detail.")
        let emptyURL = [result("A plain headline", "", "")]
        XCTAssertEqual(SearchTool.summaryReply(for: emptyURL, locale: en), "A plain headline")
    }

    func testSummaryReplyReturnsNilWhenNothingSpeakable() {
        XCTAssertNil(SearchTool.summaryReply(for: [], locale: en))
        XCTAssertNil(SearchTool.summaryReply(for: [result("", "", "https://example.com")],
                                             locale: en))
        XCTAssertNil(SearchTool.summaryReply(for: [result("", "", "")], locale: ne))
    }

    // MARK: - Question gate

    func testIsQuestionShapedRecognizesNepaliQuestionWordsAnywhere() {
        XCTAssertTrue(SearchTool.isQuestionShaped("कहाँ छ बजार?"))
        // Question word mid-utterance — not just the first word.
        XCTAssertTrue(SearchTool.isQuestionShaped("बजार कहाँ छ"))
        XCTAssertTrue(SearchTool.isQuestionShaped("काठमाडौंको मौसम कस्तो छ"))
        XCTAssertTrue(SearchTool.isQuestionShaped("हिजो राति कति बजे निदाउनुभयो"))
    }

    func testIsQuestionShapedRecognizesEnglishQuestionWordsAnywhere() {
        XCTAssertTrue(SearchTool.isQuestionShaped("what is the capital of France"))
        XCTAssertTrue(SearchTool.isQuestionShaped("do you know where the nearest pharmacy is"))
        XCTAssertTrue(SearchTool.isQuestionShaped("who is the prime minister"))
        XCTAssertTrue(SearchTool.isQuestionShaped("tell me how to set an alarm"))
    }

    func testIsQuestionShapedTrailingQuestionMarkAloneSuffices() {
        // Typed queries carry "?" even without a question word.
        XCTAssertTrue(SearchTool.isQuestionShaped("nice weather today?"))
        XCTAssertTrue(SearchTool.isQuestionShaped("आज मौसम राम्रो?"))
    }

    func testIsQuestionShapedDeclarativeUtterancesAreNotQuestions() {
        XCTAssertFalse(SearchTool.isQuestionShaped("म बजार जान्छु"))
        XCTAssertFalse(SearchTool.isQuestionShaped("मैले औषधि खाएँ"))
        XCTAssertFalse(SearchTool.isQuestionShaped("tell me a story"))
        XCTAssertFalse(SearchTool.isQuestionShaped("ठीक छ"))
        // "weather" is a topic word, not a question word.
        XCTAssertFalse(SearchTool.isQuestionShaped("आज मौसम राम्रो छ"))
    }

    func testIsQuestionShapedEmptyAndWhitespaceAreNotQuestions() {
        XCTAssertFalse(SearchTool.isQuestionShaped(""))
        XCTAssertFalse(SearchTool.isQuestionShaped("   \n  "))
        XCTAssertFalse(SearchTool.isQuestionShaped("?"))
    }

    // MARK: - SearchConfigStore (mirror of GeminiConfigStore)

    func testConfigStoreLoadsPersistedCredentials() {
        let storage = GeminiInMemoryStorage()
        let first = SearchConfigStore(storage: storage)
        first.saveAPIKey("AIza-key")
        first.saveSearchEngineID("cx-99")
        XCTAssertTrue(first.isConfigured)

        // A fresh store over the same storage reads both halves back.
        let reloaded = SearchConfigStore(storage: storage)
        XCTAssertEqual(reloaded.apiKey, "AIza-key")
        XCTAssertEqual(reloaded.searchEngineID, "cx-99")
        XCTAssertTrue(reloaded.isConfigured)
    }

    func testConfigStoreIsConfiguredOnlyWhenBothHalvesExist() {
        let store = SearchConfigStore(storage: GeminiInMemoryStorage())
        XCTAssertFalse(store.isConfigured)

        store.saveAPIKey("AIza-key")
        XCTAssertFalse(store.isConfigured,
                       "a key without an engine cannot be used and must read as unconfigured")
        store.saveSearchEngineID("cx-99")
        XCTAssertTrue(store.isConfigured)
    }

    func testConfigStoreSavingEmptyClearsOnlyThatHalf() {
        let store = SearchConfigStore(storage: GeminiInMemoryStorage())
        store.saveAPIKey("AIza-key")
        store.saveSearchEngineID("cx-99")

        store.saveAPIKey("   ")   // whitespace trims to empty → clear the key only
        XCTAssertNil(store.apiKey)
        XCTAssertEqual(store.searchEngineID, "cx-99")
        XCTAssertFalse(store.isConfigured)

        store.saveAPIKey("AIza-key-2")
        XCTAssertTrue(store.isConfigured)
    }

    func testConfigStoreClearRemovesBothHalves() {
        let storage = GeminiInMemoryStorage()
        let store = SearchConfigStore(storage: storage)
        store.saveAPIKey("AIza-key")
        store.saveSearchEngineID("cx-99")

        store.clear()

        XCTAssertNil(store.apiKey)
        XCTAssertNil(store.searchEngineID)
        XCTAssertFalse(store.isConfigured)
        // And nothing survives on the storage itself.
        let reloaded = SearchConfigStore(storage: storage)
        XCTAssertFalse(reloaded.isConfigured)
    }

    // MARK: - SearchQuota

    private var quotaDefaults: UserDefaults!
    private var quotaSuiteName: String!

    /// UTC Gregorian — the bucket stamps are pure date math; pinning the
    /// calendar keeps assertions independent of the test machine's zone.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    override func setUp() {
        super.setUp()
        quotaSuiteName = "SearchQuotaTests.\(UUID().uuidString)"
        quotaDefaults = UserDefaults(suiteName: quotaSuiteName)
    }

    override func tearDown() {
        quotaDefaults.removePersistentDomain(forName: quotaSuiteName)
        quotaDefaults = nil
        quotaSuiteName = nil
        super.tearDown()
    }

    func testDayStampFormatsUtcGregorianDate() {
        let utc = utcCalendar
        let epoch = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(SearchQuota.dayStamp(for: epoch, calendar: utc), "19700101")
        XCTAssertEqual(SearchQuota.dayStamp(for: epoch.addingTimeInterval(86_400), calendar: utc),
                       "19700102")
        XCTAssertEqual(SearchQuota.dailyLimit, 50)
    }

    func testRemainingIsFullLimitOnFreshDefaults() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(SearchQuota.remaining(today: today,
                                             count: SearchQuota.readCount(defaults: quotaDefaults),
                                             limit: SearchQuota.dailyLimit,
                                             defaults: quotaDefaults,
                                             calendar: utcCalendar),
                       SearchQuota.dailyLimit)
    }

    func testRemainingCountsOnlyTodaysConsumption() {
        let utc = utcCalendar
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        quotaDefaults.set(SearchQuota.dayStamp(for: today, calendar: utc), forKey: SearchQuota.dayKey)
        quotaDefaults.set(3, forKey: SearchQuota.countKey)

        XCTAssertEqual(SearchQuota.remaining(today: today, count: 3, limit: 50,
                                             defaults: quotaDefaults, calendar: utc),
                       47)
    }

    func testRemainingNeverGoesBelowZero() {
        let utc = utcCalendar
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        quotaDefaults.set(SearchQuota.dayStamp(for: today, calendar: utc), forKey: SearchQuota.dayKey)
        quotaDefaults.set(60, forKey: SearchQuota.countKey)

        XCTAssertEqual(SearchQuota.remaining(today: today, count: 60, limit: 50,
                                             defaults: quotaDefaults, calendar: utc),
                       0, "the cap is a hard ceiling — remaining clamps at zero")
    }

    func testStalePreviousDayCountDoesNotConsumeTodaysBudget() {
        let utc = utcCalendar
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = today.addingTimeInterval(-86_400)
        // 49 attempts yesterday — a fresh day must not inherit them.
        quotaDefaults.set(SearchQuota.dayStamp(for: yesterday, calendar: utc),
                          forKey: SearchQuota.dayKey)
        quotaDefaults.set(49, forKey: SearchQuota.countKey)

        XCTAssertEqual(SearchQuota.remaining(today: today, count: 49, limit: 50,
                                             defaults: quotaDefaults, calendar: utc),
                       50, "a previous-day count never eats today's budget")
    }

    func testIncrementAccumulatesWithinTheDay() {
        let utc = utcCalendar
        let today = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(SearchQuota.increment(defaults: quotaDefaults, now: today, calendar: utc), 1)
        XCTAssertEqual(SearchQuota.increment(defaults: quotaDefaults, now: today, calendar: utc), 2)
        XCTAssertEqual(SearchQuota.readCount(defaults: quotaDefaults), 2)
        XCTAssertEqual(SearchQuota.remaining(today: today, count: 2, limit: 50,
                                             defaults: quotaDefaults, calendar: utc),
                       48)
        XCTAssertEqual(quotaDefaults.string(forKey: SearchQuota.dayKey),
                       SearchQuota.dayStamp(for: today, calendar: utc))
    }

    func testIncrementStartsANewBucketOnTheNextDay() {
        let utc = utcCalendar
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = today.addingTimeInterval(-86_400)
        quotaDefaults.set(SearchQuota.dayStamp(for: yesterday, calendar: utc),
                          forKey: SearchQuota.dayKey)
        quotaDefaults.set(49, forKey: SearchQuota.countKey)

        // Rollover-safe: the first attempt of the new day is 1, never
        // yesterday's total + 1.
        XCTAssertEqual(SearchQuota.increment(defaults: quotaDefaults, now: today, calendar: utc), 1)
        XCTAssertEqual(quotaDefaults.string(forKey: SearchQuota.dayKey),
                       SearchQuota.dayStamp(for: today, calendar: utc))
    }

    func testReadCountIsRawAndResetClearsEverything() {
        let utc = utcCalendar
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = today.addingTimeInterval(-86_400)
        quotaDefaults.set(SearchQuota.dayStamp(for: yesterday, calendar: utc),
                          forKey: SearchQuota.dayKey)
        quotaDefaults.set(49, forKey: SearchQuota.countKey)

        // readCount is the RAW stored count — day normalization belongs to
        // `remaining`.
        XCTAssertEqual(SearchQuota.readCount(defaults: quotaDefaults), 49)

        SearchQuota.reset(defaults: quotaDefaults)
        XCTAssertEqual(SearchQuota.readCount(defaults: quotaDefaults), 0)
        XCTAssertNil(quotaDefaults.string(forKey: SearchQuota.dayKey))
        XCTAssertEqual(SearchQuota.remaining(today: today, count: 0, limit: 50,
                                             defaults: quotaDefaults, calendar: utc),
                       50)
    }
}
