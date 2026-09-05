# Plugin Architecture — Developer Guide

How to add a new capability to Sahayak without editing core voice files.
Implemented per `docs/superpowers/specs/2026-09-05-plugin-architecture-design.md` —
that doc is the *why*; this one is the *how*.

## The 60-second version

1. Create `ios/ElderlyAssistant/Services/Plugins/YourPlugin.swift` conforming to `AssistantPlugin`.
2. Register it in `AppCoordinator.init` next to the existing `pluginRegistry.register(...)` lines.
3. Add its localization keys.
4. Write tests against `FakeGeminiTransport`/`GeminiInMemoryStorage` like `NepaliCalendarPluginTests`.

You never touch `InterpretedCommand.Action`, `IntentPrompt`'s core text, or
`CommandRouter.dispatchInterpreted`'s switch — those are the three choke points this
architecture exists to eliminate.

## The contract

```swift
protocol AssistantPlugin: AnyObject {
    var pluginID: String { get }                      // stable namespace, e.g. "nepali_calendar"
    var displayNameKey: String { get }                // catalog key for a UI name
    func isApplicable(locale: Locale) -> Bool         // geography/language gate
    var intentContribution: PluginIntentContribution { get }  // action names + prompt fragment
    func handle(_ command: PluginCommand,
                context: PluginExecutionContext) async -> PluginResult
    func presentationView(for result: PluginResult) -> AnyView?  // nil if no UI
}
```

**Class-constrained on purpose** — plugins are stateful reference types; identity
matters for registry lookups and test doubles.

## How a voice command flows through your plugin

```
transcript → IntentPrompt.build(activePlugins:)     // your promptFragment is composed in
                                                      ONLY if isApplicable(activeLocale)
           → LLM emits action "plugin",
             pluginAction "<one of your actionNames>",
             pluginEntities {keys you declared}
           → CommandRouter (case .plugin — the ONLY core case, added once, forever)
           → registry.plugin(handling:pluginAction, locale:)
           → your handle(PluginCommand, PluginExecutionContext)
           → PluginResult.spoken / .spokenAndPresented / .failed
           → coordinator speaks + shows outcome card (+ optional sheet with your view)
```

`PluginExecutionContext` hands you the shared `GeminiClient` (same cost/observability
chokepoint as everything else — use it, don't create your own client), the locale, and
the observability bus.

## Geography gating — the one rule that makes "Nepali calendar plugin for Nepali" work

`isApplicable(locale:)` is checked **twice** with the same result:

1. **Prompt composition** — an inapplicable plugin's fragment never enters the prompt,
   so it costs zero tokens and zero misclassification risk for users it doesn't apply to.
2. **Dispatch** — even if the LLM hallucinates your actionName for an inapplicable user,
   `registry.plugin(handling:locale:)` returns nil and the user hears the honest
   "unavailable" message.

Check language via `locale.language.languageCode?.identifier == "ne"` (see
`NepaliCalendarPlugin`), never by special-casing in core.

## Hard rules

- **Safety-critical paths are never plugins.** Emergency, medication ack/reminders,
  and the deterministic keyword layer stay in core permanently (constitution: emergency
  must not depend on anything that can fail to load/apply). If your feature touches
  those, it doesn't belong in a plugin.
- **No silent stubs.** If your plugin isn't ready, `handle` returns
  `.failed(spokenApology:)` with an honest message (see `ApplianceHelperPlugin`),
  never a fake success.
- **Own your storage.** Plugin-local caches go through `EncryptedLocalStorage` keyed
  under your `pluginID` (see `NepaliCalendarPlugin`'s cache), never new global state
  in `AppCoordinator`.
- **Action names are namespaced by convention**: `pluginID.what_it_does`
  (`nepali_calendar.query`, `appliance.identify`). The registry **rejects duplicate
  action names at registration** — a collision emits a failure event and drops the
  second claimant (loud, but never crashes — an elderly user's app must still boot).
- **One network chokepoint.** Use `PluginExecutionContext.geminiClient`. If you need
  web search, `generateJSON(prompt:useSearchGrounding: true)` exists (verified live)
  — opt-in per call because it costs a real search.

## Reference implementations

- **`NepaliCalendarPlugin`** — the geography-plugin proof case: Nepali-only gating,
  search-grounded answers, year-scoped local cache.
- **`ApplianceHelperPlugin`** — the honest skeleton: registers intent vocabulary now so
  questions classify correctly, returns an explicit "not ready yet" until the vision
  pipeline lands.

## Testing pattern

- Registry/gating: `PluginRegistryTests` (fake plugin doubles — `FakePlugin` is
  reusable).
- Plugin logic: `NepaliCalendarPluginTests` — `FakeGeminiTransport` +
  `GeminiInMemoryStorage`, no network; test honest failure paths (no entity, low
  confidence, network down) as first-class cases, not afterthoughts.
- Dispatch: `CommandRouterTests` — fake interpreter emitting
  `InterpretedCommand(action: .plugin, pluginAction: ...)`; remember `speak()` is
  async — wait ~0.2s before asserting utterances.
- Parse round-trip: `LlamaCommandInterpreterTests.testParsePluginActionAndEntities`.
