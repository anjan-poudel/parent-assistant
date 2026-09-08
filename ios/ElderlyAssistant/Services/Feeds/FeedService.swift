import Foundation

// MARK: - Feed service (feed-agent task, 2026-09-08)

/// The fetch-and-compose pipeline behind the Feed screen:
///
/// 1. BOUNDED: per-source timeout (`fetchTimeout`), per-source item cap
///    (`maxItemsPerSource`, enforced in the parser), total cap
///    (`FeedComposer`), source count cap (`FeedSettingsStore.maxSources`).
/// 2. TTL CACHE: `refresh` serves the last good items without touching
///    the network while they are younger than `cacheTTL` — refresh-on-
///    appear (the leaf's `.task`) therefore re-fetches at most every
///    fifteen minutes.
/// 3. FAILURE ISOLATION: one dead source never blanks the feed — its
///    name lands in `failedSourceNames` (honestly surfaced by the leaf)
///    and every other source's items still compose.
/// 4. STALE-GRACE: when EVERY source fails but a cache exists, the stale
///    items are returned with the failure list — showing slightly old
///    content + "couldn't refresh" is more honest than pretending the
///    feed is empty.
/// 5. PII-FREE LOGGING: observability events carry hostnames and counts
///    only — never titles, summaries, or full URLs.

/// One refresh's outcome — everything the leaf needs to render honestly.
struct FeedRefreshResult: Equatable {
    let items: [FeedItem]
    /// Display NAMES of the sources that failed this refresh.
    let failedSourceNames: [String]
    /// True when `items` came from the TTL cache (no fetch happened).
    let fromCache: Bool
}

final class FeedService {

    /// Cache freshness window (refresh-on-appear does no network inside
    /// this window).
    static let cacheTTL: TimeInterval = 15 * 60
    /// Hard per-source timeout.
    static let fetchTimeout: TimeInterval = 15
    /// Per-source item cap (enforced by the parser).
    static let maxItemsPerSource = 20

    private let settings: FeedSettingsStore
    private let transport: FeedTransport
    private let observability: ObservabilityBus

    /// Last good composed items + when they were fetched. In-memory only:
    /// feed items are transient third-party content, not user data —
    /// they are never persisted (nothing about the user is in them, and
    /// a cold launch re-fetches).
    private var cachedItems: [FeedItem] = []
    private var cachedAt: Date?

    init(settings: FeedSettingsStore,
         transport: FeedTransport,
         observability: ObservabilityBus) {
        self.settings = settings
        self.transport = transport
        self.observability = observability
    }

    /// Fetches and composes the feed (or serves the cache — see the type
    /// docs). Thread-safe enough for the app's single-refresh-at-a-time
    /// usage: the coordinator guards against concurrent refreshes.
    func refresh(now: Date = Date()) async -> FeedRefreshResult {
        // TTL gate: fresh cache, no network at all.
        if let cachedAt, now.timeIntervalSince(cachedAt) < Self.cacheTTL {
            return FeedRefreshResult(items: cachedItems,
                                     failedSourceNames: [],
                                     fromCache: true)
        }

        let config = settings.load()
        var collected: [FeedItem] = []
        var failures: [String] = []

        for source in config.sources {
            // Legacy/payload guard — sources are validated at add time,
            // but a hand-edited payload must never crash the refresh.
            guard let url = URL(string: source.urlString) else {
                failures.append(source.name)
                continue
            }
            do {
                let (data, _) = try await transport.fetchFeedData(
                    from: url, timeout: Self.fetchTimeout)
                let parsed = FeedRSSParser.parse(data: data,
                                                 sourceName: source.name,
                                                 maxItems: Self.maxItemsPerSource)
                let matching = parsed.filter {
                    FeedTopicFilter.matches($0, topics: config.topics)
                }
                collected.append(contentsOf: matching)
                emit(source: source, outcome: "success",
                     entryCount: matching.count)
            } catch {
                failures.append(source.name)
                emit(source: source, outcome: "failure", entryCount: nil)
            }
        }

        let items = FeedComposer.compose(collected)
        if !collected.isEmpty {
            cachedItems = items
            cachedAt = now
        }

        // Stale-grace: everything failed but we have something to show.
        if items.isEmpty, !cachedItems.isEmpty {
            return FeedRefreshResult(items: cachedItems,
                                     failedSourceNames: failures,
                                     fromCache: true)
        }
        return FeedRefreshResult(items: items,
                                 failedSourceNames: failures,
                                 fromCache: false)
    }

    // MARK: - Observability (PII-free: hostname + counts only)

    private func emit(source: FeedSource, outcome: String, entryCount: Int?) {
        var metadata = ["host": Self.host(of: source.urlString)]
        if let entryCount {
            metadata["entry_count"] = String(entryCount)
        }
        observability.emit(ObservabilityEvent(
            component: "feed",
            eventType: "feed.fetch_source",
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: metadata
        ))
    }

    /// The source URL's host only — the PII-free logging contract (a
    /// configured feed URL may embed a personal token; only the hostname
    /// is ever logged).
    static func host(of urlString: String) -> String {
        URL(string: urlString)?.host ?? ""
    }
}
