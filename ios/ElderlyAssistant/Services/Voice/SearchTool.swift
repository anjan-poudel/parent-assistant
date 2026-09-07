import Foundation

/// [LOCAL-TOOLS] (2026-09-07) Web-search tool for the ON-DEVICE voice
/// stack, consulted by `CommandRouter` when the deterministic layer AND the
/// interpreter both abstained on a question-shaped utterance — and only
/// when a family member has configured a Google Custom Search JSON API key
/// (`SearchConfigStore.isConfigured`). The Gemini stack never reaches it
/// (its cloud interpreter answers questions natively); the tool is a
/// no-op unless configured.
///
/// Honesty contract:
///  - Results are REAL Google CSE results, spoken as-is — the title and a
///    two-sentence snippet cap keep the reply short; the host line
///    ("— example.com") tells the user WHERE the answer came from so an
///    inaccurate snippet is attributable, never impersonated.
///  - Empty/malformed responses and transport failures fall back to the
///    router's existing generic re-prompt — never a fabricated answer.
///  - A daily attempt cap (`SearchQuota`, 50) protects the household from
///    quota-burning loops; hitting it announces `search.capReached` and
///    falls back to the generic re-prompt.
///
/// Privacy: the query text leaves the device to Google (stated in the
/// `searchSettings.privacy` settings line) — that is why this tool is
/// opt-in via Settings and why `isQuestionShaped` gates it to genuine
/// questions, never ambient utterance echoes.
///
/// Design: a caseless enum of pure statics (house tool pattern, like
/// `CalculatorTool`); URL shape and JSON parsing are the testable seams —
/// no real network in tests.
enum SearchTool {

    /// One Google CSE hit. `url` is the raw `link` string (display host
    /// is derived at speech time).
    struct SearchResult: Equatable {
        let title: String
        let snippet: String
        let url: String
    }

    // MARK: - URL

    /// Google Custom Search JSON API v1 endpoint for one query. Pure URL
    /// construction — the unit tests assert the exact query items.
    /// `apiKey`/`searchEngineId` come from `SearchConfigStore` at call
    /// time (Keychain-backed), never from code or logs.
    static func requestURL(query: String, apiKey: String, searchEngineId: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.path = "/customsearch/v1"
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "cx", value: searchEngineId),
            URLQueryItem(name: "q", value: query)
        ]
        return components.url!
    }

    // MARK: - Parsing

    /// Wire format of the CSE response. Everything optional: Google omits
    /// fields per result and returns no `items` key at all when a query
    /// matches nothing.
    private struct SearchPayload: Decodable {
        struct Item: Decodable {
            let title: String?
            let snippet: String?
            let link: String?
        }
        let items: [Item]?
    }

    /// Decodes a CSE response into results. Returns [] on ANY malformation
    /// (non-JSON, wrong shape) and for empty result sets alike — an empty
    /// answer and a broken answer are the same outcome for the router
    /// (generic re-prompt). Results whose title/snippet/link are ALL
    /// missing or blank are dropped.
    static func parseSearchJSON(data: Data) -> [SearchResult] {
        guard let payload = try? JSONDecoder().decode(SearchPayload.self, from: data) else {
            return []
        }
        return (payload.items ?? []).compactMap { item in
            let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let snippet = item.snippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = item.link?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty || !snippet.isEmpty || !url.isEmpty else { return nil }
            return SearchResult(title: title, snippet: snippet, url: url)
        }
    }

    // MARK: - Spoken summary

    /// Builds the spoken answer from the top (1–2) results, or nil when
    /// there is nothing speakable. Each result is spoken as:
    ///
    ///     <title>.<snippet capped at two sentences> — <host>
    ///
    /// where the sentence stop between title and snippet is the
    /// locale-appropriate one (". " in English, "। " in Nepali — house
    /// convention) and the trailing "— <host>" is the `search.sourceLine`
    /// localization. Multiple results are separated by a newline (a
    /// natural pause in speech; the carded transcript shows the break).
    /// A result whose URL has no parseable host is still spoken — without
    /// the source line.
    static func summaryReply(for results: [SearchResult], locale: Locale) -> String? {
        let speakable = results.prefix(2).compactMap { result -> String? in
            spokenBlock(for: result, locale: locale)
        }
        guard !speakable.isEmpty else { return nil }
        return speakable.joined(separator: "\n")
    }

    private static func spokenBlock(for result: SearchResult, locale: Locale) -> String? {
        let title = collapsed(result.title)
        let snippet = collapsedSnippet(result.snippet)
        let body: String
        if title.isEmpty && snippet.isEmpty {
            return nil
        } else if title.isEmpty {
            body = snippet
        } else if snippet.isEmpty {
            body = title
        } else {
            // Google snippets often re-open with the title; "Title. Title
            // …" would double-speak it. When the snippet leads with the
            // title text, say the snippet alone.
            if snippet.hasPrefix(title) || snippet.lowercased().hasPrefix(title.lowercased()) {
                body = snippet
            } else {
                let stop = locale.language.languageCode?.identifier == "ne" ? "। " : ". "
                body = "\(title)\(stop)\(snippet)"
            }
        }
        guard let host = displayHost(from: result.url) else { return body }
        return body + " " + L10n.fmt("search.sourceLine", locale: locale, host)
    }

    /// Collapses whitespace/newline runs to single spaces — CSE snippets
    /// are HTML-ish text with stray newlines that would garble TTS.
    private static func collapsed(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// `collapsed` plus the two-sentence cap — applied to SNIPPETS only:
    /// a snippet can run on for many sentences, but a spoken answer must
    /// stay short. Titles are never sentence-capped.
    private static func collapsedSnippet(_ raw: String) -> String {
        cappedToTwoSentences(collapsed(raw))
    }

    /// Sentence boundary: punctuation followed by whitespace. Cuts at the
    /// end of the SECOND sentence; one or zero sentences pass through
    /// untouched. ("The rain stopped. The sun came out. And birds sang."
    /// → "The rain stopped. The sun came out.")
    private static let sentenceBoundary = try? NSRegularExpression(pattern: "(?<=[.!?।])\\s+")

    private static func cappedToTwoSentences(_ text: String) -> String {
        guard let sentenceBoundary else { return text }
        let fullRange = NSRange(text.startIndex..., in: text)
        let boundaries = sentenceBoundary.matches(in: text, range: fullRange)
        // NSRange offsets are UTF-16 — convert to a String index before
        // slicing so Devanagari text (multi-UTF-16 units) cuts correctly.
        guard boundaries.count >= 2,
              let secondBoundary = Range(boundaries[1].range, in: text) else {
            return text
        }
        return String(text[..<secondBoundary.lowerBound])
    }

    /// Bare host for the source line: "www.kathmandupost.com" →
    /// "kathmandupost.com". Non-URL strings → nil (no source line).
    private static func displayHost(from urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host, !host.isEmpty else { return nil }
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }

    // MARK: - Question gate

    /// True when an abstained utterance LOOKS like a question the search
    /// tool may answer. Conservative by design — the tool must not spend
    /// quota (or send words to Google) on statements or noise:
    ///
    ///   - a trailing "?" (typed queries; STT rarely emits it), OR
    ///   - a whole-token question word anywhere in the utterance
    ///     (split on whitespace/punctuation, exact match — the
    ///     `CommandRouter.containsToken` convention).
    ///
    /// Word table — Nepali: के, कहाँ, किन, कसरी, कहिले, को, कति, कुन,
    /// कस्तो. English: what, when, where, who, whose, whom, which, why,
    /// how. ("कुन"/"कस्तो" also serve as adjectives — "कुन बेला" — which
    /// is fine: an utterance containing them is question-shaped.)
    ///
    /// Known blind spot (deliberate): auxiliary-fronted English questions
    /// ("is there a pharmacy near here?", "can you…") carry no question
    /// word and are NOT detected — better to miss a search than to fire
    /// one on a statement.
    static func isQuestionShaped(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        // A bare "?" is STT noise, not a question — the suffix rule needs
        // at least one real character before the mark.
        if text.count > 1, text.hasSuffix("?") { return true }
        return questionTokens.contains { token in
            text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                .contains { $0 == token }
        }
    }

    private static let questionTokens: Set<String> = [
        "के", "कहाँ", "किन", "कसरी", "कहिले", "को", "कति", "कुन", "कस्तो",
        "what", "when", "where", "who", "whose", "whom", "which", "why", "how"
    ]
}

/// [LOCAL-TOOLS] (2026-09-07) Holds the Google Custom Search credentials
/// (API key + search-engine ID) — a deliberate mirror of
/// `GeminiConfigStore`: `EncryptedLocalStorage` (Keychain, Data Protection
/// Complete), never `UserDefaults`, never hardcoded. Expected to be
/// entered by a family member in Settings (the elderly primary user is not
/// asked to handle API keys).
final class SearchConfigStore: ObservableObject {
    private static let apiKeyStorageKey = "search.apiKey"
    private static let engineIdStorageKey = "search.engineId"

    private let storage: EncryptedLocalStorage

    @Published private(set) var apiKey: String?
    @Published private(set) var searchEngineID: String?

    /// The search tool fires ONLY when both halves of the credential pair
    /// exist — a key without an engine (or vice versa) cannot be used and
    /// is treated as unconfigured rather than half-configured.
    var isConfigured: Bool { apiKey != nil && searchEngineID != nil }

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
        self.apiKey = Self.load(key: Self.apiKeyStorageKey, storage: storage)
        self.searchEngineID = Self.load(key: Self.engineIdStorageKey, storage: storage)
    }

    /// Save (whitespace-trimmed) or clear the API key. Saving empty text
    /// clears ONLY the key — the engine ID survives until removed.
    func saveAPIKey(_ newKey: String) {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            _ = storage.delete(key: Self.apiKeyStorageKey)
            apiKey = nil
            return
        }
        _ = storage.write(key: Self.apiKeyStorageKey, value: trimmed)
        apiKey = trimmed
    }

    func saveSearchEngineID(_ newID: String) {
        let trimmed = newID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            _ = storage.delete(key: Self.engineIdStorageKey)
            searchEngineID = nil
            return
        }
        _ = storage.write(key: Self.engineIdStorageKey, value: trimmed)
        searchEngineID = trimmed
    }

    /// Removes BOTH credentials (the Settings "remove" action) — the
    /// search tool stops firing until reconfigured.
    func clear() {
        _ = storage.delete(key: Self.apiKeyStorageKey)
        _ = storage.delete(key: Self.engineIdStorageKey)
        apiKey = nil
        searchEngineID = nil
    }

    private static func load(key: String, storage: EncryptedLocalStorage) -> String? {
        guard case .success(let value) = storage.read(key: key, type: String.self),
              !value.isEmpty else { return nil }
        return value
    }
}

/// [LOCAL-TOOLS] (2026-09-07) Daily cap on search-tool attempts
/// (`UserDefaults` — a counter, not a secret). 50/day is deliberately
/// below the free Google CSE tier's 100-query ceiling so the household
/// never hits a hard Google block, while leaving headroom for a heavy
/// usage day; the Settings quota note states the cap plainly.
///
/// Bucket keys: "search.quota.day" (yyyyMMdd stamp of the bucket's day),
/// "search.quota.count". A count recorded on a PREVIOUS day never counts
/// against today — rollover happens on read AND on increment.
enum SearchQuota {
    static let dailyLimit = 50
    static let dayKey = "search.quota.day"
    static let countKey = "search.quota.count"

    /// The day-bucket stamp for `date` ("20260907" for 7 Sep 2026) —
    /// local calendar, so a household that crosses midnight mid-session
    /// gets a fresh budget with the new day.
    static func dayStamp(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The RAW stored count — no day normalization. Pair with
    /// `remaining(today:count:limit:defaults:)`, which applies a
    /// previous-day count as zero.
    static func readCount(defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: countKey)
    }

    /// How many searches may still fire today, or 0 once the cap is hit.
    /// `count` is the raw `readCount()`; it only eats today's budget when
    /// it was recorded under `today`'s day stamp — otherwise the full
    /// `limit` applies (fresh day, fresh budget). Never negative.
    static func remaining(today: Date,
                          count: Int,
                          limit: Int,
                          defaults: UserDefaults = .standard,
                          calendar: Calendar = .current) -> Int {
        let storedDay = defaults.string(forKey: dayKey)
        let appliesToday = storedDay == dayStamp(for: today, calendar: calendar)
        let consumed = appliesToday ? max(0, count) : 0
        return max(0, limit - consumed)
    }

    /// Records one more attempt and returns the new count. Rolls the
    /// bucket over when the stored day is not today (the first attempt of
    /// a new day starts at 1, not at yesterday's total + 1).
    @discardableResult
    static func increment(defaults: UserDefaults = .standard,
                          now: Date = Date(),
                          calendar: Calendar = .current) -> Int {
        let stamp = dayStamp(for: now, calendar: calendar)
        let current = defaults.string(forKey: dayKey) == stamp
            ? defaults.integer(forKey: countKey)
            : 0
        let next = current + 1
        defaults.set(stamp, forKey: dayKey)
        defaults.set(next, forKey: countKey)
        return next
    }

    /// Zeroes the bucket (tests; a future settings "reset" action).
    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: dayKey)
        defaults.removeObject(forKey: countKey)
    }
}
