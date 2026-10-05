import UIKit
import XCTest
@testable import ElderlyAssistant

final class AppTypographyTests: XCTestCase {
    func testInheritedCategoryRefreshesEverySystemFontWithoutChangingManualSizes() {
        let regular = AppAppearance(skin: .sky, style: .soft,
                                    systemContentSizeCategory: .large).typography
        let accessible = AppAppearance(skin: .sky, style: .soft,
                                       systemContentSizeCategory: .accessibilityMedium).typography
        XCTAssertGreaterThan(accessible.bodyPointSize, regular.bodyPointSize)
        XCTAssertGreaterThan(accessible.captionPointSize, regular.captionPointSize)
        XCTAssertGreaterThan(accessible.titlePointSize, regular.titlePointSize)
        let manual = AppAppearance(skin: .sky, style: .soft, textSize: .small,
                                  systemContentSizeCategory: .accessibilityMedium).typography
        XCTAssertEqual(manual.bodyPointSize, AppTypography(textSize: .small).bodyPointSize)
    }

    func testInvalidStoredTextSizesFollowSystem() {
        for raw in [nil, "", "unknown"] as [String?] {
            XCTAssertEqual(AppTextSize(rawOrDefault: raw), .system)
        }
        for choice in AppTextSize.allCases {
            XCTAssertEqual(AppTextSize(rawOrDefault: choice.rawValue), choice)
        }
    }

    func testManualSizesIncreaseVisibleTypographyAndKeepReadableFloors() {
        let choices: [AppTextSize] = [.small, .medium, .large, .xl, .xxl]
        var previous: AppTypography?
        for choice in choices {
            let typography = AppTypography(textSize: choice)
            XCTAssertGreaterThanOrEqual(typography.bodyPointSize, 18)
            XCTAssertGreaterThanOrEqual(typography.captionPointSize, 18)
            if let previous {
                XCTAssertGreaterThan(typography.bodyPointSize, previous.bodyPointSize)
                XCTAssertGreaterThan(typography.titlePointSize, previous.titlePointSize)
                XCTAssertGreaterThan(typography.greetingPointSize, previous.greetingPointSize)
                XCTAssertGreaterThan(typography.homeTimerDigitPointSize, previous.homeTimerDigitPointSize)
                XCTAssertGreaterThanOrEqual(typography.captionPointSize, previous.captionPointSize)
            }
            previous = typography
        }
    }

    func testManualPointSizesMatchNativeDynamicTypeCategoriesWithoutDoubleScaling() {
        let categories: [(AppTextSize, UIContentSizeCategory)] = [
            (.small, .small), (.medium, .medium), (.large, .large),
            (.xl, .extraLarge), (.xxl, .extraExtraLarge)
        ]
        for (selection, category) in categories {
            let traits = UITraitCollection(preferredContentSizeCategory: category)
            let expected = UIFontMetrics.default.scaledValue(for: 21, compatibleWith: traits)
            XCTAssertEqual(AppTypography(textSize: selection).bodyPointSize, max(18, expected), accuracy: 0.001)
        }
    }

    func testSystemUsesAccessibilityTraitsWhileManualSelectionStaysExplicit() {
        let manual = AppTypography(textSize: .xxl).bodyPointSize
        let accessibility = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        accessibility.performAsCurrent {
            let system = AppTypography(textSize: .system)
            let expected = UIFontMetrics.default.scaledValue(for: 21, compatibleWith: accessibility)
            XCTAssertEqual(system.bodyPointSize, expected, accuracy: 0.001)
            XCTAssertGreaterThan(system.bodyPointSize, manual)
            XCTAssertEqual(AppTypography(textSize: .xxl).bodyPointSize, manual)
        }
    }

    func testSkinAndStyleDoNotChangeSelectedTypography() {
        for size in AppTextSize.allCases where size != .system {
            let expected = AppTypography(textSize: size)
            for skin in AppTheme.allCases {
                for style in AppVisualStyle.allCases {
                    let appearance = AppAppearance(skin: skin, style: style, textSize: size)
                    XCTAssertEqual(appearance.typography.bodyPointSize, expected.bodyPointSize)
                    XCTAssertEqual(appearance.typography.titlePointSize, expected.titlePointSize)
                }
            }
        }
    }
}
