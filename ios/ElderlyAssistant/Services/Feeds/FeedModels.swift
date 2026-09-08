import Foundation

// MARK: - Feed agent models (feed-agent task, 2026-09-08)

/// The display/playback kind of one feed item, resolved from the item's
/// RSS/Atom enclosures (spec: image/*, audio/*, video/* MIME types).
/// `.text` is the fallback for enclosure-less items.
enum FeedItemKind: String, Codable, Equatable {
    case text
    case image
    case audio
    case video
}

/// One item on the Feed screen — the social-feed card's data.
///
/// `id` is a stable per-item string (the feed's guid, else the item link,
/// else a source+title fallback) — stable enough to dedupe within a
/// refresh and to key SwiftUI rows, but NOT a cross-fetch contract:
/// every refresh re-parses the sources, so an id collision across days is
/// harmless (the composer only dedupes within one refresh).
struct FeedItem: Identifiable, Equatable, Codable {
    let id: String
    /// The item title — plain text, entities already decoded by the
    /// parser. May carry residual markup in `summary` (sanitized at
    /// render/speech time — see `FeedSpeechSanitizer`).
    let title: String
    let summary: String
    let kind: FeedItemKind
    /// Feed publication date; nil when the source publishes none.
    let publishedAt: Date?
    /// The item's canonical web link (RSS link / Atom alternate link).
    let linkURL: String
    /// Any image-type enclosure URL (thumbnail/photo) — nil when none.
    let imageURL: String?
    /// The audio/video stream URL — non-nil only for `.audio`/`.video`.
    let mediaURL: String?
    /// The configured source name this item came from (rendered on the
    /// card caption, exactly as the user named the source).
    let sourceName: String
}

/// One configured feed source (RSS/Atom URL). Curated defaults ship
/// pre-seeded; user-added sources are identical in behaviour.
struct FeedSource: Identifiable, Equatable, Codable {
    /// Stable identity for removal/deduping within the config store.
    /// Curated defaults carry fixed ids ("default.*") so a re-seed can
    /// never duplicate them.
    let id: String
    var name: String
    var urlString: String
    /// True for the shipped curated defaults — the Settings leaf shows
    /// these with a "default" tag, but the user can remove them like any
    /// other source (their config, their choice).
    var isCuratedDefault: Bool
}

/// The whole persisted feed configuration (sources + topic keywords).
struct FeedConfig: Codable, Equatable {
    var sources: [FeedSource]
    var topics: [String]

    static let empty = FeedConfig(sources: [], topics: [])
}

/// The Feed leaf's load state, published by the coordinator and driven
/// by `FeedService.refresh`.
enum FeedLoadState: Equatable {
    /// Never fetched this launch (the leaf's first `.task` flips it).
    case idle
    /// A refresh is in flight.
    case loading
    /// A refresh finished and produced items (possibly zero — an honest
    /// empty feed is `.loaded`, not an error).
    case loaded
    /// A refresh finished with NO items AND at least one source failure.
    case failed
}
