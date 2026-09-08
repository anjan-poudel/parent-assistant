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

// MARK: - Traffic-light palette (visual-polish 2026-09-08)
//
// The hero renders WHITE glyphs on each state fill, so the pins below
// enforce the promise made in DesignTokens: every fill holds ≥4.5:1
// against white and ≥3:1 against the cream background (WCAG 1.4.3/1.4.11
// as implemented by the pure sRGB math below). The pin tests read the
// live token components (via `cgColor`) so a palette edit that breaks a
// promise fails here without duplicated literals to drift.

private extension DesignTokensTests {
    struct RGBA { let r: Double; let g: Double; let b: Double }

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

    /// Traffic-light fills — rest blue, wait ambers, go green, stop red —
    /// all carry white hero glyphs at ≥4.5:1.
    func testVoiceStateFillsHoldWhiteGlyphContrast() {
        let states: [(String, Color)] = [
            ("stateIdle #3B6EA5", DesignTokens.stateIdle),
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

    /// Every state fill stays separable from the cream background — a
    /// resting blue or listening amber must never sink into #FAF3E9.
    func testVoiceStateFillsSeparateFromCreamBackground() {
        for color in [DesignTokens.stateIdle, DesignTokens.stateStopped,
                      DesignTokens.stateListening, DesignTokens.stateTranscribing,
                      DesignTokens.stateUnderstanding, DesignTokens.stateSpeaking,
                      DesignTokens.stateError] {
            assertContrast(color, DesignTokens.background, atLeast: 3.0,
                           "state fill vs cream background")
        }
    }

    /// Exact pins — the traffic-light table as of visual-polish 2026-09-08
    /// (hex → sRGB): rest blue 3B6EA5, dimmed blue 4E627A, amber ramp
    /// A8620C → 8F5208 → 7A4A0F, go green 2E7A18, stop red C02F2A.
    func testVoiceStatePaletteIsPinned() {
        assertPinned(DesignTokens.stateIdle, r: 0.231, g: 0.431, b: 0.647)
        assertPinned(DesignTokens.stateStopped, r: 0.306, g: 0.384, b: 0.478)
        assertPinned(DesignTokens.stateListening, r: 0.659, g: 0.384, b: 0.047)
        assertPinned(DesignTokens.stateTranscribing, r: 0.561, g: 0.322, b: 0.031)
        assertPinned(DesignTokens.stateUnderstanding, r: 0.478, g: 0.290, b: 0.059)
        assertPinned(DesignTokens.stateSpeaking, r: 0.180, g: 0.478, b: 0.094)
        assertPinned(DesignTokens.stateError, r: 0.753, g: 0.184, b: 0.165)
    }

    /// The call badge left the blue family for warm vermilion #C2541F on
    /// pale salmon #F9E2D5 (visual-polish 2026-09-08) — pinned, and ≥3:1
    /// for the graphical icon per WCAG 1.4.11.
    func testCallBadgeIsWarmVermilionAndContrastsItsBackground() {
        let tint = DesignTokens.BadgeTint.call.tint
        let background = DesignTokens.BadgeTint.call.background
        assertPinned(tint, r: 0.761, g: 0.329, b: 0.122)
        assertContrast(tint, background, atLeast: 3.0, "call tint vs badge background")
    }

    /// Settings keeps its own purple (#5C5A8A) — decoupled from the voice
    /// palette when understanding joined the amber ramp.
    func testSettingsBadgeKeepsPurple() {
        assertPinned(DesignTokens.BadgeTint.settings.tint, r: 0.361, g: 0.353, b: 0.541)
    }
}
