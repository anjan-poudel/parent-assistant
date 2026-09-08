import Foundation

// MARK: - Enclosure → kind/URL resolution (feed-agent task, 2026-09-08)

/// Pure mapping from an item's enclosure list to its display kind and
/// playable/image URLs. Kept free of XML knowledge so the parser hands it
/// plain `Enclosure` values and the tests pin the resolution rules
/// directly.
enum FeedMediaResolver {

    /// One media reference found in a feed item: an RSS `<enclosure>`,
    /// a media-namespace `<media:content>`/`<media:thumbnail>`, or an
    /// Atom `<link rel="enclosure">`.
    struct Enclosure: Equatable {
        let url: String
        /// The MIME type as published (may be missing — some feeds omit
        /// it). Resolution treats a missing type as "unknown".
        let mimeType: String?
        /// True for `media:thumbnail`-style references: image URL
        /// candidates that must NEVER decide the item's kind — a
        /// thumbnail on a text story is still a text story (BBC items
        /// all carry one; turning every news article into an image card
        /// would bury the read-aloud action).
        let thumbnailOnly: Bool

        init(url: String, mimeType: String?, thumbnailOnly: Bool = false) {
            self.url = url
            self.mimeType = mimeType
            self.thumbnailOnly = thumbnailOnly
        }
    }

    /// MIME type → item kind. Prefix rules only (spec: image/*, audio/*,
    /// video/*); nil for anything else (or nothing).
    static func mimeKind(_ mimeType: String?) -> FeedItemKind? {
        guard let mime = mimeType?.lowercased(), !mime.isEmpty else { return nil }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("image/") { return .image }
        return nil
    }

    /// Resolves the item's kind and URLs from its enclosures.
    ///
    /// Preference over KIND-BEARING enclosures only: the FIRST audio
    /// wins (a podcast episode with a splash image IS an audio item);
    /// else first video; else first image; else `.text`. `imageURL`
    /// carries the first image-type URL whatever the kind — an
    /// audio/video item keeps its thumbnail for the card — and falls
    /// back to a `thumbnailOnly` reference when no real image enclosure
    /// exists. `mediaURL` is the chosen audio/video stream (nil for
    /// image/text items — those have nothing to play).
    static func resolve(enclosures: [Enclosure])
        -> (kind: FeedItemKind, mediaURL: String?, imageURL: String?) {
        let typed: [(kind: FeedItemKind, url: String)] = enclosures.compactMap { enclosure in
            guard !enclosure.thumbnailOnly,
                  let kind = mimeKind(enclosure.mimeType),
                  !enclosure.url.isEmpty else {
                return nil
            }
            return (kind, enclosure.url)
        }

        let kind: FeedItemKind
        let mediaURL: String?
        if let audio = typed.first(where: { $0.kind == .audio }) {
            kind = .audio
            mediaURL = audio.url
        } else if let video = typed.first(where: { $0.kind == .video }) {
            kind = .video
            mediaURL = video.url
        } else if typed.first(where: { $0.kind == .image }) != nil {
            kind = .image
            mediaURL = nil
        } else {
            kind = .text
            mediaURL = nil
        }

        let imageURL = typed.first(where: { $0.kind == .image })?.url
            ?? enclosures.first(where: { $0.thumbnailOnly && !$0.url.isEmpty })?.url
        return (kind, mediaURL, imageURL)
    }
}
