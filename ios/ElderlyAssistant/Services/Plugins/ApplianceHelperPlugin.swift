import Foundation
import SwiftUI

/// Skeleton for the appliance/vision helper (designs:
/// docs/superpowers/specs/2026-09-05-appliance-vision-helper-design.md
/// and its live-AR addendum). Registers the feature's intent vocabulary
/// NOW so appliance questions are classified correctly instead of being
/// hallucinated as generic `query` answers — but the camera/vision
/// pipeline itself is not built yet, so `handle` returns an honest
/// spoken "not ready yet" (constitution: no silent stubs — deferred
/// work must be explicit, never a fake success).
///
/// When the real feature lands, this plugin's `handle` wraps
/// `GeminiClient.identifyAppliance`/`getApplianceInstructions` per the
/// base design, and `presentationView(for:)` returns the photo +
/// overlay view — the plugin boundary itself does not change.
final class ApplianceHelperPlugin: AssistantPlugin {

    let pluginID = "appliance_helper"
    let displayNameKey = "plugin.applianceHelper.name"

    func isApplicable(locale: Locale) -> Bool { true }   // universal, not geography-gated

    var intentContribution: PluginIntentContribution {
        PluginIntentContribution(
            actionNames: ["appliance.identify", "appliance.get_instructions"],
            promptFragment: """
            PLUGIN CAPABILITY (appliance help): if the user wants to know \
            how to use, operate, or understand a physical appliance, \
            remote control, microwave, washing machine, TV, or screen \
            (e.g. "यो कसरी चलाउने", "माइक्रोवेभमा चिया कसरी बनाउने", \
            "यो बटन के हो"), set action to "plugin", pluginAction to \
            "appliance.identify", and pluginEntities to \
            {"question": "<their question, verbatim, or empty string>"}. \
            Use "appliance.get_instructions" instead only when they are \
            clearly asking a follow-up about an appliance they were just \
            being helped with in this conversation.
            """
        )
    }

    func handle(_ command: PluginCommand, context: PluginExecutionContext) async -> PluginResult {
        context.observabilityBus.emit(ObservabilityEvent(
            component: "plugin_appliance_helper",
            eventType: "appliance_helper_not_ready",
            durationMs: nil,
            outcome: "info",
            errorCode: nil,
            metadata: [:]
        ))
        return .failed(spokenApology: L10n.str("plugin.applianceHelper.notReady",
                                                locale: context.locale))
    }

    func presentationView(for result: PluginResult) -> AnyView? { nil }
}
