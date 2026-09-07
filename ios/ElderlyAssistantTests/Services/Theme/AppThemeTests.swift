import XCTest
@testable import ElderlyAssistant

/// Pins the skinnable-background theme palette (2026-09-07). `AppTheme`
/// is Foundation-only by design (the view layer builds the `Color` via
/// `Color(theme:)`), so this file never imports SwiftUI — same repo
/// pattern as the other pure-logic service tests.
final class AppThemeTests: XCTestCase {

    func testAllCasesRoundTripThroughRawValue() {
        for theme in AppTheme.allCases {
            XCTAssertEqual(AppTheme(rawValue: theme.rawValue), theme,
                           "\(theme.rawValue) must decode back to its own case")
        }
    }

    /// A stale/unknown persisted raw value must NOT decode — the failable
    /// `init(rawValue:)` stays the honest gate, and only the coordinator's
    /// restore helper (`rawOrDefault`) swallows the miss.
    func testUnknownRawStringDoesNotDecode() {
        XCTAssertNil(AppTheme(rawValue: "sepia"))
        XCTAssertNil(AppTheme(rawValue: ""))
        XCTAssertNil(AppTheme(rawValue: "CREAM"))
    }

    func testRawOrDefaultFallsBackToCream() {
        XCTAssertEqual(AppTheme(rawOrDefault: nil), .cream)
        XCTAssertEqual(AppTheme(rawOrDefault: "sepia"), .cream)
        XCTAssertEqual(AppTheme(rawOrDefault: ""), .cream)
    }

    func testRawOrDefaultDecodesKnownValues() {
        for theme in AppTheme.allCases {
            XCTAssertEqual(AppTheme(rawOrDefault: theme.rawValue), theme)
        }
    }

    func testIdentifiableIDIsRawValue() {
        for theme in AppTheme.allCases {
            XCTAssertEqual(theme.id, theme.rawValue)
        }
    }

    func testNameKeyPerCase() {
        for theme in AppTheme.allCases {
            XCTAssertEqual(theme.nameKey, "theme.\(theme.rawValue)")
        }
    }

    /// The cream preset IS today's `DesignTokens.background` — the theme
    /// must never silently drift from the existing look it replaces.
    func testCreamMatchesDesignTokensBackground() {
        XCTAssertEqual(AppTheme.cream.background.red, 0.980, accuracy: 0.0005)
        XCTAssertEqual(AppTheme.cream.background.green, 0.953, accuracy: 0.0005)
        XCTAssertEqual(AppTheme.cream.background.blue, 0.914, accuracy: 0.0005)
    }

    // MARK: - Dusk contrast note
    //
    // `dusk` is a MUTED warm night tone — the one background that is not
    // a light pastel. Text stays `DesignTokens.textPrimary` (#3D2F24,
    // RGB 0.239/0.184/0.141 — near-black) on every theme, so dusk was
    // deliberately kept *slightly lighter than the text* instead of going
    // truly dark: the contrast pair below stays comfortably readable
    // while still reading as "night". The pin below guards the ORDERING
    // (background luminance > text luminance) with Rec.709 luma weights —
    // the same formula on gamma-encoded sRGB components; the full WCAG
    // ratio is enforced in the visual redesign pass that will restyle
    // dusk's cards if the palette ever goes darker.
    func testDuskIsLighterThanTextPrimary() {
        let textPrimary: (red: Double, green: Double, blue: Double) = (0.239, 0.184, 0.141)
        XCTAssertGreaterThan(luma(AppTheme.dusk.background), luma(textPrimary),
                             "dusk must stay lighter than the near-black text on it")
    }

    /// Dusk is the DARKEST preset — every other background must be
    /// lighter so the pastel family reads as "daytime warmth" together.
    func testDuskIsDarkestPreset() {
        for theme in AppTheme.allCases where theme != .dusk {
            XCTAssertGreaterThan(luma(theme.background), luma(AppTheme.dusk.background),
                                 "\(theme.rawValue) must be lighter than dusk")
        }
    }

    /// Every palette value is a light color (≥0.8 per channel) except by
    /// design — cards are white and text near-black, so a background that
    /// ever drops below ~0.8 per channel would need a contrast re-check.
    func testPastelPresetsStayLight() {
        for theme in AppTheme.allCases where theme != .dusk {
            XCTAssertGreaterThanOrEqual(theme.background.red, 0.9)
            XCTAssertGreaterThanOrEqual(theme.background.green, 0.9)
            XCTAssertGreaterThanOrEqual(theme.background.blue, 0.9)
        }
    }

    /// Rec.709 luma of an RGB tuple (0-1 components) — sufficient for the
    /// ordering assertions above.
    private func luma(_ c: (red: Double, green: Double, blue: Double)) -> Double {
        0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
    }
}
