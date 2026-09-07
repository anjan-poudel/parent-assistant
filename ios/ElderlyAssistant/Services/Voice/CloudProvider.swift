import Foundation

/// Which cloud provider an OPTED-IN on-device escalation may reach
/// (cloud-fallback task, 2026-09-07). Today exactly one provider exists;
/// the setting is provider-ready by design — persisted as a raw-value
/// string (`AppCoordinator.cloudProvider`, UserDefaults key
/// "cloudProvider") so a later Settings dropdown ("ask via …") can offer
/// other cloud providers without migrating stored values. Where the
/// provider actually takes effect: `AppCoordinator.applyVoiceEngineStack()`
/// switches on this enum to decide whether the on-device chain's
/// abstentions may go to the cloud brain — future providers plug in as
/// new cases there, each gated on its own interpreter's availability.
enum CloudProvider: String {
    case gemini

    /// Whether the on-device stack's cloud escalation is live: the
    /// household switched "Ask Gemini when I can't answer" ON AND the
    /// Gemini interpreter is actually available (the SAME availability
    /// gate `IntentRouter` applies to its cloud layer at route time —
    /// `cloudEnabled` AND `cloudBrain.isAvailable` — so the Settings
    /// promise can never outrun what the chain would do). Pure static
    /// so the decision is unit-testable without an `AppCoordinator`
    /// instance (same seam as
    /// `AppCoordinator.shouldAutoDownloadAssistantBrain`).
    static func cloudFallbackEngages(enabled: Bool, geminiAvailable: Bool) -> Bool {
        enabled && geminiAvailable
    }
}
