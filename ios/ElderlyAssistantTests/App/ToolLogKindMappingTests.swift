import XCTest
@testable import ElderlyAssistant

/// Guards the tool-log review row's kind presentation ([SPOTIFY]
/// 2026-10-06, C-SP-14 / review finding C-4): the two exhaustive
/// `LocalToolLogEntry.Kind` switches in `ToolLogReviewView` (label key and
/// icon) must carry EVERY case with no default arm, and the new `spotify`
/// kind must map to the design-pinned key and glyph. Adding a kind fails
/// the build (exhaustiveness); moving an icon or a key fails here.
///
/// Tables are pinned verbatim — the `SettingsTabMappingTests` style — and
/// the keys are resolved through the real catalog in both languages so a
/// mapping that names a key nobody ships fails here instead of rendering
/// the raw identifier to a household.
final class ToolLogKindMappingTests: XCTestCase {

    typealias Kind = LocalToolLogEntry.Kind

    private let nepali = Locale(identifier: "ne-NP")
    private let english = Locale(identifier: "en-US")

    /// The full case set at this baseline — pinned so a new kind lands in
    /// this list deliberately (the build fails it out until both view
    /// switches are updated).
    private let allKinds: [Kind] = [.weather, .search, .youtube, .spotify]

    func testTheKindSetMatchesTheStorageContract() {
        XCTAssertEqual(allKinds.map(\.rawValue),
                       ["weather", "search", "youtube", "spotify"],
                       "the persisted kind strings are the stable storage/export contract")
    }

    func testEveryKindMapsToItsLabelKey() {
        XCTAssertEqual(ToolLogReviewView.kindLabelKey(for: .weather),
                       "toolLog.kind.weather")
        XCTAssertEqual(ToolLogReviewView.kindLabelKey(for: .search),
                       "toolLog.kind.search")
        XCTAssertEqual(ToolLogReviewView.kindLabelKey(for: .youtube),
                       "toolLog.kind.youtube")
        XCTAssertEqual(ToolLogReviewView.kindLabelKey(for: .spotify),
                       "toolLog.kind.spotify",
                       "the Spotify label key is pinned by design-l2 §21/§31")
    }

    func testEveryKindMapsToItsIcon() {
        XCTAssertEqual(ToolLogReviewView.kindIconName(for: .weather), "cloud.sun.fill")
        XCTAssertEqual(ToolLogReviewView.kindIconName(for: .search), "magnifyingglass")
        XCTAssertEqual(ToolLogReviewView.kindIconName(for: .youtube), "play.rectangle.fill")
        XCTAssertEqual(ToolLogReviewView.kindIconName(for: .spotify), "music.note",
                       "the Spotify row draws the app's own music glyph (the intent " +
                       "log's music icon) — C-4's icon switch")
    }

    func testEveryKindHasADistinctNonEmptyPresentation() {
        let keys = allKinds.map { ToolLogReviewView.kindLabelKey(for: $0) }
        let icons = allKinds.map { ToolLogReviewView.kindIconName(for: $0) }
        XCTAssertEqual(Set(keys).count, allKinds.count, "two kinds share a label key")
        XCTAssertEqual(Set(icons).count, allKinds.count, "two kinds share an icon")
        XCTAssertTrue(keys.allSatisfy { $0.hasPrefix("toolLog.kind.") },
                      "every kind's label must be a toolLog.kind.* catalog key")
        XCTAssertTrue(icons.allSatisfy { !$0.isEmpty },
                      "every kind must render an SF Symbol")
    }

    func testEveryKindLabelResolvesInBothLanguages() {
        // Same guard as SettingsTabMappingTests' row-title resolution: a
        // mapping key nobody ships renders the raw identifier — worst in
        // the Nepali locale. The catalog entries belong to C-SP-11; this
        // is the integration tripwire between the mapping and the catalog.
        for kind in allKinds {
            let key = ToolLogReviewView.kindLabelKey(for: kind)
            for locale in [english, nepali] {
                let value = L10n.str(key, locale: locale)
                XCTAssertNotEqual(value, key,
                                  "\(key) is unresolved in \(locale.identifier)")
            }
        }
    }
}
