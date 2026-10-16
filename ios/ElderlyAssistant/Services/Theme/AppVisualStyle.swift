import Foundation

/// Surface treatment, independent from colour and persisted separately.
enum AppVisualStyle: String, CaseIterable, Identifiable {
    case classic, soft, glass

    var id: String { rawValue }
    var nameKey: String { "appearance.style.\(rawValue)" }
    var descriptionKey: String { "appearance.style.\(rawValue).description" }

    init(rawOrDefault raw: String?) {
        self = raw.flatMap(AppVisualStyle.init(rawValue:)) ?? .soft
    }
}
