import Foundation

// MARK: - Feed composition (feed-agent task, 2026-09-08)

/// Pure ordering/dedup/capping of the merged, per-source item lists —
/// unit-testable without any network or storage.
///
/// Contract:
/// - NEWEST FIRST by `publishedAt` (stable within equal dates — input
///   order is preserved, so source order stays the tie-breaker).
/// - Items WITHOUT a published date sort AFTER all dated items: the feed
///   never claims an unknown date is new (honesty rule — "no date" is
///   not "now").
/// - Deduped by `id` within the refresh (first occurrence wins).
/// - Capped at `maxTotal` — the fetch is bounded end to end
///   (per-source cap in the parser, total cap here).
enum FeedComposer {

    static let defaultMaxTotal = 100

    static func compose(_ items: [FeedItem],
                        maxTotal: Int = defaultMaxTotal) -> [FeedItem] {
        var seen = Set<String>()
        var unique: [FeedItem] = []
        unique.reserveCapacity(items.count)
        for item in items where !seen.contains(item.id) {
            seen.insert(item.id)
            unique.append(item)
        }

        let dated = unique.filter { $0.publishedAt != nil }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        let undated = unique.filter { $0.publishedAt == nil }

        return Array((dated + undated).prefix(maxTotal))
    }
}
