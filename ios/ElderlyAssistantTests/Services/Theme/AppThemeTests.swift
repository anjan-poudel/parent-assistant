import SwiftUI
import XCTest
@testable import ElderlyAssistant

final class AppThemeTests: XCTestCase {
    func testPreviouslyStoredSkinIDsRemainReadable() {
        for raw in ["cream", "sage", "sky", "lavender", "dusk", "lightPink"] {
            XCTAssertEqual(AppTheme(rawOrDefault: raw).rawValue, raw)
        }
    }

    func testInvalidSelectionsRestoreToSafeAppearance() {
        for raw in [nil, "", "unknown"] as [String?] {
            let restored = AppAppearance(skin: AppTheme(rawOrDefault: raw),
                                         style: AppVisualStyle(rawOrDefault: raw))
            XCTAssertEqual(restored, .default)
        }
    }

    func testChangingSurfaceStyleDoesNotChangeSkinColors() {
        for skin in AppTheme.allCases {
            let baseline = AppAppearance(skin: skin, style: .classic).colors
            for style in AppVisualStyle.allCases {
                let colors = AppAppearance(skin: skin, style: style).colors
                XCTAssertEqual(colors.background, baseline.background)
                XCTAssertEqual(colors.card, baseline.card)
                XCTAssertEqual(colors.accent, baseline.accent)
                XCTAssertEqual(colors.textPrimary, baseline.textPrimary)
                XCTAssertEqual(colors.textSecondary, baseline.textSecondary)
                XCTAssertEqual(colors.talkMid, baseline.talkMid)
                XCTAssertEqual(colors.talkDeep, baseline.talkDeep)
            }
        }
    }

    func testChangingTextSizeDoesNotChangeSkinColors() {
        for skin in AppTheme.allCases {
            for style in AppVisualStyle.allCases {
                let baseline = AppAppearance(skin: skin, style: style)
                for size in AppTextSize.allCases {
                    let changed = AppAppearance(skin: skin, style: style, textSize: size)
                    XCTAssertEqual(changed.colors.background, baseline.colors.background)
                    XCTAssertEqual(changed.colors.accent, baseline.colors.accent)
                    XCTAssertEqual(changed.colors.textPrimary, baseline.colors.textPrimary)
                }
            }
        }
    }
}
