import SwiftUI
import XCTest
@testable import ElderlyAssistant

/// Accessibility floors are enforced at the token level (spec §8): any
/// view consuming `DesignTokens` inherits them, and this test makes sure
/// nobody quietly lowers a floor.
final class DesignTokensTests: XCTestCase {

    func testBodyTextFloor() {
        XCTAssertGreaterThanOrEqual(DesignTokens.minBodyPointSize, 18)
    }

    func testCaptionTextFloor() {
        XCTAssertGreaterThanOrEqual(DesignTokens.minCaptionPointSize, 15)
    }

    func testTapTargetFloor() {
        XCTAssertGreaterThanOrEqual(DesignTokens.minTapTargetSize, 44)
    }

    func testTalkButtonIsAtLeast120pt() {
        XCTAssertGreaterThanOrEqual(DesignTokens.talkButtonDiameter, 120)
    }

    /// Redesign 2026-09-03: the 2×2 hub grid became the bottom dock — its
    /// items rely on `minTapTargetSize` directly (see `HomeView.dockItem`),
    /// so this covers what `hubCardMinHeight` used to: the dock itself
    /// stays tall enough to comfortably hold a ≥44pt tap target per item.
    func testDockIsAtLeastTapTargetTall() {
        XCTAssertGreaterThanOrEqual(DesignTokens.dockHeight, DesignTokens.minTapTargetSize)
    }

    func testConfirmationChipsAreAtLeast60ptTall() {
        XCTAssertGreaterThanOrEqual(DesignTokens.chipHeight, 60)
    }

    /// Hold-to-reset duration (TALK-CRASH-FIX, 2026-09-07) stays in the
    /// intended band: comfortably past accidental holds (<0.5s), well
    /// within the "a few seconds" the feature asked for, and never so
    /// long that the progress ring's wait feels like a dead button.
    func testTalkResetHoldIsWithinTheIntendedBand() {
        XCTAssertGreaterThanOrEqual(DesignTokens.talkResetHoldSeconds, 1.0)
        XCTAssertLessThanOrEqual(DesignTokens.talkResetHoldSeconds, 3.5)
    }
}

// MARK: - Voice-state palette
//
// The hero renders white glyphs on each state fill. These checks preserve
// contrast after the VoiceBridge rebrand while semantic state colours stay
// independent from the magenta/coral identity palette.

private extension DesignTokensTests {
    struct RGBA: Equatable { let r: Double; let g: Double; let b: Double }

    func sRGB(_ color: Color) -> RGBA? {
        guard let converted = color.cgColor?.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            intent: .defaultIntent, options: nil),
            let comps = converted.components, comps.count >= 3 else { return nil }
        return RGBA(r: Double(comps[0]), g: Double(comps[1]), b: Double(comps[2]))
    }

    func luminance(_ color: Color) -> Double? {
        guard let c = sRGB(color) else { return nil }
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// WCAG contrast ratio between two token colors (pure sRGB math).
    func contrast(_ a: Color, _ b: Color) -> Double? {
        guard let la = luminance(a), let lb = luminance(b) else { return nil }
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    func assertContrast(_ a: Color, _ b: Color, atLeast floor: Double,
                        _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let ratio = contrast(a, b) else {
            XCTFail("\(message): could not read sRGB components", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(ratio, floor,
                                    "\(message): measured \(String(format: "%.2f", ratio)):1", file: file, line: line)
    }

}

extension DesignTokensTests {

    /// Semantic state fills all carry white hero glyphs at ≥4.5:1.
    func testVoiceStateFillsHoldWhiteGlyphContrast() {
        let states: [(String, Color)] = [
            ("stateIdle #163D73", DesignTokens.stateIdle),
            ("stateStopped #4E627A", DesignTokens.stateStopped),
            ("stateListening #A8620C", DesignTokens.stateListening),
            ("stateTranscribing #8F5208", DesignTokens.stateTranscribing),
            ("stateUnderstanding #7A4A0F", DesignTokens.stateUnderstanding),
            ("stateSpeaking #2E7A18", DesignTokens.stateSpeaking),
            ("stateError #C02F2A", DesignTokens.stateError),
        ]
        for (name, color) in states {
            assertContrast(color, .white, atLeast: 4.5, "\(name) vs white glyphs")
        }
    }

    /// Voice indicators must remain distinguishable on every selected canvas.
    func testVoiceStateFillsSeparateFromEverySkinBackground() {
        for skin in AppTheme.allCases {
            for color in [DesignTokens.stateIdle, DesignTokens.stateStopped,
                          DesignTokens.stateListening, DesignTokens.stateTranscribing,
                          DesignTokens.stateUnderstanding, DesignTokens.stateSpeaking,
                          DesignTokens.stateError] {
                assertContrast(color, AppColors.palette(for: skin).background, atLeast: 3.0,
                               "state fill vs \(skin) background")
            }
        }
    }


    /// Every badge category, for the sweeps below.
    private static let allBadgeTints: [DesignTokens.BadgeTint] = [
        .meds, .reminders, .call, .appliance, .settings, .apps, .feeds, .emergency, .directions,
    ]


    /// Every badge icon is a graphical object: its fill must hold ≥3:1
    /// against the circle it sits on (WCAG 1.4.11).
    func testEveryBadgeIconContrastsItsBackground() {
        for skin in AppTheme.allCases {
            let appearance = AppAppearance(skin: skin, style: .soft)
            for badge in Self.allBadgeTints {
                assertContrast(appearance.badgeTint(badge), appearance.badgeBackground(badge),
                               atLeast: 3.0, "\(skin) \(badge) badge contrast")
            }
        }
    }

    /// Emergency red remains unique among task indicators for every skin.
    func testEmergencyIsTheOnlyStopRedBadge() {
        for skin in AppTheme.allCases {
            let appearance = AppAppearance(skin: skin, style: .glass)
            XCTAssertEqual(appearance.badgeTint(.emergency), DesignTokens.stateError)
            for badge in Self.allBadgeTints where badge != .emergency {
                XCTAssertNotEqual(appearance.badgeTint(badge), DesignTokens.stateError)
            }
        }
    }

    func testSkinTextAndPrimaryControlsHaveAccessibleContrast() {
        for skin in AppTheme.allCases {
            let colors = AppColors.palette(for: skin)
            for surface in [colors.background, colors.card, colors.userBubble, colors.brandCanvasBottom] {
                assertContrast(colors.textPrimary, surface, atLeast: 4.5, "\(skin) primary text")
                assertContrast(colors.textSecondary, surface, atLeast: 4.5, "\(skin) secondary text")
            }
            for fill in [colors.accent, colors.talkHighlight, colors.talkMid, colors.talkDeep, colors.textPrimary] {
                assertContrast(colors.onAccent, fill, atLeast: 4.5, "\(skin) white control ink")
            }
        }
    }
}
