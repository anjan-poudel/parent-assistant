import Foundation

// MARK: - Feed image display URL (news-feed-images task, 2026-10-14)

/// Selection + validation of the ONE image URL a feed card or the
/// article reader may LOAD.
///
/// `FeedItem.imageURL` is whatever the feed published — an `<enclosure>`,
/// a `media:content`, or a `media:thumbnail` URL, stored verbatim by the
/// parser (which never fabricates). The display side therefore still has
/// to ask whether it is a URL this app is willing to fetch: an http(s)
/// URL with a real host. A relative reference, a `file:`/`javascript:`
/// string, or a stray whitespace fragment from the feed XML renders the
/// honest placeholder instead of a request.
///
/// Pure, so the rule is pinned by tests directly (the
/// `FeedMediaResolver` precedent). The three image surfaces — the text
/// card's thumbnail, the image card, and the reader — all resolve
/// through this one function, so none of them can ever load a URL the
/// others would refuse.
enum FeedImageURL {

    /// The loadable image URL for a stored reference, or nil when the
    /// reference is absent, empty, not a URL, not http(s), or hostless.
    static func displayURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }
}
