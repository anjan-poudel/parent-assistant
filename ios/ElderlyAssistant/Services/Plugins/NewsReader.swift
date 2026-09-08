import Foundation

/// Digest composition for the news reader (news-reader feature,
/// 2026-09-08): turns per-source fetch results into the honest spoken
/// digest. PURE statics — no network, no queue — so the templates and the
/// TTS sanitization are unit-testable without fakes.
///
/// This is a HEADLINE DIGEST, not an LLM summary (constitution: no
/// fabricated content — the app must never paraphrase news it did not
/// fetch, and must never attribute to a source something that source did
/// not publish). Every spoken line is either a source's verbatim
/// (sanitized) headline, a pinned per-source honest failure/empty line, or
/// the pinned all-failed/all-empty line. No exceptions.
///
/// TTS-friendliness: titles are plain text by nature, but feed titles
/// arrive with artifacts — HTML entities (&amp;, &#039;, &nbsp;),
/// embedded tags (CDATA titles), URLs, stray newlines. `sanitizedTitle`
/// removes them all before a title may be spoken.
enum NewsDigestComposer {

    /// Up to this many headlines are spoken per source (spec: top 2–3).
    /// Bounded so a 6-source digest stays a digest — elderly users hear a
    /// summary, not a newspaper.
    static let maxHeadlinesPerSource = 3

    /// One source's fetch result, in configured feed order.
    struct SourceResult: Equatable {
        enum Outcome: Equatable {
            /// Headlines as fetched — `fetchSource` sanitizes them before
            /// this point, and the render seam re-sanitizes defensively
            /// (idempotent), so raw titles are safe here too.
            case ok([String])
            /// Well-formed feed with zero items — honest "nothing new".
            case empty
            /// Transport / HTTP / parse failure — honest "couldn't reach".
            case failed
        }
        let source: NewsSource
        let outcome: Outcome

        var headlineCount: Int {
            if case .ok(let titles) = outcome { return titles.count }
            return 0
        }
    }

    // MARK: - Composition

    /// The digest's spoken lines for `locale`. Rules (pinned by tests):
    ///  - every source failed → ONE `news.allFailed` line (not six
    ///    failure lines in a row — spec: failures speak the honest
    ///    "couldn't fetch" line);
    ///  - every source fetched fine but had nothing → ONE `news.allEmpty`
    ///    line;
    ///  - a mix of failures and empties with NO items → per-source
    ///    lines — which sources are down and which merely have nothing
    ///    is real information, never flattened into a blanket line;
    ///  - otherwise (at least one source has items) → one line PER
    ///    SOURCE, in feed order: the localized source line + up to
    ///    `maxHeadlinesPerSource` headlines for `.ok`, and the honest
    ///    per-source empty/failed line for the rest.
    ///  - every `.ok` line ENDS with its sentence stop (each headline
    ///    also ends with one — a headline list reads as finished
    ///    sentences and TTS pauses cleanly before the next source line);
    ///  - zero sources (impossible with the pinned defaults, possible
    ///    with a configured-then-cleared race) → the honest `news.allFailed`
    ///    line rather than silence (constitution: no silent stubs).
    static func lines(for results: [SourceResult], locale: Locale) -> [String] {
        guard !results.isEmpty else {
            return [L10n.str("news.allFailed", locale: locale)]
        }
        let okCount = results.filter { if case .ok = $0.outcome { return true }; return false }.count
        if okCount == 0 {
            // The GLOBAL lines apply only when the per-source breakdown
            // carries no information: all failed, or all empty. Any mix
            // falls through to the per-source lines below.
            if results.allSatisfy({ if case .failed = $0.outcome { return true }; return false }) {
                return [L10n.str("news.allFailed", locale: locale)]
            }
            if results.allSatisfy({ if case .empty = $0.outcome { return true }; return false }) {
                return [L10n.str("news.allEmpty", locale: locale)]
            }
        }
        let stop = sentenceStop(for: locale)
        let lineEnd = stop.trimmingCharacters(in: .whitespaces)
        return results.map { result in
            switch result.outcome {
            case .ok(let titles):
                // The render seam is the LAST gate before the speaker: it
                // owns the cap (top `maxHeadlinesPerSource`) AND a
                // defensive re-sanitization of every title (idempotent —
                // `fetchSource` already sanitized, so this is a no-op in
                // production; it guarantees nothing non-speakable can
                // ever be rendered). A source whose titles all sanitize
                // to nothing renders the honest empty line, never a bare
                // "From X:".
                let speakable = titles
                    .prefix(maxHeadlinesPerSource)
                    .compactMap(sanitizedTitle)
                guard !speakable.isEmpty else {
                    return L10n.fmt("news.sourceEmpty", locale: locale, result.source.name)
                }
                // Each headline ends with its stop, and the LINE ends
                // with one too ("H1. H2. H3." / "H1। H2। H3।").
                let body = speakable.joined(separator: stop) + lineEnd
                return L10n.fmt("news.sourceLine", locale: locale, result.source.name) + " " + body
            case .empty:
                return L10n.fmt("news.sourceEmpty", locale: locale, result.source.name)
            case .failed:
                return L10n.fmt("news.sourceFailed", locale: locale, result.source.name)
            }
        }
    }

    /// The full digest text: lines joined by newlines (a natural pause in
    /// speech; the carded outcome shows the break). Exactly what gets
    /// enqueued and spoken.
    static func digestText(for results: [SourceResult], locale: Locale) -> String {
        lines(for: results, locale: locale).joined(separator: "\n")
    }

    /// The sentence stop between headlines — the house convention
    /// (SearchTool uses the same pair): ". " in English, "। " in Nepali.
    static func sentenceStop(for locale: Locale) -> String {
        locale.language.languageCode?.identifier == "ne" ? "। " : ". "
    }

    // MARK: - TTS sanitization

    /// Makes one raw feed title safe to speak, or nil when nothing
    /// speakable remains. Pipeline: decode HTML entities (a no-op for
    /// already-decoded text — `XMLParser` resolves references in normal
    /// text nodes but NOT inside CDATA) → strip embedded tags → strip
    /// URLs → collapse whitespace → trim → strip dangling trailing
    /// colons. A trailing colon is a list/continuation artifact ("Read
    /// more: <url>") — once the URL is gone the colon reads aloud like a
    /// prompt for text that never comes, so it is stripped. No other
    /// symbol scrubbing: titles are prose, and over-sanitizing corrupts
    /// Nepali script.
    static func sanitizedTitle(_ raw: String) -> String? {
        var text = decodingHTMLEntities(raw)
        text = text.replacingOccurrences(of: "<[^>]*>", with: "",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: "(https?://|www\\.)\\S+", with: "",
                                         options: .regularExpression)
        text = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(":") {
            text = String(text.dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    /// Named-entity table for the decode step — the set that actually
    /// appears in real feed titles (Ratopati ships `&#039;` + `&nbsp;`;
    /// BBC CDATA titles ship `&amp;`). Unknown named entities degrade to
    /// their inner text (dropping only the `&…;` wrapper), so no content
    /// is invented or destroyed.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "hellip": "…", "mdash": "—", "ndash": "–",
        "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
        "raquo": "»", "laquo": "«", "copy": "©", "reg": "®", "trade": "™",
        "deg": "°", "pound": "£", "euro": "€", "yen": "¥",
        "eacute": "é", "agrave": "à", "egrave": "è", "ccedil": "ç",
        "uuml": "ü", "ntilde": "ñ"
    ]

    /// One-pass entity decode: `&amp;` `&lt;` `&gt;` `&quot;` `&apos;`
    /// `&#39;` `&#x1F600;` and the named table above. Single pass on
    /// purpose — a second pass could decode already-decoded text twice
    /// ("&amp;quot;" must become "&quot;", not a quote).
    static func decodingHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        guard let regex = try? NSRegularExpression(
            pattern: "&(#\\d{1,7}|#x[0-9a-fA-F]{1,6}|[a-zA-Z]{2,10});") else {
            return text
        }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text,
                                   range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor,
                                                 length: match.range.location - cursor))
            result += replacement(for: ns.substring(with: match.range(at: 1)))
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func replacement(for entity: String) -> String {
        if entity.hasPrefix("#x") {
            let hex = entity.dropFirst(2)
            if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                return String(scalar)
            }
            return ""
        }
        if entity.hasPrefix("#") {
            if let value = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(value) {
                return String(scalar)
            }
            return ""
        }
        return namedEntities[entity] ?? entity
    }
}

/// News-reader source plugin (news-reader feature, 2026-09-08): the
/// voice-OS shell's second push source beside `MorningBriefing`. Fired by
/// the deterministic CommandRouter stage ("read me the news" /
/// "समाचार सुनाऊ" — see `CommandRouter.newsPhrases`), never by the LLM
/// interpreter, so it consumes zero IntentPrompt tokens and can never
/// misclassify (the stage covers dispatch; per spec, the AssistantPlugin
/// contribution is intentionally omitted).
///
/// Flow (spec §4 — never block the voice turn):
///  1. `fire()` enqueues the localized "checking" line FIRST — the user
///     hears the lookup started before the network round-trip.
///  2. All `effectiveSources` are fetched CONCURRENTLY (task group), each
///     with a bounded `perSourceTimeoutSeconds` (8 s — the same budget as
///     the search tool), through the `LocalToolTransport` seam (a stub in
///     tests; URLSession in production).
///  3. The digest is composed and enqueued as ONE `.briefing`-lane
///     announcement with its own outcome card. A transport-less reader
///     (dormant default, mirroring the local-tools seams) degrades to the
///     honest `news.allFailed` line — never a fake digest.
///
/// Re-entrancy (spec §4): one digest per command — a second `fire()` while
/// a fetch is in flight is a guarded no-op that speaks the honest
/// `news.alreadyFetching` line and emits `news_fire_skipped` (no
/// once-per-wake-window budget: news is on-demand).
///
/// Observability (spec §5): component `news_reader`, PII-free — event
/// metadata carries COUNTS and OUTCOME TAGS only (source index, headline
/// count, ok/empty/failed). Headline text, source names and the digest
/// itself never reach the bus or any log; they exist only inside the
/// in-memory `Announcement`.
///
/// Persistence: the source list lives in `NewsSourceStore` (Keychain,
/// REPLACE rule — configured sources replace the defaults). The digest
/// itself is deliberately NOT persisted: news is ephemeral, and storing
/// it would add a headline-carrying payload for no user benefit.
final class NewsReader: SpeechSource {

    // MARK: - SpeechSource

    static let sourceIDValue = "news_reader"

    var sourceID: String { Self.sourceIDValue }

    /// The digest is a composed reading — it waits for whatever is being
    /// spoken (`.briefing` lane, same as MorningBriefing), and is itself
    /// interrupted only by the safety-critical lanes.
    var defaultPriority: AnnouncementPriority { .briefing }

    /// Push-driven: announcements are enqueued by `fire()`; nothing is
    /// ever staged for the pull channel.
    func nextAnnouncement() async -> Announcement? { nil }

    /// Both supported app languages compose a digest (spec §7: both
    /// languages verified for every spoken template). Not geogated.
    func isApplicable(locale: Locale) -> Bool {
        guard let language = locale.language.languageCode?.identifier else { return false }
        return language == "en" || language == "ne"
    }

    // MARK: - Configuration

    /// Per-source fetch timeout — the same 8 s budget the search tool
    /// uses (`CommandRouter.searchFetchTimeoutSeconds`). Bounded so a
    /// dead feed can never hold the voice turn hostage.
    static let perSourceTimeoutSeconds: TimeInterval = 8

    /// Active composition locale. Injected by `AppCoordinator` from
    /// `activeLocale` (same pattern as MorningBriefing.locale).
    var locale: Locale = Locale(identifier: "en")

    // MARK: - State

    private let queue: SpeakQueueProtocol
    private let observability: ObservabilityBus
    private let store: NewsSourceStore
    /// Network seam — nil keeps the reader dormant (all sources fail
    /// honestly), the same dormant-default pattern as the local tools.
    private let transport: LocalToolTransport?
    /// One in-flight digest at a time (spec §4 re-entrancy guard).
    private let fireLock = NSLock()
    private var isInFlight = false

    // MARK: - Init

    init(queue: SpeakQueueProtocol,
         observability: ObservabilityBus,
         store: NewsSourceStore,
         transport: LocalToolTransport? = nil,
         locale: Locale = Locale(identifier: "en")) {
        self.queue = queue
        self.observability = observability
        self.store = store
        self.transport = transport
        self.locale = locale
    }

    // MARK: - Trigger

    /// Announces "checking", fetches every effective source, composes the
    /// honest digest and enqueues ONE announcement. A second `fire()`
    /// while a digest is in flight is a guarded no-op that still speaks
    /// (the honest "already fetching" line — never silence).
    func fire() async {
        guard beginFire() else {
            emit("news_fire_skipped", outcome: "skipped", metadata: ["state": "in_flight"])
            enqueue(line: L10n.str("news.alreadyFetching", locale: locale),
                    cardBody: L10n.str("news.alreadyFetching", locale: locale),
                    symbolName: "newspaper")
            return
        }
        defer { endFire() }

        // Spec §4: announce FIRST — the round-trip is async and the user
        // must never wait in silence.
        enqueue(line: L10n.str("news.checking", locale: locale),
                cardBody: L10n.str("news.checking", locale: locale),
                symbolName: "newspaper")
        let sources = store.effectiveSources
        emit("news_fire_started",
             metadata: ["mode": store.configuredSources.isEmpty ? "defaults" : "configured",
                        "source_count": String(sources.count)])

        let results = await fetchAll(sources)
        for (index, result) in results.enumerated() {
            let tag = Self.outcomeTag(result.outcome)
            emit("news_source_result",
                 outcome: tag == "failed" ? "failure" : "success",
                 metadata: ["index": String(index),
                            "outcome": tag,
                            "headline_count": String(result.headlineCount)])
        }

        let text = NewsDigestComposer.digestText(for: results, locale: locale)
        enqueue(line: text, cardBody: text, symbolName: "newspaper.fill")
        emit("news_digest_delivered",
             metadata: ["source_count": String(results.count),
                        "headline_count": String(results.reduce(0) { $0 + $1.headlineCount })])
    }

    /// Fetches every source CONCURRENTLY (bounded by the per-source
    /// timeout, so the whole round-trip is ~8 s, not 8 s × sources) and
    /// returns results in FEED ORDER — the digest is deterministic for
    /// identical inputs.
    private func fetchAll(_ sources: [NewsSource]) async -> [NewsDigestComposer.SourceResult] {
        await withTaskGroup(of: (Int, NewsDigestComposer.SourceResult).self) { group in
            let transport = self.transport
            for (index, source) in sources.enumerated() {
                group.addTask {
                    (index, await Self.fetchSource(source, transport: transport,
                                                   timeout: Self.perSourceTimeoutSeconds))
                }
            }
            var collected: [(Int, NewsDigestComposer.SourceResult)] = []
            for await pair in group { collected.append(pair) }
            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    /// One source's round-trip — pure async statics so the per-source
    /// outcome mapping is testable without the reader. Outcome mapping:
    ///  - no transport / unparseable URL / transport throw / non-2xx /
    ///    malformed XML → `.failed` (the honest "couldn't reach" line —
    ///    NEVER `.empty`, which would claim the source had nothing);
    ///  - well-formed feed, zero items, or items that sanitize to nothing
    ///    → `.empty`;
    ///  - otherwise `.ok` with the first `maxHeadlinesPerSource`
    ///    sanitized titles.
    static func fetchSource(_ source: NewsSource,
                            transport: LocalToolTransport?,
                            timeout: TimeInterval) async -> NewsDigestComposer.SourceResult {
        guard let transport, let url = source.url else {
            return NewsDigestComposer.SourceResult(source: source, outcome: .failed)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await transport.fetchData(for: request)
            let statusOK = (response as? HTTPURLResponse)
                .map { (200..<300).contains($0.statusCode) } ?? true
            guard statusOK else {
                return NewsDigestComposer.SourceResult(source: source, outcome: .failed)
            }
            switch NewsFeedParser.parse(data) {
            case .malformed:
                return NewsDigestComposer.SourceResult(source: source, outcome: .failed)
            case .empty:
                return NewsDigestComposer.SourceResult(source: source, outcome: .empty)
            case .ok(let headlines):
                let titles = headlines
                    .prefix(NewsDigestComposer.maxHeadlinesPerSource)
                    .compactMap { NewsDigestComposer.sanitizedTitle($0.title) }
                return NewsDigestComposer.SourceResult(
                    source: source,
                    outcome: titles.isEmpty ? .empty : .ok(titles))
            }
        } catch {
            return NewsDigestComposer.SourceResult(source: source, outcome: .failed)
        }
    }

    // MARK: - Re-entrancy guard

    private func beginFire() -> Bool {
        fireLock.lock()
        defer { fireLock.unlock() }
        if isInFlight { return false }
        isInFlight = true
        return true
    }

    private func endFire() {
        fireLock.lock()
        isInFlight = false
        fireLock.unlock()
    }

    // MARK: - Delivery

    /// One `.briefing`-lane announcement + its card (the shell's
    /// speech-and-card pattern, exactly like MorningBriefing's fire()).
    private func enqueue(line: String, cardBody: String, symbolName: String) {
        queue.enqueue(Announcement(
            id: UUID(),
            text: line,
            priority: .briefing,
            sourceID: sourceID,
            card: AnnouncementCard(
                title: L10n.str("news.cardTitle", locale: locale),
                body: cardBody,
                symbolName: symbolName
            )
        ))
    }

    // MARK: - Observability (PII-free — counts and tags only)

    private static func outcomeTag(_ outcome: NewsDigestComposer.SourceResult.Outcome) -> String {
        switch outcome {
        case .ok: return "ok"
        case .empty: return "empty"
        case .failed: return "failed"
        }
    }

    private func emit(_ eventType: String, outcome: String = "success",
                      metadata: [String: String]) {
        observability.emit(ObservabilityEvent(
            component: "news_reader",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: metadata
        ))
    }
}
