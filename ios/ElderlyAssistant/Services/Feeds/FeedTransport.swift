import Foundation

// MARK: - Feed network seam (feed-agent task, 2026-09-08)

/// Network seam for feed fetching, mirroring `LocalToolTransport`
/// (Services/Voice): tests inject a stub transport and `FeedService`
/// never touches `URLSession` directly. Named `fetchFeedData` (not
/// `data(for:)`) so the URLSession extension cannot collide with the
/// house transport extensions.
protocol FeedTransport {
    func fetchFeedData(from url: URL, timeout: TimeInterval) async throws
        -> (Data, URLResponse)
}

extension URLSession: FeedTransport {
    func fetchFeedData(from url: URL, timeout: TimeInterval) async throws
        -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        // Bounded fetch (spec): every source gets the same hard timeout.
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadRevalidatingCacheData
        return try await data(for: request)
    }
}
