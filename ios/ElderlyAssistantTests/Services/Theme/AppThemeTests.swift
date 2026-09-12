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

    /// The default preset is the VoiceBridge white app background.
    func testCreamMatchesDesignTokensBackground() {
        XCTAssertEqual(AppTheme.cream.background.red, 1.000, accuracy: 0.0005)
        XCTAssertEqual(AppTheme.cream.background.green, 1.000, accuracy: 0.0005)
        XCTAssertEqual(AppTheme.cream.background.blue, 1.000, accuracy: 0.0005)
    }

    // MARK: - Dusk contrast note
    //
    // `dusk` remains a muted light neutral. VoiceBridge navy text is used
    // on every theme, so this preset deliberately stays lighter than the
    // text instead of becoming a true dark mode.
    func testDuskIsLighterThanTextPrimary() {
        let textPrimary: (red: Double, green: Double, blue: Double) = (0.027, 0.106, 0.322)
        XCTAssertGreaterThan(luma(AppTheme.dusk.background), luma(textPrimary),
                             "dusk must stay lighter than VoiceBridge navy text")
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
