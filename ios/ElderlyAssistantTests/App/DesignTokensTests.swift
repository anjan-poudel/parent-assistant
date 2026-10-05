import SwiftUI
import XCTest
@testable import ElderlyAssistant

/// Operational layout and colour invariants. UI typography is exercised by
/// AppTypographyTests against the selected size and readable floor.
final class DesignTokensTests: XCTestCase {


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

    func composite(_ foreground: Color, opacity: Double, over background: Color) -> Color {
        guard let front = sRGB(foreground), let back = sRGB(background) else {
            XCTFail("Could not read composited surface components")
            return background
        }
        return Color(.sRGB, red: front.r * opacity + back.r * (1 - opacity),
                     green: front.g * opacity + back.g * (1 - opacity),
                     blue: front.b * opacity + back.b * (1 - opacity), opacity: 1)
    }

    func isStopRed(_ color: Color) -> Bool {
        guard let c = sRGB(color) else { return false }
        let maximum = max(c.r, c.g, c.b), minimum = min(c.r, c.g, c.b)
        guard maximum == c.r, maximum > minimum else { return false }
        let hue = 60 * (c.g - c.b) / (maximum - minimum)
        return abs(hue) < 10
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

    /// Light canvases separate the fill itself; dark canvases use an outline and readable state ink.
    func testVoiceStateFillsSeparateFromLightSkinBackgrounds() {
        for skin in AppTheme.allCases where !skin.isDark {
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
        .profile,
    ]


    /// Opaque badges also carry labels; IconBadge's translucent wash carries a graphical glyph.
    func testEveryBadgeIconContrastsItsBackground() {
        for skin in AppTheme.allCases {
            let appearance = AppAppearance(skin: skin, style: .soft)
            for badge in Self.allBadgeTints {
                let foreground = appearance.badgeTint(badge)
                let background = appearance.badgeBackground(badge)
                assertContrast(foreground, background,
                               atLeast: 4.5, "\(skin) \(badge) badge contrast")
                for surface in [appearance.colors.background, appearance.colors.card,
                                appearance.colors.brandCanvasBottom] {
                    let wash = composite(background, opacity: 0.55, over: surface)
                    assertContrast(foreground, wash, atLeast: skin.isDark ? 4.5 : 3.0,
                                   "\(skin) \(badge) composited badge contrast")
                }
            }
        }
    }

    /// The profile badge sits directly beside Settings on the home hub
    /// (home-profile-icon, 2026-10-06) — its tone must read as its own
    /// place in every skin, never a copy of the settings glyph's ink.
    func testProfileBadgeToneStaysDistinctFromSettings() {
        for skin in AppTheme.allCases {
            let appearance = AppAppearance(skin: skin, style: .soft)
            XCTAssertNotEqual(appearance.badgeTint(.profile),
                              appearance.badgeTint(.settings),
                              "\(skin): profile must not borrow the settings tint")
            XCTAssertNotEqual(appearance.badgeBackground(.profile),
                              appearance.badgeBackground(.settings),
                              "\(skin): profile must not borrow the settings wash")
        }
    }

    /// Emergency red remains unique among task indicators for every skin.
    func testEmergencyIsTheOnlyStopRedBadge() {
        for skin in AppTheme.allCases {
            let appearance = AppAppearance(skin: skin, style: .glass)
            XCTAssertTrue(isStopRed(appearance.badgeTint(.emergency)),
                          "Emergency must retain a recognisably red hue")
            for badge in Self.allBadgeTints where badge != .emergency {
                XCTAssertFalse(isStopRed(appearance.badgeTint(badge)),
                               "\(skin) \(badge) must not look like an emergency")
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
            let fills = [colors.accent, colors.talkHighlight, colors.talkMid, colors.talkDeep]
            for start in fills {
                for end in fills {
                    for step in 0...20 {
                        let fill = composite(start, opacity: Double(step) / 20, over: end)
                        assertContrast(colors.onAccent, fill, atLeast: 4.5,
                                       "\(skin) white ink across action gradient")
                    }
                }
            }
            if !skin.isDark {
                assertContrast(colors.onAccent, colors.textPrimary, atLeast: 4.5,
                               "\(skin) white ink on light skin's dark neutral action")
            }
        }
    }

    func testDarkAccentAndStatusForegroundsRemainReadableOnEverySurface() {
        let states = [DesignTokens.stateIdle, DesignTokens.stateStopped,
                      DesignTokens.stateListening, DesignTokens.stateTranscribing,
                      DesignTokens.stateUnderstanding, DesignTokens.stateSpeaking,
                      DesignTokens.stateError]
        for skin in AppTheme.allCases where skin.isDark {
            let appearance = AppAppearance(skin: skin, style: .soft)
            let colors = appearance.colors
            for surface in [colors.background, colors.card, colors.userBubble,
                            colors.brandCanvasBottom] {
                assertContrast(colors.accentForeground, surface, atLeast: 4.5,
                               "\(skin) accent label")
                for state in states {
                    assertContrast(appearance.statusForeground(state), surface, atLeast: 4.5,
                                   "\(skin) state label")
                }
            }
        }
    }
}
