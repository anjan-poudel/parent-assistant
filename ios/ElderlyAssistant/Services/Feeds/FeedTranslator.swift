import Foundation

// MARK: - Feed translation (feed translation task, 2026-09-08)

/// Per-item, ON-ASK translation of feed content into the app's active
/// language. The Feed screen shows items in their ORIGINAL language by
/// default — "single language" means the app chrome (already locale-
/// driven) never mixes; CONTENT is translated only when the user taps a
/// card's Translate button, never automatically.
///
/// Pipeline: card tap → `AppCoordinator.translateFeedItem` →
/// `FeedTranslator.translate` → the app's existing cloud provider path
/// (`GeminiClient.send` — its fail-fast `.notConfigured`/`.dailyCapReached`
/// states map to the honest `.unavailable` below) → cached under the item
/// id (session scope, capped) → the card shows the translation in place;
/// the same button toggles back to the original (a second tap reverts —
/// the cached translation makes the toggle free).
///
/// Failures never fabricate and never block the feed: the original text
/// stays and the card shows the small honest caption
/// (`feeds.translationUnavailable`).

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

/// The provider seam `FeedTranslator` speaks to. The app's `GeminiClient`
/// conforms below; tests inject a stub.
protocol FeedTranslationClient {
    func completeText(prompt: String) async throws -> String
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
