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

    /// Asserts a token still equals its pinned sRGB value (per-channel
    /// tolerance 0.004 ≈ 1/255 — the token's own storage precision).
    func assertPinned(_ color: Color, r: Double, g: Double, b: Double,
                      file: StaticString = #filePath, line: UInt = #line) {
        guard let c = sRGB(color) else {
            XCTFail("could not read sRGB components", file: file, line: line)
            return
        }
        XCTAssertEqual(c.r, r, accuracy: 0.004, "red channel", file: file, line: line)
        XCTAssertEqual(c.g, g, accuracy: 0.004, "green channel", file: file, line: line)
        XCTAssertEqual(c.b, b, accuracy: 0.004, "blue channel", file: file, line: line)
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

    /// Every state fill stays separable from the warm-white background.
    func testVoiceStateFillsSeparateFromCreamBackground() {
        for color in [DesignTokens.stateIdle, DesignTokens.stateStopped,
                      DesignTokens.stateListening, DesignTokens.stateTranscribing,
                      DesignTokens.stateUnderstanding, DesignTokens.stateSpeaking,
                      DesignTokens.stateError] {
            assertContrast(color, DesignTokens.background, atLeast: 3.0,
                           "state fill vs cream background")
        }
    }

    /// Exact semantic pins. The idle navy aligns with VoiceBridge; the
    /// amber/green/red traffic states retain their established meanings.
    func testVoiceStatePaletteIsPinned() {
        assertPinned(DesignTokens.stateIdle, r: 0.086, g: 0.239, b: 0.451)
        assertPinned(DesignTokens.stateStopped, r: 0.306, g: 0.384, b: 0.478)
        assertPinned(DesignTokens.stateListening, r: 0.659, g: 0.384, b: 0.047)
        assertPinned(DesignTokens.stateTranscribing, r: 0.561, g: 0.322, b: 0.031)
        assertPinned(DesignTokens.stateUnderstanding, r: 0.478, g: 0.290, b: 0.059)
        assertPinned(DesignTokens.stateSpeaking, r: 0.180, g: 0.478, b: 0.094)
        assertPinned(DesignTokens.stateError, r: 0.753, g: 0.184, b: 0.165)
    }

    /// Every badge category, for the sweeps below.
    private static let allBadgeTints: [DesignTokens.BadgeTint] = [
        .meds, .reminders, .call, .appliance, .settings, .apps, .feeds, .emergency, .directions,
    ]

    /// The consolidation contract (design review 2026-09-10): nine
    /// categories resolve onto exactly FOUR semantic roles. A fifth role
    /// reappearing is the noise the review asked us to remove.
    func testBadgePaletteHasExactlyFourRoles() {
        XCTAssertEqual(DesignTokens.BadgeTint.Role.allCases.count, 4,
                       "the badge palette is brand/action, voice state, emergency, neutral")
        let used = Set(Self.allBadgeTints.map(\.role))
        XCTAssertEqual(used.count, DesignTokens.BadgeTint.Role.allCases.count,
                       "every declared role is worn by at least one category")
    }

    /// Categories that share a role share its colours exactly — that is
    /// what "consolidated" means: `.feeds` and `.directions` must not
    /// quietly grow distinct hues again.
    func testCategoriesSharingARoleShareTheirColors() {
        let byRole = Dictionary(grouping: Self.allBadgeTints, by: \.role)
        for (role, tints) in byRole {
            guard let first = tints.first else { continue }
            for other in tints.dropFirst() {
                XCTAssertEqual(sRGB(first.tint), sRGB(other.tint),
                               "\(role): tint drifted between categories")
                XCTAssertEqual(sRGB(first.background), sRGB(other.background),
                               "\(role): background drifted between categories")
            }
        }
    }

    /// The role mapping itself is pinned, so a future edit that moves a
    /// category between roles has to say so here.
    func testBadgeRoleMapping() {
        let expected: [(DesignTokens.BadgeTint, DesignTokens.BadgeTint.Role)] = [
            (.meds, .brandAction), (.reminders, .brandAction), (.call, .brandAction),
            (.apps, .voiceState),
            (.emergency, .emergency),
            (.appliance, .neutralCategory), (.settings, .neutralCategory),
            (.feeds, .neutralCategory), (.directions, .neutralCategory),
        ]
        for (badge, role) in expected {
            XCTAssertEqual(badge.role, role, "\(badge) role")
        }
    }

    /// Every badge icon is a graphical object: its fill must hold ≥3:1
    /// against the circle it sits on (WCAG 1.4.11).
    func testEveryBadgeIconContrastsItsBackground() {
        for badge in Self.allBadgeTints {
            assertContrast(badge.tint, badge.background, atLeast: 3.0,
                           "\(badge) (\(badge.role)) tint vs badge background")
        }
    }

    /// Urgency stays unique: the emergency badge is the ONLY one wearing
    /// `stateError`. Brand/action is the accent, the voice role is the
    /// hero's rest blue, and the neutral role is the secondary text tone.
    func testEmergencyIsTheOnlyStopRedBadge() {
        let emergency = DesignTokens.BadgeTint.emergency
        assertPinned(emergency.tint, r: 0.753, g: 0.184, b: 0.165)   // stateError
        assertContrast(emergency.tint, emergency.background, atLeast: 4.5,
                       "emergency glyph on its white circle")
        for badge in Self.allBadgeTints where badge != .emergency {
            XCTAssertNotEqual(sRGB(badge.tint), sRGB(DesignTokens.stateError),
                              "\(badge) must not wear the emergency red")
        }
    }

    /// Persistent daily actions wear VoiceBridge maroon; neutral category
    /// icons use brand navy and voice actions use the rest-state blue.
    func testBrandActionAndNeutralRolesArePinned() {
        assertPinned(DesignTokens.BadgeTint.meds.tint, r: 0.733, g: 0.118, b: 0.302)
        assertPinned(DesignTokens.BadgeTint.settings.tint, r: 0.043, g: 0.122, b: 0.267)
        assertPinned(DesignTokens.BadgeTint.apps.tint, r: 0.086, g: 0.239, b: 0.451)
    }
}
