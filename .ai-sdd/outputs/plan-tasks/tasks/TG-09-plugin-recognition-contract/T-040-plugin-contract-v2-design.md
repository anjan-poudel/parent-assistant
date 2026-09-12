# T-040: Plugin Contract v2 Design (recognition parity, transcript, governance)

## Metadata
- **Group:** [TG-09 — Plugin Recognition & Contract](../index.md)
- **Component:** Services/Plugins (AssistantPlugin, PluginRegistry), Services/Voice (CommandRouter), docs/superpowers/specs
- **Agent:** architect
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-039](T-039-plugin-recognition-brains-rnd.md)
- **Blocks:** [T-041](T-041-brain-independent-plugin-routing.md), [T-042](T-042-transcript-contract-and-doc-truth.md), [T-043](T-043-plugin-confirmation-governance.md)
- **Requirements:** FR-008, FR-009, FR-012, NFR-013, NFR-025

## Description

Turn T-039's decision into a complete, reviewed contract v2 for the plugin system: what "recognised" means on each brain and what the user hears when it is not; what `PluginCommand.transcript` actually is; how confirmation policy for plugin actions is declared and enforced by core instead of assumed; which invariants (compile-time registration, iOS-only runtime, fixed core vocabulary) are now written down as contract; and what happens to the two hard-coded core action-name lookups and the second, deterministic YouTube path. The design is recorded in the plugin architecture why-doc (`docs/superpowers/specs/2026-09-05-plugin-architecture-design.md`) as a new section; `docs/plugin-architecture.md` is updated by the implementation tasks in the same commits as the code they describe, per this repository's convention.

## Acceptance criteria

```gherkin
Feature: Plugin contract v2

  Scenario: Recognition parity is specified per brain with an honest failure outcome
    Given T-039's chosen routing option
    When the contract section is written
    Then it states for each brain whether a plugin utterance is recognised, deterministically matched, or explicitly rejected
    And it specifies the fail-soft ladder for the three failure points — no recognition, unresolved action name at dispatch, failure inside handle — each with the exact user-facing outcome (existing localized string or a new externalised key)
    And no failure point is allowed to surface a silent drop or a fabricated success (constitution: no silent stubs)

  Scenario: The transcript contract is decided, not deferred
    Given the current state: PluginCommand documents "the sanitised transcript" (AssistantPlugin.swift:65-66) while the normal dispatch path passes an empty string (CommandRouter.swift:2302-2307) and the guide-deferral path passes the raw pending transcript (CommandRouter.swift:2345-2348), and no router-level sanitisation exists (sanitisation lives only in the three interpreters: LlamaCommandInterpreter.swift:444, LocalIntentInterpreter.swift:101, GeminiCommandInterpreter.swift:56)
    When the design records its decision
    Then it picks exactly one of: (a) fix the code — sanitise with InputSanitiser.sanitise(_:level: .quarantine) at the plugin dispatch boundary and pass the sanitised transcript on both paths; or (b) fix the contract — remove the field and make plugins declare what they need as entities
    And the chosen option states the NFR-013 sanitisation point and what the guide-deferral path does after the change
    And the rejected option and its cost are recorded, so the choice is not re-litigated in T-042

  Scenario: Confirmation governance is enforcement, not convention
    Given plugin dispatch is tier .free with the comment that plugins own their confirmation policy (ConfirmationTier.swift:25-32)
    And RoutinePlugin executes its side effect (scheduler.addEntry) before speaking a confirmation (RoutinePlugin.swift:125-149), and YouTubePlugin's confirmation is likewise post-hoc (YouTubePlugin.swift:10-16)
    When the contract section is written
    Then it specifies an action-level declaration (for each plugin action name: read-only or side-effecting) that core enforces before calling handle, using the existing confirmation flow for side-effecting actions
    And it states that a plugin cannot declare its own action as never-gated or otherwise weaken core's classification
    And it states that read-only plugins (for example the Nepali calendar query) remain ungated
    And the enforcement point in CommandRouter is named, and it is not a new per-plugin switch case

  Scenario: The fabric invariants are written down with their unlock conditions
    Given registration is compile-time by a fixed list (PluginRegistry.swift:7-9), no dynamic loading API exists (no dlopen / NSClassFromString / bundle loading in the app sources), and Android contains no plugin code
    When the contract section is written
    Then the compile-time-only and iOS-only invariants are stated as contract, each with what would have to change to lift it
    And the contract includes the collision behaviour as-is: a duplicate action name emits ObservabilityEvent(component "plugin_registry", eventType "plugin_action_collision", outcome "failure") and drops the second claimant without crashing (PluginRegistry.swift:19-42)

  Scenario: The two hard-coded core action-name lookups get a recorded disposition
    Given core hard-codes "appliance.identify" in CommandRouter.handleGuide (CommandRouter.swift:2341) and "nepali_calendar.query" in AppCoordinator.nepaliCalendarAnswer (AppCoordinator.swift:5349)
    When the design is written
    Then it decides for each: keep as a documented core flow that defers to a plugin (with the reason), or replace with a registry-provided constant lookup
    And the plugin doc's "the ONLY core case" claim is corrected to reflect the decision (T-042 applies the wording)

  Scenario: The deterministic YouTube path is documented as an intentional second path
    Given a YouTube request can be served by the deterministic marker stage (CommandRouter.swift:888) executing through YouTubeTool (CommandRouter.swift:1873-1929) without YouTubePlugin, and by the plugin when the interpreter recognises it
    When the design is written
    Then both paths are described, with the deterministic stage as the no-model safety net and the plugin as the interpreter's slot-filling path
    And the shared YouTubeTool is recorded as the mechanism that prevents drift (YouTubePlugin.swift:20-23)
    And the design does not propose removing the deterministic stage

  Scenario: Adding a fixture plugin still requires no core edits
    Given the chosen routing and the governance declaration
    When the design's "add a plugin" walkthrough is written
    Then it proves the whole path — recognition, dispatch, governance — is reachable by adding one file plus one registration line in the factory (AppCoordinator.makePluginRegistry, AppCoordinator.swift:1275-1285)
    And no step requires editing InterpretedCommand.Action, IntentPrompt's core section, or CommandRouter.dispatchInterpreted's switch

  Scenario: TG-08 reconciliation is explicit
    Given T-039's decision and the T-033 outcome
    When the design is finalised
    Then either it records the exact encoder output field for the plugin gate class plus the change request ids against T-035 and T-036, or it states that the encoder taxonomy carries no plugin class and how plugin eligibility is handled outside the model
    And it never contradicts the TG-08 taxonomy tasks silently

  Scenario: Design is reviewed and signed off before implementation starts
    Given the completed design section
    When it is submitted
    Then it is reviewed by the lead engineer and approved before T-041, T-042 or T-043 start
    And this task changes no production code and does not edit docs/plugin-architecture.md
```

## Implementation notes

- Inputs: T-039's decision record; `docs/superpowers/specs/2026-09-05-plugin-architecture-design.md` (the why-doc to extend); `docs/plugin-architecture.md` (the how-to that T-042 will correct); the live code cited above.
- Keep the constitution's hard boundary intact: emergency, medication ack/reminders and the deterministic keyword layer remain core, permanently; the design must restate why the failure surface of a plugin is unacceptable for those paths.
- Do not introduce a new confirmation UI: the enforcement must reuse the existing dual-channel yes/no flow with its 45-second timeout. If any plugin action genuinely needs no confirmation, it must be classified read-only by core's rule, not by the plugin's self-declaration.
- `PluginExecutionContext` stays exactly locale + shared `GeminiClient` + observability bus (AssistantPlugin.swift:73-79) unless the governance fix requires a strictly additive member; any change must be justified in the design and reflected in T-041/T-043.
- Do not edit `.ai-sdd/outputs/design-l2.md`; if a plugin contract point needs L2 recognition, record it as a note and leave the L2 amendment to the TG-08 owner (T-035).
- Honest-message strings must be externalised localisation keys, not literals (NFR-023); the dead `plugin.applianceHelper.notReady` key (Localizable.xcstrings:7687, no Swift usage) is T-042's to remove, not this task's.

## Definition of done
- [ ] Contract v2 section committed in the plugin architecture why-doc
- [ ] Transcript contract decided (fix-the-code or fix-the-contract) with the sanitisation point named
- [ ] Confirmation governance specified as a core-enforced action-level declaration, with the enforcement point named
- [ ] Compile-time-only and iOS-only invariants written down with unlock conditions
- [ ] Disposition recorded for both hard-coded core action-name lookups
- [ ] YouTube dual-path behaviour documented; deterministic stage retained
- [ ] "Add a plugin" walkthrough proves zero core switch/interpreter-enum edits
- [ ] TG-08 reconciliation recorded against T-035/T-036 (or a no-plugin-class statement)
- [ ] Design reviewed and approved by the lead engineer before T-041/T-042/T-043 start
