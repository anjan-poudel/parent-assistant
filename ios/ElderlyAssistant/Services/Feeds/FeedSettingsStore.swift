import Foundation

// MARK: - Feed configuration store (feed-agent task, 2026-09-08)

/// Encrypted persistence for the feed configuration (sources + topic
/// keywords) — constitution §Security: config lives in
/// `EncryptedLocalStorage` (Keychain, Data Protection Complete), exactly
/// like `FamilyContactStore`/`SavedPlaceStore`. Sources and topics are
/// the user's reading interests; plaintext UserDefaults is not the bar
/// this app holds its other stores to.
///
/// Seeding: the FIRST ever read stores the curated defaults; after that
/// the user's config is authoritative — removing every default (or every
/// source) persists, and a later read must NOT re-seed over the user's
/// choices.
final class FeedSettingsStore {

    static let storageKey = "feeds.config.v1"
    /// Bounded configuration: the feed fetches a bounded number of
    /// sources — this is the user-facing cap.
    static let maxSources = 10
    static let maxTopics = 20

    /// Curated defaults (verified reachable over HTTPS, 2026-09-08):
    /// English world news (thumbnails), Nepali news (text, Devanagari),
    /// NPR audio stories (audio enclosures), and NASA's image-of-the-day
    /// picture feed — one default per feed KIND so the mixed feed shows
    /// its whole range out of the box. Names are the services' own brand
    /// names (content data, like contact names — not UI chrome).
    static let curatedDefaults: [FeedSource] = [
        FeedSource(id: "default.bbc-world",
                   name: "BBC World",
                   urlString: "https://feeds.bbci.co.uk/news/world/rss.xml",
                   isCuratedDefault: true),
        FeedSource(id: "default.bbc-nepali",
                   name: "BBC नेपाली",
                   urlString: "https://feeds.bbci.co.uk/nepali/rss.xml",
                   isCuratedDefault: true),
        FeedSource(id: "default.npr",
                   name: "NPR News",
                   urlString: "https://feeds.npr.org/1001/rss.xml",
                   isCuratedDefault: true),
        FeedSource(id: "default.nasa-iotd",
                   name: "NASA Image of the Day",
                   urlString: "https://www.nasa.gov/feeds/iotd-feed/",
                   isCuratedDefault: true)
    ]

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    /// The stored config; seeds the curated defaults on the first ever
    /// read (see the type docs — never re-seeds over user edits).
    func load() -> FeedConfig {
        if case .success(let config) = storage.read(key: Self.storageKey,
                                                    type: FeedConfig.self) {
            return config
        }
        let seeded = FeedConfig(sources: Self.curatedDefaults, topics: [])
        // Best-effort seed write — a failed write still returns the
        // seeded config (the next mutation re-persists whatever exists).
        _ = storage.write(key: Self.storageKey, value: seeded)
        return seeded
    }

    // MARK: - Source CRUD

    /// Adds a user source. False (nothing stored, nothing claimed) when
    /// the name/URL are empty, the URL is not a valid http(s) feed URL,
    /// the URL is already configured, or the source cap is reached.
    @discardableResult
    func addSource(name: String, urlString: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = load()
        guard !trimmedName.isEmpty,
              !trimmedURL.isEmpty,
              Self.isValidFeedURL(trimmedURL),
              config.sources.count < Self.maxSources,
              !config.sources.contains(where: { $0.urlString == trimmedURL }) else {
            return false
        }
        config.sources.append(FeedSource(id: UUID().uuidString,
                                         name: trimmedName,
                                         urlString: trimmedURL,
                                         isCuratedDefault: false))
        return save(config)
    }

    @discardableResult
    func removeSource(id: String) -> Bool {
        var config = load()
        config.sources.removeAll { $0.id == id }
        return save(config)
    }

    // MARK: - Topic CRUD

    /// Adds a topic keyword. False when empty, already present
    /// (case-insensitive), or the topic cap is reached.
    @discardableResult
    func addTopic(_ topic: String) -> Bool {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = load()
        guard !trimmed.isEmpty,
              config.topics.count < Self.maxTopics,
              !config.topics.contains(where: {
                  $0.caseInsensitiveCompare(trimmed) == .orderedSame
              }) else {
            return false
        }
        config.topics.append(trimmed)
        return save(config)
    }

    @discardableResult
    func removeTopic(_ topic: String) -> Bool {
        var config = load()
        config.topics.removeAll { $0 == topic }
        return save(config)
    }

    // MARK: - URL validation (shared with the Settings add form)

    /// A feed URL must parse and carry an http(s) scheme with a host —
    /// the constitution's TLS rule (https preferred) plus "this is a
    /// reachable feed address" sanity. No head-request: validity here is
    /// syntactic; reachability is the fetch's own honest failure state.
    static func isValidFeedURL(_ string: String) -> Bool {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else {
            return false
        }
        return true
    }

    private func save(_ config: FeedConfig) -> Bool {
        switch storage.write(key: Self.storageKey, value: config) {
        case .success: return true
        case .failure: return false
        }
    }
}

// MARK: - Source name suggestion (feed-agent task, 2026-09-08)

/// Derives a display name from a pasted feed URL — the Settings add form
/// has ONE field (senior-friendly), so the name comes from the URL's
/// host with common feed prefixes stripped and the first label
/// capitalized ("feeds.bbci.co.uk" → "Bbci.co.uk"). Pure and pinned.
enum FeedSourceNameSuggester {
    static func name(from urlString: String) -> String {
        guard let host = URL(string: urlString)?.host, !host.isEmpty else { return "" }
        let cleaned = host
            .replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: "feeds.", with: "")
        guard let first = cleaned.first else { return cleaned }
        return String(first).uppercased() + cleaned.dropFirst()
    }
}
