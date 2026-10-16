import XCTest
@testable import ElderlyAssistant

/// Copy tests for the feeds read-aloud affordances (feeds readaloud task,
/// 2026-09-19).
///
/// Every user-visible string the task adds lives in the string catalog
/// with BOTH shipped languages. `L10n.str` falls back to the KEY itself
/// when neither lproj carries it, so an unresolved key would put
/// "feeds.readFullArticle" on the card, in the elder's face. `ne` is
/// asserted to be Devanagari (never the English text copied across) and
/// to differ from `en` — the two properties a translation must have.
final class FeedReadAloudCopyTests: XCTestCase {

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    /// Every catalog key the read-aloud feature adds.
    private let keys = [
        "feeds.readFullArticle",   // the card's full-article button
        "feeds.summaryOnly",       // the honest caption when there is no body
        "feeds.unread",            // the unread badge
        "feeds.voice.noItems",     // voice: nothing in the feed
        "feeds.voice.summaryOnly"  // voice: this source shares only a summary
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
        // The exact strings the card and the voice speak. Pinned so a
        // drive-by edit is a deliberate act (en is the reviewed copy).
        XCTAssertEqual(L10n.str("feeds.readFullArticle", locale: en),
                       "Read full article")
        XCTAssertEqual(L10n.str("feeds.summaryOnly", locale: en),
                       "Only a summary is available for this item.")
        XCTAssertEqual(L10n.str("feeds.unread", locale: en), "New")
        XCTAssertEqual(L10n.str("feeds.voice.noItems", locale: en),
                       "There is nothing in your feed to read yet.")
        XCTAssertEqual(L10n.str("feeds.voice.summaryOnly", locale: en),
                       "This source shares only a summary. I will read that.")

        // The ne labels the elder actually sees for the two affordances
        // the task adds — Devanagari, and the full-article label says
        // "पूरा" (whole), which is the offering.
        XCTAssertTrue(L10n.str("feeds.readFullArticle", locale: ne).contains("पूरा"))
        XCTAssertTrue(L10n.str("feeds.summaryOnly", locale: ne).contains("सारांश"))
        XCTAssertTrue(L10n.str("feeds.unread", locale: ne).contains("नयाँ"))
    }

    func testVoiceLinesCarryNoUnresolvedPlaceholders() {
        // A voice line is read verbatim by TTS — a stray "%@" would be
        // spoken. None of these keys takes an argument.
        for key in ["feeds.voice.noItems", "feeds.voice.summaryOnly"] {
            for locale in [en, ne] {
                let value = L10n.str(key, locale: locale)
                XCTAssertFalse(value.contains("%@"), "\(key) [\(locale.identifier)]")
                XCTAssertFalse(value.contains("{"),
                               "\(key) [\(locale.identifier)] carries a placeholder")
            }
        }
    }
}
