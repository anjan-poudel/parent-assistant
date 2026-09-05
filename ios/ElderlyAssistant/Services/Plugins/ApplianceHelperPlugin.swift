import Foundation
import SwiftUI

/// Appliance/vision helper plugin (designs:
/// docs/superpowers/specs/2026-09-05-appliance-vision-helper-design.md,
/// its live-AR addendum, and the plugin architecture's §6.1 wiring).
///
/// A voice utterance can never CARRY a photo (design §6.1, stated
/// plainly), so `handle` does not answer anything itself — it opens the
/// camera surface via `spokenAndPresented`, and the presented
/// `ApplianceHelperView` drives capture → identify → overlay through
/// `ApplianceHelperSession`. The in-sheet follow-up mic and the live-AR
/// mode are deliberately not built on this branch (addendum §13 is a
/// later phase; see the branch report).
final class ApplianceHelperPlugin: AssistantPlugin {

    let pluginID = "appliance_helper"
    let displayNameKey = "plugin.applianceHelper.name"

    private let cache: ApplianceCache

    /// Wired by `AppCoordinator.start()` (the speaker is built after the
    /// registry, so it can't be an init parameter). Optional: the feature
    /// works silently without it, and tests never set one.
    var speaker: Speaker?

    /// Everything `presentationView(for:)` needs from the `handle` call
    /// that produced the result — the protocol hands the context to
    /// `handle` only, so the pending request is stashed here between the
    /// two calls (CommandRouter always calls them as a pair).
    private struct PendingRequest {
        let question: String?
        let locale: Locale
        let geminiClient: GeminiClient
        let observabilityBus: ObservabilityBus
    }
    private var pendingRequest: PendingRequest?

    init(storage: EncryptedLocalStorage) {
        self.cache = ApplianceCache(storage: storage)
    }

    /// Test seam: the session cache (LRU/keys covered by
    /// `ApplianceCacheTests` directly).
    init(cache: ApplianceCache) {
        self.cache = cache
    }

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
        guard context.geminiClient.isAvailable else {
            context.observabilityBus.emit(Self.event("appliance_helper_unconfigured"))
            return .failed(spokenApology: L10n.str("plugin.applianceHelper.notConfigured",
                                                   locale: context.locale))
        }
        let question = Self.extractQuestion(from: command)
        pendingRequest = PendingRequest(question: question,
                                        locale: context.locale,
                                        geminiClient: context.geminiClient,
                                        observabilityBus: context.observabilityBus)
        context.observabilityBus.emit(Self.event("appliance_helper_presented"))
        return .spokenAndPresented(L10n.str("plugin.applianceHelper.cameraPrompt",
                                            locale: context.locale))
    }

    /// The question travels in the plugin's own `question` entity; an
    /// empty string means "no specific question" (general how-to-use),
    /// and the sanitised transcript is the last-resort carrier.
    static func extractQuestion(from command: PluginCommand) -> String? {
        if let q = command.entities["question"] {
            let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let transcript = command.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.isEmpty ? nil : transcript
    }

    func presentationView(for result: PluginResult) -> AnyView? {
        guard case .spokenAndPresented = result, let request = pendingRequest else { return nil }
        let session = ApplianceHelperSession(question: request.question,
                                             locale: request.locale,
                                             geminiClient: request.geminiClient,
                                             cache: cache,
                                             observabilityBus: request.observabilityBus,
                                             speaker: speaker)
        return AnyView(ApplianceHelperView(session: session))
    }

    private static func event(_ type: String, errorCode: String? = nil) -> ObservabilityEvent {
        ObservabilityEvent(component: "plugin_appliance_helper",
                           eventType: type, durationMs: nil,
                           outcome: errorCode == nil ? "success" : "failure",
                           errorCode: errorCode, metadata: [:])
    }
}
