import Foundation

// MARK: - Feed translation (feed translation task, 2026-09-09 — progressive)

/// PROGRESSIVE translation of feed content into the app's active
/// language: when the locale is Nepali, fallback-language (English)
/// items translate AUTOMATICALLY as they load — the cards render the
/// ORIGINAL text immediately (with a subtle "translating…" state), and
/// each translation swaps in when it lands. No per-item button is
/// needed for that anymore; the card's button is now the toggle to the
/// original plus the per-item retry/on-demand path.
///
/// Pipeline: every refresh publishes the composed (original-language)
/// items FIRST, then `AppCoordinator.translateVisibleFeedItems` runs —
/// ONE batched JSON-mode provider call for the first `batchSize`
/// untranslated Latin-script items (the visible page, cheaper than
/// per-item calls) through the app's existing cloud path
/// (`GeminiClient.generateJSON` → `send`, whose fail-fast
/// `.notConfigured`/`.dailyCapReached` states map to the honest
/// `.unavailable` below, and whose shared cost governor caps spend as
/// today). If the batch shape fails, the proven per-item path takes
/// over for the same items (resilience, same budget); per-item failures
/// keep the original + the honest caption (`feeds.translationUnavailable`).
/// Results cache under the item id (session scope, capped).
///
/// English locale: nothing translates, nothing changes.
///
/// Failures never fabricate and never block the feed: the original
/// text stays visible through every failure state.

/// One item's translated text, cached under the item id.
struct FeedTranslation: Equatable {
    let title: String
    let summary: String
}

enum FeedTranslationError: Error, Equatable {
    /// The cloud provider is not configured (or its daily budget is
    /// exhausted) — translation is honestly not available.
    case unavailable
    /// The provider replied but the reply did not parse into a
    /// translation (nothing usable to show — original stays).
    case invalidResponse
}

/// One item's outcome inside a progressive batch — per-item granularity
/// (a partial batch never blanks the rest).
enum FeedTranslationOutcome: Equatable {
    case success(FeedTranslation)
    case failure
}

/// One entry of the batch reply's promised JSON shape (validated per
/// entry after decode — an empty title is invalid and that item fails
/// alone).
struct FeedBatchEntry: Decodable, Equatable {
    let title: String
    let summary: String
}

/// The batch reply envelope: `{"translations":[...]}`.
private struct FeedBatchResponse: Decodable {
    let translations: [FeedBatchEntry]
}

/// The provider seam `FeedTranslator` speaks to. The app's `GeminiClient`
/// conforms below; tests inject a stub.
protocol FeedTranslationClient {
    /// Plain-text reply (the per-item path).
    func completeText(prompt: String) async throws -> String
    /// JSON-mode reply (`responseMimeType: application/json`) — the
    /// cheaper single-call batch path for the visible page.
    func completeJSON(prompt: String) async throws -> String
}

extension GeminiClient: FeedTranslationClient {
    /// Sends a plain-text prompt through the existing Gemini path and
    /// returns the model's raw text. The client's own fail-fast states
    /// (no API key, daily cap) become the honest `.unavailable` so the
    /// feed layer never distinguishes "no cloud" from "cloud says no" —
    /// both read as "translation unavailable", and neither has made a
    /// network call.
    func completeText(prompt: String) async throws -> String {
        do {
            let request = GeminiRequest(
                contents: [.init(parts: [.text(prompt)])],
                generationConfig: nil
            )
            return try await send(request)
        } catch let error as GeminiClient.GeminiClientError {
            switch error {
            case .notConfigured, .dailyCapReached:
                throw FeedTranslationError.unavailable
            default:
                throw error
            }
        }
    }

    /// Sends a JSON-mode prompt through the EXISTING `generateJSON` path
    /// (same cost governor, same fail-fast states — mapped identically
    /// to `completeText`).
    func completeJSON(prompt: String) async throws -> String {
        do {
            return try await generateJSON(prompt: prompt)
        } catch let error as GeminiClient.GeminiClientError {
            switch error {
            case .notConfigured, .dailyCapReached:
                throw FeedTranslationError.unavailable
            default:
                throw error
            }
        }
    }
}

/// The on-ask translation worker — stateless except for the provider
/// client; the item-id CACHE lives in the coordinator's published
/// `feedTranslations` map (its single source of truth the cards read).
final class FeedTranslator {

    /// Session-cache cap: beyond this, oldest-inserted entries are
    /// evicted (the cache only saves re-translating on refresh —
    /// eviction is a cost bound, never data loss: the original item is
    /// always present).
    static let cacheLimit = 200

    /// Prompt-input bounds: the provider sees at most this much content.
    /// Truncation is Character-safe (`String.prefix` never splits a
    /// grapheme cluster).
    static let maxTitleChars = 300
    static let maxSummaryChars = 700

    /// Items per progressive pass — the visible page. ONE batched
    /// provider call covers this many untranslated fallback-language
    /// items per refresh; later batches follow on later passes (the
    /// item-id cache skips what is done), and the per-item path covers
    /// anything the user asks for explicitly.
    static let batchSize = 8

    private let client: any FeedTranslationClient
    private let observability: ObservabilityBus

    init(client: any FeedTranslationClient, observability: ObservabilityBus) {
        self.client = client
        self.observability = observability
    }

    /// Translates one item's title+summary into `language`. Throws
    /// `FeedTranslationError.unavailable` when the provider has no
    /// cloud; propagates provider/transport failures otherwise — the
    /// caller treats every throw the same way (original text + honest
    /// caption). Exactly ONE observability event per attempt (the
    /// thrown error's code, never a re-tagged duplicate).
    func translate(title: String, summary: String,
                   language: AppLanguage) async throws -> FeedTranslation {
        // Bounding lives INSIDE `prompt` (the single prompt-construction
        // point) — the XCTest pins the builder itself to carry only the
        // Character-safe prefixes.
        let prompt = Self.prompt(title: title, summary: summary,
                                 language: language)
        let start = Date()
        do {
            let response = try await client.completeText(prompt: prompt)
            guard let parsed = Self.parse(response: response) else {
                throw FeedTranslationError.invalidResponse
            }
            emit(outcome: "success", errorCode: nil, start: start)
            return parsed
        } catch {
            emit(outcome: "failure", errorCode: errorCode(for: error), start: start)
            throw error
        }
    }

    // MARK: - Progressive batch (one call for the visible page)

    /// Translates the visible page in ONE batched call; falls back to
    /// the proven per-item path when the batch shape fails. Returns one
    /// outcome per item (same order) — a partial batch never blanks
    /// the rest.
    func translateBatch(_ items: [FeedItem], language: AppLanguage)
        async -> [(item: FeedItem, outcome: FeedTranslationOutcome)] {
        guard !items.isEmpty else { return [] }
        let start = Date()
        do {
            let response = try await client.completeJSON(
                prompt: Self.batchPrompt(items: items, language: language))
            guard let aligned = Self.parseBatch(response: response,
                                                count: items.count) else {
                throw FeedTranslationError.invalidResponse
            }
            let results = zip(items, aligned).map { item, entry
                -> (item: FeedItem, outcome: FeedTranslationOutcome) in
                guard let entry else { return (item, .failure) }
                return (item, .success(FeedTranslation(title: entry.title,
                                                       summary: entry.summary)))
            }
            let succeeded = aligned.compactMap(\.self).count
            emitBatch(outcome: "success", entryCount: succeeded,
                      errorCode: succeeded == items.count ? nil : "partial",
                      start: start)
            return results
        } catch let error as FeedTranslationError where error == .unavailable {
            // No cloud: the per-item path would fail identically for
            // every item — mark all failed WITHOUT a per-item storm
            // (the fail-fast is free; N fail-fast calls are not).
            emitBatch(outcome: "failure", entryCount: nil,
                      errorCode: "unavailable", start: start)
            return items.map { ($0, .failure) }
        } catch {
            // Batch shape failed (provider/transport): fall back to the
            // proven per-item path — resilience, bounded by the shared
            // cost governor exactly like every other path.
            emitBatch(outcome: "failure", entryCount: nil,
                      errorCode: "fallback_per_item", start: start)
            var results: [(item: FeedItem, outcome: FeedTranslationOutcome)] = []
            for item in items {
                do {
                    let translation = try await translate(title: item.title,
                                                          summary: item.summary,
                                                          language: language)
                    results.append((item, .success(translation)))
                } catch {
                    results.append((item, .failure))
                }
            }
            return results
        }
    }

    /// The batch prompt: numbered items, strict JSON contract. Content
    /// bounded exactly like the per-item prompt (Character-safe).
    static func batchPrompt(items: [FeedItem], language: AppLanguage) -> String {
        let target = language == .nepali ? "Nepali" : "English"
        let numbered = items.enumerated().map { index, item in
            let title = String(item.title.prefix(maxTitleChars))
            let summary = String(item.summary.prefix(maxSummaryChars))
            return """
            \(index + 1). Headline: \(title)
               Summary: \(summary)
            """
        }.joined(separator: "\n")
        return """
        Translate these \(items.count) news headlines and summaries into \(target). \
        Reply with ONLY a JSON object of the form \
        {"translations":[{"title":"...","summary":"..."}]} — exactly one entry \
        per item, in the same order, with no text outside the JSON. Use an \
        empty string for a missing summary.

        \(numbered)
        """
    }

    /// Parses the batch reply into `count` aligned slots: index-aligned
    /// entries, nil for a missing/invalid entry (that item fails alone —
    /// never fabricated), extra entries ignored. nil overall when the
    /// reply is not the promised JSON shape (the caller falls back to
    /// per-item). An empty entry list for a non-empty batch is ALSO
    /// invalid — the model did not comply.
    static func parseBatch(response: String, count: Int) -> [FeedBatchEntry?]? {
        guard let data = response.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FeedBatchResponse.self,
                                                      from: data) else {
            return nil
        }
        guard !decoded.translations.isEmpty || count == 0 else { return nil }
        var aligned: [FeedBatchEntry?] = Array(repeating: nil, count: count)
        for (index, entry) in decoded.translations.enumerated() where index < count {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }   // invalid entry stays nil
            aligned[index] = FeedBatchEntry(title: title,
                                            summary: entry.summary)
        }
        return aligned
    }

    // MARK: - Pure helpers (pinned by tests)

    /// The translation prompt: two output lines (headline, summary),
    /// nothing else. The instruction language is English (a machine
    /// instruction, not UI chrome); the target language name derives
    /// from the app language.
    ///
    /// CONTENT IS BOUNDED HERE at `maxTitleChars`/`maxSummaryChars`
    /// with Character-safe prefixes (`String.prefix` never splits a
    /// grapheme cluster) — the provider never sees content past the
    /// bound, and a Devanagari sentinel beyond the bound can never
    /// appear in the prompt (pinned by `FeedTranslatorTests`).
    static func prompt(title: String, summary: String,
                       language: AppLanguage) -> String {
        let boundedTitle = String(title.prefix(maxTitleChars))
        let boundedSummary = String(summary.prefix(maxSummaryChars))
        let target = language == .nepali ? "Nepali" : "English"
        return """
        Translate this news headline and summary into \(target). \
        Reply with exactly two lines and nothing else: the first line is \
        the translated headline, the second line is the translated \
        summary. If the summary is empty, reply with only the headline.

        Headline: \(boundedTitle)
        Summary: \(boundedSummary)
        """
    }

    /// Parses the model's reply: first non-empty line = title, second
    /// non-empty line = summary, EVERYTHING after the second line is
    /// discarded (commentary never pollutes the translation). nil when
    /// no non-empty line exists — nothing usable, nothing fabricated.
    static func parse(response: String) -> FeedTranslation? {
        let lines = response
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let title = lines.first else { return nil }
        let summary = lines.count >= 2 ? lines[1] : ""
        return FeedTranslation(title: title, summary: summary)
    }

    /// Cache trimming: caps the cache at `limit` entries. WHICH entries
    /// are evicted is UNSPECIFIED (Dictionary iteration order) — the
    /// cache is purely a re-translation cost bound, never a correctness
    /// or recency contract: an evicted entry is simply re-translated on
    /// its next ask. Pinned order-independently by tests.
    static func trimmed(_ cache: [String: FeedTranslation],
                        limit: Int = cacheLimit) -> [String: FeedTranslation] {
        guard cache.count > limit else { return cache }
        var result = cache
        let excess = cache.count - limit
        var dropped = 0
        for key in cache.keys {
            guard dropped < excess else { break }
            result.removeValue(forKey: key)
            dropped += 1
        }
        return result
    }

    // MARK: - Observability (PII-free: outcome + duration + code only)

    private func errorCode(for error: Error) -> String {
        if let feedError = error as? FeedTranslationError {
            switch feedError {
            case .unavailable: return "unavailable"
            case .invalidResponse: return "invalid_response"
            }
        }
        return "provider_error"
    }

    private func emit(outcome: String, errorCode: String?, start: Date) {
        // Never titles, summaries, or prompts — the same PII-free bar
        // the speak queue and feed fetch hold.
        observability.emit(ObservabilityEvent(
            component: "feed",
            eventType: "feed.translate",
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            outcome: outcome,
            errorCode: errorCode,
            metadata: [:]
        ))
    }

    /// Batch-level event (counts only — PII-free like every other
    /// feed event).
    private func emitBatch(outcome: String, entryCount: Int?, errorCode: String?,
                           start: Date) {
        var metadata: [String: String] = [:]
        if let entryCount {
            metadata["entry_count"] = String(entryCount)
        }
        observability.emit(ObservabilityEvent(
            component: "feed",
            eventType: "feed.translate_batch",
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            outcome: outcome,
            errorCode: errorCode,
            metadata: metadata
        ))
    }
}

// MARK: - Per-card display resolution (feed translation task)

/// Pure resolution of WHICH text a card shows — the single decision the
/// card render AND the read-aloud path share, so the voice can never
/// read different text than the card displays (the "read aloud speaks
/// what the card currently displays" rule). Pinned by tests.
enum FeedCardDisplayResolver {

    struct Display: Equatable {
        let title: String
        let summary: String
        /// True when the card is currently showing the TRANSLATION.
        let isShowingTranslation: Bool
        /// True when a cached translation exists — the Translate button
        /// toggles between translation and original (no new call).
        let hasTranslation: Bool
    }

    /// `showingOriginal` is the card's toggle state (the user's second
    /// tap reverted to the original): it wins over a cached translation.
    static func resolve(item: FeedItem, translation: FeedTranslation?,
                        showingOriginal: Bool) -> Display {
        if let translation, !showingOriginal {
            return Display(title: translation.title,
                           summary: translation.summary,
                           isShowingTranslation: true,
                           hasTranslation: true)
        }
        return Display(title: item.title,
                       summary: item.summary,
                       isShowingTranslation: false,
                       hasTranslation: translation != nil)
    }
}
