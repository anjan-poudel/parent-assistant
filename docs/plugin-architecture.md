# Plugin Architecture — Developer Guide

How to add a new capability to Sahayak without editing core voice files.
Implemented per `docs/superpowers/specs/2026-09-05-plugin-architecture-design.md` —
that doc is the *why*; this one is the *how*.

## The 60-second version

1. Create `ios/ElderlyAssistant/Services/Plugins/YourPlugin.swift` conforming to `AssistantPlugin`.
2. Register it in `AppCoordinator.makePluginRegistry()` (`AppCoordinator.swift:1275-1285`) next to
   the existing `registry.register(...)` lines. The registry itself is a lazy first-use factory
   (`AppCoordinator.swift:1156`) and is deliberately NOT constructed in `init`
   ([BOOT-REVIEW P0-1]): the built-ins are storage-backed services the first frame never touches.
   Keep your registration inside the factory.
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
           → CommandRouter (case .plugin — the only plugin-action case in core's switch)
           → registry.plugin(handling:pluginAction, locale:)
           → your handle(PluginCommand, PluginExecutionContext)
           → PluginResult.spoken / .spokenAndPresented / .failed
           → coordinator speaks + shows outcome card (+ optional sheet with your view)
```

`case .plugin` is the only case in `CommandRouter.dispatchInterpreted`'s switch that exists for
plugins — but core names two plugin actions directly, and those are the only exceptions:

- `appliance.identify` in `CommandRouter.handleGuide` (`CommandRouter.swift:2336`) — the guide
  flow (spec §5) defers to the appliance plugin because the plugin owns appliance UX (photo +
  grounding overlay, manuals).
- `nepali_calendar.query` in `AppCoordinator.nepaliCalendarAnswer` (`AppCoordinator.swift:5349`) —
  the calendar display surface asks the plugin for a spoken answer.

Both are fixed core-owned flows that name a plugin action directly (not per-plugin hooks), and
neither is the general interpreter dispatch path — adding a plugin never adds a case there.

**Which brain recognises your plugin.** Plugin recognition is per brain, not
brain-independent. The cloud Gemini brain composes your `promptFragment` into its prompt
(`GeminiCommandInterpreter.swift:72-75`), so it can emit your action names. The on-device brains
do **not** compose plugin fragments — the 1,024-token context cannot fit them
(`LlamaCommandInterpreter.swift:319-326`; `LocalIntentInterpreter` builds its prompt without a
registry) — so the on-device brain itself cannot emit your action names. That does not make
plugin recognition impossible on the on-device stack: with the "Ask Gemini when I can't answer"
opt-in, `applyVoiceEngineStack` enables the router's cloud layer (`AppCoordinator.swift:3691-3715`;
the `GeminiCommandInterpreter` wired as `cloudBrain`, `AppCoordinator.swift:2153`) and
`IntentRouter` escalates an abstained utterance to it (`IntentRouter.swift:177-248`), which does
compose your fragment. Core's `.guide` flow also defers to `appliance.identify` on any brain
(`CommandRouter.swift:2336`). Design your plugin for the cloud brain; the on-device brain alone
cannot classify into it, so treat strictly-on-device recognition (no opt-in) as unavailable until
the on-device context budget changes.

`PluginCommand.transcript` is the **sanitised utterance** (`InputSanitiser` quarantine level,
the same policy every interpreter applies before a prompt), built at the router's single
dispatch boundary, so normal `.plugin` dispatch and the guide-deferral path hand you identical
field semantics. It is empty only when no voice utterance is in flight (screen-initiated calls
such as the calendar display pass `""` and carry their input as an entity).

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
- **No silent stubs.** If your plugin cannot serve a request, `handle` returns
  `.failed(spokenApology:)` with an honest localised message (see
  `ApplianceHelperPlugin`'s unconfigured-client path), never a fake success.
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

Four plugins are registered in `AppCoordinator.makePluginRegistry()`
(`AppCoordinator.swift:1275-1285`). Three are built inside the factory; `RoutinePlugin` is
constructed eagerly in `init` (`AppCoordinator.swift:1432`) and only registered by the factory
(`:1279`):

- **`NepaliCalendarPlugin`** — the geography-plugin proof case: Nepali-only gating,
  search-grounded answers, year-scoped local cache.
- **`ApplianceHelperPlugin`** — the live appliance helper: `handle` opens the camera surface
  (`spokenAndPresented`) and `ApplianceHelperView` drives capture → identify → overlay through
  `ApplianceHelperSession` (`ApplianceHelperPlugin.swift:69-106`; tests at
  `ApplianceHelperPluginTests.swift:73, 88`). Its only honest failure is the unconfigured
  client: with no Gemini key it returns `.failed` with `plugin.applianceHelper.notConfigured`
  (`ApplianceHelperPlugin.swift:70-74`).
- **`RoutinePlugin`** — generalised routine reminders (`routine.set` / `routine.query`) backed
  by `RoutineScheduler`; medication-shaped reminders deliberately stay in core.
- **`YouTubePlugin`** — the interpreter-side twin of the router's deterministic YouTube stage;
  both share `YouTubeTool` (`YouTubePlugin.swift:20-23`) so the two paths cannot drift.

## Invariants

- **Compile-time registration only.** Plugins are a fixed list compiled into the app
  (`PluginRegistry.swift:7-9`). There is no dynamic loading — no `dlopen`, no
  `NSClassFromString`, no bundle loading; the collision rule above is the runtime backstop for
  the fixed list, not a loading mechanism. Adding a plugin is one Swift file plus one
  `register(...)` line in `AppCoordinator.makePluginRegistry()`. Lifting this invariant would
  mean a reviewed dynamic-loading API and a trust model that do not exist today.
- **iOS-only runtime.** The plugin runtime ships only in the iOS app
  (`ios/ElderlyAssistant/Services/Plugins/`). Android contains no plugin code — no registry, no
  `AssistantPlugin`, no plugin action names. This guide describes the iOS implementation only.

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
