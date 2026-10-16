import XCTest
@testable import ElderlyAssistant

/// Copy tests for the article reader (news-feed-images task, 2026-10-14).
///
/// The reader adds exactly ONE user-visible key — its leaf title — and
/// REUSES the card's three read-aloud keys (`feeds.readFullArticle`,
/// `feeds.readAloud`, `feeds.summaryOnly`), so both surfaces say the
/// same words about the same state. `L10n.str` falls back to the KEY
/// itself on a miss, so an unresolved key would put
/// "feeds.readerTitle" on the screen, in the elder's face. This suite
/// makes "the key resolves" a checked claim for the added key and the
/// reused set, in both shipped languages.
final class FeedReaderCopyTests: XCTestCase {

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    /// The one added key, plus the reused card keys the reader renders —
    /// if any of the reused four fell out of the catalog, the reader
    /// would show the raw key.
    private let keys = [
        "feeds.readerTitle",     // the reader leaf's title (added)
        "feeds.readFullArticle", // reused: the body-read button's label
        "feeds.readAloud",       // reused: the summary-only button's label
        "feeds.summaryOnly",     // reused: the honest no-body caption
    ]

    private func isDevanagari(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x0900...0x097F).contains($0.value)
        }
    }

    func testEveryKeyResolvesInBothLanguages() {
        for key in keys {
            let enValue = L10n.str(key, locale: en)
            XCTAssertNotEqual(enValue, key,
                              "\(key) is missing from the catalog (en)")
            XCTAssertFalse(enValue.isEmpty, "\(key) resolves to an empty en value")

            let neValue = L10n.str(key, locale: ne)
            XCTAssertNotEqual(neValue, key,
                              "\(key) is missing from the catalog (ne)")
            XCTAssertFalse(neValue.isEmpty, "\(key) resolves to an empty ne value")
            XCTAssertNotEqual(neValue, enValue,
                              "\(key) must be TRANSLATED for ne, not copied")
            XCTAssertTrue(isDevanagari(neValue),
                          "\(key) ne value must be Devanagari: \(neValue)")
        }
    }

    func testPinnedCopy() {
        // The exact strings the reader's title bar shows. Pinned so a
        // drive-by edit is a deliberate act; the ne title carries the
        // same "पूरा" (whole) promise the full-article button makes.
        XCTAssertEqual(L10n.str("feeds.readerTitle", locale: en), "Full article")
        XCTAssertEqual(L10n.str("feeds.readerTitle", locale: ne), "पूरा लेख")
    }
}
