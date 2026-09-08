import Foundation

/// [LOCAL-TOOLS] (2026-09-07) Network seam for the on-device-stack tools
/// (`WeatherTool`, `SearchTool`) — and the [NEWS-READER] (2026-09-08)
/// `NewsReader`, whose per-source fetches ride the same bounded-fetch
/// seam — mirroring `GeminiTransport` in `GeminiClient.swift`: tests
/// inject a stub transport and the tool code never touches `URLSession`
/// directly.
///
/// Named `fetchData` — NOT `send` like `GeminiTransport` — because the
/// two extensions would otherwise declare two identical `send(_:)`
/// members on `URLSession` (invalid redeclaration).
protocol LocalToolTransport {
    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: LocalToolTransport {
    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}
