import UIKit

/// Resolves custom point-sized fonts once against the selected UIKit category.
/// SwiftUI's root DynamicTypeSize supplies the matching category for native styles.
/// Resolved point sizes must not be passed through ScaledMetric again.
struct AppTypography {
    private let traits: UITraitCollection
    // Appearance typography is a value, so cache only immutable category traits;
    // resolving several fonts in one render must not allocate a trait per label.
    private static let categoryTraits = Dictionary(uniqueKeysWithValues:
        [UIContentSizeCategory.extraSmall, .small, .medium, .large,
         .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
         .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
         .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge]
            .map { ($0, UITraitCollection(preferredContentSizeCategory: $0)) })

    init(textSize: AppTextSize, systemContentSizeCategory: UIContentSizeCategory? = nil) {
        if let category = textSize.contentSizeCategory ?? systemContentSizeCategory,
           let selectedTraits = Self.categoryTraits[category] {
            traits = selectedTraits
        } else {
            // UIKit's current traits follow the device, including accessibility categories.
            // An unspecified category lets UIFontMetrics resolve the system preference.
            traits = UITraitCollection.current
        }
    }

    var bodyPointSize: CGFloat { scaled(21) }
    var captionPointSize: CGFloat { scaled(18) }
    var titlePointSize: CGFloat { scaled(32) }
    var greetingPointSize: CGFloat { scaled(33) }
    var homeTimerDigitPointSize: CGFloat { scaled(28) }

    /// Every UI label retains the app's 18pt legibility floor, including Small.
    func scaled(_ base: CGFloat) -> CGFloat {
        max(18, UIFontMetrics.default.scaledValue(for: base, compatibleWith: traits))
    }
}
