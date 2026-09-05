import Foundation

/// Confirmation policy per intent action (spec 2026-09-05 §7.2) — decided
/// by tier, not ad-hoc per call site.
///
///  - free:       execute immediately, acknowledge after (no side effects
///                beyond speech/UI)
///  - confirm:    outward-facing or schedule-mutating — dual-channel
///                yes/no (voice हो/होइन + chips), 45s timeout
///  - neverGated: emergency and the med-ack challenge flow — no
///                confirmation, no auth, no model dependency (constitution)
enum ConfirmationTier {
    case free
    case confirm
    case neverGated

    static func tier(for action: InterpretedCommand.Action) -> ConfirmationTier {
        switch action {
        case .emergency, .ackMed:
            return .neverGated
        case .call, .sendMessage, .setReminder, .createCalendarEvent:
            return .confirm
        case .music, .suggestVideo, .guide, .healthQuery, .query, .none:
            return .free
        case .plugin:
            // Plugin actions own their own confirmation policy inside
            // `handle(_:)` (e.g. a read-only Q&A plugin like the Nepali
            // calendar must NOT be gated behind a yes/no before it can
            // even answer; a future side-effecting plugin implements
            // its own challenge internally). Blanket-gating here would
            // break read-only plugins.
            return .free
        }
    }
}
