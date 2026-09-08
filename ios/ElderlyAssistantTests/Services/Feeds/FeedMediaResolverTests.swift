import XCTest
@testable import ElderlyAssistant

/// Media resolver tests (feed-agent task, 2026-09-08) — MIME → kind,
/// preference order, thumbnail behavior, and URL resolution.
final class FeedMediaResolverTests: XCTestCase {

    private func enclosure(_ url: String, _ mime: String?,
                           thumbnailOnly: Bool = false) -> FeedMediaResolver.Enclosure {
        FeedMediaResolver.Enclosure(url: url, mimeType: mime,
                                    thumbnailOnly: thumbnailOnly)
    }

    // MARK: - MIME → kind

    func testMimePrefixMapping() {
        XCTAssertEqual(FeedMediaResolver.mimeKind("audio/mpeg"), .audio)
        XCTAssertEqual(FeedMediaResolver.mimeKind("AUDIO/MP3"), .audio)
        XCTAssertEqual(FeedMediaResolver.mimeKind("video/mp4"), .video)
        XCTAssertEqual(FeedMediaResolver.mimeKind("image/jpeg"), .image)
        XCTAssertEqual(FeedMediaResolver.mimeKind("image/svg+xml"), .image)
        XCTAssertNil(FeedMediaResolver.mimeKind("application/pdf"))
        XCTAssertNil(FeedMediaResolver.mimeKind(nil))
        XCTAssertNil(FeedMediaResolver.mimeKind(""))
    }

    // MARK: - Resolution

    func testNoEnclosuresResolveToTextWithNilURLs() {
        let resolved = FeedMediaResolver.resolve(enclosures: [])
        XCTAssertEqual(resolved.kind, .text)
        XCTAssertNil(resolved.mediaURL)
        XCTAssertNil(resolved.imageURL)
    }

    func testUnknownMimeEnclosureResolvesToText() {
        let resolved = FeedMediaResolver.resolve(
            enclosures: [enclosure("https://e.example.com/doc.pdf", "application/pdf")])
        XCTAssertEqual(resolved.kind, .text)
        XCTAssertNil(resolved.mediaURL)
    }

    func testAudioPreferredOverVideoPreferredOverImage() {
        let resolved = FeedMediaResolver.resolve(enclosures: [
            enclosure("https://e.example.com/p.jpg", "image/jpeg"),
            enclosure("https://e.example.com/v.mp4", "video/mp4"),
            enclosure("https://e.example.com/a.mp3", "audio/mpeg")
        ])
        XCTAssertEqual(resolved.kind, .audio)
        XCTAssertEqual(resolved.mediaURL, "https://e.example.com/a.mp3")
        XCTAssertEqual(resolved.imageURL, "https://e.example.com/p.jpg")
    }

    func testVideoPreferredOverImageWhenNoAudio() {
        let resolved = FeedMediaResolver.resolve(enclosures: [
            enclosure("https://e.example.com/p.jpg", "image/jpeg"),
            enclosure("https://e.example.com/v.mp4", "video/mp4")
        ])
        XCTAssertEqual(resolved.kind, .video)
        XCTAssertEqual(resolved.mediaURL, "https://e.example.com/v.mp4")
        XCTAssertEqual(resolved.imageURL, "https://e.example.com/p.jpg")
    }

    func testImageOnlyResolvesToImageWithImageURL() {
        let resolved = FeedMediaResolver.resolve(
            enclosures: [enclosure("https://e.example.com/p.jpg", "image/jpeg")])
        XCTAssertEqual(resolved.kind, .image)
        XCTAssertNil(resolved.mediaURL)
        XCTAssertEqual(resolved.imageURL, "https://e.example.com/p.jpg")
    }

    func testThumbnailOnlyNeverDecidesKind() {
        // The BBC shape pinned: a thumbnail must not flip a text item.
        let resolved = FeedMediaResolver.resolve(
            enclosures: [enclosure("https://e.example.com/t.jpg", nil,
                                   thumbnailOnly: true)])
        XCTAssertEqual(resolved.kind, .text)
        XCTAssertNil(resolved.mediaURL)
        XCTAssertEqual(resolved.imageURL, "https://e.example.com/t.jpg")
    }

    func testThumbnailFallsBackToFirstImageURLOnlyWhenNoRealImage() {
        let resolved = FeedMediaResolver.resolve(enclosures: [
            enclosure("https://e.example.com/a.mp3", "audio/mpeg"),
            enclosure("https://e.example.com/t.jpg", nil, thumbnailOnly: true)
        ])
        XCTAssertEqual(resolved.kind, .audio)
        XCTAssertEqual(resolved.imageURL, "https://e.example.com/t.jpg")
    }

    func testRealImageEnclosureWinsOverThumbnailForImageURL() {
        let resolved = FeedMediaResolver.resolve(enclosures: [
            enclosure("https://e.example.com/a.mp3", "audio/mpeg"),
            enclosure("https://e.example.com/t.jpg", nil, thumbnailOnly: true),
            enclosure("https://e.example.com/p.jpg", "image/jpeg")
        ])
        XCTAssertEqual(resolved.imageURL, "https://e.example.com/p.jpg")
    }

    func testEmptyURLEnclosureIsIgnored() {
        let resolved = FeedMediaResolver.resolve(
            enclosures: [enclosure("", "audio/mpeg")])
        XCTAssertEqual(resolved.kind, .text)
        XCTAssertNil(resolved.mediaURL)
    }
}
