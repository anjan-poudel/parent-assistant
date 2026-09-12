# T-041: Implement Brain-Independent Plugin Recognition

## Metadata
- **Group:** [TG-09 — Plugin Recognition & Contract](../index.md)
- **Component:** Services/Plugins (registry-driven recognition), Services/Voice (CommandRouter, IntentRouter), Services/Intents
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-040](T-040-plugin-contract-v2-design.md)
- **Blocks:** [T-044](T-044-plugin-doc-contract-verification.md)
- **Requirements:** FR-007, FR-008, NFR-002, NFR-013

## Description

Implement the routing option T-039 selected and T-040 specified, behind the existing extension points, so that a plugin utterance is recognised on the on-device stack as well as the cloud stack — or, where the decision was keep-as-is, close the task with a recorded no-change outcome and no partial implementation. The work never adds a per-plugin case to core: `InterpretedCommand.Action` keeps its single `plugin` case (`LlamaCommandInterpreter.swift:81-87`), `CommandRouter.dispatchInterpreted` keeps its single `.plugin` case (`CommandRouter.swift:2106`, `2147`), and resolution continues to go through `PluginRegistry.plugin(handling:locale:)` (`PluginRegistry.swift:54-56`).

## Acceptance criteria

```gherkin
Feature: Plugin recognition on the local brain

  Scenario: A plugin utterance on the on-device stack reaches the plugin
    Given the on-device stack (no Gemini key configured) and a registered plugin with the vocabulary declared in T-040's design
    When the design's plugin utterances are routed
    Then PluginRegistry resolves the action name and the plugin's handle receives a PluginCommand with the declared entities
    And the response is spoken through the existing outcome plumbing without new UI wiring
    And the added latency keeps the turn inside NFR-002 on the reference device class

  Scenario: The deterministic stage never shadows safety or the keyword net
    Given an utterance that contains both a safety form and plugin vocabulary (for example an emergency phrase with an appliance word)
    When it is routed
    Then the emergency path executes exactly as before
    And a medication acknowledgement utterance is never diverted to a plugin
    And the keyword-net stages run before the plugin recognition path and their outcomes are unchanged

  Scenario: An unresolved plugin action fails honestly, never silently
    Given a registered plugin and an utterance whose resolved action name matches no active plugin (unregistered, or dropped earlier by the registry's collision rule at PluginRegistry.swift:19-42)
    When it is dispatched
    Then the existing observability event command_plugin_unresolved with outcome blocked is emitted
    And the user hears the existing localized router.pluginUnavailable message
    And no crash and no silent drop occurs

  Scenario: Adding a fixture plugin in tests requires no core edit
    Given the new recognition path
    When a test adds a fixture plugin through the registration factory
    Then the fixture is reachable end-to-end with no edit to InterpretedCommand.Action, IntentPrompt's core section, or CommandRouter.dispatchInterpreted's switch
    And an automated check (test or scripted source scan) proves the absence of per-plugin names in those three files

  Scenario: The cloud path is unchanged
    Given a configured Gemini brain
    When a plugin utterance is routed
    Then GeminiCommandInterpreter still composes applicable fragments only (GeminiCommandInterpreter.swift:72-75) and emits action "plugin" exactly as before
    And dispatch behaviour and spoken outcomes for the existing plugins are byte-identical to the pre-change behaviour

  Scenario: Matcher input is sanitised before it is matched
    Given a transcript carrying injection-shaped content
    When it enters the plugin recognition path
    Then InputSanitiser.sanitise(_:level: .quarantine) has been applied at the boundary chosen in T-040 before any matching or prompt composition (NFR-013)
    And an empty sanitised transcript falls through to the existing re-prompt path, not to a plugin

  Scenario: Observability stays PII-free
    Given any of the paths above
    When events are emitted
    Then they carry fixed rule/action vocabulary and outcomes only — never transcript text, entity values or user words (NFR-016)

  Scenario: Keep-as-is decision closes without code change
    Given T-039 selected the keep-as-is option and T-040's design does not specify a recognition change
    When this task executes
    Then no production code is changed
    And the closure note records that plugin capabilities remain cloud-only by decision, and that T-044 pins the reality test
    And no partial matcher is left in the tree
```

## Implementation notes

- The mechanism is T-040's decision (deterministic registry-driven vocabulary, an encoder gate class with a core matcher, or another option); this task implements that decision and nothing beyond it. If the decision routes through the TG-08 encoder, the encoder-side change belongs to the TG-08 change request recorded in T-039/T-040 — this task implements only the core/app-side part.
- Placement in the router ladder: after the safety net, confirmation flow, contact search, directions, alarms/timers, briefing, the strict news and YouTube stages, and the relaxed `KeywordIntentRule` stage (`CommandRouter.swift:888`, `893-931`) — mirror the ordering rationale already documented there; a plugin utterance must never pre-empt those stages.
- Do not extend `InterpretedCommand.Action`; do not add named entity fields to `InterpretedCommand` for plugin needs — plugin entities travel in `pluginEntities` (`LlamaCommandInterpreter.swift:121-128`).
- Do not change the on-device generation grammar or schema enums unless T-040 explicitly requires it; the audit reality is that they exclude "plugin" (`LlamaCommandInterpreter.swift:189-193`, `219-221`; `LocalIntentInterpreter.swift:303-312`).
- Tests follow the existing patterns: `CommandRouterTests` plugin dispatch fixtures (`CommandRouterTests.swift:229-285`), `PluginRegistryTests` doubles (`FakePlugin`, `PluginRegistryTests.swift:58-86`), `GuidePluginDispatchTests` for the guide-deferral path.
- Honest-failure strings must use existing externalised keys or new ones added to `Localizable.xcstrings` (NFR-023).

## Definition of done
- [ ] Chosen routing implemented behind existing extension points; no new core switch case per plugin
- [ ] On-device plugin utterance reaches `handle` with correct entities and speaks the declared outcome
- [ ] Safety precedence proven: emergency, med-ack and keyword stages unaffected by the new path
- [ ] Unresolved action emits `command_plugin_unresolved` and speaks the honest unavailable message
- [ ] Fixture-plugin test proves zero core edits for a new plugin
- [ ] Cloud path behaviour unchanged, verified by the existing dispatch tests
- [ ] Sanitisation applied at the T-040-specified boundary (NFR-013); observability PII-free (NFR-016)
- [ ] If keep-as-is: closure note committed, no code left behind
