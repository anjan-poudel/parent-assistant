import Foundation

/// One news feed the news reader digest can read (news-reader feature,
/// 2026-09-08). Configurable per source by a family member via Settings →
/// Feeds (built by the feeds-settings agent) — the elderly primary user is
/// never asked to type URLs.
struct NewsSource: Codable, Equatable, Identifiable {
    let id: UUID
    /// Display name spoken in the digest's source line ("From BBC World:").
    /// Keep it short and plain — it goes straight into TTS.
    var name: String
    /// The feed's URL, stored as a string so an invalid-but-preserved
    /// entry still round-trips (the Settings editor can show it for
    /// repair instead of silently losing it).
    var urlString: String
    /// Informational language tag of the feed's content ("en" / "ne").
    /// Used by the settings editor for grouping; the digest itself speaks
    /// headlines verbatim and orders sources in configured order.
    var languageCode: String

    init(id: UUID = UUID(), name: String, urlString: String, languageCode: String) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.languageCode = languageCode
    }

    var url: URL? { URL(string: urlString) }

    /// A source worth fetching: parseable URL and a non-blank name.
    var isValid: Bool {
        url != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Persisted list of user-configured news sources + the curated defaults
/// (news-reader feature, 2026-09-08) — `SearchConfigStore`-style store over
/// `EncryptedLocalStorage` (Keychain, Data Protection Complete — the list is
/// household configuration, so plaintext UserDefaults is NOT acceptable;
/// constitution §Security).
///
/// SOURCE RESOLUTION RULE (pinned, tested): configured sources REPLACE the
/// defaults. `effectiveSources` is exactly `configuredSources` whenever at
/// least one source is configured — "when the user has configured sources,
/// those are the news" — and the curated defaults only while the
/// configured list is empty. This keeps the digest predictable for the
/// elderly user (one mental model: what the family saved is what is read)
/// and avoids surprising mixed-language merges.
///
/// SEAM FOR THE FEEDS-SETTINGS AGENT (Settings → Feeds editor): this store
/// is the whole API the editor needs.
///  - `configuredSources` — @Published, bind directly to a List.
///  - `add(_:)` / `remove(id:)` / `save(_:)` — write-through mutations
///    returning Bool so the editor can show an honest failure line
///    (persist-first: memory changes only when the Keychain write
///    succeeded).
///  - `clear()` — reset to the defaults ("use built-in sources").
///  - `defaults` — the curated list, for the editor's "restore"
///    affordance and for showing what built-ins exist.
final class NewsSourceStore: ObservableObject {

    /// Keychain key for the configured-source list (one JSON array —
    /// the storage protocol offers no enumeration, so one key holds the
    /// whole list, same shape as `LocalToolLogStore`).
    static let storageKey = "news.sources"

    /// Curated DEFAULT sources (news-reader feature, 2026-09-08), mixed
    /// English + Nepali, all verified live on 2026-09-08 (HTTP 200, well-
    /// formed XML): BBC World, NPR News, The Guardian World (English);
    /// Online Khabar, Ratopati, Setopati (Nepali).
    ///
    /// Kantipur (ekantipur.com) was requested as a default but publishes
    /// NO public RSS endpoint as of 2026-09-08 — /feed and /rss both 404.
    /// Rather than ship a fabricated URL, the two Kantipur-region Nepali
    /// portals with real feeds stand in (Ratopati, Setopati). When
    /// ekantipur restores a feed, add it here or via Settings → Feeds.
    ///
    /// Feed shapes vary on purpose: BBC titles arrive in CDATA, Ratopati
    /// titles carry raw HTML entities — both are fixtures in
    /// NewsFeedParserTests / NewsDigestComposerTests.
    static let defaults: [NewsSource] = [
        NewsSource(name: "BBC World",
                   urlString: "https://feeds.bbci.co.uk/news/world/rss.xml",
                   languageCode: "en"),
        NewsSource(name: "NPR News",
                   urlString: "https://feeds.npr.org/1001/rss.xml",
                   languageCode: "en"),
        NewsSource(name: "The Guardian",
                   urlString: "https://www.theguardian.com/world/rss",
                   languageCode: "en"),
        NewsSource(name: "Online Khabar",
                   urlString: "https://www.onlinekhabar.com/feed",
                   languageCode: "ne"),
        NewsSource(name: "Ratopati",
                   urlString: "https://ratopati.com/feed",
                   languageCode: "ne"),
        NewsSource(name: "Setopati",
                   urlString: "https://www.setopati.com/feed",
                   languageCode: "ne")
    ]

    /// The user's configured sources, in the order the family saved them
    /// (the digest reads in this order). Empty means "not configured —
    /// use the defaults".
    @Published private(set) var configuredSources: [NewsSource] = []

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
        if case .success(let stored) = storage.read(key: Self.storageKey,
                                                     type: [NewsSource].self) {
            configuredSources = stored
        }
    }

    /// The sources the digest actually reads — the REPLACE rule: the
    /// configured list when non-empty, else the curated defaults.
    var effectiveSources: [NewsSource] {
        configuredSources.isEmpty ? Self.defaults : configuredSources
    }

    /// The configured list, for consumers that must NOT see defaults
    /// (the settings editor).
    func list() -> [NewsSource] { configuredSources }

    /// Adds one source (write-through). False when the Keychain write
    /// failed — the in-memory list is then unchanged (persist-first).
    @discardableResult
    func add(_ source: NewsSource) -> Bool {
        save(configuredSources + [source])
    }

    /// Removes the source with `id`. False when there is nothing to
    /// remove or the write failed.
    @discardableResult
    func remove(id: UUID) -> Bool {
        guard configuredSources.contains(where: { $0.id == id }) else { return false }
        return save(configuredSources.filter { $0.id != id })
    }

    /// Replaces the whole configured list (the editor's save-on-dismiss).
    /// Persist-first: memory is updated only when the write succeeded,
    /// so `@Published` observers never see state that is not on disk.
    @discardableResult
    func save(_ sources: [NewsSource]) -> Bool {
        switch storage.write(key: Self.storageKey, value: sources) {
        case .success:
            configuredSources = sources
            return true
        case .failure:
            return false
        }
    }

    /// Clears the configured list — `effectiveSources` falls back to the
    /// defaults ("use built-in sources"). False on write failure; a
    /// missing item deletes cleanly by the storage contract.
    @discardableResult
    func clear() -> Bool {
        guard case .success = storage.delete(key: Self.storageKey) else {
            return false
        }
        configuredSources = []
        return true
    }
}
