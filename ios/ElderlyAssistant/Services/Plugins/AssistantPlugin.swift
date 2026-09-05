import Foundation
import SwiftUI

/// One optional capability of the assistant (docs/superpowers/specs/
/// 2026-09-05-plugin-architecture-design.md). The core app (medication,
/// emergency, calling, plain conversation) is NOT a plugin — see the
/// design doc's §5 "hard boundary": safety-critical paths must never
/// depend on something that can fail to load or apply.
///
/// A plugin contributes:
///  - intent vocabulary (a prompt fragment composed into `IntentPrompt`
///    only when `isApplicable(locale:)` is true for the active locale —
///    that single check is both the geography gate AND the dispatch
///    gate, so an inapplicable plugin costs zero prompt tokens and zero
///    misclassification risk for users it doesn't apply to), and
///  - a `handle(_:context:)` implementation that executes interpreted
///    commands addressed to it.
/// Class-constrained: plugins are stateful reference types (caches,
/// pending work, test doubles recording handled commands), and identity
/// (`===`) is meaningful for registry lookups in tests.
protocol AssistantPlugin: AnyObject {
    /// Stable, namespaced identifier — e.g. "appliance_helper",
    /// "nepali_calendar". Never shown to the user directly; used as a
    /// namespace for the plugin's action names and any local storage.
    var pluginID: String { get }

    /// Catalog key for a localized display name (future "manage plugins"
    /// surface).
    var displayNameKey: String { get }

    /// Geography/language gating — THE mechanism behind "Nepali calendar
    /// plugin only for Nepali", generalized to any future market. Core
    /// never special-cases a language; it just asks each plugin this.
    func isApplicable(locale: Locale) -> Bool

    /// This plugin's contribution to the shared intent prompt. Composed
    /// in only when `isApplicable` is true for the active locale.
    var intentContribution: PluginIntentContribution { get }

    /// Called when the interpreted action belongs to this plugin. Async
    /// because most plugin work (vision calls, search-grounded lookups)
    /// is a network round trip.
    func handle(_ command: PluginCommand, context: PluginExecutionContext) async -> PluginResult

    /// A SwiftUI view this plugin wants presented as a result (e.g. the
    /// appliance photo + overlay), or nil for a spoken/outcome-card-only
    /// result. Type-erased since a protocol can't return `some View`.
    func presentationView(for result: PluginResult) -> AnyView?
}

struct PluginIntentContribution {
    /// e.g. "appliance.identify", "nepali_calendar.query". Must be
    /// globally unique — namespaced by pluginID by convention (the
    /// registry warns on collisions rather than enforcing uniqueness
    /// statically; see design doc §7 item 2).
    let actionNames: [String]
    /// Prose merged into the shared prompt, in the same style as the
    /// core prompt's per-action instructions.
    let promptFragment: String
}

struct PluginCommand {
    /// One of the plugin's own actionNames, as emitted by the LLM.
    let actionName: String
    /// The sanitised transcript, as CommandRouter already produces.
    let transcript: String
    /// Whatever entities the plugin's own prompt fragment asked the LLM
    /// to extract, keyed by the field names it declared.
    let entities: [String: String]
    let confidence: Double
}

struct PluginExecutionContext {
    let locale: Locale
    /// The shared client — same cost/observability chokepoint every
    /// other Gemini call already funnels through.
    let geminiClient: GeminiClient
    let observabilityBus: ObservabilityBus
}

enum PluginResult: Equatable {
    /// Just say this (and show it as the generic outcome card), no view.
    case spoken(String)
    /// Say this AND present the view returned by `presentationView(for:)`.
    case spokenAndPresented(String)
    /// Honest failure the user can hear — plugins must never silently
    /// swallow failures (constitution: no silent stubs).
    case failed(spokenApology: String)

    var spokenText: String {
        switch self {
        case .spoken(let t), .spokenAndPresented(let t): return t
        case .failed(let apology): return apology
        }
    }
}
