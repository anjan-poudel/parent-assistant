import Foundation

/// Owns the set of registered plugins and answers the two questions the
/// core needs: "which plugins apply to this locale?" (prompt composition
/// + dispatch) and "who handles this plugin action name?" (dispatch).
///
/// Registration is compile-time, by a fixed list in `AppCoordinator` —
/// "plugin" here means an isolated, swappable Swift module, NOT a
/// dynamically loaded bundle (design doc §7 item 3).
final class PluginRegistry {

    private(set) var plugins: [AssistantPlugin] = []
    private let observabilityBus: ObservabilityBus?

    init(observabilityBus: ObservabilityBus? = nil) {
        self.observabilityBus = observabilityBus
    }

    func register(_ plugin: AssistantPlugin) {
        // Collision check (design doc §7 item 2): two plugins claiming
        // the same action name must not silently shadow each other.
        let existing = plugins.flatMap { $0.intentContribution.actionNames }
        let incoming = plugin.intentContribution.actionNames
        let collisions = existing.filter(incoming.contains)
        if !collisions.isEmpty {
            observabilityBus?.emit(ObservabilityEvent(
                component: "plugin_registry",
                eventType: "plugin_action_collision",
                durationMs: nil,
                outcome: "failure",
                errorCode: collisions.joined(separator: ","),
                metadata: ["state": plugin.pluginID]
            ))
            // Deliberately NOT an assertionFailure: a plugin
            // misregistration must never crash the app (least of all on
            // an elderly user's device at boot). The observability event
            // above is the loud failure; the colliding plugin is simply
            // dropped.
            return
        }
        plugins.append(plugin)
    }

    /// Plugins whose `isApplicable` gate passes for `locale` — used both
    /// for prompt composition (only these contribute fragments) and for
    /// dispatch (only these may handle actions).
    func activePlugins(for locale: Locale) -> [AssistantPlugin] {
        plugins.filter { $0.isApplicable(locale: locale) }
    }

    /// The plugin that claims `actionName` among those applicable to
    /// `locale`, or nil if none — which callers must treat as
    /// "unresolved", never as a crash or a silent drop.
    func plugin(handling actionName: String, locale: Locale) -> AssistantPlugin? {
        activePlugins(for: locale).first { $0.intentContribution.actionNames.contains(actionName) }
    }
}
