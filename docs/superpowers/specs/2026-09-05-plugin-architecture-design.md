# Plugin Architecture — Modular Features & Geography Plugins

Branch: `v2-gemini-flash-lite`. Status: **first-pass design, awaiting review — not implemented.**
Revises the intent-wiring sections of both appliance-helper docs
(`docs/superpowers/specs/2026-09-05-appliance-vision-helper-design.md` §6.1 and its addendum) —
those currently assume appliance intents get added directly to the core `InterpretedCommand.Action`
enum, which is exactly the pattern this design replaces.

## 0. Why, stated precisely

"Everything can be a plugin" is a slogan; the concrete problem it needs to solve is: today,
adding ANY new capability (appliance helper, a Nepali calendar, a future India/Bangladesh-specific
feature, a future non-Nepali market entirely) means editing the same handful of core files —
`InterpretedCommand.Action` (closed enum), `IntentPrompt.build` (one shared prompt string),
`CommandRouter.dispatchInterpreted` (exhaustive switch). Every feature, forever, touches the same
choke points. Two things follow directly from that today, both real:

1. **Geography-specific features leak into every market.** A Nepali calendar intent, described in
   the one shared prompt, is vocabulary every non-Nepali user's prompt ALSO pays tokens for and
   could accidentally trigger on, even though a "when is Dashain" question is meaningless outside
   Nepal.
2. **Every new feature is a merge-conflict magnet on the same 3 files**, which is not hypothetical
   — it is exactly what almost happened this session (two parallel subagents both had to be kept
   away from `CommandRouter.swift`/the interpreter prompt files to avoid collision).

The fix is an actual extension point, not just a folder-naming convention: plugins contribute
intents and handle them, the core stops needing to know their names in advance.

## 1. Plugin contract

```swift
/// One optional capability. Core (medication, emergency, calling, plain
/// conversation) is NOT a plugin — see §5 for why that boundary is a hard
/// rule, not a style preference.
protocol AssistantPlugin {
    /// Stable, namespaced identifier — e.g. "appliance_helper",
    /// "nepali_calendar". Never shown to the user directly; used as the
    /// action-string prefix (§3) and as a storage-key namespace for
    /// anything the plugin caches locally.
    var pluginID: String { get }

    /// Localized display name, for any future "manage plugins" surface.
    var displayNameKey: String { get }

    /// Geography/language gating — THE mechanism for "Nepali calendar
    /// plugin only for Nepali," generalized to any future market. Core
    /// never special-cases a language/region; it just asks each
    /// registered plugin this question.
    func isApplicable(locale: Locale) -> Bool

    /// This plugin's contribution to the shared intent prompt — a prose
    /// fragment describing what it recognizes and what entities it needs,
    /// in the SAME style as the core prompt (see §4). Composed in only
    /// for plugins where `isApplicable` is true for the active locale, so
    /// an inapplicable plugin costs zero prompt tokens and zero
    /// misclassification risk for users it doesn't apply to.
    var intentContribution: PluginIntentContribution { get }

    /// Called when the interpreted action belongs to this plugin (§3).
    /// Async because most plugin work (vision calls, search-grounded
    /// lookups) is inherently a network round trip.
    func handle(_ command: PluginCommand, context: PluginExecutionContext) async -> PluginResult

    /// A SwiftUI view this plugin wants presented as a result (e.g. the
    /// appliance photo + overlay, or nothing for a plugin that only
    /// speaks/shows an outcome card). Type-erased since a protocol can't
    /// return `some View`.
    func presentationView(for result: PluginResult) -> AnyView?
}

struct PluginIntentContribution {
    /// e.g. "appliance.identify", "appliance.get_instructions",
    /// "nepali_calendar.query". Must be globally unique — namespaced by
    /// pluginID by convention, not enforced by the type system (see §7
    /// item 2 for why that's flagged as an open risk, not solved here).
    let actionNames: [String]
    /// Prose merged into the shared prompt — mirrors how the core prompt
    /// already describes each action + its entities (see `IntentPrompt`
    /// as it stands post-INTENT-PROMPT-UNIFY).
    let promptFragment: String
}

struct PluginCommand {
    let actionName: String        // one of the plugin's own actionNames
    let transcript: String        // sanitised, as CommandRouter already produces
    let entities: [String: String] // whatever the plugin asked the LLM to extract,
                                    // keyed by whatever field names its own prompt fragment defined
    let confidence: Double
}

struct PluginExecutionContext {
    let locale: Locale
    let geminiClient: GeminiClient   // plugins get the SAME client, same cost/observability chokepoint
    let observabilityBus: ObservabilityBus
}

enum PluginResult {
    case spoken(String)                          // just say this, no view
    case spokenAndPresented(String, resultID: UUID)  // say this AND show a view (host looks up
                                                       // the view via presentationView(for:))
    case failed(spokenApology: String)
}
```

## 2. Registry

```swift
final class PluginRegistry {
    private(set) var plugins: [AssistantPlugin] = []
    func register(_ plugin: AssistantPlugin) { plugins.append(plugin) }
    func activePlugins(for locale: Locale) -> [AssistantPlugin] {
        plugins.filter { $0.isApplicable(locale: locale) }
    }
    func plugin(handling actionName: String, locale: Locale) -> AssistantPlugin? {
        activePlugins(for: locale).first { $0.intentContribution.actionNames.contains(actionName) }
    }
}
```

`AppCoordinator` owns one `PluginRegistry`, registers built-ins at `init` (§6), passes it to
`IntentPrompt.build` (§4) and to `CommandRouter` (§3).

## 3. The one core-enum change

`InterpretedCommand.Action` (in `LlamaCommandInterpreter.swift`, shared by both interpreters via
`LlamaCommandInterpreter.parse(json:)`) stays a closed enum for the fixed, universal, safety-
relevant set — **unchanged**: `ackMed, call, emergency, setReminder, healthQuery, music,
sendMessage, query, none`. Adding exactly **one** new case:

```swift
case plugin = "plugin"
```

Plus one new field on `InterpretedCommand`:

```swift
/// Only meaningful when action == .plugin — which registered plugin
/// action this is (e.g. "appliance.identify"). Entities the plugin
/// itself needs travel in a new generic bag, NOT as more named optional
/// fields on this struct (that would just recreate the "core file grows
/// per feature" problem this design exists to avoid).
let pluginAction: String?
let pluginEntities: [String: String]?
```

`CommandRouter.dispatchInterpreted`'s exhaustive switch gets exactly one new case, forever,
regardless of how many plugins exist:

```swift
case .plugin:
    guard let actionName = command.pluginAction,
          let plugin = pluginRegistry.plugin(handling: actionName, locale: coordinator?.activeLocale ?? .current) else {
        emit(eventType: "command_plugin_unresolved", outcome: "blocked")
        speak(key: "router.pluginUnavailable")
        return
    }
    Task {
        let result = await plugin.handle(
            PluginCommand(actionName: actionName, transcript: /* the sanitised transcript */,
                          entities: command.pluginEntities ?? [:], confidence: command.confidence),
            context: PluginExecutionContext(locale: coordinator?.activeLocale ?? .current,
                                            geminiClient: /* shared client */,
                                            observabilityBus: observabilityBus)
        )
        // dispatch result.spoken/-AndPresented/-failed back through the
        // coordinator exactly like every other action already does —
        // reuses noteGenericReply/setOutcome-shaped plumbing, not new UI wiring.
    }
```

This is the entire permanent core cost of the plugin system: one enum case, two fields, one
switch case, ever again — every subsequent plugin is pure addition (a new file implementing
`AssistantPlugin` + one `registry.register(...)` line), not a further core edit.

## 4. Prompt composition (supersedes IntentPrompt as a static string)

Once INTENT-PROMPT-UNIFY lands (`IntentPrompt.build(transcript:context:)`, a single shared
function used by both interpreters — see that work-in-progress), this design turns it from a
static string builder into a composer:

```swift
enum IntentPrompt {
    static func build(transcript: String, context: InterpreterContext,
                      activePlugins: [AssistantPlugin]) -> String {
        var sections = [coreSchemaAndInstructions(context: context)]
        for plugin in activePlugins {
            sections.append(plugin.intentContribution.promptFragment)
        }
        sections.append("User said: \"\(transcript)\"")
        return sections.joined(separator: "\n\n")
    }
}
```

`GeminiCommandInterpreter`/`LlamaCommandInterpreter` pass `pluginRegistry.activePlugins(for:
context.userLanguageHint-derived locale)` — meaning a Nepali-locale user's actual prompt includes
the Nepali calendar plugin's vocabulary and an English-locale user's prompt doesn't, automatically,
from the same `isApplicable` check the registry already does for dispatch. One mechanism, used
for both "what can the LLM recognize" and "who handles it once recognized" — no separate
allow-list to keep in sync.

## 5. Hard boundary: what is NEVER a plugin

Emergency detection (`CommandRouter.routeKeyword`'s emergency-phrase check + the LLM `emergency`
action), medication acknowledgement/reminders/escalation, and the deterministic keyword safety
net stay in core, permanently, not as a starting point that migrates out later. Constitution:
*"Emergency calling logic must not be blocked by the on-device LLM being busy or unavailable."*
A plugin system, by construction, can fail to load, fail `isApplicable`, or throw inside
`handle(...)` — none of that is acceptable failure surface for a safety-critical path. Plugins
are for CAPABILITY EXPANSION only. This is worth stating as a rule future feature work must
re-check against, not just a note for today.

## 6. First two plugins (design-level only, not implemented here)

### 6.1 `ApplianceHelperPlugin` — supersedes the base design's §6.1

The existing appliance-helper base design (§6.1) and its live-AR addendum both proposed adding
`identify_appliance`/`get_instructions` directly to the core `Action` enum — written before this
plugin design existed. Under this design, that becomes:

- `pluginID`: `"appliance_helper"`.
- `isApplicable`: always `true` — universal, not geography-gated.
- `intentContribution.actionNames`: `["appliance.identify", "appliance.get_instructions"]`, with
  the SAME prompt language the base design's §6.1 already drafted, unchanged in substance.
- `handle(_:context:)`: wraps the base design's `GeminiClient.identifyAppliance`/
  `getApplianceInstructions` calls (§3 of the base design) and the addendum's search-grounding
  retry (§12) — all of that design content is still valid, it just now lives inside this plugin's
  `handle` implementation instead of inside `CommandRouter`.
- `ApplianceCache`/`LabelTranslationCache` (base design §4.3, addendum §13.2) become this
  plugin's OWN private storage — not core state, matching "plugins own their local knowledge."
- `presentationView(for:)` returns `ApplianceHelperView`/`ApplianceLiveARView` (addendum §13.3).

No other content from either existing appliance doc changes — this is purely "which file owns
the wiring," not a rethink of the feature itself.

### 6.2 `NepaliCalendarPlugin` — new, the geography-plugin proof case

- `pluginID`: `"nepali_calendar"`.
- `isApplicable(locale:)`: `locale.language.languageCode?.identifier == "ne"` — the concrete,
  minimal version of "geography-specific plugins" the user asked for. A future India-specific or
  Bangladesh-specific plugin follows the identical pattern with a different check.
- `intentContribution`: recognizes questions like "आज नेपाली पात्रोमा के हो" (what's today in the
  Nepali calendar) or "यस वर्ष दशैं कहिले हो" (when is Dashain this year).
- `handle(_:context:)`: reuses the SAME search-grounding pattern verified live this session
  (`tools: [{"google_search": {}}]`, confirmed working — see the appliance addendum §12.1) rather
  than hand-building Bikram Sambat/Panchanga date math — consistent with that already-made
  "let Gemini synthesize, cache the result locally" decision, applied to a second domain instead
  of re-litigated.
- Caches results locally (a festival date, once resolved for the current year, doesn't need
  re-fetching) — its own small `EncryptedLocalStorage`-backed cache, same pattern as
  `GeminiConfigStore`/`ApplianceCache`.

This plugin is genuinely small (mostly search-grounded Q&A) — its value here is as the reference
implementation proving the geography-gating mechanism works end-to-end, not as a large feature.

## 7. Open decisions

1. **Sequencing.** This touches `InterpretedCommand`, `IntentPrompt`, and
   `CommandRouter.dispatchInterpreted` — the same three files INTENT-PROMPT-UNIFY is finishing
   right now and STACK-TOGGLE just merged. Recommend implementing this ONLY after
   INTENT-PROMPT-UNIFY's branch is merged and the tree is green, as its own subsequent change —
   not in parallel with either. **Open for confirmation, but strongly recommended.**
2. **`actionName`/`pluginID` uniqueness is convention, not enforced.** Two plugins could
   register overlapping `actionNames` and the registry's `.first { ... }` would silently pick
   one. Fine at 2 plugins; needs an explicit collision check (fail loudly at registration time)
   before this scales past a handful. **Open, low urgency.**
3. **Plugin discovery model.** This design assumes plugins are compiled-in Swift types,
   registered by a fixed list in `AppCoordinator.init` — NOT dynamically loaded bundles/binaries.
   "Plugin" here means "an isolated, swappable Swift module," not "installable by a third party
   at runtime." Confirm that's the intended scope — a true dynamic-loading plugin system (signed
   bundles, sandboxing, a plugin marketplace) is a materially larger and different project.
   **Open, assumed narrower scope unless corrected.**
4. **Family-side plugin configuration.** Should family members be able to enable/disable plugins
   remotely (e.g. turn off the appliance helper for a household that doesn't want it), the same
   way they configure medication schedules and contacts? Not designed here. **Open.**
